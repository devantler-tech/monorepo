#!/usr/bin/env bash
# Contract tests for worktree-cleanup-all.sh — the multi-repo orchestrator.
#
# worktree-cleanup.test.sh covers the per-repo safety gates. The orchestrator carries
# contracts of its own that nothing else pins: the session-worktree root rewrite, the
# broken-isolation SKIP, per-repo manifest isolation, and abort-on-first-failure.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/worktree-cleanup-all.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# A root repo with one submodule-like nested repo, each carrying a spent worktree.
make_root() {
  local root; root=$(mktemp -d); root=$(cd "$root" && pwd -P)
  for r in main sub; do
    git init -q --bare "$root/$r.git"
  done
  git init -q -b main "$root/repo"
  git -C "$root/repo" config user.email t@t.t; git -C "$root/repo" config user.name t
  echo base > "$root/repo/f"; git -C "$root/repo" add f
  git -C "$root/repo" commit -qm base
  git -C "$root/repo" remote add origin "$root/main.git"
  git -C "$root/repo" push -q origin main

  # A nested independent repo standing in for a submodule, plus .gitmodules naming it.
  git init -q -b main "$root/repo/nested"
  git -C "$root/repo/nested" config user.email t@t.t
  git -C "$root/repo/nested" config user.name t
  echo n > "$root/repo/nested/g"; git -C "$root/repo/nested" add g
  git -C "$root/repo/nested" commit -qm base
  git -C "$root/repo/nested" remote add origin "$root/sub.git"
  git -C "$root/repo/nested" push -q origin main
  printf '[submodule "nested"]\n\tpath = nested\n\turl = %s\n' "$root/sub.git" \
    > "$root/repo/.gitmodules"
  # Register it as a REAL gitlink (mode 160000). The orchestrator requires this: a
  # .gitmodules entry alone can name an ordinary nested repository, which is not a
  # portfolio submodule and must not be swept.
  local nsha; nsha=$(git -C "$root/repo/nested" rev-parse HEAD)
  git -C "$root/repo" update-index --add --cacheinfo "160000,$nsha,nested"
  git -C "$root/repo" add .gitmodules
  git -C "$root/repo" commit -qm "register nested as a submodule"
  git -C "$root/repo" push -q origin main

  for pair in "repo:spent-root" "repo/nested:spent-sub"; do
    local r=${pair%%:*} n=${pair##*:}
    mkdir -p "$root/$r/.claude/worktrees"
    git -C "$root/$r" worktree add -q -b "claude/$n" "$root/$r/.claude/worktrees/$n" main
    git -C "$root/$r" push -q origin "claude/$n"
    touch -t 202001010000 "$root/$r/.claude/worktrees/$n"
  done
  printf '%s' "$root"
}

# add_session_with_nested <root> <pushed|unpushed> — a pushed session worktree `sess` whose
# submodule `nested` is populated (so its repository lives in the session's own admin dir)
# and holds a linked worktree `inner` of that submodule's repository. `unpushed` gives
# `inner` a commit no remote has. Both are aged past every threshold.
add_session_with_nested() {
  local root=$1 state=$2 sess="$1/repo/.claude/worktrees/sess"
  local inner="$sess/nested/.claude/worktrees/inner"
  git -C "$root/repo" worktree add -q -b claude/sess "$sess" main || return 1
  git -C "$root/repo" push -q origin claude/sess || return 1
  git -C "$sess" -c protocol.file.allow=always submodule update --init -q nested >/dev/null 2>&1 \
    || return 1
  [ -d "$(git -C "$sess" rev-parse --absolute-git-dir)/modules/nested" ] || return 1
  git -C "$sess/nested" config user.email t@t.t && git -C "$sess/nested" config user.name t
  mkdir -p "$sess/nested/.claude/worktrees"
  git -C "$sess/nested" worktree add -q -b claude/inner "$inner" HEAD || return 1
  if [ "$state" = unpushed ]; then
    echo local > "$inner/h" && git -C "$inner" add h && git -C "$inner" commit -qm "local only" \
      || return 1
  else
    git -C "$sess/nested" push -q origin claude/inner || return 1
  fi
  touch -t 202001010000 "$inner" "$sess"
}

t_sweeps_worktrees_nested_in_session_submodules() {
  # #3673: nothing visited a worktree nested in a session worktree's submodule, so the
  # parent session worktree was kept forever. The nested pass must reap it (dry-run only
  # reports), and the same run's root sweep must then reap the freed parent.
  local name="sweeps a worktree nested in a session worktree's submodule, then its parent"
  local root; root=$(make_root)
  add_session_with_nested "$root" pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local sess="$root/repo/.claude/worktrees/sess" dry out rc dry_kept
  dry=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" bash "$SUT" dry-run 24 2>&1)
  [ -d "$sess/nested/.claude/worktrees/inner" ] && dry_kept=yes || dry_kept=NO
  out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" bash "$SUT" apply 24 2>&1); rc=$?
  if grep -qx '### .claude/worktrees/sess/nested' <<<"$dry" && grep -q 'REAP  .*inner' <<<"$dry" \
     && [ "$dry_kept" = yes ] && [ "$rc" -eq 0 ] \
     && [ ! -e "$sess/nested/.claude/worktrees/inner" ] && [ ! -e "$sess" ] \
     && ls "$root/home/.claude/worktree-cleanup-manifests/"nested-sess-nested-*.tsv >/dev/null 2>&1; then
    ok "$name"
  else
    bad "$name" "rc=$rc dry_kept=$dry_kept inner=$([ -e "$sess/nested/.claude/worktrees/inner" ] && echo present || echo gone) sess=$([ -e "$sess" ] && echo present || echo gone)
$dry
---
$out"
  fi
  rm -rf "$root"
}

t_nested_sweep_never_salvages() {
  # A nested worktree's salvage refs would live in the session worktree's own submodule
  # repository, which dies with the parent. So the nested pass runs with salvage off: a
  # nested worktree holding a local-only commit is KEPT, even far past the salvage age,
  # and its parent stays with it.
  #
  # The work must look old enough to salvage, or this passes with salvage on too. Salvage
  # age counts ctime (#3642), which `touch` cannot backdate, so this test (only) runs with
  # a `stat` shim that answers a ctime query with the mtime, as worktree-cleanup.test.sh
  # does for its salvage fixtures.
  local name="the nested pass never salvages: a nested worktree with local-only work is kept"
  local root; root=$(make_root)
  add_session_with_nested "$root" unpushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local sess="$root/repo/.claude/worktrees/sess" out rc admin f
  local inner="$sess/nested/.claude/worktrees/inner" shim="$root/stat-shim"
  admin=$(git -C "$inner" rev-parse --absolute-git-dir)
  find "$inner" -mindepth 1 -exec touch -h -t 202001010000 {} + 2>/dev/null
  for f in "$admin/index" "$admin/logs/HEAD" "$inner"; do touch -t 202001010000 "$f"; done
  mkdir -p "$shim"
  cat > "$shim/stat" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in %Z) args+=(%Y) ;; %c) args+=(%m) ;; *) args+=("\$a") ;; esac
