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
  $'^CHECKED\tmerged=4\tmerged_ancestor=0\tgithub_bot=0\tmerged_other_base=2\topen=1\tclosed=1\tother_head=1\tno_pr=1\tnot_on_github=1\tnot_checked=0\tother_classes=0\tunknown=0$'
: > "$CALLS"
OUT=$(GH_HOST=ghe.example.invalid GH_REPO=someone/else PATH="$BIN:$PATH" bash "$SUT" "$ROOT" < "$TMP/in" 2>"$TMP/err"); RC=$?
if [ "$RC" = 0 ] && ! grep -qv ' github.com unset/unset$' "$CALLS"; then ok 'an inherited GH_HOST or GH_REPO is not honoured'
else bad 'an inherited GH_HOST or GH_REPO is not honoured' "rc=$RC $(head -2 "$CALLS")"; fi

echo '== a commit in the history of a merged pull request'
# The pull request moved on from the commit and then merged: no pull request has the commit
# as its head, and only the comparison can say whether the head that merged contains it.
for w in w-anc w-anc-fail w-anc-odd w-anc-second w-anc-stacked w-anc-fork w-anc-open w-anc-badhead w-anc-ident w-anc-retry w-anc-unsure; do
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
cmp w-anc-second "$H2" ahead 0 "$(sha_of w-anc-second)"
prs w-anc-ident   1 "[$(node 60 MERGED "$H1")]"
cmp w-anc-ident "$H1" identical 0 "$(sha_of w-anc-ident)"
# w-anc-retry: the first comparison cannot be read, the second proves it.
prs w-anc-retry   2 "[$(node 62 MERGED "$H1"),$(node 63 MERGED "$H2")]"
cmp w-anc-retry "$H2" ahead 0 "$(sha_of w-anc-retry)"
# w-anc-unsure: the first comparison cannot be read, the second says no.
prs w-anc-unsure  2 "[$(node 64 MERGED "$H1"),$(node 65 MERGED "$H2")]"
cmp w-anc-unsure "$H2" diverged 3 "$OTHER"
prs w-anc-stacked 1 "[$(node 56 MERGED "$H1" feature-base)]"
prs w-anc-fork    1 "[$(node 57 MERGED "$H1" main someone-else/ksail)]"
prs w-anc-open    1 "[$(node 58 OPEN "$H1")]"
prs w-anc-badhead 1 "[$(node 59 MERGED 'main/../../x')]"
{ entry w-anc unpushed; entry w-anc-second unpushed; entry w-anc-stacked unpushed; entry w-anc-retry unpushed
  entry w-anc-fork unpushed; entry w-anc-open unpushed; entry w-other unpushed; } > "$TMP/in"; seal "$TMP/in"
run < "$TMP/in"
expect 'an ancestor of the head that merged is merged-ancestor'      w-anc         'merged-ancestor pr=51 other_local=0'
expect 'the pull request that proves it is the one named'            w-anc-second  'merged-ancestor pr=55 other_local=0'
expect 'an unreadable comparison does not hide a later one that proves it' w-anc-retry 'merged-ancestor pr=63 other_local=0'
expect 'a pull request merged into another branch proves nothing'    w-anc-stacked 'other-head pr=56 other_local=0'
expect "a pull request merged into a fork proves nothing"            w-anc-fork    'other-head pr=57 other_local=0'
expect 'an open pull request at another head proves nothing'         w-anc-open    'other-head pr=58 other_local=0'
expect 'a head that merged WITHOUT the commit stays other-head'      w-other       'other-head pr=14 other_local=0'
check 'every entry answered: exit 0' rc_is 0
check 'the comparison names this commit and the head that merged' \
  grep -q "^devantler-tech/ksail cmp-$(sha_of w-anc)-$H1 github.com " "$CALLS"
check 'no comparison is made for a pull request that could not prove it' eval \
  '! grep -q "cmp-$(sha_of w-anc-stacked)-\|cmp-$(sha_of w-anc-fork)-\|cmp-$(sha_of w-anc-open)-" "$CALLS"'
check 'the closing line counts them apart from merged' out_has $'^CHECKED\tmerged=0\tmerged_ancestor=3\tgithub_bot=0\tmerged_other_base=0\topen=0\tclosed=0\tother_head=4\t'
anc_unknown() { # name worktree
  { entry "$2" unpushed; } > "$TMP/in"; seal "$TMP/in"
  run < "$TMP/in"
  if [ "$RC" = 2 ] && out_has "^UNKNOWN	$2	sub	the pull request lookup failed$" && [ -z "$(verdict_of "$2")" ]; then
    ok "$1"; else bad "$1" "rc=$RC out=$OUT"; fi
}
anc_unknown 'a comparison that failed is UNKNOWN, never other-head or merged-ancestor' w-anc-fail
anc_unknown 'an answer whose merge base is another commit but claims no divergence'    w-anc-odd
anc_unknown 'identical is never proof: the head that merged cannot be this commit'            w-anc-ident
anc_unknown 'an unreadable comparison beside one that says no is UNKNOWN, not other-head' w-anc-unsure
anc_unknown 'a head that is not a commit id is never put in a request'                 w-anc-badhead
check 'and no comparison was sent for it' eval '! grep -q " cmp-" "$CALLS"'
printf '{"status":"ahead","behind_by":0}\n' > "$FIX/cmp-$(sha_of w-anc-fail)-$H1.json"
anc_unknown 'an answer with no merge base' w-anc-fail
printf '{"message":"Not Found"}\n' > "$FIX/cmp-$(sha_of w-anc-fail)-$H1.json"
anc_unknown 'an error body' w-anc-fail
cmp w-anc-fail "$H1" behind 0 "$OTHER"
anc_unknown 'an answer that is behind by nothing' w-anc-fail

