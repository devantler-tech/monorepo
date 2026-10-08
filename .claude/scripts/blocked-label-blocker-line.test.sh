#!/usr/bin/env bash
# Hermetic self-test for blocked-label-blocker-line.sh.
#
# No network and no real issue is touched: every case is a hand-built JSON payload fed through
# the --input seam. The forge path shares all of its evaluation logic with that seam, so the
# behaviour proven here is the behaviour that runs against the org.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
CHECK="$HERE/blocked-label-blocker-line.sh"
WRAPPER="$CHECK"
[ -x "$CHECK" ] || {
  echo "FATAL: $CHECK is not executable" >&2
  exit 2
}

TMP="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$TMP"
  if [ "${completed}" != 1 ]; then
    echo "blocked-label-blocker-line.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_exit EXIT

go -C "$HERE/blocked-label-blocker-line-go" test ./... || exit 2
go -C "$HERE/blocked-label-blocker-line-go" build -o "$TMP/guard" . || exit 2
# The fixtures below pin record SHAPES and carry fixed dates, so they run with the
# verification-age bound switched off; the STALE cases at the end pass --today and
# test the bound itself. Without this the suite would turn red as the calendar moves.
GUARD="$TMP/guard"
printf '#!/usr/bin/env bash\nexec "%s" --verify-max-age-days 999999999 "$@"\n' "$GUARD" >"$TMP/guard-shapes"
chmod +x "$TMP/guard-shapes"
CHECK="$TMP/guard-shapes"

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
  if grep -qE "$2" <<<"$OUT"; then ok "$1"; else bad "$1" "no match for /$2/; out: ${OUT:0:200}"; fi
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
if [ "$RC" = 2 ] && grep -q 'must match' <<<"$OUT"; then
  ok "malformed --org is refused"
else
  bad "malformed --org is refused" "rc=$RC; out: ${OUT:0:150}"
fi

# ------------------------------------------------------------------ 11. stdin seam
OUT="$("$CHECK" --input - <"$TMP/good.json" 2>&1)"
RC=$?
if [ "$RC" = 0 ]; then ok "--input - reads stdin"; else bad "--input - reads stdin" "rc=$RC; ${OUT:0:150}"; fi

# ------------------------------------------------------------------ 12. --quiet preserves finding rows and their exit status, without summaries
# The help text promises "print findings only"; a --quiet that also hid MISSING/MALFORMED/NO-ASK rows
# left an operator with a count and no issue ids to repair.
OUT="$("$CHECK" --quiet --input "$TMP/mixed.json" 2>&1)"
RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = $'MISSING    b#2\nMISSING    c#3' ]; then
  ok "--quiet prints every finding row without a summary"
else
  bad "--quiet prints every finding row without a summary" "rc=$RC; out: ${OUT:0:200}"
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
{"total_count":1,"incomplete_results":true,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":1,"labels":[{"name":"blocked"}],"body":"no blocker line"}]}
JSON
EOF
chmod +x "$TMP/bin/gh"
OUT="$(PATH="$TMP/bin:$PATH" "$CHECK" --org devantler-tech 2>&1)"
RC=$?
if [ "$RC" = 2 ] && grep -q 'incomplete_results' <<<"$OUT"; then
  ok "a timed-out search is UNKNOWN(2), not a clean sweep"
else
  bad "a timed-out search is UNKNOWN(2), not a clean sweep" "rc=$RC; out: ${OUT:0:200}"
fi

# CONTROL: the same mocked page WITHOUT the timeout flag must be evaluated normally, so the
# case above is proven to turn on incomplete_results rather than on the mock being rejected.
# The org read is two reads (#3415): the open issues, then the open pull requests.
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *is:pr*) echo '{"total_count":0,"incomplete_results":false,"items":[]}' ;;
  *) echo '{"total_count":1,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":1,"labels":[{"name":"blocked"}],"type":null,"assignees":[],"issue_dependencies_summary":{"blocked_by":0},"sub_issues_summary":{"total":0,"completed":0},"body":"no blocker line"}]}' ;;
esac
EOF
chmod +x "$TMP/bin/gh"
OUT="$(PATH="$TMP/bin:$PATH" "$CHECK" --org devantler-tech 2>&1)"
RC=$?
if [ "$RC" = 1 ] && grep -q 'MISSING' <<<"$OUT"; then
  ok "control: the same page without the flag is evaluated normally"
else
  bad "control: the same page without the flag is evaluated normally" "rc=$RC; out: ${OUT:0:200}"
fi

# The pull-request read decides which issues are in flight, so it fails closed like the issue
# read: a failure there is UNKNOWN, never a report built from the issues alone. The shim prints
# a COMPLETE page and then fails, so the guard has to refuse the read for its exit status: with
# no output at all, the empty read would be refused as truncated and prove nothing about the
# status. CONTROL: the same two pages from a shim that succeeds are a clean sweep.
for pr_status in 1 0; do
  cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
echo '{"total_count":0,"incomplete_results":false,"items":[]}'
case "\$*" in *is:pr*) exit $pr_status ;; esac
EOF
  chmod +x "$TMP/bin/gh"
  OUT="$(PATH="$TMP/bin:$PATH" "$CHECK" --org devantler-tech 2>&1)"
  RC=$?
  if [ "$pr_status" = 1 ]; then
    if [ "$RC" = 2 ] && grep -q 'forge read failed -- UNKNOWN' <<<"$OUT" && ! grep -q 'all 0 open' <<<"$OUT"; then
      ok "a pull-request read that fails after printing a complete page is UNKNOWN(2)"
    else
      bad "a pull-request read that fails after printing a complete page is UNKNOWN(2)" "rc=$RC; out: ${OUT:0:200}"
    fi
  elif [ "$RC" = 0 ] && grep -q 'all 0 open' <<<"$OUT"; then
    ok "CONTROL: the same pages from a read that succeeds are a clean sweep"
  else
    bad "CONTROL: the same pages from a read that succeeds are a clean sweep" "rc=$RC; out: ${OUT:0:200}"
  fi
done

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
[{"repo":"p","number":25,"body":"**Blocker:** owner/repo#7 | upstream | last-verified 2025-12-31: nope"}]
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
# Both reads, the issues and the pull requests, must carry the qualifier.
if [ "$(grep -c 'archived:false' "$TMP/argv.log")" = 2 ] && [ "$(grep -c . "$TMP/argv.log")" = 2 ] &&
  grep -q 'is:issue' "$TMP/argv.log" && grep -q 'is:pr' "$TMP/argv.log"; then
  ok "both org queries exclude archived repositories"
