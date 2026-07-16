#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
classifier="${repo_root}/.claude/scripts/release-bot-exemption.sh"
surveyor="${repo_root}/.claude/agents/portfolio-surveyor.md"
constitution="${repo_root}/AGENTS.md"
maintenance_skill="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
monorepo_skill="${repo_root}/.claude/skills/products/monorepo/SKILL.md"
product_engineering_skill="${repo_root}/.claude/skills/product-engineering/SKILL.md"
agent_skills_card="${repo_root}/.claude/skills/products/agent-skills/SKILL.md"
ksail_card="${repo_root}/.claude/skills/products/ksail/SKILL.md"

fail() {
  echo "portfolio surveyor contract: FAIL — $*" >&2
  exit 1
}

[[ -x "${classifier}" ]] || fail "release-bot exemption classifier is missing or not executable"
grep -Fq '.claude/scripts/release-bot-exemption.sh' "${surveyor}" ||
  fail "surveyor does not delegate exemption decisions to the exact classifier"
grep -Fq 'ksail-bot[bot]' "${surveyor}" ||
  fail "surveyor does not recognize the exact KSail App identity returned by search"
grep -Fq '/pulls/<n>/commits' "${surveyor}" ||
  fail "surveyor does not fetch complete current-head commit provenance"
grep -Fq 'AUTOMATION-OWNED and need NO agent action' "${constitution}" ||
  fail "constitution does not exempt Renovate/Dependabot dependency PRs from agent action"
grep -Fq 'Never request CodeRabbit/Codex review' "${constitution}" ||
  fail "constitution does not explicitly forbid dependency-bot review requests"
grep -Fq 'Do not inspect commit provenance' "${constitution}" ||
  fail "constitution may reclassify dependency-bot PRs after human commits"
grep -Fq 'arm auto-merge, or merge them' "${constitution}" ||
  fail "constitution does not leave dependency-bot merging to repository automation"
grep -Fq 'AUTOMATION-OWNED (NO-ACTION)' "${surveyor}" ||
  fail "surveyor does not short-circuit dependency-bot PRs as no-action"
grep -Fq 'renovate[bot]' "${surveyor}" ||
  fail "surveyor does not bind no-action to the exact Renovate identity"
grep -Fq 'dependabot[bot]' "${surveyor}" ||
  fail "surveyor does not bind no-action to the exact Dependabot identity"
grep -Fq 'do **not** call' "${surveyor}" ||
  fail "surveyor still permits heavy dependency-PR deepening"
grep -Fq 'count it against' "${surveyor}" ||
  fail "surveyor may still turn dependency automation into operate work"
grep -Fq 'automation-owned dependency PRs' "${maintenance_skill}" ||
  fail "portfolio-maintenance skill does not defer dependency PRs to automation"
grep -Fq 'automation-owned dependency PRs' "${monorepo_skill}" ||
  fail "monorepo product card still treats dependency PRs as agent work"
grep -Fq 'automation-owned dependency PRs' "${product_engineering_skill}" ||
  fail "product-engineering skill still treats dependency PRs as agent work"
grep -Fq 'automation-owned dependency PRs' "${agent_skills_card}" ||
  fail "agent-skills product card still treats dependency PRs as agent work"
grep -Fq 'automation-owned dependency PRs' "${ksail_card}" ||
  fail "KSail product card still treats dependency PRs as agent work"
if grep -Fq 'Bot PRs are first-priority work, not background noise' "${constitution}"; then
  fail "constitution still tells agents to drive dependency-bot PRs"
fi
if grep -Fq 'Bundle Dependabot/Renovate PRs' "${monorepo_skill}"; then
  fail "monorepo product card still tells agents to bundle dependency PRs"
fi

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

expect_not_release_exempt() {
  local name="$1"
  shift
  local rc
  if "${classifier}" "$@"; then
    fail "unexpected release-bot exemption: ${name}"
  else
    rc=$?
  fi
  [[ "${rc}" -eq 1 ]] || fail "classifier errored for non-release fixture: ${name}"
}

expect_classifier_error() {
  local name="$1"
  shift
  local rc
  if "${classifier}" "$@"; then
    fail "unexpected exemption: ${name}"
  else
    rc=$?
  fi
  [[ "${rc}" -eq 2 ]] || fail "classifier did not fail closed for invalid fixture: ${name}"
}

homebrew_commits_json() {
  local component="$1"
  local version="$2"
  local first_sha="$3"
  local head_sha="$4"

  jq -cn \
    --arg component "${component}" \
    --arg version "${version}" \
    --arg first_sha "${first_sha}" \
    --arg head_sha "${head_sha}" \
    '[
      {
        sha: $first_sha,
        author_login: "goreleaserbot",
        author_name: "goreleaserbot",
        author_email: "bot@goreleaser.com",
        committer_login: "goreleaserbot",
        committer_name: "goreleaserbot",
        committer_email: "bot@goreleaser.com",
        message: "Brew cask update for \($component) version \($version)"
      },
      {
        sha: $head_sha,
        author_login: "devantler",
        author_name: "devantler",
        author_email: "26203420+devantler@users.noreply.github.com",
        committer_login: "",
        committer_name: "generator-bot",
        committer_email: "generator-bot@users.noreply.github.com",
        message: "style: autocorrect Casks (brew style --fix)"
      }
    ]'
}

ksail_head="8fdc117e5892a57a82781fc3a4806ef1f21873af"
ksail_files='[".claude-plugin/marketplace.json",".github/plugin/marketplace.json","copilot-plugin/.claude-plugin/plugin.json","copilot-plugin/plugin.json"]'
ksail_commits="$(jq -cn --arg head "${ksail_head}" '[{
  sha: $head,
  author_login: "",
  author_name: "devantler-tech-bot[bot]",
  author_email: "devantler-tech-bot[bot]@users.noreply.github.com",
  committer_login: "",
  committer_name: "devantler-tech-bot[bot]",
  committer_email: "devantler-tech-bot[bot]@users.noreply.github.com",
  message: "chore(copilot-plugin): release v7.172.2"
}]')"

