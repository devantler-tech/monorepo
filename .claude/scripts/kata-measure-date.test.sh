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
# The forge's sub-issue summary in the four shapes the delivery cases need.
none='{"total":0,"completed":0,"percent_completed":0}'
open1='{"total":1,"completed":0,"percent_completed":0}'
closed1='{"total":1,"completed":1,"percent_completed":100}'
mixed='{"total":3,"completed":2,"percent_completed":66}'
# kata <body> [today] — a stdin payload for a Kata whose delivery lives in one OPEN sub-issue, so
# the date-reading cases below are about the date alone. The delivery cases further down use `solo`.
kata() {
  if [ "$#" -ge 2 ]; then
    jq -nc --arg b "$1" --arg t "$2" --argjson s "${open1}" '{body: $b, today: $t, sub_issues: $s}'
  else
    jq -nc --arg b "$1" --argjson s "${open1}" '{body: $b, sub_issues: $s}'
  fi
}
# solo <body> <today> [sub_issues as JSON] — a Kata payload with exactly the summary given; with
# no third argument the key is absent, as an old caller would send it.
solo() {
  if [ "$#" -ge 3 ]; then
    jq -nc --arg b "$1" --arg t "$2" --argjson s "$3" '{body: $b, today: $t, sub_issues: $s}'
  else
    jq -nc --arg b "$1" --arg t "$2" '{body: $b, today: $t}'
  fi
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

# Text that does not render — code blocks and HTML comments — is an example or an instruction,
# never this Kata's date.
fence='```'
expect "a fenced example alone is not the line" 2 "UNKNOWN missing" \
  "$(kata "Write it like this:"$'\n'"${fence}"$'\n**Measure on:** 2026-10-20\n'"${fence}" 2026-09-25)"
expect "a fenced example does not conflict with the real line" 1 "NOT-DUE 2026-11-01" \
  "$(kata "${fence}md"$'\n**Measure on:** 2026-10-20\n'"${fence}"$'\n\n**Measure on:** 2026-11-01' 2026-09-25)"
expect "a tilde fence is a fence too" 2 "UNKNOWN missing" \
  "$(kata $'~~~\n**Measure on:** 2026-10-20\n~~~' 2026-09-25)"
expect "a backtick fence is not closed by a tilde line" 2 "UNKNOWN missing" \
  "$(kata "${fence}"$'\n~~~\n**Measure on:** 2026-10-20\n'"${fence}" 2026-09-25)"
# The full CommonMark fence rule: a closing fence repeats the opening character at least as many
# times, with nothing after it but whitespace.
expect "a shorter run inside a longer fence does not close it" 2 "UNKNOWN missing" \
  "$(kata "\`\`\`\`"$'\n'"${fence}"$'\n**Measure on:** 2099-01-01\n'"\`\`\`\`" 2026-09-25)"
expect "a shorter tilde run inside a longer tilde fence does not close it" 2 "UNKNOWN missing" \
  "$(kata $'~~~~\n~~~\n**Measure on:** 2099-01-01\n~~~~' 2026-09-25)"
expect "a longer run closes a fence" 1 "NOT-DUE 2026-10-20" \
  "$(kata "${fence}"$'\nexample\n'"\`\`\`\`\`"$'\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a fence line followed by text does not close the fence" 2 "UNKNOWN missing" \
  "$(kata "${fence}"$'\n'"${fence} not a close"$'\n**Measure on:** 2026-10-20\n'"${fence}" 2026-09-25)"
expect "a backtick run whose info string holds a backtick is inline code, not a fence" 1 "NOT-DUE 2026-10-20" \
  "$(kata "${fence} aa ${fence}"$'\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a tilde fence's info string may hold a backtick" 2 "UNKNOWN missing" \
  "$(kata $'~~~ a`b\n**Measure on:** 2026-10-20\n~~~' 2026-09-25)"
expect "a fence indented four spaces is code, not a fence" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'    '"${fence}"$'\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "an indented code block is not the line" 2 "UNKNOWN missing" \
  "$(kata $'Example:\n\n    **Measure on:** 2026-10-20' 2026-09-25)"
expect "a tab-indented line is code, not the line" 2 "UNKNOWN missing" "$(kata $'\t**Measure on:** 2026-10-20' 2026-09-25)"
expect "a fenced example opened by a list item is not the line" 2 "UNKNOWN missing" \
  "$(kata "- ${fence}"$'\n  **Measure on:** 2099-01-01\n  '"${fence}" 2026-09-25)"
expect "a fenced example opened by an ordered list item is not the line" 2 "UNKNOWN missing" \
  "$(kata "1. ${fence}"$'\n   **Measure on:** 2099-01-01\n   '"${fence}" 2026-09-25)"
expect "a list-contained fenced example does not conflict with the real line" 1 "NOT-DUE 2026-10-20" \
  "$(kata "- ${fence}"$'\n  **Measure on:** 2099-01-01\n  '"${fence}"$'\n\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a multi-line HTML comment is not the line" 2 "UNKNOWN missing" \
  "$(kata $'<!--\n**Measure on:** YYYY-MM-DD\n-->' 2026-09-25)"
expect "the line after a closed HTML comment counts" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'<!-- template:\n**Measure on:** 2026-01-01\n-->\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a one-line HTML comment changes nothing after it" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'<!-- note -->\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a comment reopened on a closing line hides subsequent markers" 2 "UNKNOWN missing" \
  "$(kata $'<!-- first\n--> <!-- second\n**Measure on:** 2099-01-01\n-->' 2026-09-25)"
expect "a comment closed and reopened on a closing line does not conflict with the real line" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'<!-- first\n--> <!-- second\n**Measure on:** 2099-01-01\n-->\n**Measure on:** 2026-10-20' 2026-09-25)"

