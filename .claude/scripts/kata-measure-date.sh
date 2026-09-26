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
# USAGE
#   gh api repos/devantler-tech/<repo>/issues/<n> --jq '{body:(.body // "")}' | kata-measure-date.sh --input -
#
#   --input -  REQUIRED: stdin is ONE JSON object with the string key `body` and, optionally,
#              `today` (YYYY-MM-DD; default the current UTC date). This is the only shape the
#              surveyor's read-only guard admits for a declared helper.
#
# OUTPUT (one line on stdout)
#   DUE <date>                 the named date is today or earlier: measuring is actionable now
#   NOT-DUE <date>             the named date is still in the future: skip reason (d) applies
#   UNKNOWN missing            no `**Measure on:**` line (a quoted `> ` line does not count)
#   UNKNOWN malformed          a line whose value is empty or not one real calendar date as YYYY-MM-DD
#   UNKNOWN conflicting <a,b>  two different dates; the helper never picks one
#
# EXIT CODES
#   0  DUE
#   1  NOT-DUE
#   2  UNKNOWN, a usage error, or unreadable input. The caller reports the Kata for its line to
#      be repaired; UNKNOWN is never read as due and never as not-due.
set -euo pipefail

usage() {
  sed -n '15,34p' "$0" >&2
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
    and (keys - ["body", "today"] | length == 0)
    and (.body | type == "string")
    and ((has("today") | not) or (.today | type == "string" and test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"))))' \
  <<<"${payload}" >/dev/null 2>&1 || {
  echo "kata-measure-date: stdin must be one JSON object with a string body and an optional YYYY-MM-DD today" >&2
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

# Every value on a `**Measure on:**` line, CRLF endings removed. Only rendered text counts: a line
# quoted with `>`, indented four spaces or a tab (a code block), inside a ``` or ~~~ fence, or inside
# an HTML comment is an example or an instruction, never this Kata's date. The patterns spell out
# "up to three spaces" as ` ? ? ?` because the awk on CI's runners has no {n,m} intervals.
values="$(jq -r '.body' <<<"${payload}" | awk '
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
  { sub(/\r$/, "") }
  in_comment {
    p = index($0, "-->")
    if (p > 0) in_comment = unclosed_comment(substr($0, p + 3))
    next
  }
  fence_len > 0 {
    t = unindent_fence($0, fence_indent)
    n = run(t, fence_char)
    if (n >= fence_len && substr(t, n + 1) ~ /^[ \t]*$/) { fence_len = 0; fence_indent = 0 }
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
      fence_char = c; fence_len = n; fence_indent = pfx + extra; next
    }
  }
  unclosed_comment($0) { in_comment = 1; next }
  /^ ? ? ?\*\*Measure on:\*\*/ {
    v = $0
    sub(/^ ? ? ?\*\*Measure on:\*\*[ \t]*/, "", v)
    sub(/[ \t]+$/, "", v)
    # An empty value becomes a placeholder: command substitution would strip a trailing empty line,
    # and validation must still see it.
    print (v == "" ? "(empty)" : v)
  }')"

if [ -z "${values}" ]; then
  echo "UNKNOWN missing"
  exit 2
fi
while IFS= read -r value; do
  is_calendar_date "${value}" || {
    echo "UNKNOWN malformed"
    exit 2
  }
done <<<"${values}"

dates="$(sort -u <<<"${values}")"
if [ "$(grep -c . <<<"${dates}")" -ne 1 ]; then
  echo "UNKNOWN conflicting $(paste -sd, - <<<"${dates}")"
  exit 2
fi

if [[ "${dates}" > "${today}" ]]; then
  echo "NOT-DUE ${dates}"
  exit 1
fi
echo "DUE ${dates}"
