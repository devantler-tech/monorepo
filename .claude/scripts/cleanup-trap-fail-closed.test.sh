#!/usr/bin/env bash
# Proves the canonical cleanup-trap shape fails CLOSED when a script aborts on a
# parameter-expansion error under `set -u`, and records what the naive shape does
# on whatever bash is running.
#
# Why this exists (monorepo#3414): the idiom almost every script here uses —
#
#     set -euo pipefail
#     tmp="$(mktemp -d)"
#     trap 'rm -rf "$tmp"' EXIT
#
# reports the script's status as the EXIT trap's own status for exactly one
# failure class: the `set -u` abort. A successful `rm` then becomes a clean pass.
# That class is the one that fires on an input nobody anticipated, which is when
# a guard most needs to fail closed. `$?` cannot recover it — read inside the
# trap it is already 0 for this class.
#
# The canonical shape is the one `ci-job-wiring.sh` already uses: a completion
# sentinel set on the last line, so reaching the end is the ONLY way a zero
# status leaves the script.
#
# This test runs on the CI matrix (ubuntu-latest = bash 5, macos-latest =
# bash 3.2) so the per-version behaviour is measured rather than assumed.
set -euo pipefail

tmp="$(mktemp -d)"
cleanup_trap_test_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$cleanup_trap_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "cleanup-trap-fail-closed.test: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; fails=$((fails + 1)); }

echo "shell: $(bash --version | head -1)"
echo "BASH_VERSION=${BASH_VERSION:-unknown}"
echo

# ---------------------------------------------------------------------------
# Fixtures. In BOTH, the fatal error is injected AFTER the trap line — injecting
# it before is vacuous, because the trap is not installed yet and the status
# propagates with or without the fix.
# ---------------------------------------------------------------------------

# The naive shape, exactly as it appears across the script tree.
cat > "$tmp/naive.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
case "${1:-}" in
  unbound) echo "${DELIBERATELY_UNSET_VAR}" ;;
  clean)   : ;;
  seterr)  false ;;
  code)    exit 3 ;;
esac
EOF

# The canonical shape: the completion sentinel `ci-job-wiring.sh` uses.
cat > "$tmp/canonical.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
echo "$tmp" > "${CLEANUP_TRAP_TEST_TMPDIR_RECORD:-/dev/null}"
canonical_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$canonical_finished" != 1 ] && [ "$rc" -eq 0 ]; then # ABLATE-HERE
    echo "canonical: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
case "${1:-}" in
  unbound) echo "${DELIBERATELY_UNSET_VAR}" ;;
  clean)   : ;;
  seterr)  false ;;
  code)    exit 3 ;;
esac
canonical_finished=1
EOF

chmod +x "$tmp/naive.sh" "$tmp/canonical.sh"

status_of() { # <script> <arg>
  local rc=0
  "$1" "$2" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

# ---------------------------------------------------------------------------
# 1. MEASUREMENT (monorepo#3414 acceptance criterion 1). Printed, not asserted:
#    the whole point is to learn what THIS bash does. Asserting a value here
#    would make the test fail on a bash that does not carry the defect, which is
#    the very outcome we are trying to find out about.
# ---------------------------------------------------------------------------
naive_unbound="$(status_of "$tmp/naive.sh" unbound)"
echo "MEASUREMENT naive shape, \`set -u\` abort after the trap line: exit ${naive_unbound}"
if [ "$naive_unbound" -eq 0 ]; then
  echo "MEASUREMENT verdict: this bash IS affected — the naive trap masks the abort as a clean pass."
else
  echo "MEASUREMENT verdict: this bash is NOT affected — the naive trap propagates exit ${naive_unbound}."
fi
echo

# Control: the same abort with NO trap at all must be non-zero on every bash.
# If this ever reported 0, the fixture would not be aborting and every result
# above and below it would be vacuous.
cat > "$tmp/notrap.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
echo "${DELIBERATELY_UNSET_VAR}"
EOF
chmod +x "$tmp/notrap.sh"
notrap_unbound="$(status_of "$tmp/notrap.sh" unbound)"
echo "control: same abort with no trap installed: exit ${notrap_unbound}"
if [ "$notrap_unbound" -ne 0 ]; then
  pass "control — the fixture really does abort, so the measurement above is about the trap"
else
  fail "control — the fixture did not abort; every other result here is vacuous"
fi
echo

# ---------------------------------------------------------------------------
# 2. THE INVARIANT (acceptance criteria 2 and 4). This IS asserted, on every
#    bash: the canonical shape must never report a clean pass for an abort.
# ---------------------------------------------------------------------------
echo "canonical shape:"
canonical_unbound="$(status_of "$tmp/canonical.sh" unbound)"
if [ "$canonical_unbound" -ne 0 ]; then
  pass "\`set -u\` abort after the trap line reports failure (exit ${canonical_unbound})"
else
  fail "\`set -u\` abort after the trap line reported a CLEAN PASS — the shape does not fail closed"
fi

# The sentinel must not break the statuses that already worked, or scripts
# converted to this shape would start lying in the other direction.
for arm in "clean 0" "seterr 1" "code 3"; do
  name="${arm%% *}"; want="${arm##* }"
  got="$(status_of "$tmp/canonical.sh" "$name")"
  if [ "$got" = "$want" ]; then
    pass "${name} arm still exits ${want}"
  else
    fail "${name} arm exits ${got}, expected ${want}"
  fi
done

# The trap must still do its actual job.
record="$tmp/canonical-tmpdir"
CLEANUP_TRAP_TEST_TMPDIR_RECORD="$record" "$tmp/canonical.sh" unbound >/dev/null 2>&1 || true
inner="$(cat "$record" 2>/dev/null || echo)"
if [ -n "$inner" ] && [ ! -d "$inner" ]; then
  pass "cleanup still removed the temporary directory on the aborting path"
elif [ -z "$inner" ]; then
  fail "could not record the inner temporary directory — cleanup claim unverified"
else
  fail "cleanup leaked ${inner} on the aborting path"
fi
echo

# ---------------------------------------------------------------------------
# 3. ABLATION. Removing ONLY the sentinel must reproduce the fail-open — but
#    only on a bash that showed the defect in step 1. On an unaffected bash
#    there is nothing to reproduce, and asserting otherwise would be a false
#    failure rather than a finding.
# ---------------------------------------------------------------------------
echo "ablation (sentinel removed, trap kept):"
if [ "$naive_unbound" -eq 0 ]; then
  sed 's|.*# ABLATE-HERE|  if false; then|' \
    "$tmp/canonical.sh" > "$tmp/ablated.sh"
  chmod +x "$tmp/ablated.sh"
  if ! grep -q 'if false; then' "$tmp/ablated.sh"; then
    fail "ablation did not apply — the edit matched nothing, so the result below proves nothing"
  else
    ablated_unbound="$(status_of "$tmp/ablated.sh" unbound)"
    if [ "$ablated_unbound" -eq 0 ]; then
      pass "removing the sentinel restores the fail-open (exit 0) — the sentinel is what fixes it"
    else
      fail "ablation still exits ${ablated_unbound}; the sentinel is not the operative difference"
    fi
  fi
else
  echo "  skip  this bash does not carry the defect, so there is no fail-open to reproduce"
fi
echo

if [ "$fails" -ne 0 ]; then
  echo "cleanup-trap-fail-closed.test: ${fails} assertion(s) failed" >&2
  exit 1
fi
echo "cleanup-trap-fail-closed.test: all assertions passed"
cleanup_trap_test_finished=1
