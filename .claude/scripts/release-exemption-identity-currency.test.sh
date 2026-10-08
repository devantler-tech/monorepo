#!/usr/bin/env bash
# Hermetic self-test for release-exemption-identity-currency.sh.
#
# No network and no real PR is touched: every case is a hand-built JSON payload fed through the
# --input seam, against a synthetic classifier fed through --classifier — except one case that reads
# the real classifier against recorded production provenance, so the guard is proven to still read
# the arm it watches. The forge path shares all of its comparison logic with that seam, so the
# behaviour proven here is the behaviour that runs.
#
# The suite deliberately includes a POSITIVE control (a fixture the guard must call CURRENT). A
# drift checker that reports DRIFT unconditionally would satisfy every negative case, so without a
# positive control the suite would pass on a guard that has stopped discriminating.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
CHECK="$HERE/release-exemption-identity-currency.sh"
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
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then
    echo "release-exemption-identity-currency.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    exit 1
  fi
}
trap on_exit EXIT

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

# ---------------------------------------------------------------------------
# A synthetic classifier carrying a known pin. Using a fixture rather than the real script keeps
# these cases stable when the real pin is corrected -- the guard's LOGIC is what is under test here,
# and the real pin's correctness is what the live run answers.
# ---------------------------------------------------------------------------
CLS="$TMP/classifier.sh"
cat > "$CLS" <<'EOF'
#!/usr/bin/env bash
matches_homebrew_provenance() {
  jq -e 'x == [{ author_name: "decoy-must-not-be-picked-up" }]'
}
matches_ksail_provenance() {
  local version="$1"
  jq -e \
    'map(del(.author_date, .committer_date)) == [{
      sha: $head,
      author_login: "",
      author_name: "pinned-bot[bot]",
      author_email: "pinned-bot[bot]@users.noreply.github.com",
      committer_login: "",
      committer_name: "pinned-bot[bot]",
      committer_email: "pinned-bot[bot]@users.noreply.github.com",
      message: "chore(copilot-plugin): release \($version)"
    }]' <<<"${commits_json}" >/dev/null
}
matches_other_provenance() {
  jq -e 'y == [{ author_name: "another-decoy" }]'
}
EOF
chmod +x "$CLS"

pinned_commit() {
  cat <<'EOF'
{"author_login":"","author_name":"pinned-bot[bot]",
 "author_email":"pinned-bot[bot]@users.noreply.github.com",
 "committer_login":"","committer_name":"pinned-bot[bot]",
 "committer_email":"pinned-bot[bot]@users.noreply.github.com"}
EOF
}
drifted_commit() {
  cat <<'EOF'
{"author_login":"new-bot[bot]","author_name":"new-bot[bot]",
 "author_email":"999+new-bot[bot]@users.noreply.github.com",
 "committer_login":"web-flow","committer_name":"GitHub",
 "committer_email":"noreply@github.com"}
EOF
}
# Differs from the pinned identity in committer_email ALONE. Every other field matches, so the two
# identity lines the guard prints are byte-identical unless they carry the email — which is exactly
# the case where an operator reading the report cannot see what drifted.
email_only_drift_commit() {
  cat <<'INNER'
{"author_login":"","author_name":"pinned-bot[bot]",
 "author_email":"pinned-bot[bot]@users.noreply.github.com",
 "committer_login":"","committer_name":"pinned-bot[bot]",
 "committer_email":"rotated-bot[bot]@users.noreply.github.com"}
INNER
}

# run <payload-file> [extra args...] -> sets RC and OUT
run() {
  local f="$1"; shift
  OUT="$("$CHECK" --input "$f" --classifier "$CLS" --days 0 "$@" 2>&1)"
  RC=$?
}

expect_rc() { # name expected file [extra args...]
  local name="$1" want="$2" file="$3"; shift 3
  run "$file" "$@"
  if [ "$RC" = "$want" ]; then ok "$name"; else bad "$name" "expected rc=$want got rc=$RC; out: ${OUT:0:300}"; fi
}

expect_out() { # name pattern file [extra args...]
  local name="$1" pat="$2" file="$3"; shift 3
  run "$file" "$@"
  if grep -qE "$pat" <<<"$OUT"; then ok "$name"; else bad "$name" "no match for /$pat/; out: ${OUT:0:300}"; fi
}

