#!/usr/bin/env bash
# test-timeout-seconds: 180
# Exercise the shipped CLI with synthetic metadata and record every forge call.
# No native transcript store, GitHub credential or real repository is accessed.
set -euo pipefail
# A Git hook can export these; each would redirect every fixture command into
# the caller's repository. Git names its own routing variables.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)
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
    "$BASH" "$FIX/definition/.claude/scripts/agent-telemetry.sh" --section outcomes \
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

# Local observations are selectors, never authority. Exercise the real CLI on
# synthetic repositories and trace traversal before any transcript is read.
rmdir "$FIX/corpus/.git"
git -C "$FIX/corpus" init -q
git -C "$FIX/corpus" remote add origin https://github.com/devantler-tech/monorepo.git
for pair in 'allowed scope-public' 'private scope-denied' 'mapped scope-private' 'archived scope-retired'; do
  IFS=' ' read -r child repository <<<"$pair"
  mkdir -p "$FIX/corpus/$child"
  git -C "$FIX/corpus/$child" init -q
  git -C "$FIX/corpus/$child" remote add origin "https://github.com/devantler-tech/$repository.git"
done
mkdir -p "$FIX/corpus/unlisted"
git -C "$FIX/corpus/unlisted" init -q
git -C "$FIX/corpus/unlisted" remote add origin https://github.com/excluded-owner/fixture.git
mkdir -p "$FIX/home/codex/sessions" "$FIX/projects"
SCOPE_REAL_FIND=$(command -v find)
export SCOPE_REAL_FIND
cat > "$FIX/bin/find" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$SCOPE_WALK_TRACE"
exec "$SCOPE_REAL_FIND" "$@"
EOF
chmod +x "$FIX/bin/find"
write_codex() {
  printf '{"type":"session_meta","payload":{"cwd":"%s","git":{"repository_url":"%s"}}}\n' "$1" "${2-}" > "$FIX/home/codex/sessions/scope.jsonl"
  printf '%s\n' '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"SCOPE_ADMISSION_CANARY"}]}}' >> "$FIX/home/codex/sessions/scope.jsonl"
}
transcript_run() {
  jq -s '.' "$FIX/rows.json" > "$FIX/pages.json"
  : > "$FIX/trace"; : > "$FIX/walk-trace"
  set +e
  PATH="$FIX/bin:$PATH" HOME="$FIX/home" CODEX_HOME="$FIX/home/codex" \
    CLAUDE_PROJECTS_DIR="${SCOPE_PROJECTS:-$FIX/projects}" MONOREPO_DIR="$FIX/corpus" \
    PORTFOLIO_PATHS="${SCOPE_SELECTORS:-$FIX/corpus}" PORTFOLIO_ORG=devantler-tech \
    AGENT_TELEMETRY_RUNTIME=codex SCOPE_TRACE="$FIX/trace" SCOPE_WALK_TRACE="$FIX/walk-trace" \
    SCOPE_PAGES="$FIX/pages.json" SCOPE_ROWS="$FIX/rows.json" SCOPE_LIST_FAIL="${SCOPE_LIST_FAIL:-0}" \
    "$BASH" "$FIX/definition/.claude/scripts/agent-telemetry.sh" --section efficiency \
      > "$FIX/transcript-output" 2>&1
  RC=$?
  set -e
}
measured() {
  if [ "$RC" = 0 ] && grep -qF '[BOTH instances: 0 Claude + 1 Codex sessions]' "$FIX/transcript-output"; then return 0; fi
  printf 'admitted fixture exit=%s\n' "$RC" >&2
  head -n 10 "$FIX/transcript-output" >&2
  return 1
}
not_measured() { ! grep -Eq '\[BOTH instances: ([1-9][0-9]* Claude|[0-9]+ Claude \+ [1-9][0-9]* Codex)' "$FIX/transcript-output"; }
excluded() {
  if [ "$RC" = 0 ] && grep -qF '(no sessions in window — neither instance)' "$FIX/transcript-output"; then return 0; fi
  printf 'excluded fixture exit=%s\n' "$RC" >&2
  head -n 10 "$FIX/transcript-output" >&2
  return 1
}
not_walked() { ! grep -qF "$1" "$FIX/walk-trace"; }
walked() { grep -qxF "$1" "$FIX/walk-trace"; }
for cwd in "$FIX/corpus" "$FIX/corpus/allowed" "$FIX/corpus/mapped"; do
  write_codex "$cwd"
  transcript_run
  check measured
