#!/usr/bin/env bash

# Usage:
#   programmed-bot-review-exemption.sh <repo> <author> <head-ref> <title> <head-oid> <files-json> <commits-json> [<skill-owners-json>]
#   programmed-bot-review-exemption.sh --input -   # stdin: {repo, author, head_ref, title, head_oid, files, commits[, skill_owners]}
#
#   repo              bare name (`homebrew-tap`) or `devantler-tech/<name>`
#   author            login as the repo's arm compares it (`app/ksail-bot`, `devantler`)
#   head-ref, title   the PR's head branch and title
#   head-oid          full 40-hex head SHA
#   files-json        JSON array of changed paths
#   commits-json      JSON array, oldest first, ending at head-oid; each commit has exactly these ten string keys
#                     plus an optional boolean `verified` (logins are null for unlinked accounts, so coalesce
#                     them). Without `verified`, an App-signed updater commit cannot be recognised (exit 1):
#     gh api --paginate --slurp repos/devantler-tech/<repo>/pulls/<n>/commits | jq -c 'add | map({sha,
#       author_login: (.author.login // ""), author_name: .commit.author.name, author_email: .commit.author.email,
#       author_date: .commit.author.date, committer_login: (.committer.login // ""),
#       committer_name: .commit.committer.name, committer_email: .commit.committer.email,
#       committer_date: .commit.committer.date, message: .commit.message,
#       verified: (.commit.verification.verified == true)})'
#   skill-owners-json optional JSON object: changed `.agents/skills/<name>` root -> its `metadata.github-repo` or null
#
# Exit 0: no-review exemption; 1: untrusted/non-matching; 2: invalid input or environment, with the reason
# on stderr; 3: genuine programmed updater that is trusted but requires semantic review.

set -euo pipefail

die2() {
  printf 'programmed-bot-review-exemption: %s\n' "$1" >&2
  exit 2
}

# Prints the first message a jq program yields for the input, or the fallback when it yields none.
first_reason() {
  local reason
  reason="$(jq -r "$1" <<<"$2" 2>/dev/null | head -n 1)" || true
  printf '%s' "${reason:-$3}"
}

command -v jq >/dev/null 2>&1 || die2 "jq is not installed"

# Two input shapes carry the same eight values. The positional form serves existing callers. The
# stdin form (`--input -`, one JSON object) is the only shape the read-only surveyor guard admits: a
# declared classifier may run solely as a filter after a forge read, and it may take no argument but
# `--input -` (monorepo#3123). Keys are exact — an unknown or missing key is invalid input (exit 2),
# never a silently defaulted field.
if [[ "$#" -eq 2 && "$1" == "--input" && "$2" == "-" ]]; then
  input_json="$(cat)"
  if ! jq -e '
    type == "object" and
    ((keys - ["skill_owners"]) == ["author", "commits", "files", "head_oid", "head_ref", "repo", "title"]) and
    ([.author, .head_oid, .head_ref, .repo, .title] | all(type == "string")) and
    (.files | type == "array") and
    (.commits | type == "array") and
    ((has("skill_owners") | not) or (.skill_owners | type == "object" or type == "null"))
  ' <<<"${input_json}" >/dev/null 2>&1; then
    die2 "$(first_reason '
      if type != "object" then "stdin is not one JSON object"
      else . as $in | first(
        ("author", "commits", "files", "head_oid", "head_ref", "repo", "title"
          | select(. as $k | $in | has($k) | not) | "stdin is missing key \(.)"),
        (keys[] | select(IN("author", "commits", "files", "head_oid", "head_ref", "repo", "skill_owners", "title") | not)
          | "stdin has unexpected key \(.)"),
        ("author", "head_oid", "head_ref", "repo", "title"
          | select(($in[.] | type) != "string") | "stdin \(.) is \($in[.] | type), not a string"),
        ("files", "commits" | select(($in[.] | type) != "array") | "stdin \(.) is \($in[.] | type), not an array"),
        (select(has("skill_owners") and (.skill_owners | type | IN("object", "null") | not))
          | "stdin skill_owners is \(.skill_owners | type), not an object or null"))
      end' "${input_json}" "stdin is not one JSON object")"
  fi
  repo="$(jq -r '.repo' <<<"${input_json}")"
  author="$(jq -r '.author' <<<"${input_json}")"
  branch="$(jq -r '.head_ref' <<<"${input_json}")"
  title="$(jq -r '.title' <<<"${input_json}")"
  head="$(jq -r '.head_oid' <<<"${input_json}")"
  files_json="$(jq -c '.files' <<<"${input_json}")"
  commits_json="$(jq -c '.commits' <<<"${input_json}")"
  # An absent or null map is the positional form's omitted eighth argument, not an empty map: the
  # installed-skill arm treats an omission as unproven ownership (exit 3), and must keep doing so.
  skill_owners_json="$(jq -c 'if .skill_owners == null then empty else .skill_owners end' <<<"${input_json}")"
