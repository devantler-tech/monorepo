#!/usr/bin/env bash
# board-archive.sh — archive closed 🌊 Project Board items the auto-archive workflow never archives.
#
# WHY THIS EXISTS
#   Project 5's "Auto-archive items" workflow reads `enabled: true`, yet it archived
#   0 of 5,018 closed or merged items by 2026-09-06 (monorepo#2238). The API exposes
#   the enabled flag but not the workflow's filter, so the board card has kept the
#   archive rule as a manual health check. This script is that rule, executable.
#
# THE RULE (project-board card → Health checks → Archive)
#   An item is archived only when ALL of these hold:
#     - it is an issue or pull request that is closed or merged;
#     - it closed more than --min-closed-days ago (default 30), so Insights keeps
#       recent history — archived items leave Insights entirely;
#     - for an issue, no ancestor is still open (a closed child under an open Epic
#       stays, or the Backlog hierarchy silently loses rows);
#     - for an issue, no descendant on the board is still open, and its own
#       sub-issue summary shows no unfinished child (an Epic closed early stays, or
#       its open child is orphaned from a tree nobody can see).
#   Anything this script cannot classify stays active: draft issues, content it
#   cannot read, an ancestor whose state is unknown, an item already archived.
#
# USAGE
#   board-archive.sh                                  # dry run
#   board-archive.sh --apply --manifest <file> [--max N]
#   board-archive.sh --restore <manifest>
#
#   Dry run prints one candidate per line on stdout (item id, repo#number, type,
#   closedAt) and a summary on stderr. It writes nothing.
#
# OPTIONS
#   --min-closed-days N  minimum days since closing (default 30)
#   --max N              most items archived in one --apply run (default 450)
#   --manifest FILE      --apply appends "<project id> <item id> <ref> <closedAt>"
#                        (tab-separated) BEFORE each archive, so every item this
#                        run may have touched can be restored
#   --restore FILE       unarchive every item a manifest names
#
# ENVIRONMENT
#   BOARD_ARCHIVE_NOW            ISO-8601 UTC instant used as "now" (tests)
#   BOARD_ARCHIVE_PACE_SECONDS   pause between mutations (default 1)
#
# EXIT CODES
#   0  dry run finished, or every requested mutation was verified
#   1  usage error
#   2  read, write, or verification failed — nothing further was attempted
#
# NOTES
#   - Paced and capped on purpose: GitHub allows ~80 content-generating requests a
#     minute and 500 an hour. The default --max stays under the hourly figure, so a
#     large backlog is drained over several runs. Never run two at once.
#   - Idempotent: the read excludes archived items, and each candidate's state is
#     re-read immediately before it is archived.
#   - Board text is untrusted input. Titles and field values are never printed.

set -euo pipefail

readonly PROJECT_NUMBER=5
readonly PROJECT_OWNER="devantler-tech"
# Sub-issues nest at most 8 levels. One extra id-only level is a sentinel: a
# chain deeper than expected ends in an ancestor with no known state, which the
# rule treats as open.
readonly MAX_DEPTH=8

die() {
  printf 'board-archive: %s\n' "$1" >&2
  exit "${2:-2}"
}

usage() {
  cat >&2 <<'EOF'
usage: board-archive.sh [--min-closed-days N]
       board-archive.sh --apply --manifest FILE [--max N] [--min-closed-days N]
       board-archive.sh --restore FILE
EOF
  exit 1
}

is_count() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac }

MODE=dry-run
MIN_DAYS=30
MAX=450
MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
  --apply) MODE=apply ;;
  --restore)
    [ $# -ge 2 ] || usage
    MODE=restore
    MANIFEST="$2"
    shift
    ;;
  --manifest)
    [ $# -ge 2 ] || usage
    MANIFEST="$2"
    shift
    ;;
  --max)
    if [ $# -lt 2 ] || ! is_count "$2" || [ "$2" -eq 0 ]; then usage; fi
    MAX="$2"
    shift
    ;;
  --min-closed-days)
    if [ $# -lt 2 ] || ! is_count "$2"; then usage; fi
    MIN_DAYS="$2"
    shift
    ;;
  *) usage ;;
  esac
  shift
done
[ "$MODE" != apply ] || [ -n "$MANIFEST" ] || die "--apply requires --manifest, so every archive can be restored" 1

PACE="${BOARD_ARCHIVE_PACE_SECONDS:-1}"
case "$PACE" in '' | *[!0-9.]*) die "BOARD_ARCHIVE_PACE_SECONDS must be a number" 1 ;; esac

command -v gh >/dev/null 2>&1 || die "gh CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
GH_ERR="$TMP/gh.err"

# GitHub's own error text, bounded. It comes from the API, not the board.
gh_reason() { head -c 300 "$GH_ERR" 2>/dev/null | tr '\n' ' '; }

# shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
readonly PROJECT_QUERY='query($owner: String!, $number: Int!) {
  organization(login: $owner) { projectV2(number: $number) { id } } }'

