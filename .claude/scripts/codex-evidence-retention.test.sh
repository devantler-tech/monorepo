#!/usr/bin/env bash
# test-inputs: .claude/scripts/build-cache-reclaim.sh .claude/scripts/build-cache-reclaim.test.sh
# test-inputs: .claude/scripts/cleanup-trap-census-go/go.mod
# test-inputs: .claude/scripts/codex-transcript-retention.sh
# test-inputs: .claude/scripts/codex-transcript-retention.test.sh
# test-inputs: .claude/scripts/codex-worktree-retention.sh
# test-inputs: .claude/scripts/codex-worktree-retention.test.sh .github/workflows/ci.yaml
# Tests for codex-evidence-retention.sh (monorepo#5189).
#
# The helper DELETES, so every case is a safety property proved by ablation: each kept fixture
# differs from a removable one in exactly one dimension (age, an open file, a link from an open
# issue, a symbolic link, an unsafe name, an unreadable answer), so a helper that removed
# everything could not pass. Every case runs against a fixture Codex home with stub lsof and gh;
# none reads the real ~/.codex of the machine running the suite or calls GitHub.
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
impl="${script_dir}/codex-evidence-retention.sh"

failures=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}
ok() { printf 'ok: %s\n' "$*"; }

tmp=$(mktemp -d) || { echo 'cannot create a temp dir' >&2; exit 2; }
tests_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local status=$?
  rm -rf -- "$tmp"
  if [ "$tests_finished" != 1 ]; then
    echo "FAIL: the suite aborted before finishing (status ${status})" >&2
    exit 1
  fi
}
trap cleanup EXIT
tmp=$(cd -P -- "$tmp" && pwd -P) || exit 2

home="${tmp}/codex"
bin="${tmp}/bin"
mkdir -p "$bin" || exit 2
stamp=$(date -v-30d +%Y%m%d%H%M 2>/dev/null || date -d '30 days ago' +%Y%m%d%H%M)

# age <path> makes everything at or below <path> look 30 days old (links included, not followed).
age() { find "$1" -exec touch -h -t "$stamp" {} + 2>/dev/null; }

# Stub lsof: prints `n<path>` for every line of $bin/open, or fails when $bin/lsof-fail exists.
cat > "${bin}/lsof" <<EOF
#!/bin/sh
[ -e '${bin}/lsof-fail' ] && exit 1
printf 'p1\nn/dev/null\n'
[ -f '${bin}/open' ] && sed 's/^/n/' '${bin}/open'
exit 0
EOF
# Stub gh: answers the search with one hit when its query names a folder listed in $bin/links and
# none otherwise; fails when $bin/gh-fail exists; reports an incomplete search when
# $bin/gh-incomplete exists. Every query is appended to $bin/queries.
cat > "${bin}/gh" <<EOF
#!/bin/sh
[ -e '${bin}/gh-fail' ] && exit 1
q=''
while [ \$# -gt 0 ]; do
  case "\$1" in q=*) q=\${1#q=} ;; esac
  shift
done
printf '%s\n' "\$q" >> '${bin}/queries'
incomplete=false
[ -e '${bin}/gh-incomplete' ] && incomplete=true
hits=0
if [ -f '${bin}/links' ]; then
  while IFS= read -r name; do
    case "\$q" in *"\"\$name\""*) hits=1 ;; esac
  done < '${bin}/links'
fi
printf '%s\t%s\n' "\$hits" "\$incomplete"
EOF
chmod +x "${bin}/lsof" "${bin}/gh"

run() {
  CODEX_EVIDENCE_RETENTION_HOME="$home" CODEX_EVIDENCE_RETENTION_LSOF="${bin}/lsof" \
    CODEX_EVIDENCE_RETENTION_GH="${bin}/gh" CODEX_EVIDENCE_RETENTION_PAUSE=0 bash "$impl" "$@" 2>&1
}

