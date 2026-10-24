#!/usr/bin/env bash
# Self-test for maintainer-digest.sh (monorepo#4285, ADR 0009 phase 1), against a stub gh that serves
# fixtures and records every call. One case per acceptance criterion of the issue:
#   1. a dated file present: the digest opens with that file as its body, assigned to the maintainer,
#      and closes last week's digest (and, as a dry run, changes nothing);
#   2. the file missing: the fallback lists every open ask with all four sections and says the summary
#      is missing;
#   3. an ask missing a section is reported by number and still listed;
#   4. every GitHub object read must carry the fields its kind declares, or the run is UNKNOWN;
#   5. the template and its rules forbid private content, and the check catches every marker kind.
# Plus: an ask filed after the summary still goes out, an ask showing private content is held back,
# an @mention is quieted, a digest GitHub did not assign is neither counted as sent nor closes the
# last one, the failure paths (a failed or malformed read is UNKNOWN, never an empty list), the
# workflows' triggers, permissions and pins, and the ask form.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/.claude/scripts/maintainer-digest.sh"
template="$root/docs/digests/TEMPLATE.md"
tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$tmp"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then
    echo "maintainer-digest.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    exit 1
  fi
}
trap on_exit EXIT

command -v jq >/dev/null || { echo "maintainer-digest.test.sh: jq is required" >&2; exit 1; }
command -v yq >/dev/null || { echo "maintainer-digest.test.sh: yq is required" >&2; exit 1; }

fails=0
# Reports a passing fixture assertion.
pass() { echo "  ok   $1"; }
# Records an assertion failure without stopping the remaining cases.
bad() {
  echo "  FAIL $1" >&2
  fails=$((fails + 1))
}

repo=example-org/example-repo
api="repos/$repo"
bin="$tmp/bin"
mkdir -p "$bin"
export GH_STUB_FIX="$tmp/fix" GH_STUB_LOG="$tmp/gh.log" GH_STUB_DIR="$tmp/stub"

cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
# Serves a GET from the fixture named after its path and records every call as one line. A GET with
# no fixture fails, as an unreachable API would. Writes answer with a fixture when one exists.
set -eo pipefail
# Maps an API path to the fixture filename used by this stub process.
key() { printf '%s' "$1" | tr '/?&=:' '_____'; }
[ "${1:-}" = api ] || { echo "gh stub: only gh api is expected: $*" >&2; exit 1; }
shift
method=GET path="" input="" fields=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    -X | --method) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    -f | -F) fields="$fields $2"; shift 2 ;;
    -*) echo "gh stub: unexpected flag $1" >&2; exit 1 ;;
    *) path=$1; shift ;;
  esac
done
printf '%s %s%s\n' "$method" "$path" "$fields" >>"$GH_STUB_LOG"
response="$GH_STUB_FIX/$method$(key "$path").json"
case "$method" in
  GET)
    [ -f "$response" ] || { echo "gh stub: HTTP 502 for $path" >&2; exit 1; }
    cat "$response"
    ;;
  POST)
    if [ -n "$input" ]; then cp "$input" "$GH_STUB_DIR/payload.json"; fi
    if [ -f "$response" ]; then cat "$response"; else echo '{"number": 900, "assignees": [{"login": "devantler"}]}'; fi
    ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$bin/gh"

# Uses the same path encoding as the stub when the harness writes a response fixture.
key() { printf '%s' "$1" | tr '/?&=:' '_____'; }
# Writes stdin as the response to METHOD PATH.
fixture() { cat >"$GH_STUB_FIX/$1$(key "$2").json"; }

# Clears prior fixtures, captured payloads and calls so every case observes only its own requests.
reset_case() {
  rm -rf "$GH_STUB_FIX" "$GH_STUB_DIR" "$GH_STUB_LOG"
  mkdir -p "$GH_STUB_FIX" "$GH_STUB_DIR"
  : >"$GH_STUB_LOG"
  printf '[]\n' | fixture GET "$digests_path"
  for comment_parent in 10 11 12 13 14 15 16 17 18 19 20 21 800 801 850 900; do
    printf '[]\n' | fixture GET "$api/issues/$comment_parent/comments?per_page=100"
  done
}

rc=0
# Runs the real helper against the local stub and retains stdout, stderr and exit status.
run() {
  rc=0
  env -u GITHUB_REPOSITORY PATH="$bin:$PATH" "$BASH" "$script" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
}

# Compares the helper's captured status with the status expected for this fixture.
expect_rc() {
  if [ "$rc" = "$1" ]; then pass "$2: exit $1"; else bad "$2: exit $rc, expected $1: $(cat "$tmp/err")"; fi
}
# Requires an exact text fragment in a captured file.
expect_in() {
  if grep -Fq -- "$2" "$1"; then pass "$3"; else bad "$3: '$2' is not in $(basename "$1")"; fi
}
# Rejects an exact text fragment in a captured file.
expect_not_in() {
  if grep -Fq -- "$2" "$1"; then bad "$3: '$2' is in $(basename "$1")"; else pass "$3"; fi
}
# Verifies that a preview or refusal made no mutating GitHub API call.
expect_no_writes() {
  if grep -Eq '^(POST|PATCH|DELETE) ' "$GH_STUB_LOG"; then bad "$1: a write was made: $(grep -E '^(POST|PATCH|DELETE) ' "$GH_STUB_LOG")"; else pass "$1"; fi
}
# Extracts the submitted issue body for content and privacy assertions.
posted_body() { jq -j '.body' "$GH_STUB_DIR/payload.json" | sed '/^<!-- maintainer-digest-summaries-v1: /d' >"$tmp/posted.md"; }

# An issue as the REST API lists it: number, author, title, body.
issue() {
  jq -n --argjson n "$1" --arg login "$2" --arg title "$3" --arg body "$4" '{
    number: $n, html_url: "https://github.com/example-org/example-repo/issues/\($n)", title: $title,
    body: $body, user: {login: $login}, state: "open", labels: [{name: "maintainer-ask"}], assignees: []}'
}
complete_body='> 🤖 Generated by the Agentic Engineer

### Question

Should the nightly backup keep 30 days instead of 14?

### Options

A. Keep 30 days.
B. Stay at 14 days.

### Recommendation

A, so a restore from a month back stays possible.

### If unanswered

The backup stays at 14 days.'
second_body='### Question

Shall the old status page be retired?

### Options

A. Retire it.
B. Keep it.

### Recommendation

A.

### If unanswered

It stays up.'
# The issue form writes CRLF line ends and "_No response_" for a field left empty.
incomplete_body="$(printf '### Question\r\n\r\nShall we rename the cluster?\r\n\r\n### Options\r\n\r\nA. Rename.\r\nB. Keep the name.\r\n\r\n### If unanswered\r\n\r\n_No response_\r\n')"

asks_path="$api/issues?state=open&labels=maintainer-ask&per_page=100"
digests_path="$api/issues?state=all&labels=maintainer-digest&per_page=100"

# Two pages of complete asks, as gh --paginate prints them, plus a pull request the listing returns.
complete_asks() {
  jq -s . <(issue 10 devantler "🙋 Ask: Keep 30 days of backups" "$complete_body")
  jq -s '. + [.[0] | .number = 14 | .pull_request = {}]' <(issue 11 devantler "🙋 Ask: Retire the status page" "$second_body")
}
# Last week's digest, and an issue someone else gave the digest label, which must stay open.
earlier_digests() {
  jq -n '[
    {body: "", state: "open", number: 800, title: "🙋 Maintainer digest — week 42", user: {login: "github-actions[bot]"}, assignees: [{login: "devantler"}], created_at: "2026-10-12T06:17:00Z"},
    {body: "", state: "open", number: 801, title: "Mislabelled", user: {login: "devantler"}, assignees: [], created_at: "2026-10-12T07:00:00Z"}]'
}

