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
[{"repo":"a","number":1,"body":"lead\n\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: not shipped\n\ntail"}]
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
[{"repo":"e","number":5,"body":"**Blocker:** owner/repo#9 | upstream | last-verified 26-08-01: bad date"}]
EOF
expect_rc "two-digit year is MALFORMED" 1 "$TMP/date.json"

# ------------------------------------------------------------------ 5. THE WRAPPING REGRESSION
# A real body soft-wraps the blocker line. A line-anchored regex calls this MALFORMED even though
# it conforms (measured against platform#3274). Both halves are asserted, so a join that silently
# stops working is caught by the POSITIVE CONTROL rather than passing vacuously.
cat >"$TMP/wrapped.json" <<'EOF'
[{"repo":"c","number":3,"body":"**Blocker:** maintainer authority - an org-owned App with packages read, installed on at\nleast one tenant repository | upstream | last-verified 2026-08-21: not provisioned\n\nnext"}]
EOF
expect_rc "wrapped conforming line exits 0" 0 "$TMP/wrapped.json"

# POSITIVE CONTROL: the same text on ONE line must also conform. If this ever fails, the case
# above is proving nothing about wrapping -- it would be passing for an unrelated reason.
cat >"$TMP/unwrapped.json" <<'EOF'
[{"repo":"c","number":3,"body":"**Blocker:** maintainer authority - an org-owned App with packages read, installed on at least one tenant repository | upstream | last-verified 2026-08-21: not provisioned\n\nnext"}]
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
  echo "**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: not shipped"
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
printf '[{"repo":"f","number":6,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: not shipped\\r\\n\\r\\ntail"}]\n' >"$TMP/crlf.json"
expect_rc "CRLF body conforms" 0 "$TMP/crlf.json"

