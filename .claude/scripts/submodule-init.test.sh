#!/usr/bin/env bash
#
# Self-test for submodule-init.sh — proves the worktree-isolation guard DETECTS
# a stray core.worktree that collapses a submodule onto another checkout (the
# fail-open the #2164 review caught across three rounds), that a clean tree
# passes, that repair clears the stray key and pins it per-worktree, that a
# deinitialised submodule is skipped without a false alarm, and that all of this
# holds when the tool is invoked from a linked superproject worktree (the
# documented agent execution model, where the submodule gitdir lives under
# .git/worktrees/<wt>/modules/<path>).
#
# Fixtures are throwaway local `git init` repos wired as file:// submodules — no
# network, no real submodules touched. Run in CI so a refactor that re-opens the
# fail-open is caught here, not by a silent cross-session collision in a
# production run (the exact papercut submodule-init.sh exists to prevent).
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$here/submodule-init.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Hermetic git environment: the host's real system/global config must not affect
# fixtures, and file:// submodules need protocol.file.allow (default-denied since
# the CVE-2022-39253 hardening) — set once in the throwaway global config so the
# script's own internal `git submodule update --init` inherits it too.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" user.email "test@example.com"
git config --file "$GIT_CONFIG_GLOBAL" user.name "submodule-init self-test"
git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always

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

# Physical (symlink-resolved) path — the script compares trees with `pwd -P`
# (/tmp vs /private/tmp on macOS, /var/folders symlinks), so the test must too.
abspath() { (cd "$1" 2>/dev/null && pwd -P); }

# Build a superproject embedding one file:// submodule at sub/. `remote-sub` is
# the upstream the submodule tracks; `super` is the aggregation repo.
mk_super() {
  local root="$1"
  mkdir -p "$root"
  git init -q "$root/remote-sub"
  (
    cd "$root/remote-sub"
    echo seed >file.txt
    git add file.txt
    git commit -q -m init
  )
  git init -q "$root/super"
  (
    cd "$root/super"
    echo root >root.txt
    git add root.txt
    git commit -q -m init
    git submodule add -q ../remote-sub sub
    git commit -q -m "add sub"
  )
}

# 1. Clean tree: --check passes and reports the submodule isolated.
c1="$tmp/c1"
mk_super "$c1"
out="$(cd "$c1/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "clean tree: --check exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
report "clean tree: reports the submodule isolated" \
  "$(grep -q 'sub — isolated' <<<"$out" && echo yes || echo no)" "$out"

# 2. THE fail-open regression: a stray core.worktree pointing at ANOTHER valid
#    checkout must fail --check and NAME the colliding checkout. An earlier
#    version silently dropped this exact case from the sweep and exited 0.
c2="$tmp/c2"
mk_super "$c2"
collider="$c2/collider"
git init -q "$collider"
(
  cd "$collider"
  echo x >y.txt
  git add y.txt
  git commit -q -m collider
)
git config -f "$c2/super/.git/modules/sub/config" core.worktree "$(abspath "$collider")"
out="$(cd "$c2/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "collision: --check exits non-zero" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "$out"
report "collision: reports ISOLATION BROKEN" \
  "$(grep -q 'ISOLATION BROKEN' <<<"$out" && echo yes || echo no)" "$out"
report "collision: names the colliding checkout" \
  "$(grep -q 'collider' <<<"$out" && echo yes || echo no)" "$out"

# 3. Repair: `submodule-init.sh <path>` clears the stray shared key, pins
#    core.worktree per-worktree to the submodule's OWN path, and the re-probe
#    passes.
out="$(cd "$c2/super" && "$helper" sub 2>&1)" && rc=0 || rc=$?
report "repair: exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
report "repair: removes the stray shared core.worktree" \
  "$([[ -z "$(git config -f "$c2/super/.git/modules/sub/config" core.worktree 2>/dev/null || true)" ]] && echo yes || echo no)"
