#!/usr/bin/env bash
#
# Pins security-advisory-sweep.sh's verdict in all three directions (monorepo#4294).
#
#   exit 0  every open advisory is inside its window, confirmed by the control
#   exit 1  at least one OVERDUE advisory
#   exit 2  UNKNOWN — a failed, partial, malformed or unconfirmed read
#
# The cases that matter are the ones an obvious implementation gets wrong:
#
#   * A FAILED OR PARTIAL READ READING AS "NO REPORTS". `gh api --paginate` prints the pages it read
#     before a failed one and then exits non-zero, so a sweep that judged by output would pass.
#   * AN EMPTY FILTERED READ THAT NOBODY CONFIRMED. A reader without the right role gets published
#     advisories only, so the filtered reads come back empty. Only the control can tell.
#   * PRINTING ADVISORY TEXT. Every fixture carries a summary, description, reporter and credit that
#     contain CANARY; no case may ever print it, and a malformed id must not be echoed either.
#
# `gh` is stubbed, so this runs offline and deterministically. Each fixture is keyed on the exact API
# path the sweep asks for, and every call is logged so a case can assert what was NOT read.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sweep="$script_dir/security-advisory-sweep.sh"
scratch="$(mktemp -d)"
test_run_completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$scratch"
  if [ "${test_run_completed}" != 1 ]; then
    echo "security-advisory-sweep.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT

failures=0
assertions=0

# 2026-10-17T13:00:00Z
NOW=1792242000
DAY=86400

mkdir -p "$scratch/bin"
cat >"$scratch/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers `gh api --paginate <path>` from "$STUB_DIR/<key>.json", exiting with "<key>.rc" if present.
if [ "$#" -ne 3 ] || [ "$1" != api ] || [ "$2" != --paginate ]; then
  echo "stub gh: unexpected call: $*" >&2
  exit 97
fi
printf '%s\n' "$3" >>"$STUB_LOG"
key="$(printf '%s' "$3" | LC_ALL=C tr '/?&=' '____')"
if [ ! -f "$STUB_DIR/$key.json" ]; then
  echo "stub gh: no fixture for $3" >&2
  exit 98
fi
cat "$STUB_DIR/$key.json"
if [ -f "$STUB_DIR/$key.rc" ]; then
  exit "$(cat "$STUB_DIR/$key.rc")"
fi
exit 0
STUB
chmod +x "$scratch/bin/gh"

key_of() { printf '%s' "$1" | LC_ALL=C tr '/?&=' '____'; }

fixture() { # <api path> <body> [exit status]
  local key
  key="$(key_of "$1")"
  printf '%s' "$2" >"$scratch/stub/$key.json"
  if [ "$#" -ge 3 ]; then
    printf '%s\n' "$3" >"$scratch/stub/$key.rc"
  else
    rm -f "$scratch/stub/$key.rc"
  fi
}

iso_ago() { # <seconds before NOW>
  jq -nr --argjson t "$((NOW - $1))" '$t | todate'
}

adv() { # <owner/repo> <GHSA id> <state> <severity JSON: "\"high\"" or null> <seconds old>
  printf '{"ghsa_id":"%s","state":"%s","severity":%s,"created_at":"%s","url":"https://api.github.com/repos/%s/security-advisories/%s","summary":"CANARY-SUMMARY","description":"CANARY-DESCRIPTION","author":{"login":"CANARY-REPORTER"},"credits_detailed":[{"user":{"login":"CANARY-CREDIT"}}]}' \
    "$2" "$3" "$4" "$(iso_ago "$5")" "$1" "$2"
}

REPOS='orgs/devantler-tech/repos?type=all&per_page=100'
CONTROL='orgs/devantler-tech/security-advisories?per_page=100'
read_path() { printf 'repos/%s/security-advisories?state=%s&per_page=100' "$1" "$2"; }

KSAIL_DRAFT_ID='GHSA-g57x-rm7r-hf26'

