#!/usr/bin/env bash
# fix-hint-contract.test.sh — no fix hint a helper prints tells an agent to break the contract
# (monorepo#4282).
#
# WHY THIS EXISTS
#   The helpers and tests here print a fix hint beside a failure, so the agent reading it can act,
#   and an agent does what the hint says. merge-preflight-thread-gate.test.sh told it to populate a
#   submodule with a bare `git submodule update --init`, which AGENTS.md forbids because the bare
#   form breaks worktree isolation. Nothing compared the hints with the rules, so the next hint that
#   contradicts a guide would land unnoticed too.
#
# WHAT IT CHECKS
#   A hint is the text from a marker -- `populate them:`, `fix:`, `remedy:`, `run:` or `try:` -- to
#   the end of a non-comment line of a .claude/scripts/*.sh file. Every hint is matched against the
#   deny list below: commands the contract forbids an agent to run. Each deny entry names the file
#   and the sentence it comes from, and that sentence must still be in that file, which must still be
#   part of the contract (contract-text.sh), so an entry cannot outlive its rule or cite a guess.
#   A hint written without one of these markers is not seen; the markers are the shapes in use.
#
# FAILS CLOSED
#   A scan that finds no hint at all, an unreadable directory, or a contract that cannot be read is a
#   failure, never a pass: an extraction that finds nothing passes every deny check. The scanner is
#   first run against planted fixtures, so each deny entry is shown to fire and its near miss to pass.
#
# EXIT CODES
#   0 every assertion held · 1 an assertion failed
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/../.." && pwd)

failures=0
fail() {
  printf 'fix-hint contract: FAIL — %s\n' "$*" >&2
  failures=$((failures + 1))
}

tmp=''
fix_hint_test_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() {
  local rc=$?
  [ -z "$tmp" ] || rm -rf -- "$tmp"
  # bash 3.2 can report a set -u abort inside an EXIT trap as exit 0, so require completion.
  if [ "$fix_hint_test_finished" -ne 1 ] && [ "$rc" -eq 0 ]; then
    printf 'fix-hint contract: aborted before completion\n' >&2
    exit 1
  fi
}
trap cleanup EXIT
tmp=$(mktemp -d)

# The deny list, one tab-separated entry per line: <id>, the ERE matched against a hint, the source
# file, and the source sentence. The sentence is compared with the source file's text after runs of
# whitespace are folded into one space, so a rule that wraps across lines still matches.
git_c='git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+'
# shellcheck disable=SC2016 # The backticks are literal contract text, not a substitution.
safety_rule='Never `git reset --hard`, `git stash`, force-push, or discard changes you did not author.'
# shellcheck disable=SC2016 # The backticks are literal contract text, not a substitution.
deny_list=$(
  printf '%s\t%s\t%s\t%s\n' \
    bare-submodule-init 'submodule update([[:space:]].*)?[[:space:]]--init' \
    AGENTS.md 'never a bare `git submodule update --init`, which breaks worktree isolation' \
    add-everything "${git_c}add[[:space:]]+(-A|--all|\\.)([[:space:]]|\$|[\"'])" \
    .claude/guides/git-and-worktrees.md 'Never `git add -A` / `git add .` — stage only files you edited.' \
    stash "${git_c}stash(\$|[[:space:]]*[\"';&|]|[[:space:]]+(push|save|-))" \
    .claude/guides/git-and-worktrees.md "$safety_rule" \
    reset-hard 'reset[[:space:]]+--hard' \
    .claude/guides/git-and-worktrees.md "$safety_rule" \
    force-push "${git_c}push([[:space:]][^|;&]*)?[[:space:]](--force|-f([[:space:]]|\$))" \
    .claude/guides/git-and-worktrees.md "$safety_rule" \
    merge-admin 'gh[[:space:]]+pr[[:space:]]+merge([[:space:]][^|;&]*)?[[:space:]]--admin' \
    AGENTS.md 'Never `--admin`.'
)