# fixture <automation> <run>... makes old evidence folders, each holding one file.
fixture() {
  local a=$1 r
  shift
  for r in "$@"; do
    mkdir -p "${home}/automations/${a}/evidence/${r}/sub" &&
      printf 'proof\n' > "${home}/automations/${a}/evidence/${r}/sub/file" || exit 2
  done
}
reset() {
  rm -rf -- "$home" "${bin}/open" "${bin}/links" "${bin}/queries" "${bin}/gh-fail" \
    "${bin}/gh-incomplete" "${bin}/lsof-fail" "${tmp}/elsewhere"
  mkdir -p "${home}/automations" || exit 2
}
ev() { printf '%s/automations/%s/evidence/%s' "$home" "$1" "$2"; }

# --- usage -----------------------------------------------------------------------------------
reset
out=$(run apply 13)
rc=$?
if [ "$rc" -eq 2 ] && grep -q 'at least 14' <<<"$out"; then ok 'refuses an age below 14 days'; else fail "an age of 13 days was accepted (rc=${rc}): ${out}"; fi
out=$(run remove 14)
rc=$?
if [ "$rc" -eq 2 ]; then ok 'refuses an unknown mode'; else fail "an unknown mode was accepted (rc=${rc})"; fi

# --- no Codex home -----------------------------------------------------------------------------
rm -rf -- "$home"
out=$(run apply)
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'no Codex automations at ' <<<"$out"; then ok 'a missing Codex home is a no-op'; else fail "a missing Codex home was not a clean no-op (rc=${rc}): ${out}"; fi

# --- the main ablation: one removable class and one kept fixture per safety dimension ----------
reset
fixture eng a1 a2 a3 a4 a5 # one full batch of old, unlinked folders: removed
fixture eng young          # written now: kept
fixture other held         # a process uses it: kept
fixture other zz-linked    # an open issue names it, alone in the last batch: kept
mkdir -p "${tmp}/elsewhere/target" && printf 'x\n' > "${tmp}/elsewhere/target/file"
fixture linkhome x
rm -rf -- "${home}/automations/linkhome/evidence"
ln -s "${tmp}/elsewhere" "${home}/automations/linkhome/evidence" # evidence is a link: not followed
mkdir -p "$(ev eng 'bad name')" && printf 'x\n' > "$(ev eng 'bad name')/f" # unsafe name: kept
age "$home"
age "${tmp}/elsewhere"
printf 'fresh\n' > "$(ev eng young)/sub/file"
printf '%s\n' "$(ev other held)/sub/file" > "${bin}/open"
printf 'zz-linked\n' > "${bin}/links"

out=$(run dry-run)
rc=$?
if [ "$rc" -eq 0 ] && [ -d "$(ev eng a1)" ] && grep -q 'would remove=5 ' <<<"$out" &&
  grep -q 'dry-run: nothing deleted' <<<"$out"; then
  ok 'dry-run reports five removals and deletes nothing'
else
  fail "dry-run misreported or deleted (rc=${rc}): ${out}"
fi

rm -f "${bin}/queries"
out=$(run apply)
rc=$?
if [ "$rc" -ne 0 ]; then fail "apply exited ${rc}: ${out}"; fi
gone=0
for r in a1 a2 a3 a4 a5; do [ -e "$(ev eng "$r")" ] || gone=$((gone + 1)); done
if [ "$gone" -eq 5 ] && grep -q ' removed=5 ' <<<"$out"; then ok 'old unlinked folders are removed'; else fail "expected 5 removals, got ${gone}: ${out}"; fi
if [ -d "$(ev eng young)" ]; then ok 'a recently written folder is kept'; else fail 'a recently written folder was removed'; fi
if [ -d "$(ev other held)" ]; then ok 'a folder a process uses is kept'; else fail 'a folder in use was removed'; fi
if [ -d "$(ev other zz-linked)" ] && grep -q 'linked=1 ' <<<"$out"; then ok 'a folder an open issue links to is kept'; else fail "a linked folder was removed: ${out}"; fi
if [ -f "${tmp}/elsewhere/target/file" ]; then ok 'a symbolic-link evidence folder is not followed'; else fail 'the target of an evidence link was removed'; fi
if [ -d "$(ev eng 'bad name')" ]; then ok 'an unsafe folder name is kept'; else fail 'an unsafe folder name was removed'; fi
q1=$(sed -n 1p "${bin}/queries" 2>/dev/null)
if [ "$(wc -l < "${bin}/queries" | tr -d ' ')" = 2 ] && [ "$q1" = 'org:devantler-tech is:open "a1" OR "a2" OR "a3" OR "a4" OR "a5"' ]; then
  ok 'names are searched five to a query in the organisation, open items only, oldest first'
