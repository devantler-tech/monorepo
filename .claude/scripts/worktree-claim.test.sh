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
  # Here-string, not `printf | grep -q`: under `pipefail` grep exits at the first match and the
  # writer dies with EPIPE, so a LONGER haystack makes the pipeline report failure on a needle it
  # actually found. That turns a passing assertion into a size-dependent flake.
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$hay"; then
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
rc=0
out="$("$script" add "$repo" "$wt" "claim-branch-a" "session-alpha" 2>&1)" || rc=$?
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
rc=0
out="$("$script" check "$wt" "session-alpha" 2>&1)" || rc=$?
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

# `|| rc=$?`, not a bare assignment: under `set -Eeuo pipefail` a non-zero command substitution
# terminates the suite on the assignment itself, so a regression here would abort before the arm
# below could report it — no FAIL line, no summary, just a bare shell exit. The guard keeps the
# regression a reported failure. Same shape as the malformed-count arm at lines 429-431.
stale_rc=0
stale_out="$("$script" add "$consumer" "$tmp/wt-stale" "claim-stale" "session-stale" 2>&1)" || stale_rc=$?
check "stale base still claims successfully (advisory, not fatal)" 0 "$stale_rc" \
  "$stale_out" "owner=session-stale"
check "stale base warns" 0 "$stale_rc" "$stale_out" "WARNING base is 2 commit(s) behind"
# The hint must not name refs/remotes/origin/*: nothing in the claim updates it, so it is absent on a
# moved default and frozen under a narrowed refspec. It names the fetch that was actually measured.
check "stale-base warning names the rebase fix" 0 "$stale_rc" "$stale_out" "rebase FETCH_HEAD"
stale_hint_rc=0
grep -qF -- "rebase 'origin/main'" <<<"$stale_out" && stale_hint_rc=1
check "stale-base hint does NOT send the user to the tracking ref" 0 "$stale_hint_rc"

# Control: same script, same repo, base now current — the warning MUST disappear. If this arm also
# warned, the positive arm above would prove nothing about staleness detection.
git -C "$consumer" fetch -q origin main
git -C "$consumer" reset -q --hard origin/main
current_rc=0
current_out="$("$script" add "$consumer" "$tmp/wt-current" "claim-current" "session-current" 2>&1)" || current_rc=$?
check "current base still claims successfully" 0 "$current_rc" "$current_out" "owner=session-current"
current_warn_rc=0
grep -qF -- "WARNING base is" <<<"$current_out" && current_warn_rc=1
check "current base does NOT warn (control)" 0 "$current_warn_rc"

# The remote's default branch MOVED after the clone. refs/remotes/origin/HEAD is written once, at
# clone time, and no fetch refreshes it — so a check that trusts it keeps comparing against the old
# default and reports "not behind" while the tree is arbitrarily stale against the real one. That is
# the silent-wrong-answer case, strictly worse than the UNKNOWN below, because it looks like a pass.
moved_origin="$tmp/moved-origin.git"
git init -q --bare -b main "$moved_origin"
moved_seed="$tmp/moved-seed"
git init -q -b main "$moved_seed"
git -C "$moved_seed" config user.name "worktree-claim-test"
git -C "$moved_seed" config user.email "worktree-claim-test@example.com"
git -C "$moved_seed" commit --allow-empty -qm "base"
git -C "$moved_seed" remote add origin "$moved_origin"
git -C "$moved_seed" push -q origin main

moved_consumer="$tmp/moved-consumer"
git clone -q "$moved_origin" "$moved_consumer"
git -C "$moved_consumer" config user.name "worktree-claim-test"
git -C "$moved_consumer" config user.email "worktree-claim-test@example.com"

# Default moves main → trunk, and trunk advances by two commits. The consumer's origin/HEAD still
# names main, and main itself never moves — so comparing against the stale pointer yields behind=0.
git -C "$moved_seed" checkout -q -b trunk
git -C "$moved_seed" commit --allow-empty -qm "trunk-ahead-1"
git -C "$moved_seed" commit --allow-empty -qm "trunk-ahead-2"
git -C "$moved_seed" push -q origin trunk
git -C "$moved_origin" symbolic-ref HEAD refs/heads/trunk

moved_stale="$(git -C "$moved_consumer" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "")"
check "clone-time origin/HEAD still names the OLD default (precondition)" "origin/main" "$moved_stale"

moved_rc=0
moved_out="$("$script" add "$moved_consumer" "$tmp/wt-moved" "claim-moved" "session-moved" 2>&1)" || moved_rc=$?
check "moved default still claims successfully" 0 "$moved_rc" "$moved_out" "owner=session-moved"
check "moved default is measured against the CURRENT remote default" 0 "$moved_rc" \
  "$moved_out" "WARNING base is 2 commit(s) behind origin/trunk"

# A moved default does NOT break the old tracking-ref hint, and asserting that it did would pin a
# claim this suite can disprove: `git fetch origin +refs/heads/trunk:<private>` also applies the
# repository's CONFIGURED refspec, so an ordinary consumer gains origin/trunk as a side effect of the
# claim itself. Pinned as a precondition so the narrowed-refspec arms below are not later "tidied up"
# into covering this case too.
moved_tracking_ref="$(git -C "$moved_consumer" rev-parse --verify --quiet origin/trunk >/dev/null 2>&1 && echo present || echo absent)"
check "a moved default leaves the tracking ref PRESENT, so it is not the broken-hint case" \
  "present" "$moved_tracking_ref"

# The configured fetch refspec does not map the default branch into refs/remotes/origin/*. `git fetch
# origin main` still SUCCEEDS and still retrieves the new tip — but it lands in FETCH_HEAD only,
# because the command-line refspec controls what is fetched while the CONFIGURED mapping controls
# which remote-tracking refs get updated. So a pre-existing origin/main stays frozen at its old value,
# rev-parse resolves it happily, and the comparison is made against a ref that no longer tracks
# anything. Same silent false-current as the moved-default case above, reached one layer down: every
# guard in this function fires correctly and the ANSWER is still wrong, because the ref being compared
# is not the tip that was just fetched.
narrowed_origin="$tmp/narrowed-origin.git"
git init -q --bare -b main "$narrowed_origin"
narrowed_seed="$tmp/narrowed-seed"
git init -q -b main "$narrowed_seed"
git -C "$narrowed_seed" config user.name "worktree-claim-test"
git -C "$narrowed_seed" config user.email "worktree-claim-test@example.com"
git -C "$narrowed_seed" commit --allow-empty -qm "base"
git -C "$narrowed_seed" remote add origin "$narrowed_origin"
git -C "$narrowed_seed" push -q origin main

narrowed_consumer="$tmp/narrowed-consumer"
git clone -q "$narrowed_origin" "$narrowed_consumer"
git -C "$narrowed_consumer" config user.name "worktree-claim-test"
git -C "$narrowed_consumer" config user.email "worktree-claim-test@example.com"
# Narrow the mapping so main is no longer covered. origin/main SURVIVES at the clone-time value,
# which is what makes this the silent case rather than the UNKNOWN one.
git -C "$narrowed_consumer" config remote.origin.fetch "+refs/heads/release/*:refs/remotes/origin/release/*"

git -C "$narrowed_seed" commit --allow-empty -qm "ahead-1"
git -C "$narrowed_seed" commit --allow-empty -qm "ahead-2"
git -C "$narrowed_seed" commit --allow-empty -qm "ahead-3"
git -C "$narrowed_seed" push -q origin main