# ---------------------------------------------------------------------------
# POSITIVE CONTROL: newest releases carry the pinned identity -> CURRENT.
# Without this, a guard hard-wired to report DRIFT would pass the whole suite.
# ---------------------------------------------------------------------------
jq -n --argjson p "$(pinned_commit)" '[
  {number: 3, mergedAt: "2026-09-02T00:00:00Z", commits: [$p]},
  {number: 2, mergedAt: "2026-09-01T00:00:00Z", commits: [$p]},
  {number: 1, mergedAt: "2026-08-31T00:00:00Z", commits: [$p]}
]' > "$TMP/all-pinned.json"
expect_rc "positive control: all newest match the pin -> CURRENT" 0 "$TMP/all-pinned.json"
expect_out "CURRENT names how many matched" "CURRENT — 3 of the newest 3" "$TMP/all-pinned.json"

# ---------------------------------------------------------------------------
# The real defect: newest releases all carry a different identity -> DRIFT.
# ---------------------------------------------------------------------------
jq -n --argjson d "$(drifted_commit)" '[
  {number: 3, mergedAt: "2026-09-02T00:00:00Z", commits: [$d]},
  {number: 2, mergedAt: "2026-09-01T00:00:00Z", commits: [$d]},
  {number: 1, mergedAt: "2026-08-31T00:00:00Z", commits: [$d]}
]' > "$TMP/all-drifted.json"
expect_rc "newest all carry a different identity -> DRIFT" 1 "$TMP/all-drifted.json"
expect_out "DRIFT reports the observed identity" "new-bot\[bot\]" "$TMP/all-drifted.json"
expect_out "DRIFT reports the observed committer" "committer=GitHub" "$TMP/all-drifted.json"

# ---------------------------------------------------------------------------
# THE DESIGN POINT, and the case the naive "any PR in the window" formulation gets wrong.
# Twelve old releases match; the six newest do not. This is the exact shape of the measured
# 2026-08-29 transition. A window-wide "does anything match" test reports CURRENT here and stays
# green for weeks; keying on the newest releases reports DRIFT immediately.
# ---------------------------------------------------------------------------
jq -n --argjson p "$(pinned_commit)" --argjson d "$(drifted_commit)" '
  [ range(0;6)  | {number: (100+.), mergedAt: "2026-09-0\(1+.)T00:00:00Z", commits: [$d]} ] +
  [ range(0;12) | {number: (200+.), mergedAt: "2026-08-2\(. % 9)T00:00:00Z", commits: [$p]} ]
' > "$TMP/transition.json"
expect_rc "post-transition: older matches must NOT mask a drifted head -> DRIFT" 1 "$TMP/transition.json"

# Widening the cohort must not rescue a drifted head either: 6 of 18 miss, which is more than the one
# anomaly tolerated. This pins that --recent scopes WHICH releases are judged, and never relaxes the
# threshold.
expect_rc "widening to --recent 18 does not mask the drift -> DRIFT" 1 "$TMP/transition.json" --recent 18

# ---------------------------------------------------------------------------
# The tolerance boundary, both sides of it. "At most one may miss" is the stated rule, so two misses
# in a complete cohort is drift even though one release still matches -- this is the case a
# "matching > 0" threshold gets wrong, and it is reachable: the real transition passes through it.
# ---------------------------------------------------------------------------
jq -n --argjson p "$(pinned_commit)" --argjson d "$(drifted_commit)" '[
  {number: 3, mergedAt: "2026-09-02T00:00:00Z", commits: [$d]},
  {number: 2, mergedAt: "2026-09-01T00:00:00Z", commits: [$d]},
  {number: 1, mergedAt: "2026-08-31T00:00:00Z", commits: [$p]}
]' > "$TMP/two-drifted.json"
expect_rc "two of three miss -> DRIFT even though one still matches" 1 "$TMP/two-drifted.json"
expect_out "DRIFT names the threshold it needed" "need 2" "$TMP/two-drifted.json"

