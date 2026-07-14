#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
run_loop="${1:-${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md}"
routine_prompt="${2:-}"

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

grep -Fq 'classify the saved login as indeterminate' "${run_loop}" ||
  fail "missing the indeterminate sandbox classification"

grep -Fq 'authentication verification unavailable' "${run_loop}" ||
  fail "missing the unavailable host-verification classification"

grep -Fq 'Only an explicit credential rejection from that host-level check proves the saved login invalid.' "${run_loop}" ||
  fail "missing the host-confirmed invalid classification"

grep -Fq 'record only these gate classifications in durable memory' "${run_loop}" ||
  fail "missing the credential-safe memory rule"

if [[ -n "${routine_prompt}" ]]; then
  grep -Fq '.claude/agents/daily-maintainer.md' "${routine_prompt}" ||
    fail "routine prompt does not hand off to the versioned definition"

  if grep -Fq 'gh auth status' "${routine_prompt}"; then
    fail "routine prompt duplicates the versioned authentication preflight"
  fi
fi

echo "maintainer preflight contract: all assertions passed"
