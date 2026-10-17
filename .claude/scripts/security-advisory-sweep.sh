#!/usr/bin/env bash
#
# security-advisory-sweep.sh — list the private vulnerability reports waiting across an organization,
# and report any that has outrun the security policy (monorepo#4294).
#
# Why this exists. Private vulnerability reporting is on across the portfolio. A report arrives as a
# repository security advisory in state `triage`, and no other survey read looks at advisories: on
# 2026-10-17 an outside contributor reported a real vulnerability this way, and it was handled only
# because the maintainer linked it. The security policy promises the reporter an answer within three
# business days, so a report nobody reads is a broken promise.
#
# What it prints. Only the repository, the GHSA id, the state, the severity and the age. Never the
# summary, the description, the reporter or any other advisory text: that text stays private until
# the advisory is published, and an outsider wrote it. Every printed field must match a fixed shape
# first. A value in any other shape is reported UNKNOWN and is never echoed.
#
# Windows, from the security policy's "What Happens Next" (devantler-tech/.github, SECURITY.md):
#   triage  accept or decline within three business days. The sweep counts three CALENDAR days, so
#           it flags a report no later than the policy does, and a day or two early over a weekend.
#   draft   a fixed release within 14 days for critical and high severity, and 90 days for medium
#           and low. A draft with no severity yet is held to 14 days.
# Age counts from the advisory's `created_at`.
#
# Reads, in order (about two REST calls per public repository, plus two):
#   1. the organization's repositories, every page. Archived repositories are skipped, and so are
#      private ones: GitHub offers private vulnerability reporting and repository advisories only on
#      public repositories, and answers 404 for a private one (measured 2026-10-17).
#   2. each public repository's advisories in state `triage`, then in state `draft`.
#   3. the CONTROL: the organization's advisories with no state filter. Only an organization owner or
#      security manager may read it, and that is what makes it a control. A repository read by
#      anyone else returns published advisories only, so an empty filtered read can mean "nothing
#      reported" or "not allowed to see". The control's `triage` and `draft` advisories in the swept
#      repositories must match the filtered reads exactly, or the sweep is UNKNOWN.
#
# A failed request, a partial set of pages, output that does not parse, an empty answer and a control
# that disagrees are all UNKNOWN. `gh api --paginate` stops at the first failed page AFTER printing
# the pages before it, so only its exit status, never how much it printed, says a read finished.
#
# Usage:
#   security-advisory-sweep.sh [--org <login>] [--now <epoch-seconds>]
#
# Output, one line per item:
#   ADVISORY <owner/repo> <GHSA-id> state=<triage|draft> severity=<level|unset> age=<n>d window=<n>d <OPEN|OVERDUE>
#   QUERY-UNKNOWN <owner/repo|org> — <what failed>
#   CHECKED <n> open advisor(ies) across <m> public repositor(ies); skipped <a> archived, <p> private
#     (always last, so a clean exit shows what it examined)
#
# Exit codes:
#   0  every open advisory is inside its window, or there is none and the control agrees
#   1  at least one OVERDUE advisory
#   2  UNKNOWN: a failed, partial, malformed or unconfirmed read (never "no reports"), or a usage error

set -euo pipefail

# Installed before any work: an abort before the end must never read as a verdict. bash 3.2 can
# report it as 0 (clean) and bash 5 as 1 (a finding), so any exit before the end is UNKNOWN.
finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  if [ "$finished" != 1 ]; then
    echo "security-advisory-sweep: aborted before finishing; reporting UNKNOWN" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT

usage() {
  sed -n '/^# Usage:/,/^# Output, one line per item:/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  finished=1
  exit 2
}

fail_usage() {
  echo "security-advisory-sweep: $1" >&2
  finished=1
  exit 2
}

org="devantler-tech"
now=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --org)
      [ "$#" -ge 2 ] || usage
      org="$2"
      shift 2
      ;;
    --now)
      [ "$#" -ge 2 ] || usage
      now="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

# A here-string, not a pipe: `grep -q` stops reading early, and the writer's SIGPIPE would become the
# status under pipefail. LC_ALL=C keeps the ranges ASCII on every bash and locale.
LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*$' <<<"$org" || fail_usage "--org must be a GitHub login"
if [ -z "$now" ]; then
  now="$(date -u +%s)"