# ---------------------------------------------------------------------------
# A cohort smaller than --recent cannot support the tolerance rule, so it is UNKNOWN rather than a
# verdict on thinner evidence. Both the one- and two-candidate non-matching cases.
# ---------------------------------------------------------------------------
jq -n --argjson d "$(drifted_commit)" '[
  {number: 1, mergedAt: "2026-09-02T00:00:00Z", commits: [$d]}
]' > "$TMP/one-candidate.json"
expect_rc "one non-matching candidate with --recent 3 -> UNKNOWN, not DRIFT" 2 "$TMP/one-candidate.json"
expect_out "UNKNOWN explains the thin cohort" "fewer than the 3 required" "$TMP/one-candidate.json"

jq -n --argjson d "$(drifted_commit)" '[
  {number: 2, mergedAt: "2026-09-02T00:00:00Z", commits: [$d]},
  {number: 1, mergedAt: "2026-09-01T00:00:00Z", commits: [$d]}
]' > "$TMP/two-candidates.json"
expect_rc "two non-matching candidates with --recent 3 -> UNKNOWN, not DRIFT" 2 "$TMP/two-candidates.json"
# Control: the SAME fixture judged at a cohort size it can support IS a verdict, so the case above
# proves the cohort gate fired rather than the fixture being unreadable.
expect_rc "control: same two candidates with --recent 2 -> DRIFT" 1 "$TMP/two-candidates.json" --recent 2

# --recent 1 must not pass vacuously: RECENT-1 would be 0, and "at least 0 matches" is every cohort.
jq -n --argjson d "$(drifted_commit)" '[
  {number: 1, mergedAt: "2026-09-02T00:00:00Z", commits: [$d]}
]' > "$TMP/single-drifted.json"
expect_rc "--recent 1 on a non-matching release -> DRIFT, not a vacuous pass" 1 "$TMP/single-drifted.json" --recent 1
expect_rc "--recent 1 on a matching release -> CURRENT" 0 "$TMP/all-pinned.json" --recent 1

# ---------------------------------------------------------------------------
# Tolerance: one anomalous release (an adaptation commit) must not trip the guard.
# ---------------------------------------------------------------------------
jq -n --argjson p "$(pinned_commit)" --argjson d "$(drifted_commit)" '[
  {number: 3, mergedAt: "2026-09-02T00:00:00Z", commits: [$d]},
  {number: 2, mergedAt: "2026-09-01T00:00:00Z", commits: [$p]},
  {number: 1, mergedAt: "2026-08-31T00:00:00Z", commits: [$p]}
]' > "$TMP/one-anomaly.json"
expect_rc "a single non-matching newest release is tolerated -> CURRENT" 0 "$TMP/one-anomaly.json"

# ---------------------------------------------------------------------------
# Ordering is normalised by the guard, not trusted from the caller.
# ---------------------------------------------------------------------------
jq -n --argjson p "$(pinned_commit)" --argjson d "$(drifted_commit)" '[
  {number: 1, mergedAt: "2026-08-31T00:00:00Z", commits: [$p]},
  {number: 3, mergedAt: "2026-09-02T00:00:00Z", commits: [$d]},
  {number: 2, mergedAt: "2026-09-01T00:00:00Z", commits: [$d]}
]' > "$TMP/shuffled.json"
expect_rc "input order does not change the verdict -> DRIFT" 1 "$TMP/shuffled.json" --recent 2

# ---------------------------------------------------------------------------
# The --days window applies on BOTH seams. A flag documented as a window that silently does nothing
# on the --input seam would make a fixture look windowed when it is not, so it is pinned here: these
# releases are years old, so any real window excludes all of them and the result is UNKNOWN.
# ---------------------------------------------------------------------------
jq -n --argjson p "$(pinned_commit)" '[
  {number: 1, mergedAt: "2020-01-01T00:00:00Z", commits: [$p]}
]' > "$TMP/ancient.json"
OUT="$("$CHECK" --input "$TMP/ancient.json" --classifier "$CLS" --days 30 --recent 1 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "--days windows the --input seam too -> UNKNOWN"; else bad "--days windows the --input seam too -> UNKNOWN" "expected rc=2 got rc=$RC; out: ${OUT:0:300}"; fi
if grep -qE 'no candidate release PR found' <<<"$OUT"; then
  ok "the window, not the cohort gate, is what excluded it"
else
  bad "the window, not the cohort gate, is what excluded it" "out: ${OUT:0:300}"
