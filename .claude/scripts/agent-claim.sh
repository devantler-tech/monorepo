#!/usr/bin/env bash
#
# agent-claim.sh — lane-neutral claim arbitration for multi-instance races
# (monorepo#2302).
#
# Every agent instance writes its own work-branch namespace (`claude/*`,
# `codex/*`, `cursor/*`), so a race settled on the work-branch name is never
# arbitrated across lanes. This helper pushes a SINGLE shared ref
# `agent-claim/<issue>` that every instance derives from the issue number
# alone, BEFORE creating its lane-specific work branch. The push decides the
# race; the tip comparison (never the push's exit status) decides the winner.
#
# Four traps, all proven before this script existed — do not regress them:
#   1. Second non-force push is refused; ls-remote returns the winner's sha.
#   2. `git push … | tail` exits 0 on a REJECTED push — only the tip compare
#      is safe (never judge by exit status, never through a pipe).
#   3. Identical claim commits collide: every instance may commit as the same
#      login with the same message on the same parent in the same second,
#      yielding a byte-identical sha so BOTH pushes succeed. A portable nonce
#      in the message makes the commits distinct; fail closed when no entropy
#      source is available.
#   4. An unretired claim ref is a permanent lock (nothing sweeps
#      `agent-claim/*`). Retire on PR open; stale takeover needs BOTH evidence
#      gates (no open PR for the issue AND tip older than the lease).
#
# Usage:
#   agent-claim.sh acquire <issue> [--remote NAME] [--repo-dir DIR]
#                                [--lease-hours N] [--takeover]
#   agent-claim.sh verify  <issue> <expected-sha> [--remote NAME] [--repo-dir DIR]
#   agent-claim.sh tip     <issue> [--remote NAME] [--repo-dir DIR]
#   agent-claim.sh retire  <issue> [--remote NAME] [--repo-dir DIR]
#   agent-claim.sh is-stale <issue> [--remote NAME] [--repo-dir DIR]
#                                 [--lease-hours N]
#
# Exit codes:
#   0  success (acquired / tip matches / retired / is stale)
#   1  lost the race / tip mismatch / not stale
#   2  usage error / missing entropy / unsafe arguments
set -Eeuo pipefail

DEFAULT_REMOTE="origin"
DEFAULT_LEASE_HOURS=2
REF_PREFIX="refs/heads/agent-claim"

fail() { echo "agent-claim: $*" >&2; exit 2; }

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
}

# Portable entropy — fail closed when none is available (trap 3). Prefer
# /dev/urandom (Linux + macOS); never soft-fail back to a fixed message.
claim_nonce() {
  if [[ -r /dev/urandom ]]; then
    # 16 bytes hex, no whitespace. `od` is POSIX; tr strips the spaces od
    # inserts between bytes on some platforms.
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    return 0
  fi
  fail "no portable entropy source (/dev/urandom unreadable); refusing to claim with a fixed message (trap 3)"
}

# Resolve the claim ref name for an issue number. Caller must already have
# validated the issue via require_issue — this only formats.
claim_ref() {
  printf '%s/%s' "$REF_PREFIX" "$1"
}

# Short name used by git push (heads/… without refs/).
claim_branch() {
  printf 'agent-claim/%s' "$1"
}

# Validate issue BEFORE any command substitution — `exit` inside $(…) only
# kills the subshell, so a bad issue would otherwise soft-fail into exit 1.
require_issue() {
  [[ "$1" =~ ^[0-9]+$ ]] || fail "issue must be a positive integer (got '$1')"
}

# git wrapper scoped to --repo-dir when set.
git_c() {
  if [[ -n "${REPO_DIR}" ]]; then
    git -C "$REPO_DIR" "$@"
  else
    git "$@"
  fi
}

# Read the remote tip of the claim ref. Empty string when the ref is absent.
remote_tip() {
  local issue="$1"
  local ref
  ref="$(claim_ref "$issue")"
  # Match exact ref; awk prints the sha only. No pipe after push elsewhere.
  git_c ls-remote "$REMOTE" "$ref" | awk '{print $1; exit}'
}

