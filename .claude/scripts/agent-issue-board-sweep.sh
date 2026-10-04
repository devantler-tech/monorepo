#!/usr/bin/env bash
# agent-issue-board-sweep.sh — put an explicit author's open issues on the 🌊 Project Board.
#
# WHY THIS EXISTS
#   An engineering runtime may be able to file issues without access to Projects. An authorised
#   runtime can reconcile those issues onto the board through this executable step, instead of
#   re-deriving the idempotent add and Status repair. The caller must choose the exact author;
#   neither the active runtime nor a built-in provider identity determines the discovery scope.
#
# WHAT IT DOES
#   Discovers open issues authored by the explicitly supplied identity across the org, oldest first,
#   reads which of them are already on the board, and passes EVERY other result through
#   `board-add.sh` — the idempotent helper that does both halves of the add and verifies the Status
#   by reading it back. No hand-written item-add/item-edit sequence: a half-completed add is
#   indistinguishable from a finished one, which is the defect that helper exists to close.
#
#   BULK MEMBERSHIP (monorepo#3340). Asking board-add.sh about every issue costs three remote reads
#   each: measured 2026-10-04 on 20 boarded issues, 60 calls in 30 s. At that rate the 583 open
#   issues take about 14.5 minutes and 1,750 calls for a pass that changes nothing, against a
#   120-second call budget. So membership is read from the issue's own side for up to 100 issues per
#   request (one GraphQL point each, about a second), and an issue is reported `already on the
#   board` without a helper call only when that read PROVES it: the node answers for that exact
#   issue, its repository is public, and it holds an item on THIS board (matched by id, never by
#   number) with a Status. Every other answer — absent, no Status, a private repository, an item
#   beyond the first page, a null node, a failed or short read — proves nothing, and the issue
#   goes through board-add.sh exactly as before. The bulk read can only ever skip a no-op.
#
#   DEADLINE AND CHECKPOINT. Per-issue work stops at --deadline-seconds: issues not yet examined are
#   counted `deferred`, the summary names the first of them as `checkpoint=<url>`, and
#   `--resume-from <url>` starts the next call's per-issue work there. An INT or TERM delivered to
#   the sweep does the same once the call in flight returns, and exits 2. Issues the bulk read
#   verified cost nothing, so they are counted whatever the clock says.
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
#   agent-issue-board-sweep.sh --author <login> [--owner <org>] [--limit <n>]
#                               [--pace-seconds <n>] [--max-mutations <n>]
#                               [--deadline-seconds <n>] [--resume-from <issue-url>]
#                               [--board-add <path>] [--dry-run]
#   --dry-run is the read-only path: discovery and the bulk membership read, no helper call.
#   The summary line counts discovered = verified + boarded + skipped + failed + deferred.
#   exit 0  bounded batch succeeded; inspect deferred and skipped for remaining issues
#   exit 1  usage error
#   exit 2  discovery failed or was truncated at the cap, an issue could not be boarded, the
#           checkpoint is no longer discovered, or the run was interrupted
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The board the bulk read matches on. board-add.sh writes to the same one, and the self-test
# compares the two files so they cannot drift apart.
readonly PROJECT_NUMBER=5
readonly PROJECT_OWNER="devantler-tech"
# nodes(ids:) accepts at most 100 ids.
readonly BULK_SIZE=100

