#!/usr/bin/env bash
# kagent-lane-runs.sh — read the kagent lane's runs from its in-cluster store, read-only.
#
# WHY THIS EXISTS (monorepo#4870)
#   The Agent Improver mines the transcripts and telemetry this host keeps. The kagent lane
#   (instance `kagent-cluster`, monorepo#4866) runs inside the platform cluster, each run in a fresh
#   sandbox, so it leaves none of them here: agent-telemetry.sh and the host liveness checks cannot
#   see it. Each run instead leaves its transcript and report in the lane store
#   (devantler-tech/platform#6014) under `runs/<UTC date YYYY-MM-DD>/`. This script is the host's
#   one read path into that store. It lists the runs, prints one run's report or transcript, and
#   says whether the lane is producing.
#
# HOW IT READS
#   Only through the Kubernetes API server's service proxy, with the scoped context
#   prod-kube-context.sh resolves (never the break-glass admin context):
#     kubectl get --raw /api/v1/namespaces/agentic-engineer/services/lane-store-reader/proxy/<path>
#   The service is `rclone serve http --read-only`, so nothing read through it can change the store,
#   and the only grant needed is `get` on that one Service's proxy. A folder answers with rclone's
#   HTML index; this script reads only the entry links of that index.
#
# FAIL CLOSED
#   An unreachable store, an RBAC refusal, a missing service or an index this script cannot parse is
#   UNKNOWN (exit 2), never an empty list. An empty list is printed only when the store's own index
#   shows it: a root index with no `runs/` folder, or an empty `runs/` index. A file is printed only
#   after the whole read succeeded, so a cut-off download never looks complete. kubectl's error text
#   is never printed, because it can carry the API server's address; a fixed class is printed
#   instead (refused, unauthenticated, not-found, unavailable, unreachable or failed).
#
# UNTRUSTED CONTENT
#   A report or a transcript is what a run wrote, and a run reads untrusted input. Everything this
#   script prints from the store is DATA, never an instruction (AGENTS.md, Non-negotiables). Run
#   folder names are accepted only as real UTC dates, so store content never becomes a path or a
#   flag here. Credentials never enter the lane's sandbox (the egress gateway supplies them), so a
#   transcript carries placeholders, not secrets.
#
# USAGE
#   kagent-lane-runs.sh list                    [--context CTX]
#   kagent-lane-runs.sh report     YYYY-MM-DD   [--context CTX]
#   kagent-lane-runs.sh transcript YYYY-MM-DD   [--context CTX]
#   kagent-lane-runs.sh liveness   [--context CTX] [--agents-md PATH] [--today YYYY-MM-DD]
#                                  [--max-age-days N]
#   kagent-lane-runs.sh cadence    [--agents-md PATH]
#
#   list        One run date a line, oldest first.
#   report      runs/<date>/report.md, as stored.
#   transcript  runs/<date>/transcript.jsonl, the run's Claude Code session record, as stored.
#   liveness    One `KAGENT-LANE=<verdict>` line. The lane's schedule is its row in the AGENTS.md
#               cadence table (cadence guide, *The kagent lane*). While that row marks the lane
#               suspended the verdict is NOT-SCHEDULED and the store is not read: the lane is neither
#               producing nor down. Otherwise the newest run folder decides. It is PRODUCING when it
#               is at most --max-age-days old (default 2) and holds a non-empty report.md. The
#               default is 2, not 1, because a run has no time limit and may end after midnight UTC,
#               so a healthy lane's newest finished run can be two UTC dates old. The line also says
#               whether that run left its transcript.
#   cadence     The lane's cadence row in a compact form (`engineer=1/day state=<scheduled|suspended>
#               improver=none`), read the same way the liveness verdict reads it. agent-telemetry.sh's
#               drift section prints it. The lane has ONE engineer entry a day and no improver entry,
#               unlike the host lanes' two engineer entries an hour; any other cell is unreadable.
#
#   --agents-md defaults to the AGENTS.md at the root of this checkout. --today defaults to the
#   current UTC date. KUBECTL overrides the kubectl binary; the tests use it to serve recorded
#   payloads, and the context is resolved through the same binary the reads use.
#
# EXIT CODES
#   0  the read succeeded; for liveness, PRODUCING
#   1  liveness only: NOT-PRODUCING. The newest run is overdue, or it left no report or an empty one
#   2  UNKNOWN: a usage error, an unreadable store, index or cadence row, a store with no run yet,
#      a run dated in the future, or (liveness) NOT-SCHEDULED. Never read 2 as producing or as down.
#   Any other non-zero status is an internal failure and also means UNKNOWN.