fi
# Control: the SAME fixture with the window disabled is judged normally, so the case above proves
# the window excluded it rather than the fixture being malformed.
expect_rc "control: same fixture with --days 0 is judged -> CURRENT" 0 "$TMP/ancient.json" --recent 1

# ---------------------------------------------------------------------------
# ABSENCE: an empty candidate set is UNKNOWN, never a clean result.
# ---------------------------------------------------------------------------
echo '[]' > "$TMP/empty.json"
expect_rc "no candidate release PRs -> UNKNOWN, not CURRENT" 2 "$TMP/empty.json"
expect_out "UNKNOWN says it is not a clean result" "NOT a clean result" "$TMP/empty.json"

# ---------------------------------------------------------------------------
# ABLATIONS on the pin extraction. Each must fail CLOSED to UNKNOWN. A guard that cannot read the
# pin must never report CURRENT -- that would be the original defect one level up: a check reporting
# success on input it never examined.
# ---------------------------------------------------------------------------
NO_ARM="$TMP/no-arm.sh"
grep -v 'matches_ksail_provenance' "$CLS" > "$NO_ARM" || true
OUT="$("$CHECK" --input "$TMP/all-pinned.json" --classifier "$NO_ARM" --days 0 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "ablation: arm renamed/absent -> UNKNOWN"; else bad "ablation: arm renamed/absent -> UNKNOWN" "expected rc=2 got rc=$RC"; fi

# Assert the ablation fired for the RIGHT REASON: because the arm could not be located, not because
# something incidental broke. An ablation whose failure is unexplained proves nothing.
if grep -qE 'could not locate matches_ksail_provenance' <<<"$OUT"; then
  ok "ablation fired for the stated reason"
else
  bad "ablation fired for the stated reason" "out: ${OUT:0:300}"
fi

GUTTED="$TMP/gutted.sh"
sed 's/author_name: "pinned-bot\[bot\]",//; s/author_email: "pinned-bot\[bot\]@users.noreply.github.com",//' "$CLS" > "$GUTTED"
OUT="$("$CHECK" --input "$TMP/all-pinned.json" --classifier "$GUTTED" --days 0 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "ablation: pin fields unreadable -> UNKNOWN"; else bad "ablation: pin fields unreadable -> UNKNOWN" "expected rc=2 got rc=$RC"; fi

OUT="$("$CHECK" --input "$TMP/all-pinned.json" --classifier "$TMP/does-not-exist.sh" --days 0 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "ablation: classifier missing -> UNKNOWN"; else bad "ablation: classifier missing -> UNKNOWN" "expected rc=2 got rc=$RC"; fi

# A DROPPED login key is the dangerous ablation, because its extracted value ("") is indistinguishable
# from the legitimate empty pin. The classifier's own comparison can no longer match any production
# commit, so the arm is dead -- and a value-only check would compare "" against a payload that
# normalises a missing login to "" and report CURRENT over it. Both keys, separately.
for key in author_login committer_login; do
  DROPPED="$TMP/dropped-$key.sh"
  grep -v "^[[:space:]]*$key:" "$CLS" > "$DROPPED"
  OUT="$("$CHECK" --input "$TMP/all-pinned.json" --classifier "$DROPPED" --days 0 2>&1)"; RC=$?
  if [ "$RC" = 2 ]; then ok "ablation: $key key dropped -> UNKNOWN, never CURRENT"; else bad "ablation: $key key dropped -> UNKNOWN, never CURRENT" "expected rc=2 got rc=$RC; out: ${OUT:0:300}"; fi
  if grep -qE "declares no $key key" <<<"$OUT"; then
    ok "ablation: $key names the missing key"
  else
    bad "ablation: $key names the missing key" "out: ${OUT:0:300}"
  fi
done

# Control: an EMPTY-but-DECLARED login is legitimate and must still be judged, so the two ablations
# above prove absence was detected rather than emptiness being rejected outright.
expect_rc "control: empty-but-declared logins are judged normally -> CURRENT" 0 "$TMP/all-pinned.json"

# ---------------------------------------------------------------------------
# The decoy arms must never supply the pin. If extraction wandered into a neighbouring function the
# comparison would silently be against the wrong identity.
# ---------------------------------------------------------------------------
expect_out "pin comes from the ksail arm, not a neighbouring one" "pinned-bot\[bot\]" "$TMP/all-pinned.json"
run "$TMP/all-pinned.json"
if grep -qE 'decoy' <<<"$OUT"; then
  bad "no decoy identity leaks into the pin" "out: ${OUT:0:300}"
