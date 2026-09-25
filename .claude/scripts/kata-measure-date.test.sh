#!/usr/bin/env bash
# kata-measure-date.test.sh — behavioural proof for kata-measure-date.sh (monorepo#2838).
#
# The survey once reported both open Katas as past due by reading each issue's createdAt as its
# measurement date; one was two days from its real date. The helper reads only the Kata body's
# `**Measure on:** YYYY-MM-DD` line, so this test pins that a date anywhere else never counts,
# that the date itself is the first due day, and that every unreadable shape is UNKNOWN (exit 2)
# rather than a guessed verdict.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${here}/kata-measure-date.sh"
checks=0
failures=0
kata_measure_date_test_finished=0
trap '[ "${kata_measure_date_test_finished}" = 1 ] || { echo "kata-measure-date.test.sh: aborted before finishing" >&2; exit 1; }' EXIT

# expect <label> <want-exit> <want-stdout> <stdin>
expect() {
  local label="$1" want_rc="$2" want_out="$3" payload="$4" out rc=0
  checks=$((checks + 1))
  out="$(printf '%s' "${payload}" | "${tool}" --input - 2>/dev/null)" || rc=$?
  if [ "${rc}" = "${want_rc}" ] && [ "${out}" = "${want_out}" ]; then
    echo "ok   ${label}"
  else
    echo "FAIL ${label}: want rc=${want_rc} [${want_out}], got rc=${rc} [${out}]" >&2
    failures=$((failures + 1))
  fi
}
# kata <body> [today] — a stdin payload.
kata() {
  if [ "$#" -ge 2 ]; then jq -nc --arg b "$1" --arg t "$2" '{body: $b, today: $t}'; else jq -nc --arg b "$1" '{body: $b}'; fi
}

[ -x "${tool}" ] || { echo "FAIL cannot execute ${tool}" >&2; exit 1; }

body=$'## Target condition\n\nHalve the wait.\n\n**Measure on:** 2026-10-20\n'
expect "a future date is NOT-DUE, so skip reason (d) applies" 1 "NOT-DUE 2026-10-20" "$(kata "${body}" 2026-09-25)"
expect "the named date itself is the first due day" 0 "DUE 2026-10-20" "$(kata "${body}" 2026-10-20)"
expect "a past date is DUE" 0 "DUE 2026-10-20" "$(kata "${body}" 2026-12-01)"
expect "a GitHub web edit's CRLF line endings still parse" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'Target.\r\n\r\n**Measure on:** 2026-10-20\r\n' 2026-09-25)"
expect "leading indentation is allowed" 1 "NOT-DUE 2026-10-20" "$(kata $'  **Measure on:** 2026-10-20' 2026-09-25)"
expect "the same date repeated is one date" 0 "DUE 2026-10-20" \
  "$(kata $'**Measure on:** 2026-10-20\n\nlater:\n**Measure on:** 2026-10-20' 2026-11-01)"

# A date anywhere else is never the measurement date — that is the defect being fixed.
expect "prose naming a date is not the line: UNKNOWN, never a guess" 2 "UNKNOWN missing" \
  "$(kata $'**First measurement date: 2026-10-20.**\n- Follow-up date: 2026-09-27\nMeasure by 2026-08-16.' 2026-09-25)"
expect "a quoted line is someone else's text, not this Kata's date" 2 "UNKNOWN missing" \
  "$(kata $'> **Measure on:** 2026-10-20' 2026-09-25)"
expect "an empty body is UNKNOWN" 2 "UNKNOWN missing" "$(kata '' 2026-09-25)"
expect "two different dates are UNKNOWN, not the earlier or the later" 2 "UNKNOWN conflicting 2026-09-01,2026-10-20" \
  "$(kata $'**Measure on:** 2026-10-20\n**Measure on:** 2026-09-01' 2026-09-25)"
