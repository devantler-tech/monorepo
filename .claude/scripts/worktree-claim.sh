#!/usr/bin/env bash
# worktree-claim.sh — own a per-run worktree so a sibling cannot squat it unseen.
#
# WHY THIS EXISTS (monorepo#2284)
#   The claim protocol covers the issue (assignee), the branch (pushed ref), and
#   the PR. A worktree directory is claimed by nothing. Two consecutive ticks
#   lost validated work because a sibling edited files inside a worktree this
#   session created while every GitHub-side claim signal read clean — the
#   collision surfaced only as "File has been modified since read" after work
#   was already underway.
#
#   This helper writes an ownership marker when creating a worktree, and checks
#   it before entering a foreign one. A live foreign marker is treated like a
#   live issue claim: pick another lane. Markers expire after ~2 hours so a
#   crashed session parks nothing permanently (same window as issue claims).
#
# USAGE
#   .claude/scripts/worktree-claim.sh add  <repo_path> <worktree_path> <branch> <owner-slug>
#       Create the worktree (git worktree add -b <branch>) and write the marker.
#   .claude/scripts/worktree-claim.sh check <worktree_path> <my-owner-slug>
#       Exit 0 if free / mine / expired; exit 3 if a live foreign claim exists.
#   .claude/scripts/worktree-claim.sh mark  <worktree_path> <owner-slug>
#       Write/refresh the marker on an already-created worktree (e.g. after a
#       bare `git worktree add` that could not go through `add`).
#
# MARKER
#   Path: <worktree>/.claude-worktree-owner  (gitignored locally by agents; never
#   staged — it is session state, not product content).
#   Format (two lines, KEY=value):
#     owner=<slug>
#     created_at=<ISO-8601 UTC, e.g. 2026-07-21T07:40:00Z>
#
# EXIT CODES
#   0  success / free-or-mine-or-expired
#   1  usage / argument error
#   2  git or filesystem failure
#   3  live foreign claim (check mode only)

set -euo pipefail

readonly MARKER_NAME=".claude-worktree-owner"
# Same ~2h window as the issue Claim protocol lease.
readonly CLAIM_TTL_SECS=$((2 * 60 * 60))

usage() {
  cat >&2 <<'EOF'
usage:
  worktree-claim.sh add   <repo_path> <worktree_path> <branch> <owner-slug>
  worktree-claim.sh check <worktree_path> <my-owner-slug>
  worktree-claim.sh mark  <worktree_path> <owner-slug>
EOF
  exit 1
}

fail() {
  echo "worktree-claim: $*" >&2
  exit 2
}

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Parse ISO-8601 UTC (…Z) to epoch seconds. Portable: prefer GNU date, fall
# back to python-free parsing via touch+stat only when needed — keep bash-only.
iso_to_epoch() {
  local iso="$1"
  # GNU date: date -u -d '2026-07-21T07:40:00Z' +%s
  if date -u -d "$iso" +%s 2>/dev/null; then
    return 0
  fi
  # BSD date (macOS): date -u -j -f '%Y-%m-%dT%H:%M:%SZ' …
  if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null; then
    return 0
  fi
  return 1
}

write_marker() {
  local wt="$1" owner="$2"
  local marker="$wt/$MARKER_NAME"
  # Atomic-ish write: temp then mv, so a concurrent reader never sees a half
  # file. Do not stage this path — it is per-session state.
  local tmp
  tmp="$(mktemp "$wt/.claude-worktree-owner.XXXXXX")"
  printf 'owner=%s\ncreated_at=%s\n' "$owner" "$(utc_now)" >"$tmp"
  mv -f "$tmp" "$marker"
}

read_marker() {
  # Sets MARKER_OWNER and MARKER_CREATED_AT from the file, or leaves them empty.
  local marker="$1"
  MARKER_OWNER=""
  MARKER_CREATED_AT=""
  [ -f "$marker" ] || return 0
  # shellcheck disable=SC2034
  while IFS='=' read -r key val; do
    case "$key" in
      owner) MARKER_OWNER="$val" ;;
      created_at) MARKER_CREATED_AT="$val" ;;
    esac
  done <"$marker"
}

cmd_mark() {
  local wt="$1" owner="$2"
  [ -d "$wt" ] || fail "worktree path is not a directory: $wt"
  [ -n "$owner" ] || usage
  write_marker "$wt" "$owner"
  echo "worktree-claim: marked $wt owner=$owner"
}

cmd_add() {
  local repo="$1" wt="$2" branch="$3" owner="$4"
  [ -d "$repo" ] || fail "repo path is not a directory: $repo"
  [ -n "$wt" ] && [ -n "$branch" ] && [ -n "$owner" ] || usage
  if [ -e "$wt" ]; then
    fail "worktree path already exists: $wt"
  fi
  # Create parent so git worktree add can place the tree.
  mkdir -p "$(dirname "$wt")"
  if ! git -C "$repo" worktree add -b "$branch" "$wt"; then
    fail "git worktree add failed for $wt (branch $branch)"
  fi
  write_marker "$wt" "$owner"
  echo "worktree-claim: added $wt on $branch owner=$owner"
}

cmd_check() {
  local wt="$1" me="$2"
  [ -n "$me" ] || usage
  if [ ! -d "$wt" ]; then
    # No directory → nothing to squat; caller may create.
    echo "worktree-claim: free (path absent)"
    exit 0
  fi
  local marker="$wt/$MARKER_NAME"
  read_marker "$marker"
  if [ -z "${MARKER_OWNER:-}" ] || [ -z "${MARKER_CREATED_AT:-}" ]; then
    echo "worktree-claim: free (no live marker)"
    exit 0
  fi
  if [ "$MARKER_OWNER" = "$me" ]; then
    echo "worktree-claim: mine (owner=$MARKER_OWNER)"
    exit 0
  fi
  local created_epoch now_epoch age
  created_epoch="$(iso_to_epoch "$MARKER_CREATED_AT")" || {
    echo "worktree-claim: free (unparseable created_at — treat as stale)"
    exit 0
  }
  now_epoch="$(date -u +%s)"
  age=$((now_epoch - created_epoch))
  if [ "$age" -ge "$CLAIM_TTL_SECS" ]; then
    echo "worktree-claim: free (expired age=${age}s owner=$MARKER_OWNER)"
    exit 0
  fi
  echo "worktree-claim: LIVE foreign claim owner=$MARKER_OWNER created_at=$MARKER_CREATED_AT age=${age}s — stand down" >&2
  exit 3
}

main() {
  [ $# -ge 1 ] || usage
  local mode="$1"
  shift
  case "$mode" in
    add)
      [ $# -eq 4 ] || usage
      cmd_add "$1" "$2" "$3" "$4"
      ;;
    check)
      [ $# -eq 2 ] || usage
      cmd_check "$1" "$2"
      ;;
    mark)
      [ $# -eq 2 ] || usage
      cmd_mark "$1" "$2"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
