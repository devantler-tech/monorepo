#!/usr/bin/env bash
# maintainer-digest.sh — send the weekly maintainer digest, and urgent asks, by email (ADR 0009
# phase 1, monorepo#4285).
#
# Why this exists. The agents act through the maintainer's own GitHub account, and GitHub never
# emails a user about their own activity, so an ask an agent files never reaches him on its own. The
# Slack DM that carried asks left answers unread for weeks (monorepo#3888). GitHub does email him an
# issue that github-actions[bot] opens and assigns to him, so two workflows send for the agents:
# maintainer-digest.yaml every Monday, and maintainer-ask-urgent.yaml when an ask is marked urgent.
# This script is their logic, kept here so it can be tested.
#
# Subcommands:
#   send [--repo OWNER/REPO] [--week YYYY-Www] [--dir DIR] [--dry-run]
#     Open DIR/<week>.md (default docs/digests, the current ISO week in UTC) as the issue
#     "🙋 Maintainer digest — week <n>", labelled maintainer-digest and assigned to the maintainer,
#     then close the earlier digests github-actions[bot] opened. When the file is missing, too long or
#     fails `check`, a short digest of the open asks goes instead, saying the summary is missing.
#     Nothing is sent when that week's digest is already open.
#   needs-you [--repo OWNER/REPO]
#     Print the "Needs you" section for the open asks: the one the fallback sends, and the one to
#     paste into the week's file.
#   urgent --issue N --label NAME --sender LOGIN [--repo OWNER/REPO] [--today YYYY-MM-DD] [--dry-run]
#     Assign the maintainer to an urgent ask, so GitHub emails him at once. At most three a UTC day.
#   check FILE...
#     Check a digest file: its four sections in order, the note that a reply posts publicly, and no
#     private-content marker. A finding names the file, the line and the kind, never the text found.
#
# Anyone can open an issue through the ask form, so only asks the maintainer's own account filed are
# shown. Another account's ask is named by its number and its text is left out.
#
# Exit: 0 done with no finding; 1 a finding or a refusal, each printed (a digest with a finding is
# still sent); 2 unknown: a usage error, an unreadable input, a failed GitHub read or write, or an
# abort before the end.
set -euo pipefail

tmp="$(mktemp -d)"
maintainer_digest_finished=0
# Bash 3.2 can hand an EXIT trap a zero status for a `set -u` abort, so only `finish` may leave with
# status 0 (cleanup-trap-fail-closed.test.sh).
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
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

finish() {
  maintainer_digest_finished=1
  exit "$1"
}

maintainer=devantler
bot='github-actions[bot]'
ask_label="maintainer-ask"
urgent_label="maintainer-ask-urgent"
digest_label="maintainer-digest"
urgent_daily_cap=3
# GitHub refuses an issue body over 65,536 characters, and a byte count is never the smaller number.
max_body_bytes=65536
ask_sections=("Question" "Options" "Recommendation" "If unanswered")
digest_sections=("Needs you" "What shipped" "What's in progress" "How to reply")

# Private-content markers: what the template's "Never include" list forbids, in a form a line can
# match. Each kind has its grep flags and an extended regular expression.
private_kinds=(ip-address email-address phone-number money credential private-hostname spend-heading)
private_flags=(-E -E -E -iE -E -iE -iE)
private_patterns=(
  '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)'
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
  '(tel:|\+[0-9]{1,3}[ .-]?[0-9]{2,4}([ .-]?[0-9]{2,4}){2,})'
  '(\$|€|£) ?[0-9]|[0-9][0-9.,]* ?(kr|dkk|eur|usd|gbp|sek|nok|kroner|dollars?|euros?)([^a-z]|$)'
  '(^|[^A-Za-z0-9])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,})|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '[A-Za-z0-9-]\.(internal|local|localdomain|lan|intranet|corp|home\.arpa|ts\.net)([^A-Za-z0-9-]|$)'
  '^#{1,6}[[:space:]].*(spend|money|costs?|invoice|billing|savings?)'
)

found=0
finding() {
  echo "$*" >&2
  found=1
}

usage() {
  echo "maintainer-digest.sh: $*" >&2
  echo "usage: maintainer-digest.sh send|needs-you|urgent|check ... (see the header comment)" >&2
  finish 2
}

unknown() {
  echo "UNKNOWN: $*" >&2
  finish 2
}

need_value() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || usage "$1 needs a value"
}

check_repo() {
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage "--repo OWNER/REPO is required (or GITHUB_REPOSITORY)"
}

