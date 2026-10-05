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

install_path="$(jq -er --arg id "${PLUGIN_ID}" '
  [.plugins[$id][]?.installPath | select(type == "string" and length > 0)]
  | select(length == 1)
  | .[0]
' "${registry}" 2>/dev/null)" ||
  die "runtime registry must name exactly one install path for ${PLUGIN_ID}"
[ -d "${install_path}" ] ||
  die "registered plugin install path does not exist: ${install_path}"

verify_asset() {
  local relative_path="$1"
  local asset="${install_path}/${relative_path}"
  local expected actual

  if [ ! -f "${asset}" ] || [ ! -x "${asset}" ] || [ -L "${asset}" ]; then
    die "runtime asset is not a regular executable: ${relative_path}"
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
  actual="$(sha256_file "${asset}")"
  [ "${actual}" = "${expected}" ] ||
    die "runtime asset ${relative_path} sha256 does not match desired state"
}

classifier_relative="scripts/classify-default-branch-ci-runs.sh"
guard_relative="scripts/forge-readonly-guard.sh"
adapter_relative="scripts/surveyor-forge-readonly.sh"
thread_counter_relative="scripts/count-unresolved-review-threads.sh"
verify_asset "${classifier_relative}"
verify_asset "${guard_relative}"
verify_asset "${adapter_relative}"
# The guard admits the bundled thread counter by its installed path, so the
# surveyor may run it: verify its pinned bytes like every other admitted asset.
verify_asset "${thread_counter_relative}"
# From 6.0.0 the classifier and the thread counter source this library from
# their own directory, so its bytes run inside two admitted programs: pin it too.
verify_asset "scripts/json-stream.lib.sh"

# The reviewed plugin admits a CONSUMING deployment's own classifier only when
# that deployment DECLARES it, as an absolute path, in the hook environment.
# Declaring is a trust assertion the guard cannot verify, so it is pinned here
# rather than inherited: an inherited value would let anything able to set the
# surveyor's environment widen the read-only allowlist to a program of its
# choosing, which is exactly the bypass the SCOPE and GUARD pins above close.
#
# Nine programs are declared, and all are READS. pr-ownership-disclosure.sh
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
# kata-measure-date.sh reads ONE Kata issue body on stdin and says whether its structured
# `**Measure on:**` date has arrived. Undeclared, the surveyor read the date by eye and reported
# both open Katas as past due from their createdAt (monorepo#2838).
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
kata-measure-date.sh
pr-worktree-holder.sh
maintainer-comment-candidates.sh'

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
# This adds no program the guard did not already trust. The session root comes
# from the runtime's own hook payload (`cwd`), never from the surveyor's text; it
# must be a checkout of the SAME repository (one git common dir); and a copy is
# declared there only when it is a regular executable byte-identical to the
# REPO_ROOT copy declared above. Anything else — no payload cwd, another
# repository, a diverged or missing copy — declares nothing extra, and the
# REPO_ROOT declaration stands alone exactly as before.
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
if [ -n "${session_root}" ] && [ "${session_root}" != "${REPO_ROOT}" ]; then
  repo_common=$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  session_common=$(git -C "${session_root}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [ -z "${repo_common}" ] || repo_common=$(CDPATH='' cd -- "${repo_common}" 2>/dev/null && pwd -P || true)
  [ -z "${session_common}" ] || session_common=$(CDPATH='' cd -- "${session_common}" 2>/dev/null && pwd -P || true)
  if [ -n "${repo_common}" ] && [ "${repo_common}" = "${session_common}" ]; then
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
fi

# The frontmatter hook is already scoped to portfolio-surveyor. Clear the
# adapter's optional identity scope and pin its test override to the verified
# sibling so inherited environment cannot bypass either half of the wiring.
SURVEYOR_FORGE_READONLY_SCOPE='' \
SURVEYOR_FORGE_READONLY_GUARD="${install_path}/${guard_relative}" \
SURVEYOR_FORGE_READONLY_CLASSIFIERS="${consumer_classifiers}" \
  exec "${install_path}/${adapter_relative}" <<<"${hook_input}"
