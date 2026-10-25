#!/usr/bin/env bash
# Keep the maintainer-authorized memory observer grant exact and read-only (#4533).
# Synthetic controls prove that a mention elsewhere, a wildcard or a prefix extension
# cannot turn another helper into an Agent Improver implementation surface.
set -euo pipefail
export LC_ALL=C
observer_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
observer_failure=''
observer_tick=$(printf '\140')
root_scope() {
  awk '/^- \*\*Version-controlled\*\*/ {active=1} active {print} active && /^- \*\*Runtime-local\*\*/ {exit}'
}
guide_scope() {
  awk '/^- The observation-plane implementations? at/ {active=1}
    active && /^- / && !/^- The observation-plane implementations? at/ {exit}
    active {print}'
}
observer_paths() {
  grep -oE "${observer_tick}[.]claude/scripts/[^${observer_tick}]+${observer_tick}" \
    | sed "s/^${observer_tick}//; s/${observer_tick}$//" \
    | grep -Fvx '.claude/scripts/*.test.sh' | sort -u
}
check_names() {
  local observer_label=$1 observer_text=$2 observer_names
  observer_names=$(printf '%s\n' "$observer_text" | observer_paths) || {
    observer_failure="$observer_label has no readable observer paths"; return 1;
  }
  if ! grep -Fqx '.claude/scripts/automation-memory-read.sh' <<< "$observer_names"; then
    observer_failure="$observer_label omits the exact memory observer"; return 1
  fi
  if ! grep -Fqx '.claude/scripts/agent-telemetry.sh' <<< "$observer_names"; then
    observer_failure="$observer_label omits telemetry"; return 1
  fi
  if [ "$(printf '%s\n' "$observer_names" | wc -l | tr -d ' ')" != 2 ]; then
    observer_failure="$observer_label grants another source"; return 1
  fi
}
check_scope() {
  local observer_core=$1 observer_guide=$2
  check_names root "$observer_core" && check_names guide "$observer_guide" || return 1
  if ! printf '%s\n' "$observer_guide" | tr '\n' ' ' | grep -qF 'The memory reader is read-only'; then
    observer_failure='memory observer lost read-only restriction'; return 1
  fi
  if ! printf '%s\n' "$observer_guide" | tr '\n' ' ' | grep -qF 'no other script source is included'; then
    observer_failure='unnamed sources are not excluded'; return 1
  fi
}
reject() {
  local observer_case=$1 observer_expected=$2
  shift 2
  if check_scope "$@"; then
    printf 'FAIL %s accepted\n' "$observer_case" >&2; exit 1
  fi
  [ "$observer_failure" = "$observer_expected" ] || {
    printf 'FAIL %s wrong reason: %s\n' "$observer_case" "$observer_failure" >&2; exit 1;
  }
  printf 'PASS %s\n' "$observer_case"
}

fixture_root=$(cat <<'EOF'
- **Version-controlled**: `.claude/scripts/*.test.sh`; observation surfaces:
  `.claude/scripts/agent-telemetry.sh` and
  `.claude/scripts/automation-memory-read.sh`.
- **Runtime-local**: schedules.
EOF
)
fixture_guide=$(cat <<'EOF'
- The observation-plane implementations at
  `.claude/scripts/agent-telemetry.sh` and
  `.claude/scripts/automation-memory-read.sh` are definition surfaces;
  no other script source is included by this grant.
  The memory reader is read-only.
- Deployment configuration stays separate.
EOF
)
fixture_core=$(printf '%s\n' "$fixture_root" | root_scope)
fixture_scope=$(printf '%s\n' "$fixture_guide" | guide_scope)
check_scope "$fixture_core" "$fixture_scope" || { printf 'FAIL positive fixture: %s\n' "$observer_failure"; exit 1; }
reject extra-source 'guide grants another source' "$fixture_core" "$fixture_scope
  \`.claude/scripts/other.sh\`"
reject wildcard 'guide grants another source' "$fixture_core" "$fixture_scope
  \`.claude/scripts/*.sh\`"
reject prefix-extension 'guide omits the exact memory observer' "$fixture_core" \
  "$(printf '%s\n' "$fixture_scope" | sed 's/automation-memory-read.sh/automation-memory-read.sh.extra/')"
misplaced=$(printf '%s\n' "$fixture_guide" | sed '/automation-memory-read.sh/d'; printf '\n%s%s%s\n' "$observer_tick" '.claude/scripts/automation-memory-read.sh' "$observer_tick")
reject outside-grant 'guide omits the exact memory observer' "$fixture_core" "$(printf '%s\n' "$misplaced" | guide_scope)"
reject writable-reader 'memory observer lost read-only restriction' "$fixture_core" \
  "$(printf '%s\n' "$fixture_scope" | sed 's/read-only/read-write/')"
reject open-source-grant 'unnamed sources are not excluded' "$fixture_core" \
  "$(printf '%s\n' "$fixture_scope" | sed '/no other script source is included/d')"

core=$(root_scope < "$observer_root/AGENTS.md")
guide=$(guide_scope < "$observer_root/.claude/guides/definition-surfaces.md")
check_scope "$core" "$guide" || { printf 'FAIL live observer grant: %s\n' "$observer_failure" >&2; exit 1; }
printf 'PASS live observer grant and six negative controls\n'
