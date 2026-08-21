#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
run_loop="${1:-${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md}"
routine_prompt="${2:-}"
cursor_loader="${3:-${repo_root}/.claude/loaders/cursor-daily-ai-engineer.md}"

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

grep -Fq "gh api graphql --hostname github.com -f query='{viewer{login}}'" "${run_loop}" ||
  fail "missing the authenticated GraphQL viewer.login fallback pinned to github.com"

grep -Fq 'rate-limited 403/429' "${run_loop}" ||
  fail "missing the rate-limit-as-service-degradation classification"

grep -Fq 'same host and credential context' "${run_loop}" ||
  fail "GraphQL fallback does not preserve the failing probe's credential context"

grep -Fq 'HTTP **401**' "${run_loop}" ||
  fail "missing the explicit HTTP 401 authentication-rejection criterion"

grep -Fq 'non-rate-limit' "${run_loop}" ||
  fail "missing the non-rate-limit 403 credential-rejection criterion"

grep -Fq 'gh api --include --hostname github.com user' "${run_loop}" ||
  fail "missing the observable REST status-and-header probe"

grep -Fq "The generic \`gh auth status\` invalid-token message is not conclusive" "${run_loop}" ||
  fail "gh auth status can still turn a REST outage into an invalid-credential verdict"

grep -Fq 'Reject explicit authentication failures before inspecting the response body or format.' "${run_loop}" ||
  fail "explicit authentication rejection does not precede response-shape classification"

grep -Fq "Compare \`viewer.login\` with this deployment's exact expected identity" "${run_loop}" ||
  fail "GraphQL fallback does not use the deployment-scoped expected identity"

grep -Fq "GraphQL API identity is \`cursor[bot]\`" "${run_loop}" ||
  fail "GraphQL fallback uses Cursor's PR-author identity instead of its API identity"

grep -Fq "A mismatch is \`wrong GitHub identity\`" "${run_loop}" ||
  fail "GraphQL fallback does not classify the wrong-identity case"

grep -Fq 'A REST 5xx (or' "${run_loop}" ||
  fail "missing the REST-503-plus-GraphQL-success regression rule"

grep -Fq "\`viewer.login\` proves the login valid." "${run_loop}" ||
  fail "REST service failure plus expected GraphQL identity does not prove the login valid"

grep -Fq 'Never report that saved login as invalid.' "${run_loop}" ||
  fail "REST service failure plus expected GraphQL identity can still invalidate the saved login"

# The handoff must be gated on confirmed rejection — not on every auth-status failure.
grep -Fq "and **only then** recommend \`gh auth login\`" "${run_loop}" ||
  fail "missing the confirmed-rejection gate before recommending gh auth login"

grep -Fq 'record only these gate classifications in durable memory' "${run_loop}" ||
  fail "missing the credential-safe memory rule"

grep -Fq 'gh api --include --hostname github.com user' "${cursor_loader}" ||
  fail "Cursor boot gate does not expose the REST status and headers"

grep -Fq "generic \`gh auth status\` invalid-token message is not conclusive" "${cursor_loader}" ||
  fail "Cursor boot gate can still collapse a REST outage into an invalid-token verdict"

grep -Fq "GraphQL API identity is \`cursor[bot]\`" "${cursor_loader}" ||
  fail "Cursor boot gate does not pin the measured API identity"

if grep -Fq "Confirm \`gh auth status\` authenticates **\`app/cursor\`**" "${cursor_loader}"; then
  fail "Cursor loader still hard-stops before the observable API fallback"
fi

if [[ -n "${routine_prompt}" ]]; then
  grep -Fq 'agentic-engineering plugin' "${routine_prompt}" ||
    fail "routine prompt does not hand off to the reviewed plugin"
  grep -Fq 'agentic-engineer entrypoint' "${routine_prompt}" ||
    fail "routine prompt does not name the canonical role entrypoint"

  if grep -Fq 'gh auth status' "${routine_prompt}"; then
    fail "routine prompt duplicates the versioned authentication preflight"
  fi
fi

echo "maintainer preflight contract: all assertions passed"
