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
  "$(kata $'**Measure on:** 2026-10-20\n\nlater:\n\n**Measure on:** 2026-10-20' 2026-11-01)"

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
  "$(kata "${fence}"$'\nexample\n'"\`\`\`\`\`"$'\n\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a fence line followed by text does not close the fence" 2 "UNKNOWN missing" \
  "$(kata "${fence}"$'\n'"${fence} not a close"$'\n**Measure on:** 2026-10-20\n'"${fence}" 2026-09-25)"
expect "a backtick run whose info string holds a backtick is inline code, not a fence" 1 "NOT-DUE 2026-10-20" \
  "$(kata "${fence} aa ${fence}"$'\n\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a tilde fence's info string may hold a backtick" 2 "UNKNOWN missing" \
  "$(kata $'~~~ a`b\n**Measure on:** 2026-10-20\n~~~' 2026-09-25)"
expect "a fence indented four spaces is code, not a fence" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'    '"${fence}"$'\n\n**Measure on:** 2026-10-20' 2026-09-25)"
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
  "$(kata $'<!-- template:\n**Measure on:** 2026-01-01\n-->\n\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a one-line HTML comment changes nothing after it" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'<!-- note -->\n\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a comment reopened on a closing line hides subsequent markers" 2 "UNKNOWN missing" \
  "$(kata $'<!-- first\n--> <!-- second\n**Measure on:** 2099-01-01\n-->' 2026-09-25)"
# The reopened comment is raw HTML, and the `-->` under the hidden line is ordinary text, which the
# renderer escapes. So that comment never closes and the page shows nothing after it. This case
# used to expect the last line to count; the forge's renderer, asked on 2026-10-07, hides it.
expect "a closer in ordinary text does not end a comment reopened on a closing line" 2 "UNKNOWN missing" \
  "$(kata $'<!-- first\n--> <!-- second\n**Measure on:** 2099-01-01\n-->\n\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "a closer on a line of raw HTML does end it" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'<!-- first\n--> <!-- second\n**Measure on:** 2099-01-01\n\n<p>-->\n\n**Measure on:** 2026-10-20' 2026-09-25)"

# Without `today` the helper uses the current UTC date; far past and far future are stable.
expect "without today, a far-past date is DUE" 0 "DUE 2000-01-01" "$(kata $'**Measure on:** 2000-01-01')"
expect "without today, a far-future date is NOT-DUE" 1 "NOT-DUE 2999-12-31" "$(kata $'**Measure on:** 2999-12-31')"

# ── Delivery comes first (monorepo#3619) ─────────────────────────────────────────────────────────
# Skip reason (d) covers a DELIVERED experiment waiting for its date. A future date alone used to
# read NOT-DUE, which hid a Kata that carries its own undelivered actions until its date arrived
# with nothing to measure. monorepo#3407 is that shape: no sub-issue, three pilots still to run.
own='## Actions\n\n- pick pilot 1\n\n**Measure on:** 2026-10-20\n'
own="$(printf '%b' "${own}")"
expect "a future date with no delivery on record is UNDELIVERED, never a skip" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}" 2026-09-25 "${none}")"
# A summary the read did not carry is not a count of zero. Calling the Kata undelivered on it could
# select a parent whose open child already holds the work, so the read gets no verdict at all.
expect "a null sub-issue summary gives no verdict when the verdict needs it" 2 "" "$(solo "${own}" 2026-09-25 null)"
expect "an absent sub-issue summary gives no verdict when the verdict needs it" 2 "" "$(solo "${own}" 2026-09-25)"
# It is needed only for a future date with no delivery line; the other verdicts never read it.
expect "an arrived date is DUE without a sub-issue summary" 0 "DUE 2026-10-20" "$(solo "${own}" 2026-10-20)"
expect "a recorded delivery is NOT-DUE without a sub-issue summary" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${own}"$'\n**Delivered on:** 2026-09-20' 2026-09-25)"
expect "an open sub-issue carries the delivery, so the skip hides nothing" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${own}" 2026-09-25 "${open1}")"
expect "one open sub-issue among closed ones is enough" 1 "NOT-DUE 2026-10-20" "$(solo "${own}" 2026-09-25 "${mixed}")"
# A closed sub-issue proves only that it closed: the Kata can carry actions no child covered, and
# nothing selectable is left to do them. The skip would hide that work, so it does not apply.
expect "a Kata whose sub-issues have all closed is UNDELIVERED until its delivery is recorded" 0 \
  "UNDELIVERED 2026-10-20" "$(solo "${own}" 2026-09-25 "${closed1}")"
