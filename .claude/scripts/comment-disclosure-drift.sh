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
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

input=""
repo=""
issue=""
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

if [ -n "$input" ] && { [ -n "$repo" ] || [ -n "$issue" ]; }; then
  die "--input is mutually exclusive with --repo/--issue"
fi
if [ -z "$input" ]; then
  [ -n "$repo" ] || die "either --input or --repo plus --issue is required"
  [ -n "$issue" ] || die "--repo also needs --issue (or --pr)"
  case "$repo" in
    */*) : ;;
    *) die "--repo must be <owner>/<repo>, got: $repo" ;;
  esac
  case "$issue" in
    '' | *[!0-9]*) die "--issue must be a number, got: $issue" ;;
    *) : ;;
  esac
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
if ! gh api "repos/${repo}/issues/${issue}/comments" --paginate >"$payload"; then
  die "gh could not read repos/${repo}/issues/${issue}/comments"
fi
if [ ! -s "$payload" ]; then
  die "gh returned an empty payload for repos/${repo}/issues/${issue}/comments"
fi

"$guard_binary" --author "$author" "${pass_through[@]+"${pass_through[@]}"}" --input "$payload"
