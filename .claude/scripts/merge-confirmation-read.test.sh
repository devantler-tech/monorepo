#!/usr/bin/env bash
# Keep the CI entrypoint stable; the complete guard and its fixtures live in Go (#2582).
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Definitions live outside the module, so Go's cached test result is not evidence.
exec go -C "${script_dir}/merge-confirmation-read-go" test -count=1 ./...
