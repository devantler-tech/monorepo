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

# Both streams are captured into one variable, never a file: a refusal message carries the account's
# numeric user id, and a file would outlive an interrupted run. gh writes nothing to stderr on a
# successful call; if it ever does, the reply no longer parses and reads as UNKNOWN, not serving.
rc=0
reply=$(gh api graphql --hostname github.com -f query='{viewer{login}}' 2>&1) || rc=$?

# `"RATE_LIMIT` is matched as a prefix: GitHub uses both RATE_LIMIT and RATE_LIMITED as the type.
# A refusal is recognised on either stream: gh prints the errors document on stdout and its own
# one-line summary on stderr, and which of the two survives depends on the gh version.
case "$reply" in
*graphql_rate_limit* | *'"RATE_LIMIT'* | *'rate limit'* | *'Rate limit'*)
  echo "GRAPHQL=REFUSING reason=rate-limit"
  exit 1
  ;;
esac

if [ "$rc" -eq 0 ]; then
  # Serving is a whitelist: exactly one JSON object, no `errors` member at all (not merely a falsy
  # one), and a non-empty string login. Every other shape is malformed.
  if printf '%s' "$reply" | jq -e -s '
      length == 1 and (.[0] | type == "object" and (has("errors") | not)
        and (.data | type == "object") and (.data.viewer | type == "object")
        and (.data.viewer.login | type == "string" and length > 0))' >/dev/null 2>&1; then
    echo "GRAPHQL=SERVING"
    exit 0
  fi
  echo "GRAPHQL=UNKNOWN reason=malformed-reply"
  exit 2
fi

reason=failed-call
case "$reply" in
*'HTTP 5'[0-9][0-9]*) reason=server-error ;;
*'HTTP 401'* | *'HTTP 403'*) reason=auth ;;
esac
echo "GRAPHQL=UNKNOWN reason=$reason"
exit 2
