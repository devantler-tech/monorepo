#!/usr/bin/env bash
#
# Self-test for agent-claim.sh — RED/GREEN coverage of the sixteen traps proven
# by monorepo#2302, its review rounds and monorepo#3811. Fixtures use a local bare remote + two
# clones; nothing touches a real network remote.
#
# Trap 1 — arbitration works: second non-force push loses; ls-remote shows winner.
# Trap 2 — never judge by push exit status: a piped `push | true` looks like
#          success while verify correctly reports LOST.
# Trap 3 — identical commits collide without a nonce; the helper's nonce makes
#          two acquirers produce distinct shas.
# Trap 4 — unretired claim is a permanent lock; --takeover after lease expiry
#          recovers it, and a third acquirer still loses to the takeover winner.
# Trap 8 — takeover stdout is exactly the acquired SHA; diagnostics stay on stderr.
# Trap 9 — inherited Git dates cannot backdate a fresh claim's lease clock.
# Trap 10 — an uninitialized submodule path must not resolve upward into the
#           parent repository and claim the same-numbered issue there.
# Trap 11 — a failed retire must not report success when its follow-up remote
#           tip query also fails.
# Trap 12 — publication renews ownership with a fresh CAS-protected lease.
# Trap 13 — replacement refs cannot change the tree pushed by a claim commit.
# Trap 14 — production takeover never accepts a lease below two hours.
# Trap 15 — a failed post-push tip query reports UNKNOWN and returns the
#           candidate ownership token for recovery.
# Trap 16 — a commit that lands on a pull request after a stale PR-number tip
#           must not make that tip a permanent lock: takeover names the head the
#           caller re-read, and the helper checks and records it.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$script_dir/agent-claim.sh"
chmod +x "$tool"

tmp="$(mktemp -d)"
test_run_finished=0
# bash 3.2 can report a set -e abort inside an EXIT trap as exit 0, so require completion.
on_test_exit() {
  local status=$?
  rm -rf "$tmp"
  if [ "${test_run_finished}" != 1 ]; then
    echo "agent-claim.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    [ "${status}" != 0 ] || status=1
    exit "${status}"
  fi
}
trap on_test_exit EXIT

failures=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; failures=$(( failures + 1 )); }

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

# ---------------------------------------------------------------------------
# Fixture: bare remote + seed commit, then two clones sharing that remote.
# ---------------------------------------------------------------------------
bare="$tmp/remote.git"
git init --bare --quiet "$bare"

seed="$tmp/seed"
git clone --quiet "$bare" "$seed"
git -C "$seed" config user.email "agent-claim-test@example.com"
git -C "$seed" config user.name "agent-claim-test"
git -C "$seed" config commit.gpgsign false
# One shared parent so trap 3 is reproducible (identical parent + message → same sha).
echo seed > "$seed/README"
git -C "$seed" add README
git -C "$seed" commit --quiet -m "chore: seed"
git -C "$seed" push --quiet origin HEAD:main
# The remote stands in for a forge, which publishes a head for every pull
# request. One is enough for any other number to be shown NOT to be a pull
# request, which a takeover has to establish before it treats a number as an
# issue (trap 16).
git -C "$seed" push --quiet origin HEAD:refs/pull/1/head
git -C "$seed" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
git --git-dir="$bare" symbolic-ref HEAD refs/heads/main

clone_a="$tmp/a"
clone_b="$tmp/b"
clone_c="$tmp/c"
git clone --quiet "$bare" "$clone_a"
git clone --quiet "$bare" "$clone_b"
git clone --quiet "$bare" "$clone_c"
for c in "$clone_a" "$clone_b" "$clone_c"; do
  git -C "$c" config user.email "agent-claim-test@example.com"
  git -C "$c" config user.name "agent-claim-test"
  git -C "$c" config commit.gpgsign false
done

ISSUE=2302

# ---------------------------------------------------------------------------
# Trap 10 — --repo-dir must identify that exact repository root.
#
# Git's -C lookup walks upward from an ordinary directory. An uninitialized
# submodule is such a directory, so without an explicit boundary check the
# helper silently operates on the parent monorepo and claims the wrong issue.
# ---------------------------------------------------------------------------
ISSUE10=1010
uninitialized_submodule="$clone_a/applications/uninitialized"
mkdir -p "$uninitialized_submodule"
rc_uninitialized=0
"$tool" acquire "$ISSUE10" --repo-dir "$uninitialized_submodule" --remote origin \
  >"$tmp/out-uninitialized" 2>"$tmp/err-uninitialized" || rc_uninitialized=$?
check "trap10: uninitialized submodule path exits 2" "2" "$rc_uninitialized"
parent_claim="$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE10}" | awk '{print $1}')"
check "trap10: uninitialized submodule path leaves parent remote untouched" "" "$parent_claim"
# RED cleanup: before the boundary fix, the helper creates this wrong ref.
if [[ -n "$parent_claim" ]]; then
  git -C "$clone_a" push --quiet --delete origin "agent-claim/${ISSUE10}" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Trap 1 — A wins, B loses. Tip equals A's sha.
# ---------------------------------------------------------------------------
out_a="$tmp/out-a"
rc_a=0
"$tool" acquire "$ISSUE" --repo-dir "$clone_a" --remote origin >"$out_a" 2>"$tmp/err-a" || rc_a=$?
sha_a="$(tail -n1 "$out_a")"
check "trap1: A acquire exits 0" "0" "$rc_a"
if [[ "$sha_a" =~ ^[0-9a-f]{40}$ ]]; then
  pass "trap1: A printed a full sha"
else
  fail "trap1: A sha missing ($sha_a)"
fi
check "trap1: stdout is exactly the acquired sha" "$sha_a" "$(cat "$out_a")"

rc_b=0
"$tool" acquire "$ISSUE" --repo-dir "$clone_b" --remote origin >"$tmp/out-b" 2>"$tmp/err-b" || rc_b=$?
check "trap1: B acquire exits 1 (lost)" "1" "$rc_b"

tip="$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE}" | awk '{print $1}')"
check "trap1: remote tip equals A's sha" "$sha_a" "$tip"

rc_v=0
"$tool" verify "$ISSUE" "$sha_a" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1 || rc_v=$?
check "trap1: A verify exits 0" "0" "$rc_v"

rc_vb=0
"$tool" verify "$ISSUE" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" --repo-dir "$clone_b" --remote origin >/dev/null 2>&1 || rc_vb=$?
check "trap1: B verify of foreign sha exits 1" "1" "$rc_vb"

# ---------------------------------------------------------------------------
# Trap 2 — never judge by push exit status. Simulate the classic
# `git push … | true` shape: the pipeline exits 0 even when the push is a
# no-op / rejection, but verify against B's hoped-for sha still says LOST.
# ---------------------------------------------------------------------------
# B crafts its own claim commit and "pushes" through a pipe that swallows
# the rejection, then checks the tip — the only safe signal.
nonce_b="trap2-fixed-nonce-should-lose"
parent="$(git -C "$clone_b" ls-remote origin HEAD | awk '{print $1}')"
sha_b="$(git -C "$clone_b" commit-tree "${parent}^{tree}" -p "$parent" \
  -m "chore: agent-claim #${ISSUE} nonce=${nonce_b}")"