# Committer unix time of a remote tip, via a local fetch of that single ref.
# Used only for the stale-takeover evidence gate (trap 4).
tip_committer_unix() {
  local issue="$1"
  local tip="$2"
  local tmp_ref="refs/agent-claim-probe/${issue}-$$"
  # Fetch the tip into a throwaway local ref so we can read its committer date
  # without checking it out. Clean up either way.
  if ! git_c fetch --quiet "$REMOTE" "+${tip}:${tmp_ref}" 2>/dev/null; then
    git_c update-ref -d "$tmp_ref" 2>/dev/null || true
    return 1
  fi
  local ts
  ts="$(git_c log -1 --format=%ct "$tmp_ref" 2>/dev/null || true)"
  git_c update-ref -d "$tmp_ref" 2>/dev/null || true
  [[ -n "$ts" ]] || return 1
  printf '%s' "$ts"
}

cmd_tip() {
  local issue="$1"
  require_issue "$issue"
  local tip
  tip="$(remote_tip "$issue")"
  if [[ -z "$tip" ]]; then
    echo "agent-claim: no tip for $(claim_branch "$issue")" >&2
    exit 1
  fi
  printf '%s\n' "$tip"
}

cmd_verify() {
  local issue="$1"
  local expected="$2"
  require_issue "$issue"
  [[ "$expected" =~ ^[0-9a-f]{7,40}$ ]] || fail "expected-sha looks invalid: '$expected'"
  local tip
  tip="$(remote_tip "$issue")"
  if [[ -z "$tip" ]]; then
    echo "agent-claim: LOST — $(claim_branch "$issue") is absent (expected $expected)" >&2
    exit 1
  fi
  # Accept exact match or unambiguous prefix (abbreviated expected vs full tip).
  if [[ "$tip" == "$expected" || "$tip" == "$expected"* ]]; then
    printf '%s\n' "$tip"
    exit 0
  fi
  echo "agent-claim: LOST — tip $tip is not yours (expected $expected)" >&2
  exit 1
}

# Returns 0 when the tip is past the lease, 1 when live/absent. Does not exit
# the process — callers that need a CLI exit use cmd_is_stale.
claim_is_stale() {
  local issue="$1"
  local tip
  tip="$(remote_tip "$issue")"
  [[ -n "$tip" ]] || return 1
  local ts now age_hours
  ts="$(tip_committer_unix "$issue" "$tip")" || return 1
  now="$(date -u +%s)"
  age_hours=$(( (now - ts) / 3600 ))
  (( age_hours >= LEASE_HOURS ))
}

cmd_is_stale() {
  local issue="$1"
  require_issue "$issue"
  local tip
  tip="$(remote_tip "$issue")"
  if [[ -z "$tip" ]]; then
    echo "agent-claim: no claim tip — nothing to judge stale" >&2
    exit 1
  fi
  local ts now age_hours
  ts="$(tip_committer_unix "$issue" "$tip")" || fail "could not read committer date for tip $tip"
  now="$(date -u +%s)"
  age_hours=$(( (now - ts) / 3600 ))
  if (( age_hours >= LEASE_HOURS )); then
    echo "agent-claim: STALE — tip $tip age=${age_hours}h lease=${LEASE_HOURS}h"
    exit 0
  fi
  echo "agent-claim: LIVE — tip $tip age=${age_hours}h lease=${LEASE_HOURS}h" >&2
  exit 1
}

cmd_retire() {
  local issue="$1"
  require_issue "$issue"
  local branch
  branch="$(claim_branch "$issue")"
  local tip
  tip="$(remote_tip "$issue")"
  if [[ -z "$tip" ]]; then
    echo "agent-claim: nothing to retire — ${branch} absent"
    exit 0
  fi
  # Delete the ref. If it is already gone, treat as success (idempotent).
  if ! git_c push --quiet "$REMOTE" ":${branch}" 2>/tmp/agent-claim-retire-$$.err; then
    local err
    err="$(cat /tmp/agent-claim-retire-$$.err 2>/dev/null || true)"
    rm -f /tmp/agent-claim-retire-$$.err
    if [[ -z "$(remote_tip "$issue")" ]]; then
      echo "agent-claim: retired ${branch} (already absent)"
      exit 0
    fi
    fail "retire of ${branch} failed: ${err:-unknown error}"
  fi
  rm -f /tmp/agent-claim-retire-$$.err
  echo "agent-claim: retired ${branch} (was $tip)"
}

