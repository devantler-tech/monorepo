#!/usr/bin/env bash
#
# Self-test for agent-claim-sweep.sh (monorepo#3589). A local bare remote holds
# claim tips; a fake `gh` on PATH answers issue states. Nothing touches the
# network.
#
# Cases: closed → removed; open → kept; unreadable issue → kept + exit 2;
# unexpected state → kept + exit 2; a tip re-acquired between the issue read
# and the delete → survives + exit 1; dry-run deletes nothing; a failed remote
# listing → exit 2, never "no tips".
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$script_dir/agent-claim-sweep.sh"

tmp="$(mktemp -d)"
completed=0
# The completion flag keeps an aborted run from reporting success through the
# cleanup trap.
trap 'rm -rf "$tmp"; [[ $completed == 1 ]] || exit 1' EXIT

failures=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

bare="$tmp/remote.git"
git init --bare --quiet "$bare"
work="$tmp/work"
git clone --quiet "$bare" "$work" 2>/dev/null
git -C "$work" config user.email sweep-test@example.com
git -C "$work" config user.name sweep-test
git -C "$work" config commit.gpgsign false
# The sweep binds --repo to the remote's EFFECTIVE URLs. Route a GitHub URL to
# the local bare remote and vouch for that local path explicitly — the only way
# a non-GitHub effective URL is accepted.
git -C "$work" remote set-url origin https://github.com/devantler-tech/example.git
git -C "$work" config "url.$bare.insteadOf" https://github.com/devantler-tech/example.git
export AGENT_CLAIM_SWEEP_TRUSTED_REMOTE="$bare=devantler-tech/example"
git -C "$work" commit --quiet --allow-empty -m seed
git -C "$work" push --quiet origin HEAD:refs/heads/main

new_tip() { # <issue> — push a fresh commit to agent-claim/<issue>, print its sha
  local sha
  sha="$(git -C "$work" commit-tree -m "claim $1 $RANDOM$RANDOM" "$(git -C "$work" rev-parse 'HEAD^{tree}')")"
  git -C "$work" push --quiet --force origin "$sha:refs/heads/agent-claim/$1"
  echo "$sha"
}
remote_tip() { git --git-dir="$bare" rev-parse --verify --quiet "refs/heads/agent-claim/$1" || true; }