# The baseline organization: two public repositories, one archived, one private. ksail holds one
# medium draft an hour old. The control also lists a published advisory (ignored by state) and a
# triage report in the archived repository (outside the census).
base_org() {
  rm -rf "$scratch/stub"
  mkdir -p "$scratch/stub"
  : >"$scratch/stub.log"
  fixture "$REPOS" '[{"full_name":"devantler-tech/ksail","archived":false,"private":false},{"full_name":"devantler-tech/site","archived":false,"private":false},{"full_name":"devantler-tech/old","archived":true,"private":false},{"full_name":"devantler-tech/secret","archived":false,"private":true}]'
  fixture "$(read_path devantler-tech/ksail triage)" '[]'
  fixture "$(read_path devantler-tech/ksail draft)" "[$(adv devantler-tech/ksail "$KSAIL_DRAFT_ID" draft '"medium"' 3600)]"
  fixture "$(read_path devantler-tech/site triage)" '[]'
  fixture "$(read_path devantler-tech/site draft)" '[]'
  fixture "$CONTROL" "[$(adv devantler-tech/ksail "$KSAIL_DRAFT_ID" draft '"medium"' 3600),$(adv devantler-tech/site GHSA-2345-6789-cfgh published '"low"' $((40 * DAY))),$(adv devantler-tech/old GHSA-jmpq-rvwx-2345 triage null $((9 * DAY)))]"
}

run_sweep() { # remaining args forwarded
  if OUT="$(PATH="$scratch/bin:$PATH" STUB_DIR="$scratch/stub" STUB_LOG="$scratch/stub.log" \
    /bin/bash "$sweep" "$@" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
}

show_output() { printf '%s\n' "$OUT" | sed 's/^/       | /'; }

assert_rc() { # <label> <expected>
  assertions=$((assertions + 1))
  if [ "$2" = "$RC" ]; then
    printf '  ok   %s (exit %s)\n' "$1" "$RC"
  else
    printf '  FAIL %s: expected exit %s, got %s\n' "$1" "$2" "$RC"
    show_output
    failures=$((failures + 1))
  fi
}

assert_contains() { # <label> <needle>
  assertions=$((assertions + 1))
  # A here-string, NOT a pipe: grep -q exits on first match and the resulting SIGPIPE would become
  # the pipeline status under pipefail.
  if grep -qF -- "$2" <<<"$OUT"; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s: output lacked %s\n' "$1" "$2"
    show_output
    failures=$((failures + 1))
  fi
}

assert_absent() { # <label> <needle>
  assertions=$((assertions + 1))
  if grep -qF -- "$2" <<<"$OUT"; then
    printf '  FAIL %s: output unexpectedly contained %s\n' "$1" "$2"
    show_output
    failures=$((failures + 1))
  else
    printf '  ok   %s\n' "$1"
  fi
}

assert_last_line() { # <label> <prefix>
  assertions=$((assertions + 1))
  local last
  last="$(printf '%s\n' "$OUT" | sed -n '$p')"
  case "$last" in
    "$2"*) printf '  ok   %s\n' "$1" ;;
    *)
      printf '  FAIL %s: last line was %s\n' "$1" "$last"
      failures=$((failures + 1))
      ;;
  esac
}

