#!/usr/bin/env bash
# consumer-census.test.sh — self-test for consumer-census.sh (monorepo#4842).
#
# Builds a throwaway monorepo whose `.gitmodules` lists four submodules, each backed by a local bare
# "origin": one whose fetched default branch uses the symbol while its stale working tree does not,
# one that does not use it, one that is not populated, and one whose origin cannot be fetched. It
# proves a hit is found on the fetched tip (not the working tree), a miss is reported only after the
# control passes, and an unpopulated or unfetchable repository is UNKNOWN (exit 2), never zero.
# The monorepo itself is one more row (monorepo#4917): its own hit is found, its submodule gitlinks are
# not searched again, and a failed fetch of it is UNKNOWN.
# An offline `gh` stub proves an archived repository is ARCHIVED and not searched, and an unreadable
# archive state or a non-GitHub URL is UNKNOWN.
# TEST_BASH=/bin/bash runs the helper under macOS's bash 3.2.
#
# Exit codes: 0 every assertion held · 1 an assertion failed
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
helper="${script_dir}/consumer-census.sh"

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

work=$(mktemp -d)
# Bash 3.2 hands an EXIT trap $? = 0 after a `set -u` abort, so a successful rm could turn a crash
# into a pass. Reaching the end is the only way a zero status leaves this test.
consumer_census_test_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  rm -rf "$work"
  if [ "$consumer_census_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "consumer-census.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
g() { git -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

# make_sub <name> <file> <working-tree text> [<newer text pushed to origin only>]
make_sub() {
  local name="$1" file="$2" old="$3" new="${4:-}"
  g init -q --bare "$work/origins/$name.git"
  g clone -q "$work/origins/$name.git" "$work/root/$name" 2>/dev/null
  printf '%s\n' "$old" > "$work/root/$name/$file"
  g -C "$work/root/$name" add "$file"
  g -C "$work/root/$name" commit -q -m init
  g -C "$work/root/$name" push -q origin HEAD:main
  if [ -n "$new" ]; then
    g clone -q "$work/origins/$name.git" "$work/other-$name" 2>/dev/null
    printf '%s\n' "$new" > "$work/other-$name/$file"
    g -C "$work/other-$name" commit -q -a -m newer
    g -C "$work/other-$name" push -q origin HEAD:main
  fi
}

mkdir -p "$work/origins" "$work/root"
g init -q "$work/root"
make_sub consumer workflow.yaml 'uses: ./old' 'uses: devantler-tech/.github/.github/workflows/shared.yaml@v1'
make_sub bystander README.md 'nothing shared here'
mkdir -p "$work/root/empty"
make_sub unreachable ci.yaml 'uses: devantler-tech/.github/.github/workflows/shared.yaml@v1'
g -C "$work/root/unreachable" remote set-url origin "$work/origins/missing.git"
cat > "$work/root/.gitmodules" <<'EOF'
[submodule "consumer"]
	path = consumer
	url = git@github.com:fixture-org/consumer.git
[submodule "bystander"]
	path = bystander
	url = git@github.com:fixture-org/bystander.git
[submodule "empty"]
	path = empty
	url = git@github.com:fixture-org/empty.git
[submodule "unreachable"]
	path = unreachable
	url = git@github.com:fixture-org/unreachable.git
EOF

symbol='.github/workflows/shared.yaml'

# The monorepo itself (monorepo#4917): its origin's default branch uses a symbol no submodule uses,
# and records the consumer submodule as a gitlink, so a search that descended into gitlinks would
# count the consumer's hit twice. The configured URL names the GitHub repository; `insteadOf` points
# the fetch at a local bare repository.
g init -q --bare "$work/origins/monorepo.git"
g clone -q "$work/origins/monorepo.git" "$work/other-monorepo" 2>/dev/null
printf '## Monorepo-only contract section\n' > "$work/other-monorepo/AGENTS.md"
g -C "$work/other-monorepo" add AGENTS.md
g -C "$work/other-monorepo" update-index --add --cacheinfo "160000,$(g -C "$work/other-consumer" rev-parse HEAD),consumer"
g -C "$work/other-monorepo" commit -q -m init
g -C "$work/other-monorepo" push -q origin HEAD:main
g -C "$work/root" remote add origin git@github.com:fixture-org/monorepo.git
g -C "$work/root" config "url.$work/origins/monorepo.git.insteadOf" git@github.com:fixture-org/monorepo.git
mono_symbol='Monorepo-only contract section'

# An offline `gh`: archive state comes from $work/gh-state (`<owner>/<repo> true|false|error [fork]`);
# a third word `fork` marks the repository as a fork. Any
# repository not listed is not archived. Every call is logged, so the test needs no network.
mkdir -p "$work/bin"
: > "$work/gh-state"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
[ "$1" = api ] || exit 9
slug=${2#repos/}
state=$(awk -v s="$slug" '$1 == s { print $2 }' "${GH_STUB_STATE:?}")
fork=$(awk -v s="$slug" '$1 == s { print ($3 == "fork") ? "true" : "false" }' "${GH_STUB_STATE:?}")
case "$state" in
  true) echo "true ${fork:-false}" ;;
  error) echo 'HTTP 403: API rate limit exceeded' >&2; exit 1 ;;
  *) echo "false ${fork:-false}" ;;
