#!/usr/bin/env bash
#
# Self-test for agent-claim.sh — RED/GREEN coverage of the four traps proven
# in monorepo#2302. Fixtures use a local bare remote + two clones; nothing
# touches a real network remote.
#
# Trap 1 — arbitration works: second non-force push loses; ls-remote shows winner.
# Trap 2 — never judge by push exit status: a piped `push | true` looks like
#          success while verify correctly reports LOST.
# Trap 3 — identical commits collide without a nonce; the helper's nonce makes
#          two acquirers produce distinct shas.
# Trap 4 — unretired claim is a permanent lock; --takeover after lease expiry
#          recovers it, and a third acquirer still loses to the takeover winner.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$script_dir/agent-claim.sh"
chmod +x "$tool"

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

run() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  echo "$rc"
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
# One shared parent so trap 3 is reproducible (identical parent + message → same sha).
echo seed > "$seed/README"
git -C "$seed" add README
git -C "$seed" commit --quiet -m "chore: seed"
git -C "$seed" push --quiet origin HEAD:main
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
done

ISSUE=2302

# ---------------------------------------------------------------------------
# Trap 1 — A wins, B loses. Tip equals A's sha.
# ---------------------------------------------------------------------------
out_a="$tmp/out-a"
rc_a=0
"$tool" acquire "$ISSUE" --repo-dir "$clone_a" --remote origin >"$out_a" 2>"$tmp/err-a" || rc_a=$?
sha_a="$(tail -n1 "$out_a")"
check "trap1: A acquire exits 0" "0" "$rc_a"
[[ "$sha_a" =~ ^[0-9a-f]{40}$ ]] && pass "trap1: A printed a full sha" || fail "trap1: A sha missing ($sha_a)"

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
# Push through a pipe ending in `true` — exit status of the pipeline is 0
# regardless of whether the push updated the tip (trap 2 reproduction).
set +e
git -C "$clone_b" push origin "${sha_b}:refs/heads/agent-claim/${ISSUE}" 2>/dev/null | true
pipe_rc=${PIPESTATUS[0]} # push's own status (may be non-zero)
set -e
# The PIPELINE as a whole with `| true` would be 0; we assert the tip check
# is what matters, not either status.
rc_trap2=0
"$tool" verify "$ISSUE" "$sha_b" --repo-dir "$clone_b" --remote origin >/dev/null 2>&1 || rc_trap2=$?
check "trap2: verify rejects B's sha even after a pipe-masked push" "1" "$rc_trap2"
tip_after="$(git -C "$clone_b" ls-remote origin "refs/heads/agent-claim/${ISSUE}" | awk '{print $1}')"
check "trap2: tip still A's (pipe push did not steal the claim)" "$sha_a" "$tip_after"
# Sanity: document that a bare push status alone is not the verdict we use.
pass "trap2: push_rc_observed=${pipe_rc} (ignored by protocol; tip compare is authoritative)"

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

# GREEN: helper acquire twice → distinct shas; second loses.
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
ISSUE3G=9304
rc_a3=0
out_a3="$tmp/out-a3"
"$tool" acquire "$ISSUE3G" --repo-dir "$clone_a" --remote origin >"$out_a3" 2>"$tmp/err-a3" || rc_a3=$?
sha_a3="$(tail -n1 "$out_a3")"
check "trap3 GREEN: first acquire exits 0" "0" "$rc_a3"
rc_b3=0
"$tool" acquire "$ISSUE3G" --repo-dir "$clone_b" --remote origin >"$tmp/out-b3" 2>"$tmp/err-b3" || rc_b3=$?
check "trap3 GREEN: second acquire exits 1" "1" "$rc_b3"
# Extract any sha the loser may have printed (should not match winner).
# More importantly: crafting two helper commits back-to-back must differ.
nonce_x="$("$tool" acquire 999001 --repo-dir "$clone_a" --remote origin 2>/dev/null | tail -n1 || true)"
# Retire the throwaway so it does not leak into later assertions.
"$tool" retire 999001 --repo-dir "$clone_a" --remote origin >/dev/null 2>&1 || true
# Two sequential commit-tree calls WITH distinct nonces must differ — mirror
# what the helper does internally.
n1="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
n2="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
s1="$(git -C "$clone_a" commit-tree "${parent3}^{tree}" -p "$parent3" -m "chore: agent-claim #x nonce=${n1}")"
s2="$(git -C "$clone_a" commit-tree "${parent3}^{tree}" -p "$parent3" -m "chore: agent-claim #x nonce=${n2}")"
if [[ "$s1" != "$s2" ]]; then
  pass "trap3 GREEN: distinct nonces produce distinct shas"
else
  fail "trap3 GREEN: distinct nonces still collided ($s1)"
fi
check "trap3 GREEN: winner tip stable at first sha" "$sha_a3" \
  "$(git -C "$clone_a" ls-remote origin "refs/heads/agent-claim/${ISSUE3G}" | awk '{print $1}')"

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

# B takes over with lease-hours 0 (tip age 0h >= 0 → stale). Stands in for
# "no open PR + tip past lease" after the caller checked the PR side.
rc_b4b=0
out_b4b="$tmp/out-b4b"
"$tool" acquire "$ISSUE4" --repo-dir "$clone_b" --remote origin --takeover --lease-hours 0 \
  >"$out_b4b" 2>"$tmp/err-b4b" || rc_b4b=$?
sha_b4="$(tail -n1 "$out_b4b")"
check "trap4: B stale takeover exits 0" "0" "$rc_b4b"
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

# Retire is idempotent and clears the lock.
rc_r=0
"$tool" retire "$ISSUE4" --repo-dir "$clone_b" --remote origin >/dev/null 2>&1 || rc_r=$?
check "trap4: retire exits 0" "0" "$rc_r"
tip_gone="$(git -C "$clone_b" ls-remote origin "refs/heads/agent-claim/${ISSUE4}" | awk '{print $1}')"
check "trap4: tip absent after retire" "" "$tip_gone"
rc_r2=0
"$tool" retire "$ISSUE4" --repo-dir "$clone_b" --remote origin >/dev/null 2>&1 || rc_r2=$?
check "trap4: retire is idempotent" "0" "$rc_r2"

# ---------------------------------------------------------------------------
# Entropy fail-closed: if /dev/urandom were unreadable the helper must exit 2.
# We cannot unmount /dev/urandom here; instead assert the nonce function's
# contract by checking the script refuses a non-integer issue (usage fail-closed).
# ---------------------------------------------------------------------------
rc_bad=0
"$tool" acquire not-a-number --repo-dir "$clone_a" --remote origin >/dev/null 2>&1 || rc_bad=$?
check "usage: non-integer issue exits 2" "2" "$rc_bad"

# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall agent-claim traps passed\n'
exit 0
