#!/usr/bin/env bash
# maintainer-digest.sh — email daily only while unanswered asks exist (monorepo#4475).
# ADR 0009 phase 1 / monorepo#4285 supplies delivery; urgent delivery completes monorepo#4305.
#
# Why this exists. The agents act through the maintainer's own GitHub account, and GitHub never
# emails a user about their own activity, so an ask an agent files never reaches him on its own. The
# Slack DM that carried asks left answers unread for weeks (monorepo#3888). GitHub does email him an
# issue that github-actions[bot] opens and assigns to him, so maintainer-digest.yaml sends one for the
# agents. A daily check suppresses answered asks and sends nothing on quiet days. Reviewed
# changelogs remain pending until a later ask digest records their successful delivery.
#
# Subcommands:
#   send [--repo OWNER/REPO] [--date YYYY-MM-DD] [--dir DIR] [--dry-run]
#     Open DIR/<date>.md (default docs/digests, today's UTC date) as the issue
#     "🙋 Maintainer digest — <date>", labelled maintainer-digest and assigned to the maintainer,
#     then close the earlier digests github-actions[bot] opened. Its Needs you section is replaced by
#     the asks open at the moment of sending, so an ask filed after the summary was written still
#     goes out. When the file is missing, too long or fails `check`, a short digest of the open asks
#     goes instead, saying the summary is missing. An assigned digest from today prevents a
#     duplicate. Quiet days neither send nor retire a digest, and consume no pending summary.
#   needs-you [--repo OWNER/REPO]
#     Print the Needs you section for the open asks, as `send` puts it in the digest.
#   check FILE...
#     Check a digest file: its four sections in order, the note that a reply posts publicly, and no
#     private-content marker. A finding names the file, the line and the kind, never the text found.
#
# What an ask may put in the digest. Anyone can open an issue that looks like an ask, so only asks the
# maintainer's own account filed are shown; another account's ask is named by its number only. An
# ask whose text shows a private-content marker is listed with its text held back. Copied ask text is
# shown only inside an indented code block, so GitHub renders none of it as Markdown, a link, a mention
# or an issue reference, and an @mention is also broken with a zero-width space for bots that read the
# raw text. The private-content markers are a backstop for text the agents write, not a guarantee.
#
# Exit: 0 done with no finding; 1 a finding or a refusal, each printed (a digest with a finding is
# still sent); 2 unknown: a usage error, an unreadable input, a failed GitHub read or write, or an
# abort before the end.
set -euo pipefail

tmp="$(mktemp -d)"
maintainer_digest_finished=0
# Bash 3.2 can hand an EXIT trap a zero status for a `set -u` abort, so only `finish` may leave with
# status 0 (cleanup-trap-fail-closed.test.sh).
# shellcheck disable=SC2317,SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$maintainer_digest_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "maintainer-digest.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap on_exit EXIT

# Marks normal completion before exiting, so the EXIT trap preserves the requested status.
finish() {
  maintainer_digest_finished=1
  exit "$1"
}

maintainer=devantler
bot='github-actions[bot]'
ask_label="maintainer-ask"
digest_label="maintainer-digest"
# GitHub refuses an issue body over 65,536 characters, and a byte count is never the smaller number.
max_body_bytes=65536
ask_sections=("Question" "Options" "Recommendation" "If unanswered")
digest_sections=("Needs you" "What shipped" "What's in progress" "How to reply")

# Private-content markers: what the template's "Never include" list forbids, in a form a line can
# match. Each kind has its grep flags and an extended regular expression.
private_kinds=(ip-address ipv6-address email-address phone-number money credential armoured-block credential-assignment private-hostname spend-heading spend-wording)
private_flags=(-E -E -E -E -iE -E -iE -iE -iE -iE -iE)
private_patterns=(
  '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)'
  # Eight full groups, or any "::" compressed form: groups on either side of the "::", or none.
  # Times such as 06:17:00 have too few groups and no "::", so they never match.
  '(^|[^0-9A-Za-z:])(([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6})?::([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,6})?)([^0-9A-Za-z:]|$)'
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
  # Include common eight- and ten-digit national layouts without matching date fragments or
  # longer numeric identifiers. The template still requires the author to exclude private detail.
  '(tel:|\+[0-9]{1,3}[ .-]?[0-9]{2,4}([ .-]?[0-9]{2,4}){2,}|(^|[^0-9A-Za-z])([0-9]{8}|[0-9]{10}|([0-9]{2}[ .-]){3}[0-9]{2}|[0-9]{4}[ .-][0-9]{4}|([0-9]{3}[ .-]|\([0-9]{3}\)[ .-]?)[0-9]{3}[ .-][0-9]{4})([^0-9A-Za-z]|$))'
  '(\$|€|£) ?[0-9]|(^|[^a-z])(kr|dkk|eur|usd|gbp|sek|nok)\.? ?[0-9]|[0-9][0-9.,]* ?(kr|dkk|eur|usd|gbp|sek|nok|kroner|dollars?|euros?)([^a-z]|$)'
  '(^|[^A-Za-z0-9])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,})'
  # Any armoured block (a key, a certificate, a signature), whatever its label: a digest never needs
  # one, so every opening armour line is refused rather than a list of private-key labels (monorepo#4302).
  '-----BEGIN '
  # A secret, token, password or API key written as an assignment, the form agent-telemetry.sh redacts,
  # and an Authorization header or bearer token.
  'authorization["'"'"']?[[:space:]]*[:=]|bearer[[:space:]]+[A-Za-z0-9._~+/=-]{8,}|(secret|token|password|passwd|api[_-]?key)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^"'"'"'[:space:],}]{8,}'
  '[A-Za-z0-9-]\.(internal|local|localdomain|lan|intranet|corp|home\.arpa|ts\.net|svc)([^A-Za-z0-9-]|$)'
  '^#{1,6}[[:space:]].*(spend|money|costs?|invoice|billing|savings?)'
  # Spend findings belong in the private digest, so spend wording in ordinary prose is refused too. This
  # list is a backstop for a digest the agent writes from the template, not the guarantee.
  '(^|[^a-z])(spend(ing|s)?|costs?|invoices?|billing|budgets?|expenses?|savings?)([^a-z]|$)'
)
# The template's own "Never include" line names spend findings to forbid them. Only that exact, fixed
# line is left out of the scan: it carries no data, and any other wording is still scanned.
template_rule_line="- spend findings, prices, money amounts or invoices: they wait for the private Money digest;"