expect "counts written as 1.0 and 0.0 are still one open sub-issue" 1 "NOT-DUE 2026-10-20" \
  "$(printf '{"body":%s,"today":"2026-09-25","sub_issues":{"total":1.0,"completed":0.0}}' "$(jq -n --arg b "${own}" '$b')")"
delivered="${own}"$'\n**Delivered on:** 2026-09-20\n'
expect "a recorded delivery makes a Kata with closed sub-issues NOT-DUE" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${delivered}" 2026-09-25 "${closed1}")"
expect "a recorded delivery makes a future date NOT-DUE" 1 "NOT-DUE 2026-10-20" "$(solo "${delivered}" 2026-09-25 "${none}")"
expect "a delivery recorded today counts" 1 "NOT-DUE 2026-10-20" "$(solo "${delivered}" 2026-09-20 "${none}")"
expect "a delivery date still ahead is an intention, not a delivery" 0 "UNDELIVERED 2026-10-20" \
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
expect "a quoted delivery line is someone else's text" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n> **Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a fenced delivery line is an example" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n'"${fence}"$'\n**Delivered on:** 2026-09-20\n'"${fence}" 2026-09-25 "${none}")"
expect "a delivery line inside an HTML comment is a template" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n<!--\n**Delivered on:** 2026-09-20\n-->' 2026-09-25 "${none}")"
expect "prose naming a delivery is not the line" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\nDelivered on 2026-09-20 through the pilot.' 2026-09-25 "${none}")"
expect "a delivery line does not stand in for the measurement date" 2 "UNKNOWN missing" \
  "$(solo $'**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
# ── Where a line counts: only at the start of a paragraph ────────────────────────────────────────
# The rule is a whitelist. A date line is read on the body's first line, after a blank line, or
# directly under the other date line. Anywhere else it is neither counted nor dropped: the verdict
# is UNKNOWN, so a line that only looks like a record can never hide the work. Listing the places
# a line does NOT count was tried first, and three review rounds each found one more.
under() { # under <label> <the line directly above the delivery line>
  expect "a delivery line directly under $1 is not read as delivered" 2 "UNKNOWN malformed-delivery" \
    "$(solo "${own}"$'\n'"$2"$'\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
}
under "a line of text" 'The pilots ran.'
under "a quoted line" '> someone wrote'
under "a nested quoted line" '> > someone wrote'
under "a quoted list item" '> - someone wrote'
under "an empty quoted line" '>'
under "a quoted heading" '> ## Note'
under "a heading" '## Delivery'
under "a thematic break" '---'
under "a bullet item" '- done'
under "an ordered item" '1. done'
under "a block-level tag" '<div>'
under "a closing block-level tag" '</details>'
under "an inline tag" '<span>note</span>'
under "a one-line HTML comment" '<!-- note -->'
under "a setext underline" '==='
expect "a delivery line directly under a closed fence is not read as delivered" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n'"${fence}"$'\nexample\n'"${fence}"$'\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a delivery line directly under a closed HTML comment is not read as delivered" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n<!--\nnote\n-->\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
# The case the review named: a tag-opened HTML block that interrupts a quoted paragraph runs to the
# next blank line, so the line under the tag is raw HTML and not this Kata's record.
expect "a delivery line under a tag that interrupts a quote is not read as delivered" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n> someone wrote\n<div>\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a measurement line directly under a quoted line is not read as the date" 2 "UNKNOWN malformed" \
  "$(solo $'> they suggested\n**Measure on:** 2026-10-20' 2026-09-25 "${open1}")"
