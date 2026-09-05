#!/usr/bin/env bash
# unsigned-commit-report.sh — report unsigned or unverifiable commits on agent-lane branches
# WITHOUT failing the pull request (monorepo#3212).
#
# WHY THIS EXISTS
#   Roughly one agent-lane commit in eleven reaches a merged pull request without a verifiable
#   signature (monorepo#3020), and nothing anywhere emits a signal when it happens: every
#   diagnostic pass has had to rediscover the incidence by sampling commits after the fact. This
#   is that standing signal. It REPORTS and never gates -- at ~9% incidence a required check would
#   fail one PR in eleven for a condition the author cannot fix at commit time, which is the shape
#   of check this portfolio has twice recorded as "ignored, then deleted". Enforcement is a separate
#   decision (devantler-tech/.github#142) that this report exists to make measurable.
#
# WHAT IT READS
#   GitHub's own `verification` object on each commit -- the same evidence a required
#   signature rule would consult -- so the report and any future gate cannot disagree.
#
# CLASSES  (git's %G? letters, so the report reads the same way `git log --format=%G?` does)
#   G  valid signature                          -> counted, never reported
#   N  NO signature (`reason: unsigned`)         -> reported; the "signing never attempted" case
#   B  BAD signature (invalid, malformed, bad cert) -> reported; the signature is broken
#   E  UNVERIFIABLE (bad_email, unknown_key, expired_key, no_user, ...) -> reported; a signature
#      exists but GitHub cannot bind it to the committer
#   N and B/E have different causes -- #3020's own evidence is `bad_email` (class E), which is not
#   the same failure as a commit that was never signed -- so they are never summed into one number.
#
# USAGE
#   unsigned-commit-report.sh --pr <n> --repo <owner/repo> [--head-ref <ref>]
#       CI mode: read the pull request's commits and report. Exit 0 whether or not anything is
#       unsigned -- findings are annotations and a summary line, never a failure.
#   unsigned-commit-report.sh --repo <owner/repo> --merged-since <YYYY-MM-DD> [--lanes a,b,c]
#       Measurement mode: sweep every PR merged since the date whose head branch is in one of the
#       lane namespaces (default claude,codex,cursor) and report incidence across them, so a fix
#       can be shown to have moved the number. Merged PRs are used rather than branches because
#       lane branches are deleted on merge and a branch sweep is blind to exactly the commits
#       that reached main.
#   unsigned-commit-report.sh --input <payload.json> [--head-ref <ref>]
#       Hermetic mode for the self-test: <payload.json> is a JSON array of commit objects in the
#       REST `pulls/<n>/commits` shape (`sha`, `commit.verification.{verified,reason}`), or `-`.
#
# EXIT CODES
#   0  the report was produced (findings or not -- this is the non-blocking contract)
#   2  UNKNOWN: usage error, unreadable payload, or a failed API read. Never treat as "none found".
#
# OUTPUT
#   One line per reported commit:  <class>  <sha>  <reason>  [<branch>]
#   One summary line:               examined=<n> signed=<g> unsigned=<n> bad=<b> unverifiable=<e> head=<ref> lane=<lane>
#   The summary always states what was examined, so an empty finding list reads as "none found"
#   rather than "nothing looked". Under GitHub Actions each finding is also a `::warning::`
#   annotation and the summary is appended to the step summary.
set -euo pipefail

PROG="$(basename "$0")"
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
usage_die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