done
for remote in https://github.com/devantler-tech/scope-public.git \
  git@github.com:devantler-tech/scope-private.git \
  ssh://git@github.com/devantler-tech/scope-public.git; do
  write_codex "$FIX/home/codex/worktrees/gone/corpus" "$remote"
  transcript_run
  check measured
done
for remote in https://github.com/devantler-tech/scope-retired.git \
  https://github.com/devantler-tech/scope-denied.git \
  https://notgithub.com/devantler-tech/scope-public.git \
  https://github.com/excluded-owner/fixture.git; do
  write_codex "$FIX/home/codex/worktrees/gone/corpus" "$remote"
  transcript_run
  check excluded
done
for child in unlisted private archived; do
  write_codex "$FIX/corpus/$child"
  transcript_run
  check excluded
done
write_codex "$FIX/corpus/private"
SCOPE_SELECTORS="$FIX/corpus/private" transcript_run
check excluded
GIT_DIR="$FIX/corpus/.git" transcript_run
check excluded
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/devantler-tech/monorepo.git.insteadOf \
  GIT_CONFIG_VALUE_0=https://github.com/devantler-tech/scope-denied.git transcript_run
check excluded
SCOPE_SELECTORS="$FIX/missing-selector" transcript_run
check test "$RC" = 2
check not_walked "$FIX/home/codex/sessions"
write_codex "$FIX/corpus"
SCOPE_LIST_FAIL=1 transcript_run
check test "$RC" = 2
check not_measured
check not_walked "$FIX/home/codex/sessions"
cp "$FIX/definition/AGENTS.md" "$FIX/transcript-valid-contract.md"
printf 'Missing authorization contract.\n' > "$FIX/definition/AGENTS.md"
transcript_run
check test "$RC" = 2
check not_measured
check not_walked "$FIX/home/codex/sessions"
mv "$FIX/transcript-valid-contract.md" "$FIX/definition/AGENTS.md"

# A broken worktree configuration can report an unrelated working tree root.
# The selected cwd must actually belong to the repository supplying identity.
write_codex "$FIX/corpus/allowed"
git -C "$FIX/corpus/allowed" config core.worktree "$FIX/corpus/mapped"
transcript_run
check not_measured
check test "$RC" = 2
git --git-dir="$FIX/corpus/allowed/.git" config --unset core.worktree

# A slug alone does not authorize an archived or private submodule. In
# particular, placing the session store under the aggregator grants no bypass.
rm "$FIX/home/codex/sessions/scope.jsonl"
cat > "$FIX/corpus/.gitmodules" <<'EOF'
[submodule "private"]
  path = private
  url = https://github.com/devantler-tech/scope-denied.git
[submodule "allowed"]
  path = allowed
  url = https://github.com/devantler-tech/scope-public.git
EOF
for child in private allowed; do
  slug=$(printf '%s' "$FIX/corpus/$child" | tr / -)
  mkdir -p "$FIX/projects/$slug"
  # A slug selects a source, while the source's own repository attests its
  # identity independently. A native unbound store is tested below as UNKNOWN.
  git -C "$FIX/projects/$slug" init -q
  if [ "$child" = allowed ]; then
    git -C "$FIX/projects/$slug" remote add origin https://github.com/devantler-tech/scope-public.git
  else
    git -C "$FIX/projects/$slug" remote add origin https://github.com/devantler-tech/scope-denied.git
  fi
  printf '{"type":"user","cwd":"%s","message":{"content":"SCOPE_ADMISSION_CANARY"}}\n' \
    "$FIX/corpus/$child" > "$FIX/projects/$slug/scope.jsonl"
