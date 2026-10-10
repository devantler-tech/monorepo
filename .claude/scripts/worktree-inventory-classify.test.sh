#!/usr/bin/env bash
# Tests for worktree-inventory-classify.sh — the one class per entry and per worktree read
# off the inventory and the merged check (monorepo#3072).
#
# The script reads two texts and nothing else, so every case is two small hand-written
# texts. The negative controls matter most: a row that is missing, repeated, unknown or
# about another commit must stop the run with no CLASS row, never fall through to
# `merged-in-content`, and each control asserts the message that names its own cause.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/worktree-inventory-classify.sh"

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
    echo "worktree-inventory-classify.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT

H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
T1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
T2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
T3=cccccccccccccccccccccccccccccccccccccccc

# Row builders. Every row is tab-separated, exactly as the two scripts print it.
entry() { # <worktree> <submodule> <class> <head> <unpushed> <local_only>
  printf 'ENTRY\t%s\t%s\t%s\tidle_days=3\thead=%s\tunpushed=%s\tlocal_only=%s\tmodified=0\tuntracked=0\tnested=0\tignored=0\n' "$@"
}
tip() { # <worktree> <submodule> <sha> <kind>
  printf 'TIP\t%s\t%s\ttip=%s\tkind=%s\tref=-\tcommits=1\n' "$@"
}
inv_end() { printf 'CHECKED\tworktrees=1\tentries=%s\tbelow_min_idle=0\ttips=0\n' "$1"; }
mc() { # <worktree> <submodule> <verdict> <head>
  printf 'MERGE-CHECK\t%s\t%s\t%s\thead=%s\trepo=o/r\tpr=-\tother_local=0\n' "$@"
}
tc() { # <worktree> <submodule> <verdict> <sha> <kind>
  printf 'TIP-CHECK\t%s\t%s\t%s\ttip=%s\tkind=%s\tref=-\trepo=o/r\tpr=-\tcommits=1\n' "$@"
}
cc() { # <worktree> <submodule> <verdict> <sha>
  printf 'CONTENT-CHECK\t%s\t%s\t%s\tcommit=%s\tbase=%s\tsame_as=-\n' "$@" "$H2"
}
chk_end() { printf 'CHECKED\tmerged=0\n'; }

INV="$TMP/inv"; CHK="$TMP/chk"; OUT="$TMP/out"; ERR="$TMP/err"
run() { "$SUT" --inventory "$INV" < "$CHK" > "$OUT" 2> "$ERR"; }

# expect_class <label> <worktree> <submodule> <class> — the run succeeds and gives that class.
expect_class() {
  local rc=0 got
  run || rc=$?
  got=$(awk -F'\t' -v w="$2" -v s="$3" '$1 == "CLASS" && $2 == w && $3 == s { print $4 }' "$OUT")
  if [ "$rc" = 0 ] && [ "$got" = "$4" ]; then ok "$1"; else bad "$1" "rc=$rc class=${got:-none} $(head -n 1 "$ERR")"; fi
}
# expect_refused <label> <message fragment> — exit 2, no CLASS row, and the named cause.
expect_refused() {
  local rc=0
  run || rc=$?
  if [ "$rc" = 2 ] && ! grep -q '^CLASS' "$OUT" && grep -qF -- "$2" "$ERR"; then ok "$1"
  else bad "$1" "rc=$rc rows=$(grep -c '^CLASS' "$OUT") err=$(head -n 1 "$ERR")"; fi
}
# one <inventory class> <unpushed> <local_only> — an inventory holding one entry `w s`.
one() { { entry w s "$1" "$H1" "$2" "$3"; cat; inv_end 1; } > "$INV"; }

echo "classes"
one clean 0 0 < /dev/null; chk_end > "$CHK"
expect_class "a clean entry holds nothing" w s nothing-held
one ignored 0 0 < /dev/null; chk_end > "$CHK"
expect_class "ignored files only is tool output" w s tool-output
for c in modified untracked nested; do
  one "$c" 2 2 < /dev/null; chk_end > "$CHK"
  expect_class "a $c entry needs a person, whatever its commits" w s needs-a-person
