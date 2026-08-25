#!/usr/bin/env bash
# Resolve the reviewed plugin's Claude PreToolUse adapter for the consumer's
# agent-scoped portfolio-surveyor hook. This script only locates and verifies
# runtime assets; the plugin's forge-readonly-guard.sh remains the one policy.

set -euo pipefail

HERE=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "${HERE}/../.." && pwd -P)
DESIRED_STATE="${REPO_ROOT}/.claude/plugin-consumption/agentic-engineering.desired-state.json"
PLUGIN_ID="agentic-engineering@devantler-plugins"

die() {
  printf 'portfolio-surveyor forge hook: %s\n' "$1" >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required to verify runtime assets"
  fi
}

command -v jq >/dev/null 2>&1 ||
  die "jq is required to resolve and verify the runtime plugin"
[ -r "${DESIRED_STATE}" ] ||
  die "cannot read consumer desired state: ${DESIRED_STATE}"

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  plugins_root="${CLAUDE_CONFIG_DIR}/plugins"
elif [ -n "${HOME:-}" ]; then
  plugins_root="${HOME}/.claude/plugins"
else
  die "neither CLAUDE_CONFIG_DIR nor HOME resolves the Claude plugin registry"
fi
registry="${plugins_root}/installed_plugins.json"
[ -r "${registry}" ] ||
  die "cannot read runtime plugin registry: ${registry}"

install_path="$(jq -er --arg id "${PLUGIN_ID}" '
  [.plugins[$id][]?.installPath | select(type == "string" and length > 0)]
  | select(length == 1)
  | .[0]
' "${registry}" 2>/dev/null)" ||
  die "runtime registry must name exactly one install path for ${PLUGIN_ID}"
[ -d "${install_path}" ] ||
  die "registered plugin install path does not exist: ${install_path}"

verify_asset() {
  local relative_path="$1"
  local asset="${install_path}/${relative_path}"
  local expected actual

  if [ ! -f "${asset}" ] || [ ! -x "${asset}" ] || [ -L "${asset}" ]; then
    die "runtime asset is not a regular executable: ${relative_path}"
  fi
  expected="$(jq -er --arg path "${relative_path}" '
    [.spec.source.requiredRuntimeAssets[]?
      | select(
          .path == $path
          and .executable == true
          and (.sha256 | type) == "string"
          and (.sha256 | length) == 64
        )
      | .sha256]
    | select(length == 1)
    | .[0]
  ' "${DESIRED_STATE}" 2>/dev/null)" ||
    die "desired state does not declare one executable digest for ${relative_path}"
  actual="$(sha256_file "${asset}")"
  [ "${actual}" = "${expected}" ] ||
    die "runtime asset ${relative_path} sha256 does not match desired state"
}

guard_relative="scripts/forge-readonly-guard.sh"
adapter_relative="scripts/surveyor-forge-readonly.sh"
verify_asset "${guard_relative}"
verify_asset "${adapter_relative}"

# The frontmatter hook is already scoped to portfolio-surveyor. Clear the
# adapter's optional identity scope and pin its test override to the verified
# sibling so inherited environment cannot bypass either half of the wiring.
SURVEYOR_FORGE_READONLY_SCOPE='' \
SURVEYOR_FORGE_READONLY_GUARD="${install_path}/${guard_relative}" \
  exec "${install_path}/${adapter_relative}"