# Push through a pipe ending in `true`. Temporarily disable only pipefail so
# errexit remains active while the final `true` makes the pipeline itself 0.
set +o pipefail
git -C "$clone_b" push origin "${sha_b}:refs/heads/agent-claim/${ISSUE}" 2>/dev/null | true
pipe_status=("${PIPESTATUS[@]}")
set -o pipefail
push_rc="${pipe_status[0]}"
sink_rc="${pipe_status[1]}"
if (( push_rc != 0 )); then
  pass "trap2: rejected push status is nonzero"
else
  fail "trap2: rejected push status is nonzero"
fi
check "trap2: final pipeline command succeeds" "0" "$sink_rc"
# The pipeline as a whole looked successful; assert the tip check is what
# matters, not either status.
rc_trap2=0
"$tool" verify "$ISSUE" "$sha_b" --repo-dir "$clone_b" --remote origin >/dev/null 2>&1 || rc_trap2=$?
check "trap2: verify rejects B's sha even after a pipe-masked push" "1" "$rc_trap2"
tip_after="$(git -C "$clone_b" ls-remote origin "refs/heads/agent-claim/${ISSUE}" | awk '{print $1}')"
check "trap2: tip still A's (pipe push did not steal the claim)" "$sha_a" "$tip_after"
# Sanity: document that a bare push status alone is not the verdict we use.
pass "trap2: push_rc_observed=${push_rc} (ignored by protocol; tip compare is authoritative)"

# ---------------------------------------------------------------------------
# Trap 3 — without a nonce, identical commits collide. Prove the collision
# first (RED), then prove the helper's nonce avoids it (GREEN).
# ---------------------------------------------------------------------------
# Fresh issue number so we start from an empty claim ref.
ISSUE3=9303
parent3="$(git -C "$clone_a" ls-remote origin HEAD | awk '{print $1}')"
# Same author, same message, same parent, same second → identical sha.
export GIT_AUTHOR_NAME="agent-claim-test"
export GIT_AUTHOR_EMAIL="agent-claim-test@example.com"
export GIT_COMMITTER_NAME="agent-claim-test"
export GIT_COMMITTER_EMAIL="agent-claim-test@example.com"
export GIT_AUTHOR_DATE="2026-07-20T12:00:00Z"
export GIT_COMMITTER_DATE="2026-07-20T12:00:00Z"
fixed_msg="chore: agent-claim #${ISSUE3}"
sha_left="$(git -C "$clone_a" commit-tree "${parent3}^{tree}" -p "$parent3" -m "$fixed_msg")"
sha_right="$(git -C "$clone_b" commit-tree "${parent3}^{tree}" -p "$parent3" -m "$fixed_msg")"
check "trap3 RED: identical inputs produce identical sha" "$sha_left" "$sha_right"
# Both pushes of the SAME sha succeed (fast-forward / identical update) — the
# silent double-win that made cross-lane arbitration fail.
git -C "$clone_a" push --quiet origin "${sha_left}:refs/heads/agent-claim/${ISSUE3}"
git -C "$clone_b" push --quiet origin "${sha_right}:refs/heads/agent-claim/${ISSUE3}"
tip3="$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE3}" | awk '{print $1}')"
check "trap3 RED: both writers see the tip as 'theirs'" "$sha_left" "$tip3"
# Clean up the RED fixture before the GREEN run.
git -C "$clone_a" push --quiet origin ":agent-claim/${ISSUE3}"

# GREEN: helper acquire twice with the same issue, parent, author and timestamp
# still produces distinct SHAs because the helper supplies fresh entropy.
export GIT_AUTHOR_DATE="2026-07-20T12:00:00Z"
export GIT_COMMITTER_DATE="2026-07-20T12:00:00Z"
ISSUE3G=9304
rc_a3=0
out_a3="$tmp/out-a3"
"$tool" acquire "$ISSUE3G" --repo-dir "$clone_a" --remote origin >"$out_a3" 2>"$tmp/err-a3" || rc_a3=$?
sha_a3="$(tail -n1 "$out_a3")"
check "trap3 GREEN: first acquire exits 0" "0" "$rc_a3"
rc_b3=0
"$tool" acquire "$ISSUE3G" --repo-dir "$clone_b" --remote origin >"$tmp/out-b3" 2>"$tmp/err-b3" || rc_b3=$?
check "trap3 GREEN: second acquire exits 1" "1" "$rc_b3"
check "trap3 GREEN: winner tip stable at first sha" "$sha_a3" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE3G}" | awk '{print $1}')"
"$tool" retire "$ISSUE3G" "$sha_a3" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1
rc_a3_again=0
sha_a3_again="$("$tool" acquire "$ISSUE3G" --repo-dir "$clone_a" --remote origin 2>/dev/null)" || rc_a3_again=$?
check "trap3 GREEN: same helper claim reacquires successfully" "0" "$rc_a3_again"
if [[ "$sha_a3_again" != "$sha_a3" ]]; then
  pass "trap3 GREEN: helper entropy changes the claim sha under fixed metadata"
else
  fail "trap3 GREEN: helper reused a claim sha under fixed metadata"
fi
"$tool" retire "$ISSUE3G" "$sha_a3_again" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE

# A caller's inherited Git dates must not backdate the helper's fresh lease
# commit. Otherwise a winner can look stale while it is still actively building.
ISSUE9=9306
export GIT_AUTHOR_DATE="2020-01-01T00:00:00Z"
export GIT_COMMITTER_DATE="2020-01-01T00:00:00Z"
sha_9="$("$tool" acquire "$ISSUE9" --repo-dir "$clone_a" --remote origin 2>/dev/null)"
rc_9=0
"$tool" is-stale "$ISSUE9" --repo-dir "$clone_a" --remote origin --lease-hours 2 \
  >/dev/null 2>&1 || rc_9=$?
check "trap9: inherited Git dates do not make a fresh claim stale" "1" "$rc_9"
"$tool" retire "$ISSUE9" "$sha_9" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE

# A controlled entropy-tool failure reaches nonce generation and must fail
# closed with the helper's usage/safety exit, leaving no claim ref behind.
entropy_shim="$tmp/entropy-shim"
mkdir -p "$entropy_shim"
cat > "$entropy_shim/od" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$entropy_shim/od"
ISSUE3E=9305
rc_entropy=0
PATH="$entropy_shim:$PATH" "$tool" acquire "$ISSUE3E" --repo-dir "$clone_a" --remote origin \
  >"$tmp/out-entropy" 2>"$tmp/err-entropy" || rc_entropy=$?
check "trap3 GREEN: unavailable entropy exits 2" "2" "$rc_entropy"
check "trap3 GREEN: unavailable entropy leaves no claim" "" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE3E}" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Trap 4 — unretired claim locks forever; stale takeover recovers; third loses.
# ---------------------------------------------------------------------------
ISSUE4=9404
# A acquires then "crashes" (no retire).
rc_a4=0
out_a4="$tmp/out-a4"
"$tool" acquire "$ISSUE4" --repo-dir "$clone_a" --remote origin >"$out_a4" 2>"$tmp/err-a4" || rc_a4=$?
sha_a4="$(tail -n1 "$out_a4")"
check "trap4: A acquire exits 0" "0" "$rc_a4"