done

one unpushed 1 1 < /dev/null
{ mc w s merged "$H1"; chk_end; } > "$CHK"
expect_class "an unpushed HEAD whose pull request merged is merged in content" w s merged-in-content
{ mc w s merged-ancestor "$H1"; chk_end; } > "$CHK"
expect_class "an unpushed HEAD in the history of a merged pull request is merged in content" w s merged-in-content
for v in merged-other-base closed other-head no-pr not-on-github not-checked; do
  { mc w s "$v" "$H1"; chk_end; } > "$CHK"
  expect_class "an unpushed HEAD read as $v needs a person" w s needs-a-person
done
{ mc w s open "$H1"; chk_end; } > "$CHK"
expect_class "an unpushed HEAD with an open pull request is work in flight" w s work-in-flight
for v in reached no-change same-change clean-merge; do
  { mc w s no-pr "$H1"; cc w s "$v" "$H1"; chk_end; } > "$CHK"
  expect_class "content $v settles a HEAD the lookup left open" w s merged-in-content
done
for v in differs no-reference; do
  { mc w s no-pr "$H1"; cc w s "$v" "$H1"; chk_end; } > "$CHK"
  expect_class "content $v settles nothing" w s needs-a-person
done

one local-only 0 2 <<EOF
$(tip w s "$T1" branch)
$(tip w s "$T2" ref)
EOF
{ mc w s not-checked "$H1"; tc w s merged "$T1" branch; tc w s pushed-ref "$T2" ref; chk_end; } > "$CHK"
expect_class "every tip settled is merged in content" w s merged-in-content
{ mc w s not-checked "$H1"; tc w s merged-ancestor "$T1" branch; tc w s pushed-ref "$T2" ref; chk_end; } > "$CHK"
expect_class "a tip in the history of a merged pull request is settled" w s merged-in-content
{ mc w s not-checked "$H1"; tc w s merged "$T1" branch; tc w s no-pr "$T2" ref; chk_end; } > "$CHK"
expect_class "one unsettled tip among settled ones needs a person" w s needs-a-person
if grep -q "$(printf 'settled=1\tunsettled=1\tin_flight=0')" "$OUT"; then ok "the counts name one settled and one unsettled commit"
else bad "the counts name one settled and one unsettled commit" "$(cat "$OUT")"; fi
{ mc w s not-checked "$H1"; tc w s open "$T1" branch; tc w s no-pr "$T2" ref; chk_end; } > "$CHK"
expect_class "an open tip beside an unsettled one is work in flight" w s work-in-flight
{ mc w s not-checked "$H1"; tc w s github-bot "$T1" branch; tc w s merged "$T2" ref; chk_end; } > "$CHK"
expect_class "a commit a bot made on GitHub is its own class, never merged in content" w s made-on-github
if grep -q "$(printf 'settled=1\tunsettled=0\tin_flight=0\tgithub_bot=1$')" "$OUT"; then ok "the counts keep the bot commit apart from the settled one"
else bad "the counts keep the bot commit apart from the settled one" "$(cat "$OUT")"; fi
if grep -q "$(printf '\tmerged_in_content=0\tmade_on_github=1\t.*\twt_merged_in_content=0\twt_made_on_github=1\t')" "$OUT"; then ok "the closing line counts the class apart"
else bad "the closing line counts the class apart" "$(tail -n 1 "$OUT")"; fi
{ mc w s not-checked "$H1"; tc w s github-bot "$T1" branch; tc w s no-pr "$T2" ref; chk_end; } > "$CHK"
expect_class "a bot commit beside an unsettled one needs a person" w s needs-a-person
{ mc w s not-checked "$H1"; tc w s github-bot "$T1" branch; tc w s open "$T2" ref; chk_end; } > "$CHK"
expect_class "a bot commit beside an open pull request is work in flight" w s work-in-flight

