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

# ------------------------------------------------------------------ 13. the identifier must NAME something
# A well-formed date and reason are not enough: the contract calls a "merely prose 'waiting on
# upstream' record" under-specified, and such a line would otherwise satisfy every other check.
cat >"$TMP/prose-dated.json" <<'EOF'
[{"repo":"p","number":20,"body":"**Blocker:** waiting on upstream | last-verified 2026-08-01: no response"}]
EOF
expect_rc "dated prose with no identifier is MALFORMED" 1 "$TMP/prose-dated.json"

# ...while every identifier idiom actually in use must still pass. Measured across all 22 live
# blocker lines: 10 name an authority, 8 an owner/repo#N, and the rest a bare repo path, a bare
# issue reference, or a slug. A rule that rejected any of these would fire on correct work.
cat >"$TMP/idioms.json" <<'EOF'
[{"repo":"a","number":1,"body":"**Blocker:** loft-sh/vcluster#3805 | last-verified 2026-08-25: not shipped"},
 {"repo":"b","number":2,"body":"**Blocker:** maintainer authority - an org admin must set the property | last-verified 2026-08-25: still false"},
 {"repo":"c","number":3,"body":"**Blocker:** crossplane-contrib/provider-upjet-github (a settings resource) | last-verified 2026-08-25: not shipped"},
 {"repo":"d","number":4,"body":"**Blocker:** child #3274 (installation token) | last-verified 2026-08-24: not provisioned"},
 {"repo":"e","number":5,"body":"**Blocker:** maintainer authority (an account-scoped provider quota) | last-verified 2026-08-19: still limited"}]
EOF
expect_rc "every identifier idiom in live use still CONFORMS" 0 "$TMP/idioms.json"

