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

# Bash 3.2 reports a `set -u` abort to an EXIT trap as status 0, and the trap's own successful
# cleanup then becomes the script's status. Completion is recorded explicitly, so reaching the end is
# the only way a zero status leaves this script; an abort reports UNKNOWN (monorepo#3414).
renovate_dashboard_drift_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  rm -f -- "$drift_binary"
  if [ "$renovate_dashboard_drift_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "renovate-dashboard-drift: aborted before finishing; reporting UNKNOWN rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT

if ! go -C "$script_dir/renovate-dashboard-drift-go" build -o "$drift_binary" .; then
  echo "renovate-dashboard-drift: failed to build Go guard" >&2
  exit 2
fi

drift_exit_code=0
"$drift_binary" "$@" || drift_exit_code=$?

renovate_dashboard_drift_finished=1
exit "$drift_exit_code"