ksail_cask_head="c58256924878560caff669a7c05df0d84c458b38"
ksail_cask_commits="$(homebrew_commits_json \
  "ksail" \
  "v7.172.2" \
  "c3dfd928eb6ff8fc8a9d2b1520862d45a565b0e8" \
  "${ksail_cask_head}")"
desktop_cask_head="e896ab6476c4333292b099af7240d1d61b3795f9"
desktop_cask_commits="$(homebrew_commits_json \
  "ksail-desktop" \
  "v7.172.2" \
  "5ebaed25a8e3c92f38f2c8c6f938186ebca7ffa5" \
  "${desktop_cask_head}")"
default_title_cask_head="5a5792bb83bd6b8469f10cd7e00abfe75c7f36be"
default_title_cask_commits="$(homebrew_commits_json \
  "ksail" \
  "v7.172.1" \
  "a22a9f9f56da9f5cdde4c037ec92eabf30768d72" \
  "${default_title_cask_head}")"

platform_head="1111111111111111111111111111111111111111"
platform_commits="$(jq -cn --arg head "${platform_head}" '[{
  sha: $head,
  author_login: "renovate[bot]",
  author_name: "renovate[bot]",
  author_email: "29139614+renovate[bot]@users.noreply.github.com",
  committer_login: "web-flow",
  committer_name: "GitHub",
  committer_email: "noreply@github.com",
  message: "chore(deps): update dependency devantler-tech/ksail to v7.172.1"
}]')"

adapted_ksail_head="2222222222222222222222222222222222222222"
adapted_ksail_commits="$(jq -c --arg head "${adapted_ksail_head}" '. + [{
  sha: $head,
  author_login: "devantler",
  author_name: "Nikolai Emil Damm",
  author_email: "26203420+devantler@users.noreply.github.com",
  committer_login: "devantler",
  committer_name: "Nikolai Emil Damm",
  committer_email: "26203420+devantler@users.noreply.github.com",
  message: "fix: adapt generated release"
}]' <<<"${ksail_commits}")"

adapted_cask_head="3333333333333333333333333333333333333333"
adapted_cask_commits="$(jq -c --arg head "${adapted_cask_head}" '. + [{
  sha: $head,
  author_login: "devantler",
  author_name: "Nikolai Emil Damm",
  author_email: "26203420+devantler@users.noreply.github.com",
  committer_login: "devantler",
  committer_name: "Nikolai Emil Damm",
  committer_email: "26203420+devantler@users.noreply.github.com",
  message: "fix: adapt generated cask"
}]' <<<"${ksail_cask_commits}")"

expect_exempt \
  "KSail programmed plugin release" \
  "ksail" \
  "app/ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${ksail_head}" \
  "${ksail_files}" \
  "${ksail_commits}"

expect_exempt \
  "GoReleaser KSail cask" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "${ksail_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${ksail_cask_commits}"

expect_exempt \
  "GoReleaser KSail Desktop cask" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail-desktop" \
  "chore(cask): update ksail-desktop to v7.172.2" \
  "${desktop_cask_head}" \
  '["Casks/ksail-desktop.rb"]' \
  "${desktop_cask_commits}"

expect_exempt \
  "GoReleaser default cask title" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "Brew cask update for ksail version v7.172.1" \
  "${default_title_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${default_title_cask_commits}"

expect_not_release_exempt \
  "Platform Renovate KSail bump" \
  "platform" \
  "app/renovate" \
  "renovate/ksail" \
  "chore(deps): update dependency devantler-tech/ksail to v7.172.1" \
  "${platform_head}" \
  '[".github/actions/deploy-prod/action.yml",".github/workflows/ci.yaml",".github/workflows/dr-rebuild.yaml","k8s/bases/infrastructure/controllers/ksail-operator/helm-release.yaml"]' \
  "${platform_commits}"

expect_not_release_exempt \
  "lookalike KSail release from the wrong actor" \
  "ksail" \
  "app/renovate" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${ksail_head}" \
  "${ksail_files}" \
  "${ksail_commits}"

expect_review_gated \
  "bare KSail bot alias is not an API identity" \
  "ksail" \
  "ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${ksail_head}" \
  "${ksail_files}" \
  "${ksail_commits}"

expect_review_gated \
  "GoReleaser cask with an extra file" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "${ksail_cask_head}" \
  '["Casks/ksail.rb","README.md"]' \
  "${ksail_cask_commits}"

expect_review_gated \
  "GoReleaser-shaped title from an unowned branch" \
  "homebrew-tap" \
  "devantler" \
  "feature/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "${ksail_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${ksail_cask_commits}"

expect_review_gated \
  "KSail release with a human adaptation commit" \
  "ksail" \
  "app/ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${adapted_ksail_head}" \
  "${ksail_files}" \
  "${adapted_ksail_commits}"

expect_review_gated \
  "GoReleaser cask with a human adaptation commit" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "${adapted_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${adapted_cask_commits}"

expect_classifier_error \
  "stale commit list does not reach the supplied head" \
  "ksail" \
  "app/ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "4444444444444444444444444444444444444444" \
  "${ksail_files}" \
  "${ksail_commits}"

expect_classifier_error \
  "malformed commit provenance" \
  "ksail" \
  "app/ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${ksail_head}" \
  "${ksail_files}" \
  'not-json'

echo "portfolio surveyor contract: all assertions passed"
