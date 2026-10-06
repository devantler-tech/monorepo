#!/usr/bin/env bash
# Self-test for bot-pr-adaptation-push.sh (monorepo#3885).
#
# The helper exists to make one ORDER impossible to skip: fence, confirm, then push. So every
# case asserts what reached the remote branch and which calls were made in which order, never
# only the exit status. `gh` is a stub driven by state files; git is real, against a bare
# fixture remote, behind a wrapper that only records each push in the same call log.
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
impl="${script_dir}/bot-pr-adaptation-push.sh"

failures=0
fail() {
  printf 'bot-pr-adaptation-push test: FAIL — %s\n' "$*" >&2
  failures=$((failures + 1))
}

root=$(mktemp -d) || {
  printf 'cannot create fixture root\n' >&2
  exit 2
}
trap 'rm -rf -- "$root"' EXIT
root=$(cd "$root" && pwd -P)
state="${root}/state"
bin="${root}/bin"
mkdir -p "$state" "$bin" || exit 2
real_git=$(command -v git) || exit 2

# --- the stubs ------------------------------------------------------------------------------
cat > "${bin}/gh" <<'STUB'
#!/bin/sh
s=$GH_STUB_STATE
get() { cat "$s/$1"; }
case "$1 $2" in
  "pr view")
    n=$(($(get reads) + 1)); printf '%s' "$n" > "$s/reads"
    printf 'view\n' >> "$s/calls"
    [ "$(get fail_read)" = "$n" ] && exit 1
    [ "$(get undraft_on_read)" = "$n" ] && printf 'false' > "$s/draft"
    if [ "$(get auto)" = armed ]; then auto='{"mergeMethod":"SQUASH"}'; else auto=null; fi
    if [ "$(get drop_auto)" = 1 ]; then autofield=''; else autofield="\"autoMergeRequest\":$auto,"; fi
    printf '{"state":"%s","isDraft":%s,%s"isCrossRepository":%s,"headRefOid":"%s","headRefName":"%s","author":{"is_bot":true,"login":"%s"}}\n' \
      "$(get prstate)" "$(get draft)" "$autofield" "$(get cross)" "$(get head)" "$(get branch)" "$(get author)"
    ;;
  "pr ready")
    printf 'ready-undo\n' >> "$s/calls"
    [ "$(get ready_mode)" = fail ] && exit 1
    [ "$(get ready_mode)" = noop ] || printf 'true' > "$s/draft"
    [ -n "$(get move_head_to)" ] && get move_head_to > "$s/head"
    exit 0
    ;;
  "pr merge")
    printf 'disable-auto\n' >> "$s/calls"
    [ "$(get auto_mode)" = fail ] && exit 1
    [ "$(get auto_mode)" = noop ] || printf 'none' > "$s/auto"
    exit 0
    ;;
  *) printf 'unexpected:%s\n' "$*" >> "$s/calls"; exit 1 ;;
esac
STUB
cat > "${bin}/git" <<STUB
#!/bin/sh
for a in "\$@"; do [ "\$a" = push ] && printf 'push\n' >> "\$GH_STUB_STATE/calls"; done
exec "$real_git" "\$@"
STUB
chmod +x "${bin}/gh" "${bin}/git"

