#!/usr/bin/env bash
#
# Harness-controlled `git worktree add` under the shared branch-operation lock
# (monorepo#2209). Prefer this over a bare `git worktree add` whenever the new
# worktree is an agent per-run tree — the same lock serialises local branch
# cleanup, so a concurrent cleanup cannot delete the branch mid-checkout.
#
# Usage:
#   worktree-add.sh <repo_path> <worktree_path> [git-worktree-add-args...]
#
# Examples:
#   worktree-add.sh applications/ksail .claude/worktrees/maint-abc \
#     -b cursor/area-desc-123
#   worktree-add.sh . /tmp/probe --detach
#
# All args after <worktree_path> are forwarded to `git worktree add` AFTER the
# path (so: git -C <repo> worktree add <worktree_path> <forwarded...>).
#
# Exit codes: lock failure → 1; usage → 2; otherwise git's exit status.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=branch-op-lock.sh
source "$script_dir/branch-op-lock.sh"

repo="${1-}"; shift || true
wt_path="${1-}"; shift || true

if [[ -z "$repo" || -z "$wt_path" ]]; then
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

timeout="${BRANCH_OP_LOCK_TIMEOUT_SEC:-120}"
branch_op_lock_run "$repo" --timeout-sec "$timeout" -- \
  git -C "$repo" worktree add "$wt_path" "$@"
