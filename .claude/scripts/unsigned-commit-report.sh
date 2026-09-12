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
#       unsigned -- findings are annotations and a summary line, never a failure. Author and head
#       repository provenance are always read from the PR API; --head-ref, when supplied, must match.
#       A head outside
#       every agent lane is SKIPPED (nothing classified, `skipped=non-agent-head` in the summary):
#       the report is scoped to agent branches and must not warn about branches it never covered.
#   unsigned-commit-report.sh --repo <owner/repo> --merged-since <YYYY-MM-DD> [--lanes a,b,c]
#       Measurement mode: sweep every PR merged since the date whose head branch is in one of the
#       lanes. Every examined PR gets a `T  <repo>#<n>  <branch>  commits=<k>  <sha…>` line so a clean
#       sweep still names what it examined.
#       A PR is lane work only when its author is the lane's exact writer identity AND its head lives in
#       this repository; a fork branch that merely LOOKS like `claude/x` is counted `foreign=`
#       and never examined. Repeating a lane in --lanes is a usage error (it would double every count).
#       lane namespaces (default: the consumer instance registry) and report incidence across them, so a fix
#       can be shown to have moved the number. Merged PRs are used rather than branches because
#       lane branches are deleted on merge and a branch sweep is blind to exactly the commits
#       that reached main.
#   unsigned-commit-report.sh --input <payload.json> [--head-ref <ref>]
#                             [--repo <owner/repo> --head-repo <owner/repo> --pr-author <login>]
#                             [--instances <trusted-registry.json>]
#       Payload mode -- what CI runs (a trusted step reads the endpoint with the token; the report then
#       runs from the BASE branch's copy of this script, without a token, behind the default-off
#       repository variable UNSIGNED_COMMIT_REPORT) and the seam for the self-test: <payload.json> is a JSON array of commit objects in the
#       REST `pulls/<n>/commits` shape (`sha`, `commit.verification.{verified,reason}`), or `-`.
#       PROVENANCE: --head-repo and --pr-author carry the pull request's own provenance into this
#       path, which is the same rule the sweep applies -- a head outside the base repository is
#       `skipped=foreign-head` and an author that is not the lane's writer identity is
#       `skipped=foreign-author`. Without them a fork PR opened from a branch merely NAMED
#       `codex/foo` is classified as agent-lane work and warned about.
#
# EXIT CODES
#   0  the report was produced (findings or not -- this is the non-blocking contract)
#   2  UNKNOWN: usage error, unreadable payload, or a failed API read. Never treat as "none found".
#
# OUTPUT
#   One line per reported commit:  <class>  <sha>  <reason>  [<branch>]
#   One summary line:               examined=<n> signed=<g> unsigned=<n> bad=<b> unverifiable=<e> head=<ref> lane=<lane>
#   A skipped report adds `skipped=<non-agent-head|foreign-head|foreign-author>`, naming which
#   The summary always states what was examined, so an empty finding list reads as "none found"
#   rather than "nothing looked". Under GitHub Actions each finding is also a `::warning::`
#   annotation and the summary is appended to the step summary.
set -euo pipefail

PROG="$(basename "$0")"
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
usage_die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