digests="$tmp/digests"
mkdir -p "$digests"
digest_file="$digests/2026-10-24.md"
# The week's file as its writer leaves it: Needs you as `needs-you` shows it for the asks served now.
write_digest_file() {
  run needs-you --repo "$repo"
  [ "$rc" = 0 ] || bad "needs-you failed while writing the dated file: $(cat "$tmp/err")"
  {
    printf '> 🤖 Generated by the Agentic Engineer\n\n'
    cat "$tmp/out"
    printf '\n'
    rest_of_digest_file
  } >"$digest_file"
}
# Supplies the non-ask sections of a complete, public-safe digest fixture.
rest_of_digest_file() {
  cat <<'MD'
## What shipped

### Platform

**Fixed**

- Backups now run every night. ([#5](https://github.com/example-org/example-repo/pull/5))

### Agent Improver

- The agents wait less for reviews. ([#6](https://github.com/example-org/example-repo/pull/6))

## What's in progress

- The private mail service. ([#7](https://github.com/example-org/example-repo/issues/7))

## How to reply

Reply to this email with an ask's number and your choice, for example `1: B`.
Your reply posts publicly, as a comment on this issue in the public devantler-tech/monorepo repository.
MD
}

echo "send: a dated file is present"
reset_case
complete_asks | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
write_digest_file
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "the digest opens from the dated file"
posted_body
if cmp -s "$tmp/posted.md" "$digest_file"; then pass "the issue body is exactly the dated file"; else bad "the issue body differs from the dated file"; fi
if [ "$(jq -r '.title' "$GH_STUB_DIR/payload.json")" = "🙋 Maintainer digest — 2026-10-24" ]; then
  pass "the title names the delivery date"
else
  bad "the title is $(jq -r '.title' "$GH_STUB_DIR/payload.json")"
fi
if [ "$(jq -c '[.assignees, .labels]' "$GH_STUB_DIR/payload.json")" = '[["devantler"],["maintainer-digest"]]' ]; then
  pass "the issue is assigned to the maintainer and labelled maintainer-digest"
else
  bad "the assignees and labels are $(jq -c '[.assignees, .labels]' "$GH_STUB_DIR/payload.json")"
fi
expect_in "$GH_STUB_LOG" "PATCH $api/issues/800 state=closed state_reason=completed" "last week's digest is closed"
expect_not_in "$GH_STUB_LOG" "PATCH $api/issues/801" "an issue another account labelled is never closed"
expect_in "$tmp/out" "SENT #900" "the new digest is reported"

echo "send --dry-run: a dated file is present"
reset_case
complete_asks | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-24 --dir "$digests" --dry-run
expect_rc 0 "the dry run plans the digest"
expect_no_writes "the dry run makes no write"
awk '/^--- end of body ---$/ { inside = 0 } inside { print } /^--- body ---$/ { inside = 1 }' "$tmp/out" >"$tmp/dry-body.md"
sed -i.bak '/^<!-- maintainer-digest-summaries-v1: /d' "$tmp/dry-body.md"
if cmp -s "$tmp/dry-body.md" "$digest_file"; then pass "the planned body is exactly the dated file"; else bad "the planned body differs from the dated file"; fi
expect_in "$tmp/out" "DRY-RUN would open \"🙋 Maintainer digest — 2026-10-24\", labelled maintainer-digest and assigned to devantler" "the plan names the title, label and assignee"
expect_in "$tmp/out" "DRY-RUN would close the earlier digest #800" "the plan closes last week's digest"
expect_not_in "$tmp/out" "#801" "the plan leaves another account's issue alone"

echo "send: the week file is missing"
reset_case
rm -f "$digest_file"
{
  complete_asks
  jq -s . <(issue 12 devantler "🙋 Ask: Rename the cluster" "$incomplete_body") \
    <(issue 13 someone-else "🙋 Ask: UNTRUSTED-TITLE-MARKER" "$(printf '### Question\n\nUNTRUSTED-TEXT-MARKER')")
} | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-27 --dir "$digests"
expect_rc 1 "a fallback digest is a finding"
posted_body
expect_in "$tmp/err" "FALLBACK: no pending reviewed summary is available for 2026-10-27" "the fallback is reported"
expect_in "$tmp/posted.md" "**The summary is missing for this digest:** no pending reviewed summary is available for 2026-10-27" "the fallback says the summary is missing"
expect_in "$tmp/posted.md" "### 1. Ask [#10](https://github.com/example-org/example-repo/issues/10)" "the first ask is numbered and linked"
expect_in "$tmp/posted.md" "    Keep 30 days of backups" "the ask's title is shown as code"
for text in "Should the nightly backup keep 30 days instead of 14?" "A. Keep 30 days." "B. Stay at 14 days." \
  "A, so a restore from a month back stays possible." "The backup stays at 14 days."; do
  expect_in "$tmp/posted.md" "$text" "the first ask's four sections are listed: $text"
done
for name in Question Options Recommendation "If unanswered"; do
  if [ "$(grep -c -Fx -- "**$name**" "$tmp/posted.md")" -eq 3 ]; then
    pass "every ask has its $name section"
  else
    bad "the $name section is not listed for every ask"
  fi
done
expect_in "$tmp/posted.md" "### 2. Ask [#11](https://github.com/example-org/example-repo/issues/11)" "an ask from the second page is listed"
expect_not_in "$tmp/posted.md" "#14" "a pull request is not an ask"
expect_in "$tmp/posted.md" "## How to reply" "the fallback says how to reply"
expect_in "$tmp/posted.md" "Your reply posts publicly" "the fallback says that a reply posts publicly"
expect_in "$GH_STUB_LOG" "PATCH $api/issues/800 state=closed state_reason=completed" "the fallback still closes last week's digest"

echo "send: an ask missing a section"
expect_in "$tmp/posted.md" "### 3. Ask [#12](https://github.com/example-org/example-repo/issues/12)" "the incomplete ask is still listed"
expect_in "$tmp/posted.md" "> ⚠️ #12 is missing: Recommendation, If unanswered." "the digest names what the ask is missing"
expect_in "$tmp/posted.md" "_Missing: #12 has no Recommendation section._" "the missing section is marked in place"
expect_in "$tmp/posted.md" "Shall we rename the cluster?" "a CRLF body is read"
if grep -q "$(printf '\r')" "$tmp/posted.md"; then bad "a carriage return reached the digest"; else pass "no carriage return reaches the digest"; fi
expect_in "$tmp/err" "MISSING-SECTION #12 Recommendation" "the missing Recommendation is reported by number"
expect_in "$tmp/err" "MISSING-SECTION #12 If unanswered" "an empty form field counts as missing"
expect_not_in "$tmp/err" "MISSING-SECTION #10" "a complete ask is not reported"
expect_in "$tmp/posted.md" "Asks another account filed, named here without their text: #13." "another account's ask is named by number"
expect_not_in "$tmp/posted.md" "UNTRUSTED-TEXT-MARKER" "another account's text never reaches the digest"
expect_not_in "$tmp/posted.md" "UNTRUSTED-TITLE-MARKER" "another account's title never reaches the digest"
expect_in "$tmp/err" "UNTRUSTED-ASK #13" "another account's ask is reported"

echo "needs-you"
run needs-you --repo "$repo"
expect_rc 1 "an incomplete or untrusted ask is a finding"
expect_in "$tmp/out" "### 3. Ask [#12]" "needs-you prints the same section"
reset_case
echo '[]' | fixture GET "$asks_path"
run needs-you --repo "$repo"
expect_rc 0 "no open ask is no finding"
if [ "$(cat "$tmp/out")" = "$(printf '## Needs you\n\nNothing needs you right now.')" ]; then
  pass "an empty Needs you says so in one line"
else
  bad "an empty Needs you printed: $(cat "$tmp/out")"
fi

# Asks are listed oldest first, whatever order the listing returns them in.
reset_case
{
  issue 11 devantler "🙋 Ask: Retire the status page" "$second_body"
  issue 10 devantler "🙋 Ask: Keep 30 days of backups" "$complete_body"
} | jq -s . | fixture GET "$asks_path"
run needs-you --repo "$repo"
expect_rc 0 "two complete asks are no finding"
expect_in "$tmp/out" "### 1. Ask [#10]" "the oldest ask is listed first"
expect_in "$tmp/out" "### 2. Ask [#11]" "the newer ask follows"

echo "needs-you: what an ask may put in the digest"
reset_case
# shellcheck disable=SC2016 # The backticks are literal Markdown in the fixture.
{
  jq -s . <(issue 15 devantler "🙋 Ask: Approve the new plan" \
    "$(printf '### Question\n\nApprove it?\n\n### Options\n\nA. Pay %s %s a month.\nB. Stay.\n\n### Recommendation\n\nA.\n\n### If unanswered\n\nB.' 120 kr)")
  jq -s . <(issue 16 devantler "🙋 Ask: Ping @someone-else" \
    "$(printf '### Question\n\nShall we ask `@someone-else` or @example-org/team?\n\n### Options\n\nA. Yes.\n\n### Recommendation\n\nA.\n\n### If unanswered\n\nNo.')")
} | fixture GET "$asks_path"
run needs-you --repo "$repo"
expect_rc 1 "an ask showing private content is a finding"
expect_in "$tmp/out" "### 1. Held back ([#15](https://github.com/example-org/example-repo/issues/15))" "an ask showing private content is still listed"
expect_in "$tmp/out" "> ⚠️ #15 shows private content, so its text is not repeated here." "the digest says why its text is held back"
expect_not_in "$tmp/out" "Approve" "the held-back ask's title stays out"
expect_not_in "$tmp/out" "a month" "the held-back ask's text stays out"
expect_in "$tmp/err" "private-content: money" "the private ask is reported by kind"
z=$'\xe2\x80\x8b'
expect_in "$tmp/out" "    Ping @${z}someone-else" "a mention in a title is broken with a zero-width space"
expect_in "$tmp/out" "    Shall we ask \`@${z}someone-else\` or @${z}example-org/team?" "mentions in an ask's text are broken, inside a code span too"
if grep -Eq '@(someone-else|example-org)' "$tmp/out"; then bad "a live mention reached the digest"; else pass "no live mention reaches the digest"; fi

echo "needs-you: copied ask text is shown only as code"
reset_case
# Each line is active syntax somewhere: a bot command, a closing keyword, an issue reference, HTML,
# a fence that would end a fenced block, and a heading.
active_question="$(printf '/approve\nCloses #12 and devantler/other#3\n<img src=x onerror=alert(1)>\n```\n## Not a heading\n\nhttps://example.com/x')"
jq -s . <(issue 18 devantler "🙋 Ask: Merge #12 /lgtm" \
  "$(printf '### Question\n\n%s\n\n### Options\n\nA. Yes.\n\n### Recommendation\n\nA.\n\n### If unanswered\n\nNo.' "$active_question")") |
  fixture GET "$asks_path"
run needs-you --repo "$repo"
expect_rc 0 "an ask with active syntax is shown"
expect_in "$tmp/out" "### 1. Ask [#18](https://github.com/example-org/example-repo/issues/18)" "the heading carries only text the script writes"
# Lines carrying copied active syntax, then those of them not indented as code; no pipe into grep -q.
active_lines="$(grep -nE '/approve|/lgtm|Closes #|<img|^```|Not a heading|example\.com' "$tmp/out" || true)"
unindented="$(grep -vE '^[0-9]+:    ' <<<"$active_lines" || true)"
if [ -z "$active_lines" ]; then
  bad "the active-syntax lines are missing from the digest"
elif [ -n "$unindented" ]; then
  bad "copied text reached the digest outside a code block"
else
  pass "every copied line is indented as code"
fi
next_section="$(awk '/^\*\*Question\*\*$/ { q = 1; next } q && /^\*\*Options\*\*$/ { print "ok"; exit }' "$tmp/out")"
if [ "$next_section" = ok ]; then
  pass "a fence in the text does not swallow the next section"
else
  bad "a fence in the text swallowed the next section"
fi

echo "needs-you: a partial issue object is unknown"
reset_case
issue 19 devantler "🙋 Ask: No link" "$complete_body" | jq -s 'map(del(.html_url))' | fixture GET "$asks_path"
run needs-you --repo "$repo"
expect_rc 2 "an ask without its link is unknown"
expect_not_in "$tmp/out" "null" "no literal null reaches the digest"
reset_case
issue 19 devantler "🙋 Ask: No title" "$complete_body" | jq -s 'map(del(.title))' | fixture GET "$asks_path"
run needs-you --repo "$repo"
expect_rc 2 "an ask without its title is unknown"
reset_case
issue 19 devantler "🙋 Ask: No body field" "$complete_body" | jq -s 'map(del(.body))' | fixture GET "$asks_path"
run needs-you --repo "$repo"
expect_rc 2 "an ask whose body field is missing is unknown"
reset_case
issue 19 devantler "🙋 Ask: Empty body" "" | jq -s 'map(.body = null)' | fixture GET "$asks_path"
run needs-you --repo "$repo"
expect_rc 1 "an ask with an empty (null) body is read, and its missing sections are findings"
expect_in "$tmp/err" "MISSING-SECTION #19 Question" "the empty ask is named"

echo "send: a partial digest object is unknown, and nothing is opened or closed"
for field in state created_at assignees user number title; do
  reset_case
  complete_asks | fixture GET "$asks_path"
  earlier_digests | jq --arg f "$field" '.[0] |= del(.[$f])' | fixture GET "$digests_path"
  run send --repo "$repo" --date 2026-10-24 --dir "$digests"
  expect_rc 2 "a digest listing without $field is unknown"
  expect_no_writes "a digest listing without $field opens and closes nothing"
done
for bad_value in '.created_at = "2026-10-12not-a-time"' '.created_at = "2026-02-30T06:17:00Z"' '.assignees = [{}]' '.assignees = null' '.state = "unknown"'; do
  reset_case
  complete_asks | fixture GET "$asks_path"
  earlier_digests | jq ".[0] |= ($bad_value)" | fixture GET "$digests_path"
  run send --repo "$repo" --date 2026-10-24 --dir "$digests"
  expect_rc 2 "a digest listing where $bad_value is unknown"
  expect_no_writes "a digest listing where $bad_value opens and closes nothing"
done

echo "send: an incomplete response to opening the digest closes nothing"
reset_case
complete_asks | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
write_digest_file
echo '{"number": 900}' | fixture POST "$api/issues"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 2 "a created issue without its assignees is unknown"
expect_not_in "$GH_STUB_LOG" "PATCH " "last week's digest stays open"


echo "send: a backfill of an earlier week keeps the later digest open"
reset_case
complete_asks | fixture GET "$asks_path"
jq -n '[
  {body: "", state: "open", number: 790, title: "🙋 Maintainer digest — week 40", user: {login: "github-actions[bot]"}, assignees: [], created_at: "2026-09-28T06:17:00Z"},
  {body: "", state: "open", number: 800, title: "🙋 Maintainer digest — week 42", user: {login: "github-actions[bot]"}, assignees: [], created_at: "2026-10-12T06:17:00Z"}]' |
  fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-06 --dir "$digests"
expect_rc 1 "the backfill is sent from the fallback"
expect_in "$GH_STUB_LOG" "PATCH $api/issues/790 state=closed state_reason=completed" "a digest from before the backfilled week is closed"
expect_not_in "$GH_STUB_LOG" "PATCH $api/issues/800" "the later digest stays open"

echo "send: the fallback is too long to show every ask in full"
reset_case
long_options="$(awk 'BEGIN { for (i = 0; i < 1300; i++) printf "A line of options that goes on and on to fill the digest.\n" }')"
jq -s . <(issue 17 devantler "🙋 Ask: A very long ask" "$(printf '### Question\n\nWhich?\n\n### Options\n\n%s\n\n### Recommendation\n\nA.\n\n### If unanswered\n\nB.' "$long_options")") |
  fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-27 --dir "$digests"
expect_rc 1 "the shortened fallback is a finding"
posted_body
expect_in "$tmp/posted.md" "_The asks are too long to show in full here, so open each one to read it._" "the shortened fallback says why"
expect_in "$tmp/posted.md" "- 1. Ask [#17](https://github.com/example-org/example-repo/issues/17)" "every ask is still listed by number and link"
if [ "$(wc -c <"$tmp/posted.md")" -le 65536 ]; then pass "the shortened fallback fits in an issue"; else bad "the shortened fallback is still too long"; fi

echo "send: this week's digest is already open"
reset_case
complete_asks | fixture GET "$asks_path"
jq -n --arg at "2026-10-24T06:17:00Z" \
  '[{body: "", state: "open", number: 850, title: "🙋 Maintainer digest — week 43", user: {login: "github-actions[bot]"}, assignees: [{login: "devantler"}], created_at: $at}]' |
  fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "an open digest for the week is not sent again"
expect_in "$tmp/out" "ALREADY-SENT #850" "the open digest is named"
expect_no_writes "nothing is opened or closed"
# A rerun after a close failed still retires the earlier digest, and keeps this week's open.
reset_case
complete_asks | fixture GET "$asks_path"
jq -n --arg at "2026-10-24T06:17:00Z" \
  '[{body: "", state: "open", number: 850, title: "🙋 Maintainer digest — week 43", user: {login: "github-actions[bot]"}, assignees: [{login: "devantler"}], created_at: $at},
    {body: "", state: "open", number: 801, title: "🙋 Maintainer digest — week 42", user: {login: "github-actions[bot]"}, assignees: [{login: "devantler"}], created_at: "2026-10-12T06:17:00Z"}]' |
  fixture GET "$digests_path"
echo '{"number": 801, "state": "closed"}' | fixture PATCH "$api/issues/801"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "a rerun with this week's digest open finishes the cleanup"
expect_in "$tmp/out" "CLOSED #801: the earlier digest" "the earlier digest a failed close left open is closed"
expect_not_in "$GH_STUB_LOG" "PATCH $api/issues/850" "this week's digest stays open"
expect_not_in "$GH_STUB_LOG" "POST " "nothing new is opened"
# The same week's title from a year ago, left open, does not hold back this year's digest.
reset_case
complete_asks | fixture GET "$asks_path"
jq -n '[{body: "", state: "open", number: 850, title: "🙋 Maintainer digest — week 43", user: {login: "github-actions[bot]"}, assignees: [{login: "devantler"}], created_at: "2025-10-20T06:17:00Z"}]' |
  fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_not_in "$tmp/out" "ALREADY-SENT" "a year-old digest with the same week does not count as sent"
expect_in "$GH_STUB_LOG" "POST $api/issues" "this year's digest is opened"
reset_case
complete_asks | fixture GET "$asks_path"
jq -n '[{body: "", state: "open", number: 850, title: "🙋 Maintainer digest — week 43", user: {login: "github-actions[bot]"}, assignees: [], created_at: "2026-10-24T06:17:00Z"}]' |
  fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "a digest GitHub never assigned to him is sent again"
expect_in "$GH_STUB_LOG" "PATCH $api/issues/850 state=closed state_reason=completed" "the unassigned digest is closed once the new one is sent"

echo "send: the week file shows private content"
reset_case
complete_asks | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
write_digest_file
# An address from the documentation range (RFC 5737), assembled here so no address sits in this file.
planted="$(printf '%s.%s.%s.%s' 192 0 2 10)"
printf -- '- The new node answers at %s now.\n' "$planted" >>"$digest_file"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 1 "a held-back summary is a finding"
posted_body
expect_in "$tmp/posted.md" "failed the digest check, so it was held back" "the fallback says the summary was held back"
expect_not_in "$tmp/posted.md" "$planted" "the private content never reaches the issue"
expect_in "$tmp/err" "2026-10-24.md:$(wc -l <"$digest_file" | tr -d ' '): private-content: ip-address" "the finding names the line and kind"
expect_not_in "$tmp/err" "$planted" "the finding never repeats the private text"

echo "send: the week file is too long"
reset_case
complete_asks | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
write_digest_file
awk 'BEGIN { for (i = 0; i < 1400; i++) printf "- A line that pads the digest past the size GitHub accepts. ([#5](x))\n" }' >>"$digest_file"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 1 "an oversized summary is a finding"
posted_body
expect_in "$tmp/posted.md" "the combined pending summaries were too long to send" "the fallback says the summary was too long"

echo "send: an ask filed after the summary was written"
reset_case
jq -s . <(issue 10 devantler "🙋 Ask: Keep 30 days of backups" "$complete_body") | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
write_digest_file
complete_asks | fixture GET "$asks_path"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "the digest opens with the asks open now"
posted_body
expect_in "$tmp/posted.md" "### 2. Ask [#11](https://github.com/example-org/example-repo/issues/11)" "the later ask is in the digest"
sed -n '/^## What shipped$/,$p' "$tmp/posted.md" >"$tmp/posted-rest.md"
rest_of_digest_file >"$tmp/expected-rest.md"
if cmp -s "$tmp/posted-rest.md" "$tmp/expected-rest.md"; then pass "the rest of the summary is sent as written"; else bad "the rest of the summary changed"; fi

echo "send: the template's digest part as the dated file"
reset_case
complete_asks | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
sed -n '/^---$/,$p' "$template" | sed '1d' >"$digest_file"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "the template's part is a valid dated file"
posted_body
expect_in "$tmp/posted.md" "### 1. Ask [#10]" "the workflow fills Needs you"
expect_not_in "$tmp/posted.md" "Leave this section as it is" "the placeholder is replaced"
expect_in "$tmp/posted.md" "### Agent Improver" "the rest of the template follows"

echo "send: GitHub does not record the assignee"
reset_case
complete_asks | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
write_digest_file
echo '{"number": 900, "assignees": []}' | fixture POST "$api/issues"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 1 "a digest nobody is assigned to is a finding"
expect_in "$tmp/err" "NOT-ASSIGNED #900" "the missing assignment is reported"
expect_not_in "$GH_STUB_LOG" "PATCH" "last week's digest stays open, since this one was not emailed"

echo "send: failed and malformed reads"
reset_case
earlier_digests | fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 2 "a failed read of the asks is unknown"
expect_no_writes "a failed read opens nothing"
reset_case
complete_asks | fixture GET "$asks_path"
echo '{"message": "Bad credentials"}' | fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 2 "an error object instead of a list is unknown"
expect_no_writes "a malformed read opens nothing"
reset_case
: | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 2 "an empty response is unknown, never an empty list"
run send --repo "$repo" --date 2026-02-30 --dir "$digests"
expect_rc 2 "an impossible date is a usage error"
run send --date 2026-10-24 --dir "$digests"
expect_rc 2 "a missing repository is a usage error"

echo "check: the template"
run check "$template"
expect_rc 0 "the template passes its own check"
never="$(awk '/^## Never include$/ { inside = 1; next } inside && /^#+ / { exit } inside { print }' "$template")"
if [ -z "$never" ]; then
  bad "the template has no Never include section"
else
  for marker in "spend findings" "money amounts" "credentials" "secrets" "hostnames" "IP addresses" \
    "phone numbers" "email addresses" "private detail" "private repository"; do
    if grep -Fq -- "$marker" <<<"$never"; then pass "the template forbids $marker"; else bad "the template's Never include list lacks $marker"; fi
  done
fi
for rule in "short sentences" "Every line ends with a link" "by product or area, then by Fixed," \
  "Improved and New" "Agent Improver work its own heading" "maintainer-digest.sh needs-you"; do
  expect_in "$template" "$rule" "the writing rules say: $rule"
done
for heading in "### Agent Improver" "**Fixed**" "**Improved**" "**New**"; do
  if grep -Fxq -- "$heading" "$template"; then pass "the template has $heading"; else bad "the template lacks $heading"; fi
done

echo "check: every private-content marker"
# Each value is assembled here, so this file holds no address, number or token of its own.
token="ghp_$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36)"
while IFS='|' read -r kind line; do
  [ -n "$kind" ] || continue
  f="$tmp/$kind.md"
  { sed -n '/^---$/,$p' "$template" | sed '1d'; printf '%s\n' "$line"; } >"$f"
  run check "$f"
  expect_rc 1 "$kind is caught"
  expect_in "$tmp/err" "$(basename "$f"):$(wc -l <"$f" | tr -d ' '): private-content: $kind" "$kind is reported by line and kind"
  expect_not_in "$tmp/err" "$line" "$kind is reported without its text"
done <<EOF
ip-address|The node answers at $(printf '%s.%s.%s.%s' 198 51 100 7).
email-address|Write to $(printf '%s@%s' someone example.invalid) for access.
phone-number|Call $(printf '+%s %s' 45 '00 00 00 00') when it breaks.
phone-number|Call $(printf '%s %s %s %s' 00 00 00 00) when it breaks.
phone-number|Call $(printf '%s' 00000000) when it breaks.
phone-number|Call $(printf '%s %s' 0000 0000) when it breaks.
phone-number|Call $(printf '(%s) %s-%s' 000 000 0000) when it breaks.
phone-number|Call $(printf '%s-%s-%s' 000 000 0000) when it breaks.
phone-number|Call $(printf '%s' 0000000000) when it breaks.
money|The cluster costs $(printf '%s %s' 120 kr) a month.
credential|The token is ${token}.
armoured-block|$(printf '%s%s' '-----' 'BEGIN PGP PRIVATE KEY BLOCK-----')
armoured-block|$(printf '%s%s' '-----' 'BEGIN OPENSSH PRIVATE KEY-----')
armoured-block|  $(printf '%s%s' '-----' 'begin certificate-----')
credential-assignment|Set token=$(printf '%s%s' supersecret value) in the config.
credential-assignment|Send it with Authorization: Bearer $(printf '%s%s' abcdefghij klmnopqrstuvwxyz).
private-hostname|The app reads from postgres.database.svc on start.
private-hostname|It runs on $(printf '%s.%s' build internal) now.
spend-heading|## Money
spend-wording|Cloud spend increased substantially after the migration.
spend-wording|Cloud costs decreased substantially after the migration.
money|The new plan is $(printf '%s %s' DKK 1200) a year.
EOF

# Only the template's exact rule line is left out of the scan; the same line with anything added is not.
{ sed -n '/^---$/,$p' "$template" | sed '1d'
  printf '%s\n' "- spend findings, prices, money amounts or invoices: they wait for the private Money digest; spend rose." ; } >"$tmp/rule-plus.md"
run check "$tmp/rule-plus.md"
expect_rc 1 "the template's rule line with words added is still scanned"
expect_in "$tmp/err" "private-content: spend-wording" "the added spend wording is named"

echo "check: the digest's shape"
sed -n '/^---$/,$p' "$template" | sed '1d' >"$tmp/shape.md"
run check "$tmp/shape.md"
expect_rc 0 "the template's digest part passes on its own"
grep -v "^## What's in progress$" "$tmp/shape.md" >"$tmp/no-progress.md"
run check "$tmp/no-progress.md"
expect_rc 1 "a missing section is caught"
expect_in "$tmp/err" "missing-section: What's in progress" "the missing section is named"
awk '$0 == "## Needs you" { $0 = "## What shipped (moved)" } $0 == "## What shipped" { $0 = "## Needs you" } { print }' "$tmp/shape.md" |
  sed 's/^## What shipped (moved)$/## What shipped/' >"$tmp/swapped.md"
run check "$tmp/swapped.md"
expect_rc 1 "sections out of order are caught"
expect_in "$tmp/err" "section-order: What shipped" "the out-of-order section is named"
grep -v 'publicly' "$tmp/shape.md" >"$tmp/no-note.md"
run check "$tmp/no-note.md"
expect_rc 1 "a missing public-reply note is caught"
expect_in "$tmp/err" "reply-note" "the missing note is named"
sed 's/^Your reply posts publicly/Your reply does not post publicly/' "$tmp/shape.md" >"$tmp/negated-note.md"
run check "$tmp/negated-note.md"
expect_rc 1 "a reply note that denies it posts publicly is caught"
expect_in "$tmp/err" "reply-note" "the negated note is named"
sed 's/^Your reply posts publicly.*/Your reply posts publicly? No, your response stays private./' "$tmp/shape.md" >"$tmp/continued-note.md"
run check "$tmp/continued-note.md"
expect_rc 1 "a reply note that continues the prefix into a denial is caught"
expect_in "$tmp/err" "reply-note" "the continued note is named"
{ sed 's/^Your reply posts publicly/Your reply does not post publicly/' "$tmp/shape.md"
  printf '\n## Footnotes\n\nYour reply posts publicly, but only here.\n'; } >"$tmp/late-note.md"
run check "$tmp/late-note.md"
expect_rc 1 "a public-reply note after How to reply ends does not count"
expect_in "$tmp/err" "reply-note" "the out-of-section note is named"
grep -v '^> 🤖 Generated by the Agentic Engineer$' "$tmp/shape.md" >"$tmp/no-disclosure.md"
run check "$tmp/no-disclosure.md"
expect_rc 1 "a digest without the disclosure line is caught"
expect_in "$tmp/err" "disclosure:" "the missing disclosure line is named"
{ cat "$tmp/shape.md"; printf '\n- The VPN gateway is fd12:3456:789a::1 now.\n'; } >"$tmp/ipv6.md"
run check "$tmp/ipv6.md"
expect_rc 1 "an IPv6 address is caught"
expect_in "$tmp/err" "private-content: ipv6-address" "the IPv6 address is reported by kind"
for addr in 2001:db8::1:2 ::1 fe80:: 2001:db8:85a3:0:0:8a2e:370:7334; do
  { cat "$tmp/shape.md"; printf '\n- The VPN gateway is %s now.\n' "$addr"; } >"$tmp/ipv6.md"
  run check "$tmp/ipv6.md"
  expect_rc 1 "the IPv6 address $addr is caught"
done
{ cat "$tmp/shape.md"; printf '\n- The digest now goes at 06:17:00 UTC.\n'; } >"$tmp/clock.md"
run check "$tmp/clock.md"
expect_rc 0 "a clock time is not mistaken for an IPv6 address"
{ cat "$tmp/shape.md"; printf '\n- The next digest is dated 2026-10-19; run https://github.com/example-org/example-repo/actions/runs/00000000000 records it.\n'; } >"$tmp/numeric-identifiers.md"
run check "$tmp/numeric-identifiers.md"
expect_rc 0 "an ISO date and an action run identifier are not national phone numbers"
run check "$tmp/absent.md"
expect_rc 2 "an unreadable file is unknown"
echo "workflows, and the organization's shared issue forms"
wf="$root/.github/workflows"
digest_wf="$wf/maintainer-digest.yaml"
echo "send: daily, including closed digests and calendar boundaries"
while IFS='|' read -r day previous state expected; do
  reset_case
  complete_asks | fixture GET "$asks_path"
  jq -n --arg at "$previous" --arg state "$state" '[{
    body: "", number: 850, title: "🙋 Maintainer digest — 2026-10-21", state: $state,
    user: {login: "github-actions[bot]"}, assignees: [{login: "devantler"}], created_at: $at
  }]' | fixture GET "$digests_path"
  write_digest_file
  [ "$digest_file" = "$digests/$day.md" ] || cp "$digest_file" "$digests/$day.md"
  run send --repo "$repo" --date "$day" --dir "$digests"
  expect_rc 0 "the $day cadence read succeeds"
  if [ "$expected" = send ]; then
    expect_in "$GH_STUB_LOG" "POST $api/issues" "$day sends with unanswered asks"
    expect_in "$tmp/out" "SENT #900" "$day records the delivery"
    if [ "$state" = closed ]; then
      expect_not_in "$GH_STUB_LOG" "PATCH $api/issues/850" "$day does not close an already closed digest"
    fi
  else
    expect_in "$tmp/out" "ALREADY-SENT #850" "$day prevents a same-day duplicate"
    expect_no_writes "$day makes no early or duplicate delivery"
  fi
done <<'CASES'
2026-10-24|2026-10-22T06:17:00Z|open|send
2026-10-24|2026-10-21T06:17:00Z|open|send
2026-10-24|2026-10-24T06:17:00Z|closed|skip
2026-11-02|2026-10-30T06:17:00Z|closed|send
2027-01-02|2026-12-30T06:17:00Z|closed|send
CASES

echo "send: no unanswered asks means no email or cleanup"
reset_case
echo '[]' | fixture GET "$asks_path"
earlier_digests | fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "no unanswered asks is a normal quiet day"
expect_in "$tmp/out" "NO-ASKS" "the quiet day is reported"
expect_no_writes "a quiet day neither sends nor retires a digest"

echo "send: combine pending changelogs on the next day with an ask"
reset_case
complete_asks | fixture GET "$asks_path"
echo '[]' | fixture GET "$digests_path"
write_digest_file
cp "$digest_file" "$digests/2026-10-25.md"
sed 's/Backups now run every night/Restores now verify their inputs/' "$digest_file" > "$digests/2026-10-26.md"
run send --repo "$repo" --date 2026-10-26 --dir "$digests"
expect_rc 0 "the next ask digest combines pending summaries"
posted_body
expect_in "$tmp/posted.md" "Backups now run every night" "the earlier quiet day's changelog is retained"
expect_in "$tmp/posted.md" "Restores now verify their inputs" "the newest changelog is included"

echo "send: disclose a held-back summary while delivering valid pending changes"
reset_case
complete_asks | fixture GET "$asks_path"
printf 'Not a valid summary.\n' >"$digests/2026-10-27.md"
run send --repo "$repo" --date 2026-10-27 --dir "$digests"
expect_rc 1 "a withheld summary remains a finding"
posted_body
expect_in "$tmp/posted.md" "Backups now run every night" "valid pending changes still arrive"
expect_in "$tmp/posted.md" "A pending changelog was held back because it did not pass its checks." "the reader is told that some content was held back"
expect_not_in "$tmp/posted.md" "**The summary is missing" "a valid combined summary is not replaced by fallback"
expect_not_in "$tmp/posted.md" "Not a valid summary." "withheld content is never copied"
jq -r '.body | split("\n")[1]' "$GH_STUB_DIR/payload.json" >"$tmp/receipt.txt"
expect_not_in "$tmp/receipt.txt" "2026-10-27" "the held-back changelog is not consumed"
rm "$digests/2026-10-27.md"

echo "send: a large pending backlog drains across successful deliveries"
reset_case
complete_asks | fixture GET "$asks_path"
rm -f "$digests"/2026-10-*.md
write_digest_file
awk '$0 == "## What shipped" {
    print; for (i=0; i<760; i++) print "Reviewed work improves the portfolio for its users."; next
  } { print }' \
  "$digest_file" >"$tmp/large-summary.md"
cp "$tmp/large-summary.md" "$digest_file"
sed 's/Backups now run every night/Deferred restore checks now run/' "$digest_file" >"$digests/2026-10-25.md"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "one individually valid large summary can be sent"
cp "$GH_STUB_DIR/payload.json" "$tmp/batch-sent.json"
reset_case
complete_asks | fixture GET "$asks_path"
# No previous receipt: both individually valid summaries are pending on this date.
run send --repo "$repo" --date 2026-10-25 --dir "$digests"
expect_rc 0 "an oversized combined backlog sends a fitting batch"
posted_body
expect_in "$tmp/posted.md" "Backups now run every night" "the oldest pending summary is delivered first"
expect_not_in "$tmp/posted.md" "Deferred restore checks now run" "a summary that does not fit remains pending"
expect_in "$tmp/posted.md" "More changelog content remains pending for a later ask." "the reader knows another batch remains"
cp "$GH_STUB_DIR/payload.json" "$tmp/batch-sent.json"
jq -r '.body | split("\n")[1]' "$tmp/batch-sent.json" >"$tmp/batch-receipt.txt"
expect_in "$tmp/batch-receipt.txt" "2026-10-24" "only the sent batch is receipted"
expect_not_in "$tmp/batch-receipt.txt" "2026-10-25" "deferred content is not marked delivered"
reset_case
complete_asks | fixture GET "$asks_path"
jq -n --slurpfile sent "$tmp/batch-sent.json" '[{number:900,title:$sent[0].title,body:$sent[0].body,state:"closed",
  user:{login:"github-actions[bot]"},assignees:[{login:"devantler"}],created_at:"2026-10-25T06:17:00Z"}]' | fixture GET "$digests_path"
