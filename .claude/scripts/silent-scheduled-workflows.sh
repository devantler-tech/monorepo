#!/usr/bin/env bash
#
# silent-scheduled-workflows.sh — report scheduled workflows that have stopped running
# (monorepo#2928).
#
# The survey judges default-branch health only from runs attached to the current head, so a
# workflow that never runs is invisible to it. For a dispatch-only workflow that is correct: its
# silence is a decision. For a workflow with a `schedule:` trigger it is not — GitHub disables
# schedules on inactive repositories, and a schedule that stops firing reports nothing anywhere.
#
# So this reads each active workflow's DECLARED triggers at the default branch and judges silence
# only for workflows whose `on:` includes `schedule`. The workflow `state` field alone never
# decides: a `disabled_manually` workflow is a recorded decision and is skipped, while
# `disabled_inactivity` is exactly the silent stop this exists to catch.
#
# A schedule is SILENT when its newest `schedule`-event run is older than twice its longest cron
# interval plus a grace hour — or it has never run and the workflow is older than that.
#
# Usage:
#   silent-scheduled-workflows.sh --repo <owner/repo> [--repo …] [--now <epoch>]
#
# Output, one line per finding:
#   SILENT-WORKFLOW <owner/repo> <path> — <reason>
#   QUERY-UNKNOWN <owner/repo> [<path>] — <what failed>
#   CHECKED <n> scheduled workflow(s) across <m> repositor(ies)   (always last, so a clean exit shows what it examined)
#
# Exit codes:
#   0  every scheduled workflow ran within its window
#   1  at least one SILENT-WORKFLOW
#   2  UNKNOWN: a read failed (never read as clean), or usage error

set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

