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
check "stale-base warning names the rebase fix" 0 "$stale_rc" "$stale_out" "rebase 'origin/main'"

# Control: same script, same repo, base now current — the warning MUST disappear. If this arm also
# warned, the positive arm above would prove nothing about staleness detection.
git -C "$consumer" fetch -q origin main
git -C "$consumer" reset -q --hard origin/main
current_out="$("$script" add "$consumer" "$tmp/wt-current" "claim-current" "session-current" 2>&1)"
current_rc=$?
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

moved_out="$("$script" add "$moved_consumer" "$tmp/wt-moved" "claim-moved" "session-moved" 2>&1)"
moved_rc=$?
check "moved default still claims successfully" 0 "$moved_rc" "$moved_out" "owner=session-moved"
check "moved default is measured against the CURRENT remote default" 0 "$moved_rc" \
  "$moved_out" "WARNING base is 2 commit(s) behind origin/trunk"

# Unresolvable remote: the comparison cannot be made, and the required outcome is an explicit UNKNOWN
# rather than silence — silence is indistinguishable from "base is current", the confusion this whole
# check exists to remove. Repointing origin at an absent bare repository is hermetic: ls-remote and
# fetch both fail locally, no network is touched. Claiming must still succeed (advisory, never fatal).
git -C "$consumer" remote set-url origin "$tmp/absent-origin.git"
unknown_out="$("$script" add "$consumer" "$tmp/wt-unknown" "claim-unknown" "session-unknown" 2>&1)"
unknown_rc=$?
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
# The NEGATIVE half: it must not render as a current base, which is what `behind=0` produced.
malformed_quiet_rc=0
grep -qF -- "WARNING base is 0 commit(s)" <<<"$malformed_out" && malformed_quiet_rc=1
check "a malformed behind-count never renders as 'not behind'" 0 "$malformed_quiet_rc"

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
# The guard body must actually emit the notice, not merely return.
awk -v n="$revlist_line" 'NR>n && NR<=n+2 && index($0,"base_freshness_unknown")' <<<"$normalise_code" |
  grep -q . || revfail_rc=1
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
slow_transport="$tmp/slow-transport"
printf '#!/usr/bin/env bash\nexec sleep 97\n' >"$slow_transport"
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

printf '\nworktree-claim: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