# Without `today` the helper uses the current UTC date; far past and far future are stable.
expect "without today, a far-past date is DUE" 0 "DUE 2000-01-01" "$(kata $'**Measure on:** 2000-01-01')"
expect "without today, a far-future date is NOT-DUE" 1 "NOT-DUE 2999-12-31" "$(kata $'**Measure on:** 2999-12-31')"

# ── Delivery comes first (monorepo#3619) ─────────────────────────────────────────────────────────
# Skip reason (d) covers a DELIVERED experiment waiting for its date. A future date alone used to
# read NOT-DUE, which hid a Kata that carries its own undelivered actions until its date arrived
# with nothing to measure. monorepo#3407 is that shape: no sub-issue, three pilots still to run.
own='## Actions\n\n- pick pilot 1\n\n**Measure on:** 2026-10-20\n'
own="$(printf '%b' "${own}")"
expect "a future date with no delivery on record is UNDELIVERED, never a skip" 3 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}" 2026-09-25 "${none}")"
expect "an unknown sub-issue summary proves no open sub-issue" 3 "UNDELIVERED 2026-10-20" "$(solo "${own}" 2026-09-25 null)"
expect "an absent sub-issue summary proves no open sub-issue" 3 "UNDELIVERED 2026-10-20" "$(solo "${own}" 2026-09-25)"
expect "an open sub-issue carries the delivery, so the skip hides nothing" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${own}" 2026-09-25 "${open1}")"
expect "one open sub-issue among closed ones is enough" 1 "NOT-DUE 2026-10-20" "$(solo "${own}" 2026-09-25 "${mixed}")"
# A closed sub-issue proves only that it closed: the Kata can carry actions no child covered, and
# nothing selectable is left to do them. The skip would hide that work, so it does not apply.
expect "a Kata whose sub-issues have all closed is UNDELIVERED until its delivery is recorded" 3 \
  "UNDELIVERED 2026-10-20" "$(solo "${own}" 2026-09-25 "${closed1}")"
expect "counts written as 1.0 and 0.0 are still one open sub-issue" 1 "NOT-DUE 2026-10-20" \
  "$(printf '{"body":%s,"today":"2026-09-25","sub_issues":{"total":1.0,"completed":0.0}}' "$(jq -n --arg b "${own}" '$b')")"
