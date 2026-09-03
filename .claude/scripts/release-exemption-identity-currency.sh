#!/usr/bin/env bash
# Verify that the release identity pinned by `programmed-bot-review-exemption.sh` still matches the
# identity real release PRs actually carry.
#
# WHY THIS EXISTS. The classifier's `copilot-plugin` arm grants a review exemption only to a release
# PR whose commit provenance matches a pinned bot identity, byte for byte. That pin is a claim about
# production, and production changed underneath it: the release automation re-signed as a different
# bot and the arm silently stopped matching anything (`monorepo#3173`).
#
# The failure is FAIL-CLOSED -- a genuine release PR is classified untrusted rather than exempt, so
# nothing unsafe merges. But it silently withdraws a carve-out the maintainer deliberately granted,
# and review capacity is metered, so the release train pays for an AI review round it was designed
# not to need.
#
# WHY THE EXISTING TEST SUITE CANNOT CATCH IT. `portfolio-surveyor.test.sh` encodes the SAME pinned
# identity as the implementation. Fixture and implementation agree with each other and both disagree
# with production, so the suite passes at full green while the arm matches nothing. Running those
# tests harder can never reveal it: no amount of internal consistency is evidence about the world.
#
# THE ONE DESIGN RULE THAT MAKES THIS GUARD WORK. It reads the pinned identity OUT OF the classifier
# and compares it against LIVE release PRs. It never re-declares that identity. A guard carrying its
# own copy would be a third stale copy agreeing with the other two -- precisely the defect above,
# reproduced one level up, and it would read as protection while protecting nothing.
#
# WHY "RECENT", NOT "ANY IN THE WINDOW". The obvious formulation -- fail when the pin matches no PR
# merged in the last N days -- was measured against the real transition and does not work. The
# changeover on 2026-08-29 was clean and instant: 12 releases carried the old identity, then every
# release from 16:31Z carried the new one, with zero overlap. A 30-day window still contains those
# 12 pre-transition matches, so it reports CURRENT while every release for five days has failed the
# arm, and it would keep reporting CURRENT for another three weeks. Detection lag equal to the window
# is not detection. The live question is whether the arm works NOW, so the verdict keys on the most
# recent releases and the window only bounds which PRs are considered.
#
# WHY MORE THAN ONE RECENT PR. A single non-matching release is not proof of drift: an adaptation
# commit legitimately takes one PR off its programmed path, which is the carve-out working as
# designed. Requiring the newest K to ALL miss distinguishes a systematic identity change from one
# anomalous release.
#
# THE ABSENCE TRAP. "No release PR matched the pin" and "no release PR exists" render identically as
# an empty result, and only the first is drift. A quiet release train, a renamed branch prefix, or a
# failed forge read would otherwise be reported as drift -- and a check that cries wolf on correct
# work gets ignored, then deleted. So an empty candidate set is UNKNOWN, never DRIFT.
#
# Exit codes:
#   0  CURRENT -- at least one of the most recent releases carries the pinned identity
#   1  DRIFT   -- releases exist and NONE of the most recent K carries it; the observed identity is
#      reported alongside the pinned one, so the fix is visible without a second investigation
#   2  UNKNOWN -- the check could not verify what it claims to verify: bad usage, an unreadable or
#      unparseable classifier, a failed forge read, or NO candidate release PR at all.
#      UNKNOWN is NEVER "no drift" -- it means the question was not answered.
#
# Sources, exactly one of:
#   --repo <owner/repo>    enumerate recent merged release PRs via `gh` (default: devantler-tech/ksail)
#   --input <file>|-       a pre-assembled JSON array of {number, mergedAt, commits:[{author_login,
#                          author_name, author_email, committer_login, committer_name,
#                          committer_email}]}, for hermetic tests
#
# Other options:
#   --recent K   how many of the newest releases must all miss before reporting drift (default 3)
#   --days N     only consider releases merged in the last N days; 0 means no window (default 30)
#
# PR titles, branch names and commit metadata are untrusted input (`AGENTS.md` -> *Untrusted input*).
# This reads them as DATA only: it matches shapes locally and never fetches, follows, or executes
# anything they name.

set -euo pipefail

PROG="${0##*/}"
REPO="devantler-tech/ksail"
INPUT=""
DAYS=30
RECENT=3
CLASSIFIER=""
QUIET=0

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)       [ $# -ge 2 ] || die "--repo requires a value";       REPO="$2"; shift 2 ;;
    --input)      [ $# -ge 2 ] || die "--input requires a value";      INPUT="$2"; shift 2 ;;
    --days)       [ $# -ge 2 ] || die "--days requires a value";       DAYS="$2"; shift 2 ;;
    --recent)     [ $# -ge 2 ] || die "--recent requires a value";     RECENT="$2"; shift 2 ;;
    --classifier) [ $# -ge 2 ] || die "--classifier requires a value"; CLASSIFIER="$2"; shift 2 ;;
    --quiet)      QUIET=1; shift ;;
    -h|--help)    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown argument '$1'" ;;
  esac