esac
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_STUB_LOG="$work/gh-calls" GH_STUB_STATE="$work/gh-state"

# run <args...>: sets rc and leaves stdout in $work/out
run() {
  rc=0
  "${TEST_BASH:-bash}" "$helper" --root "$work/root" "$@" >"$work/out" 2>"$work/err" || rc=$?
}
has() { NEEDLE="$1" awk 'index($0, ENVIRON["NEEDLE"]) { found = 1 } END { exit !found }' "$work/out"; }

# --- a found symbol, on the fetched tip rather than the stale working tree ---------------------
run --only consumer "$symbol"
if [ "$rc" -eq 0 ] && has "$(printf 'HIT\tconsumer\tworkflow.yaml:1\tuses: devantler-tech/.github/.github/workflows/shared.yaml@v1')"; then
  pass "found symbol: HIT with file:line from the fetched default branch"
else
  fail "found symbol: rc=$rc out=$(cat "$work/out") err=$(cat "$work/err")"
fi
if grep -q 'shared.yaml' "$work/root/consumer/workflow.yaml"; then
  fail "fixture: the consumer's working tree already holds the symbol, so the fetch is not proven"
else
  pass "fixture: the hit exists only on origin, so it came from the fetched tip"
fi
if has "$(printf 'SUMMARY\thits=1\trepos-with-hits=1\tnone=0\tarchived=0\tunknown=0')"; then
  pass "found symbol: summary counts one hit"
else
  fail "found symbol: summary wrong: $(cat "$work/out")"
fi

# --- a not-found symbol with a passing control --------------------------------------------------
run --only bystander "$symbol"
if [ "$rc" -eq 0 ] && has "$(printf 'NONE\tbystander\tmain@')" && has 'control-passed'; then
  pass "not-found symbol: NONE only after the control passed"
else
  fail "not-found symbol: rc=$rc out=$(cat "$work/out")"
fi

# --- a tree the control cannot read is UNKNOWN, not zero ----------------------------------------
make_sub binary data.bin 'placeholder'
printf '\000\001\002' > "$work/other-bin"
g clone -q "$work/origins/binary.git" "$work/other-binary" 2>/dev/null
cp "$work/other-bin" "$work/other-binary/data.bin"
g -C "$work/other-binary" commit -q -a -m binary-only
g -C "$work/other-binary" push -q origin HEAD:main
printf '[submodule "binary"]\n\tpath = binary\n\turl = git@github.com:fixture-org/binary.git\n' >> "$work/root/.gitmodules"
run --only binary "$symbol"
if [ "$rc" -eq 2 ] && has "$(printf 'UNKNOWN\tbinary\tcontrol query found no text')"; then
  pass "failed control: a tree with no searchable text is UNKNOWN"
else
  fail "failed control: rc=$rc out=$(cat "$work/out")"
fi

# --- an unpopulated submodule is UNKNOWN ---------------------------------------------------------
run --only empty "$symbol"
if [ "$rc" -eq 2 ] && has "$(printf 'UNKNOWN\tempty\tnot populated')" && ! has 'HIT'; then
  pass "unpopulated submodule: UNKNOWN, and the parent repository is not searched in its place"
else
  fail "unpopulated submodule: rc=$rc out=$(cat "$work/out")"
fi

# --- a failed fetch is UNKNOWN, even though the stale working tree holds the symbol --------------
run --only unreachable "$symbol"
if [ "$rc" -eq 2 ] && has "$(printf 'UNKNOWN\tunreachable\t')" && ! has 'HIT'; then
  pass "failed fetch: UNKNOWN, never a hit or a zero"
else
  fail "failed fetch: rc=$rc out=$(cat "$work/out")"
fi

