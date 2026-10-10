#!/usr/bin/env bash
# RED/GREEN coverage for silent-scheduled-workflows.sh (monorepo#2928) against a stub gh:
# a dispatch-only workflow with an old failing run is NOT reported, while a scheduled workflow with
# the same history IS; plus pagination, the manual-disable and missing-file skips, GitHub's
# inactivity disable, offset timestamps, and every failed read reported as UNKNOWN. Every content and
# history read is pinned to one resolved head, and a head that moves mid-scan is re-judged
# (monorepo#3672); a schedule removed and re-added inside the window is not yet due, and neither is a
# workflow that an earlier sweep saw disabled inside it (monorepo#3671).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$root/.claude/scripts/silent-scheduled-workflows.sh"
tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$tmp"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then
    echo "silent-scheduled-workflows.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    exit 1
  fi
}
trap on_exit EXIT
fail() { echo "silent-scheduled-workflows test: $*" >&2; exit 1; }

now=1790000000 # 2026-09-21T13:33:20Z
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
h=3600
d=$((24 * h))
# The commit every `main` resolves to, unless a test supplies a head sequence of its own.
export PIN
PIN="$(printf 'c0ffee%033d1' 0)"
pin="$PIN"

fix="$tmp/fix"
bin="$tmp/bin"
mkdir -p "$fix" "$bin"
cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
# Serve fixtures keyed by the request path; honour --jq by running it through jq, as gh does.
# `-f k=v` fields become the query string in the order given, as `--method GET` sends them. For
# `graphql` they are the query's variables instead, and the fixture is keyed by repository, path and
# page cursor.
args=("$@"); jqexpr=""; url=""; query=""; owner=""; repo_name=""; oid=""; path=""; after=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jqexpr="${args[i + 1]}"; i=$((i + 1)) ;;
    --method | -H) i=$((i + 1)) ;;
    -f)
      field="${args[i + 1]}"; i=$((i + 1))
      case "$field" in
        query=*) continue ;; # the GraphQL document itself
        owner=*) owner="${field#owner=}" ;;
        name=*) repo_name="${field#name=}" ;;
        oid=*) oid="${field#oid=}" ;;
        path=*) path="${field#path=}" ;;
        after=*) after="${field#after=}" ;;
      esac
      query="${query:+$query&}${field}"
      ;;
    api | --paginate) ;;
    *) url="${args[i]}" ;;
  esac
done
# A branch name comes from the API and may hold URL metacharacters: it must travel as an encoded
# field, never spliced into the URL.
case "$url" in *"ref="* | *"sha="*) echo "gh stub: branch spliced into the URL: $url" >&2; exit 1 ;; esac
if [ "$url" = graphql ]; then
  # Every history read must be pinned to a full commit SHA, never a branch name.
  [[ "$oid" =~ ^[0-9a-f]{40}$ ]] || { echo "gh stub: unpinned history read: oid '$oid'" >&2; exit 1; }
  logline="graphql oid=$oid path=$path${after:+ after=$after}"
  key="$(printf 'graphql/%s/%s/%s%s' "$owner" "$repo_name" "$path" "${after:+&after=$after}" | tr '/?&=' '____')"
  url="graphql?path=$path"
