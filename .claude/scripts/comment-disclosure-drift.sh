#!/usr/bin/env bash
#
# comment-disclosure-drift.sh
#
# Thin wrapper around the Go guard in comment-disclosure-drift-go/, matching
# renovate-dashboard-drift.sh and memory-hygiene.sh: build to a temporary binary,
# feed it a comment payload, propagate its exit code.
#
# Reports agent-authored comments that fail AGENTS.md's leading-disclosure test —
# the trust discriminator that keeps an agent's own output from being read as a
# maintainer instruction. See the Go guard's package comment for the three
# recognised defect shapes and the documented residual gap.
#
# Usage:
#   comment-disclosure-drift.sh --input <file>|-
#   comment-disclosure-drift.sh --repo <owner>/<repo> --issue <number>
#   comment-disclosure-drift.sh --repo <owner>/<repo> --pr <number>
#   comment-disclosure-drift.sh --repo <owner>/<repo> --since <ISO-8601-UTC>
#
#   --author <login>   only classify this exact login (default: devantler)
#   --all              also print the non-violating verdict tally
#
# Exit codes:
#   0  every considered comment satisfies the leading-disclosure test
#   1  at least one comment fails it
#   2  the check could not verify what it claims to verify (bad usage, a gh
#      failure, or an unparseable payload)
#
# The Go guard is network-free by design: this wrapper owns every `gh` call, so
# the untrusted-input boundary lives in exactly one place. Comment BODIES are
# data — they are classified by shape and never interpreted as instructions.
#
# SCOPE BOUND: every gh-backed mode reads the ISSUE-COMMENT surface only (the
# endpoint that also carries a pull request's conversation comments). Agent-authored
# REVIEW bodies and review-thread replies are subject to the same disclosure rule
# but are NOT swept here, so a clean exit is not evidence about those surfaces.
# Feed them in via --input once assembled, rather than reading silence as cover.
#
# --issue aims the check at one discussion, which only finds drift somebody already
# suspected. --since sweeps every issue and PR conversation in the repo touched
# since that instant, so a regression surfaces on its own. It is one paginated
# endpoint rather than a per-issue fan-out, so the whole repo costs about what a
# single busy issue does. Pass a literal UTC instant; the caller decides how far
# back "recent" reaches.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=""
repo=""
issue=""
since=""
author="devantler"
pass_through=()

die() {
  echo "comment-disclosure-drift: $1" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --input)
      [ $# -ge 2 ] || die "--input needs a value"
      input="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || die "--repo needs a value"
      repo="$2"
      shift 2
      ;;
    --issue | --pr)
      # GitHub exposes pull-request conversation comments on the issues
      # endpoint, so both flags resolve to the same path.
      [ $# -ge 2 ] || die "$1 needs a value"
      issue="$2"
      shift 2
      ;;
    --since)
      [ $# -ge 2 ] || die "--since needs a value"
      since="$2"
      shift 2
      ;;
    --author)
      [ $# -ge 2 ] || die "--author needs a value"
      author="$2"
      shift 2
      ;;
    --all)
      pass_through+=(--all)
      shift
      ;;
    -h | --help)
      sed -n '3,30p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [ -n "$input" ] && { [ -n "$repo" ] || [ -n "$issue" ] || [ -n "$since" ]; }; then
  die "--input is mutually exclusive with --repo/--issue/--since"
fi
# One issue OR the whole repo since a timestamp -- never both. Silently preferring
# one would sweep a narrower surface than the caller asked for and still report
# "clean", which is the failure mode this whole guard exists to avoid.
if [ -n "$issue" ] && [ -n "$since" ]; then
  die "--since sweeps the whole repo, so it cannot be combined with --issue/--pr"