run send --repo "$repo" --date 2026-10-26 --dir "$digests"
expect_rc 0 "the remaining large summary is delivered on the next ask day"
posted_body
expect_in "$tmp/posted.md" "Deferred restore checks now run" "the backlog drains without editing source files"
expect_not_in "$tmp/posted.md" "Backups now run every night" "the first batch is not repeated"
rm -f "$digests"/2026-10-*.md
write_digest_file

echo "needs-you: skip comment history that cannot answer a current ask"
for current_asks in open empty; do
  reset_case
  if [ "$current_asks" = open ]; then complete_asks; else echo '[]'; fi | fixture GET "$asks_path"
  jq -n --arg body "$(printf '> 🤖 Generated by the Agentic Engineer\n\n## Needs you\n\n### 1. Ask [#12](https://github.com/%s/issues/12)\n' "$repo")" \
    '[{number:850,title:"🙋 Maintainer digest — 2026-10-21",state:"closed",body:$body,
      user:{login:"github-actions[bot]"},assignees:[{login:"devantler"}],created_at:"2026-10-21T06:17:00Z"}]' | fixture GET "$digests_path"
  rm "$GH_STUB_FIX/GET$(key "$api/issues/850/comments?per_page=100").json"
  run needs-you --repo "$repo"
  expect_rc 0 "irrelevant history is unnecessary with $current_asks asks"
  expect_not_in "$GH_STUB_LOG" "GET $api/issues/850/comments" "an unrelated digest makes no comment request"