expect "a measurement line directly under a line of text is not read as the date" 2 "UNKNOWN malformed" \
  "$(kata $'Measure it then.\n**Measure on:** 2026-10-20' 2026-09-25)"
# A misplaced line is reported even beside a well-placed one: it is never silently dropped.
expect "a misplaced delivery line beside a well-placed one is still UNKNOWN" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${delivered}"$'\nnote\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a misplaced measurement line beside a well-placed one is still UNKNOWN" 2 "UNKNOWN malformed" \
  "$(kata $'**Measure on:** 2026-10-20\n\nnote\n**Measure on:** 2026-10-20' 2026-09-25)"

# A blank line ends whatever came before it, so the line after one starts a paragraph of its own.
after_blank() { # after_blank <label> <the line above the blank line>
  expect "a delivery line after $1 and a blank line counts" 1 "NOT-DUE 2026-10-20" \
    "$(solo "${own}"$'\n'"$2"$'\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
}
after_blank "a line of text" 'The pilots ran.'
after_blank "a quoted line" '> someone wrote'
after_blank "a heading" '## Delivery'
after_blank "a block-level tag" '<div>'
after_blank "a one-line HTML comment" '<!-- note -->'
after_blank "a one-line <pre> block" '<pre>example</pre>'
after_blank "a one-line declaration" '<!DOCTYPE html>'
after_blank "a one-line processing instruction" '<?note ?>'
after_blank "a tag that only begins like <pre>" '<preview>'
expect "a line of only spaces and tabs is a blank line" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${own}"$'\nThe pilots ran.\n \t \n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a delivery line on the body's first line counts" 1 "NOT-DUE 2026-10-20" \
  "$(solo $'**Delivered on:** 2026-09-20\n\n**Measure on:** 2026-10-20' 2026-09-25 "${none}")"
# The two lines may sit together: a line that is nothing but its label and a date opens nothing
# that could run on into the line below, so that line starts as cleanly as it did.
expect "a delivery line directly under the measurement line counts" 1 "NOT-DUE 2026-10-20" \
  "$(solo $'## Dates\n\n**Measure on:** 2026-10-20\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a measurement line directly under the delivery line counts" 1 "NOT-DUE 2026-10-20" \
  "$(solo $'**Delivered on:** 2026-09-20\n**Measure on:** 2026-10-20' 2026-09-25 "${none}")"
# Any other text on the upper line could open a code span or a link that swallows the lower one.
expect "a date line under a date line that carries other text is not read" 2 "UNKNOWN malformed" \
  "$(solo $'**Delivered on:** see `the\n**Measure on:** 2026-10-20\nnotes`' 2026-12-01 "${none}")"
expect "a pair of date lines that began under text is not read" 2 "UNKNOWN malformed" \
  "$(solo $'text\n**Delivered on:** 2026-09-20\n**Measure on:** 2026-10-20' 2026-12-01 "${none}")"

# An HTML block that runs to an end marker is not ended by a blank line, so a line inside one is an
# example even though a blank line stands before it. Once the block has closed, lines count again.
inside() { # inside <label> <opening line> <closing line>
  expect "a delivery line inside $1 is an example" 0 "UNDELIVERED 2026-10-20" \
    "$(solo "${own}"$'\n'"$2"$'\n\n**Delivered on:** 2026-09-20\n\n'"$3" 2026-09-25 "${none}")"
  expect "a delivery line after $1 has closed counts" 1 "NOT-DUE 2026-10-20" \
    "$(solo "${own}"$'\n'"$2"$'\n\nexample\n\n'"$3"$'\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
}
inside "a <pre> block" '<pre>' '</pre>'
inside "an upper-case <PRE> block with an attribute" '<PRE class="x">' '</PRE>'
inside "a <script> block" '<script>' '</script>'
inside "a <style> block" '<style>' '</style>'
inside "a <textarea> block" '<textarea>' '</textarea>'
inside "a processing instruction" '<?note' '?>'
inside "a declaration" '<!DOCTYPE note' '>'
inside "a CDATA section" '<![CDATA[' ']]>'
expect "a delivery line inside a <pre> block opened in a list item is an example" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n- <pre>\n\n  **Delivered on:** 2026-09-20\n  </pre>' 2026-09-25 "${none}")"
expect "a measurement line inside a <pre> block is an example, not this Kata's date" 2 "UNKNOWN missing" \
  "$(kata $'<pre>\n\n**Measure on:** 2026-10-20\n\n</pre>' 2026-09-25)"
