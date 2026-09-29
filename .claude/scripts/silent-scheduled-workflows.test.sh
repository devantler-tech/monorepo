#!/usr/bin/env bash
# RED/GREEN coverage for silent-scheduled-workflows.sh (monorepo#2928) against a stub gh:
# a dispatch-only workflow with an old failing run is NOT reported, while a scheduled workflow with
# the same history IS; plus pagination, the manual-disable and missing-file skips, GitHub's
# inactivity disable, offset timestamps, and every failed read reported as UNKNOWN.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$root/.claude/scripts/silent-scheduled-workflows.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "silent-scheduled-workflows test: $*" >&2; exit 1; }

now=1790000000 # 2026-09-21T13:33:20Z
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
h=3600
d=$((24 * h))

fix="$tmp/fix"
bin="$tmp/bin"
mkdir -p "$fix" "$bin"
cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
# Serve fixtures keyed by the request path; honour --jq by running it through jq, as gh does.
# `-f k=v` fields become the query string in the order given, as `--method GET` sends them.
args=("$@"); jqexpr=""; url=""; query=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jqexpr="${args[i + 1]}"; i=$((i + 1)) ;;
    --method | -H) i=$((i + 1)) ;;
    -f) query="${query:+$query&}${args[i + 1]}"; i=$((i + 1)) ;;
    api | --paginate) ;;
    *) url="${args[i]}" ;;
  esac
done
# A branch name comes from the API and may hold URL metacharacters: it must travel as an encoded
# field, never spliced into the URL.
case "$url" in *"ref="* | *"sha="*) echo "gh stub: branch spliced into the URL: $url" >&2; exit 1 ;; esac
[ -z "$query" ] || url="$url?$query"
[ -n "${FAIL_ON:-}" ] && [[ "$url" == *"$FAIL_ON"* ]] && { echo "gh: HTTP 502" >&2; exit 1; }
# The window start (`until=`) depends on each workflow's cron, so fixtures key on its presence only.
key="$(printf '%s' "$url" | sed 's/until=[^&]*/until/' | tr '/?&=' '____')"
f="$FIXTURES/$key.json"
# The default branch's workflow directory lists every workflow file that has a content fixture at
# `ref=main`, unless a test supplies the listing itself.
if [ ! -f "$f" ] && [[ "$url" =~ ^repos/([^/]+/[^/]+)/contents/\.github/workflows\?ref=main$ ]]; then
  prefix="$(printf '%s' "repos/${BASH_REMATCH[1]}/contents/.github/workflows/" | tr '/?&=' '____')"
  for g in "$FIXTURES/$prefix"*_ref_main.json; do
    [ -e "$g" ] || continue
    name="${g##*/}"; name="${name#"$prefix"}"; name="${name%_ref_main.json}"
    printf '%s\n' ".github/workflows/${name//%23/#}"
  done | jq -R '{type: "file", path: .}' | jq -s . >"$FIXTURES/.synth.json"
  f="$FIXTURES/.synth.json"
fi
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$f"; else cat "$f"; fi
STUB
chmod +x "$bin/gh"

put() { printf '%s' "$2" >"$fix/$(printf '%s' "$1" | tr '/?&=' '____').json"; }
workflow_file() { # <repo> <path> <yaml> [<yaml at the window start, or NONE if the file was new>]
  put "repos/$1/contents/$2?ref=main" "$3" # raw media type: the file itself
  if [ "${4-}" = NONE ]; then
    put "repos/$1/commits?path=$2&sha=main&until&per_page=1" '[]'
  else
    put "repos/$1/commits?path=$2&sha=main&until&per_page=1" '[{"sha":"b4f0e1ab"}]'
    put "repos/$1/contents/$2?ref=b4f0e1ab" "${4:-$3}"
  fi
}
runs() { # <repo> <id> <page> <event:epoch>...
  local repo="$1" id="$2" page="$3" rows="" e t
  shift 3
  for r in "$@"; do
    e="${r%%:*}"; t="${r#*:}"
    rows="${rows:+$rows,}{\"event\":\"$e\",\"created_at\":\"$(iso "$t")\"}"
  done
  local total="${RUNS_TOTAL:-$(((page - 1) * 100 + $#))}" # every page of one listing reports the same total
  put "repos/$repo/actions/workflows/$id/runs?per_page=100&page=$page" "{\"total_count\":${total},\"workflow_runs\":[${rows}]}"
}

