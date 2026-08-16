#!/usr/bin/env bash
#
# Self-test for branch-op-lock.sh + worktree-add.sh (monorepo#2209).
#
# Proves the shared lock actually serialises a harness checkout against a
# concurrent local-deletion critical section — the race `git branch -D` and
# `git update-ref -d` cannot close alone. Also covers stale-lock recovery and
# fail-closed timeout.
#
# Fixtures are throwaway git repos in a temp dir — no real checkout touched.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lock_tool="$script_dir/branch-op-lock.sh"
wt_add="$script_dir/worktree-add.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; failures=$(( failures + 1 )); }

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

# shellcheck source=branch-op-lock.sh
source "$lock_tool"

# ---------------------------------------------------------------------------
# Fixture: a tiny git repo with one commit and a side branch.
# ---------------------------------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "branch-op-lock test"
echo seed >"$repo/README"
git -C "$repo" add README
git -C "$repo" commit -q -m seed
git -C "$repo" branch claude/spent-fixture-2209

lockdir=$(branch_op_lock_dir "$repo")

# ---------------------------------------------------------------------------
# Acquire + release round-trip in the SAME shell (token stays in-process).
# ---------------------------------------------------------------------------
token=$(branch_op_lock_acquire "$repo" 5)
check "acquire exits 0 / returns token" "1" "$([[ -n "$token" ]] && echo 1 || echo 0)"
check "lock dir exists while held" "1" "$([[ -d "$lockdir" ]] && echo 1 || echo 0)"
check "release exits 0" "0" "$(branch_op_lock_release "$repo" "$token" >/dev/null 2>&1; echo $?)"
check "lock dir gone after release" "0" "$([[ -d "$lockdir" ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# Stale-lock recovery: dead-pid + same-host metadata is reaped.
# ---------------------------------------------------------------------------
mkdir -p "$lockdir"
printf '999999\n' >"$lockdir/pid"
printf 'dead-token\n' >"$lockdir/token"
printf '%s\n' "$(uname -n)" >"$lockdir/host"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$lockdir/acquired_at"
printf '%s\n' "$(date -u +%s)" >"$lockdir/acquired_epoch"
token=$(branch_op_lock_acquire "$repo" 5)
check "stale dead-pid lock is acquired" "1" "$([[ -n "$token" ]] && echo 1 || echo 0)"
branch_op_lock_release "$repo" "$token" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Fail-closed timeout: a LIVE holder (background process that stays up) blocks.
# ---------------------------------------------------------------------------
holder_token_file="$tmp/holder_token"
(
  # Keep this process alive so kill -0 sees a live holder.
  t=$(branch_op_lock_acquire "$repo" 5)
  printf '%s\n' "$t" >"$holder_token_file"
  sleep 5
  branch_op_lock_release "$repo" "$t" >/dev/null 2>&1 || true
) &
holder_pid=$!
# Wait until the holder has the lock.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$holder_token_file" && -d "$lockdir" ]] && break
  sleep 0.2
done
rc=0
branch_op_lock_acquire "$repo" 2 >/dev/null 2>&1 || rc=$?
check "live holder causes acquire timeout (exit 1)" "1" "$rc"
wait "$holder_pid" || true
# Ensure clean for next test.
[[ -d "$lockdir" ]] && _branch_op_lock_clear_dir "$lockdir" || true

# ---------------------------------------------------------------------------
# Concurrent regression: cleanup critical section vs worktree-add.
# While a holder owns the lock (simulating local deletion), worktree-add must
# NOT finish until release. Timestamps prove no overlap.
# ---------------------------------------------------------------------------
wt_path="$tmp/wt-concurrent"

(
  t=$(branch_op_lock_acquire "$repo" 5)
  date -u +%s >"$tmp/cleanup_hold_start"
  sleep 3
  date -u +%s >"$tmp/cleanup_hold_end"
  branch_op_lock_release "$repo" "$t"
) &
cleaner_pid=$!

# Wait until cleaner holds the lock.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -d "$lockdir" ]] && break
  sleep 0.2
done

add_rc=0
BRANCH_OP_LOCK_TIMEOUT_SEC=10
date -u +%s >"$tmp/add_attempt_start"
bash "$wt_add" "$repo" "$wt_path" claude/spent-fixture-2209 >/dev/null 2>&1 || add_rc=$?
date -u +%s >"$tmp/add_done"
wait "$cleaner_pid" || true