report "repair: pins core.worktree per-worktree to the submodule's own path" \
  "$([[ "$(git config -f "$c2/super/.git/modules/sub/config.worktree" core.worktree 2>/dev/null || true)" == "$(abspath "$c2/super/sub")" ]] && echo yes || echo no)"
out="$(cd "$c2/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "repair: --check passes afterwards" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"

# 4. Deinitialised submodule: skipped by --check with no false alarm, while the
#    populated one is still probed.
c4="$tmp/c4"
mk_super "$c4"
(
  cd "$c4/super"
  git submodule add -q ../remote-sub sub2
  git commit -q -m "add sub2"
  git submodule deinit -f sub2 >/dev/null 2>&1
)
out="$(cd "$c4/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "deinit: --check exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
report "deinit: does not probe the deinitialised submodule" \
  "$(grep -q 'sub2' <<<"$out" && echo no || echo yes)" "$out"
report "deinit: still probes the populated submodule" \
  "$(grep -q 'sub — isolated' <<<"$out" && echo yes || echo no)" "$out"

# 5. Linked superproject worktree (the agent execution model): init+repair+probe
#    and --check both hold when the submodule gitdir lives under
#    .git/worktrees/<wt>/modules/<path>.
c5="$tmp/c5"
mk_super "$c5"
git -C "$c5/super" worktree add -q "$c5/super-wt" -b wt
out="$(cd "$c5/super-wt" && "$helper" sub 2>&1)" && rc=0 || rc=$?
report "linked worktree: init+repair+probe exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
gitdir="$(cd "$c5/super-wt/sub" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
report "linked worktree: submodule gitdir lives under the worktree admin dir" \
  "$([[ "$gitdir" == *"/worktrees/"*"/modules/sub" ]] && echo yes || echo no)" "$gitdir"
out="$(cd "$c5/super-wt" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "linked worktree: --check passes" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"

# Cleanup is scoped to the probe's own admin entry (#2460), and `module_dir` resolves differently in
# this layout (.git/worktrees/<wt>/modules/<path>) — so prove the scoped removal lands in the RIGHT
# place here too, or repeated runs would silently accumulate entries the old repo-wide prune used to
# sweep. Several runs, because a single one cannot show accumulation.
for _ in 1 2 3; do (cd "$c5/super-wt" && "$helper" --check >/dev/null 2>&1) || true; done
c5_mdir="$(cd "$c5/super-wt/sub" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
shopt -s nullglob
c5_left=("$c5_mdir/worktrees"/probe-iso-*)
shopt -u nullglob
report "linked worktree: repeated --check leaves no probe admin entries (scoped cleanup)" \
  "$([[ ${#c5_left[@]} -eq 0 ]] && echo yes || echo no)" "mdir=$c5_mdir leftover=${c5_left[*]:-none}"

# 6. Path comparison is by filesystem IDENTITY, not by spelling (#2457). The live defect was a
#    worktree recorded as `.Codex/…` and reported by git as `.codex/…` — one inode on a
#    case-insensitive volume, string-compared unequal, reported as ISOLATION BROKEN on a tree that
#    was fine. Case-folding is only reachable on a case-insensitive filesystem, so the portable proof
#    uses a SYMLINK alias: two spellings, one inode. Under the old `[ "$got" != "$want" ]` the alias
#    case fails; the negative controls below are what keep the fix from being a blanket "equal".
real="$tmp/c6-real"
mkdir -p "$real"
alias_link="$tmp/c6-alias"
ln -s "$real" "$alias_link"
other="$tmp/c6-other"
mkdir -p "$other"

# Sourcing must be side-effect-free (the guard sits above every top-level side effect), so it needs no
# fixture repo and must not move or kill the caller's shell.
same_dir_rc() (
  # shellcheck source=/dev/null
  . "$helper" >/dev/null 2>&1
  same_dir "$1" "$2"
)

