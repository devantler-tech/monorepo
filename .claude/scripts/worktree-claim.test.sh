#!/usr/bin/env bash
#
# Self-test for worktree-claim.sh (monorepo#2284).
# Hermetic: uses a throwaway git repo + worktrees; no network.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/worktree-claim.sh"
root_contract="$here/../../AGENTS.md"
maintenance_contract="$here/../skills/portfolio-maintenance/SKILL.md"
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
status_lines="$(git -C "$wt" status --porcelain --untracked-files=all)"
check "marker leaves worktree clean" "" "$status_lines"

# ── add resolves a relative worktree path from the repository ──────────────────────
relative_wt=".claim-relative-wt"
rc=0
out="$(cd "$tmp" && "$script" add "repo" "$relative_wt" "claim-branch-relative" "session-relative" 2>&1)" || rc=$?
check "relative add succeeds" 0 "$rc" "$out" "owner=session-relative"
check "relative marker is repo-relative" 0 "$([ -f "$repo/$relative_wt/.claude-worktree-owner" ] && echo 0 || echo 1)"

# ── check: mine ────────────────────────────────────────────────────────────
out="$("$script" check "$wt" "session-alpha" 2>&1)"
rc=$?
check "check mine" 0 "$rc" "$out" "mine"

# ── check: live foreign ────────────────────────────────────────────────────
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

# ── acquire: expired ownership transfers atomically ──────────────────────────
rc=0
out="$("$script" acquire "$wt" "session-beta" 2>&1)" || rc=$?
check "acquire transfers expired claim" 0 "$rc" "$out" "owner=session-beta"
owner_line="$(grep '^owner=' "$wt/.claude-worktree-owner")"
check "transferred marker owner" 0 0 "$owner_line" "owner=session-beta"

# ── acquire: current owner renews its lease ───────────────────────────────
printf 'owner=session-beta\ncreated_at=%s\n' "$old" >"$wt/.claude-worktree-owner"
rc=0
out="$("$script" acquire "$wt" "session-beta" 2>&1)" || rc=$?
check "acquire renews own claim" 0 "$rc" "$out" "renewed"
renewed_at="$(sed -n 's/^created_at=//p' "$wt/.claude-worktree-owner")"
check "renewal refreshes timestamp" 0 "$([ "$renewed_at" != "$old" ] && echo 0 || echo 1)"

# ── malformed foreign marker fails closed ───────────────────────────────────
printf 'owner=session-beta\ncreated_at=not-a-timestamp\n' >"$wt/.claude-worktree-owner"
rc=0
out="$("$script" acquire "$wt" "session-other" 2>&1)" || rc=$?
check "malformed foreign marker fails closed" 2 "$rc" "$out" "unparseable"

# ── acquire recovers a lock whose owner process is gone ────────────────────────────
stale="$tmp/stale-lock-wt"
git -C "$repo" worktree add -q -b "claim-branch-stale-lock" "$stale"
stale_real="$(cd "$stale" && pwd -P)"
stale_hash="$(printf '%s' "$stale_real" | git -C "$stale" hash-object --stdin)"
stale_ref="refs/worktree/claim-locks/$stale_hash"
stale_blob="$(printf 'pid=999999999\ncreated_at=%s\n' "$old" | git -C "$stale" hash-object -w --stdin)"
git -C "$stale" update-ref "$stale_ref" "$stale_blob"
rc=0
out="$("$script" acquire "$stale" "session-after-crash" 2>&1)" || rc=$?
check "acquire recovers stale process lock" 0 "$rc" "$out" "owner=session-after-crash"
check "recovered lock ref is released" 1 "$(git -C "$stale" rev-parse -q --verify "$stale_ref" >/dev/null 2>&1; echo $?)"

# ── concurrent stale-lock recovery is compare-and-swap safe ────────────────────────
stale_race="$tmp/stale-race-wt"
git -C "$repo" worktree add -q -b "claim-branch-stale-race" "$stale_race"
stale_race_real="$(cd "$stale_race" && pwd -P)"
stale_race_hash="$(printf '%s' "$stale_race_real" | git -C "$stale_race" hash-object --stdin)"
stale_race_ref="refs/worktree/claim-locks/$stale_race_hash"
stale_race_blob="$(printf 'pid=999999999\ncreated_at=%s\n' "$old" | git -C "$stale_race" hash-object -w --stdin)"
git -C "$stale_race" update-ref "$stale_race_ref" "$stale_race_blob"
"$script" acquire "$stale_race" "session-stale-racer-a" >"$tmp/stale-racer-a.out" 2>&1 &
stale_pid_a=$!
"$script" acquire "$stale_race" "session-stale-racer-b" >"$tmp/stale-racer-b.out" 2>&1 &
stale_pid_b=$!
stale_rc_a=0
wait "$stale_pid_a" || stale_rc_a=$?
stale_rc_b=0
wait "$stale_pid_b" || stale_rc_b=$?
stale_race_result=1
if { [ "$stale_rc_a" -eq 0 ] && [ "$stale_rc_b" -eq 3 ]; } ||
  { [ "$stale_rc_a" -eq 3 ] && [ "$stale_rc_b" -eq 0 ]; }; then
  stale_race_result=0
fi
check "concurrent stale recovery has one winner" 0 "$stale_race_result"

# ── acquire: concurrent claimants have exactly one winner ────────────────────────
race="$tmp/race-wt"
git -C "$repo" worktree add -q -b "claim-branch-race" "$race"
"$script" acquire "$race" "session-racer-a" >"$tmp/racer-a.out" 2>&1 &
pid_a=$!
"$script" acquire "$race" "session-racer-b" >"$tmp/racer-b.out" 2>&1 &
pid_b=$!
rc_a=0
wait "$pid_a" || rc_a=$?
rc_b=0
wait "$pid_b" || rc_b=$?
race_result=1
if { [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 3 ]; } ||
  { [ "$rc_a" -eq 3 ] && [ "$rc_b" -eq 0 ]; }; then
  race_result=0
fi
check "concurrent acquire has one winner" 0 "$race_result"
race_owner="$(sed -n 's/^owner=//p' "$race/.claude-worktree-owner")"
winner="session-racer-a"
[ "$rc_b" -eq 0 ] && winner="session-racer-b"
check "concurrent winner owns marker" "$winner" "$race_owner"

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

# ── caller contract requires a per-run unique renewal token ────────────────────────
contract_rc=0
grep -qF 'unique to one runtime invocation' "$root_contract" || contract_rc=1
grep -qF 'unique to one runtime invocation' "$maintenance_contract" || contract_rc=1
check "contracts require a per-run unique owner token" 0 "$contract_rc"

printf '\nworktree-claim: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