else
  bad "both org queries exclude archived repositories" "argv: $(cat "$TMP/argv.log")"
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
[{"repo":"a","number":2,"body":"**Blocker:** maintainer authority — an R2 bucket | authority | last-verified 2026-09-01: not provisioned | asked pr 2026-09-01"}]
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
[{"repo":"a","number":7,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked pr 2026-08-01"}]
EOF
OUT="$("$CHECK" --input "$TMP/cls-auth-stale.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ]; then ok "an ask older than the cadence is a finding"; else bad "an ask older than the cadence is a finding" "rc=$RC out=${OUT:0:200}"; fi
if grep -qE '^STALE-ASK +a#7' <<<"$OUT"; then ok "a stale ask is reported as STALE-ASK"; else bad "a stale ask is reported as STALE-ASK" "out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 30. BOUNDARY: an ask inside the cadence passes
cat >"$TMP/cls-auth-fresh.json" <<'EOF'
[{"repo":"a","number":8,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked pr 2026-08-30"}]
EOF
OUT="$("$CHECK" --input "$TMP/cls-auth-fresh.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "BOUNDARY: an ask inside the cadence passes"; else bad "BOUNDARY: an ask inside the cadence passes" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 31. the ask date must be a real day
cat >"$TMP/cls-auth-baddate.json" <<'EOF'
[{"repo":"a","number":9,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked pr 2026-02-31"}]
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
[{"repo":"a","number":11,"body":"**Blocker:** maintainer authority (Cloudflare account action) | last-verified 2026-09-01: not provisioned | asked pr 2026-09-01"}]
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
if grep -qE '^NO-ASK +a#13' <<<"$OUT"; then ok "and is reported as NO-ASK, not as delivered"; else bad "and is reported as NO-ASK, not as delivered" "out=${OUT:0:200}"; fi

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
[{"repo":"a","number":15,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked pr 2030-01-01"}]
EOF2
OUT="$("$CHECK" --input "$TMP/cls-auth-future.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ]; then ok "an ask dated after today is a finding"; else bad "an ask dated after today is a finding" "rc=$RC out=${OUT:0:200}"; fi
if grep -qE '^MALFORMED +a#15' <<<"$OUT"; then ok "a future ask is reported as MALFORMED"; else bad "a future ask is reported as MALFORMED" "out=${OUT:0:200}"; fi

# BOUNDARY: an ask dated exactly today is not future and conforms.
cat >"$TMP/cls-auth-today.json" <<'EOF2'
[{"repo":"a","number":16,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked pr 2026-09-05"}]
EOF2
OUT="$("$CHECK" --input "$TMP/cls-auth-today.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "BOUNDARY: an ask dated today conforms"; else bad "BOUNDARY: an ask dated today conforms" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 35. `--today` must name a real day
#
# The clock the whole ask cadence is measured against was only shape-checked, so `2026-02-31`
# reached the day arithmetic and produced a verdict against a date that never happened.
OUT="$("$CHECK" --input "$TMP/cls-auth-ok.json" --today 2026-02-31 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "--today on an impossible date is a usage error"; else bad "--today on an impossible date is a usage error" "rc=$RC out=${OUT:0:200}"; fi
if grep -q -- '--today must be a real' <<<"$OUT"; then ok "and names --today as the cause"; else bad "and names --today as the cause" "out=${OUT:0:200}"; fi

# CONTROL: the well-formed shape is still what is rejected -- a real boundary date is accepted
# (on an upstream record verified before it, so no date can read as future against the clock).
OUT="$("$CHECK" --input "$TMP/cls-upstream.json" --today 2026-12-31 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "CONTROL: --today on a real boundary date is accepted"; else bad "CONTROL: --today on a real boundary date is accepted" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 36. year zero is outside the arithmetic domain
# `days_from_civil` steps the year back for January and February, so year 0 computes with y=-1,
# where bash's truncating division disagrees with the algorithm's floor division: 0000-02-29 and
# 0000-03-01 collapse onto the same day count, and an ask dated AFTER today read as current.
cat >"$TMP/year0.json" <<'EOF2'
[{"repo":"p","number":60,"body":"**Blocker:** maintainer authority | authority | last-verified 0000-02-29: pending | asked pr 0000-03-01"}]
EOF2
OUT="$("$CHECK" --input "$TMP/year0.json" --today 0000-02-29 --ask-max-age-days 0 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "--today in year zero is a usage error"; else bad "--today in year zero is a usage error" "rc=$RC out=${OUT:0:200}"; fi
# The same year-zero date inside a RECORD is a malformed record, not a verdict.
OUT="$("$CHECK" --input "$TMP/year0.json" --today 2026-09-05 --ask-max-age-days 0 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -qE '^MALFORMED +p#60' <<<"$OUT"; then ok "a year-zero ask date is MALFORMED"; else bad "a year-zero ask date is MALFORMED" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: year 1 is inside the domain and still evaluates normally.
cat >"$TMP/year1.json" <<'EOF2'
[{"repo":"p","number":61,"body":"**Blocker:** maintainer authority | authority | last-verified 0001-03-01: pending | asked pr 0001-03-01"}]
EOF2
OUT="$("$CHECK" --input "$TMP/year1.json" --today 0001-03-01 --ask-max-age-days 0 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "CONTROL: year one is inside the domain and conforms"; else bad "CONTROL: year one is inside the domain and conforms" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 37. the cadence must fit the integer comparison
# A digits-only check accepts a value past the 64-bit range; `[ a -gt b ]` then prints
# `integer expression expected` and evaluates FALSE, so a stale ask reported CONFORMS.
cat >"$TMP/stale-ask.json" <<'EOF2'
[{"repo":"p","number":62,"body":"**Blocker:** maintainer authority | authority | last-verified 2026-09-05: pending | asked pr 2026-08-01"}]
EOF2
OUT="$("$CHECK" --input "$TMP/stale-ask.json" --today 2026-09-05 --ask-max-age-days 999999999999999999999999 2>&1)"; RC=$?
if [ "$RC" = 2 ] && grep -q -- 'at most 9 digits' <<<"$OUT"; then ok "an out-of-range cadence is a usage error"; else bad "an out-of-range cadence is a usage error" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: the largest accepted cadence still evaluates and permits the same age.
OUT="$("$CHECK" --input "$TMP/stale-ask.json" --today 2026-09-05 --ask-max-age-days 999999999 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "CONTROL: a nine-digit cadence is accepted and evaluates"; else bad "CONTROL: a nine-digit cadence is accepted and evaluates" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: the default cadence still reports that same ask as STALE-ASK, so the bound changed no verdict.
OUT="$("$CHECK" --input "$TMP/stale-ask.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -qE '^STALE-ASK +p#62' <<<"$OUT"; then ok "CONTROL: the default cadence still reports the stale ask"; else bad "CONTROL: the default cadence still reports the stale ask" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 39. --quiet keeps NO-ASK rows too (findings, not CONFORMS)
OUT="$("$CHECK" --quiet --input "$TMP/cls-legacy-auth.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -qE '^NO-ASK +a#10' <<<"$OUT"; then ok "--quiet still prints the NO-ASK row"; else bad "--quiet still prints the NO-ASK row" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: a payload of only CONFORMS rows prints no row at all under --quiet
OUT="$("$CHECK" --quiet --input "$TMP/good.json" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! grep -qE '^(CONFORMS|MISSING|MALFORMED|NO-ASK|STALE-ASK) ' <<<"$OUT"; then ok "CONTROL: --quiet on an all-conforming payload prints no row"; else bad "CONTROL: --quiet on an all-conforming payload prints no row" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 40. the legacy annotation reaches NON-conforming rows too
# An operator repairing a NO-ASK on a classless record must also be told the class token is missing;
# annotating only the CONFORMS branch left the migration invisible exactly where it is acted on.
OUT="$("$CHECK" --input "$TMP/cls-legacy-auth.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -qE '^NO-ASK +a#10 +\[legacy: no class token\]' <<<"$OUT"; then ok "a legacy NO-ASK row carries the legacy annotation"; else bad "a legacy NO-ASK row carries the legacy annotation" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: an explicitly classed NO-ASK row carries NO legacy annotation
cat >"$TMP/cls-explicit-noask.json" <<'JSON'
[{"repo":"a","number":41,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned"}]
JSON
OUT="$("$CHECK" --input "$TMP/cls-explicit-noask.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -qE '^NO-ASK +a#41' <<<"$OUT" && ! grep -q 'legacy: no class token' <<<"$OUT"; then ok "CONTROL: an explicitly classed NO-ASK row is not marked legacy"; else bad "CONTROL: an explicitly classed NO-ASK row is not marked legacy" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 41. trailing whitespace after the ask date is not a missing ask
# Markdown's two-space hard break is ordinary; an end-anchored regex read it as NO-ASK and prompted a repeat ask.
cat >"$TMP/ask-trailing-ws.json" <<'JSON'
[{"repo":"a","number":42,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked pr 2026-09-01  "}]
JSON
OUT="$("$CHECK" --input "$TMP/ask-trailing-ws.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -qE '^CONFORMS +a#42' <<<"$OUT"; then ok "trailing whitespace after the ask date still conforms"; else bad "trailing whitespace after the ask date still conforms" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: trailing NON-whitespace after the date is still not an ask
cat >"$TMP/ask-trailing-text.json" <<'JSON'
[{"repo":"a","number":43,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: not provisioned | asked pr 2026-09-01 maybe"}]
JSON
OUT="$("$CHECK" --input "$TMP/ask-trailing-text.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -qE '^NO-ASK +a#43' <<<"$OUT"; then ok "CONTROL: trailing text after the ask date is still NO-ASK"; else bad "CONTROL: trailing text after the ask date is still NO-ASK" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 42. an EMPTY verification result is MALFORMED, ask or no ask
# `last-verified <date>: | asked pr <date>` let the structure regex read the ask suffix as the result,
# so an authority record with a fresh ask and NO live verification evidence conformed.
cat >"$TMP/empty-result-ask.json" <<'JSON'
[{"repo":"a","number":44,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: | asked pr 2026-09-01"}]
JSON
OUT="$("$CHECK" --input "$TMP/empty-result-ask.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -qE '^MALFORMED +a#44' <<<"$OUT"; then ok "an authority record with an ask but no verification result is MALFORMED"; else bad "an authority record with an ask but no verification result is MALFORMED" "rc=$RC out=${OUT:0:200}"; fi
cat >"$TMP/empty-result-upstream.json" <<'JSON'
[{"repo":"a","number":45,"body":"**Blocker:** o/r#1 | upstream | last-verified 2026-08-01:   "}]
JSON
OUT="$("$CHECK" --input "$TMP/empty-result-upstream.json" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -qE '^MALFORMED +a#45' <<<"$OUT"; then ok "an upstream record whose result is only whitespace is MALFORMED"; else bad "an upstream record whose result is only whitespace is MALFORMED" "rc=$RC out=${OUT:0:200}"; fi
# CONTROL: a one-word result with the same ask suffix still conforms
cat >"$TMP/short-result-ask.json" <<'JSON'
[{"repo":"a","number":46,"body":"**Blocker:** maintainer authority — a bucket | authority | last-verified 2026-09-01: pending | asked pr 2026-09-01"}]
JSON
OUT="$("$CHECK" --input "$TMP/short-result-ask.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -qE '^CONFORMS +a#46' <<<"$OUT"; then ok "CONTROL: a real result with the same ask suffix conforms"; else bad "CONTROL: a real result with the same ask suffix conforms" "rc=$RC out=${OUT:0:200}"; fi

# ------------------------------------------------------------------ 38. --help documents the class and the ask record
# A caller following the built-in help must not be led to write a classless authority record, which
# the legacy fallback reads as upstream and never asks for an ask.
OUT="$("$CHECK" --help 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q '| <blocker-kind> | last-verified' <<<"$OUT" && grep -q '| authority | last-verified <YYYY-MM-DD>: <result> | asked <pr|slack|session> <YYYY-MM-DD>' <<<"$OUT" && grep -q -- '--ask-max-age-days <n>' <<<"$OUT"; then ok "--help shows the class token, the authority ask suffix and the cadence option"; else bad "--help shows the class token, the authority ask suffix and the cadence option" "rc=$RC out=${OUT:0:300}"; fi
if ! grep -q '^set -euo pipefail' <<<"$OUT"; then ok "and --help stops before the code"; else bad "and --help stops before the code" "help leaked code"; fi

# ------------------------------------------------------------------ 43. --help and the guides define the same ask channels
# A caller reading only --help has no other definition of the channels. The help once sent a Slack
# ask to "the declared Slack channel" while the guides send it to the maintainer's self-DM, because
# every channel in the workspace is public, and it never said `push` is excluded (#3784). So the
# vocabulary is read out of the guide's own ask-record rule, and the help and the check are both
# held to it: a token or an exclusion that changes in the guide alone turns this red.
RULE_GUIDE="$HERE/../guides/work-selection.md"
DESTINATION_GUIDE="$HERE/../guides/maintainer-channels.md"
flat() { tr '\n' ' ' | tr -s '[:space:]' ' '; }
# Every backticked span is a token, however it is spelt. A pattern that knew only lowercase words
# would never examine `self-dm`, `SMS` or `dm2`, and a token nobody examined passes every check.
# shellcheck disable=SC2016 # literal backticks: the guide marks each token up as code
tokens() { { grep -o '`[^`]*`' || true; } | tr -d '`' | paste -sd'|' -; }
# section <file> <start> [<end>]: the lines from the one holding <start> up to the first later line
# holding <end> (no <end>: the next blank line), flattened. It prints nothing unless BOTH anchors
# were seen, so a renamed end anchor cannot stretch the span to the end of the file. The anchors
# travel through the environment because `awk -v` would process their backslashes.
section() {
  SECTION_START="$2" SECTION_END="${3:-}" awk '
    BEGIN { a = ENVIRON["SECTION_START"]; b = ENVIRON["SECTION_END"] }
    !inside {
      if (index($0, a)) { inside = 1; buf = $0 "\n" }
      next
    }
    (b == "" ? ($0 ~ /^[[:space:]]*$/) : index($0, b)) { printf "%s", buf; exit }
    { buf = buf $0 "\n" }
  ' "$1" | flat
}
# rule_tokens <rule> <start> <end>: the tokens between two clauses of the rule, or nothing unless
# both clauses are there in that order -- without them the span would be the whole rule.
rule_tokens() {
  local span
  case "$1" in
    *"$2"*"$3"*)
      span=${1#*"$2"}
      span=${span%%"$3"*}
      tokens <<<"$span"
      ;;
  esac
}
# shellcheck disable=SC2016
ASK_RULE="$(section "$RULE_GUIDE" '**An `authority` line MUST also record the ask')"
SLACK_DESTINATION="$(section "$DESTINATION_GUIDE" '- **Destination:**' '- **Surface:**')"
"$CHECK" --help >"$TMP/help.txt" 2>&1
HELP_CHANNELS="$(section "$TMP/help.txt" 'Ask channels:')"
GUIDE_CHANNELS="$(rule_tokens "$ASK_RULE" 'names where it actually landed' 'No other word is a channel token')"
GUIDE_EXCLUDED="$(rule_tokens "$ASK_RULE" 'That includes' 'Re-raise on a cadence')"
HELP_EXCLUDED=""
case "$HELP_CHANNELS" in
  *'No other word is a channel token'*) HELP_EXCLUDED="${HELP_CHANNELS#*No other word is a channel token}" ;;
esac
# Fail closed, and name the first anchor that went: an empty span says nothing about why.
MISSING_ANCHOR=""
missing() { MISSING_ANCHOR="${MISSING_ANCHOR:-$1}"; }
# shellcheck disable=SC2016
grep -qF -- '**An `authority` line MUST also record the ask' "$RULE_GUIDE" ||
  missing 'work-selection.md has no "**An `authority` line MUST also record the ask" rule'
[ -n "$ASK_RULE" ] || missing "the ask-record rule in work-selection.md has no blank line ending it"
for anchor in 'names where it actually landed' 'No other word is a channel token' 'That includes' 'Re-raise on a cadence'; do
  case "$ASK_RULE" in *"$anchor"*) ;; *) missing "the ask-record rule in work-selection.md lacks '$anchor'" ;; esac
done
for anchor in '- **Destination:**' '- **Surface:**'; do
  grep -qF -- "$anchor" "$DESTINATION_GUIDE" || missing "maintainer-channels.md has no '$anchor' bullet"
done
[ -n "$SLACK_DESTINATION" ] || missing "maintainer-channels.md has no '- **Surface:**' bullet after '- **Destination:**'"
for anchor in 'Ask channels:' 'No other word is a channel token'; do
  case "$HELP_CHANNELS" in *"$anchor"*) ;; *) missing "the Ask channels paragraph of --help lacks '$anchor'" ;; esac
done
if [ -z "$MISSING_ANCHOR" ] && [ -n "$GUIDE_CHANNELS" ] && [ -n "$GUIDE_EXCLUDED" ]; then
  ok "the guides' ask-record rule and Slack destination, and the help's channel paragraph, are found"
else
  bad "the guides' ask-record rule and Slack destination, and the help's channel paragraph, are found" "${MISSING_ANCHOR:-every anchor is present, but out of order or around no token}; channels='$GUIDE_CHANNELS' excluded='$GUIDE_EXCLUDED'"
fi
# MUTATION: with its end anchor renamed, the destination reads as not found instead of running on
# to the end of the guide.
sed 's/- \*\*Surface:\*\*/- **Tooling:**/' "$DESTINATION_GUIDE" >"$TMP/destination-without-end.md"
if ! cmp -s "$DESTINATION_GUIDE" "$TMP/destination-without-end.md" && [ -z "$(section "$TMP/destination-without-end.md" '- **Destination:**' '- **Surface:**')" ]; then
  ok "MUTATION: a section whose end anchor is gone is not read to the end of the file"
else
  bad "MUTATION: a section whose end anchor is gone is not read to the end of the file" "the mutation changed nothing, or the span was still returned"
fi
help_advertises() { grep -qF "| asked <$1> <YYYY-MM-DD>" "$TMP/help.txt"; } # the grammar names exactly these
if help_advertises "$GUIDE_CHANNELS"; then
  ok "--help advertises exactly the guide's channel tokens"
else
  bad "--help advertises exactly the guide's channel tokens" "guide='$GUIDE_CHANNELS'"
fi
# MUTATION: a channel the guide spells with a capital, a hyphen or a digit is read out of it like any
# other. Unexamined, it would leave the comparison above green while the guide named a channel the
# help never lists and the check reads as NO-ASK.
# shellcheck disable=SC2016
MUTATED_RULE="$(FROM='and `session` the native' TO='`SMS` a text, `self-dm` a second DM, `dm2` a third, and `session` the native' awk '
  (i = index($0, ENVIRON["FROM"])) { $0 = substr($0, 1, i - 1) ENVIRON["TO"] substr($0, i + length(ENVIRON["FROM"])) }
  { print }' <<<"$ASK_RULE")"
MUTATED_CHANNELS="$(rule_tokens "$MUTATED_RULE" 'names where it actually landed' 'No other word is a channel token')"
if [ "$MUTATED_CHANNELS" = 'pr|slack|SMS|self-dm|dm2|session' ] && ! help_advertises "$MUTATED_CHANNELS"; then
  ok "MUTATION: a guide channel of any spelling is read, and turns the comparison red"
else
  bad "MUTATION: a guide channel of any spelling is read, and turns the comparison red" "read '$MUTATED_CHANNELS' from the mutated rule"
fi
ask_verdict() { # word -> the check's verdict on an authority record asked through it
  printf '[{"repo":"a","number":80,"body":"**Blocker:** maintainer authority | authority | last-verified 2026-09-01: pending | asked %s 2026-09-01"}]\n' "$1" >"$TMP/help-vocabulary.json"
  "$CHECK" --input "$TMP/help-vocabulary.json" --today 2026-09-05 2>&1 | awk 'NR == 1 { print $1 }'
}
IFS='|' read -r -a guide_channels <<<"$GUIDE_CHANNELS"
for token in "${guide_channels[@]:-}"; do
  if [ -n "$token" ] && grep -qF " $token = " <<<"$HELP_CHANNELS" && [ "$(ask_verdict "$token")" = CONFORMS ]; then
    ok "--help defines the guide's channel '$token', and the check accepts it"
  else
    bad "--help defines the guide's channel '$token', and the check accepts it" "verdict=$(ask_verdict "$token") help=${HELP_CHANNELS:0:200}"
  fi
done
# The meaning, not only the token. Each row is a clause a guide states and the clause that carries
# it in the help; both sides are asserted, so rewording either one prompts the other. A row that
# names a token must open on it, and an `excluded` row is looked for only in the sentence of the
# help that rules words out, so a word the help merely uses elsewhere cannot pass for its exclusion.
CLAUSE_TOKENS="|"
while IFS='@' read -r source token guide_clause help_clause; do
  case "$source" in
    rule) guide_text="$ASK_RULE" help_text="$HELP_CHANNELS" ;;
    excluded) guide_text="$ASK_RULE" help_text="$HELP_EXCLUDED" ;;
    *) guide_text="$SLACK_DESTINATION" help_text="$HELP_CHANNELS" ;;
  esac
  case "$guide_clause" in "${token:+\`$token\`}"*) about_token=1 ;; *) about_token=0 ;; esac
  if [ "$about_token" = 1 ] && grep -qF -- "$guide_clause" <<<"$guide_text" && grep -qF -- "$help_clause" <<<"$help_text"; then
    ok "--help carries the guide's '$guide_clause'"
    [ "$source" != excluded ] || CLAUSE_TOKENS="$CLAUSE_TOKENS$token|"
  else
    bad "--help carries the guide's '$guide_clause'" "the guide must still say it, opening on its token '$token', and the help must say '$help_clause'"
  fi
done <<'CLAUSES'
rule@slack@`slack` the Slack DM to his own user@slack = the Slack DM to the maintainer's own user
destination@@**Destination:** his self-DM@(his self-DM), never a Slack channel
destination@@never a channel. Every channel in the workspace is public@never a Slack channel, because every channel in the workspace is public
excluded@push@`push`, whether it means a git push or the runtime's push notification@push, whether it means a git push or the runtime's push notification
excluded@issue@`issue`: a GitHub comment is a durable **record** of an ask@issue: a GitHub comment records an ask and is not one
CLAUSES
# ruled_out <word>: an `excluded` row above holds for it, and the check reads it as NO-ASK.
ruled_out() {
  case "$CLAUSE_TOKENS" in *"|$1|"*) ;; *) return 1 ;; esac
  [ "$(ask_verdict "$1")" = NO-ASK ]
}
IFS='|' read -r -a guide_excluded <<<"$GUIDE_EXCLUDED"
for word in "${guide_excluded[@]:-}"; do
  if [ -n "$word" ] && ruled_out "$word"; then
    ok "--help rules out the guide's non-channel '$word', and the check reads it as NO-ASK"
  else
    bad "--help rules out the guide's non-channel '$word', and the check reads it as NO-ASK" "it needs an 'excluded' row in CLAUSES that holds (rows hold for '$CLAUSE_TOKENS'); verdict=$(ask_verdict "$word")"
  fi
done
# MUTATION: the help says "a GitHub comment" and "the check reads" in passing, and the check reads
# either word as NO-ASK. Neither counts as ruled out unless a row says so.
for word in comment check; do
  if grep -qw -- "$word" <<<"$HELP_EXCLUDED" && [ "$(ask_verdict "$word")" = NO-ASK ] && ! ruled_out "$word"; then
    ok "MUTATION: '$word', which the help only uses in passing, is not ruled out without a row"
  else
    bad "MUTATION: '$word', which the help only uses in passing, is not ruled out without a row" "the control needs the word in the help's exclusion sentence, and no row for it"
  fi
done

# Current-head review regressions: exercise the public CLI with literal records.
cat >"$TMP/authority-description.json" <<'JSON'
[{"repo":"a","number":70,"body":"**Blocker:** Cloudflare account action | authority | last-verified 2026-09-01: pending | asked session 2026-09-01"}]
JSON
OUT="$("$CHECK" --input "$TMP/authority-description.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "explicit authority accepts a descriptive account action"; else bad "explicit authority accepts a descriptive account action" "rc=$RC out=$OUT"; fi
cat >"$TMP/duplicate-kind.json" <<'JSON'
[{"repo":"a","number":71,"body":"**Blocker:** owner/repo#1 | authority | upstream | last-verified 2026-09-01: pending"}]
JSON
OUT="$("$CHECK" --input "$TMP/duplicate-kind.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -q '^MALFORMED' <<<"$OUT"; then ok "multiple blocker kinds cannot bypass the authority ask"; else bad "multiple blocker kinds cannot bypass the authority ask" "rc=$RC out=$OUT"; fi
cat >"$TMP/pr-ask.json" <<'JSON'
[{"repo":"a","number":72,"body":"**Blocker:** maintainer authority | authority | last-verified 2026-09-01: outage-cause=credentials/auth; access is still missing | asked pr 2026-09-01"}]
JSON
OUT="$("$CHECK" --input "$TMP/pr-ask.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "a draft PR ask and separate outage cause conform"; else bad "a draft PR ask and separate outage cause conform" "rc=$RC out=$OUT"; fi

# Exercise digest flag plumbing through the compiled CLI with both selected and
# excluded records; direct run() tests cannot catch a main() argument regression.
cat >"$TMP/ask-digest.json" <<'JSON'
[{"repo":"pending","number":73,"body":"**Blocker:** Grant pending access | authority | last-verified 2026-09-05: unavailable"},
 {"repo":"fresh","number":74,"body":"**Blocker:** Already requested access | authority | last-verified 2026-09-05: unavailable | asked session 2026-09-05"}]
JSON
OUT="$("$CHECK" --ask-digest --input "$TMP/ask-digest.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -q '^ASK DIGEST -- 1 ' <<<"$OUT" &&
  grep -q '^  > Grant pending access$' <<<"$OUT" &&
  ! grep -qE 'fresh|Already requested access' <<<"$OUT"; then
  ok "compiled CLI emits the digest and excludes a fresh ask"
else
  bad "compiled CLI emits the digest and excludes a fresh ask" "rc=$RC out=$OUT"
fi

# Exercise the installed entrypoint as a caller, including stdin/argument forwarding
# and both successful and findings exit codes. Keep the large fixture suite fast
# by running its individual cases through the compiled binary above.
OUT="$("$WRAPPER" --quiet --verify-max-age-days 999999999 --input "$TMP/good.json" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "shell entrypoint forwards quiet success"; else bad "shell entrypoint forwards quiet success" "rc=$RC out=$OUT"; fi
OUT="$("$WRAPPER" --quiet --input - <"$TMP/missing.json" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = 'MISSING    b#2' ]; then ok "shell entrypoint forwards stdin and findings status"; else bad "shell entrypoint forwards stdin and findings status" "rc=$RC out=$OUT"; fi

# A record whose shape conforms but whose last verification is older than the bound
# is a finding (#3161): skipping a blocked issue needs a live re-check, and a label
# never expires. These run the unwrapped guard, so the default bound applies.
printf '[{"repo":"s","number":1,"body":"**Blocker:** o/r#7 | upstream | last-verified 2026-09-01: pending"}]' >"$TMP/verify-age.json"
OUT="$("$GUARD" --input "$TMP/verify-age.json" --today 2026-09-08 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q '^CONFORMS' <<<"$OUT"; then ok "a record verified exactly 7 days ago conforms"; else bad "a record verified exactly 7 days ago conforms" "rc=$RC out=$OUT"; fi
OUT="$("$GUARD" --input "$TMP/verify-age.json" --today 2026-09-09 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -q '^STALE      s#1' <<<"$OUT"; then ok "a record verified 8 days ago is STALE by default"; else bad "a record verified 8 days ago is STALE by default" "rc=$RC out=$OUT"; fi
OUT="$("$GUARD" --input "$TMP/verify-age.json" --today 2026-09-09 --verify-max-age-days 30 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then ok "the verification bound is a flag"; else bad "the verification bound is a flag" "rc=$RC out=$OUT"; fi
OUT="$("$GUARD" --input "$TMP/verify-age.json" --today 2026-08-31 2>&1)"; RC=$?
if [ "$RC" = 1 ] && grep -q '^MALFORMED' <<<"$OUT"; then ok "a future verification date is never fresh"; else bad "a future verification date is never fresh" "rc=$RC out=$OUT"; fi

# A declared blocker on an issue without the blocked label is its own finding class
# (#3142); "**Blocker:** none" and a record-less unlabelled issue are not findings.
cat >"$TMP/unlabelled.json" <<'EOF'
[{"repo":"u","number":1,"labels":[{"name":"bug"}],"body":"**Blocker:** maintainer authority: sign the release"},
 {"repo":"u","number":2,"labels":[],"type":null,"body":"**Blocker:** none — agent-actionable"},
 {"repo":"u","number":3,"labels":[],"type":null,"body":"plain work"}]
EOF
OUT="$("$WRAPPER" --quiet --input "$TMP/unlabelled.json" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = 'UNLABELLED u#1  >>**Blocker:** maintainer authority: sign the release' ]; then ok "an unlabelled declared blocker is UNLABELLED, and none is skipped"; else bad "an unlabelled declared blocker is UNLABELLED, and none is skipped" "rc=$RC out=$OUT"; fi

# A Security issue nobody has started, carrying neither the label nor a declared blocker, is its
# own finding class (#3415): why it is unstarted lives only in a run's memory. The Bug beside it
# is the same in every other respect and is not reported, because only Security outranks every
# other issue whatever its age.
# unstarted <number> <type> <created_at> <assignees> <native-blocker member, or nothing> <body>
unstarted() {
  printf '{"repo":"s","number":%s,"labels":[],"type":{"name":"%s"},"created_at":"%s","assignees":%s,%s"sub_issues_summary":{"total":0,"completed":0},"body":"%s"}' "$@"
}
no_blocker='"issue_dependencies_summary":{"blocked_by":0},'
parked_security="$(unstarted 1 Security 2026-09-01T00:00:00Z '[]' "$no_blocker" 'plain work')"
unrecorded_row='UNRECORDED s#1  opened 2026-09-01, unstarted for 19 day(s)'
printf '[%s,%s]\n' "$parked_security" "$(unstarted 2 Bug 2026-09-01T00:00:00Z '[]' "$no_blocker" 'plain work')" >"$TMP/unrecorded.json"
OUT="$("$WRAPPER" --quiet --input "$TMP/unrecorded.json" --today 2026-09-20 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "$unrecorded_row with no record" ]; then ok "an unstarted Security issue with no record is UNRECORDED, and a Bug is not"; else bad "an unstarted Security issue with no record is UNRECORDED, and a Bug is not" "rc=$RC out=$OUT"; fi
# ABLATION: give the same issue a pull request that mentions it, or move the bound past its age,
# and the row goes away -- so it fires for being unstarted, not for being a Security issue.
printf '[%s,{"repo":"s","number":9,"labels":[],"pull_request":{},"user":{"login":"devantler"},"body":"Part of #1"}]\n' "$parked_security" >"$TMP/unrecorded-in-flight.json"
OUT="$("$WRAPPER" --quiet --input "$TMP/unrecorded-in-flight.json" --today 2026-09-20 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "ABLATION: an open pull request that mentions it clears it"; else bad "ABLATION: an open pull request that mentions it clears it" "rc=$RC out=$OUT"; fi
OUT="$("$WRAPPER" --quiet --input "$TMP/unrecorded.json" --today 2026-09-20 --unrecorded-max-age-days 19 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "ABLATION: within the bound it is only new"; else bad "ABLATION: within the bound it is only new" "rc=$RC out=$OUT"; fi
# What does NOT clear it. A dependency bot's pull request quotes upstream release notes; an
# assignment is a claim that lapses after about two hours, not a start; and "**Blocker:** none"
# says nothing blocks the issue, which is no reason to leave it unstarted.
printf '[%s,{"repo":"s","number":9,"labels":[],"pull_request":{},"user":{"login":"renovate[bot]"},"body":"Fixes #1"}]\n' "$parked_security" >"$TMP/unrecorded-bot.json"
OUT="$("$WRAPPER" --quiet --input "$TMP/unrecorded-bot.json" --today 2026-09-20 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "$unrecorded_row with no record" ]; then ok "a dependency bot's pull request does not clear it"; else bad "a dependency bot's pull request does not clear it" "rc=$RC out=$OUT"; fi
printf '[%s]\n' "$(unstarted 1 Security 2026-09-01T00:00:00Z '[{"login":"devantler"}]' "$no_blocker" 'plain work')" >"$TMP/unrecorded-assigned.json"
OUT="$("$WRAPPER" --quiet --input "$TMP/unrecorded-assigned.json" --today 2026-09-20 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "$unrecorded_row with no record  [assigned]" ]; then ok "an assignee does not clear it, and the row says it is assigned"; else bad "an assignee does not clear it, and the row says it is assigned" "rc=$RC out=$OUT"; fi
printf '[%s]\n' "$(unstarted 1 Security 2026-09-01T00:00:00Z '[]' "$no_blocker" '**Blocker:** none — agent-actionable')" >"$TMP/unrecorded-none.json"
OUT="$("$WRAPPER" --quiet --input "$TMP/unrecorded-none.json" --today 2026-09-20 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "$unrecorded_row while declaring no blocker" ]; then ok "declaring no blocker does not clear it, and the row says what was declared"; else bad "declaring no blocker does not clear it, and the row says what was declared" "rc=$RC out=$OUT"; fi
# A fact the verdict rests on that cannot be read is UNKNOWN, never a clean sweep: an age is not
# shown to be within the bound, and a missing native-blocker summary is not zero blockers.
printf '[%s]\n' "$(unstarted 1 Security '' '[]' "$no_blocker" 'plain work')" >"$TMP/unrecorded-undated.json"
OUT="$("$WRAPPER" --input "$TMP/unrecorded-undated.json" --today 2026-09-20 2>&1)"; RC=$?
if [ "$RC" = 2 ] && grep -q 'no readable created_at' <<<"$OUT" && ! grep -q 'all 0 open' <<<"$OUT"; then ok "an unstarted Security issue of unreadable age is UNKNOWN"; else bad "an unstarted Security issue of unreadable age is UNKNOWN" "rc=$RC out=$OUT"; fi
printf '[%s]\n' "$(unstarted 1 Security 2026-09-01T00:00:00Z '[]' '' 'plain work')" >"$TMP/unrecorded-no-summary.json"
OUT="$("$WRAPPER" --input "$TMP/unrecorded-no-summary.json" --today 2026-09-20 2>&1)"; RC=$?
if [ "$RC" = 2 ] && grep -q 'carries no issue_dependencies_summary' <<<"$OUT" && ! grep -q 'all 0 open' <<<"$OUT"; then ok "an unstarted Security issue with no native-blocker summary is UNKNOWN"; else bad "an unstarted Security issue with no native-blocker summary is UNKNOWN" "rc=$RC out=$OUT"; fi
# The verdict says how many Security issues it rests on, so a renamed type cannot read as clean.
OUT="$("$WRAPPER" --input "$TMP/unrecorded.json" --today 2026-09-20 --unrecorded-max-age-days 19 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'none of the 1 open Security issue(s) read has gone unstarted for more than 19 day(s)' <<<"$OUT"; then ok "the clean verdict counts the Security issues it read"; else bad "the clean verdict counts the Security issues it read" "rc=$RC out=$OUT"; fi

# ------------------------------------------------------------------ parked pull requests (#3424)
# A parked pull request carries its blocker in ONE record comment, under the blocked label. The
# Go tests cover the record's shapes; these prove the real `gh api <endpoint> --paginate` read
# and that the guide and the help define the same record.
park_record='> 🤖 Generated by the Agentic Engineer\n\n<!-- pr-blocker-record -->\n**Blocker:** owner/repo#7 | upstream | last-verified 2026-08-01: open'
parked_gh() { # <comment count the pull request reports> <comment pages> [<comment read exit status>]
  cat >"$TMP/bin/gh" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *is:pr*) echo '{"total_count":1,"incomplete_results":false,"items":[{"repository_url":"https://api.github.com/repos/o/r","number":7,"labels":[{"name":"blocked"}],"user":{"login":"renovate[bot]"},"comments":0,"body":"bump"}]}' ;;
  *is:issue*) echo '{"total_count":0,"incomplete_results":false,"items":[]}' ;;
  "api repos/devantler-tech/r/issues/7 --paginate") echo '{"number":7,"comments":$1}' ;;
  "api repos/devantler-tech/r/issues/7/comments?per_page=100 --paginate") printf '%s\n' '$2'; exit ${3:-0} ;;
  *) echo "unexpected gh call: \$*" >&2; exit 9 ;;