# --- the whole census: hits still print, but one UNKNOWN makes it incomplete ---------------------
run "$symbol"
if [ "$rc" -eq 2 ] && has "$(printf 'HIT\tconsumer\t')" && has "$(printf 'SUMMARY\thits=1\trepos-with-hits=1\tnone=2\tarchived=0\tunknown=3')"; then
  pass "full census: hits printed, exit 2 while any repository is UNKNOWN"
else
  fail "full census: rc=$rc out=$(cat "$work/out")"
fi
if has "$(printf 'NONE\t.\tmain@')" && ! has "$(printf 'HIT\t.\t')"; then
  pass "full census: the monorepo row is searched, and its submodule gitlink is not counted again"
else
  fail "full census: monorepo row missing or double-counted: $(cat "$work/out")"
fi

# --- the monorepo itself is a row (monorepo#4917) ----------------------------------------------
run "$mono_symbol"
if has "$(printf 'HIT\t.\tAGENTS.md:1\t## Monorepo-only contract section')" \
  && has "$(printf 'SUMMARY\thits=1\trepos-with-hits=1\t')"; then
  pass "monorepo row: a symbol only the monorepo uses is a HIT with file:line"
else
  fail "monorepo row: rc=$rc out=$(cat "$work/out")"
fi
if [ ! -e "$work/root/AGENTS.md" ]; then
  pass "fixture: the monorepo hit exists only on origin, so it came from the fetched tip"
else
  fail "fixture: the root working tree holds AGENTS.md, so the fetch is not proven"
fi
run --only . "$mono_symbol"
if [ "$rc" -eq 0 ] && has "$(printf 'HIT\t.\tAGENTS.md:1')" && ! has "$(printf '\tconsumer\t')" \
  && has "$(printf 'SUMMARY\thits=1\trepos-with-hits=1\tnone=0\tarchived=0\tunknown=0')"; then
  pass "monorepo row: --only . searches the monorepo alone"
else
  fail "monorepo row --only .: rc=$rc out=$(cat "$work/out")"
fi
run --only consumer "$mono_symbol"
if ! has "$(printf '\t.\t')"; then
  pass "monorepo row: an --only list without . leaves the monorepo out"
else
  fail "monorepo row: --only consumer still searched the monorepo: $(cat "$work/out")"
fi

# A failed fetch for the monorepo row is UNKNOWN, even though an earlier fetch left a tip with a hit.
g -C "$work/root" config --unset "url.$work/origins/monorepo.git.insteadOf"
g -C "$work/root" config "url.$work/origins/missing-monorepo.git.insteadOf" git@github.com:fixture-org/monorepo.git
run --only . "$mono_symbol"
if [ "$rc" -eq 2 ] && has "$(printf 'UNKNOWN\t.\t')" && ! has 'HIT' \
  && has "$(printf 'SUMMARY\thits=0\trepos-with-hits=0\tnone=0\tarchived=0\tunknown=1')"; then
  pass "monorepo row: a failed fetch is UNKNOWN and exit 2, never zero consumers or a stale hit"
else
  fail "monorepo row failed fetch: rc=$rc out=$(cat "$work/out")"
fi
g -C "$work/root" config --unset "url.$work/origins/missing-monorepo.git.insteadOf"
g -C "$work/root" config "url.$work/origins/monorepo.git.insteadOf" git@github.com:fixture-org/monorepo.git

# An unreadable archive state for the monorepo is UNKNOWN, read from its configured GitHub URL.
printf 'fixture-org/monorepo error\n' > "$work/gh-state"
run --only . "$mono_symbol"
if [ "$rc" -eq 2 ] && has "$(printf 'UNKNOWN\t.\tarchive state of fixture-org/monorepo could not be read')" && ! has 'HIT'; then
  pass "monorepo row: an unreadable archive state is UNKNOWN"
else
  fail "monorepo row archive state: rc=$rc out=$(cat "$work/out")"
fi
: > "$work/gh-state"

# A fork as origin makes the monorepo row UNKNOWN, although its fetched tip holds the symbol:
# a fork can be behind the monorepo without saying so (monorepo#4917).
printf 'fixture-org/monorepo false fork\n' > "$work/gh-state"
run --only . "$mono_symbol"
if [ "$rc" -eq 2 ] && has "$(printf 'UNKNOWN\t.\tfixture-org/monorepo is a fork')" && ! has 'HIT' \
  && has "$(printf 'SUMMARY\thits=0\trepos-with-hits=0\tnone=0\tarchived=0\tunknown=1')"; then
  pass "monorepo row: a fork as origin is UNKNOWN and exit 2, never zero consumers or a hit"
