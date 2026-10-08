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

# A quoted line and a line indented as code are not date lines at all.
fence='```'
expect "an indented code block is not the line" 2 "UNKNOWN missing" \
  "$(kata $'Example:\n\n    **Measure on:** 2026-10-20' 2026-09-25)"
expect "a tab-indented line is code, not the line" 2 "UNKNOWN missing" "$(kata $'\t**Measure on:** 2026-10-20' 2026-09-25)"

# ── Nothing below a code fence or HTML is read ───────────────────────────────────────────────────
# A fence and an HTML block are the two things that can hold a line across a blank line, and
# whether a line below one is on the page depends on details a line scanner cannot settle. So the
# rule does not ask: a date line below the first of either is reported, never counted and never
# dropped. What stands above it is read as usual.
expect "a fence below the line changes nothing" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'**Measure on:** 2026-10-20\n\n'"${fence}"$'\ncode\n'"${fence}" 2026-09-25)"
expect "HTML below the line changes nothing" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'**Measure on:** 2026-10-20\n\n<details>\n<summary>more</summary>\n\ntext\n</details>' 2026-09-25)"
below() { # below <label> <the lines above the date line, which stands after a blank line>
  expect "a measurement line below $1 is reported, not read" 2 "UNKNOWN malformed" \
    "$(kata "$2"$'\n\n**Measure on:** 2026-10-20' 2026-09-25)"
}
below "a closed fence" "${fence}"$'\nexample\n'"${fence}"
below "a closed tilde fence" $'~~~\nexample\n~~~'
below "a fence with an info string" "${fence}md"$'\nexample\n'"${fence}"
below "a fence on a list item line" "- ${fence}"$'\n  example\n  '"${fence}"
below "a fence inside an ordered item" $'1. step\n   '"${fence}"$'\n   example\n   '"${fence}"
below "a quoted fence" "> ${fence}"$'\n> example\n> '"${fence}"
below "a fence indented four spaces, which may sit in a list item" $'    '"${fence}"
below "a line of inline code that starts like a fence" "${fence} aa ${fence}"
below "a multi-line HTML comment" $'<!-- template:\nnote\n-->'
below "a comment with more text on its line" '<!-- note --> and more'
below "two comments on one line" '<!-- a --> <!-- b -->'
below "a quoted comment" '> <!-- note -->'
below "a block-level tag" '<div>'
below "a closing tag" '</div>'
below "a <details> block" $'<details>\n<summary>more</summary>\n\ntext\n</details>'
below "a one-line <pre> block" '<pre>example</pre>'
below "an indented <pre>, which may sit in a list item" $'Example:\n\n    <pre>'
below "a tag on a list item line" '- <br>'
below "a paragraph that starts with an inline tag" '<b>Note:</b> see below.'
below "a paragraph that starts with an autolink" '<https://example.com> has more.'
# One line that is a whole HTML comment opens nothing, and marker comments are common in bodies.
expect "a one-line HTML comment changes nothing after it" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'<!-- note -->\n\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "an indented one-line HTML comment changes nothing after it" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'- item\n  <!-- note -->\n\n**Measure on:** 2026-10-20' 2026-09-25)"
# HTML does not have to start the line. A tag left open in the middle of a line can strip the
# formatting from everything after it (measured with <select>), and telling a tag from one inside
# a code span would mean parsing inline Markdown. So anything in angle brackets that could be HTML
# counts, wherever it stands; the remedy is to put the date lines above it.
below "a tag in the middle of a line" 'Press <kbd>Enter</kbd> and wait.'
below "a tag left open in the middle of a line" 'Choose <select> here.'
below "a closing tag in the middle of a line" 'text </div> more'
below "a comment opener left open in a paragraph" 'text <!-- x'
# shellcheck disable=SC2016 # backticks are literal Markdown in the case, not a substitution
below "a code span holding a comment opener" 'The token `<!--` starts a comment.'
# shellcheck disable=SC2016 # backticks are literal Markdown in the case, not a substitution
below "a placeholder in inline code" 'Run `gh pr view <n>` first.'
below "an autolink in the middle of a line" 'See <https://example.com> for more.'
below "a comparison written without a space, which reads as a tag" 'Stop when latency <target.'
# A < that cannot start HTML, and a fence run that does not start the line, open nothing.
expect "a spaced comparison changes nothing after it" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'Target: p95 < 2 s, 1 <2, a <= b and x <- y.\n\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "an escaped tag changes nothing after it" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'Write &lt;pre&gt; for the tag.\n\n**Measure on:** 2026-10-20' 2026-09-25)"
expect "inline code holding a fence run changes nothing after it" 1 "NOT-DUE 2026-10-20" \
  "$(kata "Use ${fence} to open a fence."$'\n\n**Measure on:** 2026-10-20' 2026-09-25)"