delivered="${own}"$'\n**Delivered on:** 2026-09-20\n'
expect "a recorded delivery makes a Kata with closed sub-issues NOT-DUE" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${delivered}" 2026-09-25 "${closed1}")"
expect "a recorded delivery makes a future date NOT-DUE" 1 "NOT-DUE 2026-10-20" "$(solo "${delivered}" 2026-09-25 "${none}")"
expect "a delivery recorded today counts" 1 "NOT-DUE 2026-10-20" "$(solo "${delivered}" 2026-09-20 "${none}")"
expect "a delivery date still ahead is an intention, not a delivery" 3 "UNDELIVERED 2026-10-20" \
  "$(solo "${delivered}" 2026-09-19 "${none}")"
expect "the same delivery date repeated is one date" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${delivered}"$'\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a delivery line that is not a date is UNKNOWN" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n**Delivered on:** last week' 2026-09-25 "${none}")"
expect "an empty delivery line is UNKNOWN" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n**Delivered on:**' 2026-09-25 "${none}")"
expect "an impossible delivery date is UNKNOWN" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n**Delivered on:** 2026-02-30' 2026-09-25 "${none}")"
expect "two different delivery dates are UNKNOWN, not the earlier or the later" 2 \
  "UNKNOWN conflicting-delivery 2026-09-01,2026-09-20" \
  "$(solo "${delivered}"$'\n**Delivered on:** 2026-09-01' 2026-09-25 "${none}")"
# A malformed delivery line is reported even when a sub-issue would settle the verdict: the line
# is this Kata's record and a later reader will trust it.
expect "a malformed delivery line is UNKNOWN beside an open sub-issue too" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n**Delivered on:** soon' 2026-09-25 "${open1}")"
# Only rendered text records a delivery, exactly as for the measurement date.
expect "a quoted delivery line is someone else's text" 3 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n> **Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a fenced delivery line is an example" 3 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n'"${fence}"$'\n**Delivered on:** 2026-09-20\n'"${fence}" 2026-09-25 "${none}")"
expect "a delivery line inside an HTML comment is a template" 3 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n<!--\n**Delivered on:** 2026-09-20\n-->' 2026-09-25 "${none}")"
expect "prose naming a delivery is not the line" 3 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\nDelivered on 2026-09-20 through the pilot.' 2026-09-25 "${none}")"
expect "a delivery line does not stand in for the measurement date" 2 "UNKNOWN missing" \
  "$(solo $'**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
# A paragraph line straight after a quoted line is still inside the quote, for either marker.
expect "a delivery line that continues a quote is someone else's text" 3 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n> someone wrote\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a delivery line after a quote and a blank line counts" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${own}"$'\n> someone wrote\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a delivery line after a quote and a heading counts" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${own}"$'\n> someone wrote\n## Delivery\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a measurement line that continues a quote is not this Kata's date" 2 "UNKNOWN missing" \
  "$(solo $'> they suggested\n**Measure on:** 2026-10-20' 2026-09-25 "${open1}")"
# A NUL byte ends a line for BSD awk, which hid whatever followed it on that line.
expect "a comment opened after a NUL byte still hides the delivery line" 3 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\nx\x01<!--\n**Delivered on:** 2026-09-20\n-->' 2026-09-25 "${none}" | sed 's/\\u0001/\\u0000/')"
expect "trailing words after a NUL byte still make a delivery line malformed" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n**Delivered on:** 2026-09-20\x01 not yet' 2026-09-25 "${none}" | sed 's/\\u0001/\\u0000/')"
# Once the date arrives the Kata is actionable whatever was delivered, so delivery is not read.
expect "an arrived date is DUE with nothing delivered" 0 "DUE 2026-10-20" "$(solo "${own}" 2026-10-20 "${none}")"
expect "an arrived date is DUE beside a malformed delivery line" 0 "DUE 2026-10-20" \
  "$(solo "${own}"$'\n**Delivered on:** soon' 2026-10-21 "${none}")"

