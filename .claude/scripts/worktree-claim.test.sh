#!/usr/bin/env bash
#
# Self-test for worktree-claim.sh (monorepo#2284).
# Hermetic: uses a throwaway git repo + worktrees; no network.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/worktree-claim.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

check() {
  local name="$1" want="$2" got="$3" hay="${4:-}" needle="${5:-}"
  if [ "$want" != "$got" ]; then
    printf 'FAIL %s: expected exit %s, got %s\n' "$name" "$want" "$got" >&2
    fail=$((fail + 1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$hay" | grep -qF "$needle"; then
    printf 'FAIL %s: output missing %q\n  got: %s\n' "$name" "$needle" "$hay" >&2
    fail=$((fail + 1)); return
  fi
  printf 'ok   %s\n' "$name"
  pass=$((pass + 1))
}

chmod +x "$script"

# Throwaway repo
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.name "worktree-claim-test"
git -C "$repo" config user.email "worktree-claim-test@example.com"
git -C "$repo" commit --allow-empty -qm "init"

wt="$tmp/wt-a"

# ── add writes marker ──────────────────────────────────────────────────────
out="$("$script" add "$repo" "$wt" "claim-branch-a" "session-alpha" 2>&1)"
rc=$?
check "add succeeds" 0 "$rc" "$out" "owner=session-alpha"
check "marker file exists" 0 "$([ -f "$wt/.claude-worktree-owner" ] && echo 0 || echo 1)"
owner_line="$(grep '^owner=' "$wt/.claude-worktree-owner")"
check "marker owner line" 0 0 "$owner_line" "owner=session-alpha"
created_line="$(grep '^created_at=' "$wt/.claude-worktree-owner")"
check "marker created_at present" 0 0 "$created_line" "created_at="

# ── check: mine ────────────────────────────────────────────────────────────
out="$("$script" check "$wt" "session-alpha" 2>&1)"
rc=$?
check "check mine" 0 "$rc" "$out" "mine"

# ── check: live foreign ────────────────────────────────────────────────────
out="$("$script" check "$wt" "session-beta" 2>&1)" || rc=$?
# When exit is non-zero under set -e with ||, capture explicitly:
rc=0
out="$("$script" check "$wt" "session-beta" 2>&1)" || rc=$?
check "check live foreign" 3 "$rc" "$out" "LIVE foreign claim"

# ── check: expired foreign ─────────────────────────────────────────────────
# Rewrite marker with an old timestamp (3h ago).
old="$(date -u -d '3 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ")"
printf 'owner=session-alpha\ncreated_at=%s\n' "$old" >"$wt/.claude-worktree-owner"
rc=0
out="$("$script" check "$wt" "session-beta" 2>&1)" || rc=$?
check "check expired foreign" 0 "$rc" "$out" "expired"

# ── check: absent path is free ─────────────────────────────────────────────
rc=0
out="$("$script" check "$tmp/no-such-wt" "session-beta" 2>&1)" || rc=$?
check "check absent path" 0 "$rc" "$out" "path absent"

# ── mark on existing tree ──────────────────────────────────────────────────
bare="$tmp/bare-wt"
git -C "$repo" worktree add -q -b "claim-branch-b" "$bare"
rc=0
out="$("$script" mark "$bare" "session-gamma" 2>&1)" || rc=$?
check "mark succeeds" 0 "$rc" "$out" "owner=session-gamma"
rc=0
out="$("$script" check "$bare" "session-other" 2>&1)" || rc=$?
check "mark then foreign check" 3 "$rc" "$out" "LIVE foreign claim"

# ── usage error ────────────────────────────────────────────────────────────
rc=0
out="$("$script" 2>&1)" || rc=$?
check "usage no args" 1 "$rc"

printf '\nworktree-claim: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
