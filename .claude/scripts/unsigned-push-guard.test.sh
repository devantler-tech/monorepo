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

# The same identity with no allowed-signers file: git cannot run SSH verification at all.
noverify="$tmp/gitconfig-noverify"
cat >"$noverify" <<EOF
[user]
	name = fixture
	email = fixture@example.com
[gpg]
	format = ssh
[init]
	defaultBranch = main
EOF

unsigned_commit() { git -C "$1" -c commit.gpgsign=false commit -q --allow-empty -m "$2"; }
signed_commit() { git -C "$1" -c commit.gpgsign=true -c user.signingkey="$tmp/key" commit -q --allow-empty -m "$2"; }

# tampered_commit <repo> — rewrite HEAD's message under its original signature, so the header
# is present but the signature no longer matches the object.
tampered_commit() {
  local forged
  forged="$(git -C "$1" cat-file commit HEAD | sed 's/^original$/tampered/' |
    git -C "$1" hash-object -t commit -w --stdin)"
  git -C "$1" update-ref HEAD "$forged"
}

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

# 7. A host that cannot verify SSH signatures (no allowed-signers file) reports N for a signed
#    commit. The signature header decides it: the signed commit passes, the unsigned one does not.
pre_nv="$(new_repo pre-noverify)"
signed_commit "$pre_nv" s
nv_class="$(GIT_CONFIG_GLOBAL="$noverify" git -C "$pre_nv" log --format='%G?' base..HEAD 2>/dev/null)"
if [ "$nv_class" = "N" ]; then pass "precondition: unverifiable SSH signature yields N"; else bad "precondition: expected N, got '$nv_class'"; fi

r7="$(new_repo noverify)"
signed_commit "$r7" signed
sha7="$(git -C "$r7" rev-parse HEAD)"
run "unverifiable signature passes" 0 env GIT_CONFIG_GLOBAL="$noverify" "$guard" "$r7" base
case "$out" in *"UNVERIFIED $sha7"*) pass "unverifiable signature is named" ;; *) bad "unverifiable sha not named: $out" ;; esac
case "$out" in *"findings=0 unverified=1"*) pass "unverifiable signature is counted, not a finding" ;; *) bad "summary missing: $out" ;; esac

unsigned_commit "$r7" unsigned
sha7u="$(git -C "$r7" rev-parse HEAD)"
run "unsigned commit still fails where signatures cannot be verified" 1 env GIT_CONFIG_GLOBAL="$noverify" "$guard" "$r7" base
case "$out" in *"UNSIGNED  $sha7u"*) pass "unverifiable host still names the unsigned commit" ;; *) bad "unsigned sha not named: $out" ;; esac

# 8. Only the header block counts — a message line starting with "gpgsig " is not a signature.
r8="$(new_repo message-lookalike)"
git -C "$r8" -c commit.gpgsign=false commit -q --allow-empty -m subject -m 'gpgsig -----BEGIN SSH SIGNATURE-----'
run "signature text in the message is not a signature" 1 env GIT_CONFIG_GLOBAL="$noverify" "$guard" "$r8" base

# 9. A signature that verifies as bad is still a finding.
r9="$(new_repo bad-sig)"
signed_commit "$r9" original
tampered_commit "$r9"
sha9="$(git -C "$r9" rev-parse HEAD)"
bad_class="$(git -C "$r9" log -1 --format='%G?' 2>/dev/null)"
if [ "$bad_class" = "B" ]; then pass "precondition: tampered commit yields B"; else bad "precondition: expected B, got '$bad_class'"; fi
run "bad signature fails" 1 "$guard" "$r9" base
case "$out" in *"BAD-SIG   $sha9"*) pass "bad signature is named" ;; *) bad "bad-signature sha not named: $out" ;; esac

# 10. Ablations — each must flip its fixture, proving the case above fails or passes for the
#     reason it claims rather than an incidental one.
ablated="$tmp/ablated-guard.sh"
sed "/printf 'UNSIGNED /s/findings=\$((findings + 1)); //" "$guard" >"$ablated"
chmod +x "$ablated"
if cmp -s "$guard" "$ablated"; then
  bad "ablation did not change the guard (the UNSIGNED branch moved?)"
else
  run "ablated guard passes the unsigned fixture" 0 "$ablated" "$r1" base
fi

header_ablated="$tmp/header-ablated-guard.sh"
# shellcheck disable=SC2016 # the pattern is the guard's literal source text.
sed 's/if has_signature_header "\$sha"; then/if false; then/' "$guard" >"$header_ablated"
chmod +x "$header_ablated"
if cmp -s "$guard" "$header_ablated"; then
  bad "header ablation did not change the guard (the header check moved?)"
else
  git -C "$r7" update-ref HEAD "$sha7"
  run "reverting to %G? alone fails the unverifiable signature" 1 env GIT_CONFIG_GLOBAL="$noverify" "$header_ablated" "$r7" base
fi

if [ "$fail" -eq 0 ]; then
  printf 'unsigned-push-guard.test.sh: all cases passed\n'
else
  printf 'unsigned-push-guard.test.sh: FAILURES\n'
  exit 1
fi
