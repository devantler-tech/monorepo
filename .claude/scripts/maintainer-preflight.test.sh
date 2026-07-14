#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
run_loop="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"

fail() {
  echo "maintainer preflight contract: FAIL — $*" >&2
  exit 1
}

grep -Fq 'sandboxed' "${run_loop}" ||
  fail "missing the sandboxed saved-login failure case"

grep -Fq 'env -u GITHUB_TOKEN gh auth status' "${run_loop}" ||
  fail "missing the injected-token fallback command"

grep -Fq 'approved host-level execution path' "${run_loop}" ||
  fail "missing the required host-level keychain retry"

grep -Fq 'A sandbox-only failure is not evidence that the saved login is invalid.' "${run_loop}" ||
  fail "missing the fail-closed sandbox false-negative rule"

echo "maintainer preflight contract: all assertions passed"