done

echo "send: answered asks are excluded, including replies on closed digests"
for answer_surface in direct digest; do
  reset_case
  complete_asks | fixture GET "$asks_path"
  write_digest_file
  if [ "$answer_surface" = direct ]; then
    jq -n '[{id:1,user:{login:"devantler"},body:"A"}]' | fixture GET "$api/issues/10/comments?per_page=100"
  else
    jq -n --arg body "$(printf '> 🤖 Generated by the Agentic Engineer\n\n## Needs you\n\n### 1. Ask [#10](https://github.com/%s/issues/10)\n' "$repo")" \
      '[{number:850,title:"🙋 Maintainer digest — 2026-10-21",state:"closed",body:$body,
        user:{login:"github-actions[bot]"},assignees:[{login:"devantler"}],created_at:"2026-10-21T06:17:00Z"}]' | fixture GET "$digests_path"
    jq -n '[{id:1,user:{login:"devantler"},body:"1: B"}]' | fixture GET "$api/issues/850/comments?per_page=100"
  fi
  run send --repo "$repo" --date 2026-10-24 --dir "$digests"
  expect_rc 0 "$answer_surface answers are reconciled"
  posted_body
  expect_not_in "$tmp/posted.md" "Ask [#10]" "$answer_surface does not repeat the answered ask"
  expect_in "$tmp/posted.md" "Ask [#11]" "$answer_surface keeps the unanswered ask"