# Repository o/a — every shape the checker must decide.
old="2026-01-01T10:00:00.000+02:00" # the offset form GitHub actually returns for workflows
put "repos/o/a" '{"default_branch":"main"}'
put "repos/o/a/actions/workflows?per_page=100" "{\"total_count\":11,\"workflows\":[
  {\"id\":11,\"state\":\"active\",\"path\":\".github/workflows/moved.yaml\",\"created_at\":\"$old\"},
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"},
  {\"id\":2,\"state\":\"active\",\"path\":\".github/workflows/dispatch.yaml\",\"created_at\":\"$old\"},
  {\"id\":3,\"state\":\"active\",\"path\":\".github/workflows/stale.yaml\",\"created_at\":\"$old\"},
  {\"id\":4,\"state\":\"disabled_manually\",\"path\":\".github/workflows/off.yaml\",\"created_at\":\"$old\"},
  {\"id\":5,\"state\":\"disabled_inactivity\",\"path\":\".github/workflows/inactive.yaml\",\"created_at\":\"$old\"},
  {\"id\":6,\"state\":\"active\",\"path\":\".github/workflows/gone.yaml\",\"created_at\":\"$old\"},
  {\"id\":7,\"state\":\"active\",\"path\":\".github/workflows/monthly.yaml\",\"created_at\":\"$old\"},
  {\"id\":9,\"state\":\"active\",\"path\":\".github/workflows/leap.yaml\",\"created_at\":\"2019-01-01T00:00:00.000+02:00\"},
  {\"id\":10,\"state\":\"active\",\"path\":\".github/workflows/gained.yaml\",\"created_at\":\"$old\"},
  {\"id\":8,\"state\":\"active\",\"path\":\"dynamic/github-code-scanning/codeql\",\"created_at\":\"$old\"}
]}"
daily='on:
  schedule:
    - cron: "17 6 * * *"
  workflow_dispatch: {}'
workflow_file o/a .github/workflows/daily.yaml "$daily"
runs o/a 1 1 "schedule:$((now - 10 * h))"
# Dispatch-only, with an old failing run and 40 days of silence: a decision, not breakage.
workflow_file o/a .github/workflows/dispatch.yaml 'on:
  workflow_dispatch: {}'
runs o/a 2 1 "workflow_dispatch:$((now - 40 * d))"
# The SAME history on a daily schedule: this silence is breakage.
workflow_file o/a .github/workflows/stale.yaml "$daily"
runs o/a 3 1 "schedule:$((now - 40 * d))"
workflow_file o/a .github/workflows/off.yaml "$daily"
workflow_file o/a .github/workflows/inactive.yaml "$daily"
# gone.yaml has no file on the default branch (404): it cannot fire a schedule.
# Monthly: page 1 holds only recent push runs, the schedule run is on page 2.
workflow_file o/a .github/workflows/monthly.yaml 'on:
  schedule:
    - cron: "3 2 1 * *"'
# A full first page (per_page=100) of newer push runs, as the API would really return it.
page1=()
for ((i = 1; i <= 100; i++)); do page1+=("push:$((now - i * h))"); done
RUNS_TOTAL=101 runs o/a 7 1 "${page1[@]}"
RUNS_TOTAL=101 runs o/a 7 2 "schedule:$((now - 20 * d))"
# 29 February fires only in leap years: three years of silence is not a stopped schedule.
workflow_file o/a .github/workflows/leap.yaml 'on:
  schedule:
    - cron: "0 0 29 2 *"'
runs o/a 9 1 "schedule:$((now - 3 * 365 * d))"
# An old dispatch-only workflow that GAINED a daily schedule inside the window: not yet due.
workflow_file o/a .github/workflows/gained.yaml "$daily" 'on:
  workflow_dispatch: {}'
runs o/a 10 1 "workflow_dispatch:$((now - 40 * d))"
# A file with no commit before the window (added or moved there recently) is new: not yet due.
workflow_file o/a .github/workflows/moved.yaml "$daily" NONE
runs o/a 11 1 "workflow_dispatch:$((now - 40 * d))"

run() { set +e; PATH="$bin:$PATH" FIXTURES="$fix" "$checker" "$@" --now "$now" >"$tmp/out" 2>"$tmp/err"; rc=$?; set -e; }
has() { grep -qxF -- "$1" "$tmp/out" || { cat "$tmp/out" "$tmp/err" >&2; fail "$2"; }; }
lacks() { ! grep -qF -- "$1" "$tmp/out" || { cat "$tmp/out" >&2; fail "$2"; }; }

run --repo o/a
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "silent schedules must exit 1, got $rc"; }
has "SILENT-WORKFLOW o/a .github/workflows/stale.yaml — no scheduled run in the last 97h (its cron fires at least every 1d)" \
  "a daily schedule silent for 40 days must be reported"
lacks "dispatch.yaml" "a dispatch-only workflow's silence must never be reported"
has "SILENT-WORKFLOW o/a .github/workflows/inactive.yaml — schedule disabled by GitHub for repository inactivity" \
  "GitHub's inactivity disable must be reported"
lacks "off.yaml" "a manually disabled workflow is a recorded decision, not a finding"
lacks "gone.yaml" "a workflow whose file left the default branch cannot fire and must be skipped"
lacks "daily.yaml" "a schedule that ran 10h ago is healthy"
lacks "monthly.yaml" "a schedule run on the second page must be found"
lacks "codeql" "a dynamic GitHub-managed workflow is out of scope"
lacks "leap.yaml" "a 29 February schedule silent for three years is not stopped"
lacks "gained.yaml" "a schedule added 10h ago to an old workflow is not yet due"
lacks "moved.yaml" "a file with no commit before the window is new, not silent"
has "CHECKED 7 scheduled workflow(s) across 1 repositor(ies)" "the summary must count what was examined"
[ "$(grep -c '^SILENT-WORKFLOW' "$tmp/out")" -eq 2 ] || fail "exactly two findings expected"

# A failed run-list read is UNKNOWN — never "silent", never clean.
FAIL_ON="workflows/3/runs" run --repo o/a
[ "$rc" -eq 2 ] || fail "a failed run read must exit 2, got $rc"
has "QUERY-UNKNOWN o/a .github/workflows/stale.yaml — run list read failed" "a failed run read must be named"

# A failed workflow-file read that is not a 404 is UNKNOWN, not a skip.
FAIL_ON="contents/.github/workflows/daily.yaml" run --repo o/a
[ "$rc" -eq 2 ] || fail "a failed file read must exit 2, got $rc"
has "QUERY-UNKNOWN o/a .github/workflows/daily.yaml — workflow file read failed" "a failed file read must be named"

# A failed repository listing is UNKNOWN and still prints the summary.
FAIL_ON="actions/workflows?per_page" run --repo o/a
[ "$rc" -eq 2 ] || fail "a failed workflow list must exit 2, got $rc"
has "QUERY-UNKNOWN o/a — workflow list read failed" "a failed workflow list must be named"
has "CHECKED 0 scheduled workflow(s) across 0 repositor(ies)" "the summary must not claim a repository it never read"

# An unparseable creation time is UNKNOWN, not "too new to judge".
put "repos/o/b" '{"default_branch":"main"}'
put "repos/o/b/actions/workflows?per_page=100" '{"total_count":1,"workflows":[
  {"id":9,"state":"active","path":".github/workflows/daily.yaml","created_at":"yesterday"}]}'
workflow_file o/b .github/workflows/daily.yaml "$daily"
run --repo o/b
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an unparseable timestamp must exit 2, got $rc"; }

# A healthy repository exits 0.
put "repos/o/c" '{"default_branch":"main"}'
put "repos/o/c/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/c .github/workflows/daily.yaml "$daily"
runs o/c 1 1 "schedule:$((now - 3 * h))"
run --repo o/c
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a healthy repository must exit 0, got $rc"; }
has "CHECKED 1 scheduled workflow(s) across 1 repositor(ies)" "healthy summary"

# Only a February-ONLY day-29 schedule skips years: 31 January fires every year, and `29 2,3`
# fires every March, so four years of silence is a stop for both.
put "repos/o/d" '{"default_branch":"main"}'
put "repos/o/d/actions/workflows?per_page=100" '{"total_count":3,"workflows":[
  {"id":1,"state":"active","path":".github/workflows/annual.yaml","created_at":"2019-01-01T00:00:00.000+02:00"},
  {"id":2,"state":"active","path":".github/workflows/febmar.yaml","created_at":"2019-01-01T00:00:00.000+02:00"},
  {"id":3,"state":"active","path":".github/workflows/feb1and29.yaml","created_at":"2019-01-01T00:00:00.000+02:00"}]}'
# annual.yaml's file was edited recently (a pin bump, say) but its schedule was not: the fixture's
# window-start content equals today's, so the silence is judged rather than excused.
workflow_file o/d .github/workflows/annual.yaml 'on:
  schedule:
    - cron: "0 0 31 1 *"
jobs: {}'
put "repos/o/d/contents/.github/workflows/annual.yaml?ref=b4f0e1ab" 'on:
  schedule:
    - cron: "0 0 31 1 *"
jobs: {old: {}}'
runs o/d 1 1 "schedule:$((now - 4 * 366 * d))"
workflow_file o/d .github/workflows/febmar.yaml 'on:
  schedule:
    - cron: "0 0 29 2,3 *"'
runs o/d 2 1 "schedule:$((now - 4 * 366 * d))"
workflow_file o/d .github/workflows/feb1and29.yaml 'on:
  schedule:
    - cron: "0 0 1,29 2 *"'
runs o/d 3 1 "schedule:$((now - 4 * 366 * d))"
run --repo o/d
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "annual schedules silent for four years must be reported, got $rc"; }
grep -qF "annual.yaml" "$tmp/out" || fail "a 31 January schedule silent for four years must be reported, even after an unrelated edit"
grep -qF "febmar.yaml" "$tmp/out" || fail "a 29 Feb/March schedule silent for four years must be reported"
grep -qF "feb1and29.yaml" "$tmp/out" || fail "a 1 and 29 February schedule silent for four years must be reported"

# A restricted weekday makes `29 2 1` fire every Monday in February too: no multi-year gap. And a
# workflow GitHub disabled because the repository is a fork is a policy, not a stopped schedule.
put "repos/o/h" '{"default_branch":"main"}'
put "repos/o/h/actions/workflows?per_page=100" '{"total_count":2,"workflows":[
  {"id":1,"state":"active","path":".github/workflows/febmon.yaml","created_at":"2019-01-01T00:00:00.000+02:00"},
  {"id":2,"state":"disabled_fork","path":".github/workflows/forked.yaml","created_at":"2019-01-01T00:00:00.000+02:00"}]}'
