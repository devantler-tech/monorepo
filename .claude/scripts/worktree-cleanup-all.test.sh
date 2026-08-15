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
t_aborts_on_malformed_gitmodules
t_skips_a_gitmodules_entry_that_is_not_a_gitlink
t_gitlink_validation_uses_a_literal_pathspec
t_rejects_bad_mode
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
