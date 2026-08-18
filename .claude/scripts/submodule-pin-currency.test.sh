#!/usr/bin/env bash
# submodule-pin-currency.test.sh — RED/GREEN coverage for the submodule pin currency pre-flight.
#
# The defect this guards against is a FALSE CURRENT: a check that reports the pin is up to date when
# it is not sends a run off to build against a stale tree, which is the exact failure the script
# exists to prevent (#2891). So the assertions are weighted toward the two ways a false CURRENT can
# be manufactured — comparing the revision range in the wrong order, and resolving an uninitialised
# submodule to its PARENT repository — rather than toward the happy path.
#
# Fixtures are real git repositories built in a scratch dir: a submodule with its own history, a
# bare "origin" for it to fetch from, and a superproject pinning a chosen commit. Nothing depends on
# the network, the surrounding checkout, or wall-clock time.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/submodule-pin-currency.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fails=0
asserts=0
note_fail() { echo "FAIL: $1" >&2; fails=$(( fails + 1 )); }

git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@e -c commit.gpgsign=false "$@"; }

# Build: an upstream product repo with <n> commits, a bare origin, and a superproject whose gitlink
# pins commit <pin_index> (1-based). Returns the superproject path on stdout.
# mkfixture <name> <n_commits> <pin_index>
mkfixture() {
  local name=$1 n=$2 pin_index=$3
  local root="$TMP/$name"
  mkdir -p "$root"

  git_q init -q "$root/product"
  local i
  for i in $(seq 1 "$n"); do
    echo "commit $i" >"$root/product/file.txt"
    git_q -C "$root/product" add file.txt
    git_q -C "$root/product" commit -q -m "c$i"
  done

  git_q init -q --bare "$root/origin.git"
  git_q -C "$root/product" remote add origin "$root/origin.git"
  git_q -C "$root/product" push -q origin main

  local pin
  pin=$(git_q -C "$root/product" rev-list --reverse main | sed -n "${pin_index}p")

  git_q init -q "$root/super"
  # `protocol.file.allow` — git refuses local-path submodules by default (CVE-2022-39253).
  git_q -c protocol.file.allow=always -C "$root/super" submodule -q add "$root/origin.git" sub
  git_q -C "$root/super" -c protocol.file.allow=always submodule -q update --init sub
  git_q -C "$root/super/sub" checkout -q "$pin"
  git_q -C "$root/super" add .gitmodules sub
  git_q -C "$root/super" commit -q -m "pin sub at $pin"

  printf '%s\n' "$root/super"
}

# run_check <cwd> [args...] -> sets OUT and RC
run_check() {
  local cwd=$1; shift
  set +e
  OUT=$(cd "$cwd" && "$SCRIPT" "$@" 2>&1)
  RC=$?
  set -e
}

expect_rc() {
  asserts=$(( asserts + 1 ))
  [ "$RC" = "$1" ] || note_fail "$2 (expected exit $1, got $RC)
--- output ---
$OUT"
}

expect_match() {
  asserts=$(( asserts + 1 ))
  printf '%s' "$OUT" | grep -q -- "$1" || note_fail "$2 (output lacks '$1')
--- output ---
$OUT"
}

expect_no_match() {
  asserts=$(( asserts + 1 ))
  printf '%s' "$OUT" | grep -q -- "$1" && note_fail "$2 (output wrongly contains '$1')
--- output ---
$OUT"
  return 0
}

# ------------------------------------------------------------------ BEHIND --
# The case that motivated the script: the pin is real, the submodule is healthy, and the product has
# simply moved on. Anything other than exit 1 here means a run would build on the stale tree.
super=$(mkfixture behind 5 2)
run_check "$super" sub
expect_rc 1 "a pin 3 commits behind must exit 1"
expect_match "BEHIND" "the behind verdict must be named"
expect_match "3 commit" "the exact distance must be reported"
expect_no_match "CURRENT" "a behind pin must never print CURRENT"

# The remedy has to be actionable, or the check is a nag: it must name the tip to branch from.
tip=$(git_q -C "$super/sub" rev-parse FETCH_HEAD)
expect_match "$tip" "the branch-from revision must be printed"
# ...and it must NOT tell the reader to change how pinned definitions are read.
expect_match "UNCHANGED" "the plugin-definition carve-out must be restated"

