#!/usr/bin/env bash
# coderabbit-comment-verdict.sh — decide whether ONE CodeRabbit reply COMMENT carries a finding-free
# review verdict for ONE exact head (monorepo#3008).
#
# WHY THIS EXISTS
#   CodeRabbit often delivers a finished review as a reply comment rather than a review object, and
#   it words the verdict differently almost every time. Measured on real current-head greens:
#     `I reviewed <sha>.` / `I reviewed exact head <sha>.` / `Reviewed exact head <sha>.` /
#     `Reviewed <sha>.` / `I completed a static review at <sha>.` / `Full review is complete for
#     <sha> against <base>.` / `Reviewed pull request #<n> at <sha>.`, each followed by a verdict
#     such as `I found no actionable issues.`, `I found no new correctness issue.`,
#     `I found no blocking issue in this revision.`, `No findings.` or `No new findings.`
#   A matcher pinned to one or two of those sentences read every other one as "no review", and runs
#   then spent weekly-limited Codex and monthly-limited Bugbot on heads that were already green.
#   So this helper matches the STRUCTURE every one of them shares instead of a phrase list:
#     - the body is a CodeRabbit reply (its `auto-generated reply` marker), from `coderabbitai[bot]`;
#     - a standalone finding-free verdict sentence (`I found no …` / `No …` naming issues or
#       findings, with no qualifying clause);
#     - the FIRST sha the reply's prose names before that verdict (its opening `I reviewed <sha>`
#       line) is a prefix (7+ chars) of the head, so a later `against <base>` never binds;
#     - no did-not-run marker and no finding marker anywhere in the prose.
#   The protections stay: an acknowledgement shell has no verdict, a verdict naming no sha is at
#   best stale evidence, and a verdict naming another sha is a review of another head.
#
# USAGE
#   coderabbit-comment-verdict.sh --input -
#   stdin: ONE JSON object with exactly the string keys `head`, `author` and `body`, e.g. from
#          `gh api repos/<o>/<r>/issues/comments/<id> --jq '{head:"<headRefOid>",
#          author:.user.login, body:(.body // "")}'`. `head` must be the full 40-character sha.
#   The caller still owns the freshness bind (updated after the authenticated request for this head)
#   and every other pentad surface; this judges one comment only.
#
# OUTPUT (one line on stdout)
#   GREEN            a CodeRabbit reply stating a finding-free review of --head
#   NONE <reason>    not a green for this head; <reason> is one of not-coderabbit, not-a-reply,
#                    did-not-run, finding-markers, no-verdict, no-sha, other-head
#
# EXIT CODES
#   0  GREEN
#   1  NONE
#   2  usage error or malformed input — nothing was judged
set -euo pipefail

usage() {
  sed -n '26,44p' "$0" >&2
  exit 2
}

[ "$#" -eq 2 ] && [ "$1" = "--input" ] && [ "$2" = "-" ] || usage
command -v jq >/dev/null 2>&1 || {
  echo "coderabbit-comment-verdict: jq is required" >&2
  exit 2
}

payload="$(cat)" || exit 2
jq -se 'length == 1 and (.[0] | type == "object"
    and (keys == ["author", "body", "head"])
    and (.head | type == "string" and length == 40 and (test("[^0-9a-f]") | not))
    and (.author | type == "string") and (.body | type == "string"))' \
  <<<"$payload" >/dev/null 2>&1 || {
  echo "coderabbit-comment-verdict: stdin must be one JSON object with exactly the string keys author, body and head (full lowercase sha)" >&2
  exit 2
}

head="$(jq -r '.head' <<<"$payload")"
author="$(jq -r '.author' <<<"$payload")"
body="$(jq -r '.body' <<<"$payload")"

verdict() {
  printf '%s\n' "$1"
  [ "$1" = GREEN ]
  exit $?
}

[ "$author" = "coderabbitai[bot]" ] || verdict "NONE not-coderabbit"
grep -Fq '<!-- This is an auto-generated reply by CodeRabbit -->' <<<"$body" || verdict "NONE not-a-reply"

