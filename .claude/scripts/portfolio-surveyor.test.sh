#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
classifier="${repo_root}/.claude/scripts/release-bot-exemption.sh"
surveyor="${repo_root}/.claude/agents/portfolio-surveyor.md"

fail() {
  echo "portfolio surveyor contract: FAIL — $*" >&2
  exit 1
}

[[ -x "${classifier}" ]] || fail "release-bot exemption classifier is missing or not executable"
grep -Fq '.claude/scripts/release-bot-exemption.sh' "${surveyor}" ||
  fail "surveyor does not delegate exemption decisions to the exact classifier"
grep -Fq 'ksail-bot[bot]' "${surveyor}" ||
  fail "surveyor does not recognize the exact KSail App identity returned by search"

expect_exempt() {
  local name="$1"
  shift
  "${classifier}" "$@" || fail "expected exemption: ${name}"
}

expect_review_gated() {
  local name="$1"
  shift
  local rc
  if "${classifier}" "$@"; then
    fail "unexpected exemption: ${name}"
  else
    rc=$?
  fi
  [[ "${rc}" -eq 1 ]] || fail "classifier errored for review-gated fixture: ${name}"
}

expect_exempt \
  "KSail programmed plugin release" \
  "ksail" \
  "app/ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  ".claude-plugin/marketplace.json" \
  ".github/plugin/marketplace.json" \
  "copilot-plugin/.claude-plugin/plugin.json" \
  "copilot-plugin/plugin.json"

expect_exempt \
  "GoReleaser KSail cask" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "Casks/ksail.rb"

expect_exempt \
  "GoReleaser KSail Desktop cask" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail-desktop" \
  "chore(cask): update ksail-desktop to v7.172.2" \
  "Casks/ksail-desktop.rb"

expect_review_gated \
  "Platform Renovate KSail bump" \
  "platform" \
  "app/renovate" \
  "renovate/ksail" \
  "chore(deps): update dependency devantler-tech/ksail to v7.172.1" \
  ".github/actions/deploy-prod/action.yml" \
  ".github/workflows/ci.yaml" \
  ".github/workflows/dr-rebuild.yaml" \
  "k8s/bases/infrastructure/controllers/ksail-operator/helm-release.yaml"

expect_review_gated \
  "lookalike KSail release from the wrong actor" \
  "ksail" \
  "app/renovate" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  ".claude-plugin/marketplace.json" \
  ".github/plugin/marketplace.json" \
  "copilot-plugin/.claude-plugin/plugin.json" \
  "copilot-plugin/plugin.json"

expect_review_gated \
  "bare KSail bot alias is not an API identity" \
  "ksail" \
  "ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  ".claude-plugin/marketplace.json" \
  ".github/plugin/marketplace.json" \
  "copilot-plugin/.claude-plugin/plugin.json" \
  "copilot-plugin/plugin.json"

expect_review_gated \
  "GoReleaser cask with an extra file" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "Casks/ksail.rb" \
  "README.md"

expect_review_gated \
  "GoReleaser-shaped title from an unowned branch" \
  "homebrew-tap" \
  "devantler" \
  "feature/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "Casks/ksail.rb"

echo "portfolio surveyor contract: all assertions passed"