# Negative controls: each delivery guard, removed, must change the verdict it exists for. A
# control that left the helper unchanged would prove nothing, so that is checked first.
mutants="$(mktemp -d)"
mutant() { # mutant <name> <sed expression> — writes a mutated helper and requires it to differ
  sed "$2" "${tool}" >"${mutants}/$1.sh"
  chmod +x "${mutants}/$1.sh"
  checks=$((checks + 1))
  if cmp -s "${tool}" "${mutants}/$1.sh"; then
    echo "FAIL control $1 did not change the helper" >&2
    failures=$((failures + 1))
  else
    echo "ok   control $1 changes the helper"
  fi
}
expect_mutant() { # expect_mutant <label> <mutant> <the WRONG verdict the mutant must give> <stdin>
  # The exact wrong verdict is required: a mutant that merely crashed prints nothing, and that
  # would say the mutation broke the helper, not that the guard it removed was doing the work.
  local out
  checks=$((checks + 1))
  out="$(printf '%s' "$4" | "${mutants}/$2.sh" --input - 2>/dev/null)" || true
  if [ "${out}" = "$3" ]; then
    echo "ok   control caught: $1"
  else
    echo "FAIL control not caught: $1 (wanted ${3}, got ${out})" >&2
    failures=$((failures + 1))
  fi
}
mutant no-delivery-gate 's/^hides_nothing=no$/hides_nothing=yes/'
expect_mutant "without the delivery gate an undelivered Kata reads NOT-DUE" no-delivery-gate \
  "NOT-DUE 2026-10-20" "$(solo "${own}" 2026-09-25 "${none}")"
# shellcheck disable=SC2016 # the expression matches the helper's own text; nothing here expands
mutant future-delivery-counts 's/ && \[\[ ! "${delivered_on}" > "${today}" \]\]//'
expect_mutant "without the date test a planned delivery reads delivered" future-delivery-counts \
  "NOT-DUE 2026-10-20" "$(solo "${delivered}" 2026-09-19 "${none}")"
mutant children-ignored 's/ >= 1 then "yes" else "no" end/ >= 1 then "no" else "no" end/'
expect_mutant "without the open sub-issue test a Kata with an open child reads UNDELIVERED" children-ignored \
  "UNDELIVERED 2026-10-20" "$(solo "${own}" 2026-09-25 "${open1}")"
mutant closed-children-count 's/(\.sub_issues\.total - \.sub_issues\.completed) >= 1/.sub_issues.total >= 1/'
expect_mutant "counting closed sub-issues hides a Kata whose children have all closed" closed-children-count \
  "NOT-DUE 2026-10-20" "$(solo "${own}" 2026-09-25 "${closed1}")"
mutant no-lazy-quote 's/^    if (in_quote) next$//'
expect_mutant "without the quote rule a delivery line that continues a quote counts" no-lazy-quote \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n> someone wrote\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
rm -rf "${mutants}"

# Unreadable input judges nothing: exit 2 and no verdict on stdout.
measure='"body":"**Measure on:** 2026-10-20"'
expect "a bare sub-issue count instead of the summary" 2 "" "{${measure},\"sub_issues\":1}"
expect "a summary with a negative count" 2 "" "{${measure},\"sub_issues\":{\"total\":1,\"completed\":-1}}"
expect "a summary with a fractional count" 2 "" "{${measure},\"sub_issues\":{\"total\":1.5,\"completed\":0}}"
expect "a summary with a count that is not a number" 2 "" "{${measure},\"sub_issues\":{\"total\":\"1\",\"completed\":0}}"
expect "a summary with more completed than total" 2 "" "{${measure},\"sub_issues\":{\"total\":1,\"completed\":2}}"
expect "a summary missing its completed count" 2 "" "{${measure},\"sub_issues\":{\"total\":1}}"
expect "a summary with an absurd count" 2 "" "{${measure},\"sub_issues\":{\"total\":1e300,\"completed\":0}}"
expect "not JSON" 2 "" "not json"
expect "two JSON documents" 2 "" '{"body":"a"}{"body":"b"}'
expect "a body that is not a string" 2 "" '{"body":42}'
expect "an unexpected key" 2 "" '{"body":"x","createdAt":"2026-07-19T00:00:00Z"}'
expect "a malformed today" 2 "" '{"body":"**Measure on:** 2026-10-20","today":"25/09/2026"}'
expect "an impossible today" 2 "" '{"body":"**Measure on:** 2026-10-20","today":"2026-02-30"}'