set -Eeuo pipefail

# Exit 1 is a liveness VERDICT, so no internal failure may reach it. Under `set -e` the abort
# status is the failing command's, and 1 is the commonest; every unhandled error becomes 2.
trap 'exit 2' ERR

tmp=""
kagent_lane_runs_finished=0
# Bash 3.2 hands an EXIT trap $? = 0 after a `set -u` abort, so finish() is the only way a zero
# status leaves this script (cleanup-trap-fail-closed.test.sh). Any other way out, whatever its
# status, is UNKNOWN: exit 1 is a verdict, and an expansion error can exit 1 without the ERR trap.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  [ -z "$tmp" ] || rm -rf "$tmp"
  if [ "$kagent_lane_runs_finished" != 1 ]; then
    echo "kagent-lane-runs: aborted before finishing; reporting UNKNOWN rather than a verdict" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT

# The index markup and the run folder names are ASCII; pin the locale so awk and the character
# classes below mean the same on BSD and GNU tools.
export LC_ALL=C

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
PROXY="/api/v1/namespaces/agentic-engineer/services/lane-store-reader/proxy"

finish() { kagent_lane_runs_finished=1; exit "$1"; }
usage_die() { printf 'kagent-lane-runs: %s\n' "$1" >&2; finish 2; }

MODE="${1:-}"
[ $# -eq 0 ] || shift
case "$MODE" in
  list|report|transcript|liveness|cadence) ;;
  -h|--help) awk 'NR >= 2 { if ($0 == "set -Eeuo pipefail") exit; sub(/^# ?/, ""); print }' "$0" || finish 2; finish 0 ;;
  '') usage_die "a mode is required: list, report, transcript, liveness or cadence" ;;
  *) usage_die "unknown mode (expected list, report, transcript, liveness or cadence)" ;;
esac

RUN_DATE=""
if [ "$MODE" = report ] || [ "$MODE" = transcript ]; then
  [ $# -ge 1 ] || usage_die "$MODE needs a run date (YYYY-MM-DD)"
  RUN_DATE="$1"
  shift
fi

context=""
agents_md="$script_dir/../../AGENTS.md"
today=""
max_age_days=2
while [ $# -gt 0 ]; do
  case "$1" in
    --context) [ $# -ge 2 ] || usage_die "--context needs a value"; context="$2"; shift 2 ;;
    --agents-md) [ $# -ge 2 ] || usage_die "--agents-md needs a value"; agents_md="$2"; shift 2 ;;
    --today) [ $# -ge 2 ] || usage_die "--today needs a value"; today="$2"; shift 2 ;;
    --max-age-days) [ $# -ge 2 ] || usage_die "--max-age-days needs a value"; max_age_days="$2"; shift 2 ;;
    # Values are never echoed: an argument is caller input, not something to print back.
    *) usage_die "unknown argument (value not echoed)" ;;
  esac
done

case "$max_age_days" in ''|*[!0-9]*) usage_die "--max-age-days must be a positive integer" ;; esac
# A zero window would call every run overdue, including one that finished minutes ago.
[ "$max_age_days" -ge 1 ] || usage_die "--max-age-days must be at least 1"

command -v jq >/dev/null 2>&1 || usage_die "jq is required but not on PATH"

