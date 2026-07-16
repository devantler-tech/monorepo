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
grep -Fq '/pulls/<n>/commits' "${surveyor}" ||
  fail "surveyor does not fetch complete current-head commit provenance"

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

expect_review_gated \
  "Platform Renovate KSail bump" \
  "platform" \
  "app/renovate" \
  "renovate/ksail" \
  "chore(deps): update dependency devantler-tech/ksail to v7.172.1" \
  "${platform_head}" \
  '[".github/actions/deploy-prod/action.yml",".github/workflows/ci.yaml",".github/workflows/dr-rebuild.yaml","k8s/bases/infrastructure/controllers/ksail-operator/helm-release.yaml"]' \
  "${platform_commits}"

expect_review_gated \
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
