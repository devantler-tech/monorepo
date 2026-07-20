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

grep -Fq 'env -u GH_TOKEN -u GITHUB_TOKEN gh auth status --active --hostname github.com' "${run_loop}" ||
  fail "saved-login probe does not clear both injected-token variables"

grep -Fq "active account other than \`devantler\`" "${run_loop}" ||
  fail "saved-login fallback does not cover a valid token for the wrong account"

grep -Fq "If the saved login is selected, prefix every subsequent \`gh\` command with \`env -u GH_TOKEN -u GITHUB_TOKEN\`" "${run_loop}" ||
  fail "saved-login fallback does not neutralize env tokens for later gh commands"

grep -Fq "If only the host-level saved-login check succeeds, run every subsequent \`gh\` command through that" "${run_loop}" ||
  fail "host-only keychain access is not preserved for later gh commands"

grep -Fq 'approved host-level execution path' "${run_loop}" ||
  fail "missing the required host-level keychain retry"

grep -Fq 'A sandbox-only failure is not evidence that the saved login is invalid.' "${run_loop}" ||
  fail "missing the fail-closed sandbox false-negative rule"

grep -Fq 'classify the saved login as indeterminate' "${run_loop}" ||
  fail "missing the indeterminate sandbox classification"

grep -Fq 'authentication verification unavailable' "${run_loop}" ||
  fail "missing the unavailable host-verification classification"

grep -Fq 'Only an explicit credential rejection' "${run_loop}" ||
  fail "missing the host-confirmed invalid classification"

grep -Fq 'GitHub service degraded' "${run_loop}" ||
  fail "missing the REST 5xx / service-degraded classification"

grep -Fq "gh api graphql -f query='{viewer{login}}'" "${run_loop}" ||
  fail "missing the authenticated GraphQL viewer.login fallback"

grep -Fq 'HTTP 401/403' "${run_loop}" ||
  fail "missing the explicit 401/403 authentication-rejection criterion"

grep -Fq 'A REST 5xx with a successful GraphQL' "${run_loop}" ||
  fail "missing the REST-503-plus-GraphQL-success regression rule"

grep -Fq 'recommend' "${run_loop}" && grep -Fq 'gh auth login' "${run_loop}" ||
  fail "missing the gh-auth-login-only-on-confirmed-rejection handoff rule"

# The handoff must be gated on confirmed rejection — not on every auth-status failure.
grep -Fq 'and **only then** recommend' "${run_loop}" ||
  fail "missing the confirmed-rejection gate before recommending gh auth login"

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