found=0
# Reports a known finding and remembers that the completed command must not report clean.
finding() {
  echo "$*" >&2
  found=1
}

# Prints invalid arguments and exits with the UNKNOWN status through the guarded completion path.
usage() {
  echo "maintainer-digest.sh: $*" >&2
  echo "usage: maintainer-digest.sh send|urgent|needs-you|check ... (see the header comment)" >&2
  finish 2
}

# Stops on an unreadable or failed operation without treating it as a clean empty result.
unknown() {
  echo "UNKNOWN: $*" >&2
  finish 2
}

# Requires an option's following argument to exist and contain a value.
need_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    usage "$1 needs a value"
  fi
}

# Accepts only an owner/repository pair before constructing any GitHub API path.
check_repo() {
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "--repo OWNER/REPO is required (or GITHUB_REPOSITORY)"
}

# The fields each kind of GitHub object must carry before the script decides anything from it,
# declared once (monorepo#4302). Every object read is checked against its kind's whole list, so a
# partial object is UNKNOWN by construction: no decision falls back to a default for a missing field.
# A field is a dotted path and its shape: number, string, text (present, a string or null, as GitHub
# writes an empty body), timestamp (a valid UTC ISO 8601 time) or logins (a list of accounts).
required_ask='{"number":"number","title":"string","user.login":"string","html_url":"string","body":"text","state":"string","labels":"labels","assignees":"logins","created_at":"timestamp"}'
required_digest='{"number":"number","title":"string","body":"text","state":"string","user.login":"string","created_at":"timestamp","assignees":"logins"}'
required_comment='{"id":"number","body":"text","user.login":"string"}'
required_created='{"number":"number","assignees":"logins"}'
# Only a reply's own unquoted prose can answer an ask. Keep this shared by direct and numbered
# replies; a short closing fence cannot end a longer opening fence.
# shellcheck disable=SC2016 # Constant jq program, not shell expansion.
reply_lines_def='def reply_lines:
  gsub("\\r"; "") | split("\n")
  | reduce .[] as $line ({fence:"", lines:[]};
      ($line | sub("^ {0,3}"; "")) as $trim
      | if .fence == "" and ($trim | test("^(?:`{3,}|~{3,})")) then
          .fence = ($trim | capture("^(?<fence>`{3,}|~{3,})").fence)
        elif .fence != "" then
          .fence as $fence
          | if ($trim | test("^" + $fence[0:1] + "{" + ($fence | length | tostring) + ",}[ \\t]*$"))
            then .fence = "" else . end
        else .lines += [$line] end)
  | .lines[] | select(test("^[^> \\t]"));'
# shellcheck disable=SC2016 # A jq program, not a shell expansion.
conforms_def='def conforms($spec):
  . as $o | type == "object" and all($spec | to_entries[];
    (.key | split(".")) as $p | .value as $shape
    | ($o | getpath($p)) as $v
    | if $shape == "number" then ($v | type) == "number"
      elif $shape == "string" then ($v | type) == "string"
      elif $shape == "text" then ($o | getpath($p[:-1]) | type == "object" and has($p[-1]))
        and (($v | type) == "string" or $v == null)
      elif $shape == "timestamp" then ($v | type) == "string"
        and ((try ($v | fromdateiso8601 | todateiso8601) catch null) == $v)
      elif $shape == "logins" then ($v | type) == "array" and all($v[]; type == "object" and (.login | type) == "string")
      elif $shape == "labels" then ($v | type) == "array" and all($v[]; type == "object" and (.name | type) == "string")
      else false end);'

# Reads every page of an issue listing into $2 as one JSON array, leaving out pull requests. Every
# issue must carry the fields $3 (one of the required_* lists) declares. A failed read, an empty
# response or anything but pages of complete issues is UNKNOWN, never an empty list.
read_issues() {
  local path=$1 out=$2 spec=$3
  gh api --paginate "$path" >"$tmp/page.json" || unknown "could not read $path"
  [ -s "$tmp/page.json" ] || unknown "an empty response for $path"
  jq -s --argjson spec "$spec" "$conforms_def"'
    if all(.[]; type == "array") and all(.[][]; type == "object")
    then [.[][] | select(has("pull_request") | not)]
         | if all(.[]; conforms($spec)) then . else error("an incomplete issue") end
    else error("not a list of issues") end' "$tmp/page.json" >"$out" 2>/dev/null ||
    unknown "an unexpected or incomplete response for $path"
}

# Splits the open asks into the maintainer's own, oldest first, and the numbers of everyone else's.
fetch_asks() {
  read_issues "repos/$repo/issues?state=open&labels=$ask_label&per_page=100" "$tmp/asks-all.json" "$required_ask"
  jq -e 'all(.[]; .state == "open")' "$tmp/asks-all.json" >/dev/null || unknown "unexpected ask state"
  jq --arg who "$maintainer" 'map(select(.user.login == $who)) | sort_by([if any(.labels[]; .name == "maintainer-ask-cap-delayed") then 0 else 1 end, .number])' \
    "$tmp/asks-all.json" >"$tmp/asks.json" || unknown "could not sort the asks"
  jq -r --arg who "$maintainer" 'map(select(.user.login != $who) | .number) | sort | .[]' \
    "$tmp/asks-all.json" >"$tmp/untrusted.txt" || unknown "could not sort the asks"
  filter_answered_asks
}