expect "a comment opened on the line that opens <pre> does not end the block" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n<pre><!-- note\n-->\n\n**Delivered on:** 2026-09-20\n\n</pre>' 2026-09-25 "${none}")"
expect "a delivery line after a comment that held a whole <pre> block counts" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${own}"$'\n<!--\n<pre>\nexample\n</pre>\n-->\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"

# ── Measured against the forge's own renderer ────────────────────────────────────────────────────
# Each body below was sent to the forge's Markdown endpoint on 2026-10-07 (POST /markdown with
# the body as `text`, `mode` gfm and this repository as `context`) and the result read for the
# delivery line. `shown` cases came back with the line as a rendered bold label, that is with
# `<strong>Delivered on:</strong>` in the HTML; `hidden` cases came back with it as raw text, as
# code, or not at all. The property that matters is the second: a line the page does not show as
# the record must never count as one. In all 99 bodies measured, none did. The format's %s is
# the line.
measured() { # measured <want-exit> <want-stdout> <label> <printf format of the text under the measure line>
  local text
  # shellcheck disable=SC2059 # the format is the case itself
  text="$(printf -- "$4" '**Delivered on:** 2026-09-20')"
  expect "$3" "$1" "$2" "$(solo "${own}"$'\n'"${text}" 2026-09-25 "${none}")"
}
shown() { measured 1 "NOT-DUE 2026-10-20" "the page shows it, so it counts: $1" "$2"; }
hidden() { measured 0 "UNDELIVERED 2026-10-20" "the page does not show it, so it does not count: $1" "$2"; }
# shellcheck disable=SC2016 # backticks are literal Markdown in the cases, not substitutions
{
# An HTML comment exists only where the renderer passes text through as raw HTML. In ordinary
# text and in code the opener is escaped, so nothing after it is hidden.
shown "a code span holding a comment opener" 'The token `<!--` starts a comment.\n\n%s'
shown "a comment opener left open in a paragraph" 'text <!-- x\n\n%s\n\n-->'
shown "a four-space-indented comment opener, which is code" 'Example:\n\n    <!--\n\n%s\n\n    -->'
shown "a fence holding a comment opener" '```\n<!--\n```\n\n%s'
shown "a paragraph that starts with an inline tag and holds an opener" '<span>x</span> <!--\n\n%s'
shown "a paragraph that starts with an autolink and holds an opener" '<https://example.com> <!--\n\n%s'
shown "a tag with attributes and more text on its line, holding an opener" '<a href="x"> <!--\n\n%s'
shown "an opener in a paragraph, then a fence holding a closer" 'text <!--\n```\n-->\n```\n\n%s'
# In raw HTML it is a comment, and it stays open across blank lines and past the block it opened in.
hidden "a multi-line comment with blank lines" '<!--\n\n%s\n\n-->'
hidden "a comment opened on a block-level tag line" '<div> <!--\n\n%s\n\n-->'
hidden "a comment opened on a closing tag line" '</div> <!--\n\n%s'
hidden "a comment opened on a text line inside a tag-opened block" '<div>\ntext <!--\n\n%s\n\n-->'
hidden "a comment opened under a line that is one complete tag" '<a href="x">\ntext <!--\n\n%s'
hidden "a comment opened inside <pre>, after the block has closed" '<pre>\n<!--\n</pre>\n\n%s\n\n-->'
hidden "a comment opened inside <pre> and never closed" '<pre>\n<!--\n</pre>\n\n%s'
hidden "a comment opened inside <script>, after the block has closed" '<script>\n<!--\n</script>\n\n%s'
hidden "a comment opened inside <textarea>, after the block has closed" '<textarea>\n<!--\n</textarea>\n\n%s'
hidden "a comment block that interrupts a paragraph" 'text\n<!--\n\n%s\n\n-->'
hidden "a second comment left open on the line that closed the first" '<!-- a --> <!-- b\n\n%s'
hidden "a comment opened on a list item line" '- <!--\n\n  %s\n  -->'
hidden "a comment that only --!> tries to close" '<!--\na --!>\n\n%s'
# Only a closer that is raw HTML too can end it.
hidden "a comment opened in raw HTML, after a closer in a paragraph" '<div> <!--\n\nx\n\n-->\n\n%s'
hidden "a comment reopened on a closing line, after a closer in a paragraph" '<!-- first\n--> <!-- second\n\nx\n\n-->\n\n%s'
shown "a comment opened in raw HTML, after a closer on a tag line" '<div> <!--\n\nx\n\n<p>-->\n\n%s'
shown "a comment opened and closed inside <pre>" '<pre>\n<!--\n-->\n</pre>\n\n%s'
shown "a comment opened and closed inside <details>" '<details>\n<!--\nnote\n-->\n\n%s\n</details>'
shown "balanced comments inside a tag-opened block" '<div><!-- a -->\ntext <!--\nb -->\n\n%s'
shown "a stray closer inside a tag-opened block" '<div>\n-->\n\n%s'
shown "the empty comment <!-->" '<!-->\n\n%s'
shown "a comment closed with more text on its line" '<!-- a --> text\n\n%s'
# A block inside a comment is part of the comment, and a tag inside a tag-opened block is part of it.
shown "<pre> opened inside a comment, after the comment has closed" '<!--\n<pre>\n-->\n\n%s\n\n</pre>'
shown "a fence marker inside a comment, after the comment has closed" '<!--\n```\n-->\n\n%s\n\n```'
shown "<pre> inside a tag-opened block, after its blank line" '<div>\n<pre>\n\n%s\n\n</pre>'
shown "<details> with its summary and a text line, after a blank line" '<details>\n<summary>x</summary>\nsome text\n\n%s'
# An HTML block opens only on a line indented at most three spaces; deeper is code.
shown "a four-space-indented <pre>, which is code" 'Example:\n\n    <pre>\n\n%s'
shown "a tab-indented <pre>, which is code" '\t<pre>\n\n%s'
hidden "a four-space-indented line after a blank line, which is code" 'text\n\n    %s'
# A block or a fence opened inside a quote or a list item ends with it.
shown "a quoted <pre> left open, after the quote has ended" '> <pre>\n\n%s'
shown "<pre> left open in a list item, after the item has ended" '- <pre>\n\n%s'
shown "a comment block inside a list item, after it has closed" '- item\n  <!--\n  note\n  -->\n\n%s'
shown "a comment inside an ordered item, after the next item" '1. step\n   <!-- note\n   more -->\n2. next\n\n%s'
shown "a quoted comment block, after it has closed" '> <!--\n> note\n> -->\n\n%s'
shown "an indented comment block, after it has closed" '  <!--\n  note\n  -->\n\n%s'
hidden "a quoted line inside a quoted <pre>" '> <pre>\n>\n> %s\n> </pre>'
shown "a fence inside an ordered item, after it has closed" '1. step\n   ```\n   code\n   ```\n\n%s'
shown "a fence on a list item line, after it has closed" '- ```\n  code\n  ```\n\n%s'
shown "a fence left open in a list item, after the item has ended" '- ```\n  code\n\n%s'
shown "a quoted fence left open, after the quote has ended" '> ```\n> code\n\n%s'
hidden "a fence opened at the margin after a list item left its own open" '- ```\n  code\n```\n\n%s\n```'
hidden "a fence opened at the margin after an indented one in a list item" '- item\n  ```\n  code\n```\n\n%s\n```'
hidden "a fence opened at the margin after a quoted one left open" '> ```\n> code\n```\n\n%s\n```'
hidden "a deeper fence line inside a one-space fence, which is its content" ' ```\n    ```\n\n%s\n ```'
hidden "a fence opened after an outdented line ended an indented one in a list item" '- item\n  ```\noutdented\n  ```\n\n%s\n  ```'
# A tag-opened block is placed by the same rules, because its lines are raw HTML and can open a
# comment, while the same lines outside it are ordinary text and cannot.
shown "a quoted <div>, then an unquoted text line holding an opener" '> <div>\ntext <!--\n\n%s'
shown "<div> on a list item line, then a text line at the margin holding an opener" '- <div>\ntext <!--\n\n%s'
hidden "<div> on a list item line, then a text line inside the item holding an opener" '- <div>\n  text <!--\n\n%s'
shown "an indented <details> whose lines are indented alike" '  <details>\n  <summary>x</summary>\n\n%s'
hidden "an indented <div>, then a text line at the margin holding an opener" '  <div>\ntext <!--\n\n%s'
hidden "<div> in a list item, then a fence at the margin around the line" '- item\n  <div>\n```\n\n%s\n```'
hidden "a line at the margin that closes a comment and a <pre> left open in a list item" \
  '<div> <!--\n\n- item\n  <pre>\noutdented --> </pre>\n\n%s'
# Ordinary structure around the line changes nothing.
shown "two blank lines above it" 'text\n\n\n%s'
shown "a list item above it, the line at the margin" '- item\n\n%s'
shown "three spaces of indentation" 'text\n\n   %s'
shown "a table above it" '| a | b |\n|---|---|\n| 1 | 2 |\n\n%s'
shown "a link reference definition above it" '[x]: https://example.com\n\n%s'
# Some shapes the page DOES show are still not counted. A fence or an HTML block opened on an
# indented line may sit inside a list item or at the top level, and a line scanner cannot tell
# which. A fence line at the margin is then read as opening a fence even where it was closing one,
# and any other less indented line stops the read. A line that is one inline tag is read as opening
# a block even where it only continues a paragraph. Refusing a real record costs a repair; counting
# an example would hide the work.
refused() { measured 0 "UNDELIVERED 2026-10-20" "the page shows it, but it cannot be placed, so it does not count: $1" "$2"; }
refused "an indented fence closed at the margin" '  ```\n  code\n```\n\n%s'
refused "an indented comment block with lines at the margin" '  <!--\nnote\n-->\n\n%s'
refused "<div> in a list item, then a text line at the margin holding an opener" '- item\n  <div>\ntext <!--\n\n%s'
refused "a paragraph continued by a lone inline tag and a line holding an opener" 'text\n<span>\nmore <!--\n\n%s'
}
# A NUL byte inside a date must not be deleted: that would join the pieces into a date nobody wrote.
expect "a NUL byte inside a delivery date leaves it malformed" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n**Delivered on:** 2026-0\x019-20' 2026-09-25 "${none}" | sed 's/\\u0001/\\u0000/')"
expect "a NUL byte inside a measurement date leaves it malformed" 2 "UNKNOWN malformed" \
  "$(solo $'**Measure on:** 2026-1\x010-20' 2026-09-25 "${open1}" | sed 's/\\u0001/\\u0000/')"
