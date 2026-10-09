#!/usr/bin/env bash
# Contract tests for shared-checkout-freshness.sh.
#
# Each case builds a real upstream repository and a real clone standing in for the shared
# checkout, so every verdict comes from git itself rather than from a mocked report. The
# property that matters most is the one #3331 was filed for: a checkout that is behind AND
# cannot be fast-forwarded must be reported as FROZEN with the blocking path, never passed
# over. Each FROZEN case is paired with a control that differs only in the blocking edit, and
# the fast-forward git would actually perform is run to confirm the verdict matches it.
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
impl="${script_dir}/shared-checkout-freshness.sh"

pass=0; failures=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { failures=$((failures + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

fixture=$(mktemp -d) || { printf 'cannot create a fixture directory\n' >&2; exit 2; }
test_run_completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf -- "$fixture"
  if [ "${test_run_completed}" != 1 ]; then
    echo "shared-checkout-freshness.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT
fixture=$(cd "$fixture" && pwd -P)

git_try() { # <dir> <git args...> — git with a fixed identity and no host configuration
  local dir=$1; shift
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$dir" -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false -c init.defaultBranch=main "$@"
}

# g <dir> <git args...> — a fixture step that must succeed. A setup command that fails would
# leave the fixture in another state than the case describes, and the assertion could then
# pass without testing it, so the run stops instead. Inside $(...) the exit only leaves the
# subshell: such callers check the status themselves.
g() {
  git_try "$@" || { printf 'fixture setup failed: git -C %s\n' "$*" >&2; exit 2; }
}

# new_pair <name> — an upstream with two files and one commit, and a clone of it. Sets
# $up and $co.
new_pair() {
  up="$fixture/$1-upstream"; co="$fixture/$1-checkout"
  mkdir -p "$up"
  g "$up" init -q
  printf 'one\n' > "$up/contract.md"
  printf 'one\n' > "$up/other.md"
  g "$up" add contract.md other.md
  g "$up" commit -q -m 'initial'
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git clone -q "$up" "$co" ||
    { printf 'fixture setup failed: git clone %s\n' "$up" >&2; exit 2; }
}

# advance <file> — one more upstream commit that changes <file>.
advance() {
  printf 'more\n' >> "$up/$1"
  g "$up" add -- "$1"
  g "$up" commit -q -m "change $1"
}

run() { # [args...] -> sets out, rc
  out=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$impl" "$@" 2>&1); rc=$?
}

# ff_succeeds — would git itself fast-forward this checkout? Run on a copy, so the fixture
# the verdict was read from is left untouched.
ff_succeeds() {
  local copy="$fixture/ff-probe"
  rm -rf -- "$copy"; cp -R "$co" "$copy"
  git_try "$copy" fetch -q origin '+refs/heads/main:refs/remotes/origin/main' || return 2
  # The one git call whose failure is an answer, not a broken fixture.
  git_try "$copy" merge -q --ff-only origin/main >/dev/null 2>&1
}

expect() { # <name> <rc> <pattern>
  if [ "$rc" -eq "$2" ] && grep -qE -- "$3" <<<"$out"; then ok "$1"
  else bad "$1" "want rc=$2 /$3/, got rc=$rc $out"; fi
}

printf 'shared-checkout-freshness.sh contract tests\n'

# --- CURRENT ------------------------------------------------------------------------
new_pair current
run --repo-dir "$co"
expect "a checkout at the remote head is CURRENT and exits 0" 0 '^shared-checkout-freshness: CURRENT '

printf 'local\n' >> "$co/contract.md"
run --repo-dir "$co"
expect "a local edit does not make an up-to-date checkout a finding" 0 ': CURRENT '

# --- BEHIND (syncable) --------------------------------------------------------------
new_pair behind
advance contract.md
run --repo-dir "$co"
expect "a clean checkout one commit behind is BEHIND, exit 1, with the command" 1 ': BEHIND — 1 commit\(s\).*merge --ff-only origin/main'
if ff_succeeds; then ok "control: git really can fast-forward the BEHIND checkout"
else bad "control: git really can fast-forward the BEHIND checkout"; fi

printf 'local\n' >> "$co/other.md"
run --repo-dir "$co"
expect "an edit to a path the incoming commits do not touch stays BEHIND" 1 ': BEHIND '
if ff_succeeds; then ok "control: git fast-forwards over the unrelated edit"
else bad "control: git fast-forwards over the unrelated edit"; fi

# --- FROZEN -------------------------------------------------------------------------
new_pair frozen
advance contract.md
advance contract.md
printf 'local\n' >> "$co/contract.md"
run --repo-dir "$co"
expect "an edit to an incoming path is FROZEN, exit 1, naming the path and the count" 1 ': FROZEN — behind 2 commit\(s\).*1 path\(s\).*contract\.md'
if ff_succeeds; then bad "control: git refuses to fast-forward the FROZEN checkout" "the merge succeeded"
else ok "control: git refuses to fast-forward the FROZEN checkout"; fi
if grep -q 'Do not discard' <<<"$out"; then ok "FROZEN tells the reader not to discard the edit"
else bad "FROZEN tells the reader not to discard the edit" "$out"; fi

new_pair staged
advance contract.md
printf 'local\n' >> "$co/contract.md"
g "$co" add contract.md
run --repo-dir "$co"
expect "a STAGED edit to an incoming path is FROZEN too" 1 ': FROZEN .*contract\.md'

new_pair untracked
printf 'new\n' > "$up/added.md"
g "$up" add added.md
g "$up" commit -q -m 'add a file'
printf 'mine\n' > "$co/added.md"
run --repo-dir "$co"
expect "an untracked file the incoming commits add is FROZEN" 1 ': FROZEN .*added\.md'
if ff_succeeds; then bad "control: git refuses to overwrite the untracked file" "the merge succeeded"
else ok "control: git refuses to overwrite the untracked file"; fi

new_pair deleted
advance contract.md
rm -- "$co/contract.md"
run --repo-dir "$co"
expect "an incoming file that is only missing from the working tree does not block" 1 ': BEHIND '
if ff_succeeds; then ok "control: git fast-forwards and restores the missing file"
else bad "control: git fast-forwards and restores the missing file"; fi

new_pair nested
mkdir -p "$up/dir"; printf 'new\n' > "$up/dir/added.md"
g "$up" add dir/added.md
g "$up" commit -q -m 'add a nested file'
mkdir -p "$co/dir"; printf 'mine\n' > "$co/dir/added.md"; printf 'mine\n' > "$co/dir/unrelated.md"
run --repo-dir "$co"
expect "an untracked file inside an untracked directory is matched by its own path" 1 ': FROZEN .*1 path\(s\).*dir/added\.md'

new_pair spaced
printf 'one\n' > "$up/a name with spaces.md"
g "$up" add -- 'a name with spaces.md'
g "$up" commit -q -m 'add a spaced path'
g "$co" pull -q origin main
advance 'a name with spaces.md'
printf 'local\n' >> "$co/a name with spaces.md"
run --repo-dir "$co"
expect "a blocking path holding spaces is reported as ONE path" 1 ': FROZEN .*1 path\(s\).*a\\ name\\ with\\ spaces\.md'

new_pair many
for i in 1 2 3 4 5 6 7; do
  printf 'one\n' > "$up/f$i.md"; g "$up" add "f$i.md"
done
g "$up" commit -q -m 'add seven'
g "$co" pull -q origin main
for i in 1 2 3 4 5 6 7; do printf 'more\n' >> "$up/f$i.md"; g "$up" add "f$i.md"; done
g "$up" commit -q -m 'change seven'
for i in 1 2 3 4 5 6 7; do printf 'local\n' >> "$co/f$i.md"; done
run --repo-dir "$co"
expect "more than five blocking paths are counted in full and summarised" 1 ': FROZEN .*7 path\(s\).*and 2 more'

# --- the main worktree is judged, wherever the call comes from ------------------------
new_pair linked
advance contract.md
printf 'local\n' >> "$co/contract.md"
g "$co" worktree add -q "$fixture/linked-wt" -b side
run --repo-dir "$fixture/linked-wt"
expect "called from a linked worktree, it still judges the main worktree" 1 ': FROZEN .*linked-checkout'

# --- OFF-BRANCH / AHEAD / DIVERGED --------------------------------------------------
new_pair offbranch
advance contract.md
g "$co" checkout -q -b feature
run --repo-dir "$co"
expect "behind with another branch checked out is OFF-BRANCH" 1 ": OFF-BRANCH .*'feature' checked out"

new_pair detached
advance contract.md
g "$co" checkout -q --detach
run --repo-dir "$co"
expect "behind with a detached HEAD is OFF-BRANCH" 1 ': OFF-BRANCH .*a detached HEAD'

new_pair ahead
printf 'local\n' >> "$co/other.md"
g "$co" commit -q -am 'local commit'
run --repo-dir "$co"
expect "a local commit the remote lacks is AHEAD" 1 ': AHEAD — 1 local commit'

advance contract.md
run --repo-dir "$co"
expect "behind and ahead at once is DIVERGED" 1 ': DIVERGED — behind 1 and ahead 1'

# --- fetching -----------------------------------------------------------------------
new_pair nofetch
advance contract.md
run --repo-dir "$co" --no-fetch
expect "--no-fetch judges the stale remote-tracking ref, so the checkout reads CURRENT" 0 ': CURRENT '
run --repo-dir "$co"
expect "without --no-fetch the same checkout is BEHIND (the fetch is not inert)" 1 ': BEHIND '

# --- UNKNOWN, never CURRENT ---------------------------------------------------------
new_pair gone
rm -rf -- "$up"
run --repo-dir "$co"
expect "a failed fetch is UNKNOWN (exit 2), not CURRENT" 2 'UNKNOWN — cannot fetch origin/main \(3 attempts\)'

mkdir -p "$fixture/plain"
run --repo-dir "$fixture/plain"
expect "a directory that is not a repository is UNKNOWN" 2 'UNKNOWN — not a git repository'

run --repo-dir "$fixture/does-not-exist"
expect "a missing directory is UNKNOWN" 2 'UNKNOWN — not a directory'

new_pair nobranch
run --repo-dir "$co" --branch absent --no-fetch
expect "a remote branch that does not exist is UNKNOWN" 2 'UNKNOWN — cannot read origin/absent'

run --repo-dir "$co" --branch '../x'
expect "a branch name outside the ref alphabet is refused" 2 'UNKNOWN — invalid branch name'
run --repo-dir "$co" --remote '-o'
expect "a remote name that looks like an option is refused" 2 'UNKNOWN — invalid remote name'
run --repo-dir
expect "a flag with no value is a usage error" 2 'UNKNOWN — --repo-dir needs a value'
run --bogus
expect "an unknown argument is a usage error" 2 "UNKNOWN — unexpected argument '--bogus'"

# --- it reads only ------------------------------------------------------------------
new_pair readonly
advance contract.md
printf 'local\n' >> "$co/contract.md"
before=$(g "$co" rev-parse HEAD && g "$co" status --porcelain && cat "$co/contract.md") || exit 2
run --repo-dir "$co"
after=$(g "$co" rev-parse HEAD && g "$co" status --porcelain && cat "$co/contract.md") || exit 2
if [ "$before" = "$after" ]; then ok "the check leaves HEAD, the index and the local edit untouched"
else bad "the check leaves HEAD, the index and the local edit untouched"; fi

printf '\n%s passed, %s failed\n' "$pass" "$failures"
test_run_completed=1
[ "$failures" -eq 0 ]
