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
test_run_completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$TMP"
  if [ "${test_run_completed}" != 1 ]; then
    echo "worktree-submodule-inventory.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT

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

s=$(make_wt m-ignored)
echo 'build/' > "$s/.gitignore"; g -C "$s" add .gitignore; g -C "$s" commit -qm ignore; g -C "$s" push -q origin main
mkdir "$s/build"; echo out > "$s/build/out.o"

# An ignored directory holding a whole repository two levels down. (m-ignored pushed the ignore rule, so this clone has it.)
s=$(make_wt n-ignored-repository)
mkdir -p "$s/build/deep"; g init -q -b main "$s/build/deep/inner"

# A staged rename is ONE change: -z prints its source as a second field.
s=$(make_wt o-renamed)
g -C "$s" mv f renamed

# A submodule whose NAME holds a space (the key is then `submodule.my mod.path`).
s=$(make_wt p-spaced-name)
printf '[submodule "my mod"]\n\tpath = sub\n\turl = https://example.invalid/s.git\n' > "$ROOT/p-spaced-name/.gitmodules"
echo edit > "$s/f"

# .gitmodules deleted from the working tree: the index still records the gitlink.
s=$(make_wt q-gitlink-only)
g -C "$ROOT/q-gitlink-only" update-index --add --cacheinfo "160000,$(g -C "$s" rev-parse HEAD),sub"
rm "$ROOT/q-gitlink-only/.gitmodules"; echo edit > "$s/f"

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
expect_class m-ignored ignored
expect_class n-ignored-repository nested
expect_class o-renamed modified
expect_class p-spaced-name modified
expect_class q-gitlink-only modified
case "$(row m-ignored)" in *$'\tignored=1') ok "ignored content is counted, not reported clean" ;; *) bad "ignored content is counted" "$(row m-ignored)" ;; esac
case "$(row o-renamed)" in *$'\tmodified=1\t'*) ok "a rename counts once" ;; *) bad "a rename counts once" "$(row o-renamed)" ;; esac

case "$(row b-unpushed)" in *$'\tunpushed=1\t'*) ok "an unpushed commit is counted" ;; *) bad "an unpushed commit is counted" "$(row b-unpushed)" ;; esac
case "$(row d-untracked)" in *$'\tuntracked=2\t'*) ok "untracked files are counted" ;; *) bad "untracked files are counted" "$(row d-untracked)" ;; esac
case "$(row e-nested)" in *$'\tnested=1\tignored=0') ok "a nested repository is counted apart from untracked files" ;; *) bad "a nested repository is counted apart from untracked files" "$(row e-nested)" ;; esac
case "$(row g-precedence)" in *$'\tunpushed=1\t'*$'\tmodified=1\t'*$'untracked=1\t'*) ok "the lower-precedence counts stay visible" ;; *) bad "the lower-precedence counts stay visible" "$(row g-precedence)" ;; esac
[ "$(row h-spaced | awk -F'\t' '{ print $3 }')" = 'sub dir' ] \
  && ok "a submodule path holding a space is kept whole" || bad "a submodule path holding a space is kept whole" "$(row h-spaced)"
[ -z "$(row i-unpopulated)" ] && ok "an unpopulated submodule has no row" || bad "an unpopulated submodule has no row" "$(row i-unpopulated)"
grep -q $'^SKIP\tj-plain-directory\t' <<<"$out" \
  && ok "a directory that is not a worktree is reported, not classified" || bad "a non-worktree directory is reported" "$out"
grep -q $'^CHECKED\tworktrees=14\tentries=13\tmodified=5\tnested=2\tuntracked=2\tunpushed=1\tlocal_only=1\tignored=1\tclean=1\tbelow_min_idle=0\tskipped=1\tunreadable=0$' <<<"$out" \
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
grep -q $'\tentries=1\t.*\tbelow_min_idle=12\t' <<<"$out" \
  && ok "entries below the idle floor are counted, not dropped silently" || bad "below-floor entries are counted" "$(printf '%s\n' "$out" | tail -n 1)"

# NEGATIVE CONTROL 1: a submodule whose .git points nowhere is UNREADABLE and the run is
# incomplete (exit 2). It must not appear as an ENTRY.
BROKEN="$TMP/broken"; mkdir -p "$BROKEN"
ROOT_SAVE=$ROOT; ROOT=$BROKEN
s=$(make_wt k-dangling)
rm -rf "$s/.git"; printf 'gitdir: /nonexistent/gone\n' > "$s/.git"
out=$(bash "$SUT" "$BROKEN" 2>&1); rc=$?
{ [ "$rc" -eq 2 ] && grep -q $'^UNREADABLE\tk-dangling\tsub\t' <<<"$out" && [ -z "$(row k-dangling)" ]; } \
  && ok "a dangling submodule git directory is UNREADABLE and exits 2" || bad "a dangling submodule is UNREADABLE" "rc=$rc: $out"

