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
TODAY=""
ASK_MAX_AGE_DAYS=14

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
    --today)
      [ $# -ge 2 ] || usage_die "--today requires a value"
      TODAY="$2"
      shift 2
      ;;
    --ask-max-age-days)
      [ $# -ge 2 ] || usage_die "--ask-max-age-days requires a value"
      ASK_MAX_AGE_DAYS="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h | --help)
      sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) usage_die "unknown argument '$1'" ;;
  esac
done

[ -n "$ORG" ] || [ -n "$INPUT" ] || usage_die "either --org or --input is required"
[ -z "$ORG" ] || [ -z "$INPUT" ] || usage_die "--org and --input are mutually exclusive"

# The org name is interpolated into a search URL, so constrain it to the shape GitHub actually
# allows rather than trusting the caller. It is operator-supplied rather than issue-derived, but
# a value that reaches a query unvalidated is the pattern this contract rules out generally, and
# an unencoded `+`, `&` or space would silently rewrite the query rather than fail.
case "$ORG" in
  "") : ;;
  *[!A-Za-z0-9._-]*) usage_die "--org must match [A-Za-z0-9._-]+ (got '$ORG')" ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required"

# `date -u +%F` is the one spelling both BSD and GNU agree on; every OTHER date operation in this
# script is hand-rolled arithmetic for exactly that reason. `--today` exists so the self-test can
# pin the clock: a suite whose verdict changes with the calendar is one that eventually fails for
# no reason and gets deleted.
if [ -z "$TODAY" ]; then
  TODAY="$(date -u +%F)" || die "could not read the current date -- UNKNOWN"
fi
is_real_date_early() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
is_real_date_early "$TODAY" || usage_die "--today must be YYYY-MM-DD (got '$TODAY')"
case "$ASK_MAX_AGE_DAYS" in
  "" | *[!0-9]*) usage_die "--ask-max-age-days must be a non-negative integer (got '$ASK_MAX_AGE_DAYS')" ;;
esac

# What counts as NAMING a dependency. The contract's shape is `<owner/repo#N-or-release-id>`,
# but that grammar alone rejects the idiom actually in use: measured 2026-08-25 across all live
# blocker lines, 10 of them name an authority ("maintainer authority - ...") rather than a
# repository, and one names a bare repository path with no issue number. Requiring `owner/repo#N`
# would report nearly half of the portfolio's correct, live-verified records as malformed, and a
# check that fires on correct work is one people learn to ignore, then delete.
#
# These three forms are exhaustive and, unlike a slug pattern, none of them can be satisfied by
# ordinary prose. An earlier revision also accepted any hyphenated token, which meant
# `**Blocker:** waiting on third-party response | last-verified ...` CONFORMED because
# "third-party" looked like an identifier -- precisely the prose-only record this check exists to
# expose. There is no syntactic way to tell a deliberate slug from an incidental compound word,
# so the slug form is gone rather than approximated.
IDENTIFIER_RE='#[0-9]+|maintainer authority|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+'

# A URL is NOT an identifier, and the contract is explicit: the blocker record's identifier is
# "plain local data (no URL or control characters)", matched LOCALLY and never used to choose a
# destination. Unchecked, the slug alternative above matches a slash-delimited substring of any
# link -- `github.com/owner` inside `https://github.com/owner/repo/issues/7` -- so a record
# naming nothing but a link CONFORMED, which is the indefinite skip this check exists to expose.
#
# URL-shaped tokens are STRIPPED before the grammar runs rather than rejecting the whole record,
# because a record may legitimately name a real identifier AND link to it; refusing that would
# fire on correct work, which is how a check gets ignored and then deleted. A record whose only
# identifier-looking text was a URL has nothing left to match, so it is MALFORMED.
URL_TOKEN_RE='([A-Za-z][A-Za-z0-9+.-]*://|//|www\.|[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\.[A-Za-z]{2,}/)[^[:space:]]*'

STRUCTURE_RE='^\*\*Blocker:\*\* .+ \| last-verified [0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]): .+$'