PR=""; REPO=""; INPUT=""; HEAD_REF=""; SINCE=""; LANES=""
PR_AUTHOR=""; HEAD_OWNER=""; HEAD_REPO=""
INSTANCES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../plugin-consumption/agent-instances.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || usage_die "--pr needs a number"; PR="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage_die "--repo needs owner/repo"; REPO="$2"; shift 2 ;;
    --input) [ $# -ge 2 ] || usage_die "--input needs a path"; INPUT="$2"; shift 2 ;;
    --head-ref) [ $# -ge 2 ] || usage_die "--head-ref needs a ref"; HEAD_REF="$2"; shift 2 ;;
    --pr-author) [ $# -ge 2 ] || usage_die "--pr-author needs a login"; PR_AUTHOR="$2"; shift 2 ;;
    --head-owner) [ $# -ge 2 ] || usage_die "--head-owner needs a login"; HEAD_OWNER="$2"; shift 2 ;;
    --head-repo) [ $# -ge 2 ] || usage_die "--head-repo needs owner/repo"; HEAD_REPO="$2"; shift 2 ;;
    --instances) [ $# -ge 2 ] || usage_die "--instances needs a path"; INSTANCES="$2"; shift 2 ;;
    --merged-since) [ $# -ge 2 ] || usage_die "--merged-since needs YYYY-MM-DD"; SINCE="$2"; shift 2 ;;
    --lanes) [ $# -ge 2 ] || usage_die "--lanes needs a comma-separated list"; LANES="$2"; shift 2 ;;
    -h | --help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage_die "unknown argument '$1'" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"

# The checked-in consumer registry is the authority for membership and each API's
# exact author spelling. A head prefix alone can never register a provider.
registry="$(jq -ces '
  def nonempty: type == "string" and length > 0;
  if length == 1 then .[0] else error("one registry required") end
  | select(type == "object" and .version == 1 and (.instances | type == "object" and length > 0))
  | select(.policyPublisher as $p | ($p | nonempty) and (.instances | has($p)))
  | select(all(.instances[];
      (.namespace | type == "string" and test("^[a-z][a-z0-9-]*$")) and
      (.authors | type == "object") and
      ([.authors.cli, .authors.rest, .authors.graphql, .authors.search] | all(nonempty)) and
      (.definitionAdapter | nonempty) and
      (.roles | type == "array" and length > 0 and all(nonempty))))
  | select([.instances[].namespace] | length == (unique | length))
' "$INSTANCES" 2>/dev/null)" || die "instance registry is unreadable or malformed -- UNKNOWN"
[ -n "$LANES" ] || LANES="$(printf '%s' "$registry" | jq -r '[.instances[].namespace] | join(",")')"
IFS=, read -r -a lane_list <<<"$LANES"
seen_lanes=","
for l in "${lane_list[@]}"; do
  [ -n "$l" ] || usage_die "--lanes has an empty namespace -- UNKNOWN"
  case "$seen_lanes" in *",$l,"*) usage_die "--lanes repeats '$l' -- UNKNOWN" ;; esac
  seen_lanes="${seen_lanes}${l},"
  printf '%s' "$registry" | jq -e --arg lane "$l" 'any(.instances[]; .namespace == $lane)' >/dev/null \
    || usage_die "--lanes names an unregistered namespace -- UNKNOWN"
done

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