esac
SHIM
  chmod +x "$TMP/bin/gh"
  OUT="$(PATH="$TMP/bin:$PATH" "$CHECK" --org devantler-tech 2>&1)"
  RC=$?
}
parked_gh 2 '[{"user":{"login":"renovate[bot]"},"body":"rebased"}] [{"user":{"login":"devantler"},"body":"'"$park_record"'"}]'
if [ "$RC" = 0 ] && grep -q 'all 1 open blocked-labelled pull request(s) carry one conforming record comment' <<<"$OUT"; then
  ok "a parked pull request with one record comment, read over two pages, conforms"
else
  bad "a parked pull request with one record comment, read over two pages, conforms" "rc=$RC; out: ${OUT:0:300}"
fi
parked_gh 1 '[{"user":{"login":"renovate[bot]"},"body":"rebased"}]'
if [ "$RC" = 1 ] && grep -q '^MISSING    r#7  \[pull request\]$' <<<"$OUT"; then
  ok "a parked pull request with no record comment is MISSING"
else
  bad "a parked pull request with no record comment is MISSING" "rc=$RC; out: ${OUT:0:300}"
fi
# The failing read prints the conforming record, so ignoring its status would print a clean sweep.
parked_gh 1 '[{"user":{"login":"devantler"},"body":"'"$park_record"'"}]' 1
if [ "$RC" = 2 ] && grep -q 'forge read failed -- UNKNOWN' <<<"$OUT" && ! grep -q 'pull request(s)' <<<"$OUT"; then
  ok "a comment read that fails after printing the record is UNKNOWN(2)"