narrowed_pre="$(git -C "$narrowed_consumer" rev-parse origin/main)"
narrowed_tip="$(git -C "$narrowed_seed" rev-parse main)"
check "origin/main is present but STALE before the claim (precondition)" 0 \
  "$([ "$narrowed_pre" != "$narrowed_tip" ] && echo 0 || echo 1)"

narrowed_rc=0
narrowed_out="$("$script" add "$narrowed_consumer" "$tmp/wt-narrowed" "claim-narrowed" "session-narrowed" 2>&1)" || narrowed_rc=$?
check "narrowed refspec still claims successfully" 0 "$narrowed_rc" "$narrowed_out" "owner=session-narrowed"
# The whole point: three commits behind must be REPORTED, not swallowed by a tracking ref the fetch
# never updated. A silent pass here is the exact failure this function exists to remove.
check "narrowed refspec is measured against the tip actually FETCHED" 0 "$narrowed_rc" \
  "$narrowed_out" "WARNING base is 3 commit(s) behind"
narrowed_silent_rc=0
grep -qF -- "WARNING base is" <<<"$narrowed_out" || narrowed_silent_rc=1
check "narrowed refspec never reports a silent 'current' base" 0 "$narrowed_silent_rc"

# The arms below execute the two commands literally, so this pins that the script actually EMITS
# them — without it the execution arms would keep passing even if the hint reverted, and they would
# be proving git's behaviour rather than this script's advice. Both halves are asserted: the rebase
# target alone would leave the fetch, which is what makes FETCH_HEAD correct, unpinned.
check "the emitted hint names the fetch that makes FETCH_HEAD correct" 0 "$narrowed_rc" \
  "$narrowed_out" "fetch origin 'main' &&"
check "the emitted hint rebases onto FETCH_HEAD" 0 "$narrowed_rc" "$narrowed_out" "rebase FETCH_HEAD"

# A hint is only advice if it RUNS, so both forms are EXECUTED here rather than pattern-matched.
# This is the fixture where they differ: the claim's fetch does not update origin/main (the
# configured mapping does not cover it), so the tracking ref is frozen while the tree is 3 behind.
#
# NEGATIVE CONTROL, and it carries the whole argument: the OLD hint does not fail loudly here — it
# SUCCEEDS, says "up to date", and leaves the tree exactly as stale as the warning just reported.
# That is the silent false-current this function exists to remove, reappearing inside its remedy.
narrowed_old_hint_rc=0
git -C "$tmp/wt-narrowed" rebase 'origin/main' >/dev/null 2>&1 || narrowed_old_hint_rc=$?
check "the tracking-ref hint SUCCEEDS while changing nothing (negative control)" 0 "$narrowed_old_hint_rc"
narrowed_behind_after_old="$(git -C "$tmp/wt-narrowed" rev-list --count "HEAD..$narrowed_tip" 2>/dev/null)"
check "the tracking-ref hint leaves the tree just as stale" 3 "$narrowed_behind_after_old"

# The emitted hint, run exactly as written. It must close the gap the warning reported.
narrowed_new_hint_rc=0
{ git -C "$tmp/wt-narrowed" fetch origin main >/dev/null 2>&1 &&
  git -C "$tmp/wt-narrowed" rebase FETCH_HEAD >/dev/null 2>&1; } || narrowed_new_hint_rc=$?
check "the emitted hint RUNS under a narrowed refspec" 0 "$narrowed_new_hint_rc"
narrowed_behind_after_new="$(git -C "$tmp/wt-narrowed" rev-list --count "HEAD..$narrowed_tip" 2>/dev/null)"
check "the emitted hint actually closes the gap it reported" 0 "$narrowed_behind_after_new"

# Unresolvable remote: the comparison cannot be made, and the required outcome is an explicit UNKNOWN
# rather than silence — silence is indistinguishable from "base is current", the confusion this whole
# check exists to remove. Repointing origin at an absent bare repository is hermetic: ls-remote and
# fetch both fail locally, no network is touched. Claiming must still succeed (advisory, never fatal).
git -C "$consumer" remote set-url origin "$tmp/absent-origin.git"
unknown_rc=0
unknown_out="$("$script" add "$consumer" "$tmp/wt-unknown" "claim-unknown" "session-unknown" 2>&1)" || unknown_rc=$?
check "unavailable remote still claims successfully" 0 "$unknown_rc" \
  "$unknown_out" "owner=session-unknown"
check "unavailable remote writes the ownership marker" 0 \
  "$([ -e "$tmp/wt-unknown/.claude-worktree-owner" ] && echo 0 || echo 1)"
check "unavailable remote reports base freshness UNKNOWN" 0 "$unknown_rc" \
  "$unknown_out" "base freshness UNKNOWN"
git -C "$consumer" remote set-url origin "$origin_repo"

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
# Comment lines are stripped first. The function DOCUMENTS the numeric test verbatim ("would make
# `[ "$behind" -gt 0 ]` fail OPEN…"), so matching the raw text finds the prose two lines above the
# code and reports the order backwards — the same match-a-comment defect this arm exists to catch.
normalise_code="$(grep -vE '^[[:space:]]*#' <<<"$normalise_src")"
grep -qF -- '[!0-9]' <<<"$normalise_code" || normalise_rc=1
# Presence alone is not the property. Both tokens would still be found if a later edit moved the
# normalisation BELOW the numeric test, which reinstates the fail-open path this arm guards. So
# compare their positions: the normalisation must precede the comparison that depends on it.
# awk with `exit` (not `grep -n | head`) — the pipe would EPIPE the writer under pipefail, exactly
# the flake fixed in check() above. index() keeps both needles literal.
# The malformed case must take the UNKNOWN path, not fold to `behind=0`: normalising to 0 also
# stopped the fail-open, but rendered an unestablished comparison identically to a current base.
# So the anchor is the `[!0-9]` case itself, and the arm below additionally requires that the
# diagnostic — not a silent assignment — is what follows it.
norm_line="$(awk 'index($0,"[!0-9]"){print NR; exit}' <<<"$normalise_code")"
test_line="$(awk 'index($0,"\"$behind\" -gt 0"){print NR; exit}' <<<"$normalise_code")"
# ...and the malformed branch must EMIT the UNKNOWN notice rather than silently choosing a value.
# `if`, not `cmd && assign`: under `set -e` a non-final `&&` operand that fails makes the LIST's
# status non-zero, which is the fail-open/abort ambiguity this file keeps pinning elsewhere.
malformed_branch="$(awk -v n="$norm_line" \
  'NR>n && NR<=n+3 && index($0,"base_freshness_unknown")' <<<"$normalise_code")"
if [ -z "$malformed_branch" ]; then normalise_rc=1; fi
# And the retired normalisation must be gone, or both spellings could coexist with the silent one winning.
if grep -qF -- 'behind=0' <<<"$normalise_code"; then normalise_rc=1; fi
# Guard both operands before the numeric comparison: `[ "" -lt 3 ]` errors rather than returning
# false, and an unguarded `&&` chain would swallow that as "arm satisfied" — the same fail-open
# shape this test exists to pin.
case "$norm_line" in '' | *[!0-9]*) norm_line=0 ;; esac
case "$test_line" in '' | *[!0-9]*) test_line=0 ;; esac
[ "$norm_line" -gt 0 ] && [ "$test_line" -gt 0 ] && [ "$norm_line" -lt "$test_line" ] || normalise_rc=1
check "behind-count is normalised BEFORE the numeric test" 0 "$normalise_rc"