# Reads every page of an issue listing into $2 as one JSON array, leaving out pull requests. A failed
# read, an empty response or anything but pages of issues is UNKNOWN, never an empty list.
read_issues() {
  local path=$1 out=$2
  gh api --paginate "$path" >"$tmp/page.json" || unknown "could not read $path"
  [ -s "$tmp/page.json" ] || unknown "an empty response for $path"
  jq -s 'if all(.[]; type == "array") and all(.[][]; type == "object" and (.number | type) == "number")
         then [.[][] | select(has("pull_request") | not)]
         else error("not a list of issues") end' "$tmp/page.json" >"$out" 2>/dev/null ||
    unknown "an unexpected response for $path"
}

# Splits the open asks into the maintainer's own, oldest first, and the numbers of everyone else's.
fetch_asks() {
  read_issues "repos/$repo/issues?state=open&labels=$ask_label&per_page=100" "$tmp/asks-all.json"
  jq --arg who "$maintainer" 'map(select(.user.login == $who)) | sort_by(.number)' \
    "$tmp/asks-all.json" >"$tmp/asks.json" || unknown "could not sort the asks"
  jq -r --arg who "$maintainer" 'map(select(.user.login != $who) | .number) | sort | .[]' \
    "$tmp/asks-all.json" >"$tmp/untrusted.txt" || unknown "could not sort the asks"
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

# Loads ask $1 (an index into the sorted asks) into ask_number, ask_url, ask_title and ask_missing,
# writing each section's text to $tmp/section-<k>.md, and reports each missing section.
load_ask() {
  local k name
  ask_number="$(jq -r --argjson i "$1" '.[$i].number' "$tmp/asks.json")"
  ask_url="$(jq -r --argjson i "$1" '.[$i].html_url' "$tmp/asks.json")"
  ask_title="$(jq -r --argjson i "$1" '.[$i].title | sub("^🙋 *Ask: *"; "")' "$tmp/asks.json")"
  jq -r --argjson i "$1" '.[$i].body // ""' "$tmp/asks.json" >"$tmp/ask-body.md"
  ask_missing=""
  k=0
  for name in "${ask_sections[@]}"; do
    section_text "$tmp/ask-body.md" "$name" >"$tmp/section-$k.md"
    if [ ! -s "$tmp/section-$k.md" ]; then
      ask_missing="${ask_missing:+$ask_missing, }$name"
      finding "MISSING-SECTION #$ask_number $name"
    fi
    k=$((k + 1))
  done
}

# Writes the "Needs you" section for the open asks to stdout. Every ask is listed, a missing section is
# named in the digest as well as reported, and another account's ask is named by number only.
render_needs_you() {
  local count i k name others number
  count="$(jq 'length' "$tmp/asks.json")"
  printf '## Needs you\n\n'
  [ "$count" -gt 0 ] || printf 'Nothing needs you this week.\n'
  i=0
  while [ "$i" -lt "$count" ]; do
    load_ask "$i"
    [ "$i" -eq 0 ] || printf '\n'
    printf '### %s. %s ([#%s](%s))\n' "$((i + 1))" "$ask_title" "$ask_number" "$ask_url"
    [ -z "$ask_missing" ] || printf '\n> ⚠️ #%s is missing: %s.\n' "$ask_number" "$ask_missing"
    k=0
    for name in "${ask_sections[@]}"; do
      printf '\n**%s**\n\n' "$name"
      if [ -s "$tmp/section-$k.md" ]; then
        cat "$tmp/section-$k.md"
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

# Checks one digest file. Returns 0 when clean, 1 with each finding printed, 2 when it cannot be read.
check_file() {
  local f=$1 bad=0 name stats count first prev=0 i lines line rc
  { [ -f "$f" ] && [ -r "$f" ]; } || return 2
  if [ ! -s "$f" ]; then
    finding "$f: empty"
    return 1
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
      seen && tolower($0) ~ /publicly/ { ok = 1 }
      $0 == h { seen = 1 }
      END { exit ok ? 0 : 1 }' "$f"; then
    finding "$f: reply-note: How to reply does not say that a reply posts publicly"
    bad=1
  fi
  i=0
  while [ "$i" -lt "${#private_kinds[@]}" ]; do
    rc=0
    lines="$(matching_lines "${private_flags[$i]}" "${private_patterns[$i]}" "$f")" || rc=$?
    case "$rc" in
      0)
        while IFS= read -r line; do
          finding "$f:$line: private-content: ${private_kinds[$i]}"
        done <<<"$lines"
        bad=1
        ;;
      1) ;;
      *) return 2 ;;
    esac
    i=$((i + 1))
  done
  return "$bad"
}

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