# A NUL byte ends a line for BSD awk, which hid whatever followed it on that line.
expect "a comment opened after a NUL byte still hides the delivery line" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n<div>\x01<!--\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}" | sed 's/\\u0001/\\u0000/')"
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
mutant no-paragraph-rule 's/^      starts = fresh$/      starts = 1/'
expect_mutant "without the paragraph rule a delivery line that continues a quote counts" no-paragraph-rule \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n> someone wrote\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect_mutant "without the paragraph rule a delivery line inside a tag-opened HTML block counts" no-paragraph-rule \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n> someone wrote\n<div>\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
mutant no-html-block-state 's/^        block_kind = kind$/        block_kind = 0/'
expect_mutant "without the HTML block state a delivery line inside <pre> counts" no-html-block-state \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n<pre>\n\n**Delivered on:** 2026-09-20\n\n</pre>' 2026-09-25 "${none}")"
# shellcheck disable=SC2016 # the expression matches the helper's own text; nothing here expands
mutant raw-lines-open-no-comment 's/^      comments(\$0)$//'
expect_mutant "without following comments on raw HTML lines one opened inside <pre> hides nothing" raw-lines-open-no-comment \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n<pre>\n<!--\n</pre>\n\n**Delivered on:** 2026-09-20\n\n-->' 2026-09-25 "${none}")"
# shellcheck disable=SC2016 # the expression matches the helper's own text; nothing here expands
mutant live-comment-ignored 's/^      if (!live && \$0 ~ marker) {$/      if (\$0 ~ marker) {/'
expect_mutant "without the open-comment test a line the page hides counts" live-comment-ignored \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n<div> <!--\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
# shellcheck disable=SC2016 # the expression matches the helper's own text; nothing here expands
mutant item-fence-never-ends 's/^    if (!blank && fence_item > 0 && indent(\$0) < fence_item) {$/    if (0) {/'
expect_mutant "without the list item rule a fence at the margin closes the one the item left open" item-fence-never-ends \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n- ```\n  code\n```\n\n**Delivered on:** 2026-09-20\n```' 2026-09-25 "${none}")"
# shellcheck disable=SC2016 # the expression matches the helper's own text; nothing here expands
mutant indented-fence-trusted 's/^    } else if (!blank && fence_maybe > 0 && indent(\$0) < fence_maybe) {$/    } else if (0) {/'
expect_mutant "without the indented fence rule a fence at the margin closes one that sat in a list item" indented-fence-trusted \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n- item\n  ```\n  code\n```\n\n**Delivered on:** 2026-09-20\n```' 2026-09-25 "${none}")"
# shellcheck disable=SC2016 # the expression matches the helper's own text; nothing here expands
mutant indented-block-trusted 's/^    if (pad > 0 && indent(\$0) < pad) return 2$/    if (0) return 2/'
expect_mutant "without the indented block rule a fence at the margin is read as raw HTML of a <div> in a list item" indented-block-trusted \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n- item\n  <div>\n```\n\n**Delivered on:** 2026-09-20\n```' 2026-09-25 "${none}")"
# shellcheck disable=SC2016 # the expression matches the helper's own text; nothing here expands
mutant any-date-line-chains 's/^      fresh = (starts && \$0 ~ whole)$/      fresh = starts/'
expect_mutant "without the whole-line test a date line under one that carries other text counts" any-date-line-chains \
  "DUE 2026-10-20" "$(solo $'**Delivered on:** see `the\n**Measure on:** 2026-10-20\nnotes`' 2026-12-01 "${none}")"