# ----------------------------------------------------------------- CURRENT --
# The complementary half. A guard that fires on a current pin would be turned off within a week.
super=$(mkfixture current 4 4)
run_check "$super" sub
expect_rc 0 "a pin at the tip must exit 0"
expect_match "CURRENT" "the current verdict must be named"
expect_no_match "BEHIND" "a current pin must never print BEHIND"

# A one-commit lag is still a lag — the boundary, where an off-by-one would hide a real drift.
super=$(mkfixture boundary 4 3)
run_check "$super" sub
expect_rc 1 "a pin 1 commit behind must exit 1"
expect_match "1 commit" "the single-commit distance must be reported"

# ------------------------------------------------- ORDER-OF-RANGE REGRESSION --
# `rev-list --count <tip>..<pin>` is 0 for a pin that is behind, so the reversed range yields a
# confident false CURRENT. This asserts the script does not merely exit non-zero, but reports the
# distance the CORRECT order produces — a reversed implementation would print 0 and exit 0 above.
super=$(mkfixture order 6 1)
run_check "$super" sub
expect_rc 1 "a pin 5 commits behind must exit 1"
expect_match "5 commit" "the distance must come from <pin>..<tip>, not the reverse"

# -------------------------------------------------------- UNPOPULATED SUBMODULE --
# The parent-resolution trap: `git -C <uninitialised path>` resolves UPWARD to the superproject, so
# a naive check compares the superproject against itself and reports CURRENT. Nothing has been
# verified in that case, so the only safe verdict is UNKNOWN.
super=$(mkfixture empty 4 2)
rm -rf "${super:?}/sub"
mkdir -p "$super/sub"
run_check "$super" sub
expect_rc 2 "an unpopulated submodule must exit 2"
expect_match "UNKNOWN" "the unknown verdict must be named"
# `expect_rc 2` alone cannot pin THIS check: with the isolation test removed the run still
# exits 2, because the later fetch fails inside the superproject it wrongly resolved to. The
# reason is therefore the assertion — it is what distinguishes the guard from its shadow.
expect_match "isolated working tree" "the parent-resolution trap must be named specifically"
expect_no_match "CURRENT" "an unpopulated submodule must never read as CURRENT"

# ------------------------------------------------------------------ UNKNOWN --
# A path that is not a tracked submodule at all. Same reasoning: no verdict is possible.
super=$(mkfixture untracked 3 2)
mkdir -p "$super/not-a-sub"
run_check "$super" not-a-sub
expect_rc 2 "a non-submodule path must exit 2"
# Same over-determination as the unpopulated case: with this check removed the isolation test
# downstream also yields 2, so only the reason distinguishes them.
expect_match "not a submodule path" "the tracked-submodule check must be named specifically"
expect_no_match "CURRENT" "a non-submodule path must never read as CURRENT"

# Usage errors are UNKNOWN too, never a pass.
run_check "$super"
expect_rc 2 "no argument must exit 2"
run_check "$super" sub --branch
expect_rc 2 "a --branch with no value must exit 2"

# A trailing slash names the same submodule — a path copied from shell completion must not be
# reported as untracked.
super=$(mkfixture slash 4 4)
run_check "$super" sub/
expect_rc 0 "a trailing slash must resolve to the same submodule"

# An explicit --branch that does not exist cannot be fetched: UNKNOWN, never CURRENT.
run_check "$super" sub --branch no-such-branch
expect_rc 2 "an unfetchable branch must exit 2"
expect_no_match "CURRENT" "an unfetchable branch must never read as CURRENT"

