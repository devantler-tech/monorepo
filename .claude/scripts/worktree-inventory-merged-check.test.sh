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
sha=''; name=''
for a in "$@"; do
  case "$a" in sha=*) sha=${a#sha=} ;; r=*) name=${a#r=} ;; esac
done
printf '%s %s\n' "$name" "$sha" >> "$CALLS"
[ -f "$FIX/$sha.json" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
cat "$FIX/$sha.json"
STUB
chmod +x "$BIN/gh"
export FIX CALLS

sha_of() { printf '%040d' "$1"; }
# fixture <n> <jq-object-for-.data.repository.object | raw-body>
prs() { # sha-number total nodes-json
  printf '{"data":{"repository":{"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":%s,"nodes":%s}}}}}\n' \
    "$2" "$3" > "$FIX/$(sha_of "$1").json"
}
node() { printf '{"number":%s,"state":"%s","headRefOid":"%s"}' "$1" "$2" "$3"; }

# add_sub <worktree> <origin-url> -> a directory shaped like a populated submodule.
add_sub() {
  local d="$ROOT/$1/sub"
  mkdir -p "$ROOT/$1"
  g init -q -b main "$d"
  g -C "$d" config remote.origin.url "$2"
}
entry() { # worktree class sha-number
  printf 'ENTRY\t%s\tsub\t%s\tidle_days=20\thead=%s\tunpushed=1\tlocal_only=1\tmodified=0\tuntracked=0\tnested=0\tignored=0\n' \
    "$1" "$2" "$(sha_of "$3")"
}
closing() { printf 'CHECKED\tworktrees=1\n'; }

run() { # stdin -> OUT, RC
  : > "$CALLS"
  OUT=$(PATH="$BIN:$PATH" bash "$SUT" "$ROOT" 2>"$TMP/err"); RC=$?
}
verdict_of() { printf '%s\n' "$OUT" | awk -F'\t' -v w="$1" '$1 == "MERGE-CHECK" && $2 == w { print $4 " " $7 }'; }
expect() { # name worktree want
  local got; got=$(verdict_of "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$got] rc=$RC out=$OUT"; fi
}

add_sub w-merged   'git@github.com:devantler-tech/ksail.git'
add_sub w-open     'https://github.com/devantler-tech/platform.git'
add_sub w-closed   'ssh://git@github.com/devantler-tech/ksail.git'
add_sub w-other    'https://github.com/devantler-tech/ksail'
add_sub w-nopr     'git@github.com:devantler-tech/ksail.git'
add_sub w-absent   'git@github.com:devantler-tech/ksail.git'
add_sub w-both     'git@github.com:devantler-tech/ksail.git'
add_sub w-foreign  'git@github.com:someone-else/ksail.git'
add_sub w-gitlab   'git@gitlab.com:devantler-tech/ksail.git'
add_sub w-lookalike 'git@github.com:devantler-tech-evil/ksail.git'
add_sub w-local    'git@github.com:devantler-tech/ksail.git'
add_sub w-same     'git@github.com:devantler-tech/ksail.git'
add_sub w-fail     'git@github.com:devantler-tech/ksail.git'

prs 1 1 "[$(node 11 MERGED "$(sha_of 1)")]"
prs 2 1 "[$(node 12 OPEN "$(sha_of 2)")]"
prs 3 1 "[$(node 13 CLOSED "$(sha_of 3)")]"
prs 4 1 "[$(node 14 MERGED "$(sha_of 99)")]"
prs 5 0 '[]'
printf '{"data":{"repository":{"object":null}}}\n' > "$FIX/$(sha_of 6).json"
prs 7 2 "[$(node 17 CLOSED "$(sha_of 7)"),$(node 18 MERGED "$(sha_of 7)")]"

echo '== verdicts'
{ entry w-merged unpushed 1; entry w-open unpushed 2; entry w-closed unpushed 3
  entry w-other unpushed 4; entry w-nopr unpushed 5; entry w-absent unpushed 6
  entry w-both unpushed 7; entry w-same unpushed 1; closing; } > "$TMP/in"
run < "$TMP/in"
expect 'a merged pull request at this head is merged'             w-merged 'merged pr=11'
expect 'an open pull request at this head is open'                w-open   'open pr=12'
expect 'a closed pull request at this head is closed'             w-closed 'closed pr=13'
expect 'a merged pull request at ANOTHER head is not merged'      w-other  'other-head pr=14'
expect 'a commit in no pull request is no-pr'                     w-nopr   'no-pr pr=-'
expect 'a commit GitHub does not have is not-on-github'           w-absent 'not-on-github pr=-'
expect 'merged wins over closed at the same head'                 w-both   'merged pr=18'
expect 'a second entry at the same commit gets the same verdict'  w-same   'merged pr=11'
[ "$RC" = 0 ] && ok 'every entry answered: exit 0' || bad 'every entry answered: exit 0' "rc=$RC"
n=$(grep -c " $(sha_of 1)\$" "$CALLS")
[ "$n" = 1 ] && ok 'one lookup per repository and commit' || bad 'one lookup per repository and commit' "calls=$n"
grep -q "^platform $(sha_of 2)\$" "$CALLS" && ok 'the repository name comes from the origin' \
  || bad 'the repository name comes from the origin' "$(cat "$CALLS")"
printf '%s\n' "$OUT" | grep -q $'^CHECKED\tmerged=3\topen=1\tclosed=1\tother_head=1\tno_pr=1\tnot_on_github=1\tnot_checked=0\tother_classes=0\tunknown=0$' \
  && ok 'the closing line carries the totals' || bad 'the closing line carries the totals' "$OUT"

echo '== never queried'
{ entry w-foreign unpushed 1; entry w-gitlab unpushed 1; entry w-lookalike unpushed 1
  entry w-local local-only 1; entry w-merged clean 1; closing; } > "$TMP/in"
run < "$TMP/in"
expect 'another organisation is not-checked'            w-foreign   'not-checked pr=-'
expect 'another host is not-checked'                    w-gitlab    'not-checked pr=-'
expect 'an organisation with our name as prefix is not-checked' w-lookalike 'not-checked pr=-'
expect 'a local-only entry is not-checked'              w-local     'not-checked pr=-'
[ ! -s "$CALLS" ] && ok 'none of them reached GitHub' || bad 'none of them reached GitHub' "$(cat "$CALLS")"
[ "$RC" = 0 ] && ok 'not-checked is not a failure' || bad 'not-checked is not a failure' "rc=$RC"
printf '%s\n' "$OUT" | grep -q $'\tnot_checked=4\tother_classes=1\t' && ok 'other classes are counted, not listed' \
  || bad 'other classes are counted, not listed' "$OUT"

echo '== a lookup that cannot be trusted is UNKNOWN'
unknown_case() { # name sha-number
  { entry w-fail unpushed "$2"; closing; } > "$TMP/in"
  run < "$TMP/in"
  if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q $'^UNKNOWN\tw-fail\tsub\t' && [ -z "$(verdict_of w-fail)" ]; then
    ok "$1"; else bad "$1" "rc=$RC out=$OUT"; fi
}
unknown_case 'a failed request' 50
printf '{"errors":[{"message":"rate limited"}],"data":{"repository":{"object":null}}}\n' > "$FIX/$(sha_of 51).json"
unknown_case 'an error body beside an empty object (would read as not-on-github)' 51
printf '{"data":{"repository":null}}\n' > "$FIX/$(sha_of 52).json"
unknown_case 'a repository GitHub does not return' 52
prs 53 3 "[$(node 21 CLOSED "$(sha_of 99)")]"
unknown_case 'a list cut short (would read as other-head)' 53
printf '{"data":{"repository":{"object":{"__typename":"Tree"}}}}\n' > "$FIX/$(sha_of 54).json"
unknown_case 'an object that is not a commit' 54
printf 'not json\n' > "$FIX/$(sha_of 55).json"
unknown_case 'an answer that is not JSON' 55
prs 56 1 "[$(node 22 DRAFT "$(sha_of 56)")]"
unknown_case 'a pull request state this script does not know' 56
: > "$FIX/$(sha_of 57).json"
unknown_case 'an empty answer' 57

echo '== rows are data'
bad_row() { # name row
  { printf '%s\n' "$2"; closing; } > "$TMP/in"
  run < "$TMP/in"
  if [ "$RC" = 2 ] && [ ! -s "$CALLS" ] && ! printf '%s\n' "$OUT" | grep -q '^MERGE-CHECK'; then ok "$1"
  else bad "$1" "rc=$RC calls=$(cat "$CALLS") out=$OUT"; fi
}
mkdir -p "$TMP/outside"; g init -q -b main "$TMP/outside/sub"
g -C "$TMP/outside/sub" config remote.origin.url 'git@github.com:devantler-tech/ksail.git'
bad_row 'a worktree name that leaves the root' \
  "$(printf 'ENTRY\t../outside\tsub\tunpushed\tidle_days=1\thead=%s' "$(sha_of 1)")"
bad_row 'a submodule path that leaves the worktree' \
  "$(printf 'ENTRY\tw-merged\t../../outside/sub\tunpushed\tidle_days=1\thead=%s' "$(sha_of 1)")"
bad_row 'a short commit' "$(printf 'ENTRY\tw-merged\tsub\tunpushed\tidle_days=1\thead=abc123')"
bad_row 'a commit that is not hexadecimal' \
  "$(printf 'ENTRY\tw-merged\tsub\tunpushed\tidle_days=1\thead=%s' 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz')"
bad_row 'a path with no repository under the root' \
  "$(printf 'ENTRY\tw-merged\tmissing\tunpushed\tidle_days=1\thead=%s' "$(sha_of 1)")"
bad_row 'a class this script does not know' \
  "$(printf 'ENTRY\tw-merged\tsub\tmerged\tidle_days=1\thead=%s' "$(sha_of 1)")"
bad_row 'a row kind this script does not know' "$(printf 'MERGE-CHECK\tw-merged\tsub\tmerged')"

echo '== an incomplete inventory'
entry w-merged unpushed 1 > "$TMP/in"
run < "$TMP/in"
[ "$RC" = 2 ] && grep -q 'no closing CHECKED line' "$TMP/err" && ok 'no closing line: exit 2' \
  || bad 'no closing line: exit 2' "rc=$RC err=$(cat "$TMP/err")"
{ entry w-merged unpushed 1; printf 'UNREADABLE\tw-x\tsub\tcannot read its status\n'; closing; } > "$TMP/in"
run < "$TMP/in"
[ "$RC" = 2 ] && grep -q 'UNREADABLE or malformed' "$TMP/err" && ok 'an UNREADABLE inventory row: exit 2' \
  || bad 'an UNREADABLE inventory row: exit 2' "rc=$RC err=$(cat "$TMP/err")"
: > "$TMP/in"
run < "$TMP/in"
[ "$RC" = 2 ] && ok 'an empty inventory: exit 2' || bad 'an empty inventory: exit 2' "rc=$RC"

echo '== usage'
PATH="$BIN:$PATH" bash "$SUT" >/dev/null 2>&1 </dev/null; [ $? = 2 ] && ok 'no root: exit 2' || bad 'no root: exit 2'
PATH="$BIN:$PATH" bash "$SUT" "$TMP/absent" >/dev/null 2>&1 </dev/null; [ $? = 2 ] && ok 'a missing root: exit 2' || bad 'a missing root: exit 2'

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
printf '{"data":{"repository":{"object":{"__typename":"Commit","associatedPullRequests":{"totalCount":1,"nodes":[%s]}}}}}\n' \
  "$(node 31 MERGED "$head_sha")" > "$FIX/$head_sha.json"
: > "$CALLS"
OUT=$(bash "$INVENTORY" "$E2E" | PATH="$BIN:$PATH" bash "$SUT" "$E2E" 2>"$TMP/err"); RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q "^MERGE-CHECK	wt	sub	merged	head=$head_sha	repo=devantler-tech/ksail	pr=31\$"; then
  ok 'the inventory output is read as it is printed'
else bad 'the inventory output is read as it is printed' "rc=$RC out=$OUT err=$(cat "$TMP/err")"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
test_run_completed=1
[ "$fail" -eq 0 ]