# ...and the same property BEHAVIOURALLY, which is what the arm above says it cannot be. It can:
# `git` is resolved from PATH, so a stub forwarding every other subcommand to the real binary and
# returning a non-integer on `rev-list --count` is the injectable seam the comment asked for. Worth
# both arms — the source-coupled one pins that the retired `behind=0` spelling is gone, this one
# pins the OUTPUT, so a reformat cannot break it and a matching comment cannot satisfy it.
stub_dir="$tmp/stub-bin"
mkdir -p "$stub_dir"
real_git="$(command -v git)"
cat >"$stub_dir/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "rev-list" ]; then
    for inner in "\$@"; do
      [ "\$inner" = "--count" ] && { printf 'fatal: not a valid object name\n'; exit 0; }
    done
  fi
done
exec "$real_git" "\$@"
STUB
chmod +x "$stub_dir/git"
malformed_consumer="$tmp/malformed-consumer"
git clone -q "$origin_repo" "$malformed_consumer"
malformed_rc=0
malformed_out="$(PATH="$stub_dir:$PATH" "$script" add \
  "$malformed_consumer" "$tmp/wt-malformed" "claim-malformed" "session-malformed" 2>&1)" || malformed_rc=$?
check "a malformed behind-count still claims successfully (advisory, not fatal)" 0 "$malformed_rc" \
  "$malformed_out" "owner=session-malformed"
check "a malformed behind-count reports UNKNOWN rather than a silent 'current'" 0 "$malformed_rc" \
  "$malformed_out" "base freshness UNKNOWN"
# The NEGATIVE half. It must not emit a behind-count WARNING at all: the count is unusable, so the
# only honest outputs are the UNKNOWN notice (asserted above) and silence about a distance. Matched on
# the `WARNING base is` PREFIX, not on `WARNING base is 0 commit(s)` -- the retired `behind=0` folding
# never printed that string either (0 is not > 0, so it warned about nothing), which made the old
# assertion unfireable. The prefix form does fire, on a garbage count rendered into the message.
malformed_quiet_rc=0
grep -qF -- "WARNING base is" <<<"$malformed_out" && malformed_quiet_rc=1
check "a malformed behind-count never renders a distance" 0 "$malformed_quiet_rc"

# A FAILED rev-list must report UNKNOWN, not fold into behind=0 — otherwise an unavailable comparison
# renders identically to a current base, the exact silence this whole check removes.
#
# ⚠️ SOURCE-COUPLED for the same reason as the arm above: `warn_if_base_is_stale` runs immediately
# after a successful `git worktree add`, so a failing `rev-list` in that window cannot be provoked
# hermetically. Asserted on structure — the assignment is guarded by `if !`, and the guard body calls
# base_freshness_unknown — with comments stripped so prose cannot satisfy it. Replace with a
# behavioural arm if the count ever moves behind an injectable seam.
revfail_rc=0
revlist_line="$(awk 'index($0,"rev-list --count"){print NR; exit}' <<<"$normalise_code")"
case "$revlist_line" in '' | *[!0-9]*) revlist_line=0 ;; esac
[ "$revlist_line" -gt 0 ] &&
  grep -qF -- 'if ! behind="$(git -C "$wt" rev-list --count' <<<"$normalise_code" || revfail_rc=1
# The guard body must actually emit the notice, not merely return. Captured output + an emptiness
# test, NOT `awk | grep -q`: `grep -q` exits at the first match, the awk writer can then die of
# EPIPE, and under `pipefail` the pipeline reports failure for a needle it actually found — the
# size-dependent flake `check()` documents at lines 26-28. Same shape as lines 394-396.
revfail_branch="$(awk -v n="$revlist_line" \
  'NR>n && NR<=n+2 && index($0,"base_freshness_unknown")' <<<"$normalise_code")"
if [ -z "$revfail_branch" ]; then revfail_rc=1; fi
check "a FAILED rev-list reports UNKNOWN rather than behind=0" 0 "$revfail_rc"

# A remote that never answers must not hold the claim open. `ext::` runs an arbitrary command as the
# transport, so this hangs git deterministically with no network and no unreachable-address guesswork.
# The bound is asserted by WALL CLOCK: a run that merely "succeeds" would also succeed if the timer
# never fired and git sat there for the full sleep, so elapsed time is the only thing that separates
# a working bound from an absent one.
#
# `protocol.ext.allow` is REQUIRED and is not decoration: it defaults to `never`, so without it git
# rejects the transport in 0s with "transport 'ext' not allowed" and the fixture exercises the
# fast-FAILURE path instead of the hang. That version of this test passed with the bound removed —
# it was vacuous, and only the ablation exposed it.
hang_consumer="$tmp/hang-consumer"
git clone -q "$origin_repo" "$hang_consumer"
git -C "$hang_consumer" remote set-url origin "ext::sleep 60"
git -C "$hang_consumer" config protocol.ext.allow always
hang_start="$(date +%s)"
hang_rc=0
hang_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=3 "$script" add \
  "$hang_consumer" "$tmp/wt-hang" "claim-hang" "session-hang" 2>&1)" || hang_rc=$?
hang_elapsed=$(($(date +%s) - hang_start))
check "an unresponsive remote still claims successfully (advisory, not fatal)" 0 "$hang_rc" \
  "$hang_out" "owner=session-hang"
# Two calls are bounded, so allow both plus slack -- but far below the 60s the transport would take.
hang_bounded_rc=0
[ "$hang_elapsed" -lt 30 ] || hang_bounded_rc=1
check "an unresponsive remote is abandoned at the bound, not waited out" 0 "$hang_bounded_rc"
hang_unknown_rc=0
grep -qF -- "base freshness UNKNOWN" <<<"$hang_out" || hang_unknown_rc=1
check "an unresponsive remote reports UNKNOWN rather than silence" 0 "$hang_unknown_rc"

# shquote must survive a TERMINAL NEWLINE. `$(…)` strips trailing newlines, so the previous
# command-substitution form emitted a rebase hint naming a DIFFERENT path than the one it operated
# on — and that hint is written to be pasted and run.
# The SHIPPED function is extracted and evaluated, not reimplemented here: a local copy would only
# prove that the copy works, which is the vacuous shape this file guards against elsewhere.
shquote_rc=0
shquote_fn="$(sed -n '/^shquote()/,/^}/p' "$script")"
# `printf %s` then measure: capturing with $() here would strip the very newline under test.
shquote_len="$(bash -c 'eval "$1"; out="$(shquote "$2"; printf X)"; out=${out%X}; printf %s "${#out}"' \
  _ "$shquote_fn" $'wt\n')"