expect "a date that is not a date is UNKNOWN" 2 "UNKNOWN malformed" "$(kata $'**Measure on:** 2026-13-40' 2026-09-25)"
# Shaped like a date but never on the calendar: classifying it would postpone or trigger a
# measurement on a day that does not exist.
expect "February 30 is UNKNOWN" 2 "UNKNOWN malformed" "$(kata $'**Measure on:** 2026-02-30' 2026-09-25)"
expect "April 31 is UNKNOWN" 2 "UNKNOWN malformed" "$(kata $'**Measure on:** 2026-04-31' 2026-09-25)"
expect "February 29 outside a leap year is UNKNOWN" 2 "UNKNOWN malformed" "$(kata $'**Measure on:** 2026-02-29' 2026-09-25)"
expect "February 29 in a leap year is a date" 1 "NOT-DUE 2028-02-29" "$(kata $'**Measure on:** 2028-02-29' 2026-09-25)"
expect "February 29 in a century year not divisible by 400 is UNKNOWN" 2 "UNKNOWN malformed" \
  "$(kata $'**Measure on:** 2100-02-29' 2026-09-25)"
expect "February 29 in a year divisible by 400 is a date" 1 "NOT-DUE 2400-02-29" "$(kata $'**Measure on:** 2400-02-29' 2026-09-25)"
expect "a line without a date is UNKNOWN" 2 "UNKNOWN malformed" "$(kata $'**Measure on:** after the next release' 2026-09-25)"
# An empty value must survive to validation: command substitution strips trailing newlines, so a
# final empty line would otherwise vanish and the earlier date would be classified alone.
expect "a valid line followed by an empty one is UNKNOWN" 2 "UNKNOWN malformed" \
  "$(kata $'**Measure on:** 2026-10-20\n**Measure on:**' 2026-09-25)"
expect "a valid line followed by a blank one is UNKNOWN" 2 "UNKNOWN malformed" \
  "$(kata $'**Measure on:** 2026-10-20\n**Measure on:**   \n' 2026-09-25)"
expect "an empty line on its own is malformed, not missing" 2 "UNKNOWN malformed" "$(kata $'**Measure on:**' 2026-09-25)"
expect "trailing words after the date are UNKNOWN" 2 "UNKNOWN malformed" "$(kata $'**Measure on:** 2026-10-20 or later' 2026-09-25)"

# Without `today` the helper uses the current UTC date; far past and far future are stable.
expect "without today, a far-past date is DUE" 0 "DUE 2000-01-01" "$(kata $'**Measure on:** 2000-01-01')"
expect "without today, a far-future date is NOT-DUE" 1 "NOT-DUE 2999-12-31" "$(kata $'**Measure on:** 2999-12-31')"

# Unreadable input judges nothing: exit 2 and no verdict on stdout.
expect "not JSON" 2 "" "not json"
expect "two JSON documents" 2 "" '{"body":"a"}{"body":"b"}'
expect "a body that is not a string" 2 "" '{"body":42}'
expect "an unexpected key" 2 "" '{"body":"x","createdAt":"2026-07-19T00:00:00Z"}'
expect "a malformed today" 2 "" '{"body":"**Measure on:** 2026-10-20","today":"25/09/2026"}'
expect "an impossible today" 2 "" '{"body":"**Measure on:** 2026-10-20","today":"2026-02-30"}'

checks=$((checks + 1))
if "${tool}" --input /dev/null >/dev/null 2>&1 || "${tool}" >/dev/null 2>&1 </dev/null; then
  echo "FAIL anything but --input - must be a usage error" >&2
  failures=$((failures + 1))
else
  echo "ok   anything but --input - is a usage error"
fi

kata_measure_date_test_finished=1
if [ "${failures}" -gt 0 ]; then
  echo "kata-measure-date.test.sh: ${failures} of ${checks} checks FAILED" >&2
  exit 1
fi
echo "kata-measure-date.test.sh: all ${checks} checks passed"