cmd_acquire() {
  local issue="$1"
  require_issue "$issue"
  local branch tip existing
  branch="$(claim_branch "$issue")"

  existing="$(remote_tip "$issue")"
  if [[ -n "$existing" ]]; then
    if [[ "$TAKEOVER" -eq 1 ]]; then
      # Evidence gate 1 of 2 (caller must have confirmed no open PR). Gate 2:
      # tip past the lease. Refuse takeover of a live claim.
      if ! claim_is_stale "$issue"; then
        echo "agent-claim: REFUSED takeover — claim is still within the ${LEASE_HOURS}h lease (tip $existing)" >&2
        exit 1
      fi
      echo "agent-claim: taking over stale claim ${branch} (tip $existing)"
      # Delete the stale tip first so the subsequent non-force push can land.
      # Never --force onto a live tip — only delete after is-stale.
      git_c push --quiet "$REMOTE" ":${branch}" \
        || fail "could not delete stale ${branch} before takeover"
    else
      echo "agent-claim: LOST — ${branch} already held at $existing (pass --takeover after confirming no open PR + lease expiry)" >&2
      exit 1
    fi
  fi

  local nonce parent sha
  nonce="$(claim_nonce)"
  # Anchor on the remote default branch tip when available so two acquirers
  # share a parent (the condition that makes trap 3 reproducible). Fall back
  # to HEAD when offline / no remote default.
  parent="$(git_c ls-remote "$REMOTE" HEAD 2>/dev/null | awk '{print $1; exit}')"
  if [[ -z "$parent" ]]; then
    parent="$(git_c rev-parse HEAD)"
  fi

  # Empty commit with a UNIQUE message (nonce). Identical messages on the same
  # parent in the same second produce byte-identical commits (trap 3) — the
  # nonce is the whole defence.
  sha="$(git_c commit-tree "$parent^{tree}" -p "$parent" -m "chore: agent-claim #${issue} nonce=${nonce}")"

  # Push WITHOUT force. Capture status ourselves — never through a pipe
  # (trap 2: `push | tail` reports tail's status, so a rejection reads as 0).
  local push_rc=0
  git_c push --quiet "$REMOTE" "${sha}:refs/heads/${branch}" || push_rc=$?

  tip="$(remote_tip "$issue")"
  if [[ -z "$tip" ]]; then
    echo "agent-claim: LOST — push produced no tip for ${branch} (push_rc=${push_rc})" >&2
    exit 1
  fi
  if [[ "$tip" != "$sha" ]]; then
    echo "agent-claim: LOST — tip ${tip} is not ours (ours=${sha}, push_rc=${push_rc})" >&2
    exit 1
  fi
  # Tip matches ours — we won, regardless of push_rc (defensive: a weird
  # transport that exits non-zero after a successful update still counts).
  echo "agent-claim: WON ${branch} tip=${sha}"
  printf '%s\n' "$sha"
}

# ---------------------------------------------------------------------------
# argv
# ---------------------------------------------------------------------------
REMOTE="$DEFAULT_REMOTE"
REPO_DIR=""
LEASE_HOURS="$DEFAULT_LEASE_HOURS"
TAKEOVER=0
COMMAND=""
ISSUE=""
EXPECTED_SHA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    acquire|verify|tip|retire|is-stale)
      [[ -z "$COMMAND" ]] || fail "command already set to '$COMMAND'"
      COMMAND="$1"; shift
      ;;
    --remote) REMOTE="${2-}"; shift 2 || fail "--remote needs a value" ;;
    --repo-dir) REPO_DIR="${2-}"; shift 2 || fail "--repo-dir needs a value" ;;
    --lease-hours) LEASE_HOURS="${2-}"; shift 2 || fail "--lease-hours needs a value" ;;
    --takeover) TAKEOVER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) fail "unknown flag '$1'" ;;
    *)
      if [[ -z "$ISSUE" ]]; then
        ISSUE="$1"; shift
      elif [[ "$COMMAND" == "verify" && -z "$EXPECTED_SHA" ]]; then
        EXPECTED_SHA="$1"; shift
      else
        fail "unexpected argument '$1'"
      fi
      ;;
  esac
done

[[ -n "$COMMAND" ]] || { usage >&2; exit 2; }
[[ -n "$ISSUE" ]] || fail "issue number required"
[[ "$LEASE_HOURS" =~ ^[0-9]+$ ]] || fail "--lease-hours must be a non-negative integer"

case "$COMMAND" in
  acquire) cmd_acquire "$ISSUE" ;;
  verify)
    [[ -n "$EXPECTED_SHA" ]] || fail "verify requires <expected-sha>"
    cmd_verify "$ISSUE" "$EXPECTED_SHA"
    ;;
  tip) cmd_tip "$ISSUE" ;;
  retire) cmd_retire "$ISSUE" ;;
  is-stale) cmd_is_stale "$ISSUE" ;;
  *) fail "unknown command '$COMMAND'" ;;
esac