check "worktree-add eventually succeeds under contention" "0" "$add_rc"
check "worktree exists after serialised add" "1" "$([[ -d "$wt_path" ]] && echo 1 || echo 0)"

hold_end=$(cat "$tmp/cleanup_hold_end")
add_done=$(cat "$tmp/add_done")
if (( add_done >= hold_end )); then
  pass "worktree-add finished only after cleanup released the lock"
else
  fail "worktree-add finished ($add_done) before cleanup release ($hold_end) — overlap"
fi

bash "$script_dir/worktree-remove.sh" "$repo" "$wt_path" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# run subcommand wraps an arbitrary command.
# ---------------------------------------------------------------------------
check "run wraps true" "0" \
  "$(bash "$lock_tool" run "$repo" --timeout-sec 5 -- true >/dev/null 2>&1; echo $?)"
check "run propagates failure" "7" \
  "$(bash "$lock_tool" run "$repo" --timeout-sec 5 -- bash -c 'exit 7' >/dev/null 2>&1; echo $?)"
check "lock not left behind after run" "0" "$([[ -d "$lockdir" ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# CLI release requires --token (cross-process ownership).
# ---------------------------------------------------------------------------
cli_token=$(bash "$lock_tool" acquire "$repo" --timeout-sec 5)
# Immediate CLI acquire exits → dead pid; that is stale. Re-acquire via age would
# also work, but here we release with the printed token while simulating a
# still-held lock by rewriting pid to our live shell before release.
printf '%s\n' "$$" >"$lockdir/pid"
check "CLI release with token exits 0" "0" \
  "$(bash "$lock_tool" release "$repo" --token "$cli_token" >/dev/null 2>&1; echo $?)"


# ---------------------------------------------------------------------------
# Codex P1/P2 findings (t1139): staleness must not reap a LIVE or a HALF-WRITTEN
# lock, a detached CLI lock must survive its own exit, and `run` must not hide a
# failed release. Each case drives `_branch_op_lock_is_stale` directly so it
# tests the predicate rather than a wrapper's incidental behaviour.
# ---------------------------------------------------------------------------
stale_repo="$tmp/stale-repo"
mkdir -p "$stale_repo"
git -C "$stale_repo" init -q -b main
git -C "$stale_repo" config user.email "test@example.com"
git -C "$stale_repo" config user.name "Test"
git -C "$stale_repo" commit -q --allow-empty -m init
stale_lockdir=$(branch_op_lock_dir "$stale_repo")

# (1) A LIVE same-host supervised holder is never stale, even far past the TTL.
rm -rf "$stale_lockdir"; mkdir -p "$stale_lockdir"
printf '%s\n' "$$" >"$stale_lockdir/pid"
printf '%s\n' "$(uname -n)" >"$stale_lockdir/host"
printf '%s\n' "supervised" >"$stale_lockdir/pid_mode"
printf '%s\n' "$(( $(date -u +%s) - 99999 ))" >"$stale_lockdir/acquired_epoch"
check "live same-host supervised holder is NOT stale past TTL" "1" \
  "$(_branch_op_lock_is_stale "$stale_lockdir" 600; echo $?)"

# (2) A DEAD same-host supervised holder still IS stale — the recovery path must survive fix (1).
rm -rf "$stale_lockdir"; mkdir -p "$stale_lockdir"
dead_pid=$(bash -c 'echo $$')          # exited before we read it
printf '%s\n' "$dead_pid" >"$stale_lockdir/pid"
printf '%s\n' "$(uname -n)" >"$stale_lockdir/host"
printf '%s\n' "supervised" >"$stale_lockdir/pid_mode"
printf '%s\n' "$(date -u +%s)" >"$stale_lockdir/acquired_epoch"
check "dead same-host supervised holder IS stale" "0" \
  "$(_branch_op_lock_is_stale "$stale_lockdir" 600; echo $?)"