workflow_file o/h .github/workflows/febmon.yaml 'on:
  schedule:
    - cron: "0 0 29 2 1"'
runs o/h 1 1 "schedule:$((now - 4 * 366 * d))"
workflow_file o/h .github/workflows/forked.yaml "$daily"
run --repo o/h
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a February-Mondays schedule silent for four years must be reported, got $rc"; }
grep -qF "febmon.yaml" "$tmp/out" || fail "a restricted weekday must not get the leap-year gap"
lacks "forked.yaml" "a fork-disabled workflow is a policy, not a finding"

# A non-empty page shorter than its total implies is a partial payload: UNKNOWN, not silence.
put "repos/o/i" '{"default_branch":"main"}'
put "repos/o/i/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/i .github/workflows/daily.yaml "$daily"
put "repos/o/i/actions/workflows/1/runs?per_page=100&page=1" \
  "{\"total_count\":5,\"workflow_runs\":[{\"event\":\"push\",\"created_at\":\"$(iso $((now - 40 * d)))\"}]}"
run --repo o/i
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a short non-empty run page must exit 2, got $rc"; }

# A malformed history payload must not grant the new-file grace.
put "repos/o/j" '{"default_branch":"main"}'
put "repos/o/j/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/j .github/workflows/daily.yaml "$daily"
put "repos/o/j/commits?path=.github/workflows/daily.yaml&sha=main&until&per_page=1" '[{"sha":null}]'
runs o/j 1 1 "schedule:$((now - 40 * d))"
run --repo o/j
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed history payload must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/j .github/workflows/daily.yaml — history at the window start unreadable" \
  "a malformed history payload must be named"