# -------------------------------------------------------------------- AHEAD --
# The third way to manufacture a false CURRENT, and the one a commit COUNT cannot see.
# `<pin>..<tip>` counts commits reachable from the tip but not the pin, so it is zero when the pin
# is the tip AND when the pin is AHEAD of it. Testing `behind -eq 0` alone therefore prints
# "CURRENT — the pin is the tip", which is simply false for an ahead pin: the gitlink carries work
# that is not on the default branch. Only SHA equality establishes CURRENT.
# mkfixture_ahead <name> <n_commits> <pushed_index> — origin/main stops at <pushed_index>, the
# superproject pins the final commit, so the pin leads the branch.
mkfixture_ahead() {
  local name=$1 n=$2 pushed=$3
  local root="$TMP/$name"
  mkdir -p "$root"

  git_q init -q "$root/product"
  local i
  for i in $(seq 1 "$n"); do
    echo "commit $i" >"$root/product/file.txt"
    git_q -C "$root/product" add file.txt
    git_q -C "$root/product" commit -q -m "c$i"
  done

  git_q init -q --bare "$root/origin.git"
  git_q -C "$root/product" remote add origin "$root/origin.git"

  # Publish only the first <pushed> commits as the branch; the rest stay local and become the pin.
  local pushed_sha pin
  pushed_sha=$(git_q -C "$root/product" rev-list --reverse main | sed -n "${pushed}p")
  git_q -C "$root/product" push -q origin "${pushed_sha}:refs/heads/main"
  pin=$(git_q -C "$root/product" rev-parse main)

  git_q init -q "$root/super"
  git_q -c protocol.file.allow=always -C "$root/super" submodule -q add "$root/origin.git" sub
  git_q -C "$root/super" -c protocol.file.allow=always submodule -q update --init sub
  # Fetch the unpublished commits into the submodule clone so the gitlink can name one.
  git_q -C "$root/super/sub" fetch -q "$root/product" main
  git_q -C "$root/super/sub" checkout -q "$pin"
  git_q -C "$root/super" add .gitmodules sub
  git_q -C "$root/super" commit -q -m "pin sub ahead at $pin"

  printf '%s\n' "$root/super"
}

super=$(mkfixture_ahead ahead 5 2)
run_check "$super" sub
expect_no_match "CURRENT" "a pin AHEAD of the branch tip must never read as CURRENT"
expect_rc 2 "an ahead pin has no CURRENT/BEHIND verdict and must exit 2"
expect_match "AHEAD" "the ahead state must be named explicitly, not folded into UNKNOWN"
expect_match "3 commit" "the ahead distance must be reported from <tip>..<pin>"
expect_no_match "BEHIND" "an ahead pin must never read as BEHIND"

# ------------------------------------------------------ PATH QUOTING (BEHIND) --
# The BEHIND verdict emits a copy-paste `git -C <path> checkout -b ...`. The path comes from
# .gitmodules, so a bare %s emits a command that does something other than it appears to when the
# path carries a space or a shell metacharacter. Assert the emitted path is quoted.
mkfixture_spacepath() {
  local root="$TMP/spacepath"
  mkdir -p "$root"

  git_q init -q "$root/product"
  local i
  for i in $(seq 1 4); do
    echo "commit $i" >"$root/product/file.txt"
    git_q -C "$root/product" add file.txt
    git_q -C "$root/product" commit -q -m "c$i"
  done

  git_q init -q --bare "$root/origin.git"
  git_q -C "$root/product" remote add origin "$root/origin.git"
  git_q -C "$root/product" push -q origin main

  local pin
  pin=$(git_q -C "$root/product" rev-list --reverse main | sed -n '2p')

  git_q init -q "$root/super"
  git_q -c protocol.file.allow=always -C "$root/super" submodule -q add "$root/origin.git" 'my sub'
  git_q -C "$root/super" -c protocol.file.allow=always submodule -q update --init 'my sub'
  git_q -C "$root/super/my sub" checkout -q "$pin"
  git_q -C "$root/super" add .gitmodules 'my sub'
  git_q -C "$root/super" commit -q -m "pin spaced sub at $pin"

  printf '%s\n' "$root/super"
}

super=$(mkfixture_spacepath)
run_check "$super" 'my sub'
expect_rc 1 "a spaced submodule path must still produce the BEHIND verdict"
expect_match "git -C 'my sub'" "the emitted command must shell-quote the submodule path"

# ------------------------------------------------------------------ report --
if [ "$fails" -ne 0 ]; then
  echo "submodule-pin-currency.test.sh: $fails failure(s) across $asserts assertion(s)" >&2
  exit 1
fi
echo "submodule-pin-currency.test.sh: all $asserts assertion(s) passed"
