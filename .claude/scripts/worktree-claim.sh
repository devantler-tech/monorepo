#!/usr/bin/env bash
# worktree-claim.sh — own a per-run worktree so a sibling cannot squat it unseen.
#
# WHY THIS EXISTS (monorepo#2284)
#   The claim protocol covers the issue (assignee), the branch (pushed ref), and
#   the PR. A worktree directory is claimed by nothing. Two consecutive ticks
#   lost validated work because a sibling edited files inside a worktree this
#   session created while every GitHub-side claim signal read clean — the
#   collision surfaced only as "File has been modified since read" after work
#   was already underway.
#
#   This helper atomically acquires an ownership marker when creating or
#   entering a worktree. A live foreign marker is treated like a live issue
#   claim: pick another lane. Markers expire after ~2 hours so a crashed
#   session parks nothing permanently (same window as issue claims).
#
# USAGE
#   .claude/scripts/worktree-claim.sh add  <repo_path> <worktree_path> <branch> <owner-token>
#       Create the worktree (git worktree add -b <branch>) and write the marker.
#       A relative worktree_path is resolved from repo_path.
#   .claude/scripts/worktree-claim.sh check <worktree_path> <my-owner-token>
#       Read-only diagnostic: exit 0 if free / mine / expired; exit 3 if a live
#       foreign claim exists. This does not reserve the worktree.
#   .claude/scripts/worktree-claim.sh acquire <worktree_path> <owner-token>
#       Atomically acquire a free/expired worktree or renew the current owner's
#       lease. Exit 3 without changing the marker when another live owner wins.
#   .claude/scripts/worktree-claim.sh mark  <worktree_path> <owner-token>
#       Compatibility alias for `acquire`.
#
# MARKER
#   Path: <worktree>/.claude-worktree-owner  (gitignored locally by agents; never
#   staged — it is session state, not product content).
#   Format (two lines, KEY=value):
#     owner=<slug>
#     created_at=<ISO-8601 UTC, e.g. 2026-07-21T07:40:00Z>
#
# EXIT CODES
#   0  success / free-or-mine-or-expired
#   1  usage / argument error
#   2  git or filesystem failure
#   3  live foreign claim (check or acquire mode)

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=worktree-claim-lib.sh
. "$SCRIPT_DIR/worktree-claim-lib.sh" || {
  echo "worktree-claim: cannot load shared claim protocol" >&2
  exit 2
}

usage() {
  cat >&2 <<'EOF'
usage:
  worktree-claim.sh add   <repo_path> <worktree_path> <branch> <owner-token>
  worktree-claim.sh check <worktree_path> <my-owner-token>
  worktree-claim.sh acquire <worktree_path> <owner-token>
  worktree-claim.sh mark  <worktree_path> <owner-token>
EOF
  exit 1
}

fail() {
  echo "worktree-claim: $*" >&2
  exit 2
}

write_marker() {
  local wt="$1" owner="$2"
  local marker="$wt/$WORKTREE_CLAIM_MARKER_NAME"
  # Atomic-ish write: temp then mv, so a concurrent reader never sees a half
  # file. Do not stage this path — it is per-session state.
  local tmp
  tmp="$(mktemp "$wt/.claude-worktree-owner.XXXXXX")"
  printf 'owner=%s\ncreated_at=%s\n' "$owner" "$(worktree_claim_utc_now)" >"$tmp"
  mv -f "$tmp" "$marker"
}

trap 'worktree_claim_lock_release >/dev/null 2>&1 || true' EXIT
trap 'exit 2' HUP INT TERM

acquire_lock() {
  local wt=$1 rc=0
  worktree_claim_lock_acquire "$wt" || rc=$?
  case "$rc" in
    0) ;;
    1) fail "timed out waiting for ownership lock: $wt" ;;
    *) fail "malformed, unreadable, or unavailable ownership lock: $wt" ;;
  esac
  [ "$WORKTREE_CLAIM_LOCK_RECOVERED" -eq 1 ] &&
    echo "worktree-claim: recovered stale ownership lock: $WORKTREE_CLAIM_LOCK_REF" >&2
  return 0
}

release_lock() {
  local ref=${WORKTREE_CLAIM_LOCK_REF:-unknown}
  worktree_claim_lock_release || fail "ownership lock changed owner before release: $ref"
}