# Digit counting alone accepts `2026-02-31`: month and day are bounded independently, so a day
# that cannot exist in that month still reads as a verification date. The date is what makes a
# skip RE-VERIFIABLE, so a value naming no real day is not a record. Computed arithmetically
# rather than with `date`, whose parsing flags differ between BSD and GNU and would make this
# check disagree with itself across the two CI runners.
is_real_date() { # YYYY-MM-DD
  local y m d max
  [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  y=$((10#${1:0:4}))
  m=$((10#${1:5:2}))
  d=$((10#${1:8:2}))
  case "$m" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) max=31 ;;
    4 | 6 | 9 | 11) max=30 ;;
    2) if [ "$(((y % 4 == 0 && y % 100 != 0) || y % 400 == 0))" = 1 ]; then max=29; else max=28; fi ;;
    *) return 1 ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$max" ]
}

# Days since the civil epoch (Howard Hinnant's algorithm), in pure shell arithmetic.
#
# `date` is deliberately not used: its parsing flags differ between BSD and GNU, which would make
# this check disagree with itself across the two CI runners -- the same reason `is_real_date` above
# counts days itself. Every year this sees is well inside the range where bash's truncating
# division agrees with the algorithm's floor division, so no negative-year correction is needed.
days_from_civil() { # YYYY-MM-DD -> days since 1970-01-01 on stdout
  local y m d era yoe doy doe
  y=$((10#${1:0:4}))
  m=$((10#${1:5:2}))
  d=$((10#${1:8:2}))
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$((y / 400))
  yoe=$((y - era * 400))
  if [ "$m" -gt 2 ]; then doy=$(((153 * (m - 3) + 2) / 5 + d - 1)); else doy=$(((153 * (m + 9) + 2) / 5 + d - 1)); fi
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf '%s' "$((era * 146097 + doe - 719468))"
}

# The CAUSE CLASS, and why it is not inferred from prose.
#
# An `upstream` blocker clears itself when the dependency ships, so re-verifying it every run is
# exactly right. An `authority` blocker clears only when a person is asked, so re-verification
# ALONE GUARANTEES IT NEVER CLEARS -- the loop is structurally incapable of finishing it, and the
# more diligently it re-verifies the more permanent the parking looks.
#
# Measured 2026-09-05 across the org: 19 of 46 open blocked-labelled issues were authority-caused,
# and 8 of those carried no ask of ANY kind -- only CodeRabbit's auto-generated plan, or no
# comments at all. The oldest had been open 54 days. Their blocker lines were all CONFORMING; the
# check reported a clean sweep over them, because conformance was never the same thing as progress.
#
# The class is an EXPLICIT token rather than something sniffed out of the identifier. Inference
# would fail open on exactly the case that matters: a blocker phrased "needs an account action" or
# "requires provisioning" is authority-caused, reads as ordinary prose, and would silently escape
# the ask requirement forever. A missing class is therefore a finding (LEGACY), never a pass.
CLASS_RE='^(upstream|authority)$'
ASK_RE='\| asked ([A-Za-z0-9._-]+) ([0-9]{4}-[0-9]{2}-[0-9]{2})$'

# Matching is done with bash's own `=~` rather than `printf | grep -q`: `grep -q` exits on its
# first match and can SIGPIPE the writer, which under `set -o pipefail` surfaces as rc=141 on a
# body large enough to exceed the pipe buffer. Keeping the match in-process removes that class.
line_conforms() { # <logical line>
  local logical="$1" ident stripped date_str
  [[ $logical =~ $STRUCTURE_RE ]] || return 1

  # Control characters cannot occur in a legitimate record and are named by the contract
  # alongside URLs. Tabs are normalised first so ordinary indentation is not treated as one.
  case "${logical//$'\t'/ }" in
    *[[:cntrl:]]*) return 1 ;;
  esac

  date_str="$(printf '%s\n' "$logical" |
    sed -n -E 's/.*\| last-verified ([0-9]{4}-[0-9]{2}-[0-9]{2}):.*/\1/p')"
  [ -n "$date_str" ] || return 1
  is_real_date "$date_str" || return 1

  ident="${logical%% | last-verified *}"
  stripped="$(printf '%s\n' "$ident" | sed -E "s#$URL_TOKEN_RE##g")"
  [[ $stripped =~ $IDENTIFIER_RE ]]
}

# Classify a structurally-conforming record. Sets VERDICT to one of:
#
#   CONFORMS   an upstream blocker, or an authority blocker with a fresh ask
#   LEGACY     no class field -- predates this grammar, repair it
#   MALFORMED  a class token that is not one of the two, or a malformed ask
#   NO-ASK     an authority blocker nobody has raised
#   STALE-ASK  an authority blocker whose ask has gone quiet past the cadence
#
# The class is the ` | `-delimited segment immediately before `last-verified`. Reading it
# positionally rather than by searching the whole line matters: an identifier may legitimately
# contain the word "authority" as prose ("maintainer authority — a bucket"), and a substring
# search would then read a class out of an identifier that never declared one.
classify_record() { # <logical line> -> sets VERDICT, LEGACY_NOTE
  local logical="$1" head cls ask_date ask_days today_days
  LEGACY_NOTE=0

  head="${logical%% | last-verified *}"
  if [ "$head" = "$logical" ]; then VERDICT="MALFORMED"; return; fi

  if [ "$head" = "${head%% | *}" ]; then
    # No class segment. INFER it from the identifier rather than refusing the record.
    #
    # Refusing was tried and rejected on a measurement: every one of the 46 live records predates
    # this field, so a strict reading reports 46 findings on day one and buries the 19 that are
    # real. This script's own header names that failure -- "a check that cries wolf on correct work
    # is one people learn to ignore, then delete" -- and the migration that would clear it is not
    # performable by the lane that ships this (issue-body writes are denied by the runtime).
    #
    # Inference is strictly better than the status quo and never worse: an unclassed record is
    # evaluated exactly as it is today unless its identifier already says `maintainer authority`,
    # in which case the ask requirement now bites. It is a WEAKER guarantee than an explicit token
    # -- a blocker phrased "needs an account action" still reads as upstream -- which is why the
    # explicit form stays required by the contract and always overrides this fallback.
    LEGACY_NOTE=1
    if [[ $head =~ maintainer\ authority ]]; then cls="authority"; else cls="upstream"; fi
  else
    cls="${head##* | }"
    [[ $cls =~ $CLASS_RE ]] || { VERDICT="MALFORMED"; return; }
  fi

  if [ "$cls" = "upstream" ]; then VERDICT="CONFORMS"; return; fi

  # ---- authority: an ask is REQUIRED, because nothing else will ever move this issue.
  if [[ ! $logical =~ $ASK_RE ]]; then VERDICT="NO-ASK"; return; fi
  ask_date="${BASH_REMATCH[2]}"
  is_real_date "$ask_date" || { VERDICT="MALFORMED"; return; }

  ask_days="$(days_from_civil "$ask_date")"
  today_days="$(days_from_civil "$TODAY")"
  if [ "$((today_days - ask_days))" -gt "$ASK_MAX_AGE_DAYS" ]; then
    VERDICT="STALE-ASK"
    return
  fi
  VERDICT="CONFORMS"
}

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
  if ! raw="$(gh api "search/issues?q=org:${ORG}+is:issue+state:open+label:blocked+archived:false&per_page=100" \
    --paginate 2>/dev/null)"; then
    die "forge read failed -- UNKNOWN, never zero"
  fi
  [ -n "$raw" ] || die "forge read returned nothing -- UNKNOWN, never zero"

  # A timed-out search returns whatever it found so far AND a matching total_count, so the
  # fetched-vs-expected comparison below AGREES on a truncated set and reports a clean sweep.
  # `incomplete_results` is the only field that distinguishes the two, so it is checked first.
  if printf '%s' "$raw" | jq -se 'any(.[]; .incomplete_results == true)' >/dev/null 2>&1; then
    die "search reported incomplete_results (timed out) -- UNKNOWN, never a clean sweep"
  fi

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
        BEGIN { found = 0; collecting = 0; buf = ""; infence = 0; incomment = 0; fencechar = ""; fencelen = 0 }
        {
          line = $0
          sub(/\r$/, "", line)
          if (found) next

          # ---- HTML comment context. A body that keeps an old record inside <!-- --> has no
          # visible status line, so a marker in there must not satisfy the check. Comments can
          # open and close mid-line and can span many lines, so consume the commented spans and
          # keep only what is left OUTSIDE them.
          #
          # ONLY outside a fence. Inside a fenced block an <!-- --> run is literal code content,
          # so stripping it there can forge a closing fence out of a commented prefix followed by
          # a backtick run -- ending the block early and exposing the example as a live record.
          # A fence cannot be open while incomment is set: the opener would itself have been
          # consumed as commented text, so infence == 1 implies incomment == 0 here.
          if (!infence) {
            out = ""
            rest = line
            while (rest != "") {
              if (incomment) {
                p = index(rest, "-->")
                if (p == 0) { rest = ""; break }
                rest = substr(rest, p + 3)
                incomment = 0
              } else {
                p = index(rest, "<!--")
                if (p == 0) { out = out rest; rest = ""; break }
                out = out substr(rest, 1, p - 1)
                rest = substr(rest, p + 4)
                incomment = 1
              }
            }
            line = out
          }

          # ---- fenced code block context. A fence shows the SYNTAX as an example; it is not a
          # record. A fence opens on a run of 3+ backticks or tildes and closes only on a run of
          # the SAME character, at least as long, carrying no info string (CommonMark). A shorter
          # or mismatched run is ordinary CONTENT, so the ``` line inside a ```` block does not
          # end it -- a plain toggle would end the block there and expose the example as a record.
          if (line ~ /^[ \t]{0,3}(`{3,}|~{3,})/) {
            m = line
            sub(/^[ \t]{0,3}/, "", m)
            fch = substr(m, 1, 1)
            n = 0
            while (substr(m, n + 1, 1) == fch) n++
            info = substr(m, n + 1)
            gsub(/[ \t]/, "", info)
            if (!infence) {
              if (collecting) { found = 1; collecting = 0 }
              infence = 1
              fencechar = fch
              fencelen = n
              next
            }
            if (fch == fencechar && n >= fencelen && info == "") {
              infence = 0
              next
            }
            # a shorter or mismatched run inside a fence is content, not a close
          }
          if (infence) next

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
  elif ! line_conforms "$logical"; then
    [ "$QUIET" = 1 ] || printf 'MALFORMED  %s#%s  >>%s\n' "$repo" "$num" "${logical:0:100}"
    bad=$((bad + 1))
  else
    classify_record "$logical"
    case "$VERDICT" in
      CONFORMS)
        [ "$QUIET" = 1 ] || {
          if [ "$LEGACY_NOTE" = 1 ]; then
            printf 'CONFORMS   %s#%s  [legacy: no class token]\n' "$repo" "$num"
          else
            printf 'CONFORMS   %s#%s\n' "$repo" "$num"
          fi
        }
        ;;
      *)
        [ "$QUIET" = 1 ] || printf '%-10s %s#%s  >>%s\n' "$VERDICT" "$repo" "$num" "${logical:0:100}"
        bad=$((bad + 1))
        ;;
    esac
  fi
done

# A payload with records must produce evaluations; silence here would be a broken loop
# reporting success, which is the fail-open this whole check exists to avoid.
if [ "$considered" != "$count" ]; then
  die "evaluated ${considered} of ${count} records -- UNKNOWN"
fi

if [ "$bad" -gt 0 ]; then
  printf '\n%s: %d of %d open blocked-labelled issue(s) need repair (missing, malformed, or an unraised authority blocker).\n' \
    "$PROG" "$bad" "$count"
  exit 1
fi

printf '\n%s: all %d open blocked-labelled issue(s) carry a conforming **Blocker:** line.\n' \
  "$PROG" "$count"
exit 0
