#!/usr/bin/env bash
#
# Self-test for unsigned-push-guard.sh (monorepo#3322).
#
# Fixtures are throwaway repositories under mktemp. Signed commits use a generated SSH key with
# an allowed-signers file, so the GREEN cases need no GPG agent or keychain and run the same way
# in CI as on the agent host. Every fixture commit states its signing setting explicitly, so the
# result never depends on the global git configuration of whoever runs the test.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/unsigned-push-guard.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

ssh-keygen -q -t ed25519 -N '' -f "$tmp/key" -C fixture
printf 'fixture@example.com %s\n' "$(cat "$tmp/key.pub")" >"$tmp/allowed"

# Isolate every git call from the caller's global and system config.
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
cat >"$GIT_CONFIG_GLOBAL" <<EOF
[user]
	name = fixture
	email = fixture@example.com
[gpg]
	format = ssh
[gpg "ssh"]
	allowedSignersFile = $tmp/allowed
[init]
	defaultBranch = main
EOF

unsigned_commit() { git -C "$1" -c commit.gpgsign=false commit -q --allow-empty -m "$2"; }
signed_commit() { git -C "$1" -c commit.gpgsign=true -c user.signingkey="$tmp/key" commit -q --allow-empty -m "$2"; }

# run <name> <expected-exit> <command...> — records output in $out
run() {
  local name="$1" want="$2"; shift 2
  set +e
  out="$("$@" 2>&1)"
  got=$?
  set -e
  if [ "$got" -eq "$want" ]; then pass "$name (exit $got)"; else bad "$name: want exit $want, got $got — $out"; fi
}

new_repo() {
  local r="$tmp/$1"
  git init -q "$r"
  signed_commit "$r" base
  git -C "$r" branch -q base
  printf '%s' "$r"
}

# Precondition: the fixture really produces both classes, so the cases below test the guard
# rather than a host that silently signs or silently cannot.
pre="$(new_repo pre)"
unsigned_commit "$pre" u
signed_commit "$pre" s
classes="$(git -C "$pre" log --format='%G?' base..HEAD | tr -d '\n')"
if [ "$classes" = "GN" ]; then pass "precondition: fixture yields G and N"; else bad "precondition: expected GN, got '$classes'"; fi

# 1. RED — a single unsigned commit is named and fails.
r1="$(new_repo red)"
unsigned_commit "$r1" unsigned
sha1="$(git -C "$r1" rev-parse HEAD)"
run "unsigned commit fails" 1 "$guard" "$r1" base
case "$out" in *"UNSIGNED  $sha1"*) pass "unsigned commit is named" ;; *) bad "unsigned sha not named: $out" ;; esac

# 2. GREEN — signed commits pass.
r2="$(new_repo green)"
signed_commit "$r2" one
signed_commit "$r2" two
run "signed commits pass" 0 "$guard" "$r2" base
case "$out" in *"examined=2 findings=0"*) pass "signed range states what it examined" ;; *) bad "summary missing: $out" ;; esac

# 3. Mixed — only the unsigned commit is named, the signed ones are not.
r3="$(new_repo mixed)"
signed_commit "$r3" a
unsigned_commit "$r3" b
sha3="$(git -C "$r3" rev-parse HEAD)"
signed_commit "$r3" c
run "mixed range fails" 1 "$guard" "$r3" base
n_named="$(printf '%s\n' "$out" | awk '/^UNSIGNED /{n++} END{print n+0}')"
case "$out" in *"UNSIGNED  $sha3"*) pass "mixed range names the unsigned commit" ;; *) bad "unsigned sha not named: $out" ;; esac
if [ "$n_named" = 1 ]; then pass "mixed range names only that commit"; else bad "named $n_named commits: $out"; fi

# 4. Empty range — passes, and says so rather than printing nothing.
r4="$(new_repo empty)"
run "empty range passes" 0 "$guard" "$r4" base
case "$out" in *"examined=0 findings=0"*) pass "empty range is stated" ;; *) bad "empty range not stated: $out" ;; esac

# 5. UNKNOWN — an unresolvable base or a non-repository is exit 2, never a clean pass.
run "unresolvable base is UNKNOWN" 2 "$guard" "$r1" no-such-ref
run "non-repository is UNKNOWN" 2 "$guard" "$tmp"

# 6. Default base — with no argument and no upstream, origin/main is used; absent, it is UNKNOWN.
run "missing default base is UNKNOWN" 2 "$guard" "$r1"

# 6b. With origin's default branch recorded, it becomes the base before origin/main is tried.
git -C "$r1" update-ref refs/remotes/origin/trunk "$(git -C "$r1" rev-parse base)"
git -C "$r1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
run "origin's default branch is the fallback base" 1 "$guard" "$r1"
case "$out" in *"range=origin/trunk..HEAD"*) pass "fallback resolves origin/HEAD" ;; *) bad "fallback base is not origin/HEAD: $out" ;; esac

# 7. Ablation — a copy that no longer treats N as a finding must PASS the unsigned fixture.
#    This proves case 1 fails because of the N branch, not for some incidental reason.
ablated="$tmp/ablated-guard.sh"
sed 's/^    N) findings=.*$/    N) ;;/' "$guard" >"$ablated"
chmod +x "$ablated"
if cmp -s "$guard" "$ablated"; then
  bad "ablation did not change the guard (the N branch moved?)"
else
  run "ablated guard passes the unsigned fixture" 0 "$ablated" "$r1" base
fi

if [ "$fail" -eq 0 ]; then
  printf 'unsigned-push-guard.test.sh: all cases passed\n'
else
  printf 'unsigned-push-guard.test.sh: FAILURES\n'
  exit 1
fi