# B tries immediately — refused (live lease).
rc_b4=0
"$tool" acquire "$ISSUE4" --repo-dir "$clone_b" --remote origin --takeover --lease-hours 2 \
  >"$tmp/out-b4" 2>"$tmp/err-b4" || rc_b4=$?
check "trap4: B takeover within lease exits 1" "1" "$rc_b4"
check "trap4: tip still A's after refused takeover" "$sha_a4" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE4}" | awk '{print $1}')"

# Production must not expose the zero-hour shortcut the old fixture used.
rc_lease0=0
"$tool" acquire "$ISSUE4" --repo-dir "$clone_b" --remote origin --takeover --lease-hours 0 \
  >"$tmp/out-lease0" 2>"$tmp/err-lease0" || rc_lease0=$?
check "trap14: zero-hour production takeover exits 2" "2" "$rc_lease0"
check "trap14: rejected lease override leaves the live holder intact" "$sha_a4" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE4}" | awk '{print $1}')"

# Reset the fixture and install a genuinely old claim commit. This tests the
# production two-hour path without an unsafe test-only CLI bypass.
git -C "$clone_a" push --quiet --delete origin "agent-claim/${ISSUE4}" >/dev/null 2>&1 || true
if old_claim_time="$(date -u -v-3H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
  :
else
  old_claim_time="$(date -u -d '3 hours ago' '+%Y-%m-%dT%H:%M:%SZ')"
fi
parent4="$(git -C "$clone_a" rev-parse HEAD)"
sha_a4="$(GIT_AUTHOR_DATE="$old_claim_time" GIT_COMMITTER_DATE="$old_claim_time" \
  git -C "$clone_a" commit-tree "${parent4}^{tree}" -p "$parent4" \
    -m "chore: stale agent-claim #${ISSUE4}")"
git -C "$clone_a" push --quiet origin "${sha_a4}:refs/heads/agent-claim/${ISSUE4}"

# B takes over the genuinely expired tip with the fixed production lease.
rc_b4b=0
out_b4b="$tmp/out-b4b"
"$tool" acquire "$ISSUE4" --repo-dir "$clone_b" --remote origin --takeover --lease-hours 2 \
  >"$out_b4b" 2>"$tmp/err-b4b" || rc_b4b=$?
sha_b4="$(tail -n1 "$out_b4b")"
check "trap4: B stale takeover exits 0" "0" "$rc_b4b"
check "trap8: takeover stdout is exactly the acquired sha" "$sha_b4" "$(cat "$out_b4b")"
check "trap4: tip equals B after takeover" "$sha_b4" \
  "$(git -C "$clone_b" ls-remote origin "refs/heads/agent-claim/${ISSUE4}" | awk '{print $1}')"
if [[ "$sha_b4" != "$sha_a4" ]]; then
  pass "trap4: takeover sha differs from crashed A's"
else
  fail "trap4: takeover reused A's sha"
fi

# C still loses to B.
rc_c4=0
"$tool" acquire "$ISSUE4" --repo-dir "$clone_c" --remote origin >"$tmp/out-c4" 2>"$tmp/err-c4" || rc_c4=$?
check "trap4: C acquire exits 1 (lost to B)" "1" "$rc_c4"
check "trap4: tip still B's after C loses" "$sha_b4" \
  "$(git -C "$clone_c" ls-remote origin "refs/heads/agent-claim/${ISSUE4}" | awk '{print $1}')"

# A stale holder must not be able to retire B's replacement claim. Retirement
# is ownership-sensitive: the acquired SHA, not merely the currently observed
# remote tip, is the authority to delete.
rc_stale_r=0
"$tool" retire "$ISSUE4" "$sha_a4" --repo-dir "$clone_a" --remote origin \
  >"$tmp/out-stale-r4" 2>"$tmp/err-stale-r4" || rc_stale_r=$?
check "trap4: stale holder retire exits 1 (lost ownership)" "1" "$rc_stale_r"
check "trap4: stale holder cannot erase takeover winner" "$sha_b4" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE4}" | awk '{print $1}')"

# The actual holder can retire when it supplies the SHA returned by acquire.
rc_owned_r=0
"$tool" retire "$ISSUE4" "$sha_b4" --repo-dir "$clone_b" --remote origin \
  >"$tmp/out-owned-r4" 2>"$tmp/err-owned-r4" || rc_owned_r=$?
check "trap4: holder retire with acquired sha exits 0" "0" "$rc_owned_r"
check "trap4: holder retire removes its own claim" "" \
  "$(git -C "$clone_b" ls-remote origin "refs/heads/agent-claim/${ISSUE4}" | awk '{print $1}')"

# Retire is idempotent and clears the lock.
rc_r=0
"$tool" retire "$ISSUE4" "$sha_b4" --repo-dir "$clone_b" --remote origin >/dev/null 2>&1 || rc_r=$?
check "trap4: retire exits 0" "0" "$rc_r"
tip_gone="$(git -C "$clone_b" ls-remote origin "refs/heads/agent-claim/${ISSUE4}" | awk '{print $1}')"
check "trap4: tip absent after retire" "" "$tip_gone"
rc_r2=0
"$tool" retire "$ISSUE4" "$sha_b4" --repo-dir "$clone_b" --remote origin >/dev/null 2>&1 || rc_r2=$?
check "trap4: retire is idempotent" "0" "$rc_r2"

# ---------------------------------------------------------------------------
# Entropy fail-closed: if /dev/urandom were unreadable the helper must exit 2.
# We cannot unmount /dev/urandom here; instead assert the nonce function's
# contract by checking the script refuses a non-integer issue (usage fail-closed).
# ---------------------------------------------------------------------------
# --help prints the usage block and exits 0 on BSD userlands too: a GNU-only
# `head -n -1` made it print nothing and exit 1 on macOS under pipefail.
rc_help=0
out_help="$tmp/out-help"
"$tool" --help >"$out_help" 2>&1 || rc_help=$?
check "usage: --help exits 0" "0" "$rc_help"
check "usage: --help prints the acquire synopsis" "1" \
  "$(grep -c '^  agent-claim.sh acquire <issue>' "$out_help" || true)"
check "usage: --help stops before the exit codes" "0" \
  "$(grep -c 'Exit codes:' "$out_help" || true)"
rc_bad=0
"$tool" acquire not-a-number --repo-dir "$clone_a" --remote origin >/dev/null 2>&1 || rc_bad=$?
check "usage: non-integer issue exits 2" "2" "$rc_bad"
rc_zero=0
out_zero="$tmp/out-zero"
"$tool" acquire 0 --repo-dir "$clone_a" --remote origin >"$out_zero" 2>"$tmp/err-zero" || rc_zero=$?
check "usage: zero issue exits 2" "2" "$rc_zero"
zero_sha="$(tail -n1 "$out_zero")"
if [[ "$zero_sha" =~ ^[0-9a-f]{40}$ ]]; then
  "$tool" retire 0 "$zero_sha" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Trap 5 — a delete must be a COMPARE-and-delete.