# "'" + w + t + newline + "'" = 5 characters. A stripped newline yields 4.
[ "$shquote_len" = "5" ] || shquote_rc=1
check "shipped shquote preserves a terminal newline" 0 "$shquote_rc"
# Source-coupled arm: the shipped shquote must not use command substitution at all, which is the
# only way the strip can reappear.
shquote_src="$(sed -n '/^shquote()/,/^}/p' "$script" | grep -vE '^[[:space:]]*#')"
shquote_impl_rc=0
if grep -qF -- '$(' <<<"$shquote_src"; then shquote_impl_rc=1; fi
check "shquote uses no command substitution (cannot strip a trailing newline)" 0 "$shquote_impl_rc"
# The POSITIVE half, and it is not decoration: both arms above would still pass if the newline fix
# had broken quote escaping outright, since neither input contains a quote. Escaping IS the job this
# helper exists to do, so it needs an arm of its own — compared byte-exactly against the expected
# `'it'\''s'`, because a length check cannot tell a correct escape from a differently-wrong one.
shquote_esc_rc=0
bash -c 'eval "$1"; shquote "$2" >"$3"' _ "$shquote_fn" "it's" "$tmp/shq.esc"
printf "%s" "'it'\\''s'" >"$tmp/shq.esc.expected"
cmp -s "$tmp/shq.esc" "$tmp/shq.esc.expected" || shquote_esc_rc=1
check "shquote still escapes an embedded single quote" 0 "$shquote_esc_rc"

# `add` must CLAIM before it runs the advisory freshness check. That check makes up to two bounded
# remote calls, so running it first leaves the new tree unclaimed for both timeouts — long enough for
# a concurrent run to take the marker, which would leave this invocation exiting 3 on a worktree and
# branch it just created. Asserted on OUTPUT ORDER against the unresponsive-remote fixture, which is
# the case where the window is widest: the acquire line must precede the freshness NOTE.
#
# The transport is a script under this run's own `mktemp -d`, NOT a bare `sleep`: the orphan check
# below greps the process table, and a bare `sleep 97` matches a leftover from any earlier run of
# this suite — which made the assertion fail on a tree that was actually correct. The temp path is
# unique per run, so the grep can only ever match this run's descendants.
#
# NO `exec`, for the same reason spelled out for `ignore_transport` below — but the failure it
# prevents here is narrower than "the arm never fires", and the difference was measured rather than
# assumed. `exec sleep 97` replaces the process image, so the transport's own argv becomes "sleep 97"
# and this run's unique path is gone from it. The arm still went red, because `git remote-ext origin
# <path>` carries the path as an ARGUMENT and is itself orphaned by the same regression — so what the
# assertion actually observed was the git helper, a PROXY, never the transport the comment names.
# Ablating group signalling to pid-only signalling made that concrete: with `exec` a bare `sleep 97`
# was left running and `pgrep -f "$slow_transport"` could not see it (1 leaked, 0 of them matched);
# without `exec` the transport is matched directly (2 matches, 0 leaked). A regression that reaped
# the helper but not the transport — exactly the TERM-ignoring case the next arm covers — would
# therefore have read clean here. Looping over short sleeps keeps the script itself resident, so the
# arm observes the process it claims to.
slow_transport="$tmp/slow-transport"
printf '#!/usr/bin/env bash\nfor _ in $(seq 97); do sleep 1; done\n' >"$slow_transport"
chmod +x "$slow_transport"
order_consumer="$tmp/order-consumer"
git clone -q "$origin_repo" "$order_consumer"
git -C "$order_consumer" remote set-url origin "ext::$slow_transport"
git -C "$order_consumer" config protocol.ext.allow always
order_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=2 "$script" add \
  "$order_consumer" "$tmp/wt-order" "claim-order" "session-order" 2>&1)" || true
acquire_at="$(awk '/owner=session-order/{print NR; exit}' <<<"$order_out")"
note_at="$(awk '/base freshness UNKNOWN/{print NR; exit}' <<<"$order_out")"
case "$acquire_at" in '' | *[!0-9]*) acquire_at=0 ;; esac
case "$note_at" in '' | *[!0-9]*) note_at=0 ;; esac
order_rc=0
[ "$acquire_at" -gt 0 ] && [ "$note_at" -gt 0 ] && [ "$acquire_at" -lt "$note_at" ] || order_rc=1
check "add claims the worktree BEFORE the advisory remote check" 0 "$order_rc"

# A timed-out git must not leave its TRANSPORT child running. git delegates to a helper process, and
# killing only the git pid leaves that helper reparented, running to its own native timeout — twice
# per `add`, so an unresponsive remote accumulates them. Matched on this run's unique transport path.
sleep 1
orphan_rc=0
if pgrep -f "$slow_transport" >/dev/null 2>&1; then orphan_rc=1; fi
check "a timed-out remote leaves no orphaned transport process" 0 "$orphan_rc"
# Mirror the `ignore_transport` cleanup below: if the arm above just FAILED there is a live process
# holding this run's temp dir, and the EXIT trap's `rm -rf` would otherwise race it.
pkill -KILL -f "$slow_transport" >/dev/null 2>&1 || true

# SIGTERM is a REQUEST -- catchable and ignorable -- so the timer's TERM does not stop a transport
# that ignores it. The WAITED-ON process is `git`, which honours TERM and dies, so `add` still
# returns at the bound; what survives is the transport helper, reparented and running to its own
# native timeout. `add` reports success while leaving a process behind, twice per call. SIGKILL
# cannot be trapped, so escalating to it after a grace period is what actually reaps the tree.
#
# Fixture shape is load-bearing in two ways, both learned by ablation:
#   * NO `exec`. `exec sleep 97` replaces the process image, so its argv becomes "sleep 97" and
#     `pgrep -f "$ignore_transport"` can never match -- the assertion would pass on a broken tree.
#     Looping over short sleeps keeps the script itself resident, so its path stays greppable.
#   * The loop is what makes ignoring TERM observable: the group TERM kills the current `sleep 1`
#     child, but the script traps nothing and continues, which is exactly the surviving helper.
# Elapsed time is deliberately NOT asserted here: `git` dies on TERM either way, so a wall-clock
# assertion passes in both arms and would only look like proof.
ignore_transport="$tmp/ignore-term-transport"
printf '#!/usr/bin/env bash\ntrap "" TERM\nfor _ in $(seq 97); do sleep 1; done\n' >"$ignore_transport"
chmod +x "$ignore_transport"
ignore_consumer="$tmp/ignore-consumer"
git clone -q "$origin_repo" "$ignore_consumer"
git -C "$ignore_consumer" remote set-url origin "ext::$ignore_transport"
git -C "$ignore_consumer" config protocol.ext.allow always
ignore_rc=0
ignore_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=2 "$script" add \
  "$ignore_consumer" "$tmp/wt-ignore" "claim-ignore" "session-ignore" 2>&1)" || ignore_rc=$?
sleep 2
# An absence assertion alone is vacuous: if a regression made `add` fail BEFORE bounded_remote ever
# ran, no transport would be spawned and the arm below would report success on a broken tree. So
# establish first that the bounded call actually happened — this transport swallows TERM, so the
# remote is abandoned and the freshness verdict degrades to UNKNOWN, which is the observable proof
# that the timeout path executed rather than being skipped.
check "the SIGTERM-ignoring transport was actually reached (guards the arm below)" 0 "$ignore_rc" \
  "$ignore_out" "base freshness UNKNOWN"
ignore_orphan_rc=0
if pgrep -f "$ignore_transport" >/dev/null 2>&1; then ignore_orphan_rc=1; fi
check "a SIGTERM-IGNORING transport is SIGKILLed, not left orphaned" 0 "$ignore_orphan_rc"
pkill -KILL -f "$ignore_transport" >/dev/null 2>&1 || true

