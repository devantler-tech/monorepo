#!/usr/bin/env bash
#
# Pins disclosure-drift-sweep.sh's verdict in all three directions.
#
#   exit 0  swept clean, or every finding cleared by an authoritative re-verification
#   exit 1  at least one REAL violation
#   exit 2  UNKNOWN — a sweep or a re-verification produced no verdict
#
# The assertions that matter are not the happy path. Three cases exist because the
# obvious implementation gets them wrong:
#
#   * RE-VERIFYING BY SHAPE. Sending every bare trigger through the --issue round
#     trip files `@coderabbitai`/`@codex` violations inside the Bugbot pile, where
#     they read as known noise (monorepo#2965 records that misread). The test asserts
#     the round trip is never even ATTEMPTED for those lanes.
#   * A FAILED SWEEP READING AS CLEAN. A guard that dies produces no findings, which
#     is byte-identical to a clean sweep.
#   * AN UNVERIFIABLE CARVE-OUT COUNTING AS CLEARED. Clearing needs a verdict the
#     authoritative mode actually produced, not merely the absence of one.
#
# The guard is stubbed, so this runs offline and deterministically. Every fixture
# carries its own distinctive comment id, so an assertion can only be satisfied by
# the case it belongs to.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sweep="$script_dir/disclosure-drift-sweep.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

failures=0
assertions=0

# The stub answers from per-mode fixture files the case writes, and logs every
# invocation so a case can assert on what was NOT called.
stub="$scratch/stub-drift.sh"
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
mode="sweep"
for a in "$@"; do [ "$a" = "--issue" ] && mode="issue"; done
printf '%s %s\n' "$mode" "$*" >>"$STUB_LOG"
out="$STUB_DIR/$mode.out"
rc_file="$STUB_DIR/$mode.rc"
[ -f "$out" ] && cat "$out"
[ -f "$rc_file" ] && exit "$(cat "$rc_file")"
exit 0
STUB
chmod +x "$stub"

reset_stub() {
  rm -rf "$scratch/stub"
  mkdir -p "$scratch/stub"
  : >"$scratch/stub.log"
}

run_sweep() { # remaining args forwarded
  if OUT="$(STUB_DIR="$scratch/stub" STUB_LOG="$scratch/stub.log" \
    DISCLOSURE_DRIFT_CMD="$stub" "$sweep" "$@" 2>&1)"; then
    RC=0
  else
    RC=$?
  fi
}