# --- the repository fixture -----------------------------------------------------------------
# A bare remote with one bot branch at `base`; the work clone holds `fix`, one commit on top of
# it, and `stray`, a commit that does not descend from it.
g() { "$real_git" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
remote_repo="${root}/remote.git"
work="${root}/work"
branch=renovate/widget-2.x
g init -q --bare "$remote_repo" || fail 'fixture: init remote'
g init -q "$work" || fail 'fixture: init work'
g -C "$work" remote add origin "$remote_repo"
g -C "$work" commit -q --allow-empty -m base || fail 'fixture: base commit'
base=$(g -C "$work" rev-parse HEAD)
g -C "$work" commit -q --allow-empty -m fix || fail 'fixture: fix commit'
fix=$(g -C "$work" rev-parse HEAD)
g -C "$work" checkout -q --orphan stray || fail 'fixture: stray branch'
g -C "$work" commit -q --allow-empty -m stray || fail 'fixture: stray commit'
stray=$(g -C "$work" rev-parse HEAD)
g -C "$work" checkout -q --detach "$base" || fail 'fixture: detach'
g -C "$work" commit -q --allow-empty -m other || fail 'fixture: other commit'
other=$(g -C "$work" rev-parse HEAD)

remote_head() { g -C "$remote_repo" rev-parse "refs/heads/${branch}" 2>/dev/null; }

# reset <draft> <auto> puts the pull request and the remote branch back to the start.
reset() {
  printf '%s' "$1" > "${state}/draft"
  printf '%s' "$2" > "${state}/auto"
  printf 'OPEN' > "${state}/prstate"
  printf 'false' > "${state}/cross"
  printf 'app/renovate' > "${state}/author"
  printf '%s' "$branch" > "${state}/branch"
  printf '%s' "$base" > "${state}/head"
  printf '0' > "${state}/reads"
  for f in fail_read undraft_on_read drop_auto ready_mode auto_mode move_head_to; do
    : > "${state}/${f}"
  done
  : > "${state}/calls"
  g -C "$work" push -q --force origin "${base}:refs/heads/${branch}" 2>/dev/null || fail 'fixture: reset remote'
}
set_state() { printf '%s' "$2" > "${state}/$1"; }
calls() { tr '\n' ' ' < "${state}/calls" | sed 's/ $//'; }

run() { # [<commit>] — sets out and rc
  out=$(GH_STUB_STATE="$state" PATH="${bin}:$PATH" bash "$impl" \
    --repo acme/widgets --pr 7 --repo-dir "$work" --commit "${1:-$fix}" 2>&1)
  rc=$?
}

# expect_untouched <case>: nothing was pushed, and no push was even attempted.
expect_untouched() {
  [ "$(remote_head)" = "$base" ] || fail "$1: the remote branch moved to $(remote_head)"
  case " $(calls) " in *" push "*) fail "$1: a push was attempted ($(calls))" ;; esac
}

# --- 1. ready and armed: fenced, confirmed, then pushed — in that order ----------------------
reset false armed
run
[ "$rc" -eq 0 ] || fail "1: exit ${rc}, not 0: ${out}"
[ "$(calls)" = 'view ready-undo disable-auto view push view' ] ||
  fail "1: the fence was not applied and confirmed before the push ($(calls))"
[ "$(remote_head)" = "$fix" ] || fail '1: the commit is not the remote branch head'
grep -qF "FENCED acme/widgets#7 draft=true auto_merge=none head=${base}" <<<"$out" ||
  fail '1: the confirmed fence was not reported'
grep -qF "PUSHED acme/widgets#7 ${fix} -> ${branch}" <<<"$out" || fail '1: the push was not reported'

# --- 2. already a draft with nothing armed: no change is made, both states are still read ----
reset true none
run
[ "$rc" -eq 0 ] || fail "2: exit ${rc}, not 0: ${out}"
[ "$(calls)" = 'view view push view' ] || fail "2: unexpected calls ($(calls))"
[ "$(remote_head)" = "$fix" ] || fail '2: the commit is not the remote branch head'

# --- 3. a draft with auto-merge armed: only the armed half is changed ------------------------
reset true armed
run
[ "$rc" -eq 0 ] || fail "3: exit ${rc}, not 0: ${out}"
[ "$(calls)" = 'view disable-auto view push view' ] || fail "3: unexpected calls ($(calls))"

# --- 4. a failed read is UNKNOWN, whichever read it is, and nothing is pushed ----------------
reset false armed
set_state fail_read 1
run
[ "$rc" -eq 2 ] || fail "4a: a failed first read exited ${rc}, not 2"
[ "$(calls)" = view ] || fail "4a: the pull request was changed after a failed read ($(calls))"
expect_untouched 4a
reset false armed
set_state fail_read 2
run
[ "$rc" -eq 2 ] || fail "4b: a failed confirmation read exited ${rc}, not 2"
expect_untouched 4b
grep -q FENCED <<<"$out" && fail '4b: a fence nobody confirmed was reported as confirmed'
# A read without the auto-merge field cannot say "not armed".
reset true none
set_state drop_auto 1
run
[ "$rc" -eq 2 ] || fail "4c: a read with no auto-merge field exited ${rc}, not 2"
expect_untouched 4c

