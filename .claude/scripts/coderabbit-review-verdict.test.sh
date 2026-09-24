#!/usr/bin/env bash
# The ablation phrases below are literal jq source, so nothing in them is meant to expand.
# shellcheck disable=SC2016
# coderabbit-review-verdict.test.sh — behavioural proof for coderabbit-review-verdict.sh
# (monorepo#2768). Each rule the helper encodes has a case that fails when that rule is removed,
# and the ablations at the end remove one rule at a time to prove it.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tool="${here}/coderabbit-review-verdict.sh"
fixtures="${here}/fixtures"
hint_fixture="${fixtures}/coderabbit-review-body-hint-prefix-2819.txt"
outside_fixture="${fixtures}/coderabbit-review-body-outside-diff-2748.txt"
head="0123456789abcdef0123456789abcdef01234567"
other="89abcdef0123456789abcdef0123456789abcdef"

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

for f in "${hint_fixture}" "${outside_fixture}"; do
  [ -s "${f}" ] || { echo "FAIL fixture missing or empty: ${f}" >&2; exit 1; }
done

payload() { # payload <body> [commit_id] [author]
  jq -n --arg body "$1" --arg commit "${2:-${head}}" --arg author "${3:-coderabbitai[bot]}" \
    --arg head "${head}" '{head:$head, author:$author, commit_id:$commit, body:$body}'
}

run() { # run <tool> <payload> -> sets got, rc
  set +e
  got="$(printf '%s' "$2" | bash "$1" --input - 2>"${tmp}/stderr")"
  rc=$?
  set -e
}

expect() { # expect <name> <want-rc> <want-line> <payload>
  checks=$((checks + 1))
  run "${tool}" "$4"
  if [ "${rc}" != "$2" ] || [ "${got}" != "$3" ]; then
    echo "FAIL $1: want rc=$2 '$3', got rc=${rc} '${got}' ($(cat "${tmp}/stderr"))" >&2
    failures=$((failures + 1))
  else
    echo "ok   $1"
  fi
}

hint_body="$(cat "${hint_fixture}")"
outside_body="$(cat "${outside_fixture}")"
hint_prefix="$(sed -n '1,3p' "${hint_fixture}")"
clean="${hint_prefix}

**Actionable comments posted: 0**"

# Real bodies.
expect "real review behind an agent-hint prefix counts its findings" 1 "FINDINGS 2" "$(payload "${hint_body}")"
expect "real outside-diff review is a review with a finding" 1 "FINDINGS 1" "$(payload "${outside_body}")"
expect "finding-free review behind the hint prefix is green" 0 "GREEN" "$(payload "${clean}")"

# Identity and head binds.
expect "another author is never a CodeRabbit review" 1 "NONE not-coderabbit" "$(payload "${clean}" "${head}" "coderabbitai")"
expect "a review of another head is not this head's green" 1 "NONE other-head" "$(payload "${clean}" "${other}")"

# Positive identification.
expect "an empty object is a reply container" 1 "NONE empty-container" "$(payload "")"
expect "a comment-only body is a reply container" 1 "NONE empty-container" "$(payload "${hint_prefix}")"
expect "a marker further in is not a review" 1 "NONE not-a-review" \
  "$(payload "Thanks for the update. **Actionable comments posted: 0**")"
expect "an unterminated leading comment stops the strip" 1 "NONE not-a-review" \
  "$(payload "<!-- never closed
**Actionable comments posted: 0**")"
expect "a marker whose count cannot be parsed is not a review" 1 "NONE not-a-review" \
  "$(payload "**Actionable comments posted: 2")"
expect "other CAUTION text is not the outside-diff shape" 1 "NONE not-a-review" \
  "$(payload "> [!CAUTION]
> This is a different warning.")"

# Finding sections.
expect "a nitpick section counts as findings" 1 "FINDINGS 2" "$(payload "${clean}
<details>
<summary>🧹 Nitpick comments (2)</summary><blockquote>
</blockquote></details>")"
expect "the informational section is not a finding" 0 "GREEN" "$(payload "${clean}
<details>
<summary>🔇 Additional comments (3)</summary><blockquote>
</blockquote></details>")"