# A date line that itself carries HTML is reported like one below it.
expect "a date line with a comment after the date is reported" 2 "UNKNOWN malformed" \
  "$(kata $'**Measure on:** 2026-10-20 <!-- moved -->' 2026-09-25)"
# An example of the line inside the fence is a date line below a fence like any other, so it is
# reported even beside the real line above it. Examples belong inline, quoted or indented.
expect "a fenced example of the line is reported" 2 "UNKNOWN malformed" \
  "$(kata "Write it like this:"$'\n'"${fence}"$'\n**Measure on:** 2026-10-20\n'"${fence}" 2026-09-25)"
expect "a fenced example below the real line is reported too" 2 "UNKNOWN malformed" \
  "$(kata $'**Measure on:** 2026-10-20\n\n'"${fence}"$'\n**Measure on:** YYYY-MM-DD\n'"${fence}" 2026-09-25)"
expect "an example inside a multi-line comment is reported" 2 "UNKNOWN malformed" \
  "$(kata $'<!--\n**Measure on:** YYYY-MM-DD\n-->' 2026-09-25)"
expect "an inline example below the real line is not a date line" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'**Measure on:** 2026-10-20\n\nMove it by editing the `**Measure on:** YYYY-MM-DD` line.' 2026-09-25)"
expect "a quoted example below the real line is not a date line" 1 "NOT-DUE 2026-10-20" \
  "$(kata $'**Measure on:** 2026-10-20\n\n> **Measure on:** YYYY-MM-DD' 2026-09-25)"

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
# A delivery line is placed exactly as the measurement line is.
expect "a quoted delivery line is someone else's text" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n> **Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a delivery line indented as code is not a date line" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\n    **Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a fenced delivery line is reported, not read" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n'"${fence}"$'\n**Delivered on:** 2026-09-20\n'"${fence}" 2026-09-25 "${none}")"
expect "a delivery line inside an HTML comment is reported, not read" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n<!--\n**Delivered on:** 2026-09-20\n-->' 2026-09-25 "${none}")"
expect "a delivery line below a closed fence is reported, not read" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n'"${fence}"$'\nexample\n'"${fence}"$'\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
expect "a fence below both lines changes nothing" 1 "NOT-DUE 2026-10-20" \
  "$(solo "${delivered}"$'\n'"${fence}"$'\ncode\n'"${fence}" 2026-09-25 "${none}")"
# The measurement date is read first, so a body whose only fault is below it still names its date.
expect "an arrived date is DUE even with a delivery line below a fence" 0 "DUE 2026-10-20" \
  "$(solo "${own}"$'\n'"${fence}"$'\nexample\n'"${fence}"$'\n\n**Delivered on:** 2026-09-20' 2026-10-21 "${none}")"
expect "prose naming a delivery is not the line" 0 "UNDELIVERED 2026-10-20" \
  "$(solo "${own}"$'\nDelivered on 2026-09-20 through the pilot.' 2026-09-25 "${none}")"
expect "a delivery line does not stand in for the measurement date" 2 "UNKNOWN missing" \
  "$(solo $'**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
# ── Where a line counts: only at the start of a paragraph ────────────────────────────────────────
# The rule is a whitelist. A date line is read on the body's first line, after a blank line, or
# directly under the other date line. Anywhere else it is neither counted nor dropped: the verdict
# is UNKNOWN, so a line that only looks like a record can never hide the work. Listing the places
# a line does NOT count was tried first, and each review round found one more.
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
under "a line with an inline tag" 'See <span>note</span>.'
under "a one-line HTML comment" '<!-- note -->'
under "a setext underline" '==='
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
after_blank "a thematic break" '---'
after_blank "a list item" '- done'
after_blank "a one-line HTML comment" '<!-- note -->'
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