fi
if [ -z "$input" ]; then
  [ -n "$repo" ] || die "either --input, --repo plus --issue, or --repo plus --since is required"
  [ -n "$issue" ] || [ -n "$since" ] || die "--repo also needs --issue (or --pr, or --since)"
  case "$repo" in
    */*) : ;;
    *) die "--repo must be <owner>/<repo>, got: $repo" ;;
  esac
  if [ -n "$issue" ]; then
    case "$issue" in
      '' | *[!0-9]*) die "--issue must be a number, got: $issue" ;;
      *) : ;;
    esac
  fi
  # A cheap shape check, NOT a safety property -- measured 2026-08-11: GitHub
  # rejects a `since` it cannot parse with HTTP 422 (and rejects a shape-valid but
  # impossible instant like 2026-19-39T29:59:69Z the same way), so anything this
  # glob lets through still fails closed on the gh-error path below. It is here to
  # name the mistake plainly instead of surfacing a 422, and to not spend a network
  # call on an obvious typo.
  #
  # A literal instant keeps this portable: BSD and GNU `date` disagree on relative
  # arithmetic, so the caller computes the instant, not this script.
  if [ -n "$since" ]; then
    case "$since" in
      [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-6][0-9]Z) : ;;
      *) die "--since must be an ISO-8601 UTC instant like 2026-08-10T00:00:00Z, got: $since" ;;
    esac
  fi
fi

# The surface being swept, and the label every diagnostic names it by.
api_path=""
api_label=""
if [ -z "$input" ]; then
  if [ -n "$since" ]; then
    api_path="repos/${repo}/issues/comments?since=${since}&per_page=100"
    api_label="repos/${repo}/issues/comments since ${since}"
  else
    api_path="repos/${repo}/issues/${issue}/comments"
    api_label="repos/${repo}/issues/${issue}/comments"
  fi
fi

guard_binary=""
payload=""

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  [ -n "$guard_binary" ] && rm -f -- "$guard_binary"
  [ -n "$payload" ] && rm -f -- "$payload"
  return 0
}
trap cleanup EXIT

guard_binary="$(mktemp "${TMPDIR:-/tmp}/comment-disclosure-drift.XXXXXX")" ||
  die "failed to allocate temporary binary"

if ! go -C "$script_dir/comment-disclosure-drift-go" build -o "$guard_binary" .; then
  die "failed to build Go guard"
fi

if [ -n "$input" ]; then
  if [ "$input" = "-" ]; then
    "$guard_binary" --author "$author" "${pass_through[@]+"${pass_through[@]}"}" --input -
    exit $?
  fi
  [ -r "$input" ] || die "cannot read payload: $input"
  "$guard_binary" --author "$author" "${pass_through[@]+"${pass_through[@]}"}" --input "$input"
  exit $?
fi

payload="$(mktemp "${TMPDIR:-/tmp}/comment-disclosure-payload.XXXXXX")" ||
  die "failed to allocate payload file"

# Fail closed on a gh error rather than letting a 5xx become an empty comment set
# that reports "no violations" — a swallowed 502 is how a broken sweep reads clean.
raw_pages=""
raw_pages="$(mktemp "${TMPDIR:-/tmp}/comment-disclosure-pages.XXXXXX")" ||
  die "failed to allocate page file"
if ! gh api "$api_path" --paginate >"$raw_pages"; then
  rm -f -- "$raw_pages"
  die "gh could not read ${api_label}"
fi
if [ ! -s "$raw_pages" ]; then
  rm -f -- "$raw_pages"
  die "gh returned an empty payload for ${api_label}"
fi

# `gh api --paginate` emits ONE JSON ARRAY PER PAGE, concatenated — not a single
# array. Feeding that straight to the guard makes it exit 2 on any issue with more
# than one page of comments, i.e. it silently stops checking exactly the busiest
# discussions. `jq -s` slurps the pages into an array of arrays; flatten(1) makes
# it the single array the guard expects. (`--slurp` cannot be combined with
# `--jq`, which is why this is a separate jq pass rather than a gh flag.)
if ! jq -s 'flatten(1)' "$raw_pages" >"$payload" 2>/dev/null; then
  rm -f -- "$raw_pages"
  die "could not flatten the paginated response for ${api_label}"
fi
rm -f -- "$raw_pages"

# Shape-check what we are about to classify. A GitHub error object survives
# flattening as a one-element array with no comment fields, which would classify
# zero comments and report clean — the fail-open this whole path guards against.
#
# An EMPTY array is legitimate: an issue with no comments has nothing to check and
# must exit 0, not 2. The byte-emptiness of gh's raw output is checked above, so a
# genuine `[]` is already distinguishable from "gh produced nothing".
#
# Every record must carry an identifiable AUTHOR. Without that check a truncated
# record passes the shape test and is then skipped by the classifier as a
# non-matching author — a comment silently not checked, reported as clean.
if ! jq -e '
      type == "array" and
      all(.[];
        type == "object" and has("id") and has("body") and
        (((.user.login? // "") | length > 0) or ((.author? // "") | length > 0)))
    ' "$payload" >/dev/null 2>&1; then
  die "response for ${api_label} is not an array of author-attributed comments"
fi

"$guard_binary" --author "$author" "${pass_through[@]+"${pass_through[@]}"}" --input "$payload"