author=""
owner="devantler-tech"
limit=300
board_add="${here}/board-add.sh"
dry_run=0
resume_from=""
# PACING AND BATCH SIZE. Three limits bind, and the batch is sized by the tightest of them. Each
# board-add performs an item-add AND an item-edit, so one WRITE costs TWO requests.
#
#   per-minute  ~80 content-generating requests: 2 requests / 2 s = 60 a minute, with margin.
#   per-hour    ~500, and that budget is SHARED — both machine-local lanes run this sweep every
#               hour, so the ceiling is per-hour-per-fleet, not per-process. 2 lanes x 25 writes
#               x 2 requests = 100 an hour, leaving the rest for everything else the runs do.
#   per-call    the runtime's Bash timeout defaults to 120 s. At a 2 s pace a batch of 25 spends
#               48 s sleeping before any API latency, which fits; a batch of 150 would have spent
#               298 s and been killed mid-run, losing the summary and the exit status while
#               leaving the writes it had already made applied.
#
# A backfill larger than the batch is not an error and needs no human: board-add.sh is idempotent
# and discovery is oldest-first, so the next scheduled run continues where this one stopped. A
# large catch-up therefore drains over several runs rather than in one oversized call.
pace=2
max_mutations=25
# DEADLINE. The batch bounds writes, not time: a write is seven remote calls, so a full batch can
# outlast the call budget on its own, and so can any pass whose bulk read did not hold. Stopping
# per-issue work here leaves room for the call in flight and the summary inside 120 s.
deadline=90

while [ $# -gt 0 ]; do
  case "$1" in
    --author)
      [ $# -ge 2 ] || { echo "agent-issue-board-sweep: --author needs a value" >&2; exit 1; }
      author="$2"; shift 2 ;;
    --owner)      owner="${2:?--owner needs a value}"; shift 2 ;;
    --limit)      limit="${2:?--limit needs a value}"; shift 2 ;;
    --board-add)  board_add="${2:?--board-add needs a value}"; shift 2 ;;
    --pace-seconds) pace="${2:?--pace-seconds needs a value}"; shift 2 ;;
    --max-mutations) max_mutations="${2:?--max-mutations needs a value}"; shift 2 ;;
    --deadline-seconds) deadline="${2:?--deadline-seconds needs a value}"; shift 2 ;;
    --resume-from) resume_from="${2:?--resume-from needs a value}"; shift 2 ;;
    --dry-run)    dry_run=1; shift ;;
    -h|--help)    sed -n '2,/^set -Eeuo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    *) echo "agent-issue-board-sweep: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Validate author before discovery or helper invocation: no implicit identity may select issues.
case "$author" in
  '') echo "agent-issue-board-sweep: --author is required" >&2; exit 1 ;;
  -*|*[[:space:]]*) echo "agent-issue-board-sweep: --author must be an exact login without whitespace or a leading hyphen" >&2; exit 1 ;;
esac

# Match the bounded decimal spelling before arithmetic or gh argument parsing. This also rejects
# ambiguous leading zeros and oversized integers without depending on the shell's integer width.
case "$limit" in
  [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|1000) ;;
  *) echo "agent-issue-board-sweep: --limit must be a decimal integer from 1 to 1000 without leading zeros" >&2; exit 1 ;;
esac
case "$pace" in ''|*[!0-9]*) echo "agent-issue-board-sweep: --pace-seconds must be a whole number of seconds: $pace" >&2; exit 1 ;; esac
case "$max_mutations" in ''|*[!0-9]*) echo "agent-issue-board-sweep: --max-mutations must be a number: $max_mutations" >&2; exit 1 ;; esac
[ "$max_mutations" -gt 0 ] || { echo "agent-issue-board-sweep: --max-mutations must be greater than zero" >&2; exit 1; }
# Bounded like --limit: a value the shell cannot compare would switch the deadline off silently.
case "$deadline" in
  [0-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) ;;
  *) echo "agent-issue-board-sweep: --deadline-seconds must be a whole number of seconds from 0 to 9999 without leading zeros" >&2; exit 1 ;;
esac
case "$resume_from" in
  ''|https://github.com/*/*/issues/*) ;;
  *) echo "agent-issue-board-sweep: --resume-from must be an issue URL printed as checkpoint= by an earlier run" >&2; exit 1 ;;
esac
[ "$dry_run" -eq 1 ] || [ -x "$board_add" ] ||
  { echo "agent-issue-board-sweep: board-add helper is not executable: $board_add" >&2; exit 1; }