# The gap is computed, not guessed from spelling: `* 1-12 *` is every day, so 40 days is a stop.
put "repos/o/k" '{"default_branch":"main"}'
put "repos/o/k/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/range.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/k .github/workflows/range.yaml 'on:
  schedule:
    - cron: "0 0 * 1-12 *"'
runs o/k 1 1 "schedule:$((now - 40 * d))"
run --repo o/k
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a daily schedule spelled with a month range must be judged daily, got $rc"; }

# A cron that can never fire (31 February) is UNKNOWN, not a years-long grace.
workflow_file o/k .github/workflows/range.yaml 'on:
  schedule:
    - cron: "0 0 31 2 *"'
run --repo o/k
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a never-firing cron must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/k .github/workflows/range.yaml — schedule '0 0 31 2 *' unparseable or never fires" \
  "a never-firing cron must be named"

# A null default branch, or a malformed workflow record, is UNKNOWN — never a clean skip.
put "repos/o/l" '{"default_branch":null}'
run --repo o/l
[ "$rc" -eq 2 ] || fail "a null default branch must exit 2, got $rc"
has "QUERY-UNKNOWN o/l — default branch read failed" "a null default branch must be named"
put "repos/o/m" '{"default_branch":"main"}'
put "repos/o/m/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":null,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
run --repo o/m
[ "$rc" -eq 2 ] || fail "a malformed workflow record must exit 2, got $rc"
has "QUERY-UNKNOWN o/m — workflow list holds a malformed record" "a malformed record must be named"