ignore_marker() {
  local wt="$1"
  local exclude
  exclude="$(git -C "$wt" rev-parse --git-path info/exclude)" ||
    fail "cannot resolve git exclude file for worktree: $wt"
  mkdir -p "$(dirname "$exclude")"
  if ! grep -qxF "/$WORKTREE_CLAIM_MARKER_NAME*" "$exclude" 2>/dev/null; then
    if [ -s "$exclude" ] && [ -n "$(tail -c 1 "$exclude")" ]; then
      printf '\n' >>"$exclude"
    fi
    printf '/%s*\n' "$WORKTREE_CLAIM_MARKER_NAME" >>"$exclude"
  fi
}

read_marker() {
  # Sets MARKER_OWNER and MARKER_CREATED_AT from the file, or leaves them empty.
  local marker="$1"
  MARKER_OWNER=""
  MARKER_CREATED_AT=""
  [ -f "$marker" ] || return 0
  # shellcheck disable=SC2034
  while IFS='=' read -r key val; do
    case "$key" in
      owner) MARKER_OWNER="$val" ;;
      created_at) MARKER_CREATED_AT="$val" ;;
    esac
  done <"$marker"
}

cmd_acquire() {
  local wt="$1" owner="$2"
  [ -d "$wt" ] || fail "worktree path is not a directory: $wt"
  [ -n "$owner" ] || usage
  wt="$(cd "$wt" && pwd -P)" || fail "cannot resolve worktree path: $wt"
  acquire_lock "$wt"
  ignore_marker "$wt"
  local marker="$wt/$WORKTREE_CLAIM_MARKER_NAME" action="acquired"
  read_marker "$marker"
  if [ -e "$marker" ]; then
    if [ -z "${MARKER_OWNER:-}" ] || [ -z "${MARKER_CREATED_AT:-}" ]; then
      fail "malformed ownership marker (owner and created_at are required): $marker"
    fi
    if [ "$MARKER_OWNER" = "$owner" ]; then
      action="renewed"
    else
      local created_epoch now_epoch age
      created_epoch="$(worktree_claim_iso_to_epoch "$MARKER_CREATED_AT")" ||
        fail "unparseable ownership marker timestamp: $MARKER_CREATED_AT"
      now_epoch="$(date -u +%s)"
      age=$((now_epoch - created_epoch))
      if [ "$age" -lt "$WORKTREE_CLAIM_TTL_SECS" ]; then
        echo "worktree-claim: LIVE foreign claim owner=$MARKER_OWNER created_at=$MARKER_CREATED_AT age=${age}s — stand down" >&2
        release_lock
        exit 3
      fi
      action="transferred expired claim"
    fi
  fi
  write_marker "$wt" "$owner"
  release_lock
  echo "worktree-claim: $action $wt owner=$owner"
}

cmd_mark() {
  cmd_acquire "$1" "$2"
}