# PRECONDITION, not a nicety: `same_dir_rc` runs in a subshell, so if sourcing failed to define
# `same_dir` at all, command-not-found exits non-zero and every "compare UNEQUAL" assertion below
# would report PASS against nothing. Pin that the helper is really there first.
# shellcheck source=/dev/null
( . "$helper" >/dev/null 2>&1 && declare -f same_dir >/dev/null ) && ok=yes || ok=no
report "same_dir: helper is defined when the script is sourced (guards the controls below)" "$ok"

same_dir_rc "$real" "$alias_link" && ok=yes || ok=no
report "same_dir: two spellings of ONE directory compare equal (symlink alias)" "$ok" \
  "real=$real alias=$alias_link"

same_dir_rc "$real" "$other" && ok=no || ok=yes
report "same_dir: genuinely different directories compare UNEQUAL (negative control)" "$ok" \
  "real=$real other=$other"

same_dir_rc "" "$real" && ok=no || ok=yes
report "same_dir: fails closed on one empty path" "$ok"

# THE fail-open the emptiness guard exists for, and the only line in the diff that changes a reachable
# outcome: `[ "" = "" ]` is TRUE, so without the guard two empty paths compare as "the same directory"
# and an unverifiable worktree is reported isolated. The one-empty case above passes either way
# (`[ -e "" ]` catches it), so it does NOT cover this.
same_dir_rc "" "" && ok=no || ok=yes
report "same_dir: fails closed when BOTH paths are empty (the pre-existing fail-open)" "$ok"

same_dir_rc "$real" "$tmp/c6-does-not-exist" && ok=no || ok=yes
report "same_dir: fails closed on a non-existent path" "$ok"

# The case variant that actually bit, end-to-end — only meaningful where the filesystem folds case,
# so probe for that rather than assuming the platform.
case_dir="$tmp/c6-CaseProbe"
mkdir -p "$case_dir"
if [[ -d "$tmp/c6-caseprobe" ]]; then
  same_dir_rc "$case_dir" "$tmp/c6-caseprobe" && ok=yes || ok=no
  report "same_dir: case-only difference compares equal on a case-insensitive filesystem" "$ok" \
    "$case_dir vs $tmp/c6-caseprobe"
else
  echo "SKIP: case-only comparison — filesystem is case-sensitive (covered by the symlink case above)"
fi

# 7. #2460 — an UNVERIFIABLE linked worktree must fail --check CLOSED, and the check must not destroy
#    the evidence it reads. `probe` used to run a repository-wide `git worktree prune` BEFORE
#    `check_existing_worktrees`; prune drops the admin entry of any worktree that is missing OR merely
#    unverifiable, so the sweep found nothing and reported `isolated ✓` on a colliding tree.
#    The fixture makes the worktree UNSEARCHABLE (chmod 0400): `-d` still passes, so the entry is not
#    skipped as "missing", while both `cd` and `git -C` fail — i.e. genuinely unverifiable.
c7="$tmp/c7"
mk_super "$c7"
live_wt="$c7/live-wt"
git -C "$c7/super/sub" worktree add -q --detach "$live_wt"
wt_admin="$c7/super/.git/modules/sub/worktrees"
chmod 0400 "$live_wt"
# Restore permissions on exit so the EXIT trap's `rm -rf "$tmp"` can actually remove the fixture.
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

# PRECONDITION: if the platform lets us read the dir anyway (running as root, or a filesystem that
# ignores the mode), the case under test never arises and the assertions below would pass vacuously.
if (cd "$live_wt") 2>/dev/null; then
  echo "SKIP: #2460 end-to-end — this platform can still enter a 0400 directory (vacuous otherwise)"
else
  out="$(cd "$c7/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
  report "unverifiable worktree: --check exits non-zero (fails closed)" \
    "$([[ $rc -ne 0 ]] && echo yes || echo no)" "$out"
  report "unverifiable worktree: reports ISOLATION BROKEN and names it" \
    "$(grep -q 'ISOLATION BROKEN' <<<"$out" && grep -q 'live-wt' <<<"$out" && echo yes || echo no)" "$out"
  report "unverifiable worktree: never reports the submodule isolated" \
    "$(grep -q 'sub — isolated' <<<"$out" && echo no || echo yes)" "$out"
  # The evidence-destruction half: the sibling's admin entry must SURVIVE the check.
  report "unverifiable worktree: the sibling's admin entry survives --check (not pruned)" \
    "$([[ -e "$wt_admin/live-wt" ]] && echo yes || echo no)" "$(ls "$wt_admin" 2>&1)"