# The clock starts before the first remote call: discovery and the bulk read spend the same budget.
SECONDS=0

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
# An interrupt is noted and acted on between issues, so the call in flight finishes and the
# checkpoint and summary are still printed.
interrupted=0
trap 'interrupted=1' INT TERM
# Each row is `<node id><TAB><url>`: the bulk membership read asks by node id.
# shellcheck disable=SC2016 # The jq filter is passed to gh literally.
if ! found="$(gh search issues --owner "$owner" --archived=false --state open --author "$author" \
                --limit "$limit" --sort created --order asc --json id,url \
                --jq '.[] | "\(.id)\t\(.url)"' 2>"$err_file")"; then
  echo "agent-issue-board-sweep: discovery FAILED (nothing swept) — $(tr '\n' ' ' <"$err_file")" >&2
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
  echo "agent-issue-board-sweep: discovery TRUNCATED at the --limit cap (${discovered_count} of at least ${limit}); use a higher --limit up to 1000; saturation at 1000 requires partitioned discovery before this sweep can proceed" >&2
  exit 2
fi

# A row that is not `<node id><TAB><issue url>` is a discovery this script cannot read. Stopping is
# the only safe answer: guessing which half is the URL would hand board-add.sh something else.
bad_rows="$(awk -F'\t' 'NF != 2 || $1 == "" || $2 !~ /^https:\/\/github\.com\/[^\/]+\/[^\/]+\/issues\/[0-9]+$/' <<<"$found")"
if [ "$discovered_count" -gt 0 ] && [ -n "$bad_rows" ]; then
  echo "agent-issue-board-sweep: discovery returned $(grep -c . <<<"$bad_rows") row(s) that are not '<node id><TAB><issue url>' (nothing swept)" >&2
  exit 2
fi

# A checkpoint places the resume point only while discovery still returns that issue. Checked before
# any per-issue work: resuming from a point that cannot be found would examine nothing and say so
# only at the end.
if [ -n "$resume_from" ]; then
  discovered_urls="$(cut -f2 <<<"$found")"
  if ! grep -Fxq -- "$resume_from" <<<"$discovered_urls"; then
    echo "agent-issue-board-sweep: the --resume-from checkpoint is not among the discovered issues (it was closed, moved, or belongs to another author); run again without --resume-from (nothing swept)" >&2
    exit 2
  fi
fi