mutant nul-deleted "s/tr '.000' '.001'/tr -d '\\\\000'/"
expect_mutant "deleting a NUL byte joins a broken delivery date into a valid one" nul-deleted \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n**Delivered on:** 2026-0\x019-20' 2026-09-25 "${none}" | sed 's/\\u0001/\\u0000/')"
mutant null-summary-is-zero 's/if .sub_issues == null then "unknown"/if .sub_issues == null then "no"/'
expect_mutant "reading a missing summary as zero calls the Kata undelivered" null-summary-is-zero \
  "UNDELIVERED 2026-10-20" "$(solo "${own}" 2026-09-25 null)"
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
  'Write each of the two lines at the start of a paragraph: after a blank line, or directly under the other one.'
  'Anywhere else it cannot be told from quoted or example text, and is reported for repair instead of read.'
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
projected "the overlay's projection of a Kata with no sub-issue is UNDELIVERED" 0 "UNDELIVERED 2999-12-31" \
  "${far},\"sub_issues_summary\":${none}}"
projected "the overlay's projection of a Kata with an open sub-issue is NOT-DUE" 1 "NOT-DUE 2999-12-31" \
  "${far},\"sub_issues_summary\":${open1}}"
projected "the overlay's projection of a Kata whose sub-issues have all closed is UNDELIVERED" 0 "UNDELIVERED 2999-12-31" \
  "${far},\"sub_issues_summary\":${closed1}}"
projected "the overlay's projection of an issue with no summary gives no verdict" 2 "" \
  "${far}}"
projected "the overlay's projection of an arrived Kata needs no summary" 0 "DUE 2000-01-01" \
  '{"body":"**Measure on:** 2000-01-01"}'
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
