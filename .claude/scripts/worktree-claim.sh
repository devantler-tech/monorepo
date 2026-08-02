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
#   This helper atomically acquires an ownership marker when creating or
#   entering a worktree. A live foreign marker is treated like a live issue
#   claim: pick another lane. Markers expire after ~2 hours so a crashed
#   session parks nothing permanently (same window as issue claims).
#
# USAGE
#   .claude/scripts/worktree-claim.sh add  <repo_path> <worktree_path> <branch> <owner-token>
#       Create the worktree (git worktree add -b <branch>) and write the marker.
#       A relative worktree_path is resolved from repo_path.
#   .claude/scripts/worktree-claim.sh check <worktree_path> <my-owner-token>
#       Read-only diagnostic: exit 0 if free / mine / expired; exit 3 if a live
#       foreign claim exists. This does not reserve the worktree.
#   .claude/scripts/worktree-claim.sh acquire <worktree_path> <owner-token>
#       Atomically acquire a free/expired worktree or renew the current owner's
#       lease. Exit 3 without changing the marker when another live owner wins.
#   .claude/scripts/worktree-claim.sh mark  <worktree_path> <owner-token>
#       Compatibility alias for `acquire`.
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
#   3  live foreign claim (check or acquire mode)

set -euo pipefail

readonly MARKER_NAME=".claude-worktree-owner"
readonly LOCK_REF_PREFIX="refs/worktree/claim-locks"
# Same ~2h window as the issue Claim protocol lease.
readonly CLAIM_TTL_SECS=$((2 * 60 * 60))
readonly LOCK_ATTEMPTS=50
CLAIM_LOCK_WORKTREE=""
CLAIM_LOCK_REF=""
CLAIM_LOCK_OID=""

usage() {
  cat >&2 <<'EOF'
usage:
  worktree-claim.sh add   <repo_path> <worktree_path> <branch> <owner-token>
  worktree-claim.sh check <worktree_path> <my-owner-token>
  worktree-claim.sh acquire <worktree_path> <owner-token>
  worktree-claim.sh mark  <worktree_path> <owner-token>
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

cleanup_lock() {
  if [ -n "${CLAIM_LOCK_WORKTREE:-}" ] && [ -n "${CLAIM_LOCK_REF:-}" ] && [ -n "${CLAIM_LOCK_OID:-}" ]; then
    git -C "$CLAIM_LOCK_WORKTREE" update-ref -d "$CLAIM_LOCK_REF" "$CLAIM_LOCK_OID" >/dev/null 2>&1 || true
  fi
  CLAIM_LOCK_WORKTREE=""
  CLAIM_LOCK_REF=""
  CLAIM_LOCK_OID=""
}

trap cleanup_lock EXIT
trap 'exit 2' HUP INT TERM

read_lock_object() {
  local wt="$1" oid="$2" data key val
  LOCK_PID=""
  LOCK_CREATED_AT=""
  data="$(git -C "$wt" cat-file blob "$oid" 2>/dev/null)" || return 2
  while IFS='=' read -r key val; do
    case "$key" in
      pid) LOCK_PID="$val" ;;
      created_at) LOCK_CREATED_AT="$val" ;;
    esac
  done <<< "$data"
}

lock_object_is_stale() {
  local wt="$1" oid="$2" created_epoch now_epoch age
  read_lock_object "$wt" "$oid" || return 2
  case "$LOCK_PID" in
    '' | *[!0-9]*) ;;
    *)
      if ! kill -0 "$LOCK_PID" 2>/dev/null; then
        return 0
      fi
      ;;
  esac
  created_epoch="$(iso_to_epoch "$LOCK_CREATED_AT")" || return 2
  now_epoch="$(date -u +%s)"
  age=$((now_epoch - created_epoch))
  [ "$age" -ge "$CLAIM_TTL_SECS" ] && return 0
  return 1
}

acquire_lock() {
  local wt="$1" attempt=0 path_hash ref new_oid zero_oid current_oid="" stale_rc recovered=0
  # A per-worktree Git ref is the mutex. update-ref's expected-old-OID argument
  # makes both first acquisition and stale-owner replacement compare-and-swap
  # operations, so two reapers cannot delete or overwrite the winner's lock.
  path_hash="$(printf '%s' "$wt" | git -C "$wt" hash-object --stdin)" ||
    fail "cannot derive ownership lock identity for: $wt"
  ref="$LOCK_REF_PREFIX/$path_hash"
  new_oid="$(printf 'pid=%s\ncreated_at=%s\n' "$$" "$(utc_now)" | git -C "$wt" hash-object -w --stdin)" ||
    fail "cannot write ownership lock metadata for: $wt"
  zero_oid="$(printf '%*s' "${#new_oid}" '' | tr ' ' 0)"

  while true; do
    current_oid="$(git -C "$wt" rev-parse -q --verify "$ref" 2>/dev/null || true)"
    if [ -z "$current_oid" ]; then
      if git -C "$wt" update-ref "$ref" "$new_oid" "$zero_oid" 2>/dev/null; then
        break
      fi
    else
      stale_rc=0
      lock_object_is_stale "$wt" "$current_oid" || stale_rc=$?
      case "$stale_rc" in
        0)
          if git -C "$wt" update-ref "$ref" "$new_oid" "$current_oid" 2>/dev/null; then
            recovered=1
            break
          fi
          ;;
        1) ;;
        2) fail "malformed or unreadable ownership lock ref: $ref" ;;
      esac
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$LOCK_ATTEMPTS" ]; then
      fail "timed out waiting for ownership lock: $ref"
    fi
    sleep 0.1
  done
  CLAIM_LOCK_WORKTREE="$wt"
  CLAIM_LOCK_REF="$ref"
  CLAIM_LOCK_OID="$new_oid"
  [ "$recovered" -eq 1 ] && echo "worktree-claim: recovered stale ownership lock: $ref" >&2
  return 0
}