resolve_project_id() {
  local out
  out=$(gh api graphql -f owner="$PROJECT_OWNER" -F number="$PROJECT_NUMBER" \
    -f query="$PROJECT_QUERY" 2>"$GH_ERR") || die "could not resolve project ${PROJECT_NUMBER}: $(gh_reason)"
  PROJECT_ID=$(printf '%s' "$out" | jq -r '.data.organization.projectV2.id // empty')
  [ -n "$PROJECT_ID" ] || die "could not resolve project ${PROJECT_NUMBER}"
}

# ── restore ────────────────────────────────────────────────────────────────
if [ "$MODE" = restore ]; then
  [ -r "$MANIFEST" ] || die "cannot read manifest: ${MANIFEST}" 1
  resolve_project_id
  # Validate every line before the first mutation, so a manifest from another
  # project cannot be half-applied.
  lines=0
  while IFS=$'\t' read -r pid item ref _; do
    [ -n "$pid$item" ] || continue
    [ -n "$item" ] || die "malformed manifest line for ${ref:-an unnamed item}; nothing was restored"
    [ "$pid" = "$PROJECT_ID" ] || die "manifest names a different project for ${ref}; nothing was restored"
    lines=$((lines + 1))
  done <"$MANIFEST"
  # shellcheck disable=SC2016
  readonly UNARCHIVE='mutation($project: ID!, $item: ID!) {
    unarchiveProjectV2Item(input: {projectId: $project, itemId: $item}) { item { id isArchived } } }'
  restored=0
  while IFS=$'\t' read -r pid item ref _; do
    [ -n "$pid$item" ] || continue
    out=$(gh api graphql -f project="$PROJECT_ID" -f item="$item" -f query="$UNARCHIVE" 2>"$GH_ERR") ||
      die "unarchive failed for ${ref} after ${restored} of ${lines} restored: $(gh_reason)"
    printf '%s' "$out" | jq -e --arg id "$item" '(.errors // [] | length) == 0 and
      .data.unarchiveProjectV2Item.item.id == $id and
      .data.unarchiveProjectV2Item.item.isArchived == false' >/dev/null ||
      die "read-back for ${ref} did not show it active after ${restored} of ${lines} restored"
    restored=$((restored + 1))
    [ "$PACE" = 0 ] || sleep "$PACE"
  done <"$MANIFEST"
  printf 'board-archive: restored %s item(s) from %s [verified]\n' "$restored" "$MANIFEST" >&2
  exit 0
fi

# ── read every active item ─────────────────────────────────────────────────
chain=""
close=""
for ((i = 0; i < MAX_DEPTH; i++)); do
  chain+=" parent { id state"
  close+=" }"
done
chain+=" parent { id }${close}"

# shellcheck disable=SC2016
ITEMS_QUERY='query($owner: String!, $number: Int!, $after: String) {
  organization(login: $owner) { projectV2(number: $number) { id
    items(first: 100, after: $after, archivedStates: [NOT_ARCHIVED]) {
      pageInfo { hasNextPage endCursor }
      nodes { id isArchived content { __typename
        ... on Issue { id number state closedAt repository { nameWithOwner }
          subIssuesSummary { total completed }'"$chain"' }
        ... on PullRequest { id number state closedAt repository { nameWithOwner } }
      } }
    } } } }'