else
  if [[ "$#" -lt 7 || "$#" -gt 8 ]]; then
    die2 "expected 7 or 8 arguments or --input -, got $#"
  fi

  repo="$1"
  author="$2"
  branch="$3"
  title="$4"
  head="$5"
  files_json="$6"
  commits_json="$7"
  # Optional map of changed installed-skill root -> that skill's `metadata.github-repo` value, read
  # by the caller at the PR head (null when the frontmatter is absent or unreadable). This is a
  # CORROBORATOR, never an authorization: the value lives inside the payload being classified, so an
  # upstream can write whatever it likes there. Supplying it can only move a root from allowed to
  # review-required — it can never grant the carve-out on its own.
  skill_owners_json="${8-}"
fi

# The arms compare bare names, while other surfaces print `devantler-tech/<name>`. Any other shape is
# an input error, never a "not exempt" verdict about a PR the arms never examined.
repo="${repo#devantler-tech/}"
[[ "${repo}" =~ ^[A-Za-z0-9._-]+$ ]] || die2 "repo must be a bare name or devantler-tech/<name>"

# The authorization source is a reviewed, version-controlled list kept outside the skills, because
# an installed root holds copies from many upstreams and the copied frontmatter is authored by the
# upstream it is meant to identify. It may name exactly one upstream: the carve-out exists for
# content already reviewed here, so any other value is a malformed row rather than another owner.
allowlist_file="$(cd "$(dirname "$0")/.." && pwd)/skill-ownership-allowlist.tsv"
suite_skill_owner="https://github.com/devantler-tech/agent-skills"

commit_schema='type == "array" and length > 0 and all(.[];
  type == "object" and
  ((keys - ["verified"]) == [
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
  ]) and
  (del(.verified) | all(.[]; type == "string")) and
  ((has("verified") | not) or (.verified | type == "boolean")) and
  (.sha | test("^[0-9a-f]{40}$")) and
  (.author_date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.committer_date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
)'

[[ "${head}" =~ ^[0-9a-f]{40}$ ]] || die2 "head-oid is not a full 40-character lowercase hex SHA"

jq -e 'type == "array" and all(.[]; type == "string")' <<<"${files_json}" >/dev/null 2>&1 ||
  die2 "files-json is not a JSON array of strings"

if ! jq -e "${commit_schema}" <<<"${commits_json}" >/dev/null 2>&1; then
  die2 "$(first_reason '
    ["author_date", "author_email", "author_login", "author_name", "committer_date", "committer_email",
      "committer_login", "committer_name", "message", "sha"] as $keys
    | if type != "array" then "commits-json is \(type), not an array"
      elif length == 0 then "commits-json is empty"
      else first(to_entries[] | .key as $i | .value as $c
        | if ($c | type) != "object" then "commit[\($i)] is \($c | type), not an object"
          else
            ($keys[] | select(. as $k | $c | has($k) | not) | "commit[\($i)] is missing key \(.)"),
            ($c | keys[] | select(IN($keys[], "verified") | not) | "commit[\($i)] has unexpected key \(.)"),
            (select($c | has("verified") and (.verified | type) != "boolean")
              | "commit[\($i)].verified is \($c.verified | type), not a boolean"),
            ($keys[] | select(($c[.] | type) != "string") | "commit[\($i)].\(.) is \($c[.] | type), not a string"),
            (select($c.sha | test("^[0-9a-f]{40}$") | not) | "commit[\($i)].sha is not a 40-character lowercase hex SHA"),
            ("author_date", "committer_date"
              | select($c[.] | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not)
              | "commit[\($i)].\(.) is not YYYY-MM-DDTHH:MM:SSZ")
          end)
      end' "${commits_json}" "commits-json is not valid JSON")"
fi