fi
LC_ALL=C grep -Eq '^[0-9]+$' <<<"$now" || fail_usage "--now must be whole seconds since the epoch"
command -v gh >/dev/null 2>&1 || fail_usage "gh is not installed"
command -v jq >/dev/null 2>&1 || fail_usage "jq is not installed"

unknown=0
overdue=0
open_count=0
swept=0
archived_count=0
private_count=0
swept_repos=""
archived_repos=""
failed_repos=""
seen=""

report_unknown() { # <subject> <what failed>
  printf 'QUERY-UNKNOWN %s — %s\n' "$1" "$2"
  unknown=1
}

finish() {
  echo "CHECKED ${open_count} open advisor(ies) across ${swept} public repositor(ies); skipped ${archived_count} archived, ${private_count} private"
  finished=1
  [ "$unknown" -eq 0 ] || exit 2
  [ "$overdue" -eq 0 ] || exit 1
  exit 0
}

in_list() { # <line> <newline-separated list>
  grep -Fxq -- "$1" <<<"$2"
}

# Print every page of one GET as ONE JSON array, or fail. Each page must be an array and there must
# be at least one: an empty answer is not an empty list.
read_pages() { # <api path>
  local raw
  raw="$(gh api --paginate "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$raw" |
    jq -cse 'if length > 0 and all(.[]; type == "array") then add else error("not a page set") end' 2>/dev/null
}

ghsa_re='GHSA(-[23456789cfghjmpqrvwx]{4}){3}'

# One advisory from a filtered read -> "<id>\t<severity>\t<created epoch>", or MALFORMED. The state
# must be the one asked for: a filter the API ignored is a malformed read, not a different answer.
# shellcheck disable=SC2016 # jq program text; $state and $re are jq variables.
advisory_row='
  .[] |
  if (.ghsa_id | type) == "string" and (.ghsa_id | test("^" + $re + "$"))
     and .state == $state
     and (.created_at | type) == "string"
     and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
     and (.severity == null
          or ((.severity | type) == "string" and (.severity | test("^(critical|high|medium|low)$"))))
  then [.ghsa_id, (.severity // "unset"), (.created_at | fromdateiso8601 | floor | tostring)] | @tsv
  else "MALFORMED" end'

# One advisory from the control -> "<owner/repo> <id> <state>" for triage and draft, nothing for a
# published, closed or withdrawn one, and MALFORMED for anything else. The repository comes from the
# advisory's own API URL, whose id must match the advisory's.
# shellcheck disable=SC2016 # jq program text; $re is a jq variable.
control_row='
  .[] |
  if (.state | type) == "string" and (.state | test("^(triage|draft|published|closed|withdrawn)$"))
     and (.ghsa_id | type) == "string" and (.ghsa_id | test("^" + $re + "$"))
     and (.url | type) == "string"
     and (.url | test("/repos/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+/security-advisories/" + $re + "$"))
  then
    if .state == "triage" or .state == "draft" then
      (.url | capture("/repos/(?<repo>[^/]+/[^/]+)/security-advisories/(?<id>[^/]+)$")) as $u
      | if $u.id == .ghsa_id then [$u.repo, .ghsa_id, .state] | join(" ") else "MALFORMED" end
    else empty end
  else "MALFORMED" end'

sweep_state() { # <owner/repo> <triage|draft>
  local repo="$1" state="$2" page rows id severity created age_s window verdict
  if ! page="$(read_pages "repos/${repo}/security-advisories?state=${state}&per_page=100")"; then
    report_unknown "$repo" "the ${state} advisory read failed or returned a partial set of pages"
    failed_repos+="${repo}"$'\n'
    return 0
  fi
  if ! rows="$(printf '%s\n' "$page" | jq -r --arg state "$state" --arg re "$ghsa_re" "$advisory_row" 2>/dev/null)"; then
    report_unknown "$repo" "the ${state} advisory read did not parse"
    failed_repos+="${repo}"$'\n'
    return 0
  fi
  while IFS=$'\t' read -r id severity created; do
    [ -n "$id" ] || continue
    if [ "$id" = MALFORMED ]; then
      report_unknown "$repo" "a ${state} advisory had an unexpected shape, so it is not printed"
      failed_repos+="${repo}"$'\n'
      continue
    fi
    age_s=$((now - created))
    [ "$age_s" -ge 0 ] || age_s=0
    case "${state}:${severity}" in
      triage:*) window=3 ;;
      draft:medium | draft:low) window=90 ;;
      *) window=14 ;;
    esac
    if [ "$age_s" -gt $((window * 86400)) ]; then
      verdict=OVERDUE
      overdue=1
    else
      verdict=OPEN
    fi
    printf 'ADVISORY %s %s state=%s severity=%s age=%sd window=%sd %s\n' \
      "$repo" "$id" "$state" "$severity" "$((age_s / 86400))" "$window" "$verdict"
    open_count=$((open_count + 1))
    seen+="${repo} ${id} ${state}"$'\n'
  done <<EOF
