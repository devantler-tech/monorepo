#!/usr/bin/env bash
# Tests for worktree-submodule-inventory.sh — the read-only, per-submodule inventory of what
# a session worktree still holds (monorepo#3072).
#
# Each case builds a worktree root with real repositories, so the classes are decided by
# git itself and not by a stub. The negative controls matter most: a broken submodule must
# never be reported with its PARENT's state, and a failed read must never count as clean.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/worktree-submodule-inventory.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

g() { git -c user.email=t@t.t -c user.name=t -c commit.gpgsign=false "$@"; }

# A bare "remote" every submodule clones, holding one commit on main.
g init -q -b main "$TMP/seed"
echo base > "$TMP/seed/f"; g -C "$TMP/seed" add f; g -C "$TMP/seed" commit -qm base
g clone -q --bare "$TMP/seed" "$TMP/remote.git"

ROOT="$TMP/worktrees"; mkdir -p "$ROOT"

# make_wt <name> [submodule-path] -> a worktree-shaped repository under ROOT with one
# populated submodule cloned from the remote. Prints the submodule directory.
make_wt() {
  local sub=${2:-sub} wt="$ROOT/$1"
  g init -q -b main "$wt"
  printf '[submodule "s"]\n\tpath = %s\n\turl = https://example.invalid/s.git\n' "$sub" > "$wt/.gitmodules"
  g -C "$wt" add .gitmodules; g -C "$wt" commit -qm base
  g clone -q "$TMP/remote.git" "$wt/$sub"
  printf '%s\n' "$wt/$sub"
}

s=$(make_wt a-clean)

s=$(make_wt b-unpushed)
echo more > "$s/f"; g -C "$s" commit -qam more

s=$(make_wt c-modified)
echo edit > "$s/f"

s=$(make_wt d-untracked)
echo new > "$s/new.txt"; echo two > "$s/two.txt"

s=$(make_wt e-nested)
g init -q -b main "$s/inner"

s=$(make_wt f-local-only)
g -C "$s" checkout -q -b side; echo side > "$s/f"; g -C "$s" commit -qam side
g -C "$s" checkout -q main

s=$(make_wt g-precedence)
echo more > "$s/f"; g -C "$s" commit -qam more; echo edit > "$s/f"; echo new > "$s/new.txt"

s=$(make_wt h-spaced 'sub dir')
echo new > "$s/new.txt"

# An unpopulated submodule: listed in .gitmodules, directory present but empty.
g init -q -b main "$ROOT/i-unpopulated"
printf '[submodule "s"]\n\tpath = sub\n\turl = https://example.invalid/s.git\n' > "$ROOT/i-unpopulated/.gitmodules"
mkdir "$ROOT/i-unpopulated/sub"

mkdir "$ROOT/j-plain-directory"

out=$(bash "$SUT" "$ROOT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "a readable root exits 0" || bad "a readable root exits 0" "rc=$rc: $out"

row() { printf '%s\n' "$out" | awk -F'\t' -v w="$1" '$1 == "ENTRY" && $2 == w'; }
class_of() { row "$1" | awk -F'\t' '{ print $4 }'; }
expect_class() {
  local got; got=$(class_of "$1")
  [ "$got" = "$2" ] && ok "$1 is classified $2" || bad "$1 is classified $2" "got '$got'"
}
expect_class a-clean clean
expect_class b-unpushed unpushed
expect_class c-modified modified
expect_class d-untracked untracked
expect_class e-nested nested
expect_class f-local-only local-only
expect_class g-precedence modified
expect_class h-spaced untracked

case "$(row b-unpushed)" in *$'\tunpushed=1\t'*) ok "an unpushed commit is counted" ;; *) bad "an unpushed commit is counted" "$(row b-unpushed)" ;; esac
case "$(row d-untracked)" in *$'\tuntracked=2\t'*) ok "untracked files are counted" ;; *) bad "untracked files are counted" "$(row d-untracked)" ;; esac
case "$(row e-nested)" in *$'\tnested=1') ok "a nested repository is counted apart from untracked files" ;; *) bad "a nested repository is counted apart from untracked files" "$(row e-nested)" ;; esac
case "$(row g-precedence)" in *$'\tunpushed=1\t'*$'\tmodified=1\t'*$'untracked=1\t'*) ok "the lower-precedence counts stay visible" ;; *) bad "the lower-precedence counts stay visible" "$(row g-precedence)" ;; esac
[ "$(row h-spaced | awk -F'\t' '{ print $3 }')" = 'sub dir' ] \
  && ok "a submodule path holding a space is kept whole" || bad "a submodule path holding a space is kept whole" "$(row h-spaced)"
