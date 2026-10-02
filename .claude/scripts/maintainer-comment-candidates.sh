#!/usr/bin/env bash
#
# maintainer-comment-candidates.sh
#
# Turns ONE comment payload into finished maintainer-comment digest rows (monorepo#3163).
#
# The surveyor's maintainer-comment sweep used to compose each CANDIDATE-MAINTAINER-* row by
# hand, from the number of the artifact it was looping over plus the comment it was reading.
# Those came apart on 2026-09-02: a real undisclosed comment on platform#3275 was reported
# under platform#3239, whose comments are all disclosed, so the orchestrator checked the named
# issue, found nothing, and the finding was discarded while looking verified.
#
# Here every row's repository, number, issue-or-PR class and permalink are parsed from the
# comment's OWN url, and a record whose parent URL disagrees with it makes the whole payload
# UNKNOWN. The disclosure gate is comment-disclosure-drift's own Classify, so the sweep and
# the drift guard cannot disagree on what is disclosed or what is a sibling's sender marker.
#
# Usage (the surveyor pipes a read in; the guard admits exactly `--input -`):
#   gh issue view <n> --repo devantler-tech/<repo> --json comments | maintainer-comment-candidates.sh --input -
#   maintainer-comment-candidates.sh --input <file>
#
# Accepts a `gh issue|pr view --json comments` object or the REST comment, review or inline
# review-comment arrays (several pages concatenated, as `gh api --paginate` emits them).
#
# Output: one row per candidate, then ONE closing line that proves the read was complete:
#   CANDIDATE-MAINTAINER-ISSUE-COMMENT <repo> #<n> — `devantler` @<created>: "<first line>" <permalink>
#   CANDIDATE-SIBLING-ISSUE-COMMENT <repo> #<n> (missing disclosure) — … (…-COMMENT on a PR)
#   CANDIDATE-SCAN author=devantler records=… considered=… disclosed=… maintainer=… sibling=… empty=… artifacts=<repo>#<n>,…|none
#
# Exit codes:
#   0  classified (zero or more rows, then the CANDIDATE-SCAN line)
#   2  UNKNOWN — usage, an unreadable or empty payload, or a comment whose author or artifact
#      cannot be established. Nothing is printed on stdout, so no partial answer survives.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The canonical fail-closed trap (cleanup-trap-fail-closed.test.sh): bash 3.2 hands an EXIT trap
# a zero status for a `set -u` abort, so reaching the last line is the only way 0 leaves here.
guard_binary=""
candidates_finished=0
# shellcheck disable=SC2317,SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  local rc=$?
  [ -z "${guard_binary}" ] || rm -f -- "${guard_binary}"
  if [ "${candidates_finished}" != 1 ] && [ "${rc}" -eq 0 ]; then
    echo "maintainer-comment-candidates: aborted before finishing; reporting UNKNOWN" >&2
    rc=2
  fi
  exit "${rc}"
}
trap cleanup EXIT

die() {
  echo "maintainer-comment-candidates: $1" >&2
  exit 2
}

input=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input)
      [ $# -ge 2 ] || die "--input needs a value"
      [ -z "${input}" ] || die "--input may be given only once"
      input="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '3,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      candidates_finished=1
      exit 0
      ;;
    *)
      die "unknown argument: $1 (the only form is --input <file>|-)"
      ;;
  esac
done
[ -n "${input}" ] || die "need --input <file>|-"
if [ "${input}" != "-" ] && [ ! -r "${input}" ]; then
  die "cannot read payload: ${input}"
fi

guard_binary="$(mktemp "${TMPDIR:-/tmp}/maintainer-comment-candidates.XXXXXX")" ||
  die "failed to allocate temporary binary"
go -C "${script_dir}/comment-disclosure-drift-go" build -o "${guard_binary}" . ||
  die "failed to build the comment-disclosure-drift Go guard"

status=0
"${guard_binary}" --candidates --author devantler --input "${input}" || status=$?
candidates_finished=1
exit "${status}"