PR=""; REPO=""; INPUT=""; HEAD_REF=""; SINCE=""; LANES="claude,codex,cursor"
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || usage_die "--pr needs a number"; PR="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage_die "--repo needs owner/repo"; REPO="$2"; shift 2 ;;
    --input) [ $# -ge 2 ] || usage_die "--input needs a path"; INPUT="$2"; shift 2 ;;
    --head-ref) [ $# -ge 2 ] || usage_die "--head-ref needs a ref"; HEAD_REF="$2"; shift 2 ;;
    --merged-since) [ $# -ge 2 ] || usage_die "--merged-since needs YYYY-MM-DD"; SINCE="$2"; shift 2 ;;
    --lanes) [ $# -ge 2 ] || usage_die "--lanes needs a comma-separated list"; LANES="$2"; shift 2 ;;
    -h | --help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage_die "unknown argument '$1'" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"

modes=0
[ -z "$PR" ] || modes=$((modes + 1))
[ -z "$INPUT" ] || modes=$((modes + 1))
[ -z "$SINCE" ] || modes=$((modes + 1))
[ "$modes" = 1 ] || usage_die "exactly one of --pr, --input or --merged-since is required"
case "$PR" in "" | *[!0-9]*) [ -z "$PR" ] || usage_die "--pr must be a number (got '$PR')" ;; esac
case "$SINCE" in "" | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;; *) usage_die "--merged-since must be YYYY-MM-DD (got '$SINCE')" ;; esac
if [ -n "$PR" ] || [ -n "$SINCE" ]; then
  case "$REPO" in
    */*) : ;;
    *) usage_die "--repo owner/repo is required with --pr or --merged-since" ;;
  esac
  case "$REPO" in *[!A-Za-z0-9._/-]*) usage_die "--repo must match [A-Za-z0-9._/-]+ (got '$REPO')" ;; esac
  command -v gh >/dev/null 2>&1 || die "gh is required"
fi

# The lane is read from the head ref's first path segment. `none` is a real answer: the report
# runs on every PR, and stating the lane is part of stating coverage.
lane_of() { # <ref>
  local ref="$1" l
  case "$ref" in */*) l="${ref%%/*}" ;; *) l="none" ;; esac
  case ",$LANES," in *",$l,"*) printf '%s' "$l" ;; *) printf 'none' ;; esac
}

# `verification.reason` -> class letter. Only the reason is consulted: GitHub sets `verified`
# true exactly when the reason is `valid`, and the reason is what a future gate would key on.
# Anything this table does not name is class E: a reason the report has not seen is still
# "GitHub could not verify it", never a pass.
class_of() { # <reason>
  case "$1" in
    valid) printf 'G' ;;
    unsigned) printf 'N' ;;
    invalid | malformed_signature | bad_cert | unknown_signature_type | malformed_ssh_signature) printf 'B' ;;
    *) printf 'E' ;;
  esac
}

# ---------------------------------------------------------------- acquire commits
# Emits TSV: sha \t verified \t reason \t branch
acquire_pr_commits() { # <repo> <pr> <branch-label>
  # `gh api --jq` rejects jq's own `--arg`, so the pages are piped into jq instead; `--paginate`
  # emits one array per page and `.[]` walks each. `pipefail` is set, so a failed read fails here.
  gh api "repos/$1/pulls/$2/commits" --paginate |
    jq -r --arg branch "$3" '.[] | [.sha, (.commit.verification.verified|tostring), (.commit.verification.reason // "missing"), $branch] | @tsv'
}

rows=""
if [ -n "$INPUT" ]; then
  if [ "$INPUT" = "-" ]; then payload="$(cat)" || die "could not read payload from stdin"
  else [ -r "$INPUT" ] || die "cannot read payload: $INPUT"; payload="$(cat -- "$INPUT")" || die "could not read payload: $INPUT"; fi
  printf '%s' "$payload" | jq -e 'type == "array"' >/dev/null 2>&1 || die "payload is not a JSON array -- UNKNOWN"
  rows="$(printf '%s' "$payload" | jq -r --arg branch "${HEAD_REF:-}" \
    '.[] | [(.sha // "missing"), (.commit.verification.verified // false | tostring), (.commit.verification.reason // "missing"), $branch] | @tsv')" \
    || die "could not parse payload -- UNKNOWN"
