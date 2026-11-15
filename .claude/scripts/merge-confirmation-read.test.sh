#!/usr/bin/env bash
# test-inputs: .claude/**/*.json .claude/**/*.md .claude/guides/** .claude/scripts/contract-text.sh
# test-inputs: .github/workflows/ci.yaml AGENTS.md libraries/agent-plugins
# Keep the CI entrypoint stable; the complete guard and its fixtures live in Go (#2582).
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Definitions live outside the module, so Go's cached test result is not evidence.
exec go -C "${script_dir}/merge-confirmation-read-go" test -count=1 ./...