done

echo "send: numbered answers work for shortened and held-back asks"
for ask_heading in '- 1. Ask [#10](https://github.com/example-org/example-repo/issues/10)' \
  '### 1. Held back ([#10](https://github.com/example-org/example-repo/issues/10))'; do
  reset_case
  complete_asks | fixture GET "$asks_path"
  write_digest_file
  jq -n --arg body "$(printf '> 🤖 Generated by the Agentic Engineer\n\n## Needs you\n\n%s\n' "$ask_heading")" \
    '[{number:850,title:"🙋 Maintainer digest — 2026-10-21",state:"closed",body:$body,
      user:{login:"github-actions[bot]"},assignees:[{login:"devantler"}],created_at:"2026-10-21T06:17:00Z"}]' | fixture GET "$digests_path"
  jq -n '[{id:1,user:{login:"devantler"},body:"1: B"}]' | fixture GET "$api/issues/850/comments?per_page=100"
  run send --repo "$repo" --date 2026-10-24 --dir "$digests"
  expect_rc 0 "a numbered reply to an alternate ask heading is read"
  posted_body
  expect_not_in "$tmp/posted.md" "Ask [#10]" "an answered shortened or held-back ask is not repeated"
done

echo "needs-you: replies below nested agent quotations are human answers"
for answer_surface in direct digest; do
  reset_case
  complete_asks | fixture GET "$asks_path"
  answer=A
  parent=10
  if [ "$answer_surface" = digest ]; then
    answer='1: A'
    parent=850
    jq -n --arg body "$(printf '> 🤖 Generated by the Agentic Engineer\n\n## Needs you\n\n### 1. Ask [#10](https://github.com/%s/issues/10)\n' "$repo")" \
      '[{number:850,title:"🙋 Maintainer digest — 2026-10-21",state:"closed",body:$body,
        user:{login:"github-actions[bot]"},assignees:[{login:"devantler"}],created_at:"2026-10-21T06:17:00Z"}]' | fixture GET "$digests_path"
  fi
  jq -n --arg body "$(printf '>> 🤖 Generated by the Agentic Engineer\n>> Earlier question\n\n%s\n' "$answer")" \
    '[{id:1,user:{login:"devantler"},body:$body}]' | fixture GET "$api/issues/$parent/comments?per_page=100"
  run needs-you --repo "$repo"
  expect_rc 0 "a $answer_surface answer below a nested quote is read"
  expect_not_in "$tmp/out" "Ask [#10]" "the $answer_surface answered ask is excluded"
  expect_in "$tmp/out" "Ask [#11]" "an unanswered ask remains"
