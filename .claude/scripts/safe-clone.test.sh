#!/usr/bin/env bash
#
# Self-test for safe-clone.sh — proves the credential guard DETECTS a remote
# URL carrying userinfo without ever printing the secret, that --sanitize
# strips the userinfo in place, that a clean clone passes, and that the
# argument guards fail closed. Fixtures are local `git init` repos with
# hand-set remote URLs — no network, no real credentials (the fixture secret
# is a synthetic marker string). Run in CI so a refactor that weakens the
# guard or starts echoing URL values is caught here, not by a leaked token.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$here/safe-clone.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Hermetic git environment: the host's real system/global config (which may
# itself carry the very rewrites the guard hunts) must not affect fixtures.
touch "$tmp/gitconfig-clean"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$tmp/gitconfig-clean"

secret="SYNTHETIC-FIXTURE-SECRET-0000"
fail=0

report() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "yes" ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name${detail:+ — $detail}"
    fail=1
  fi
}

mk_fixture() {
  local dir="$1" url="$2"
  git init --quiet "$dir"
  git -C "$dir" remote add origin "$url"
}

# 1. --check fails on a userinfo remote and never prints the secret.
unsafe="$tmp/unsafe"
mk_fixture "$unsafe" "https://x-access-token:${secret}@github.com/example/repo.git"
out="$("$helper" --check "$unsafe" 2>&1)" && rc=0 || rc=$?
report "check detects userinfo remote (exit != 0)" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "check output names the unsafe remote" \
  "$(grep -q "remote.origin.url" <<<"$out" && echo yes || echo no)"
report "check output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 2. --sanitize strips the userinfo, passes the guard, leaks nothing.
# Assert on the RAW stored config value — `remote get-url` applies insteadOf
# rewrites at read time, which is display state, not what is on disk.
out="$("$helper" --sanitize "$unsafe" 2>&1)" && rc=0 || rc=$?
sanitized_url="$(git -C "$unsafe" config remote.origin.url)"
report "sanitize exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)"
report "sanitize leaves a credential-free URL" \
  "$([[ "$sanitized_url" == "https://github.com/example/repo.git" ]] && echo yes || echo no)" \
  "got a rewritten URL that still differs from the canonical form"
report "sanitize output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 3. --check passes a clean clone.
clean="$tmp/clean"
mk_fixture "$clean" "https://github.com/example/repo.git"
out="$("$helper" --check "$clean" 2>&1)" && rc=0 || rc=$?
report "check passes a credential-free clone" "$([[ $rc -eq 0 ]] && echo yes || echo no)"

# 4. Guard covers every remote, not just origin.
multi="$tmp/multi"
mk_fixture "$multi" "https://github.com/example/repo.git"
git -C "$multi" remote add upstream "https://user:${secret}@github.com/example/upstream.git"
out="$("$helper" --check "$multi" 2>&1)" && rc=0 || rc=$?
report "check detects userinfo on a non-origin remote" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "multi-remote check does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 5. SSH-style remotes (no userinfo semantics to leak a token) pass untouched.
ssh="$tmp/ssh"
mk_fixture "$ssh" "git@github.com:example/repo.git"
out="$("$helper" --check "$ssh" 2>&1)" && rc=0 || rc=$?
report "check passes an ssh remote" "$([[ $rc -eq 0 ]] && echo yes || echo no)"

# 6. Environment guard: a credential-bearing insteadOf rewrite in the
# effective config fails --check on an otherwise-clean clone, with the
# secret (which sits in the config KEY) never printed. This pins the actual
# 2026-07-12 incident mechanism.
unsafe_global="$tmp/gitconfig-unsafe"
git config --file "$unsafe_global" \
  "url.https://x-access-token:${secret}@github.com/.insteadOf" \
  "https://github.com/"
out="$(GIT_CONFIG_GLOBAL="$unsafe_global" "$helper" --check "$clean" 2>&1)" && rc=0 || rc=$?
report "env guard fails a clean clone under an unsafe insteadOf rewrite" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "env guard output mentions insteadOf" \
  "$(grep -qi "insteadof" <<<"$out" && echo yes || echo no)"
report "env guard output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 7. Environment guard refuses clone mode up front (nothing gets created).
out="$(GIT_CONFIG_GLOBAL="$unsafe_global" "$helper" example/repo "$tmp/refused" 2>&1)" && rc=0 || rc=$?
report "env guard refuses clone mode" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "refused clone creates nothing" \
  "$([[ ! -e "$tmp/refused" ]] && echo yes || echo no)"
