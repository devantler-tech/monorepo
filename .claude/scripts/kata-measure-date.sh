#!/usr/bin/env bash
# kata-measure-date.sh — decide whether ONE Kata issue has reached its named measurement date
# (monorepo#2838).
#
# WHY THIS EXISTS
#   A Kata is not actionable until its named measurement date (contract skip reason (d)). The
#   survey used to read that date by eye, and on 2026-08-14 it reported both open Katas as past
#   due from each issue's createdAt; one was two days from its real date. Kata bodies had named
#   their date in free prose ("measure by", "First measurement date:", "Follow-up date:"), so no
#   reader could find it reliably. The contract now gives the date one structured line in the
#   issue body, updated in place when the date moves:
#       **Measure on:** YYYY-MM-DD
#   This helper reads that line and nothing else — never createdAt, never a date in prose.
#
#   DELIVERY COMES FIRST (monorepo#3619). Skip reason (d) covers a DELIVERED experiment waiting
#   for its date. A future date alone used to exclude a Kata, so one that carries its own
#   undelivered actions was hidden until its date arrived with nothing to measure. A future date
#   is therefore NOT-DUE only when the skip hides nothing, in one of two ways:
#     - the Kata has at least one OPEN sub-issue: its remaining delivery work lives there and
#       stays selectable; or
#     - its body carries the line the delivering run writes when the Kata's own actions are done:
#           **Delivered on:** YYYY-MM-DD
#       with a date, in UTC, that is today or earlier.
#   With neither, the verdict is UNDELIVERED: the Kata is delivery work, never a skip. That
#   includes a Kata whose sub-issues have all CLOSED. A closed child proves only that the child
#   closed, and the Kata can carry actions no child covered, so its delivery is then recorded by
#   the line.
#
# USAGE
#   gh api repos/devantler-tech/<repo>/issues/<n> --jq '{body:(.body // ""),sub_issues:.sub_issues_summary}' | kata-measure-date.sh --input -
#
#   --input -  REQUIRED: stdin is ONE JSON object with the string key `body` and, optionally,
#              `today` (YYYY-MM-DD; default the current UTC date) and `sub_issues` (the forge's
#              sub-issue summary for the Kata: an object whose `total` and `completed` are whole
#              numbers with completed <= total). A null or absent summary is not a count of
#              zero: when the verdict depends on it, the read is incomplete and the helper exits
#              2 with no verdict. This is the only shape the surveyor's read-only guard admits
#              for a declared helper.
#
# OUTPUT (one line on stdout)
#   DUE <date>                 the named date is today or earlier: measuring is actionable now
#   NOT-DUE <date>             the named date is still in the future, and an open sub-issue or a
#                              delivery line means the skip hides nothing: skip reason (d) applies
#   UNDELIVERED <date>         the named date is still in the future, with no open sub-issue and no
#                              delivery line: the Kata is delivery work, and (d) does NOT apply
#   UNKNOWN missing            no `**Measure on:**` line (a quoted `> ` line does not count)
#   UNKNOWN malformed          a line whose value is empty or not one real calendar date as
#                              YYYY-MM-DD, or a line that does not start a paragraph
#   UNKNOWN conflicting <a,b>  two different dates; the helper never picks one
#   UNKNOWN malformed-delivery / UNKNOWN conflicting-delivery <a,b>
#                              the same two faults on a `**Delivered on:**` line
#
# WHERE A LINE COUNTS
#   Each date line is read only at the start of a paragraph: on the body's first line, after a
#   blank line, or directly under the other date line. Anywhere else it is reported as malformed
#   rather than guessed at. A line that is quoted, indented as code, or inside a fence, an HTML
#   comment or a <pre>-like HTML block is an example and is not read at all.
#
# EXIT CODES
#   0  the Kata is actionable now: DUE (measure it) or UNDELIVERED (deliver it); stdout says which
#   1  NOT-DUE: skip reason (d) applies. A caller that skips on exit 1 therefore never skips an
#      undelivered Kata.
#   2  UNKNOWN, a usage error, or unreadable input, including a sub-issue summary the verdict needs
#      and the read did not carry. The caller reports an UNKNOWN verdict for its line to be
#      repaired, and a read with no verdict as failed; neither is ever read as due or as not-due.
set -euo pipefail