# The informational section can quote changed code that contains finding-shaped summaries; those
# are data, not findings. A real finding section after it closes still counts.
quoted="${clean}
<details>
<summary>🔇 Additional comments (1)</summary><blockquote>
<details>
<summary>scripts/check.sh (1)</summary><blockquote>
<summary>🧹 Nitpick comments (2)</summary>
</blockquote></details>
</blockquote></details>"
expect "summaries quoted inside the informational section are not findings" 0 "GREEN" "$(payload "${quoted}")"
expect "a finding section after the informational section still counts" 1 "FINDINGS 4" "$(payload "${quoted}
<details>
<summary>🧹 Nitpick comments (4)</summary><blockquote>
</blockquote></details>")"

# Leading HTML comments are metadata: a section-shaped string inside one is not a finding.
metadata_section="<!-- <summary>Nitpick comments (2)</summary> -->
${clean}"
expect "a summary inside a leading comment is not a finding" 0 "GREEN" "$(payload "${metadata_section}")"
# jq's index/1 returns a byte offset on multibyte text, so a strip built on it cuts a leading
# comment carrying an emoji in the wrong place and loses the marker behind it.
multibyte_comment="<!-- 🤖 agent hint -->
${clean}"
expect "a leading comment with multibyte text is still stripped" 0 "GREEN" "$(payload "${multibyte_comment}")"

# Quoted code inside the informational section can carry an unmatched literal <details>. The skip
# then never closes and would hide the real finding section after it, so the walk fails closed.
unbalanced="${clean}
<details>
<summary>🔇 Additional comments (1)</summary><blockquote>
The template opens a <details> block here without closing it.
</blockquote></details>
<details>
<summary>🧹 Nitpick comments (2)</summary><blockquote>
</blockquote></details>"
expect "an unmatched quoted tag never reads green" 1 "NONE unbalanced-sections" "$(payload "${unbalanced}")"
# A quoted close-then-open takes the depth below zero and back, so the final depth alone reads
# balanced. A walk that ever underflows is unbalanced.
underflow="${clean}
The template closes a </details> and reopens a <details> here."
expect "a walk that dips below zero never reads green" 1 "NONE unbalanced-sections" "$(payload "${underflow}")"

expect "only the exact informational title is excluded" 1 "FINDINGS 2" "$(payload "${clean}
<summary>🔇 Security comments (2)</summary>")"

# Did-not-run marker: blocks the green, never discards a finding.
expect "a service-shell heading blocks the green" 1 "NONE did-not-run" \
  "$(payload "${clean}
> ## Review limit reached")"
expect "review prose quoting a service phrase is still green" 0 "GREEN" \
  "$(payload "${clean}
<summary>🔇 Additional comments (1)</summary>
The retry path logs Review failed when the upstream call errors.")"
expect "a did-not-run marker blocks the green" 1 "NONE did-not-run" \
  "$(payload "${clean}
<!-- rate limited by coderabbit.ai -->")"
expect "a did-not-run marker keeps the findings" 1 "FINDINGS 3" \
  "$(payload "${hint_prefix}

**Actionable comments posted: 3**
<!-- rate limited by coderabbit.ai -->")"

# Malformed input judges nothing.
for bad in '{}' '{"head":"x","author":"a","commit_id":"y","body":""}' \
  "{\"head\":\"${head}\",\"author\":\"a\",\"commit_id\":\"${head}\"}" \
  "{\"head\":\"${head}\",\"author\":\"a\",\"commit_id\":\"${head}\",\"body\":\"\",\"extra\":1}" \
  "{\"head\":\"$(tr a-f A-F <<<"${head}")\",\"author\":\"a\",\"commit_id\":\"${head}\",\"body\":\"\"}" \
  'not json'; do
  expect "malformed input is refused: ${bad:0:40}" 2 "" "${bad}"
done
checks=$((checks + 1))
if bash "${tool}" </dev/null >/dev/null 2>&1; then
  echo "FAIL a call without --input - must be refused" >&2
  failures=$((failures + 1))
else
  echo "ok   a call without --input - is refused"
fi

