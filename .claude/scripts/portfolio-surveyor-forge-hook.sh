#!/usr/bin/env bash
# Resolve the reviewed plugin's Claude PreToolUse adapter for the consumer's
# agent-scoped portfolio-surveyor hook. This script only locates and verifies
# runtime assets; the plugin's forge-readonly-guard.sh remains the one policy.

set -euo pipefail

HERE=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "${HERE}/../.." && pwd -P)
DESIRED_STATE="${REPO_ROOT}/.claude/plugin-consumption/agentic-engineering.desired-state.json"
PLUGIN_ID="agentic-engineering@devantler-plugins"

die() {
  printf 'portfolio-surveyor forge hook: %s\n' "$1" >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required to verify runtime assets"
  fi
}

command -v jq >/dev/null 2>&1 ||
  die "jq is required to resolve and verify the runtime plugin"
[ -r "${DESIRED_STATE}" ] ||
  die "cannot read consumer desired state: ${DESIRED_STATE}"

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  plugins_root="${CLAUDE_CONFIG_DIR}/plugins"
elif [ -n "${HOME:-}" ]; then
  plugins_root="${HOME}/.claude/plugins"
else
  die "neither CLAUDE_CONFIG_DIR nor HOME resolves the Claude plugin registry"
fi
registry="${plugins_root}/installed_plugins.json"
[ -r "${registry}" ] ||
  die "cannot read runtime plugin registry: ${registry}"