cmd_send() {
  local week="" dir="" dry_run=0 week_number title file reason="" rc existing count i number
  repo="${GITHUB_REPOSITORY:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) need_value "$@"; repo=$2; shift 2 ;;
      --week) need_value "$@"; week=$2; shift 2 ;;
      --dir) need_value "$@"; dir=$2; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) usage "unknown send option: $1" ;;
    esac
  done
  check_repo
  [ -n "$week" ] || week="$(date -u +%G-W%V)"
  [[ "$week" =~ ^[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3])$ ]] || usage "--week must look like 2026-W43"
  [ -n "$dir" ] || dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docs/digests"
  week_number=$((10#${week##*-W}))
  title="🙋 Maintainer digest — week $week_number"
  file="$dir/$week.md"

  read_issues "repos/$repo/issues?state=open&labels=$digest_label&per_page=100" "$tmp/digests.json"
  existing="$(jq -r --arg title "$title" --arg bot "$bot" \
    'map(select(.title == $title and .user.login == $bot) | .number) | first // empty' "$tmp/digests.json")"
  if [ -n "$existing" ]; then
    echo "ALREADY-SENT #$existing: this week's digest is already open, so nothing is sent"
    finish 0
  fi
  fetch_asks

  if [ ! -e "$file" ]; then
    reason="no summary was written for week $week_number"
  elif [ ! -f "$file" ] || [ ! -r "$file" ]; then
    unknown "cannot read $file"
  elif [ "$(wc -c <"$file")" -gt "$max_body_bytes" ]; then
    reason="the summary for week $week_number was too long to send"
  else
    rc=0
    check_file "$file" || rc=$?
    case "$rc" in
      0) ;;
      1) reason="the summary for week $week_number failed the digest check, so it was held back" ;;
      *) unknown "cannot read $file" ;;
    esac
  fi

  if [ -z "$reason" ]; then
    cp "$file" "$tmp/body.md"
    count="$(jq 'length' "$tmp/asks.json")"
    i=0
    while [ "$i" -lt "$count" ]; do
      load_ask "$i"
      grep -Eq -e "(/issues/$ask_number|#$ask_number)([^0-9]|$)" -- "$file" ||
        finding "NOT-IN-SUMMARY #$ask_number: the week's summary does not list this open ask"
      i=$((i + 1))
    done
  else
    finding "FALLBACK: $reason"
    {
      printf '> 🤖 Generated by the Agentic Engineer\n\n'
      printf '**The summary is missing this week:** %s, so this digest lists only the open asks.\n\n' "$reason"
      render_needs_you
      printf '\n## How to reply\n\n%s\n%s\n' \
        "Reply to this email with an ask's number and your choice, for example \`1: B\`, or the number and your own words." \
        "Your reply posts publicly, as a comment on this issue in the public $repo repository."
    } >"$tmp/body.md"
  fi

  jq -r --arg bot "$bot" 'map(select(.user.login == $bot) | .number) | .[]' \
    "$tmp/digests.json" >"$tmp/earlier.txt" || unknown "could not list the earlier digests"

  if [ "$dry_run" -eq 1 ]; then
    echo "DRY-RUN would open \"$title\", labelled $digest_label and assigned to $maintainer, from ${reason:+the fallback because }${reason:-$file}"
    echo "--- body ---"
    cat "$tmp/body.md"
    echo "--- end of body ---"
    while IFS= read -r number; do
      [ -z "$number" ] || echo "DRY-RUN would close the earlier digest #$number"
    done <"$tmp/earlier.txt"
    finish "$found"
  fi

  jq -n --arg title "$title" --rawfile body "$tmp/body.md" --arg who "$maintainer" --arg label "$digest_label" \
    '{title: $title, body: $body, assignees: [$who], labels: [$label]}' >"$tmp/payload.json"
  gh api -X POST "repos/$repo/issues" --input "$tmp/payload.json" >"$tmp/created.json" ||
    unknown "could not open the digest issue"
  number="$(jq -r 'if (.number | type) == "number" then .number else empty end' "$tmp/created.json" 2>/dev/null)" ||
    unknown "an unexpected response when opening the digest issue"
  [ -n "$number" ] || unknown "an unexpected response when opening the digest issue"
  echo "SENT #$number: \"$title\" from ${reason:+the fallback because }${reason:-$file}"
  # GitHub drops an assignee it cannot assign without an error, and then no email goes out.
  jq -e --arg who "$maintainer" 'any(.assignees[]?; .login == $who)' "$tmp/created.json" >/dev/null ||
    finding "NOT-ASSIGNED #$number: GitHub did not assign $maintainer, so the digest was not emailed"
  while IFS= read -r existing; do
    [ -n "$existing" ] || continue
    gh api -X PATCH "repos/$repo/issues/$existing" -f state=closed -f state_reason=completed >/dev/null ||
      unknown "could not close the earlier digest #$existing"
    echo "CLOSED #$existing: the earlier digest"
  done <"$tmp/earlier.txt"
  finish "$found"
}