# The TIMER must not outlive the call it bounds. The killer subshell sleeps in a separate child
# process, so signalling the subshell's pid alone leaves that `sleep` running to its full duration --
# on the FAST path, where the remote answers immediately, every `add` leaked one or two of them.
# Bounding both is the same tree-kill problem as the transport, one level up.
#
# The timeout value is deliberately absurd and unique: a real leak is then unmistakable in the
# process table, and the assertion cannot collide with an unrelated `sleep` from this suite, another
# suite, or a developer's shell. A round number like 60 would match half the machine.
timer_consumer="$tmp/timer-consumer"
git clone -q "$origin_repo" "$timer_consumer"
timer_rc=0
timer_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=9871 "$script" add \
  "$timer_consumer" "$tmp/wt-timer" "claim-timer" "session-timer" 2>&1)" || timer_rc=$?
sleep 1
# Same vacuity guard as the transport arm above: an `add` that failed before arming the timer would
# leave no `sleep 9871` and the leak assertion would pass for the wrong reason. A successful claim is
# the marker that the fast path — the one that used to leak a timer per call — actually ran.
check "the fast path was actually reached (guards the arm below)" 0 "$timer_rc" \
  "$timer_out" "owner=session-timer"
timer_leak_rc=0
if pgrep -f 'sleep 9871' >/dev/null 2>&1; then timer_leak_rc=1; fi
check "a fast remote leaves no timer process behind" 0 "$timer_leak_rc"
pkill -KILL -f 'sleep 9871' >/dev/null 2>&1 || true

# The bound is read from the environment and handed straight to `sleep`, so a malformed value makes
# that `sleep` fail instantly and collapses the bound to roughly zero: the remote is abandoned before
# it can answer, and a REACHABLE remote is then reported UNKNOWN for a reason nothing states. The
# guard rejects the value, says so, and falls back to the default.
#
# Asserted on the NOTICE rather than on elapsed time, deliberately. Both the guarded and unguarded
# arms finish quickly here -- the unguarded one because the bound collapsed, the guarded one because
# the fixture answers immediately -- so a wall-clock assertion would pass either way and prove
# nothing. The distinguishing observable is that the rejection is reported.
badtimeout_consumer="$tmp/badtimeout-consumer"
git clone -q "$origin_repo" "$badtimeout_consumer"
badtimeout_rc=0
badtimeout_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=invalid "$script" add \
  "$badtimeout_consumer" "$tmp/wt-badtimeout" "claim-badtimeout" "session-badtimeout" 2>&1)" || badtimeout_rc=$?
check "a non-integer timeout is rejected and reported" 0 "$badtimeout_rc" \
  "$badtimeout_out" "ignoring unusable WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="
check "a rejected timeout still claims the worktree" 0 "$badtimeout_rc" \
  "$badtimeout_out" "owner=session-badtimeout"

# `0` parses as an integer but is not a bound -- it abandons every remote call immediately, which is
# the same invisible-UNKNOWN failure wearing a well-formed value.
zerotimeout_consumer="$tmp/zerotimeout-consumer"
git clone -q "$origin_repo" "$zerotimeout_consumer"
zerotimeout_rc=0
zerotimeout_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=0 "$script" add \
  "$zerotimeout_consumer" "$tmp/wt-zerotimeout" "claim-zerotimeout" "session-zerotimeout" 2>&1)" || zerotimeout_rc=$?
check "a zero timeout is rejected as not-a-bound" 0 "$zerotimeout_rc" \
  "$zerotimeout_out" "ignoring unusable WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="

# Zero has more than one spelling. `00` and `000` are digit-only and are not the literal `0`, and
# `sleep` returns from each immediately -- so a guard written against the SPELLING `0` leaves exactly
# the same collapsed bound reachable. An earlier round of this PR did precisely that.
for zero_spelling in 00 000; do
  zs_consumer="$tmp/zs-$zero_spelling-consumer"
  git clone -q "$origin_repo" "$zs_consumer"
  zs_rc=0
  zs_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="$zero_spelling" "$script" add \
    "$zs_consumer" "$tmp/wt-zs-$zero_spelling" "claim-zs-$zero_spelling" "session-zs" 2>&1)" || zs_rc=$?
  check "an all-zero timeout spelling '$zero_spelling' is rejected" 0 "$zs_rc" \
    "$zs_out" "ignoring unusable WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="
done

# POSITIVE CONTROL: `0001` has leading zeros but is a genuine 1-second bound and must NOT be
# rejected. Without this, a guard that simply refused any value containing a zero would satisfy every
# assertion above while quietly refusing legitimate configuration -- strict-looking and wrong.
leadzero_consumer="$tmp/leadzero-consumer"
git clone -q "$origin_repo" "$leadzero_consumer"
leadzero_add_rc=0
leadzero_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=0001 "$script" add \
  "$leadzero_consumer" "$tmp/wt-leadzero" "claim-leadzero" "session-leadzero" 2>&1)" || leadzero_add_rc=$?
check "a leading-zero timeout still claims successfully" 0 "$leadzero_add_rc" \
  "$leadzero_out" "owner=session-leadzero"
leadzero_rc=0
grep -qF "ignoring unusable" <<<"$leadzero_out" && leadzero_rc=1
check "a leading-zero but NON-zero timeout is accepted" 0 "$leadzero_rc"

# RANGE, not just spelling. `sleep` enforces the bound, and both ends defeat it: BSD sleep (the
# primary host) rejects a value at/above ~2^31 with a usage error and returns INSTANTLY, so the killer
# fires at once and TERMs a reachable remote -- the bound collapses to ~0 and every claim reports
# UNKNOWN; GNU sleep accepts the same value and waits ~317 years, i.e. no bound at all. `600000` is
# unbounded on both and is the plausible "someone meant milliseconds" value. Measured on this PR's own
# previous head: both were ACCEPTED.
for bad_range in 600000 10000000000; do
  br_consumer="$tmp/br-$bad_range-consumer"
  git clone -q "$origin_repo" "$br_consumer"
  br_rc=0
  br_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="$bad_range" "$script" add \
    "$br_consumer" "$tmp/wt-br-$bad_range" "claim-br-$bad_range" "session-br" 2>&1)" || br_rc=$?
  check "an out-of-range timeout '$bad_range' is rejected" 0 "$br_rc" \
    "$br_out" "ignoring unusable WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="
done

# POSITIVE CONTROL for the range guard: the maximum must still be ACCEPTED, or a guard that simply
# refused anything long would satisfy both arms above while rejecting legitimate configuration.
maxtimeout_consumer="$tmp/maxtimeout-consumer"
git clone -q "$origin_repo" "$maxtimeout_consumer"
maxtimeout_rc=0
maxtimeout_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=3600 "$script" add \
  "$maxtimeout_consumer" "$tmp/wt-maxtimeout" "claim-maxtimeout" "session-maxtimeout" 2>&1)" || maxtimeout_rc=$?
maxtimeout_rejected=0
grep -qF "ignoring unusable" <<<"$maxtimeout_out" && maxtimeout_rejected=1
check "the maximum in-range timeout is accepted (control)" 0 "$maxtimeout_rejected"
check "the maximum in-range timeout still claims" 0 "$maxtimeout_rc" \
  "$maxtimeout_out" "owner=session-maxtimeout"

