#!/usr/bin/env bash
#
# Self-test for agent-claim.sh — RED/GREEN coverage of the eleven traps proven
# by monorepo#2302 and its review rounds. Fixtures use a local bare remote + two clones; nothing
# touches a real network remote.
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

# B takes over with lease-hours 0 (tip age 0h >= 0 → stale). Stands in for
# "no open PR + tip past lease" after the caller checked the PR side.
rc_b4b=0
out_b4b="$tmp/out-b4b"
"$tool" acquire "$ISSUE4" --repo-dir "$clone_b" --remote origin --takeover --lease-hours 0 \
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
if (( failures > 0 )); then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall agent-claim traps passed\n'
exit 0