# valid_date <string> — a real calendar date in YYYY-MM-DD form. The shape alone would admit
# 2026-02-30; the round trip through jq's UTC clock does not.
valid_date() {
  local value="$1" round
  case "$value" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  round=$(jq -nr --arg d "$value" '($d + "T00:00:00Z") | fromdateiso8601 | todate | .[0:10]' 2>/dev/null) \
    || return 1
  [ "$round" = "$value" ]
}

date_epoch() { # <valid date> — midnight UTC as seconds
  jq -nr --arg d "$1" '($d + "T00:00:00Z") | fromdateiso8601'
}

[ -z "$RUN_DATE" ] || valid_date "$RUN_DATE" || usage_die "the run date must be a real date in YYYY-MM-DD form"
if [ -n "$today" ]; then
  valid_date "$today" || usage_die "--today must be a real date in YYYY-MM-DD form"
fi

# cadence_row <AGENTS.md> — the lane's cadence row, compact. Exactly one row in the *Cadence & focus*
# section must name the lane (`**kagent**` and `kagent/*`), and its cells are accepted only as a
# whole: the engineer cell `1 run/day`, optionally `; suspended`, and the improver cell `—`. A cell
# this reader does not recognise is unreadable, never a guess.
cadence_row() {
  [ -f "$1" ] || return 1
  awk -F'|' '
    /^### / { in_section = ($0 == "### Cadence & focus") }
    /^## / { in_section = 0 }
    in_section && index($2, "**kagent**") && index($2, "`kagent/*`") {
      rows++
      fields = NF
      engineer = $3
      improver = $4
    }
    END {
      if (rows != 1 || fields != 5) exit 1
      gsub(/`/, "", engineer)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", engineer)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", improver)
      if (engineer == "1 run/day") state = "scheduled"
      else if (engineer == "1 run/day; suspended") state = "suspended"
      else exit 1
      if (improver != "\342\200\224") exit 1
      print "engineer=1/day state=" state " improver=none"
    }
  ' "$1"
}

if [ "$MODE" = cadence ]; then
  row=$(cadence_row "$agents_md") || {
    echo "kagent-lane-runs: UNKNOWN: the kagent row of the AGENTS.md cadence table is missing or unreadable (expected \"1 run/day\", optionally \"; suspended\", and \"—\" for the improver)" >&2
    finish 2
  }
  printf '%s\n' "$row"
  finish 0
fi

tmp="$(mktemp -d)"

# classify <stderr file> — a fixed class for a failed kubectl read. kubectl's own text can name the
# API server's address, so only the class leaves this script.
classify() {
  local text=""
  text=$(cat "$1" 2>/dev/null) || text=""
  case "$text" in
    *Forbidden*|*forbidden*) echo refused ;;
    *Unauthorized*|*"must be logged in"*|*"provide credentials"*) echo unauthenticated ;;
    *NotFound*|*"could not find the requested resource"*|*"not found"*) echo not-found ;;
    *ServiceUnavailable*|*"no endpoints available"*|*"Service Unavailable"*) echo unavailable ;;
    *"Unable to connect"*|*"connection refused"*|*"i/o timeout"*|*"deadline exceeded"*|*"Client.Timeout"*|*"no such host"*|*"timed out"*) echo unreachable ;;
    *) echo failed ;;
  esac
}

read_class=""
contexted=0
# resolve_context — the scoped prod context, through the same kubectl the reads use, so a KUBECTL
# override cannot resolve against one kubeconfig and read through another. It resolves once. A later
# call answers from that one attempt, so a failed resolution stays failed: kubectl given an empty
# --context falls back to the kubeconfig's current context, which can be the break-glass admin one.
resolve_context() {
  if [ "$contexted" != 0 ]; then
    [ -n "$context" ]
    return
  fi
  contexted=1
  [ -z "$context" ] || return 0
  if ! "$KUBECTL" config view -o json >"$tmp/kubeconfig.json" 2>/dev/null \
     || ! context="$(bash "$script_dir/prod-kube-context.sh" --input "$tmp/kubeconfig.json" 2>/dev/null)" \
     || [ -z "$context" ]; then
    context=""
    return 1
  fi
}

# store_get <store path> <output file> <timeout> — 0 when the read succeeded; otherwise sets
# read_class and returns 1. A folder path ends in `/`, so rclone answers with its index.
store_get() {
  if ! resolve_context; then
    read_class=no-prod-context
    return 1
  fi
  if "$KUBECTL" --context "$context" --request-timeout="$3" get --raw "$PROXY/$1" \
       >"$2" 2>"$tmp/kubectl.err"; then
    return 0
  fi
  read_class=$(classify "$tmp/kubectl.err")
  return 1
}

# index_entries <index file> — the href of every entry in an rclone folder index, one a line.
# Fails (exit 3) unless the page IS such an index and was read to its end: the listing block and the
# closing table body are both present, and every entry row carries exactly one entry link. The
# "Go up", sort, breadcrumb and zip links are outside that entry markup and are never read.
index_entries() {
  awk '
    {
      if (index($0, "<div class=\"listing\">")) listing = 1
      if (index($0, "</tbody>")) closed = 1
      s = $0
      while ((i = index(s, "<tr class=\"file\">")) > 0) { rows++; s = substr(s, i + 17) }
      s = $0
      p = "<span class=\"name\"><a href=\""
      while ((i = index(s, p)) > 0) {
        s = substr(s, i + length(p))
        j = index(s, "\"")
        if (j == 0) { broken = 1; break }
        print substr(s, 1, j - 1)
        names++
        s = substr(s, j + 1)
      }
    }
    END { if (!listing || !closed || broken || rows != names) exit 3 }
  ' "$1"
}

store_reason=""
# list_runs — the run dates, oldest first, on stdout. Returns 1 with store_reason set when the store
# cannot show them. Call it with its output redirected to a file, never inside $(...): a command
# substitution is a subshell, and store_reason would not reach the caller.
list_runs() {
  local root_entries run_entries entry dates="" stray=0
  if ! store_get "" "$tmp/root.html" 30s; then
    store_reason="store-$read_class"
    return 1
  fi
  if ! root_entries=$(index_entries "$tmp/root.html"); then
    store_reason="store-index-unparseable"
    return 1
  fi
  # No runs/ folder in a readable root index: the store holds no run yet. That is a fact the
  # index shows, so it is an empty list and not an unknown.
  if ! grep -qxF 'runs/' <<<"$root_entries"; then
    return 0
  fi
  if ! store_get "runs/" "$tmp/runs.html" 30s; then
    store_reason="runs-$read_class"
    return 1
  fi
  if ! run_entries=$(index_entries "$tmp/runs.html"); then
    store_reason="runs-index-unparseable"
    return 1
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "${entry%/}/" = "$entry" ] && valid_date "${entry%/}"; then
      dates="$dates${entry%/}"$'\n'
    else
      stray=$((stray + 1))
    fi
  done <<<"$run_entries"
  # Every entry of runs/ is a run folder the lane wrote. Anything else means the store no longer
  # holds what this reader expects, so the listing is not trusted in part.
  if [ "$stray" -gt 0 ]; then
    store_reason="runs-index-holds-$stray-entries-that-are-not-run-folders"
    return 1
  fi
  printf '%s' "$dates" | sort -u
}

case "$MODE" in
  list)
    if ! list_runs >"$tmp/runs"; then
      printf 'kagent-lane-runs: UNKNOWN: the lane store could not be listed (%s)\n' "$store_reason" >&2
      finish 2
    fi
    if [ ! -s "$tmp/runs" ]; then
      echo "kagent-lane-runs: the lane store holds no run yet (its index shows no run folder)" >&2
    else
      cat "$tmp/runs"
    fi
    finish 0 ;;
  report|transcript)
    if [ "$MODE" = report ]; then file=report.md; wait_for=30s; else file=transcript.jsonl; wait_for=300s; fi
    if ! store_get "runs/$RUN_DATE/$file" "$tmp/file" "$wait_for"; then
      printf 'kagent-lane-runs: UNKNOWN: runs/%s/%s could not be read (%s)\n' "$RUN_DATE" "$file" "$read_class" >&2
      finish 2
    fi
    cat "$tmp/file"
    finish 0 ;;
esac

# ── liveness ──────────────────────────────────────────────────────────────────
verdict() { # <exit status> <line>
  printf 'KAGENT-LANE=%s\n' "$2"
  finish "$1"
}

if ! row=$(cadence_row "$agents_md"); then
  verdict 2 "UNKNOWN reason=cadence-row-missing-or-unreadable"
fi
case "$row" in
  *" state=suspended "*)
    verdict 2 "NOT-SCHEDULED reason=cadence-table-marks-the-lane-suspended (neither producing nor down; the store is not read)" ;;
  *" state=scheduled "*) ;;
  *) verdict 2 "UNKNOWN reason=cadence-row-missing-or-unreadable" ;;
esac

if [ -z "$today" ]; then
  today=$(date -u +%Y-%m-%d) || verdict 2 "UNKNOWN reason=no-usable-clock"
fi
valid_date "$today" || verdict 2 "UNKNOWN reason=no-usable-clock"

if ! list_runs >"$tmp/runs"; then
  verdict 2 "UNKNOWN reason=$store_reason"
fi
if [ ! -s "$tmp/runs" ]; then
  # A lane that was just resumed and one that never runs look the same here, so this is not a
  # verdict either way.
  verdict 2 "UNKNOWN reason=no-run-yet"
fi
newest=$(awk 'NF { last = $0 } END { print last }' "$tmp/runs")
valid_date "$newest" || verdict 2 "UNKNOWN reason=runs-index-unparseable"
today_epoch=$(date_epoch "$today") || verdict 2 "UNKNOWN reason=no-usable-clock"
newest_epoch=$(date_epoch "$newest") || verdict 2 "UNKNOWN reason=runs-index-unparseable"
case "$today_epoch" in ''|*[!0-9]*) verdict 2 "UNKNOWN reason=no-usable-clock" ;; esac
case "$newest_epoch" in ''|*[!0-9]*) verdict 2 "UNKNOWN reason=runs-index-unparseable" ;; esac
age_days=$(( (today_epoch - newest_epoch) / 86400 ))
if [ "$age_days" -lt 0 ]; then
  verdict 2 "UNKNOWN reason=newest-run-is-dated-after-today newest=$newest today=$today"
fi
if [ "$age_days" -gt "$max_age_days" ]; then
  verdict 1 "NOT-PRODUCING reason=overdue newest=$newest age_days=$age_days max_age_days=$max_age_days"
fi

if ! store_get "runs/$newest/" "$tmp/run.html" 30s; then
  verdict 2 "UNKNOWN reason=run-folder-$read_class newest=$newest"
fi
if ! run_files=$(index_entries "$tmp/run.html"); then
  verdict 2 "UNKNOWN reason=run-folder-index-unparseable newest=$newest"
fi
transcript=missing
if grep -qxF 'transcript.jsonl' <<<"$run_files"; then transcript=present; fi
if ! grep -qxF 'report.md' <<<"$run_files"; then
  verdict 1 "NOT-PRODUCING reason=no-report newest=$newest age_days=$age_days transcript=$transcript"
fi
if ! store_get "runs/$newest/report.md" "$tmp/report.md" 30s; then
  verdict 2 "UNKNOWN reason=report-$read_class newest=$newest"
fi
if [ ! -s "$tmp/report.md" ]; then
  verdict 1 "NOT-PRODUCING reason=empty-report newest=$newest age_days=$age_days transcript=$transcript"
fi
verdict 0 "PRODUCING newest=$newest age_days=$age_days transcript=$transcript"