else
  # Every content read must be pinned to a full commit SHA, never a branch name.
  case "$url" in
    repos/*/contents/*)
      [[ "$query" =~ ^ref=[0-9a-f]{40}$ ]] || { echo "gh stub: unpinned content read: $url?$query" >&2; exit 1; }
      ;;
  esac
  [ -z "$query" ] || url="$url?$query"
  logline="$url"
  key="$(printf '%s' "$url" | tr '/?&=' '____')"
fi
[ -z "${REQUEST_LOG:-}" ] || printf '%s\n' "$logline" >>"$REQUEST_LOG"
[ -n "${FAIL_ON:-}" ] && [[ "$url" == *"$FAIL_ON"* ]] && { echo "gh: HTTP 502" >&2; exit 1; }
f="$FIXTURES/$key.json"
# A fixture sequence serves its next line on each call, repeating the last: a branch that moves
# between reads. A FAIL line is a failed request.
if [ -f "$FIXTURES/$key.seq" ]; then
  n="$(cat "$FIXTURES/$key.n" 2>/dev/null || echo 0)"
  n=$((n + 1))
  echo "$n" >"$FIXTURES/$key.n"
  lines="$(grep -c . "$FIXTURES/$key.seq")"
  [ "$n" -le "$lines" ] || n="$lines"
  sed -n "${n}p" "$FIXTURES/$key.seq" >"$FIXTURES/.seq.json"
  f="$FIXTURES/.seq.json"
  [ "$(cat "$f")" != FAIL ] || { echo "gh: HTTP 502" >&2; exit 1; }
fi
# An `.httperror` fixture is a request GitHub refused: real gh prints the reply body, skips --jq
# and exits 1.
if [ -f "$FIXTURES/$key.httperror" ]; then
  cat "$FIXTURES/$key.httperror"
  echo "gh: $(jq -r '.message // "error"' "$FIXTURES/$key.httperror" 2>/dev/null) (HTTP $(jq -r '.status // "?"' "$FIXTURES/$key.httperror" 2>/dev/null))" >&2
  exit 1
fi
# The default branch resolves to $PIN unless a test supplies the ref itself.
if [ ! -f "$f" ] && [[ "$url" =~ ^repos/[^/]+/[^/]+/git/ref/heads/main$ ]]; then
  printf '{"ref":"refs/heads/main","object":{"type":"commit","sha":"%s"}}' "$PIN" >"$FIXTURES/.head.json"
  f="$FIXTURES/.head.json"
fi
# The workflow directory at a commit lists every workflow file that has a content fixture at that
# commit, unless a test supplies the listing itself.
if [ ! -f "$f" ] && [[ "$url" =~ ^repos/([^/]+/[^/]+)/contents/\.github/workflows\?ref=([0-9a-f]{40})$ ]]; then
  prefix="$(printf '%s' "repos/${BASH_REMATCH[1]}/contents/.github/workflows/" | tr '/?&=' '____')"
  at="${BASH_REMATCH[2]}"
  for g in "$FIXTURES/$prefix"*"_ref_${at}.json"; do
    [ -e "$g" ] || continue
    wf="${g##*/}"; wf="${wf#"$prefix"}"; wf="${wf%_ref_"${at}".json}"
    printf '%s\n' ".github/workflows/${wf//%23/#}"
  done | jq -R '{type: "file", path: .}' | jq -s . >"$FIXTURES/.synth.json"
  f="$FIXTURES/.synth.json"
fi
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
# A GraphQL reply that carries `errors` makes real gh print the raw reply, skip --jq and exit 1.
# GRAPHQL_EXIT1 forces that exit for any reply, to prove a failed request is never read as clean.
if [[ "$url" == graphql* ]] && { [ -n "${GRAPHQL_EXIT1:-}" ] || jq -e '(.errors // []) | length > 0' "$f" >/dev/null 2>&1; }; then
  cat "$f"
  echo "gh: $(jq -r '.errors[0].message // "error"' "$f")" >&2
  exit 1
fi
if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$f"; else cat "$f"; fi
STUB
chmod +x "$bin/gh"

put() { printf '%s' "$2" >"$fix/$(printf '%s' "$1" | tr '/?&=' '____').json"; }
# One version of a workflow file in a history page: YAML text, ABSENT (no file at that commit), or
# MISSING (a malformed node with no `file` key at all).
node_json() {
  case "$1" in
    ABSENT) echo '{"file":null}' ;;
    MISSING) echo '{}' ;;
    *) jq -nc --arg t "$1" '{file: {object: {isTruncated: false, text: $t}}}' ;;
  esac
}
# One page of a file's history as the GraphQL query returns it. As GitHub does (measured on monorepo
# at 665092ec), every ABSENT version also adds a top-level NOT_FOUND error whose path names that node's
# `file`, and the stub then exits 1 like real gh.
history_json() { # <window-start version | NONE> <totalCount | -> <next cursor | -> [<version inside the window, newest first>...]
  local before="$1" total="$2" next="$3" b w="[]" v
  shift 3
  if [ "$before" = NONE ]; then b='[]'; else b="[$(node_json "$before")]"; fi
  for v in "$@"; do w="$(jq -c --argjson n "$(node_json "$v")" '. + [$n]' <<<"$w")"; done
  [ "$total" != - ] || total="$(jq length <<<"$w")"
  jq -nc --argjson b "$b" --argjson w "$w" --argjson t "$total" --arg c "$next" '
    def missing($at; $nodes): $nodes | to_entries[] | select((.value | has("file")) and .value.file == null)
      | {type: "NOT_FOUND", path: ["repository", "object", $at, "nodes", .key, "file"],
         locations: [{line: 1, column: 1}], message: "Could not resolve file for path"};
    {data: {repository: {object: {before: {nodes: $b}, window: {totalCount: $t,
      pageInfo: (if $c == "-" then {hasNextPage: false, endCursor: null} else {hasNextPage: true, endCursor: $c} end),
      nodes: $w}}}}}
    + ([missing("before"; $b), missing("window"; $w)] | if length > 0 then {errors: .} else {} end)'
}
history() { # <repo> <path> <window-start version | NONE> [<version inside the window, newest first>...]
  local repo="$1" path="$2" before="$3"
  shift 3
  put "graphql/$repo/${path//%23/#}" "$(history_json "$before" - - "$@")"
}
workflow_file() { # <repo> <path> <yaml> [<yaml at the window start, or NONE if the file was new> [<version inside the window>...]]
  local repo="$1" path="$2" yaml="$3" before="${4:-$3}"
  put "repos/$repo/contents/$path?ref=$pin" "$yaml" # raw media type: the file itself
  shift 3
  [ "$#" -eq 0 ] || shift
  history "$repo" "$path" "$before" "$@"
}
head_sequence() { # <repo> <sha | FAIL>...: what each successive resolution of `main` returns
  local key s
  key="$(printf '%s' "repos/$1/git/ref/heads/main" | tr '/?&=' '____')"
  shift
  rm -f "$fix/$key.n"
  for s in "$@"; do
    if [ "$s" = FAIL ]; then echo FAIL; else printf '{"ref":"refs/heads/main","object":{"type":"commit","sha":"%s"}}\n' "$s"; fi
  done >"$fix/$key.seq"
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

REQUEST_LOG="$tmp/log" run --repo o/a
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
# Every directory, file and history read named the one resolved head (monorepo#3672): the stub
# refuses a branch name, and this proves no read used any other commit.
grep -q '^graphql oid=' "$tmp/log" || fail "the history walk must have been exercised"
grep -q '/contents/.*?ref=' "$tmp/log" || fail "the content reads must have been exercised"
[ "$(grep -oE '(ref|oid)=[0-9a-f]+' "$tmp/log" | sed 's/^[a-z]*=//' | sort -u)" = "$pin" ] ||
  { cat "$tmp/log" >&2; fail "every content and history read must be pinned to the resolved head"; }
[ "$(grep -c 'git/ref/heads/main' "$tmp/log")" -eq 2 ] ||
  { cat "$tmp/log" >&2; fail "the head must be resolved once per repository, and once more to confirm a silence"; }
# A schedule that ran inside the window needs no history: only a missing run is walked.
! grep -qE '^graphql oid=[0-9a-f]+ path=\.github/workflows/(daily|monthly)\.yaml$' "$tmp/log" ||
  { cat "$tmp/log" >&2; fail "a schedule with a run inside the window must not have its history walked"; }

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
# annual.yaml's file was edited inside the window (a pin bump, say) but its schedule was not: the
# window-start content and every edit since hold today's crons, so the silence is judged rather than
# excused.
workflow_file o/d .github/workflows/annual.yaml 'on:
  schedule:
    - cron: "0 0 31 1 *"
jobs: {}' 'on:
  schedule:
    - cron: "0 0 31 1 *"
jobs: {old: {}}' 'on:
  schedule:
    - cron: "0 0 31 1 *"
jobs: {}' 'on:
  schedule:
    - cron: "0 0 31 1 *"
jobs: {older: {}}'
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
history o/j .github/workflows/daily.yaml MISSING
runs o/j 1 1 "schedule:$((now - 40 * d))"
run --repo o/j
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed history payload must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/j .github/workflows/daily.yaml — file history at the pinned head unreadable" \
  "a malformed history payload must be named"
# …nor may a malformed version INSIDE the window read as "file absent there", the removal grace.
history o/j .github/workflows/daily.yaml "$daily" MISSING
run --repo o/j
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed in-window version must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/j .github/workflows/daily.yaml — file history at the pinned head unreadable" \
  "a malformed in-window version must be named"
# …and neither may a missing commit object (the head unknown to GraphQL) or a failed history read.
put "graphql/o/j/.github/workflows/daily.yaml" '{"data":{"repository":{"object":null}}}'
run --repo o/j
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a missing commit object must exit 2, got $rc"; }
history o/j .github/workflows/daily.yaml "$daily"
FAIL_ON="graphql?path=.github/workflows/daily.yaml" run --repo o/j
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a failed history read must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/j .github/workflows/daily.yaml — file history at the pinned head unreadable" \
  "a failed history read must be named"

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
history o/n .github/workflows/daily.yaml ''
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
put "repos/o/t/contents/.github/workflows?ref=$pin" '[{"type":"file","path":".github/workflows/hidden.yaml"}]'
run --repo o/t
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a listed but unreadable file must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/t .github/workflows/hidden.yaml — workflow file read failed" "a listed but unreadable file must be named"
put "repos/o/t/contents/.github/workflows?ref=$pin" '{"message":"Not Found"}'
run --repo o/t
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an unreadable workflow directory must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/t .github/workflows/hidden.yaml — workflow directory on the default branch unreadable" \
  "an unreadable workflow directory must be named"

# A malformed directory entry would make every listed file look removed: the listing is UNKNOWN.
put "repos/o/t/contents/.github/workflows?ref=$pin" '[{"type":"file","path":null}]'
run --repo o/t
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed directory entry must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/t .github/workflows/hidden.yaml — workflow directory on the default branch unreadable" \
  "a malformed directory entry must make the directory unreadable"

# GitHub's documented `deleted` state is a removed workflow: skipped, not UNKNOWN.
put "repos/o/u" '{"default_branch":"main"}'
put "repos/o/u/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"deleted\",\"path\":\".github/workflows/gone.yaml\",\"created_at\":\"$old\"}]}"
put "repos/o/u/contents/.github/workflows?ref=$pin" '[]'
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

# The trap is installed before any work, so even a failing `date` during start-up is UNKNOWN.
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/date"
chmod +x "$bin/date"
set +e
PATH="$bin:$PATH" FIXTURES="$fix" "$checker" --repo o/c --now "$now" >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
rm -f "$bin/date"
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a start-up date failure must exit 2, got $rc"; }

# A temporary-file failure is UNKNOWN, never exit 1 (a finding).
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

# Workflow paths are allowlisted, not blocklisted: a carriage return (or any character outside
# [A-Za-z0-9._#-]) makes the record malformed rather than silently unmatched.
put "repos/o/v/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/a\\rb.yaml\",\"created_at\":\"$old\"}]}"
run --repo o/v
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a carriage return in a workflow path must exit 2, got $rc"; }

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

# A malformed envelope (an object where the array belongs) is UNKNOWN, never "no workflows".
put "repos/o/y" '{"default_branch":"main"}'
put "repos/o/y/actions/workflows?per_page=100" '{"total_count":0,"workflows":{}}'
run --repo o/y
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed workflow-list envelope must exit 2, got $rc"; }
# …and a malformed run-page envelope is UNKNOWN, never "no runs, so silent".
put "repos/o/y/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/y .github/workflows/daily.yaml "$daily"
put "repos/o/y/actions/workflows/1/runs?per_page=100&page=1" '{"total_count":0,"workflow_runs":{}}'
run --repo o/y
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed run-page envelope must exit 2, got $rc"; }

# A directory listing at the Contents API's 1,000-entry cap may be truncated: absence proves nothing.
put "repos/o/w" '{"default_branch":"main"}'
put "repos/o/w/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/zz.yaml\",\"created_at\":\"$old\"}]}"
jq -n '[range(0; 1000) | {type: "file", path: ".github/workflows/w\(.).yaml"}]' >"$fix/$(printf '%s' "repos/o/w/contents/.github/workflows?ref=$pin" | tr '/?&=' '____').json"
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
# The content fixture is keyed by the encoded URL; the history read carries the raw path as a GraphQL
# variable, so `workflow_file` keys it by the decoded path.
workflow_file o/f .github/workflows/a%23b.yaml "$daily"
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
grep -qF 'deliberately_unset_for_abort_test' "$tmp/err" ||
  { cat "$tmp/out" "$tmp/err" >&2; fail "the scan must have aborted at the injected expansion, not earlier"; }

# Repository o/p — a schedule is judged only when it has run CONTINUOUSLY since the window start
# (monorepo#3671). Every workflow here last ran 40 days ago and its window-start version equals today's.
dispatch='on:
  workflow_dispatch: {}'
weekly='on:
  schedule:
    - cron: "17 6 * * 1"'
put "repos/o/p" '{"default_branch":"main"}'
put "repos/o/p/actions/workflows?per_page=100" "{\"total_count\":5,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/readded.yaml\",\"created_at\":\"$old\"},
  {\"id\":2,\"state\":\"active\",\"path\":\".github/workflows/recreated.yaml\",\"created_at\":\"$old\"},
  {\"id\":3,\"state\":\"active\",\"path\":\".github/workflows/bounced.yaml\",\"created_at\":\"$old\"},
  {\"id\":4,\"state\":\"active\",\"path\":\".github/workflows/edited.yaml\",\"created_at\":\"$old\"},
  {\"id\":5,\"state\":\"active\",\"path\":\".github/workflows/restored.yaml\",\"created_at\":\"$old\"}]}"
# The schedule removed and re-added with the SAME cron inside the window: it restarted at the re-add.
workflow_file o/p .github/workflows/readded.yaml "$daily" "$daily" "$daily" "$dispatch"
# The file deleted and re-created inside the window: the same.
workflow_file o/p .github/workflows/recreated.yaml "$daily" "$daily" "$daily" ABSENT
# Changed to weekly and back inside the window: the same.
workflow_file o/p .github/workflows/bounced.yaml "$daily" "$daily" "$daily" "$weekly"
# Edited inside the window without touching the schedule: still judged, so still reported.
workflow_file o/p .github/workflows/edited.yaml "$daily" "$daily" "$daily
jobs: {b: {}}" "$daily
jobs: {a: {}}"
# Absent at the window start (deleted by the last commit before it) and restored inside it: new.
workflow_file o/p .github/workflows/restored.yaml "$daily" ABSENT "$daily"
for id in 1 2 3 4 5; do runs o/p "$id" 1 "schedule:$((now - 40 * d))"; done
run --repo o/p
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "only the continuously scheduled workflow is silent, got $rc"; }
lacks "readded.yaml" "a schedule removed and re-added inside the window is not yet due"
lacks "recreated.yaml" "a workflow file deleted and re-created inside the window is not yet due"
lacks "bounced.yaml" "a schedule changed and changed back inside the window is not yet due"
lacks "restored.yaml" "a file absent at the window start is new, not silent"
has "SILENT-WORKFLOW o/p .github/workflows/edited.yaml — no scheduled run in the last 97h (its cron fires at least every 1d)" \
  "edits that keep the schedule must never extend the grace"
has "CHECKED 5 scheduled workflow(s) across 1 repositor(ies)" "every scheduled workflow is examined"

# A workflow switched back on inside the window is not yet due (monorepo#3671), and only a sweep that
# SAW it disabled can know: --state-file records those sightings. edited.yaml is the one silent
# workflow in o/p, with a 97-hour window.
state="$tmp/state/seen.tsv" # its directory does not exist yet
edited=".github/workflows/edited.yaml"
silent_edited="SILENT-WORKFLOW o/p ${edited} — no scheduled run in the last 97h (its cron fires at least every 1d)"
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
# A sweep records every workflow it finds disabled, by hand or by GitHub, and nothing else.
run --repo o/a --state-file "$state"
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "recording sightings must not change the verdict, got $rc"; }
has "SILENT-WORKFLOW o/a .github/workflows/inactive.yaml — schedule disabled by GitHub for repository inactivity" \
  "a workflow GitHub disabled is still reported while it is disabled"
{ row o/a .github/workflows/inactive.yaml "$now"; row o/a .github/workflows/off.yaml "$now"; } >"$tmp/want"
cmp -s "$tmp/want" "$state" || { cat "$state" >&2; fail "exactly the two disabled workflows must be recorded"; }
# A later sighting replaces the earlier one, other rows are kept, and a row too old to matter is dropped.
{ row o/a .github/workflows/off.yaml "$((now - 5 * d))"; row o/x .github/workflows/kept.yaml "$((now - 3 * d))"
  row o/x .github/workflows/ancient.yaml "$((now - 6000 * d))"; } >"$state"
run --repo o/a --state-file "$state"
{ row o/a .github/workflows/inactive.yaml "$now"; row o/a .github/workflows/off.yaml "$now"
  row o/x .github/workflows/kept.yaml "$((now - 3 * d))"; } >"$tmp/want"
cmp -s "$tmp/want" "$state" || { cat "$state" >&2; fail "sightings must merge to the newest per workflow and drop expired rows"; }
# Seen disabled 10 hours ago and active now: switched back on inside the window, so not yet due.
row o/p "$edited" "$((now - 10 * h))" >"$state"
run --repo o/p --state-file "$state"
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a workflow re-enabled inside the window must not be reported, got $rc"; }
lacks "edited.yaml" "a workflow re-enabled inside the window is not yet due"
has "CHECKED 5 scheduled workflow(s) across 1 repositor(ies)" "a graced workflow is still counted as examined"
row o/p "$edited" "$((now - 10 * h))" | cmp -s - "$state" || { cat "$state" >&2; fail "a sighting must survive a sweep that adds none"; }
# The sighting excuses a silence, never an unread run list: a failed read stays UNKNOWN.
FAIL_ON="actions/workflows/4/runs" run --repo o/p --state-file "$state"
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a failed run read must exit 2 even with a recent sighting, got $rc"; }
has "QUERY-UNKNOWN o/p ${edited} — run list read failed" "a recent sighting must not hide a failed run read"
# The control: the same sweep with no state reports it, so the sighting is what granted the grace.
run --repo o/p
has "$silent_edited" "without a sighting the workflow is judged on its run history"
# A sighting AT the window start, or before it, proves nothing about the window: reported.
for age in $((97 * h)) $((30 * d)); do
  row o/p "$edited" "$((now - age))" >"$state"
  run --repo o/p --state-file "$state"
  [ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a sighting ${age}s old must not grant the grace, got $rc"; }
  has "$silent_edited" "a sighting outside the window must not grant the grace"
done
row o/p "$edited" "$((now - 97 * h + 1))" >"$state"
run --repo o/p --state-file "$state"
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a sighting one second inside the window grants the grace, got $rc"; }
# A sighting of another repository's workflow, or of another file, is not this workflow's.
{ row o/q "$edited" "$((now - h))"; row o/p .github/workflows/other.yaml "$((now - h))"; } >"$state"
run --repo o/p --state-file "$state"
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "another workflow's sighting must not grant the grace, got $rc"; }
has "$silent_edited" "a sighting is matched on the repository and the path together"
# A state file that does not validate is UNKNOWN, grants nothing, and is left exactly as found.
# That includes a sighting dated after the sweep, which would otherwise grant a grace that never ends,
# and a line holding a NUL byte, which BSD grep does not select.
for bad in "o/p	${edited}" "o/p	${edited}	soon" "o/p	../../etc/passwd	$((now - h))" "o p	${edited}	$((now - h))" \
  "o/x	${edited}	$((now + 400 * d))" "o/x	${edited}	99999999999999999999999" "o/x	${edited}	$((now - h))\0000junk"; do
  # shellcheck disable=SC2059 # the row is the format, so the NUL escape is written as a byte
  { row o/p "$edited" "$((now - h))"; printf "${bad}\n"; } >"$state"
  cp "$state" "$tmp/before"
  run --repo o/p --state-file "$state"
  [ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed state row '$bad' must exit 2, got $rc"; }
  has "QUERY-UNKNOWN — state file unreadable or malformed; scanned without it" "a malformed state file must be named"
  has "$silent_edited" "a malformed state file must not grant the valid row's grace either"
  cmp -s "$tmp/before" "$state" || fail "a malformed state file must not be rewritten"
done
# End to end, on one state file: the sweep that sees the workflow disabled is what lets the next one,
# which finds it active and silent, leave it alone. GitHub's own disable is recorded the same way.
for was in disabled_manually disabled_inactivity; do
  rm -f "$state"
  put "repos/o/r" '{"default_branch":"main"}'
  put "repos/o/r/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
    {\"id\":1,\"state\":\"${was}\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
  workflow_file o/r .github/workflows/daily.yaml "$daily"
  runs o/r 1 1 "schedule:$((now - 40 * d))"
  run --repo o/r --state-file "$state"
  row o/r .github/workflows/daily.yaml "$now" | cmp -s - "$state" || { cat "$state" >&2; fail "a ${was} workflow must be recorded"; }
  put "repos/o/r/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
    {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
  run --repo o/r --repo o/p --state-file "$state"
  lacks "o/r .github/workflows/daily.yaml" "a workflow seen ${was} by the last sweep is not yet due once active"
  has "$silent_edited" "one repository's sighting must not grace another repository in the same sweep"
  run --repo o/r
  has "SILENT-WORKFLOW o/r .github/workflows/daily.yaml — no scheduled run in the last 97h (its cron fires at least every 1d)" \
    "without the sighting the re-enabled workflow is reported"
done
# A state path that is not a file is the same.
mkdir "$tmp/statedir"
run --repo o/p --state-file "$tmp/statedir"
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a state path that is a directory must exit 2, got $rc"; }
has "QUERY-UNKNOWN — state file unreadable or malformed; scanned without it" "an unreadable state file must be named"
has "$silent_edited" "an unreadable state file must not hide a silence"
# A state file that cannot be written is UNKNOWN: the sightings this sweep made would be lost.
: >"$tmp/plainfile"
run --repo o/a --state-file "$tmp/plainfile/seen.tsv"
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an unwritable state file must exit 2, got $rc"; }
has "QUERY-UNKNOWN — state file could not be written" "an unwritable state file must be named"
# No --state-file writes nothing, and an empty path is a usage error.
rm -rf "$tmp/state"
run --repo o/a
[ ! -e "$tmp/state" ] || fail "a sweep without --state-file must not write state"
run --repo o/a --state-file ""
[ "$rc" -eq 2 ] || fail "an empty --state-file must exit 2, got $rc"
# Only a PROVEN difference grants the grace: an unparseable version inside the window is UNKNOWN…
workflow_file o/p .github/workflows/edited.yaml "$daily" "$daily" 'on: [unclosed'
run --repo o/p
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an unparseable in-window version must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/p .github/workflows/edited.yaml — file version inside the window unparseable" \
  "an unparseable in-window version must be named"
# …unless another version inside the window proves the schedule restarted there anyway.
workflow_file o/p .github/workflows/edited.yaml "$daily" "$daily" 'on: [unclosed' "$dispatch"
run --repo o/p
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a proven restart inside the window grants the grace, got $rc"; }

# Repository o/q — the history walk pages through the window, and is bounded and complete or UNKNOWN.
put "repos/o/q" '{"default_branch":"main"}'
put "repos/o/q/actions/workflows?per_page=100" "{\"total_count\":2,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/early.yaml\",\"created_at\":\"$old\"},
  {\"id\":2,\"state\":\"active\",\"path\":\".github/workflows/late.yaml\",\"created_at\":\"$old\"}]}"
put "repos/o/q/contents/.github/workflows/early.yaml?ref=$pin" "$daily"
put "repos/o/q/contents/.github/workflows/late.yaml?ref=$pin" "$daily"
for id in 1 2; do runs o/q "$id" 1 "schedule:$((now - 40 * d))"; done
# early.yaml's removal is on the SECOND page of the window: found, so not yet due. late.yaml's two
# pages hold only its schedule: judged, so reported.
put "graphql/o/q/.github/workflows/early.yaml" "$(history_json "$daily" 2 c1 "$daily")"
put "graphql/o/q/.github/workflows/early.yaml&after=c1" "$(history_json "$daily" 2 - "$dispatch")"
put "graphql/o/q/.github/workflows/late.yaml" "$(history_json "$daily" 2 c1 "$daily")"
put "graphql/o/q/.github/workflows/late.yaml&after=c1" "$(history_json "$daily" 2 - "$daily")"
run --repo o/q
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a paged window must be walked to its end, got $rc"; }
lacks "early.yaml" "a removal on the second page of the window must be found"
has "SILENT-WORKFLOW o/q .github/workflows/late.yaml — no scheduled run in the last 97h (its cron fires at least every 1d)" \
  "a schedule unchanged across a paged window must be judged"
# A walk that never reaches the window start within its bound is UNKNOWN, never a verdict.
put "graphql/o/q/.github/workflows/late.yaml" "$(history_json "$daily" 999 c "$daily")"
put "graphql/o/q/.github/workflows/late.yaml&after=c" "$(history_json "$daily" 999 c "$daily")"
run --repo o/q
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a walk past its bound must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/q .github/workflows/late.yaml — file history inside the window exceeds 300 commits" \
  "a walk past its bound must be named"
# A last page whose versions fall short of the total is a partial payload: UNKNOWN.
put "graphql/o/q/.github/workflows/late.yaml" "$(history_json "$daily" 3 - "$daily")"
run --repo o/q
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a short history must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/q .github/workflows/late.yaml — file history inside the window incomplete (1 of 3)" \
  "a short history must be named"
# A truncated text is not the file: UNKNOWN, never a difference.
put "graphql/o/q/.github/workflows/late.yaml" "$(history_json "$daily" - - "$daily" |
  jq -c '.data.repository.object.window.nodes[0].file.object.isTruncated = true')"
run --repo o/q
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a truncated version must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/q .github/workflows/late.yaml — file history at the pinned head unreadable" \
  "a truncated version must be named"
# GitHub answers an absent version with a NOT_FOUND error and gh exits 1 (the ABSENT fixtures above).
# Only exactly that error is tolerated: any other error, a NOT_FOUND naming a node that HAS a file or
# naming anything but a node's `file`, an extra error beside a tolerated one, or a body that is not
# JSON at all, is UNKNOWN — never the removal grace.
absent_reply="$(history_json "$daily" - - "$daily" ABSENT)"
jq -e '.errors == [{type: "NOT_FOUND", path: ["repository", "object", "window", "nodes", 1, "file"],
  locations: [{line: 1, column: 1}], message: "Could not resolve file for path"}]' <<<"$absent_reply" >/dev/null ||
  fail "the ABSENT fixture must carry GitHub's NOT_FOUND error for that node"
for bad in '.errors[0].type = "FORBIDDEN"' \
  '.errors[0].path[4] = 0' \
  '.errors[0].path = ["repository", "object"]' \
  '.errors[0].path[2] = "after"' \
  '.errors += [{type: "RATE_LIMITED", path: null, message: "slow down"}]' \
  '.errors = []' \
  '.errors = {}'; do
  put "graphql/o/q/.github/workflows/late.yaml" "$(jq -c "$bad" <<<"$absent_reply")"
  run --repo o/q
  [ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a GraphQL reply edited by '$bad' must exit 2, got $rc"; }
  has "QUERY-UNKNOWN o/q .github/workflows/late.yaml — file history at the pinned head unreadable" \
    "a GraphQL reply edited by '$bad' must be named"
done
put "graphql/o/q/.github/workflows/late.yaml" '<html>Bad Gateway</html>'
run --repo o/q
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a non-JSON history reply must exit 2, got $rc"; }
# A failed request whose reply is well formed but carries no error to explain the failure is UNKNOWN.
put "graphql/o/q/.github/workflows/late.yaml" "$(history_json "$daily" - - "$daily")"
GRAPHQL_EXIT1=1 run --repo o/q
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a failed request with an error-free reply must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/q .github/workflows/late.yaml — file history at the pinned head unreadable" \
  "a failed request with an error-free reply must be named"
# …while the tolerated answer is read as what it is: the file removed inside the window, not yet due.
put "graphql/o/q/.github/workflows/late.yaml" "$absent_reply"
run --repo o/q
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "GitHub's NOT_FOUND for a removed version grants the grace, got $rc"; }

# Repository o/r2 — the head every read is pinned to must resolve, or the repository is UNKNOWN.
put "repos/o/r2" '{"default_branch":"main"}'
put "repos/o/r2/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/r2 .github/workflows/daily.yaml "$daily"
runs o/r2 1 1 "schedule:$((now - 3 * h))"
FAIL_ON="git/ref/heads/main" run --repo o/r2
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an unresolvable head must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/r2 — default branch head unresolvable" "an unresolvable head must be named"
has "CHECKED 0 scheduled workflow(s) across 0 repositor(ies)" "a repository never pinned is never counted as read"
for reply in '{"ref":"refs/heads/main","object":{"type":"commit","sha":"c0ffee"}}' \
  '{"ref":"refs/heads/main-old","object":{"type":"commit","sha":"'"$pin"'"}}' \
  '{"ref":"refs/heads/main","object":{"type":"tag","sha":"'"$pin"'"}}' \
  '{"ref":"refs/heads/main","object":{"type":"commit","sha":null}}'; do
  put "repos/o/r2/git/ref/heads/main" "$reply"
  run --repo o/r2
  [ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a malformed head ($reply) must exit 2, got $rc"; }
  has "QUERY-UNKNOWN o/r2 — default branch head unresolvable" "a malformed head must be named"
done
# A schedule that ran inside the window is healthy without its history: even an unreadable history
# is never read, so it cannot turn a proven firing into UNKNOWN.
rm -f "$fix/$(printf '%s' "repos/o/r2/git/ref/heads/main" | tr '/?&=' '____').json"
history o/r2 .github/workflows/daily.yaml MISSING
run --repo o/r2
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a schedule that ran inside the window must not need its history, got $rc"; }
has "CHECKED 1 scheduled workflow(s) across 1 repositor(ies)" "the healthy schedule is still examined"

# Repository o/z — the default branch moves while it is scanned (monorepo#3672). At the first head the
# workflow holds a daily schedule that last ran 40 days ago.
pin2="$(printf 'beef%035d2' 0)"
pin3="$(printf 'beef%035d3' 0)"
put "repos/o/z" '{"default_branch":"main"}'
put "repos/o/z/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/z .github/workflows/daily.yaml "$daily"
runs o/z 1 1 "schedule:$((now - 40 * d))"
# The schedule is removed after the file was read: the silence is re-judged at the new head, where
# the workflow is dispatch-only, so nothing is reported.
put "repos/o/z/contents/.github/workflows/daily.yaml?ref=$pin2" "$dispatch"
head_sequence o/z "$pin" "$pin2"
rm -f "$tmp/log"
REQUEST_LOG="$tmp/log" run --repo o/z
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a schedule removed mid-scan must not be reported, got $rc"; }
lacks "daily.yaml" "a schedule removed mid-scan must not be reported"
has "CHECKED 0 scheduled workflow(s) across 1 repositor(ies)" "the re-judgement at the new head is what counts"
grep -qxF "repos/o/z/contents/.github/workflows/daily.yaml?ref=$pin2" "$tmp/log" ||
  { cat "$tmp/log" >&2; fail "the file must be re-read at the new head"; }
# The workflow FILE deleted mid-scan: absent from the new head's directory, so nothing is reported.
head_sequence o/z "$pin" "$pin3"
run --repo o/z
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a workflow deleted mid-scan must not be reported, got $rc"; }
lacks "daily.yaml" "a workflow deleted mid-scan must not be reported"
# The branch moved but the schedule did not: the silence is confirmed at the new head and reported.
put "repos/o/z/contents/.github/workflows/daily.yaml?ref=$pin2" "$daily"
head_sequence o/z "$pin" "$pin2"
rm -f "$tmp/log"
REQUEST_LOG="$tmp/log" run --repo o/z
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a silence that survives the move must be reported, got $rc"; }
has "SILENT-WORKFLOW o/z .github/workflows/daily.yaml — no scheduled run in the last 97h (its cron fires at least every 1d)" \
  "a silence confirmed at the new head must be reported"
# The re-judgement walks the history at the NEW head, not the one the first scan was pinned to.
grep -qxF "graphql oid=$pin2 path=.github/workflows/daily.yaml" "$tmp/log" ||
  { cat "$tmp/log" >&2; fail "the history must be walked again at the new head"; }
# A branch that keeps moving, or a head that cannot be re-read, leaves the silence UNKNOWN.
head_sequence o/z "$pin" "$pin2" "$pin3"
run --repo o/z
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a branch that keeps moving must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/z .github/workflows/daily.yaml — silence not confirmed: default branch moved again while it was re-judged" \
  "a branch that keeps moving must be named"
lacks "SILENT-WORKFLOW" "an unconfirmed silence is never reported"
head_sequence o/z "$pin" FAIL
run --repo o/z
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a head that cannot be re-read must exit 2, got $rc"; }
has "QUERY-UNKNOWN o/z .github/workflows/daily.yaml — silence not confirmed: default branch head unresolvable before reporting" \
  "a head that cannot be re-read must be named"

# Repository o/empty has no commits (monorepo#4087): GitHub refuses the head read with its explicit
# empty-repository answer. Nothing can be scheduled there, so it is named and skipped, not UNKNOWN.
put_error() { printf '%s' "$2" >"$fix/$(printf '%s' "$1" | tr '/?&=' '____').httperror"; }
drop_error() { rm -f "$fix/$(printf '%s' "$1" | tr '/?&=' '____').httperror"; }
empty_reply='{"message":"Git Repository is empty.","documentation_url":"https://docs.github.com/rest/git/refs#get-a-reference","status":"409"}'
put "repos/o/empty" '{"default_branch":"main"}'
put "repos/o/empty/actions/workflows?per_page=100" '{"total_count":0,"workflows":[]}'
put_error "repos/o/empty/git/ref/heads/main" "$empty_reply"
run --repo o/empty
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an empty repository alone must exit 0, got $rc"; }
has "EMPTY-REPOSITORY o/empty — no commits, so no schedule to judge" "an empty repository must be named"
lacks "QUERY-UNKNOWN" "an empty repository is not an unknown"
has "CHECKED 0 scheduled workflow(s) across 0 repositor(ies); skipped 1 empty repositor(ies)" \
  "the closing line counts empty repositories apart from the ones read"
# Beside a healthy repository the sweep stays clean, and the healthy one is still counted as read.
run --repo o/empty --repo o/q
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an empty repository beside a healthy one must exit 0, got $rc"; }
grep -qF -- "across 1 repositor(ies); skipped 1 empty repositor(ies)" "$tmp/out" ||
  { cat "$tmp/out" "$tmp/err" >&2; fail "a read repository and an empty one are counted apart"; }
# Only that exact answer counts. Any other refusal of the head read stays UNKNOWN: a missing ref,
# a server error, a body that is not the empty-repository answer, or one that is not JSON at all.
for reply in '{"message":"Not Found","status":"404"}' \
  '{"message":"Server Error","status":"502"}' \
  '{"message":"Git Repository is empty.","status":"404"}' \
  '{"message":"Conflict","status":"409"}' \
  '["Git Repository is empty.","409"]' \
  '<html>Git Repository is empty. 409</html>' \
  ''; do
  put_error "repos/o/empty/git/ref/heads/main" "$reply"
  run --repo o/empty
  [ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a refused head read ($reply) must exit 2, got $rc"; }
  has "QUERY-UNKNOWN o/empty — default branch head unresolvable" "a refused head read ($reply) must be named"
  lacks "EMPTY-REPOSITORY" "a refused head read ($reply) is never an empty repository"
done
# A repository that lists a workflow has commits, whatever the head read says: still UNKNOWN.
put_error "repos/o/empty/git/ref/heads/main" "$empty_reply"
put "repos/o/empty/actions/workflows?per_page=100" "{\"total_count\":1,\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
run --repo o/empty
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an empty answer beside a listed workflow must exit 2, got $rc"; }
lacks "EMPTY-REPOSITORY" "a repository that lists a workflow is never skipped as empty"
# A head read that succeeds on the second look (a first commit just landed) is not empty either.
put "repos/o/empty/actions/workflows?per_page=100" '{"total_count":0,"workflows":[]}'
drop_error "repos/o/empty/git/ref/heads/main"
head_sequence o/empty FAIL "$pin"
run --repo o/empty
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a head that resolves on the second read must exit 2, got $rc"; }
lacks "EMPTY-REPOSITORY" "a head that resolves on the second read is never an empty repository"

# Usage errors are UNKNOWN.
run
[ "$rc" -eq 2 ] || fail "no --repo must exit 2, got $rc"

echo "silent-scheduled-workflows: all assertions passed"
completed=1