else
  bad "a comment read that fails after printing the record is UNKNOWN(2)" "rc=$RC; out: ${OUT:0:300}"
fi
parked_gh 3 '[{"user":{"login":"devantler"},"body":"'"$park_record"'"}]'
if [ "$RC" = 2 ] && grep -q 'truncated comment read' <<<"$OUT" && ! grep -q 'pull request(s)' <<<"$OUT"; then
  ok "a comment read shorter than the counted comments is UNKNOWN(2)"
else
  bad "a comment read shorter than the counted comments is UNKNOWN(2)" "rc=$RC; out: ${OUT:0:300}"
fi

# COMPOSER: the record a run posts is printed by the wrapper, not typed (monorepo#3879). Run the
# real wrapper, then feed what it printed back through the sweep as a parked pull request's only
# comment: the two must agree, and a refusal must leave nothing on stdout to post.
COMPOSED="$("$WRAPPER" compose --target o/r#5 --kind upstream --blocker o/other#7 --result 'still open')"
RC=$?
if [ "$RC" = 0 ] && [ -n "$COMPOSED" ] &&
  OUT="$(jq -n --arg body "$COMPOSED" '[{repo:"r",number:5,pull_request:{},labels:[{name:"blocked"}],body:"",comments:[{user:{login:"devantler"},body:$body}]}]' | "$GUARD" --input - 2>&1)" &&
  grep -q 'all 1 open blocked-labelled pull request(s) carry one conforming record comment' <<<"$OUT"; then
  ok "the wrapper composes a record the sweep accepts"