echo '== a commit a bot made on GitHub'
# GitHub signed the commit for a bot, its only author: it was never made on this machine.
# Every other shape (a local signature, a person, a second author, a name that only looks
# like a bot's) must stay what it was without the rule.
botfix() { # sha total nodes-json [login|null] [signed-by-github] [valid] [authors]
  local user="{\"login\":\"${4:-renovate[bot]}\"}"
  [ "${4:-}" != null ] || user=null
  printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","author":{"user":%s},"authors":{"totalCount":%s},"signature":{"isValid":%s,"wasSignedByGitHub":%s},"associatedPullRequests":{"totalCount":%s,"nodes":%s}}}}}\n' \
    "$user" "${7:-1}" "${6:-true}" "${5:-true}" "$2" "$3" > "$FIX/$1.json"
}
bot() { local w=$1; shift; botfix "$(sha_of "$w")" "$@"; }
for w in w-bot w-bot-dep w-bot-pr w-bot-anc w-bot-ancfail w-bot-head w-bot-local w-bot-invalid w-bot-person \
         w-bot-nouser w-bot-two w-bot-alike w-bot-string w-bot-nosig w-bot-range w-bot-mixed w-bot-rfail w-bot-long; do
  add_sub "$w" 'git@github.com:devantler-tech/ksail.git'
done
bot w-bot         0 '[]'
bot w-bot-dep     0 '[]' 'dependabot[bot]'
bot w-bot-pr      1 "[$(node 81 OPEN "$H1")]"
bot w-bot-anc     1 "[$(node 82 MERGED "$H1")]"
cmp w-bot-anc "$H1" ahead 0 "$(sha_of w-bot-anc)"
bot w-bot-ancfail 1 "[$(node 83 MERGED "$H1")]"
bot w-bot-head    1 "[$(node 84 CLOSED "$(sha_of w-bot-head)")]"
bot w-bot-local   0 '[]' 'renovate[bot]' false
bot w-bot-invalid 0 '[]' 'renovate[bot]' true false
bot w-bot-person  0 '[]' 'devantler'
bot w-bot-nouser  0 '[]' null
bot w-bot-two     0 '[]' 'renovate[bot]' true true 2
bot w-bot-alike   0 '[]' 'renovate[bot]-evil'
bot w-bot-string  0 '[]' 'renovate[bot]' '"true"' '"true"'
printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","author":{"user":{"login":"renovate[bot]"}},"authors":{"totalCount":1},"signature":null,"associatedPullRequests":{"totalCount":0,"nodes":[]}}}}}\n' \
  > "$FIX/$(sha_of w-bot-nosig).json"
{ for w in w-bot w-bot-dep w-bot-pr w-bot-anc w-bot-ancfail w-bot-head w-bot-local w-bot-invalid w-bot-person \
           w-bot-nouser w-bot-two w-bot-alike w-bot-string w-bot-nosig; do entry "$w" unpushed; done; } > "$TMP/in"; seal "$TMP/in"
run < "$TMP/in"
expect 'a commit GitHub signed for a bot is github-bot'                 w-bot         'github-bot pr=- other_local=0'
expect 'each bot that works here counts'                                w-bot-dep     'github-bot pr=- other_local=0'
expect 'a pull request that moved on from it is named'                  w-bot-pr      'github-bot pr=81 other_local=0'
expect 'proof that it merged still wins over the weaker verdict'        w-bot-anc     'merged-ancestor pr=82 other_local=0'
expect 'an unreadable comparison leaves what is known: a bot made it'   w-bot-ancfail 'github-bot pr=83 other_local=0'
expect 'a pull request with this head keeps its own verdict'            w-bot-head    'closed pr=84 other_local=0'
expect 'a signature GitHub did not make proves nothing'                 w-bot-local   'no-pr pr=- other_local=0'
expect 'an invalid signature proves nothing'                            w-bot-invalid 'no-pr pr=- other_local=0'
expect 'a person GitHub signed for is not a bot'                        w-bot-person  'no-pr pr=- other_local=0'
expect 'an author GitHub cannot name is not a bot'                      w-bot-nouser  'no-pr pr=- other_local=0'
expect 'a second author means someone else had a hand in it'            w-bot-two     'no-pr pr=- other_local=0'
expect "a login that only starts like a bot's is not that bot"          w-bot-alike   'no-pr pr=- other_local=0'
expect 'a signature answer of another type is not a yes'                w-bot-string  'no-pr pr=- other_local=0'
expect 'no signature at all proves nothing'                             w-bot-nosig   'no-pr pr=- other_local=0'
check 'every entry answered: exit 0' rc_is 0
check 'the closing line counts them apart from merged' out_has $'^CHECKED\tmerged=0\tmerged_ancestor=1\tgithub_bot=4\tmerged_other_base=0\topen=0\tclosed=1\tother_head=0\tno_pr=8\t'

