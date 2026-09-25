#!/usr/bin/env bash
#
# agent-claim-sweep.sh — remove `agent-claim/<issue>` tips whose issue is closed
# (monorepo#3589).
#
# The claim protocol retires a tip when the draft PR opens, but a run that
# crashes, or a flow that never opens a PR, leaves the tip behind and nothing
# removes it later. Measured 2026-09-25: 39 of 43 tips in platform and ksail
# pointed at issues that were already closed.
#
# Safety properties:
#   - Only a tip whose issue in THIS repository reads `closed` is deleted.
#   - The delete goes through `agent-claim.sh retire` with the SHA this sweep
#     observed, so it is compare-and-swap: a tip re-acquired in between survives.
#   - A tip whose issue is open is kept, whatever its age (takeover is the
#     claim protocol's job, not this sweep's).
#   - A failed or unrecognised issue read skips that tip and makes the sweep
#     exit 2; it is never read as "closed".
#   - dry-run is the default; --apply is required to delete anything.
#
# Usage:
#   agent-claim-sweep.sh --repo <owner/repo> [--repo-dir DIR] [--remote NAME] [--apply]
#
# Output: one line per tip — `KEEP <n> open`, `REMOVE <n> closed <sha>`
# (dry-run: `WOULD-REMOVE`), `UNKNOWN <n> <reason>`, `RACED <n> <sha>` (the tip moved),
# `FAILED <n> <sha>` (the delete could not be confirmed) — then a
# summary line.
#
# Exit codes:
#   0  every tip was classified (and, with --apply, every closed one removed)
#   1  at least one removal did not happen (the tip moved or the delete failed)
#   2  usage error, unreadable remote, or at least one tip could not be classified
set -Euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claim_tool="${AGENT_CLAIM_TOOL:-$script_dir/agent-claim.sh}"

REPO=""
REPO_DIR="."
REMOTE="origin"
APPLY=0

die() { echo "agent-claim-sweep: $*" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 || die "--repo needs a value" ;;
    --repo-dir) REPO_DIR="${2:-}"; shift 2 || die "--repo-dir needs a value" ;;
    --remote) REMOTE="${2:-}"; shift 2 || die "--remote needs a value" ;;
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unexpected argument '$1'" ;;
  esac
done

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be <owner>/<repo> (got '$REPO')"
[[ -d "$REPO_DIR" ]] || die "--repo-dir '$REPO_DIR' is not a directory"

# Issue numbers are repository-scoped: the issue read must be about the same
# repository the listing reads and `retire` deletes from. Git contacts the
# EFFECTIVE URLs — after `insteadOf`, `pushurl` and `pushInsteadOf` — so every
# effective fetch AND push URL must name --repo on GitHub. A URL that is not a
# GitHub repository URL has no identity and is refused, unless the caller
# explicitly exports AGENT_CLAIM_SWEEP_TRUSTED_REMOTE='<exact-url>=<owner/repo>'
# (a test-only escape: git config can never set it). URLs are compared, never
# printed — they may carry credentials; only slugs are.
url_slug() {
  local url="${1%/}"
  url="${url%.git}"
  if [[ "$url" =~ ^(https://github\.com/|ssh://git@github\.com/|git@github\.com:)([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    printf '%s/%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ -n "${AGENT_CLAIM_SWEEP_TRUSTED_REMOTE:-}" && "$1" == "${AGENT_CLAIM_SWEEP_TRUSTED_REMOTE%=*}" ]]; then
    printf '%s\n' "${AGENT_CLAIM_SWEEP_TRUSTED_REMOTE##*=}"
  fi
}
if ! fetch_urls="$(git -C "$REPO_DIR" remote get-url --all "$REMOTE" 2>/dev/null)" ||
  ! push_urls="$(git -C "$REPO_DIR" remote get-url --push --all "$REMOTE" 2>/dev/null)" ||
  [[ -z "$fetch_urls" || -z "$push_urls" ]]; then
  die "UNKNOWN — could not resolve the effective URLs of remote '$REMOTE' in '$REPO_DIR'"
fi
while IFS= read -r url; do
  slug="$(url_slug "$url")"
  [[ -n "$slug" ]] ||
    die "UNKNOWN — an effective URL of remote '$REMOTE' is not a GitHub repository URL; refusing to judge claims whose repository cannot be identified"
  shopt -s nocasematch
  [[ "$slug" == "$REPO" ]] || {
    shopt -u nocasematch
    die "--repo $REPO does not match an effective URL of remote '$REMOTE' ($slug); refusing to judge one repository's claims by another's issues"
  }
  shopt -u nocasematch
done <<<"$fetch_urls"$'\n'"$push_urls"

# Capture the listing and check its status: an empty listing from a failed read
# must never look like "no tips".
if ! listing="$(git -C "$REPO_DIR" ls-remote "$REMOTE" 'refs/heads/agent-claim/*')"; then
  die "UNKNOWN — could not list agent-claim tips on '$REMOTE'"
fi

kept=0 removed=0 unknown=0 raced=0 failed=0
while IFS=$'\t' read -r sha ref; do
  [[ -n "$sha" ]] || continue
  n="${ref#refs/heads/agent-claim/}"
  if ! [[ "$n" =~ ^[1-9][0-9]*$ && "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "UNKNOWN $ref unrecognised claim ref"
    unknown=$((unknown + 1))
    continue
  fi
  if ! state="$(gh api "repos/$REPO/issues/$n" --jq '.state' 2>/dev/null)"; then
    echo "UNKNOWN $n issue read failed"
    unknown=$((unknown + 1))
    continue
  fi
  case "$state" in
    open)
      echo "KEEP $n open"
      kept=$((kept + 1))
      ;;
    closed)
      if ((APPLY == 0)); then
        echo "WOULD-REMOVE $n closed $sha"
        removed=$((removed + 1))
      else
        # agent-claim.sh retire: 1 = LOST (the tip moved), 2 = the query, push or
        # confirmation failed. Its diagnostics stay on stderr.
        retire_rc=0
        "$claim_tool" retire "$n" "$sha" --repo-dir "$REPO_DIR" --remote "$REMOTE" >/dev/null || retire_rc=$?
        case "$retire_rc" in
          0) echo "REMOVE $n closed $sha"; removed=$((removed + 1)) ;;
          1) echo "RACED $n $sha"; raced=$((raced + 1)) ;;
          *) echo "FAILED $n $sha"; failed=$((failed + 1)) ;;
        esac
      fi
      ;;
    *)
      echo "UNKNOWN $n unexpected issue state '$state'"
      unknown=$((unknown + 1))
      ;;
  esac
done <<<"$listing"

mode=dry-run
((APPLY == 1)) && mode=apply
echo "agent-claim-sweep: repo=$REPO mode=$mode kept=$kept removed=$removed raced=$raced failed=$failed unknown=$unknown"
((unknown > 0)) && exit 2
((raced + failed > 0)) && exit 1
exit 0