else
  fail "unexpected search queries: $(cat "${bin}/queries" 2>/dev/null)"
fi

# --- a hit keeps every folder searched in the same query ---------------------------------------
reset
fixture eng b1 b2 b3
age "$home"
printf 'b2\n' > "${bin}/links"
out=$(run apply)
rc=$?
if [ "$rc" -eq 0 ] && [ -d "$(ev eng b1)" ] && [ -d "$(ev eng b3)" ] && grep -q 'linked=3 ' <<<"$out"; then
  ok 'a hit keeps every folder of its query'
else
  fail "a hit did not keep its whole query (rc=${rc}): ${out}"
fi

# --- unreadable answers keep everything --------------------------------------------------------
reset
fixture eng c1 c2
age "$home"
touch "${bin}/gh-fail"
out=$(run apply)
rc=$?
if [ "$rc" -eq 2 ] && [ -d "$(ev eng c1)" ] && [ -d "$(ev eng c2)" ]; then ok 'a failed search keeps everything and is UNKNOWN'; else fail "a failed search removed or exited ${rc}: ${out}"; fi

rm -f "${bin}/gh-fail"
touch "${bin}/gh-incomplete"
out=$(run apply)
rc=$?
if [ "$rc" -eq 2 ] && [ -d "$(ev eng c1)" ]; then ok 'an incomplete search keeps everything and is UNKNOWN'; else fail "an incomplete search removed or exited ${rc}: ${out}"; fi

rm -f "${bin}/gh-incomplete"
touch "${bin}/lsof-fail"
out=$(run apply)
rc=$?
if [ "$rc" -eq 2 ] && [ -d "$(ev eng c1)" ]; then ok 'an unreadable open-file list keeps everything and is UNKNOWN'; else fail "an unreadable open-file list removed or exited ${rc}: ${out}"; fi

# --- the lookup budget defers the rest ---------------------------------------------------------
reset
fixture eng d1 d2 d3 d4 d5 d6
age "$home"
out=$(CODEX_EVIDENCE_RETENTION_LOOKUPS=1 run apply)
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$(ev eng d1)" ] && [ -d "$(ev eng d6)" ] && grep -q 'deferred=1 ' <<<"$out" &&
  grep -q 'lookups=1 ' <<<"$out"; then
  ok 'folders past the lookup budget are deferred, oldest removed first'
else
  fail "the lookup budget was not honoured (rc=${rc}): ${out}"
fi

# --- the summary is the one build-cache-reclaim parses -----------------------------------------
if [ "$(grep -c '^codex-evidence-retention: summary:' <<<"$out")" = 1 ] && grep -qE ' removed=[0-9]+ ' <<<"$out" &&
  grep -qE ' reclaimed=~[0-9]+ MB' <<<"$out"; then
  ok 'one summary line carries removed= and reclaimed=~'
else
  fail "the summary is not in the shape build-cache-reclaim reads: ${out}"
fi

tests_finished=1
if [ "$failures" -gt 0 ]; then
  printf '%d failure(s)\n' "$failures" >&2
  exit 1
fi
echo 'all codex-evidence-retention tests passed'