done
exec '$(command -v stat)' "\${args[@]}"
EOF
  chmod +x "$shim/stat"
  out=$(PATH="$shim:$PATH" HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" \
        bash "$SUT" apply 24 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ -d "$sess/nested/.claude/worktrees/inner" ] && [ -d "$sess" ] \
     && [ -z "$(git -C "$sess/nested" for-each-ref refs/salvaged 2>/dev/null)" ] \
     && [ "$(git -C "$sess/nested/.claude/worktrees/inner" log -1 --format=%s 2>/dev/null)" = "local only" ]; then
    ok "$name"
  else
    bad "$name" "rc=$rc $out"
  fi
  rm -rf "$root"
}

t_nested_failure_does_not_block_the_root_sweep() {
  # One session worktree's broken submodule repository must not stop every later sweep:
  # the run carries on to the root, and still exits non-zero so the failure is seen.
  local name="a failed nested sweep is reported, the root is still swept, and the run exits non-zero"
  local root; root=$(make_root)
  add_session_with_nested "$root" pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local inner="$root/repo/.claude/worktrees/sess/nested/.claude/worktrees/inner" out rc
  chmod 000 "$inner"   # the per-repo sweep cannot resolve this candidate and aborts
  out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" bash "$SUT" dry-run 24 2>&1); rc=$?
  chmod 755 "$inner"
  if [ "$rc" -ne 0 ] && grep -q 'sweep of .claude/worktrees/sess/nested failed .* continuing' <<<"$out" \
     && grep -q 'REAP  .*spent-root' <<<"$out" && grep -q 'REAP  .*spent-sub' <<<"$out" \
     && grep -q 'a nested submodule sweep failed' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "rc=$rc $out"
  fi
  rm -rf "$root"
}