# extract_hints <dir>: prints `<file>:<line>:<hint>` for every hint in <dir>/*.sh. Exit 2 when the
# directory holds no script or a script cannot be read: no listing is ever read as "no hints".
extract_hints() {
  local dir=$1 scripts=()
  local f
  for f in "$dir"/*.sh; do
    [ -f "$f" ] && scripts+=("$f")
  done
  [ "${#scripts[@]}" -gt 0 ] || return 2
  awk '
    /^[[:space:]]*#/ { next }
    {
      if (match($0, /(^|[^[:alnum:]_.-])(populate them|fix|remedy|run|try):/)) {
        hint = substr($0, RSTART)
        sub(/^[^[:alnum:]]*/, "", hint)
        print FILENAME ":" FNR ":" hint
      }
    }
  ' "${scripts[@]}" || return 2
}

# scan <dir>: 0 hints found and none denied; 1 a denied hint, each printed as `<id> <file>:<line>`;
# 2 no hint found, or the directory could not be read.
scan() {
  local hints id pattern found=0 hit
  hints=$(extract_hints "$1") || return 2
  [ -n "$hints" ] || return 2
  while IFS=$'\t' read -r id pattern _ _; do
    [ -n "$id" ] || continue
    # Fed from a variable, not a pipe, so an early-exiting reader cannot turn a match into a miss.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      local location=${hit%%:*} rest=${hit#*:}
      location="${location}:${rest%%:*}"
      local hint=${rest#*:}
      if grep -Eq -- "$pattern" <<<"$hint"; then
        printf '%s %s\n' "$id" "$location"
        found=1
      fi
    done <<<"$hints"
  done <<<"$deny_list"
  [ "$found" -eq 0 ] || return 1
  return 0
}

# --- 1. every deny entry cites a sentence that is still in a contract file --------------------
if ! contract_files=$(bash "${script_dir}/contract-text.sh" --files --root "$repo_root"); then
  fail 'the contract file list cannot be assembled (contract-text.sh --files failed)'
  contract_files=''
fi
entries=0
while IFS=$'\t' read -r id _ source sentence; do
  [ -n "$id" ] || continue
  entries=$((entries + 1))
  grep -Fqx -- "$source" <<<"$contract_files" ||
    fail "deny entry '${id}' cites ${source}, which is not part of the contract"
  if ! folded=$(tr -s '[:space:]' ' ' <"${repo_root}/${source}"); then
    fail "deny entry '${id}' cites ${source}, which cannot be read"
    continue
  fi
  grep -Fq -- "$sentence" <<<"$folded" ||
    fail "deny entry '${id}' cites a sentence ${source} no longer holds: ${sentence}"
done <<<"$deny_list"
[ "$entries" -eq 6 ] || fail "the deny list holds ${entries} entries, not the 6 this test plants hints for"

# --- 2. planted hints: each deny entry fires, and its near miss passes -------------------------
# The planted text is assembled from parts so this file never holds a denied hint itself: the scan
# in step 4 reads this file too.
plant() { # plant <dir> <marker> <hint>: a fail message whose second line is the hint
  mkdir -p "$1"
  printf 'fail "the thing is missing\n  %s: %s"\n' "$2" "$3" >"${1}/planted.sh"
}
expect_denied() { # expect_denied <case> <marker> <hint> <id>
  local dir="${tmp}/$1" out rc=0
  plant "$dir" "$2" "$3"
  out=$(scan "$dir") || rc=$?
  [ "$rc" -eq 1 ] || fail "planted hint '$3' was not denied (exit ${rc}, not 1)"
  grep -Eq "^$4 ${dir}/planted.sh:2$" <<<"$out" ||
    fail "planted hint '$3' was not reported as '$4' at its line; it said: ${out}"
}
expect_allowed() { # expect_allowed <case> <marker> <hint>
  local dir="${tmp}/$1" out rc=0
  plant "$dir" "$2" "$3"
  out=$(scan "$dir") || rc=$?
  [ "$rc" -eq 0 ] || fail "near-miss hint '$3' was denied (exit ${rc}, not 0): ${out}"
}
init_word='--in''it'
expect_denied submodule 'populate them' "git -c 'url.https://github.com/.insteadOf=git@github.com:' submodule update ${init_word} libraries/agent-plugins" bare-submodule-init
expect_denied submodule-plain fix "git submodule update ${init_word} --recursive" bare-submodule-init
expect_allowed submodule-wrapper 'populate them' '.claude/scripts/submodule-init.sh libraries/agent-plugins'
expect_denied add-all run "git add -""A" add-everything
expect_denied add-dot try "git -C wt add ""." add-everything
expect_allowed add-path run 'git add .claude/scripts/fix-hint-contract.test.sh'
expect_denied stash fix "git sta""sh" stash
expect_denied stash-push remedy "git sta""sh push -m wip" stash
expect_allowed stash-list fix "git sta""sh list"
expect_denied reset fix "git reset --ha""rd origin/main" reset-hard
expect_allowed reset-soft fix 'git reset --soft HEAD~1'
expect_denied force run "git push --for""ce origin branch" force-push
expect_denied force-short run "git -C wt push -""f origin branch" force-push
expect_allowed push-plain run 'git push origin claude/branch'
expect_denied admin run "gh pr merge 12 --squash --ad""min" merge-admin
expect_allowed merge-pinned run 'gh pr merge 12 --squash --match-head-commit abc'

# A word that merely ends in a marker is not a marker: `prefix:` names no hint.
dir="${tmp}/not-a-marker"
plant "$dir" prefix "git sta""sh"
rc=0
out=$(scan "$dir") || rc=$?
[ "$rc" -eq 2 ] || fail "a word ending in a marker was read as a hint (exit ${rc}, not 2): ${out}"
# A comment is not printed, so it is not a hint.
dir="${tmp}/comment"
mkdir -p "$dir"
printf '# fix: git sta%s\nfail "x\n  fix: .claude/scripts/submodule-init.sh x"\n' sh >"${dir}/commented.sh"
rc=0
out=$(scan "$dir") || rc=$?
[ "$rc" -eq 0 ] || fail "a commented-out hint was scanned (exit ${rc}, not 0): ${out}"

# --- 3. no hint found is UNKNOWN, never clean ----------------------------------------------
dir="${tmp}/no-hints"
mkdir -p "$dir"
printf 'echo nothing to see\n' >"${dir}/quiet.sh"
rc=0
scan "$dir" >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "a directory with no hints exited ${rc}, not 2 (UNKNOWN)"
rc=0
scan "${tmp}/absent" >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "a directory with no scripts exited ${rc}, not 2 (UNKNOWN)"

# --- 4. the real helpers print no denied hint ----------------------------------------------
rc=0
out=$(scan "$script_dir") || rc=$?
case "$rc" in
  0) ;;
  1) fail "a helper prints a fix hint the contract forbids; use the command the cited rule allows:
${out}" ;;
  *) fail "the hints in ${script_dir} could not be read, or none was found (exit ${rc}) — the scan would be vacuous" ;;
esac
hint_count=$(extract_hints "$script_dir" | wc -l | tr -d ' ') || hint_count=0
[ "${hint_count:-0}" -gt 0 ] || fail 'no fix hint was found in the helpers, so step 4 checked nothing'

fix_hint_test_finished=1
if [ "$failures" -eq 0 ]; then
  printf 'fix-hint contract: all assertions passed (%s hints checked against %s deny entries)\n' \
    "$hint_count" "$entries"
  exit 0
fi
printf 'fix-hint contract: %d assertion(s) failed\n' "$failures" >&2
exit 1