if [[ -n "${skill_owners_json}" ]] &&
  ! jq -e 'type == "object" and all(.[]; type == "string" or type == "null")' \
    <<<"${skill_owners_json}" >/dev/null 2>&1; then
  die2 "skill-owners-json is not a JSON object of string or null values"
fi

# A stale or partial commit list is a survey error, never a normal exemption miss.
jq -e --arg head "${head}" '.[-1].sha == $head' <<<"${commits_json}" >/dev/null ||
  die2 "the last commit in commits-json is not head-oid (stale or partial commit list)"

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

# Marketplace skills are executable agent instructions sourced from several upstreams. Even a
# mechanically genuine update needs semantic review: path/provenance checks prove who produced the
# copy, not whether its prose preserves the consumer's authority boundaries. Exit 3 distinguishes a
# genuine, trusted updater PR that requires review from both the no-review exemption (0) and an
# untrusted lookalike (1).
matches_agent_plugins_review_files() {
  jq -e '
    length > 0 and
    any(.[]; test("^plugins/[^/]+/skills/[^/]+/.+")) and
    all(.[];
      test("^plugins/[^/]+/skills/[^/]+/.+") or
      test("^plugins/[^/]+/(\\.claude-plugin/)?plugin\\.json$") or
      . == ".claude-plugin/marketplace.json" or
      . == ".github/plugin/marketplace.json")
  ' <<<"${files_json}" >/dev/null
}

# Every changed skill root must be listed for this repository in the reviewed allowlist, and — when
# the caller supplies the corroborating map — the copied frontmatter must still agree with it. A root
# that is absent, or whose declared owner has drifted from the reviewed one, takes the semantic-review
# path. An unreadable allowlist fails closed for the same reason.
matches_suite_owned_skills() {
  [[ -r "${allowlist_file}" ]] || return 1
  # The corroborator is REQUIRED on this arm. It is what detects an upstream handover on a root we
  # still allowlist, and a tripwire the caller may omit is one that never fires — so an omitted map
  # is unproven ownership, not permission. Other arms take seven arguments and never reach here.
  [[ -n "${skill_owners_json}" ]] || return 1

  # Every row is validated, not just the ones selected: a row is only ever allowed to name the one
  # reviewed suite upstream, so an empty or drifted third field is a malformed file rather than a
  # different owner. Without that, a stray trailing tab yields an empty owner that still compares
  # unequal to null and would authorize the carve-out with no upstream named at all. A duplicate root
  # is rejected for the same reason — `from_entries` would silently keep the last one.
  local allow_json
  allow_json="$(
    sed 's/#.*//' "${allowlist_file}" |
      awk -F'\t' -v repo="${repo}" -v suite="${suite_skill_owner}" '
        { sub(/[ \t]+$/, "") }
        $0 == "" { next }
        NF != 3 || $2 !~ /^\.agents\/skills\/[^\/]+$/ || $3 != suite { exit 1 }
        seen[$1 "\t" $2]++ { exit 1 }
        $1 == repo { printf "%s\t%s\n", $2, $3 }' |
      jq -Rn '[inputs | select(length > 0) | split("\t") | {key: .[0], value: .[1]}] | from_entries'
  )" || return 1

  jq -e \
    --argjson allow "${allow_json}" \
    --argjson owners "${skill_owners_json:-null}" \
    '[.[] | capture("^(?<root>\\.agents/skills/[^/]+)/").root] | unique
     | length > 0
     and all(.[];
       . as $root
       | ($allow[$root] // null) as $reviewed
       | $reviewed != null
       and ($owners | type) == "object"
       and $owners[$root] == $reviewed)' \
    <<<"${files_json}" >/dev/null
}

