#!/usr/bin/env bash
# cursor-issue-board-sweep.sh — put every open Cursor-authored issue on the 🌊 Project Board.
#
# WHY THIS EXISTS
#   The Cursor cloud instance gets 403 on Projects, so every issue it files is necessarily
#   unboarded and a local run has to board it. That duty lived only as a paragraph in AGENTS.md,
#   and a distant paragraph is not reliably reached: the status-less card count regressed
#   0 -> 4 -> 0 -> 16 across ticks while the repair was already scripted and idempotent
#   (monorepo#2402). This is that duty as one executable step, so the run loop invokes it
#   instead of re-deriving it.
#
# WHAT IT DOES
#   Discovers open issues authored by the Cursor identity across the org, oldest first, then
#   passes EVERY result through `board-add.sh` — the idempotent helper that does both halves of
#   the add and verifies the Status by reading it back. No hand-written item-add/item-edit
#   sequence: a half-completed add is indistinguishable from a finished one, which is the defect
#   that helper exists to close.
#
#   `--limit` is pinned because `gh search` defaults to 30: a lane with more open issues than
#   that would have the remainder silently never boarded. Ordering is pinned to created-ascending
#   so the sweep is deterministic rather than dependent on relevance ranking. The author is
#   matched EXACTLY -- a free-text search for a marker string returns unrelated issues that merely
#   mention it.
#
# FAIL-CLOSED
#   A failed discovery is never treated as "no issues": an empty result is only believed when the
#   search command itself succeeded. A `board-add.sh` failure on one issue does not abort the
#   sweep -- the remaining issues are still boarded -- but the script exits non-zero so the
#   failure is visible rather than absorbed. A private repository's issue is a maintainer
#   decision, and `board-add.sh` refuses it; that refusal is reported as SKIPPED and does not
#   fail the sweep.
#
# USAGE
#   cursor-issue-board-sweep.sh [--author <login>] [--owner <org>] [--limit <n>]
#                               [--board-add <path>] [--dry-run]
#   exit 0  every discovered issue is on the board (or there were none)
#   exit 1  usage error
#   exit 2  discovery failed, or at least one issue could not be boarded
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

author="app/cursor"
owner="devantler-tech"
limit=300
board_add="${here}/board-add.sh"
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --author)     author="${2:?--author needs a value}"; shift 2 ;;
    --owner)      owner="${2:?--owner needs a value}"; shift 2 ;;
    --limit)      limit="${2:?--limit needs a value}"; shift 2 ;;
    --board-add)  board_add="${2:?--board-add needs a value}"; shift 2 ;;
    --dry-run)    dry_run=1; shift ;;
    -h|--help)    sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "cursor-issue-board-sweep: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$limit" in ''|*[!0-9]*) echo "cursor-issue-board-sweep: --limit must be a number: $limit" >&2; exit 1 ;; esac
[ "$dry_run" -eq 1 ] || [ -x "$board_add" ] ||
  { echo "cursor-issue-board-sweep: board-add helper is not executable: $board_add" >&2; exit 1; }

# Discovery. Captured rather than piped so a FAILED search cannot read as an empty one:
# `gh ... | while read` would report the loop's status and sweep zero issues on an auth error.
if ! found="$(gh search issues --owner "$owner" --state open --author "$author" \
                --limit "$limit" --sort created --order asc --json url --jq '.[].url' 2>&1)"; then
  echo "cursor-issue-board-sweep: discovery FAILED (nothing swept) — ${found}" >&2
  exit 2
fi

# `--jq` on an empty result set prints nothing, so an empty string here means zero issues from a
# search that SUCCEEDED. That is the only path on which an empty sweep is believed.
total=0
boarded=0
skipped=0
failed=0

while IFS= read -r url; do
  [ -n "$url" ] || continue
  total=$((total + 1))
  if [ "$dry_run" -eq 1 ]; then
    echo "cursor-issue-board-sweep: DRY-RUN would board ${url}"
    boarded=$((boarded + 1))
    continue
  fi
  if out="$("$board_add" "$url" 2>&1)"; then
    boarded=$((boarded + 1))
    echo "cursor-issue-board-sweep: boarded ${url}"
  elif printf '%s' "$out" | grep -q 'is PRIVATE; project 5 is public'; then
    skipped=$((skipped + 1))
    echo "cursor-issue-board-sweep: SKIPPED (private repository, a maintainer decision) ${url}"
  else
    failed=$((failed + 1))
    echo "cursor-issue-board-sweep: FAILED ${url} — ${out}" >&2
  fi
# Process substitution, NOT a pipe: `printf ... | while` runs the loop in a SUBSHELL, so every
# counter incremented above would be discarded and the summary would always read zeros. It is also
# not a heredoc, whose unquoted body would expand a `$` arriving inside a URL.
done < <(printf '%s\n' "$found")

echo "cursor-issue-board-sweep: discovered=${total} boarded=${boarded} skipped=${skipped} failed=${failed} author=${author} owner=${owner} limit=${limit}"
[ "$failed" -eq 0 ] || exit 2
exit 0
