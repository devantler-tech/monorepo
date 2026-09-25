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
#   UNKNOWN malformed          a line whose value is not exactly one YYYY-MM-DD date
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

today="$(jq -r '.today // empty' <<<"${payload}")"
[ -n "${today}" ] || today="$(date -u +%Y-%m-%d)"

# Every value on a `**Measure on:**` line, CRLF endings removed. A line quoted with `>` is not one.
values="$(jq -r '.body' <<<"${payload}" | awk '
  { sub(/\r$/, "") }
  /^[ \t]*\*\*Measure on:\*\*/ {
    v = $0
    sub(/^[ \t]*\*\*Measure on:\*\*[ \t]*/, "", v)
    sub(/[ \t]+$/, "", v)
    print v
  }')"

if [ -z "${values}" ]; then
  echo "UNKNOWN missing"
  exit 2
fi
date_re='^[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
while IFS= read -r value; do
  [[ "${value}" =~ ${date_re} ]] || {
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