# Read both open and closed delivery records; a closed email thread can receive a later answer.
load_delivery_history() {
  [ ! -f "$tmp/digests.json" ] || return 0
  read_issues "repos/$repo/issues?state=all&labels=$digest_label&per_page=100" "$tmp/digests.json" "$required_digest"
  jq -e 'all(.[]; .state == "open" or .state == "closed")' "$tmp/digests.json" >/dev/null ||
    unknown "a digest listing has an invalid issue state"
}

# Select the maintainer's own replies, excluding disclosed agent output and sender/trigger markers.
# This only suppresses a repeated question; it never executes or grants authority from reply text.
# Strip only the canonical disclosure's quote level; a nested quotation is still quoted material.
human_comments() {
  read_issues "repos/$repo/issues/$1/comments?per_page=100" "$2" "$required_comment"
  jq --arg who "$maintainer" "$reply_lines_def"'
    map(select(.user.login == $who and (.body | type) == "string")
      | select((.body | [reply_lines] | length) > 0)
      | select((.body | gsub("\\r"; "") | split("\n") | map(select(test("\\S"))) | first
        | sub("^[ \\t]*(?:[-*+][ \\t]+)*(?:>[ \\t]*)?(?:[-*+][ \\t]+)*"; "")
        | test("^(?:🤖[ \\t]*)?(?:Generated by the|Generated with \\[|Sent using|@(?:codex|coderabbitai|cursor)\\b)"; "i")) | not))' \
    "$2" >"$2.human" || unknown "could not classify maintainer replies"
}

# Remove asks already answered directly or by an unambiguous numbered reply to a delivered digest.
# A direct maintainer reply counts as a response, leaving any follow-up decision to the engineer.
filter_answered_asks() {
  local number digest rc
  : >"$tmp/answered.txt"
  load_delivery_history
  jq -r '.[].number' "$tmp/asks.json" >"$tmp/ask-numbers.txt"
  while IFS= read -r number; do
    human_comments "$number" "$tmp/ask-comments-$number.json"
    if jq -e 'length > 0' "$tmp/ask-comments-$number.json.human" >/dev/null; then
      printf '%s\n' "$number" >>"$tmp/answered.txt"
    fi
  done <"$tmp/ask-numbers.txt"
  jq -r --arg bot "$bot" --arg who "$maintainer" '
    .[] | select(.user.login == $bot and any(.assignees[]; .login == $who)
      and (.title | test("^🙋 Maintainer digest — (week ([1-9]|[1-4][0-9]|5[0-3])|[0-9]{4}-[0-9]{2}-[0-9]{2})$"))
      and (.body | type) == "string" and (.body | startswith("> 🤖 Generated by the"))) | .number' \
    "$tmp/digests.json" >"$tmp/delivery-numbers.txt"
  while IFS= read -r digest; do
    jq -er --argjson n "$digest" '.[] | select(.number == $n) | .body' "$tmp/digests.json" >"$tmp/delivery-body.md"
    awk '$0 == "## Needs you" { inside=1; next } inside && /^## / { exit } inside { print }' \
      "$tmp/delivery-body.md" >"$tmp/delivery-asks.md"
    jq -Rn --arg repo "$repo" '
      [inputs | gsub("\\r$"; "")
        | sub("^- "; "### ") | sub("\\. Held back \\(\\[#"; ". Ask [#") | sub("\\)\\)$"; ")")
        | try capture("^### (?<index>[1-9][0-9]*)\\. Ask \\[#(?<number>[1-9][0-9]*)\\]\\(https://github\\.com/(?<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/(?<target>[1-9][0-9]*)\\)$") catch empty
        | select(.repo == $repo and .number == .target)]
      | group_by(.index) | if any(.[]; length != 1) then error("ambiguous ask index")
        else map(.[0]) end' <"$tmp/delivery-asks.md" >"$tmp/answer-map.json" || unknown "ambiguous digest answer mapping"
    # A digest that carried no currently open ask cannot answer one. Keep read failures distinct
    # from a normal non-match, and retain all delivery numbers for summary-receipt accounting.
    rc=0
    jq -e --slurpfile asks "$tmp/asks.json" '
      ([$asks[0][].number | tostring]) as $open
      | any(.[]; .number as $number | ($open | index($number)) != null)' \
      "$tmp/answer-map.json" >/dev/null || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *) unknown "could not match delivered asks to current asks" ;;
    esac
    human_comments "$digest" "$tmp/digest-comments-$digest.json"
    # Ignore quoted and fenced examples, including fences longer than three characters.
    jq -r --slurpfile mapping "$tmp/answer-map.json" "$reply_lines_def"'
      .[].body | reply_lines | try capture("^(?<index>[1-9][0-9]*):[ \\t]*(?<answer>\\S.*)$") catch empty
      | .index as $index | $mapping[0][] | select(.index == $index) | .number' \
      "$tmp/digest-comments-$digest.json.human" >"$tmp/digest-answers.txt" || unknown "could not read numbered maintainer replies"
    cat "$tmp/digest-answers.txt" >>"$tmp/answered.txt"
  done <"$tmp/delivery-numbers.txt"
  jq --rawfile answered "$tmp/answered.txt" '($answered | split("\n")) as $ids
    | map(select((.number | tostring) as $n | ($ids | index($n)) == null))' \
    "$tmp/asks.json" >"$tmp/unanswered.json" || unknown "could not remove answered asks"
  mv "$tmp/unanswered.json" "$tmp/asks.json"
}