#
# Between observing a tip and deleting it, a rival can retire and reacquire the
# claim. An unconditional delete erases that fresh holder, so both lanes come
# away believing they hold it — the exact double-win the ref exists to prevent.
# ---------------------------------------------------------------------------
ISSUE5=5005
claim5="refs/heads/agent-claim/${ISSUE5}"

sha_a5="$("$tool" acquire "$ISSUE5" --repo-dir "$clone_a" --remote origin 2>/dev/null | tail -1)"
check "trap5: first acquire wins" "$sha_a5" "$(git -C "$clone_a" ls-remote origin "$claim5" | awk '{print $1}')"

# The rival retires and immediately reacquires — a legitimate, fresh claim.
"$tool" retire "$ISSUE5" "$sha_a5" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1
sha_b5="$("$tool" acquire "$ISSUE5" --repo-dir "$clone_b" --remote origin 2>/dev/null | tail -1)"
check "trap5: rival reacquires after retire" "$sha_b5" "$(git -C "$clone_b" ls-remote origin "$claim5" | awk '{print $1}')"

# Now a takeover that observed the ORIGINAL tip tries to delete. Its expectation
# is stale, so it must fail closed and leave the rival's claim standing.
git -C "$clone_a" fetch --quiet origin 2>/dev/null || true
rc_cas=0
git -C "$clone_a" push --quiet --force-with-lease="agent-claim/${ISSUE5}:${sha_a5}" \
  origin ":agent-claim/${ISSUE5}" >/dev/null 2>&1 || rc_cas=$?
if (( rc_cas != 0 )); then
  pass "trap5: compare-and-delete against a stale tip is refused"
else
  fail "trap5: compare-and-delete against a stale tip is refused (it succeeded)"
fi
check "trap5: rival's claim survives the stale delete" "$sha_b5" \
  "$(git -C "$clone_b" ls-remote origin "$claim5" | awk '{print $1}')"

# The holder's own retire observes the current tip, so it still succeeds.
rc_r5=0
"$tool" retire "$ISSUE5" "$sha_b5" --repo-dir "$clone_b" --remote origin >/dev/null 2>&1 || rc_r5=$?
check "trap5: the real holder can still retire" "0" "$rc_r5"
check "trap5: claim is gone after the holder's retire" "" \
  "$(git -C "$clone_b" ls-remote origin "$claim5" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Trap 5b — the same guard, exercised THROUGH THE TOOL.
#
# Trap 5 above proves git's compare-and-delete primitive; it does not prove the
# helper uses it. A `git` shim races a rival tip into place at the exact moment
# the helper issues its delete, which is the interleaving the fix defends and
# the one no fixture can produce by ordering alone.
# ---------------------------------------------------------------------------
ISSUE5B=5015
claim5b="refs/heads/agent-claim/${ISSUE5B}"
real_git="$(command -v git)"

sha_a5b="$("$tool" acquire "$ISSUE5B" --repo-dir "$clone_a" --remote origin 2>/dev/null | tail -1)"
rival5b="$(git -C "$clone_b" commit-tree "HEAD^{tree}" -p HEAD -m "chore: rival reacquire ${ISSUE5B}")"

shim_dir="$tmp/shim"
mkdir -p "$shim_dir"
retire_tmp="$tmp/retire-tmp"
mkdir -p "$retire_tmp"
cat > "$shim_dir/git" <<SHIM
#!/usr/bin/env bash
# Delegates to real git, but the first time it sees the claim delete it lets a
# rival replace the tip first — simulating a retire+reacquire landing inside the
# helper's observe→delete window.
raced=0
for a in "\$@"; do
  case "\$a" in ":agent-claim/${ISSUE5B}"|":${claim5b}") raced=1 ;; esac
done
if [[ "\$raced" -eq 1 && ! -f "$tmp/shim.fired" ]]; then
  if compgen -G "$retire_tmp/agent-claim-retire.*" >/dev/null; then
    : > "$tmp/retire-tmp-seen"
  fi
  : > "$tmp/shim.fired"
  "$real_git" -C "$clone_b" push --quiet --force origin "${rival5b}:${claim5b}" >/dev/null 2>&1
fi
exec "$real_git" "\$@"
SHIM
chmod +x "$shim_dir/git"

rc_race=0
TMPDIR="$retire_tmp" PATH="$shim_dir:$PATH" "$tool" retire "$ISSUE5B" "$sha_a5b" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1 || rc_race=$?
if [[ -f "$tmp/shim.fired" ]]; then
  pass "trap5b: fixture — the race actually fired inside the helper"
else
  fail "trap5b: fixture — the race never fired (shim did not intercept the delete)"
fi
if (( rc_race != 0 )); then
  pass "trap5b: helper's delete fails closed when the tip moved under it"
else
  fail "trap5b: helper's delete fails closed when the tip moved under it (it succeeded)"
fi
check "trap5b: the rival's fresh claim survives" "$rival5b" \
  "$(git -C "$clone_b" ls-remote origin "$claim5b" | awk '{print $1}')"
if [[ -f "$tmp/retire-tmp-seen" ]]; then
  pass "trap5b: retire stderr uses a private mktemp file"
else
  fail "trap5b: retire stderr uses a private mktemp file"
fi
check "trap5b: retire temp file is removed after failure" "" \
  "$(find "$retire_tmp" -type f -name 'agent-claim-retire.*' -print -quit)"
git -C "$clone_b" push --quiet --delete origin "$claim5b" >/dev/null 2>&1 || true
unset sha_a5b

# ---------------------------------------------------------------------------
# Trap 6 — the claim parent must be a LOCAL object.
#
# The remote default advances independently of this checkout (routine for a
# pinned submodule). Naming a SHA this clone has never fetched makes
# `commit-tree -p` exit 128 with `not a valid object`, so acquisition becomes
# impossible exactly when the remote is busiest.
# ---------------------------------------------------------------------------
ISSUE6=6006
# clone_b pushes a commit clone_a has never seen.
echo "remote-only change" >> "$clone_b/README"
git -C "$clone_b" add README
git -C "$clone_b" commit --quiet -m "chore: remote-only advance"
git -C "$clone_b" push --quiet origin HEAD:main

remote_head="$(git -C "$clone_a" ls-remote origin HEAD | awk '{print $1; exit}')"
if git -C "$clone_a" cat-file -e "${remote_head}^{commit}" 2>/dev/null; then
  fail "trap6: fixture invalid — clone_a already has the remote-only commit"
else
  pass "trap6: fixture — remote tip is absent locally"
fi

rc_acq6=0
sha_a6="$("$tool" acquire "$ISSUE6" --repo-dir "$clone_a" --remote origin 2>/dev/null | tail -1)" || rc_acq6=$?
check "trap6: acquire succeeds against an unfetched remote tip" "0" "$rc_acq6"
check "trap6: the claim tip is ours" "$sha_a6" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE6}" | awk '{print $1}')"
"$tool" retire "$ISSUE6" "$sha_a6" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Trap 7 — a rejected create with no competing tip is a capability/service
# failure, not a lost race. A pre-receive hook rejects only this issue ref so
# the real push and remote-tip behavior remain under test.
# ---------------------------------------------------------------------------
ISSUE7=7007
hook="$bare/hooks/pre-receive"
cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
  if [[ "$ref" == "refs/heads/agent-claim/7007" ]]; then
    echo "claim namespace denied" >&2
    exit 1
  fi