done
transcript_run
check not_walked "$FIX/projects/$(printf '%s' "$FIX/corpus/private" | tr / -)"
check walked "$FIX/projects/$(printf '%s' "$FIX/corpus/allowed" | tr / -)"
check test "$RC" = 0
check grep -qF '[BOTH instances: 1 Claude + 0 Codex sessions]' "$FIX/transcript-output"
allowed_slug=$(printf '%s' "$FIX/corpus/allowed" | tr / -)
mkdir -p "$FIX/projects/$allowed_slug/scope/subagents"
cp "$FIX/projects/$allowed_slug/scope.jsonl" "$FIX/projects/$allowed_slug/scope/subagents/agent-child.jsonl"
transcript_run
check grep -qF '[BOTH instances: 2 Claude + 0 Codex sessions]' "$FIX/transcript-output"
check grep -qF '1 parent + 1 delegated' "$FIX/transcript-output"
mkdir -p "$FIX/corpus/store"
private_slug=$(printf '%s' "$FIX/corpus/private" | tr / -)
mkdir -p "$FIX/corpus/store/$private_slug"
cp "$FIX/projects/$private_slug/scope.jsonl" "$FIX/corpus/store/$private_slug/"
SCOPE_PROJECTS="$FIX/corpus/store" transcript_run
check not_walked "$FIX/corpus/store/$private_slug"
check excluded

# An unpopulated Gitlink slot inherits the aggregator's remote when asked with
# git -C. That inherited identity is not evidence about its recorded product.
mkdir -p "$FIX/corpus/unpopulated"
cat >> "$FIX/corpus/.gitmodules" <<'EOF'
[submodule "unpopulated"]
  path = unpopulated
  url = https://github.com/devantler-tech/scope-public.git
EOF
write_codex "$FIX/corpus/unpopulated"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check not_measured
check test "$RC" = 2

# Neutralizing repository-environment isolation really admits the private
# fixture. This control cannot pass merely because collection stopped working.
# Keep the corpus identical on both sides of the mutation; a separate alias
# mismatch must not conceal the repository-routing defect this control tests.
mv "$FIX/corpus/.gitmodules" "$FIX/routing-gitmodules"
write_codex "$FIX/corpus/private"
GIT_DIR="$FIX/corpus/.git" transcript_run
check excluded
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/devantler-tech/monorepo.git.insteadOf \
  GIT_CONFIG_VALUE_0=https://github.com/devantler-tech/scope-denied.git transcript_run
check excluded
cp "$FIX/definition/.claude/scripts/agent-telemetry.sh" "$FIX/collector-before-routing-mutation.sh"
awk '
  /^transcript_git\(\) \{/ { print "transcript_git() { git \"$@\"; }"; inside = 1; next }
  inside && /^\}/ { inside = 0; next }
  !inside { print }
' "$FIX/collector-before-routing-mutation.sh" > "$FIX/definition/.claude/scripts/agent-telemetry.sh"
if cmp -s "$FIX/collector-before-routing-mutation.sh" "$FIX/definition/.claude/scripts/agent-telemetry.sh"; then
  check false
else
  write_codex "$FIX/corpus/private"
  GIT_DIR="$FIX/corpus/.git" transcript_run
  check grep -qF '1 Codex sessions]' "$FIX/transcript-output"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/devantler-tech/monorepo.git.insteadOf \
    GIT_CONFIG_VALUE_0=https://github.com/devantler-tech/scope-denied.git transcript_run
  check grep -qF '1 Codex sessions]' "$FIX/transcript-output"
fi
cp "$FIX/collector-before-routing-mutation.sh" "$FIX/definition/.claude/scripts/agent-telemetry.sh"
mv "$FIX/routing-gitmodules" "$FIX/corpus/.gitmodules"

# Live Codex worktrees use the same repository and product-slot checks as a
# selected ordinary checkout, including a cwd that has since been removed.
worktree_root="$FIX/home/codex/worktrees/native/corpus"
mkdir -p "$worktree_root/unpopulated"
git -C "$worktree_root" init -q
git -C "$worktree_root" remote add origin https://github.com/devantler-tech/monorepo.git
cat > "$worktree_root/.gitmodules" <<'SLOT'
[submodule "unpopulated"]
  path = unpopulated
  url = https://github.com/devantler-tech/scope-public.git