# A window-start version that cannot be parsed is UNKNOWN, never the new-schedule grace.
put "repos/o/n" '{"default_branch":"main"}'
put "repos/o/n/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/n .github/workflows/daily.yaml "$daily" 'on: [unclosed'
runs o/n 1 1 "schedule:$((now - 40 * d))"
run --repo o/n
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an unparseable window-start version must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/n .github/workflows/daily.yaml — file at the window start unparseable" \
  "an unparseable window-start version must be named"

# An EMPTY window-start body parses as "no schedule", so it too must be UNKNOWN, never the grace.
workflow_file o/n .github/workflows/daily.yaml "$daily"
put "repos/o/n/contents/.github/workflows/daily.yaml?ref=b4f0e1ab" ''
run --repo o/n
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an empty window-start body must exit 2, got $rc"; }

# A run record whose event is not a string is malformed data: UNKNOWN, never a silence verdict.
put "repos/o/n/actions/workflows/1/runs?per_page=100&page=1" \
  "{\"total_count\":1,\"workflow_runs\":[{\"event\":5,\"created_at\":\"$(iso $((now - 40 * d)))\"}]}"
workflow_file o/n .github/workflows/daily.yaml "$daily"
run --repo o/n
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed run record must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/n .github/workflows/daily.yaml — run list read failed" "a malformed run record must be named"

# Two annual lines (1 January + 1 July) fire every six months: 13 months of silence is a stop.
put "repos/o/r" '{"default_branch":"main"}'
put "repos/o/r/actions/workflows?per_page=100" '{"total_count":1,"workflows":[
  {"id":1,"state":"active","path":".github/workflows/halfyear.yaml","created_at":"2019-01-01T00:00:00.000+02:00"}]}'
workflow_file o/r .github/workflows/halfyear.yaml 'on:
  schedule:
    - cron: "0 0 1 1 *"
    - cron: "0 0 1 7 *"'
