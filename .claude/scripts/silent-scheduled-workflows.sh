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
# A schedule is SILENT when it has had no `schedule`-event run for twice its longest gap between
# firing DAYS plus one day, plus a grace hour. The granularity is deliberately a day: the sweep runs
# about daily, so a sub-daily schedule (`*/5 * * * *`) is still reported within a few days, and a
# coarser bound can only delay a report, never invent one.
#
# Every content and history read for one repository is pinned to ONE commit: the default branch's
# head, resolved once (monorepo#3672). A branch that moves mid-scan would otherwise let the directory,
# the file and its history describe different commits. Run history cannot be pinned, so before a
# silence is reported the head is resolved again; if it moved, the repository is judged once more at
# the new head, because the schedule may have changed or gone in between.
#
# A schedule is judged on its run history only when it has run CONTINUOUSLY since the window began:
# the file held the same crons at the window start and at every commit that touched it inside the
# window (monorepo#3671). A schedule that was added, changed, or removed and re-added inside the
# window is not yet due, so it is skipped rather than judged on runs from before it began.
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

# Installed first, before ANY work (argument parsing, `date`, `mktemp`): an abort before the end
# must never read as a verdict: bash 3.2 reports it as 0 (clean) and bash 5
# as 1 (a finding). So any exit before the end is UNKNOWN; only reaching it may report 0 or 1.
finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  rm -f "${err:-}" "${buf:-}"
  if [ "$finished" != 1 ]; then
    echo "silent-scheduled-workflows: aborted before finishing; reporting UNKNOWN" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT

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
def parsed($c):
  ($c | split(" ") | map(select(. != ""))) as $f
  | if ($f | length) != 5 then null else
    { dom: (try field($f[2]; 1; 31; "dom") catch null),
      mon: (try field($f[3]; 1; 12; "mon") catch null),
      dow: (try field($f[4]; 0; 6; "dow") catch null),
      domr: (($f[2] | startswith("*") | not) and $f[2] != "?"), dowr: (($f[4] | startswith("*") | not) and $f[4] != "?") }
    | if .dom == null or .mon == null or .dow == null then null else . end end;
def hit($p; $t):
  ($p.mon | index($t[1] + 1)) != null
  and (if $p.domr and $p.dowr then (($p.dom | index($t[2])) != null or ($p.dow | index($t[6])) != null)
       elif $p.domr then ($p.dom | index($t[2])) != null
       elif $p.dowr then ($p.dow | index($t[6])) != null
       else true end);
# Several cron lines fire on the UNION of their days (Jan 1 + Jul 1 is every six months, though each
# line alone is annual), so the gap is measured on the union.
[$c | split("\n")[] | select(length > 0) | parsed(.)] as $ps
| if ($ps | length) == 0 or any($ps[]; . == null) then 0 else
  [ range(0; 8 * 366) as $i | (1704067200 + $i * 86400 | gmtime) as $t
    | select(any($ps[]; hit(.; $t))) | $i ]
  | if length < 2 then 0 else [range(1; length) as $k | .[$k] - .[$k - 1]] | max end
  end'
cron_gap_days() { jq -rn --arg c "$1" "$cron_gap_jq"; } # $1: the cron lines, one per line

# GitHub returns workflow timestamps with a UTC offset and milliseconds
# (`2024-04-14T02:42:29.000+02:00`) but run timestamps in `Z` form, and BSD and GNU `date` parse
# neither the same way. Convert in jq, where both shapes are handled identically, and check every
# result is an integer before comparing it — a failed conversion must never read as "recent".
# shellcheck disable=SC2016 # a jq program: its `$` are jq variables
jq_epoch='def epoch: if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$") then . else error("timestamp") end | ((.[0:19] + "Z" | fromdate) as $u | if ($u | todate)[0:19] == .[0:19] then $u else error("calendar") end) - ((capture("(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$") // {s: "+", h: "0", m: "0"}) | ((.h | tonumber) * 3600 + (.m | tonumber) * 60) * (if .s == "+" then 1 else -1 end));'
is_epoch() { [[ "$1" =~ ^[0-9]+$ ]]; }

