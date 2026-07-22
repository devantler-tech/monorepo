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
if [[ "$failures" -gt 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall checks passed\n'
exit 0
