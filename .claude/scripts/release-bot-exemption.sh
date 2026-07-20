#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 7 ]] || ! command -v jq >/dev/null 2>&1; then
  exit 2
fi

repo="$1"
author="$2"
branch="$3"
title="$4"
head="$5"
files_json="$6"
commits_json="$7"

commit_schema='type == "array" and length > 0 and all(.[];
  type == "object" and
  keys == [
    "author_email",
    "author_login",
    "author_name",
    "committer_email",
    "committer_login",
    "committer_name",
    "message",
    "sha"
  ] and
  all(.[]; type == "string") and
  (.sha | test("^[0-9a-f]{40}$"))
)'

if [[ ! "${head}" =~ ^[0-9a-f]{40}$ ]] ||
  ! jq -e 'type == "array" and all(.[]; type == "string")' \
    <<<"${files_json}" >/dev/null 2>&1 ||
  ! jq -e "${commit_schema}" <<<"${commits_json}" >/dev/null 2>&1; then
  exit 2
fi

# A stale or partial commit list is a survey error, never a normal exemption miss.
if ! jq -e --arg head "${head}" '.[-1].sha == $head' \
  <<<"${commits_json}" >/dev/null; then
  exit 2
fi

matches_exact_files() {
  local expected_json
  expected_json="$(printf '%s\n' "$@" | jq -R . | jq -s 'sort')"
  jq -e --argjson expected "${expected_json}" 'sort == $expected' \
    <<<"${files_json}" >/dev/null
}

is_semver() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]
}

matches_ksail_provenance() {
  local version="$1"
  jq -e \
    --arg head "${head}" \
    --arg version "${version}" \
    '. == [{
      sha: $head,
      author_login: "",
      author_name: "devantler-tech-bot[bot]",
      author_email: "devantler-tech-bot[bot]@users.noreply.github.com",
      committer_login: "",
      committer_name: "devantler-tech-bot[bot]",
      committer_email: "devantler-tech-bot[bot]@users.noreply.github.com",
      message: "chore(copilot-plugin): release \($version)"
    }]' <<<"${commits_json}" >/dev/null
}

# GoReleaser's tap path (ksail, ksail-desktop). The branch is evergreen, so one open PR can
# accumulate several release cycles, each a GoReleaser cask commit optionally followed by the tap's
# `brew style --fix` autocorrect commit. Every commit must match one of those two identities — an
# agent or human adaptation commit anywhere in the list takes the PR off its programmed path and
# makes it review-bearing again, per the constitution's carve-out.
matches_homebrew_provenance() {
  local component="$1"

  jq -e \
    --arg head "${head}" \
    --arg component "${component}" \
    '
      def goreleaser_commit:
        .author_login == "goreleaserbot" and
        .author_name == "goreleaserbot" and
        .author_email == "bot@goreleaser.com" and
        .committer_login == "goreleaserbot" and
        .committer_name == "goreleaserbot" and
        .committer_email == "bot@goreleaser.com" and
        (.message | test("^Brew cask update for \($component) version v[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"));
      def autocorrect_commit:
        .author_login == "" and
        .author_name == "generator-bot" and
        .author_email == "generator-bot@users.noreply.github.com" and
        .committer_login == "" and
        .committer_name == "generator-bot" and
        .committer_email == "generator-bot@users.noreply.github.com" and
        .message == "style: autocorrect Casks (brew style --fix)";
      length > 0 and
      (.[0] | goreleaser_commit) and
      (.[-1].sha == $head) and
      all(.[]; goreleaser_commit or autocorrect_commit)
    ' <<<"${commits_json}" >/dev/null
}

# World at Ruin's cask PRs come from its own CD workflow rather than GoReleaser, so they are a
# single tap-token commit whose message is the normalized title. Named explicitly by maintainer
# direction 2026-07-18 as a programmed release path.
matches_war_cask_provenance() {
  local version="$1"

  jq -e \
    --arg head "${head}" \
    --arg version "${version}" \
    '. == [{
      sha: $head,
      author_login: "devantler",
      author_name: "Nikolai Emil Damm",
      author_email: "ned@devantler.tech",
      committer_login: "devantler",
      committer_name: "Nikolai Emil Damm",
      committer_email: "ned@devantler.tech",
      message: "chore(cask): update world-at-ruin to \($version)"
    }]' <<<"${commits_json}" >/dev/null
}

if [[ "${repo}" == "ksail" &&
  "${author}" == "app/ksail-bot" &&
  "${title}" == "chore(copilot-plugin): release "* ]]; then
  version="${title#chore(copilot-plugin): release }"
  if is_semver "${version}" &&
    [[ "${branch}" == "chore/copilot-plugin-${version}" ]] &&
    matches_exact_files \
      ".claude-plugin/marketplace.json" \
      ".github/plugin/marketplace.json" \
      "copilot-plugin/.claude-plugin/plugin.json" \
      "copilot-plugin/plugin.json" &&
    matches_ksail_provenance "${version}"; then
    exit 0
  fi
fi

if [[ "${repo}" == "homebrew-tap" && "${author}" == "devantler" ]]; then
  case "${branch}" in
  goreleaser/ksail)
    component="ksail"
    expected_file="Casks/ksail.rb"
    ;;
  goreleaser/ksail-desktop)
    component="ksail-desktop"
    expected_file="Casks/ksail-desktop.rb"
    ;;
  goreleaser/world-at-ruin)
    component="world-at-ruin"
    expected_file="Casks/world-at-ruin.rb"
    ;;
  *)
    exit 1
    ;;
  esac

  normalized_title_prefix="chore(cask): update ${component} to "
  goreleaser_title_prefix="Brew cask update for ${component} version "
  case "${title}" in
  "${normalized_title_prefix}"*)
    version="${title#"${normalized_title_prefix}"}"
    ;;
  "${goreleaser_title_prefix}"*)
    version="${title#"${goreleaser_title_prefix}"}"
    ;;
  *)
    exit 1
    ;;
  esac

  if is_semver "${version}" && matches_exact_files "${expected_file}"; then
    if [[ "${component}" == "world-at-ruin" ]]; then
      matches_war_cask_provenance "${version}" && exit 0
    else
      matches_homebrew_provenance "${component}" && exit 0
    fi
  fi
fi

exit 1
