#!/usr/bin/env bash
#
# Self-test for worktree-claim.sh (monorepo#2284).
# Hermetic: uses a throwaway git repo + worktrees; no network.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/worktree-claim.sh"
cleanup_script="$here/worktree-cleanup.sh"
shared_lib="$here/worktree-claim-lib.sh"
root_contract="$here/../../AGENTS.md"
maintenance_contract="$here/../skills/portfolio-maintenance/SKILL.md"
workflow_contract="$here/../../.github/workflows/ci.yaml"
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
# A pre-existing exclude file need not end with a newline. The marker rule must
# still become a distinct pattern rather than concatenate with the last one.
exclude_path="$(git -C "$bare" rev-parse --git-path info/exclude)"
printf 'existing-rule' >"$exclude_path"
rc=0
out="$("$script" mark "$bare" "session-gamma" 2>&1)" || rc=$?
check "mark succeeds" 0 "$rc" "$out" "owner=session-gamma"
bare_status="$(git -C "$bare" status --porcelain --untracked-files=all)"
check "newline-less exclude still ignores marker" "" "$bare_status"
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

# ── the claim and cleanup commands must share one mutex protocol ──────────────────
shared_rc=0
[ -f "$shared_lib" ] || shared_rc=1
grep -qF 'worktree-claim-lib.sh' "$script" || shared_rc=1
grep -qF 'worktree-claim-lib.sh' "$cleanup_script" || shared_rc=1
grep -qF 'WORKTREE_CLAIM_LOCK_REF_PREFIX' "$shared_lib" 2>/dev/null || shared_rc=1
grep -qF 'worktree_claim_lock_acquire()' "$shared_lib" 2>/dev/null || shared_rc=1
check "claim and cleanup source one mutex protocol" 0 "$shared_rc"

claim_filter=$(awk '
  /^            worktree-claim:/ { inside=1; next }
  inside && /^            [a-zA-Z0-9_-]+:/ { exit }
  inside { print }
' "$workflow_contract")
filter_rc=0
grep -qF ".claude/scripts/worktree-cleanup.sh" <<< "$claim_filter" || filter_rc=1
check "claim contract runs when cleanup consumer changes" 0 "$filter_rc"

# ── caller contracts fail closed on every acquisition error ─────────────────────
fail_closed_rc=0
grep -qiF 'only exit 0 authorizes' "$root_contract" || fail_closed_rc=1
grep -qiF 'only exit 0 authorizes' "$maintenance_contract" || fail_closed_rc=1
grep -qF 'every non-zero status' "$root_contract" || fail_closed_rc=1
grep -qF 'every non-zero status' "$maintenance_contract" || fail_closed_rc=1
check "contracts fail closed on every acquisition error" 0 "$fail_closed_rc"

# ── stale-base warning (the pinned-gitlink trap) ───────────────────────────────
# A submodule worktree is created at the pinned gitlink, not at the remote default branch. git is
# silent about the gap, so a tree tens of commits behind reads exactly like a current one. Both arms
# below are required: the control is what proves the warning is discriminating rather than
# unconditional, since a script that always warned would pass the positive arm alone.
origin_repo="$tmp/origin.git"
git init -q --bare -b main "$origin_repo"

seed="$tmp/seed"
git init -q -b main "$seed"
git -C "$seed" config user.name "worktree-claim-test"
git -C "$seed" config user.email "worktree-claim-test@example.com"
git -C "$seed" commit --allow-empty -qm "base"
git -C "$seed" remote add origin "$origin_repo"
git -C "$seed" push -q origin main

consumer="$tmp/consumer"
git clone -q "$origin_repo" "$consumer"
git -C "$consumer" config user.name "worktree-claim-test"
git -C "$consumer" config user.email "worktree-claim-test@example.com"

# Upstream advances by exactly two commits; the consumer stays pinned at base.
git -C "$seed" commit --allow-empty -qm "ahead-1"
git -C "$seed" commit --allow-empty -qm "ahead-2"
git -C "$seed" push -q origin main

stale_out="$("$script" add "$consumer" "$tmp/wt-stale" "claim-stale" "session-stale" 2>&1)"
stale_rc=$?
check "stale base still claims successfully (advisory, not fatal)" 0 "$stale_rc" \
  "$stale_out" "owner=session-stale"
check "stale base warns" 0 "$stale_rc" "$stale_out" "WARNING base is 2 commit(s) behind"
check "stale-base warning names the rebase fix" 0 "$stale_rc" "$stale_out" "rebase origin/main"

# Control: same script, same repo, base now current — the warning MUST disappear. If this arm also
# warned, the positive arm above would prove nothing about staleness detection.
git -C "$consumer" fetch -q origin main
git -C "$consumer" reset -q --hard origin/main
current_out="$("$script" add "$consumer" "$tmp/wt-current" "claim-current" "session-current" 2>&1)"
current_rc=$?
check "current base still claims successfully" 0 "$current_rc" "$current_out" "owner=session-current"
current_warn_rc=0
printf '%s' "$current_out" | grep -qF "WARNING base is" && current_warn_rc=1
check "current base does NOT warn (control)" 0 "$current_warn_rc"

# The numeric guard must be present: an unnormalised count would make the -gt test fail OPEN inside
# an if, silently skipping the warning on exactly the malformed input it should be loudest about.
#
# ⚠️ This arm is a SOURCE-COUPLED guard, not a behavioural one — reaching the malformed-count path
# needs `git rev-list --count` to emit a non-integer, which cannot be provoked hermetically. It is
# therefore matched on the two semantic tokens rather than a whole literal line: an exact-line match
# breaks on a harmless reformat and passes on the same text sitting in a comment, which fails in both
# directions. Replace this with a behavioural arm if the count ever moves behind an injectable seam.
normalise_rc=0
normalise_src="$(sed -n '/^warn_if_base_is_stale()/,/^}/p' "$script")"
printf '%s' "$normalise_src" | grep -qF 'behind=0' || normalise_rc=1
printf '%s' "$normalise_src" | grep -qF '[!0-9]' || normalise_rc=1
check "behind-count is normalised before the numeric test" 0 "$normalise_rc"

printf '\nworktree-claim: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
