#!/usr/bin/env bash
# board-add.sh — put an issue on the 🌊 Project Board *with* a Status, atomically.
#
# WHY THIS EXISTS
#   `gh project item-add` has no Status option, so adding an issue to the board is
#   two commands. The first exits 0 and prints an item id, so a half-completed add
#   is indistinguishable from a successful one — and a status-less item is invisible
#   in board layout and unsortable in triage, which defeats the board as a surface.
#   Measured 2026-07-19: 0 status-less items at 15:25Z, 9 at 19:2xZ, all created that
#   day. The contract already described the two-step in detail; prose did not hold.
#
#   So this script does both halves and then VERIFIES by reading the Status back.
#   A success here means the status is on the board, not that a command exited 0.
#
# USAGE
#   .claude/scripts/board-add.sh <issue-url> [status-name]
#   .claude/scripts/board-add.sh https://github.com/devantler-tech/ksail/issues/42
#   .claude/scripts/board-add.sh <issue-url> "🫴 Ready"
#
#   Default status is "📥 Backlog" — the contract's landing column for new work.
#
# EXIT CODES
#   0  item is on the board and carries the requested Status (verified by read-back)
#   1  usage error
#   2  add or set failed, or the read-back did not show the requested Status
#
# NOTES
#   - Idempotent: an issue already on the board is not duplicated; its Status is
#     set (or corrected) and verified all the same.
#   - PRIVATE REPOS: project 5 is PUBLIC. Adding an item from a private repo is a
#     maintainer decision, never an agent default — this script refuses one.
#   - Serialized on purpose: GitHub's secondary limits allow ~80 content-generating
#     requests/minute. Never fan this out concurrently.

set -euo pipefail

readonly PROJECT_NUMBER=5
readonly PROJECT_OWNER="devantler-tech"
readonly DEFAULT_STATUS="📥 Backlog"
# Fields default to 30 per page and the documented project cap is 50, so Status
# can fall off the first page and read as "field missing" on a project that has
# it. Ask for the whole set.
readonly FIELD_PAGE_LIMIT=100

# The CANONICAL ladder, as documented in the contract. Deliberately a local
# constant rather than the live option names: option names are editable by
# anyone with project write access, so echoing them into this agent's transcript
# would put board-controlled text in front of a high-authority reader. Untrusted
# input is never echoed unbounded — see AGENTS.md → Untrusted input / Egress.
readonly STATUS_LADDER='✅ Done | 📊 Verifying | 🚀 Ready to Merge | 👀 In Review
          🏃🏻‍♂️ In Progress | 🫴 Ready | 📥 Backlog | 🧊 Icebox'

die() { printf 'board-add: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() {
  cat >&2 <<EOF
usage: board-add.sh <issue-url> [status-name]

  <issue-url>    full https://github.com/<owner>/<repo>/issues/<n> URL
  [status-name]  board Status, default "${DEFAULT_STATUS}"

Statuses: ${STATUS_LADDER}
EOF
  exit 1
}

[ $# -ge 1 ] || usage
ISSUE_URL="$1"
STATUS_NAME="${2:-$DEFAULT_STATUS}"

case "$ISSUE_URL" in
  https://github.com/*/*/issues/*) : ;;
  *) die "not an issue URL: ${ISSUE_URL} (expected https://github.com/<owner>/<repo>/issues/<n>)" 1 ;;
esac

# Resolve owner/repo from the URL so the private-repo check reads the right repo.
_path="${ISSUE_URL#https://github.com/}"
REPO_OWNER="${_path%%/*}"
_rest="${_path#*/}"
REPO_NAME="${_rest%%/*}"

command -v gh >/dev/null 2>&1 || die "gh CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

# ORG SCOPE, checked before the repo is even inspected. Cross-repo scope is
# closed by default (AGENTS.md → Merge policy), so an arbitrary external issue
# URL must not cause this script to probe that repository, let alone put it on
# the org board. This is a scope gate, not a convenience check.
[ "$REPO_OWNER" = "$PROJECT_OWNER" ] \
  || die "refusing ${REPO_OWNER}/${REPO_NAME}: only ${PROJECT_OWNER} issues belong on this board" 1

# FAIL CLOSED on visibility: project 5 is public, so a private repo's issue must
# never be swept onto it by an agent. An unreadable repo is treated as private.
IS_PRIVATE=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}" --jq '.private' 2>/dev/null || echo "unknown")
case "$IS_PRIVATE" in
  false) : ;;
  true)  die "${REPO_OWNER}/${REPO_NAME} is PRIVATE; project 5 is public — adding it is a maintainer decision, not an agent default" ;;
  *)     die "could not determine visibility of ${REPO_OWNER}/${REPO_NAME}; refusing (fail-closed)" ;;
esac