usage() {
  sed -n '/^# USAGE$/,/^set -euo pipefail$/p' "$0" | sed '$d' >&2
  exit 2
}

if [ "$#" -ne 2 ] || [ "$1" != "--input" ] || [ "$2" != "-" ]; then
  usage
fi
command -v jq >/dev/null 2>&1 || {
  echo "kata-measure-date: jq is required" >&2
  exit 2
}

payload="$(cat)" || exit 2
jq -se 'length == 1 and (.[0] | type == "object"
    and (keys - ["body", "today", "sub_issues"] | length == 0)
    and (.body | type == "string")
    and ((has("today") | not) or (.today | type == "string" and test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$")))
    and ((has("sub_issues") | not) or .sub_issues == null
         or (.sub_issues | type == "object"
             and ([.total, .completed] | all(type == "number" and . >= 0 and . <= 100000 and . == floor))
             and .completed <= .total)))' \
  <<<"${payload}" >/dev/null 2>&1 || {
  echo "kata-measure-date: stdin must be one JSON object with a string body, an optional YYYY-MM-DD today and an optional sub_issues summary whose total and completed are whole numbers" >&2
  exit 2
}

# is_calendar_date <value> — true only for a YYYY-MM-DD date that exists on the calendar, so a
# well-shaped impossible date such as 2026-02-30 is never compared as if it were one.
is_calendar_date() {
  [[ "$1" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]})) last
  case "$m" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) last=31 ;;
    4 | 6 | 9 | 11) last=30 ;;
    2) if { [ $((y % 4)) -eq 0 ] && [ $((y % 100)) -ne 0 ]; } || [ $((y % 400)) -eq 0 ]; then last=29; else last=28; fi ;;
    *) return 1 ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$last" ]
}

today="$(jq -r '.today // empty' <<<"${payload}")"
if [ -n "${today}" ] && ! is_calendar_date "${today}"; then
  echo "kata-measure-date: today is not a calendar date: ${today}" >&2
  exit 2
fi
[ -n "${today}" ] || today="$(date -u +%Y-%m-%d)"