# Fake gh: `gh api repos/<o>/<r>/issues/<n> --jq .state`. The state for issue n
# comes from $tmp/state/<n>; a missing file is a failed read. Issue 5 moves its
# own claim tip first, simulating a re-acquire between the read and the delete.
mkdir -p "$tmp/bin" "$tmp/state"
cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
[[ "\$2" == repos/devantler-tech/example/issues/* ]] || { echo "unexpected request \$2" >&2; exit 1; }
n="\${2##*/}"
if [[ "\$n" == 5 ]]; then
  sha="\$(git -C "$work" commit-tree -m "reacquire 5" "\$(git -C "$work" rev-parse 'HEAD^{tree}')")"
  git -C "$work" push --quiet --force origin "\$sha:refs/heads/agent-claim/5"
fi
[[ -f "$tmp/state/\$n" ]] || { echo "HTTP 502" >&2; exit 1; }
cat "$tmp/state/\$n"
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

run() { # <args…> — sets out and rc
  rc=0
  out="$("$tool" --repo devantler-tech/example --repo-dir "$work" "$@" 2>&1)" || rc=$?
}

# --- dry-run deletes nothing -------------------------------------------------
t1="$(new_tip 1)"; echo closed >"$tmp/state/1"
t2="$(new_tip 2)"; echo open >"$tmp/state/2"
run
check "dry-run exit 0" 0 "$rc"
check "dry-run reports the closed tip" 1 "$(grep -c "^WOULD-REMOVE 1 closed $t1$" <<<"$out")"
check "dry-run keeps the closed tip" "$t1" "$(remote_tip 1)"

# --- apply: closed removed, open kept ----------------------------------------
run --apply
check "apply exit 0" 0 "$rc"
check "closed tip removed" "" "$(remote_tip 1)"
check "open tip kept" "$t2" "$(remote_tip 2)"
check "open tip reported" 1 "$(grep -c '^KEEP 2 open$' <<<"$out")"

# --- an unreadable issue is never read as closed -----------------------------
t3="$(new_tip 3)"   # no state file → the fake gh fails
run --apply
check "failed read exits 2" 2 "$rc"
check "failed-read tip kept" "$t3" "$(remote_tip 3)"
check "failed read reported" 1 "$(grep -c '^UNKNOWN 3 issue read failed$' <<<"$out")"
git -C "$work" push --quiet origin ":refs/heads/agent-claim/3"

# --- an unexpected state is never read as closed -----------------------------
t4="$(new_tip 4)"; echo "" >"$tmp/state/4"
run --apply
check "unexpected state exits 2" 2 "$rc"
check "unexpected-state tip kept" "$t4" "$(remote_tip 4)"
git -C "$work" push --quiet origin ":refs/heads/agent-claim/4"

# --- a tip re-acquired after the read survives (compare-and-swap) ------------
t5="$(new_tip 5)"; echo closed >"$tmp/state/5"
run --apply
check "raced removal exits 1" 1 "$rc"
check "raced removal reported" 1 "$(grep -c "^RACED 5 $t5$" <<<"$out")"
after5="$(remote_tip 5)"
if [[ -n "$after5" && "$after5" != "$t5" ]]; then pass "re-acquired tip survives"; else fail "re-acquired tip survives (tip '$after5')"; fi
git -C "$work" push --quiet origin ":refs/heads/agent-claim/5"

# --- a failed listing is not "no tips" ---------------------------------------
rc=0
out="$("$tool" --repo devantler-tech/example --repo-dir "$work" --remote nowhere 2>&1)" || rc=$?
check "failed listing exits 2" 2 "$rc"

# --- --repo must name the repository the tips live in --------------------------
t6="$(new_tip 6)"; echo closed >"$tmp/state/6"
rc=0
out="$("$tool" --repo devantler-tech/other --repo-dir "$work" --apply 2>&1)" || rc=$?
check "mismatched --repo exits 2" 2 "$rc"
check "mismatched --repo deletes nothing" "$t6" "$(remote_tip 6)"
run --apply
check "matching --repo removes the closed tip" "" "$(remote_tip 6)"

# --- deletions must go where the listing came from -----------------------------
# A push URL that differs from the fetch URL (remote.<r>.pushurl or
# url.*.pushInsteadOf) would judge one repository's tips and delete another's.
other="$tmp/other.git"
git init --quiet --bare "$other"
t7="$(new_tip 7)"; echo closed >"$tmp/state/7"
git -C "$work" config remote.origin.pushurl "$other"
rc=0
out="$("$tool" --repo devantler-tech/example --repo-dir "$work" --apply 2>&1)" || rc=$?
check "diverging pushurl exits 2" 2 "$rc"
check "diverging pushurl deletes nothing" "$t7" "$(remote_tip 7)"
git -C "$work" config --unset remote.origin.pushurl
git -C "$work" config "url.$other.pushInsteadOf" https://github.com/devantler-tech/example.git
rc=0
out="$("$tool" --repo devantler-tech/example --repo-dir "$work" --apply 2>&1)" || rc=$?
check "diverging pushInsteadOf exits 2" 2 "$rc"
check "diverging pushInsteadOf deletes nothing" "$t7" "$(remote_tip 7)"
git -C "$work" config --unset "url.$other.pushInsteadOf"
git -C "$work" config remote.origin.pushurl https://github.com/devantler-tech/other.git
rc=0
out="$("$tool" --repo devantler-tech/example --repo-dir "$work" --apply 2>&1)" || rc=$?
check "pushurl naming another GitHub repo exits 2" 2 "$rc"
check "pushurl naming another GitHub repo deletes nothing" "$t7" "$(remote_tip 7)"
git -C "$work" config --unset remote.origin.pushurl
run --apply
check "matching push destination removes the closed tip" "" "$(remote_tip 7)"

# --- a non-GitHub effective URL has no identity unless explicitly vouched for --
t8="$(new_tip 8)"; echo closed >"$tmp/state/8"
rc=0
out="$(env -u AGENT_CLAIM_SWEEP_TRUSTED_REMOTE "$tool" --repo devantler-tech/example --repo-dir "$work" --apply 2>&1)" || rc=$?
check "unvouched local target exits 2" 2 "$rc"
check "unvouched local target deletes nothing" "$t8" "$(remote_tip 8)"

# --- a delete that fails for a reason other than a race is FAILED, not RACED ---
cat >"$tmp/bin/retire-fails" <<'EOF'
#!/usr/bin/env bash
echo "agent-claim: push could not be confirmed" >&2
exit 2
EOF
chmod +x "$tmp/bin/retire-fails"
rc=0
out="$(AGENT_CLAIM_TOOL="$tmp/bin/retire-fails" "$tool" --repo devantler-tech/example --repo-dir "$work" --apply 2>&1)" || rc=$?
check "failed delete exits 1" 1 "$rc"
check "failed delete reported as FAILED" 1 "$(grep -c "^FAILED 8 $t8$" <<<"$out")"
check "failed delete keeps its diagnostics" 1 "$(grep -c 'push could not be confirmed' <<<"$out")"
check "failed delete is not reported as RACED" 0 "$(grep -c '^RACED 8' <<<"$out" || true)"
run --apply
check "vouched local target removes the closed tip" "" "$(remote_tip 8)"

# --- usage --------------------------------------------------------------------
rc=0
"$tool" --repo not-a-slug --repo-dir "$work" >/dev/null 2>&1 || rc=$?
check "malformed --repo exits 2" 2 "$rc"

completed=1
if ((failures > 0)); then
  echo "agent-claim-sweep.test: $failures failure(s)"
  exit 1
fi
echo "agent-claim-sweep.test: all passed"