# Ablations: remove one rule at a time and prove the case that pins it now fails. Each pinned
# phrase must occur exactly once, or the ablation would edit the wrong place or nothing at all.
ablate() { # ablate <name> <exact-phrase> <replacement> <payload> <want-line-with-rule>
  local phrase="$2" count
  checks=$((checks + 1))
  # Count occurrences, not matching lines: a phrase twice on one line must still fail.
  count="$( { grep -oF -- "${phrase}" "${tool}" || true; } | wc -l | tr -d " ")"
  if [ "${count}" != 1 ]; then
    echo "FAIL ablation $1: pinned phrase occurs ${count} times, want exactly 1" >&2
    failures=$((failures + 1))
    return
  fi
  PHRASE="${phrase}" REPL="$3" perl -0pe 's/\Q$ENV{PHRASE}\E/$ENV{REPL}/' "${tool}" >"${tmp}/ablated.sh"
  if cmp -s "${tool}" "${tmp}/ablated.sh"; then
    echo "FAIL ablation $1: the edit changed nothing" >&2
    failures=$((failures + 1))
    return
  fi
  run "${tmp}/ablated.sh" "$4"
  if [ "${rc}" = 2 ]; then
    echo "FAIL ablation $1: the ablated tool errored, so it proves nothing ($(cat "${tmp}/stderr"))" >&2
    failures=$((failures + 1))
  elif [ "${got}" = "$5" ]; then
    echo "FAIL ablation $1: still '${got}' without the rule, so the case does not pin it" >&2
    failures=$((failures + 1))
  else
    echo "ok   ablation $1 fires ('${got}')"
  fi
}

ablate "no leading-comment strip" '($body | strip) as $lead' '$body as $lead' \
  "$(payload "${hint_body}")" "FINDINGS 2"
ablate "sections read from the full body" '[$lead | scan("<details' '[$body | scan("<details' \
  "$(payload "${metadata_section}")" "GREEN"
ablate "comment strip by byte offset" \
  'if test("^<!--[\\s\\S]*?-->") then sub("^<!--[\\s\\S]*?-->"; "") | strip else . end' \
  'if startswith("<!--") then (index("-->")) as $i | if $i == null then . else (.[$i + 3:] | strip) end else . end' \
  "$(payload "${multibyte_comment}")" "GREEN"
ablate "no balance check" '($walk.d == 0 and $walk.skip == null and ($walk.under | not)) as $balanced' 'true as $balanced' \
  "$(payload "${unbalanced}")" "NONE unbalanced-sections"
ablate "no underflow check" ' and ($walk.under | not)) as $balanced' ') as $balanced' \
  "$(payload "${underflow}")" "NONE unbalanced-sections"
ablate "no empty-container check" 'elif ($lead | length) == 0 then "NONE empty-container"' \
  'elif false then "NONE empty-container"' "$(payload "")" "NONE empty-container"
ablate "unanchored marker" 'test("^\\*\\*Actionable comments posted: [0-9]+\\*\\*")' 'test("\\*\\*Actionable comments posted: [0-9]+\\*\\*")' \
  "$(payload "Thanks. **Actionable comments posted: 0**")" "NONE not-a-review"
ablate "no outside-diff shape" ') as $outside' ' and false) as $outside' \
  "$(payload "${outside_body}")" "FINDINGS 1"
ablate "emoji-only informational exclusion" 'test("^<summary>🔇 Additional comments \\(")' 'startswith("<summary>🔇")' \
  "$(payload "${clean}
<summary>🔇 Security comments (2)</summary>")" "FINDINGS 2"
ablate "unanchored service heading" '(\\A|\\n)(> )?#+ (Review limit reached|Review failed|Review skipped)' \
  'Review limit reached|Review failed|Review skipped' \
  "$(payload "${clean}
The retry path logs Review failed when the upstream call errors.")" "GREEN"
ablate "no informational exclusion" 'elif ($t | test("^<summary>🔇 Additional comments \\(")) then' 'elif false then' \
  "$(payload "${clean}
<summary>🔇 Additional comments (3)</summary>")" "GREEN"
ablate "no skip inside the informational section" '(if .d > 0 then .skip = .d else . end)' '.' \
  "$(payload "${quoted}")" "GREEN"
ablate "no author bind" 'if .author != "coderabbitai[bot]"' 'if false' \
  "$(payload "${clean}" "${head}" "coderabbitai")" "NONE not-coderabbit"
ablate "no head bind" 'elif .commit_id != .head then' 'elif false then' \
  "$(payload "${clean}" "${other}")" "NONE other-head"
ablate "findings survive a did-not-run marker" 'elif $n > 0 then "FINDINGS \($n)"' 'elif false then "FINDINGS \($n)"' \
  "$(payload "${hint_prefix}

**Actionable comments posted: 3**
<!-- rate limited by coderabbit.ai -->")" "FINDINGS 3"

completed=1
if [ "${failures}" -gt 0 ]; then
  echo "coderabbit-review-verdict.test.sh: ${failures} of ${checks} checks FAILED" >&2
  exit 1
fi
echo "coderabbit-review-verdict.test.sh: all ${checks} checks passed"