report "refused clone output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 8. A credential-free insteadOf rewrite (legitimate mirror redirect) passes.
benign_global="$tmp/gitconfig-benign"
git config --file "$benign_global" \
  "url.https://mirror.example.com/.insteadOf" "https://github.com/"
out="$(GIT_CONFIG_GLOBAL="$benign_global" "$helper" --check "$clean" 2>&1)" && rc=0 || rc=$?
report "credential-free insteadOf rewrite passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)"

# 9. pushurl is covered like url: detection, sanitize, no leak.
pushu="$tmp/pushurl"
mk_fixture "$pushu" "https://github.com/example/repo.git"
git -C "$pushu" config remote.origin.pushurl "https://x:${secret}@github.com/example/repo.git"
out="$("$helper" --check "$pushu" 2>&1)" && rc=0 || rc=$?
report "check detects userinfo pushurl" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
out="$("$helper" --sanitize "$pushu" 2>&1)" && rc=0 || rc=$?
report "sanitize strips pushurl userinfo" \
  "$([[ $rc -eq 0 && "$(git -C "$pushu" config remote.origin.pushurl)" == "https://github.com/example/repo.git" ]] && echo yes || echo no)"
report "pushurl handling does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 10. Uppercase scheme cannot bypass the userinfo check.
upper="$tmp/upper"
mk_fixture "$upper" "HTTPS://x:${secret}@github.com/example/repo.git"
out="$("$helper" --check "$upper" 2>&1)" && rc=0 || rc=$?
report "check detects uppercase-scheme userinfo remote" "$([[ $rc -ne 0 ]] && echo yes || echo no)"

# 11. pushInsteadOf rewrites are guarded like insteadOf (key side).
pio_global="$tmp/gitconfig-pushinsteadof"
git config --file "$pio_global" \
  "url.https://x:${secret}@github.com/.pushInsteadOf" "https://github.com/"
out="$(GIT_CONFIG_GLOBAL="$pio_global" "$helper" --check "$clean" 2>&1)" && rc=0 || rc=$?
report "env guard fails on credential-bearing pushInsteadOf" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "pushInsteadOf output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 12. A credential in a rewrite VALUE (clean key) is caught too.
vio_global="$tmp/gitconfig-value-rewrite"
git config --file "$vio_global" \
  "url.https://github.com/.insteadOf" "https://x:${secret}@github.com/"
out="$(GIT_CONFIG_GLOBAL="$vio_global" "$helper" --check "$clean" 2>&1)" && rc=0 || rc=$?
report "env guard fails on credential in rewrite value" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "value-rewrite output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 13. http extraHeader (auth-header carrier) fails closed before config diagnostics.
xh_global="$tmp/gitconfig-extraheader"
git config --file "$xh_global" \
  "http.https://github.com/.extraHeader" "AUTHORIZATION: bearer ${secret}"
out="$(GIT_CONFIG_GLOBAL="$xh_global" "$helper" --check "$clean" 2>&1)" && rc=0 || rc=$?
report "env guard fails on http extraHeader" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "extraHeader output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 13b. Credentialed proxy values fail closed before config diagnostics.
px_global="$tmp/gitconfig-proxy"
git config --file "$px_global" http.proxy "https://user:${secret}@proxy.example.com:8080"
out="$(GIT_CONFIG_GLOBAL="$px_global" "$helper" --check "$clean" 2>&1)" && rc=0 || rc=$?
report "env guard fails on credentialed http.proxy" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "proxy output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 13c. Multi-valued pushurl keys sanitize every value without aborting.
multi_push="$tmp/multi-pushurl"
mk_fixture "$multi_push" "https://github.com/example/repo.git"
git -C "$multi_push" config --add remote.origin.pushurl "https://x:${secret}@github.com/example/a.git"
git -C "$multi_push" config --add remote.origin.pushurl "https://github.com/example/b.git"
out="$("$helper" --sanitize "$multi_push" 2>&1)" && rc=0 || rc=$?
report "multi-valued pushurl sanitize exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)"
report "multi-valued pushurl keeps both values credential-free" \
  "$([[ "$(git -C "$multi_push" config --get-all remote.origin.pushurl | tr '\n' ' ')" == "https://github.com/example/a.git https://github.com/example/b.git " ]] && echo yes || echo no)"