done

case "$DAYS" in   ''|*[!0-9]*) die "--days must be a non-negative integer, got '$DAYS'" ;; esac
case "$RECENT" in ''|*[!0-9]*) die "--recent must be a positive integer, got '$RECENT'" ;; esac
[ "$RECENT" -gt 0 ] || die "--recent must be at least 1"

command -v jq >/dev/null 2>&1 || die "jq is required"

# ---------------------------------------------------------------------------
# 1. Read the pinned identity OUT OF the classifier.
# ---------------------------------------------------------------------------
if [ -z "$CLASSIFIER" ]; then
  CLASSIFIER="$(cd "$(dirname "$0")" && pwd)/programmed-bot-review-exemption.sh"
fi
[ -r "$CLASSIFIER" ] || die "classifier not readable: $CLASSIFIER"

# The pin lives in the `matches_ksail_provenance` jq literal. Take only that function's body, so a
# same-named field in a neighbouring arm can never be picked up instead.
arm="$(awk '
  /^matches_ksail_provenance\(\)/ { inarm = 1 }
  inarm { print }
  inarm && /^}/ && inarm_started { exit }
  inarm { inarm_started = 1 }
' "$CLASSIFIER")" || die "failed to read classifier"

[ -n "$arm" ] || die "could not locate matches_ksail_provenance() in $CLASSIFIER — the arm may have been renamed; re-point this guard rather than assuming it is clean"