# marked_values <label> — every value on a `**<label>:**` line of the body, CRLF endings removed.
#
# WHERE A LINE COUNTS is a whitelist, on purpose. A date line is read only at the START OF A
# PARAGRAPH: on the body's first line, after a blank line, or directly under the other date line.
# The rule used to be the reverse, a list of the places a line does NOT count (in a quote, after a
# quoted line, after a line that cannot end a quote ...), and three review rounds each found one
# more such place. Markdown has too many of them for a line scanner to enumerate. A blank line
# settles nearly all of them at once: it ends a paragraph, a quote's lazy continuation and an HTML
# block opened by a tag, so the line after it starts a block of its own.
#
# What a blank line does NOT end is tracked as a state, and a line inside one is an example or an
# instruction, never this Kata's date: a ``` or ~~~ fence, an HTML comment, and the other HTML
# blocks that run to an end marker (<pre>, <script>, <style>, <textarea>, <?, <!LETTER and
# <![CDATA[). A line quoted with `>` or indented four spaces or a tab (a code block) is not a date
# line at all.
#
# A date line anywhere else (under a line of text, a quoted line, a heading, a closed fence) is
# not guessed at. It prints a placeholder that is no date, so the verdict is UNKNOWN malformed and
# the line gets repaired; it is never silently counted and never silently dropped.
#
# The patterns spell out "up to three spaces" as ` ? ? ?`, and a date as digit by digit, because
# the awk on CI's runners has no {n,m} intervals.
# A NUL byte is replaced by another control character first. BSD awk ends a line at a NUL, which
# would hide the rest of that line (a comment opener, or trailing words that make a value
# malformed) from the scan. It is replaced, never deleted: deleting one inside `2026-0<NUL>9-20`
# would join the pieces into a date nobody wrote.
marked_values() {
  jq -r '.body' <<<"${payload}" | tr '\000' '\001' | awk -v label="$1" '
  BEGIN {
    marker = "^ ? ? ?\\*\\*" label ":\\*\\*"
    # Either date line, and one that is nothing but its label and a date-shaped value. Only the
    # second keeps the next line at a paragraph start: any other text could open an inline span
    # (a code span, a link) that runs on into the line below.
    dateline = "^ ? ? ?\\*\\*(Measure on|Delivered on):\\*\\*"
    whole = dateline "[ \t]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]*$"
    fresh = 1
  }
  # Fences follow CommonMark: an opening run of three or more backticks or tildes indented at most
  # three spaces (or opened within a list item), closed only by a run of the same character at
  # least as long, with nothing after it but whitespace.
  function unindent(s) { sub(/^ ? ? ?/, "", s); return s }
  function unindent_fence(s, extra,    k) {
    k = 3 + extra
    while (k > 0 && substr(s, 1, 1) == " ") {
      s = substr(s, 2)
      k--
    }
    return s
  }
  function run(s, c,    k) { k = 0; if (c == "") return 0; while (substr(s, k + 1, 1) == c) k++; return k }
  function unclosed_comment(rem,    p, q) {
    while ((p = index(rem, "<!--")) > 0) {
      rem = substr(rem, p + 4)
      q = index(rem, "-->")
      if (q == 0) return 1
      rem = substr(rem, q + 3)
    }
    return 0
  }
  # raw_html(line): the kind of HTML block this line opens that a blank line does not end, or 0.
  # CommonMark numbers them: 1 is <pre>, <script>, <style> or <textarea>; 3 is <?; 4 is <! and a
  # letter; 5 is <![CDATA[. (Kind 2 is the comment, which has its own rule.) Quote and list
  # markers before the tag are skipped, so a block opened inside a list item is seen too. A block
  # inside a quote really ends with the quote; here it runs to its end marker, which can only hide
  # a line, never count one. raw_rest is the line from the tag on.
  function raw_html(s,    t, l) {
    t = s
    while (t ~ /^[ \t]*(>|[-+*][ \t]|[0-9]+[.)][ \t])/) sub(/^[ \t]*(>|[-+*]|[0-9]+[.)])[ \t]*/, "", t)
    sub(/^[ \t]+/, "", t)
    raw_rest = t
    l = tolower(t)
    if (l ~ /^<(pre|script|style|textarea)([ \t>]|$)/) return 1
    if (t ~ /^<\?/) return 3
    if (t ~ /^<!\[CDATA\[/) return 5
    if (t ~ /^<![A-Za-z]/) return 4
    return 0
  }
  # raw_html_ends(line, kind): does this line carry the end marker of that kind of block?
  function raw_html_ends(s, kind,    l) {
    if (kind == 1) {
      l = tolower(s)
      return (index(l, "</pre>") > 0 || index(l, "</script>") > 0 || index(l, "</style>") > 0 || index(l, "</textarea>") > 0)
    }
    if (kind == 3) return index(s, "?>") > 0
    if (kind == 4) return index(s, ">") > 0
    return index(s, "]]>") > 0
  }
  { sub(/\r$/, "") }
  # An HTML comment and an HTML block that runs to an end marker each stay open until their own
  # end marker, whatever the lines between hold, and either can open inside the other. Both are
  # followed on every such line, and a line is hidden while either is open.
  in_comment || raw_kind > 0 {
    if (raw_kind > 0) {
      if (raw_html_ends($0, raw_kind)) raw_kind = 0
    } else {
      kind = raw_html($0)
      if (kind > 0 && !raw_html_ends(raw_rest, kind)) raw_kind = kind
    }
    if (in_comment) {
      p = index($0, "-->")
      if (p > 0) in_comment = unclosed_comment(substr($0, p + 3))
    } else if (unclosed_comment($0)) in_comment = 1
    fresh = 0
    next
  }
  fence_len > 0 {
    t = unindent_fence($0, fence_indent)
    n = run(t, fence_char)
    if (n >= fence_len && substr(t, n + 1) ~ /^[ \t]*$/) { fence_len = 0; fence_indent = 0 }
    fresh = 0
    next
  }
  {
    t = $0
    pfx = 0
    while (pfx < 3 && substr(t, 1, 1) == " ") {
      t = substr(t, 2)
      pfx++
    }
    extra = 0
    u = t
    if (u ~ /^([-+*]|[0-9]+[.)])[ \t]+/) {
      match(u, /^([-+*]|[0-9]+[.)])[ \t]+/)
      extra = RLENGTH
      u = substr(u, RLENGTH + 1)
    }
    c = substr(u, 1, 1)
    n = run(u, c)
    # A backtick fence info string cannot contain a backtick; such a line is inline code.
    if ((c == "`" || c == "~") && n >= 3 && !(c == "`" && index(substr(u, n + 1), "`") > 0)) {
      fence_char = c; fence_len = n; fence_indent = pfx + extra; fresh = 0; next
    }
  }
  {
    kind = raw_html($0)
    # A block whose first line also carries its end marker is that one line. The same line can
    # open a comment as well, and then both are open.
    if (kind > 0 && !raw_html_ends(raw_rest, kind)) raw_kind = kind
    if (unclosed_comment($0)) in_comment = 1
    if (kind > 0 || in_comment) { fresh = 0; next }
  }
  /^[ \t]*$/ { fresh = 1; next }
  $0 ~ dateline {
    starts = fresh
    fresh = (starts && $0 ~ whole)
    if ($0 ~ marker) {
      v = $0
      sub(marker "[ \t]*", "", v)
      sub(/[ \t]+$/, "", v)
      # A line that does not start a paragraph, and an empty value, each become a placeholder that
      # is no date. Validation must see both: neither may be dropped, and command substitution
      # would strip a trailing empty line.
      if (!starts) print "(misplaced)"
      else print (v == "" ? "(empty)" : v)
    }
    next
  }
  { fresh = 0 }'
}