NODES="$TMP/nodes.jsonl"
: >"$NODES"
PROJECT_ID=""
after=""
while :; do
  cursor_args=(-F after=null)
  [ -z "$after" ] || cursor_args=(-f "after=$after")
  page=$(gh api graphql -f owner="$PROJECT_OWNER" -F number="$PROJECT_NUMBER" "${cursor_args[@]}" \
    -f query="$ITEMS_QUERY" 2>"$GH_ERR") || die "could not read project items: $(gh_reason)"
  printf '%s' "$page" | jq -e '
    (.errors // [] | length) == 0 and
    (.data.organization.projectV2.id | type == "string" and length > 0) and
    (.data.organization.projectV2.items.nodes | type == "array") and
    (.data.organization.projectV2.items.pageInfo.hasNextPage | type == "boolean") and
    all(.data.organization.projectV2.items.nodes[];
      (.id | type == "string" and length > 0) and (.isArchived | type == "boolean"))' >/dev/null ||
    die "invalid project items response; nothing was archived"
  page_project=$(printf '%s' "$page" | jq -r '.data.organization.projectV2.id')
  [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "$page_project" ] || die "project id changed between pages; nothing was archived"
  PROJECT_ID="$page_project"
  printf '%s' "$page" | jq -c '.data.organization.projectV2.items.nodes[]' >>"$NODES"
  [ "$(printf '%s' "$page" | jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage')" = true ] || break
  next=$(printf '%s' "$page" | jq -r '.data.organization.projectV2.items.pageInfo.endCursor // empty')
  [ -n "$next" ] && [ "$next" != "$after" ] || die "project items cursor did not advance; nothing was archived"
  after="$next"
done

# ── apply the rule ─────────────────────────────────────────────────────────
if [ -n "${BOARD_ARCHIVE_NOW:-}" ]; then
  now=$(jq -n --arg now "$BOARD_ARCHIVE_NOW" '$now | fromdateiso8601') || die "BOARD_ARCHIVE_NOW is not ISO-8601 UTC" 1
else
  now=$(jq -n 'now | floor')
fi
cutoff=$((now - MIN_DAYS * 86400))

SELECTION="$TMP/selection.json"
jq -s --argjson cutoff "$cutoff" '
  def ancestors: [(.parent // empty) | recurse(.parent // empty)];
  def aged: (.closedAt | type == "string") and ((.closedAt | fromdateiso8601) < $cutoff);
  . as $nodes
  | [$nodes[] | .content | select(. != null and .__typename == "Issue" and .state == "OPEN")
      | ancestors[] | .id] as $has_open_descendant
  | [$nodes[] | select(.isArchived == false and .content != null)
      | select(.content.__typename == "Issue" or .content.__typename == "PullRequest")
      | select((.content.state == "CLOSED" or .content.state == "MERGED") and (.content | aged))] as $aged
  | [$aged[] | select(.content.__typename == "PullRequest" or (
        (.content | ancestors | map(select(.state != "CLOSED")) | length) == 0
        and (.content.id as $id | any($has_open_descendant[]; . == $id) | not)
        and ((.content.subIssuesSummary.total // 1) == (.content.subIssuesSummary.completed // 0))
      ))] as $candidates
  | { scanned: ($nodes | length),
      aged: ($aged | length),
      kept: (($aged | length) - ($candidates | length)),
      candidates: [$candidates[] | { id,
        ref: "\(.content.repository.nameWithOwner)#\(.content.number)",
        type: .content.__typename,
        closedAt: .content.closedAt }] }' "$NODES" >"$SELECTION" || die "could not evaluate the archive rule"

jq -r '"board-archive: \(.scanned) active item(s), \(.aged) closed over '"$MIN_DAYS"' day(s), \(.kept) kept for open hierarchy, \(.candidates | length) candidate(s)"' "$SELECTION" >&2

if [ "$MODE" = dry-run ]; then
  jq -r '.candidates[] | [.id, .ref, .type, .closedAt] | @tsv' "$SELECTION"
  exit 0
fi

# ── archive ────────────────────────────────────────────────────────────────
: >>"$MANIFEST" || die "cannot write manifest: ${MANIFEST}; nothing was archived"

# shellcheck disable=SC2016
readonly RECHECK='query($item: ID!) { node(id: $item) { ... on ProjectV2Item { id isArchived
  content { ... on Issue { state } ... on PullRequest { state } } } } }'
# shellcheck disable=SC2016
readonly ARCHIVE='mutation($project: ID!, $item: ID!) {
  archiveProjectV2Item(input: {projectId: $project, itemId: $item}) { item { id isArchived } } }'

archived=0
skipped=0
while IFS=$'\t' read -r item ref _ closed; do
  [ "$archived" -lt "$MAX" ] || break
  [ -n "$item" ] && [ -n "$closed" ] || die "malformed candidate after ${archived} archived (manifest: ${MANIFEST})"

  # The read above can be minutes old by now; a reopened item must not be archived.
  state=$(gh api graphql -f item="$item" -f query="$RECHECK" 2>"$GH_ERR" |
    jq -r --arg id "$item" 'select((.errors // [] | length) == 0 and .data.node.id == $id)
      | if .data.node.isArchived then "archived" else (.data.node.content.state // "unknown") end') ||
    die "could not re-read ${ref} after ${archived} archived (manifest: ${MANIFEST}): $(gh_reason)"
  case "$state" in
  CLOSED | MERGED) : ;;
  "") die "could not re-read ${ref} after ${archived} archived (manifest: ${MANIFEST})" ;;
  *)
    skipped=$((skipped + 1))
    continue
    ;;
  esac

  printf '%s\t%s\t%s\t%s\n' "$PROJECT_ID" "$item" "$ref" "$closed" >>"$MANIFEST" ||
    die "cannot write manifest before archiving ${ref}; stopped after ${archived} archived"
  out=$(gh api graphql -f project="$PROJECT_ID" -f item="$item" -f query="$ARCHIVE" 2>"$GH_ERR") ||
    die "archive failed for ${ref} after ${archived} archived (manifest: ${MANIFEST}): $(gh_reason)"
  printf '%s' "$out" | jq -e --arg id "$item" '(.errors // [] | length) == 0 and
    .data.archiveProjectV2Item.item.id == $id and
    .data.archiveProjectV2Item.item.isArchived == true' >/dev/null ||
    die "read-back for ${ref} did not show it archived after ${archived} archived (manifest: ${MANIFEST})"
  archived=$((archived + 1))
  [ "$PACE" = 0 ] || sleep "$PACE"
done < <(jq -r '.candidates[] | [.id, .ref, .type, .closedAt] | @tsv' "$SELECTION")

printf 'board-archive: archived %s item(s), skipped %s changed since the read (manifest: %s) [verified]\n' \
  "$archived" "$skipped" "$MANIFEST" >&2
