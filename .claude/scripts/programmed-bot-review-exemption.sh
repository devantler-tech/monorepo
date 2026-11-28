#!/usr/bin/env bash

# Usage:
#   programmed-bot-review-exemption.sh <repo> <author> <head-ref> <title> <head-oid> <files-json> <commits-json> [<skill-owners-json>]
#   programmed-bot-review-exemption.sh --input -   # stdin: {repo, author, head_ref, title, head_oid, files, commits[, skill_owners]}
#
#   repo              bare name (`homebrew-tap`) or `devantler-tech/<name>`
#   author            login as the repo's arm compares it (`app/botantler-1` or `app/botantler-2`)
#   head-ref, title   the PR's head branch and title
#   head-oid          full 40-hex head SHA
#   files-json        JSON array of changed paths
#   commits-json      JSON array, oldest first, ending at head-oid; each commit has exactly these ten string keys
#                     plus an optional boolean `verified` and an optional `parents` array of full SHAs (logins
#                     are null for unlinked accounts, so coalesce them). Without `verified`, an App-signed
#                     updater commit cannot be recognised (exit 1); without `parents`, neither can the
#                     updater's base-refresh merge (monorepo#4597):
#     gh api --paginate --slurp repos/devantler-tech/<repo>/pulls/<n>/commits | jq -c 'add | map({sha,
#       author_login: (.author.login // ""), author_name: .commit.author.name, author_email: .commit.author.email,
#       author_date: .commit.author.date, committer_login: (.committer.login // ""),
#       committer_name: .commit.committer.name, committer_email: .commit.committer.email,
#       committer_date: .commit.committer.date, message: .commit.message,
#       verified: (.commit.verification.verified == true), parents: [.parents[].sha]})'
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
suite_skill_owner="https://github.com/devantler-tech/agent-plugins"

# The two interchangeable org Apps. The GitHub token broker (ADR 0020, devantler-tech/.github#1001)
# mints each token from whichever App has more rate limit left, so a programmed PR may be opened,
# and each of its commits written, by either one. An App is its exact REST login, its numeric user
# ID and its GraphQL PR-author spelling together, so a look-alike login or another App's ID matches
# neither.
updater_apps_json='[
  {"login": "botantler-1[bot]", "id": "185060876", "pr_author": "app/botantler-1"},
  {"login": "botantler-2[bot]", "id": "296234498", "pr_author": "app/botantler-2"}
]'

# jq: the App of $apps that a commit's author fields name exactly (its login as both login and
# name, and its `<id>+<login>` noreply email), or null when they name none.
# shellcheck disable=SC2016 # `$apps` and `$c` are jq variables, not shell expansions.
author_app_jq='def author_app($apps): . as $c | [$apps[] | select(
  $c.author_login == .login and $c.author_name == .login and
  $c.author_email == "\(.id)+\(.login)@users.noreply.github.com")] | first;'

# is_updater_app_author <author> succeeds only for one of those Apps' exact PR-author spelling.
is_updater_app_author() {
  jq -e --arg author "$1" 'any(.[]; .pr_author == $author)' <<<"${updater_apps_json}" >/dev/null
}