# The lane is read from the head ref's first path segment. An empty internal
# result means no registered match; every allowed namespace, including `none`,
# remains usable. Only the rendered summary uses `none` as its no-match label.
lane_of() { # <ref>
  local ref="$1" l
  case "$ref" in */*) l="${ref%%/*}" ;; *) return 0 ;; esac
  case ",$LANES," in *",$l,"*) printf '%s' "$l" ;; *) return 0 ;; esac
}

# API spellings are not interchangeable: accepting a GraphQL App login on the
# REST surface can admit an ordinary account with the same bare name.
lane_writer_ok() { # <lane> <author-login> [rest|cli]
  printf '%s' "$registry" | jq -e --arg lane "$1" --arg author "$2" --arg surface "${3:-rest}" \
    'any(.instances[]; .namespace == $lane and .authors[$surface] == $author)' >/dev/null
}

# Per-PR provenance, the same rule the sweep applies: this pull request is lane work only when its
# head lives in the base repository AND its author is that lane's exact writer identity. The sweep
# had this from the start; the per-PR path did not, so a fork PR opened from a branch merely NAMED
# `codex/foo` was classified as agent-lane work and warned about commits from a stranger's
# repository. Absent provenance is UNKNOWN rather than trusted: the caller states it or the report
# says it could not check.
non_lane_reason() { # <lane> -> "" when this PR is lane work, else the skip reason
  local lane="$1"
  [ -n "$lane" ] || { printf 'non-agent-head'; return; }
  if [ -n "$HEAD_OWNER" ] && [ -n "$REPO" ] && [ "$HEAD_OWNER" != "${REPO%%/*}" ]; then
    printf 'foreign-head'; return
  fi
  if [ -n "$HEAD_REPO" ] && [ -n "$REPO" ] && [ "$HEAD_REPO" != "$REPO" ]; then
    printf 'foreign-head'; return
  fi
  if [ -n "$PR_AUTHOR" ] && ! lane_writer_ok "$lane" "$PR_AUTHOR"; then
    printf 'foreign-author'; return
  fi
  printf ''
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
# The endpoint lists AT MOST 250 commits per pull request whatever the pagination, so a PR past that
# cap would be examined in part while `examined=` read as the whole. Reaching the cap is UNKNOWN.
PR_COMMIT_CAP=250
acquire_pr_commits() { # <repo> <pr> <branch-label>
  # `gh api --jq` rejects jq's own `--arg`, so the pages are piped into jq instead; `--paginate`
  # emits one array per page and `.[]` walks each. `pipefail` is set, so a failed read fails here.
  local out count
  out="$(gh api "repos/$1/pulls/$2/commits" --paginate |
    jq -r --arg branch "$3" '.[] | [.sha, (.commit.verification.verified|tostring), (.commit.verification.reason // "missing"), $branch] | @tsv')" || die "could not read $1#$2 commits -- UNKNOWN"
  count="$(printf '%s' "$out" | grep -c .)" || true
  [ "$count" -lt "$PR_COMMIT_CAP" ] \
    || die "$1#$2 has $count commits, at the $PR_COMMIT_CAP-commit endpoint cap: the report would be TRUNCATED -- UNKNOWN"
  printf '%s' "$out"
}

rows=""; SKIPPED=0; SKIP_REASON=""; targets=""
if [ -n "$INPUT" ]; then
  if [ "$INPUT" = "-" ]; then payload="$(cat)" || die "could not read payload from stdin"
  else [ -r "$INPUT" ] || die "cannot read payload: $INPUT"; payload="$(cat -- "$INPUT")" || die "could not read payload: $INPUT"; fi
  printf '%s' "$payload" | jq -se 'length == 1 and (.[0] | type == "array")' >/dev/null 2>&1 || die "payload is not a JSON array (exactly one document required) -- UNKNOWN"
  rows="$(printf '%s' "$payload" | jq -r --arg branch "${HEAD_REF:-}" \
    '.[] | [(.sha // "missing"), (.commit.verification.verified // false | tostring), (.commit.verification.reason // "missing"), $branch] | @tsv')" \
    || die "could not parse payload -- UNKNOWN"
  # Identity/repository claims turn this into an authoritative PR report. Bind
  # the branch and every required provenance field before any skip or count.
  # The raw classification seam makes no identity/repository claims at all.
  if [ -n "$REPO$HEAD_OWNER$HEAD_REPO$PR_AUTHOR" ]; then
    [ -n "$HEAD_REF" ] && [ -n "$REPO" ] && [ -n "$HEAD_REPO" ] && [ -n "$PR_AUTHOR" ] \
      || die "payload has incomplete branch/repository/author provenance -- UNKNOWN"
  fi
  # A complete named head outside every agent lane, a fork head, or a non-lane
  # author is out of scope: classify nothing and state which of those it was.
  if [ -n "$HEAD_REF" ] && [ -n "$(non_lane_reason "$(lane_of "$HEAD_REF")")" ]; then
    SKIP_REASON="$(non_lane_reason "$(lane_of "$HEAD_REF")")"
    SKIPPED=1; rows=""
  else
    # CI feeds this mode the raw endpoint payload, so the 250-commit cap applies here as well.
    count="$(printf '%s' "$rows" | grep -c .)" || true
    [ "$count" -lt "$PR_COMMIT_CAP" ] \
      || die "payload has $count commits, at the $PR_COMMIT_CAP-commit endpoint cap: the report would be TRUNCATED -- UNKNOWN"
  fi
elif [ -n "$PR" ]; then
  # Fetch provenance even when a caller supplies the branch name. Only payload mode is a
  # caller-supplied fixture seam; direct mode must describe the PR the endpoint actually returned.
  metadata="$(gh api "repos/$REPO/pulls/$PR")" || die "could not read $REPO#$PR metadata -- UNKNOWN"
  printf '%s' "$metadata" | jq -se '
    length == 1 and (.[0] | type == "object" and
      ([.head.ref, .head.repo.owner.login, .head.repo.full_name, .user.login] | all(type == "string" and length > 0)))
  ' >/dev/null 2>&1 || die "$REPO#$PR has missing or malformed provenance -- UNKNOWN"
  actual_head="$(printf '%s' "$metadata" | jq -r '.head.ref')"
  [ -z "$HEAD_REF" ] || [ "$HEAD_REF" = "$actual_head" ] || die "supplied head ref differs from $REPO#$PR -- UNKNOWN"
  HEAD_REF="$actual_head"
  HEAD_OWNER="$(printf '%s' "$metadata" | jq -r '.head.repo.owner.login')"
  HEAD_REPO="$(printf '%s' "$metadata" | jq -r '.head.repo.full_name')"
  PR_AUTHOR="$(printf '%s' "$metadata" | jq -r '.user.login')"
  SKIP_REASON="$(non_lane_reason "$(lane_of "$HEAD_REF")")"
  if [ -n "$SKIP_REASON" ]; then SKIPPED=1
  else rows="$(acquire_pr_commits "$REPO" "$PR" "$HEAD_REF")" || exit 2; fi
else
  # Measurement mode. One search per lane keeps the query agent-constructed and the branch
  # attribution exact; `--limit` is explicit because gh defaults to 30 and would silently truncate.
  # The cap is still a cap: a lane with MORE merged PRs than it in the window would be analysed
  # only in part while the summary read as a complete sweep, so reaching it is UNKNOWN, never a
  # smaller number presented as the whole -- narrow `--merged-since` or `--lanes` and re-run.
  LANE_PR_LIMIT=1000
  prs=""; foreign=0
  for l in "${lane_list[@]}"; do
    [ -n "$l" ] || continue
    chunk="$(gh pr list --repo "$REPO" --state merged --limit "$LANE_PR_LIMIT" --search "merged:>=$SINCE head:$l/" \
      --json number,headRefName,author,isCrossRepository \
      --jq '.[] | [.number, .headRefName, (.author.login // ""), (.isCrossRepository | tostring)] | @tsv')" \
      || die "could not list merged $l/* PRs in $REPO -- UNKNOWN"
    # Foreign-provenance results consume the same search limit. Check the raw listing before
    # filtering, or a capped search with even one foreign result could look complete.
    lane_count="$(printf '%s' "$chunk" | grep -c .)" || true
    [ "$lane_count" -lt "$LANE_PR_LIMIT" ] \
      || die "lane $l/* has $lane_count merged PRs since $SINCE, at the $LANE_PR_LIMIT-PR cap: the sweep would be TRUNCATED -- UNKNOWN; narrow --merged-since or --lanes"
    # `head:<lane>/` matches branch NAMES, and names are not owned across forks: a stranger's `claude/x`
    # on a fork is not lane work. Provenance is the lane's exact writer identity on a head that lives in
    # this repository; anything else is counted `foreign=` and never examined.
    own=""
    while IFS=$'\t' read -r pn pbranch pauthor pcross; do
      [ -n "$pn" ] || continue
      if [ -z "$pauthor" ] || { [ "$pcross" != true ] && [ "$pcross" != false ]; }; then
        die "merged PR has missing or malformed provenance -- UNKNOWN"
      fi
      if [ "$pcross" = false ] && [ "$(lane_of "$pbranch")" = "$l" ] && lane_writer_ok "$l" "$pauthor" cli; then
        own="${own}${pn}"$'\t'"${pbranch}"$'\n'
      else
        foreign=$((foreign + 1))
      fi
    done <<<"$chunk"
    chunk="$own"
    prs="${prs}${chunk}"$'\n'
  done
  count=0
  while IFS=$'\t' read -r n branch; do
    [ -n "$n" ] || continue
    chunk="$(acquire_pr_commits "$REPO" "$n" "$branch")" || exit 2
    rows="${rows}${chunk}"$'\n'
    count=$((count + 1))
    # Name the target: a clean sweep that identifies neither the PRs nor the SHAs it examined cannot
    # be audited, so every PR gets a T line whatever its verdict.
    k="$(printf '%s' "$chunk" | grep -c .)" || true
    shas="$(printf '%s\n' "$chunk" | awk -F'\t' 'NF { printf "%s%s", (seen++ ? " " : ""), substr($1, 1, 10) }')"
    targets="${targets}$(printf 'T  %s#%s  %s  commits=%s  %s' "$REPO" "$n" "$branch" "$k" "$shas")"$'\n'
  done <<<"$prs"
  HEAD_REF="merged-since:$SINCE prs=$count foreign=$foreign lanes=$LANES"
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

[ -z "$targets" ] || printf '%s' "$targets"
[ -z "$findings" ] || printf '%s' "$findings"
if [ -n "$SINCE" ]; then lane="sweep"; else lane="$(lane_of "${HEAD_REF:-}")"; lane="${lane:-none}"; fi
skip_note=""; [ "$SKIPPED" = 1 ] && skip_note=" skipped=${SKIP_REASON:-non-agent-head}"
summary="$(printf 'examined=%d signed=%d unsigned=%d bad=%d unverifiable=%d head=%s lane=%s%s' \
  "$examined" "$g" "$n" "$b" "$e" "${HEAD_REF:-unknown}" "$lane" "$skip_note")"
printf '%s\n' "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Unsigned-commit report (non-blocking, monorepo#3212)\n\n'
    printf '`%s`\n\n' "$summary"
    if [ -n "$findings" ]; then
      printf '| class | sha | reason | branch |\n|---|---|---|---|\n'
      printf '%s' "$findings" | awk '{ printf "| %s | `%s` | %s | %s |\n", $1, substr($2,1,10), $3, $4 }'
    elif [ "$SKIPPED" = 1 ]; then
      case "${SKIP_REASON:-non-agent-head}" in
        foreign-head)
          printf 'Skipped: the head of this pull request lives outside `%s`, so its commits are not agent-lane work and nothing was classified.\n' "$REPO" ;;
        foreign-author)
          printf 'Skipped: `%s` is not the writer identity of the `%s` lane, so nothing was classified.\n' "$PR_AUTHOR" "$(lane_of "${HEAD_REF:-}")" ;;
        *)
          printf 'Skipped: `%s` is not an agent-lane head (%s), so nothing was classified.\n' "${HEAD_REF:-}" "$LANES" ;;
      esac
    else
      printf 'No unsigned or unverifiable commits among the %d examined.\n' "$examined"
    fi
    if [ -n "$targets" ]; then
      printf '\n| target | branch | commits | examined |\n|---|---|---|---|\n'
      printf '%s' "$targets" | awk '{ b = $4; sub(/^commits=/, "", b); rest = ""; for (i = 5; i <= NF; i++) rest = rest (i > 5 ? " " : "") $i; printf "| %s | %s | %s | `%s` |\n", $2, $3, b, rest }'
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi
exit 0
