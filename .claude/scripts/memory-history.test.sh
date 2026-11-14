#!/usr/bin/env bash
# Behaviour tests for memory-history.sh (monorepo#5050) against throwaway stores.

set -euo pipefail

subject="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/memory-history.sh"
tmp="$(mktemp -d)"
finished=0
# bash 3.2 can report a set -e abort inside an EXIT trap as exit 0, so require completion.
on_exit() {
  local status=$?
  rm -rf "${tmp}"
  if [ "${finished}" != 1 ]; then
    echo "memory-history.test.sh: aborted before finishing; reporting failure" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT

fail() {
  echo "memory-history test: FAIL — $*" >&2
  exit 1
}

# expect <status> <stderr-substring> <command…>: the exit status and the reason must both match.
expect() {
  local want="$1" text="$2" got=0
  shift 2
  "$@" >"${tmp}/out" 2>"${tmp}/err" || got=$?
  [ "${got}" -eq "${want}" ] || { cat "${tmp}/err" >&2; fail "'$*' exited ${got}, want ${want}"; }
  [ -z "${text}" ] || grep -Fq -- "${text}" "${tmp}/err" "${tmp}/out" ||
    { cat "${tmp}/err" >&2; fail "'$*' did not report '${text}'"; }
}

# A Claude-style store with backup artifacts beside real memory.
store="${tmp}/memory"
mkdir -p "${store}/.memory-backups/store.1" "${store}/attic" "${store}/.memory-archive-backup-7"
printf 'index\n' >"${store}/MEMORY.md"
printf 'topic\n' >"${store}/topic.md"
printf 'old\n' >"${store}/attic/old.txt"
printf 'data\n' >"${store}/inventory.private.jsonl.gz"
printf 'bak\n' >"${store}/MEMORY.md.bak-20260101T000000Z"
printf 'bak\n' >"${store}/.memory-backups/store.1/MEMORY.md"
printf 'bak\n' >"${store}/.memory-archive-backup-7/topic.md"
hist="${tmp}/history/claude.git"

expect 0 'initialised' "${subject}" init --store "${store}" --git-dir "${hist}" --layout claude
[ ! -e "${store}/.git" ] || fail "init must not add a .git entry to the store"
tracked="$("${subject}" git --git-dir "${hist}" -- ls-files | sort | tr '\n' ' ')"
[ "${tracked}" = "MEMORY.md attic/old.txt inventory.private.jsonl.gz topic.md " ] ||
  fail "claude layout tracked the wrong files: ${tracked}"
expect 0 'already initialised' "${subject}" init --store "${store}" --git-dir "${hist}" --layout claude
expect 1 'outside the store' "${subject}" init --store "${store}" --git-dir "${store}/h.git" --layout claude

# Commits only when something changed, and a bad rewrite is recoverable.
expect 0 'unchanged' "${subject}" commit --git-dir "${hist}"
printf 'index\nnew line\n' >"${store}/MEMORY.md"
# A global config that signs commits and a caller's GIT_* environment are both ignored.
printf '[commit]\n\tgpgsign = true\n[user]\n\tsigningkey = none\n' >"${tmp}/global.gitconfig"
mkdir -p "${tmp}/elsewhere" && printf 'secret\n' >"${tmp}/elsewhere/secret"
GIT_CONFIG_GLOBAL="${tmp}/global.gitconfig" GIT_WORK_TREE="${tmp}/elsewhere" GIT_INDEX_FILE="${tmp}/idx" \
  "${subject}" commit --git-dir "${hist}" --message 'run 1' >"${tmp}/sha"
grep -Eq '^[0-9a-f]{40}$' "${tmp}/sha" || fail "commit did not print a sha"
tracked="$("${subject}" git --git-dir "${hist}" -- ls-files | sort | tr '\n' ' ')"
[ "${tracked}" = "MEMORY.md attic/old.txt inventory.private.jsonl.gz topic.md " ] ||
  fail "a caller's GIT_WORK_TREE changed what was committed: ${tracked}"
[ "$("${subject}" git --git-dir "${hist}" -- log --format=%G? -1)" = 'N' ] || fail "commit was signed"
: >"${store}/MEMORY.md"
expect 1 'named files' "${subject}" git --git-dir "${hist}" -- restore MEMORY.md
expect 1 'named files only' "${subject}" git --git-dir "${hist}" -- restore -- .
"${subject}" git --git-dir "${hist}" -- restore -- MEMORY.md
[ "$(cat "${store}/MEMORY.md")" = "$(printf 'index\nnew line')" ] || fail "restore did not bring the file back"
[ "$("${subject}" git --git-dir "${hist}" -- log --format=%s -1)" = 'run 1' ] || fail "message not kept"

# Never a remote: a repository that gained one is refused, and only read verbs and restore pass.
git --git-dir="${hist}" remote add origin https://example.invalid/x.git
expect 1 'must stay local' "${subject}" commit --git-dir "${hist}"
git --git-dir="${hist}" remote remove origin
for verb in push remote fetch pull ls-remote send-pack fetch-pack http-push bundle archive daemon \
  instaweb request-pull config clean reset stash checkout worktree gc -c; do
  expect 1 'not allowed' "${subject}" git --git-dir "${hist}" -- "${verb}" origin
done
for option in --output=/tmp/x --ext-diff -Ocat --open-files-in-pager=cat; do
  expect 1 'not allowed' "${subject}" git --git-dir "${hist}" -- grep "${option}" index
done
# Configuration that could reach the network or run a program is refused outright.
for key in alias.ship url.https://x.insteadOf core.fsmonitor core.sshCommand include.path diff.external; do
  git --git-dir="${hist}" config "${key}" value
  expect 1 'unsafe configuration' "${subject}" commit --git-dir "${hist}"
  git --git-dir="${hist}" config --unset "${key}"
done

# A Codex-style store: only <automation>/memory.md is tracked, and artifacts are never read.
codex="${tmp}/automations"
mkdir -p "${codex}/engineer/artifacts" "${codex}/improver"
printf 'e\n' >"${codex}/engineer/memory.md"
printf 'big\n' >"${codex}/engineer/artifacts/run.log"
printf 'cfg\n' >"${codex}/engineer/automation.toml"
printf 'i\n' >"${codex}/improver/memory.md"
printf 'salt\n' >"${codex}/.run-jitter-salt"
chmod 000 "${codex}/engineer/artifacts"
expect 0 'initialised' "${subject}" init --store "${codex}" --git-dir "${tmp}/history/codex.git" --layout codex
printf 'e2\n' >"${codex}/engineer/memory.md"
expect 0 '' "${subject}" commit --git-dir "${tmp}/history/codex.git"
chmod 700 "${codex}/engineer/artifacts"
tracked="$("${subject}" git --git-dir "${tmp}/history/codex.git" -- ls-files | sort | tr '\n' ' ')"
[ "${tracked}" = "engineer/memory.md improver/memory.md " ] || fail "codex layout tracked the wrong files: ${tracked}"
# A store with nothing to track yet still initialises.
mkdir -p "${tmp}/empty-codex"
expect 0 'initialised' "${subject}" init --store "${tmp}/empty-codex" --git-dir "${tmp}/history/empty.git" --layout codex

# Refusals and usage errors.
mkdir -p "${tmp}/withgit/.git"
expect 1 'already holds a .git' "${subject}" init --store "${tmp}/withgit" --git-dir "${tmp}/h2.git" --layout claude
expect 1 'not an initialised' "${subject}" commit --git-dir "${tmp}/missing.git"
expect 2 '' "${subject}" init --store "${store}" --git-dir "${tmp}/h3.git" --layout other
[ ! -e "${tmp}/h3.git" ] || fail "a refused layout must not leave a repository behind"
expect 2 '' "${subject}"

finished=1
echo "memory-history.test.sh: PASS"