fi

# 8. NEGATIVE CONTROL for 7 — the fix must not simply disable cleanup. On a clean tree, --check still
#    removes its OWN probe entry, leaving no `probe-iso-*` admin dir behind.
c8="$tmp/c8"
mk_super "$c8"
out="$(cd "$c8/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "cleanup: clean tree still passes --check" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
# A fully-cleaned tree may leave no `worktrees` dir at all, so `find` on a missing path must not abort
# the suite under `set -Eeuo pipefail` — glob instead, and count with no pipeline.
shopt -s nullglob
leftover_admin=("$c8/super/.git/modules/sub/worktrees"/probe-iso-*)
leftover_tree=("$c8/super/sub"/probe-iso-*)
shopt -u nullglob
report "cleanup: --check removes its own probe admin entry (no probe-iso-* left)" \
  "$([[ ${#leftover_admin[@]} -eq 0 ]] && echo yes || echo no)" "leftover=${leftover_admin[*]:-none}"
report "cleanup: --check leaves no probe worktree directory behind" \
  "$([[ ${#leftover_tree[@]} -eq 0 ]] && echo yes || echo no)" "leftover=${leftover_tree[*]:-none}"
# POSITIVE precondition: the two assertions above are pure ABSENCE checks, so they also pass when the
# helper never ran at all (a non-executable script leaves no probe dirs either). Pin that it ran.
report "cleanup: the probe actually ran (guards the absence assertions above)" \
  "$(grep -q 'sub — isolated' <<<"$out" && echo yes || echo no)" "$out"

# 9. #2460 follow-up — the probe self-exclusion must match THIS probe's admin dir by IDENTITY, never
#    by a path substring. Moving the sweep before cleanup promoted that filter from dead code into the
#    sweep's only self-exclusion, so an over-broad match became a live fail-open: a genuinely
#    unverifiable sibling whose path merely CONTAINS `/probe-iso-` was skipped and the submodule
#    reported isolated ✓.
c9="$tmp/c9"
mk_super "$c9"
mkdir -p "$c9/probe-iso-experiments"
c9_wt="$c9/probe-iso-experiments/live-wt"
git -C "$c9/super/sub" worktree add -q --detach "$c9_wt"
chmod 0400 "$c9_wt"
if (cd "$c9_wt") 2>/dev/null; then
  echo "SKIP: #2460 self-exclusion — this platform can still enter a 0400 directory (vacuous otherwise)"
else
  out="$(cd "$c9/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
  report "probe self-exclusion: an unverifiable sibling under a 'probe-iso-*' PATH still fails --check" \
    "$([[ $rc -ne 0 ]] && echo yes || echo no)" "$out"
  report "probe self-exclusion: it is reported, not silently skipped" \
    "$(grep -q 'ISOLATION BROKEN' <<<"$out" && echo yes || echo no)" "$out"
fi

