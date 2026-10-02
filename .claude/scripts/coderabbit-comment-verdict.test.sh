#!/usr/bin/env bash
# coderabbit-comment-verdict.test.sh — behavioural proof for coderabbit-comment-verdict.sh
# (monorepo#3008). The real-comment fixtures pin the shapes CodeRabbit actually produced; the
# synthetic cases pin each protection, and every negative case asserts its exact reason so a case
# cannot pass by failing for the wrong cause.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tool="${here}/coderabbit-comment-verdict.sh"
fixtures="${here}/fixtures"
head="0123456789abcdef0123456789abcdef01234567"
other="89abcdef0123456789abcdef0123456789abcdef"
reply_marker='<!-- This is an auto-generated reply by CodeRabbit -->'

tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -e abort inside an EXIT trap as exit 0, so require completion.
on_exit() {
  local status=$?
  rm -rf "${tmp}"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then exit 1; fi
}
trap on_exit EXIT
failures=0
checks=0

fixture() { # fixture <name> -> prints the body, failing when missing or empty
  local f="${fixtures}/$1"
  [ -s "${f}" ] || { echo "FAIL fixture missing or empty: ${f}" >&2; exit 1; }
  cat "${f}"
}

payload() { # payload <body> [head] [author]
  jq -n --arg body "$1" --arg head "${2:-${head}}" --arg author "${3:-coderabbitai[bot]}" \
    '{head:$head, author:$author, body:$body}'
}

expect() { # expect <name> <want-rc> <want-line> <payload>
  checks=$((checks + 1))
  set +e
  got="$(printf '%s' "$4" | bash "${tool}" --input - 2>"${tmp}/stderr")"
  rc=$?
  set -e
  if [ "${rc}" != "$2" ] || [ "${got}" != "$3" ]; then
    echo "FAIL $1: want rc=$2 '$3', got rc=${rc} '${got}' ($(cat "${tmp}/stderr"))" >&2
    failures=$((failures + 1))
  else
    echo "ok   $1"
  fi
}

reply() { # reply <prose...> -> a CodeRabbit reply body
  printf '%s\n' "${reply_marker}" "$@"
}

# --- Real comments, at the heads they reviewed -------------------------------------------------
h3316="ed7bb238485ce8f395a54841d80ec5db70558617"
h2998="c615dfa69a41c204216ac87fb497794a79553afa"
h6930="a333b570d11d9b6aa6118dda7d01665233f59bfe"
b6930="74e55d72cbfabe967fd5bab00c618f241d33e316"
h3051="992a93caecd1e5a2babe7a6613e467253c2a7cdb"
c3316="$(fixture coderabbit-comment-i-reviewed-3316.txt)"
c2998="$(fixture coderabbit-comment-tail-verdict-2998.txt)"
c6930="$(fixture coderabbit-comment-full-review-6930.txt)"
c3051="$(fixture coderabbit-comment-no-sha-3051.txt)"

expect "platform#3316 'I reviewed <sha>' + 'I found no actionable issues'" 0 GREEN "$(payload "${c3316}" "${h3316}")"
expect "monorepo#2998 verdict at the tail, sha on the opening line" 0 GREEN "$(payload "${c2998}" "${h2998}")"
expect "ksail#6930 'Full review is complete for <sha> against <base>'" 0 GREEN "$(payload "${c6930}" "${h6930}")"
expect "ksail#6930 judged at its BASE sha is another head" 1 "NONE other-head" "$(payload "${c6930}" "${b6930}")"
expect "platform#3316 judged at a later head is stale" 1 "NONE other-head" "$(payload "${c3316}" "${other}")"
expect "platform#3051 verdict naming no sha is never a green" 1 "NONE no-sha" "$(payload "${c3051}" "${h3051}")"

# --- Wording family: the structure decides, not the sentence ----------------------------------
for pair in \
  "I reviewed \`${head}\`.|I found no actionable issues." \
  "I reviewed exact head \`${head}\`.|I found no actionable issues." \
  "Reviewed exact head \`${head}\`.|No findings." \
  "Reviewed \`${head}\`.|No new findings." \
  "I completed a static review at \`${head}\`.|I found no new correctness issue." \
  "I reviewed \`${head}\`.|I found no blocking issue in this revision." \
  "Reviewed pull request \`#42\` at \`${head:0:8}\`.|I found no actionable issues."; do
  opening="${pair%%|*}"
  verdict_line="${pair#*|}"
  expect "wording: ${opening%% \`*} … / ${verdict_line}" 0 GREEN \
    "$(payload "$(reply "\`@devantler\` ${opening}" "" "${verdict_line}")")"
