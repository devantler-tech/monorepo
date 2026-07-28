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
    "author_date",
    "author_email",
    "author_login",
    "author_name",
    "committer_date",
    "committer_email",
    "committer_login",
    "committer_name",
    "message",
    "sha"
  ] and
  all(.[]; type == "string") and
  (.sha | test("^[0-9a-f]{40}$")) and
  (.author_date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.committer_date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
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

# The shared update-agent-skills workflow creates one recurring PR shape in each current consumer.
# Bind the exemption to generated skill roots and workflow commit provenance; branch/title alone are
# only candidate signals and never sufficient to skip review.
matches_agent_skills_files() {
  local path_pattern

  case "${repo}" in
  agent-plugins)
    path_pattern='^plugins/[^/]+/skills/[^/]+/.+'
    ;;
  ksail | platform)
    path_pattern='^\.agents/skills/[^/]+/.+'
    ;;
  *)
    return 1
    ;;
  esac

  jq -e --arg pattern "${path_pattern}" \
    'length > 0 and all(.[]; test($pattern))' \
    <<<"${files_json}" >/dev/null
}

matches_agent_skills_provenance() {
  jq -e '
    def app_authored:
      .author_login == "devantler" and
      .author_name == "devantler" and
      .author_email == "26203420+devantler@users.noreply.github.com";
    def merge_queue_authored:
      .author_login == "github-merge-queue[bot]" and
      .author_name == "github-merge-queue" and
      .author_email == "118344674+github-merge-queue@users.noreply.github.com";
    length == 1 and
    all(.[];
      (app_authored or merge_queue_authored) and
      .committer_login == "github-actions[bot]" and
      .committer_name == "github-actions[bot]" and
      .committer_email == "41898282+github-actions[bot]@users.noreply.github.com" and
      .message == "chore(deps): update agent skills")
  ' <<<"${commits_json}" >/dev/null
}

is_semver() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]
}

# The date pair is dropped before the identity comparison: this arm is authored by a bot account
# that a rewrite would replace, so it already detects an adaptation commit the way the World at Ruin
# arm cannot, and pinning timestamps here would only make the fixture brittle.
matches_ksail_provenance() {
  local version="$1"
  jq -e \
    --arg head "${head}" \
    --arg version "${version}" \
    'map(del(.author_date, .committer_date)) == [{
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
  local version="$2"

  jq -e \
    --arg head "${head}" \
    --arg component "${component}" \
    --arg version "${version}" \
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
      all(.[]; goreleaser_commit or autocorrect_commit) and
      # The title version must name one of the release cycles actually present, so a stale or
      # hand-edited title cannot smuggle an arbitrary version past the gate. It is deliberately NOT
      # pinned to the LATEST cycle: on a real multi-cycle PR (tap#1225) the title stayed at the
      # first cycle v7.176.0 while a later commit shipped v7.176.1, so requiring the newest would
      # reject a genuine release.
      any(.[];
        goreleaser_commit and
        .message == "Brew cask update for \($component) version \($version)")
    ' <<<"${commits_json}" >/dev/null
}

# World at Ruin's cask PRs come from its own CD workflow rather than GoReleaser, so they are a
# single tap-token commit whose message is the normalized title. Named explicitly by maintainer
# direction 2026-07-18 as a programmed release path.
#
# This arm carries an identity check that the GoReleaser arm gets for free. The tap token commits
# under the maintainer's own Git identity, so every login/name/email/message field is the same
# whether the workflow produced the commit or a person rewrote it — an adaptation commit cannot be
# detected by identity here the way `goreleaserbot` detects it above.
#
# The author/committer date pair supplies the missing signal. A commit created in one operation
# carries one timestamp in both fields; `git commit --amend` preserves the author date and moves the
# committer date, which is exactly the maneuver that edits a cask body while leaving every identity
# field intact. Requiring the pair to be equal therefore revokes the exemption for a rewritten
# commit and keeps it for a freshly-produced one (#2291).
#
# Measured 2026-07-28 on the real path: the CD workflow pushes with the tap token rather than
# committing through the API, so its commits are `verified=false`/`unsigned`. A signature predicate
# would reject every genuine release, which is why the date pair — not commit signing — is the
# discriminator here.
#
# Residual, deliberately accepted: `git commit --amend --reset-author`, or an explicit `--date`,
# realigns the pair and is not detected. Both are deliberate evasions by an actor who already holds
# tap write access, whereas the plain `--amend` this catches is the maneuver reachable by accident.
matches_war_cask_provenance() {
  local version="$1"

  jq -e \
    --arg head "${head}" \
    --arg version "${version}" \
    'length == 1 and
     (.[0].author_date == .[0].committer_date) and
     (map(del(.author_date, .committer_date)) == [{
      sha: $head,
      author_login: "devantler",
      author_name: "Nikolai Emil Damm",
      author_email: "ned@devantler.tech",
      committer_login: "devantler",
      committer_name: "Nikolai Emil Damm",
      committer_email: "ned@devantler.tech",
      message: "chore(cask): update world-at-ruin to \($version)"
    }])' <<<"${commits_json}" >/dev/null
}

if [[ "${branch}" == "deps/agent-skills-update" &&
  "${title}" == "chore(deps): update agent skills" ]]; then
  expected_author=""
  case "${repo}" in
  agent-plugins | platform)
    expected_author="app/botantler-1"
    ;;
  ksail)
    expected_author="app/ksail-bot"
    ;;
  esac

  if [[ -n "${expected_author}" &&
    "${author}" == "${expected_author}" ]] &&
    matches_agent_skills_files &&
    matches_agent_skills_provenance; then
    exit 0
  fi
fi

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
      matches_homebrew_provenance "${component}" "${version}" && exit 0
    fi
  fi
fi

exit 1