# --- 5. a fence step that fails, or reports success without effect, stops the push -----------
reset false armed
set_state ready_mode fail
run
[ "$rc" -eq 2 ] || fail "5a: a failed draft conversion exited ${rc}, not 2"
expect_untouched 5a
reset false armed
set_state auto_mode fail
run
[ "$rc" -eq 2 ] || fail "5b: a failed auto-merge disable exited ${rc}, not 2"
expect_untouched 5b
reset false armed
set_state ready_mode noop
run
[ "$rc" -eq 1 ] || fail "5c: a draft conversion with no effect exited ${rc}, not 1"
grep -qF 'still not a draft' <<<"$out" || fail '5c: the unconfirmed draft state was not named'
expect_untouched 5c
reset true armed
set_state auto_mode noop
run
[ "$rc" -eq 1 ] || fail "5d: an auto-merge disable with no effect exited ${rc}, not 1"
grep -qF 'still has auto-merge armed' <<<"$out" || fail '5d: the armed state was not named'
expect_untouched 5d

# --- 6. a head that moved is refused: by the confirmation read, and by the remote itself -----
reset false armed
set_state move_head_to "$other"
run
[ "$rc" -eq 1 ] || fail "6a: a head that moved between the reads exited ${rc}, not 1"
grep -qF "moved from ${base} to ${other}" <<<"$out" || fail '6a: the moved head was not named'
expect_untouched 6a
# The reads still say `base`, but the branch itself advanced: the unforced push is rejected.
reset true none
g -C "$work" push -q origin "${other}:refs/heads/${branch}" 2>/dev/null || fail 'fixture: advance remote'
run
[ "$rc" -eq 2 ] || fail "6b: a rejected push exited ${rc}, not 2"
[ "$(remote_head)" = "$other" ] || fail '6b: a branch that had moved was overwritten'
grep -q PUSHED <<<"$out" && fail '6b: a rejected push was reported as pushed'

# --- 7. not a pull request this helper is for: refused before anything is changed ------------
for pair in 'author devantler' 'author app/renovate-approve' 'prstate MERGED' 'cross true' \
  'branch -f' 'branch a..b'; do
  reset false armed
  set_state "${pair%% *}" "${pair#* }"
  run
  [ "$rc" -eq 1 ] || fail "7: ${pair} exited ${rc}, not 1: ${out}"
  [ "$(calls)" = view ] || fail "7: ${pair} still changed the pull request ($(calls))"
  expect_untouched "7 (${pair})"
done
reset false armed
run "$stray"
[ "$rc" -eq 1 ] || fail "7: a commit that does not descend from the head exited ${rc}, not 1"
[ "$(calls)" = view ] || fail "7: an unrelated commit still changed the pull request ($(calls))"
expect_untouched '7 (unrelated commit)'
reset false armed
run "$base"
[ "$rc" -eq 1 ] || fail "7: pushing the current head exited ${rc}, not 1"

# --- 8. a pull request that left draft after the push is not reported as done ---------------
reset false armed
set_state undraft_on_read 3
run
[ "$rc" -eq 2 ] || fail "8: a pull request no longer a draft after the push exited ${rc}, not 2"
grep -q PUSHED <<<"$out" && fail '8: a pull request no longer fenced was reported as done'

# --- 9. usage errors are UNKNOWN and reach nothing -------------------------------------------
reset false armed
run "${fix%????}"
[ "$rc" -eq 2 ] || fail "9: an abbreviated sha exited ${rc}, not 2"
[ -z "$(calls)" ] || fail "9: a usage error still called out ($(calls))"

if [ "$failures" -eq 0 ]; then
  printf 'bot-pr-adaptation-push test: all assertions passed\n'
  exit 0
fi
printf 'bot-pr-adaptation-push test: %d assertion(s) failed\n' "$failures" >&2
exit 1