# BULK MEMBERSHIP. One read per BULK_SIZE issues, from the issue's own side. `verified_urls` holds
# only the issues a read PROVED are on this board with a Status; everything else is left to
# board-add.sh, so a failed, short or surprising read can cost time but never coverage.
verified_urls=""
bulk_note() { echo "agent-issue-board-sweep: $*" >&2; }
if [ "$discovered_count" -gt 0 ]; then
  # GraphQL variables belong to the query, not the shell.
  # shellcheck disable=SC2016
  if project_id="$(gh api graphql -f owner="$PROJECT_OWNER" -F number="$PROJECT_NUMBER" -f query='
      query($owner: String!, $number: Int!) {
        organization(login: $owner) { projectV2(number: $number) { id } }
      }' --jq '.data.organization.projectV2.id // empty' 2>"$err_file")" && [ -n "$project_id" ]; then
    # shellcheck disable=SC2016
    membership_query='query($ids: [ID!]!) {
      nodes(ids: $ids) {
        ... on Issue {
          id
          url
          repository { isPrivate }
          projectItems(first: 20, includeArchived: false) {
            nodes { project { id } fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            } }
          }
        }
      }
    }'
    offset=1
    while [ "$offset" -le "$discovered_count" ]; do
      # An interrupt ends the reads here. The issues not yet read stay unverified, so the loop
      # below stops at the first of them and names it as the checkpoint.
      [ "$interrupted" -eq 0 ] || break
      chunk="$(sed -n "${offset},$((offset + BULK_SIZE - 1))p" <<<"$found")"
      offset=$((offset + BULK_SIZE))
      # The answer is trusted node by node, and by its CONTENT rather than gh's exit status: gh
      # exits non-zero whenever the response carries an `errors` entry, which it does for one
      # unresolvable id beside ninety-nine good nodes (measured 2026-10-04). A node proves
      # membership only when it answers for the issue asked about at that position (same id AND
      # url), its repository is public, and one of its items is on THIS board with a Status. An
      # answer that is not exactly one document as long as the request is not read at all: there
      # is nothing to read, or positions no longer line up.
      page=""
      # shellcheck disable=SC2016
      if body="$(jq -Rn --arg q "$membership_query" '{query: $q, variables: {ids: [inputs | split("\t")[0]]}}' <<<"$chunk")"; then
        page="$(gh api graphql --input - <<<"$body" 2>"$err_file")" || true
      fi
      # shellcheck disable=SC2016
      if proven="$(jq -rs --arg rows "$chunk" --arg project "$project_id" '
          ($rows | split("\n") | map(select(length > 0) | split("\t") | {id: .[0], url: .[1]})) as $asked
          | if length != 1 then error("no answer") else .[0] end
          | if (.data.nodes | type) != "array" or (.data.nodes | length) != ($asked | length)
            then error("the answer does not line up with the request") else . end
          | .data.nodes as $nodes
          | range(0; $asked | length) as $i
          | $nodes[$i] as $node | $asked[$i] as $want
          | select(($node | type) == "object")
          | select($node.id == $want.id and $node.url == $want.url)
          | select($node.repository.isPrivate == false)
          | select(($node.projectItems.nodes | type) == "array")
          | select(any($node.projectItems.nodes[];
              .project.id == $project and ((.fieldValueByName.name // "") | type == "string" and length > 0)))
          | $want.url' <<<"$page" 2>/dev/null)"; then
        [ -z "$proven" ] || verified_urls="${verified_urls}${proven}"$'\n'
      else
        bulk_note "bulk membership read did not hold for $(grep -c . <<<"$chunk") issue(s): none of them counts as verified, each is left to board-add.sh — $(tr '\n' ' ' <"$err_file")"
      fi
    done
  else
    bulk_note "bulk membership read did not hold: the board id could not be resolved, so no issue counts as verified and each is left to board-add.sh — $(tr '\n' ' ' <"$err_file")"
  fi
fi

total=0
verified=0
boarded=0
skipped=0
failed=0
mutated=0
deferred=0
wrote_last=0
stopped=""
checkpoint=""
resume_pending=0
[ -z "$resume_from" ] || resume_pending=1

# say <line> — print one report line. bash 3.2 does not restart a write that a signal interrupts
# (measured once here: `echo: write error: Interrupted system call` in this loop), and under
# `set -e` that failed builtin would end the sweep with no summary. A report line is retried once
# and never decides the run.
say() { echo "$1" || echo "$1" || true; }

while IFS=$'\t' read -r _ url; do
  [ -n "$url" ] || continue
  total=$((total + 1))
  [ "$url" != "$resume_from" ] || resume_pending=0
  # Proven on the board with a Status by the bulk read: nothing to ask and nothing to write, so it
  # costs neither the batch nor the clock.
  case $'\n'"$verified_urls" in
    *$'\n'"$url"$'\n'*)
      verified=$((verified + 1))
      say "agent-issue-board-sweep: already on the board ${url}"
      continue
      ;;
  esac
  if [ "$dry_run" -eq 1 ]; then
    # An interrupt ended the membership reads, so what is left was never read. Reporting it as
    # "would board" would turn unread input into a count behind exit 0; it is the checkpoint.
    if [ "$interrupted" -eq 1 ]; then
      [ -n "$stopped" ] || checkpoint="$url"
      stopped="interrupted"
      deferred=$((deferred + 1))
      continue
    fi
    say "agent-issue-board-sweep: DRY-RUN would board ${url}"
    boarded=$((boarded + 1))
    continue
  fi
  # Before the checkpoint of an earlier run: that run examined it, this one starts further on.
  if [ "$resume_pending" -eq 1 ]; then
    deferred=$((deferred + 1))
    continue
  fi
  # Already stopped by the deadline or an interrupt: nothing more is examined.
  if [ -n "$stopped" ]; then
    deferred=$((deferred + 1))
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
  # DEADLINE OR INTERRUPT. Decided immediately before each helper call, AFTER the pace sleep, so a
  # signal or a deadline that arrives while sleeping is not followed by one more write. Never
  # during a call: the one in flight finishes and its write is counted. This issue is the first
  # one not examined, so it is the checkpoint.
  if [ "$interrupted" -eq 1 ]; then
    stopped="interrupted"
  elif [ "$SECONDS" -ge "$deadline" ]; then
    stopped="deadline"
  fi
  if [ -n "$stopped" ]; then
    checkpoint="$url"
    deferred=$((deferred + 1))
    continue
  fi
  # stdin is closed for the helper: the loop reads its rows from stdin, and a helper that read it
  # would swallow every row after this one.
  if out="$("$board_add" "$url" 2>&1 </dev/null)"; then
    boarded=$((boarded + 1))
    # Match board-add.sh's EXACT no-op marker. A bare `already-present` substring would also match
    # its `already-present (status set)` outcome, which is a real item-edit — and a backlog of
    # status-less cards is precisely what this sweep exists to repair, so that misread would let
    # the one case that matters bypass both the batch and the pacing.
    if grep -q 'already-present (status untouched)' <<<"$out"; then
      say "agent-issue-board-sweep: already on the board ${url}"
    else
      mutated=$((mutated + 1))
      wrote_last=1
      say "agent-issue-board-sweep: boarded ${url}"
    fi
  elif grep -q 'is PRIVATE; project 5 is public' <<<"$out"; then
    skipped=$((skipped + 1))
    say "agent-issue-board-sweep: SKIPPED (private repository, a maintainer decision) ${url}"
  else
    # A failure is charged to the budget and paced, because board-add.sh can fail AFTER a
    # successful item-add or item-edit — a read-back that does not confirm the status still exits
    # non-zero. Treating that as costless would let repeated partial writes bypass both safeguards
    # and keep hammering exactly when GitHub is already refusing.
    failed=$((failed + 1))
    mutated=$((mutated + 1))
    wrote_last=1
    say "agent-issue-board-sweep: FAILED ${url} — ${out}" >&2
  fi
# A here-string, NOT a pipe: `printf ... | while` runs the loop in a SUBSHELL, so every counter
# incremented above would be discarded and the summary would always read zeros. It is also not a
# heredoc, whose unquoted body would expand a `$` arriving inside a URL, and not a process
# substitution: that leaves a child exiting while the loop prints, and its SIGCHLD is one more
# signal that can interrupt a write on bash 3.2.
done <<<"$found"

# CONSERVATION. Every discovered issue was either verified, handed to the helper, or counted as
# deferred. A loop that saw fewer rows than discovery returned has dropped some without a trace.
if [ "$total" -ne "$discovered_count" ] ||
  [ $((verified + boarded + skipped + failed + deferred)) -ne "$total" ]; then
  echo "agent-issue-board-sweep: accounted for ${total} of ${discovered_count} discovered issue(s) (verified=${verified} boarded=${boarded} skipped=${skipped} failed=${failed} deferred=${deferred}); coverage is unknown" >&2
  exit 2
fi

say "agent-issue-board-sweep: discovered=${total} verified=${verified} boarded=${boarded} wrote=${mutated} skipped=${skipped} failed=${failed} deferred=${deferred} author=${author} owner=${owner} limit=${limit} pace=${pace}s batch=${max_mutations} deadline=${deadline}s elapsed=${SECONDS}s${checkpoint:+ checkpoint=${checkpoint}}"
if [ -n "$stopped" ]; then
  # The reason is one of two fixed words; the URL is the script's own discovery row.
  say "agent-issue-board-sweep: stopped (${stopped}) with ${deferred} issue(s) not examined — continue with --resume-from ${checkpoint}"
elif [ "$deferred" -gt 0 ]; then
  say "agent-issue-board-sweep: ${deferred} issue(s) deferred to the next run to stay inside the hourly request budget — board-add is idempotent, so the next sweep continues where this one stopped"
fi
[ "$failed" -eq 0 ] || exit 2
[ "$stopped" != interrupted ] || exit 2
exit 0