# Prints the text under "### <name>" in the body file $1, up to the next heading, without the blank
# lines around it. An issue form writes "_No response_" for an empty field, which counts as empty.
section_text() {
  awk -v name="$2" '
    { sub(/\r$/, ""); line = $0; sub(/[ \t]+$/, "", line) }
    # Spelled without an interval: an older mawk reads "{1,3}" literally.
    line ~ /^##?#?[ \t]/ {
      if (inside) { inside = 0; done = 1 }
      else if (!done && line == "### " name) { inside = 1; next }
    }
    inside { lines[++n] = $0 }
    END {
      s = 1; while (s <= n && lines[s] ~ /^[ \t]*$/) s++
      e = n; while (e >= s && lines[e] ~ /^[ \t]*$/) e--
      if (s == e && lines[s] ~ /^[ \t]*_No response_[ \t]*$/) e = s - 1
      for (i = s; i <= e; i++) print lines[i]
    }' "$1"
}

# Breaks each @mention with a zero-width space after the @, so a digest that repeats an ask never
# notifies anyone or triggers a bot again. A code span would not do: bots parse the raw Markdown.
zwsp=$'\xe2\x80\x8b'
# Breaks mention tokens in copied text before a bot can interpret the raw digest body.
quiet_mentions() {
  sed -E "s/(^|[^A-Za-z0-9_])@([A-Za-z0-9][A-Za-z0-9-]*(\/[A-Za-z0-9_.-]+)?)/\1@${zwsp}\2/g"
}

# Shows copied ask text as an indented code block: every line, blank ones too, starts with four
# spaces, so GitHub renders the text literally (no Markdown, link, mention, issue reference or HTML)
# and no line of it starts with a command a bot reads. Unlike a fence, nothing in the text can end
# the block. Only text the script writes itself appears outside one.
as_code() {
  sed -e 's/^/    /'
}

# Prints the numbers of the lines in file $3 that match regex $2 with grep flags $1. Returns 1 when no
# line matches and 2 when grep fails. The matched text itself is never printed.
matching_lines() {
  local out rc=0
  # -a reads the file as text, so a stray byte can never turn the line list into "Binary file matches".
  out="$(grep -a -n "$1" -e "$2" -- "$3")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" | cut -d: -f1 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# Reports every private-content marker in file $1 as "<$2>:<line>: private-content: <kind>". Returns 0
# when there is none, 1 when there is one and 2 when the file cannot be read.
scan_private() {
  local i=0 rc lines line any=0
  # Blanks the template's rule line in a copy, so line numbers still match the file.
  awk -v rule="$template_rule_line" '{ l = $0; sub(/\r$/, "", l); print (l == rule ? "" : $0) }' "$1" >"$tmp/scan.txt" ||
    return 2
  while [ "$i" -lt "${#private_kinds[@]}" ]; do
    rc=0
    lines="$(matching_lines "${private_flags[$i]}" "${private_patterns[$i]}" "$tmp/scan.txt")" || rc=$?
    case "$rc" in
      0)
        while IFS= read -r line; do
          finding "$2:$line: private-content: ${private_kinds[$i]}"
        done <<<"$lines"
        any=1
        ;;
      1) ;;
      *) return 2 ;;
    esac
    i=$((i + 1))
  done
  return "$any"
}

# Loads ask $1 (an index into the sorted asks) into ask_number, ask_url, ask_title, ask_missing and
# ask_private, writing each section's text to $tmp/section-<k>.md. Reports each missing section and
# each private-content marker.
load_ask() {
  local k name rc
  ask_number="$(jq -r --argjson i "$1" '.[$i].number' "$tmp/asks.json")"
  ask_url="$(jq -r --argjson i "$1" '.[$i].html_url' "$tmp/asks.json")"
  ask_title="$(jq -r --argjson i "$1" '.[$i].title | sub("^🙋 *Ask: *"; "")' "$tmp/asks.json" | quiet_mentions)"
  jq -r --argjson i "$1" '.[$i].body // ""' "$tmp/asks.json" >"$tmp/ask-body.md"
  ask_missing=""
  printf '%s\n' "$ask_title" >"$tmp/ask-text.md"
  k=0
  for name in "${ask_sections[@]}"; do
    section_text "$tmp/ask-body.md" "$name" | quiet_mentions >"$tmp/section-$k.md"
    cat "$tmp/section-$k.md" >>"$tmp/ask-text.md"
    if [ ! -s "$tmp/section-$k.md" ]; then
      ask_missing="${ask_missing:+$ask_missing, }$name"
      finding "MISSING-SECTION #$ask_number $name"
    fi
    k=$((k + 1))
  done
  rc=0
  scan_private "$tmp/ask-text.md" "#$ask_number" || rc=$?
  case "$rc" in
    0) ask_private=0 ;;
    1) ask_private=1 ;;
    *) unknown "could not check the text of #$ask_number" ;;
  esac
}

# Writes the Needs you section for the open asks to stdout. Every ask is listed: a missing section is
# named in the digest, an ask showing private content is listed with its text held back, and another
# account's ask is named by its number only. With $1 = brief, each ask is a numbered link only.
render_needs_you() {
  local brief=${1:-} count i k name others number
  count="$(jq 'length' "$tmp/asks.json")"
  printf '## Needs you\n\n'
  [ "$count" -gt 0 ] || printf 'Nothing needs you right now.\n'
  [ "$brief" != brief ] || [ "$count" -eq 0 ] ||
    printf '_The asks are too long to show in full here, so open each one to read it._\n\n'
  i=0
  while [ "$i" -lt "$count" ]; do
    load_ask "$i"
    if [ "$ask_private" -eq 1 ]; then
      [ "$i" -eq 0 ] || [ "$brief" = brief ] || printf '\n'
      printf '### %s. Held back ([#%s](%s))\n' "$((i + 1))" "$ask_number" "$ask_url"
      printf '\n> ⚠️ #%s shows private content, so its text is not repeated here. Edit the ask to remove it.\n' "$ask_number"
      i=$((i + 1))
      continue
    fi
    if [ "$brief" = brief ]; then
      printf -- '- %s. Ask [#%s](%s)\n' "$((i + 1))" "$ask_number" "$ask_url"
      i=$((i + 1))
      continue
    fi
    [ "$i" -eq 0 ] || printf '\n'
    printf '### %s. Ask [#%s](%s)\n' "$((i + 1))" "$ask_number" "$ask_url"
    printf '\n**Title**\n\n'
    printf '%s\n' "$ask_title" | as_code
    [ -z "$ask_missing" ] || printf '\n> ⚠️ #%s is missing: %s.\n' "$ask_number" "$ask_missing"
    k=0
    for name in "${ask_sections[@]}"; do
      printf '\n**%s**\n\n' "$name"
      if [ -s "$tmp/section-$k.md" ]; then
        as_code <"$tmp/section-$k.md"
      else
        printf '_Missing: #%s has no %s section._\n' "$ask_number" "$name"
      fi
      k=$((k + 1))
    done
    i=$((i + 1))
  done
  others=""
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    others="${others:+$others, }#$number"
    finding "UNTRUSTED-ASK #$number"
  done <"$tmp/untrusted.txt"
  [ -z "$others" ] || printf '\nAsks another account filed, named here without their text: %s.\n' "$others"
}