runs o/r 1 1 "schedule:$((now - 400 * d))"
run --repo o/r
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a six-monthly union silent for 400 days must be reported, got $rc"; }

# An unrecognised workflow state is never assumed active: UNKNOWN.
put "repos/o/s" '{"default_branch":"main"}'
put "repos/o/s/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"disabled_someday\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/s .github/workflows/daily.yaml "$daily"
runs o/s 1 1 "schedule:$((now - 40 * d))"
run --repo o/s
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an unknown workflow state must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/s .github/workflows/daily.yaml — unrecognised workflow state 'disabled_someday'" "an unknown state must be named"

# A file the directory lists but whose content 404s (e.g. a token without contents access) is
# UNKNOWN, not "removed"; an unreadable directory makes every workflow UNKNOWN.
put "repos/o/t" '{"default_branch":"main"}'
put "repos/o/t/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/hidden.yaml\",\"created_at\":\"$old\"}]}"
put "repos/o/t/contents/.github/workflows?ref=main" '[{"type":"file","path":".github/workflows/hidden.yaml"}]'
run --repo o/t
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a listed but unreadable file must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/t .github/workflows/hidden.yaml — workflow file read failed" "a listed but unreadable file must be named"
put "repos/o/t/contents/.github/workflows?ref=main" '{"message":"Not Found"}'
run --repo o/t
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an unreadable workflow directory must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/t .github/workflows/hidden.yaml — workflow directory on the default branch unreadable" \
  "an unreadable workflow directory must be named"

# A malformed directory entry would make every listed file look removed: the listing is UNKNOWN.
put "repos/o/t/contents/.github/workflows?ref=main" '[{"type":"file","path":null}]'
run --repo o/t
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed directory entry must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/t .github/workflows/hidden.yaml — workflow directory on the default branch unreadable" \
  "a malformed directory entry must make the directory unreadable"

# GitHub's documented `deleted` state is a removed workflow: skipped, not UNKNOWN.
put "repos/o/u" '{"default_branch":"main"}'
put "repos/o/u/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"deleted\",\"path\":\".github/workflows/gone.yaml\",\"created_at\":\"$old\"}]}"
put "repos/o/u/contents/.github/workflows?ref=main" '[]'
run --repo o/u
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a deleted workflow must be skipped, got $rc"; }

# A timestamp with trailing garbage must not parse as its valid-looking prefix: UNKNOWN.
put "repos/o/v" '{"default_branch":"main"}'
put "repos/o/v/actions/workflows?per_page=100" '{"total_count":1,"workflows":[
  {"id":1,"state":"active","path":".github/workflows/daily.yaml","created_at":"2026-09-21T00:00:00garbage"}]}'
workflow_file o/v .github/workflows/daily.yaml "$daily"
run --repo o/v
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed timestamp must exit 2, got $rc"; }

# An out-of-range UTC offset is malformed, not a 100-hour shift: UNKNOWN.
runs o/v 1 1 "schedule:$((now - 3 * h))"
put "repos/o/v/actions/workflows?per_page=100" '{"total_count":1,"workflows":[
  {"id":1,"state":"active","path":".github/workflows/daily.yaml","created_at":"2026-01-01T00:00:00.000+99:99"}]}'
run --repo o/v
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an out-of-range offset must exit 2, got $rc"; }

# A temporary-file failure before the EXIT trap exists is UNKNOWN, never exit 1 (a finding).
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/mktemp"
chmod +x "$bin/mktemp"
set +e
PATH="$bin:$PATH" FIXTURES="$fix" "$checker" --repo o/c --now "$now" >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
rm -f "$bin/mktemp"
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a mktemp failure must exit 2, got $rc"; }

# An impossible calendar date (31 February) is malformed, not 3 March: UNKNOWN.
put "repos/o/v/actions/workflows?per_page=100" '{"total_count":1,"workflows":[
  {"id":1,"state":"active","path":".github/workflows/daily.yaml","created_at":"2026-02-31T00:00:00Z"}]}'
