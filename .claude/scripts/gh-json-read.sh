#!/usr/bin/env bash
# gh-json-read.sh — run one `gh` JSON read and fail closed, so a rejected request can never read
# as "no results" (monorepo#2692).
#
# WHY THIS EXISTS
#   `gh` rejects a whole `--json` request when one field is unknown, and field vocabularies
#   differ per subcommand. The rejection is visible only in the exit status and on stderr, so the
#   idiom `out=$(gh … --json … 2>/dev/null)` discards both and leaves an empty string that looks
#   exactly like "nothing matched". On 2026-08-06 that form reported zero open `claude/*` PRs
#   while 108 were open. This helper keeps both discriminators: its only success is a zero exit
#   with a JSON payload on stdout.
#
# USAGE
#   gh-json-read.sh <gh arguments…>
#
#   Pass the arguments you would give `gh`, for example
#     gh-json-read.sh search prs --owner devantler-tech --state open --json number,repository
#     gh-json-read.sh api repos/devantler-tech/monorepo/pulls --paginate
#   and filter the result with `jq` afterwards. `--jq`/`-q` and `--template`/`-t` are refused,
#   because their output is not JSON and so cannot be checked.
#
# OUTPUT
#   success   gh's stdout, unchanged
#   failure   nothing on stdout; `UNKNOWN <reason>` on stderr, followed by gh's first stderr line
#
# EXIT CODES
#   0  gh exited 0 and printed JSON (`[]` is a genuine empty result)
#   2  UNKNOWN or usage error — gh failed, printed nothing, or printed something that is not JSON.
#      Never read this as zero results.
set -uo pipefail

usage() {
  sed -n '13,20p' "$0" >&2
  exit 2
}

[ "$#" -gt 0 ] || usage
for arg in "$@"; do
  case "${arg}" in
  --jq | --jq=* | -q | --template | --template=* | -t)
    echo "UNKNOWN usage: ${arg%%=*} output is not JSON; filter with jq after this helper" >&2
    exit 2
    ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  echo "UNKNOWN jq-missing" >&2
  exit 2
}

errfile="$(mktemp)" || {
  echo "UNKNOWN tempfile" >&2
  exit 2
}
trap 'rm -f "${errfile}"' EXIT

out="$(gh "$@" 2>"${errfile}")"
rc=$?

if [ "${rc}" -ne 0 ]; then
  echo "UNKNOWN gh-exit=${rc}" >&2
  head -n 1 "${errfile}" >&2
  exit 2
fi

if [ -z "${out//[[:space:]]/}" ]; then
  echo "UNKNOWN empty-output" >&2
  exit 2
fi

# `--paginate` concatenates one JSON document per page, so validate the stream, not one value.
if ! jq -e -n '[inputs] | length > 0' <<<"${out}" >/dev/null 2>&1; then
  echo "UNKNOWN not-json" >&2
  exit 2
fi

printf '%s\n' "${out}"