# ── Measured against the forge's own renderer ────────────────────────────────────────────────────
# Each body below was sent to the forge's Markdown endpoint on 2026-10-07 (POST /markdown with
# the body as `text`, `mode` gfm and this repository as `context`) and the result read for the
# delivery line: was it there as a rendered bold label, that is as `<strong>Delivered on:</strong>`
# in the HTML? The property that matters is one-way. A line the page does not show as the record
# must never count as one, and over all 261 bodies measured none did (the cases here are a
# selection). The reverse is allowed and common: a line the page does show is reported for moving
# when it stands below a fence or HTML, because a line scanner cannot tell those bodies from the
# ones where the page hides it. The format's %s is the delivery line.
measured() { # measured <want-exit> <want-stdout> <label> <printf format of the text under the measure line>
  local text
  # shellcheck disable=SC2059 # the format is the case itself
  text="$(printf -- "$4" '**Delivered on:** 2026-09-20')"
  expect "$3" "$1" "$2" "$(solo "${own}"$'\n'"${text}" 2026-09-25 "${none}")"
}
counts() { measured 1 "NOT-DUE 2026-10-20" "the page shows it and it counts: $1" "$2"; }
hidden() { measured 2 "UNKNOWN malformed-delivery" "the page does not show it, and it is reported: $1" "$2"; }
moved() { measured 2 "UNKNOWN malformed-delivery" "the page shows it, but it is reported for moving: $1" "$2"; }
# shellcheck disable=SC2016 # backticks are literal Markdown in the cases, not substitutions
{
# The page does not show the line: as raw text or code, or not at all once a comment has opened.
hidden "inside <pre> after a blank line" '<pre>\n\n%s\n\n</pre>'
hidden "inside an upper-case <PRE> with an attribute" '<PRE class="x">\n\n%s\n\n</PRE>'
hidden "inside <script> after a blank line" '<script>\n\n%s\n\n</script>'
hidden "inside <style> after a blank line" '<style>\n\n%s\n\n</style>'
hidden "inside <textarea> after a blank line" '<textarea>\n\n%s\n\n</textarea>'
hidden "inside a declaration" '<!DOCTYPE note\n\n%s\n\n>'
hidden "inside a processing instruction" '<?note\n\n%s\n\n?>'
hidden "inside a CDATA section" '<![CDATA[\n\n%s\n\n]]>'
hidden "inside <pre> opened on a list item line" '- <pre>\n\n  %s\n  </pre>'
hidden "under a tag that interrupts a quote" '> someone wrote\n<div>\n%s'
hidden "inside a multi-line comment with blank lines" '<!--\n\n%s\n\n-->'
hidden "inside a comment that interrupts a paragraph" 'text\n<!--\n\n%s\n\n-->'
hidden "inside a comment opened on a list item line" '- <!--\n\n  %s\n  -->'
hidden "after a comment opened on a block-level tag line" '<div> <!--\n\n%s\n\n-->'
hidden "after a comment opened on a closing tag line" '</div> <!--\n\n%s'
hidden "after <div> and a comment opener on a list item line" '- <div> <!--\n\n%s'
hidden "after a comment opened on a text line inside a tag-opened block" '<div>\ntext <!--\n\n%s\n\n-->'
hidden "after a comment opened inside <pre>, with a closer further down" '<pre>\n<!--\n</pre>\n\n%s\n\n-->'
hidden "after a comment opened inside <pre> and never closed" '<pre>\n<!--\n</pre>\n\n%s'
hidden "after a comment opened inside <script>" '<script>\n<!--\n</script>\n\n%s'
hidden "after a comment opened inside <textarea>" '<textarea>\n<!--\n</textarea>\n\n%s'
hidden "after a second comment left open on the line that closed the first" '<!-- a --> <!-- b\n\n%s'
hidden "after a comment reopened on its closing line" '<!-- first\n--> <!-- second\n\n%s\n\n-->'
hidden "after a comment that only --!> tries to close" '<!--\na --!>\n\n%s'
hidden "after a raw comment and a closer in a paragraph, which is escaped" '<div> <!--\n\nx\n\n-->\n\n%s'
hidden "after a raw comment and a closer inside a fence" '<div> <!--\n\n```\n-->\n```\n\n%s'
hidden "after a raw comment and a closer in indented code" '<div> <!--\n\n    -->\n\n%s'
hidden "after a raw comment and a closer in a code span" '<div> <!--\n\nsee `-->` here\n\n%s'
hidden "after a raw comment and a closer on a heading" '<div> <!--\n\n## T -->\n\n%s'
hidden "after a raw comment and a closer under a line of inline tags" '<div> <!--\n\n<span>x</span>\n-->\n\n%s'
hidden "after a comment opened under a self-closing tag line" '<br/>\ntext <!--\n\n%s'
hidden "after a comment opened under a closing tag line" '</span>\ntext <!--\n\n%s'
hidden "after a comment opened under a custom element line" '<my-box>\ntext <!--\n\n%s'
hidden "after a comment opened under a tag with a bare attribute" '<input disabled>\ntext <!--\n\n%s'
hidden "after a comment opened under a tag whose quoted value holds >" '<a title="a>b">\ntext <!--\n\n%s'
hidden "after a comment opened under <div split over two lines" '<div\nclass="x"> <!--\n\n%s'
hidden "after a comment opened inside an indented <div>" '  <div>\ntext <!--\n\n%s'
hidden "after a comment opened inside <div> on a list item line" '- <div>\n  text <!--\n\n%s'
hidden "after a comment and a <pre> in a list item, both closed at the margin" \
  '<div> <!--\n\n- item\n  <pre>\noutdented --> </pre>\n\n%s'
hidden "inside a fence opened at the margin after a list item left its own open" '- ```\n  code\n```\n\n%s\n```'
hidden "inside a fence opened at the margin after an indented one in a list item" '- item\n  ```\n  code\n```\n\n%s\n```'
hidden "inside a fence opened at the margin after a quoted one left open" '> ```\n> code\n```\n\n%s\n```'
hidden "inside a one-space fence that holds a deeper fence line" ' ```\n    ```\n\n%s\n ```'
hidden "inside a fence opened after an outdented line ended one in a list item" '- item\n  ```\noutdented\n  ```\n\n%s\n  ```'
hidden "inside a fence at the margin under <div> in a list item" '- item\n  <div>\n```\n\n%s\n```'
hidden "below <select> left open in the middle of a line, which strips its formatting" 'text <select>\n\n%s'
hidden "below a comment line that > ends early, with a tag left after it" '<!--> <select> -->\n\n%s'
hidden "below a comment line that --!> ends early, with a tag left after it" '<!-- a --!> <select> -->\n\n%s'
hidden "below a comment line that -> ends early, with a tag left after it" '<!---> <select> -->\n\n%s'
# Two shapes the page does not show are not date lines to begin with, so nothing is reported.
measured 0 "UNDELIVERED 2026-10-20" "the page does not show it, and it is no date line: a quoted line inside a quoted <pre>" \
  '> <pre>\n>\n> %s\n> </pre>'
measured 0 "UNDELIVERED 2026-10-20" "the page does not show it, and it is no date line: four spaces of indentation, which is code" \
  'text\n\n    %s'
# The page shows the line and nothing above it could be a fence or HTML, so it counts.
counts "a line that is one whole comment above it" '<!-- note -->\n\n%s'
counts "an indented whole comment above it, inside a list item" '- item\n  <!-- note -->\n\n%s'
counts "a whole comment holding a double hyphen above it" '<!-- a -- b -->\n\n%s'
counts "two whole comment lines above it" '<!-- a -->\n<!-- b -->\n\n%s'
counts "a comment made of dashes above it" '<!----->\n\n%s'
counts "a table above it" '| a | b |\n|---|---|\n| 1 | 2 |\n\n%s'
counts "a link reference definition above it" '[x]: https://example.com\n\n%s'
counts "a footnote definition above it" 'See[^1].\n\n[^1]: note\n\n%s'
counts "a math block around it, which a blank line ends" '$$\n\n%s\n\n$$'
counts "two blank lines above it" 'text\n\n\n%s'
counts "a list item above it, the line at the margin" '- item\n\n%s'
counts "a list item above it, the line inside the item" '- item\n\n  %s'
counts "three spaces of indentation" 'text\n\n   %s'
counts "a setext underline below it" '%s\n==='
# The page shows the line too, but a fence or HTML stands above it, so it is reported for moving.
moved "below a code span holding a comment opener" 'The token `<!--` starts a comment.\n\n%s'
moved "below a comment opener left open in a paragraph" 'text <!-- x\n\n%s\n\n-->'
moved "below a whole comment inside one paragraph, over two lines" 'text <!-- a\nb --> more\n\n%s'
moved "below an opener at the end of a heading" '## Title <!--\n\n%s'
moved "below an opener in a table cell" '| a |\n|---|\n| <!-- |\n\n%s'
moved "below <pre> in the middle of a line" 'text <pre>\n\n%s'
moved "below a closed multi-line comment" '<!--\nnote\n-->\n\n%s'
moved "below a closed fence inside an ordered item" '1. step\n   ```\n   code\n   ```\n\n%s'
moved "below <details> with its summary and a text line" '<details>\n<summary>x</summary>\nsome text\n\n%s'
moved "inside <details>, after a blank line" '<details>\n<summary>x</summary>\n\n%s\n\n</details>'
moved "below a four-space-indented <pre>, which is code" 'Example:\n\n    <pre>\n\n%s'
moved "below a paragraph that starts with an autolink" '<https://example.com> <!--\n\n%s'
moved "below a comment opened and closed inside <pre>" '<pre>\n<!--\n-->\n</pre>\n\n%s'
}

