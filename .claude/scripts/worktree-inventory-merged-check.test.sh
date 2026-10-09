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
set -euo pipefail
sha=''; name=''; owner=''; host=''; prev=''
for a in "$@"; do
  case "$a" in sha=*) sha=${a#sha=} ;; r=*) name=${a#r=} ;; o=*) owner=${a#o=} ;; esac
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
out_has() { printf '%s\n' "$OUT" | grep -q "$1"; }
no_verdict() { ! printf '%s\n' "$OUT" | grep -q '^MERGE-CHECK'; }
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

prs w-merged 1 "[$(node 11 MERGED "$(sha_of w-merged)")]"
prs w-open   1 "[$(node 12 OPEN "$(sha_of w-open)" main devantler-tech/platform)]"
prs w-closed 1 "[$(node 13 CLOSED "$(sha_of w-closed)")]"
prs w-other  1 "[$(node 14 MERGED "$OTHER")]"
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
  $'^CHECKED\tmerged=4\tmerged_other_base=2\topen=1\tclosed=1\tother_head=1\tno_pr=1\tnot_on_github=1\tnot_checked=0\tother_classes=0\tunknown=0$'
: > "$CALLS"
OUT=$(GH_HOST=ghe.example.invalid GH_REPO=someone/else PATH="$BIN:$PATH" bash "$SUT" "$ROOT" < "$TMP/in" 2>"$TMP/err"); RC=$?
if [ "$RC" = 0 ] && ! grep -qv ' github.com unset/unset$' "$CALLS"; then ok 'an inherited GH_HOST or GH_REPO is not honoured'
else bad 'an inherited GH_HOST or GH_REPO is not honoured' "rc=$RC $(head -2 "$CALLS")"; fi

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
# An inventory that fails (a root with no worktree) must not read as an empty, clean result.
mkdir -p "$TMP/empty-root"
OUT=$(bash "$INVENTORY" "$TMP/empty-root" 2>/dev/null | PATH="$BIN:$PATH" bash "$SUT" "$TMP/empty-root" 2>"$TMP/err"); RC=$?
check 'a failed inventory behind a pipe is not a clean result' rc_is 2

printf '\n%s passed, %s failed\n' "$pass" "$fail"
test_run_completed=1
[ "$fail" -eq 0 ]