commit_schema='type == "array" and length > 0 and all(.[];
  type == "object" and
  ((keys - ["verified", "parents"]) == [
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
  (del(.verified, .parents) | all(.[]; type == "string")) and
  ((has("verified") | not) or (.verified | type == "boolean")) and
  ((has("parents") | not) or (.parents | type == "array" and all(.[]; type == "string" and test("^[0-9a-f]{40}$")))) and
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
            ($c | keys[] | select(IN($keys[], "verified", "parents") | not) | "commit[\($i)] has unexpected key \(.)"),
            (select($c | has("verified") and (.verified | type) != "boolean")
              | "commit[\($i)].verified is \($c.verified | type), not a boolean"),
            (select($c | has("parents") and (.parents | type != "array" or any(.[]; type != "string" or (test("^[0-9a-f]{40}$") | not))))
              | "commit[\($i)].parents is not an array of 40-character lowercase hex SHAs"),
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
# With no argument, any bundled skill may change. With a per-skill path (`plugins/<plugin>/skills/<skill>`,
# agent-plugins#241), the skill files must all sit under that one skill, and the generated files must
# belong to its own plugin — so a per-skill PR cannot carry a second skill's update past review routing.
# The plugin manifests are the Claude one (`.claude-plugin/plugin.json`) and, since the plugin also
# ships to Codex, the Codex one (`.codex-plugin/plugin.json`); the release-notes bump writes both
# (monorepo#4928). The Codex manifest is admitted only for a plugin whose skill changed. The
# marketplace is `.claude-plugin/marketplace.json` alone: agent-plugins#709 deleted the second
# manifest set (`.github/plugin/marketplace.json` and each top-level `plugins/<name>/plugin.json`),
# so a PR that writes either is no longer updater output.
matches_agent_plugins_review_files() {
  local skill_path="${1-}" skill_re plugin_re
  if [[ -n "${skill_path}" ]]; then
    skill_re="^${skill_path}/.+"
    plugin_re="${skill_path%%/skills/*}"
  else
    skill_re="^plugins/[^/]+/skills/[^/]+/.+"
    plugin_re="plugins/[^/]+"
  fi
  jq -e --arg skill "${skill_re}" --arg plugin "${plugin_re}" '
    length > 0 and
    any(.[]; test($skill)) and
    all(.[];
      test($skill) or
      test("^\($plugin)/\\.claude-plugin/plugin\\.json$") or
      (. as $f | [$changed[] | "\(.)/.codex-plugin/plugin.json"] | index($f) != null) or
      test("^\($plugin)/resources/provider-neutral\\.desired-state\\.json$") or
      (. as $f | [$changed[] | "\(.)/CHANGELOG.md"] | index($f) != null) or
      . == ".claude-plugin/marketplace.json")
  ' --argjson changed "$(jq -c --arg skill "${skill_re}" \
      '[.[] | select(test($skill)) | capture("^(?<p>plugins/[^/]+)/skills/").p] | unique' \
      <<<"${files_json}")" <<<"${files_json}" >/dev/null
}

# A plugin changelog is written only by the release-notes bump (agent-plugins#247), and that bump
# writes one for every plugin whose skills changed. So without the bump no changelog may change, and
# with it the plugins carrying a changelog must be exactly the plugins carrying a skill change. A
# looser test lets a sync commit alone, or the legacy bump, bring a changelog edit through the
# trusted path, or passes a head whose changelog set is missing a plugin — neither of which is
# untouched updater output. Only a plugin-root changelog is release notes: a skill may ship its own
# CHANGELOG.md as ordinary skill content, which the file boundary already admits.
matches_changelog_bump() {
  jq -e --argjson commits "${commits_json}" '
    ([.[] | capture("^(?<p>plugins/[^/]+)/CHANGELOG\\.md$").p] | unique) as $logged |
    ([.[] | capture("^(?<p>plugins/[^/]+)/skills/").p] | unique) as $changed |
    if any($commits[1:][];
         .message == "chore(deps): bump plugin versions and record skill updates" or
         .message == "chore(deps): refresh plugin metadata for synced content")
    then $logged == $changed
    else $logged == []
    end
  ' <<<"${files_json}" >/dev/null
}

# The digest refresh job commits only when the sync moved a declared digest, and it is the only job
# that writes a desired-state file. So a desired-state change and the refresh commit come together
# or not at all: a head changing that file without the refresh, or carrying the refresh without the
# file, is not untouched updater output. The combined App-signed publisher also refreshes
# digests, but may have only version/release-note changes; its identity is checked below.
matches_digest_refresh() {
  jq -e --argjson commits "${commits_json}" '
    if any($commits[1:][]; .message == "chore(deps): refresh plugin metadata for synced content")
    then true
    else any(.[]; test("^plugins/[^/]+/resources/provider-neutral\\.desired-state\\.json$")) ==
      any($commits[1:][]; .message == "chore(deps): refresh desired-state digests for synced content")
    end
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
# committed by GitHub's `web-flow` identity (#3126). The App is one of the two org Apps, each an
# exact login and numeric user ID pair per repository, so this arm is as specific as the two below
# it rather than a loosened match.
# Those identities are only what the commit CLAIMS: anyone who can push can write the App's public
# email and `GitHub <noreply@github.com>` into a commit, and REST maps them back to the same logins.
# So this arm also requires GitHub's own signature verdict (`verified: true`), which only a commit
# GitHub signed can carry. A caller that omits `verified` never reaches this arm.
matches_agent_skills_provenance() {
  local apps='[]'
  case "${repo}" in
  platform | ksail)
    apps="${updater_apps_json}"
    ;;
  esac
  jq -e --argjson apps "${apps}" "${author_app_jq}"'
    def signed_app_authored:
      author_app($apps) != null and
      .verified == true and
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

# The sync commit comes first, carrying the exact expected message. It is either the legacy shape or
# the App-signed one the updater writes once it signs through the API, which is recognised only with
# GitHub's own signature verdict, as in the consumer arm above. After it, the caller's follow-up jobs
# may add a digest refresh and a version bump, each at most once and in the order its job writes them
# (refresh first, then bump). The corrected producer instead uses one combined follow-up,
# signed the same way. Its job mints its own token, so either org App may sign either commit.
# Mixing the two histories is never programmed output.
matches_agent_plugins_review_provenance() {
  local sync_message="$1"
  jq -e --arg sync_message "${sync_message}" --argjson apps "${updater_apps_json}" "${author_app_jq}"'
    def actions_bot_authored:
      .author_login == "github-actions[bot]" and
      .author_name == "github-actions[bot]" and
      .author_email == "41898282+github-actions[bot]@users.noreply.github.com";
    def actions_bot_committed:
      .committer_login == "github-actions[bot]" and
      .committer_name == "github-actions[bot]" and
      .committer_email == "41898282+github-actions[bot]@users.noreply.github.com";
    def legacy_skill_update:
      .author_login == "devantler" and
      .author_name == "devantler" and
      .author_email == "26203420+devantler@users.noreply.github.com" and
      actions_bot_committed;
    def signed_skill_update:
      .verified == true and
      author_app($apps) != null and
      .committer_login == "web-flow" and
      .committer_name == "GitHub" and
      .committer_email == "noreply@github.com";
    def skill_update:
      (legacy_skill_update or signed_skill_update) and .message == $sync_message;
    # Each follow-up is identified by its KIND, so two wordings of one kind still count once. The
    # updater writes the version bump as "bump plugin versions and record skill updates" since
    # agent-plugins#247 added release notes to it; the earlier wording stays accepted for PRs
    # opened before that change, but never alongside it.
    def follow_up_kind:
      if .message == "chore(deps): refresh desired-state digests for synced content" then "digest"
      elif .message == "chore(deps): bump versions of changed plugins" or
           .message == "chore(deps): bump plugin versions and record skill updates" then "bump"
      else null end;
    length >= 1 and
    (.[0] | skill_update) and
    (if any(.[1:][]; .message == "chore(deps): refresh plugin metadata for synced content")
     then length == 2 and (.[0] | signed_skill_update) and
       (.[1] | signed_skill_update and .message == "chore(deps): refresh plugin metadata for synced content")
     else all(.[1:][]; actions_bot_authored and actions_bot_committed and follow_up_kind != null) and
       (.[1:] | map(follow_up_kind) | (unique | length) == length) and
       (.[1:] | map(follow_up_kind) | IN([], ["digest"], ["bump"], ["digest", "bump"]))
     end)
  ' <<<"${commits_json}" >/dev/null
}

# When `main` moves, an open PR is refreshed through GitHub's update-branch API. GitHub computes
# that merge itself and signs it, authored by the App whose token asked for it and committed by
# `web-flow`. In agent-plugins the refresh first came from its `recheck-open-prs.yaml` workflow,
# which the merge queue replaced (agent-plugins#707); update-branch merges still occur, there and
# on the tap's Cask bump PRs, so the helper stays. Before monorepo#4597 that one trailing commit
# turned a genuine updater PR into exit 1, so merging one updater PR made its open sibling
# "untrusted".
#
# strip_base_refresh_merges <apps-json> rewrites commits_json without its trailing
# base-refresh merges, so the arms below judge the programmed head the refresh sat on. A commit
# is a base-refresh merge only when every one of these holds:
#   - GitHub's own signature verdict is `verified: true`, the author is exactly one of this
#     repository's updater Apps and the committer is exactly `web-flow`, as on the signed sync
#     commit. The refresh is requested with its own token, so either App may have written it;
#   - its message is exactly `Merge branch 'main' into <head-ref>` for this PR's head ref;
#   - it has exactly two parents, the first being the commit before it in the list;
#   - its second parent is not one of the PR's own commits. The list is every commit reachable
#     from the head and not from the base, and it is complete (it ends at head-oid), so a second
#     parent outside it is already on the base branch.
# Anything else stays in the list, where no arm accepts a merge commit, so it still reads exit 1.
# The changed-files list is the PR's own diff against the refreshed base, so a merge that also
# brings a file the updater never writes still fails the file arms. The residual: a change inside
# the allowed skill paths made in the merge itself is indistinguishable here from the sync commit's
# own content. Only a token of one of those Apps can author a GitHub-signed commit as that App,
# which is the trust the signed sync commit already rests on.
strip_base_refresh_merges() {
  local apps="$1" stripped before
  jq -e 'length > 0' <<<"${apps}" >/dev/null 2>&1 || return 0
  stripped="$(jq -c --argjson apps "${apps}" --arg ref "${branch}" "${author_app_jq}"'
    def refresh_merge($prev; $shas):
      .verified == true and
      author_app($apps) != null and
      .committer_login == "web-flow" and
      .committer_name == "GitHub" and
      .committer_email == "noreply@github.com" and
      .message == "Merge branch '\''main'\'' into \($ref)" and
      (.parents | type) == "array" and
      (.parents | length) == 2 and
      .parents[0] == $prev.sha and
      (.parents[1] as $base | $shas | index($base) == null);
    (map(.sha)) as $shas
    | until(length < 2 or ((.[-2]) as $prev | .[-1] | refresh_merge($prev; $shas) | not); .[:-1])
  ' <<<"${commits_json}")" || die2 "could not read base-refresh merges from commits-json"
  before="$(jq 'length' <<<"${commits_json}")"
  if [[ "$(jq 'length' <<<"${stripped}")" != "${before}" ]]; then
    refresh_note="$(printf 'programmed-bot-review-exemption: %s updater PR judged below %s trailing base-refresh merge(s) from main' \
      "${repo}" "$((before - $(jq 'length' <<<"${stripped}")))")"
    commits_json="${stripped}"
  fi
}

# updater_verdict <0|3> exits with a trusted updater verdict. The note that the PR was judged below
# its refresh is said only here, beside a verdict that rests on it, never next to an exit 1.
refresh_note=""
updater_verdict() {
  [[ -z "${refresh_note}" ]] || printf '%s\n' "${refresh_note}" >&2
  exit "$1"
}

# updater_apps <repo> prints the JSON list of Apps that write this repository's signed programmed
# commits, or `[]` for a repository with none. The tap's Cask bump workflow mints its token from the
# same broker as the agent-plugins updater, so either org App may write its commit too.
updater_apps() {
  case "$1" in
  agent-plugins | homebrew-tap | ksail | platform) printf '%s\n' "${updater_apps_json}" ;;
  *) printf '[]\n' ;;
  esac
}

# The tap bumps its own Casks (homebrew-tap#2568), replacing the product pipelines' cask PRs
# (ksail#8394, world-at-ruin#1713). Its hourly `bump-casks` workflow finds each Cask's latest
# GitHub release with `brew livecheck`, rewrites the Cask with `brew bump-cask-pr --write-only`
# (which also runs `brew style --fix`), and commits it once through the contents API under the
# App's token, with the PR title as the message. GitHub's latest release is never a draft or a
# prerelease, so the release a bump PR names is published by construction.
#
# The identities are only what the commit claims, as on the updater's signed sync commit above, so
# GitHub's own signature verdict (`verified: true`) is required: only a token of an App can make
# GitHub sign a commit authored as that App. Every App-signed commit measured in this org is
# committed by `web-flow`; the App itself as committer is accepted too, because GitHub's API
# default names the authenticated App there and only GitHub's signature can verify either form.
# One API call writes the commit with one token, so that committer must be the App that authored it.
# The list must hold that one commit. A second one, even a re-run of the workflow after `main`
# changed the Cask under an open PR, sends the PR to review.
matches_cask_bump_provenance() {
  local apps="$1"
  jq -e --argjson apps "${apps}" --arg title "${title}" "${author_app_jq}"'
    length == 1 and
    (.[0] | author_app($apps) as $app |
      $app != null and
      .verified == true and
      ((.committer_login == "web-flow" and
        .committer_name == "GitHub" and
        .committer_email == "noreply@github.com") or
       (.committer_login == $app.login and
        .committer_name == $app.login and
        .committer_email == "\($app.id)+\($app.login)@users.noreply.github.com")) and
      .message == $title)
  ' <<<"${commits_json}" >/dev/null
}

if [[ "${branch}" == "deps/agent-skills-update" &&
  "${title}" == "chore(deps): update agent skills" ]]; then
  updater_repo=false
  case "${repo}" in
  agent-plugins | ksail | platform)
    updater_repo=true
    ;;
  esac

  if [[ "${updater_repo}" == true ]] && is_updater_app_author "${author}"; then
    strip_base_refresh_merges "$(updater_apps "${repo}")"
    if [[ "${repo}" == "agent-plugins" ]] &&
      matches_agent_plugins_review_files &&
      matches_agent_plugins_review_provenance "chore(deps): update agent skills" &&
      matches_changelog_bump &&
      matches_digest_refresh; then
      updater_verdict 3
    fi
    if [[ "${repo}" != "agent-plugins" ]] &&
      matches_agent_skills_files &&
      matches_agent_skills_provenance; then
      matches_suite_owned_skills && updater_verdict 0
      updater_verdict 3
    fi
    # The branch, title and App all name the updater, yet its files or commits do not match any
    # known shape. That stays exit 1 (untrusted, review-gated), but it is said on stderr so it is
    # not mistaken for "not the updater" — a silent exit 1 hid a changed updater for weeks (#3126).
    printf 'programmed-bot-review-exemption: %s updater PR with unexpected files or commit provenance; treated as untrusted\n' \
      "${repo}" >&2
  fi
