#!/usr/bin/env bash
#
# Harness-controlled `git worktree remove` under the shared branch-operation
# lock (monorepo#2209). Pair with worktree-add.sh so create and remove cannot
# race local branch cleanup.
#
# Usage:
#   worktree-remove.sh <repo_path> <worktree_path> [git-worktree-remove-args...]
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=branch-op-lock.sh
source "$script_dir/branch-op-lock.sh"

repo="${1-}"; shift || true
wt_path="${1-}"; shift || true

if [[ -z "$repo" || -z "$wt_path" ]]; then
  printf 'Usage: %s <repo_path> <worktree_path> [git-worktree-remove-args...]\n' \
    "$(basename "$0")" >&2
  exit 2
fi

timeout="${BRANCH_OP_LOCK_TIMEOUT_SEC:-120}"
branch_op_lock_run "$repo" --timeout-sec "$timeout" -- \
  git -C "$repo" worktree remove "$wt_path" "$@"
