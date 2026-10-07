#!/usr/bin/env bash
# graphql-availability.sh — is GitHub's GraphQL surface serving right now? (monorepo#3429)
#
# WHY THIS EXISTS
#   Measured 2026-09-20: every GraphQL call was refused for about 35 minutes with a rate-limit
#   error while `gh api rate_limit` reported that same bucket as untouched (`used: 0`) and REST
#   stayed healthy. The rate-limit report is therefore NOT evidence that GraphQL is available, and
#   waiting for the reset it names is either pointless or misleading. The only honest answer comes
#   from a call that exercises the surface.
#
#   The merge preflight's unresolved-thread count is GraphQL-only, so while GraphQL refuses, no
#   pull request can be merged. The merge-policy guide names that state `GraphQL-unavailable` and
#   says what a run does in it; this helper is the probe that establishes it.
#
# WHAT IT DOES
#   One call: the cheapest authenticated GraphQL query there is (`viewer.login`), against
#   github.com explicitly so GH_HOST cannot redirect it. It never reads `rate_limit`.
#
# USAGE
#   graphql-availability.sh
#
# OUTPUT (one line on stdout) AND EXIT CODES
#   0  GRAPHQL=SERVING                    the query returned a viewer login
#   1  GRAPHQL=REFUSING reason=rate-limit the surface answered with a rate-limit refusal
#   2  GRAPHQL=UNKNOWN reason=<class>     anything else: a 5xx, an auth failure, no network, a
#                                         malformed reply, a missing tool or a usage error
#   Exit 1 and exit 2 both mean "do not rely on a GraphQL read": thread counts are UNKNOWN and no
#   merge goes ahead. They are kept apart because a refusal clears by itself, while an UNKNOWN may
#   need a diagnosis.
#
#   The raw reply is never printed: a refusal message carries the account's numeric user id.

set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "GRAPHQL=UNKNOWN reason=usage"
  echo "usage: graphql-availability.sh (takes no arguments)" >&2
  exit 2
fi
for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "GRAPHQL=UNKNOWN reason=missing-$tool"
    exit 2
  }
done

err_file=$(mktemp) || {
  echo "GRAPHQL=UNKNOWN reason=no-temp-file"
  exit 2
}
rc=0
out=$(gh api graphql --hostname github.com -f query='{viewer{login}}' 2>"$err_file") || rc=$?
err=$(cat "$err_file" 2>/dev/null || true)
rm -f "$err_file"

# A refusal is recognised on either stream: gh prints the errors document on stdout and its own
# one-line summary on stderr, and which of the two survives depends on the gh version.
both="$out
$err"
case "$both" in
*graphql_rate_limit* | *'"RATE_LIMIT"'* | *'rate limit'* | *'Rate limit'*)
  echo "GRAPHQL=REFUSING reason=rate-limit"
  exit 1
  ;;
esac

if [ "$rc" -eq 0 ]; then
  login=$(printf '%s' "$out" | jq -r '.data.viewer.login // empty' 2>/dev/null) || login=''
  if [ -n "$login" ]; then
    echo "GRAPHQL=SERVING"
    exit 0
  fi
  echo "GRAPHQL=UNKNOWN reason=malformed-reply"
  exit 2
fi

reason=failed-call
case "$err" in
*'HTTP 5'[0-9][0-9]*) reason=server-error ;;
*'HTTP 401'* | *'HTTP 403'*) reason=auth ;;
esac
echo "GRAPHQL=UNKNOWN reason=$reason"
exit 2