fi

# agent-plugins opts into one updater PR per skill (agent-plugins#241). Each comes from
# `deps/agent-skills-update-<slug>`, where the slug is the skill's path under `plugins/` with `/`
# replaced by `-`, and its title and sync commit carry `(<path>)`. The slug is derived from the
# title's path and compared exactly, so a branch, title and commit naming different skills never
# match. A genuine one still needs semantic review (3), never the exemption.
per_skill_title_prefix="chore(deps): update agent skills ("
if [[ "${repo}" == "agent-plugins" &&
  "${title}" == "${per_skill_title_prefix}"*")" ]] &&
  is_updater_app_author "${author}"; then
  skill_path="${title#"${per_skill_title_prefix}"}"
  skill_path="${skill_path%")"}"
  if [[ "${skill_path}" =~ ^plugins/[a-z0-9][a-z0-9-]*/skills/[a-z0-9][a-z0-9-]*$ ]]; then
    skill_slug="${skill_path#plugins/}"
    skill_slug="${skill_slug//\//-}"
    if [[ "${branch}" == "deps/agent-skills-update-${skill_slug}" ]]; then
      strip_base_refresh_merges "$(updater_apps "${repo}")"
      if matches_agent_plugins_review_files "${skill_path}" &&
        matches_agent_plugins_review_provenance "${title}" &&
        matches_changelog_bump &&
        matches_digest_refresh; then
        updater_verdict 3
      fi
      printf 'programmed-bot-review-exemption: %s per-skill updater PR with unexpected files or commit provenance; treated as untrusted\n' \
        "${repo}" >&2
    fi
  fi