# ------------------------------------------------------------------ 14. a timed-out search is UNKNOWN
# GitHub returns partial results with a MATCHING total_count when a search times out, so the
# fetched-vs-expected comparison agrees on a truncated set. `incomplete_results` is the only
# field that separates the two, and reading a truncated sweep as clean is the exact fail-open
# this check exists to prevent. Mocked `gh` so the case is hermetic.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Emits one search page that is TRUNCATED but internally consistent: total_count equals the
# number of items returned, so only incomplete_results reveals it.
cat <<'JSON'
{"total_count":1,"incomplete_results":true,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":1,"body":"no blocker line"}]}
JSON
EOF
chmod +x "$TMP/bin/gh"
OUT="$(PATH="$TMP/bin:$PATH" "$CHECK" --org devantler-tech 2>&1)"
RC=$?
if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q 'incomplete_results'; then
  ok "a timed-out search is UNKNOWN(2), not a clean sweep"
else
  bad "a timed-out search is UNKNOWN(2), not a clean sweep" "rc=$RC; out: ${OUT:0:200}"
fi

# CONTROL: the same mocked page WITHOUT the timeout flag must be evaluated normally, so the
# case above is proven to turn on incomplete_results rather than on the mock being rejected.
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"total_count":1,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":1,"body":"no blocker line"}]}
JSON
EOF
chmod +x "$TMP/bin/gh"
OUT="$(PATH="$TMP/bin:$PATH" "$CHECK" --org devantler-tech 2>&1)"
RC=$?
if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q 'MISSING'; then
  ok "control: the same page without the flag is evaluated normally"
else
  bad "control: the same page without the flag is evaluated normally" "rc=$RC; out: ${OUT:0:200}"
fi

# ------------------------------------------------------------------ 15. prose that LOOKS like an id
# An earlier revision accepted any hyphenated token as the identifier, so an ordinary compound
# word satisfied it. This is the reviewer's counterexample and it must stay rejected: there is no
# syntactic way to separate a deliberate slug from an incidental compound word, which is why the
# slug form was removed rather than narrowed.
cat >"$TMP/hyphen-prose.json" <<'EOF'
[{"repo":"p","number":21,"body":"**Blocker:** waiting on third-party response | last-verified 2026-08-25: no response"}]
EOF
expect_rc "hyphenated prose is not an identifier" 1 "$TMP/hyphen-prose.json"

# CONTROL: the same sentence carrying a real identifier must still pass, so the case above is
# shown to turn on the identifier rather than on the surrounding prose.
cat >"$TMP/hyphen-prose-ok.json" <<'EOF'
[{"repo":"p","number":22,"body":"**Blocker:** waiting on third-party response from owner/repo#7 | last-verified 2026-08-25: no response"}]
EOF
expect_rc "control: the same prose WITH an identifier conforms" 0 "$TMP/hyphen-prose-ok.json"

# ------------------------------------------------------------------ 16. the date must be a calendar date
# Digit counting alone accepts 2026-99-99, so a record that cannot represent a real verification
# date was reported as a clean verdict.
cat >"$TMP/baddate.json" <<'EOF'
[{"repo":"p","number":23,"body":"**Blocker:** owner/repo#7 | last-verified 2026-99-99: nope"}]
EOF
expect_rc "an impossible date is MALFORMED" 1 "$TMP/baddate.json"

cat >"$TMP/baddate2.json" <<'EOF'
[{"repo":"p","number":24,"body":"**Blocker:** owner/repo#7 | last-verified 2026-13-01: nope"}]
EOF
expect_rc "month 13 is MALFORMED" 1 "$TMP/baddate2.json"

# CONTROL: a boundary date that IS real must still pass, so the range check is not simply
# rejecting everything.
cat >"$TMP/gooddate.json" <<'EOF'
[{"repo":"p","number":25,"body":"**Blocker:** owner/repo#7 | last-verified 2026-12-31: nope"}]
EOF
expect_rc "control: a real boundary date conforms" 0 "$TMP/gooddate.json"

# ------------------------------------------------------------------ 17. archived repos are out of scope
# Archived repositories are outside the active portfolio and their open issues must not be able
# to fail this check. Assert the qualifier reaches the query, using a gh stub that records argv.
mkdir -p "$TMP/bin2"
cat >"$TMP/bin2/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ARGV_LOG:?}"
cat <<'JSON'
{"total_count":0,"incomplete_results":false,"items":[]}
JSON
EOF
chmod +x "$TMP/bin2/gh"
: >"$TMP/argv.log"
ARGV_LOG="$TMP/argv.log" PATH="$TMP/bin2:$PATH" "$CHECK" --org devantler-tech >/dev/null 2>&1
if grep -q 'archived:false' "$TMP/argv.log"; then
  ok "the org query excludes archived repositories"
else
  bad "the org query excludes archived repositories" "argv: $(cat "$TMP/argv.log")"
fi

# ------------------------------------------------------------------ 18. a URL is not an identifier
# The contract requires the identifier to be plain local data with no URL, because it may only
# ever be matched LOCALLY and must never choose a destination. The slug alternative is unanchored,
# so `github.com/owner` inside a link satisfied it and a record naming nothing but a link
# CONFORMED -- the indefinite skip this check exists to expose.
cat >"$TMP/url.json" <<'EOF'
[{"repo":"p","number":30,"body":"**Blocker:** https://github.com/owner/repo/issues/7 | last-verified 2026-08-25: not shipped"}]
EOF
expect_rc "a URL identifier is MALFORMED" 1 "$TMP/url.json"

# A scheme-less URL is the same class and must not slip past a scheme-only test.
cat >"$TMP/url-bare.json" <<'EOF'
[{"repo":"p","number":36,"body":"**Blocker:** github.com/owner/repo/issues/7 | last-verified 2026-08-25: not shipped"}]
EOF
expect_rc "a scheme-less URL identifier is MALFORMED" 1 "$TMP/url-bare.json"

# CONTROL: a record may legitimately NAME an identifier and also link to it. Rejecting that
# would fire on correct work, so URL tokens are stripped rather than poisoning the whole record.
cat >"$TMP/url-plus-id.json" <<'EOF'
[{"repo":"p","number":37,"body":"**Blocker:** owner/repo#7 (see https://github.com/owner/repo/issues/7) | last-verified 2026-08-25: x"}]
EOF
expect_rc "control: a real identifier alongside a link still CONFORMS" 0 "$TMP/url-plus-id.json"

# ------------------------------------------------------------------ 19. the date must be a real day
# Bounding month and day independently accepts a day that cannot exist in that month, so
# `2026-02-31` read as a verification date. The date is what makes a skip re-verifiable.
cat >"$TMP/feb31.json" <<'EOF'
[{"repo":"p","number":31,"body":"**Blocker:** owner/repo#7 | last-verified 2026-02-31: nope"}]
EOF
expect_rc "31 February is MALFORMED" 1 "$TMP/feb31.json"

cat >"$TMP/apr31.json" <<'EOF'
[{"repo":"p","number":40,"body":"**Blocker:** owner/repo#7 | last-verified 2026-04-31: nope"}]
EOF
expect_rc "31 April is MALFORMED" 1 "$TMP/apr31.json"

# Leap years must be computed, not assumed: these two differ ONLY in the year, so a check that
# hard-coded 28 or 29 days fails one of them.
cat >"$TMP/feb29-non.json" <<'EOF'
[{"repo":"p","number":38,"body":"**Blocker:** owner/repo#7 | last-verified 2026-02-29: nope"}]
EOF
expect_rc "29 February in a non-leap year is MALFORMED" 1 "$TMP/feb29-non.json"

cat >"$TMP/feb29-leap.json" <<'EOF'
[{"repo":"p","number":39,"body":"**Blocker:** owner/repo#7 | last-verified 2024-02-29: leap"}]
EOF
expect_rc "control: 29 February in a leap year CONFORMS" 0 "$TMP/feb29-leap.json"

# ------------------------------------------------------------------ 20. comments and fences hold no records
# A marker inside an HTML comment or a fenced example is not a visible status record, so treating
# it as one leaves the `blocked` label trusted over a body that shows no blocker metadata --
# recreating the indefinite skip. Note this file's fence handling is deliberate where AGENTS.md
# declines it for the disclosure classifier: there an unswallowed marker costs a re-askable steer,
# here it costs an issue parked forever, so the cheap direction is the opposite one.
cat >"$TMP/in-comment.json" <<'EOF'
[{"repo":"p","number":32,"body":"real text\n\n<!--\n**Blocker:** owner/repo#7 | last-verified 2026-08-25: stale\n-->\n\nmore"}]
EOF
expect_rc "a marker inside an HTML comment is MISSING" 1 "$TMP/in-comment.json"
expect_out "a commented marker reports MISSING" '^MISSING +p#32' "$TMP/in-comment.json"

cat >"$TMP/in-fence.json" <<'EOF'
[{"repo":"p","number":33,"body":"Example of the format:\n\n```\n**Blocker:** owner/repo#7 | last-verified 2026-08-25: example\n```\n\nend"}]
EOF
expect_rc "a marker inside a code fence is MISSING" 1 "$TMP/in-fence.json"

# CONTROL: an inline comment ELSEWHERE in the body must not suppress a real record, so the case
# above is shown to turn on the marker's context rather than on the body containing a comment.
cat >"$TMP/comment-elsewhere.json" <<'EOF'
[{"repo":"p","number":34,"body":"x <!-- hidden --> y\n\n**Blocker:** owner/repo#7 | last-verified 2026-08-25: real\n\nend"}]
EOF
expect_rc "control: a comment elsewhere does not hide a real record" 0 "$TMP/comment-elsewhere.json"

# CONTROL: the fence must TOGGLE, not swallow the rest of the body -- a record after a closed
# fence is still a record. Without this, "ignore fences" could pass by ignoring everything.
cat >"$TMP/after-fence.json" <<'EOF'
[{"repo":"p","number":35,"body":"```\nexample fence\n```\n\n**Blocker:** owner/repo#7 | last-verified 2026-08-25: real\n\nend"}]
EOF
expect_rc "control: a record after a closed fence still CONFORMS" 0 "$TMP/after-fence.json"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