# The cron lines a workflow file declares (empty when it has no schedule). `on:` parses as the
# boolean key `true` under YAML 1.1, so read both spellings.
crons_of() {
  yq -r '(.on // .true // {}) | select(tag == "!!map") | .schedule // [] | .[].cron' <<<"$1" 2>/dev/null
}

# One page of a workflow's runs, newest first, as `event<TAB>epoch<TAB>created_at` rows. Every read
# of run history goes through here, so every one is validated the same way: the page must hold
# exactly the rows its `total_count` implies for its offset (100, or the remainder on the last page),
# and every record must carry a lowercase string event and a parseable time. Anything else — a
# failed read, a short page, a malformed record — returns 1, which callers treat as UNKNOWN.
read_run_page() { # <repo> <workflow id> <page>
  local out total rows expected got
  out="$(gh api "repos/$1/actions/workflows/$2/runs?per_page=100&page=$3" \
    --jq "${jq_epoch} if (.total_count | type) == \"number\" and (.total_count | floor) == .total_count and (.workflow_runs | type) == \"array\" then (\"TOTAL\t\(.total_count)\", (.workflow_runs[] | if (.event | type) == \"string\" and (.event | test(\"^[a-z_]+$\")) and (.created_at | type) == \"string\" then [.event, (.created_at | epoch), .created_at] | @tsv else \"BAD\" end)) else \"BAD\" end")" ||
    return 1
  total="$(awk -F'\t' '$1 == "TOTAL" { print $2; exit }' <<<"$out")"
  is_epoch "${total:-x}" || return 1
  rows="$(grep -v $'^TOTAL\t' <<<"$out" || true)"
  expected=$((total - ($3 - 1) * 100))
  [ "$expected" -gt 100 ] && expected=100
  [ "$expected" -lt 0 ] && expected=0
  got="$(grep -c . <<<"$rows" || true)"
  [ "$got" -eq "$expected" ] || return 1
  if [ -n "$rows" ] && ! awk -F'\t' 'NF != 3 || $2 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' <<<"$rows"; then
    return 1
  fi
  printf '%s' "$rows"
}

# The default branch's head commit, which every content and history read of one repository is pinned
# to. The branch name comes from the API, so each segment is percent-encoded; the single-ref endpoint
# matches exactly, never a prefix, and the reply must name that same branch and a full commit SHA.
# Anything else returns 1, which callers treat as UNKNOWN.
resolve_head() { # <repo> <branch>
  local encoded out ref kind sha
  encoded="$(jq -rn --arg b "$2" '$b | split("/") | map(@uri) | join("/")')" || return 1
  out="$(gh api "repos/$1/git/ref/heads/${encoded}" \
    --jq 'if (.ref | type) == "string" and (.object.type | type) == "string" and (.object.sha | type) == "string" then [.ref, .object.type, .object.sha] | @tsv else "BAD" end')" ||
    return 1
  IFS=$'\t' read -r ref kind sha <<<"$out" || return 1
  [ "$ref" = "refs/heads/$2" ] && [ "$kind" = commit ] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$sha"
}