# ── The contract routes skip reason (d) through delivery (monorepo#3619) ─────────────────────────
# The helper can only say UNDELIVERED if the survey hands it the sub-issue count and then keeps the
# Kata, and if the selection rule tells a run what the verdict means. Pin each of those, and run
# the overlay's OWN projection so its key names cannot drift from the ones the helper accepts.
repo_root="$(cd "${here}/../.." && pwd)"
overlay="${repo_root}/.claude/agents/portfolio-surveyor.md"
# Each text is cut down to the passage that carries the rule and then flattened. Scoping keeps a
# phrase that survives elsewhere in the file from satisfying a clause, and keeps the strings short:
# bash 3.2 takes minutes to substitute inside a whole flattened definition.
flat() { tr '\n' ' ' | tr -s ' '; }
overlay_flat="$(grep -A 6 -F 'whose named measurement date is still in the FUTURE' "${overlay}" | flat || true)"
selection_flat="$(sed -n '/(d) a delivered experiment is$/,/Once that date arrives/p' \
  "${repo_root}/.claude/guides/work-selection.md" | flat)"
board_flat="$(grep -F '| **Kata** |' "${repo_root}/.claude/guides/issues-and-board.md" | flat || true)"
# missing_clause <text> <clause>... — prints the first clause the text lacks
missing_clause() {
  local text="$1" clause
  shift
  for clause in "$@"; do
    case "${text}" in
      *"${clause}"*) ;;
      *) printf '%s\n' "${clause}"; return ;;
    esac
  done
}
# shellcheck disable=SC2016 # backticks are literal Markdown in the clauses, not substitutions
overlay_clauses=(
  '**Exclude a DELIVERED `Kata` whose named measurement date is still in the FUTURE**'
  'An undelivered one is delivery work (monorepo#3619).'
  "--jq '{body:(.body // \"\"),sub_issues:.sub_issues_summary}' | <repo-root>/.claude/scripts/kata-measure-date.sh --input -"
  '`NOT-DUE <date>` excludes it'
  '`UNDELIVERED <date>` keeps it as delivery work'
  '`UNKNOWN …` reports its `**Measure on:**` or (`…-delivery`) `**Delivered on:**` line for repair'
)
# shellcheck disable=SC2016 # backticks are literal Markdown in the clauses, not substitutions
selection_clauses=(
  'awaiting its **named, future measurement date**'
  '**"Delivered" is part of the test, not a description** (monorepo#3619)'
  'Either the experiment has at least one **open** sub-issue, which carries its remaining delivery work and stays selectable'
  'its body carries a `**Delivered on:** YYYY-MM-DD` line (a UTC date, today or earlier), which the delivering run adds'
  'An experiment with a future date and neither is **delivery work, never a skip**'
  'That includes one whose sub-issues have all closed. A closed child proves only that the child closed'
  '`NOT-DUE` is the skip, `UNDELIVERED` is delivery work, and its `UNKNOWN` is a line to repair, never a skip'
)
contract() { # contract <label> <text> <clause>...
  local label="$1" text="$2" lacking
  shift 2
  checks=$((checks + 1))
  lacking="$(missing_clause "${text}" "$@")"
  if [ -z "${lacking}" ]; then
    echo "ok   contract: ${label}"
  else
    echo "FAIL contract: ${label} — must say: ${lacking}" >&2
    failures=$((failures + 1))
  fi
}
contract "the survey excludes only a delivered Kata and keeps an undelivered one" "${overlay_flat}" "${overlay_clauses[@]}"
contract "skip reason (d) requires delivery on record" "${selection_flat}" "${selection_clauses[@]}"
# shellcheck disable=SC2016 # backticks are literal Markdown in the clause, not a substitution
contract "the Kata type names where its delivery is recorded" "${board_flat}" \
  'its delivery carried by open sub-issues or its own actions, and recorded as a `**Delivered on:** YYYY-MM-DD` line when done'