done

echo "send: agent, third-party and quoted replies are not answers"
reset_case
complete_asks | fixture GET "$asks_path"
write_digest_file
jq -n '[{id:1,user:{login:"devantler"},body:"> 🤖 Generated by the Agentic Engineer\n\nA"},
  {id:2,user:{login:"someone-else"},body:"A"}]' | fixture GET "$api/issues/10/comments?per_page=100"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "agent and third-party replies remain data"
posted_body
expect_in "$tmp/posted.md" "Ask [#10]" "only the maintainer can answer the ask"

reset_case
complete_asks | fixture GET "$asks_path"
write_digest_file
# shellcheck disable=SC2016 # Literal Markdown fences are fixture data.
jq -n --arg body "$(printf '> A\n\n````\nA\n```\nA\n````\n')" \
  '[{id:1,user:{login:"devantler"},body:$body}]' | fixture GET "$api/issues/10/comments?per_page=100"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "quoted and fenced examples are ignored"
posted_body
expect_in "$tmp/posted.md" "Ask [#10]" "a quoted example does not answer the ask"

reset_case
complete_asks | fixture GET "$asks_path"
write_digest_file
jq -n --arg body "$(printf '> 🤖 Generated by the Agentic Engineer\n\n## Needs you\n\n### 1. Ask [#10](https://github.com/%s/issues/10)\n### 2. Ask [#11](https://github.com/%s/issues/11)\n' "$repo" "$repo")" \
  '[{number:850,title:"🙋 Maintainer digest — 2026-10-21",state:"closed",body:$body,
    user:{login:"github-actions[bot]"},assignees:[{login:"devantler"}],created_at:"2026-10-21T06:17:00Z"}]' | fixture GET "$digests_path"