SLOT
write_codex "$worktree_root/unpopulated"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check not_measured
check test "$RC" = 2
rmdir "$worktree_root/unpopulated"
write_codex "$worktree_root/unpopulated"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check not_measured
check test "$RC" = 2
write_codex "$worktree_root"
git -C "$worktree_root" config core.worktree "$FIX/corpus/mapped"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check not_measured
check test "$RC" = 2
git --git-dir="$worktree_root/.git" config --unset core.worktree
write_codex "$worktree_root/ordinary-deleted-directory"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check measured

# A remote is one value, not a list of independently admissible lines.
git -C "$FIX/corpus/private" remote set-url origin $'https://github.com/devantler-tech/scope-denied\ndevantler-tech/scope-public.git'
write_codex "$FIX/corpus/private"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check excluded
git -C "$FIX/corpus/private" remote set-url origin https://github.com/devantler-tech/scope-denied.git

# The project-store slug survives worktree removal. A confirmed removal is a
# visible coverage exclusion; a still-existing root with broken metadata is not.
rm "$FIX/home/codex/sessions/scope.jsonl"
claude_root="$FIX/corpus/.claude/worktrees/calm-quiet-abcdef"
claude_slug="$(printf '%s' "$FIX/corpus" | tr / -)--claude-worktrees-calm-quiet-abcdef"
mkdir -p "$FIX/stale-projects/$claude_slug"
printf '{"type":"user","message":{"content":"SCOPE_ADMISSION_CANARY"}}\n' \
  > "$FIX/stale-projects/$claude_slug/scope.jsonl"
SCOPE_PROJECTS="$FIX/stale-projects" transcript_run
check test "$RC" = 0
check excluded
check not_walked "$FIX/stale-projects/$claude_slug"
check grep -qF 'Claude project folders left out, worktree confirmed gone: 1' "$FIX/transcript-output"
mkdir -p "$claude_root"
SCOPE_PROJECTS="$FIX/stale-projects" transcript_run
check test "$RC" = 2
check not_walked "$FIX/stale-projects/$claude_slug"
git -C "$claude_root" init -q
git -C "$claude_root" remote add origin https://github.com/devantler-tech/scope-public.git
git -C "$FIX/stale-projects/$claude_slug" init -q
git -C "$FIX/stale-projects/$claude_slug" remote add origin https://github.com/devantler-tech/scope-public.git
SCOPE_PROJECTS="$FIX/stale-projects" transcript_run
check test "$RC" = 0
check grep -qF '[BOTH instances: 1 Claude + 0 Codex sessions]' "$FIX/transcript-output"

# Failure to establish a populated product's identity must stop preparation,
# rather than shrink the admitted set and publish clean measurements.
unresolved_product() {
  SCOPE_PROJECTS="$FIX/no-projects" transcript_run
  check test "$RC" = 2
  check not_measured
  check not_walked "$FIX/home/codex/sessions"
}
write_codex "$FIX/corpus"
cp "$FIX/corpus/allowed/.git/config" "$FIX/allowed-git-config"
cp "$FIX/corpus/.gitmodules" "$FIX/valid-gitmodules"
printf '[broken\n' > "$FIX/corpus/allowed/.git/config"
unresolved_product
cp "$FIX/allowed-git-config" "$FIX/corpus/allowed/.git/config"
git -C "$FIX/corpus" config --file .gitmodules --unset submodule.allowed.url
unresolved_product
cp "$FIX/valid-gitmodules" "$FIX/corpus/.gitmodules"
git -C "$FIX/corpus" config --file .gitmodules submodule.allowed.url https://github.com/devantler-tech/scope-private.git
unresolved_product
cp "$FIX/valid-gitmodules" "$FIX/corpus/.gitmodules"
git -C "$FIX/corpus" config --file .gitmodules submodule.allowed.url $'https://github.com/devantler-tech/scope-public.git\n'
unresolved_product
cp "$FIX/valid-gitmodules" "$FIX/corpus/.gitmodules"
cat >> "$FIX/corpus/.gitmodules" <<'DUPLICATE'
[submodule "duplicate"]
  path = allowed
  url = https://github.com/devantler-tech/scope-public.git
