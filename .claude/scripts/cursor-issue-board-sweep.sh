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
#   failure is visible rather than absorbed. A result set sitting exactly AT the --limit cap is
#   treated as truncated and fails closed, because `--limit` bounds what is fetched rather than
#   guaranteeing an exhaustive search, and a silent shortfall would leave issues unboarded behind
#   a clean exit. A private repository's issue is a maintainer
#   decision, and `board-add.sh` refuses it; that refusal is reported as SKIPPED and does not
#   fail the sweep.
#
# USAGE
#   cursor-issue-board-sweep.sh [--author <login>] [--owner <org>] [--limit <n>]
#                               [--pace-seconds <n>] [--max-mutations <n>]
#                               [--board-add <path>] [--dry-run]
#   exit 0  every discovered issue is on the board (or there were none)
#   exit 1  usage error
#   exit 2  discovery failed or was truncated at the cap, or an issue could not be boarded
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

author="app/cursor"
owner="devantler-tech"
limit=300
board_add="${here}/board-add.sh"
dry_run=0
# PACING AND BATCH SIZE, both derived from the documented secondary limits: roughly 80
# content-generating requests per MINUTE and 500 per HOUR, shared with everything else the agent
# writes. Each board-add performs an item-add AND an item-edit, so one issue costs TWO requests.
#
#   per-minute: 2 requests / 2 s  = 60 per minute, under the ~80 ceiling with margin.
#   per-hour:   150 issues x 2    = 300 requests, leaving room in the ~500 hourly budget for the
#               rest of the run rather than consuming it all here.
#
# A backfill larger than the batch is not an error and needs no human: the helper is idempotent
# and the next scheduled run continues where this one stopped, so the sweep reports the remainder
# and exits 0 rather than hammering past a limit it would then keep failing against.
pace=2
max_mutations=150

while [ $# -gt 0 ]; do
  case "$1" in
    --author)     author="${2:?--author needs a value}"; shift 2 ;;
    --owner)      owner="${2:?--owner needs a value}"; shift 2 ;;
    --limit)      limit="${2:?--limit needs a value}"; shift 2 ;;
    --board-add)  board_add="${2:?--board-add needs a value}"; shift 2 ;;
    --pace-seconds) pace="${2:?--pace-seconds needs a value}"; shift 2 ;;
    --max-mutations) max_mutations="${2:?--max-mutations needs a value}"; shift 2 ;;
    --dry-run)    dry_run=1; shift ;;
    -h|--help)    sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "cursor-issue-board-sweep: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$limit" in ''|*[!0-9]*) echo "cursor-issue-board-sweep: --limit must be a number: $limit" >&2; exit 1 ;; esac
case "$pace" in ''|*[!0-9]*) echo "cursor-issue-board-sweep: --pace-seconds must be a whole number of seconds: $pace" >&2; exit 1 ;; esac
case "$max_mutations" in ''|*[!0-9]*) echo "cursor-issue-board-sweep: --max-mutations must be a number: $max_mutations" >&2; exit 1 ;; esac
[ "$max_mutations" -gt 0 ] || { echo "cursor-issue-board-sweep: --max-mutations must be greater than zero" >&2; exit 1; }
[ "$dry_run" -eq 1 ] || [ -x "$board_add" ] ||
  { echo "cursor-issue-board-sweep: board-add helper is not executable: $board_add" >&2; exit 1; }

# Discovery. Captured rather than piped so a FAILED search cannot read as an empty one:
# `gh ... | while read` would report the loop's status and sweep zero issues on an auth error.
#
# stderr goes to its OWN file, never folded in with `2>&1`: the CLI prints an upgrade notice on
# stderr roughly once a day, and merging that into the newline-delimited URL list would hand a
# banner line to board-add.sh as if it were an issue.
#
# `--archived=false` because the search otherwise covers every repository in the owner, including
# archived ones. Archived repositories are read-only history and outside the active portfolio, so a
# stale issue in one must never be added to the live board.
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT
if ! found="$(gh search issues --owner "$owner" --archived=false --state open --author "$author" \
                --limit "$limit" --sort created --order asc --json url --jq '.[].url' 2>"$err_file")"; then
  echo "cursor-issue-board-sweep: discovery FAILED (nothing swept) — $(tr '\n' ' ' <"$err_file")" >&2
  exit 2
fi

# `--jq` on an empty result set prints nothing, so an empty string here means zero issues from a
# search that SUCCEEDED. That is the only path on which an empty sweep is believed.
discovered_count=0
[ -z "$found" ] || discovered_count="$(printf '%s\n' "$found" | grep -c .)"

# SATURATION. `--limit` is a CAP on results fetched, not a page size that guarantees an exhaustive
# search, so a result set exactly at the cap means the lane may hold more issues that were never
# returned. Reporting success there would leave them unboarded behind a clean exit, so fail closed
# and say what to do.
if [ "$discovered_count" -ge "$limit" ]; then
  echo "cursor-issue-board-sweep: discovery TRUNCATED at the --limit cap (${discovered_count} of at least ${limit}); re-run with a higher --limit — some issues would stay unboarded behind a success" >&2
  exit 2
fi

total=0
boarded=0
skipped=0
failed=0
mutated=0
deferred=0
wrote_last=0

while IFS= read -r url; do
  [ -n "$url" ] || continue
  total=$((total + 1))
  if [ "$dry_run" -eq 1 ]; then
    echo "cursor-issue-board-sweep: DRY-RUN would board ${url}"
    boarded=$((boarded + 1))
    continue
  fi
  # BOUNDED BATCH, counted in actual WRITES rather than issues examined. An issue already on the
  # board costs board-add.sh a read and no mutation, so charging it to the budget would spend the
  # whole batch on the oldest already-boarded issues — and because discovery is oldest-first and
  # returns the same prefix every run, the later issues would then be deferred FOREVER rather than
  # picked up next time. Counting writes is what makes "the next run continues" actually true.
  if [ "$mutated" -ge "$max_mutations" ]; then
    deferred=$((deferred + 1))
    continue
  fi
  # Pace only after a call that actually wrote: a no-op costs no mutation, so it needs no
  # throttling. Sleeping before a call whose predecessor wrote guarantees at least `pace` seconds
  # between any two writes. This is deliberate throttling, not a wait for remote state to change.
  [ "$wrote_last" -eq 0 ] || [ "$pace" -eq 0 ] || sleep "$pace"
  wrote_last=0
  if out="$("$board_add" "$url" 2>&1)"; then
    boarded=$((boarded + 1))
    # `already-present (status untouched)` is board-add.sh's own no-op marker.
    if printf '%s' "$out" | grep -q 'already-present'; then
      echo "cursor-issue-board-sweep: already on the board ${url}"
    else
      mutated=$((mutated + 1))
      wrote_last=1
      echo "cursor-issue-board-sweep: boarded ${url}"
    fi
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

echo "cursor-issue-board-sweep: discovered=${total} boarded=${boarded} wrote=${mutated} skipped=${skipped} failed=${failed} deferred=${deferred} author=${author} owner=${owner} limit=${limit} pace=${pace}s batch=${max_mutations}"
if [ "$deferred" -gt 0 ]; then
  echo "cursor-issue-board-sweep: ${deferred} issue(s) deferred to the next run to stay inside the hourly request budget — board-add is idempotent, so the next sweep continues where this one stopped"
fi
[ "$failed" -eq 0 ] || exit 2
exit 0