# (3) A DETACHED lock is not reaped for a dead pid — the CLI `acquire` process exits by design.
rm -rf "$stale_lockdir"; mkdir -p "$stale_lockdir"
printf '%s\n' "$dead_pid" >"$stale_lockdir/pid"
printf '%s\n' "$(uname -n)" >"$stale_lockdir/host"
printf '%s\n' "detached" >"$stale_lockdir/pid_mode"
printf '%s\n' "$(date -u +%s)" >"$stale_lockdir/acquired_epoch"
check "detached lock with dead pid is NOT stale inside TTL" "1" \
  "$(_branch_op_lock_is_stale "$stale_lockdir" 600; echo $?)"

# (4) …but a detached lock past its TTL still IS recoverable.
printf '%s\n' "$(( $(date -u +%s) - 99999 ))" >"$stale_lockdir/acquired_epoch"
check "detached lock past TTL IS stale" "0" \
  "$(_branch_op_lock_is_stale "$stale_lockdir" 600; echo $?)"

# (5) A freshly-mkdir'd lock with NO metadata yet is the mkdir/write window — not stale.
rm -rf "$stale_lockdir"; mkdir -p "$stale_lockdir"
check "half-written lock (no metadata) is NOT stale inside TTL" "1" \
  "$(_branch_op_lock_is_stale "$stale_lockdir" 600; echo $?)"

# (6) …but an abandoned half-write is still recovered once it ages out (TTL 0 ⇒ any age qualifies).
check "half-written lock IS stale once past TTL" "0" \
  "$(_branch_op_lock_is_stale "$stale_lockdir" 0; echo $?)"

# (7) `run` surfaces a failed release instead of reporting success over a leaked lock.
rm -rf "$stale_lockdir"
run_rc=0
# The wrapped command SUCCEEDS but leaves a stray file, so `rmdir` fails and release returns 3.
# Passing the absolute lockdir as $0 keeps this about the release path rather than about how the
# inner shell resolves a relative git-common-dir.
branch_op_lock_run "$stale_repo" -- bash -c ': >"$0/stray-file"' "$stale_lockdir" >/dev/null 2>&1 || run_rc=$?
check "run propagates a failed release (leaked lock)" "3" "$run_rc"
rm -rf "$stale_lockdir"

# ---------------------------------------------------------------------------
# `run` must PRESERVE a caller's pre-existing EXIT trap.
#
# This helper is sourceable and `worktree-claim.sh` releases its ownership mutex from an EXIT
# handler. A bare `trap - EXIT` after the wrapped command deleted that handler for the rest of the
# process, so a later exit left the CAS claim ref behind. Run it in a subshell so the assertion is
# about what the caller's own EXIT handler does at exit, not about this test's shell.
# ---------------------------------------------------------------------------
caller_trap_marker="$tmp/caller-exit-ran"
rm -f "$caller_trap_marker"
(
  # shellcheck source=branch-op-lock.sh
  source "$lock_tool"
  trap 'printf ran >"'"$caller_trap_marker"'"' EXIT
  branch_op_lock_run "$stale_repo" -- true >/dev/null 2>&1
) || true
check "run preserves the caller's pre-existing EXIT trap" "ran" \
  "$(cat "$caller_trap_marker" 2>/dev/null || echo MISSING)"

# …and with no caller trap installed, `run` must still leave EXIT clear rather than restoring junk.
(
  # shellcheck source=branch-op-lock.sh
  source "$lock_tool"
  branch_op_lock_run "$stale_repo" -- true >/dev/null 2>&1
  [[ -z "$(trap -p EXIT)" ]]
)
check "run leaves EXIT clear when the caller had no trap" "0" "$?"
rm -rf "$stale_lockdir"

# ---------------------------------------------------------------------------
# A lock whose metadata cannot be written must NOT be reported as acquired.
#
# An unchecked write failure left the holder with no `pid`/`host`, so staleness fell through to the
# age path and a waiter reaped the ACTIVE holder once the TTL elapsed. Simulate the failure by making
# the lock directory read-only after `mkdir` wins, which is what a full disk looks like to `printf`.
# ---------------------------------------------------------------------------
rm -rf "$stale_lockdir"
acquire_rc=0
(
  # shellcheck source=branch-op-lock.sh
  source "$lock_tool"
  # Fail every `printf` after the first, which is the one `branch_op_lock_dir` needs to report the
  # path. That lands the failure squarely on the metadata block — the same shape a full disk or
  # exhausted inodes produces — without depending on filesystem permissions.
  _pf_calls=0
  printf() {
    _pf_calls=$(( _pf_calls + 1 ))
    (( _pf_calls >= 2 )) && return 1
    builtin printf "$@"
  }
  branch_op_lock_acquire "$stale_repo" 5 600 >/dev/null 2>&1
) || acquire_rc=$?
check "acquire FAILS when its metadata cannot be written" "1" "$acquire_rc"
check "a metadata-write failure leaves NO lock dir behind" "0" \
  "$([[ -d "$stale_lockdir" ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# Reclaiming a stale lock must act on the instance it JUDGED, not whatever occupies the path now.
