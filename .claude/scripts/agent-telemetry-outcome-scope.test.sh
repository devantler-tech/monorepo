#!/usr/bin/env bash
# test-timeout-seconds: 180
# Exercise the shipped CLI with synthetic metadata and record every forge call.
# No native transcript store, GitHub credential or real repository is accessed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIX=$(mktemp -d)
scope_test_finished=0
cleanup() {
  local rc=$?
  rm -rf "$FIX"
  if [ "$scope_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo 'outcome authorization: aborted before finishing' >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
mkdir -p "$FIX/definition/.claude/scripts" "$FIX/definition/.claude/guides" \
  "$FIX/bin" "$FIX/corpus/.git" "$FIX/home"
cp "$SCRIPT_DIR/agent-telemetry.sh" "$FIX/definition/.claude/scripts/"
cp "$SOURCE_ROOT/.claude/guides/work-selection.md" "$SOURCE_ROOT/.claude/guides/egress-and-privacy.md" \
  "$FIX/definition/.claude/guides/"
awk '
  { print }
  /^## Portfolio map$/ { inside = 1 }
  inside && /^\|---\|---\|---\|---\|$/ {
    print "| Synthetic private products | `devantler-tech/scope-private`, `scope-private-two` | — | `AGENTS.md` |"
    inside = 0
  }
' "$SOURCE_ROOT/AGENTS.md" > "$FIX/definition/AGENTS.md"
cp "$FIX/definition/AGENTS.md" "$FIX/valid-contract.md"
cat > "$FIX/corpus/.gitmodules" <<'EOF'
[submodule "denied"]
  path = applications/denied
  url = https://github.com/devantler-tech/scope-denied.git
EOF
cat > "$FIX/instances.json" <<'EOF'
{"version":1,"policyPublisher":"codex-local","instances":{"codex-local":{"namespace":"codex","authors":{"cli":"devantler","rest":"devantler","graphql":"devantler","search":"devantler"},"definitionAdapter":"codex","roles":["agentic-engineer"]}}}
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/classifier"
chmod +x "$FIX/classifier"
if command -v sha256sum >/dev/null 2>&1; then
  digest=$(sha256sum "$FIX/classifier" | awk '{print $1}')
else
  digest=$(shasum -a 256 "$FIX/classifier" | awk '{print $1}')
fi
printf '{"spec":{"source":{"requiredRuntimeAssets":[{"path":"scripts/classify-default-branch-ci-runs.sh","sha256":"%s","executable":true}]}}}\n' \
  "$digest" > "$FIX/desired.json"
cat > "$FIX/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SCOPE_TRACE"
case "$*" in
  api*'orgs/devantler-tech/repos?type=all&per_page=100'*)
    # Simulate gh pagination failing after already emitting a valid page.
    if [ "${SCOPE_LIST_FAIL:-0}" = 1 ]; then
      printf '[{"id":1,"full_name":"devantler-tech/monorepo","private":false,"archived":false}]\n'
      exit 1
    fi
    case "$*" in
      *--slurp*) cat "$SCOPE_PAGES" ;;
      *) while [ $# -gt 0 ]; do
           if [ "$1" = --jq ]; then jq -r "$2" "$SCOPE_ROWS"; exit; fi
           shift
         done
         cat "$SCOPE_ROWS" ;;
    esac ;;
  'pr list '*)
    printf '%s\n' '[{"mergedAt":"2099-01-01T00:00:00Z","headRefName":"codex/change","author":{"login":"devantler"},"isCrossRepository":false}]' ;;
  api*'/commits/main --jq .sha') printf '%s\n' 0123456789abcdef0123456789abcdef01234567 ;;
  api*'/commits -X GET '*) printf '0\n' ;;
  *) exit 93 ;;
