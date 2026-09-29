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
args=("$@"); jqexpr=""; url=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jqexpr="${args[i + 1]}"; i=$((i + 1)) ;;
    api | --paginate) ;;
    *) url="${args[i]}" ;;
  esac
done
[ -n "${FAIL_ON:-}" ] && [[ "$url" == *"$FAIL_ON"* ]] && { echo "gh: HTTP 502" >&2; exit 1; }
key="$(printf '%s' "$url" | tr '/?&=' '____')"
f="$FIXTURES/$key.json"
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$f"; else cat "$f"; fi
STUB
chmod +x "$bin/gh"

put() { printf '%s' "$2" >"$fix/$(printf '%s' "$1" | tr '/?&=' '____').json"; }
workflow_file() { # <repo> <path> <yaml>
  put "repos/$1/contents/$2?ref=main" "{\"content\":\"$(printf '%s' "$3" | base64 | tr -d '\n')\"}"
}
runs() { # <repo> <id> <page> <event:epoch>...
  local repo="$1" id="$2" page="$3" rows="" e t
  shift 3
  for r in "$@"; do
    e="${r%%:*}"; t="${r#*:}"
    rows="${rows:+$rows,}{\"event\":\"$e\",\"created_at\":\"$(iso "$t")\"}"
  done
  put "repos/$repo/actions/workflows/$id/runs?per_page=100&page=$page" "{\"workflow_runs\":[${rows}]}"
}

# Repository o/a — every shape the checker must decide.
old="2026-01-01T10:00:00.000+02:00" # the offset form GitHub actually returns for workflows
put "repos/o/a" '{"default_branch":"main"}'
put "repos/o/a/actions/workflows?per_page=100" "{\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"},
  {\"id\":2,\"state\":\"active\",\"path\":\".github/workflows/dispatch.yaml\",\"created_at\":\"$old\"},
  {\"id\":3,\"state\":\"active\",\"path\":\".github/workflows/stale.yaml\",\"created_at\":\"$old\"},
  {\"id\":4,\"state\":\"disabled_manually\",\"path\":\".github/workflows/off.yaml\",\"created_at\":\"$old\"},
  {\"id\":5,\"state\":\"disabled_inactivity\",\"path\":\".github/workflows/inactive.yaml\",\"created_at\":\"$old\"},
  {\"id\":6,\"state\":\"active\",\"path\":\".github/workflows/gone.yaml\",\"created_at\":\"$old\"},
  {\"id\":7,\"state\":\"active\",\"path\":\".github/workflows/monthly.yaml\",\"created_at\":\"$old\"},
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
runs o/a 7 1 "push:$((now - 1 * h))" "push:$((now - 2 * d))"
runs o/a 7 2 "schedule:$((now - 20 * d))"

run() { set +e; PATH="$bin:$PATH" FIXTURES="$fix" "$checker" "$@" --now "$now" >"$tmp/out" 2>"$tmp/err"; rc=$?; set -e; }
has() { grep -qxF -- "$1" "$tmp/out" || { cat "$tmp/out" "$tmp/err" >&2; fail "$2"; }; }
lacks() { ! grep -qF -- "$1" "$tmp/out" || { cat "$tmp/out" >&2; fail "$2"; }; }

run --repo o/a
[ "$rc" -eq 1 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "silent schedules must exit 1, got $rc"; }
has "SILENT-WORKFLOW o/a .github/workflows/stale.yaml — no scheduled run in the last 49h (longest cron gap 24h)" \
  "a daily schedule silent for 40 days must be reported"
lacks "dispatch.yaml" "a dispatch-only workflow's silence must never be reported"
has "SILENT-WORKFLOW o/a .github/workflows/inactive.yaml — schedule disabled by GitHub for repository inactivity" \
  "GitHub's inactivity disable must be reported"
lacks "off.yaml" "a manually disabled workflow is a recorded decision, not a finding"
lacks "gone.yaml" "a workflow whose file left the default branch cannot fire and must be skipped"
lacks "daily.yaml" "a schedule that ran 10h ago is healthy"
lacks "monthly.yaml" "a schedule run on the second page must be found"
lacks "codeql" "a dynamic GitHub-managed workflow is out of scope"
has "CHECKED 4 scheduled workflow(s) across 1 repositor(ies)" "the summary must count what was examined"
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
put "repos/o/b/actions/workflows?per_page=100" '{"workflows":[
  {"id":9,"state":"active","path":".github/workflows/daily.yaml","created_at":"yesterday"}]}'
workflow_file o/b .github/workflows/daily.yaml "$daily"
run --repo o/b
[ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "an unparseable timestamp must exit 2, got $rc"; }

# A healthy repository exits 0.
put "repos/o/c" '{"default_branch":"main"}'
put "repos/o/c/actions/workflows?per_page=100" "{\"workflows\":[
  {\"id\":1,\"state\":\"active\",\"path\":\".github/workflows/daily.yaml\",\"created_at\":\"$old\"}]}"
workflow_file o/c .github/workflows/daily.yaml "$daily"
runs o/c 1 1 "schedule:$((now - 3 * h))"
run --repo o/c
[ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err" >&2; fail "a healthy repository must exit 0, got $rc"; }
has "CHECKED 1 scheduled workflow(s) across 1 repositor(ies)" "healthy summary"

# Usage errors are UNKNOWN.
run
[ "$rc" -eq 2 ] || fail "no --repo must exit 2, got $rc"

echo "silent-scheduled-workflows: all assertions passed"