else
  ok "no decoy identity leaks into the pin"
fi

# ---------------------------------------------------------------------------
# Usage errors are UNKNOWN, never a verdict.
# ---------------------------------------------------------------------------
OUT="$("$CHECK" --input "$TMP/all-pinned.json" --classifier "$CLS" --recent 0 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "--recent 0 rejected -> UNKNOWN"; else bad "--recent 0 rejected -> UNKNOWN" "got rc=$RC"; fi
OUT="$("$CHECK" --input "$TMP/all-pinned.json" --classifier "$CLS" --days x 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "--days non-numeric rejected -> UNKNOWN"; else bad "--days non-numeric rejected -> UNKNOWN" "got rc=$RC"; fi
OUT="$("$CHECK" --bogus 2>&1)"; RC=$?
if [ "$RC" = 2 ]; then ok "unknown argument rejected -> UNKNOWN"; else bad "unknown argument rejected -> UNKNOWN" "got rc=$RC"; fi

# ---------------------------------------------------------------------------
# An email-only drift must be REPORTED AS A DRIFT and must be READABLE. The verdict alone is not
# enough here: every other identity field matches, so unless both committer emails are printed the
# report shows two identical-looking lines and names nothing that actually differs.
# ---------------------------------------------------------------------------
jq -n --argjson e "$(email_only_drift_commit)" '[
  {number:1, mergedAt:"2026-09-01T00:00:00Z", commits:[$e]},
  {number:2, mergedAt:"2026-08-31T00:00:00Z", commits:[$e]},
  {number:3, mergedAt:"2026-08-30T00:00:00Z", commits:[$e]}
]' > "$TMP/email-only-drift.json"
expect_rc "a committer_email-only difference -> DRIFT" 1 "$TMP/email-only-drift.json"
expect_out "the PINNED committer email is visible" \
  "committer=pinned-bot\[bot\] <pinned-bot\[bot\]@users\.noreply\.github\.com>" "$TMP/email-only-drift.json"
expect_out "the OBSERVED committer email is visible" \
  "<rotated-bot\[bot\]@users\.noreply\.github\.com>" "$TMP/email-only-drift.json"