# 10. The scoped removal must stand on its own. `worktree remove` normally deletes the admin entry, so
#     with it succeeding the new scoped `rm` is unobservable and a mutation test cannot see it. Force
#     `git worktree remove` to fail with a PATH shim, leaving the scoped rm as the only cleanup path.
#     Also pins that a PRE-EXISTING sibling entry survives and still works — the harm that removing by
#     NAME (rather than by resolved admin dir) would cause when git counter-appends on a collision.
c10="$tmp/c10"
mk_super "$c10"
c10_sib="$c10/sibling-wt"
git -C "$c10/super/sub" worktree add -q --detach "$c10_sib"
shim="$tmp/shim"
mkdir -p "$shim"
real_git="$(command -v git)"
cat >"$shim/git" <<EOF
#!/usr/bin/env bash
# Fail ONLY 'worktree remove'; everything else passes through untouched.
for a in "\$@"; do [[ "\$a" == "remove" ]] && seen_remove=1; [[ "\$a" == "worktree" ]] && seen_wt=1; done
if [[ -n "\${seen_wt:-}" && -n "\${seen_remove:-}" ]]; then exit 1; fi
exec "$real_git" "\$@"
EOF
chmod +x "$shim/git"
out="$(cd "$c10/super" && PATH="$shim:$PATH" "$helper" --check 2>&1)" && rc=0 || rc=$?
report "scoped cleanup: --check still passes when 'worktree remove' fails" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
shopt -s nullglob
c10_left=("$c10/super/.git/modules/sub/worktrees"/probe-iso-*)
shopt -u nullglob
report "scoped cleanup: the scoped rm alone removes the probe entry (worktree remove failing)" \
  "$([[ ${#c10_left[@]} -eq 0 ]] && echo yes || echo no)" "leftover=${c10_left[*]:-none}"
report "scoped cleanup: a pre-existing sibling worktree still exists afterwards" \
  "$([[ -e "$c10/super/.git/modules/sub/worktrees/sibling-wt" ]] && echo yes || echo no)"
report "scoped cleanup: that sibling worktree is still FUNCTIONAL (not just present)" \
  "$(git -C "$c10_sib" rev-parse --show-toplevel >/dev/null 2>&1 && echo yes || echo no)"

# 11. #2492 — init mode must FAIL when `git submodule update --init` exits 0 without populating.
#     Observed running from a linked superproject worktree while a sibling worktree already held the
#     submodule: git printed `checked out '<sha>'`, exited 0, left the directory EMPTY, and the script
#     still reported `isolated ✓` with exit 0 — `probe` verifies isolation, not content, so it passes
#     vacuously on an empty tree. Simulated here with the same PATH-shim technique as case 10 so the
#     reproduction is deterministic on every platform rather than depending on that git quirk.
#
#     ⚠️ HONEST LIMIT — the production symptom was a false SUCCESS (`isolated ✓`, exit 0). That exact
#     state could NOT be reproduced hermetically: in a fixture, an empty submodule has no gitdir, so
#     `probe` rejects it on its own and the run already fails without the guard. Two of the four
#     assertions below are therefore non-discriminating and are labelled as such. What IS proven RED
#     is the guard's real contribution — failing AT the init step with an accurate message, instead of
#     continuing into `repair` and emerging with a benign-sounding "nothing to probe". The guard is a
#     fail-closed POST-CONDITION, so it holds whatever made `update --init` no-op; do not weaken it to
#     match only the reproducible half.
c11="$tmp/c11"
mk_super "$c11"
git -C "$c11/super" submodule --quiet deinit -f sub >/dev/null
report "empty-init precondition: the submodule really is empty before the run" \
  "$([[ -z "$(ls -A "$c11/super/sub" 2>/dev/null)" ]] && echo yes || echo no)"
noop_shim="$tmp/shim-noop"
mkdir -p "$noop_shim"
cat >"$noop_shim/git" <<EOF
#!/usr/bin/env bash
# Make ONLY 'submodule update' a silent success; everything else passes through untouched. This is
# exactly the observed failure: exit 0, nothing populated.
for a in "\$@"; do [[ "\$a" == "submodule" ]] && seen_sub=1; [[ "\$a" == "update" ]] && seen_upd=1; done
if [[ -n "\${seen_sub:-}" && -n "\${seen_upd:-}" ]]; then exit 0; fi
exec "$real_git" "\$@"
EOF
chmod +x "$noop_shim/git"
out="$(cd "$c11/super" && PATH="$noop_shim:$PATH" "$helper" sub 2>&1)" && rc=0 || rc=$?
# NON-DISCRIMINATING context (both hold with the guard ablated, because `probe` then rejects the
# empty tree on its own path). Kept because they pin the overall contract, NOT as proof of the guard.
report "empty-init: init mode FAILS when the submodule is still empty afterwards" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "empty-init: it never reports 'isolated ✓' for an empty submodule" \
  "$(grep -q 'isolated ✓' <<<"$out" && echo no || echo yes)" "$out"