t_nested_listing_failure_exits_non_zero() {
  # A session worktree whose submodules cannot be listed is skipped, but that is a failure,
  # not a verdict: the root is still swept and the run must exit non-zero, or the scheduled
  # log (which keeps only a summary on success) would hide that the pass never ran there.
  local name="a session worktree whose submodules cannot be listed makes the run exit non-zero"
  local root; root=$(make_root)
  add_session_with_nested "$root" pushed || { bad "$name" "FIXTURE"; rm -rf "$root"; return; }
  local shim="$root/git-shim" real_git out rc
  real_git=$(command -v git)
  mkdir -p "$shim"
  # Fail only `git -C <…/sess> submodule foreach`; every other git call passes through.
  cat > "$shim/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${2:-}" = '$root/repo/.claude/worktrees/sess' ] \\
   && [ "\${3:-}" = submodule ] && [ "\${4:-}" = foreach ]; then
  exit 128
fi
exec '$real_git' "\$@"
EOF
  chmod +x "$shim/git"
  out=$(PATH="$shim:$PATH" HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" \
        bash "$SUT" dry-run 24 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'SKIP .claude/worktrees/sess (cannot list its submodules)' <<<"$out" \
     && grep -q 'cannot list the submodules of .claude/worktrees/sess .* exit non-zero' <<<"$out" \
     && grep -q 'REAP  .*spent-root' <<<"$out"; then
    ok "$name"
  else
    bad "$name" "rc=$rc $out"
  fi
  rm -rf "$root"
}

t_sweeps_root_and_submodules() {
  local root; root=$(make_root)
  local out; out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" \
                   bash "$SUT" dry-run 24 2>&1)
  if grep -q 'REAP  .*spent-root' <<<"$out" \
     && grep -q 'REAP  .*spent-sub' <<<"$out"; then
    ok "sweeps the root AND every submodule from .gitmodules"
  else
    bad "sweeps the root AND every submodule from .gitmodules" "$out"
  fi
  rm -rf "$root"
}

t_rewrites_session_worktree_root() {
  # Invoked with a root INSIDE .claude/worktrees/, it must sweep the MAIN checkout —
  # otherwise a run launched from a session worktree only ever sees its own nested tree.
  local root; root=$(make_root)
  local inner="$root/repo/.claude/worktrees/spent-root"
  local out; out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$inner" \
                   bash "$SUT" dry-run 24 2>&1)
  # NB: match the banner's trailing " ===" rather than anchoring with $ — the path is
  # not at end-of-line, so a $ anchor never matches even when the rewrite is correct.
  if grep -qF "root=$root/repo ===" <<<"$out"; then
    ok "rewrites a session-worktree root to the main checkout"
  else
    bad "rewrites a session-worktree root to the main checkout" \
        "$(printf '%s' "$out" | head -3)"
  fi
  rm -rf "$root"
}

