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

# Longest gap between two firings of one cron expression, coarsely: a fixed month is yearly, a
# fixed day-of-month is monthly, a fixed weekday is weekly, a fixed hour is daily, else hourly.
# Coarse is the safe direction here: overestimating the gap can only delay a report, never
# invent one.
cron_interval() {
  local hr dom mon dow late leap
  read -r _ hr dom mon dow _ <<<"$1"
  if [ -z "${dow:-}" ]; then
    echo 0
    return
  fi
  # Day 29-31 does not exist in every month. Only 29 February can skip YEARS (it fires in leap
  # years only, up to 8 years apart across a skipped century leap year), so only a February field
  # with day 29 gets the multi-year bound; without a fixed month a late day can skip a month.
  leap=0
  late=0
  [[ "$dom" =~ (^|[,-])(29|30|31)([,/-]|$) ]] && late=1
  [[ "$dom" =~ (^|[,-])29([,/-]|$) && "$mon" =~ (^|[,-])(2|[Ff][Ee][Bb])([,/-]|$) ]] && leap=1
  if [ "$mon" != "*" ]; then
    if [ "$leap" -eq 1 ]; then echo $((8 * 366 * day)); else echo $((366 * day)); fi
  elif [ "$dom" != "*" ]; then
    if [ "$late" -eq 1 ]; then echo $((62 * day)); else echo $((31 * day)); fi
  elif [ "$dow" != "*" ]; then echo $((7 * day))
  elif [ "$hr" != "*" ]; then echo "$day"
  else echo "$hour"
  fi
}

# GitHub returns workflow timestamps with a UTC offset and milliseconds
# (`2024-04-14T02:42:29.000+02:00`) but run timestamps in `Z` form, and BSD and GNU `date` parse
# neither the same way. Convert in jq, where both shapes are handled identically, and check every
# result is an integer before comparing it — a failed conversion must never read as "recent".
jq_epoch='def epoch: (.[0:19] + "Z" | fromdate) - ((capture("(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$") // {s: "+", h: "0", m: "0"}) | ((.h | tonumber) * 3600 + (.m | tonumber) * 60) * (if .s == "+" then 1 else -1 end));'
is_epoch() { [[ "$1" =~ ^[0-9]+$ ]]; }

silent=0
checked=0
repos_read=0
max_pages=5
err="$(mktemp)"
# Bash 3.2 reports $? as 0 to an EXIT trap after a `set -u` abort, so a successful `rm` would
# become the exit status and an aborted scan would read as clean. Only reaching the end may exit 0.
finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  rm -f "$err"
  if [ "$finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "silent-scheduled-workflows: aborted before finishing; reporting UNKNOWN" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT
unknown=0

for repo in "${repos[@]}"; do
  if ! branch="$(gh api "repos/${repo}" --jq '.default_branch')" || [ -z "$branch" ]; then
    echo "QUERY-UNKNOWN ${repo} — default branch read failed"
    unknown=1
    continue
  fi
  if ! workflows="$(gh api --paginate "repos/${repo}/actions/workflows?per_page=100" \
    --jq "${jq_epoch} .workflows[] | [.id, .state, .path, (.created_at | epoch)] | @tsv")"; then
    echo "QUERY-UNKNOWN ${repo} — workflow list read failed"
    unknown=1
    continue
  fi
  repos_read=$((repos_read + 1))
  while IFS=$'\t' read -r id state path created; do
    [ -n "$id" ] || continue
    case "$path" in .github/workflows/*) ;; *) continue ;; esac # dynamic / GitHub-managed
    [ "$state" = "disabled_manually" ] && continue               # a recorded decision

    # A workflow can stay listed `active` after its file left the default branch (it ran on some
    # other ref). Only a file ON the default branch can fire a schedule, so a 404 is a skip — but
    # only a 404; any other failure is UNKNOWN.
    # Branch names come from the API and may hold URL metacharacters, so send them as encoded
    # GET fields rather than concatenating them into the path.
    if ! raw="$(gh api --method GET "repos/${repo}/contents/${path}" -f ref="${branch}" \
      --jq '.content' 2>"$err")"; then
      grep -q 'HTTP 404' "$err" && continue
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow file read failed"
      unknown=1
      continue
    fi
    if ! content="$(base64 --decode <<<"$raw")" || [ -z "$content" ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow file unreadable"
      unknown=1
      continue
    fi
    # `on:` parses as the boolean key `true` under YAML 1.1, so read both spellings.
    if ! crons="$(yq -r '(.on // .true // {}) | select(tag == "!!map") | .schedule // [] | .[].cron' \
      <<<"$content" 2>/dev/null)"; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow triggers unparseable"
      unknown=1
      continue
    fi
    [ -n "$crons" ] || continue # no schedule: silence is not evidence

    window=0
    while IFS= read -r cron; do
      interval="$(cron_interval "$cron")"
      [ "$interval" -gt "$window" ] && window="$interval"
    done <<<"$crons"
    if [ "$window" -eq 0 ]; then
      echo "QUERY-UNKNOWN ${repo} ${path} — cron expression unparseable"
      unknown=1
      continue
    fi
    limit=$((2 * window + hour))
    checked=$((checked + 1))

    if [ "$state" = "disabled_inactivity" ]; then
      echo "SILENT-WORKFLOW ${repo} ${path} — schedule disabled by GitHub for repository inactivity"
      silent=1
      continue
    fi

    cutoff=$((now - limit))
    # Too new to have missed a firing yet. The workflow's creation time is not enough: an old
    # dispatch-only workflow that GAINS a schedule was created long ago, yet its first firing may
    # not be due. So the schedule counts as active only from the file's newest commit on the default
    # branch — later than the real activation at worst, which can only delay a report.
    if ! is_epoch "$created"; then
      echo "QUERY-UNKNOWN ${repo} ${path} — workflow creation time unparseable"
      unknown=1
      continue
    fi
    if ! changed="$(gh api --method GET "repos/${repo}/commits" -f path="${path}" -f sha="${branch}" -f per_page=1 \
      --jq "${jq_epoch} .[0].commit.committer.date // \"\" | if . == \"\" then \"\" else epoch end")" ||
      ! is_epoch "$changed"; then
      echo "QUERY-UNKNOWN ${repo} ${path} — last change on the default branch unreadable"
      unknown=1
      continue
    fi
    [ "$created" -gt "$cutoff" ] && continue
    [ "$changed" -gt "$cutoff" ] && continue

    # 🔴 Never filter the run list by `event=schedule`: that filtered listing is INCOMPLETE —
    # measured 2026-09-29 on a monthly workflow, it returned 3 runs (newest July) while the
    # unfiltered listing held September's. Read the unfiltered, newest-first listing instead and
    # page back only until a page crosses the window edge.
    found=""
    verdict=""
    for ((page = 1; page <= max_pages; page++)); do
      if ! rows="$(gh api "repos/${repo}/actions/workflows/${id}/runs?per_page=100&page=${page}" \
        --jq "${jq_epoch} .workflow_runs[] | [.event, (.created_at | epoch), .created_at] | @tsv")"; then
        verdict="unknown"
        break
      fi
      [ -n "$rows" ] || { verdict="edge"; break; }
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
      echo "SILENT-WORKFLOW ${repo} ${path} — no scheduled run in the last $((limit / hour))h (longest cron gap $((window / hour))h)"
      silent=1
    fi
  done <<<"$workflows"
done

echo "CHECKED ${checked} scheduled workflow(s) across ${repos_read} repositor(ies)"
finished=1
[ "$unknown" -eq 0 ] || exit 2
[ "$silent" -eq 0 ] || exit 1
exit 0