# The entry holds more unpushed commits below the bot's: each needs its own answer.
below() { # worktree count -> adds that many commits; prints nothing
  local i; for i in $(seq 1 "$2"); do echo "$1 $i" > "$ROOT/$1/sub/f"; g -C "$ROOT/$1/sub" commit -qam "more $i"; done
}
parent_of() { g -C "$ROOT/$1/sub" rev-parse HEAD~1; }
for w in w-bot-range w-bot-mixed w-bot-rfail; do below "$w" 1; bot "$w" 0 '[]'; done
below w-bot-long 11; bot w-bot-long 0 '[]'
botfix "$(parent_of w-bot-range)" 0 '[]'
botfix "$(parent_of w-bot-mixed)" 0 '[]' 'devantler'
{ entry w-bot-range unpushed 2 2; entry w-bot-mixed unpushed 2 2; entry w-bot-long unpushed 12 12; } > "$TMP/in"; seal "$TMP/in"
run < "$TMP/in"
expect 'bot commits all the way down are github-bot'                    w-bot-range 'github-bot pr=- other_local=0'
expect "a person's commit below the bot's keeps the entry unsettled"    w-bot-mixed 'no-pr pr=- other_local=0'
expect 'a range too long to walk is not settled on a guess'             w-bot-long  'no-pr pr=- other_local=0'
check 'every entry answered: exit 0' rc_is 0
check 'the commit below was asked about' grep -q "^devantler-tech/ksail $(parent_of w-bot-range) " "$CALLS"
check 'the long range was not walked' eval '[ "$(grep -c "^devantler-tech/ksail " "$CALLS")" = 5 ]'
{ entry w-bot-rfail unpushed 2 2; } > "$TMP/in"; seal "$TMP/in"
run < "$TMP/in"
check 'a commit below that cannot be read is UNKNOWN, never github-bot' eval \
  '[ "$RC" = 2 ] && out_has "^UNKNOWN	w-bot-rfail	sub	the pull request lookup failed$" && [ -z "$(verdict_of w-bot-rfail)" ]'

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
check 'the closing line totals the tips' out_has '	tips=4	tips_merged=1	tips_merged_ancestor=0	tips_github_bot=0	tips_pushed_ref=1	tips_unsettled=2	tips_other_classes=0$'
check 'and exits 0' rc_is 0

# The same tip, when its pull request moved on and merged with it in its history.
commit_fix "$side" "$(node 61 MERGED "$H1")"
printf '{"status":"ahead","behind_by":0,"ahead_by":2,"merge_base_commit":{"sha":"%s"}}\n' "$side" > "$FIX/cmp-$side-$H1.json"
tips_run
tip_is 'a branch tip in the history of a merged pull request is merged-ancestor' "$side" 'merged-ancestor kind=branch pr=61'
check 'the closing line counts it apart from merged' out_has '	tips_merged=0	tips_merged_ancestor=1	tips_github_bot=0	tips_pushed_ref=1	tips_unsettled=2	'
commit_fix "$side" "$(node 41 MERGED "$side")"; rm -f "$FIX/cmp-$side-$H1.json"
# The same tip, when a bot made it on GitHub and no pull request holds it any more.
printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","author":{"user":{"login":"ksail-bot[bot]"}},"authors":{"totalCount":1},"signature":{"isValid":true,"wasSignedByGitHub":true},"associatedPullRequests":{"totalCount":0,"nodes":[]}}}}}\n' > "$FIX/$side.json"
tips_run
tip_is 'a branch tip a bot made on GitHub is github-bot' "$side" 'github-bot kind=branch pr=-'
check 'the closing line counts it apart from merged and unsettled' out_has '	tips_merged=0	tips_merged_ancestor=0	tips_github_bot=1	tips_pushed_ref=1	tips_unsettled=2	'
commit_fix "$side" "$(node 41 MERGED "$side")"

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
check 'tips of an untracked entry are counted, not looked up' eval 'grep -q "	tips=4	tips_merged=0	tips_merged_ancestor=0	tips_github_bot=0	tips_pushed_ref=0	tips_unsettled=0	tips_other_classes=4$" <<<"$OUT" && [ ! -s "$CALLS" ] && [ "$RC" = 0 ]'
rm -f "$ts/f.new"
# One of the entry's OWN worktrees, holding no file of its own, is not a change (monorepo#4085).
g -C "$ts" worktree add -q --detach "$ts/.claude/worktrees/w" origin/main
bash "$INVENTORY" "$T" --tips > "$TMP/tips.own"; tips_run "$TMP/tips.own"
check 'an own worktree holding no file leaves the entry checked' eval 'grep -q "^MERGE-CHECK	wt	sub	not-checked	" <<<"$OUT" && ! grep -q "^UNKNOWN" <<<"$OUT" && grep -q "	tips=4	tips_merged=1	" <<<"$OUT" && [ "$RC" = 0 ]'
echo new > "$ts/.claude/worktrees/w/new.txt"; tips_run "$TMP/tips.own"
check 'a file added to an own worktree since the inventory is UNKNOWN' eval 'grep -q "^UNKNOWN	wt	sub	it changed since the inventory" <<<"$OUT" && [ "$RC" = 2 ]'
rm -f "$ts/.claude/worktrees/w/new.txt"; echo edit > "$ts/.claude/worktrees/w/f"; tips_run "$TMP/tips.own"
check 'a file edited in an own worktree since the inventory is UNKNOWN' eval 'grep -q "^UNKNOWN	wt	sub	it changed since the inventory" <<<"$OUT" && [ "$RC" = 2 ]'
g -C "$ts" worktree remove --force "$ts/.claude/worktrees/w"
# Another repository in the same place is a change, however clean it is.
g clone -q "$TMP/remote.git" "$TMP/tips-foreign"; g -C "$TMP/tips-foreign" worktree add -q --detach "$ts/.claude/worktrees/w"
tips_run "$TMP/tips.own"
check 'another repository where the own worktree stood is UNKNOWN' eval 'grep -q "^UNKNOWN	wt	sub	it changed since the inventory" <<<"$OUT" && [ "$RC" = 2 ]'
g -C "$TMP/tips-foreign" worktree remove --force "$ts/.claude/worktrees/w"; rm -rf "$ts/.claude"

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
# Merge commits (c-cm*): each merges a local commit with the commit c-reached pushed.
# c-cm: both sides merge cleanly. c-cmopen: the same, but no pull request has the local
# side. c-cmhand: both sides add the same file, resolved by hand. c-cmevil: a clean merge
# with one more file added in the merge commit itself.
for w in c-cm c-cmopen c-cmhand c-cmevil; do
  c_add "$w"; g -C "$CR/$w/sub" fetch -q "$CR/c-reached/sub" main