esac
EOF
chmod +x "$FIX/bin/gh"
cat > "$FIX/rows.json" <<'EOF'
[
 {"id":1,"full_name":"devantler-tech/monorepo","private":false,"archived":false},
 {"id":2,"full_name":"devantler-tech/scope-public","private":false,"archived":false},
 {"id":3,"full_name":"devantler-tech/scope-private","private":true,"archived":false},
 {"id":4,"full_name":"devantler-tech/scope-private-two","private":true,"archived":false},
 {"id":5,"full_name":"devantler-tech/scope-denied","private":true,"archived":false},
 {"id":6,"full_name":"devantler-tech/scope-retired","private":false,"archived":true}
]
EOF
cp "$FIX/rows.json" "$FIX/valid-rows.json"
run() {
  if [ "${SCOPE_MULTI_PAGE:-0}" = 1 ]; then
    jq '[.[0:3], .[3:]]' "$FIX/rows.json" > "$FIX/pages.json"
  else
    jq -s '.' "$FIX/rows.json" > "$FIX/pages.json"
  fi
  : > "$FIX/trace"
  set +e
  PATH="$FIX/bin:$PATH" HOME="$FIX/home" CODEX_HOME="$FIX/home/codex" \
    CLAUDE_PROJECTS_DIR="$FIX/home/projects" MONOREPO_DIR="$FIX/corpus" \
    PORTFOLIO_PATHS="$FIX/corpus" PORTFOLIO_ORG="${TEST_SCOPE_ORG:-devantler-tech}" \
    AGENT_TELEMETRY_RUNTIME=codex AGENT_CI_CLASSIFIER="$FIX/classifier" \
    AGENT_CI_DESIRED_STATE="$FIX/desired.json" SCOPE_TRACE="$FIX/trace" \
    SCOPE_PAGES="$FIX/pages.json" SCOPE_ROWS="$FIX/rows.json" SCOPE_LIST_FAIL="${SCOPE_LIST_FAIL:-0}" \
    bash "$FIX/definition/.claude/scripts/agent-telemetry.sh" --section outcomes \
    --instances "$FIX/instances.json" > "$FIX/output" 2>&1
  RC=$?
  set -e
}
PASS=0; FAIL=0
check() {
  if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*" >&2; fi
}
no_repo_queries() { ! grep -Eq '^pr list |^api .*repos/' "$FIX/trace"; }
no_target_query() { ! grep -Eq "(pr list --repo $1([[:space:]]|$)|api .*repos/$1/)" "$FIX/trace"; }
queried() { grep -qF "pr list --repo $1 " "$FIX/trace"; }
unknown() { [ "$RC" = 2 ] && grep -qF 'repository inventory: UNKNOWN' "$FIX/output"; }
run
check test "$RC" = 0
check queried devantler-tech/monorepo
check queried devantler-tech/scope-public
check queried devantler-tech/scope-private
check queried devantler-tech/scope-private-two
check no_target_query devantler-tech/scope-denied
check no_target_query devantler-tech/scope-retired
check grep -qF 'total: 4' "$FIX/output"
check grep -qF 'authorization policy: portfolio-v1' "$FIX/output"
check grep -qF 'AUTHORIZED SUBSET' "$FIX/output"
SCOPE_MULTI_PAGE=1 run
check test "$RC" = 0
check queried devantler-tech/scope-private-two
check no_target_query devantler-tech/scope-denied

jq 'map(if .full_name == "devantler-tech/monorepo" or .full_name == "devantler-tech/scope-private" then .archived = true else . end)' \
  "$FIX/valid-rows.json" > "$FIX/rows.json"
run
check test "$RC" = 0
check no_target_query devantler-tech/monorepo
check no_target_query devantler-tech/scope-private
check queried devantler-tech/scope-public
cp "$FIX/valid-rows.json" "$FIX/rows.json"

SCOPE_LIST_FAIL=1 run
check unknown
check no_repo_queries

for alteration in 'map(. | del(.private))' '.[0].private = "false"' \
  '.[0].archived = null' '.[0].full_name = "another-owner/outside"' \
  '. + [.[0]]' '.[1].id = .[0].id' '.[0].id = null' '. = []'; do
  jq "$alteration" "$FIX/valid-rows.json" > "$FIX/rows.json"
  run
  check unknown
  check no_repo_queries
done
cp "$FIX/valid-rows.json" "$FIX/rows.json"
for contract in missing-map malformed-map missing-guide missing-index duplicate-map \
  trailing-junk unmatched-code late-malformed-row missing-header changed-policy; do
  cp "$FIX/valid-contract.md" "$FIX/definition/AGENTS.md"
  case "$contract" in
    missing-map) sed 's/^## Portfolio map$/## Other map/' "$FIX/valid-contract.md" > "$FIX/definition/AGENTS.md" ;;
    malformed-map) sed 's/`scope-private-two`/`other-owner\/scope-private-two`/' "$FIX/valid-contract.md" > "$FIX/definition/AGENTS.md" ;;
    missing-guide) mv "$FIX/definition/.claude/guides/egress-and-privacy.md" "$FIX/privacy.md" ;;
    missing-index) sed '/\[egress-and-privacy\]/d' "$FIX/valid-contract.md" > "$FIX/definition/AGENTS.md" ;;
    duplicate-map) printf '\n## Portfolio map\n' >> "$FIX/definition/AGENTS.md" ;;
    trailing-junk) sed 's/`scope-private-two`/`scope-private-two` and others/' "$FIX/valid-contract.md" > "$FIX/definition/AGENTS.md" ;;
    unmatched-code) sed 's/`scope-private-two`/`scope-private-two/' "$FIX/valid-contract.md" > "$FIX/definition/AGENTS.md" ;;
    late-malformed-row) sed 's/`devantler-tech\/cloudflare`/`foreign-owner\/outside`/' "$FIX/valid-contract.md" > "$FIX/definition/AGENTS.md" ;;
    missing-header) sed 's/^| Product | Repo | Path | Instructions |$/| Product | Unknown | Path | Instructions |/' "$FIX/valid-contract.md" > "$FIX/definition/AGENTS.md" ;;
    changed-policy)
      cp "$FIX/definition/.claude/guides/egress-and-privacy.md" "$FIX/privacy.md"
      printf 'A different policy.\n' > "$FIX/definition/.claude/guides/egress-and-privacy.md" ;;
  esac
  run
  check unknown
  check no_repo_queries
  if [ -f "$FIX/privacy.md" ]; then mv "$FIX/privacy.md" "$FIX/definition/.claude/guides/egress-and-privacy.md"; fi
done
cp "$FIX/valid-contract.md" "$FIX/definition/AGENTS.md"
TEST_SCOPE_ORG=another-owner run
check unknown
check no_repo_queries
printf 'outcome authorization: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
scope_test_finished=1