t_skips_uninitialised_submodule() {
  # An UNINITIALISED submodule (no git metadata of its own) resolves up to the parent
  # repo and must be SKIPPED — never swept through that alias.
  #
  # It must NOT be reported as broken isolation. The two conditions have opposite
  # remedies: this one is benign and cleared by submodule-init.sh, whereas broken
  # isolation means live sessions are silently colliding in one physical tree. This
  # fixture builds the uninitialised case (it deletes the metadata outright), so
  # asserting the broken-isolation wording here is what let the two blur together.
  local root; root=$(make_root)
  rm -rf "$root/repo/nested/.git"          # now resolves up to the parent repo
  mkdir -p "$root/repo/nested/.claude/worktrees"
  local out; out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" \
                   bash "$SUT" dry-run 24 2>&1)
  if grep -q 'SKIP .*nested .*not initialised' <<<"$out" \
     && grep -q 'submodule-init.sh' <<<"$out" \
     && ! grep -q 'nested .*broken isolation' <<<"$out"; then
    ok "SKIPs an uninitialised submodule and names it as such"
  else
    bad "SKIPs an uninitialised submodule and names it as such" "$out"
  fi
  rm -rf "$root"
}

t_skips_broken_isolation() {
  # GENUINELY broken worktree isolation: the submodule keeps git metadata of its own,
  # but a stray core.worktree resolves it back into the parent checkout. This is the
  # dangerous case — sweeping through that alias would operate on the wrong tree — and
  # until now nothing covered it, because the only test that claimed to deleted .git
  # instead and so exercised the uninitialised path.
  local root; root=$(make_root)
  # Relocate the nested gitdir the way a real submodule stores it, then point
  # core.worktree at the PARENT so the toplevel resolves outside the submodule.
  mkdir -p "$root/repo/.git/modules"
  mv "$root/repo/nested/.git" "$root/repo/.git/modules/nested"
  printf 'gitdir: %s\n' "$root/repo/.git/modules/nested" > "$root/repo/nested/.git"
  git -C "$root/repo/.git/modules/nested" config core.worktree "$root/repo"
  mkdir -p "$root/repo/nested/.claude/worktrees"
  # Guard the fixture itself: it is only a broken-isolation case if the metadata is
  # still present AND the toplevel now resolves away from the submodule.
  local top; top=$(git -C "$root/repo/nested" rev-parse --show-toplevel 2>/dev/null)
  if [ ! -e "$root/repo/nested/.git" ] || [ "$top" = "$root/repo/nested" ]; then
    bad "SKIPs a submodule with broken worktree isolation" \
        "fixture did not reproduce broken isolation (toplevel=$top)"
    rm -rf "$root"; return
  fi
  local out; out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" \
                   bash "$SUT" dry-run 24 2>&1)
  if grep -q 'SKIP .*nested .*broken isolation' <<<"$out" \
     && ! grep -q 'nested .*not initialised' <<<"$out"; then
    ok "SKIPs a submodule with broken worktree isolation"
  else
    bad "SKIPs a submodule with broken worktree isolation" "$out"
  fi
  rm -rf "$root"
}