run --repo o/v
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an impossible calendar date must exit 2, got $rc"; }

# A path holding a backslash would be escaped by @tsv and then never match the listing: UNKNOWN.
put "repos/o/v/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/a\\\\\\\\b.yaml\",\"created_at\":\"$old\"}]}"
run --repo o/v
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a backslash in a workflow path must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/v — workflow list holds a malformed record" "a backslash path must be a malformed record"

# `*/1` in the day-of-month field is star-derived, so the weekday alone decides: `*/1 * MON` is weekly,
# and a Monday schedule last seen 5 days ago is not silent.
put "repos/o/x" '{"default_branch":"main"}'
put "repos/o/x/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/weekly.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/x .github/workflows/weekly.yaml 'on:
  schedule:
    - cron: "0 0 */1 * MON"'
runs o/x 1 1 "schedule:$((now - 5 * d))"
run --repo o/x
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a star-derived day-of-month must leave the weekday in control, got $rc"; }

# A directory listing at the Contents API's 1,000-entry cap may be truncated: absence proves nothing.
put "repos/o/w" '{"default_branch":"main"}'
put "repos/o/w/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/zz.yaml\",\"created_at\":\"$old\"}]}"
jq -n '[range(0; 1000) | {type: "file", path: ".github/workflows/w\(.).yaml"}]' >"$fix/$(printf '%s' 'repos/o/w/contents/.github/workflows?ref=main' | tr '/?&=' '____').json"
run --repo o/w
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a capped directory listing must exit 2, got $rc"; }

# An empty run page is the end only when total_count says so; a short payload is UNKNOWN.
put "repos/o/g" '{"default_branch":"main"}'
put "repos/o/g/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/g .github/workflows/daily.yaml "$daily"
put "repos/o/g/actions/workflows/1/runs?per_page=100&page=1" '{"total_count":5,"workflow_runs":[]}'
run --repo o/g
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a short run page must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/g .github/workflows/daily.yaml — run list read failed" "a short run page must be named"

# A listing that succeeds but is short of its own total_count is UNKNOWN, never an empty repository.
put "repos/o/e" '{"default_branch":"main"}'
put "repos/o/e/actions/workflows?per_page=100" '{"total_count":3,"workflows":[]}'
run --repo o/e
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a short workflow listing must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/e — workflow list incomplete (0 of 3)" "a short listing must be named"

# A path with a URL metacharacter is percent-encoded, so the request reaches the file.
put "repos/o/f" '{"default_branch":"main"}'
put "repos/o/f/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/a#b.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/f .github/workflows/a%23b.yaml "$daily"
put "repos/o/f/commits?path=.github/workflows/a#b.yaml&sha=main&until&per_page=1" '[{"sha":"b4f0e1ab"}]'
runs o/f 1 1 "schedule:$((now - 40 * d))"
run --repo o/f
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an encoded path must be read and judged, got $rc"; }

# An abort mid-scan (here a `set -u` expansion of an unset name, injected through a stub `yq`)
# must surface as UNKNOWN, never as the cleanup trap's successful status.
cat >"$bin/yq" <<'STUB'
#!/usr/bin/env bash
echo 'on_unset_var_marker'
STUB
chmod +x "$bin/yq"
abort_checker="$tmp/abort-checker.sh"
# shellcheck disable=SC2016 # the replacement is literal shell text for the copied checker
sed 's/^    \[ -n "\$crons" \] || continue.*$/    : "${deliberately_unset_for_abort_test}"/' "$checker" >"$abort_checker"
grep -qF 'deliberately_unset_for_abort_test' "$abort_checker" || fail "abort injection did not apply"
set +e
PATH="$bin:$PATH" FIXTURES="$fix" bash "$abort_checker" --repo o/c --now "$now" >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
rm -f "$bin/yq"
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an aborted scan must exit 2, got $rc"; }

# Usage errors are UNKNOWN.
run
[ "$rc" -eq 2 ] || fail "no --repo must exit 2, got $rc"

echo "silent-scheduled-workflows: all assertions passed"