repos=()
now="$(date -u +%s)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; repos+=("$2"); shift 2 ;;
    --now) [ "$#" -ge 2 ] || usage; now="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ "${#repos[@]}" -gt 0 ] || usage
[[ "$now" =~ ^[0-9]+$ ]] || usage

hour=3600
day=$((24 * hour))

# Longest gap, in whole days, between two firing DAYS of one 5-field cron expression, measured by
# evaluating the day-of-month, month and day-of-week fields (lists, ranges, steps, names, and cron's
# rule that a restricted day-of-month and day-of-week are ALTERNATIVES) on every day of an 8-year span
# from 2024-01-01, so leap years are covered. Prints 0 when the expression never fires in that span
# or cannot be parsed. Computing the gap replaced a field-literal estimate after review kept finding
# spellings it misjudged (`1-12` for every month, `29 2 1` for February Mondays, `1,29 2`).
# shellcheck disable=SC2016 # a jq program: its `$` are jq variables
cron_gap_jq='
def names($n): if $n == "mon" then {"JAN":1,"FEB":2,"MAR":3,"APR":4,"MAY":5,"JUN":6,"JUL":7,"AUG":8,"SEP":9,"OCT":10,"NOV":11,"DEC":12}
  else {"SUN":0,"MON":1,"TUE":2,"WED":3,"THU":4,"FRI":5,"SAT":6} end;
def num($s; $n): ($s | ascii_upcase) as $u | (names($n)[$u] // ($u | tonumber));
def field($f; $lo; $hi; $n):
  [ $f | split(",")[] | split("/") as $p
    | ($p[1] // "1" | tonumber) as $step
    | (if $p[0] == "*" or $p[0] == "?" then [$lo, $hi]
       elif ($p[0] | test("-")) then ($p[0] | split("-") | map(num(.; $n)))
       elif $p[1] != null then [num($p[0]; $n), $hi]
       else [num($p[0]; $n), num($p[0]; $n)] end) as $r
    | if $step < 1 then error("step") else range($r[0]; $r[1] + 1; $step) end ]
  | map(if $n == "dow" and . == 7 then 0 else . end) | unique;
($c | split(" ") | map(select(. != ""))) as $f
| if ($f | length) != 5 then 0 else
  (try field($f[2]; 1; 31; "dom") catch null) as $dom
  | (try field($f[3]; 1; 12; "mon") catch null) as $mon
  | (try field($f[4]; 0; 6; "dow") catch null) as $dow
  | if $dom == null or $mon == null or $dow == null then 0 else
    ($f[2] != "*" and $f[2] != "?") as $domr | ($f[4] != "*" and $f[4] != "?") as $dowr
    | [ range(0; 8 * 366) as $i | (1704067200 + $i * 86400 | gmtime) as $t
        | select(($mon | index($t[1] + 1)) != null)
        | select(if $domr and $dowr then (($dom | index($t[2])) != null or ($dow | index($t[6])) != null)
                 elif $domr then ($dom | index($t[2])) != null
                 elif $dowr then ($dow | index($t[6])) != null
                 else true end)
        | $i ]
    | if length < 2 then 0 else [range(1; length) as $k | .[$k] - .[$k - 1]] | max end
  end end'
cron_gap_days() { jq -rn --arg c "$1" "$cron_gap_jq"; }

# GitHub returns workflow timestamps with a UTC offset and milliseconds
# (`2024-04-14T02:42:29.000+02:00`) but run timestamps in `Z` form, and BSD and GNU `date` parse
# neither the same way. Convert in jq, where both shapes are handled identically, and check every
# result is an integer before comparing it — a failed conversion must never read as "recent".
jq_epoch='def epoch: (.[0:19] + "Z" | fromdate) - ((capture("(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$") // {s: "+", h: "0", m: "0"}) | ((.h | tonumber) * 3600 + (.m | tonumber) * 60) * (if .s == "+" then 1 else -1 end));'
is_epoch() { [[ "$1" =~ ^[0-9]+$ ]]; }

# The cron lines a workflow file declares (empty when it has no schedule). `on:` parses as the
# boolean key `true` under YAML 1.1, so read both spellings.
crons_of() {
  yq -r '(.on // .true // {}) | select(tag == "!!map") | .schedule // [] | .[].cron' <<<"$1" 2>/dev/null
}

silent=0
checked=0
repos_read=0
max_pages=5
err="$(mktemp)"
# An abort before the end must never read as a verdict: bash 3.2 reports it as 0 (clean) and bash 5
# as 1 (a finding). So any exit before the end is UNKNOWN; only reaching it may report 0 or 1.
finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  rm -f "$err"
  if [ "$finished" != 1 ]; then
    echo "silent-scheduled-workflows: aborted before finishing; reporting UNKNOWN" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT
unknown=0

for repo in "${repos[@]}"; do
  # A null or missing default_branch reads as the string "null" through a bare filter; require a
  # non-empty string, or every content read 404s and is skipped as though the file were gone.
  if ! branch="$(gh api "repos/${repo}" --jq 'if (.default_branch | type) == "string" and .default_branch != "" then .default_branch else "" end')" || [ -z "$branch" ]; then
    echo "QUERY-UNKNOWN ${repo} — default branch read failed"
    unknown=1
    continue
  fi
  # Each page also emits its `total_count`, so a successful but short or empty listing is caught
  # rather than read as a repository with nothing scheduled.
  if ! listing="$(gh api --paginate "repos/${repo}/actions/workflows?per_page=100" \
    --jq "${jq_epoch} \"TOTAL\t\(.total_count)\", (.workflows[] | if (.id | type) == \"number\" and (.state | type) == \"string\" and (.path | type) == \"string\" and (.path | test(\"^[^\\t\\n]+$\")) and (.created_at | type) == \"string\" then [.id, .state, .path, (.created_at | epoch)] | @tsv else \"BAD\" end)")"; then
    echo "QUERY-UNKNOWN ${repo} — workflow list read failed"
    unknown=1
    continue
  fi
  total="$(awk -F'\t' '$1 == "TOTAL" { print $2; exit }' <<<"$listing")"
  workflows="$(grep -v $'^TOTAL\t' <<<"$listing" || true)"
  listed="$(grep -c . <<<"$workflows" || true)"
  if ! is_epoch "${total:-x}" || [ "$listed" -ne "$total" ]; then
    echo "QUERY-UNKNOWN ${repo} — workflow list incomplete (${listed} of ${total:-unknown})"
    unknown=1
    continue
  fi
  # A record missing a required field would shift the TSV columns and be skipped by the path
  # guard below, so any malformed record makes the whole listing UNKNOWN.
  if grep -qx 'BAD' <<<"$workflows"; then
    echo "QUERY-UNKNOWN ${repo} — workflow list holds a malformed record"
    unknown=1
    continue
  fi
  repos_read=$((repos_read + 1))
  while IFS=$'\t' read -r id state path created; do
    [ -n "$id" ] || continue
    case "$path" in .github/workflows/*) ;; *) continue ;; esac # dynamic / GitHub-managed
    case "$state" in disabled_manually | disabled_fork) continue ;; esac # a recorded decision

    # A workflow can stay listed `active` after its file left the default branch (it ran on some
    # other ref). Only a file ON the default branch can fire a schedule, so a 404 is a skip — but
    # only a 404; any other failure is UNKNOWN. The path and branch come from the API and may hold
    # URL metacharacters: each path segment is percent-encoded and the branch travels as an encoded
    # GET field. The raw media type returns the file itself, so no base64 decoder (whose flags
    # differ between BSD and GNU) is involved.
    encoded_path="$(jq -rn --arg p "$path" '$p | split("/") | map(@uri) | join("/")')"
    if ! content="$(gh api --method GET -H 'Accept: application/vnd.github.raw' \
      "repos/${repo}/contents/${encoded_path}" -f ref="${branch}" 2>"$err")"; then
      grep -q 'HTTP 404' "$err" && continue
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow file read failed"
      unknown=1
      continue
    fi
    if [ -z "$content" ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow file empty"
      unknown=1
      continue
    fi
    if ! crons="$(crons_of "$content")"; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow triggers unparseable"
      unknown=1
      continue
    fi
    [ -n "$crons" ] || continue # no schedule: silence is not evidence

    # Several cron lines fire on the union of their days, whose longest gap is at most the SHORTEST
    # single-line gap, so that bound is safe. A line that never fires, or cannot be parsed, is UNKNOWN.
    gap_days=0
    bad_cron=""
    while IFS= read -r cron; do
      g="$(cron_gap_days "$cron")" || g=0
      if ! is_epoch "$g" || [ "$g" -eq 0 ]; then
        bad_cron="$cron"
        break
      fi
      if [ "$gap_days" -eq 0 ] || [ "$g" -lt "$gap_days" ]; then gap_days="$g"; fi
    done <<<"$crons"
    if [ -n "$bad_cron" ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — cron '${bad_cron}' unparseable or never fires"
      unknown=1
      continue
    fi
    # The extra day covers where in its day the firing falls; the grace hour covers queueing delay.
    window=$(((gap_days + 1) * day))
    limit=$((2 * window + hour))
    checked=$((checked + 1))

    if [ "$state" = "disabled_inactivity" ]; then
      echo "SILENT-WORKFLOW ${repo} ${path} — schedule disabled by GitHub for repository inactivity"
      silent=1
      continue
    fi

    cutoff=$((now - limit))
    # Too new to have missed a firing yet?
    if ! is_epoch "$created"; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow creation time unparseable"
      unknown=1
      continue
    fi
    [ "$created" -gt "$cutoff" ] && continue
    # The creation time is not enough: an old dispatch-only workflow that GAINS a schedule was
    # created long ago, yet its first firing may not be due. And the file's newest commit is not
    # enough either, because unrelated edits (a pin bump every month) would renew that grace
    # forever. So compare the schedule itself: read the file as it stood at the window's start and
    # judge silence only when its crons then equal its crons now. A file with no commit before the
    # window is new, and gets the grace.
    cutoff_iso="$(jq -rn --argjson e "$cutoff" '$e | todate')"
    if ! before_sha="$(gh api --method GET "repos/${repo}/commits" -f path="${path}" -f sha="${branch}" \
      -f until="${cutoff_iso}" -f per_page=1 \
      --jq 'if type != "array" then "BAD" elif length == 0 then "" elif (.[0].sha | type) == "string" and (.[0].sha | test("^[0-9a-f]{7,40}$")) then .[0].sha else "BAD" end')" ||
      [ "$before_sha" = BAD ]; then
      # Only a well-formed empty array means "no commit before the window"; any other shape is
      # a partial payload and must not grant the new-file grace.
      echo "QUERY-UNKNOWN ${repo} ${path} — history at the window start unreadable"
      unknown=1
      continue
    fi
    [ -n "$before_sha" ] || continue
    if ! before="$(gh api --method GET -H 'Accept: application/vnd.github.raw' \
      "repos/${repo}/contents/${encoded_path}" -f ref="${before_sha}" 2>"$err")"; then
      if grep -q 'HTTP 404' "$err"; then continue; fi # the file was elsewhere then: new here
      echo "QUERY-UNKNOWN ${repo} ${path} — file at the window start unreadable"
      unknown=1
      continue
    fi
    if ! before_crons="$(crons_of "$before")"; then
      continue # unparseable then, so the current schedule is newer than the window
    fi
    [ "$before_crons" = "$crons" ] || continue

    # 🔴 Never filter the run list by `event=schedule`: that filtered listing is INCOMPLETE —
    # measured 2026-09-29 on a monthly workflow, it returned 3 runs (newest July) while the
    # unfiltered listing held September's. Read the unfiltered, newest-first listing instead and
    # page back only until a page crosses the window edge.
    found=""
    verdict=""
    for ((page = 1; page <= max_pages; page++)); do
      if ! page_out="$(gh api "repos/${repo}/actions/workflows/${id}/runs?per_page=100&page=${page}" \
        --jq "${jq_epoch} \"TOTAL\t\(.total_count)\", (.workflow_runs[] | [.event, (.created_at | epoch), .created_at] | @tsv)")"; then
        verdict="unknown"
        break
      fi
      run_total="$(awk -F'\t' '$1 == "TOTAL" { print $2; exit }' <<<"$page_out")"
      rows="$(grep -v $'^TOTAL\t' <<<"$page_out" || true)"
      is_epoch "${run_total:-x}" || { verdict="unknown"; break; }
      # Every page must hold exactly the rows its total implies (100, or the remainder on the last
      # page). A short page — empty or not — is a partial payload, so the silence is unproven.
      expected=$((run_total - (page - 1) * 100))
      [ "$expected" -gt 100 ] && expected=100
      [ "$expected" -lt 0 ] && expected=0
      got="$(grep -c . <<<"$rows" || true)"
      if [ "$got" -ne "$expected" ]; then
        verdict="unknown"
        break
      fi
      if [ -z "$rows" ]; then
        verdict="edge"
        break
      fi
      oldest=""
      while IFS=$'\t' read -r event at stamp; do
        is_epoch "$at" || { verdict="unknown"; break; }
        oldest="$at"
        if [ "$event" = "schedule" ] && [ "$at" -ge "$cutoff" ]; then
          found="$stamp"
          break
        fi
      done <<<"$rows"
      [ -n "$found" ] && break
      [ "$verdict" = "unknown" ] && break
      [ "$oldest" -lt "$cutoff" ] && { verdict="edge"; break; }
    done
    if [ "$verdict" = "unknown" ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — run list read failed"
      unknown=1
    elif [ -z "$found" ] && [ "$verdict" != "edge" ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — window not reached within ${max_pages} pages of runs"
      unknown=1
    elif [ -z "$found" ]; then
      echo "SILENT-WORKFLOW ${repo} ${path} — no scheduled run in the last $((limit / hour))h (its cron fires at least every ${gap_days}d)"
      silent=1
    fi
  done <<<"$workflows"
done

echo "CHECKED ${checked} scheduled workflow(s) across ${repos_read} repositor(ies)"
finished=1
[ "$unknown" -eq 0 ] || exit 2
[ "$silent" -eq 0 ] || exit 1
exit 0