[ -z "$(row i-unpopulated)" ] && ok "an unpopulated submodule has no row" || bad "an unpopulated submodule has no row" "$(row i-unpopulated)"
printf '%s\n' "$out" | grep -q $'^SKIP\tj-plain-directory\t' \
  && ok "a directory that is not a worktree is reported, not classified" || bad "a non-worktree directory is reported" "$out"
printf '%s\n' "$out" | grep -q $'^CHECKED\tworktrees=9\tentries=8\tmodified=2\tnested=1\tuntracked=2\tunpushed=1\tlocal_only=1\tclean=1\tbelow_min_idle=0\tskipped=1\tunreadable=0$' \
  && ok "the closing line totals every class" || bad "the closing line totals every class" "$(printf '%s\n' "$out" | tail -n 1)"

# Read-only: the run must not rewrite another session's index (GIT_OPTIONAL_LOCKS=0).
idx="$ROOT/c-modified/sub/.git/index"
touch -t 202001010000 "$idx" "$ROOT/c-modified/sub/.git/HEAD"
before=$(stat -c %Y "$idx" 2>/dev/null || stat -f %m "$idx")
bash "$SUT" "$ROOT" >/dev/null 2>&1
after=$(stat -c %Y "$idx" 2>/dev/null || stat -f %m "$idx")
[ "$before" = "$after" ] && ok "a run leaves the submodule index untouched" || bad "a run leaves the submodule index untouched" "$before -> $after"

# --min-idle-days lists only entries idle that long, and counts the rest.
out=$(bash "$SUT" "$ROOT" --min-idle-days 30 2>&1); rc=$?
n=$(printf '%s\n' "$out" | grep -c $'^ENTRY\t')
{ [ "$rc" -eq 0 ] && [ "$n" -eq 1 ] && [ "$(class_of c-modified)" = modified ]; } \
  && ok "--min-idle-days keeps only the old entry" || bad "--min-idle-days keeps only the old entry" "rc=$rc rows=$n"
printf '%s\n' "$out" | grep -q $'\tentries=1\t.*\tbelow_min_idle=7\t' \
  && ok "entries below the idle floor are counted, not dropped silently" || bad "below-floor entries are counted" "$(printf '%s\n' "$out" | tail -n 1)"

# NEGATIVE CONTROL 1: a submodule whose .git points nowhere is UNREADABLE and the run is
# incomplete (exit 2). It must not appear as an ENTRY.
BROKEN="$TMP/broken"; mkdir -p "$BROKEN"
ROOT_SAVE=$ROOT; ROOT=$BROKEN
s=$(make_wt k-dangling)
rm -rf "$s/.git"; printf 'gitdir: /nonexistent/gone\n' > "$s/.git"
out=$(bash "$SUT" "$BROKEN" 2>&1); rc=$?
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q $'^UNREADABLE\tk-dangling\tsub\t' && [ -z "$(row k-dangling)" ]; } \
  && ok "a dangling submodule git directory is UNREADABLE and exits 2" || bad "a dangling submodule is UNREADABLE" "rc=$rc: $out"

# NEGATIVE CONTROL 2: an EMPTY .git directory makes `git -C` answer for the parent
# repository. The parent here is clean, so a naive read would print `clean`.
BROKEN2="$TMP/broken2"; mkdir -p "$BROKEN2"; ROOT=$BROKEN2
s=$(make_wt l-parent-answers)
rm -rf "$s/.git"; mkdir "$s/.git"
out=$(bash "$SUT" "$BROKEN2" 2>&1); rc=$?
{ [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q $'^UNREADABLE\tl-parent-answers\tsub\tgit resolves it to another working tree$' \
    && [ -z "$(row l-parent-answers)" ]; } \
  && ok "a submodule git answers for the parent is UNREADABLE, never clean" \
  || bad "a submodule git answers for the parent is UNREADABLE" "rc=$rc: $out"
printf '%s\n' "$out" | grep -q $'\tclean=0\t.*\tunreadable=1$' \
  && ok "the unreadable entry is not counted as clean" || bad "the unreadable entry is not counted as clean" "$(printf '%s\n' "$out" | tail -n 1)"
ROOT=$ROOT_SAVE

# Usage errors are UNKNOWN (2), never an empty clean inventory.
bash "$SUT" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no root exits 2" || bad "no root exits 2"
bash "$SUT" "$TMP/absent" >/dev/null 2>&1; [ $? -eq 2 ] && ok "a missing root exits 2" || bad "a missing root exits 2"
bash "$SUT" "$ROOT" --min-idle-days x >/dev/null 2>&1; [ $? -eq 2 ] && ok "a non-numeric idle floor exits 2" || bad "a non-numeric idle floor exits 2"
bash "$SUT" "$ROOT" --frobnicate >/dev/null 2>&1; [ $? -eq 2 ] && ok "an unknown option exits 2" || bad "an unknown option exits 2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