assert_read() { # <label> <yes|no> <api path>
  assertions=$((assertions + 1))
  local hit=no
  grep -qFx -- "$3" "$scratch/stub.log" && hit=yes
  if [ "$hit" = "$2" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s: expected read=%s for %s\n' "$1" "$2" "$3"
    sed 's/^/       log| /' "$scratch/stub.log"
    failures=$((failures + 1))
  fi
}

# Every case also proves no advisory text and no stub diagnostics leaked into the output.
assert_private() { # <label>
  assert_absent "$1: no advisory text printed" CANARY
  assert_absent "$1: every read had a fixture" "stub gh:"
}

echo "clean organization (exit 0)"
base_org
run_sweep --now "$NOW"
assert_rc "clean" 0
assert_contains "clean: the draft is listed by id, state, severity and age" \
  "ADVISORY devantler-tech/ksail ${KSAIL_DRAFT_ID} state=draft severity=medium age=0d window=90d OPEN"
assert_last_line "clean: CHECKED is the last line" \
  "CHECKED 1 open advisor(ies) across 2 public repositor(ies); skipped 1 archived, 1 private"
assert_absent "clean: the archived triage report is outside the census" GHSA-jmpq-rvwx-2345
assert_absent "clean: a published advisory is not open work" GHSA-2345-6789-cfgh
assert_read "clean: the private repository is never read" no "$(read_path devantler-tech/secret triage)"
assert_read "clean: the archived repository is never read" no "$(read_path devantler-tech/old triage)"
assert_read "clean: the control was read" yes "$CONTROL"
assert_private "clean"

echo "windows (exit 1 on any overdue advisory; NOW is a Saturday)"
base_org
fixture "$(read_path devantler-tech/site triage)" \
  "[$(adv devantler-tech/site GHSA-cccc-2222-xxxx triage null $((5 * DAY))),$(adv devantler-tech/site GHSA-cccc-3333-xxxx triage '"high"' $((2 * DAY)))]"
fixture "$(read_path devantler-tech/site draft)" \
  "[$(adv devantler-tech/site GHSA-ffff-2222-xxxx draft '"critical"' $((15 * DAY))),$(adv devantler-tech/site GHSA-ffff-3333-xxxx draft '"low"' $((89 * DAY))),$(adv devantler-tech/site GHSA-ffff-4444-xxxx draft null $((15 * DAY)))]"
fixture "$CONTROL" "[$(adv devantler-tech/ksail "$KSAIL_DRAFT_ID" draft '"medium"' 3600),$(adv devantler-tech/site GHSA-cccc-2222-xxxx triage null 1),$(adv devantler-tech/site GHSA-cccc-3333-xxxx triage null 1),$(adv devantler-tech/site GHSA-ffff-2222-xxxx draft null 1),$(adv devantler-tech/site GHSA-ffff-3333-xxxx draft null 1),$(adv devantler-tech/site GHSA-ffff-4444-xxxx draft null 1)]"
run_sweep --now "$NOW"
assert_rc "windows" 1
assert_contains "a Monday report is overdue by Saturday (its third weekday was Thursday)" \
  "GHSA-cccc-2222-xxxx state=triage severity=unset age=5d window=3bd OVERDUE"
assert_contains "a Thursday report is still open on Saturday" \
  "GHSA-cccc-3333-xxxx state=triage severity=high age=2d window=3bd OPEN"
assert_contains "a critical draft past 14 days is overdue" \
  "GHSA-ffff-2222-xxxx state=draft severity=critical age=15d window=14d OVERDUE"
assert_contains "a low draft inside 90 days is open" \
  "GHSA-ffff-3333-xxxx state=draft severity=low age=89d window=90d OPEN"
assert_contains "a draft with no severity is held to 14 days" \
  "GHSA-ffff-4444-xxxx state=draft severity=unset age=15d window=14d OVERDUE"
assert_last_line "windows: CHECKED counts every open advisory" "CHECKED 6 open advisor(ies)"
assert_private "windows"

# Only site holds triage reports in the next two runs; the control lists the same set.
site_triage_only() { # <advisory JSON>...
  local list
  list="$(IFS=,; printf '%s' "$*")"
  base_org
  fixture "$(read_path devantler-tech/site triage)" "[${list}]"
  fixture "$CONTROL" "[$(adv devantler-tech/ksail "$KSAIL_DRAFT_ID" draft '"medium"' 3600),${list}]"
}

echo "a weekend does not count toward the three business days"
# Friday 12:00 to Monday 13:00 is more than three calendar days but one business day.
site_triage_only "$(adv devantler-tech/site GHSA-cccc-4444-xxxx triage null $((DAY + 3600)))"
run_sweep --now "$((NOW + 2 * DAY))"
assert_rc "weekend" 0
assert_contains "a Friday report is open on Monday" \
  "GHSA-cccc-4444-xxxx state=triage severity=unset age=3d window=3bd OPEN"
assert_private "weekend"

echo "the business-day deadline is exact to the second"
# The sweep runs on Thursday 13:00; both reports came in on Monday, at 13:00 and one second earlier.
site_triage_only "$(adv devantler-tech/site GHSA-cccc-5555-xxxx triage null $((5 * DAY)))" \
  "$(adv devantler-tech/site GHSA-cccc-6666-xxxx triage null $((5 * DAY + 1)))"
run_sweep --now "$((NOW - 2 * DAY))"
assert_rc "deadline boundary" 1
assert_contains "a report exactly at its deadline is still open" \
  "GHSA-cccc-5555-xxxx state=triage severity=unset age=3d window=3bd OPEN"
assert_contains "a report one second past its deadline is overdue" \
  "GHSA-cccc-6666-xxxx state=triage severity=unset age=3d window=3bd OVERDUE"
assert_private "deadline boundary"

echo "negative control: a failed read (exit 2, never no reports)"
base_org
fixture "$(read_path devantler-tech/site triage)" '{"message":"Server Error"}' 1
run_sweep --now "$NOW"
assert_rc "failed read" 2
assert_contains "failed read: names the repository and state" \
  "QUERY-UNKNOWN devantler-tech/site — the triage advisory read failed"
assert_contains "failed read: the other repository is still reported" "ADVISORY devantler-tech/ksail ${KSAIL_DRAFT_ID}"
assert_last_line "failed read: CHECKED is still the last line" "CHECKED "
assert_private "failed read"

echo "negative control: a partial page set (gh printed a page, then failed)"
base_org
fixture "$(read_path devantler-tech/ksail draft)" "[$(adv devantler-tech/ksail "$KSAIL_DRAFT_ID" draft '"medium"' 3600)]" 1
run_sweep --now "$NOW"
assert_rc "partial advisory pages" 2
assert_contains "partial advisory pages: reported as a partial read" \
  "QUERY-UNKNOWN devantler-tech/ksail — the draft advisory read failed or returned a partial set of pages"
assert_absent "partial advisory pages: the half-read advisory is not reported as found" "ADVISORY devantler-tech/ksail"
assert_private "partial advisory pages"

base_org
fixture "$REPOS" '[{"full_name":"devantler-tech/ksail","archived":false,"private":false}]' 1
run_sweep --now "$NOW"
assert_rc "partial discovery" 2
assert_contains "partial discovery: reported" \
  "QUERY-UNKNOWN devantler-tech — repository discovery failed or returned a partial set of pages"
assert_read "partial discovery: no advisory is read from a partial repository list" no \
  "$(read_path devantler-tech/ksail triage)"
assert_private "partial discovery"

base_org
fixture "$(read_path devantler-tech/site draft)" '[][{"ghsa_id":"GHSA-g57x'
run_sweep --now "$NOW"
assert_rc "truncated page" 2
assert_contains "truncated page: reported" "QUERY-UNKNOWN devantler-tech/site — the draft advisory read failed"
assert_private "truncated page"

base_org
fixture "$(read_path devantler-tech/site triage)" ''
run_sweep --now "$NOW"
assert_rc "empty answer" 2
assert_contains "empty answer: an empty answer is not an empty list" "QUERY-UNKNOWN devantler-tech/site"
assert_private "empty answer"

base_org
fixture "$REPOS" '[]'
run_sweep --now "$NOW"
assert_rc "no repositories" 2
assert_contains "no repositories: reported" "QUERY-UNKNOWN devantler-tech — repository discovery returned no repositories"
assert_private "no repositories"

echo "negative control: an empty filtered read the control does not confirm"
base_org
fixture "$CONTROL" "[$(adv devantler-tech/ksail "$KSAIL_DRAFT_ID" draft '"medium"' 3600),$(adv devantler-tech/site GHSA-hhhh-2222-xxxx triage null $((1 * DAY)))]"
run_sweep --now "$NOW"
assert_rc "unconfirmed empty read" 2
assert_contains "unconfirmed empty read: names the advisory the filtered read missed" \
  "QUERY-UNKNOWN devantler-tech/site — the control lists GHSA-hhhh-2222-xxxx as triage, but the filtered read did not return it"
assert_private "unconfirmed empty read"

base_org
fixture "$CONTROL" '[]'
run_sweep --now "$NOW"
assert_rc "control missing a filtered advisory" 2
assert_contains "control missing a filtered advisory: reported" \
  "the filtered read returned ${KSAIL_DRAFT_ID} as draft, but the control did not list it"
assert_private "control missing a filtered advisory"

base_org
fixture "$CONTROL" '{"message":"Must be an organization owner or security manager"}' 1
run_sweep --now "$NOW"
assert_rc "control refused" 2
assert_contains "control refused: reported" "QUERY-UNKNOWN devantler-tech — the control read of every advisory failed"
assert_private "control refused"

base_org
fixture "$CONTROL" "[$(adv devantler-tech/elsewhere GHSA-hhhh-3333-xxxx triage null 60)]"
run_sweep --now "$NOW"
assert_rc "control lists an unswept repository" 2
assert_contains "control lists an unswept repository: reported" \
  "QUERY-UNKNOWN devantler-tech/elsewhere — the control lists GHSA-hhhh-3333-xxxx as triage in a repository the sweep did not read"
assert_private "control lists an unswept repository"

echo "negative control: malformed advisories are UNKNOWN and never echoed"
base_org
fixture "$(read_path devantler-tech/site triage)" \
  '[{"ghsa_id":"CANARY-ID","state":"triage","severity":null,"created_at":"2026-10-17T12:00:00Z","summary":"CANARY-SUMMARY"}]'
run_sweep --now "$NOW"
assert_rc "malformed id" 2
assert_contains "malformed id: reported without the value" \
  "QUERY-UNKNOWN devantler-tech/site — a triage advisory had an unexpected shape, so it is not printed"
assert_private "malformed id"

base_org
fixture "$(read_path devantler-tech/site triage)" "[$(adv devantler-tech/site GHSA-mmmm-2222-xxxx draft '"low"' 60)]"
run_sweep --now "$NOW"
assert_rc "filter ignored" 2
assert_contains "filter ignored: a draft in the triage read is a malformed read" \
  "QUERY-UNKNOWN devantler-tech/site — a triage advisory had an unexpected shape"
assert_absent "filter ignored: the advisory is not printed" GHSA-mmmm-2222-xxxx
assert_private "filter ignored"

base_org
fixture "$(read_path devantler-tech/site draft)" "[$(adv devantler-tech/site GHSA-mmmm-3333-xxxx draft '"severe"' 60)]"
run_sweep --now "$NOW"
assert_rc "unknown severity" 2
assert_absent "unknown severity: the advisory is not printed" GHSA-mmmm-3333-xxxx
assert_private "unknown severity"

base_org
fixture "$REPOS" '[{"full_name":"someone-else/ksail","archived":false,"private":false}]'
run_sweep --now "$NOW"
assert_rc "foreign repository in discovery" 2
assert_contains "foreign repository in discovery: reported" \
  "repository discovery returned a repository with an unexpected shape"
assert_private "foreign repository in discovery"

echo "usage"
base_org
run_sweep --bogus
assert_rc "unknown flag" 2
run_sweep --now yesterday
assert_rc "non-numeric --now" 2
run_sweep --org 'devantler-tech/../x'
assert_rc "an --org that is not a login" 2
assert_read "usage errors read nothing" no "$REPOS"

echo
echo "${assertions} assertions, ${failures} failure(s)"
test_run_completed=1
[ "$failures" -eq 0 ]
