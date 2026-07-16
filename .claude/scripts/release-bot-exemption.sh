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

matches_homebrew_provenance() {
  local component="$1"
  local version="$2"

  jq -e \
    --arg head "${head}" \
    --arg component "${component}" \
    --arg version "${version}" \
    '
      def goreleaser_commit:
        {
          author_login: "goreleaserbot",
          author_name: "goreleaserbot",
          author_email: "bot@goreleaser.com",
          committer_login: "goreleaserbot",
          committer_name: "goreleaserbot",
          committer_email: "bot@goreleaser.com",
          message: "Brew cask update for \($component) version \($version)"
        };
      def autocorrect_commit:
        {
          author_login: "devantler",
          author_name: "devantler",
          author_email: "26203420+devantler@users.noreply.github.com",
          committer_login: "",
          committer_name: "generator-bot",
          committer_email: "generator-bot@users.noreply.github.com",
          message: "style: autocorrect Casks (brew style --fix)"
        };
      (
        length == 1 and
        .[0].sha == $head and
        (.[0] | del(.sha)) == goreleaser_commit
      ) or (
        length == 2 and
        .[0].sha != $head and
        (.[0] | del(.sha)) == goreleaser_commit and
        .[1] == (autocorrect_commit + {sha: $head})
      )
    ' <<<"${commits_json}" >/dev/null
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

  if is_semver "${version}" &&
    matches_exact_files "${expected_file}" &&
    matches_homebrew_provenance "${component}" "${version}"; then
    exit 0
  fi
fi

exit 1