$rows
EOF
}

# 1. Discovery.
if ! repos_json="$(read_pages "orgs/${org}/repos?type=all&per_page=100")"; then
  report_unknown "$org" "repository discovery failed or returned a partial set of pages"
  finish
fi
# shellcheck disable=SC2016 # jq program text; $org is a jq variable.
if ! repo_rows="$(printf '%s\n' "$repos_json" | jq -r --arg org "$org" '
  .[] |
  if (.full_name | type) == "string"
     and (.full_name | test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$"))
     and ((.full_name | split("/")[0] | ascii_downcase) == ($org | ascii_downcase))
     and (.archived | type) == "boolean" and (.private | type) == "boolean"
  then [.full_name, (if .archived then "archived" elif .private then "private" else "public" end)] | @tsv
  else "MALFORMED" end' 2>/dev/null)"; then
  report_unknown "$org" "repository discovery did not parse"
  finish
fi
if [ -z "$repo_rows" ]; then
  report_unknown "$org" "repository discovery returned no repositories"
  finish
fi
if in_list MALFORMED "$repo_rows"; then
  report_unknown "$org" "repository discovery returned a repository with an unexpected shape"
  finish
fi

# 2. The filtered reads.
while IFS=$'\t' read -r repo kind; do
  case "$kind" in
    archived)
      archived_count=$((archived_count + 1))
      archived_repos+="${repo}"$'\n'
      ;;
    private)
      private_count=$((private_count + 1))
      ;;
    *)
      swept=$((swept + 1))
      swept_repos+="${repo}"$'\n'
      sweep_state "$repo" triage
      sweep_state "$repo" draft
      ;;
  esac
done <<EOF
$repo_rows
EOF

# 3. The control.
if ! control="$(read_pages "orgs/${org}/security-advisories?per_page=100")"; then
  report_unknown "$org" "the control read of every advisory failed; it needs an organization owner or security manager"
  finish
fi
if ! control_rows="$(printf '%s\n' "$control" | jq -r --arg re "$ghsa_re" "$control_row" 2>/dev/null)"; then
  report_unknown "$org" "the control read did not parse"
  finish
fi
expected=""
while read -r repo id state; do
  [ -n "$repo" ] || continue
  if [ "$repo" = MALFORMED ]; then
    report_unknown "$org" "the control returned an advisory with an unexpected shape, so it is not printed"
    continue
  fi
  # Archived repositories are outside the census; a repository whose read already failed is UNKNOWN.
  if in_list "$repo" "$archived_repos" || in_list "$repo" "$failed_repos"; then
    continue
  fi
  if ! in_list "$repo" "$swept_repos"; then
    report_unknown "$repo" "the control lists ${id} as ${state} in a repository the sweep did not read"
    continue
  fi
  expected+="${repo} ${id} ${state}"$'\n'
  if ! in_list "${repo} ${id} ${state}" "$seen"; then
    report_unknown "$repo" "the control lists ${id} as ${state}, but the filtered read did not return it"
  fi
done <<EOF
$control_rows
EOF
while read -r repo id state; do
  [ -n "$repo" ] || continue
  in_list "$repo" "$failed_repos" && continue
  if ! in_list "${repo} ${id} ${state}" "$expected"; then
    report_unknown "$repo" "the filtered read returned ${id} as ${state}, but the control did not list it"
  fi
done <<EOF
$seen
EOF

finish