# ---------------------------------------------------------------------------
# The signature verdict is part of the pin when the arm declares it (#3173). A release carrying the
# right names but no GitHub signature fails such an arm, so it must count as a miss here — and an
# arm that does not pin the verdict must still be judged on identity alone.
# ---------------------------------------------------------------------------
CLS_SIGNED="$TMP/classifier-signed.sh"
cat > "$CLS_SIGNED" <<'EOF'
#!/usr/bin/env bash
matches_ksail_provenance() {
  local version="$1"
  jq -e \
    'map(del(.author_date, .committer_date)) == [{
      sha: $head,
      author_login: "pinned-bot[bot]",
      author_name: "pinned-bot[bot]",
      author_email: "1+pinned-bot[bot]@users.noreply.github.com",
      committer_login: "web-flow",
      committer_name: "GitHub",
      committer_email: "noreply@github.com",
      message: "chore(copilot-plugin): release \($version)",
      verified: true
    }]' <<<"${commits_json}" >/dev/null
}
EOF
signed_commit() { # verified value, or "absent"
  jq -nc --arg v "$1" '{author_login: "pinned-bot[bot]", author_name: "pinned-bot[bot]",
    author_email: "1+pinned-bot[bot]@users.noreply.github.com", committer_login: "web-flow",
    committer_name: "GitHub", committer_email: "noreply@github.com"}
    | if $v == "absent" then . else .verified = ($v == "true") end'
}
three_of() {
  jq -n --argjson c "$1" '[
    {number: 3, mergedAt: "2026-09-02T00:00:00Z", commits: [$c]},
    {number: 2, mergedAt: "2026-09-01T00:00:00Z", commits: [$c]},
    {number: 1, mergedAt: "2026-08-31T00:00:00Z", commits: [$c]}
  ]'
}
three_of "$(signed_commit true)" > "$TMP/signed.json"
three_of "$(signed_commit false)" > "$TMP/unsigned.json"
three_of "$(signed_commit absent)" > "$TMP/signature-unread.json"
expect_signed() { # name expected-rc file [pattern]
  OUT="$("$CHECK" --input "$3" --classifier "$CLS_SIGNED" --days 0 2>&1)"; RC=$?
  if [ "$RC" = "$2" ] && { [ -z "${4:-}" ] || grep -qE "$4" <<<"$OUT"; }; then ok "$1"
  else bad "$1" "expected rc=$2${4:+ and /$4/} got rc=$RC; out: ${OUT:0:400}"; fi
}
expect_signed "signed pin, signed releases -> CURRENT" 0 "$TMP/signed.json" "signed=\[required\]"
expect_signed "signed pin, the same names unsigned -> DRIFT" 1 "$TMP/unsigned.json" "signed=\[false\]"
expect_signed "signed pin, no signature verdict in the payload -> DRIFT" 1 "$TMP/signature-unread.json" "signed=\[unknown\]"
# The verdict comes from the arm: the identity-only pin above ignores it.
jq -n --argjson p "$(pinned_commit)" '[
  {number: 3, mergedAt: "2026-09-02T00:00:00Z", commits: [$p + {verified: false}]},
  {number: 2, mergedAt: "2026-09-01T00:00:00Z", commits: [$p + {verified: false}]},
  {number: 1, mergedAt: "2026-08-31T00:00:00Z", commits: [$p + {verified: false}]}
]' > "$TMP/identity-only-unsigned.json"
expect_rc "an arm that pins no verdict is judged on identity alone" 0 "$TMP/identity-only-unsigned.json"
expect_out "and says the signature is not pinned" "signed=\[not pinned\]" "$TMP/identity-only-unsigned.json"
sed 's/verified: true/verified: false/' "$CLS_SIGNED" > "$TMP/classifier-odd-verdict.sh"
OUT="$("$CHECK" --input "$TMP/signed.json" --classifier "$TMP/classifier-odd-verdict.sh" --days 0 2>&1)"; RC=$?
if [ "$RC" = 2 ] && grep -q "pins verified to something other than true" <<<"$OUT"; then
  ok "a verdict pin the guard cannot read -> UNKNOWN"
else
  bad "a verdict pin the guard cannot read -> UNKNOWN" "got rc=$RC; out: ${OUT:0:300}"
fi

# ---------------------------------------------------------------------------
# The REAL classifier against the newest real release PRs, as REST reports them (devantler-tech/ksail
# #7249, #7245 and #7232, read 2026-10-02; #7232 also carries a maintainer's update-branch merge). This
# is recorded evidence, not a second declaration of the pin: the live run is what re-checks it. It
# proves the guard can still read the arm it watches, and that this pin matched production when it
# was set — the stale `devantler-tech-bot[bot]` pin reported DRIFT on exactly this input.
# ---------------------------------------------------------------------------
REAL="$HERE/programmed-bot-review-exemption.sh"
jq -n '
  def release: {author_login: "ksail-bot[bot]", author_name: "ksail-bot[bot]",
    author_email: "262010955+ksail-bot[bot]@users.noreply.github.com", committer_login: "web-flow",
    committer_name: "GitHub", committer_email: "noreply@github.com", verified: true};
  [
    {number: 7249, mergedAt: "2026-09-24T03:25:01Z", commits: [release]},
    {number: 7245, mergedAt: "2026-09-23T22:28:38Z", commits: [release]},
    {number: 7232, mergedAt: "2026-09-23T17:50:02Z", commits: [release,
      {author_login: "devantler", author_name: "Nikolai Emil Damm", author_email: "ned@devantler.tech",
       committer_login: "web-flow", committer_name: "GitHub", committer_email: "noreply@github.com",
       verified: true}]}
  ]' > "$TMP/production.json"
OUT="$("$CHECK" --input "$TMP/production.json" --classifier "$REAL" --days 0 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q "CURRENT — 3 of the newest 3" <<<"$OUT" && grep -qF "signed=[required]" <<<"$OUT"; then
  ok "the real classifier's pin matches the newest real releases -> CURRENT"
else
  bad "the real classifier's pin matches the newest real releases -> CURRENT" "got rc=$RC; out: ${OUT:0:500}"
fi

printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$pass" "$fail"
completed=1
[ "$fail" -eq 0 ]
