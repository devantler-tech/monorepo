#!/usr/bin/env bash
#
# Portable branch-operation lock shared by harness-controlled worktree
# create/attach/remove and by local branch cleanup (monorepo#2209).
#
# Why: `git branch -D` refuses a checked-out branch but has no expected-SHA
# CAS; `git update-ref -d <ref> <old-oid>` has CAS but bypasses the worktree
# occupancy guard. Polling between the two cannot make cleanup atomic against
# a concurrent `git worktree add`. One lock held by BOTH sides closes that
# race without depending on GNU-only tools (`flock` is absent on stock macOS).
#
# Protocol:
#   - Lock path: `<git-common-dir>/devantler-branch-op.lock/` (directory).
#   - Acquire is `mkdir` — atomic on both Linux and macOS APFS/HFS+.
#   - Holder writes `pid`, `token`, `acquired_at` (UTC), `acquired_epoch`, `host`.
#   - Ownership for release is the **token** (also kept in-shell as
#     BRANCH_OP_LOCK_TOKEN). Same-pid is accepted as a convenience when sourced.
#     A CLI `acquire` that exits leaves a dead-pid lock — prefer `run`, or keep
#     the acquiring process alive and `release --token`.
#   - Stale recovery (fail-closed otherwise):
#       1. Same-host dead PID → remove and retry.
#       2. Age past STALE_TTL_SEC (default 600) → remove and retry
#          (covers cross-host / reboot where kill -0 is meaningless).
#       3. Anything else → keep waiting until --timeout-sec, then FAIL.
#   - Release removes the directory only when the caller presents the matching
#     token (or is the same pid), so a timed-out waiter cannot delete a later
#     holder's lock.
#
# Usage:
#   branch-op-lock.sh acquire <repo_path> [--timeout-sec N] [--stale-ttl-sec N]
#       # prints the ownership token on stdout
#   branch-op-lock.sh release <repo_path> --token <token>
#   branch-op-lock.sh run <repo_path> [--timeout-sec N] -- <command...>
#
# Exit codes:
#   0  success
#   1  lock acquisition failed / timed out (fail closed)
#   2  usage / repo path error
#   3  release refused (not our lock) — caller should not ignore
#
# Sourceable: `source branch-op-lock.sh` exposes
#   branch_op_lock_dir / branch_op_lock_acquire / branch_op_lock_release /
#   branch_op_lock_run
#
# Do NOT `set -e` at file scope — sourcing this into another script must not
# change the caller's errexit behaviour. The CLI entry enables pipefail locally.

DEFAULT_TIMEOUT_SEC=120
DEFAULT_STALE_TTL_SEC=600
BRANCH_OP_LOCK_TOKEN="${BRANCH_OP_LOCK_TOKEN-}"

