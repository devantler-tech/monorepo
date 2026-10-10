#!/usr/bin/env bash
# Tests for worktree-inventory-merged-check.sh — the pull-request lookup for the inventory's
# `unpushed` entries (monorepo#3072).
#
# `gh` is a stub that answers from one fixture file per commit and records every call, so
# the cases assert both the verdict and what was (and was not) sent. The negative controls
# matter most: a failed, partial or surprising answer must never become `merged` or `no-pr`,
# and a repository outside the organisation must never be queried.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/worktree-inventory-merged-check.sh"
INVENTORY="$SCRIPT_DIR/worktree-submodule-inventory.sh"

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
    echo "worktree-inventory-merged-check.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT

g() { git -c user.email=t@t.t -c user.name=t -c commit.gpgsign=false "$@"; }

BIN="$TMP/bin"; FIX="$TMP/fixtures"; CALLS="$TMP/calls"; ROOT="$TMP/worktrees"
mkdir -p "$BIN" "$FIX" "$ROOT"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Answers `gh api graphql` from $FIX/<sha>.json; a missing fixture is a failed request.
# A ref question (q=refs/...) is answered from $FIX/ref-<last path component>.json.
set -euo pipefail
sha=''; name=''; owner=''; host=''; prev=''
for a in "$@"; do
  case "$a" in sha=*) sha=${a#sha=} ;; r=*) name=${a#r=} ;; o=*) owner=${a#o=} ;; q=*) sha="ref-${a##*/}" ;; esac
  # A comparison (repos/<owner>/<name>/compare/<base>...<head>) is answered from
  # $FIX/cmp-<base>-<head>.json.
  case "$a" in repos/*/*/compare/*...*)
    c=${a##*/compare/}; sha="cmp-${c%%...*}-${c##*...}"; rest=${a#repos/}; owner=${rest%%/*}; rest=${rest#*/}; name=${rest%%/*} ;;
  esac
  [ "$prev" != --hostname ] || host=$a
  prev=$a
done
printf '%s %s %s %s\n' "$owner/$name" "$sha" "$host" "${GH_HOST:-unset}/${GH_REPO:-unset}" >> "$CALLS"
[ -f "$FIX/$sha.json" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
cat "$FIX/$sha.json"
STUB
chmod +x "$BIN/gh"
export FIX CALLS

OTHER=$(printf '%040d' 99)
# add_sub <worktree> <origin-url> -> a directory shaped like a populated submodule, with one
# commit of its own so that every worktree has a distinct real HEAD.
add_sub() {
  local d="$ROOT/$1/sub"
  mkdir -p "$ROOT/$1"
  g init -q -b main "$d"
  echo "$1" > "$d/f"; g -C "$d" add f; g -C "$d" commit -qm "$1"
  g -C "$d" config remote.origin.url "$2"
}
sha_of() { g -C "$ROOT/$1/sub" rev-parse HEAD; }
node() { # number state head [base] [base-repository]
  printf '{"number":%s,"state":"%s","headRefOid":"%s","baseRefName":"%s","baseRepository":{"nameWithOwner":"%s"}}' \
    "$1" "$2" "$3" "${4:-main}" "${5:-devantler-tech/ksail}"
}
prs() { # worktree total nodes-json
  printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":%s,"nodes":%s}}}}}\n' \
    "$2" "$3" > "$FIX/$(sha_of "$1").json"
}
cmp() { # worktree head status behind merge-base
  printf '{"status":"%s","behind_by":%s,"ahead_by":1,"merge_base_commit":{"sha":"%s"}}\n' \
    "$3" "$4" "$5" > "$FIX/cmp-$(sha_of "$1")-$2.json"
}
raw() { printf '%s\n' "$2" > "$FIX/$(sha_of "$1").json"; }
entry() { # worktree class [unpushed] [local_only] [path]
  printf 'ENTRY\t%s\t%s\t%s\tidle_days=20\thead=%s\tunpushed=%s\tlocal_only=%s\tmodified=0\tuntracked=0\tnested=0\tignored=0\n' \
    "$1" "${5:-sub}" "$2" "$(sha_of "$1")" "${3:-1}" "${4:-1}"
}
# seal <file> -> appends the closing line the inventory would print for those rows.
seal() {
  awk -F'\t' '$1 == "ENTRY" { e++; if ($4 == "unpushed") u++; if ($4 == "local-only") l++ }
    END { printf "CHECKED\tworktrees=1\tentries=%d\tunpushed=%d\tlocal_only=%d\tbelow_min_idle=0\tunreadable=0\n", e, u, l }' "$1" >> "$1"
}

run() { # stdin -> OUT, RC
  : > "$CALLS"
  OUT=$(PATH="$BIN:$PATH" bash "$SUT" "$ROOT" 2>"$TMP/err"); RC=$?
}
verdict_of() { printf '%s\n' "$OUT" | awk -F'\t' -v w="$1" '$1 == "MERGE-CHECK" && $2 == w { print $4 " " $7 " " $8 }'; }
expect() { # name worktree want
  local got; got=$(verdict_of "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$got] rc=$RC out=$OUT"; fi
}
check() { # name condition...
  local name=$1; shift
  if "$@"; then ok "$name"; else bad "$name" "rc=$RC out=$OUT err=$(cat "$TMP/err") calls=$(cat "$CALLS")"; fi
}
out_has() { grep -q "$1" <<<"$OUT"; }
no_verdict() { ! grep -q '^MERGE-CHECK' <<<"$OUT"; }
no_calls() { [ ! -s "$CALLS" ]; }
rc_is() { [ "$RC" = "$1" ]; }

for w in w-merged w-closed w-nopr w-absent w-both w-stacked w-local w-fail w-held w-fork w-stale w-dirty w-gitlink; do
  add_sub "$w" 'git@github.com:devantler-tech/ksail.git'
done
add_sub w-open      'https://github.com/devantler-tech/platform.git'
add_sub w-other     'ssh://git@github.com/devantler-tech/ksail.git'
add_sub w-foreign   'git@github.com:someone-else/ksail.git'
add_sub w-gitlab    'git@gitlab.com:devantler-tech/ksail.git'
add_sub w-lookalike 'git@github.com:devantler-tech-evil/ksail.git'
# A second worktree at the same commit as w-merged.
mkdir -p "$ROOT/w-same"; g clone -q "$ROOT/w-merged/sub" "$ROOT/w-same/sub"
g -C "$ROOT/w-same/sub" config remote.origin.url 'https://github.com/devantler-tech/ksail'
g -C "$ROOT/w-same/sub" update-ref -d refs/remotes/origin/main
g -C "$ROOT/w-same/sub" symbolic-ref -d refs/remotes/origin/HEAD
# w-held keeps 8 more commits on another local branch.
g -C "$ROOT/w-held/sub" checkout -q -b side
for i in 1 2 3 4 5 6 7 8; do echo "$i" > "$ROOT/w-held/sub/f"; g -C "$ROOT/w-held/sub" commit -qam "side $i"; done
g -C "$ROOT/w-held/sub" checkout -q main
# w-local's HEAD is pushed, and it keeps 3 commits on another local branch.
g -C "$ROOT/w-local/sub" update-ref refs/remotes/origin/main HEAD
g -C "$ROOT/w-local/sub" checkout -q -b side
for i in 1 2 3; do echo "$i" > "$ROOT/w-local/sub/f"; g -C "$ROOT/w-local/sub" commit -qam "side $i"; done
g -C "$ROOT/w-local/sub" checkout -q main

prs w-merged 1 "[$(node 11 MERGED "$(sha_of w-merged)")]"
prs w-open   1 "[$(node 12 OPEN "$(sha_of w-open)" main devantler-tech/platform)]"
prs w-closed 1 "[$(node 13 CLOSED "$(sha_of w-closed)")]"
prs w-other  1 "[$(node 14 MERGED "$OTHER")]"
# The head that merged does not contain w-other's commit: the two diverged.
cmp w-other "$OTHER" diverged 2 "$(printf '%040d' 98)"
prs w-nopr   0 '[]'
raw w-absent '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":null}}}'
prs w-both   2 "[$(node 17 CLOSED "$(sha_of w-both)"),$(node 18 MERGED "$(sha_of w-both)")]"
prs w-stacked 1 "[$(node 19 MERGED "$(sha_of w-stacked)" feature-base)]"
prs w-held   1 "[$(node 20 MERGED "$(sha_of w-held)")]"
prs w-fork   1 "[$(node 23 MERGED "$(sha_of w-fork)" main someone-else/ksail)]"
prs w-stale  1 "[$(node 24 MERGED "$(sha_of w-stale)")]"
prs w-dirty  1 "[$(node 25 MERGED "$(sha_of w-dirty)")]"
prs w-gitlink 1 "[$(node 26 MERGED "$(sha_of w-gitlink)")]"

echo '== verdicts'
{ entry w-merged unpushed; entry w-open unpushed; entry w-closed unpushed; entry w-other unpushed
  entry w-nopr unpushed; entry w-absent unpushed; entry w-both unpushed; entry w-same unpushed
  entry w-stacked unpushed; entry w-held unpushed 1 9; entry w-fork unpushed; } > "$TMP/in"; seal "$TMP/in"
run < "$TMP/in"
expect 'a merged pull request at this head is merged'            w-merged  'merged pr=11 other_local=0'
expect 'an open pull request at this head is open'               w-open    'open pr=12 other_local=0'
expect 'a closed pull request at this head is closed'            w-closed  'closed pr=13 other_local=0'
expect 'a merged pull request at ANOTHER head is not merged'     w-other   'other-head pr=14 other_local=0'
expect 'a commit in no pull request is no-pr'                    w-nopr    'no-pr pr=- other_local=0'
expect 'a commit GitHub does not have is not-on-github'          w-absent  'not-on-github pr=- other_local=0'
expect 'merged wins over closed at the same head'                w-both    'merged pr=18 other_local=0'
expect 'a second entry at the same commit gets the same verdict' w-same    'merged pr=11 other_local=0'
expect 'merged into another branch is not merged'                w-stacked 'merged-other-base pr=19 other_local=0'
expect 'commits held away from HEAD are counted beside merged'   w-held    'merged pr=20 other_local=8'
expect "merged into a fork's default branch is not merged"           w-fork    'merged-other-base pr=23 other_local=0'
check 'every entry answered: exit 0' rc_is 0
n=$(grep -c " $(sha_of w-merged) " "$CALLS")
if [ "$n" = 1 ]; then ok 'one lookup per repository and commit'; else bad 'one lookup per repository and commit' "calls=$n"; fi
check 'owner, name and host are the ones sent' grep -q "^devantler-tech/platform $(sha_of w-open) github.com " "$CALLS"
check 'the closing line carries the totals' out_has \
  $'^CHECKED\tmerged=4\tmerged_ancestor=0\tmerged_other_base=2\topen=1\tclosed=1\tother_head=1\tno_pr=1\tnot_on_github=1\tnot_checked=0\tother_classes=0\tunknown=0$'
: > "$CALLS"
OUT=$(GH_HOST=ghe.example.invalid GH_REPO=someone/else PATH="$BIN:$PATH" bash "$SUT" "$ROOT" < "$TMP/in" 2>"$TMP/err"); RC=$?
if [ "$RC" = 0 ] && ! grep -qv ' github.com unset/unset$' "$CALLS"; then ok 'an inherited GH_HOST or GH_REPO is not honoured'
else bad 'an inherited GH_HOST or GH_REPO is not honoured' "rc=$RC $(head -2 "$CALLS")"; fi

echo '== a commit in the history of a merged pull request'
# The pull request moved on from the commit and then merged: no pull request has the commit
# as its head, and only the comparison can say whether the head that merged contains it.
for w in w-anc w-anc-fail w-anc-odd w-anc-second w-anc-stacked w-anc-fork w-anc-open w-anc-badhead; do
  add_sub "$w" 'git@github.com:devantler-tech/ksail.git'
done
H1=$(printf '%040d' 71); H2=$(printf '%040d' 72)
prs w-anc         1 "[$(node 51 MERGED "$H1")]"
cmp w-anc "$H1" ahead 0 "$(sha_of w-anc)"
prs w-anc-fail    1 "[$(node 52 MERGED "$H1")]"
prs w-anc-odd     1 "[$(node 53 MERGED "$H1")]"
cmp w-anc-odd "$H1" ahead 0 "$OTHER"
prs w-anc-second  2 "[$(node 54 MERGED "$H1"),$(node 55 MERGED "$H2")]"
cmp w-anc-second "$H1" diverged 3 "$OTHER"
cmp w-anc-second "$H2" identical 0 "$(sha_of w-anc-second)"
prs w-anc-stacked 1 "[$(node 56 MERGED "$H1" feature-base)]"
prs w-anc-fork    1 "[$(node 57 MERGED "$H1" main someone-else/ksail)]"
prs w-anc-open    1 "[$(node 58 OPEN "$H1")]"
prs w-anc-badhead 1 "[$(node 59 MERGED 'main/../../x')]"
{ entry w-anc unpushed; entry w-anc-second unpushed; entry w-anc-stacked unpushed
  entry w-anc-fork unpushed; entry w-anc-open unpushed; entry w-other unpushed; } > "$TMP/in"; seal "$TMP/in"
run < "$TMP/in"
expect 'an ancestor of the head that merged is merged-ancestor'      w-anc         'merged-ancestor pr=51 other_local=0'
expect 'the pull request that proves it is the one named'            w-anc-second  'merged-ancestor pr=55 other_local=0'
expect 'a pull request merged into another branch proves nothing'    w-anc-stacked 'other-head pr=56 other_local=0'
expect "a pull request merged into a fork proves nothing"            w-anc-fork    'other-head pr=57 other_local=0'
expect 'an open pull request at another head proves nothing'         w-anc-open    'other-head pr=58 other_local=0'
expect 'a head that merged WITHOUT the commit stays other-head'      w-other       'other-head pr=14 other_local=0'
check 'every entry answered: exit 0' rc_is 0
check 'the comparison names this commit and the head that merged' \
  grep -q "^devantler-tech/ksail cmp-$(sha_of w-anc)-$H1 github.com " "$CALLS"
check 'no comparison is made for a pull request that could not prove it' eval \
  '! grep -q "cmp-$(sha_of w-anc-stacked)-\|cmp-$(sha_of w-anc-fork)-\|cmp-$(sha_of w-anc-open)-" "$CALLS"'
check 'the closing line counts them apart from merged' out_has $'^CHECKED\tmerged=0\tmerged_ancestor=2\tmerged_other_base=0\topen=0\tclosed=0\tother_head=4\t'
anc_unknown() { # name worktree
  { entry "$2" unpushed; } > "$TMP/in"; seal "$TMP/in"
  run < "$TMP/in"
  if [ "$RC" = 2 ] && out_has "^UNKNOWN	$2	sub	the pull request lookup failed$" && [ -z "$(verdict_of "$2")" ]; then
    ok "$1"; else bad "$1" "rc=$RC out=$OUT"; fi
}
anc_unknown 'a comparison that failed is UNKNOWN, never other-head or merged-ancestor' w-anc-fail
anc_unknown 'an answer whose merge base is another commit but claims no divergence'    w-anc-odd
anc_unknown 'a head that is not a commit id is never put in a request'                 w-anc-badhead
check 'and no comparison was sent for it' eval '! grep -q " cmp-" "$CALLS"'
printf '{"status":"ahead","behind_by":0}\n' > "$FIX/cmp-$(sha_of w-anc-fail)-$H1.json"
anc_unknown 'an answer with no merge base' w-anc-fail
printf '{"message":"Not Found"}\n' > "$FIX/cmp-$(sha_of w-anc-fail)-$H1.json"
anc_unknown 'an error body' w-anc-fail
cmp w-anc-fail "$H1" behind 0 "$OTHER"
anc_unknown 'an answer that is behind by nothing' w-anc-fail

echo '== never queried'
{ entry w-foreign unpushed; entry w-gitlab unpushed; entry w-lookalike unpushed
  entry w-local local-only 0 3; entry w-merged clean 0 0; } > "$TMP/in"; seal "$TMP/in"
run < "$TMP/in"
expect 'another organisation is not-checked'                     w-foreign   'not-checked pr=- other_local=0'
expect 'another host is not-checked'                             w-gitlab    'not-checked pr=- other_local=0'
expect 'an organisation with our name as prefix is not-checked'  w-lookalike 'not-checked pr=- other_local=0'
expect 'a local-only entry is not-checked'                       w-local     'not-checked pr=- other_local=3'
check 'none of them reached GitHub' no_calls
check 'not-checked is not a failure' rc_is 0
check 'other classes are counted, not listed' out_has $'\tnot_checked=4\tother_classes=1\t'

echo '== a lookup that cannot be trusted is UNKNOWN'
unknown_case() { # name
  { entry w-fail unpushed; } > "$TMP/in"; seal "$TMP/in"
  run < "$TMP/in"
  if [ "$RC" = 2 ] && out_has $'^UNKNOWN\tw-fail\tsub\tthe pull request lookup failed$' && [ -z "$(verdict_of w-fail)" ]; then
    ok "$1"; else bad "$1" "rc=$RC out=$OUT"; fi
}
unknown_case 'a failed request'
raw w-fail '{"errors":[{"message":"rate limited"}],"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":null}}}'
unknown_case 'an error body beside an empty object (would read as not-on-github)'
raw w-fail '{"data":{"repository":null}}'
unknown_case 'a repository GitHub does not return'
raw w-fail '{"data":{"repository":{"defaultBranchRef":{"name":"main"}}}}'
unknown_case 'an answer with no object key (would read as not-on-github)'
raw w-fail "{\"data\":{\"repository\":{\"defaultBranchRef\":null,\"object\":{\"__typename\":\"Commit\",\"associatedPullRequests\":{\"totalCount\":1,\"nodes\":[$(node 21 MERGED "$(sha_of w-fail)")]}}}}}"
unknown_case 'no default branch to compare the base with (would read as merged)'
prs w-fail 3 "[$(node 21 CLOSED "$OTHER")]"
unknown_case 'a list cut short (would read as other-head)'
raw w-fail '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Tree"}}}}'
unknown_case 'an object that is not a commit'
raw w-fail 'not json'
unknown_case 'an answer that is not JSON'
prs w-fail 1 "[$(node 22 DRAFT "$(sha_of w-fail)")]"
unknown_case 'a pull request state this script does not know'
: > "$FIX/$(sha_of w-fail).json"
unknown_case 'an empty answer'

echo '== rows are data'
bad_row() { # name row want-reason
  { printf '%s\n' "$2"; } > "$TMP/in"; seal "$TMP/in"
  run < "$TMP/in"
  if [ "$RC" = 2 ] && no_calls && no_verdict && { out_has "$3" || grep -q "$3" "$TMP/err"; }; then ok "$1"
  else bad "$1" "rc=$RC calls=$(cat "$CALLS") out=$OUT err=$(cat "$TMP/err")"; fi
}
M=$(sha_of w-merged)
mkdir -p "$TMP/outside"; g clone -q "$ROOT/w-merged/sub" "$TMP/outside/sub"
g -C "$TMP/outside/sub" config remote.origin.url 'git@github.com:devantler-tech/secret.git'
ln -s "$TMP/outside" "$ROOT/w-link"
mkdir -p "$ROOT/w-inner"; ln -s "$TMP/outside/sub" "$ROOT/w-inner/sub"
row_for() { printf 'ENTRY\t%s\t%s\t%s\tidle_days=1\thead=%s\tunpushed=1\tlocal_only=1' "$1" "$2" "${4:-unpushed}" "$3"; }
bad_row 'a worktree name that leaves the root'       "$(row_for ../outside sub "$M")"        'not a worktree name'
bad_row 'a submodule path that leaves the worktree'  "$(row_for w-merged ../../outside/sub "$M")" 'does not stay inside'
bad_row 'a worktree that is a symbolic link'         "$(row_for w-link sub "$M")"            'symbolic link'
bad_row 'a submodule that is a symbolic link'        "$(row_for w-inner sub "$M")"           'symbolic link'
bad_row 'a short commit'                             "$(row_for w-merged sub abc123)"        'no full head commit'
bad_row 'a commit that is not hexadecimal'           "$(row_for w-merged sub zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz)" 'no full head commit'
bad_row 'a commit the repository is no longer at'    "$(row_for w-merged sub "$(sha_of w-closed)")" 'HEAD moved since the inventory'
bad_row 'a path with no repository under the root'   "$(row_for w-merged missing "$M")"      'no repository at that path'
bad_row 'a class this script does not know'          "$(row_for w-merged sub "$M" merged)"   'malformed'
bad_row 'a row kind this script does not know'       "$(printf 'MERGE-CHECK\tw-merged\tsub\tmerged')" 'malformed'
bad_row 'a row shifted by a leading tab'             "$(printf '\t%s' "$(row_for w-merged sub "$M")")" 'malformed'
bad_row 'a row with no commit counts'                "$(printf 'ENTRY\tw-merged\tsub\tunpushed\tidle_days=1\thead=%s' "$M")" 'no commit counts'
bad_row 'fewer local-only commits than unpushed ones' \
  "$(printf 'ENTRY\tw-merged\tsub\tunpushed\tidle_days=1\thead=%s\tunpushed=3\tlocal_only=1' "$M")" 'no commit counts'
# HEAD stands still while the entry changes underneath a saved inventory.
entry w-stale unpushed > "$TMP/row-stale"; entry w-dirty unpushed > "$TMP/row-dirty"
g -C "$ROOT/w-stale/sub" checkout -q -b later; echo later > "$ROOT/w-stale/sub/f"
g -C "$ROOT/w-stale/sub" commit -qam later; g -C "$ROOT/w-stale/sub" checkout -q main
echo edit > "$ROOT/w-dirty/sub/f"
bad_row 'a new local commit since the inventory, HEAD unchanged' "$(tr -d '\n' < "$TMP/row-stale")" 'it changed since the inventory'
bad_row 'an edited file since the inventory'                     "$(tr -d '\n' < "$TMP/row-dirty")" 'it changed since the inventory'
# The submodule directory is real, but its .git is a link to a repository outside the root.
G=$(sha_of w-gitlink); mv "$ROOT/w-gitlink/sub/.git" "$TMP/outside-git"; ln -s "$TMP/outside-git" "$ROOT/w-gitlink/sub/.git"
bad_row 'a .git that is a symbolic link'             "$(row_for w-gitlink sub "$G")"         'symbolic link'
bad_row 'counts written with a leading zero' \
  "$(printf 'ENTRY\tw-merged\tsub\tunpushed\tidle_days=1\thead=%s\tunpushed=01\tlocal_only=01' "$M")" 'no commit counts'
bad_row 'a row with an empty field' \
  "$(printf 'ENTRY\tw-merged\t\tunpushed\tidle_days=1\thead=%s\tunpushed=1\tlocal_only=1' "$M")" 'malformed'
# A submodule whose own .git is an empty directory: git answers with the worktree's origin.
mkdir -p "$ROOT/w-broken"; g init -q -b main "$ROOT/w-broken"
g -C "$ROOT/w-broken" config remote.origin.url 'git@github.com:devantler-tech/monorepo.git'
mkdir -p "$ROOT/w-broken/sub/.git"
bad_row 'a broken submodule is not looked up in its parent repository' "$(row_for w-broken sub "$M")" 'cannot read its origin'

echo '== an incomplete inventory'
incomplete() { # name want-in-stderr  (stdin already in $TMP/in)
  run < "$TMP/in"
  if [ "$RC" = 2 ] && grep -q "$2" "$TMP/err"; then ok "$1"; else bad "$1" "rc=$RC err=$(cat "$TMP/err") out=$OUT"; fi
}
entry w-merged unpushed > "$TMP/in"
incomplete 'no closing line' 'no closing CHECKED line'
{ entry w-merged unpushed; printf 'UNREADABLE\tw-x\tsub\tcannot read its status\n'; } > "$TMP/in"; seal "$TMP/in"
incomplete 'an UNREADABLE inventory row' 'UNREADABLE, malformed or trailing'
: > "$TMP/in"
incomplete 'an empty inventory' 'no closing CHECKED line'
printf 'CHECKED\tworktrees=1\tentries=5\tunpushed=5\tlocal_only=0\tbelow_min_idle=0\tunreadable=0\n' > "$TMP/in"
incomplete 'a closing line whose rows were lost' 'do not match'
printf 'CHECKED\tworktrees=1\tentries=0\tunpushed=0\tlocal_only=0\tbelow_min_idle=0\tunreadable=2\n' > "$TMP/in"
incomplete 'a closing line that reports unreadable entries' 'reports unreadable entries'
printf 'CHECKED\tworktrees=0\tentries=0\tunpushed=0\tlocal_only=0\tbelow_min_idle=0\tunreadable=0\n' > "$TMP/in"
incomplete 'an inventory that found no worktree' 'found no worktree'
for f in entries unpushed local_only; do
  { entry w-merged unpushed; entry w-local local-only 0 3; } > "$TMP/in"; seal "$TMP/in"
  sed -i.bak "s/	$f=[0-9]*/	$f=7/" "$TMP/in"
  incomplete "a closing line whose $f total disagrees" 'do not match'
done
{ entry w-merged unpushed; } > "$TMP/in"; seal "$TMP/in"; sed -i.bak 's/below_min_idle=0/below_min_idle=4/' "$TMP/in"
run < "$TMP/in"
check 'entries the inventory left out for their age are named' out_has $'^NOTE\tthe inventory left out 4 entries'
printf 'CHECKED\tworktrees=1\n' > "$TMP/in"
incomplete 'a closing line with no totals' 'carries no totals'
{ printf 'CHECKED\tworktrees=1\tentries=1\tunpushed=1\tlocal_only=0\tbelow_min_idle=0\tunreadable=0\n'; entry w-merged unpushed; } > "$TMP/in"
incomplete 'a row after the closing line' 'UNREADABLE, malformed or trailing'
check 'and that row was not looked up' no_calls
{ entry w-merged unpushed; printf 'CHECKED\tworktrees=1\tentries=1\tunpushed=1\tlocal_only=0\tbelow_min_idle=0\tunreadable=0'; } > "$TMP/in"
run < "$TMP/in"
check 'a closing line with no trailing newline still counts' rc_is 0

echo '== usage'
PATH="$BIN:$PATH" bash "$SUT" >/dev/null 2>&1 </dev/null; RC=$?; check 'no root: exit 2' rc_is 2
PATH="$BIN:$PATH" bash "$SUT" "$TMP/absent" >/dev/null 2>&1 </dev/null; RC=$?; check 'a missing root: exit 2' rc_is 2

echo '== end to end with the real inventory'
E2E="$TMP/e2e"; mkdir -p "$E2E"
g init -q -b main "$TMP/seed"; echo base > "$TMP/seed/f"; g -C "$TMP/seed" add f; g -C "$TMP/seed" commit -qm base
g clone -q --bare "$TMP/seed" "$TMP/remote.git"
g init -q -b main "$E2E/wt"
printf '[submodule "s"]\n\tpath = sub\n\turl = https://example.invalid/s.git\n' > "$E2E/wt/.gitmodules"
g -C "$E2E/wt" add .gitmodules; g -C "$E2E/wt" commit -qm base
g clone -q "$TMP/remote.git" "$E2E/wt/sub"
echo more > "$E2E/wt/sub/f"; g -C "$E2E/wt/sub" commit -qam more
head_sha=$(g -C "$E2E/wt/sub" rev-parse HEAD)
# The clone's origin is a local path; the lookup needs the GitHub origin a real submodule has.
g -C "$E2E/wt/sub" config remote.origin.url 'git@github.com:devantler-tech/ksail.git'
printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":1,"nodes":[%s]}}}}}\n' \
  "$(node 31 MERGED "$head_sha")" > "$FIX/$head_sha.json"
: > "$CALLS"
OUT=$(bash "$INVENTORY" "$E2E" | PATH="$BIN:$PATH" bash "$SUT" "$E2E" 2>"$TMP/err"); RC=$?
check 'the inventory output is read as it is printed' out_has \
  "^MERGE-CHECK	wt	sub	merged	head=$head_sha	repo=devantler-tech/ksail	pr=31	other_local=0\$"
check 'and exits 0' rc_is 0

echo '== tips: the commits an entry holds away from HEAD'
T="$TMP/tips"; mkdir -p "$T"
g init -q -b main "$T/wt"
printf '[submodule "s"]\n\tpath = sub\n\turl = https://example.invalid/s.git\n' > "$T/wt/.gitmodules"
g -C "$T/wt" add .gitmodules; g -C "$T/wt" commit -qm base
ts="$T/wt/sub"; g clone -q "$TMP/remote.git" "$ts"
g -C "$ts" checkout -q -b side; echo one > "$ts/f"; g -C "$ts" commit -qam one; side=$(g -C "$ts" rev-parse HEAD)
g -C "$ts" checkout -q main
echo tagged > "$ts/f"; g -C "$ts" commit -qam tagged; g -C "$ts" tag -a -m release v1; tagged=$(g -C "$ts" rev-parse HEAD)
g -C "$ts" reset -q --hard origin/main
echo lost > "$ts/f"; g -C "$ts" commit -qam lost; lost=$(g -C "$ts" rev-parse HEAD)
g -C "$ts" reset -q --hard origin/main
echo aside > "$ts/f"; g -C "$ts" stash -q; stashed=$(g -C "$ts" rev-parse refs/stash)
g -C "$ts" config remote.origin.url 'git@github.com:devantler-tech/ksail.git'
commit_fix() { # sha nodes-json|null
  if [ "$2" = null ]; then printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":null}}}\n' > "$FIX/$1.json"
  else printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":1,"nodes":[%s]}}}}}\n' "$2" > "$FIX/$1.json"; fi
}
ref_fix() { printf '{"data":{"repository":{"ref":%s}}}\n' "$1" > "$FIX/ref-v1.json"; }
commit_fix "$side" "$(node 41 MERGED "$side")"
commit_fix "$lost" null
commit_fix "$tagged" "$(node 42 OPEN "$tagged")"
# GitHub answers an annotated tag with the tag object, and the commit below it.
ref_fix "{\"target\":{\"oid\":\"$OTHER\",\"target\":{\"oid\":\"$tagged\"}}}"
bash "$INVENTORY" "$T" --tips > "$TMP/tips.in"
tips_run() { : > "$CALLS"; OUT=$(PATH="$BIN:$PATH" bash "$SUT" "$T" < "${1:-$TMP/tips.in}" 2>"$TMP/err"); RC=$?; }
tip_of() { printf '%s\n' "$OUT" | awk -F'\t' -v t="tip=$1" '$1 == "TIP-CHECK" && $5 == t { print $4 " " $6 " " $9 }'; }
tip_is() { # name sha want
  local got; got=$(tip_of "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$got] rc=$RC out=$OUT err=$(cat "$TMP/err")"; fi
}
tips_run
tip_is 'a branch tip whose pull request merged is merged'        "$side"    'merged kind=branch pr=41'
tip_is 'a tag GitHub holds at that commit is pushed-ref'         "$tagged"  'pushed-ref kind=ref pr=-'
tip_is 'a commit only this machine has is not-on-github'         "$lost"    'not-on-github kind=reflog pr=-'
tip_is 'a stash is reported, never looked up'                    "$stashed" 'stash kind=stash pr=-'
check 'the stash never reached GitHub' eval '! grep -q "$stashed" "$CALLS"'
check 'the entry row still says its HEAD was not looked up' out_has '^MERGE-CHECK	wt	sub	not-checked	'
check 'the closing line totals the tips' out_has '	tips=4	tips_merged=1	tips_merged_ancestor=0	tips_pushed_ref=1	tips_unsettled=2	tips_other_classes=0$'
check 'and exits 0' rc_is 0

# The same tip, when its pull request moved on and merged with it in its history.
commit_fix "$side" "$(node 61 MERGED "$H1")"
printf '{"status":"ahead","behind_by":0,"ahead_by":2,"merge_base_commit":{"sha":"%s"}}\n' "$side" > "$FIX/cmp-$side-$H1.json"
tips_run
tip_is 'a branch tip in the history of a merged pull request is merged-ancestor' "$side" 'merged-ancestor kind=branch pr=61'
check 'the closing line counts it apart from merged' out_has '	tips_merged=0	tips_merged_ancestor=1	tips_pushed_ref=1	tips_unsettled=2	'
commit_fix "$side" "$(node 41 MERGED "$side")"; rm -f "$FIX/cmp-$side-$H1.json"

ref_fix "{\"target\":{\"oid\":\"$OTHER\"}}"; tips_run
tip_is 'a tag GitHub holds at ANOTHER commit falls back to the commit lookup' "$tagged" 'open kind=ref pr=42'
ref_fix null; tips_run
tip_is 'a tag GitHub does not have falls back to the commit lookup'           "$tagged" 'open kind=ref pr=42'
rm -f "$FIX/ref-v1.json"; tips_run
check 'a failed ref lookup is UNKNOWN, never pushed-ref' eval '[ -z "$(tip_of "$tagged")" ] && grep -q "^UNKNOWN	wt	sub	the ref lookup failed" <<<"$OUT" && [ "$RC" = 2 ]'
printf '{"data":{"repository":{}},"errors":[{"message":"x"}]}\n' > "$FIX/ref-v1.json"; tips_run
check 'a ref answer carrying errors is UNKNOWN' eval '[ -z "$(tip_of "$tagged")" ] && [ "$RC" = 2 ]'
ref_fix "{\"target\":{\"oid\":\"$tagged\"}}"
rm -f "$FIX/$lost.json"; tips_run
check 'a failed commit lookup for a tip is UNKNOWN' eval '[ -z "$(tip_of "$lost")" ] && grep -q "^UNKNOWN	wt	sub	the pull request lookup failed for a commit held away" <<<"$OUT" && [ "$RC" = 2 ]'
commit_fix "$lost" null

tips_bad() { # name sed-expression expected-stderr
  sed "$2" "$TMP/tips.in" > "$TMP/tips.bad"; tips_run "$TMP/tips.bad"
  if [ "$RC" = 2 ] && grep -q "$3" "$TMP/err"; then ok "$1"; else bad "$1" "rc=$RC out=$OUT err=$(cat "$TMP/err")"; fi
}
tips_bad 'a lost TIP row disagrees with the inventory total'      "/tip=$side/d" 'TIP rows read do not match'
tips_bad 'TIP rows without a tips total are refused'              's/	tips=4$//' 'without the inventory'
tips_bad 'a TIP row naming another entry is malformed'            "s/^TIP	wt	sub	tip=$side/TIP	wt	other	tip=$side/" 'malformed'
tips_bad 'a TIP row with an unknown kind is malformed'            's/kind=reflog/kind=surprise/' 'malformed'
tips_bad 'a TIP row with a short commit is malformed'             "s/tip=$lost/tip=abc123/" 'malformed'
{ grep -v '^TIP' "$TMP/tips.in" | sed 's/	tips=4$/	tips=0/'; } > "$TMP/tips.bad"; tips_run "$TMP/tips.bad"
check 'an entry holding such commits but naming none is incomplete' eval '[ "$RC" = 2 ] && grep -q "names none of them" "$TMP/err"'
sed "s/\(tip=$side.*\)commits=1/\1commits=5/" "$TMP/tips.in" > "$TMP/tips.bad"; tips_run "$TMP/tips.bad"
check 'a tip whose commit count no longer matches is UNKNOWN' eval '[ -z "$(tip_of "$side")" ] && grep -q "changed since the inventory" <<<"$OUT" && [ "$RC" = 2 ]'
# A TIP row before any entry describes nothing.
{ grep '^TIP' "$TMP/tips.in" | head -n 1; cat "$TMP/tips.in"; } | sed 's/	tips=4$/	tips=5/' > "$TMP/tips.bad"; tips_run "$TMP/tips.bad"
check 'a TIP row before any entry is malformed' eval '[ "$RC" = 2 ] && grep -q "malformed" "$TMP/err"'
# Tips of an entry in another class are counted, not looked up.
echo edit > "$ts/f.new"; bash "$INVENTORY" "$T" --tips > "$TMP/tips.other"; tips_run "$TMP/tips.other"
check 'tips of an untracked entry are counted, not looked up' eval 'grep -q "	tips=4	tips_merged=0	tips_merged_ancestor=0	tips_pushed_ref=0	tips_unsettled=0	tips_other_classes=4$" <<<"$OUT" && [ ! -s "$CALLS" ] && [ "$RC" = 0 ]'
rm -f "$ts/f.new"

echo "== content comparison with a reference checkout"
# UP stands for the repository on GitHub. REF is a checkout that fetched it recently; every
# entry under CR cloned it earlier and never fetched again, as a session's submodule does.
UP="$TMP/upstream"; REF="$TMP/reference"; CR="$TMP/content-root"
URL='git@github.com:devantler-tech/ksail.git'
g init -q -b main "$UP"
printf 'one\ntwo\nthree\n' > "$UP/f"; printf 'a\nb\nc\n' > "$UP/h"; printf '\000\001\002' > "$UP/bin"
g -C "$UP" add f h bin; g -C "$UP" commit -qm base
c_add() { # worktree -> a clone of UP as it is now, with the origin a submodule would have
  g init -q -b main "$CR/$1"
  printf '[submodule "s"]\n\tpath = sub\n\turl = https://example.invalid/s.git\n' > "$CR/$1/.gitmodules"
  g -C "$CR/$1" add .gitmodules; g -C "$CR/$1" commit -qm base
  g clone -q "$UP" "$CR/$1/sub"; g -C "$CR/$1/sub" config remote.origin.url "$URL"
}
for w in c-same c-moved c-differs c-space c-empty c-reached c-binary c-merged c-noref c-foreign c-nohead; do c_add "$w"; done
c_commit() { g -C "$CR/$1/sub" add -A; g -C "$CR/$1/sub" commit -qm "$2"; }
c_sha() { g -C "$CR/$1/sub" rev-parse HEAD; }
# c-same: two commits; the default branch gets their sum as one commit of its own.
printf 'one\nTWO\nthree\n' > "$CR/c-same/sub/f"; c_commit c-same 'first half'
echo new > "$CR/c-same/sub/added"; c_commit c-same 'second half'
# c-moved: one commit; the default branch gets it, then changes the same line again.
echo moved > "$CR/c-moved/sub/m"; printf 'a\nB\nc\n' > "$CR/c-moved/sub/h"; c_commit c-moved 'moved on'
echo unique > "$CR/c-differs/sub/u"; c_commit c-differs 'never merged'
# c-space: the default branch gets the same lines with other indentation.
printf 'x\n    y\n' > "$CR/c-space/sub/w"; c_commit c-space 'four spaces'
echo tmp > "$CR/c-empty/sub/t"; c_commit c-empty 'try'; rm "$CR/c-empty/sub/t"; c_commit c-empty 'undo'
echo reached > "$CR/c-reached/sub/r"; c_commit c-reached 'pushed straight to the default branch'
printf '\000\001\003' > "$CR/c-binary/sub/bin"; c_commit c-binary 'binary, one content'
echo merged > "$CR/c-merged/sub/x"; c_commit c-merged 'merged pull request'
for w in c-noref c-foreign c-nohead; do echo "$w" > "$CR/$w/sub/own"; c_commit "$w" "$w"; done
# The default branch moves on.
g -C "$UP" pull -q --ff-only "$CR/c-reached/sub" main
echo unrelated > "$UP/z"; g -C "$UP" add z; g -C "$UP" commit -qm 'unrelated'
printf 'x\n\ty\n' > "$UP/w"; g -C "$UP" add w; g -C "$UP" commit -qm 'the same lines, indented with a tab'
printf 'one\nTWO\nthree\n' > "$UP/f"; echo new > "$UP/added"; g -C "$UP" add -A; g -C "$UP" commit -qm 'squash of c-same'
same_as=$(g -C "$UP" rev-parse HEAD)
echo moved > "$UP/m"; printf 'a\nB\nc\n' > "$UP/h"; g -C "$UP" add -A; g -C "$UP" commit -qm 'squash of c-moved'
moved_as=$(g -C "$UP" rev-parse HEAD)
printf 'a\nB again\nc\n' > "$UP/h"; g -C "$UP" commit -qam 'the same line changes again'
printf '\000\001\004' > "$UP/bin"; g -C "$UP" commit -qam 'binary, another content'
mkdir -p "$REF"; g clone -q "$UP" "$REF/sub"; g -C "$REF/sub" config remote.origin.url "$URL"
ref_base=$(g -C "$REF/sub" rev-parse refs/remotes/origin/main)
nopr='{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":0,"nodes":[]}}}}}'
for w in c-same c-moved c-differs c-space c-empty c-reached c-binary c-noref c-foreign c-nohead; do printf '%s\n' "$nopr" > "$FIX/$(c_sha "$w").json"; done
printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":1,"nodes":[%s]}}}}}\n' \
  "$(node 51 MERGED "$(c_sha c-merged)")" > "$FIX/$(c_sha c-merged).json"

c_run() { # inventory-file [reference] -> OUT, RC
  : > "$CALLS"
  if [ $# -gt 1 ]; then OUT=$(PATH="$BIN:$PATH" bash "$SUT" "$CR" --content-reference "$2" < "$1" 2>"$TMP/err"); RC=$?
  else OUT=$(PATH="$BIN:$PATH" bash "$SUT" "$CR" < "$1" 2>"$TMP/err"); RC=$?; fi
}
content_of() { printf '%s\n' "$OUT" | awk -F'\t' -v w="$1" '$1 == "CONTENT-CHECK" && $2 == w { print $4 " " $5 " " $6 " " $7 }'; }
content_is() { # name worktree want
  local got; got=$(content_of "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$got] rc=$RC out=$OUT err=$(cat "$TMP/err")"; fi
}
objects_of() { find "$CR"/*/sub/.git "$REF/sub/.git" -type f -exec cksum {} + | LC_ALL=C sort | cksum; }
content_rows() { grep -E "^ENTRY	c-(same|moved|differs|space|empty|reached|binary|merged)	" "$TMP/content.all"; }
bash "$INVENTORY" "$CR" > "$TMP/content.all"
{ content_rows; } > "$TMP/content.in"; seal "$TMP/content.in"
before=$(objects_of)
c_run "$TMP/content.in" "$REF"
after=$(objects_of)
check 'the fixture inventory lists the eight compared entries' eval '[ "$(grep -c "^ENTRY" "$TMP/content.in")" = 8 ]'
content_is 'the sum of two commits merged as one is same-change'   c-same    "same-change commit=$(c_sha c-same) base=$ref_base same_as=$same_as"
content_is 'a change the default branch later built on is same-change' c-moved "same-change commit=$(c_sha c-moved) base=$ref_base same_as=$moved_as"
content_is 'a change the default branch never got differs'         c-differs "differs commit=$(c_sha c-differs) base=$ref_base same_as=-"
content_is 'a change that differs only in indentation differs'     c-space   "differs commit=$(c_sha c-space) base=$ref_base same_as=-"
content_is 'a commit that leaves the files as they were is no-change' c-empty "no-change commit=$(c_sha c-empty) base=$ref_base same_as=-"
content_is 'a commit the default branch contains is reached'       c-reached "reached commit=$(c_sha c-reached) base=$ref_base same_as=-"
content_is 'a binary file with other content differs'              c-binary  "differs commit=$(c_sha c-binary) base=$ref_base same_as=-"
content_is 'a merged entry is not compared'                        c-merged  ''
check 'the comparison keeps the pull-request verdicts' eval '[ "$(printf "%s\n" "$OUT" | grep -c "^MERGE-CHECK	c-.*	no-pr	")" = 7 ] && grep -q "^MERGE-CHECK	c-merged	sub	merged	" <<<"$OUT"'
check 'the closing line carries the content totals' eval 'grep -q "	content_reached=1	content_same_change=2	content_no_change=1	content_differs=3	content_no_reference=0$" <<<"$OUT" && [ "$RC" = 0 ]'
check 'the comparison writes to neither repository' [ "$before" = "$after" ]
c_run "$TMP/content.in"
check 'without a reference nothing is compared' eval '! grep -q "CONTENT-CHECK\|content_" <<<"$OUT" && [ "$RC" = 0 ]'

c_one() { # worktree -> an inventory holding that entry alone
  sed -n "/^ENTRY	$1	/p" "$TMP/content.all" > "$TMP/content.one"; seal "$TMP/content.one"
}
# The reference holds nothing at that path, or holds another repository there.
c_one c-noref; mkdir -p "$TMP/ref-empty"; c_run "$TMP/content.one" "$TMP/ref-empty"
content_is 'a reference without that repository is no-reference' c-noref "no-reference commit=$(c_sha c-noref) base=- same_as=-"
check 'no-reference is a verdict, not a failure' rc_is 0
mkdir -p "$TMP/ref-foreign"; g clone -q "$UP" "$TMP/ref-foreign/sub"
g -C "$TMP/ref-foreign/sub" config remote.origin.url 'git@github.com:devantler-tech/platform.git'
c_one c-foreign; c_run "$TMP/content.one" "$TMP/ref-foreign"
content_is 'a reference holding another repository there is no-reference' c-foreign "no-reference commit=$(c_sha c-foreign) base=- same_as=-"
mkdir -p "$TMP/ref-link"; ln -s "$REF/sub" "$TMP/ref-link/sub"
c_one c-differs; c_run "$TMP/content.one" "$TMP/ref-link"
content_is 'a reference reached through a symbolic link is not read' c-differs "no-reference commit=$(c_sha c-differs) base=- same_as=-"
# A reference whose default branch cannot be named is a failed read, never `differs`.
mkdir -p "$TMP/ref-nohead"; g clone -q "$UP" "$TMP/ref-nohead/sub"; g -C "$TMP/ref-nohead/sub" config remote.origin.url "$URL"
g -C "$TMP/ref-nohead/sub" symbolic-ref -d refs/remotes/origin/HEAD
c_one c-nohead; c_run "$TMP/content.one" "$TMP/ref-nohead"
check 'a reference with no default branch is UNKNOWN' eval '[ -z "$(content_of c-nohead)" ] && grep -q "^UNKNOWN	c-nohead	sub	cannot read the default branch in the reference checkout" <<<"$OUT" && [ "$RC" = 2 ]'
# A repository can configure programs for git to run while it prints commits and patches.
# None of them may run here: the comparison reads repositories other sessions own.
cat > "$BIN/ran" <<'RAN'
#!/usr/bin/env bash
: > "$RAN_MARK"
exit 1
RAN
chmod +x "$BIN/ran"; RAN_MARK="$TMP/ran.mark"; export RAN_MARK
printf '* diff=probe\n' > "$CR/c-same/sub/.git/info/attributes"
for kv in log.showSignature=true "gpg.program=$BIN/ran" "diff.external=$BIN/ran" "diff.probe.textconv=$BIN/ran" "diff.probe.command=$BIN/ran"; do
  g -C "$CR/c-same/sub" config "${kv%%=*}" "${kv#*=}"
done
c_one c-same; rm -f "$RAN_MARK"; c_run "$TMP/content.one" "$REF"
no_program_ran() { [ ! -e "$RAN_MARK" ] && [ "$(content_of c-same)" = "same-change commit=$(c_sha c-same) base=$ref_base same_as=$same_as" ] && [ "$RC" = 0 ]; }
check 'no program the repository configures is run' no_program_ran
for k in log.showSignature gpg.program diff.external diff.probe.textconv diff.probe.command; do g -C "$CR/c-same/sub" config --unset "$k"; done
rm -f "$CR/c-same/sub/.git/info/attributes"
# A patch read that fails must not read as `differs`.
c_one c-same
OUT=$(PATH="$BIN:$PATH" bash -c 'git() { case " $* " in *" patch-id "*) return 3 ;; esac; command git "$@"; }; export -f git; bash "$0" "$1" --content-reference "$2" < "$3"' "$SUT" "$CR" "$REF" "$TMP/content.one" 2>"$TMP/err"); RC=$?
check 'a failed patch read is UNKNOWN, never differs' eval '[ -z "$(content_of c-same)" ] && grep -q "^UNKNOWN	c-same	sub	cannot" <<<"$OUT" && [ "$RC" = 2 ]'
c_run "$TMP/content.in" "$TMP/no-such-reference"
check 'a missing reference directory is a usage error' eval '[ "$RC" = 2 ] && grep -q "not a directory" "$TMP/err"'
OUT=$(PATH="$BIN:$PATH" bash "$SUT" "$CR" --surprise "$REF" < "$TMP/content.in" 2>"$TMP/err"); RC=$?
check 'an unknown option is a usage error' eval '[ "$RC" = 2 ] && grep -q "usage:" "$TMP/err"'

# A commit held away from HEAD is compared the same way, after its own TIP-CHECK row.
CT="$TMP/content-tips"; g init -q -b main "$CT/wt"
printf '[submodule "s"]\n\tpath = sub\n\turl = https://example.invalid/s.git\n' > "$CT/wt/.gitmodules"
g -C "$CT/wt" add .gitmodules; g -C "$CT/wt" commit -qm base
g clone -q "$UP" "$CT/wt/sub"; g -C "$CT/wt/sub" reset -q --hard "$(g -C "$UP" rev-list --max-parents=0 HEAD)"
g -C "$CT/wt/sub" update-ref refs/remotes/origin/main HEAD
g -C "$CT/wt/sub" checkout -q -b side; echo unrelated > "$CT/wt/sub/z"; g -C "$CT/wt/sub" add z; g -C "$CT/wt/sub" commit -qm 'the same file, locally'
tip_sha=$(g -C "$CT/wt/sub" rev-parse HEAD); g -C "$CT/wt/sub" checkout -q main
g -C "$CT/wt/sub" config remote.origin.url "$URL"
printf '%s\n' "$nopr" > "$FIX/$tip_sha.json"
unrelated_as=$(g -C "$UP" log --format=%H --grep='^unrelated$' main)
# The clone's first HEAD stays in its reflog: a second held commit, which the reference has.
printf '%s\n' "$nopr" > "$FIX/$ref_base.json"
: > "$CALLS"
OUT=$(bash "$INVENTORY" "$CT" --tips | PATH="$BIN:$PATH" bash "$SUT" "$CT" --content-reference "$REF" 2>"$TMP/err"); RC=$?
want_tip="same-change commit=$tip_sha base=$ref_base same_as=$unrelated_as"
want_log="reached commit=$ref_base base=$ref_base same_as=-"
tip_content_ok() {
  grep -q "^TIP-CHECK	wt	sub	no-pr	tip=$tip_sha	kind=branch	" <<<"$OUT" || return 1
  [ "$(content_of wt | LC_ALL=C sort)" = "$(printf '%s\n%s\n' "$want_tip" "$want_log" | LC_ALL=C sort)" ] && [ "$RC" = 0 ]
}
check 'commits held away from HEAD are compared too' tip_content_ok

# An inventory that fails (a root with no worktree) must not read as an empty, clean result.
mkdir -p "$TMP/empty-root"
OUT=$(bash "$INVENTORY" "$TMP/empty-root" 2>/dev/null | PATH="$BIN:$PATH" bash "$SUT" "$TMP/empty-root" 2>"$TMP/err"); RC=$?
check 'a failed inventory behind a pipe is not a clean result' rc_is 2

printf '\n%s passed, %s failed\n' "$pass" "$fail"
test_run_completed=1
[ "$fail" -eq 0 ]