release_lock() {
  [ -n "${CLAIM_LOCK_WORKTREE:-}" ] && [ -n "${CLAIM_LOCK_REF:-}" ] && [ -n "${CLAIM_LOCK_OID:-}" ] || return 0
  git -C "$CLAIM_LOCK_WORKTREE" update-ref -d "$CLAIM_LOCK_REF" "$CLAIM_LOCK_OID" 2>/dev/null ||
    fail "ownership lock changed owner before release: $CLAIM_LOCK_REF"
  CLAIM_LOCK_WORKTREE=""
  CLAIM_LOCK_REF=""
  CLAIM_LOCK_OID=""
}

ignore_marker() {
  local wt="$1"
  local exclude
  exclude="$(git -C "$wt" rev-parse --git-path info/exclude)" ||
    fail "cannot resolve git exclude file for worktree: $wt"
  mkdir -p "$(dirname "$exclude")"
  if ! grep -qxF "/$MARKER_NAME*" "$exclude" 2>/dev/null; then
    if [ -s "$exclude" ] && [ -n "$(tail -c 1 "$exclude")" ]; then
      printf '\n' >>"$exclude"
    fi
    printf '/%s*\n' "$MARKER_NAME" >>"$exclude"
  fi
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

cmd_acquire() {
  local wt="$1" owner="$2"
  [ -d "$wt" ] || fail "worktree path is not a directory: $wt"
  [ -n "$owner" ] || usage
  wt="$(cd "$wt" && pwd -P)" || fail "cannot resolve worktree path: $wt"
  acquire_lock "$wt"
  ignore_marker "$wt"
  local marker="$wt/$MARKER_NAME" action="acquired"
  read_marker "$marker"
  if [ -e "$marker" ]; then
    if [ -z "${MARKER_OWNER:-}" ] || [ -z "${MARKER_CREATED_AT:-}" ]; then
      fail "malformed ownership marker (owner and created_at are required): $marker"
    fi
    if [ "$MARKER_OWNER" = "$owner" ]; then
      action="renewed"
    else
      local created_epoch now_epoch age
      created_epoch="$(iso_to_epoch "$MARKER_CREATED_AT")" ||
        fail "unparseable ownership marker timestamp: $MARKER_CREATED_AT"
      now_epoch="$(date -u +%s)"
      age=$((now_epoch - created_epoch))
      if [ "$age" -lt "$CLAIM_TTL_SECS" ]; then
        echo "worktree-claim: LIVE foreign claim owner=$MARKER_OWNER created_at=$MARKER_CREATED_AT age=${age}s — stand down" >&2
        release_lock
        exit 3
      fi
      action="transferred expired claim"
    fi
  fi
  write_marker "$wt" "$owner"
  release_lock
  echo "worktree-claim: $action $wt owner=$owner"
}

cmd_mark() {
  cmd_acquire "$1" "$2"
}

cmd_add() {
  local repo="$1" wt="$2" branch="$3" owner="$4"
  [ -d "$repo" ] || fail "repo path is not a directory: $repo"
  [ -n "$wt" ] && [ -n "$branch" ] && [ -n "$owner" ] || usage
  local repo_abs
  repo_abs="$(cd "$repo" && pwd -P)" || fail "cannot resolve repo path: $repo"
  case "$wt" in
    /*) ;;
    *) wt="$repo_abs/$wt" ;;
  esac
  if [ -e "$wt" ]; then
    fail "worktree path already exists: $wt"
  fi
  # Create parent so git worktree add can place the tree.
  mkdir -p "$(dirname "$wt")"
  if ! git -C "$repo" worktree add -b "$branch" "$wt"; then
    fail "git worktree add failed for $wt (branch $branch)"
  fi
  cmd_acquire "$wt" "$owner"
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
  if [ ! -e "$marker" ]; then
    echo "worktree-claim: free (no live marker)"
    exit 0
  fi
  if [ -z "${MARKER_OWNER:-}" ] || [ -z "${MARKER_CREATED_AT:-}" ]; then
    fail "malformed ownership marker (owner and created_at are required): $marker"
  fi
  if [ "$MARKER_OWNER" = "$me" ]; then
    echo "worktree-claim: mine (owner=$MARKER_OWNER)"
    exit 0
  fi
  local created_epoch now_epoch age
  created_epoch="$(iso_to_epoch "$MARKER_CREATED_AT")" ||
    fail "unparseable ownership marker timestamp: $MARKER_CREATED_AT"
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
    acquire)
      [ $# -eq 2 ] || usage
      cmd_acquire "$1" "$2"
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
