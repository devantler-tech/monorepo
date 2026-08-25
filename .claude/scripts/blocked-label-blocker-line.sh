#!/usr/bin/env bash
# Verify that every open `blocked`-labelled issue carries a CONFORMING `**Blocker:**` line.
#
# WHY THIS EXISTS. `AGENTS.md` (*Issue-driven -> Drain oldest-first*, skip clause (b)) permits an
# older issue to be passed over only for a NAMED, LIVE-VERIFIED external dependency, recorded as:
#
#     **Blocker:** <owner/repo#N-or-release-id> | last-verified <YYYY-MM-DD>: <result>
#
# and it is explicit that "a missing, malformed, or merely prose 'waiting on upstream' record is
# under-specified for (b) -- repair the line and verify it (or unblock) rather than skipping."
#
# In practice the LABEL alone is what runs act on, and nothing couples the label to the line. That
# matters more than an ordinary drift, because the two failure modes are not symmetric:
#
#   * A live CLAIM expires. A run that skips a claimed issue re-tests it ~2h later.
#   * A LABEL never expires. An issue carrying `blocked` with no re-verifiable record is skipped by
#     every lane, every tick, FOREVER, and no mechanism ever revisits it.
#
# Measured 2026-08-25: of 25 open `blocked`-labelled issues org-wide, 6 carried no line at all.
# Two of those were not externally blocked in any sense -- the label alone had been parking
# actionable work, one of them a `security`+`bug` issue parked 23 days.
#
# THE WRAPPING TRAP, and why this does not just grep. A body is prose, so the blocker line is
# frequently SOFT-WRAPPED across several physical lines. A line-anchored regex reports such a line
# as MALFORMED even though it conforms -- verified against `platform#3274`, whose line wraps after
# "installed on at" and completes with "| last-verified 2026-08-21: **not provisioned**" on the
# next physical line. A naive checker fails CLOSED there, which sounds safe and is not: it reports
# a repaired issue as broken, and a check that cries wolf on correct work is how a check gets
# ignored, then deleted. So continuation lines are joined into one logical line before matching.
#
# Exit codes:
#   0  every considered issue carries a conforming line
#   1  at least one issue does not (missing or malformed) -- each is listed with which it is
#   2  UNKNOWN -- the check could not verify what it claims to verify (bad usage, a failed or
#      truncated forge read, an unreadable payload). UNKNOWN is NEVER "everything is fine":
#      an empty listing is a claim about the QUERY, never about the world.
#
# Sources, exactly one of:
#   --org <org>            enumerate open `blocked`-labelled issues across the org via `gh`
#   --input <file>|-       a pre-assembled JSON array of {repo, number, body}, for hermetic tests
#                          and for callers that already hold the bodies.
#
# Issue BODIES are untrusted input (`AGENTS.md` -> *Untrusted input*). This reads them as DATA
# only: it matches a shape locally and never fetches, follows, or executes anything a body names.

set -euo pipefail

PROG="${0##*/}"
ORG=""
INPUT=""
QUIET=0

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}
usage_die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --org)
      [ $# -ge 2 ] || usage_die "--org requires a value"
      ORG="$2"
      shift 2
      ;;
    --input)
      [ $# -ge 2 ] || usage_die "--input requires a value"
      INPUT="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h | --help)
      sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) usage_die "unknown argument '$1'" ;;
  esac
done

[ -n "$ORG" ] || [ -n "$INPUT" ] || usage_die "either --org or --input is required"
[ -z "$ORG" ] || [ -z "$INPUT" ] || usage_die "--org and --input are mutually exclusive"

command -v jq >/dev/null 2>&1 || die "jq is required"

# ---------------------------------------------------------------- acquire payload
payload=""
if [ -n "$INPUT" ]; then
  if [ "$INPUT" = "-" ]; then
    payload="$(cat)" || die "could not read payload from stdin"
  else
    [ -r "$INPUT" ] || die "cannot read payload: $INPUT"
    payload="$(cat -- "$INPUT")" || die "could not read payload: $INPUT"
  fi