# One page of a workflow file's history at the pinned head: the newest version at or before the
# window start, and the versions committed inside the window, newest first, each with its full text.
# A version whose `file` is null is a commit where the file did not exist (it was deleted there).
# GraphQL returns every version's text in one request, where the REST API needs one per version.
history_page_size=50
max_history_pages=6
# shellcheck disable=SC2016 # GraphQL variables, not shell expansions
history_query='query($owner: String!, $name: String!, $oid: GitObjectID!, $path: String!, $since: GitTimestamp!, $after: String) {
  repository(owner: $owner, name: $name) {
    object(oid: $oid) {
      ... on Commit {
        before: history(path: $path, until: $since, first: 1) {
          nodes { file(path: $path) { object { ... on Blob { isTruncated text } } } }
        }
        window: history(path: $path, since: $since, first: '"${history_page_size}"', after: $after) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes { file(path: $path) { object { ... on Blob { isTruncated text } } } }
        }
      }
    }
  }
}'
# Shapes one history page into `BEFORE …`, `WINDOW …` and a closing `PAGE <total> <count> <more>
# <cursor>` line, where each version is `NONE` (no commit before the window), `ABSENT` (no file at that
# commit) or `TEXT <json string>`. A node missing its `file` key, a truncated or non-text blob, or a
# malformed envelope is `BAD`, so a partial payload can never read as "absent" and grant the grace.
# shellcheck disable=SC2016 # a jq program: its `$` are jq variables
history_jq='
def version: if type != "object" or (has("file") | not) then "BAD"
  elif .file == null then "ABSENT"
  elif (.file.object | type) == "object" and .file.object.isTruncated == false and (.file.object.text | type) == "string"
    then "TEXT " + (.file.object.text | @json)
  else "BAD" end;
if (.errors // null) != null then "BAD" else
  .data.repository.object as $c
  | if ($c | type) != "object" or ($c.before.nodes | type) != "array" or ($c.window.nodes | type) != "array"
      or ($c.window.totalCount | type) != "number" or ($c.window.pageInfo.hasNextPage | type) != "boolean"
      or ($c.window.pageInfo.hasNextPage and ($c.window.pageInfo.endCursor | type) != "string") then "BAD"
    else
      (if ($c.before.nodes | length) == 0 then "BEFORE NONE" else "BEFORE " + ($c.before.nodes[0] | version) end),
      ($c.window.nodes[] | "WINDOW " + version),
      "PAGE \($c.window.totalCount) \($c.window.nodes | length) \($c.window.pageInfo.hasNextPage) \($c.window.pageInfo.endCursor // "" | @json)"
    end
  end'

# Whether the current schedule has run continuously since the window start (monorepo#3671). Comparing
# only the window-start version with today's would pass a schedule that was removed and re-added
# inside the window, so every version committed inside the window is compared too. Prints JUDGE when
# all of them hold today's crons; GRACE when any one proves otherwise (other crons, no schedule, no
# file, or no commit before the window), because the current schedule then began inside the window and
# is not yet due; or `UNKNOWN <reason>`. Only a proven difference grants the grace: a version that
# cannot be parsed could be the tool, not the file, and a walk that fails or does not reach the window
# start within its bound is UNKNOWN.
schedule_continuity() { # <repo> <path> <pinned head> <window start, ISO 8601> <current crons>
  local after="" page out line text version_crons total count more cursor seen=0 unparseable="" args
  for ((page = 1; page <= max_history_pages; page++)); do
    args=(-f query="$history_query" -f owner="${1%%/*}" -f name="${1#*/}" -f oid="$3" -f path="$2" -f since="$4")
    [ -z "$after" ] || args+=(-f after="$after")
    if ! out="$(gh api graphql "${args[@]}" --jq "$history_jq" 2>"$err")" || grep -qE '(^| )BAD$' <<<"$out"; then
      echo "UNKNOWN file history at the pinned head unreadable"
      return 0
    fi
    total="" count="" more="" cursor=""
    while IFS= read -r line; do
      case "$line" in
        "BEFORE "*) [ "$page" -eq 1 ] || continue ;; # every page repeats it
      esac
      case "$line" in
        "BEFORE NONE" | "BEFORE ABSENT" | "WINDOW ABSENT")
          echo GRACE
          return 0
          ;;
        "BEFORE TEXT "* | "WINDOW TEXT "*)
          if ! text="$(jq -r . <<<"${line#* TEXT }")" || [ -z "$text" ] || ! version_crons="$(crons_of "$text")"; then
            # An empty body parses as "no schedule", so it is unparseable here, never a difference.
            case "$line" in
              BEFORE*) unparseable="file at the window start unparseable" ;;
              *) unparseable="file version inside the window unparseable" ;;
            esac
            continue
          fi
          if [ "$version_crons" != "$5" ]; then
            echo GRACE
            return 0
          fi
          ;;
        "PAGE "*) read -r _ total count more cursor <<<"$line" ;;
        *)
          echo "UNKNOWN file history at the pinned head unreadable"
          return 0
          ;;
      esac
    done <<<"$out"
    if ! is_epoch "${total:-x}" || ! is_epoch "${count:-x}"; then
      echo "UNKNOWN file history at the pinned head unreadable"
      return 0
    fi
    seen=$((seen + count))
    case "$more" in
      false)
        if [ "$seen" -ne "$total" ]; then
          echo "UNKNOWN file history inside the window incomplete (${seen} of ${total})"
        elif [ -n "$unparseable" ]; then
          echo "UNKNOWN ${unparseable}"
        else
          echo JUDGE
        fi
        return 0
        ;;
      true) ;;
      *)
        echo "UNKNOWN file history at the pinned head unreadable"
        return 0
        ;;
    esac
    if [ "$count" -eq 0 ] || ! after="$(jq -r . <<<"$cursor")" || [ -z "$after" ]; then
      echo "UNKNOWN file history at the pinned head unreadable"
      return 0
    fi
  done
  echo "UNKNOWN file history inside the window exceeds $((max_history_pages * history_page_size)) commits"
}