# ------------------------------------------------------------------ 8. counting is accurate
cat >"$TMP/mixed.json" <<'EOF'
[{"repo":"a","number":1,"body":"**Blocker:** o/r#1 | upstream | last-verified 2026-08-01: x"},
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

# ------------------------------------------------------------------ 12. --quiet drops CONFORMS rows ONLY: findings and the verdict survive
# The help text promises "print findings only"; a --quiet that also hid MISSING/MALFORMED/NO-ASK rows
# left an operator with a count and no issue ids to repair.
OUT="$("$CHECK" --quiet --input "$TMP/mixed.json" 2>&1)"
RC=$?
if [ "$RC" = 1 ] && ! printf '%s\n' "$OUT" | grep -q '^CONFORMS' &&
  printf '%s\n' "$OUT" | grep -qE '^MISSING +b#2' && printf '%s\n' "$OUT" | grep -qE '^MISSING +c#3' &&
  printf '%s\n' "$OUT" | grep -q '2 of 3'; then
  ok "--quiet drops CONFORMS rows but keeps every finding row and the verdict"
else
  bad "--quiet drops CONFORMS rows but keeps every finding row and the verdict" "rc=$RC; out: ${OUT:0:200}"
fi

# ------------------------------------------------------------------ 13. the identifier must NAME something
# A well-formed date and reason are not enough: the contract calls a "merely prose 'waiting on
# upstream' record" under-specified, and such a line would otherwise satisfy every other check.
cat >"$TMP/prose-dated.json" <<'EOF'
[{"repo":"p","number":20,"body":"**Blocker:** waiting on upstream | upstream | last-verified 2026-08-01: no response"}]
EOF
expect_rc "dated prose with no identifier is MALFORMED" 1 "$TMP/prose-dated.json"

# ...while every identifier idiom actually in use must still pass. Measured across all 22 live
# blocker lines: 10 name an authority, 8 an owner/repo#N, and the rest a bare repo path, a bare
# issue reference, or a slug. A rule that rejected any of these would fire on correct work.
cat >"$TMP/idioms.json" <<'EOF'
[{"repo":"a","number":1,"body":"**Blocker:** loft-sh/vcluster#3805 | upstream | last-verified 2026-08-25: not shipped"},
 {"repo":"b","number":2,"body":"**Blocker:** maintainer authority - an org admin must set the property | upstream | last-verified 2026-08-25: still false"},
 {"repo":"c","number":3,"body":"**Blocker:** crossplane-contrib/provider-upjet-github (a settings resource) | upstream | last-verified 2026-08-25: not shipped"},
 {"repo":"d","number":4,"body":"**Blocker:** child #3274 (installation token) | upstream | last-verified 2026-08-24: not provisioned"},
 {"repo":"e","number":5,"body":"**Blocker:** maintainer authority (an account-scoped provider quota) | upstream | last-verified 2026-08-19: still limited"}]
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
[{"repo":"p","number":21,"body":"**Blocker:** waiting on third-party response | upstream | last-verified 2026-08-25: no response"}]
EOF
expect_rc "hyphenated prose is not an identifier" 1 "$TMP/hyphen-prose.json"

# CONTROL: the same sentence carrying a real identifier must still pass, so the case above is
# shown to turn on the identifier rather than on the surrounding prose.
cat >"$TMP/hyphen-prose-ok.json" <<'EOF'
[{"repo":"p","number":22,"body":"**Blocker:** waiting on third-party response from owner/repo#7 | upstream | last-verified 2026-08-25: no response"}]
EOF
expect_rc "control: the same prose WITH an identifier conforms" 0 "$TMP/hyphen-prose-ok.json"

# ------------------------------------------------------------------ 16. the date must be a calendar date
# Digit counting alone accepts 2026-99-99, so a record that cannot represent a real verification
# date was reported as a clean verdict.
cat >"$TMP/baddate.json" <<'EOF'
[{"repo":"p","number":23,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-99-99: nope"}]
EOF
expect_rc "an impossible date is MALFORMED" 1 "$TMP/baddate.json"

cat >"$TMP/baddate2.json" <<'EOF'
[{"repo":"p","number":24,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-13-01: nope"}]
EOF
expect_rc "month 13 is MALFORMED" 1 "$TMP/baddate2.json"

# CONTROL: a boundary date that IS real must still pass, so the range check is not simply
# rejecting everything.
cat >"$TMP/gooddate.json" <<'EOF'
[{"repo":"p","number":25,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-12-31: nope"}]
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
[{"repo":"p","number":30,"body":"**Blocker:** https://github.com/owner/repo/issues/7 | upstream | last-verified 2026-08-25: not shipped"}]
EOF
expect_rc "a URL identifier is MALFORMED" 1 "$TMP/url.json"

# A scheme-less URL is the same class and must not slip past a scheme-only test.
cat >"$TMP/url-bare.json" <<'EOF'
[{"repo":"p","number":36,"body":"**Blocker:** github.com/owner/repo/issues/7 | upstream | last-verified 2026-08-25: not shipped"}]
EOF
expect_rc "a scheme-less URL identifier is MALFORMED" 1 "$TMP/url-bare.json"

# CONTROL: a record may legitimately NAME an identifier and also link to it. Rejecting that
# would fire on correct work, so URL tokens are stripped rather than poisoning the whole record.
cat >"$TMP/url-plus-id.json" <<'EOF'
[{"repo":"p","number":37,"body":"**Blocker:** owner/repo#7 (see https://github.com/owner/repo/issues/7) | upstream | last-verified 2026-08-25: x"}]
EOF
expect_rc "control: a real identifier alongside a link still CONFORMS" 0 "$TMP/url-plus-id.json"

# ------------------------------------------------------------------ 19. the date must be a real day
# Bounding month and day independently accepts a day that cannot exist in that month, so
# `2026-02-31` read as a verification date. The date is what makes a skip re-verifiable.
cat >"$TMP/feb31.json" <<'EOF'
[{"repo":"p","number":31,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-02-31: nope"}]
EOF
expect_rc "31 February is MALFORMED" 1 "$TMP/feb31.json"

cat >"$TMP/apr31.json" <<'EOF'
[{"repo":"p","number":40,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-04-31: nope"}]
EOF
expect_rc "31 April is MALFORMED" 1 "$TMP/apr31.json"

# Leap years must be computed, not assumed: these two differ ONLY in the year, so a check that
# hard-coded 28 or 29 days fails one of them.
cat >"$TMP/feb29-non.json" <<'EOF'
[{"repo":"p","number":38,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-02-29: nope"}]
EOF
expect_rc "29 February in a non-leap year is MALFORMED" 1 "$TMP/feb29-non.json"

cat >"$TMP/feb29-leap.json" <<'EOF'
[{"repo":"p","number":39,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2024-02-29: leap"}]
EOF
expect_rc "control: 29 February in a leap year CONFORMS" 0 "$TMP/feb29-leap.json"

# ------------------------------------------------------------------ 20. comments and fences hold no records
# A marker inside an HTML comment or a fenced example is not a visible status record, so treating
# it as one leaves the `blocked` label trusted over a body that shows no blocker metadata --
# recreating the indefinite skip. Note this file's fence handling is deliberate where AGENTS.md
# declines it for the disclosure classifier: there an unswallowed marker costs a re-askable steer,
# here it costs an issue parked forever, so the cheap direction is the opposite one.
cat >"$TMP/in-comment.json" <<'EOF'
[{"repo":"p","number":32,"body":"real text\n\n<!--\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: stale\n-->\n\nmore"}]
EOF
expect_rc "a marker inside an HTML comment is MISSING" 1 "$TMP/in-comment.json"
expect_out "a commented marker reports MISSING" '^MISSING +p#32' "$TMP/in-comment.json"

cat >"$TMP/in-fence.json" <<'EOF'
[{"repo":"p","number":33,"body":"Example of the format:\n\n```\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: example\n```\n\nend"}]
EOF
expect_rc "a marker inside a code fence is MISSING" 1 "$TMP/in-fence.json"

# CONTROL: an inline comment ELSEWHERE in the body must not suppress a real record, so the case
# above is shown to turn on the marker's context rather than on the body containing a comment.
cat >"$TMP/comment-elsewhere.json" <<'EOF'
[{"repo":"p","number":34,"body":"x <!-- hidden --> y\n\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: real\n\nend"}]
EOF
expect_rc "control: a comment elsewhere does not hide a real record" 0 "$TMP/comment-elsewhere.json"

# CONTROL: the fence must TOGGLE, not swallow the rest of the body -- a record after a closed
# fence is still a record. Without this, "ignore fences" could pass by ignoring everything.
cat >"$TMP/after-fence.json" <<'EOF'
[{"repo":"p","number":35,"body":"```\nexample fence\n```\n\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: real\n\nend"}]
EOF
expect_rc "control: a record after a closed fence still CONFORMS" 0 "$TMP/after-fence.json"

# ------------------------------------------------------------------ 21. fence RUN LENGTH and CHARACTER
# A plain open/close toggle ends the block on the first fence-looking line, so a ``` line INSIDE a
# ```` block closed it and the example beneath was read as a live record -- the same fail-open the
# fence handling exists to remove, one level down. CommonMark closes a fence only on a run of the
# SAME character, at least as long as the opening, carrying no info string.
#
# Built with printf rather than a heredoc: the fixtures are made OF fence delimiters, so embedding
# them in this file's own prose is what makes them easy to get subtly wrong.
printf 'Example:\n\n````\n```\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: example\n```\n````\n\nend\n' >"$TMP/fence4.txt"
jq -Rs '[{repo:"p",number:50,body:.}]' <"$TMP/fence4.txt" >"$TMP/fence4.json"
expect_rc "a shorter run inside a longer fence does not close it" 1 "$TMP/fence4.json"
expect_out "the 4-backtick fence body reports MISSING" '^MISSING +p#50' "$TMP/fence4.json"

# The character must match too: a ``` run cannot close a ~~~ fence.
printf 'Example:\n\n~~~\n```\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: example\n```\n~~~\n\nend\n' >"$TMP/fencex.txt"
jq -Rs '[{repo:"p",number:52,body:.}]' <"$TMP/fencex.txt" >"$TMP/fencex.json"
expect_rc "a mismatched fence character does not close it" 1 "$TMP/fencex.json"

# CONTROL: a fence that IS properly closed must release, or "never close" would pass every case
# above by simply swallowing the rest of the body. The record here sits after a closed 4-backtick
# fence and must conform.
printf 'Example:\n\n````\n```\ninner\n```\n````\n\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: real\n\nend\n' >"$TMP/fenceok.txt"
jq -Rs '[{repo:"p",number:54,body:.}]' <"$TMP/fenceok.txt" >"$TMP/fenceok.json"
expect_rc "control: a record after a closed 4-backtick fence CONFORMS" 0 "$TMP/fenceok.json"

# CONTROL: a LONGER closing run is legal, so it must close a shorter fence.
printf 'Example:\n\n```\ninner\n````\n\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: real\n\nend\n' >"$TMP/fencelong.txt"
jq -Rs '[{repo:"p",number:55,body:.}]' <"$TMP/fencelong.txt" >"$TMP/fencelong.json"
expect_rc "control: a longer closing run closes a shorter fence" 0 "$TMP/fencelong.json"

# ------------------------------------------------------------------ 22. comment stripping vs fence order
# HTML comments are stripped so a retired record inside <!-- --> cannot satisfy the check. That strip
# must NOT run inside a fence: there an <!-- --> run is literal code content, so removing it can
# FORGE a closing delimiter out of a commented prefix followed by a backtick run, ending the block
# early and exposing the example as a live record. Reported by CodeRabbit on PR #3053 -- the reported
# 4-backtick fixture did NOT reproduce (the run-length rule already rejects it); the equal-length
# one did, so both shapes are pinned here.
printf 'Example:\n\n```\n<!-- x -->```\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: example\n```\n\nend\n' >"$TMP/fencecmt.txt"
jq -Rs '[{repo:"p",number:56,body:.}]' <"$TMP/fencecmt.txt" >"$TMP/fencecmt.json"
expect_rc "a commented prefix cannot forge a closing fence" 1 "$TMP/fencecmt.json"
expect_out "the forged-close body reports MISSING" '^MISSING +p#56' "$TMP/fencecmt.json"

# The reported 4-backtick shape, pinned so the run-length rule that already covers it cannot regress.
printf 'Example:\n\n````\n<!-- ignored -->```\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: example\n````\n\nend\n' >"$TMP/fencecmt4.txt"
jq -Rs '[{repo:"p",number:57,body:.}]' <"$TMP/fencecmt4.txt" >"$TMP/fencecmt4.json"
expect_rc "a commented prefix cannot forge a shorter closing run either" 1 "$TMP/fencecmt4.json"

# CONTROL: the strip must still run OUTSIDE a fence, or suppressing it there would stop a
# comment-prefixed line from OPENING one -- exposing the example by the opposite route.
printf 'Example:\n\n<!-- lead-in -->```\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: example\n```\n\nend\n' >"$TMP/cmtopen.txt"
jq -Rs '[{repo:"p",number:58,body:.}]' <"$TMP/cmtopen.txt" >"$TMP/cmtopen.json"
expect_rc "control: a commented prefix still OPENS a fence outside one" 1 "$TMP/cmtopen.json"

# CONTROL: the fence still releases, so a real record after it conforms -- without this, "never
# close inside a fence" would pass every negative case above by swallowing the whole body.
printf 'Example:\n\n```\n<!-- x -->```\ninner\n```\n\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: real\n\nend\n' >"$TMP/fencecmtok.txt"
jq -Rs '[{repo:"p",number:59,body:.}]' <"$TMP/fencecmtok.txt" >"$TMP/fencecmtok.json"
expect_rc "control: a record after that fence still CONFORMS" 0 "$TMP/fencecmtok.json"

# CONTROL: multi-line comment suppression outside a fence is unchanged by the guard.
printf '<!--\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-25: retired\n-->\n\nend\n' >"$TMP/cmtmulti.txt"
jq -Rs '[{repo:"p",number:60,body:.}]' <"$TMP/cmtmulti.txt" >"$TMP/cmtmulti.json"
expect_rc "control: a multi-line commented record is still MISSING" 1 "$TMP/cmtmulti.json"


# ------------------------------------------------------------------ 23. CAUSE CLASS: explicit upstream
#
# The class is the segment immediately before `last-verified`. An `upstream` blocker clears itself
# when the dependency ships, so re-verification is exactly the right treatment and the check must
# not ask for anything more.
cat >"$TMP/cls-upstream.json" <<'EOF'
[{"repo":"a","number":1,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: not shipped"}]
EOF
expect_rc "explicit upstream class conforms" 0 "$TMP/cls-upstream.json"

# ------------------------------------------------------------------ 24. CAUSE CLASS: authority WITH an ask
cat >"$TMP/cls-auth-ok.json" <<'EOF'
[{"repo":"a","number":2,"body":"**Blocker:** maintainer authority — an R2 bucket | authority | last-verified 2026-09-01: not provisioned | asked push 2026-09-01"}]
EOF
# Pinned clock: the fixture's ask is dated 2026-09-01, so an unpinned run would read it STALE-ASK
# from 2026-09-16 on and fail CI purely because the calendar advanced.
OUT="$("$CHECK" --input "$TMP/cls-auth-ok.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "authority class with a fresh ask conforms"; else bad "authority class with a fresh ask conforms" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 25. THE DEFECT: authority with NO ask
#
# This is the whole point of the change. An authority blocker clears only when a person is asked,
# so re-verification alone guarantees it never clears. Measured 2026-09-05: 8 of 21 authority-class
# blocked issues org-wide carried no ask of any kind, the oldest 54 days.
cat >"$TMP/cls-auth-noask.json" <<'EOF'
[{"repo":"a","number":3,"body":"**Blocker:** maintainer authority — an R2 bucket | authority | last-verified 2026-09-01: not provisioned"}]
EOF
expect_rc "authority class with no ask is a finding" 1 "$TMP/cls-auth-noask.json"
expect_out "authority with no ask is reported as NO-ASK" '^NO-ASK +a#3' "$TMP/cls-auth-noask.json"

# ------------------------------------------------------------------ 26. NEGATIVE CONTROL
#
# The same body shape, differing ONLY in the class token, must NOT be flagged. Without this the
# check could be passing case 25 by flagging every line regardless of class.
cat >"$TMP/cls-upstream-noask.json" <<'EOF'
[{"repo":"a","number":4,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2026-09-01: not shipped"}]
EOF
expect_rc "NEGATIVE CONTROL: upstream with no ask is NOT flagged" 0 "$TMP/cls-upstream-noask.json"

# ------------------------------------------------------------------ 27. absent class is INFERRED
#
# Every live record predates this field, so refusing them would report 46 findings on day one and
# bury the real ones. An unclassed record is evaluated exactly as before -- and is marked so the
# migration stays visible.
cat >"$TMP/cls-legacy.json" <<'EOF'
[{"repo":"a","number":5,"body":"**Blocker:** owner/repo#7 | last-verified 2026-09-01: not shipped"}]
EOF
expect_rc "absent class is inferred, not refused" 0 "$TMP/cls-legacy.json"
expect_out "an unclassed record is marked legacy" 'legacy: no class token' "$TMP/cls-legacy.json"

# ------------------------------------------------------------------ 28. an unknown class token is MALFORMED
cat >"$TMP/cls-bogus.json" <<'EOF'
[{"repo":"a","number":6,"body":"**Blocker:** owner/repo#7 | sometimes | last-verified 2026-09-01: not shipped"}]
EOF
expect_rc "an unknown class token is a finding" 1 "$TMP/cls-bogus.json"

# ------------------------------------------------------------------ 29. an ask goes STALE on the cadence
#
# `--today` is passed explicitly so the case is hermetic; without it the suite would change verdict
# with the calendar, which is a test that eventually fails for no reason and gets deleted.
cat >"$TMP/cls-auth-stale.json" <<'EOF'
[{"repo":"a","number":7,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked push 2026-08-01"}]
EOF
OUT="$("$CHECK" --input "$TMP/cls-auth-stale.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ]; then ok "an ask older than the cadence is a finding"; else bad "an ask older than the cadence is a finding" "rc=$RC out=${OUT:0:200}"; fi
if printf '%s\n' "$OUT" | grep -qE '^STALE-ASK +a#7'; then ok "a stale ask is reported as STALE-ASK"; else bad "a stale ask is reported as STALE-ASK" "out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 30. BOUNDARY: an ask inside the cadence passes
cat >"$TMP/cls-auth-fresh.json" <<'EOF'
[{"repo":"a","number":8,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked push 2026-08-30"}]
EOF
OUT="$("$CHECK" --input "$TMP/cls-auth-fresh.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "BOUNDARY: an ask inside the cadence passes"; else bad "BOUNDARY: an ask inside the cadence passes" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 31. the ask date must be a real day
cat >"$TMP/cls-auth-baddate.json" <<'EOF'
[{"repo":"a","number":9,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked push 2026-02-31"}]
EOF
expect_rc "an ask carrying an impossible date is a finding" 1 "$TMP/cls-auth-baddate.json"


# ------------------------------------------------------------------ 32. THE MIGRATION-FREE WIN
#
# An unclassed record whose identifier already says "maintainer authority" is inferred as authority,
# so the ask requirement bites on the 19 live records that need it WITHOUT editing a single issue
# body first. This is the case that makes the change deliverable rather than merely correct.
cat >"$TMP/cls-legacy-auth.json" <<'EOF'
[{"repo":"a","number":10,"body":"**Blocker:** maintainer authority (Cloudflare account action) | last-verified 2026-09-01: not provisioned"}]
EOF
expect_rc "an unclassed AUTHORITY record still demands an ask" 1 "$TMP/cls-legacy-auth.json"
expect_out "and is reported as NO-ASK" '^NO-ASK +a#10' "$TMP/cls-legacy-auth.json"

# CONTROL: the same unclassed record WITH an ask conforms -- so case 32 is failing on the missing
# ask rather than on being unclassed.
cat >"$TMP/cls-legacy-auth-ok.json" <<'EOF'
[{"repo":"a","number":11,"body":"**Blocker:** maintainer authority (Cloudflare account action) | last-verified 2026-09-01: not provisioned | asked push 2026-09-01"}]
EOF
OUT="$("$CHECK" --input "$TMP/cls-legacy-auth-ok.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "CONTROL: the same unclassed record with an ask conforms"; else bad "CONTROL: the same unclassed record with an ask conforms" "rc=$RC out=${OUT:0:200}"; fi

# CONTROL: an explicit class OVERRIDES the inference -- an identifier mentioning "maintainer
# authority" that is explicitly classed `upstream` is not held to the ask requirement.
cat >"$TMP/cls-explicit-wins.json" <<'EOF'
[{"repo":"a","number":12,"body":"**Blocker:** maintainer authority (an account-scoped provider quota) | upstream | last-verified 2026-09-01: still limited"}]
EOF
expect_rc "CONTROL: an explicit class overrides the inference" 0 "$TMP/cls-explicit-wins.json"

# ------------------------------------------------------------------ 33. the ask CHANNEL is a closed set
#
# `issue` is not a channel that reaches the maintainer -- a GitHub comment is a record of an ask,
# not an attention channel -- so `asked issue <date>` must read as NO ask at all. Accepting any
# token here let exactly the parked-while-looking-handled record this check exists to find CONFORM.
cat >"$TMP/cls-auth-issue-channel.json" <<'EOF2'
[{"repo":"a","number":13,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked issue 2026-09-01"}]
EOF2
OUT="$("$CHECK" --input "$TMP/cls-auth-issue-channel.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ]; then ok "an ask on a non-attention channel is a finding"; else bad "an ask on a non-attention channel is a finding" "rc=$RC out=${OUT:0:200}"; fi
if printf '%s\n' "$OUT" | grep -qE '^NO-ASK +a#13'; then ok "and is reported as NO-ASK, not as delivered"; else bad "and is reported as NO-ASK, not as delivered" "out=${OUT:0:200}"; fi

# CONTROL: the two other named channels conform on the same body -- so case 33 fails on the
# channel token rather than on some other property of the line.
for ch in slack session; do
  printf '[{"repo":"a","number":14,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked %s 2026-09-01"}]\n' "$ch" >"$TMP/cls-auth-$ch.json"
  OUT="$("$CHECK" --input "$TMP/cls-auth-$ch.json" --today 2026-09-05 2>&1)"; RC=$?
  if [ "$RC" = 0 ]; then ok "CONTROL: an ask via '$ch' conforms"; else bad "CONTROL: an ask via '$ch' conforms" "rc=$RC out=${OUT:0:200}"; fi
done

# ------------------------------------------------------------------ 34. a FUTURE ask date is not a fresh ask
#
# `today - ask` goes negative for a date after today, and a plain "older than the cadence" test
# reads negative as fresh: an ask dated 2030-01-01 would bypass the re-raise cadence until 2030.
cat >"$TMP/cls-auth-future.json" <<'EOF2'
[{"repo":"a","number":15,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked push 2030-01-01"}]
EOF2
OUT="$("$CHECK" --input "$TMP/cls-auth-future.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ]; then ok "an ask dated after today is a finding"; else bad "an ask dated after today is a finding" "rc=$RC out=${OUT:0:200}"; fi
if printf '%s\n' "$OUT" | grep -qE '^MALFORMED +a#15'; then ok "a future ask is reported as MALFORMED"; else bad "a future ask is reported as MALFORMED" "out=${OUT:0:200}"; fi

# BOUNDARY: an ask dated exactly today is not future and conforms.
cat >"$TMP/cls-auth-today.json" <<'EOF2'
[{"repo":"a","number":16,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked push 2026-09-05"}]
EOF2
OUT="$("$CHECK" --input "$TMP/cls-auth-today.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "BOUNDARY: an ask dated today conforms"; else bad "BOUNDARY: an ask dated today conforms" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 35. `--today` must name a real day
#
# The clock the whole ask cadence is measured against was only shape-checked, so `2026-02-31`
# reached the day arithmetic and produced a verdict against a date that never happened.
OUT="$("$CHECK" --input "$TMP/cls-auth-ok.json" --today 2026-02-31 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "--today on an impossible date is a usage error"; else bad "--today on an impossible date is a usage error" "rc=$RC out=${OUT:0:200}"; fi
if printf '%s\n' "$OUT" | grep -q -- '--today must be a real'; then ok "and names --today as the cause"; else bad "and names --today as the cause" "out=${OUT:0:200}"; fi

# CONTROL: the well-formed shape is still what is rejected -- a real boundary date is accepted
# (on an upstream record, so no ask date can read as future against a February clock).
OUT="$("$CHECK" --input "$TMP/cls-upstream.json" --today 2026-02-28 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "CONTROL: --today on a real boundary date is accepted"; else bad "CONTROL: --today on a real boundary date is accepted" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 36. year zero is outside the arithmetic domain
# `days_from_civil` steps the year back for January and February, so year 0 computes with y=-1,
# where bash's truncating division disagrees with the algorithm's floor division: 0000-02-29 and
# 0000-03-01 collapse onto the same day count, and an ask dated AFTER today read as current.
cat >"$TMP/year0.json" <<'EOF2'
[{"repo":"p","number":60,"body":"**Blocker:** maintainer authority | authority | last-verified 0000-02-29: pending | asked push 0000-03-01"}]
EOF2
OUT="$("$CHECK" --input "$TMP/year0.json" --today 0000-02-29 --ask-max-age-days 0 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "--today in year zero is a usage error"; else bad "--today in year zero is a usage error" "rc=$RC out=${OUT:0:200}"; fi
# The same year-zero date inside a RECORD is a malformed record, not a verdict.
OUT="$("$CHECK" --input "$TMP/year0.json" --today 2026-09-05 --ask-max-age-days 0 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -qE '^MALFORMED +p#60'; then ok "a year-zero ask date is MALFORMED"; else bad "a year-zero ask date is MALFORMED" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: year 1 is inside the domain and still evaluates normally.
cat >"$TMP/year1.json" <<'EOF2'
[{"repo":"p","number":61,"body":"**Blocker:** maintainer authority | authority | last-verified 0001-03-01: pending | asked push 0001-03-01"}]
EOF2
OUT="$("$CHECK" --input "$TMP/year1.json" --today 0001-03-01 --ask-max-age-days 0 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "CONTROL: year one is inside the domain and conforms"; else bad "CONTROL: year one is inside the domain and conforms" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 37. the cadence must fit the integer comparison
# A digits-only check accepts a value past the 64-bit range; `[ a -gt b ]` then prints
# `integer expression expected` and evaluates FALSE, so a stale ask reported CONFORMS.
cat >"$TMP/stale-ask.json" <<'EOF2'
[{"repo":"p","number":62,"body":"**Blocker:** maintainer authority | authority | last-verified 2026-09-05: pending | asked push 2026-08-01"}]
EOF2
OUT="$("$CHECK" --input "$TMP/stale-ask.json" --today 2026-09-05 --ask-max-age-days 999999999999999999999999 2>&1)"; RC=$?
if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q -- 'at most 9 digits'; then ok "an out-of-range cadence is a usage error"; else bad "an out-of-range cadence is a usage error" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: the largest accepted cadence still evaluates and permits the same age.
OUT="$("$CHECK" --input "$TMP/stale-ask.json" --today 2026-09-05 --ask-max-age-days 999999999 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "CONTROL: a nine-digit cadence is accepted and evaluates"; else bad "CONTROL: a nine-digit cadence is accepted and evaluates" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: the default cadence still reports that same ask as STALE-ASK, so the bound changed no verdict.
OUT="$("$CHECK" --input "$TMP/stale-ask.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -qE '^STALE-ASK +p#62'; then ok "CONTROL: the default cadence still reports the stale ask"; else bad "CONTROL: the default cadence still reports the stale ask" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 39. --quiet keeps NO-ASK rows too (findings, not CONFORMS)
OUT="$("$CHECK" --quiet --input "$TMP/cls-legacy-auth.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -qE '^NO-ASK +a#10'; then ok "--quiet still prints the NO-ASK row"; else bad "--quiet still prints the NO-ASK row" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: a payload of only CONFORMS rows prints no row at all under --quiet
OUT="$("$CHECK" --quiet --input "$TMP/good.json" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! printf '%s\n' "$OUT" | grep -qE '^(CONFORMS|MISSING|MALFORMED|NO-ASK|STALE-ASK) '; then ok "CONTROL: --quiet on an all-conforming payload prints no row"; else bad "CONTROL: --quiet on an all-conforming payload prints no row" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 40. the legacy annotation reaches NON-conforming rows too
# An operator repairing a NO-ASK on a classless record must also be told the class token is missing;
# annotating only the CONFORMS branch left the migration invisible exactly where it is acted on.
OUT="$("$CHECK" --input "$TMP/cls-legacy-auth.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -qE '^NO-ASK +a#10 +\[legacy: no class token\]'; then ok "a legacy NO-ASK row carries the legacy annotation"; else bad "a legacy NO-ASK row carries the legacy annotation" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: an explicitly classed NO-ASK row carries NO legacy annotation
cat >"$TMP/cls-explicit-noask.json" <<'JSON'
[{"repo":"a","number":41,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned"}]
JSON
OUT="$("$CHECK" --input "$TMP/cls-explicit-noask.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -qE '^NO-ASK +a#41' && ! printf '%s\n' "$OUT" | grep -q 'legacy: no class token'; then ok "CONTROL: an explicitly classed NO-ASK row is not marked legacy"; else bad "CONTROL: an explicitly classed NO-ASK row is not marked legacy" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 41. trailing whitespace after the ask date is not a missing ask
# Markdown's two-space hard break is ordinary; an end-anchored regex read it as NO-ASK and prompted a repeat ask.
cat >"$TMP/ask-trailing-ws.json" <<'JSON'
[{"repo":"a","number":42,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked push 2026-09-01  "}]
JSON
OUT="$("$CHECK" --input "$TMP/ask-trailing-ws.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qE '^CONFORMS +a#42'; then ok "trailing whitespace after the ask date still conforms"; else bad "trailing whitespace after the ask date still conforms" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: trailing NON-whitespace after the date is still not an ask
cat >"$TMP/ask-trailing-text.json" <<'JSON'
[{"repo":"a","number":43,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked push 2026-09-01 maybe"}]
JSON
OUT="$("$CHECK" --input "$TMP/ask-trailing-text.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -qE '^NO-ASK +a#43'; then ok "CONTROL: trailing text after the ask date is still NO-ASK"; else bad "CONTROL: trailing text after the ask date is still NO-ASK" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 42. an EMPTY verification result is MALFORMED, ask or no ask
# `last-verified <date>: | asked push <date>` let the structure regex read the ask suffix as the result,
# so an authority record with a fresh ask and NO live verification evidence conformed.
cat >"$TMP/empty-result-ask.json" <<'JSON'
[{"repo":"a","number":44,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: | asked push 2026-09-01"}]
JSON
OUT="$("$CHECK" --input "$TMP/empty-result-ask.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -qE '^MALFORMED +a#44'; then ok "an authority record with an ask but no verification result is MALFORMED"; else bad "an authority record with an ask but no verification result is MALFORMED" "rc=$RC out=${OUT:0:200}"; fi
cat >"$TMP/empty-result-upstream.json" <<'JSON'
[{"repo":"a","number":45,"body":"**Blocker:** o/r#1 | upstream | last-verified 2026-08-01:   "}]
JSON
OUT="$("$CHECK" --input "$TMP/empty-result-upstream.json" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -qE '^MALFORMED +a#45'; then ok "an upstream record whose result is only whitespace is MALFORMED"; else bad "an upstream record whose result is only whitespace is MALFORMED" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: a one-word result with the same ask suffix still conforms
cat >"$TMP/short-result-ask.json" <<'JSON'
[{"repo":"a","number":46,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: pending | asked push 2026-09-01"}]
JSON
OUT="$("$CHECK" --input "$TMP/short-result-ask.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -qE '^CONFORMS +a#46'; then ok "CONTROL: a real result with the same ask suffix conforms"; else bad "CONTROL: a real result with the same ask suffix conforms" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 38. --help documents the class and the ask record
# A caller following the built-in help must not be led to write a classless authority record, which
# the legacy fallback reads as upstream and never asks for an ask.
OUT="$("$CHECK" --help 2>&1)"; RC=$?
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '| <class> | last-verified' && printf '%s\n' "$OUT" | grep -q '| authority | last-verified <YYYY-MM-DD>: <result> | asked <push|slack|session> <YYYY-MM-DD>' && printf '%s\n' "$OUT" | grep -q -- '--ask-max-age-days <n>'; then ok "--help shows the class token, the authority ask suffix and the cadence option"; else bad "--help shows the class token, the authority ask suffix and the cadence option" "rc=$RC out=${OUT:0:300}"; fi
if ! printf '%s\n' "$OUT" | grep -q '^set -euo pipefail'; then ok "and --help stops before the code"; else bad "and --help stops before the code" "help leaked code"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