cmd_urgent() {
  local issue="" label="" sender="" today="" dry_run=0 used=0 m k already
  repo="${GITHUB_REPOSITORY:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) need_value "$@"; repo=$2; shift 2 ;;
      --issue) need_value "$@"; issue=$2; shift 2 ;;
      --label) need_value "$@"; label=$2; shift 2 ;;
      --sender) need_value "$@"; sender=$2; shift 2 ;;
      --today) need_value "$@"; today=$2; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) usage "unknown urgent option: $1" ;;
    esac
  done
  check_repo
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || usage "--issue must be an issue number"
  [ -n "$label" ] || usage "--label is required"
  [ -n "$sender" ] || usage "--sender is required"
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"
  [[ "$today" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage "--today must look like 2026-10-19"

  if [ "$label" != "$urgent_label" ]; then
    echo "SKIP #$issue: the label added is not $urgent_label, so nobody is assigned"
    finish 0
  fi
  if [ "$sender" != "$maintainer" ]; then
    finding "REFUSED #$issue: only the maintainer's account may mark an ask urgent"
    finish 1
  fi

  gh api "repos/$repo/issues/$issue" >"$tmp/issue.json" || unknown "could not read #$issue"
  jq -e --argjson n "$issue" 'type == "object" and .number == $n' "$tmp/issue.json" >/dev/null 2>&1 ||
    unknown "an unexpected response for #$issue"
  if jq -e 'has("pull_request")' "$tmp/issue.json" >/dev/null; then
    finding "REFUSED #$issue: a pull request is not an ask"
    finish 1
  fi
  if ! jq -e '.state == "open"' "$tmp/issue.json" >/dev/null; then
    echo "SKIP #$issue: the ask is closed"
    finish 0
  fi
  if ! jq -e --arg l "$urgent_label" 'any(.labels[]?; .name == $l)' "$tmp/issue.json" >/dev/null; then
    echo "SKIP #$issue: the ask no longer carries $urgent_label"
    finish 0
  fi

  # An assignment updates the issue, so every urgent ask assigned today was updated today.
  read_issues "repos/$repo/issues?state=all&labels=$urgent_label&since=${today}T00:00:00Z&per_page=100" "$tmp/urgent.json"
  jq -r '.[].number' "$tmp/urgent.json" >"$tmp/urgent.txt" || unknown "could not list today's urgent asks"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    gh api --paginate "repos/$repo/issues/$m/events?per_page=100" >"$tmp/events.json" ||
      unknown "could not read the events of #$m"
    [ -s "$tmp/events.json" ] || unknown "an empty response for the events of #$m"
    k="$(jq -s --arg bot "$bot" --arg who "$maintainer" --arg day "$today" '
      if all(.[]; type == "array") then
        [.[][] | select(.event == "assigned" and .actor.login == $bot and .assignee.login == $who
                        and ((.created_at // "") | startswith($day)))] | length
      else error("not a list of events") end' "$tmp/events.json" 2>/dev/null)" ||
      unknown "an unexpected response for the events of #$m"
    used=$((used + k))
  done <"$tmp/urgent.txt"
  if [ "$used" -ge "$urgent_daily_cap" ]; then
    finding "REFUSED #$issue: $used urgent asks were already assigned today (UTC), and the limit is $urgent_daily_cap"
    finish 1
  fi

  already="$(jq --arg who "$maintainer" 'any(.assignees[]?; .login == $who)' "$tmp/issue.json")"
  if [ "$dry_run" -eq 1 ]; then
    [ "$already" != true ] ||
      echo "DRY-RUN would first remove the existing assignment, because assigning him again would not email him"
    echo "DRY-RUN would assign $maintainer to #$issue: urgent assignment $((used + 1)) of $urgent_daily_cap today (UTC)"
    finish 0
  fi
  if [ "$already" = true ]; then
    gh api -X DELETE "repos/$repo/issues/$issue/assignees" -f "assignees[]=$maintainer" >/dev/null ||
      unknown "could not remove the existing assignment on #$issue"
  fi
  gh api -X POST "repos/$repo/issues/$issue/assignees" -f "assignees[]=$maintainer" >"$tmp/assigned.json" ||
    unknown "could not assign #$issue"
  if ! jq -e --arg who "$maintainer" 'any(.assignees[]?; .login == $who)' "$tmp/assigned.json" >/dev/null 2>&1; then
    finding "NOT-ASSIGNED #$issue: GitHub did not assign $maintainer, so no email went out"
    finish 1
  fi
  echo "ASSIGNED #$issue: urgent assignment $((used + 1)) of $urgent_daily_cap today (UTC)"
  finish 0
}

[ "$#" -gt 0 ] || usage "a subcommand is required"
subcommand=$1
shift
case "$subcommand" in
  send) cmd_send "$@" ;;
  needs-you) cmd_needs_you "$@" ;;
  urgent) cmd_urgent "$@" ;;
  check) cmd_check "$@" ;;
  *) usage "unknown subcommand: $subcommand" ;;
esac