# NEGATIVE CONTROL 2: an EMPTY .git directory makes `git -C` answer for the parent
# repository. The parent here is clean, so a naive read would print `clean`.
BROKEN2="$TMP/broken2"; mkdir -p "$BROKEN2"; ROOT=$BROKEN2
s=$(make_wt l-parent-answers)
rm -rf "$s/.git"; mkdir "$s/.git"
out=$(bash "$SUT" "$BROKEN2" 2>&1); rc=$?
{ [ "$rc" -eq 2 ] && grep -q $'^UNREADABLE\tl-parent-answers\tsub\tgit resolves it to another working tree$' <<<"$out" \
    && [ -z "$(row l-parent-answers)" ]; } \
  && ok "a submodule git answers for the parent is UNREADABLE, never clean" \
  || bad "a submodule git answers for the parent is UNREADABLE" "rc=$rc: $out"
grep -q $'\tclean=0\t.*\tunreadable=1$' <<<"$out" \
  && ok "the unreadable entry is not counted as clean" || bad "the unreadable entry is not counted as clean" "$(printf '%s\n' "$out" | tail -n 1)"
ROOT=$ROOT_SAVE

# NEGATIVE CONTROL 3: a worktree whose own .git is an empty directory, inside another
# repository. `git -C` answers for that outer repository.
OUTER="$TMP/outer"; g init -q -b main "$OUTER"; mkdir -p "$OUTER/wts/r-outer-answers/.git"
out=$(bash "$SUT" "$OUTER/wts" 2>&1); rc=$?
{ [ "$rc" -eq 2 ] && grep -q $'^UNREADABLE\tr-outer-answers\t-\tgit resolves it to another working tree$' <<<"$out"; } \
  && ok "a worktree git answers for an outer repository is UNREADABLE" || bad "a worktree answered by an outer repository is UNREADABLE" "rc=$rc: $out"

# NEGATIVE CONTROLS 4-7: each must be UNREADABLE with exit 2, never a missing row.
unreadable_case() { # name, expected reason, description
  out=$(bash "$SUT" "$ROOT" 2>&1); rc=$?
  { [ "$rc" -eq 2 ] && grep -q "^UNREADABLE"$'\t'"$1"$'\t'".*$2\$" <<<"$out" && [ -z "$(row "$1")" ]; } \
    && ok "$3" || bad "$3" "rc=$rc: $(grep -F "$1" <<<"$out")"
}
ROOT="$TMP/unborn"; mkdir -p "$ROOT"; s=$(make_wt s-unborn)
rm -rf "$s"; g init -q -b main "$s"
unreadable_case s-unborn 'HEAD is not a commit' "an unborn HEAD is UNREADABLE"
ROOT="$TMP/newline"; mkdir -p "$ROOT"; s=$(make_wt t-newline)
echo x > "$s/a"$'\n'"b"
unreadable_case t-newline 'a path holds a newline' "a path holding a newline is UNREADABLE"
ROOT="$TMP/escape"; mkdir -p "$ROOT"; s=$(make_wt u-escape); make_wt v-victim >/dev/null
printf '[submodule "s"]\n\tpath = ../v-victim/sub\n\turl = https://example.invalid/s.git\n' > "$ROOT/u-escape/.gitmodules"
unreadable_case u-escape 'the path does not stay inside the worktree' "a submodule path leaving the worktree is UNREADABLE"
if [ "$(id -u)" -ne 0 ]; then
  ROOT="$TMP/perm"; mkdir -p "$ROOT"; s=$(make_wt w-no-permission); echo edit > "$s/f"; chmod 000 "$s"
  unreadable_case w-no-permission 'no permission to read the directory' "a submodule that may not be read is UNREADABLE"
  chmod 700 "$s"; chmod 000 "$ROOT/w-no-permission"
  unreadable_case w-no-permission 'no permission to read the directory' "a worktree that may not be read is UNREADABLE, not skipped"
  chmod 700 "$ROOT/w-no-permission"
fi
ROOT=$ROOT_SAVE