# ── a hostile remote default-branch name must never reach git as an OPTION ──────
# The name is REMOTE-supplied and fed to `git fetch`. Passed positionally, a name beginning with `-`
# is parsed as an option: a remote whose HEAD symrefs to refs/heads/--upload-pack=<cmd> made git RUN
# <cmd>. Reproduced against this PR's own previous head -- the sentinel file was created -- so this is
# a demonstrated arbitrary-command primitive on the creation path of every worktree, not a theory.
# Note the ref really does live under refs/heads/, so requiring that prefix does NOT close it; the
# name itself has to be rejected.
inj_origin="$tmp/inj-origin.git"
git init -q --bare -b main "$inj_origin"
git -C "$seed" push -q "$inj_origin" main
inj_pwn="$tmp/inj-pwn"
inj_sentinel="$tmp/inj-executed"
printf '#!/usr/bin/env bash\n: >"%s"\nexit 1\n' "$inj_sentinel" >"$inj_pwn"
chmod +x "$inj_pwn"
git -C "$inj_origin" update-ref "refs/heads/--upload-pack=$inj_pwn" refs/heads/main
git -C "$inj_origin" symbolic-ref HEAD "refs/heads/--upload-pack=$inj_pwn"
inj_consumer="$tmp/inj-consumer"
git clone -q "$origin_repo" "$inj_consumer"
git -C "$inj_consumer" remote set-url origin "$inj_origin"
inj_rc=0
inj_out="$("$script" add "$inj_consumer" "$tmp/wt-inj" "claim-inj" "session-inj" 2>&1)" || inj_rc=$?
check "a hostile default-branch name still claims (advisory, not fatal)" 0 "$inj_rc" \
  "$inj_out" "owner=session-inj"
check "a hostile default-branch name reports UNKNOWN" 0 "$inj_rc" \
  "$inj_out" "base freshness UNKNOWN"
# The arm that matters: the attacker-chosen command must not have run.
inj_exec_rc=0
[ -e "$inj_sentinel" ] && inj_exec_rc=1
check "a hostile default-branch name is NEVER executed" 0 "$inj_exec_rc"

# Remote-default DISCOVERY failure must report UNKNOWN, not fall back to the clone-time pointer.
# The fallback trusted `refs/remotes/origin/HEAD` — written once at clone time and never refreshed —
# which is the stale source this whole check exists to stop trusting: if the default moved, the old
# branch usually still fetches, so the comparison yields behind=0 and reports a CURRENT base for an
# arbitrarily stale tree. The git stub makes only the symref discovery fail, so the branch fetch
# still succeeds and the old fallback path would have been taken.
symref_stub="$tmp/symref-stub"
mkdir -p "$symref_stub"
cat >"$symref_stub/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = "--symref" ] && exit 0
done
exec "$real_git" "\$@"
STUB
chmod +x "$symref_stub/git"
symref_consumer="$tmp/symref-consumer"
git clone -q "$origin_repo" "$symref_consumer"
symref_rc=0
symref_out="$(PATH="$symref_stub:$PATH" "$script" add \
  "$symref_consumer" "$tmp/wt-symref" "claim-symref" "session-symref" 2>&1)" || symref_rc=$?
check "failed default discovery still claims successfully" 0 "$symref_rc" \
  "$symref_out" "owner=session-symref"
check "failed default discovery reports UNKNOWN, not a stale-pointer comparison" 0 "$symref_rc" \
  "$symref_out" "base freshness UNKNOWN"

# ── add attaches to a branch that already exists (monorepo#2776) ───────────────────
# Rung 1 of the work-selection ladder is "finish an open PR", and that branch exists before the
# worktree does. `add` hardcoded `-b`, so the mandated helper could only ever create a NEW branch:
# resuming an open PR fell out of the claim protocol entirely, because the one command that writes
# the ownership marker refused to run.
existing_repo="$tmp/existing-repo"
mkdir -p "$existing_repo"
git -C "$existing_repo" init -q -b main
git -C "$existing_repo" config user.name "worktree-claim-test"
git -C "$existing_repo" config user.email "worktree-claim-test@example.com"
git -C "$existing_repo" commit --allow-empty -qm "init"
git -C "$existing_repo" branch "claim-existing-local"
git -C "$existing_repo" commit --allow-empty -qm "main moves on"
existing_tip="$(git -C "$existing_repo" rev-parse "claim-existing-local")"

local_rc=0
local_out="$("$script" add \
  "$existing_repo" "$tmp/wt-existing-local" "claim-existing-local" "session-existing" 2>&1)" || local_rc=$?
check "add attaches to an existing local branch" 0 "$local_rc" "$local_out" "owner=session-existing"
check "existing-branch add writes the marker" 0 \
  "$([ -f "$tmp/wt-existing-local/.claude-worktree-owner" ] && echo 0 || echo 1)"
# The point of attaching is landing on THAT branch's commit. Creating a fresh branch from HEAD would
# also exit 0 and also write a marker, so the exit code alone cannot tell the two apart — assert the
# checked-out commit, which is the only thing that distinguishes a resumed PR from a silent fork.
check "existing-branch add lands on that branch's tip, not the repo HEAD" 0 0 \
  "$(git -C "$tmp/wt-existing-local" rev-parse HEAD)" "$existing_tip"
check "existing-branch add checks out the branch itself" 0 0 \
  "$(git -C "$tmp/wt-existing-local" rev-parse --abbrev-ref HEAD)" "claim-existing-local"

# A branch that exists only on the REMOTE is the actual open-PR case: a fresh checkout has no local
# ref for it. Creating it from the consumer's HEAD would silently fork the PR — the worktree would
# look plausible and carry none of the PR's commits.
remote_seed="$tmp/remote-seed"
mkdir -p "$remote_seed"
git -C "$remote_seed" init -q -b main
git -C "$remote_seed" config user.name "worktree-claim-test"
git -C "$remote_seed" config user.email "worktree-claim-test@example.com"
git -C "$remote_seed" commit --allow-empty -qm "init"
git -C "$remote_seed" checkout -q -b "claim-existing-remote"
git -C "$remote_seed" commit --allow-empty -qm "work that only exists on the PR branch"
remote_tip="$(git -C "$remote_seed" rev-parse "claim-existing-remote")"
git -C "$remote_seed" checkout -q main
remote_origin="$tmp/remote-origin.git"
git clone -q --bare "$remote_seed" "$remote_origin"
remote_consumer="$tmp/remote-consumer"
git clone -q "$remote_origin" "$remote_consumer"
git -C "$remote_consumer" branch -D "claim-existing-remote" >/dev/null 2>&1 || true
# Drop the tracking ref too. `git clone` creates one for every remote branch, so leaving it would let
# this case pass without the fetch ever running — the assertion would hold while the code path it is
# meant to cover was dead. Clearing it is what makes the fetch load-bearing: ablate the fetch and this
# block goes RED.
git -C "$remote_consumer" update-ref -d "refs/remotes/origin/claim-existing-remote"
check "remote-branch fixture starts with no local and no tracking ref" 0 0 \
  "$(git -C "$remote_consumer" for-each-ref --format='%(refname)' \
      'refs/heads/claim-existing-remote' 'refs/remotes/origin/claim-existing-remote' | wc -l | tr -d ' ')" "0"

remote_rc=0
remote_out="$("$script" add \
  "$remote_consumer" "$tmp/wt-existing-remote" "claim-existing-remote" "session-remote-existing" 2>&1)" || remote_rc=$?
check "add attaches to a branch that exists only on the remote" 0 "$remote_rc" \
  "$remote_out" "owner=session-remote-existing"
check "remote-branch add lands on the remote tip, not the consumer HEAD" 0 0 \
  "$(git -C "$tmp/wt-existing-remote" rev-parse HEAD)" "$remote_tip"