pin_field() {
  # `author_name: "value",` -> `value`. An absent field yields empty, which the caller rejects.
  printf '%s\n' "$arm" \
    | sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\(.*\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p" \
    | head -1
}

PIN_AUTHOR_LOGIN="$(pin_field author_login)"
PIN_AUTHOR_NAME="$(pin_field author_name)"
PIN_AUTHOR_EMAIL="$(pin_field author_email)"
PIN_COMMITTER_LOGIN="$(pin_field committer_login)"
PIN_COMMITTER_NAME="$(pin_field committer_name)"
PIN_COMMITTER_EMAIL="$(pin_field committer_email)"

# `author_login`/`committer_login` are legitimately pinned to the empty string, so emptiness cannot
# distinguish "pinned empty" from "extraction failed" for those two. The three name/email fields are
# never legitimately empty, so they are what proves the extraction actually ran.
[ -n "$PIN_AUTHOR_NAME" ] && [ -n "$PIN_AUTHOR_EMAIL" ] && [ -n "$PIN_COMMITTER_NAME" ] \
  || die "could not extract the pinned identity from $CLASSIFIER — refusing to report a verdict from an unparsed pin"

# ---------------------------------------------------------------------------
# 2. Collect candidate release PRs, newest first.
# ---------------------------------------------------------------------------
# A candidate is a MERGED PR on the copilot-plugin release path. The shape mirrors the classifier's
# own branch/title conditions; if the release automation renames either, no candidate is found and
# this reports UNKNOWN, which is the honest answer -- the pin may still be right, we just cannot see.
BRANCH_RE='^chore/copilot-plugin-v[0-9]+\.[0-9]+\.[0-9]+'

cutoff=""
if [ "$DAYS" -gt 0 ]; then
  # BSD and GNU `date` spell relative arithmetic differently and neither accepts the other's form.
  cutoff="$(date -u -v-"${DAYS}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "${DAYS} days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || true)"
  [ -n "$cutoff" ] || die "could not compute a ${DAYS}-day cutoff with either BSD or GNU date"
fi

if [ -n "$INPUT" ]; then
  if [ "$INPUT" = "-" ]; then payload="$(cat)"; else
    [ -r "$INPUT" ] || die "input not readable: $INPUT"
    payload="$(cat "$INPUT")"
  fi
  printf '%s' "$payload" | jq -e 'type == "array"' >/dev/null 2>&1 || die "input is not a JSON array"
else
  command -v gh >/dev/null 2>&1 || die "gh is required for --repo mode"
  # NOTE: filtering is CLIENT-SIDE on purpose. `gh pr list --search 'chore(copilot-plugin): release
  # in:title'` returns ZERO rows against this very repository while the PRs plainly exist -- the
  # parentheses and colon break the qualifier, and it fails by returning an empty set rather than an
  # error. An empty filtered read is a claim about the filter, so the filter is not trusted here.
  raw="$(gh pr list --repo "$REPO" --state merged --limit 100 \
      --json number,mergedAt,headRefName 2>/dev/null)" \
    || die "failed to list merged PRs for $REPO"
  [ -n "$raw" ] || die "empty response listing merged PRs for $REPO"

  heads="$(printf '%s' "$raw" | jq -r --arg b "$BRANCH_RE" --arg c "$cutoff" '
    [ .[]
      | select((.headRefName // "") | test($b))
      | select($c == "" or ((.mergedAt // "") >= $c))
    ] | sort_by(.mergedAt) | reverse | .[] | "\(.number) \(.mergedAt)"')" \
    || die "failed to filter candidate release PRs"

  payload="[]"
  while read -r n merged; do
    [ -n "$n" ] || continue
    commits="$(gh api "repos/$REPO/pulls/$n/commits" --jq '[.[] | {
        author_login:    (.author.login // ""),
        author_name:     (.commit.author.name // ""),
        author_email:    (.commit.author.email // ""),
        committer_login: (.committer.login // ""),
        committer_name:  (.commit.committer.name // ""),
        committer_email: (.commit.committer.email // "")
      }]' 2>/dev/null)" \
      || die "failed to read commits for $REPO#$n"
    [ -n "$commits" ] || die "empty commit list for $REPO#$n"
    payload="$(printf '%s' "$payload" \
      | jq --argjson c "$commits" --arg n "$n" --arg m "$merged" \
           '. + [{number: ($n | tonumber), mergedAt: $m, commits: $c}]')" \
      || die "failed to assemble payload for $REPO#$n"
  done <<EOF
$heads
EOF
fi

# Apply the window uniformly. The gh path already filtered on it, but --input did not, and a flag
# documented as a window that silently does nothing on one seam is worse than no flag: it makes a
# fixture look windowed when it is not.
if [ -n "$cutoff" ]; then
  payload="$(printf '%s' "$payload" | jq --arg c "$cutoff" '[ .[] | select((.mergedAt // "") >= $c) ]')" \
    || die "failed to apply the ${DAYS}-day window"
fi

# Normalise ordering here rather than trusting the caller: an --input fixture in any order, and the
# gh path alike, must be judged on the genuinely newest releases.
payload="$(printf '%s' "$payload" | jq 'sort_by(.mergedAt // "") | reverse')" \
  || die "failed to order candidates"

candidates="$(printf '%s' "$payload" | jq 'length')" || die "failed to count candidates"

# ---------------------------------------------------------------------------
# 3. Compare the most recent releases, and report.
# ---------------------------------------------------------------------------
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

say "classifier      : $CLASSIFIER"
say "pinned identity : author=$PIN_AUTHOR_NAME <$PIN_AUTHOR_EMAIL> login=[$PIN_AUTHOR_LOGIN] committer=$PIN_COMMITTER_NAME"
if [ -n "$cutoff" ]; then
  say "window          : merged since $cutoff (${DAYS}d)"
else
  say "window          : all available merged PRs"
fi
say "candidates      : $candidates release PR(s); judging the newest $RECENT"
say ""

if [ "$candidates" -eq 0 ]; then
  printf '%s: UNKNOWN — no candidate release PR found. This is NOT a clean result: the pin may be\n' "$PROG" >&2
  printf '%s: stale and simply unobservable (a quiet release train, or a renamed branch shape).\n' "$PROG" >&2
  printf '%s: Widen --days or re-point the candidate shape before concluding anything.\n' "$PROG" >&2
  exit 2
fi

recent="$(printf '%s' "$payload" | jq --argjson k "$RECENT" '.[0:$k]')" || die "failed to select recent candidates"

matching="$(printf '%s' "$recent" | jq \
  --arg al "$PIN_AUTHOR_LOGIN" --arg an "$PIN_AUTHOR_NAME" --arg ae "$PIN_AUTHOR_EMAIL" \
  --arg cl "$PIN_COMMITTER_LOGIN" --arg cn "$PIN_COMMITTER_NAME" --arg ce "$PIN_COMMITTER_EMAIL" '
  [ .[] | select(
      [ .commits[] | select(
          .author_login == $al and .author_name == $an and .author_email == $ae and
          .committer_login == $cl and .committer_name == $cn and .committer_email == $ce
        ) ] | length > 0
    ) ] | length')" || die "failed to compare identities"

judged="$(printf '%s' "$recent" | jq 'length')" || die "failed to count judged candidates"

if [ "$matching" -gt 0 ]; then
  say "CURRENT — $matching of the newest $judged release PR(s) carry the pinned identity."
  exit 0
fi

say "DRIFT — 0 of the newest $judged release PR(s) carry the pinned identity."
say ""
say "newest releases and what they actually carry:"
printf '%s' "$recent" | jq -r '.[] | "  #\(.number) merged \(.mergedAt // "?")"'
say ""
say "observed identities:"
printf '%s' "$recent" | jq -r '
  [ .[] | .commits[]
    | "  author=\(.author_name) <\(.author_email)> login=[\(.author_login)] committer=\(.committer_name) login=[\(.committer_login)]" ]
  | unique | .[]'
say ""
say "The exemption arm is unreachable for every genuine release PR while this stands."
exit 1