elif [ -n "$PR" ]; then
  if [ -z "$HEAD_REF" ]; then
    HEAD_REF="$(gh api "repos/$REPO/pulls/$PR" --jq '.head.ref')" || die "could not read $REPO#$PR head ref -- UNKNOWN"
  fi
  rows="$(acquire_pr_commits "$REPO" "$PR" "$HEAD_REF")" || die "could not read $REPO#$PR commits -- UNKNOWN"
else
  # Measurement mode. One search per lane keeps the query agent-constructed and the branch
  # attribution exact; `--limit` is explicit because gh defaults to 30 and would silently truncate.
  # The cap is still a cap: a lane with MORE merged PRs than it in the window would be analysed
  # only in part while the summary read as a complete sweep, so reaching it is UNKNOWN, never a
  # smaller number presented as the whole -- narrow `--merged-since` or `--lanes` and re-run.
  LANE_PR_LIMIT=1000
  prs=""
  IFS=, read -r -a lane_list <<<"$LANES"
  for l in "${lane_list[@]}"; do
    [ -n "$l" ] || continue
    chunk="$(gh pr list --repo "$REPO" --state merged --limit "$LANE_PR_LIMIT" --search "merged:>=$SINCE head:$l/" \
      --json number,headRefName --jq '.[] | [.number, .headRefName] | @tsv')" \
      || die "could not list merged $l/* PRs in $REPO -- UNKNOWN"
    lane_count="$(printf '%s' "$chunk" | grep -c .)" || true
    [ "$lane_count" -lt "$LANE_PR_LIMIT" ] \
      || die "lane $l/* has $lane_count merged PRs since $SINCE, at the $LANE_PR_LIMIT-PR cap: the sweep would be TRUNCATED -- UNKNOWN; narrow --merged-since or --lanes"
    prs="${prs}${chunk}"$'\n'
  done
  count=0
  while IFS=$'\t' read -r n branch; do
    [ -n "$n" ] || continue
    chunk="$(acquire_pr_commits "$REPO" "$n" "$branch")" || die "could not read $REPO#$n commits -- UNKNOWN"
    rows="${rows}${chunk}"$'\n'
    count=$((count + 1))
  done <<<"$prs"
  HEAD_REF="merged-since:$SINCE prs=$count lanes=$LANES"
fi

# ---------------------------------------------------------------- classify and report
examined=0; g=0; n=0; b=0; e=0
findings=""
while IFS=$'\t' read -r sha _ reason branch; do
  [ -n "$sha" ] || continue
  examined=$((examined + 1))
  cls="$(class_of "$reason")"
  case "$cls" in
    G) g=$((g + 1)); continue ;;
    N) n=$((n + 1)) ;;
    B) b=$((b + 1)) ;;
    E) e=$((e + 1)) ;;
  esac
  line="$(printf '%s  %s  %s  %s' "$cls" "$sha" "$reason" "$branch")"
  findings="${findings}${line}"$'\n'
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::warning title=Unsigned or unverifiable commit (%s)::%s %s on %s\n' "$cls" "${sha:0:10}" "$reason" "$branch"
  fi
done <<<"$rows"

[ -z "$findings" ] || printf '%s' "$findings"
if [ -n "$SINCE" ]; then lane="sweep"; else lane="$(lane_of "${HEAD_REF:-}")"; fi
summary="$(printf 'examined=%d signed=%d unsigned=%d bad=%d unverifiable=%d head=%s lane=%s' \
  "$examined" "$g" "$n" "$b" "$e" "${HEAD_REF:-unknown}" "$lane")"
printf '%s\n' "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Unsigned-commit report (non-blocking, monorepo#3212)\n\n'
    printf '`%s`\n\n' "$summary"
    if [ -n "$findings" ]; then
      printf '| class | sha | reason | branch |\n|---|---|---|---|\n'
      printf '%s' "$findings" | awk '{ printf "| %s | `%s` | %s | %s |\n", $1, substr($2,1,10), $3, $4 }'
    else
      printf 'No unsigned or unverifiable commits among the %d examined.\n' "$examined"
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi
exit 0