# More spellings of "cannot be established", each of which once read as absent or clean.
gm() { printf '[submodule "s"]\n\tpath = %s\n\turl = https://example.invalid/s.git\n' "$2" > "$ROOT/$1/.gitmodules"; }
ROOT="$TMP/absolute"; mkdir -p "$ROOT"; s=$(make_wt x-absolute); gm x-absolute "$s"
unreadable_case x-absolute 'the path is absolute' "an absolute submodule path is UNREADABLE"
ROOT="$TMP/dot"; mkdir -p "$ROOT"; s=$(make_wt y-dot); gm y-dot .
unreadable_case y-dot 'the path does not stay inside the worktree' "a submodule path naming the worktree itself is UNREADABLE"
ROOT="$TMP/link"; mkdir -p "$ROOT"; s=$(make_wt z-link); make_wt z-victim >/dev/null
ln -s ../z-victim/sub "$ROOT/z-link/link"; gm z-link link
unreadable_case z-link 'a path component is a symbolic link' "a submodule path through a symbolic link is UNREADABLE"
if [ "$(id -u)" -ne 0 ]; then
  ROOT="$TMP/parent"; mkdir -p "$ROOT"; s=$(make_wt aa-parent 'libs/sub'); echo edit > "$s/f"; chmod 000 "$ROOT/aa-parent/libs"
  unreadable_case aa-parent 'no permission to read libs' "a submodule behind a directory that may not be searched is UNREADABLE"
  chmod 700 "$ROOT/aa-parent/libs"
  ROOT="$TMP/inner"; mkdir -p "$ROOT"; s=$(make_wt ab-inner); mkdir "$s/priv"; echo secret > "$s/priv/x"; chmod 000 "$s/priv"
  unreadable_case ab-inner 'git warned about the read, or a path holds a newline' "a submodule holding a directory git may not open is UNREADABLE, never clean"
  chmod 700 "$s/priv"
  ROOT="$TMP/modules"; mkdir -p "$ROOT"; s=$(make_wt ac-modules); echo edit > "$s/f"; chmod 000 "$ROOT/ac-modules/.gitmodules"
  out=$(bash "$SUT" "$ROOT" 2>&1); rc=$?
  { [ "$rc" -eq 2 ] && grep -q $'^UNREADABLE\tac-modules\t-\tcannot list its submodules$' <<<"$out"; } \
    && ok "a .gitmodules that may not be read is UNREADABLE, not empty" || bad "an unreadable .gitmodules is UNREADABLE" "rc=$rc: $out"
  chmod 600 "$ROOT/ac-modules/.gitmodules"
fi
# git status hides an edit to a file marked assume-unchanged or skip-worktree.
ROOT="$TMP/assume"; mkdir -p "$ROOT"; s=$(make_wt ae-assume)
g -C "$s" update-index --assume-unchanged f; echo authored > "$s/f"
unreadable_case ae-assume 'tracked files are hidden from git status' "an edit behind assume-unchanged is UNREADABLE, never clean"
ROOT="$TMP/skip"; mkdir -p "$ROOT"; s=$(make_wt af-skip)
g -C "$s" update-index --skip-worktree f; echo authored > "$s/f"
unreadable_case af-skip 'tracked files are hidden from git status' "an edit behind skip-worktree is UNREADABLE, never clean"
ROOT="$TMP/nogit"; mkdir -p "$ROOT"; s=$(make_wt ag-no-git); rm -rf "$s/.git"
unreadable_case ag-no-git 'holds files but no git directory' "a submodule with files but no git directory is UNREADABLE, not unpopulated"
ROOT="$TMP/tab"; mkdir -p "$ROOT"; s=$(make_wt ah-tab "a"$'\t'"b")
unreadable_case ah-tab 'the path holds a tab' "a submodule path holding a tab is UNREADABLE"
# A symbolic link to a worktree is skipped, so the worktree is counted once.
ROOT="$TMP/alias"; mkdir -p "$ROOT"; make_wt ai-real >/dev/null; ln -s ai-real "$ROOT/ai-alias"
out=$(bash "$SUT" "$ROOT" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && grep -q $'^SKIP\tai-alias\ta symbolic link$' <<<"$out" && grep -q $'\tworktrees=1\tentries=1\t' <<<"$out"; } \
  && ok "a link to a worktree is skipped, not listed twice" || bad "a link to a worktree is skipped" "rc=$rc: $out"
# An inherited trace setting must not turn every read into a warning.
out=$(GIT_TRACE=1 bash "$SUT" "$ROOT" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && grep -q $'\tunreadable=0$' <<<"$out"; } \
  && ok "an inherited GIT_TRACE does not fail the reads" || bad "an inherited GIT_TRACE does not fail the reads" "rc=$rc"