branch_op_lock_dir() {
  local repo="$1" common
  if ! common=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null); then
    echo "branch-op-lock: cannot resolve git-common-dir for '$repo'" >&2
    return 2
  fi
  case "$common" in
    /*) ;;
    # This file deliberately does not `set -e`, so an unchecked command substitution here is
    # silent: a failed `cd` leaves `common` EMPTY and the lock path becomes
    # `/devantler-branch-op.lock` — every caller then serialises on a directory at the filesystem
    # root instead of the repository, so branch cleanup and worktree operations lose mutual
    # exclusion with no error anywhere. Fail closed instead.
    *)
      if ! common="$(cd "$repo" && cd "$common" && pwd)" || [[ -z "$common" ]]; then
        echo "branch-op-lock: cannot resolve absolute git-common-dir for '$repo'" >&2
        return 2
      fi
      ;;
  esac
  printf '%s\n' "$common/devantler-branch-op.lock"
}

_branch_op_lock_new_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
  else
    # Portable fallback — not cryptographic; ownership uniqueness is enough.
    head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'
  fi
}

# Directory mtime, in epoch seconds, across GNU and BSD userlands. `date -r <file>` handles both
# (BSD date documents `-r filename` alongside `-r seconds`), `stat -c %Y` is the GNU spelling and
# `stat -f %m` the BSD one. Prints nothing when every probe fails, so callers decide the fallback
# rather than inheriting a silent `0` that reads as 1970.
_branch_op_lock_dir_mtime() {
  local path="$1"
  date -u -r "$path" +%s 2>/dev/null && return 0
  stat -c %Y "$path" 2>/dev/null && return 0
  stat -f %m "$path" 2>/dev/null && return 0
  return 1
}

# Identity of the lock directory *instance*, so a reclaim decision can be checked against the same
# directory it was made about. The inode changes when a directory is removed and recreated, and the
# token distinguishes two holders that happen to reuse an inode number.
_branch_op_lock_identity() {
  local lockdir="$1" inode token
  inode=$(stat -c %i "$lockdir" 2>/dev/null || stat -f %i "$lockdir" 2>/dev/null) || return 1
  [[ -n "$inode" ]] || return 1
  token=""
  [[ -f "$lockdir/token" ]] && token=$(tr -d '[:space:]' <"$lockdir/token" 2>/dev/null || true)
  printf '%s:%s\n' "$inode" "$token"
}

_branch_op_lock_clear_dir() {
  local lockdir="$1"
  rm -f "$lockdir/pid" "$lockdir/token" "$lockdir/host" "$lockdir/pid_mode" \
    "$lockdir/acquired_at" "$lockdir/acquired_epoch" 2>/dev/null || true
  rmdir "$lockdir" 2>/dev/null || true
}

_branch_op_lock_is_stale() {
  local lockdir="$1" stale_ttl="$2"
  local pid_file="$lockdir/pid" host_file="$lockdir/host" at_file="$lockdir/acquired_at"
  local holder host_now host_then age now pid_mode

  if [[ ! -d "$lockdir" ]]; then
    return 1
  fi

  holder=""
  [[ -f "$pid_file" ]] && holder=$(tr -d '[:space:]' <"$pid_file" 2>/dev/null || true)
  host_now=$(uname -n 2>/dev/null || hostname 2>/dev/null || echo unknown)
  host_then=""
  [[ -f "$host_file" ]] && host_then=$(tr -d '[:space:]' <"$host_file" 2>/dev/null || true)

  # `pid_mode` decides whether PID liveness may be read at all. A lock taken by the in-process
  # `run`/library path is `supervised`: its recorded PID lives for exactly as long as the critical
  # section, so both liveness directions are meaningful. A lock taken by the standalone `acquire`
  # subcommand is `detached`: that process exits immediately by design and the caller does its work
  # afterwards, so its PID is dead while the lock is legitimately held — reading death as staleness
  # would let any competing acquirer reap a live claim on sight. Only the TTL governs a detached lock.
  pid_mode="supervised"
  [[ -f "$lockdir/pid_mode" ]] && pid_mode=$(tr -d '[:space:]' <"$lockdir/pid_mode" 2>/dev/null || true)

  if [[ -n "$holder" && "$host_then" == "$host_now" && "$pid_mode" == "supervised" ]]; then
    if kill -0 "$holder" 2>/dev/null; then
      # A LIVE same-host holder is never stale, whatever its age. The critical section legitimately
      # spans network calls (GitHub queries, per-branch pushes), so an age-only test would declare an
      # actively-running holder stale and let the next acquirer delete its directory mid-operation —
      # defeating the mutual exclusion the lock exists to provide.
      return 1
    fi
    return 0
  fi

  if [[ -f "$lockdir/acquired_epoch" ]]; then
    local stamp
    stamp=$(tr -d '[:space:]' <"$lockdir/acquired_epoch" 2>/dev/null || true)
    # A holder that died mid-write leaves this file empty or partial. Feeding that straight into
    # `$(( ))` makes bash treat it as a VARIABLE NAME, which aborts the caller under `set -u` and
    # otherwise prints an arithmetic error — either way the staleness question goes unanswered.
    # An unreadable stamp is not evidence of age, so fall through to the directory-mtime test
    # below rather than guessing.
    if [[ "$stamp" =~ ^[0-9]+$ ]]; then
      now=$(date -u +%s)
      age=$(( now - stamp ))
      if (( age >= stale_ttl )); then
        return 0
      fi
      return 1
    fi
  fi

  if [[ -f "$at_file" ]]; then
    now=$(date -u +%s)
    age=$(( now - $(_branch_op_lock_dir_mtime "$lockdir" || echo "$now") ))
    if (( age >= stale_ttl )); then
      return 0
    fi
    return 1
  fi

  # No metadata YET. `mkdir` publishes the directory before the acquirer can write into it, so a
  # waiter that loses the race observes exactly this state for a few milliseconds. Treating it as
  # immediately stale let that waiter delete the winner's directory while the winner was still
  # writing its own metadata — two holders, no error. Age it from the directory's own mtime, which
  # `mkdir` sets atomically, so a genuinely crashed half-write is still recovered once it exceeds
  # the TTL.
  #
  # When no mtime probe works the fallback is `now`, i.e. "treat it as brand new". That direction is
  # deliberate: an unreadable mtime must never manufacture an ancient age and reap a live holder, and
  # the script's own timeout message already promises to FAIL CLOSED. The `acquired_at` branch above
  # uses the same fallback, so both age paths agree.
  now=$(date -u +%s)
  age=$(( now - $(_branch_op_lock_dir_mtime "$lockdir" || echo "$now") ))
  if (( age >= stale_ttl )); then
    return 0
  fi
  return 1
}

_branch_op_lock_try_remove_stale() {
  local lockdir="$1" stale_ttl="$2"
  local ident_before ident_after

  # The staleness verdict is about ONE directory instance, and evaluating it takes real time (file
  # reads, `kill -0`, `date`). Without an identity check a waiter can decide "stale", have another
  # waiter reclaim and a third acquire in the meantime, and then delete the NEW holder's directory —
  # leaving two holders inside one critical section. Bracketing the verdict with the directory's
  # inode+token confines the clear to the instance actually judged stale; a replacement is left alone
  # and simply re-judged on the next pass.
  ident_before=$(_branch_op_lock_identity "$lockdir") || return 1
  _branch_op_lock_is_stale "$lockdir" "$stale_ttl" || return 1
  ident_after=$(_branch_op_lock_identity "$lockdir") || return 1
  [[ "$ident_before" == "$ident_after" ]] || return 1

  _branch_op_lock_clear_dir "$lockdir"
  return 0
}

branch_op_lock_acquire() {
  local repo="$1"
  local timeout="${2:-$DEFAULT_TIMEOUT_SEC}"
  local stale_ttl="${3:-$DEFAULT_STALE_TTL_SEC}"
  local lockdir start_epoch now holder_info token

  lockdir=$(branch_op_lock_dir "$repo") || return $?
  start_epoch=$(date -u +%s)

  while true; do
    if mkdir "$lockdir" 2>/dev/null; then
      token=$(_branch_op_lock_new_token)
      # Every metadata write is checked. An unchecked failure (a full disk, exhausted inodes) left the
      # acquirer holding a lock whose `pid`/`host` never landed, so `_branch_op_lock_is_stale` fell
      # through to the age path and a waiter reaped the ACTIVE holder once the TTL elapsed. A lock we
      # cannot describe is one we must not hold: tear it down and fail closed instead.
      if ! { printf '%s\n' "$$" >"$lockdir/pid" &&
             printf '%s\n' "$token" >"$lockdir/token" &&
             printf '%s\n' "$(uname -n 2>/dev/null || hostname 2>/dev/null || echo unknown)" >"$lockdir/host" &&
             printf '%s\n' "${BRANCH_OP_LOCK_PID_MODE:-supervised}" >"$lockdir/pid_mode" &&
             printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$lockdir/acquired_at" &&
             printf '%s\n' "$(date -u +%s)" >"$lockdir/acquired_epoch"; }; then
        _branch_op_lock_clear_dir "$lockdir"
        echo "branch-op-lock: FAIL CLOSED — acquired '$lockdir' but could not write its metadata; lock released." >&2
        return 1
      fi
      BRANCH_OP_LOCK_TOKEN="$token"
      # CLI callers capture stdout; sourced callers use BRANCH_OP_LOCK_TOKEN.
      printf '%s\n' "$token"
      return 0
    fi

    _branch_op_lock_try_remove_stale "$lockdir" "$stale_ttl" || true

    now=$(date -u +%s)
    if (( now - start_epoch >= timeout )); then
      holder_info="unknown"
      if [[ -f "$lockdir/pid" ]]; then
        holder_info="pid=$(tr -d '[:space:]' <"$lockdir/pid" 2>/dev/null || echo '?')"
        if [[ -f "$lockdir/acquired_at" ]]; then
          holder_info+=" since=$(tr -d '[:space:]' <"$lockdir/acquired_at")"
        fi
      fi
      echo "branch-op-lock: FAIL CLOSED — could not acquire '$lockdir' within ${timeout}s ($holder_info). Stale-lock recovery: same-host dead PID, or age ≥ ${stale_ttl}s. Manual recovery: confirm no agent holds it, then rm -rf the lock directory." >&2
      return 1
    fi
    sleep 1
  done
}

branch_op_lock_release() {
  local repo="$1"
  local token="${2:-${BRANCH_OP_LOCK_TOKEN-}}"
  local lockdir holder stored

  lockdir=$(branch_op_lock_dir "$repo") || return $?

  if [[ ! -d "$lockdir" ]]; then
    BRANCH_OP_LOCK_TOKEN=""
    return 0
  fi

  holder=""
  [[ -f "$lockdir/pid" ]] && holder=$(tr -d '[:space:]' <"$lockdir/pid" 2>/dev/null || true)
  stored=""
  [[ -f "$lockdir/token" ]] && stored=$(tr -d '[:space:]' <"$lockdir/token" 2>/dev/null || true)

  if [[ -n "$token" && -n "$stored" && "$token" == "$stored" ]]; then
    :
  elif [[ -n "$holder" && "$holder" == "$$" ]]; then
    :
  else
    echo "branch-op-lock: REFUSING release of '$lockdir' — token/pid mismatch (holder pid=${holder:-?}, we=$$)" >&2
    return 3
  fi

  _branch_op_lock_clear_dir "$lockdir"
  BRANCH_OP_LOCK_TOKEN=""
  if [[ -d "$lockdir" ]]; then
    echo "branch-op-lock: WARN — could not rmdir '$lockdir' (left in place)" >&2
    return 3
  fi
  return 0
}

branch_op_lock_run() {
  local repo="$1"
  shift
  local timeout="$DEFAULT_TIMEOUT_SEC" stale_ttl="$DEFAULT_STALE_TTL_SEC"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout-sec) timeout="${2-}"; shift 2 ;;
      --stale-ttl-sec) stale_ttl="${2-}"; shift 2 ;;
      --) shift; break ;;
      *) echo "branch-op-lock: unexpected arg '$1' before --" >&2; return 2 ;;
    esac
  done
  if [[ $# -lt 1 ]]; then
    echo "branch-op-lock: run requires a command after --" >&2
    return 2
  fi

  # Discard the token line from stdout so wrapped commands keep a clean pipe.
  branch_op_lock_acquire "$repo" "$timeout" "$stale_ttl" >/dev/null || return $?
  local token="$BRANCH_OP_LOCK_TOKEN"
  # This helper is sourceable, so the caller may already own an EXIT handler — `worktree-claim.sh`
  # releases its ownership mutex there. The caller's EXIT slot is therefore never read or replaced:
  # `trap -p EXIT` reports a handler INHERITED from an ancestor shell on bash >= 5 even when this
  # shell armed none, and no probe separates the two cases, so capturing it and eval-ing it back
  # ARMED a dormant ancestor handler and fired that cleanup at the wrong time. A subshell owns the
  # release trap instead, which leaves the caller's own handler untouched on every bash version.
  local rc=0
  (
    # Single-quoted so `$repo` and `$token` are expanded when the trap FIRES, not when it is armed.
    # Double-quoting bakes the values into the trap body, so a repository path containing a single
    # quote produces a syntactically broken handler and the safety-net release never runs — the
    # lock then leaks until its TTL expires. Both names are locals of `branch_op_lock_run` and stay
    # visible inside this subshell, so deferring the expansion is also correct.
    trap 'branch_op_lock_release "$repo" "$token" >/dev/null 2>&1 || true' EXIT
    inner_rc=0
    "$@" || inner_rc=$?
    # Normal completion: drop the safety net (this subshell's slot only) so the accountable release
    # below reports its own status instead of finding the lock already gone.
    trap - EXIT
    # A failed release means the lock directory is still there — every later worktree or branch
    # operation will block on it until the TTL expires. Discarding that status reported a clean
    # cleanup over a leaked lock, so it is propagated when the wrapped command itself succeeded.
    release_rc=0
    branch_op_lock_release "$repo" "$token" || release_rc=$?
    if (( inner_rc == 0 && release_rc != 0 )); then
      exit "$release_rc"
    fi
    exit "$inner_rc"
  ) || rc=$?
  BRANCH_OP_LOCK_TOKEN="$token"
  return "$rc"
}

_branch_op_lock_usage() {
  sed -n '/^# Usage:/,/^#   3 /p' "$0" | sed 's/^# \{0,1\}//'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
  cmd="${1-}"
  shift || true
  case "$cmd" in
    acquire)
      repo="${1-}"; shift || true
      [[ -n "$repo" ]] || { _branch_op_lock_usage >&2; exit 2; }
      timeout="$DEFAULT_TIMEOUT_SEC"; stale_ttl="$DEFAULT_STALE_TTL_SEC"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --timeout-sec) timeout="${2-}"; shift 2 ;;
          --stale-ttl-sec) stale_ttl="${2-}"; shift 2 ;;
          *) echo "branch-op-lock: unknown arg '$1'" >&2; exit 2 ;;
        esac
      done
      BRANCH_OP_LOCK_PID_MODE=detached branch_op_lock_acquire "$repo" "$timeout" "$stale_ttl"
      ;;
    release)
      repo="${1-}"; shift || true
      [[ -n "$repo" ]] || { _branch_op_lock_usage >&2; exit 2; }
      token=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --token) token="${2-}"; shift 2 ;;
          *) echo "branch-op-lock: unknown arg '$1'" >&2; exit 2 ;;
        esac
      done
      [[ -n "$token" ]] || { echo "branch-op-lock: release requires --token" >&2; exit 2; }
      branch_op_lock_release "$repo" "$token"
      ;;
    run)
      repo="${1-}"; shift || true
      [[ -n "$repo" ]] || { _branch_op_lock_usage >&2; exit 2; }
      branch_op_lock_run "$repo" "$@"
      ;;
    -h|--help|help|"")
      _branch_op_lock_usage
      exit 0
      ;;
    *)
      echo "branch-op-lock: unknown command '$cmd'" >&2
      _branch_op_lock_usage >&2
      exit 2
      ;;
  esac
fi