# shellcheck disable=SC2016 # Literal Markdown fences are fixture data.
jq -n --arg body "$(printf '> 1: A\n````\n1: A\n```\n1: A\n````\n2: B\n')" \
  '[{id:1,user:{login:"devantler"},body:$body}]' | fixture GET "$api/issues/850/comments?per_page=100"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "a real numbered answer after fenced examples is read"
posted_body
expect_in "$tmp/posted.md" "Ask [#10]" "quoted and fenced numbered examples remain unanswered"
expect_not_in "$tmp/posted.md" "Ask [#11]" "the unquoted numbered answer is honored"

reset_case
complete_asks | fixture GET "$asks_path"
jq -n '[{user:{login:"devantler"},body:"A"}]' | fixture GET "$api/issues/10/comments?per_page=100"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 2 "an incomplete reply read is unknown"
expect_no_writes "an incomplete reply read sends nothing"

reset_case
jq -s . <(issue 10 devantler "🙋 Ask: Keep 30 days of backups" "$complete_body") | fixture GET "$asks_path"
jq -n '[{id:1,user:{login:"devantler"},body:"A"}]' | fixture GET "$api/issues/10/comments?per_page=100"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "all asks answered is a quiet day"
expect_in "$tmp/out" "NO-ASKS" "an answered but still-open issue does not trigger mail"
expect_no_writes "all asks answered makes no delivery or cleanup write"