done
exit 0
HOOK
chmod +x "$hook"

rc_denied=0
"$tool" acquire "$ISSUE7" --repo-dir "$clone_a" --remote origin \
  >"$tmp/out-denied7" 2>"$tmp/err-denied7" || rc_denied=$?
check "trap7: rejected push with no winner exits 2" "2" "$rc_denied"
if grep -q "FAILED" "$tmp/err-denied7"; then
  pass "trap7: rejected push is reported as capability/service failure"
else
  fail "trap7: rejected push is reported as capability/service failure"
fi
check "trap7: rejected push leaves no competing claim tip" "" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE7}" | awk '{print $1}')"
rm -f "$hook"

# ---------------------------------------------------------------------------
# Trap 11 — failed delete + failed confirmation is UNKNOWN, never retired.
#
# A transient transport failure can reject the compare-and-delete and then make
# the follow-up ls-remote fail too. Empty output from that failed query does not
# prove absence; the helper must fail closed so the caller retries cleanup.
# ---------------------------------------------------------------------------
ISSUE11=1111
sha_11="$("$tool" acquire "$ISSUE11" --repo-dir "$clone_a" --remote origin 2>/dev/null)"
shim_dir_11="$tmp/shim-11"
mkdir -p "$shim_dir_11"
real_git_11="$(command -v git)"
cat > "$shim_dir_11/git" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == ":agent-claim/${ISSUE11}" || "\$arg" == ":refs/heads/agent-claim/${ISSUE11}" ]]; then
    : > "$tmp/trap11-delete-failed"
    echo "simulated delete transport failure" >&2
    exit 1
  fi
done
if [[ -f "$tmp/trap11-delete-failed" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == "ls-remote" ]]; then
      echo "simulated tip query transport failure" >&2
      exit 1
    fi
  done
fi
exec "$real_git_11" "\$@"
SHIM
chmod +x "$shim_dir_11/git"

rc_11=0
PATH="$shim_dir_11:$PATH" "$tool" retire "$ISSUE11" "$sha_11" \
  --repo-dir "$clone_a" --remote origin >"$tmp/out-11" 2>"$tmp/err-11" || rc_11=$?
check "trap11: failed delete plus failed tip query exits 2" "2" "$rc_11"
check "trap11: unknown retirement leaves the claim intact" "$sha_11" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE11}" | awk '{print $1}')"
"$tool" retire "$ISSUE11" "$sha_11" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Trap 12 — renew atomically refreshes an expired ownership token.
# ---------------------------------------------------------------------------
ISSUE12=1212
parent12="$(git -C "$clone_a" rev-parse HEAD)"
sha_old12="$(GIT_AUTHOR_DATE="$old_claim_time" GIT_COMMITTER_DATE="$old_claim_time" \
  git -C "$clone_a" commit-tree "${parent12}^{tree}" -p "$parent12" \
    -m "chore: stale agent-claim #${ISSUE12}")"
git -C "$clone_a" push --quiet origin "${sha_old12}:refs/heads/agent-claim/${ISSUE12}"
rc_renew12=0
out_renew12="$tmp/out-renew12"
"$tool" renew "$ISSUE12" "$sha_old12" --repo-dir "$clone_a" --remote origin \
  >"$out_renew12" 2>"$tmp/err-renew12" || rc_renew12=$?
sha_new12="$(tail -n1 "$out_renew12")"
check "trap12: expired holder renew exits 0" "0" "$rc_renew12"
if [[ "$sha_new12" =~ ^[0-9a-f]{40}$ && "$sha_new12" != "$sha_old12" ]]; then
  pass "trap12: renew returns a fresh full ownership sha"
else
  fail "trap12: renew returns a fresh full ownership sha"
fi
check "trap12: renewed sha is the remote tip" "$sha_new12" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE12}" | awk '{print $1}')"
rc_stale12=0
"$tool" is-stale "$ISSUE12" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1 || rc_stale12=$?
check "trap12: renewed lease is live" "1" "$rc_stale12"
rc_old12=0
"$tool" retire "$ISSUE12" "$sha_old12" --repo-dir "$clone_a" --remote origin \
  >/dev/null 2>&1 || rc_old12=$?
check "trap12: pre-renew token cannot retire the renewed claim" "1" "$rc_old12"
if [[ "$sha_new12" =~ ^[0-9a-f]{40}$ ]]; then
  "$tool" retire "$ISSUE12" "$sha_new12" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1 || true
else
  git -C "$clone_a" push --quiet --delete origin "agent-claim/${ISSUE12}" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Trap 13 — local replacement refs cannot alter coordination commit bytes.
# ---------------------------------------------------------------------------
ISSUE13=1313
git -C "$clone_a" fetch --quiet origin HEAD
parent13="$(git -C "$clone_a" --no-replace-objects rev-parse FETCH_HEAD)"
parent_tree13="$(git -C "$clone_a" --no-replace-objects rev-parse "${parent13}^{tree}")"
secret_blob13="$(printf 'must-not-be-pushed\n' | git -C "$clone_a" hash-object -w --stdin)"
secret_tree13="$(printf '100644 blob %s\tSECRET\n' "$secret_blob13" | git -C "$clone_a" mktree)"
replacement13="$(git -C "$clone_a" commit-tree "$secret_tree13" -p "$parent13" \
  -m 'chore: local replacement trap')"
git -C "$clone_a" replace "$parent13" "$replacement13"
sha_13="$("$tool" acquire "$ISSUE13" --repo-dir "$clone_a" --remote origin 2>/dev/null)"
claim_tree13="$(git -C "$clone_a" --no-replace-objects rev-parse "${sha_13}^{tree}")"
check "trap13: claim tree ignores the local replacement" "$parent_tree13" "$claim_tree13"
check "trap13: replacement-only secret is absent from claim tree" "" \
  "$(git -C "$clone_a" --no-replace-objects ls-tree -r --name-only "$sha_13" | grep -Fx 'SECRET' || true)"
if git --git-dir="$bare" cat-file -e "$secret_blob13" 2>/dev/null; then
  fail "trap13: replacement-only secret object was uploaded to the remote"
else
  pass "trap13: replacement-only secret object was not uploaded to the remote"
fi
"$tool" retire "$ISSUE13" "$sha_13" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1
git -C "$clone_a" replace -d "$parent13" >/dev/null

# ---------------------------------------------------------------------------
# Trap 15 — a post-push query outage preserves the candidate token.
# ---------------------------------------------------------------------------
ISSUE15=1515
shim_dir_15="$tmp/shim-15"
mkdir -p "$shim_dir_15"
real_git_15="$(command -v git)"
cat > "$shim_dir_15/git" <<SHIM
#!/usr/bin/env bash
is_claim_create=0
for arg in "\$@"; do
  if [[ "\$arg" =~ ^[0-9a-f]{40}:refs/heads/agent-claim/${ISSUE15}$ ]]; then
    is_claim_create=1
  fi