cmd_add() {
  local repo="$1" wt="$2" branch="$3" owner="$4"
  [ -d "$repo" ] || fail "repo path is not a directory: $repo"
  [ -n "$wt" ] && [ -n "$branch" ] && [ -n "$owner" ] || usage
  local repo_abs
  repo_abs="$(cd "$repo" && pwd -P)" || fail "cannot resolve repo path: $repo"
  case "$wt" in
    /*) ;;
    *) wt="$repo_abs/$wt" ;;
  esac
  if [ -e "$wt" ]; then
    fail "worktree path already exists: $wt"
  fi
  # Create parent so git worktree add can place the tree.
  mkdir -p "$(dirname "$wt")"
  if ! git -C "$repo" worktree add -b "$branch" "$wt"; then
    fail "git worktree add failed for $wt (branch $branch)"
  fi
  # Claim BEFORE the advisory freshness check, not after. That check makes up to two bounded remote
  # calls, so it can hold the newly-created tree unclaimed for the length of both timeouts — a window
  # in which a concurrent run can take the marker, leaving this invocation to create the worktree and
  # branch and then exit 3 without the lane it just built. Ownership is the point of `add`; freshness
  # is a NOTE, so the note waits.
  cmd_acquire "$wt" "$owner"
  warn_if_base_is_stale "$repo" "$wt"
  echo "worktree-claim: added $wt on $branch owner=$owner"
}

# base_freshness_unknown reports that the comparison could not be made. Both unresolvable paths emit
# it: staying silent would be indistinguishable from "base is current", which is the exact confusion
# the staleness check below exists to remove.
base_freshness_unknown() {
  echo "worktree-claim: NOTE could not resolve $1 — base freshness UNKNOWN, verify before" >&2
  echo "worktree-claim:      concluding anything about current upstream behaviour." >&2
}

# How long an advisory remote call may take before it is abandoned. Short on purpose: this runs on
# the creation path of every worktree, and its answer is a NOTE, never a gate.
WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="${WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS:-10}"

# bounded_remote runs an advisory remote git call that can never hang the claim.
#
# Both remote calls below happen inside cmd_add, where the freshness check is explicitly allowed to
# fail — so a remote that never answers must not block worktree creation. Two different hangs are
# possible and they need different fixes: a credential or passphrase PROMPT waits forever (closed by
# GIT_TERMINAL_PROMPT and ssh BatchMode), and an UNREACHABLE host waits on TCP (closed by the timer).
#
# Deliberately not coreutils `timeout`: it is absent from a stock macOS, which is both this script's
# primary host and one leg of the CI matrix, so a timeout-based bound would silently not apply on the
# platform that needs it most. The killer subshell below is portable to bash 3.2.
#
# Two non-obvious details, both verified rather than assumed:
#   * the command is `wait`ed on, not polled with `kill -0` — a finished child stays a zombie until it
#     is reaped, so a poll loop would spin until the deadline instead of returning immediately;
#   * the killer's stdout is redirected, because it would otherwise inherit and hold open a caller's
#     pipe, making every call take the full timeout even when git answered instantly.
bounded_remote() {
  local secs="$1"
  shift
  local cmd_pid killer_pid rc=0 had_monitor=0
  # Job control gives the background command its OWN process group, which is what makes the whole
  # transport tree killable. git delegates to a helper (`git remote-ext`, ssh, git-remote-https); a
  # kill aimed at the git pid alone leaves that helper reparented and running to ITS native timeout,
  # and `add` can time out twice per call, so an unresponsive remote accumulates them.
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" "$@" &
  cmd_pid=$!
  [ "$had_monitor" -eq 1 ] || set +m
  (
    sleep "$secs"
    # Negative pid = the process GROUP. Falls back to the single pid if the group is already gone
    # (or job control was unavailable), so a host without it degrades to the previous behaviour
    # rather than failing to time out at all.
    kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  killer_pid=$!
  # `wait` reports a signal-killed job on the SHELL's stderr, so it is silenced here rather than at
  # each call site.
  { wait "$cmd_pid" || rc=$?; } 2>/dev/null
  kill -TERM "$killer_pid" 2>/dev/null || true
  { wait "$killer_pid" || true; } 2>/dev/null
  return "$rc"
}

# shquote renders "$1" as one single-quoted shell word, so a path or ref containing spaces, newlines,
# or shell metacharacters prints as a single safely reusable argument rather than something that
# would re-split or be interpreted if pasted back into a shell.
#
# The escaping is a parameter expansion rather than `$(… | sed …)`: command substitution strips
# TRAILING NEWLINES, so a path ending in one was quoted as a different path than the one being
# operated on — and this output is a command the reader is invited to paste and run.
shquote() {
  local escaped=${1//\'/\'\\\'\'}
  printf "'%s'" "$escaped"
}

# warn_if_base_is_stale reports how far the new worktree's base is behind the remote default branch.
#
# A submodule worktree is created at the PINNED gitlink, not at the remote default branch, and git
# says nothing about the gap. That silence is the whole defect: a tree tens of commits stale reads
# exactly like a current one, so "this code is missing X" can be true of the pin and false upstream.
# Measured twice on the same issue (ksail#6203, pin 7ac8e7bb) — the second time it reached a public
# root-cause comment asserting a security hole that two merged PRs had already closed. A prose rule
# did not prevent either occurrence, because the moment you need it is the moment you have no reason
# to suspect anything. So the check is unconditional and its output lands at creation time.
#
# Advisory, never fatal: creating a worktree at the pin is legitimate (a monorepo-coordinated change
# pins deliberately), and an offline or restricted host must still be able to claim one.
warn_if_base_is_stale() {
  local repo="$1" wt="$2" default_ref default_branch behind
  # Ask the REMOTE for its current default branch. refs/remotes/origin/HEAD is local metadata written
  # at clone time and never refreshed, so once a repository's default moves (main → trunk) the stale
  # pointer makes this compare against a branch the remote no longer defaults to — and report "not
  # behind" while the tree is arbitrarily stale, which is precisely the silence this check removes.
  # `|| true`: with `set -o pipefail` a repo that has no origin at all (or an unreachable one) would
  # otherwise abort the whole claim on an advisory check that is explicitly allowed to fail.
  default_branch="$(bounded_remote "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" \
    git -C "$repo" ls-remote --symref origin HEAD 2>/dev/null |
    awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }' || true)"
  if [ -z "$default_branch" ]; then
    # Remote discovery FAILED, and that is not the same as "the default is probably main". The local
    # pointer and the conventional guess are exactly the stale sources this function was written to
    # stop trusting: if the remote default has moved, the old branch usually still exists and still
    # fetches, so comparing against it yields behind=0 and reports a current base for an arbitrarily
    # stale tree — the silent false-current this check exists to remove, reached by the fallback
    # rather than by the bug it replaced.
    #
    # Claiming still succeeds (advisory, never fatal); only the freshness VERDICT becomes UNKNOWN.
    base_freshness_unknown "origin/HEAD"
    return 0
  fi
  default_ref="origin/$default_branch"
  if ! bounded_remote "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" \
    git -C "$repo" fetch --quiet origin "$default_branch" 2>/dev/null; then
    base_freshness_unknown "$default_ref"
    return 0
  fi
  if ! git -C "$repo" rev-parse --verify --quiet "$default_ref" >/dev/null 2>&1; then
    base_freshness_unknown "$default_ref"
    return 0
  fi
  # A FAILED rev-list is an unavailable comparison, not a current base. Folding it into `|| echo 0`
  # made the normalisation below accept it and the numeric test skip silently — reporting neither a
  # warning nor UNKNOWN, which is the same silent "looks current" this check exists to remove.
  if ! behind="$(git -C "$wt" rev-list --count "HEAD..$default_ref" 2>/dev/null)"; then
    base_freshness_unknown "$default_ref"
    return 0
  fi
  # A non-integer (empty, or an error string) from a command that nonetheless SUCCEEDED must be
  # handled before the numeric test, or `[ "$behind" -gt 0 ]` fails OPEN inside an if and silently
  # skips the very warning this exists for. It takes the UNKNOWN path rather than normalising to 0:
  # folding it to 0 also stopped the fail-open, but it bought that by rendering an unestablished
  # comparison exactly like a current base — the same silence the FAILED-rev-list branch above
  # refuses, and the one this whole check exists to remove.
  case "$behind" in '' | *[!0-9]*)
    base_freshness_unknown "$default_ref"
    return 0
    ;;
  esac
  [ "$behind" -gt 0 ] || return 0
  echo "worktree-claim: WARNING base is $behind commit(s) behind $default_ref" >&2
  echo "worktree-claim:      This tree does NOT show current $default_ref. Anything you conclude here" >&2
  echo "worktree-claim:      about 'current behaviour' may already be changed or fixed upstream." >&2
  echo "worktree-claim:      Rebase before analysing:  git -C $(shquote "$wt") rebase $(shquote "$default_ref")" >&2
}

cmd_check() {
  local wt="$1" me="$2"
  [ -n "$me" ] || usage
  if [ ! -d "$wt" ]; then
    # No directory → nothing to squat; caller may create.
    echo "worktree-claim: free (path absent)"
    exit 0
  fi
  local marker="$wt/$WORKTREE_CLAIM_MARKER_NAME"
  read_marker "$marker"
  if [ ! -e "$marker" ]; then
    echo "worktree-claim: free (no live marker)"
    exit 0
  fi
  if [ -z "${MARKER_OWNER:-}" ] || [ -z "${MARKER_CREATED_AT:-}" ]; then
    fail "malformed ownership marker (owner and created_at are required): $marker"
  fi
  if [ "$MARKER_OWNER" = "$me" ]; then
    echo "worktree-claim: mine (owner=$MARKER_OWNER)"
    exit 0
  fi
  local created_epoch now_epoch age
  created_epoch="$(worktree_claim_iso_to_epoch "$MARKER_CREATED_AT")" ||
    fail "unparseable ownership marker timestamp: $MARKER_CREATED_AT"
  now_epoch="$(date -u +%s)"
  age=$((now_epoch - created_epoch))
  if [ "$age" -ge "$WORKTREE_CLAIM_TTL_SECS" ]; then
    echo "worktree-claim: free (expired age=${age}s owner=$MARKER_OWNER)"
    exit 0
  fi
  echo "worktree-claim: LIVE foreign claim owner=$MARKER_OWNER created_at=$MARKER_CREATED_AT age=${age}s — stand down" >&2
  exit 3
}

main() {
  [ $# -ge 1 ] || usage
  local mode="$1"
  shift
  case "$mode" in
    add)
      [ $# -eq 4 ] || usage
      cmd_add "$1" "$2" "$3" "$4"
      ;;
    check)
      [ $# -eq 2 ] || usage
      cmd_check "$1" "$2"
      ;;
    acquire)
      [ $# -eq 2 ] || usage
      cmd_acquire "$1" "$2"
      ;;
    mark)
      [ $# -eq 2 ] || usage
      cmd_mark "$1" "$2"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