one local-only 0 1 <<EOF
$(tip w s "$T1" stash)
EOF
{ mc w s not-checked "$H1"; tc w s stash "$T1" stash; cc w s same-change "$T1"; chk_end; } > "$CHK"
expect_class "a stash is never settled, even by a content row" w s needs-a-person
{ mc w s not-checked "$H1"; tc w s merged "$T1" stash; chk_end; } > "$CHK"
expect_class "a stash is never settled, even by a merged verdict" w s needs-a-person
{ mc w s not-checked "$H1"; tc w s github-bot "$T1" stash; chk_end; } > "$CHK"
expect_class "a stash is never settled, even by a bot verdict" w s needs-a-person

one unpushed 1 2 <<EOF
$(tip w s "$T1" reflog)
EOF
{ mc w s merged "$H1"; tc w s no-pr "$T1" reflog; chk_end; } > "$CHK"
expect_class "a merged HEAD does not cover an unsettled tip" w s needs-a-person

echo "untracked files and ignored files"
# entry_f <worktree> <submodule> <class> <head> <unpushed> <local_only> <untracked> <ignored>
entry_f() {
  printf 'ENTRY\t%s\t%s\t%s\tidle_days=3\thead=%s\tunpushed=%s\tlocal_only=%s\tmodified=0\tuntracked=%s\tnested=0\tignored=%s\n' "$@"
}
fcr() { # <worktree> <submodule> <verdict> <files> <same>
  printf 'FILE-CHECK\t%s\t%s\t%s\tfiles=%s\tsame=%s\tbase=%s\n' "$@" "$H2"
}
# one_f <unpushed> <local_only> <untracked> <ignored> — one `untracked` entry `w s`.
one_f() { { entry_f w s untracked "$H1" "$@"; cat; inv_end 1; } > "$INV"; }

one_f 0 0 2 0 < /dev/null
{ fcr w s same-as-default 2 2; chk_end; } > "$CHK"
expect_class "untracked files that are all copies of the default branch's need no rescue" w s merged-in-content
for v in differs no-reference; do
  { fcr w s "$v" 2 0; chk_end; } > "$CHK"
  expect_class "untracked files read as $v need a person" w s needs-a-person
done
{ fcr w s differs 2 1; chk_end; } > "$CHK"
expect_class "one file that is not a copy keeps the entry with a person" w s needs-a-person
chk_end > "$CHK"
expect_class "untracked files nobody compared need a person" w s needs-a-person
one_f 0 0 2 3 < /dev/null
{ fcr w s same-as-default 2 2; chk_end; } > "$CHK"
expect_class "copies beside ignored files are tool output, never nothing" w s tool-output
{ fcr w s differs 2 0; chk_end; } > "$CHK"
expect_class "ignored files never lower an entry that needs a person" w s needs-a-person

one_f 1 1 1 0 < /dev/null
{ fcr w s same-as-default 1 1; mc w s merged "$H1"; chk_end; } > "$CHK"
expect_class "copies and a merged HEAD are merged in content" w s merged-in-content
{ fcr w s same-as-default 1 1; mc w s no-pr "$H1"; chk_end; } > "$CHK"
expect_class "copies do not settle a HEAD no evidence settles" w s needs-a-person
{ fcr w s same-as-default 1 1; mc w s open "$H1"; chk_end; } > "$CHK"
expect_class "copies beside an open pull request are work in flight" w s work-in-flight
{ fcr w s same-as-default 1 1; mc w s github-bot "$H1"; chk_end; } > "$CHK"
expect_class "copies beside a bot's commit are made on GitHub" w s made-on-github
{ fcr w s same-as-default 1 1; chk_end; } > "$CHK"
expect_refused "copies with an unexamined HEAD" "has no row for w s"
{ fcr w s differs 1 0; chk_end; } > "$CHK"
expect_class "files that differ need no commit verdict to need a person" w s needs-a-person