# Checks one digest file. Returns 0 when clean, 1 with each finding printed, 2 when it cannot be read.
check_file() {
  local f=$1 bad=0 name stats count first prev=0 rc
  { [ -f "$f" ] && [ -r "$f" ]; } || return 2
  if [ ! -s "$f" ]; then
    finding "$f: empty"
    return 1
  fi
  # The first line that is not blank must be one of the agents' disclosure lines, as on every artifact
  # they author: a summary that dropped it would go out without it.
  if ! awk '
      { sub(/\r$/, ""); sub(/[ \t]+$/, "") }
      $0 == "" { next }
      { ok = ($0 == "> 🤖 Generated by the Agentic Engineer" || $0 == "> 🤖 Generated by the Agent Improver"); exit }
      END { exit ok ? 0 : 1 }' "$f"; then
    finding "$f: disclosure: the first line is not the agents' disclosure line"
    bad=1
  fi
  for name in "${digest_sections[@]}"; do
    stats="$(awk -v h="## $name" '
      { sub(/\r$/, ""); sub(/[ \t]+$/, "") }
      $0 == h { n++; if (!first) first = NR }
      END { print n + 0, first + 0 }' "$f")" || return 2
    count="${stats% *}"
    first="${stats#* }"
    if [ "$count" -eq 0 ]; then
      finding "$f: missing-section: $name"
      bad=1
    elif [ "$count" -gt 1 ]; then
      finding "$f:$first: repeated-section: $name"
      bad=1
    elif [ "$first" -lt "$prev" ]; then
      finding "$f:$first: section-order: $name"
      bad=1
    fi
    [ "$count" -eq 0 ] || prev="$first"
  done
  if ! awk -v h="## How to reply" '
      { sub(/\r$/, ""); sub(/[ \t]+$/, "") }
      # Only the How to reply section counts: the next level-two heading ends it.
      seen && /^## / && $0 != h { seen = 0 }
      # The whole canonical line, so a continuation such as "? No, it stays private" never passes.
      seen && $0 ~ /^Your reply posts publicly, as a comment on this issue in the public [A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+ repository\.$/ { ok = 1 }
      $0 == h { seen = 1 }
      END { exit ok ? 0 : 1 }' "$f"; then
    finding "$f: reply-note: How to reply lacks the line \"Your reply posts publicly, as a comment on this issue in the public OWNER/REPO repository.\""
    bad=1
  fi
  rc=0
  scan_private "$f" "$f" || rc=$?
  case "$rc" in
    0) ;;
    1) bad=1 ;;
    *) return 2 ;;
  esac
  return "$bad"
}

# Writes file $1 with its Needs you section replaced by $tmp/needs-you.md. `check` has already proved
# the section appears once and that a later section ends it.
compose_body() {
  awk -v needs="$tmp/needs-you.md" '
    { line = $0; sub(/\r$/, "", line); sub(/[ \t]+$/, "", line) }
    line == "## Needs you" { while ((getline l < needs) > 0) print l; print ""; skipping = 1; next }
    skipping && line ~ /^## / { skipping = 0 }
    !skipping { print }' "$1"
}

# Writes the fallback digest for $1, the reason the summary is missing, to $tmp/body.md.
compose_fallback() {
  {
    printf '> 🤖 Generated by the Agentic Engineer\n\n'
    printf '**The summary is missing for this digest:** %s, so it lists only the open asks.\n\n' "$1"
    cat "$tmp/needs-you.md"
    printf '\n## How to reply\n\n%s\n%s\n' \
      "Reply on this GitHub issue (or to its notification email) with an ask's number and your choice, for example \`1: B\`, or the number, a colon and your own words, for example \`3: your words\`." \
      "Your reply posts publicly, as a comment on this issue in the public $repo repository."
  } >"$tmp/body.md"
}