done
if [[ "\$is_claim_create" -eq 1 ]]; then
  "$real_git_15" "\$@"
  rc=\$?
  if [[ "\$rc" -eq 0 ]]; then : > "$tmp/trap15-pushed"; fi
  exit "\$rc"
fi
if [[ -f "$tmp/trap15-pushed" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == "ls-remote" ]]; then
      echo "simulated post-push tip query failure" >&2
      exit 1
    fi
  done
fi
exec "$real_git_15" "\$@"
SHIM
chmod +x "$shim_dir_15/git"

rc_15=0
PATH="$shim_dir_15:$PATH" "$tool" acquire "$ISSUE15" --repo-dir "$clone_a" --remote origin \
  >"$tmp/out-15" 2>"$tmp/err-15" || rc_15=$?
candidate_15="$(tail -n1 "$tmp/out-15")"
check "trap15: post-push tip query failure exits 2" "2" "$rc_15"
if [[ "$candidate_15" =~ ^[0-9a-f]{40}$ ]]; then
  pass "trap15: UNKNOWN returns the candidate ownership token"
else
  fail "trap15: UNKNOWN returns the candidate ownership token"
fi
actual_15="$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE15}" | awk '{print $1}')"
check "trap15: candidate token can recover the live remote claim" "$actual_15" "$candidate_15"
if grep -q 'UNKNOWN' "$tmp/err-15"; then
  pass "trap15: post-push outage has an explicit UNKNOWN diagnostic"
else
  fail "trap15: post-push outage has an explicit UNKNOWN diagnostic"
fi
if [[ "$actual_15" =~ ^[0-9a-f]{40}$ ]]; then
  "$tool" retire "$ISSUE15" "$actual_15" --repo-dir "$clone_a" --remote origin >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
# Trap 16 — a commit on the pull request after a stale PR-number tip must not
# make that tip a permanent lock (monorepo#3811).
#
# Claim protocol rule 6 used to allow takeover of an `agent-claim/<pr-number>`
# tip only while no commit on the pull request was newer than the tip, reading
# a newer commit as "the holder delivered and only failed to retire". A commit
# the holder never made — an "Update branch" merge of the base — satisfied that
# too, and then nothing could take the tip over or clear it until the pull
# request closed. Takeover of a pull-request number is now gated on the caller
# naming the head it re-read: the helper compares it with the remote's
# refs/pull/<n>/head, which is how the forge publishes a pull request's head,
# and records it in the claim commit.
# ---------------------------------------------------------------------------
ISSUE16=1616
claim16="refs/heads/agent-claim/${ISSUE16}"
pull16="refs/pull/${ISSUE16}/head"
tip16() { git -C "$clone_c" ls-remote origin "$claim16" | awk '{print $1}'; }

if older_time="$(date -u -v-4H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
  :
else
  older_time="$(date -u -d '4 hours ago' '+%Y-%m-%dT%H:%M:%SZ')"
fi
base16="$(git -C "$clone_b" rev-parse HEAD)"
# The pull request's head as the holder last saw it, older than the claim.
head16_v1="$(GIT_AUTHOR_DATE="$older_time" GIT_COMMITTER_DATE="$older_time" \
  git -C "$clone_b" commit-tree "${base16}^{tree}" -p "$base16" -m "feat: the pull request's work")"
git -C "$clone_b" push --quiet origin "${head16_v1}:${pull16}"
# The holder claimed the pull request three hours ago and never retired.
stale16="$(GIT_AUTHOR_DATE="$old_claim_time" GIT_COMMITTER_DATE="$old_claim_time" \
  git -C "$clone_b" commit-tree "${base16}^{tree}" -p "$base16" \
    -m "chore: stale agent-claim #${ISSUE16}")"
git -C "$clone_b" push --quiet origin "${stale16}:${claim16}"
# Afterwards a commit the holder did not make lands on the pull request.
head16_v2="$(git -C "$clone_b" commit-tree "${base16}^{tree}" -p "$head16_v1" -p "$base16" \
  -m "Merge branch 'main' into the pull request")"
git -C "$clone_b" push --quiet origin "${head16_v2}:${pull16}"

if (( $(git -C "$clone_b" log -1 --format=%ct "$head16_v2") > $(git -C "$clone_b" log -1 --format=%ct "$stale16") )); then
  pass "trap16: fixture — a commit landed on the pull request after the stale tip"
else
  fail "trap16: fixture — a commit landed on the pull request after the stale tip"
fi
rc_16_stale=0
"$tool" is-stale "$ISSUE16" --repo-dir "$clone_c" --remote origin >/dev/null 2>&1 || rc_16_stale=$?
check "trap16: fixture — the tip is past its lease" "0" "$rc_16_stale"
rc_16_plain=0
"$tool" acquire "$ISSUE16" --repo-dir "$clone_c" --remote origin >/dev/null 2>&1 || rc_16_plain=$?
check "trap16: a plain acquire still loses to the leftover tip" "1" "$rc_16_plain"

# Takeover of a pull-request number must name the head the caller re-read.
rc_16_nohead=0
"$tool" acquire "$ISSUE16" --repo-dir "$clone_c" --remote origin --takeover \
  >"$tmp/out-16-nohead" 2>"$tmp/err-16-nohead" || rc_16_nohead=$?
check "trap16: takeover of a pull-request number without --pr-head exits 2" "2" "$rc_16_nohead"
check "trap16: takeover without --pr-head leaves the tip in place" "$stale16" "$(tip16)"
if grep -q 'is a pull request' "$tmp/err-16-nohead" && grep -q -- '--pr-head' "$tmp/err-16-nohead"; then
  pass "trap16: the refusal asks for the head that was re-read"
else
  fail "trap16: the refusal asks for the head that was re-read"
fi

# A head read before the newer commit is not the current head: the caller has
# not seen what landed, which is exactly what the retired date gate stood for.
rc_16_old=0
"$tool" acquire "$ISSUE16" --repo-dir "$clone_c" --remote origin --takeover --pr-head "$head16_v1" \
  >"$tmp/out-16-old" 2>"$tmp/err-16-old" || rc_16_old=$?
check "trap16: takeover naming a head that has since moved exits 1" "1" "$rc_16_old"
check "trap16: takeover naming a moved head leaves the tip in place" "$stale16" "$(tip16)"
if grep -q 'REFUSED takeover' "$tmp/err-16-old" && grep -q 'not the head you re-read' "$tmp/err-16-old"; then
  pass "trap16: a moved head is refused as a moved head"
else
  fail "trap16: a moved head is refused as a moved head"
fi
# The current head must come from the caller's own read of the pull request,
# so neither refusal hands it out.
check "trap16: no refusal prints the current head" "0" \
  "$(cat "$tmp/err-16-nohead" "$tmp/out-16-nohead" "$tmp/err-16-old" "$tmp/out-16-old" | grep -c "$head16_v2" || true)"