one_f 0 1 1 0 <<EOF2
$(tip w s "$T1" branch)
EOF2
{ fcr w s same-as-default 1 1; mc w s not-checked "$H1"; tc w s merged "$T1" branch; chk_end; } > "$CHK"
expect_class "copies and a merged tip are merged in content" w s merged-in-content
{ fcr w s same-as-default 1 1; mc w s not-checked "$H1"; tc w s no-pr "$T1" branch; chk_end; } > "$CHK"
expect_class "copies do not settle a tip no evidence settles" w s needs-a-person
{ fcr w s same-as-default 1 1; mc w s not-checked "$H1"; chk_end; } > "$CHK"
expect_refused "copies with an unexamined tip" "has no row for tip $T1"
{ fcr w s same-as-default 1 1; mc w s merged "$H1"; tc w s merged "$T1" branch; chk_end; } > "$CHK"
expect_refused "a verdict for the pushed HEAD of an untracked entry" "judged the pushed HEAD"

one_f 0 0 2 0 < /dev/null
{ fcr w s same-as-default 2 2; mc w s merged "$H1"; chk_end; } > "$CHK"
expect_refused "a commit verdict for an entry that holds no commit" "which holds no commit"
{ mc w s merged "$H1"; fcr w s same-as-default 2 2; chk_end; } > "$CHK"
expect_refused "a commit verdict before the files were compared" "which the inventory reads as untracked"
{ fcr w s same-as-default 2 2; fcr w s same-as-default 2 2; chk_end; } > "$CHK"
expect_refused "the files compared twice" "compares the files of w s twice"
{ fcr w s same-as-default 3 3; chk_end; } > "$CHK"
expect_refused "a file count the inventory does not have" "counts other files than the inventory"
{ fcr w s same-as-default 2 1; chk_end; } > "$CHK"
expect_refused "same-as-default with a file that did not match" "without matching every file"
{ fcr w s differs 2 3; chk_end; } > "$CHK"
expect_refused "more matches than files" "malformed FILE-CHECK row"
{ fcr w s shiny 2 2; chk_end; } > "$CHK"
expect_refused "a FILE-CHECK verdict this script does not know" "unknown FILE-CHECK verdict shiny"
{ printf 'FILE-CHECK\tw\ts\tsame-as-default\tfiles=2\tsame=2\n'; chk_end; } > "$CHK"
expect_refused "a FILE-CHECK row that is cut short" "a FILE-CHECK row has 6 fields, not 7"
one unpushed 1 1 < /dev/null
{ fcr w s same-as-default 2 2; mc w s merged "$H1"; chk_end; } > "$CHK"
expect_refused "a FILE-CHECK row for an entry that is not untracked" "which the inventory reads as unpushed"

{ entry_f w s unpushed "$H1" 1 1 0 4; inv_end 1; } > "$INV"
{ mc w s merged "$H1"; chk_end; } > "$CHK"
expect_class "a merged HEAD beside ignored files is tool output" w s tool-output
{ mc w s github-bot "$H1"; chk_end; } > "$CHK"
expect_class "a bot's commit beside ignored files is tool output" w s tool-output
{ mc w s open "$H1"; chk_end; } > "$CHK"
expect_class "ignored files never lower work in flight" w s work-in-flight
{ mc w s no-pr "$H1"; chk_end; } > "$CHK"
expect_class "ignored files never lower an unsettled commit" w s needs-a-person

echo "unknown and the worktree row"
{ entry a s1 clean "$H1" 0 0; entry a s2 unpushed "$H1" 1 1; entry b s1 ignored "$H1" 0 0
  entry b s2 unpushed "$H2" 1 1; entry c s1 clean "$H1" 0 0; inv_end 5; } > "$INV"
{ mc a s2 no-pr "$H1"; printf 'UNKNOWN\tb\ts2\tit changed since the inventory\n'; chk_end; } > "$CHK"
rc=0; run || rc=$?
if [ "$rc" = 2 ] && grep -q "$(printf '^CLASS\tb\ts2\tunknown\t')" "$OUT"; then ok "an UNKNOWN row gives the class unknown and exit 2"
else bad "an UNKNOWN row gives the class unknown and exit 2" "rc=$rc"; fi
want=$(printf 'WORKTREE\ta\tneeds-a-person\tentries=2\nWORKTREE\tb\tunknown\tentries=2\nWORKTREE\tc\tnothing-held\tentries=1')
if [ "$(grep '^WORKTREE' "$OUT")" = "$want" ]; then ok "a worktree takes its most demanding entry's class"
else bad "a worktree takes its most demanding entry's class" "$(grep '^WORKTREE' "$OUT")"; fi
last=$(tail -n 1 "$OUT")
case "$last" in
  "$(printf 'CLASSIFIED\tentries=5\tnothing_held=2\tmerged_in_content=0\tmade_on_github=0\ttool_output=1\twork_in_flight=0\tneeds_a_person=1\tunknown=1\tworktrees=3\twt_nothing_held=1\twt_merged_in_content=0\twt_made_on_github=0\twt_tool_output=0\twt_work_in_flight=0\twt_needs_a_person=1\twt_unknown=1\tbelow_min_idle=0')")
    ok "the closing line carries the totals" ;;
  *) bad "the closing line carries the totals" "$last" ;;