# A NUL byte inside a date must not be deleted: that would join the pieces into a date nobody wrote.
expect "a NUL byte inside a delivery date leaves it malformed" 2 "UNKNOWN malformed-delivery" \
  "$(solo "${own}"$'\n**Delivered on:** 2026-0\x019-20' 2026-09-25 "${none}" | sed 's/\\u0001/\\u0000/')"
expect "a NUL byte inside a measurement date leaves it malformed" 2 "UNKNOWN malformed" \
  "$(solo $'**Measure on:** 2026-1\x010-20' 2026-09-25 "${open1}" | sed 's/\\u0001/\\u0000/')"
# A NUL byte ends a line for BSD awk, which hid whatever followed it on that line.
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
mutant no-paragraph-rule 's/^    starts = fresh$/    starts = 1/'
expect_mutant "without the paragraph rule a delivery line that continues a quote counts" no-paragraph-rule \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n> someone wrote\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
# shellcheck disable=SC2016 # the expression matches the helper's own text; nothing here expands
mutant below-is-read 's/^  !below && (\$0 ~ fence || \$0 ~ angle) && !whole_comment(\$0) { below = 1 }$//'
expect_mutant "without the rule a delivery line inside <pre> counts" below-is-read \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n<pre>\n\n**Delivered on:** 2026-09-20\n\n</pre>' 2026-09-25 "${none}")"
expect_mutant "without the rule a delivery line inside a fence counts" below-is-read \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n'"${fence}"$'\n\n**Delivered on:** 2026-09-20\n\n'"${fence}" 2026-09-25 "${none}")"
expect_mutant "without the rule a delivery line the page hides behind an open comment counts" below-is-read \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n<div> <!--\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
mutant any-comment-line-is-whole 's/^    return (p > 0 && substr(s, p + 3) ~ .*$/    return (p > 0)/'
expect_mutant "without the whole-line test a second comment left open on the line hides nothing" any-comment-line-is-whole \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n<!-- a --> <!-- b\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
mutant comment-text-unchecked 's/ && substr(s, 1, p - 1) !~ \/\[<>\]\/)$/)/'
expect_mutant "without the text test a comment line that ends early hides the tag left after it" comment-text-unchecked \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n<!--> <select> -->\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
mutant html-only-at-line-start 's/^    angle = .*$/    angle = "^[ \\t]*<[A-Za-z\/!?]"/'
expect_mutant "reading HTML only at a line start counts a line whose formatting an open <select> strips" html-only-at-line-start \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\ntext <select>\n\n**Delivered on:** 2026-09-20' 2026-09-25 "${none}")"
mutant markers-not-skipped 's/^    fence = .*$/    fence = "^(```|~~~)"/'
expect_mutant "without skipping markers a fence on a list item line is missed" markers-not-skipped \
  "NOT-DUE 2026-10-20" "$(solo "${own}"$'\n- '"${fence}"$'\n\n  **Delivered on:** 2026-09-20\n  '"${fence}" 2026-09-25 "${none}")"
# shellcheck disable=SC2016 # the expression matches the helper's own text; nothing here expands
mutant any-date-line-chains 's/^    fresh = (starts && \$0 ~ whole)$/    fresh = starts/'
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
  'Write the two lines near the top of the body: each at the start of a paragraph (after a blank line, or directly under the other one), and above any code fence and anything in angle brackets, a `<placeholder>` in inline code included.'
  'Anywhere else a line cannot be told from quoted or example text, and is reported for repair instead of read.'
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