else
  bad "the wrapper composes a record the sweep accepts" "rc=$RC; composed: ${COMPOSED:0:200}; sweep: ${OUT:0:300}"
fi
OUT="$("$WRAPPER" compose --target o/r#5 --kind upstream --blocker 'review, CI and evaluation' --result 'pending' 2>"$TMP/compose.err")"
RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q 'its own unfinished work' "$TMP/compose.err"; then
  ok "the wrapper refuses readiness work as a blocker and prints nothing"
else
  bad "the wrapper refuses readiness work as a blocker and prints nothing" "rc=$RC; out: ${OUT:0:200}; err: $(head -c 300 "$TMP/compose.err")"
fi

# CONTRACT: the merge policy tells a run how to write the record the check accepts. Scope the
# assertions to the paragraph that defines it, and fail when that paragraph cannot be found: an
# empty extraction would pass no check here, but must not be mistaken for a rule that moved.
MERGE_GUIDE="$HERE/../guides/merge-policy.md"
PARK_RULE="$(awk '/^\*\*A parked PR carries one blocker record/{f=1} f&&/^\*\*"Is someone actively working on it\?"/{exit} f{print}' "$MERGE_GUIDE")"
HELP="$("$GUARD" --help)"
if [ -z "$PARK_RULE" ]; then
  bad "the merge policy defines the parked-PR record" "no paragraph starting '**A parked PR carries one blocker record' in $MERGE_GUIDE"