t_aborts_and_exits_nonzero_on_sweep_failure() {
  # An infrastructure failure in one repo must stop the run and surface a nonzero exit,
  # not be swallowed by the `| tail` pipeline and the trailing success banner.
  local root; root=$(make_root)
  local shim="$root/shim"; mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$shim/lsof"   # force the fail-closed abort
  chmod +x "$shim/lsof"
  local out rc
  out=$(PATH="$shim:$PATH" HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" \
        bash "$SUT" dry-run 24 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'ABORTING' <<<"$out"; then
    ok "aborts and exits nonzero when a sweep fails"
  else
    bad "aborts and exits nonzero when a sweep fails" "rc=$rc $(printf '%s' "$out" | tail -3)"
  fi
  rm -rf "$root"
}

t_per_repo_manifest_isolation() {
  local root; root=$(make_root)
  HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" bash "$SUT" apply 24 >/dev/null 2>&1
  local n; n=$(ls -1 "$root/home/.claude/worktree-cleanup-manifests/"*.tsv 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -ge 2 ]; then
    ok "writes a separate manifest per repository"
  else
    bad "writes a separate manifest per repository" \
        "manifests=$n $(ls -1 "$root/home/.claude/worktree-cleanup-manifests/" 2>&1)"
  fi
  rm -rf "$root"
}

t_rejects_bad_mode() {
  local root; root=$(make_root)
  HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" bash "$SUT" alpply 24 >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -d "$root/repo/.claude/worktrees/spent-root" ]; then
    ok "rejects an invalid MODE without deleting anything"
  else
    bad "rejects an invalid MODE without deleting anything" "rc=$rc"
  fi
  rm -rf "$root"
}

t_validates_args_even_with_no_worktree_dirs() {
  # With no .claude/worktrees/ anywhere, every per-repo call returns before validating,
  # so a malformed launcher invocation used to print "done" and exit 0.
  local root; root=$(make_root)
  rm -rf "$root/repo/.claude/worktrees" "$root/repo/nested/.claude/worktrees"
  local out rc
  out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" bash "$SUT" alpply 24 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -qi 'invalid MODE' <<<"$out"; then
    ok "validates MODE even when no repository has a worktree dir"
  else
    bad "validates MODE even when no repository has a worktree dir" "rc=$rc $out"
  fi
  rm -rf "$root"
}


t_passes_salvage_age_and_validates_it() {
  # The scheduled launcher passes only MODE and min_age, so the wrapper's own default is
  # what turns salvage on for the real sweep (#2831). A malformed value must stop the run.
  local root; root=$(make_root)
  local out rc out_bad rc_bad
  out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" bash "$SUT" dry-run 24 2>&1); rc=$?
  out_bad=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" bash "$SUT" dry-run 24 2w 2>&1); rc_bad=$?
  if [ "$rc" -eq 0 ] && grep -q 'salvage_age=336h' <<<"$out" \
     && [ "$rc_bad" -eq 2 ] && grep -q 'salvage_age_hours must be a non-negative integer' <<<"$out_bad"; then
    ok "defaults salvage_age to 336h and rejects a malformed value"
  else
    bad "defaults salvage_age to 336h and rejects a malformed value" "rc=$rc rc_bad=$rc_bad $out $out_bad"
  fi
  rm -rf "$root"
}

t_aborts_on_malformed_gitmodules() {
  # Both the --get-regexp and the --list probe fail on a malformed file, producing no
  # output; testing only the probe's emptiness read that as "no submodules" and
  # silently degraded the sweep to the root repo.
  local root; root=$(make_root)
  printf '[submodule "broken"\n\tpath =\n' > "$root/repo/.gitmodules"
  local out rc
  out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" bash "$SUT" dry-run 24 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'ABORTING' <<<"$out"; then
    ok "aborts on a malformed .gitmodules instead of sweeping only the root"
  else
    bad "aborts on a malformed .gitmodules instead of sweeping only the root" "rc=$rc $out"
  fi
  rm -rf "$root"
}

t_skips_a_gitmodules_entry_that_is_not_a_gitlink() {
  # Containment is not sufficient: a stale or malformed .gitmodules entry can name an
  # ordinary nested repository INSIDE the root, which is not a portfolio submodule and
  # must never be swept destructively.
  local root; root=$(make_root)
  git -C "$root/repo" rm -q --cached nested >/dev/null 2>&1   # drop the gitlink, keep the dir
  git -C "$root/repo" commit -qm "de-register nested" >/dev/null 2>&1
  local out; out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" \
                   bash "$SUT" apply 24 2>&1)
  # Assert the SAFETY PROPERTY, not one reason string: de-registering the gitlink can be
  # caught either by the exact-path check (index entry resolves to nothing) or by the
  # mode check. Both are correct SKIPs; what must hold is that the nested repository is
  # left alone while the root is still swept.
  if grep -q '### SKIP nested' <<<"$out" \
     && [ -d "$root/repo/nested/.claude/worktrees/spent-sub" ] \
     && grep -q 'REAPED .*spent-root' <<<"$out"; then
    ok "SKIPs a .gitmodules entry that is not a real gitlink"
  else
    bad "SKIPs a .gitmodules entry that is not a real gitlink" \
        "sub_present=$([ -d "$root/repo/nested/.claude/worktrees/spent-sub" ] && echo yes || echo NO) $out"
  fi
  rm -rf "$root"
}

t_gitlink_validation_uses_a_literal_pathspec() {
  # A .gitmodules path containing pathspec metacharacters must not validate against a
  # DIFFERENT index entry: `nested[12]` matches the real `nested` gitlink under wildcard
  # magic, which would let an ordinary nested repository be swept.
  local root; root=$(make_root)
  # Point .gitmodules at a metacharacter path that glob-matches the real gitlink, and
  # make that literal path a real (non-submodule) repository with a spent worktree.
  printf '[submodule "x"]\n\tpath = nested[12]\n\turl = %s\n' "$root/sub.git" \
    > "$root/repo/.gitmodules"
  git init -q -b main "$root/repo/nested[12]"
  git -C "$root/repo/nested[12]" config user.email t@t.t
  git -C "$root/repo/nested[12]" config user.name t
  echo z > "$root/repo/nested[12]/z"; git -C "$root/repo/nested[12]" add z
  git -C "$root/repo/nested[12]" commit -qm base
  git -C "$root/repo/nested[12]" remote add origin "$root/sub.git"
  git -C "$root/repo/nested[12]" fetch -q origin 2>/dev/null || true
  mkdir -p "$root/repo/nested[12]/.claude/worktrees"
  git -C "$root/repo/nested[12]" worktree add -q -b claude/victim \
      "$root/repo/nested[12]/.claude/worktrees/victim" main 2>/dev/null
  echo "only copy" > "$root/repo/nested[12]/.claude/worktrees/victim/precious.txt"
  touch -t 202001010000 "$root/repo/nested[12]/.claude/worktrees/victim"
  local out; out=$(HOME="$root/home" WORKTREE_CLEANUP_ROOT="$root/repo" \
                   bash "$SUT" apply 24 2>&1)
  if [ -f "$root/repo/nested[12]/.claude/worktrees/victim/precious.txt" ] \
     && grep -q 'SKIP nested\[12\]' <<<"$out"; then
    ok "gitlink validation uses a literal pathspec (metacharacter path is SKIPped)"
  else
    bad "gitlink validation uses a literal pathspec (metacharacter path is SKIPped)" \
        "victim=$([ -f "$root/repo/nested[12]/.claude/worktrees/victim/precious.txt" ] && echo present || echo GONE) $out"
  fi
  rm -rf "$root"
}

printf 'worktree-cleanup-all.sh contract tests\n'
t_sweeps_root_and_submodules
t_rewrites_session_worktree_root
t_skips_uninitialised_submodule
t_skips_broken_isolation
t_aborts_and_exits_nonzero_on_sweep_failure
t_per_repo_manifest_isolation
t_validates_args_even_with_no_worktree_dirs
t_passes_salvage_age_and_validates_it
t_aborts_on_malformed_gitmodules
t_skips_a_gitmodules_entry_that_is_not_a_gitlink
t_gitlink_validation_uses_a_literal_pathspec
t_sweeps_worktrees_nested_in_session_submodules
t_nested_sweep_never_salvages
t_nested_failure_does_not_block_the_root_sweep
t_nested_listing_failure_exits_non_zero
t_rejects_bad_mode
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