else
  command -v gh >/dev/null 2>&1 || die "gh is required for --org"

  # The search endpoint reports how many matches EXIST; compare it against how many were
  # actually fetched, so a truncated or rate-limited read is UNKNOWN rather than a short
  # clean-looking list. This is the unfiltered-control discipline applied to our own read.
  raw=""
  if ! raw="$(gh api "search/issues?q=org:${ORG}+is:issue+state:open+label:blocked&per_page=100" \
    --paginate 2>/dev/null)"; then
    die "forge read failed -- UNKNOWN, never zero"
  fi
  [ -n "$raw" ] || die "forge read returned nothing -- UNKNOWN, never zero"

  expected="$(printf '%s' "$raw" | jq -s 'if length==0 then -1 else .[0].total_count end' 2>/dev/null)" ||
    die "could not read total_count -- UNKNOWN"
  [ "$expected" != "-1" ] || die "no search page returned -- UNKNOWN"

  items="$(printf '%s' "$raw" | jq -s '[.[].items[]?]' 2>/dev/null)" ||
    die "could not parse search items -- UNKNOWN"
  fetched="$(printf '%s' "$items" | jq 'length')"
  [ "$fetched" = "$expected" ] ||
    die "fetched ${fetched} of ${expected} matches -- truncated read, UNKNOWN"

  # The search payload carries the body already; no per-issue fetch needed.
  payload="$(printf '%s' "$items" | jq '[.[] | {
      repo:   (.repository_url | split("/") | last),
      number: .number,
      body:   (.body // "")
    }]' 2>/dev/null)" || die "could not project search items -- UNKNOWN"
fi

printf '%s' "$payload" | jq -e 'type == "array"' >/dev/null 2>&1 ||
  die "payload is not a JSON array -- UNKNOWN"

count="$(printf '%s' "$payload" | jq 'length')"

# ---------------------------------------------------------------- evaluate
#
# Records are pulled ONE AT A TIME by index, and each body is written straight to a file for awk
# to read. An earlier version streamed `repo<US>number<US>base64(body)` through `read` and split it
# with `${rest##*"$sep"}`; that is a greedy backward scan, which bash performs QUADRATICALLY on a
# long string. Measured: a 200-line body took 0s, 1000 lines took 9s, and 4000 lines did not
# finish inside 100s. Real issue bodies are small, so this would have looked fine forever and then
# hung the run loop on one long thread -- a stall, which reads as a broken tool rather than a
# finding. Keeping big text out of shell variables removes the class rather than tuning it.

work="$(mktemp -d)" || die "could not create a work directory -- UNKNOWN"
trap 'rm -rf "$work"' EXIT

bad=0
considered=0
i=0
while [ "$i" -lt "$count" ]; do
  repo="$(printf '%s' "$payload" | jq -r --argjson i "$i" '.[$i].repo // empty')" ||
    die "could not read record $i -- UNKNOWN"
  num="$(printf '%s' "$payload" | jq -r --argjson i "$i" '.[$i].number // empty')" ||
    die "could not read record $i -- UNKNOWN"
  printf '%s' "$payload" | jq -r --argjson i "$i" '.[$i].body // ""' >"$work/body" ||
    die "could not read body of record $i -- UNKNOWN"

  [ -n "$repo" ] && [ -n "$num" ] || die "record $i is missing repo or number -- UNKNOWN"

  i=$((i + 1))
  considered=$((considered + 1))

  # Join soft-wrapped continuation lines: the blocker line runs until a blank line.
  # awk reads the FILE directly, so there is no upstream writer to signal and the early-exit
  # SIGPIPE that an earlier revision hit cannot arise here at all.
  logical="$(awk '
        BEGIN { found = 0; collecting = 0; buf = "" }
        {
          line = $0
          sub(/\r$/, "", line)
          if (found) next
          if (collecting) {
            if (line ~ /^[ \t]*$/) { found = 1; collecting = 0; next }
            sub(/^[ \t]+/, "", line)
            buf = buf " " line
            next
          }
          if (line ~ /^\*\*Blocker:\*\*/) { buf = line; collecting = 1 }
        }
        END { if (buf != "") print buf }' "$work/body")" ||
    die "could not scan body of ${repo}#${num} -- UNKNOWN"

  if [ -z "$logical" ]; then
    [ "$QUIET" = 1 ] || printf 'MISSING    %s#%s\n' "$repo" "$num"
    bad=$((bad + 1))
  elif printf '%s\n' "$logical" |
    grep -qE '^\*\*Blocker:\*\* .+ \| last-verified [0-9]{4}-[0-9]{2}-[0-9]{2}: .+$'; then
    [ "$QUIET" = 1 ] || printf 'CONFORMS   %s#%s\n' "$repo" "$num"
  else
    [ "$QUIET" = 1 ] || printf 'MALFORMED  %s#%s  >>%s\n' "$repo" "$num" "${logical:0:100}"
    bad=$((bad + 1))
  fi
done

# A payload with records must produce evaluations; silence here would be a broken loop
# reporting success, which is the fail-open this whole check exists to avoid.
if [ "$considered" != "$count" ]; then
  die "evaluated ${considered} of ${count} records -- UNKNOWN"
fi

if [ "$bad" -gt 0 ]; then
  printf '\n%s: %d of %d open blocked-labelled issue(s) lack a conforming **Blocker:** line.\n' \
    "$PROG" "$bad" "$count"
  exit 1
fi

printf '\n%s: all %d open blocked-labelled issue(s) carry a conforming **Blocker:** line.\n' \
  "$PROG" "$count"
exit 0