# one_date <label> <unknown-suffix> — prints the single calendar date the body names on that line,
# or nothing when it has no such line. Exits 2 with an UNKNOWN verdict on a value that is not a
# calendar date or on two different dates: the helper never picks one.
one_date() {
  local values value dates
  # A body that could not be scanned is unreadable input, never "no such line".
  values="$(marked_values "$1")" || exit 2
  [ -n "${values}" ] || return 0
  while IFS= read -r value; do
    is_calendar_date "${value}" || {
      echo "UNKNOWN malformed$2"
      exit 2
    }
  done <<<"${values}"
  # Errexit is off in here (the caller tests this function's status), so a failed sort is checked
  # by hand: an empty list must never be reported as two conflicting dates.
  dates="$(sort -u <<<"${values}")" || exit 2
  [ -n "${dates}" ] || exit 2
  if [ "$(grep -c . <<<"${dates}")" -ne 1 ]; then
    echo "UNKNOWN conflicting$2 $(paste -sd, - <<<"${dates}")"
    exit 2
  fi
  printf '%s\n' "${dates}"
}

# A verdict printed inside the substitution is the helper's whole answer, so pass it through.
measure_on="$(one_date "Measure on" "")" || {
  [ -z "${measure_on}" ] || printf '%s\n' "${measure_on}"
  exit 2
}
if [ -z "${measure_on}" ]; then
  echo "UNKNOWN missing"
  exit 2
fi

if [[ ! "${measure_on}" > "${today}" ]]; then
  echo "DUE ${measure_on}"
  exit 0
fi

# The date is still ahead. That is skip reason (d) only when the skip hides nothing, so that is
# established before the Kata may be called not due (monorepo#3619).
delivered_on="$(one_date "Delivered on" "-delivery")" || {
  [ -z "${delivered_on}" ] || printf '%s\n' "${delivered_on}"
  exit 2
}
hides_nothing=no
# A delivery date still ahead records an intention, not a delivery.
if [ -n "${delivered_on}" ] && [[ ! "${delivered_on}" > "${today}" ]]; then
  hides_nothing=yes
fi
if [ "${hides_nothing}" = yes ]; then
  echo "NOT-DUE ${measure_on}"
  exit 1
fi
# No delivery line, so the verdict now rests on the sub-issues. An OPEN one carries the remaining
# delivery work and stays selectable; a closed one proves only that it closed. A summary the read
# did not carry is not a count of zero: calling the Kata undelivered on it could select a parent
# whose open child already holds the work, so the read is incomplete and gets no verdict.
# Subtracted inside jq: a count may print as `1.0`, which a shell integer test would reject.
open_child="$(jq -r 'if .sub_issues == null then "unknown"
  elif (.sub_issues.total - .sub_issues.completed) >= 1 then "yes" else "no" end' <<<"${payload}")"
case "${open_child}" in
  yes)
    echo "NOT-DUE ${measure_on}"
    exit 1
    ;;
  no)
    echo "UNDELIVERED ${measure_on}"
    exit 0
    ;;
  *)
    echo "kata-measure-date: the verdict needs the sub-issue summary, and stdin did not carry one" >&2
    exit 2
    ;;
esac