done
cm_merge() { g -C "$CR/$1/sub" merge -q --no-ff --no-edit FETCH_HEAD; }
for w in c-cm c-cmopen c-cmevil; do echo "$w" > "$CR/$w/sub/side"; c_commit "$w" 'local side'; done
cm_side=$(c_sha c-cm); cmopen_side=$(c_sha c-cmopen); cmevil_side=$(c_sha c-cmevil)
cm_merge c-cm; cm_merge c-cmopen
g -C "$CR/c-cmevil/sub" merge -q --no-ff --no-commit FETCH_HEAD; echo extra > "$CR/c-cmevil/sub/extra"; c_commit c-cmevil 'merge, with one more file'
echo mine > "$CR/c-cmhand/sub/r"; c_commit c-cmhand 'the same file, other content'; cmhand_side=$(c_sha c-cmhand)
g -C "$CR/c-cmhand/sub" merge -q --no-ff --no-commit FETCH_HEAD >/dev/null 2>&1 || true
echo both > "$CR/c-cmhand/sub/r"; c_commit c-cmhand 'merge, resolved by hand'
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
for w in c-cm c-cmopen c-cmhand c-cmevil; do printf '%s\n' "$nopr" > "$FIX/$(c_sha "$w").json"; done
printf '%s\n' "$nopr" > "$FIX/$cmopen_side.json"
cm_pr() { # side-sha pr-number -> a pull request with that head was merged
  printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":1,"nodes":[%s]}}}}}\n' \
    "$(node "$2" MERGED "$1")" > "$FIX/$1.json"
}
cm_pr "$cm_side" 52; cm_pr "$cmhand_side" 53; cm_pr "$cmevil_side" 54

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
check 'the closing line carries the content totals' eval 'grep -q "	content_reached=1	content_same_change=2	content_no_change=1	content_clean_merge=0	content_differs=3	content_no_reference=0	files_same_as_default=0	files_default_ignores=0	files_differ=0	files_no_reference=0$" <<<"$OUT" && [ "$RC" = 0 ]'
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

echo "== a merge commit that adds no change of its own"
before=$(objects_of)
c_one c-cm; c_run "$TMP/content.one" "$REF"
after=$(objects_of)
content_is 'a clean merge of a merged commit and the default branch is clean-merge' c-cm "clean-merge commit=$(c_sha c-cm) base=$ref_base same_as=-"
check 'the closing line counts the clean merge' eval 'grep -q "	content_no_change=0	content_clean_merge=1	content_differs=0	" <<<"$OUT" && [ "$RC" = 0 ]'
check 'making the merge again writes to neither repository' [ "$before" = "$after" ]
check 'the parent on the default branch is not looked up' eval '[ "$(grep -c . "$CALLS")" = 2 ]'
c_one c-cmopen; c_run "$TMP/content.one" "$REF"
content_is 'a clean merge with a parent nothing settles differs' c-cmopen "differs commit=$(c_sha c-cmopen) base=$ref_base same_as=-"
c_one c-cmhand; c_run "$TMP/content.one" "$REF"
content_is 'a merge resolved by hand differs' c-cmhand "differs commit=$(c_sha c-cmhand) base=$ref_base same_as=-"
c_one c-cmevil; c_run "$TMP/content.one" "$REF"
content_is 'a merge commit that adds a file of its own differs' c-cmevil "differs commit=$(c_sha c-cmevil) base=$ref_base same_as=-"
# A merge driver is a program the repository configures: no merge is made where one is set.
printf '* merge=probe\n' > "$CR/c-cm/sub/.git/info/attributes"
g -C "$CR/c-cm/sub" config merge.probe.driver "$BIN/ran"
c_one c-cm; rm -f "$RAN_MARK"; c_run "$TMP/content.one" "$REF"
cm_no_driver() { [ ! -e "$RAN_MARK" ] && [ "$(content_of c-cm)" = "differs commit=$(c_sha c-cm) base=$ref_base same_as=-" ] && [ "$RC" = 0 ]; }
check 'a configured merge driver is never run, and the merge stays differs' cm_no_driver
g -C "$CR/c-cm/sub" config --unset merge.probe.driver; rm -f "$CR/c-cm/sub/.git/info/attributes"
# A merge that cannot be made again is a failed read, never `differs` or `clean-merge`.
c_one c-cm
OUT=$(PATH="$BIN:$PATH" bash -c 'git() { case " $* " in *" merge-tree "*) return 3 ;; esac; command git "$@"; }; export -f git; bash "$0" "$1" --content-reference "$2" < "$3"' "$SUT" "$CR" "$REF" "$TMP/content.one" 2>"$TMP/err"); RC=$?
check 'a failed merge read is UNKNOWN' eval '[ -z "$(content_of c-cm)" ] && grep -q "^UNKNOWN	c-cm	sub	cannot read a merge commit" <<<"$OUT" && [ "$RC" = 2 ]'
# The lookup of a parent that fails must not read as an unsettled parent.
c_one c-cm; mv "$FIX/$cm_side.json" "$TMP/cm-side.json"; c_run "$TMP/content.one" "$REF"
check 'a failed parent lookup is UNKNOWN' eval '[ -z "$(content_of c-cm)" ] && grep -q "^UNKNOWN	c-cm	sub	cannot read a merge commit" <<<"$OUT" && [ "$RC" = 2 ]'
mv "$TMP/cm-side.json" "$FIX/$cm_side.json"

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