fi

# The tap's Cask bump PRs. The workflow names its branch `bump-<cask>-<version>` and its title
# `chore(cask): update <cask> to v<version>` from one livecheck result, so the branch fixes the
# Cask and the version, the title must name the same pair, and the PR may change only that Cask's
# file. The version is digits and dots, the only shape the workflow accepts. The workflow arms
# auto-merge itself, so exit 0 here waives only the review.
cask_bump_branch_re='^bump-(ksail|ksail-desktop|world-at-ruin)-([0-9]+(\.[0-9]+)*)$'
if [[ "${repo}" == "homebrew-tap" &&
  ("${branch}" == bump-* || "${title}" == "chore(cask): update "*) ]] &&
  is_updater_app_author "${author}"; then
  if [[ "${branch}" =~ ${cask_bump_branch_re} ]]; then
    cask="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    tap_apps="$(updater_apps "${repo}")"
    strip_base_refresh_merges "${tap_apps}"
    if [[ "${title}" == "chore(cask): update ${cask} to v${version}" ]] &&
      matches_exact_files "Casks/${cask}.rb" &&
      matches_cask_bump_provenance "${tap_apps}"; then
      updater_verdict 0
    fi
    # Since homebrew-tap#2575 the workflow bumps the KSail CLI and desktop Casks together: one PR
    # from `bump-ksail-<version>` titled `chore(cask): update KSail CLI and desktop to v<version>`,
    # changing exactly both Casks, under the same one-commit provenance (monorepo#5117).
    if [[ "${cask}" == "ksail" &&
      "${title}" == "chore(cask): update KSail CLI and desktop to v${version}" ]] &&
      matches_exact_files "Casks/ksail.rb" "Casks/ksail-desktop.rb" &&
      matches_cask_bump_provenance "${tap_apps}"; then
      updater_verdict 0
    fi
  fi
  # As for the updater above: still exit 1, but said, so a changed bump workflow is not mistaken
  # for a PR that never claimed to be one.
  printf 'programmed-bot-review-exemption: %s Cask bump PR with an unexpected branch, title, files or commit provenance; treated as untrusted\n' \
    "${repo}" >&2
fi

exit 1
