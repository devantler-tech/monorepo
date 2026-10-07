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
# more such place. A blank line settles nearly all of them at once: it ends a paragraph, a quote's
# lazy continuation and an HTML block opened by a tag, so the line after it starts a block of its
# own. A date line anywhere else is not guessed at. It prints a placeholder that is no date, so
# the verdict is UNKNOWN malformed and the line gets repaired; it is never silently counted.
#
# WHAT A BLANK LINE DOES NOT END is followed in two layers, the way the page is produced. Each
# rule here was checked against the forge's own renderer (POST /markdown) on 2026-10-07; the
# property kept is that a line the page does not show as a rendered bold label is never counted.
#   Blocks, as CommonMark defines them. A line inside one is an example and is not read:
#     - a ``` or ~~~ fence. One opened on a list item line ends with the item. One opened on an
#       indented line may or may not sit inside a list item, so a less indented line inside it
#       cannot be placed: a fence line there is read as opening a fence, and after any other
#       line nothing more is read;
#     - an HTML block that runs to an end marker: <pre>, <script>, <style> or <textarea> to the
#       closing tag, <!-- to -->, <? to ?>, <! and a letter to >, <![CDATA[ to ]]>. It opens only
#       on a line indented at most three spaces (deeper is code), and one opened inside a quote or
#       a list item ends with it. One opened on an indented line has the fence's problem, and
#       after a less indented line inside it nothing more is read.
#   HTML comments, as the browser reads the result. Only text the renderer passes through as raw
#   HTML can open or close one: a line inside an HTML block, including a block opened by any other
#   tag, which runs to the next blank line and is placed by the same rules, though a line inside it
#   is not hidden. `<!--` in ordinary text or in a code span is escaped,
#   so it opens nothing; `-->` in ordinary text is escaped too, so it closes nothing. A comment
#   opened in raw HTML therefore stays open, across blank lines and past the end of the block it
#   opened in, until a `-->` that is raw HTML as well. A line inside one is not on the page.
# A line quoted with `>` or indented four spaces or a tab (a code block) is not a date line at all.
#
# The patterns spell out "up to three spaces" as ` ? ? ?`, and a date digit by digit, because the
# awk on CI's runners has no {n,m} intervals.
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
    # A line that is one complete opening or closing tag and nothing else, as CommonMark spells a
    # tag: a name, then attributes whose values may be bare, single-quoted or double-quoted. A
    # quoted value may hold a > of its own. \047 is the single quote, which this program cannot
    # hold literally.
    attribute = "[ \t]+[A-Za-z_:][A-Za-z0-9_.:-]*([ \t]*=[ \t]*([^ \t\"\047=<>`]+|\047[^\047]*\047|\"[^\"]*\"))?"
    one_tag = "^(<[A-Za-z][A-Za-z0-9-]*(" attribute ")*[ \t]*/?>|</[A-Za-z][A-Za-z0-9-]*[ \t]*>)[ \t]*$"
    fresh = 1
  }
  # Fences follow CommonMark: an opening run of three or more backticks or tildes indented at most
  # three spaces (or opened within a list item), closed only by a run of the same character at
  # least as long, with nothing after it but whitespace.
  function unindent_fence(s, extra,    k) {
    k = 3 + extra
    while (k > 0 && substr(s, 1, 1) == " ") {
      s = substr(s, 2)
      k--
    }
    return s
  }
  function run(s, c,    k) { k = 0; if (c == "") return 0; while (substr(s, k + 1, 1) == c) k++; return k }
  function spaces(s,    k) { k = 0; while (substr(s, k + 1, 1) == " ") k++; return k }
  # fence_opens(line): does this line open a fence? Sets open_char and open_len to its run,
  # open_pfx to its indentation and open_marker to the width of a list marker before the run.
  function fence_opens(s,    u) {
    open_pfx = 0
    while (open_pfx < 3 && substr(s, 1, 1) == " ") {
      s = substr(s, 2)
      open_pfx++
    }
    open_marker = 0
    u = s
    if (match(u, /^([-+*]|[0-9]+[.)])[ \t]+/)) {
      open_marker = RLENGTH
      u = substr(u, RLENGTH + 1)
    }
    open_char = substr(u, 1, 1)
    open_len = run(u, open_char)
    # A backtick fence info string cannot contain a backtick; such a line is inline code.
    return ((open_char == "`" || open_char == "~") && open_len >= 3 && !(open_char == "`" && index(substr(u, open_len + 1), "`") > 0))
  }
  # indent(line): the width of its leading whitespace, a tab reaching the next multiple of four.
  function indent(s,    k, i, c) {
    k = 0
    i = 1
    while (1) {
      c = substr(s, i, 1)
      if (c == " ") k++
      else if (c == "\t") k += 4 - (k % 4)
      else break
      i++
    }
    return k
  }
  # content(line): the line without its quote and list markers, or "" when what is left is
  # indented as code (four or more spaces, or a tab). It also records where the line sits:
  # first_quote is 1 when its outermost container is a quote, first_item is the column a list
  # item holds its content at when the outermost container is a list item (else 0), and
  # first_pad is the indentation of a line that carries no marker at all (else 0).
  function content(s,    k, depth, at) {
    first_quote = 0
    first_item = 0
    first_pad = 0
    depth = 0
    at = 0
    while (1) {
      k = spaces(s)
      if (k > 3 || substr(s, k + 1, 1) == "\t") return ""
      if (depth == 0) first_pad = k
      s = substr(s, k + 1)
      at += k
      if (substr(s, 1, 1) == ">") {
        if (depth == 0) { first_quote = 1; first_pad = 0 }
        depth++
        s = substr(s, 2)
        at++
        if (substr(s, 1, 1) == " ") { s = substr(s, 2); at++ }
        continue
      }
      if (match(s, /^([-+*]|[0-9]+[.)])[ \t]/)) {
        at += RLENGTH - 1
        s = substr(s, RLENGTH)
        if (substr(s, 1, 1) == "\t") { s = substr(s, 2); at++ }
        else {
          # One to four spaces after the marker belong to it; of five or more only one does, and
          # the rest indent the content as code.
          k = spaces(s)
          if (k > 4) k = 1
          s = substr(s, k + 1)
          at += k
        }
        if (depth == 0) { first_item = at; first_pad = 0 }
        depth++
        continue
      }
      return s
    }
  }
  # outside(quoted, item, pad): has the current line left the container an HTML block opened in?
  # 0 is no. 1 is yes: a block opened inside a quote ends at the first line that is not quoted,
  # and one opened inside a list item at the first line indented less than the item. 2 is cannot
  # tell: a block opened on an indented line with no marker may sit inside a list item, which a
  # less indented line then ended, or at the top level, where that line is still part of it.
  function outside(quoted, item, pad) {
    if (quoted) return ($0 !~ /^ ? ? ?>/) ? 1 : 0
    if (blank) return 0
    if (item > 0 && indent($0) < item) return 1
    if (pad > 0 && indent($0) < pad) return 2
    return 0
  }
  # html_block(content): the kind of HTML block with an end marker that this line opens, or 0.
  # CommonMark numbers them: 1 is <pre>, <script>, <style> or <textarea>; 2 is the comment; 3 is
  # <?; 4 is <! and a letter; 5 is <![CDATA[.
  function html_block(t,    l) {
    if (t ~ /^<!--/) return 2
    l = tolower(t)
    if (l ~ /^<(pre|script|style|textarea)([ \t>]|$)/) return 1
    if (t ~ /^<\?/) return 3
    if (t ~ /^<!\[CDATA\[/) return 5
    if (t ~ /^<![A-Za-z]/) return 4
    return 0
  }
  # html_block_ends(line, kind): does this line carry the end marker of that kind of block?
  function html_block_ends(s, kind,    l) {
    if (kind == 1) {
      l = tolower(s)
      return (index(l, "</pre>") > 0 || index(l, "</script>") > 0 || index(l, "</style>") > 0 || index(l, "</textarea>") > 0)
    }
    if (kind == 2) return index(s, "-->") > 0
    if (kind == 3) return index(s, "?>") > 0
    if (kind == 4) return index(s, ">") > 0
    return index(s, "]]>") > 0
  }
  # tag_block(content): does this line open an HTML block that runs to the next blank line? That
  # is a line starting with one of the block-level tags CommonMark lists (kind 6), or a line that
  # is one complete tag and nothing else (kind 7). A paragraph that merely starts with an inline
  # tag, or with an autolink, is ordinary text.
  function tag_block(t,    l) {
    l = tolower(t)
    if (l ~ /^<\/?(address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)([ \t>]|\/>|$)/) return 1
    if (t ~ one_tag) return 1
    return 0
  }
  # comments(raw): follow the comment openers and closers on a line of raw HTML, in order. `live`
  # is 1 while a comment is open. `<!-->` and `<!--->` are complete, empty comments.
  function comments(s,    p) {
    while (1) {
      if (live) {
        p = index(s, "-->")
        if (p == 0) return
        live = 0
        s = substr(s, p + 3)
      } else {
        p = index(s, "<!--")
        if (p == 0) return
        s = substr(s, p + 4)
        if (substr(s, 1, 1) == ">") s = substr(s, 2)
        else if (substr(s, 1, 2) == "->") s = substr(s, 3)
        else live = 1
      }
    }
  }
  # settle(): the line is ordinary text. A blank line starts a paragraph; a date line is read or
  # reported; anything else leaves the next line inside a paragraph.
  function settle(    v, starts) {
    if ($0 ~ /^[ \t]*$/) { fresh = 1; return }
    if ($0 ~ dateline) {
      starts = fresh
      fresh = (starts && $0 ~ whole)
      if (!live && $0 ~ marker) {
        v = $0
        sub(marker "[ \t]*", "", v)
        sub(/[ \t]+$/, "", v)
        # A line that does not start a paragraph, and an empty value, each become a placeholder
        # that is no date. Validation must see both: neither may be dropped, and command
        # substitution would strip a trailing empty line.
        if (!starts) print "(misplaced)"
        else print (v == "" ? "(empty)" : v)
      }
      return
    }
    fresh = 0
  }
  { sub(/\r$/, ""); blank = ($0 ~ /^[ \t]*$/) }
  lost { next }
  fence_len > 0 {
    ended = 0
    if (!blank && fence_item > 0 && indent($0) < fence_item) {
      # Opened on a list item line, the fence ends with the item: at the first line indented
      # less than the item. That line is then read like any other, and may open a fence itself.
      ended = 1
    } else if (!blank && fence_maybe > 0 && indent($0) < fence_maybe) {
      # Opened on an indented line with no marker, the fence may sit inside a list item, and
      # then this less indented line ended both; or it sits at the top level, and this line is
      # its content or its closing fence. A fence line is read as OPENING a fence, which hides
      # what follows under either reading. Any other line cannot be placed at all, so nothing
      # after it is read.
      if (fence_opens($0)) ended = 1
      else {
        lost = 1
        next
      }
    }
    if (!ended) {
      t = unindent_fence($0, fence_item)
      n = run(t, fence_char)
      if (n >= fence_len && substr(t, n + 1) ~ /^[ \t]*$/) { fence_len = 0; fence_item = 0; fence_maybe = 0 }
      # A blank line still counts as one if the item, and the fence with it, ends on the next line.
      fresh = blank
      next
    }
    fence_len = 0
    fence_item = 0
    fence_maybe = 0
  }
  # A line that left the container a block opened in is read like any other. One that cannot be
  # placed is raw HTML under one reading and ordinary text under the other, and no reading of it
  # is safe under both, so nothing after it is read.
  block_kind > 0 {
    where = outside(block_quoted, block_item, block_pad)
    if (where == 2) {
      lost = 1
      next
    }
    if (where == 1) block_kind = 0
    else {
      comments($0)
      if (html_block_ends($0, block_kind)) block_kind = 0
      # A blank line still counts as one if the container, and the block with it, ends next.
      fresh = blank
      next
    }
  }
  in_tag_block {
    where = (blank ? 1 : outside(tag_quoted, tag_item, tag_pad))
    if (where == 2) {
      lost = 1
      next
    }
    if (where == 1) in_tag_block = 0
    else {
      comments($0)
      settle()
      next
    }
  }
  fence_opens($0) {
    fence_char = open_char
    fence_len = open_len
    # The column a list item holds its content at, when the fence opens on the item line; else
    # the indentation of a fence that may or may not sit inside an item.
    fence_item = (open_marker > 0 ? open_pfx + open_marker : 0)
    fence_maybe = (open_marker > 0 ? 0 : open_pfx)
    fresh = 0
    next
  }
  {
    t = content($0)
    kind = html_block(t)
    if (kind > 0) {
      comments(t)
      # A block whose first line also carries its end marker is that one line.
      if (!html_block_ends(t, kind)) {
        block_kind = kind
        block_quoted = first_quote
        block_item = first_item
        block_pad = first_pad
      }
      fresh = 0
      next
    }
    if (tag_block(t)) {
      in_tag_block = 1
      tag_quoted = first_quote
      tag_item = first_item
      tag_pad = first_pad
      comments(t)
      fresh = 0
      next
    }
  }
  { settle() }'
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