report "multi-valued pushurl output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 13d. Clone options outside the safe allowlist are rejected up front.
out="$("$helper" example/repo "$tmp/never3" -c "url.https://x:${secret}@github.com/.insteadOf=https://github.com/" 2>&1)" && rc=0 || rc=$?
report "-c clone option is rejected" \
  "$([[ $rc -ne 0 && ! -e "$tmp/never3" ]] && echo yes || echo no)"
report "rejected -c option does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"
out="$("$helper" example/repo "$tmp/never4" --origin upstream 2>&1)" && rc=0 || rc=$?
report "--origin clone option is rejected" "$([[ $rc -ne 0 && ! -e "$tmp/never4" ]] && echo yes || echo no)"
out="$("$helper" example/repo "$tmp/never5" --separate-git-dir "$tmp/gitdir" 2>&1)" && rc=0 || rc=$?
report "--separate-git-dir clone option is rejected" \
  "$([[ $rc -ne 0 && ! -e "$tmp/never5" && ! -e "$tmp/gitdir" ]] && echo yes || echo no)"

# 14. A rejected slug value is never echoed (it may itself be a secret URL).
out="$("$helper" "https://x:${secret}@github.com/o/r.git" "$tmp/never2" 2>&1)" && rc=0 || rc=$?
report "invalid slug is rejected without echoing it" \
  "$([[ $rc -ne 0 ]] && ! grep -q "$secret" <<<"$out" && echo yes || echo no)"

# 15. Argument guards fail closed.
out="$("$helper" not-a-slug "$tmp/never" 2>&1)" && rc=0 || rc=$?
report "invalid slug is rejected" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
out="$("$helper" --check "$tmp/missing" 2>&1)" && rc=0 || rc=$?
report "check on a non-clone is rejected" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
mkdir -p "$tmp/exists"
out="$("$helper" example/repo "$tmp/exists" 2>&1)" && rc=0 || rc=$?
report "existing destination is rejected" "$([[ $rc -ne 0 ]] && echo yes || echo no)"

# 16. Userinfo containing a raw @ (email-address username) is stripped to the
# LAST @ — no credential remnant may survive in the "sanitized" URL.
at_user="$tmp/at-user"
mk_fixture "$at_user" "https://user@example.com:${secret}@github.com/example/repo.git"
out="$("$helper" --sanitize "$at_user" 2>&1)" && rc=0 || rc=$?
at_url="$(git -C "$at_user" config remote.origin.url)"
report "sanitize strips userinfo containing a raw @ to the last @" \
  "$([[ $rc -eq 0 && "$at_url" == "https://github.com/example/repo.git" ]] && echo yes || echo no)" \
  "sanitized URL still carries a credential remnant"
report "at-userinfo sanitize output does not leak the secret" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 17. env_guard fails CLOSED when the config itself is unreadable — a corrupt
# config must not read as "no rewrites found". The secret sits in the VALID
# prefix before the corrupt line: `git config --list` can emit partial stdout
# before failing, so the failure path must not echo config contents either.
corrupt="$tmp/corrupt"
mk_fixture "$corrupt" "https://github.com/example/repo.git"
printf '[safeclone]\n\tfixturesecret = %s\n[section\n' "$secret" >>"$corrupt/.git/config"
out="$("$helper" --check "$corrupt" 2>&1)" && rc=0 || rc=$?
report "check fails closed on an unreadable git config" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "corrupt-config failure output does not leak config contents" \
  "$(grep -q "$secret" <<<"$out" && echo no || echo yes)"

