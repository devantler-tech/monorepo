#!/usr/bin/env bash
# Shared ownership-marker and compare-and-swap mutex protocol for
# worktree-claim.sh and worktree-cleanup.sh. Keep the safety-critical wire
# format and staleness rules here so acquisition and reaping cannot drift.

# Consumed by both sourcing scripts rather than this library itself.
# shellcheck disable=SC2034
readonly WORKTREE_CLAIM_MARKER_NAME=".claude-worktree-owner"
readonly WORKTREE_CLAIM_LOCK_REF_PREFIX="refs/worktree/claim-locks"
readonly WORKTREE_CLAIM_TTL_SECS=$((2 * 60 * 60))
readonly WORKTREE_CLAIM_LOCK_ATTEMPTS=50

WORKTREE_CLAIM_LOCK_GITDIR=""
WORKTREE_CLAIM_LOCK_REF=""
WORKTREE_CLAIM_LOCK_OID=""
WORKTREE_CLAIM_LOCK_RECOVERED=0
WORKTREE_CLAIM_LOCK_PID=""
WORKTREE_CLAIM_LOCK_CREATED_AT=""

worktree_claim_utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Parse ISO-8601 UTC (...Z) with GNU or BSD date. This stays shell-only because
# both consumers run during bootstrap and cleanup, where Python is not assumed.
worktree_claim_iso_to_epoch() {
  local iso=$1
  date -u -d "$iso" +%s 2>/dev/null ||
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null
}

worktree_claim_lock_forget() {
  WORKTREE_CLAIM_LOCK_GITDIR=""
  WORKTREE_CLAIM_LOCK_REF=""
  WORKTREE_CLAIM_LOCK_OID=""
  WORKTREE_CLAIM_LOCK_RECOVERED=0
}

# Delete only the exact lock object this process acquired. The saved per-worktree
# gitdir lets cleanup release after its rm fallback has removed the working tree.
worktree_claim_lock_release() {
  if [ -n "${WORKTREE_CLAIM_LOCK_GITDIR:-}" ] && [ -n "${WORKTREE_CLAIM_LOCK_REF:-}" ] \
     && [ -n "${WORKTREE_CLAIM_LOCK_OID:-}" ]; then
    git --git-dir="$WORKTREE_CLAIM_LOCK_GITDIR" update-ref -d \
      "$WORKTREE_CLAIM_LOCK_REF" "$WORKTREE_CLAIM_LOCK_OID" >/dev/null 2>&1 || return 1
  fi
  worktree_claim_lock_forget
  return 0
}

worktree_claim_lock_read() {
  local wt=$1 oid=$2 data key val
  WORKTREE_CLAIM_LOCK_PID=""
  WORKTREE_CLAIM_LOCK_CREATED_AT=""
  data=$(git -C "$wt" cat-file blob "$oid" 2>/dev/null) || return 2
  while IFS='=' read -r key val; do
    case "$key" in
      pid) WORKTREE_CLAIM_LOCK_PID=$val ;;
      created_at) WORKTREE_CLAIM_LOCK_CREATED_AT=$val ;;
    esac
  done <<< "$data"
}

# Returns 0 for stale, 1 for live, and 2 when the lock cannot be interpreted.
# An unreadable lock is never replaceable: both consumers fail closed on 2.
worktree_claim_lock_is_stale() {
  local wt=$1 oid=$2 created_epoch now_epoch age
  worktree_claim_lock_read "$wt" "$oid" || return 2
  case "$WORKTREE_CLAIM_LOCK_PID" in
    ''|*[!0-9]*) ;;
    *)
      if ! kill -0 "$WORKTREE_CLAIM_LOCK_PID" 2>/dev/null; then return 0; fi
      ;;
  esac
  created_epoch=$(worktree_claim_iso_to_epoch "$WORKTREE_CLAIM_LOCK_CREATED_AT") || return 2
  now_epoch=$(date -u +%s)
  age=$((now_epoch - created_epoch))
  [ "$age" -ge "$WORKTREE_CLAIM_TTL_SECS" ] && return 0
  return 1
}

# Acquire the per-worktree mutex with compare-and-swap. Returns 0 when held,
# 1 when a live owner outlasts the bounded wait, or 2 on unverifiable state.
# On success the caller must call worktree_claim_lock_release, or deliberately
# forget the state after Git removes the linked worktree and its private refs.
worktree_claim_lock_acquire() {
  local wt=$1 attempt=0 path_hash ref new_oid zero_oid current_oid="" stale_rc gitdir
  [ -z "${WORKTREE_CLAIM_LOCK_OID:-}" ] || return 2
  WORKTREE_CLAIM_LOCK_RECOVERED=0
  path_hash=$(printf '%s' "$wt" | git -C "$wt" hash-object --stdin) || return 2
  ref="$WORKTREE_CLAIM_LOCK_REF_PREFIX/$path_hash"
  new_oid=$(printf 'pid=%s\ncreated_at=%s\n' "$$" "$(worktree_claim_utc_now)" \
    | git -C "$wt" hash-object -w --stdin) || return 2
  zero_oid=$(printf '%*s' "${#new_oid}" '' | tr ' ' 0)
  gitdir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || return 2

  while true; do
    current_oid=$(git -C "$wt" rev-parse -q --verify "$ref" 2>/dev/null || true)
    if [ -z "$current_oid" ]; then
      if git -C "$wt" update-ref "$ref" "$new_oid" "$zero_oid" 2>/dev/null; then break; fi
    else
      stale_rc=0
      worktree_claim_lock_is_stale "$wt" "$current_oid" || stale_rc=$?
      case "$stale_rc" in
        0)
          if git -C "$wt" update-ref "$ref" "$new_oid" "$current_oid" 2>/dev/null; then
            # Consumed by worktree-claim.sh after this function returns.
            # shellcheck disable=SC2034
            WORKTREE_CLAIM_LOCK_RECOVERED=1
            break
          fi
          ;;
        1) ;;
        2) return 2 ;;
      esac
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -ge "$WORKTREE_CLAIM_LOCK_ATTEMPTS" ] && return 1
    sleep 0.1
  done
  WORKTREE_CLAIM_LOCK_GITDIR=$gitdir
  WORKTREE_CLAIM_LOCK_REF=$ref
  WORKTREE_CLAIM_LOCK_OID=$new_oid
  return 0
}