echo "== untracked files compared with the default branch"
# Each entry under FR is a clone that stopped at the default branch's first commit, as a
# session's submodule stops at an old pin. The reference has moved on and now tracks `z`
# (unrelated), `added` (new) and more: a copy of one of those here is an untracked file.
FR="$TMP/file-root"
root_sha=$(g -C "$UP" rev-list --max-parents=0 HEAD)
f_add() { # worktree
  g init -q -b main "$FR/$1"
  printf '[submodule "s"]\n\tpath = sub\n\turl = https://example.invalid/s.git\n' > "$FR/$1/.gitmodules"
  g -C "$FR/$1" add .gitmodules; g -C "$FR/$1" commit -qm base
  g clone -q "$UP" "$FR/$1/sub"; g -C "$FR/$1/sub" reset -q --hard "$root_sha"
  g -C "$FR/$1/sub" update-ref refs/remotes/origin/main "$root_sha"
  # The clone's first HEAD would otherwise stay behind as a commit held in the reflog.
  g -C "$FR/$1/sub" reflog expire --expire=all --all
  g -C "$FR/$1/sub" config remote.origin.url "$URL"
}
for w in f-copy f-part f-other f-link f-filter f-many f-tip f-head f-open; do f_add "$w"; done
echo unrelated > "$FR/f-copy/sub/z"; echo new > "$FR/f-copy/sub/added"
echo unrelated > "$FR/f-part/sub/z"; echo mine > "$FR/f-part/sub/only-here"
echo 'not the same' > "$FR/f-other/sub/z"
echo unrelated > "$TMP/z-target"; ln -s "$TMP/z-target" "$FR/f-link/sub/z"
echo unrelated > "$FR/f-filter/sub/z"
# One file more than is compared, among them a real copy.
echo unrelated > "$FR/f-many/sub/z"
i=0; while [ "$i" -lt 200 ]; do echo x > "$FR/f-many/sub/extra-$i"; i=$((i+1)); done
# f-tip: a copy beside a commit on another local branch. f-head, f-open: beside an unpushed HEAD.
g -C "$FR/f-tip/sub" checkout -q -b side; echo side > "$FR/f-tip/sub/s"; g -C "$FR/f-tip/sub" add s; g -C "$FR/f-tip/sub" commit -qm side
f_tip=$(g -C "$FR/f-tip/sub" rev-parse HEAD); g -C "$FR/f-tip/sub" checkout -q main
echo unrelated > "$FR/f-tip/sub/z"
for w in f-head f-open; do
  echo "$w" > "$FR/$w/sub/own"; g -C "$FR/$w/sub" add own; g -C "$FR/$w/sub" commit -qm "$w"
  echo unrelated > "$FR/$w/sub/z"
done
f_sha() { g -C "$FR/$1/sub" rev-parse HEAD; }
cm_pr "$f_tip" 61; cm_pr "$(f_sha f-head)" 62
printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":1,"nodes":[%s]}}}}}\n' \
  "$(node 63 OPEN "$(f_sha f-open)")" > "$FIX/$(f_sha f-open).json"