# One awk pass walks the prose: code fences are skipped entirely, <details> blocks (the analysis
# chain) are skipped for the verdict and its sha, but still searched for markers. Prints one line.
result="$(awk -v head="$head" '
  function lower(s) { return tolower(s) }
  function ishex(t) { return t != "" && t !~ /[^0-9a-f]/ }
  # The reviewed sha on a line: the FIRST backticked 7-40 hex token, else the first bare 40-hex word.
  # Interval expressions are avoided on purpose: not every awk on the CI runners supports them.
  function sha_of(line,   rest, t, n, w, i) {
    rest = line
    while (match(rest, /`[^`]*`/)) {
      t = substr(rest, RSTART + 1, RLENGTH - 2)
      if (ishex(t) && length(t) >= 7 && length(t) <= 40) return t
      rest = substr(rest, RSTART + RLENGTH)
    }
    n = split(line, w, /[^0-9a-f]+/)
    for (i = 1; i <= n; i++) if (length(w[i]) == 40) return w[i]
    return ""
  }
  # A standalone finding-free verdict: "I found no ..." or "No ..." naming issues or findings,
  # plain words only (no comma, colon or qualifying clause), at most four words on either side of
  # the noun, ending in a full stop.
  function is_verdict(s,   l, n, w, i, start, noun) {
    l = lower(s)
    if (l !~ /\.$/) return 0
    l = substr(l, 1, length(l) - 1)
    if (l ~ /[^a-z -]/) return 0
    n = split(l, w, / /)
    if (w[1] == "i" && w[2] == "found" && w[3] == "no") start = 4
    else if (w[1] == "no") start = 2
    else return 0
    noun = 0
    for (i = start; i <= n; i++) {
      if (w[i] == "") return 0
      if (w[i] ~ /^(except|but|however|besides|apart|aside|other|beyond|unless|only|remain|remaining|yet)$/) return 0
      if (!noun && w[i] ~ /^(issue|issues|finding|findings)$/) noun = i
    }
    if (!noun || noun - start > 4 || n - noun > 4) return 0
    return 1
  }
  BEGIN { fence = 0; depth = 0; first = ""; notrun = 0; finding = 0; vsha = "none"; found = 0 }
  {
    line = $0
    if (line ~ /rate limited by coderabbit\.ai -->/) notrun = 1
    if (line ~ /^[ \t]*(```|~~~)/) { fence = !fence; next }
    if (fence) next
    if (line ~ /(Review limit reached|[Rr]eview limit|couldn.t start this review|Review skipped|Review failed|[Rr]ate limit exceeded)/) notrun = 1
    if (line ~ /(^#+ *P[0-3]([^0-9]|$)|\*\*P[0-3]([^0-9]|$)|^#+ Review finding|Potential issue|Actionable comments posted: [1-9])/) finding = 1
    if (line ~ /<summary>[^<]*comments \([1-9][0-9]*\)<\/summary>/ && line !~ /🔇/) finding = 1
    opens = gsub(/<details/, "&", line); closes = gsub(/<\/details>/, "&", line)
    was = depth; depth += opens - closes
    if (was > 0 || depth > 0) next
    stripped = line; sub(/^[ \t]+/, "", stripped); sub(/[ \t]+$/, "", stripped)
    if (stripped == "" || stripped ~ /^<!--.*-->$/) next
    if (stripped ~ /^>/) next
    if (!found) {
      # The reviewed commit is the FIRST sha the prose of the reply names before its verdict: CodeRabbit
      # opens with it (`I reviewed <sha>.`) and may discuss other commits further down. A verdict
      # sentence on the same line as that opening is split off first.
      n = split(stripped, parts, /\. /)
      before = ""
      for (i = 1; i <= n; i++) {
        s = parts[i]; if (i < n) s = s "."
        if (is_verdict(s)) {
          found = 1
          vsha = first; if (vsha == "") vsha = sha_of(before)
          break
        }
        before = before " " s
      }
    }
    if (first == "") first = sha_of(stripped)
  }
  END {
    if (notrun) { print "NONE did-not-run"; exit }
    if (finding) { print "NONE finding-markers"; exit }
    if (!found) { print "NONE no-verdict"; exit }
    if (vsha == "") { print "NONE no-sha"; exit }
    if (length(vsha) < 7 || substr(head, 1, length(vsha)) != vsha) { print "NONE other-head"; exit }
    print "GREEN"
  }
' <<<"$body")" || exit 2

verdict "$result"