# Combine a fitting oldest-first batch of reviewed summaries not recorded in an assigned delivery.
# Receipts live in the email itself; deferred content and failed assignment advance no file cursor.
prepare_pending_summaries() {
  local candidate date hash count=0 marker receipt existing rc held_back=0 selected_count=0
  : >"$tmp/sent-summary-records.jsonl"
  while IFS= read -r existing; do
    jq -r --argjson n "$existing" '.[] | select(.number == $n) | .body | split("\n")[1] // ""' \
      "$tmp/digests.json" >"$tmp/receipt-line.txt"
    marker=$(cat "$tmp/receipt-line.txt")
    case "$marker" in
      '<!-- maintainer-digest-summaries-v1: '*' -->')
        receipt=${marker#'<!-- maintainer-digest-summaries-v1: '}
        receipt=${receipt%' -->'}
        printf '%s\n' "$receipt" | jq -c 'if type == "array" and all(.[];
          type == "object" and (.date | type) == "string" and (.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
          and (.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$")))
          then .[] else error("invalid summary receipt") end' >>"$tmp/sent-summary-records.jsonl" ||
          unknown "could not read a delivered summary receipt"
        ;;
    esac
  done <"$tmp/delivery-numbers.txt"
  jq -s . "$tmp/sent-summary-records.jsonl" >"$tmp/sent-summaries.json"
  : >"$tmp/pending-summary-records.jsonl"
  : >"$tmp/shipped.md"
  : >"$tmp/pending-files.txt"
  for candidate in "$dir"/????-??-??.md; do
    [ -e "$candidate" ] || continue
    date=${candidate##*/}; date=${date%.md}
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$date" < "$day" || "$date" = "$day" ]] || continue
    if [ ! -f "$candidate" ] || [ ! -r "$candidate" ]; then
      unknown "cannot read $candidate"
    fi
    hash=$(shasum -a 256 "$candidate" | awk '{print $1}') || unknown "cannot hash $candidate"
    if jq -e --arg date "$date" --arg hash "$hash" 'any(.[]; .date == $date and .sha256 == $hash)' "$tmp/sent-summaries.json" >/dev/null; then
      continue
    fi
    rc=0
    check_file "$candidate" || rc=$?
    case "$rc" in
      0) ;;
      1) held_back=1; reason="a pending summary failed the digest check, so it was held back"; continue ;;
      *) unknown "cannot read $candidate" ;;
    esac
    printf '%s\n' "$candidate" >>"$tmp/pending-files.txt"
    jq -nc --arg date "$date" --arg hash "$hash" '{date:$date,sha256:$hash}' >>"$tmp/pending-summary-records.jsonl"
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    [ -n "$reason" ] || reason="no pending reviewed summary is available for $day"
    return 0
  fi
  reason=""
  : >"$tmp/selected-shipped.md"
  : >"$tmp/selected-records.jsonl"
  while IFS= read -r candidate; do
    cp "$tmp/selected-shipped.md" "$tmp/trial-shipped.md"
    if [ "$count" -gt 1 ]; then
      date=${candidate##*/}; printf '**%s**\n\n' "${date%.md}" >>"$tmp/trial-shipped.md"
    fi
    awk '{ sub(/\r$/, ""); line=$0; sub(/[ \t]+$/, "", line) }
      line == "## What shipped" { inside=1; next } inside && line ~ /^## / { exit } inside { print }' \
      "$candidate" >>"$tmp/trial-shipped.md"
    cp "$tmp/selected-records.jsonl" "$tmp/trial-records.jsonl"
    date=${candidate##*/}; date=${date%.md}
    jq -ec --arg date "$date" 'select(.date == $date)' "$tmp/pending-summary-records.jsonl" >>"$tmp/trial-records.jsonl" ||
      unknown "could not select pending summary receipts"
    jq -sc . "$tmp/trial-records.jsonl" >"$tmp/summary-receipt.json" || unknown "could not compose summary receipts"
    cp "$tmp/trial-shipped.md" "$tmp/shipped.md"
    if [ "$held_back" -eq 1 ]; then
      printf '\n> ⚠️ A pending changelog was held back because it did not pass its checks.\n' >>"$tmp/shipped.md"
    fi
    if [ "$((selected_count + 1))" -lt "$count" ]; then
      printf '\n> More changelog content remains pending for a later ask.\n' >>"$tmp/shipped.md"
    fi
    receipt=$(cat "$tmp/summary-receipt.json")
    awk -v shipped="$tmp/shipped.md" -v receipt="$receipt" '
      { sub(/\r$/, ""); header=$0; sub(/[ \t]+$/, "", header) }
      !started && header == "" { next }
      !started { print header; print "<!-- maintainer-digest-summaries-v1: " receipt " -->"; started=1; next }
      header == "## What shipped" { print header; while ((getline line < shipped) > 0) print line; skipping=1; next }
      skipping && header ~ /^## / { skipping=0 }
      !skipping { print }' "$candidate" >"$tmp/combined-summary.md"
    compose_body "$tmp/combined-summary.md" >"$tmp/body.md"
    if too_long "$tmp/body.md"; then
      # Keep a completed fitting batch. If this one cannot fit even alone, try a later summary
      # instead of blocking every smaller summary behind it. No receipt is recorded for the skip.
      [ "$selected_count" -eq 0 ] || break
      continue
    fi
    cp "$tmp/trial-shipped.md" "$tmp/selected-shipped.md"
    cp "$tmp/trial-records.jsonl" "$tmp/selected-records.jsonl"
    cp "$tmp/body.md" "$tmp/accepted-body.md"
    selected_count=$((selected_count + 1))
  done <"$tmp/pending-files.txt"
  if [ "$selected_count" -eq 0 ]; then
    reason="the combined pending summaries were too long to send"
    return 0
  fi
  cp "$tmp/accepted-body.md" "$tmp/body.md"
}

# Tests the conservative byte limit before an issue body is submitted to GitHub.
too_long() {
  [ "$(wc -c <"$1")" -gt "$max_body_bytes" ]
}

# Checks each requested digest and preserves the distinction between findings and unreadable files.
cmd_check() {
  local f rc any=0
  [ "$#" -gt 0 ] || usage "check needs at least one file"
  for f in "$@"; do
    rc=0
    check_file "$f" || rc=$?
    case "$rc" in
      0) ;;
      1) any=1 ;;
      *) unknown "cannot read $f" ;;
    esac
  done
  [ "$any" -eq 1 ] || echo "CLEAN: $# digest file(s) checked"
  finish "$any"
}

