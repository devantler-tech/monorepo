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

die() { printf 'board-add: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() {
  cat >&2 <<'EOF'
usage: board-add.sh <issue-url> [status-name]

  <issue-url>    full https://github.com/<owner>/<repo>/issues/<n> URL
  [status-name]  board Status, default "📥 Backlog"

Statuses: ✅ Done | 📊 Verifying | 🚀 Ready to Merge | 👀 In Review
          🏃🏻‍♂️ In Progress | 🫴 Ready | 📥 Backlog | 🧊 Icebox
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
PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json 2>/dev/null \
             | jq -r '.id // empty')
[ -n "$PROJECT_ID" ] || die "could not resolve project ${PROJECT_OWNER}/${PROJECT_NUMBER}"

FIELD_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json 2>/dev/null \
             | jq -r '.fields[] | select(.name=="Status")')
[ -n "$FIELD_JSON" ] || die "could not resolve the Status field on project ${PROJECT_NUMBER}"

FIELD_ID=$(printf '%s' "$FIELD_JSON" | jq -r '.id // empty')
OPTION_ID=$(printf '%s' "$FIELD_JSON" \
            | jq -r --arg n "$STATUS_NAME" '.options[]? | select(.name==$n) | .id // empty')

if [ -z "$OPTION_ID" ]; then
  VALID=$(printf '%s' "$FIELD_JSON" | jq -r '[.options[]?.name] | join(" | ")')
  die "unknown status \"${STATUS_NAME}\" — valid: ${VALID}" 1
fi

# Add. `item-add` is idempotent server-side (an existing item is returned, not
# duplicated), and prints nothing useful off-TTY, so ask for the id explicitly.
ITEM_ID=$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" \
            --url "$ISSUE_URL" --format json 2>/dev/null | jq -r '.id // empty')
[ -n "$ITEM_ID" ] || die "item-add returned no item id for ${ISSUE_URL}"

gh project item-edit --id "$ITEM_ID" --project-id "$PROJECT_ID" \
   --field-id "$FIELD_ID" --single-select-option-id "$OPTION_ID" >/dev/null 2>&1 \
   || die "item-edit failed for ${ISSUE_URL} (item ${ITEM_ID})"

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
  die "read-back MISMATCH for ${ISSUE_URL}: wanted \"${STATUS_NAME}\", board shows \"${ACTUAL:-<none>}\""
fi

printf 'board-add: %s → %s (item %s) [verified]\n' "$ISSUE_URL" "$STATUS_NAME" "$ITEM_ID"