#
# Without an identity check a waiter could decide "stale", have the directory replaced by a fresh
# holder in the meantime, and then delete that new holder's directory — two holders, one critical
# section. `_branch_op_lock_try_remove_stale` brackets its verdict with the directory's inode+token.
# ---------------------------------------------------------------------------
rm -rf "$stale_lockdir"
mkdir -p "$stale_lockdir"                       # half-written ⇒ stale at TTL 0
ident_orig=$(_branch_op_lock_identity "$stale_lockdir")
check "identity is readable for an existing lock dir" "1" \
  "$([[ -n "$ident_orig" ]] && echo 1 || echo 0)"

# Replace the directory (new inode) and confirm the identity actually changes — otherwise the guard
# below would pass vacuously.
rm -rf "$stale_lockdir"; mkdir -p "$stale_lockdir"
ident_new=$(_branch_op_lock_identity "$stale_lockdir")
check "a replaced lock dir has a DIFFERENT identity" "1" \
  "$([[ "$ident_orig" != "$ident_new" ]] && echo 1 || echo 0)"

# Positive control: an unreplaced stale dir IS reclaimed.
rm -rf "$stale_lockdir"; mkdir -p "$stale_lockdir"
check "unreplaced stale lock IS reclaimed" "0" \
  "$(_branch_op_lock_try_remove_stale "$stale_lockdir" 0; echo $?)"
check "reclaimed lock dir is gone" "0" \
  "$([[ -d "$stale_lockdir" ]] && echo 1 || echo 0)"

# NEGATIVE control — the race itself, made deterministic. Shadow the staleness test so it replaces
# the directory as a side effect, exactly as a competing waiter would between the verdict and the
# clear. The reclaim must decline, and the new holder's directory must survive untouched.
rm -rf "$stale_lockdir"; mkdir -p "$stale_lockdir"
race_rc=0
race_out=$(
  # shellcheck source=branch-op-lock.sh
  source "$lock_tool"
  _branch_op_lock_is_stale() {
    rm -rf "$1"; mkdir -p "$1"          # a rival reclaimed and re-acquired under us
    printf 'newholder\n' >"$1/token"
    return 0                             # …and we still say "stale", as the old code would
  }
  _branch_op_lock_try_remove_stale "$stale_lockdir" 0 || echo DECLINED
) || race_rc=$?
check "reclaim DECLINES when the dir was replaced mid-verdict" "DECLINED" "$race_out"
check "the replacement holder's dir SURVIVES the declined reclaim" "1" \
  "$([[ -d "$stale_lockdir" ]] && echo 1 || echo 0)"
check "the replacement holder's token is intact" "newholder" \
  "$(cat "$stale_lockdir/token" 2>/dev/null || echo MISSING)"
rm -rf "$stale_lockdir"

# ---------------------------------------------------------------------------
# Directory mtime must resolve on this host — the `echo 0` fallback made a NEW lock look ancient.
# ---------------------------------------------------------------------------
mtime_probe_dir="$tmp/mtime-probe"
mkdir -p "$mtime_probe_dir"
probe_mtime=$(_branch_op_lock_dir_mtime "$mtime_probe_dir" || echo FAILED)
check "dir mtime probe resolves on this host" "1" \
  "$([[ "$probe_mtime" =~ ^[0-9]+$ ]] && echo 1 || echo 0)"
# A just-created directory must read as ~0s old, never as 1970 (which is >= any TTL ⇒ instant reap).
probe_age=$(( $(date -u +%s) - probe_mtime ))
check "a brand-new dir is NOT already past a 600s TTL" "1" \
  "$([[ "$probe_age" -lt 600 ]] && echo 1 || echo 0)"
rm -rf "$mtime_probe_dir"
# ---------------------------------------------------------------------------
if [[ "$failures" -gt 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall checks passed\n'
exit 0