esac
{ entry a s1 unpushed "$H1" 1 1; entry a s2 ignored "$H1" 0 0; inv_end 2; } > "$INV"
{ mc a s1 merged "$H1"; chk_end; } > "$CHK"
run; if grep -q "$(printf '^WORKTREE\ta\ttool-output\t')" "$OUT"; then ok "tool output outranks merged in content"
else bad "tool output outranks merged in content" "$(grep '^WORKTREE' "$OUT")"; fi
{ entry a s1 unpushed "$H1" 1 1; entry a s2 unpushed "$H2" 1 1; entry b s1 unpushed "$H1" 1 1; entry b s2 ignored "$H1" 0 0; inv_end 4; } > "$INV"
{ mc a s1 merged "$H1"; mc a s2 github-bot "$H2"; mc b s1 github-bot "$H1"; chk_end; } > "$CHK"
run; if grep -q "$(printf '^WORKTREE\ta\tmade-on-github\t')" "$OUT" && grep -q "$(printf '^WORKTREE\tb\ttool-output\t')" "$OUT"
then ok "made on GitHub outranks merged in content, and tool output outranks it"
else bad "made on GitHub outranks merged in content, and tool output outranks it" "$(grep '^WORKTREE' "$OUT")"; fi

{ entry a s1 clean "$H1" 0 0; inv_end 1; } > "$INV"
{ printf 'UNKNOWN\ta\ts1\tit changed since the inventory\n'; chk_end; } > "$CHK"
rc=0; run || rc=$?
if [ "$rc" = 2 ] && grep -q "$(printf '^CLASS\ta\ts1\tunknown\t')" "$OUT"; then ok "an UNKNOWN row outranks a clean inventory read"
else bad "an UNKNOWN row outranks a clean inventory read" "rc=$rc $(cat "$OUT")"; fi
echo "input that cannot be joined"
one unpushed 1 1 < /dev/null
chk_end > "$CHK"
expect_refused "an unpushed entry with no MERGE-CHECK row" "has no row for w s"
{ mc w s merged "$H2"; chk_end; } > "$CHK"
expect_refused "a MERGE-CHECK row for another HEAD" "names another HEAD"
{ mc w s merged "$H1"; mc w s merged "$H1"; chk_end; } > "$CHK"
expect_refused "two MERGE-CHECK rows for one entry" "answers twice for w s"
{ mc w s merged-ish "$H1"; chk_end; } > "$CHK"
expect_refused "a verdict this script does not know" "unknown MERGE-CHECK verdict merged-ish"
{ mc w other merged "$H1"; chk_end; } > "$CHK"
expect_refused "a row for an entry the inventory does not list" "which the inventory does not list"
{ mc w s merged "$H1"; } > "$CHK"
expect_refused "a merged check with no closing line" "merged check has no CHECKED line"
{ mc w s merged "$H1"; chk_end; mc w s merged "$H1"; } > "$CHK"
expect_refused "rows after the merged check's closing line" "rows after its CHECKED line"
{ mc w s merged "$H1"; printf 'SURPRISE\tw\ts\n'; chk_end; } > "$CHK"
expect_refused "a row kind this script does not know" "unknown merged-check row SURPRISE"
{ mc w s no-pr "$H1"; cc w s same-change "$T3"; chk_end; } > "$CHK"
expect_refused "a content row for a commit the entry does not hold" "neither HEAD nor a tip"
{ mc w s no-pr "$H1"; cc w s same-ish "$H1"; chk_end; } > "$CHK"
expect_refused "a content verdict this script does not know" "unknown CONTENT-CHECK verdict"