else
  ok "the merge policy defines the parked-PR record"
  for token in '<!-- pr-blocker-record -->' '`blocked` label' 'on a line of its own' 'edit that comment in place' '`MISSING`' '`DUPLICATE`' 'by `devantler`' 'delete the record comment' 'blocked-label-blocker-line.sh --org devantler-tech' 'blocked-label-blocker-line.sh compose --target' 'blocked-label-blocker-line.sh park --org devantler-tech --target' 'only after reading both' 'never a blocker'; do
    if grep -qF -- "$token" <<<"$PARK_RULE"; then ok "the parked-PR rule states: $token"; else bad "the parked-PR rule states: $token" "not found in the rule paragraph"; fi
  done
  for token in '<!-- pr-blocker-record -->' 'DUPLICATE' 'devantler' 'on a line of its own'; do
    if grep -qF -- "$token" <<<"$HELP"; then ok "--help states: $token"; else bad "--help states: $token" "not found in --help"; fi
  done
fi


# The parked digest (#3288) through the compiled CLI and the installed entrypoint: flag
# plumbing, the three row shapes and both exit codes. The verdicts themselves are judged in Go.
RECORD='> 🤖 Generated by the Agentic Engineer\n\n<!-- pr-blocker-record -->\n**Blocker:** o/r#7 | upstream | last-verified 2026-09-01: open'
digest_pull() { printf '{"repo":"d","number":%s,"pull_request":{},"labels":[{"name":"blocked"}],%s"body":"x","comments":[%s]}' "$1" "$2" "$3"; }
DIGEST_COMMENT="$(printf '{"user":{"login":"devantler"},"body":"%s"}' "$RECORD")"
printf '[%s,%s,%s]' "$(digest_pull 1 '"blocker_state":"open",' "$DIGEST_COMMENT")" "$(digest_pull 2 '"blocker_state":"closed",' "$DIGEST_COMMENT")" "$(digest_pull 3 '' '')" >"$TMP/parked-digest.json"
EXPECTED='PARKED     d#1  [upstream, blocker open]  o/r#7
ACTIONABLE d#2  record=BLOCKER-CLOSED  o/r#7
ACTIONABLE d#3  record=MISSING
CHECKED labelled=3 parked=1 actionable=2'
OUT="$("$GUARD" --parked-digest --input "$TMP/parked-digest.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "$EXPECTED" ]; then ok "compiled CLI emits the parked digest"; else bad "compiled CLI emits the parked digest" "rc=$RC out=$OUT"; fi
OUT="$("$WRAPPER" --parked-digest --input - --today 2026-09-05 <"$TMP/parked-digest.json" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "$EXPECTED" ]; then ok "shell entrypoint forwards the parked digest and its findings status"; else bad "shell entrypoint forwards the parked digest and its findings status" "rc=$RC out=$OUT"; fi
printf '[%s]' "$(digest_pull 1 '"blocker_state":"open",' "$DIGEST_COMMENT")" >"$TMP/parked-digest-clean.json"
OUT="$("$WRAPPER" --parked-digest --input "$TMP/parked-digest-clean.json" --today 2026-09-05 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -qx 'CHECKED labelled=1 parked=1 actionable=0' <<<"$OUT"; then ok "shell entrypoint exits 0 when every labelled pull request is parked"; else bad "shell entrypoint exits 0 when every labelled pull request is parked" "rc=$RC out=$OUT"; fi
# An unreadable payload is UNKNOWN and must not print a digest that reads as "nothing parked".
OUT="$("$WRAPPER" --parked-digest --input - <<<'{' 2>&1)"; RC=$?
if [ "$RC" = 2 ] && ! grep -q 'CHECKED' <<<"$OUT"; then ok "the parked digest is UNKNOWN on an unreadable payload"; else bad "the parked digest is UNKNOWN on an unreadable payload" "rc=$RC out=$OUT"; fi