# Whether a number is a pull request is read from the remote's whole ref
# listing, asked for with no pattern. The shim answers that one read falsely,
# as TRAP16_READS says, and passes every other git call through: `fail` fails
# it, `no-pulls` leaves out every pull-request head and `omit-claim` leaves out
# the claim tips.
shim_dir_16="$tmp/shim-16"
mkdir -p "$shim_dir_16"
real_git_16="$(command -v git)"
cat > "$shim_dir_16/git" <<SHIM
#!/usr/bin/env bash
listing=0
patterned=0
for arg in "\$@"; do
  if [[ "\$arg" == "ls-remote" ]]; then listing=1; fi
  if [[ "\$arg" == refs/* || "\$arg" == HEAD ]]; then patterned=1; fi
done
if [[ "\$listing" -eq 1 && "\$patterned" -eq 0 && -n "\${TRAP16_READS:-}" ]]; then
  : > "$tmp/trap16-read-\${TRAP16_READS}"
  case "\${TRAP16_READS}" in
    fail)
      echo "simulated ref listing failure" >&2
      exit 1
      ;;
    no-pulls) drop='refs/pull/' ;;
    omit-claim) drop='refs/heads/agent-claim/' ;;
    *) exit 1 ;;
  esac
  rows="\$("$real_git_16" "\$@")" || exit 1
  awk -v drop="\$drop" 'index(\$2, drop) != 1' <<<"\$rows"
  exit 0
fi
exec "$real_git_16" "\$@"
SHIM
chmod +x "$shim_dir_16/git"
# A listing that cannot be read is UNKNOWN, never "this is an issue".
rc_16_unknown=0
TRAP16_READS=fail PATH="$shim_dir_16:$PATH" "$tool" acquire "$ISSUE16" --repo-dir "$clone_c" --remote origin \
  --takeover --pr-head "$head16_v2" >"$tmp/out-16-unknown" 2>"$tmp/err-16-unknown" || rc_16_unknown=$?
if [[ -f "$tmp/trap16-read-fail" ]]; then
  pass "trap16: fixture — the pull-request head read actually failed"
else
  fail "trap16: fixture — the pull-request head read never ran"
fi
check "trap16: an unreadable pull-request head exits 2" "2" "$rc_16_unknown"
check "trap16: an unreadable pull-request head leaves the tip in place" "$stale16" "$(tip16)"
if grep -q 'UNKNOWN' "$tmp/err-16-unknown" && grep -q 'could not list the refs' "$tmp/err-16-unknown"; then
  pass "trap16: an unreadable pull-request head is reported as UNKNOWN, as a failed read"
else
  fail "trap16: an unreadable pull-request head is reported as UNKNOWN, as a failed read"
fi
# The same outage without --pr-head is the fail-open to rule out: a failed read
# taken for "no pull request here" would let the takeover through unchecked.
rc_16_unknown_bare=0
TRAP16_READS=fail PATH="$shim_dir_16:$PATH" "$tool" acquire "$ISSUE16" --repo-dir "$clone_c" --remote origin \
  --takeover >/dev/null 2>"$tmp/err-16-unknown-bare" || rc_16_unknown_bare=$?
check "trap16: an unreadable pull-request head without --pr-head exits 2" "2" "$rc_16_unknown_bare"
check "trap16: an unreadable pull-request head never reads as an issue" "$stale16" "$(tip16)"

# A listing that READS but leaves refs out is not proof of an issue either. The
# only thing that can show a listing is whole is that it holds what is known to
# be there, so one that does not show the claim tip just read proves nothing
# about the pull-request head.
rc_16_partial=0
TRAP16_READS=omit-claim PATH="$shim_dir_16:$PATH" "$tool" acquire "$ISSUE16" --repo-dir "$clone_c" \
  --remote origin --takeover >/dev/null 2>"$tmp/err-16-partial" || rc_16_partial=$?
if [[ -f "$tmp/trap16-read-omit-claim" ]]; then
  pass "trap16: fixture — the listing left out the claim tip"
else
  fail "trap16: fixture — the listing was never read"
fi
check "trap16: a listing that leaves out the claim tip exits 2" "2" "$rc_16_partial"
check "trap16: a listing that leaves out the claim tip leaves it in place" "$stale16" "$(tip16)"
if grep -q 'UNKNOWN' "$tmp/err-16-partial" && grep -q 'do not show the claim tip' "$tmp/err-16-partial"; then
  pass "trap16: a listing that leaves out the claim tip is reported as UNKNOWN"
else
  fail "trap16: a listing that leaves out the claim tip is reported as UNKNOWN"
fi
# With every pull-request head left out, this pull request reads like an issue
# to a helper that trusts an empty answer.
rc_16_hidden=0
TRAP16_READS=no-pulls PATH="$shim_dir_16:$PATH" "$tool" acquire "$ISSUE16" --repo-dir "$clone_c" \
  --remote origin --takeover >/dev/null 2>"$tmp/err-16-hidden" || rc_16_hidden=$?
if [[ -f "$tmp/trap16-read-no-pulls" ]]; then
  pass "trap16: fixture — the listing left out every pull-request head"
else
  fail "trap16: fixture — the listing was never read"
fi
check "trap16: a pull request whose head the listing leaves out exits 2" "2" "$rc_16_hidden"
check "trap16: a pull request whose head the listing leaves out is not taken over as an issue" \
  "$stale16" "$(tip16)"

# Naming the current head takes the tip over although a commit landed after it.
rc_16_take=0
"$tool" acquire "$ISSUE16" --repo-dir "$clone_c" --remote origin --takeover --pr-head "$head16_v2" \
  >"$tmp/out-16-take" 2>"$tmp/err-16-take" || rc_16_take=$?
sha_16="$(tail -n1 "$tmp/out-16-take")"
check "trap16: takeover naming the current head exits 0" "0" "$rc_16_take"
check "trap16: takeover stdout is exactly the acquired sha" "$sha_16" "$(cat "$tmp/out-16-take")"
check "trap16: the tip is the takeover's" "$sha_16" "$(tip16)"
subject_16=""
if [[ "$sha_16" =~ ^[0-9a-f]{40}$ ]]; then
  git -C "$clone_b" fetch --quiet origin "+${claim16}:refs/trap16/claim"
  subject_16="$(git -C "$clone_b" log -1 --format=%s refs/trap16/claim)"
fi
case "$subject_16" in
  *" takeover-pr-head=${head16_v2}") pass "trap16: the claim commit records the head that was re-read" ;;
  *) fail "trap16: the claim commit records the head that was re-read (subject '$subject_16')" ;;
esac

# Naming the head never replaces the lease: the fresh takeover is a live claim.
rc_16_live=0
"$tool" acquire "$ISSUE16" --repo-dir "$clone_a" --remote origin --takeover --pr-head "$head16_v2" \
  >/dev/null 2>"$tmp/err-16-live" || rc_16_live=$?
check "trap16: the current head does not take over a live claim" "1" "$rc_16_live"
check "trap16: the live claim survives" "$sha_16" "$(tip16)"

# The defined path to clear a leftover tip: take it over, then retire it.
if [[ "$sha_16" =~ ^[0-9a-f]{40}$ ]]; then
  "$tool" retire "$ISSUE16" "$sha_16" --repo-dir "$clone_c" --remote origin >/dev/null 2>&1 || true
fi
check "trap16: retiring the takeover clears the lock" "" "$(tip16)"

# The head is checked and recorded whether or not a tip is still there: the
# holder may retire between the caller's staleness read and its takeover.
rc_16_gone_old=0
"$tool" acquire "$ISSUE16" --repo-dir "$clone_c" --remote origin --takeover --pr-head "$head16_v1" \
  >/dev/null 2>&1 || rc_16_gone_old=$?
check "trap16: with no tip left, a head that has moved is still refused" "1" "$rc_16_gone_old"
check "trap16: the refused takeover of a free number creates no claim" "" "$(tip16)"
rc_16_gone=0
sha_16_gone="$("$tool" acquire "$ISSUE16" --repo-dir "$clone_c" --remote origin --takeover \
  --pr-head "$head16_v2" 2>/dev/null)" || rc_16_gone=$?
check "trap16: with no tip left, the current head acquires the claim" "0" "$rc_16_gone"
subject_16_gone=""
if [[ "$sha_16_gone" =~ ^[0-9a-f]{40}$ ]]; then
  subject_16_gone="$(git -C "$clone_c" log -1 --format=%s "$sha_16_gone")"
  "$tool" retire "$ISSUE16" "$sha_16_gone" --repo-dir "$clone_c" --remote origin >/dev/null 2>&1 || true
fi
case "$subject_16_gone" in
  *" takeover-pr-head=${head16_v2}") pass "trap16: that claim records the head too" ;;
  *) fail "trap16: that claim records the head too (subject '$subject_16_gone')" ;;
esac

# An issue number has no pull-request head, so --pr-head is a mistake there and
# never a way to skip the gate. A branch whose name merely ends in the pull ref
# matches the same ls-remote pattern and must not read as a pull request.
ISSUE16I=1617
claim16i="refs/heads/agent-claim/${ISSUE16I}"
tip16i() { git -C "$clone_c" ls-remote origin "$claim16i" | awk '{print $1}'; }
stale16i="$(GIT_AUTHOR_DATE="$old_claim_time" GIT_COMMITTER_DATE="$old_claim_time" \
  git -C "$clone_b" commit-tree "${base16}^{tree}" -p "$base16" \
    -m "chore: stale agent-claim #${ISSUE16I}")"
git -C "$clone_b" push --quiet origin "${stale16i}:${claim16i}"
git -C "$clone_b" push --quiet origin "${head16_v2}:refs/heads/decoy/refs/pull/${ISSUE16I}/head"
check "trap16: fixture — a decoy branch matches the pull-ref pattern" "1" \
  "$(git -C "$clone_c" ls-remote origin "refs/pull/${ISSUE16I}/head" | grep -c . || true)"
rc_16_issue=0
"$tool" acquire "$ISSUE16I" --repo-dir "$clone_c" --remote origin --takeover --pr-head "$head16_v2" \
  >/dev/null 2>"$tmp/err-16-issue" || rc_16_issue=$?
check "trap16: --pr-head on an issue number exits 2" "2" "$rc_16_issue"
check "trap16: --pr-head on an issue number leaves the tip in place" "$stale16i" "$(tip16i)"
if grep -q 'not a pull request' "$tmp/err-16-issue"; then
  pass "trap16: --pr-head on an issue number is refused as not a pull request"
else
  fail "trap16: --pr-head on an issue number is refused as not a pull request"
fi
# A number is taken for an issue only when the remote shows pull-request heads
# and this is not one of them. A remote that shows none proves nothing, and
# neither does a listing that cannot be read.
rm -f "$tmp/trap16-read-no-pulls" "$tmp/trap16-read-fail"
rc_16_none=0
TRAP16_READS=no-pulls PATH="$shim_dir_16:$PATH" "$tool" acquire "$ISSUE16I" --repo-dir "$clone_c" \
  --remote origin --takeover >/dev/null 2>"$tmp/err-16-none" || rc_16_none=$?
if [[ -f "$tmp/trap16-read-no-pulls" ]]; then
  pass "trap16: fixture — the listing showed no pull-request head"
else
  fail "trap16: fixture — the listing was never read"
fi
check "trap16: a remote that shows no pull-request head exits 2" "2" "$rc_16_none"
check "trap16: a remote that shows no pull-request head leaves the tip in place" "$stale16i" "$(tip16i)"
if grep -q 'UNKNOWN' "$tmp/err-16-none" && grep -q 'no pull-request head for any number' "$tmp/err-16-none"; then
  pass "trap16: a remote that shows no pull-request head is reported as UNKNOWN"
else
  fail "trap16: a remote that shows no pull-request head is reported as UNKNOWN"
fi
rc_16_listfail=0
TRAP16_READS=fail PATH="$shim_dir_16:$PATH" "$tool" acquire "$ISSUE16I" --repo-dir "$clone_c" \
  --remote origin --takeover >/dev/null 2>&1 || rc_16_listfail=$?
if [[ -f "$tmp/trap16-read-fail" ]]; then
  pass "trap16: fixture — the listing failed for an issue number"
else
  fail "trap16: fixture — the listing was never read for an issue number"
fi
check "trap16: an unreadable listing exits 2 for an issue number" "2" "$rc_16_listfail"
check "trap16: an unreadable listing leaves an issue number's tip in place" "$stale16i" "$(tip16i)"

rc_16_issue_take=0
sha_16i="$("$tool" acquire "$ISSUE16I" --repo-dir "$clone_c" --remote origin --takeover 2>/dev/null)" ||
  rc_16_issue_take=$?
check "trap16: an issue-number takeover needs no head" "0" "$rc_16_issue_take"
check "trap16: the issue-number tip is the takeover's" "$sha_16i" "$(tip16i)"
if [[ "$sha_16i" =~ ^[0-9a-f]{40}$ ]]; then
  "$tool" retire "$ISSUE16I" "$sha_16i" --repo-dir "$clone_c" --remote origin >/dev/null 2>&1 || true
fi
git -C "$clone_b" push --quiet --delete origin "decoy/refs/pull/${ISSUE16I}/head" >/dev/null 2>&1 || true

# --pr-head is a takeover argument and a full SHA: anything else is a usage
# error that creates no claim.
ISSUE16U=1618
tip16u() { git -C "$clone_c" ls-remote origin "refs/heads/agent-claim/${ISSUE16U}" | awk '{print $1}'; }
rc_16_notake=0
"$tool" acquire "$ISSUE16U" --repo-dir "$clone_c" --remote origin --pr-head "$head16_v2" \
  >/dev/null 2>&1 || rc_16_notake=$?
check "trap16: --pr-head without --takeover exits 2" "2" "$rc_16_notake"
rc_16_short=0
"$tool" acquire "$ISSUE16U" --repo-dir "$clone_c" --remote origin --takeover --pr-head "${head16_v2:0:12}" \
  >/dev/null 2>&1 || rc_16_short=$?
check "trap16: an abbreviated --pr-head exits 2" "2" "$rc_16_short"
rc_16_empty=0
"$tool" acquire "$ISSUE16U" --repo-dir "$clone_c" --remote origin --takeover --pr-head \
  >/dev/null 2>&1 || rc_16_empty=$?
check "trap16: --pr-head without a value exits 2" "2" "$rc_16_empty"
check "trap16: no usage error creates a claim" "" "$(tip16u)"

# ---------------------------------------------------------------------------
test_run_finished=1
if (( failures > 0 )); then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall agent-claim traps passed\n'
exit 0