# The registry holds one record per install SCOPE: every session worktree adds a
# project-scope record keyed by its `projectPath`, and records for removed
# worktrees stay behind. Requiring exactly one record therefore refused every
# surveyor call from 2026-11-04 (14 of 14 dispatches; 178 records naming 5 cache
# versions on 2026-11-08, monorepo#4835). Only records that apply to THIS
# project count: a project- or local-scope record for REPO_ROOT or the
# runtime's CLAUDE_PROJECT_DIR (the more specific scope), else the user-scope
# record (no scope reads as user). Identical paths are one path; two distinct
# paths in the deciding tier are still refused. Whichever path resolves, every
# asset below must still match its pinned digest before anything runs.
install_path="$(jq -er --arg id "${PLUGIN_ID}" \
  --arg root "${REPO_ROOT}" --arg project_dir "${CLAUDE_PROJECT_DIR:-}" '
  def trimmed: sub("/+$"; "");
  [.plugins[$id][]?
    | select(type == "object" and (.installPath | type) == "string"
        and (.installPath | length) > 0)] as $all
  | ([$root, $project_dir] | map(select(length > 0) | trimmed)) as $roots
  | ([$all[] | select((.scope == "project" or .scope == "local")
        and (((.projectPath // "") | trimmed) as $p | any($roots[]; . == $p)))
      | .installPath] | unique) as $project
  | ([$all[] | select(.scope == null or .scope == "user") | .installPath]
      | unique) as $user
  | (if ($project | length) > 0 then $project else $user end)
  | select(length == 1)
  | .[0]
' "${registry}" 2>/dev/null)" ||
  die "runtime registry must name exactly one install path for ${PLUGIN_ID} that applies to ${REPO_ROOT}"
[ -d "${install_path}" ] ||
  die "registered plugin install path does not exist: ${install_path}"

asset_failure=''
verify_asset() {
  local root="$1" relative_path="$2"
  local asset="${root}/${relative_path}"
  local expected actual

  if [ ! -f "${asset}" ] || [ ! -x "${asset}" ] || [ -L "${asset}" ]; then
    asset_failure="runtime asset is not a regular executable: ${relative_path}"
    return 1
  fi
  expected="$(jq -er --arg path "${relative_path}" '
    [.spec.source.requiredRuntimeAssets[]?
      | select(
          .path == $path
          and .executable == true
          and (.sha256 | type) == "string"
          and (.sha256 | length) == 64
        )
      | .sha256]
    | select(length == 1)
    | .[0]
  ' "${DESIRED_STATE}" 2>/dev/null)" ||
    die "desired state does not declare one executable digest for ${relative_path}"
  # Called from a condition, errexit is off here: a failed read must not pass
  # as a hash, and must not be reported as a mismatch either.
  if ! actual="$(sha256_file "${asset}")" || [ -z "${actual}" ]; then
    asset_failure="cannot read runtime asset ${relative_path} to hash it"
    return 1
  fi
  if [ "${actual}" != "${expected}" ]; then
    asset_failure="runtime asset ${relative_path} sha256 does not match desired state"
    return 1
  fi
}

classifier_relative="scripts/classify-default-branch-ci-runs.sh"
guard_relative="scripts/forge-readonly-guard.sh"
adapter_relative="scripts/surveyor-forge-readonly.sh"
thread_counter_relative="scripts/count-unresolved-review-threads.sh"
# Every asset the guard can run is verified. The guard admits the bundled thread
# counter by its installed path, so the surveyor may run it. From 6.0.0 the
# classifier and the thread counter source json-stream.lib.sh from their own
# directory, so its bytes run inside two admitted programs: pin it too. Every
# other asset the desired state pins is verified as well, so an install is only
# ever accepted whole.
all_assets="$(jq -er --arg a "${classifier_relative}" --arg b "${guard_relative}" \
  --arg c "${adapter_relative}" --arg d "${thread_counter_relative}" \
  --arg e "scripts/json-stream.lib.sh" '
  [$a, $b, $c, $d, $e] as $named
  | [.spec.source.requiredRuntimeAssets[]? | .path | select(type == "string" and length > 0)]
  | $named + (map(select(. as $p | $named | index($p) | not)) | unique)
  | .[]
' "${DESIRED_STATE}" 2>/dev/null)" ||
  die "desired state does not list its required runtime assets"
verify_install() {
  local root="$1" relative_path
  while IFS= read -r relative_path; do
    verify_asset "${root}" "${relative_path}" || return 1
  done <<<"${all_assets}"
}

# The installed plugin lags the pin whenever the marketplace has moved past it: a
# gated refresh installs only the pin, so it cannot catch up until the next pin
# bump. From the 2026-11-11 bump, 5 of 6 surveyor dispatches were refused that way
# (monorepo#4969). On drift the contract follows the reviewed definition at the
# gitlink, so the reviewed checkout in THIS checkout is the first fallback. It is held
# to the same digests, and is used only at its own real path, never through a link.
#
# The session root comes from the runtime's own hook payload (`cwd`), never from the
# surveyor's text, and counts only when it is a checkout of the SAME repository (one
# git common dir). It is resolved here because it serves two purposes: the second
# reviewed-checkout fallback below, and the classifier declarations further down.
hook_input=$(cat 2>/dev/null || true)
session_cwd=$(printf '%s' "${hook_input}" |
  jq -r 'if (.cwd | type) == "string" then .cwd else "" end' 2>/dev/null || true)
session_root=''
if [ -n "${session_cwd}" ] && [ -d "${session_cwd}" ]; then
  session_root=$(git -C "${session_cwd}" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "${session_root}" ]; then
    session_root=$(CDPATH='' cd -- "${session_root}" 2>/dev/null && pwd -P || true)
  fi
fi
session_same_repo=false
if [ -n "${session_root}" ] && [ "${session_root}" != "${REPO_ROOT}" ]; then
  repo_common=$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  session_common=$(git -C "${session_root}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [ -z "${repo_common}" ] || repo_common=$(CDPATH='' cd -- "${repo_common}" 2>/dev/null && pwd -P || true)
  [ -z "${session_common}" ] || session_common=$(CDPATH='' cd -- "${session_common}" 2>/dev/null && pwd -P || true)
  if [ -n "${repo_common}" ] && [ "${repo_common}" = "${session_common}" ]; then
    session_same_repo=true
  fi
fi

# Sets checkout_failure and returns 1 unless the reviewed copy below <root> is
# populated, reached at its own real path, and matches every pinned digest.
checkout_failure=''
verify_reviewed_checkout() {
  local checkout="$1/libraries/agent-plugins/plugins/agentic-engineering" real=''
  if [ -d "${checkout}" ]; then
    real=$(CDPATH='' cd -- "${checkout}" 2>/dev/null && pwd -P || true)
  fi
  if [ -z "${real}" ]; then
    checkout_failure="libraries/agent-plugins is not populated"
  elif [ "${real}" != "${checkout}" ]; then
    checkout_failure="libraries/agent-plugins resolves through a symlink"
  elif ! verify_install "${checkout}"; then
    checkout_failure="${asset_failure}"
  else
    return 0
  fi
  return 1
}

# For a scheduled worktree session the runtime resolves "$CLAUDE_PROJECT_DIR", and
# so REPO_ROOT, to the SHARED main checkout, whose submodule sits off the pin. That
# left 3 of 4 surveyor dispatches refused after the first fallback shipped
# (monorepo#4974). The session worktree holds the pinned bytes, so it is the second
# fallback, held to exactly the same checks.
if ! verify_install "${install_path}"; then
  installed_failure="${asset_failure}"
  if verify_reviewed_checkout "${REPO_ROOT}"; then
    install_path="${REPO_ROOT}/libraries/agent-plugins/plugins/agentic-engineering"
  else
    refusal="${installed_failure}; reviewed checkout fallback: ${checkout_failure}"
    if [ "${session_same_repo}" = true ]; then
      if verify_reviewed_checkout "${session_root}"; then
        install_path="${session_root}/libraries/agent-plugins/plugins/agentic-engineering"
        refusal=''
      else
        refusal="${refusal}; session checkout fallback (${session_root}/libraries/agent-plugins/plugins/agentic-engineering): ${checkout_failure}"
      fi
    fi
    [ -z "${refusal}" ] || die "${refusal}"
  fi
fi

# The reviewed plugin admits a CONSUMING deployment's own classifier only when
# that deployment DECLARES it, as an absolute path, in the hook environment.
# Declaring is a trust assertion the guard cannot verify, so it is pinned here
# rather than inherited: an inherited value would let anything able to set the
# surveyor's environment widen the read-only allowlist to a program of its
# choosing, which is exactly the bypass the SCOPE and GUARD pins above close.
#
# Twelve programs are declared, and all are READS. pr-ownership-disclosure.sh
# classifies a `devantler` PR body as the maintainer's interactive work or the
# routine's own output. Without a route for it the surveyor falls back to
# hand-deriving that verdict, and that substitution has already misread live
# maintainer PRs — the verdict decides whether a `devantler` comment is the
# maintainer's control channel or the agent's own output.
# programmed-bot-review-exemption.sh decides whether a release or updater PR is
# exempt from review; undeclared, every such PR reached the orchestrator as
# QUERY-UNKNOWN and sat green and unmerged (monorepo#3123, monorepo#3139). It
# reads its payload from stdin and one reviewed allowlist file, nothing else.
# pr-unresolved-threads.sh counts a PR's unresolved review threads from the
# paginated GraphQL pages on stdin, and says UNKNOWN for a failed, empty or
# partial read. Undeclared, the surveyor counted pages by hand, and a hand count
# once read an open Major thread as zero (monorepo#2670).
# coderabbit-summary-verdict.sh judges ONE CodeRabbit summary comment body on stdin
# against one exact head and prints a single verdict line. The overlay prescribes
# it (monorepo#2653); undeclared, every call was refused and the surveyor judged
# the summary by eye instead (monorepo#3529).
# local-review-verdict.sh judges a PR's review-object pages on stdin for a clean
# local review round at one exact head. The contract prescribes it (monorepo#3487);
# undeclared, 3 of the first 5 surveyor dispatches after that were refused and
# fell back to judging the round by eye (monorepo#2697).
# coderabbit-review-verdict.sh judges ONE CodeRabbit review object on stdin against
# one exact head. The contract names it (monorepo#3571); undeclared, the surveyor
# kept judging review objects by eye, which is how empty reply containers were read
# as reviews (monorepo#3572).
# coderabbit-comment-verdict.sh judges ONE CodeRabbit reply comment on stdin against one exact
# head, by its structure rather than a phrase list. The contract names it (monorepo#3008);
# undeclared, the surveyor matched two reply wordings by eye and read every other finding-free
# reply (`I reviewed <sha>`, among others) as no review, spending the metered lanes on green heads.
# kata-measure-date.sh reads ONE Kata issue body on stdin and says whether its structured
# `**Measure on:**` date has arrived. Undeclared, the surveyor read the date by eye and reported
# both open Katas as past due from their createdAt (monorepo#2838). The same stdin object also
# carries the Kata's sub-issue summary, so a future date is not-due only when an open sub-issue
# or a recorded delivery means the skip hides nothing (monorepo#3619).
# pr-worktree-holder.sh reads a PR's head branch from the forge JSON on stdin and says
# whether a live process on this host works in a local checkout of it. It is the one
# declared program that reads beyond stdin — the process table (`lsof`, `ps`) and local
# git metadata — but never a path or argument taken from its input. Every other
# active-work signal is a published event, and #3053 read idle on all of them while
# two sessions worked in its worktree (monorepo#3067).
# maintainer-comment-candidates.sh reads ONE comment payload on stdin and prints the
# maintainer-comment sweep's rows, each bound to the artifact named by the comment's own
# permalink. Undeclared, the surveyor composed those rows by hand and reported a real
# maintainer-channel comment under the wrong issue, which discarded it (monorepo#3163).
# required-gate-completeness.sh reads ONE pull request on stdin (its url, base branch and
# head) and says whether every REQUIRED gate ran at that head. It is the one declared
# program that reads the forge itself: GET requests only, for the devantler-tech
# repository, base and head that pull request names, which are reads the guard already
# admits from the surveyor directly. Its argv is `--input -` alone and it refuses any
# other owner before the first request. Undeclared, the survey could only read the check
# rollup, which lists what ran and so reported an absent required check as green
# (monorepo#3506).
# managed-run-streak.sh reads ONE GitHub-managed workflow's run history on stdin and says
# whether a red run on main is the first failure of its streak or a repeated one, refusing a
# history shorter than the pages' own total_count. Undeclared, the surveyor counted the streak
# by eye from a run listing, so the tested rule and the applied one could drift (monorepo#3586).
#
# Absence fails CLOSED, consistently with DESIRED_STATE above: a checkout that
# cannot present its own reviewed files does not get a survey. Exiting 0 with
# the capability silently missing is the worse direction — it returns the
# surveyor to the hazardous fallback with nothing anywhere saying so.
classifier_names='pr-ownership-disclosure.sh
programmed-bot-review-exemption.sh
pr-unresolved-threads.sh
coderabbit-summary-verdict.sh
local-review-verdict.sh
coderabbit-review-verdict.sh
coderabbit-comment-verdict.sh
kata-measure-date.sh
pr-worktree-holder.sh
maintainer-comment-candidates.sh
required-gate-completeness.sh
managed-run-streak.sh'

consumer_classifiers=''
for classifier_name in ${classifier_names}; do
  consumer_classifier="${REPO_ROOT}/.claude/scripts/${classifier_name}"
  if [ ! -f "${consumer_classifier}" ] ||
    [ ! -x "${consumer_classifier}" ] ||
    [ -L "${consumer_classifier}" ]; then
    die "consumer classifier is not a regular executable: ${consumer_classifier}"
  fi
  case "${consumer_classifier}" in
    *:*) die "consumer classifier path contains ':' and cannot be declared: ${consumer_classifier}" ;;
  esac
  consumer_classifiers="${consumer_classifiers:+${consumer_classifiers}:}${consumer_classifier}"
done

# Also declare each classifier at the checkout the session is RUNNING IN, which
# is what the overlay tells the surveyor to type (monorepo#3732). REPO_ROOT
# follows the hook's own location, i.e. "$CLAUDE_PROJECT_DIR", and the harness
# resolves that to the session worktree in some dispatch shapes and to the
# shared main checkout in others. It flipped between them twice (monorepo#3127,
# then 2026-10-01T00Z), and each flip left one of the two paths refused: from
# 2026-10-01 the worktree path was denied on 64 of 67 calls while it had been
# admitted on 72 of 75 the day before, and the surveyor fell back to the
# hand-derivation these classifiers exist to replace.
#
# This adds no program the guard did not already trust. The session root (resolved
# above from the payload `cwd`, same repository only) gets a copy declared only when
# it is a regular executable byte-identical to the REPO_ROOT copy declared above.
# Anything else — no payload cwd, another repository, a diverged or missing copy —
# declares nothing extra, and the REPO_ROOT declaration stands alone exactly as before.
if [ "${session_same_repo}" = true ]; then
  for classifier_name in ${classifier_names}; do
    session_classifier="${session_root}/.claude/scripts/${classifier_name}"
    case "${session_classifier}" in *:*) continue ;; esac
    if [ -f "${session_classifier}" ] && [ -x "${session_classifier}" ] &&
      [ ! -L "${session_classifier}" ] &&
      cmp -s "${session_classifier}" "${REPO_ROOT}/.claude/scripts/${classifier_name}"; then
      consumer_classifiers="${consumer_classifiers}:${session_classifier}"
    fi
  done
fi

# The frontmatter hook is already scoped to portfolio-surveyor. Clear the
# adapter's optional identity scope and pin its test override to the verified
# sibling so inherited environment cannot bypass either half of the wiring.
SURVEYOR_FORGE_READONLY_SCOPE='' \
SURVEYOR_FORGE_READONLY_GUARD="${install_path}/${guard_relative}" \
SURVEYOR_FORGE_READONLY_CLASSIFIERS="${consumer_classifiers}" \
  exec "${install_path}/${adapter_relative}" <<<"${hook_input}"