# 18. A clone failure that has already created a partial destination must not
# leave that unusable checkout behind. Use a fake git binary so the fixture is
# local, deterministic, and exercises the helper's failure path without a
# network request.
fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
# The quoted fixture lines must expand only when the generated fake git runs.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'if [[ "$1" == "config" && "$2" == "--list" ]]; then' \
  '  exit 0' \
  'fi' \
  'if [[ "$1" == "-c" ]]; then' \
  '  dest="${!#}"' \
  '  if [[ "${FAKE_GIT_MODE:-failure}" == "success" ]]; then' \
  '    "${REAL_GIT:?}" init --quiet "$dest"' \
  '    "${REAL_GIT:?}" -C "$dest" remote add origin https://github.com/example/repo.git' \
  '    if [[ -n "${FAKE_GIT_REMOTE_URL:-}" ]]; then' \
  '      "${REAL_GIT:?}" -C "$dest" remote add upstream "$FAKE_GIT_REMOTE_URL"' \
  '    fi' \
  '    exit 0' \
  '  fi' \
  '  mkdir -p "$dest/.git/objects/pack"' \
  '  printf "ref: refs/heads/.invalid\\n" >"$dest/.git/HEAD"' \
  '  printf partial >"$dest/.git/objects/pack/tmp_pack_fixture"' \
  '  if [[ -n "${FAKE_GIT_SECRET:-}" ]]; then' \
  '    printf "clone diagnostic: %s\\n" "$FAKE_GIT_SECRET" >&2' \
  '  fi' \
  '  if [[ "${FAKE_GIT_MODE:-failure}" == "replace" ]]; then' \
  '    mv "$dest" "${dest}.owned"' \
  '    mkdir -p "$dest"' \
  '    printf unrelated >"$dest/sentinel"' \
  '    exit 42' \
  '  fi' \
  '  if [[ "${FAKE_GIT_MODE:-failure}" == "interrupt" ]]; then' \
  '    kill -s "${FAKE_SIGNAL:-TERM}" "$PPID"' \
  '    sleep 0.1' \
  '    exit 143' \
  '  fi' \
  '  exit 42' \
  'fi' \
  'exec "${REAL_GIT:?}" "$@"' >"$fake_bin/git"
chmod +x "$fake_bin/git"
real_git="$(command -v git)"

successful="$tmp/successful-clone"
out="$(FAKE_GIT_MODE=success REAL_GIT="$real_git" PATH="$fake_bin:$PATH" "$helper" example/repo "$successful" 2>&1)" && rc=0 || rc=$?
report "successful clone mode exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)"
report "successful clone mode keeps a valid checkout" \
  "$([[ -d "$successful/.git" ]] && "$helper" --check "$successful" >/dev/null 2>&1 && echo yes || echo no)"

guard_failed="$tmp/post-clone-guard-failure"
unsafe_remote="https://x-access-token:${secret}@github.com/example/repo.git"
out="$(FAKE_GIT_MODE=success FAKE_GIT_REMOTE_URL="$unsafe_remote" REAL_GIT="$real_git" \
  PATH="$fake_bin:$PATH" "$helper" example/repo "$guard_failed" 2>&1)" && rc=0 || rc=$?
report "post-clone credential guard fails clone mode" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)"
guard_quarantine=
for candidate in "$tmp"/.safe-clone-cleanup.*; do
  if [[ -d "$candidate" ]]; then
    guard_quarantine="$candidate"
    break
  fi
done
report "post-clone credential guard removes its destination and quarantine" \
  "$([[ ! -e "$guard_failed" && -z "$guard_quarantine" ]] && echo yes || echo no)"
report "post-clone credential guard output remains redacted" \
  "$(! grep -Eq "https?://|${secret}" <<<"$out" && echo yes || echo no)"

partial="$tmp/partial-clone"
out="$(FAKE_GIT_SECRET="$secret" REAL_GIT="$real_git" PATH="$fake_bin:$PATH" "$helper" example/repo "$partial" 2>&1)" && rc=0 || rc=$?
report "failed clone exits non-zero" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
report "failed clone removes its partial destination" \
  "$([[ ! -e "$partial" ]] && echo yes || echo no)"
report "failed clone output remains redacted" \
  "$(! grep -Eq "https?://|${secret}" <<<"$out" && echo yes || echo no)"

replacement="$tmp/replaced-clone"
out="$(FAKE_GIT_MODE=replace PATH="$fake_bin:$PATH" "$helper" example/repo "$replacement" 2>&1)" && rc=0 || rc=$?
replacement_quarantine="$(find "$tmp" -path '*/.safe-clone-cleanup.*/clone/sentinel' -type f -print -quit)"
report "failed clone quarantines a replaced destination without deleting or restoring it" \
  "$([[ $rc -ne 0 && ! -e "$replacement" && -n "$replacement_quarantine" ]] && echo yes || echo no)"