assert_rc() { # <label> <expected> <actual>
  assertions=$((assertions + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %s (exit %s)\n' "$1" "$3"
  else
    printf '  FAIL %s: expected exit %s, got %s\n' "$1" "$2" "$3"
    printf '%s\n' "$OUT" | sed 's/^/       | /'
    failures=$((failures + 1))
  fi
}

assert_contains() { # <label> <needle>
  assertions=$((assertions + 1))
  # A here-string, NOT a pipe: grep -q exits on first match and the resulting
  # SIGPIPE would become the pipeline status under pipefail.
  if grep -qF -- "$2" <<<"$OUT"; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s: output lacked %s\n' "$1" "$2"
    printf '%s\n' "$OUT" | sed 's/^/       | /'
    failures=$((failures + 1))
  fi
}

assert_absent() { # <label> <needle>
  assertions=$((assertions + 1))
  if grep -qF -- "$2" <<<"$OUT"; then
    printf '  FAIL %s: output unexpectedly contained %s\n' "$1" "$2"
    printf '%s\n' "$OUT" | sed 's/^/       | /'
    failures=$((failures + 1))
  else printf '  ok   %s\n' "$1"; fi
}

assert_log() { # <label> <expect-present:yes|no> <needle>
  assertions=$((assertions + 1))
  if grep -qF -- "$3" "$scratch/stub.log" 2>/dev/null; then found=yes; else found=no; fi
  if [ "$found" = "$2" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s: expected present=%s, got %s\n' "$1" "$2" "$found"
    sed 's/^/       | /' "$scratch/stub.log"
    failures=$((failures + 1))
  fi
}

finding() { # <shape> <url> <first-line>
  printf 'VIOLATION %s %s\n    first line: %s\n' "$1" "$2" "$3"
}

printf '\n== exit 0: a clean sweep ==\n'
reset_stub
printf '0\n' >"$scratch/stub/sweep.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/clean-case-repo
assert_rc "clean sweep passes" 0 "$RC"
assert_log "the guard was actually invoked (anti-vacuity)" yes "clean-case-repo"

printf '\n== exit 1: a bare @coderabbitai trigger is a violation ON SIGHT ==\n'
reset_stub
finding undisclosed-trigger \
  "https://github.com/o/r/pull/11#issuecomment-9000001" "@coderabbitai review" \
  >"$scratch/stub/sweep.out"
printf '1\n' >"$scratch/stub/sweep.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/r
assert_rc "coderabbitai bare trigger is REAL" 1 "$RC"
assert_contains "names the offending comment" "issuecomment-9000001"
assert_contains "reports it as real" "REAL"
# The point of the lane scoping: no round trip is spent, and it cannot be filed
# among the Bugbot findings.
assert_log "no --issue re-verification was attempted" no "--issue"

printf '\n== exit 1: a bare @codex trigger is likewise ON SIGHT ==\n'
reset_stub
finding undisclosed-trigger \
  "https://github.com/o/r/pull/12#issuecomment-9000002" "@codex review" \
  >"$scratch/stub/sweep.out"
printf '1\n' >"$scratch/stub/sweep.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/r
assert_rc "codex bare trigger is REAL" 1 "$RC"
assert_contains "names the codex comment" "issuecomment-9000002"
assert_log "no --issue re-verification for codex either" no "--issue"

printf '\n== exit 0: a bare @cursor trigger CLEARED by full-history re-verification ==\n'
reset_stub
finding undisclosed-trigger \
  "https://github.com/o/r/pull/13#issuecomment-9000003" "@cursor review" \
  >"$scratch/stub/sweep.out"
printf '1\n' >"$scratch/stub/sweep.rc"
# Authoritative mode reports a DIFFERENT comment, so ours resolved its pairing.
finding undisclosed-trigger \
  "https://github.com/o/r/pull/13#issuecomment-9999999" "@coderabbitai review" \
  >"$scratch/stub/issue.out"
printf '1\n' >"$scratch/stub/issue.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/r
assert_rc "cleared cursor trigger passes" 0 "$RC"
assert_contains "reports it as cleared" "1 cleared on re-verification"
assert_log "the re-verification really ran" yes "--issue 13"
assert_absent "the cleared comment is not reported real" "REAL     https://github.com/o/r/pull/13#issuecomment-9000003"

printf '\n== exit 1: a @cursor trigger the full history STILL reports ==\n'
reset_stub
finding undisclosed-trigger \
  "https://github.com/o/r/pull/14#issuecomment-9000004" "@cursor review" \
  >"$scratch/stub/sweep.out"
printf '1\n' >"$scratch/stub/sweep.rc"
cp "$scratch/stub/sweep.out" "$scratch/stub/issue.out"
printf '1\n' >"$scratch/stub/issue.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/r
assert_rc "an unpaired cursor trigger stays REAL" 1 "$RC"
assert_contains "names it" "issuecomment-9000004"

printf '\n== exit 2: a failed sweep is UNKNOWN, never clean ==\n'
reset_stub
printf 'comment-disclosure-drift: gh failed\n' >"$scratch/stub/sweep.out"
printf '2\n' >"$scratch/stub/sweep.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/broken-sweep-repo
assert_rc "guard exit 2 propagates as UNKNOWN" 2 "$RC"
assert_contains "names the unswept repo" "broken-sweep-repo"
assert_contains "counts it unknown" "1 unknown"

printf '\n== exit 2: an unverifiable carve-out is UNKNOWN, not cleared ==\n'
reset_stub
finding undisclosed-trigger \
  "https://github.com/o/r/pull/15#issuecomment-9000005" "@cursor review" \
  >"$scratch/stub/sweep.out"
printf '1\n' >"$scratch/stub/sweep.rc"
printf '2\n' >"$scratch/stub/issue.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/r
assert_rc "re-verification failure is UNKNOWN" 2 "$RC"
assert_contains "says re-verification could not run" "re-verification could not run"
assert_absent "and it was NOT counted as cleared" "1 cleared on re-verification"

printf '\n== exit 2: drift reported but output unparseable ==\n'
reset_stub
printf 'something entirely unexpected\n' >"$scratch/stub/sweep.out"
printf '1\n' >"$scratch/stub/sweep.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/unparseable-repo
assert_rc "unparseable drift output is UNKNOWN" 2 "$RC"
assert_contains "says nothing could be parsed" "no finding could be parsed"

printf '\n== exit 2: usage ==\n'
reset_stub
run_sweep --repo o/r
assert_rc "missing --since is usage error" 2 "$RC"
run_sweep --since 2026-01-01T00:00:00Z
assert_rc "missing --repo is usage error" 2 "$RC"
run_sweep --since 2026-01-01T00:00:00Z --repo o/r --bogus
assert_rc "unknown argument is usage error" 2 "$RC"

printf '\n== exit 2: an INCOMPLETE finding record is UNKNOWN, never a silent drop ==\n'
# A record missing its URL used to be dropped by the emit condition. Alone it was
# caught by the empty-findings guard; NEXT TO a well-formed record it vanished and
# the sweep exited 1 reporting only the survivor — under-reporting while looking
# decisive. The pair below is the shape that regression needs.
reset_stub
{
  finding undisclosed-trigger \
    "https://github.com/o/r/pull/71#issuecomment-9000071" "@coderabbitai review"
  printf 'VIOLATION undisclosed-trigger\n    first line: @codex review\n'
} >"$scratch/stub/sweep.out"
printf '1\n' >"$scratch/stub/sweep.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/partial-record-repo
assert_rc "an incomplete record makes the sweep UNKNOWN" 2 "$RC"
assert_contains "names the shape change" "the guard's output shape changed under us"
assert_contains "still reports the well-formed finding beside it" "issuecomment-9000071"

printf '\n== exit 2: a record with NO continuation line is UNKNOWN ==\n'
# Without body_seen the record would carry an empty body, which is not the Bugbot
# carve-out, so it would be counted REAL — a verdict on a record we cannot read.
reset_stub
printf 'VIOLATION undisclosed-trigger https://github.com/o/r/pull/72#issuecomment-9000072\n' \
  >"$scratch/stub/sweep.out"
printf '1\n' >"$scratch/stub/sweep.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/no-continuation-repo
assert_rc "a record without its continuation is UNKNOWN" 2 "$RC"
assert_absent "it is not counted as a REAL violation" "REAL     https://github.com/o/r/pull/72"

printf '\n== MULTI-REPOSITORY: every repo is swept and UNKNOWN outranks REAL ==\n'
# Every other case passes a single --repo, so the repository loop itself was never
# exercised: a regression dropping a repo, or mishandling a mixed verdict, passed.
reset_stub
finding undisclosed-trigger \
  "https://github.com/o/r/pull/73#issuecomment-9000073" "@coderabbitai review" \
  >"$scratch/stub/sweep.out"
printf '1\n' >"$scratch/stub/sweep.rc"
run_sweep --since 2026-01-01T00:00:00Z --repo o/multi-first --repo o/multi-second
assert_log "the first repository reached the guard" yes "multi-first"
assert_log "the second repository reached the guard" yes "multi-second"
assert_rc "two REAL repositories still exit 1" 1 "$RC"
assert_contains "each repository is counted, not deduplicated" "2 real"

printf '\n%d assertion(s), %d failure(s)\n' "$assertions" "$failures"
[ "$failures" -eq 0 ] || exit 1
printf 'disclosure-drift-sweep: OK\n'