# Fetches current asks and renders their public-safe Needs you section without making writes.
cmd_needs_you() {
  repo="${GITHUB_REPOSITORY:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) need_value "$@"; repo=$2; shift 2 ;;
      *) usage "unknown needs-you option: $1" ;;
    esac
  done
  check_repo
  fetch_asks
  render_needs_you
  finish "$found"
}

# Close only open bot digests through the requested UTC date, except #$1 (0 keeps none).
# A preview reports the plan, and a backfill never closes a later digest.
close_earlier() {
  local keep=$1 n
  jq -r --arg bot "$bot" --argjson keep "$keep" --argjson end "$send_end" 'map(select(.user.login == $bot and .state == "open" and .number != $keep
      and (.created_at | fromdateiso8601) < $end) | .number) | .[]' \
    "$tmp/digests.json" >"$tmp/earlier.txt" || unknown "could not list the earlier digests"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    # Closing an assigned issue can send another notification. Keep the reply thread;
    # the engineer closes it only after its asks have been reconciled.
    echo "RETAINED #$n: the earlier digest reply thread"
  done <"$tmp/earlier.txt"
}

# Send a dated digest when due; retire earlier bot digests only after confirmed assignment.
cmd_send() {
  local day="" dir="" dry_run=0 day_start send_end title file reason="" existing number assigned=1
  repo="${GITHUB_REPOSITORY:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) need_value "$@"; repo=$2; shift 2 ;;
      --date) need_value "$@"; day=$2; shift 2 ;;
      --dir) need_value "$@"; dir=$2; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) usage "unknown send option: $1" ;;
    esac
  done
  check_repo
  [ -n "$day" ] || day="$(date -u +%Y-%m-%d)"
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage "--date must look like 2026-10-24"
  day_start="$(jq -en --arg day "$day" '$day + "T00:00:00Z" | fromdateiso8601
    | select(strftime("%Y-%m-%d") == $day)')" || usage "--date must be a real UTC date"
  send_end=$((day_start + 86400))
  [ -n "$dir" ] || dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docs/digests"
  title="🙋 Maintainer digest — $day"
  file="$dir/$day.md"

  load_delivery_history
  fetch_asks
  if [ "$(jq 'length' "$tmp/asks.json")" -eq 0 ]; then
    echo "NO-ASKS: no unanswered asks; pending changelogs remain for the next ask"
    finish 0
  fi
  # A digest GitHub did not assign to him was never emailed, so it does not count as sent. The title
  # may name a legacy ISO week or a date. Use its creation date, not its title or open state, to
  # prevent a second delivery on the same UTC day. A future delivery suppresses a backfill.
  existing="$(jq -r --arg bot "$bot" --arg who "$maintainer" --argjson start "$day_start" '
    map(select(.user.login == $bot and any(.assignees[]; .login == $who)
      and (.title | test("^🙋 Maintainer digest — (week ([1-9]|[1-4][0-9]|5[0-3])|[0-9]{4}-[0-9]{2}-[0-9]{2})$"))
      and (.created_at | fromdateiso8601) >= $start))
    | sort_by(.created_at) | last | .number // empty' "$tmp/digests.json")"
  if [ -n "$existing" ]; then
    echo "ALREADY-SENT #$existing: a digest was already delivered for this UTC day"
    # A rerun after a failed close still retires earlier open digests, keeping the newest one.
    close_earlier "$existing" "$dry_run"
    finish "$found"
  fi
  render_needs_you >"$tmp/needs-you.md"

  prepare_pending_summaries
  if [ -n "$reason" ]; then
    finding "FALLBACK: $reason"
    compose_fallback "$reason"
    if too_long "$tmp/body.md"; then
      render_needs_you brief >"$tmp/needs-you.md"
      compose_fallback "$reason"
      ! too_long "$tmp/body.md" || unknown "even the shortest digest is too long to send"
    fi
  fi

  if [ "$dry_run" -eq 1 ]; then
    echo "DRY-RUN would open \"$title\", labelled $digest_label and assigned to $maintainer, from ${reason:+the fallback because }${reason:-$file}"
    echo "--- body ---"
    cat "$tmp/body.md"
    echo "--- end of body ---"
    close_earlier 0 1
    finish "$found"
  fi

  jq -n --arg title "$title" --rawfile body "$tmp/body.md" --arg who "$maintainer" --arg label "$digest_label" \
    '{title: $title, body: $body, assignees: [$who], labels: [$label]}' >"$tmp/payload.json"
  gh api -X POST "repos/$repo/issues" --input "$tmp/payload.json" >"$tmp/created.json" ||
    unknown "could not open the digest issue"
  # An incomplete response cannot show whether he was assigned, so the earlier digests stay open.
  jq -e --argjson spec "$required_created" "$conforms_def"' conforms($spec)' "$tmp/created.json" >/dev/null 2>&1 ||
    unknown "an unexpected or incomplete response when opening the digest issue"
  number="$(jq -r '.number' "$tmp/created.json")" || unknown "an unexpected response when opening the digest issue"
  echo "SENT #$number: \"$title\" from ${reason:+the fallback because }${reason:-$file}"
  # GitHub drops an assignee it cannot assign without an error, and then no email goes out. The
  # earlier digest then stays open: it is still the newest one he received.
  if ! jq -e --arg who "$maintainer" 'any(.assignees[]; .login == $who)' "$tmp/created.json" >/dev/null; then
    finding "NOT-ASSIGNED #$number: GitHub did not assign $maintainer, so the digest was not emailed"
    assigned=0
  fi
  [ "$assigned" -eq 0 ] || close_earlier 0 0
  finish "$found"
}