# Fail-closed regression: attaching must not defeat git's own single-checkout rule. A branch already
# checked out elsewhere stays refused, so two worktrees can never share one branch.
dup_rc=0
dup_out="$("$script" add \
  "$existing_repo" "$tmp/wt-existing-dup" "claim-existing-local" "session-dup" 2>&1)" || dup_rc=$?
check "a branch already checked out elsewhere is still refused" 2 "$dup_rc" \
  "$dup_out" "git worktree add failed"

# ── an unresolvable remote must not become a silent fork (CodeRabbit, #2810) ────────
# A fetch failure leaves refs/remotes/origin/<branch> untouched, so "no tracking ref" cannot be read
# as "the branch does not exist on origin" — it also means "we could not ask". Creating the branch
# from HEAD there reintroduces exactly the silent fork the remote arm exists to prevent, and the
# bounded remote call makes it reachable on a mere TIMEOUT, where the network is fine seconds later
# and the run does go on to push.
unreach_seed="$tmp/unreach-repo"
mkdir -p "$unreach_seed"
git -C "$unreach_seed" init -q -b main
git -C "$unreach_seed" config user.name "worktree-claim-test"
git -C "$unreach_seed" config user.email "worktree-claim-test@example.com"
git -C "$unreach_seed" commit --allow-empty -qm "init"
git -C "$unreach_seed" remote add origin "$tmp/definitely-not-a-repo.git"
# Remote state must never decide whether `add` succeeds — a pinned property of this helper, with
# four "advisory, not fatal" assertions behind it — so this still claims. What it must NOT do is stay
# silent: the ambiguity is announced, and the claim protocol's own remote-tip SHA comparison before
# pushing is what actually catches a fork.
unreach_rc=0
unreach_out="$(WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=5 "$script" add \
  "$unreach_seed" "$tmp/wt-unreach" "claim-unreachable" "session-unreach" 2>&1)" || unreach_rc=$?
check "an unresolvable remote still claims (advisory, not fatal)" 0 "$unreach_rc" \
  "$unreach_out" "owner=session-unreach"
check "an unresolvable remote ANNOUNCES that it could not check for an existing branch" 0 \
  "$unreach_rc" "$unreach_out" "could not reach origin to check whether"
check "the announcement names the verification the caller must do" 0 \
  "$unreach_rc" "$unreach_out" "VERIFY the remote tip before pushing"

# The reachable-remote counterpart MUST still create: `ls-remote --exit-code` answers 2 for "branch
# absent" and 128 for "could not ask", and only the first is proof the branch is new. Without this
# the fix above would block every genuinely-new branch.
absent_seed="$tmp/absent-repo"
mkdir -p "$absent_seed"
git -C "$absent_seed" init -q -b main
git -C "$absent_seed" config user.name "worktree-claim-test"
git -C "$absent_seed" config user.email "worktree-claim-test@example.com"
git -C "$absent_seed" commit --allow-empty -qm "init"
git init -q --bare "$tmp/absent-origin.git"
git -C "$absent_seed" remote add origin "$tmp/absent-origin.git"
absent_rc=0
absent_out="$("$script" add \
  "$absent_seed" "$tmp/wt-absent" "claim-genuinely-new" "session-absent" 2>&1)" || absent_rc=$?
check "a branch absent from a REACHABLE remote is still created" 0 "$absent_rc" \
  "$absent_out" "owner=session-absent"

# A repo with no origin at all is not an unreachable remote — nothing can host the branch, so
# creating it is correct. `ls-remote` cannot tell these apart (both exit 128), which is why origin's
# presence is checked separately rather than inferred from the exit code.
noremote_rc=0
noremote_out="$("$script" add \
  "$repo" "$tmp/wt-noremote" "claim-no-remote" "session-noremote" 2>&1)" || noremote_rc=$?
check "a repo with no origin still creates the branch" 0 "$noremote_rc" \
  "$noremote_out" "owner=session-noremote"

# ── a STALE local branch must not attach silently (Codex P2, #2810) ────────────────
# The local arm returned before any remote check, so a local ref left behind by an earlier run
# attached at its old SHA while origin had moved on. Work then targets an obsolete head and only the
# eventual push reveals it — the same shape that once produced a worktree 56 commits behind its PR,
# where a plausible-looking diff would have reverted the PR's own commits.
stale_seed="$tmp/stale-seed"
mkdir -p "$stale_seed"
git -C "$stale_seed" init -q -b main
git -C "$stale_seed" config user.name "worktree-claim-test"
git -C "$stale_seed" config user.email "worktree-claim-test@example.com"
git -C "$stale_seed" commit --allow-empty -qm "init"
git -C "$stale_seed" checkout -q -b "claim-stale-local"
git -C "$stale_seed" commit --allow-empty -qm "the commit the local ref will sit at"
stale_old="$(git -C "$stale_seed" rev-parse HEAD)"
git -C "$stale_seed" checkout -q main
stale_origin="$tmp/stale-origin.git"
git clone -q --bare "$stale_seed" "$stale_origin"
stale_consumer="$tmp/stale-consumer"
git clone -q "$stale_origin" "$stale_consumer"
git -C "$stale_consumer" branch -f "claim-stale-local" "$stale_old"
# origin advances past the local ref, exactly as a sibling push or review follow-up would.
git -C "$stale_seed" checkout -q "claim-stale-local"
git -C "$stale_seed" commit --allow-empty -qm "origin moves ahead"
git -C "$stale_seed" push -q "$stale_origin" "claim-stale-local"
git -C "$stale_seed" checkout -q main

stalelocal_rc=0
stalelocal_out="$("$script" add \
  "$stale_consumer" "$tmp/wt-stale-local" "claim-stale-local" "session-stalelocal" 2>&1)" || stalelocal_rc=$?
check "a stale local branch still claims (advisory, not fatal)" 0 "$stalelocal_rc" \
  "$stalelocal_out" "owner=session-stalelocal"
check "a stale local branch is ANNOUNCED rather than attached silently" 0 "$stalelocal_rc" \
  "$stalelocal_out" "behind origin"
check "the staleness announcement names the branch" 0 "$stalelocal_rc" \
  "$stalelocal_out" "claim-stale-local"

# A local branch that is already current must stay quiet — otherwise the warning fires on every
# ordinary attach and is trained away as noise.
current_consumer="$tmp/current-consumer"
git clone -q "$stale_origin" "$current_consumer"
git -C "$current_consumer" branch -f "claim-current-local" "$(git -C "$current_consumer" rev-parse origin/main)"
currentlocal_rc=0
currentlocal_out="$("$script" add \
  "$current_consumer" "$tmp/wt-current-local" "claim-current-local" "session-currentlocal" 2>&1)" || currentlocal_rc=$?
check "a current local branch claims without a staleness warning" 0 "$currentlocal_rc" \
  "$currentlocal_out" "owner=session-currentlocal"
check "no false staleness warning on a branch origin does not have" 0 \
  "$(grep -qF 'behind origin' <<<"$currentlocal_out" && echo 1 || echo 0)"