one local-only 0 1 <<EOF
$(tip w s "$T1" branch)
EOF
{ mc w s not-checked "$H1"; chk_end; } > "$CHK"
expect_refused "a tip with no TIP-CHECK row" "has no row for tip $T1"
{ mc w s not-checked "$H1"; tc w s merged "$T2" branch; chk_end; } > "$CHK"
expect_refused "a TIP-CHECK row for a tip the inventory does not list" "which the inventory does not list for w s"
{ mc w s not-checked "$H1"; tc w s merged "$T1" ref; chk_end; } > "$CHK"
expect_refused "a TIP-CHECK row of another kind" "names another kind"
{ mc w s merged "$H1"; tc w s merged "$T1" branch; chk_end; } > "$CHK"
expect_refused "a judged HEAD on an entry whose HEAD is pushed" "judged the pushed HEAD"
one local-only 0 1 < /dev/null
{ mc w s not-checked "$H1"; chk_end; } > "$CHK"
expect_refused "commits away from HEAD with no tip named" "names no tip for w s"

one clean 0 0 < /dev/null
{ mc w s merged "$H1"; chk_end; } > "$CHK"
expect_refused "a verdict for an entry that holds no commits" "which the inventory reads as clean"
chk_end > "$CHK"
{ entry w s clean "$H1" 0 0; printf 'CHECKED\tworktrees=1\tentries=1\tbelow_min_idle=0\n'; } > "$INV"
expect_refused "an inventory taken without --tips" "taken without --tips"
{ entry w s clean "$H1" 0 0; } > "$INV"
expect_refused "an inventory with no closing line" "inventory has no CHECKED line"
{ entry w s clean "$H1" 0 0; inv_end 2; } > "$INV"
expect_refused "an inventory whose total disagrees with its rows" "lists 1 entries and its CHECKED line says 2"
{ entry w s clean "$H1" 0 0; entry w s clean "$H1" 0 0; inv_end 2; } > "$INV"
expect_refused "an entry listed twice" "lists w s twice"
{ entry w s clean "$H1" 0 0; printf 'UNREADABLE\tw\tt\twhy\n'; inv_end 1; } > "$INV"
expect_refused "an UNREADABLE inventory row" "UNREADABLE row"
{ entry w s shiny "$H1" 0 0; inv_end 1; } > "$INV"
expect_refused "an inventory class this script does not know" "unknown inventory class shiny"
{ inv_end 0; entry w s clean "$H1" 0 0; } > "$INV"
expect_refused "rows after the inventory's closing line" "inventory has rows after its CHECKED line"
: > "$INV"
expect_refused "an empty inventory" "inventory has no CHECKED line"

echo "usage"
rc=0; "$SUT" > "$OUT" 2> "$ERR" < /dev/null || rc=$?
if [ "$rc" = 2 ] && grep -q '^worktree-inventory-classify: usage' "$ERR"; then ok "no arguments is a usage error"; else bad "no arguments is a usage error" "rc=$rc"; fi
rc=0; "$SUT" --inventory "$TMP/absent" > "$OUT" 2> "$ERR" < /dev/null || rc=$?
if [ "$rc" = 2 ] && grep -q 'not a readable file' "$ERR"; then ok "a missing inventory file is refused"; else bad "a missing inventory file is refused" "rc=$rc"; fi
"$SUT" --help > "$OUT" 2> "$ERR"; rc=$?
if [ "$rc" = 0 ] && grep -q '^Usage:' "$OUT"; then ok "--help prints the header"; else bad "--help prints the header" "rc=$rc"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
test_run_completed=1
[ "$fail" = 0 ]