else
  fail "monorepo row fork: rc=$rc out=$(cat "$work/out")"
fi
# The rule is for the monorepo row only: a submodule that is itself a fork is searched as usual.
printf 'fixture-org/consumer false fork\n' > "$work/gh-state"
run --only consumer "$symbol"
if [ "$rc" -eq 0 ] && has "$(printf 'HIT\tconsumer\tworkflow.yaml:1')"; then
  pass "fork rule: a forked submodule is still searched"
else
  fail "fork rule on a submodule: rc=$rc out=$(cat "$work/out")"
fi
: > "$work/gh-state"

# --- --no-fetch searches what was already fetched -----------------------------------------------
run --no-fetch --only consumer "$symbol"
if [ "$rc" -eq 0 ] && has "$(printf 'HIT\tconsumer\tworkflow.yaml:1')"; then
  pass "--no-fetch: searches the already-fetched tip"
else
  fail "--no-fetch: rc=$rc out=$(cat "$work/out")"
fi

# --- archived repositories are outside the census; an unreadable state is UNKNOWN ---------------
printf 'fixture-org/consumer true\n' > "$work/gh-state"
: > "$work/gh-calls"
run --only consumer "$symbol"
if [ "$rc" -eq 0 ] && has "$(printf 'ARCHIVED\tconsumer\tfixture-org/consumer')" && ! has 'HIT' \
  && has "$(printf 'SUMMARY\thits=0\trepos-with-hits=0\tnone=0\tarchived=1\tunknown=0')"; then
  pass "archived: reported ARCHIVED and not searched, even though it uses the symbol"
else
  fail "archived: rc=$rc out=$(cat "$work/out")"
fi
if grep -qxF 'api repos/fixture-org/consumer --jq "\(.archived) \(.fork)"' "$work/gh-calls"; then
  pass "archived: the state was read live, one call for the repository"
else
  fail "archived: unexpected gh calls: $(cat "$work/gh-calls")"
fi

printf 'fixture-org/consumer false\n' > "$work/gh-state"
run --only consumer "$symbol"
if [ "$rc" -eq 0 ] && has "$(printf 'HIT\tconsumer\t')" && ! has 'ARCHIVED'; then
  pass "not archived: searched as usual"
else
  fail "not archived: rc=$rc out=$(cat "$work/out")"
fi

printf 'fixture-org/consumer error\n' > "$work/gh-state"
run --only consumer "$symbol"
if [ "$rc" -eq 2 ] && has "$(printf 'UNKNOWN\tconsumer\tarchive state of fixture-org/consumer could not be read')" && ! has 'HIT'; then
  pass "unreadable archive state (403): UNKNOWN and exit 2, never assumed not archived"
else
  fail "unreadable archive state: rc=$rc out=$(cat "$work/out")"
fi
: > "$work/gh-state"

printf '[submodule "elsewhere"]\n\tpath = elsewhere\n\turl = https://gitlab.example.invalid/x/y.git\n' >> "$work/root/.gitmodules"
run --only elsewhere "$symbol"
if [ "$rc" -eq 2 ] && has "$(printf 'UNKNOWN\telsewhere\tarchive state unknown: not a GitHub submodule URL')"; then
  pass "non-GitHub URL: archive state cannot be read, so UNKNOWN"
else
  fail "non-GitHub URL: rc=$rc out=$(cat "$work/out")"
fi

# --- usage errors are exit 2--------------------------------------------------------------------
run
if [ "$rc" -eq 2 ]; then pass "usage: no symbol is exit 2"; else fail "usage: no symbol gave $rc"; fi
run --only nosuch "$symbol"
if [ "$rc" -eq 2 ] && grep -q 'nor a submodule path' "$work/err"; then
  pass "usage: an --only path outside .gitmodules is exit 2"
else
  fail "usage: --only nosuch gave $rc ($(cat "$work/err"))"
fi
rm "$work/root/.gitmodules"
run "$symbol"
if [ "$rc" -eq 2 ]; then pass "usage: no .gitmodules is exit 2"; else fail "usage: no .gitmodules gave $rc"; fi

if [ "$failures" -ne 0 ]; then
  echo "consumer-census.test.sh: $failures assertion(s) failed"
  consumer_census_test_finished=1
  exit 1
fi
echo "consumer-census.test.sh: all assertions held"
consumer_census_test_finished=1