# Controls: the same check must reject a contract that lost the delivery condition, each for the
# clause that carried it. A mutation that changed nothing would prove nothing.
control() { # control <label> <text> <mutated text> <expected fragment of the missing clause> <clause>...
  local label="$1" text="$2" mutated="$3" want="$4"
  shift 4
  checks=$((checks + 1))
  if [ "${mutated}" != "${text}" ] && [[ "$(missing_clause "${mutated}" "$@")" == *"${want}"* ]]; then
    echo "ok   control: ${label}"
  else
    echo "FAIL control: ${label}" >&2
    failures=$((failures + 1))
  fi
}
control "an overlay that excludes every future-dated Kata is rejected" "${overlay_flat}" \
  "${overlay_flat//Exclude a DELIVERED /Exclude a }" 'Exclude a DELIVERED' "${overlay_clauses[@]}"
control "an overlay that drops the sub-issue summary is rejected" "${overlay_flat}" \
  "${overlay_flat//,sub_issues:.sub_issues_summary/}" 'sub_issues:.sub_issues_summary' "${overlay_clauses[@]}"
control "an overlay that drops the UNDELIVERED verdict is rejected" "${overlay_flat}" \
  "${overlay_flat//UNDELIVERED <date>/NOT-DUE <date>}" 'UNDELIVERED <date>' "${overlay_clauses[@]}"
control "a selection rule that skips an undelivered experiment is rejected" "${selection_flat}" \
  "${selection_flat//delivery work, never a skip/a skip}" 'delivery work, never a skip' "${selection_clauses[@]}"
control "a selection rule that counts closed sub-issues is rejected" "${selection_flat}" \
  "${selection_flat//at least one \*\*open\*\* sub-issue/at least one sub-issue}" '**open** sub-issue' "${selection_clauses[@]}"

# The overlay's own projection, applied to issue objects shaped like the forge's, must give the
# helper a payload it accepts and the verdict the rule promises. A far-future date keeps it stable.
projection="$(grep -o -- "--jq '{body:[^']*}' | <repo-root>/.claude/scripts/kata-measure-date.sh --input -" "${overlay}" |
  sed -e "s/^--jq '//" -e "s/' | <repo-root>.*\$//" || true)"
checks=$((checks + 1))
if [ "$(grep -c . <<<"${projection}")" = 1 ]; then
  echo "ok   the overlay prescribes exactly one Kata projection"
else
  echo "FAIL the overlay must prescribe exactly one Kata projection, found: ${projection}" >&2
  failures=$((failures + 1))
fi
projected() { # projected <label> <want-exit> <want-stdout> <forge issue JSON>
  local label="$1" want_rc="$2" want_out="$3" issue="$4" out rc=0
  checks=$((checks + 1))
  out="$(jq -c "${projection}" <<<"${issue}" 2>/dev/null | "${tool}" --input - 2>/dev/null)" || rc=$?
  if [ "${rc}" = "${want_rc}" ] && [ "${out}" = "${want_out}" ]; then
    echo "ok   ${label}"
  else
    echo "FAIL ${label}: want rc=${want_rc} [${want_out}], got rc=${rc} [${out}]" >&2
    failures=$((failures + 1))
  fi
}
far='{"body":"**Measure on:** 2999-12-31"'
projected "the overlay's projection of a Kata with no sub-issue is UNDELIVERED" 3 "UNDELIVERED 2999-12-31" \
  "${far},\"sub_issues_summary\":${none}}"
projected "the overlay's projection of a Kata with an open sub-issue is NOT-DUE" 1 "NOT-DUE 2999-12-31" \
  "${far},\"sub_issues_summary\":${open1}}"
projected "the overlay's projection of a Kata whose sub-issues have all closed is UNDELIVERED" 3 "UNDELIVERED 2999-12-31" \
  "${far},\"sub_issues_summary\":${closed1}}"
projected "the overlay's projection of an issue with no summary proves no open sub-issue" 3 "UNDELIVERED 2999-12-31" \
  "${far}}"
projected "the overlay's projection of an issue with no body is UNKNOWN missing" 2 "UNKNOWN missing" \
  "{\"body\":null,\"sub_issues_summary\":${open1}}"

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