f_run() { # inventory-file [reference] -> OUT, RC
  : > "$CALLS"
  if [ $# -gt 1 ]; then OUT=$(PATH="$BIN:$PATH" bash "$SUT" "$FR" --content-reference "$2" < "$1" 2>"$TMP/err"); RC=$?
  else OUT=$(PATH="$BIN:$PATH" bash "$SUT" "$FR" < "$1" 2>"$TMP/err"); RC=$?; fi
}
file_of() { printf '%s\n' "$OUT" | awk -F'\t' -v w="$1" '$1 == "FILE-CHECK" && $2 == w { print $4 " " $5 " " $6 " " $7 " " $8 }'; }
file_is() { # name worktree want
  local got; got=$(file_of "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$got] rc=$RC out=$OUT err=$(cat "$TMP/err")"; fi
}
f_objects() { find "$FR"/*/sub/.git "$REF/sub/.git" -type f -exec cksum {} + | LC_ALL=C sort | cksum; }
bash "$INVENTORY" "$FR" --tips > "$TMP/files.all"
check 'the fixture inventory reads all nine entries as untracked' eval '[ "$(grep -c "^ENTRY	f-[a-z]*	sub	untracked	" "$TMP/files.all")" = 9 ]'
# A clean filter is a program the repository configures: hashing must not run it. It is
# set after the inventory, which reads an entry whose filter fails as unreadable.
printf 'z filter=probe\n' > "$FR/f-filter/sub/.git/info/attributes"
g -C "$FR/f-filter/sub" config filter.probe.clean "$BIN/ran"
rm -f "$RAN_MARK"; before=$(f_objects)
f_run "$TMP/files.all" "$REF"
after=$(f_objects)
file_is 'copies of files the default branch holds are same-as-default' f-copy "same-as-default files=2 same=2 default_ignores=0 base=$ref_base"
file_is 'one file the default branch does not hold differs'            f-part "differs files=2 same=1 default_ignores=0 base=$ref_base"
file_is 'a file with other content than the default branch differs'    f-other "differs files=1 same=0 default_ignores=0 base=$ref_base"
file_is 'a symbolic link to a copy is not a copy'                      f-link "differs files=1 same=0 default_ignores=0 base=$ref_base"
file_is 'a file is hashed as it is on disk'                            f-filter "same-as-default files=1 same=1 default_ignores=0 base=$ref_base"
check 'the clean filter the repository configures is never run' [ ! -e "$RAN_MARK" ]
file_is 'more files than are compared differ, copy or not'             f-many "differs files=201 same=0 default_ignores=0 base=$ref_base"
check 'an entry holding files only gets no commit verdict' eval '! grep -qE "^MERGE-CHECK	f-(copy|part|other|link|filter|many)	" <<<"$OUT"'
file_is 'a copy beside a held commit is still compared'                f-tip "same-as-default files=1 same=1 default_ignores=0 base=$ref_base"
f_tip_ok() {
  grep -q "^MERGE-CHECK	f-tip	sub	not-checked	head=$root_sha	repo=-	pr=-	other_local=1$" <<<"$OUT" || return 1
  grep -q "^TIP-CHECK	f-tip	sub	merged	tip=$f_tip	kind=branch	ref=side	repo=devantler-tech/ksail	pr=61	commits=1$" <<<"$OUT"
}
check 'the commit it holds away from HEAD is looked up' f_tip_ok
check 'an unpushed HEAD beside a copy is looked up' eval 'grep -q "^MERGE-CHECK	f-head	sub	merged	head=$(f_sha f-head)	repo=devantler-tech/ksail	pr=62	other_local=0$" <<<"$OUT"'
check 'an open pull request beside a copy stays open' eval 'grep -q "^MERGE-CHECK	f-open	sub	open	head=$(f_sha f-open)	repo=devantler-tech/ksail	pr=63	other_local=0$" <<<"$OUT"'
check 'each FILE-CHECK row comes before its entry'"'"'s commit rows' eval '[ "$(grep -n "^FILE-CHECK	f-tip	" <<<"$OUT" | cut -d: -f1)" -lt "$(grep -n "^MERGE-CHECK	f-tip	" <<<"$OUT" | cut -d: -f1)" ]'
check 'the closing line carries the file totals' eval 'grep -q "	files_same_as_default=5	files_default_ignores=0	files_differ=4	files_no_reference=0$" <<<"$OUT" && [ "$RC" = 0 ]'
check 'only the three commits are looked up' eval '[ "$(grep -c . "$CALLS")" = 3 ]'
check 'the file comparison writes to neither repository' [ "$before" = "$after" ]
check 'the classification joins the two texts' eval '[ "$(printf "%s\n" "$OUT" | bash "$SCRIPT_DIR/worktree-inventory-classify.sh" --inventory "$TMP/files.all" | awk -F"\t" "\$1 == \"CLASS\" { printf \"%s=%s \", \$2, \$4 }")" = "f-copy=merged-in-content f-filter=merged-in-content f-head=merged-in-content f-link=needs-a-person f-many=needs-a-person f-open=work-in-flight f-other=needs-a-person f-part=needs-a-person f-tip=merged-in-content " ]'

f_run "$TMP/files.all"
check 'without a reference no file is compared and no commit looked up' eval '! grep -qE "FILE-CHECK|files_|^MERGE-CHECK" <<<"$OUT" && [ ! -s "$CALLS" ] && [ "$RC" = 0 ]'

f_one() { # worktree -> an inventory holding that entry alone, with its TIP rows
  grep "^[A-Z]*	$1	" "$TMP/files.all" > "$TMP/files.one"
  awk -F'\t' '$1 == "ENTRY" { e++; if ($4 == "unpushed") u++; if ($4 == "local-only") l++ } $1 == "TIP" { t++ }
    END { printf "CHECKED\tworktrees=1\tentries=%d\tunpushed=%d\tlocal_only=%d\tbelow_min_idle=0\tunreadable=0\ttips=%d\n", e, u, l, t }' "$TMP/files.one" >> "$TMP/files.one"
}
f_one f-copy; f_run "$TMP/files.one" "$TMP/ref-empty"
file_is 'a reference without that repository is no-reference for files too' f-copy "no-reference files=2 same=0 default_ignores=0 base=-"
check 'no-reference for files is a verdict, not a failure' rc_is 0
f_one f-copy; f_run "$TMP/files.one" "$TMP/ref-foreign"
file_is 'a reference holding another repository compares no file' f-copy "no-reference files=2 same=0 default_ignores=0 base=-"
# A failed read is never `differs` or `same-as-default`.
f_one f-copy
OUT=$(PATH="$BIN:$PATH" bash -c 'git() { case " $* " in *" hash-object "*) return 3 ;; esac; command git "$@"; }; export -f git; bash "$0" "$1" --content-reference "$2" < "$3"' "$SUT" "$FR" "$REF" "$TMP/files.one" 2>"$TMP/err"); RC=$?
check 'a file that cannot be hashed is UNKNOWN' eval '[ -z "$(file_of f-copy)" ] && grep -q "^UNKNOWN	f-copy	sub	cannot read an untracked file" <<<"$OUT" && [ "$RC" = 2 ]'
OUT=$(PATH="$BIN:$PATH" bash -c 'git() { case " $* " in *" ls-tree "*) return 3 ;; esac; command git "$@"; }; export -f git; bash "$0" "$1" --content-reference "$2" < "$3"' "$SUT" "$FR" "$REF" "$TMP/files.one" 2>"$TMP/err"); RC=$?
check 'a default branch that cannot be read is UNKNOWN' eval '[ -z "$(file_of f-copy)" ] && grep -q "^UNKNOWN	f-copy	sub	cannot read a file of the default branch" <<<"$OUT" && [ "$RC" = 2 ]'
# The entry changed after the inventory read it: nothing is claimed.
echo later > "$FR/f-copy/sub/later"; f_run "$TMP/files.one" "$REF"
check 'one more untracked file than the row counts is UNKNOWN' eval '[ -z "$(file_of f-copy)" ] && grep -q "^UNKNOWN	f-copy	sub	it changed since the inventory" <<<"$OUT" && [ "$RC" = 2 ]'
rm -f "$FR/f-copy/sub/later"; echo edited >> "$FR/f-copy/sub/f"; rm -f "$FR/f-copy/sub/added"; f_run "$TMP/files.one" "$REF"
check 'a changed tracked file in place of an untracked one is UNKNOWN' eval '[ -z "$(file_of f-copy)" ] && grep -q "^UNKNOWN	f-copy	sub	it changed since the inventory" <<<"$OUT" && [ "$RC" = 2 ]'
g -C "$FR/f-copy/sub" checkout -q -- f; echo new > "$FR/f-copy/sub/added"
sed 's/	untracked=2	/	untracked=x	/' "$TMP/files.one" > "$TMP/files.bad"; f_run "$TMP/files.bad" "$REF"
check 'a row without an untracked file count is UNKNOWN' eval '[ -z "$(file_of f-copy)" ] && grep -q "^UNKNOWN	f-copy	sub	the row carries no untracked file count" <<<"$OUT" && [ "$RC" = 2 ]'
# The tip of an untracked entry is held to the same checks as any other tip.
f_one f-tip; mv "$FIX/$f_tip.json" "$TMP/f-tip.json"; f_run "$TMP/files.one" "$REF"
check 'a failed lookup of a commit beside copies is UNKNOWN' eval 'grep -q "^UNKNOWN	f-tip	sub	the pull request lookup failed for a commit held away from HEAD" <<<"$OUT" && ! grep -q "^TIP-CHECK" <<<"$OUT" && [ "$RC" = 2 ]'
mv "$TMP/f-tip.json" "$FIX/$f_tip.json"

echo "== untracked files the default branch ignores"
# The default branch gains ignore rules after the entries stopped at its first commit, and
# tracks one file its own rules cover. Entries under IR hold files those rules speak about.
printf '*.log\ncache/\n!keep.log\n' > "$UP/.gitignore"
mkdir -p "$UP/deep"; printf '*.tmp\n' > "$UP/deep/.gitignore"
echo tracked > "$UP/tracked.log"
g -C "$UP" add .gitignore deep/.gitignore; g -C "$UP" add -f tracked.log; g -C "$UP" commit -qm 'ignore rules'
IREF="$TMP/reference-ignores"
mkdir -p "$IREF"; g clone -q "$UP" "$IREF/sub"; g -C "$IREF/sub" config remote.origin.url "$URL"
iref_base=$(g -C "$IREF/sub" rev-parse refs/remotes/origin/main)
# The reference's working files and its own exclude file are not the default branch's rules.
printf '*.txt\n' >> "$IREF/sub/.gitignore"; printf '*.txt\n' >> "$IREF/sub/.git/info/exclude"
FR="$TMP/ignore-root"
for w in i-all i-mix i-part i-neg i-deep i-top i-held i-dir i-case i-own i-head i-open; do f_add "$w"; done
echo out > "$FR/i-all/sub/a.log"; mkdir -p "$FR/i-all/sub/cache/in"; echo out > "$FR/i-all/sub/cache/in/x.bin"
echo unrelated > "$FR/i-mix/sub/z"; echo out > "$FR/i-mix/sub/b.log"
echo out > "$FR/i-part/sub/a.log"; echo mine > "$FR/i-part/sub/mine.txt"
echo out > "$FR/i-neg/sub/keep.log"
mkdir -p "$FR/i-deep/sub/deep/er"; echo out > "$FR/i-deep/sub/deep/er/x.tmp"
echo out > "$FR/i-top/sub/x.tmp"
echo 'another content' > "$FR/i-held/sub/tracked.log"
echo 'a file, not a directory' > "$FR/i-dir/sub/cache"
echo out > "$FR/i-case/sub/A.LOG"
# i-own: a file only the machine's own ignore file will name, further down.
echo mine > "$FR/i-own/sub/notes.md"
for w in i-head i-open; do
  echo "$w" > "$FR/$w/sub/own"; g -C "$FR/$w/sub" add own; g -C "$FR/$w/sub" commit -qm "$w"
  echo out > "$FR/$w/sub/run.log"
done
cm_pr "$(f_sha i-head)" 71
printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":1,"nodes":[%s]}}}}}\n' \
  "$(node 72 OPEN "$(f_sha i-open)")" > "$FIX/$(f_sha i-open).json"
bash "$INVENTORY" "$FR" --tips > "$TMP/ignores.all"
check 'the fixture inventory reads all twelve entries as untracked' eval '[ "$(grep -c "^ENTRY	i-[a-z]*	sub	untracked	" "$TMP/ignores.all")" = 12 ]'
f_objects() { find "$FR"/*/sub/.git "$IREF/sub/.git" -type f -exec cksum {} + | LC_ALL=C sort | cksum; }
before=$(f_objects)
f_run "$TMP/ignores.all" "$IREF"
after=$(f_objects)
file_is 'files the default branch ignores are default-ignores'             i-all "default-ignores files=2 same=0 default_ignores=2 base=$iref_base"
file_is 'a copy beside an ignored file is default-ignores'                 i-mix "default-ignores files=2 same=1 default_ignores=1 base=$iref_base"
file_is 'one file no rule covers differs'                                  i-part "differs files=2 same=0 default_ignores=1 base=$iref_base"
file_is 'a file a later rule takes back out differs'                       i-neg "differs files=1 same=0 default_ignores=0 base=$iref_base"
file_is 'a rule file deeper in the default branch covers its own folder'   i-deep "default-ignores files=1 same=0 default_ignores=1 base=$iref_base"
file_is 'and covers nothing outside it'                                    i-top "differs files=1 same=0 default_ignores=0 base=$iref_base"
file_is 'a path the default branch holds is never ignored, rule or not'    i-held "differs files=1 same=0 default_ignores=0 base=$iref_base"
file_is 'a file is not covered by a rule for a directory'                  i-dir "differs files=1 same=0 default_ignores=0 base=$iref_base"
file_is 'letter case is kept apart'                                        i-case "differs files=1 same=0 default_ignores=0 base=$iref_base"
file_is 'only rules the default branch holds count'                        i-own "differs files=1 same=0 default_ignores=0 base=$iref_base"
check 'a merged HEAD beside an ignored file is looked up' eval 'grep -q "^MERGE-CHECK	i-head	sub	merged	head=$(f_sha i-head)	repo=devantler-tech/ksail	pr=71	other_local=0$" <<<"$OUT"'
check 'the closing line counts the ignored entries' eval 'grep -q "	files_same_as_default=0	files_default_ignores=5	files_differ=7	files_no_reference=0$" <<<"$OUT" && [ "$RC" = 0 ]'
check 'reading the rules writes to neither repository' [ "$before" = "$after" ]
check 'the classification never puts ignored files below tool output' eval '[ "$(printf "%s\n" "$OUT" | bash "$SCRIPT_DIR/worktree-inventory-classify.sh" --inventory "$TMP/ignores.all" | awk -F"\t" "\$1 == \"CLASS\" { printf \"%s=%s \", \$2, \$4 }")" = "i-all=tool-output i-case=needs-a-person i-deep=tool-output i-dir=needs-a-person i-head=tool-output i-held=needs-a-person i-mix=tool-output i-neg=needs-a-person i-open=work-in-flight i-own=needs-a-person i-part=needs-a-person i-top=needs-a-person " ]'
i_one() { # worktree -> an inventory holding that entry alone
  grep "^[A-Z]*	$1	" "$TMP/ignores.all" > "$TMP/ignores.one"
  printf 'CHECKED\tworktrees=1\tentries=1\tunpushed=0\tlocal_only=0\tbelow_min_idle=0\tunreadable=0\ttips=0\n' >> "$TMP/ignores.one"
}
# The machine's own ignore file is not the default branch's either. The entry turns it off
# for itself, so its file stays listed: only the rules read for the default branch could
# still pick it up.
mkdir -p "$TMP/machine-home"; printf '*.md\n*.txt\n' > "$TMP/machine-ignore"
printf '[core]\n\texcludesFile = %s\n' "$TMP/machine-ignore" > "$TMP/machine-home/.gitconfig"
g -C "$FR/i-own/sub" config core.excludesFile /dev/null
i_one i-own
OUT=$(PATH="$BIN:$PATH" HOME="$TMP/machine-home" XDG_CONFIG_HOME="$TMP/machine-home/none" GIT_CONFIG_GLOBAL="$TMP/machine-home/.gitconfig" bash "$SUT" "$FR" --content-reference "$IREF" < "$TMP/ignores.one" 2>"$TMP/err"); RC=$?
file_is 'a rule of the machine does not count'                             i-own "differs files=1 same=0 default_ignores=0 base=$iref_base"
# Nor is a rule the machine plants in every new repository.
mkdir -p "$TMP/machine-home/template/info"; printf '*.md\n' > "$TMP/machine-home/template/info/exclude"
printf '[init]\n\ttemplateDir = %s\n' "$TMP/machine-home/template" > "$TMP/machine-home/.gitconfig"
i_one i-own
OUT=$(PATH="$BIN:$PATH" HOME="$TMP/machine-home" XDG_CONFIG_HOME="$TMP/machine-home/none" GIT_CONFIG_GLOBAL="$TMP/machine-home/.gitconfig" bash "$SUT" "$FR" --content-reference "$IREF" < "$TMP/ignores.one" 2>"$TMP/err"); RC=$?
file_is 'a rule planted in every new repository does not count'           i-own "differs files=1 same=0 default_ignores=0 base=$iref_base"
# A failed read of the rules is never `differs` or `default-ignores`.
i_one i-all
for verb in check-ignore cat-file init; do
  OUT=$(PATH="$BIN:$PATH" V="$verb" bash -c 'git() { case " $* " in *" $V "*) return 3 ;; esac; command git "$@"; }; export -f git; bash "$0" "$1" --content-reference "$2" < "$3"' "$SUT" "$FR" "$IREF" "$TMP/ignores.one" 2>"$TMP/err"); RC=$?
  check "a failed $verb is UNKNOWN" eval '[ -z "$(file_of i-all)" ] && grep -q "^UNKNOWN	i-all	sub	cannot read the ignore rules of the default branch" <<<"$OUT" && [ "$RC" = 2 ]'
done

# An inventory that fails (a root with no worktree) must not read as an empty, clean result.
mkdir -p "$TMP/empty-root"
OUT=$(bash "$INVENTORY" "$TMP/empty-root" 2>/dev/null | PATH="$BIN:$PATH" bash "$SUT" "$TMP/empty-root" 2>"$TMP/err"); RC=$?
check 'a failed inventory behind a pipe is not a clean result' rc_is 2

printf '\n%s passed, %s failed\n' "$pass" "$fail"
test_run_completed=1
[ "$fail" -eq 0 ]