# CONTRACT: the merge policy and the run procedure tell a run to read the digest and what each
# row means. Scoped to the parked-PR rule above, so the tokens must sit where the rule is used.
if [ -n "$PARK_RULE" ]; then
  for token in 'blocked-label-blocker-line.sh --org devantler-tech --parked-digest' '`PARKED <repo>#<n>  [<note>]  <blocker>`' '`ACTIONABLE <repo>#<n>' '`record=BLOCKER-CLOSED`' '`BLOCKER-SELF`' 'never reads an authority blocker' 'do not count it against `nothing_on_fire`' '`2` is UNKNOWN' 'Only this digest makes a PR parked'; do
    if grep -qF -- "$token" <<<"$PARK_RULE"; then ok "the parked-PR rule states: $token"; else bad "the parked-PR rule states: $token" "not found in the rule paragraph"; fi
  done
  for token in '--parked-digest' 'BLOCKER-CLOSED' 'CHECKED'; do
    if grep -qF -- "$token" <<<"$HELP"; then ok "--help states: $token"; else bad "--help states: $token" "not found in --help"; fi
  done
fi
RUN_SKILL="$HERE/../skills/portfolio-maintenance/SKILL.md"
if grep -qF -- 'blocked-label-blocker-line.sh --org devantler-tech --parked-digest' "$RUN_SKILL"; then ok "the run procedure runs the parked digest after the survey"; else bad "the run procedure runs the parked digest after the survey" "command not found in $RUN_SKILL"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
completed=1
[ "$fail" = 0 ] || exit 1
