#!/usr/bin/env bash
#
# renovate-dashboard-drift.sh
#
# Thin wrapper around the Go guard in renovate-dashboard-drift-go/, matching
# memory-hygiene.sh: build to a temporary binary, run it, propagate its exit
# code.
#
# Exit codes:
#   0  every declared Renovate config resolves to a disabled Dependency Dashboard
#   1  at least one resolves to enabled
#   2  the check could not verify what it claims to verify (a declared root is
#      not checked out, a config is unparseable, or a preset is unknown)
#
# The check is network-free: it reads .gitmodules and the already-checked-out
# submodule working trees, never the GitHub API. CI therefore has to check out
# the submodules that carry a config before running it — see ci.yaml.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
drift_binary=""
if ! drift_binary="$(mktemp "${TMPDIR:-/tmp}/renovate-dashboard-drift.XXXXXX")"; then
  echo "renovate-dashboard-drift: failed to allocate temporary binary" >&2
  exit 2
fi

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  rm -f -- "$drift_binary"
}
trap cleanup EXIT

if ! go -C "$script_dir/renovate-dashboard-drift-go" build -o "$drift_binary" .; then
  echo "renovate-dashboard-drift: failed to build Go guard" >&2
  exit 2
fi

set +e
"$drift_binary" "$@"
drift_exit_code=$?
set -e

exit "$drift_exit_code"