# Judges every workflow in `workflows` for one repository, with every content and history read pinned
# to <head>. Prints its findings and sets scan_checked, scan_silent and scan_unknown, so the caller can
# confirm the head before reporting.
scan_repo() { # <repo> <pinned head>
  local repo="$1" head="$2" wf_files wf_dir id state path created encoded_path content crons gap_days
  local window limit cutoff cutoff_iso continuity found verdict page rows oldest event at stamp recheck
  scan_checked=0
  scan_silent=0
  scan_unknown=0
  # Which workflow files exist on the default branch, from the directory listing. A workflow can stay
  # listed `active` after its file left the default branch (it ran on some other ref), and only a
  # file ON the default branch can fire a schedule. A single file's 404 cannot tell "removed" from
  # "this token cannot read contents", so the directory listing decides: absent from it means
  # removed; present but unreadable is UNKNOWN. An unreadable directory leaves every file unknown,
  # and so does a listing at the Contents API's 1,000-entry cap, which may be truncated.
  if wf_files="$(gh api --method GET "repos/${repo}/contents/.github/workflows" -f ref="${head}" \
    --jq 'if type != "array" or length >= 1000 then "BAD" else (.[] | if (.type | type) != "string" then "BAD" elif .type != "file" then empty elif (.path | type) == "string" and (.path | test("^[^\\n]+$")) then .path else "BAD" end) end' 2>"$err")" &&
    ! grep -qx 'BAD' <<<"$wf_files"; then
    wf_dir=readable
  else
    wf_dir=unreadable
  fi
  while IFS=$'\t' read -r id state path created; do
    [ -n "$id" ] || continue
    case "$path" in .github/workflows/*) ;; *) continue ;; esac # dynamic / GitHub-managed
    # Whitelist the documented states: an unknown or future one is never assumed to be active.
    case "$state" in
      active | disabled_inactivity) ;;
      disabled_manually | disabled_fork | deleted) continue ;; # a decision, a policy, or gone
      *)
        echo "QUERY-UNKNOWN ${repo} ${path} — unrecognised workflow state '${state}'"
        scan_unknown=1
        continue
        ;;
    esac
    if [ "$wf_dir" != readable ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow directory on the default branch unreadable"
      scan_unknown=1
      continue
    fi
    grep -qxF -- "$path" <<<"$wf_files" || continue # removed from the default branch

    # The path comes from the API and may hold URL metacharacters: each path segment is
    # percent-encoded and the pinned commit travels as an encoded GET field. The raw media type
    # returns the file itself, so no base64 decoder (whose flags differ between BSD and GNU) is
    # involved.
    encoded_path="$(jq -rn --arg p "$path" '$p | split("/") | map(@uri) | join("/")')"
    if ! content="$(gh api --method GET -H 'Accept: application/vnd.github.raw' \
      "repos/${repo}/contents/${encoded_path}" -f ref="${head}" 2>"$err")"; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow file read failed"
      scan_unknown=1
      continue
    fi
    if [ -z "$content" ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow file empty"
      scan_unknown=1
      continue
    fi
    if ! crons="$(crons_of "$content")"; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow triggers unparseable"
      scan_unknown=1
      continue
    fi
    [ -n "$crons" ] || continue # no schedule: silence is not evidence

    # The gap is measured on the union of every cron line's firing days. A line that cannot be
    # parsed, or a schedule that never fires, is UNKNOWN.
    gap_days="$(cron_gap_days "$crons")" || gap_days=0
    if ! is_epoch "$gap_days" || [ "$gap_days" -eq 0 ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — schedule '$(tr '\n' ';' <<<"$crons" | sed 's/;$//')' unparseable or never fires"
      scan_unknown=1
      continue
    fi
    # The extra day covers where in its day the firing falls; the grace hour covers queueing delay.
    window=$(((gap_days + 1) * day))
    limit=$((2 * window + hour))
    scan_checked=$((scan_checked + 1))

    if [ "$state" = "disabled_inactivity" ]; then
      echo "SILENT-WORKFLOW ${repo} ${path} — schedule disabled by GitHub for repository inactivity"
      scan_silent=1
      continue
    fi

    cutoff=$((now - limit))
    # Too new to have missed a firing yet?
    if ! is_epoch "$created"; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow creation time unparseable"
      scan_unknown=1
      continue
    fi
    [ "$created" -gt "$cutoff" ] && continue
    # The creation time is not enough: an old dispatch-only workflow that GAINS a schedule was
    # created long ago, yet its first firing may not be due. And the file's newest commit is not
    # enough either, because unrelated edits (a pin bump every month) would renew that grace
    # forever. So judge the schedule itself: only one that has held today's crons since the window
    # start is judged on its run history.
    cutoff_iso="$(jq -rn --argjson e "$cutoff" '$e | todate')"
    continuity="$(schedule_continuity "$repo" "$path" "$head" "$cutoff_iso" "$crons")"
    case "$continuity" in
      JUDGE) ;;
      GRACE) continue ;;
      "UNKNOWN "*)
        echo "QUERY-UNKNOWN ${repo} ${path} — ${continuity#UNKNOWN }"
        scan_unknown=1
        continue
        ;;
      *)
        echo "QUERY-UNKNOWN ${repo} ${path} — schedule history gave no verdict"
        scan_unknown=1
        continue
        ;;
    esac

    # 🔴 Never filter the run list by `event=schedule`: that filtered listing is INCOMPLETE —
    # measured 2026-09-29 on a monthly workflow, it returned 3 runs (newest July) while the
    # unfiltered listing held September's. Read the unfiltered, newest-first listing instead and
    # page back only until a page crosses the window edge.
    found=""
    verdict=""
    for ((page = 1; page <= max_pages; page++)); do
      if ! rows="$(read_run_page "$repo" "$id" "$page")"; then
        verdict="unknown"
        break
      fi
      if [ -z "$rows" ]; then
        verdict="edge"
        break
      fi
      oldest=""
      while IFS=$'\t' read -r event at stamp; do
        oldest="$at"
        if [ "$event" = "schedule" ] && [ "$at" -ge "$cutoff" ]; then
          found="$stamp"
          break
        fi
      done <<<"$rows"
      [ -n "$found" ] && break
      [ "$oldest" -lt "$cutoff" ] && { verdict="edge"; break; }
    done
    if [ "$verdict" = "unknown" ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — run list read failed"
      scan_unknown=1
    elif [ -z "$found" ] && [ "$verdict" != "edge" ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — window not reached within ${max_pages} pages of runs"
      scan_unknown=1
    elif [ -z "$found" ]; then
      # Offset pagination shifts if a run is created mid-scan, so a scheduled run that landed after
      # page 1 was read could be skipped. Re-read page 1 before reporting a stop.
      # The re-read goes through the same validated reader as the scan.
      if ! recheck="$(read_run_page "$repo" "$id" 1)"; then
        echo "QUERY-UNKNOWN ${repo} ${path} — run list re-read failed"
        scan_unknown=1
      elif ! awk -F'\t' -v c="$cutoff" '$1 == "schedule" && $2 >= c { hit = 1 } END { exit hit ? 0 : 1 }' \
        <<<"$recheck"; then
        echo "SILENT-WORKFLOW ${repo} ${path} — no scheduled run in the last $((limit / hour))h (its cron fires at least every ${gap_days}d)"
        scan_silent=1
      fi
    fi
  done <<<"$workflows"
}

# Turns every silence in the scan buffer into an UNKNOWN naming <reason>: a silence whose schedule
# could not be confirmed at the current head is never reported, and never read as clean.
unconfirmed() { # <reason>
  local rewritten
  rewritten="$(awk -v r="$1" '$1 == "SILENT-WORKFLOW" { print "QUERY-UNKNOWN " $2 " " $3 " — silence not confirmed: " r; next } { print }' "$buf")"
  printf '%s\n' "$rewritten" >"$buf"
  scan_silent=0
  scan_unknown=1
}

silent=0
checked=0
repos_read=0
max_pages=5
err="$(mktemp)"
buf="$(mktemp)"
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
    --jq "${jq_epoch} if (.total_count | type) == \"number\" and (.total_count | floor) == .total_count and (.workflows | type) == \"array\" then (\"TOTAL\t\(.total_count)\", (.workflows[] | if (.id | type) == \"number\" and (.state | type) == \"string\" and (.path | type) == \"string\" and (if (.path | startswith(\".github/workflows/\")) then (.path | test(\"^[.]github/workflows/[A-Za-z0-9._#-]+$\")) else (.path | test(\"^[!-~]+$\")) end) and (.created_at | type) == \"string\" then [.id, .state, .path, (.created_at | epoch)] | @tsv else \"BAD\" end)) else \"BAD\" end")"; then
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
  if ! head="$(resolve_head "$repo" "$branch")"; then
    echo "QUERY-UNKNOWN ${repo} — default branch head unresolvable"
    unknown=1
    continue
  fi
  repos_read=$((repos_read + 1))
  # Run history is read live, not at the pinned head, so a silence holds only while the head it was
  # judged at is still the head. Confirm that before reporting; if the branch moved, the schedule may
  # have changed or gone, so judge the repository once more at the new head. A branch that moves
  # again turns each silence into UNKNOWN rather than a report.
  for attempt in 1 2; do
    scan_repo "$repo" "$head" >"$buf"
    [ "$scan_silent" -eq 1 ] || break
    if ! latest="$(resolve_head "$repo" "$branch")"; then
      unconfirmed "default branch head unresolvable before reporting"
      break
    fi
    [ "$latest" != "$head" ] || break
    if [ "$attempt" -eq 2 ]; then
      unconfirmed "default branch moved again while it was re-judged"
      break
    fi
    head="$latest"
  done
  cat "$buf"
  checked=$((checked + scan_checked))
  [ "$scan_silent" -eq 0 ] || silent=1
  [ "$scan_unknown" -eq 0 ] || unknown=1
done

echo "CHECKED ${checked} scheduled workflow(s) across ${repos_read} repositor(ies)"
finished=1
[ "$unknown" -eq 0 ] || exit 2
[ "$silent" -eq 0 ] || exit 1
exit 0