# Replace the destination after cleanup's identity read, then return the old
# identity. This deterministically catches a check-then-rm implementation:
# only moving the path aside and verifying it after that atomic rename can
# prove a replacement will not be recursively deleted.
fake_stat_bin="$tmp/fake-stat-bin"
mkdir -p "$fake_stat_bin"
stat_state="$tmp/stat-state"
printf '0\n' >"$stat_state"
# The quoted fixture variables must expand only in the generated fake stat.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'value="$("${REAL_STAT:?}" "$@" 2>/dev/null)" || exit $?' \
  'if [[ "$value" =~ ^[0-9]+:[0-9]+$ ]]; then' \
  '  count="$(<"${FAKE_STAT_STATE:?}")"' \
  '  if [[ "$count" == "0" ]]; then' \
  '    printf "1\\n" >"$FAKE_STAT_STATE"' \
  '  else' \
  '    if [[ -e "${FAKE_STAT_DEST:?}" ]]; then' \
  '      mv "$FAKE_STAT_DEST" "${FAKE_STAT_DEST}.owned-late"' \
  '    fi' \
  '    mkdir -p "$FAKE_STAT_DEST"' \
  '    printf unrelated >"$FAKE_STAT_DEST/sentinel"' \
  '  fi' \
  'fi' \
  'printf "%s\\n" "$value"' >"$fake_stat_bin/stat"
chmod +x "$fake_stat_bin/stat"
late_replacement="$tmp/late-replaced-clone"
out="$(REAL_STAT="$(command -v stat)" FAKE_STAT_STATE="$stat_state" \
  FAKE_STAT_DEST="$late_replacement" PATH="$fake_stat_bin:$fake_bin:$PATH" \
  "$helper" example/repo "$late_replacement" 2>&1)" && rc=0 || rc=$?
report "cleanup cannot delete a destination replaced after its identity read" \
  "$([[ $rc -ne 0 && -f "$late_replacement/sentinel" ]] && echo yes || echo no)"

# Identity capture itself can fail on a constrained host. The newly-created,
# still-empty claim must be removed before failing so retrying is possible.
fake_stat_failure_bin="$tmp/fake-stat-failure-bin"
mkdir -p "$fake_stat_failure_bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$fake_stat_failure_bin/stat"
chmod +x "$fake_stat_failure_bin/stat"
identity_failure="$tmp/identity-failure"
out="$(PATH="$fake_stat_failure_bin:$fake_bin:$PATH" \
  "$helper" example/repo "$identity_failure" 2>&1)" && rc=0 || rc=$?
report "identity-capture failure removes the empty destination claim" \
  "$([[ $rc -ne 0 && ! -e "$identity_failure" ]] && echo yes || echo no)"

fake_rm_bin="$tmp/fake-rm-bin"
mkdir -p "$fake_rm_bin"
# The quoted fixture variable must expand only in the generated fake rm.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "cleanup diagnostic: %s\\n" "${FAKE_RM_SECRET:-}" >&2' \
  'exit 77' >"$fake_rm_bin/rm"
chmod +x "$fake_rm_bin/rm"
cleanup_failure="$tmp/cleanup-failure"
out="$(FAKE_RM_SECRET="$secret" PATH="$fake_rm_bin:$fake_bin:$PATH" "$helper" example/repo "$cleanup_failure" 2>&1)" && rc=0 || rc=$?
report "cleanup failure preserves the clone failure status" \
  "$([[ $rc -eq 1 ]] && echo yes || echo no)" "got exit $rc instead of 1"
report "cleanup failure output remains redacted" \
  "$(! grep -Eq "https?://|${secret}" <<<"$out" && echo yes || echo no)"
report "clone failure does not claim cleanup succeeded before the EXIT trap" \
  "$(! grep -q "partial destination removed" <<<"$out" && echo yes || echo no)"
"$(command -v rm)" -rf "$cleanup_failure"

for signal_spec in HUP:129 INT:130 TERM:143; do
  signal="${signal_spec%%:*}"
  expected="${signal_spec##*:}"
  interrupted="$tmp/interrupted-clone-${signal}"
  out="$(FAKE_GIT_MODE=interrupt FAKE_SIGNAL="$signal" FAKE_GIT_SECRET="$secret" PATH="$fake_bin:$PATH" "$helper" example/repo "$interrupted" 2>&1)" && rc=0 || rc=$?
  report "$signal interruption preserves exit status $expected" \
    "$([[ $rc -eq $expected ]] && echo yes || echo no)" "got exit $rc"
  report "$signal interruption removes its partial destination" \
    "$([[ ! -e "$interrupted" ]] && echo yes || echo no)"
  report "$signal interruption output remains redacted" \
    "$(! grep -Eq "https?://|${secret}" <<<"$out" && echo yes || echo no)"
done

if [[ $fail -ne 0 ]]; then
  echo "safe-clone self-test: FAILURES above" >&2
  exit 1
fi
echo "safe-clone self-test: all cases passed"