# The updater signs its commit by creating it through the GitHub API (`sign-commits: true`,
# devantler-tech/.github#142), so an unadapted head is authored by the updater App itself and
# committed by GitHub's `web-flow` identity (#3126). The App login and its numeric user ID are exact
# per repository, so this arm is as specific as the two below it rather than a loosened match.
# Those identities are only what the commit CLAIMS: anyone who can push can write the App's public
# email and `GitHub <noreply@github.com>` into a commit, and REST maps them back to the same logins.
# So this arm also requires GitHub's own signature verdict (`verified: true`), which only a commit
# GitHub signed can carry. A caller that omits `verified` never reaches this arm.
matches_agent_skills_provenance() {
  local app_login="" app_id=""
  case "${repo}" in
  platform)
    app_login="botantler-1[bot]"
    app_id="185060876"
    ;;
  ksail)
    app_login="ksail-bot[bot]"
    app_id="262010955"
    ;;
  esac
  jq -e --arg app_login "${app_login}" --arg app_id "${app_id}" '
    def signed_app_authored:
      $app_login != "" and
      .verified == true and
      .author_login == $app_login and
      .author_name == $app_login and
      .author_email == "\($app_id)+\($app_login)@users.noreply.github.com" and
      .committer_login == "web-flow" and
      .committer_name == "GitHub" and
      .committer_email == "noreply@github.com" and
      .message == "chore(deps): update agent skills";
    def app_authored:
      .author_login == "devantler" and
      .author_name == "devantler" and
      .author_email == "26203420+devantler@users.noreply.github.com";
    def merge_queue_authored:
      .author_login == "github-merge-queue[bot]" and
      .author_name == "github-merge-queue" and
      .author_email == "118344674+github-merge-queue@users.noreply.github.com";
    length == 1 and
    ((.[0] | signed_app_authored) or all(.[];
      (app_authored or merge_queue_authored) and
      .committer_login == "github-actions[bot]" and
      .committer_name == "github-actions[bot]" and
      .committer_email == "41898282+github-actions[bot]@users.noreply.github.com" and
      .message == "chore(deps): update agent skills"))
  ' <<<"${commits_json}" >/dev/null
}

matches_agent_plugins_review_provenance() {
  jq -e '
    def skill_update:
      .author_login == "devantler" and
      .author_name == "devantler" and
      .author_email == "26203420+devantler@users.noreply.github.com" and
      .committer_login == "github-actions[bot]" and
      .committer_name == "github-actions[bot]" and
      .committer_email == "41898282+github-actions[bot]@users.noreply.github.com" and
      .message == "chore(deps): update agent skills";
    def version_bump:
      .author_login == "github-actions[bot]" and
      .author_name == "github-actions[bot]" and
      .author_email == "41898282+github-actions[bot]@users.noreply.github.com" and
      .committer_login == "github-actions[bot]" and
      .committer_name == "github-actions[bot]" and
      .committer_email == "41898282+github-actions[bot]@users.noreply.github.com" and
      .message == "chore(deps): bump versions of changed plugins";
    (length == 1 and (.[0] | skill_update)) or
    (length == 2 and (.[0] | skill_update) and (.[1] | version_bump))
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
# GoReleaser writes either its default subject or the Conventional subject ksail's
# `commit_msg_template` sets (ksail#6975); an evergreen branch can carry both across cycles (#3547).
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
        (.message | test("^(Brew cask update for \($component) version |chore\\(cask\\): update \($component) to )v[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$"));
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
        (.message == "Brew cask update for \($component) version \($version)" or
         .message == "chore(cask): update \($component) to \($version)"))
    ' <<<"${commits_json}" >/dev/null
}

# World at Ruin's cask PRs come from its own CD workflow rather than GoReleaser, so they are a
# single tap-token commit whose message is the normalized title. Named explicitly by maintainer
# direction 2026-07-18 as a programmed release path.
#
# This arm has to earn a property the GoReleaser arm gets for free. The tap token commits under the
# maintainer's own Git identity, so every login/name/email/message field is the same whether the
# workflow produced the commit or a person rewrote it — an adaptation commit cannot be detected by
# identity here the way `goreleaserbot` detects it above.
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

  if [[ -n "${expected_author}" && "${author}" == "${expected_author}" ]]; then
    if [[ "${repo}" == "agent-plugins" ]] &&
      matches_agent_plugins_review_files &&
      matches_agent_plugins_review_provenance; then
      exit 3
    fi
    if [[ "${repo}" != "agent-plugins" ]] &&
      matches_agent_skills_files &&
      matches_agent_skills_provenance; then
      matches_suite_owned_skills && exit 0
      exit 3
    fi
    # The branch, title and App all name the updater, yet its files or commits do not match any
    # known shape. That stays exit 1 (untrusted, review-gated), but it is said on stderr so it is
    # not mistaken for "not the updater" — a silent exit 1 hid a changed updater for weeks (#3126).
    printf 'programmed-bot-review-exemption: %s updater PR with unexpected files or commit provenance; treated as untrusted\n' \
      "${repo}" >&2
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