done
expect "verdict on the same line as the opening" 0 GREEN \
  "$(payload "$(reply "\`@devantler\` Reviewed \`${head}\`. No findings.")")"

# --- Protections -------------------------------------------------------------------------------
expect "spoofed author with the same body" 1 "NONE not-coderabbit" \
  "$(payload "$(reply "I reviewed \`${head}\`." "" "No findings.")" "${head}" "devantler")"
expect "summary comment is not a reply (its own helper judges it)" 1 "NONE not-a-reply" \
  "$(payload "$(printf '%s\n' '<!-- This is an auto-generated comment: summarize by coderabbit.ai -->' "I reviewed \`${head}\`." 'No findings.')")"
expect "acknowledgement shell carries no verdict" 1 "NONE no-verdict" \
  "$(payload "$(reply '<!-- CodeRabbit review command invocation: v2:abc -->' '✅ Action performed' '' 'Review finished.')")"
expect "rate-limit marker blocks the green" 1 "NONE did-not-run" \
  "$(payload "$(reply "I reviewed \`${head}\`." "" "No findings." "<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->")")"
expect "service shell heading blocks the green" 1 "NONE did-not-run" \
  "$(payload "$(reply "## Review failed" "I reviewed \`${head}\`." "" "No findings.")")"
expect "a P1 heading elsewhere blocks the green" 1 "NONE finding-markers" \
  "$(payload "$(reply "I reviewed \`${head}\`." "" "### P1: Do not accept non-literal conditions" "" "No findings.")")"
expect "a bold P2 marker blocks the green" 1 "NONE finding-markers" \
  "$(payload "$(reply "I reviewed \`${head}\`." "" "**P2 — stale cache key**" "" "I found no blocking issues.")")"
expect "a qualified verdict is not finding-free" 1 "NONE no-verdict" \
  "$(payload "$(reply "I reviewed \`${head}\`." "" "I found no issues except one.")")"
expect "a verdict with a trailing clause is not standalone" 1 "NONE no-verdict" \
  "$(payload "$(reply "I reviewed \`${head}\`." "" "I found no actionable issues, but see below.")")"
expect "a verdict inside a code fence does not count" 1 "NONE no-verdict" \
  "$(payload "$(reply "I reviewed \`${head}\`." '```' 'No findings.' '```')")"
expect "a verdict inside the analysis chain does not count" 1 "NONE no-verdict" \
  "$(payload "$(reply "I reviewed \`${head}\`." '<details>' '<summary>🧩 Analysis chain</summary>' '' 'No findings.' '</details>')")"
expect "a quoted verdict does not count" 1 "NONE no-verdict" \
  "$(payload "$(reply "I reviewed \`${head}\`." "" "> No findings.")")"
expect "a sha only inside the analysis chain does not bind" 1 "NONE no-sha" \
  "$(payload "$(reply '<details>' "git rev-parse \`${head}\`" '</details>' '' 'No findings.')")"
expect "the FIRST sha by POSITION binds: a bare reviewed sha before a backticked comparison sha" 1 "NONE other-head" \
  "$(payload "$(reply "I reviewed ${other} against \`${head:0:8}\`." "" "No findings.")")"
expect "a chat reply that only names the head is not a review" 1 "NONE not-a-review" \
  "$(payload "$(reply "At head \`${head:0:8}\`." "" "No findings.")")"
expect "a negated review claim is not a review" 1 "NONE not-a-review" \
  "$(payload "$(reply "I could not review \`${head}\` yet." "" "No findings.")")"
expect "a deferred review claim is not a review" 1 "NONE not-a-review" \
  "$(payload "$(reply "I will review \`${head}\` next." "" "No findings.")")"
expect "a six-character prefix is too short to be a sha" 1 "NONE no-sha" \
  "$(payload "$(reply "I reviewed \`${head:0:6}\`." "" "No findings.")")"
expect "a bare 40-character sha binds" 0 GREEN \
  "$(payload "$(reply "I reviewed ${head}." "" "No findings.")")"

# --- Input contract ----------------------------------------------------------------------------
expect "abbreviated head is refused" 2 "" "$(payload "$(reply 'No findings.')" "${head:0:12}")"
expect "unknown key is refused" 2 "" '{"head":"'"${head}"'","author":"coderabbitai[bot]","body":"x","commit_id":"y"}'
checks=$((checks + 1))
set +e
bash "${tool}" --head "${head}" </dev/null >/dev/null 2>&1
rc=$?
set -e
if [ "${rc}" = 2 ]; then echo "ok   usage error exits 2"; else
  echo "FAIL usage error: want rc=2, got ${rc}" >&2
  failures=$((failures + 1))
fi

completed=1
echo "${checks} checks, ${failures} failures"
[ "${failures}" -eq 0 ]