# ── ls-remote SUCCEEDS but the fetch fails, with no cached tracking ref ────────────────────────
# The remote arm attaches with `--track … origin/$branch`. That ref only exists if the fetch landed,
# so when `ls-remote` says the branch exists and the fetch then fails on a checkout that has never
# fetched it, `worktree add` dies on `invalid reference` and `add` FAILS — remote state deciding
# whether `add` succeeds, which every "advisory, not fatal" assertion above exists to prevent. The
# combination is not exotic: `bounded_remote` gives the fetch a short timeout, so a merely SLOW
# remote trips it while `ls-remote` already succeeded, and resuming an open PR is exactly the case
# with no cached ref. The stub fails ONLY `fetch`, so `ls-remote` still answers 0 — without that
# asymmetry the run would take the `*)` arm and this case would never be exercised.
fetchfail_origin="$tmp/fetchfail-origin.git"
git init -q --bare "$fetchfail_origin"
fetchfail_seed="$tmp/fetchfail-seed"
git clone -q "$fetchfail_origin" "$fetchfail_seed" 2>/dev/null || git init -q "$fetchfail_seed"
git -C "$fetchfail_seed" config user.name "worktree-claim-test"
git -C "$fetchfail_seed" config user.email "worktree-claim-test@example.com"
git -C "$fetchfail_seed" commit --allow-empty -qm "init"
git -C "$fetchfail_seed" branch -M main
git -C "$fetchfail_seed" checkout -qb "claim-fetchfail"
git -C "$fetchfail_seed" commit --allow-empty -qm "work that only exists on origin"
git -C "$fetchfail_seed" remote add origin "$fetchfail_origin" 2>/dev/null || true
git -C "$fetchfail_seed" push -q origin main claim-fetchfail

# Clone WITHOUT the branch's tracking ref, but keep the normal wildcard refspec — a narrowed
# refspec would fail `--track` for an unrelated reason and mask what this fixture measures.
fetchfail_consumer="$tmp/fetchfail-consumer"
git clone -q --single-branch --branch main "$fetchfail_origin" "$fetchfail_consumer"
git -C "$fetchfail_consumer" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
check "precondition: the branch has NO cached tracking ref" 0 \
  "$(git -C "$fetchfail_consumer" show-ref --verify --quiet refs/remotes/origin/claim-fetchfail && echo 1 || echo 0)"

fetchfail_stub="$tmp/fetchfail-stub"
mkdir -p "$fetchfail_stub"
cat >"$fetchfail_stub/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = "fetch" ] && exit 1
done
exec "$real_git" "\$@"
STUB
chmod +x "$fetchfail_stub/git"

fetchfail_rc=0
fetchfail_out="$(PATH="$fetchfail_stub:$PATH" "$script" add \
  "$fetchfail_consumer" "$tmp/wt-fetchfail" "claim-fetchfail" "session-fetchfail" 2>&1)" || fetchfail_rc=$?
check "an unfetchable existing branch still claims (advisory, not fatal)" 0 "$fetchfail_rc" \
  "$fetchfail_out" "owner=session-fetchfail"
check "the unfetchable-branch claim actually creates the worktree" 0 \
  "$([ -d "$tmp/wt-fetchfail" ] && echo 0 || echo 1)"
# Silence here would be the dangerous outcome: origin POSITIVELY has this branch, so creating it
# locally forks a real PR rather than resuming it. The warning is what sends the operator to
# re-fetch before pushing, and it must say which of the two situations this is.
check "an unfetchable existing branch is announced as a FORK, not a resume" 0 "$fetchfail_rc" \
  "$fetchfail_out" "FORK, not a resume"
check "the fork warning states the branch exists on origin" 0 "$fetchfail_rc" \
  "$fetchfail_out" "EXISTS on origin"

# ── a CACHED tracking ref that is STALE, when the refresh fails ────────────────────────────────
# The guard above proves a cached ref EXISTS; existence is not freshness. With the fetch failing,
# that ref is whatever the last successful fetch left, so attaching resumes the PR at an obsolete
# head — the same silent staleness the fork branch warns about, arriving through the fallback
# instead. `ls-remote` already returned origin's tip, so this is checkable rather than unknowable.
stalecache_origin="$tmp/stalecache-origin.git"
git init -q --bare "$stalecache_origin"
stalecache_seed="$tmp/stalecache-seed"
git init -q "$stalecache_seed"
git -C "$stalecache_seed" config user.name "worktree-claim-test"
git -C "$stalecache_seed" config user.email "worktree-claim-test@example.com"
git -C "$stalecache_seed" commit --allow-empty -qm "init"
git -C "$stalecache_seed" branch -M main
git -C "$stalecache_seed" checkout -qb "claim-stalecache"
git -C "$stalecache_seed" commit --allow-empty -qm "v1"
git -C "$stalecache_seed" remote add origin "$stalecache_origin"
git -C "$stalecache_seed" push -q origin main claim-stalecache

# Clone WHILE the branch is at v1, so the tracking ref is cached and genuinely current...
stalecache_consumer="$tmp/stalecache-consumer"
git clone -q "$stalecache_origin" "$stalecache_consumer"
stalecache_cached="$(git -C "$stalecache_consumer" rev-parse refs/remotes/origin/claim-stalecache)"
# ...then advance origin, which is what makes the cache stale without touching the consumer.
git -C "$stalecache_seed" commit --allow-empty -qm "v2"
git -C "$stalecache_seed" push -q origin claim-stalecache
stalecache_tip="$(git -C "$stalecache_origin" rev-parse claim-stalecache)"
check "precondition: the cached ref and origin's tip actually differ" 0 \
  "$([ "$stalecache_cached" != "$stalecache_tip" ] && echo 0 || echo 1)"

stalecache_rc=0
stalecache_out="$(PATH="$fetchfail_stub:$PATH" "$script" add \
  "$stalecache_consumer" "$tmp/wt-stalecache" "claim-stalecache" "session-stalecache" 2>&1)" || stalecache_rc=$?
check "a stale cached ref still claims (advisory, not fatal)" 0 "$stalecache_rc" \
  "$stalecache_out" "owner=session-stalecache"
check "an unrefreshable cached ref is announced as STALE" 0 "$stalecache_rc" \
  "$stalecache_out" "is STALE"
# Naming both SHAs is what makes the warning actionable rather than vague: the operator can see
# which head they are on and which one they wanted.
check "the stale-cache warning names the cached AND the origin sha" 0 "$stalecache_rc" \
  "$stalecache_out" "${stalecache_cached:0:10}"

# The complement, and the reason this cannot just always warn: when the fetch SUCCEEDS the cached
# ref is current, so the warning must stay silent or it fires on every ordinary attach.
freshcache_consumer="$tmp/freshcache-consumer"
git clone -q "$stalecache_origin" "$freshcache_consumer"
freshcache_rc=0
freshcache_out="$("$script" add \
  "$freshcache_consumer" "$tmp/wt-freshcache" "claim-stalecache" "session-freshcache" 2>&1)" || freshcache_rc=$?
check "no false STALE warning when the refresh succeeds" 0 \
  "$(grep -qF 'is STALE' <<<"$freshcache_out" && echo 1 || echo 0)"

# ── the stale-LOCAL remediation must move something ────────────────────────────────────────────
# It used to print `git fetch origin <branch>` — a command this function has already run, and which
# only updates refs/remotes/origin/<branch>. Following it leaves the worktree exactly as stale, so
# the operator learns the warning is noise. The hint must name the fast-forward in the WORKTREE.
check "the stale-local hint names a merge, not another fetch" 0 "$stalelocal_rc" \
  "$stalelocal_out" "merge --ff-only"
check "the stale-local hint targets the WORKTREE, not the repo" 0 "$stalelocal_rc" \
  "$stalelocal_out" "wt-stale-local"

printf '\nworktree-claim: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