# Field metadata. Resolved live rather than hardcoded: option ids change whenever
# the maintainer edits the column set, and a stale id sets the WRONG column silently.
#
# NOTE the `|| die` on each assignment. Under `set -euo pipefail` a failing gh
# makes the ASSIGNMENT fail, which aborts the script immediately — before the
# empty-value check below can run. The caller would then get exit 1 (documented
# here as a *usage* error) and, because stderr is discarded, no diagnostic at
# all. Binding the failure to `die` keeps operational failures on exit 2 where
# they belong. An assignment inside a `||` list does not trip `set -e`.
PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json 2>/dev/null \
             | jq -r '.id // empty') \
             || die "could not reach the Projects API for ${PROJECT_OWNER}/${PROJECT_NUMBER} (auth, network, or scope)"
[ -n "$PROJECT_ID" ] || die "could not resolve project ${PROJECT_OWNER}/${PROJECT_NUMBER}"

FIELD_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" \
               --limit "$FIELD_PAGE_LIMIT" --format json 2>/dev/null \
             | jq -r '.fields[] | select(.name=="Status")') \
             || die "could not read the field list of project ${PROJECT_NUMBER} (auth, network, or scope)"
[ -n "$FIELD_JSON" ] || die "could not resolve the Status field on project ${PROJECT_NUMBER}"

FIELD_ID=$(printf '%s' "$FIELD_JSON" | jq -r '.id // empty')
OPTION_ID=$(printf '%s' "$FIELD_JSON" \
            | jq -r --arg n "$STATUS_NAME" '.options[]? | select(.name==$n) | .id // empty')

if [ -z "$OPTION_ID" ]; then
  # Report the CANONICAL ladder, never the live option names. Option names come
  # from the board and are editable by anyone with project write access, so
  # echoing them here would render board-controlled text — potentially
  # instruction-shaped — into the transcript of an agent with high authority.
  # Only the count of live options is reported, which carries no attacker text.
  LIVE_COUNT=$(printf '%s' "$FIELD_JSON" | jq -r '[.options[]?] | length' 2>/dev/null || echo "?")
  die "unknown status \"${STATUS_NAME}\" — expected one of: ${STATUS_LADDER}
          (the board currently defines ${LIVE_COUNT} options; if the ladder was
           renamed on the board, reconcile it in the UI rather than guessing)" 1
fi

# Add. `item-add` is idempotent server-side (an existing item is returned, not
# duplicated), and prints nothing useful off-TTY, so ask for the id explicitly.
ITEM_ID=$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" \
            --url "$ISSUE_URL" --format json 2>/dev/null | jq -r '.id // empty') \
            || die "item-add failed for ${ISSUE_URL} (auth, network, or scope)"
[ -n "$ITEM_ID" ] || die "item-add returned no item id for ${ISSUE_URL}"

# DELIBERATELY NO ROLLBACK-BY-DELETE. An earlier revision deleted the item when
# the Status could not be set, which looks tidier but is strictly worse: telling
# a newly-created item from a pre-existing one depends on a lookup that can fail,
# paginate, or match another owner's project #5 — and every one of those
# misreadings ends in DELETING a board card the maintainer already had. That
# trades a recoverable failure for a destructive one.
#
# The failure left behind here is benign and self-healing instead: a status-less
# item, which is exactly what this script fixes, and re-running it on the same
# URL sets the Status (item-add is idempotent). So we fail loudly and tell the
# caller the one thing that resolves it.
if ! gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" \
        --field-id "$FIELD_ID" --single-select-option-id "$OPTION_ID" >/dev/null 2>&1; then
  die "could not set the Status for ${ISSUE_URL} (item ${ITEM_ID}).
          The item may now be on the board WITHOUT a Status — re-run this script
          on the same URL to finish it; it is idempotent and will not duplicate."
fi

# VERIFY BY READ-BACK — the whole point of the script. An exit-0 from item-edit is
# not evidence the status landed; only reading it back off the board is.
#
# Fetch the ONE item by node id. Do NOT use `gh project item-list`: it walks all
# ~4,300 board items over the shared 5k/hr GraphQL budget and has already died on
# that here — an unaffordable read for a single-field check.
ACTUAL=$(gh api graphql -f id="$ITEM_ID" -f query='
  query($id: ID!) {
    node(id: $id) {
      ... on ProjectV2Item {
        fieldValueByName(name: "Status") {
          ... on ProjectV2ItemFieldSingleSelectValue { name }
        }
      }
    }
  }' --jq '.data.node.fieldValueByName.name // empty' 2>/dev/null || true)

if [ "$ACTUAL" != "$STATUS_NAME" ]; then
  # Do NOT echo $ACTUAL — it is board-controlled text, the same untrusted class
  # as the option names above. Reporting only whether a value was present keeps
  # a renamed-to-instruction-shaped Status out of this agent's transcript while
  # still saying everything the operator needs to act.
  if [ -z "$ACTUAL" ]; then observed="no Status at all"; else observed="a different Status"; fi
  die "read-back MISMATCH for ${ISSUE_URL}: wanted \"${STATUS_NAME}\", board shows ${observed}.
          Re-run to retry; if it persists, inspect the board in the UI (the live
          value is not printed here because board text is not trusted input)."
fi

printf 'board-add: %s → %s (item %s) [verified]\n' "$ISSUE_URL" "$STATUS_NAME" "$ITEM_ID"