# THE discriminating assertion — verified RED with the guard ablated. Without it the run still exits
# non-zero, but only after `repair`, and the message is `not checked out here; nothing to probe`,
# which reads as a benign skip rather than a failed init. The guard fails immediately, at the step
# that actually broke, and says so.
report "empty-init: the failure NAMES the empty submodule (fails at init, not later as a 'skip')" \
  "$(grep -q 'STILL EMPTY' <<<"$out" && echo yes || echo no)" "$out"
# `--check` must be UNCHANGED: an uninitialised submodule is legitimately empty there and is skipped,
# not failed. Without this, the fix above could be "achieved" by failing on every empty submodule.
out="$(cd "$c11/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "empty-init: --check still SKIPS a legitimately deinitialised submodule" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc $out"
# 12. --advance: move a populated checkout to a newer recorded pin WITHOUT
#    `git submodule update` (which rewrites shared core.worktree). Hermetic
#    fixture: bump the gitlink in the index while leaving the working tree on
#    the old SHA, then advance and assert HEAD + isolation.
c12="$tmp/c12"
mk_super "$c11"
(
  cd "$c12/remote-sub"
  echo next >file.txt
  git add file.txt
  git commit -q -m next
)
new_sha="$(git -C "$c12/remote-sub" rev-parse HEAD)"
old_sha="$(git -C "$c12/super/sub" rev-parse HEAD)"
(
  cd "$c12/super"
  # Record the new pin in the superproject without moving the working tree.
  git update-index --cacheinfo "160000,$new_sha,sub"
  git commit -q -m "bump sub"
)
report "advance fixture: working tree still on old pin before --advance" \
  "$([[ "$(git -C "$c12/super/sub" rev-parse HEAD)" == "$old_sha" ]] && echo yes || echo no)"
# Make the new object reachable in the submodule (file:// remote).
git -C "$c12/super/sub" fetch -q origin
out="$(cd "$c12/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance: exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
report "advance: checkout moved to the recorded pin" \
  "$([[ "$(git -C "$c12/super/sub" rev-parse HEAD)" == "$new_sha" ]] && echo yes || echo no)"
report "advance: does not leave a shared core.worktree" \
  "$([[ -z "$(git config -f "$c12/super/.git/modules/sub/config" core.worktree 2>/dev/null || true)" ]] && echo yes || echo no)"
out="$(cd "$c12/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "advance: --check passes afterwards" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"

# 13. --advance refuses a dirty working tree.
c13="$tmp/c13"
mk_super "$c12"
echo dirty >>"$c13/super/sub/file.txt"
out="$(cd "$c13/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance dirty: exits non-zero" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "$out"
report "advance dirty: names the dirty-tree refusal" \
  "$(grep -q 'dirty working tree' <<<"$out" && echo yes || echo no)" "$out"

# 14. --advance refuses a checkout that is ahead of the recorded pin.
c14="$tmp/c14"
mk_super "$c13"
pin="$(git -C "$c14/super/sub" rev-parse HEAD)"
(
  cd "$c14/super/sub"
  echo local >extra.txt
  git add extra.txt
  git commit -q -m local-ahead
)
# Superproject gitlink still points at the old pin; checkout is one commit ahead.
report "advance ahead fixture: gitlink still at old pin" \
  "$([[ "$(git -C "$c14/super" rev-parse HEAD:sub)" == "$pin" ]] && echo yes || echo no)"
out="$(cd "$c14/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance ahead: exits non-zero" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "$out"
report "advance ahead: names the ahead-of-pin refusal" \
  "$(grep -q 'ahead of the recorded pin' <<<"$out" && echo yes || echo no)" "$out"
if [[ $fail -ne 0 ]]; then
  echo "submodule-init self-test: FAILURES above" >&2
  exit 1
fi
echo "submodule-init self-test: all cases passed"