reset_case
complete_asks | fixture GET "$asks_path"
write_digest_file
jq -n --arg body "$(printf '> 🤖 Generated by the Agentic Engineer\n\n## Needs you\n\n### 1. Ask [#10](https://github.com/%s/issues/10)\n\n## What shipped\n\n### 2. Ask [#11](https://github.com/%s/issues/11)\n' "$repo" "$repo")" \
  '[{number:850,title:"🙋 Maintainer digest — 2026-10-21",state:"closed",body:$body,
    user:{login:"github-actions[bot]"},assignees:[{login:"devantler"}],created_at:"2026-10-21T06:17:00Z"}]' | fixture GET "$digests_path"
jq -n '[{id:1,user:{login:"devantler"},body:"2: A"}]' | fixture GET "$api/issues/850/comments?per_page=100"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "a number outside Needs you is not an answer mapping"
posted_body
expect_in "$tmp/posted.md" "Ask [#11]" "a changelog example cannot answer a different ask"

echo "send: a quiet day leaves pending changes for the next ask"
saved_delivery="$tmp/delivered-payload.json"
reset_case
complete_asks | fixture GET "$asks_path"
write_digest_file
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "the initial summary delivery succeeds"
cp "$GH_STUB_DIR/payload.json" "$saved_delivery"
reset_case
jq -n --slurpfile sent "$saved_delivery" '[{number:900,title:$sent[0].title,body:$sent[0].body,state:"closed",
  user:{login:"github-actions[bot]"},assignees:[{login:"devantler"}],created_at:"2026-10-24T06:17:00Z"}]' | fixture GET "$digests_path"
echo '[]' | fixture GET "$asks_path"
sed 's/Backups now run every night/Quiet-day restore verification now runs/' "$digest_file" > "$digests/2026-10-25.md"
run send --repo "$repo" --date 2026-10-25 --dir "$digests"
expect_rc 0 "a quiet day succeeds without consuming the summary"
expect_no_writes "a quiet day makes no delivery or cleanup write"
jq -s . <(issue 11 devantler "🙋 Ask: Retire the status page" "$second_body") | fixture GET "$asks_path"
run send --repo "$repo" --date 2026-10-26 --dir "$digests"
expect_rc 0 "the next unanswered ask gets the pending changelog"
posted_body
expect_in "$tmp/posted.md" "Quiet-day restore verification now runs" "quiet-day changes reach the next ask digest"
expect_not_in "$tmp/posted.md" "Backups now run every night" "an already delivered summary is not repeated"
expect_not_in "$GH_STUB_LOG" "PATCH $api/issues/900" "a closed digest is left closed"

echo "send: accepted summary whitespace preserves content and delivery receipts"
reset_case
complete_asks | fixture GET "$asks_path"
rm -f "$digests"/2026-10-*.md
write_digest_file
{ printf '\n'; sed 's/$/  /' "$digest_file"; } | awk '{ printf "%s\r\n", $0 }' >"$tmp/spaced-summary.md"
cp "$tmp/spaced-summary.md" "$digest_file"
run send --repo "$repo" --date 2026-10-24 --dir "$digests"
expect_rc 0 "a summary accepted by check still composes"
posted_body
expect_in "$tmp/posted.md" "Backups now run every night" "normalized headings retain the shipped changelog"
jq -r '.body' "$GH_STUB_DIR/payload.json" >"$tmp/raw-delivery.md"
receipt_line="$(sed -n '2p' "$tmp/raw-delivery.md")"
if [ "$(head -n 1 "$tmp/raw-delivery.md")" = '> 🤖 Generated by the Agentic Engineer' ] &&
  grep -q '^<!-- maintainer-digest-summaries-v1: ' <<<"$receipt_line"; then
  pass "the delivery starts with its disclosure and second-line receipt"
else
  bad "accepted whitespace broke delivery authentication or its receipt"
fi

# Converts workflow YAML to JSON for structural assertions.
as_json() { yq -o=json '.' "$1"; }
as_json "$digest_wf" >"$tmp/digest-wf.json"
# GitHub shows the organization's shared issue forms only in a repository with no issue templates of
# its own, so one local form would hide all of them. Asks are filed through the API, so none is needed.
if [ -e "$root/.github/ISSUE_TEMPLATE" ]; then
  bad "a local .github/ISSUE_TEMPLATE would hide the organization's shared issue forms"
else
  pass "the repository keeps the organization's shared issue forms"
fi
# Compares a compact JSON projection with its expected workflow configuration.
expect_json() {
  local actual
  actual="$(jq -c "$2" "$1")"
  if [ "$actual" = "$3" ]; then pass "$4"; else bad "$4: $2 is $actual, expected $3"; fi
}
expect_json "$tmp/digest-wf.json" '.on.schedule' '[{"cron":"17 6 * * *"}]' "the digest checks daily at 06:17 UTC"
expect_json "$tmp/digest-wf.json" '.on | has("workflow_dispatch")' 'true' "the digest can be sent by hand"
expect_json "$tmp/digest-wf.json" '[.permissions, .jobs.send.permissions]' '[{},{"contents":"read","issues":"write"}]' "the digest workflow holds only what it needs"
expect_json "$tmp/digest-wf.json" '[.jobs.send.steps[].run // empty | test("maintainer-digest\\.sh \"\\$\\{args")] | any' 'true' "the digest workflow runs the helper"
expect_json "$tmp/digest-wf.json" '[.jobs[].steps[].run // empty | test("\\$\\{\\{")] | any' 'false' "the digest workflow splices no expression into a script"
expect_json "$tmp/digest-wf.json" '[.jobs[].steps[].uses // empty | test("^[^@]+@[0-9a-f]{40}$")] | all' 'true' "the digest workflow pins every action to a full commit"
expect_not_in "$digest_wf" "secrets." "the digest workflow uses only its own token"
if [ "$fails" -ne 0 ]; then
  echo "maintainer-digest.test.sh: $fails assertion(s) failed" >&2
  exit 1
fi
echo "maintainer-digest.test.sh: all assertions passed"
completed=1