DUPLICATE
unresolved_product
cp "$FIX/valid-gitmodules" "$FIX/corpus/.gitmodules"

# Command substitution must not trim a malformed remote into an admitted URL.
git -C "$FIX/corpus/private" remote set-url origin $'https://github.com/devantler-tech/scope-public.git\n'
write_codex "$FIX/corpus/private"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check excluded
git -C "$FIX/corpus/private" remote set-url origin https://github.com/devantler-tech/scope-denied.git

# Preserve the complete Git configuration values, including spaces in the
# submodule name and path. An unpopulated slot cannot borrow its parent's remote.
mkdir -p "$FIX/corpus/space folder "
cat >> "$FIX/corpus/.gitmodules" <<'SPACED'
[submodule "spaced product"]
  path = "space folder "
  url = https://github.com/devantler-tech/scope-public.git
SPACED
write_codex "$FIX/corpus/space folder "
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check test "$RC" = 2
check not_measured
git -C "$FIX/corpus/space folder " init -q
git -C "$FIX/corpus/space folder " remote add origin https://github.com/devantler-tech/scope-public.git
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check measured

# Missing cwd routes still belong to the nearest surviving repository. They
# cannot borrow the outer worktree when a nested excluded checkout survives.
rmdir "$FIX/corpus/unpopulated"
write_codex "$FIX/corpus/unpopulated"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check test "$RC" = 2
check not_measured
mkdir -p "$FIX/corpus/unpopulated"
# An ordinary name can have belonged to a different checkout. Once that
# checkout is removed, the broad selector cannot recover its former identity.
mkdir -p "$FIX/corpus/ordinary-deleted-directory"
git -C "$FIX/corpus/ordinary-deleted-directory" init -q
git -C "$FIX/corpus/ordinary-deleted-directory" remote add origin https://github.com/devantler-tech/scope-denied.git
write_codex "$FIX/corpus/ordinary-deleted-directory"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check excluded
rm -rf "$FIX/corpus/ordinary-deleted-directory"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check test "$RC" = 2
check not_measured
mkdir -p "$worktree_root/private"
git -C "$worktree_root/private" init -q
git -C "$worktree_root/private" remote add origin https://github.com/devantler-tech/scope-denied.git
write_codex "$worktree_root/private/deleted-directory"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check excluded
write_codex "$worktree_root/.claude/worktrees/gone/deleted-directory"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check test "$RC" = 2
check not_measured
# A misplaced core.worktree can name an authorized ancestor and still contain
# the selected cwd. The nearest checkout marker must agree with that root.
write_codex "$FIX/corpus"
git -C "$FIX/corpus/allowed" config core.worktree "$FIX/corpus"
unresolved_product
cp "$FIX/allowed-git-config" "$FIX/corpus/allowed/.git/config"
# A selected direct store is itself an observation source. Unreadable metadata
# cannot become a clean zero, nor authorize matching child project namespaces.
rm "$FIX/home/codex/sessions/scope.jsonl"
direct_store="$FIX/corpus/nested-store"
mkdir -p "$direct_store"
git -C "$direct_store" init -q
git -C "$direct_store" remote add origin https://github.com/devantler-tech/scope-public.git
printf '{"type":"user","message":{"content":"SCOPE_ADMISSION_CANARY"}}\n' > "$direct_store/scope.jsonl"
SCOPE_PROJECTS="$direct_store" transcript_run
check test "$RC" = 0
check grep -qF '[BOTH instances: 1 Claude + 0 Codex sessions]' "$FIX/transcript-output"
cp "$direct_store/.git/config" "$FIX/direct-store-git-config"
printf '[broken\n' > "$direct_store/.git/config"
SCOPE_PROJECTS="$direct_store" transcript_run
check test "$RC" = 2
check grep -qF 'UNKNOWN: the Claude projects folder' "$FIX/transcript-output"
check not_measured
check not_walked "$direct_store"
mkdir -p "$direct_store/$allowed_slug"
cp "$direct_store/scope.jsonl" "$direct_store/$allowed_slug/scope.jsonl"
SCOPE_PROJECTS="$direct_store" transcript_run
check test "$RC" = 2
check grep -qF 'UNKNOWN: the Claude projects folder' "$FIX/transcript-output"
check not_measured
check not_walked "$direct_store"
cp "$FIX/direct-store-git-config" "$direct_store/.git/config"
for repository in scope-denied scope-retired; do
  git -C "$direct_store" remote set-url origin "https://github.com/devantler-tech/$repository.git"
  SCOPE_PROJECTS="$direct_store" transcript_run
  check test "$RC" = 0
  check excluded
  check not_walked "$direct_store"
