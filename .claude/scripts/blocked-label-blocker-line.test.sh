#!/usr/bin/env bash
# Hermetic self-test for blocked-label-blocker-line.sh.
#
# No network and no real issue is touched: every case is a hand-built JSON payload fed through
# the --input seam. The forge path shares all of its evaluation logic with that seam, so the
# behaviour proven here is the behaviour that runs against the org.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
CHECK="$HERE/blocked-label-blocker-line.sh"
[ -x "$CHECK" ] || {
  echo "FATAL: $CHECK is not executable" >&2
  exit 2
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
bad() {
  fail=$((fail + 1))
  printf 'FAIL %s\n     %s\n' "$1" "${2:-}"
}

# run <payload-file> -> sets RC and OUT
run() {
  OUT="$("$CHECK" --input "$1" 2>&1)"
  RC=$?
}

expect_rc() { # name expected file
  run "$3"
  if [ "$RC" = "$2" ]; then ok "$1"; else bad "$1" "expected rc=$2 got rc=$RC; out: ${OUT:0:200}"; fi
}

expect_out() { # name pattern file
  run "$3"
  if printf '%s\n' "$OUT" | grep -qE "$2"; then ok "$1"; else bad "$1" "no match for /$2/; out: ${OUT:0:200}"; fi
}

# ------------------------------------------------------------------ 1. conforming
cat >"$TMP/good.json" <<'EOF'
[{"repo":"a","number":1,"body":"lead\n\n**Blocker:** owner/repo#7 | last-verified 2026-08-01: not shipped\n\ntail"}]
EOF
expect_rc "conforming line exits 0" 0 "$TMP/good.json"

# ------------------------------------------------------------------ 2. missing
cat >"$TMP/missing.json" <<'EOF'
[{"repo":"b","number":2,"body":"this body has no blocker line"}]
EOF
expect_rc "missing line exits 1" 1 "$TMP/missing.json"
expect_out "missing line is reported" '^MISSING +b#2' "$TMP/missing.json"

# ------------------------------------------------------------------ 3. prose-only ("waiting on upstream")
cat >"$TMP/prose.json" <<'EOF'
[{"repo":"d","number":4,"body":"**Blocker:** waiting on upstream someday"}]
EOF
expect_rc "prose blocker exits 1" 1 "$TMP/prose.json"
expect_out "prose blocker is MALFORMED" '^MALFORMED +d#4' "$TMP/prose.json"

# ------------------------------------------------------------------ 4. malformed date
cat >"$TMP/date.json" <<'EOF'
[{"repo":"e","number":5,"body":"**Blocker:** owner/repo#9 | last-verified 26-08-01: bad date"}]
EOF
expect_rc "two-digit year is MALFORMED" 1 "$TMP/date.json"

# ------------------------------------------------------------------ 5. THE WRAPPING REGRESSION
# A real body soft-wraps the blocker line. A line-anchored regex calls this MALFORMED even though
# it conforms (measured against platform#3274). Both halves are asserted, so a join that silently
# stops working is caught by the POSITIVE CONTROL rather than passing vacuously.
cat >"$TMP/wrapped.json" <<'EOF'
[{"repo":"c","number":3,"body":"**Blocker:** maintainer authority - an org-owned App with packages read, installed on at\nleast one tenant repository | last-verified 2026-08-21: not provisioned\n\nnext"}]
EOF
expect_rc "wrapped conforming line exits 0" 0 "$TMP/wrapped.json"

# POSITIVE CONTROL: the same text on ONE line must also conform. If this ever fails, the case
# above is proving nothing about wrapping -- it would be passing for an unrelated reason.
cat >"$TMP/unwrapped.json" <<'EOF'
[{"repo":"c","number":3,"body":"**Blocker:** maintainer authority - an org-owned App with packages read, installed on at least one tenant repository | last-verified 2026-08-21: not provisioned\n\nnext"}]
EOF
expect_rc "control: same line unwrapped also exits 0" 0 "$TMP/unwrapped.json"

# NEGATIVE CONTROL: wrapping must not manufacture a match out of a line that never conforms.
# Here the continuation carries no last-verified clause at all.
cat >"$TMP/wrapped-bad.json" <<'EOF'
[{"repo":"c","number":9,"body":"**Blocker:** something external and vague\nthat merely continues onto another line\n\nnext"}]
EOF
expect_rc "wrapped NON-conforming line still exits 1" 1 "$TMP/wrapped-bad.json"

# The join must stop at the blank line -- a later paragraph must not be swept in to complete a
# match that the blocker paragraph itself does not make.
cat >"$TMP/stops.json" <<'EOF'
[{"repo":"c","number":10,"body":"**Blocker:** something vague\n\n| last-verified 2026-08-21: not provisioned\n"}]
EOF
expect_rc "join stops at the blank line" 1 "$TMP/stops.json"

# ------------------------------------------------------------------ 6. SIGPIPE REGRESSION
# An early `exit` in the joining awk closes the pipe while the upstream printf is still writing,
# raising SIGPIPE; under pipefail the substitution returns 141 and set -e aborts the whole run.
# It is invisible on small fixtures because a short body fits the pipe buffer, so this case uses
# a body far larger than it. Exit 141 (or any rc>1) here is the regression.
# AGENTS.md: all scripting here is bash or Go, never Python -- so the oversized body is
# built with the shell and jq (already a hard dependency) rather than a python3 one-liner.
i=0
while [ "$i" -lt 6000 ]; do
  echo "filler line that is here only to exceed the pipe buffer"
  i=$((i + 1))
done >"$TMP/big.txt"
{
  echo
  echo "**Blocker:** owner/repo#7 | last-verified 2026-08-01: not shipped"
} >>"$TMP/big.txt"
jq -Rs '[{repo: "big", number: 11, body: .}]' <"$TMP/big.txt" >"$TMP/big.json"

# A fixture that silently failed to build would make the case below pass for the wrong
# reason -- the regression it guards is only reachable with a body well past the pipe
# buffer (64 KiB here), so assert the size rather than assume the loop ran.
big_bytes=$(wc -c <"$TMP/big.txt" | tr -d " ")
if [ "${big_bytes:-0}" -gt 200000 ]; then
  ok "oversized fixture built (${big_bytes} bytes)"
else
  bad "oversized fixture built" "only ${big_bytes:-0} bytes -- the SIGPIPE case would be vacuous"
fi
run "$TMP/big.json"
if [ "$RC" = 0 ]; then
  ok "large body does not raise SIGPIPE (rc=0)"
elif [ "$RC" = 141 ]; then
  bad "large body does not raise SIGPIPE" "rc=141 -- the SIGPIPE regression is back"
else bad "large body does not raise SIGPIPE" "rc=$RC; out: ${OUT:0:200}"; fi

# ------------------------------------------------------------------ 7. CRLF bodies
printf '[{"repo":"f","number":6,"body":"**Blocker:** owner/repo#7 | last-verified 2026-08-01: not shipped\\r\\n\\r\\ntail"}]\n' >"$TMP/crlf.json"
expect_rc "CRLF body conforms" 0 "$TMP/crlf.json"

# ------------------------------------------------------------------ 8. counting is accurate
cat >"$TMP/mixed.json" <<'EOF'
[{"repo":"a","number":1,"body":"**Blocker:** o/r#1 | last-verified 2026-08-01: x"},
 {"repo":"b","number":2,"body":"none"},
 {"repo":"c","number":3,"body":"none either"}]
EOF
expect_out "reports 2 of 3" '2 of 3 open blocked-labelled' "$TMP/mixed.json"

# ------------------------------------------------------------------ 9. empty set is 0, and says so
echo '[]' >"$TMP/empty.json"
expect_rc "empty payload exits 0" 0 "$TMP/empty.json"
expect_out "empty payload says all 0" 'all 0 open blocked-labelled' "$TMP/empty.json"

# ------------------------------------------------------------------ 10. UNKNOWN paths are 2, never 0
echo '{"not":"an array"}' >"$TMP/obj.json"
expect_rc "non-array payload is UNKNOWN(2)" 2 "$TMP/obj.json"
# Assert the SPECIFIC diagnostic. Without this the case passes even with the type guard
# removed, because a later `.[0]` on an object also errors out to 2 -- the right exit code
# for the wrong reason, which would let the guard rot untested.
expect_out "non-array payload names the type guard" 'not a JSON array' "$TMP/obj.json"

echo 'not json at all' >"$TMP/nonjson.json"
expect_rc "unparseable payload is UNKNOWN(2)" 2 "$TMP/nonjson.json"

OUT="$("$CHECK" --input "$TMP/does-not-exist.json" 2>&1)"
RC=$?
if [ "$RC" = 2 ]; then ok "unreadable payload is UNKNOWN(2)"; else bad "unreadable payload is UNKNOWN(2)" "rc=$RC"; fi

OUT="$("$CHECK" 2>&1)"
RC=$?
if [ "$RC" = 2 ]; then ok "no source is UNKNOWN(2)"; else bad "no source is UNKNOWN(2)" "rc=$RC"; fi

OUT="$("$CHECK" --org x --input "$TMP/good.json" 2>&1)"
RC=$?
if [ "$RC" = 2 ]; then ok "--org with --input is UNKNOWN(2)"; else bad "--org with --input is UNKNOWN(2)" "rc=$RC"; fi

OUT="$("$CHECK" --org 2>&1)"
RC=$?
if [ "$RC" = 2 ]; then ok "--org without a value is UNKNOWN(2)"; else bad "--org without a value is UNKNOWN(2)" "rc=$RC"; fi

# The org name reaches a search URL, so a value outside GitHub's allowed shape is refused rather
# than interpolated. An unencoded space or `&` would silently rewrite the query instead of failing.
OUT="$("$CHECK" --org 'foo bar&x' 2>&1)"
RC=$?
if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q 'must match'; then
  ok "malformed --org is refused"
else
  bad "malformed --org is refused" "rc=$RC; out: ${OUT:0:150}"
fi

# ------------------------------------------------------------------ 11. stdin seam
OUT="$("$CHECK" --input - <"$TMP/good.json" 2>&1)"
RC=$?
if [ "$RC" = 0 ]; then ok "--input - reads stdin"; else bad "--input - reads stdin" "rc=$RC; ${OUT:0:150}"; fi

# ------------------------------------------------------------------ 12. --quiet suppresses rows, keeps the verdict
OUT="$("$CHECK" --quiet --input "$TMP/mixed.json" 2>&1)"
RC=$?
if [ "$RC" = 1 ] && ! printf '%s\n' "$OUT" | grep -q '^MISSING' &&
  printf '%s\n' "$OUT" | grep -q '2 of 3'; then
  ok "--quiet suppresses rows but keeps the verdict"
else
  bad "--quiet suppresses rows but keeps the verdict" "rc=$RC; out: ${OUT:0:200}"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
