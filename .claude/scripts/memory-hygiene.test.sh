#!/usr/bin/env bash
# test-inputs: .claude/guides/** .claude/scripts/automation-memory-read.sh
# test-inputs: .claude/scripts/automation-memory-read.test.sh .claude/scripts/contract-text.sh
# test-inputs: .claude/scripts/go-helper-build.sh .claude/skills/portfolio-maintenance/SKILL.md
# test-inputs: .github/workflows/ci.yaml AGENTS.md
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/memory-hygiene-go"
exec go test -race -cover ./...