# Urgent notifications share the daily workflow's concurrency group. Sweep the whole queue:
# GitHub replaces pending concurrency runs, so the triggering issue alone is not a durable queue.
# Assignment events are the ledger, including closed/relabelled issues and ambiguous retries.
cmd_urgent() {
  local dry=0 number count today
  repo="${GITHUB_REPOSITORY:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) need_value "$@"; repo=$2; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) usage "unknown urgent option: $1" ;;
    esac
  done
  check_repo
  fetch_asks
  jq -r '.[] | select(any(.labels[]; .name == "maintainer-ask-urgent")) | .number' \
    "$tmp/asks.json" >"$tmp/urgent-numbers.txt"
  if [ ! -s "$tmp/urgent-numbers.txt" ]; then echo "NO-URGENT-ASKS"; finish 0; fi
  read_issues "repos/$repo/issues/events?per_page=100" "$tmp/events.json" \
    '{"id":"number","event":"string","created_at":"timestamp"}'
  jq -e "$conforms_def"' all(.[] | select(.event == "assigned");
    conforms({"actor.login":"string","assignee.login":"string","issue.number":"number"}))' \
    "$tmp/events.json" >/dev/null || unknown "incomplete assignment history"
  today=$(date -u +%Y-%m-%d)
  # Count all bot assignments conservatively, except authenticated daily digest issues.
  # Removing an urgent label or closing an ask cannot replenish the notification budget.
  jq --arg who "$maintainer" --arg bot "$bot" --slurpfile digests "$tmp/digests.json" '
    [$digests[0][] | select(.user.login == $bot and (.title | startswith("🙋 Maintainer digest — "))) | .number] as $digestids
    | map(select(.event == "assigned" and .actor.login == $bot and .assignee.login == $who)
      | select(.issue.number as $n | ($digestids | index($n)) == null))' \
    "$tmp/events.json" >"$tmp/assignments.json" || unknown "could not classify assignment history"
  count=$(jq --arg day "$today" '[.[] | select(.created_at[0:10] == $day)] | length' "$tmp/assignments.json")
  while IFS= read -r number; do
    # Re-read the actual target and human replies immediately before each write.
    gh api "repos/$repo/issues/$number" >"$tmp/current.json" || unknown "could not refresh urgent #$number"
    jq -e --argjson spec "$required_ask" --argjson n "$number" "$conforms_def"' conforms($spec) and .number == $n and (has("pull_request") | not)' \
      "$tmp/current.json" >/dev/null || unknown "incomplete urgent #$number"
    jq -e '.state == "open" or .state == "closed"' "$tmp/current.json" >/dev/null || unknown "invalid urgent state"
    jq -s --arg who "$maintainer" 'map(select(.state == "open" and .user.login == $who
      and any(.labels[]; .name == "maintainer-ask") and any(.labels[]; .name == "maintainer-ask-urgent")))' \
      "$tmp/current.json" >"$tmp/asks.json"
    filter_answered_asks
    [ "$(jq length "$tmp/asks.json")" -gt 0 ] || continue
    if jq -e --argjson n "$number" 'any(.[]; .issue.number == $n)' "$tmp/assignments.json" >/dev/null; then
      echo "ALREADY-DELIVERED #$number"
      continue
    fi
    if jq -e --arg who "$maintainer" 'any(.assignees[]; .login == $who)' "$tmp/current.json" >/dev/null; then
      unknown "urgent #$number is assigned without a proven bot delivery; never toggle its assignment"
    fi
    if [ "$count" -ge 3 ]; then
      if [ "$dry" -eq 0 ] && ! jq -e 'any(.labels[]; .name == "maintainer-ask-cap-delayed")' "$tmp/current.json" >/dev/null; then
        gh api -X POST "repos/$repo/issues/$number/labels" -f 'labels[]=maintainer-ask-cap-delayed' >/dev/null ||
          unknown "could not mark cap-delayed #$number"
        gh api "repos/$repo/issues/$number" >"$tmp/marked.json" || unknown "could not verify cap delay"
        jq -e --argjson n "$number" '.number == $n and any(.labels[]; .name == "maintainer-ask-cap-delayed")' "$tmp/marked.json" >/dev/null ||
          unknown "cap delay did not read back"
      fi
      echo "CAP-DELAYED #$number"
      continue
    fi
    load_ask 0
    [ "$ask_private" -eq 0 ] && [ -z "$ask_missing" ] || unknown "urgent #$number is not public-safe and complete"
    if [ "$dry" -eq 1 ]; then
      echo "WOULD-ASSIGN #$number"
    else
      gh api -X POST "repos/$repo/issues/$number/assignees" -f "assignees[]=$maintainer" >"$tmp/assigned.json" ||
        unknown "assignment of urgent #$number is ambiguous; retry against the event ledger"
      jq -e --argjson spec "$required_created" --argjson n "$number" --arg who "$maintainer" "$conforms_def"'
        conforms($spec) and .number == $n and any(.assignees[]; .login == $who)' "$tmp/assigned.json" >/dev/null ||
        unknown "urgent #$number assignment was not confirmed"
      gh api "repos/$repo/issues/$number" >"$tmp/assigned-readback.json" || unknown "could not verify urgent assignment"
      jq -e --argjson spec "$required_ask" --argjson n "$number" --arg who "$maintainer" "$conforms_def"'
        conforms($spec) and .number == $n and any(.assignees[]; .login == $who)' "$tmp/assigned-readback.json" >/dev/null ||
        unknown "urgent assignment did not read back"
      gh api -X POST "repos/$repo/issues/$number/labels" -f 'labels[]=maintainer-ask-delivered' >/dev/null ||
        unknown "urgent #$number delivered but marker failed; retry against the event ledger"
      echo "DELIVERED #$number"
    fi
    count=$((count + 1))
  done <"$tmp/urgent-numbers.txt"
  finish "$found"
}

[ "$#" -gt 0 ] || usage "a subcommand is required"
subcommand=$1
shift
case "$subcommand" in
  send) cmd_send "$@" ;;
  needs-you) cmd_needs_you "$@" ;;
  check) cmd_check "$@" ;;
  urgent) cmd_urgent "$@" ;;
  *) usage "unknown subcommand: $subcommand" ;;
esac