done
git -C "$direct_store" remote set-url origin https://github.com/devantler-tech/scope-public.git
git -C "$direct_store/$allowed_slug" init -q
git -C "$direct_store/$allowed_slug" remote add origin https://github.com/devantler-tech/scope-public.git
SCOPE_PROJECTS="$direct_store" transcript_run
check test "$RC" = 0
check grep -qF '[BOTH instances: 2 Claude + 0 Codex sessions]' "$FIX/transcript-output"
# Parent-process configuration files cannot rewrite an excluded origin into
# an admitted one, independently of the repository's own configuration.
git config --file "$FIX/routing.config" \
  url.https://github.com/devantler-tech/monorepo.git.insteadOf https://github.com/excluded-owner/fixture.git
write_codex "$FIX/corpus/unlisted"
GIT_CONFIG_SYSTEM="$FIX/routing.config" SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check excluded
GIT_CONFIG_GLOBAL="$FIX/routing.config" SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check excluded
# A matching project slug cannot grant a symlink target admission.
rm "$FIX/home/codex/sessions/scope.jsonl"
mkdir -p "$FIX/linked-projects" "$FIX/foreign-store/subagents"
printf '%s\n' '{"type":"user","message":{"content":"SYMLINK_ADMISSION_CANARY"}}' > "$FIX/foreign-store/subagents/agent-foreign.jsonl"
ln -s "$FIX/foreign-store" "$FIX/linked-projects/$allowed_slug"
SCOPE_PROJECTS="$FIX/linked-projects" transcript_run
check test "$RC" = 2
check not_measured
check not_walked "$FIX/linked-projects/$allowed_slug/subagents"
# Native project slugs lose the distinction between a slash and a literal
# hyphen. The selected checkout cannot attest an independently stored corpus.
collision_checkout="$FIX/corpus/slug-collision"
collision_other="$FIX/corpus/slug/collision"
mkdir -p "$collision_checkout" "$collision_other" "$FIX/corpus/collision-projects"
git -C "$collision_checkout" init -q
git -C "$collision_checkout" remote add origin https://github.com/devantler-tech/monorepo.git
git -C "$collision_other" init -q
git -C "$collision_other" remote add origin https://github.com/excluded-owner/fixture.git
collision_slug=$(printf '%s' "$collision_checkout" | tr / -)
check test "$collision_slug" = "$(printf '%s' "$collision_other" | tr / -)"
collision_store="$FIX/corpus/collision-projects/$collision_slug"
mkdir -p "$collision_store/subagents"
printf '{"type":"user","message":{"content":"COLLIDING_STORE_CANARY"}}\n' > "$collision_store/subagents/agent-foreign.jsonl"
SCOPE_SELECTORS="$collision_checkout" SCOPE_PROJECTS="$FIX/corpus/collision-projects" transcript_run
check test "$RC" = 2
check not_measured
check not_walked "$collision_store/subagents"
# An independently bound store for a different admitted product still cannot
# borrow the selected checkout's identity. No transcript needs to be opened.
git -C "$collision_store" init -q
git -C "$collision_store" remote add origin https://github.com/devantler-tech/scope-public.git
SCOPE_SELECTORS="$collision_checkout" SCOPE_PROJECTS="$FIX/corpus/collision-projects" transcript_run
check test "$RC" = 2
check not_measured
check not_walked "$collision_store/subagents"
# Preserve real parent/delegated coverage once both source identities agree.
git -C "$collision_store" remote set-url origin https://github.com/devantler-tech/monorepo.git
rm "$collision_store/subagents/agent-foreign.jsonl"
printf '{"type":"user","message":{"content":"OWNED_STORE_CANARY"}}\n' > "$collision_store/owned.jsonl"
mkdir -p "$collision_store/owned/subagents"
cp "$collision_store/owned.jsonl" "$collision_store/owned/subagents/agent-owned.jsonl"
SCOPE_SELECTORS="$collision_checkout" SCOPE_PROJECTS="$FIX/corpus/collision-projects" transcript_run
check test "$RC" = 0
check grep -qF '[BOTH instances: 2 Claude + 0 Codex sessions]' "$FIX/transcript-output"
check grep -qF '1 parent + 1 delegated' "$FIX/transcript-output"
check walked "$collision_store/owned/subagents"
# A colon in a declared path cannot add another literal selector. Both paths
# have admitted origins so repository authorization cannot mask the escape.
cp "$FIX/corpus/.gitmodules" "$FIX/before-colon-gitmodules"
colon_outside="$FIX/unselected-repository"
colon_sub="colon:$colon_outside"
mkdir -p "$colon_outside" "$FIX/corpus/$colon_sub"
git -C "$colon_outside" init -q
git -C "$colon_outside" remote add origin https://github.com/devantler-tech/scope-public.git
git -C "$FIX/corpus/$colon_sub" init -q
git -C "$FIX/corpus/$colon_sub" remote add origin https://github.com/devantler-tech/scope-public.git
git -C "$FIX/corpus" config --file .gitmodules submodule.colon.path "$colon_sub"
git -C "$FIX/corpus" config --file .gitmodules submodule.colon.url https://github.com/devantler-tech/scope-public.git
write_codex "$colon_outside"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check test "$RC" = 2
check not_measured
check not_walked "$FIX/home/codex/sessions"
cp "$FIX/before-colon-gitmodules" "$FIX/corpus/.gitmodules"
write_codex "$FIX/corpus/allowed"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check measured
# A JSON NUL cannot be part of a real cwd. Shell read must not discard it and
# turn malformed metadata into an admitted existing path.
jq -cn --arg p "$FIX/corpus/allowed" '{type:"session_meta",payload:{cwd:($p+"\u0000")}}' > "$FIX/home/codex/sessions/scope.jsonl"
printf '%s\n' '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"NUL_ADMISSION_CANARY"}]}}' >> "$FIX/home/codex/sessions/scope.jsonl"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check excluded
check not_measured
write_codex "$FIX/corpus/allowed"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check measured
# A removed native worktree relies on the recorded remote, so apply the same
# complete-value requirement there and retain the legitimate historical case.
nul_worktree="$FIX/home/codex/worktrees/nul/corpus"
jq -cn --arg p "$nul_worktree" '{type:"session_meta",payload:{cwd:$p,git:{repository_url:("https://github.com/devantler-tech/monorepo.git"+"\u0000")}}}' > "$FIX/home/codex/sessions/scope.jsonl"
printf '%s\n' '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"NUL_ADMISSION_CANARY"}]}}' >> "$FIX/home/codex/sessions/scope.jsonl"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check excluded
check not_measured
# The same allow-list refuses every control character, not only the ones a
# past finding named: a tab in a cwd is not a real recorded folder either.
tab_cwd="$(printf '%s\tx' "$FIX/corpus/allowed")"
jq -cn --arg p "$tab_cwd" '{type:"session_meta",payload:{cwd:$p}}' > "$FIX/home/codex/sessions/scope.jsonl"
printf '%s\n' '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"NUL_ADMISSION_CANARY"}]}}' >> "$FIX/home/codex/sessions/scope.jsonl"
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check excluded
check not_measured
write_codex "$nul_worktree" https://github.com/devantler-tech/monorepo.git
SCOPE_PROJECTS="$FIX/no-projects" transcript_run
check measured
printf 'outcome authorization: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
scope_test_finished=1