# One directory named twice (a gitlink `sub` and a .gitmodules `sub/`) is ONE entry.
ROOT="$TMP/twice"; mkdir -p "$ROOT"; s=$(make_wt ad-twice)
g -C "$ROOT/ad-twice" update-index --add --cacheinfo "160000,$(g -C "$s" rev-parse HEAD),sub"; gm ad-twice sub/
out=$(bash "$SUT" "$ROOT" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(grep -c $'^ENTRY\tad-twice\t' <<<"$out")" -eq 1 ]; } \
  && ok "a submodule named by both sources is listed once" || bad "a submodule named by both sources is listed once" "rc=$rc: $out"
ROOT=$ROOT_SAVE

# --tips names the commits an entry holds away from HEAD, by what holds each one.
ROOT="$TMP/tips"; mkdir -p "$ROOT"; s=$(make_wt t-held)
g -C "$s" checkout -q -b side; echo one > "$s/f"; g -C "$s" commit -qam one; echo two > "$s/f"; g -C "$s" commit -qam two
side=$(g -C "$s" rev-parse HEAD)
g -C "$s" checkout -q main
echo tagged > "$s/f"; g -C "$s" commit -qam tagged; g -C "$s" tag -a -m release v1; tagged=$(g -C "$s" rev-parse HEAD)
g -C "$s" reset -q --hard origin/main
echo lost > "$s/f"; g -C "$s" commit -qam lost; lost=$(g -C "$s" rev-parse HEAD)
g -C "$s" reset -q --hard origin/main
echo aside > "$s/f"; g -C "$s" stash -q; stashed=$(g -C "$s" rev-parse refs/stash)
s=$(make_wt u-clean)
out=$(bash "$SUT" "$ROOT" --tips 2>&1); rc=$?
tip() { grep $'^TIP\tt-held\tsub\ttip='"$1"$'\t' <<<"$out" | cut -f5-; }
[ "$rc" -eq 0 ] && ok "--tips exits 0" || bad "--tips exits 0" "rc=$rc: $out"
[ "$(tip "$side")" = $'kind=branch\tref=side\tcommits=2' ] \
  && ok "a local branch is named with the commits it alone reaches" || bad "a local branch tip" "$out"
[ "$(tip "$tagged")" = $'kind=ref\tref=refs/tags/v1\tcommits=1' ] \
  && ok "an annotated tag is named by the commit it points at" || bad "an annotated tag tip" "$out"
[ "$(tip "$lost")" = $'kind=reflog\tref=-\tcommits=1' ] \
  && ok "a commit only old history keeps is a reflog tip" || bad "a reflog tip" "$out"
case "$(tip "$stashed")" in $'kind=stash\tref=-\tcommits='[1-9]) ok "a stash is named as a stash" ;; *) bad "a stash tip" "$out" ;; esac
[ "$(grep -c '^TIP' <<<"$out")" -eq 4 ] \
  && ok "only tips are listed: no commit below one, none for a clean entry" || bad "only tips are listed" "$out"
[ "$(grep -n $'^ENTRY\tt-held\t' <<<"$out" | cut -d: -f1)" -lt "$(grep -n '^TIP' <<<"$out" | head -n 1 | cut -d: -f1)" ] \
  && ok "an entry's TIP rows follow its ENTRY row" || bad "an entry's TIP rows follow its ENTRY row" "$out"
grep -q $'\tunreadable=0\ttips=4$' <<<"$out" && ok "the closing line counts the tips" || bad "the closing line counts the tips" "$out"
out=$(bash "$SUT" "$ROOT" 2>&1)
{ ! grep -q '^TIP' <<<"$out" && grep -q $'\tunreadable=0$' <<<"$out"; } \
  && ok "without --tips the output is unchanged" || bad "without --tips the output is unchanged" "$out"
ROOT=$ROOT_SAVE

# A root with no worktree at all is the wrong directory, not an empty inventory.
mkdir -p "$TMP/empty/plain"
bash "$SUT" "$TMP/empty" >/dev/null 2>&1; [ $? -eq 2 ] && ok "a root holding no worktree exits 2" || bad "a root holding no worktree exits 2"

# Usage errors are UNKNOWN (2), never an empty clean inventory.
bash "$SUT" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no root exits 2" || bad "no root exits 2"
bash "$SUT" "$TMP/absent" >/dev/null 2>&1; [ $? -eq 2 ] && ok "a missing root exits 2" || bad "a missing root exits 2"
bash "$SUT" "$ROOT" --min-idle-days x >/dev/null 2>&1; [ $? -eq 2 ] && ok "a non-numeric idle floor exits 2" || bad "a non-numeric idle floor exits 2"
bash "$SUT" "$ROOT" --frobnicate >/dev/null 2>&1; [ $? -eq 2 ] && ok "an unknown option exits 2" || bad "an unknown option exits 2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
test_run_completed=1
[ "$fail" -eq 0 ]
