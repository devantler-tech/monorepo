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
mk_super "$c12"
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
# Deliberately NOT fetched here: the script's own target-fetch path (cat-file miss -> fetch) is
# part of what this case exercises. Pre-fetching made `cat-file -e` succeed and skipped it entirely.
report "advance fixture: the target object is absent before --advance" \
  "$(git -C "$c12/super/sub" cat-file -e "${new_sha}^{commit}" 2>/dev/null && echo no || echo yes)"
out="$(cd "$c12/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance: exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
report "advance: checkout moved to the recorded pin" \
  "$([[ "$(git -C "$c12/super/sub" rev-parse HEAD)" == "$new_sha" ]] && echo yes || echo no)"
report "advance: does not leave a shared core.worktree" \
  "$([[ -z "$(git config -f "$c12/super/.git/modules/sub/config" core.worktree 2>/dev/null || true)" ]] && echo yes || echo no)"
out="$(cd "$c12/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "advance: --check passes afterwards" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
c12_excludes="$c12/excludes"
printf 'ignored.log\n' >"$c12_excludes"
git -C "$c12/super/sub" config core.excludesFile "$c12_excludes"
echo reusable-cache >"$c12/super/sub/ignored.log"
report "advance already-at-pin ignored precondition: status stays clean" \
  "$([[ -z "$(git -C "$c12/super/sub" status --porcelain --untracked-files=all)" ]] && echo yes || echo no)"
out="$(cd "$c12/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance already-at-pin ignored: exits 0 without a checkout" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance already-at-pin ignored: preserves the ignored artifact" \
  "$([[ "$(cat "$c12/super/sub/ignored.log")" == "reusable-cache" ]] && echo yes || echo no)"

# 13. --advance refuses a dirty working tree.
c13="$tmp/c13"
mk_super "$c13"
echo dirty >>"$c13/super/sub/file.txt"
out="$(cd "$c13/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance dirty: exits non-zero" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "$out"
report "advance dirty: names the dirty-tree refusal" \
  "$(grep -q 'dirty working tree' <<<"$out" && echo yes || echo no)" "$out"

# 14. --advance refuses a checkout that is ahead of the recorded pin.
c14="$tmp/c14"
mk_super "$c14"
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

# 15. monorepo#2694 — a registered submodule that is NON-EMPTY but NOT INITIALISED (no `.git`) must
#     never make `repair` write into the SUPERPROJECT's config. `is_populated` only asks "is the
#     directory non-empty", so a leftover file is enough to route such a path into `repair`; there
#     `git -C <path> rev-parse --git-common-dir` walks UP and returns the superproject's gitdir, and
#     repair then pins `core.worktree` in the PARENT repo's per-worktree config — redirecting the
#     parent's main checkout at the submodule directory.
#
#     Measured on the live host 2026-08-06: the monorepo main checkout resolved to
#     `<monorepo>/.claude/worktrees/<slug>/platform`, `git status` reported 182 phantom deletions, and
#     the contract-mandated end-of-tick `branch-cleanup.sh` fail-closed on EVERY tick as a result.
#     The blast radius is the parent repository and every session sharing it, which is why this fails
#     closed rather than best-effort repairing.
c15="$tmp/c15"
mk_super "$c15"
git -C "$c15/super" submodule --quiet deinit -f sub >/dev/null
# The state that bit: not empty, but carrying no `.git` — so `is_populated` says yes and git escapes up.
echo leftover >"$c15/super/sub/leftover.txt"

report "parent-escape precondition: the submodule dir is non-empty" \
  "$([[ -n "$(ls -A "$c15/super/sub" 2>/dev/null)" ]] && echo yes || echo no)"
report "parent-escape precondition: it has no .git of its own" \
  "$([[ ! -e "$c15/super/sub/.git" ]] && echo yes || echo no)"
# PRECONDITION that makes the whole case meaningful: git really does resolve this path to the PARENT.
# If some future git stopped escaping upward, the assertions below would pass vacuously.
c15_escaped="$(cd "$c15/super/sub" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
report "parent-escape precondition: git -C on it resolves to the SUPERPROJECT gitdir" \
  "$([[ "$c15_escaped" -ef "$c15/super/.git" ]] && echo yes || echo no)" "got=$c15_escaped"

out="$(cd "$c15/super" && "$helper" sub 2>&1)" && rc=0 || rc=$?

# THE discriminating assertion — this is the production harm, and it is what goes RED without the fix.
c15_parent_key="$(git config -f "$c15/super/.git/config.worktree" core.worktree 2>/dev/null || true)"
report "parent-escape: never writes core.worktree into the SUPERPROJECT's per-worktree config" \
  "$([[ -z "$c15_parent_key" ]] && echo yes || echo no)" "parent core.worktree=${c15_parent_key:-<unset>}"

# The same harm stated as the user-visible symptom (#2694 AC-1): the parent still resolves to itself.
c15_top="$(git -C "$c15/super" rev-parse --show-toplevel 2>/dev/null || true)"
report "parent-escape: the superproject still resolves to its OWN root" \
  "$([[ -n "$c15_top" && "$c15_top" -ef "$c15/super" ]] && echo yes || echo no)" "toplevel=$c15_top"

report "parent-escape: the run FAILS rather than reporting success" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "parent-escape: it never reports 'isolated ✓'" \
  "$(grep -q 'isolated ✓' <<<"$out" && echo no || echo yes)" "$out"

# NEGATIVE CONTROL — the fix must refuse only the escaping case, not every repair. A genuinely
# initialised submodule must still be repaired and probed exactly as case 3 requires.
c15b="$tmp/c15b"
mk_super "$c15b"
out="$(cd "$c15b/super" && "$helper" sub 2>&1)" && rc=0 || rc=$?
report "parent-escape negative control: a properly initialised submodule still repairs (exit 0)" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "parent-escape negative control: its core.worktree is still pinned to the submodule's own path" \
  "$([[ "$(git config -f "$c15b/super/.git/modules/sub/config.worktree" core.worktree 2>/dev/null || true)" == "$(abspath "$c15b/super/sub")" ]] && echo yes || echo no)"


# 15c. The second guard, and why it is not redundant with the `.git`-existence check: a `.git` that
#      EXISTS but points at the superproject passes that check while still resolving outward. Same
#      harm, different route — so it gets its own reproduction rather than riding on 12's.
c15c="$tmp/c15c"
mk_super "$c15c"
git -C "$c15c/super" submodule --quiet deinit -f sub >/dev/null
printf 'gitdir: %s\n' "$(abspath "$c15c/super")/.git" >"$c15c/super/sub/.git"
report "outward-.git precondition: the .git entry exists (an existence check would NOT catch this)" \
  "$([[ -e "$c15c/super/sub/.git" ]] && echo yes || echo no)"
out="$(cd "$c15c/super" && "$helper" sub 2>&1)" && rc=0 || rc=$?
c15c_parent_key="$(git config -f "$c15c/super/.git/config.worktree" core.worktree 2>/dev/null || true)"
report "outward-.git: never writes core.worktree into the SUPERPROJECT's per-worktree config" \
  "$([[ -z "$c15c_parent_key" ]] && echo yes || echo no)" "parent core.worktree=${c15c_parent_key:-<unset>}"
report "outward-.git: the failure names the SUPERPROJECT gitdir" \
  "$(grep -q "SUPERPROJECT's gitdir" <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 16. --advance must repair isolation BEFORE it runs any other `git -C <path>` command. A stale
#     shared `core.worktree` redirects that path at ANOTHER session's worktree, so every later
#     `git -C` reads that directory instead of the submodule.
#
#     MEASURED pre-fix behaviour (this is what the two discriminating assertions below catch, and
#     it is deliberately NOT the "writes into the other worktree" story): `status --porcelain` runs
#     first, sees the redirected-and-empty decoy against a HEAD that has files, calls that a dirty
#     working tree, and dies. So `--advance` fails with a misleading diagnosis on a checkout that
#     is not dirty at all, and — because it died before reaching the repair — leaves the stale
#     redirect in place for the next command to trip over. Repairing first makes the same run
#     succeed and clears the redirect.
c16="$tmp/c16"
mk_super "$c16"
(
  cd "$c16/remote-sub"
  echo next >file.txt
  git add file.txt
  git commit -q -m next
)
c16_new="$(git -C "$c16/remote-sub" rev-parse HEAD)"
(
  cd "$c16/super"
  git update-index --cacheinfo "160000,$c16_new,sub"
  git commit -q -m "bump sub"
)
# The victim: a directory standing in for another session's worktree.
c16_decoy="$c16/other-session-worktree"
mkdir -p "$c16_decoy"
# The hazard: a stale SHARED core.worktree pointing the submodule's gitdir at that directory.
git config -f "$c16/super/.git/modules/sub/config" core.worktree "$(abspath "$c16_decoy")"
report "stale-redirect precondition: the shared core.worktree points at the other worktree" \
  "$([[ "$(git config -f "$c16/super/.git/modules/sub/config" core.worktree)" == "$(abspath "$c16_decoy")" ]] && echo yes || echo no)"
report "stale-redirect precondition: the other worktree is empty before --advance" \
  "$([[ -z "$(ls -A "$c16_decoy" 2>/dev/null)" ]] && echo yes || echo no)"

out="$(cd "$c16/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?

# DISCRIMINATING (both go RED when the repair is moved back after the checkout):
report "stale-redirect: the stale shared core.worktree is cleared" \
  "$([[ -z "$(git config -f "$c16/super/.git/modules/sub/config" core.worktree 2>/dev/null || true)" ]] && echo yes || echo no)"
report "stale-redirect: --advance exits successfully" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "stale-redirect: --advance checks out the recorded pin" \
  "$([[ "$(git -C "$c16/super/sub" rev-parse HEAD 2>/dev/null)" == "$c16_new" ]] && echo yes || echo no)" "rc=$rc $out"

# SAFETY INVARIANT, not a discriminator: it holds pre-fix too, because the pre-fix run dies at the
# dirty-tree check before any checkout. Kept so a future reordering that DOES reach `checkout` with
# the redirect live cannot land silently.
report "stale-redirect: --advance never writes into the other session's worktree" \
  "$([[ -z "$(ls -A "$c16_decoy" 2>/dev/null)" ]] && echo yes || echo no)" \
  "decoy contains: $(ls -A "$c16_decoy" 2>/dev/null | tr '\n' ' ')"

# 17. Hidden index flags make `status --porcelain` lie about cleanliness. Both forms must stop an
#     advance before checkout, even when the flagged file is unchanged between the two pins (the
#     exact case where checkout otherwise carries the hidden edit forward and exits successfully).
for flag in assume-unchanged skip-worktree; do
  c17="$tmp/c17-$flag"
  mk_super "$c17"
  c17_old="$(git -C "$c17/super/sub" rev-parse HEAD)"
  (
    cd "$c17/remote-sub"
    echo target >added.txt
    git add added.txt
    git commit -q -m "target pin"
  )
  c17_target="$(git -C "$c17/remote-sub" rev-parse HEAD)"
  (
    cd "$c17/super"
    git update-index --cacheinfo "160000,$c17_target,sub"
    git commit -q -m "bump sub"
  )
  git -C "$c17/super/sub" update-index "--$flag" file.txt
  echo "hidden edit" >>"$c17/super/sub/file.txt"
  report "advance hidden-$flag precondition: status is empty despite the edit" \
    "$([[ -z "$(git -C "$c17/super/sub" status --porcelain)" ]] && echo yes || echo no)"
  out="$(cd "$c17/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
  report "advance hidden-$flag: exits non-zero" \
    "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
  report "advance hidden-$flag: leaves the checkout at the old pin" \
    "$([[ "$(git -C "$c17/super/sub" rev-parse HEAD)" == "$c17_old" ]] && echo yes || echo no)"
  report "advance hidden-$flag: preserves the hidden edit" \
    "$(grep -q 'hidden edit' "$c17/super/sub/file.txt" && echo yes || echo no)"
done

# 18. A superproject replace ref must not substitute a different gitlink for the one recorded by
#     the actual HEAD commit. The helper must resolve HEAD:<path> with replacement objects disabled.
c18="$tmp/c18"
mk_super "$c18"
c18_parent="$(git -C "$c18/remote-sub" rev-parse HEAD)"
(
  cd "$c18/remote-sub"
  echo legitimate >legitimate.txt
  git add legitimate.txt
  git commit -q -m legitimate
)
c18_legitimate="$(git -C "$c18/remote-sub" rev-parse HEAD)"
(
  cd "$c18/remote-sub"
  git checkout -q --detach "$c18_parent"
  echo substituted >substituted.txt
  git add substituted.txt
  git commit -q -m substituted
  git checkout -q main
)
c18_substituted="$(git -C "$c18/remote-sub" rev-parse --verify "HEAD@{1}")"
(
  cd "$c18/super"
  git update-index --cacheinfo "160000,$c18_legitimate,sub"
  git commit -q -m "record legitimate pin"
  c18_actual_head="$(git rev-parse HEAD)"
  git update-index --cacheinfo "160000,$c18_substituted,sub"
  c18_replacement_tree="$(git write-tree)"
  c18_replacement_head="$(printf 'replacement head\n' | git commit-tree "$c18_replacement_tree" -p "$(git rev-parse "${c18_actual_head}^")")"
  git read-tree "$c18_actual_head"
  git replace "$c18_actual_head" "$c18_replacement_head"
)
report "advance super-replace precondition: ordinary HEAD:sub is substituted" \
  "$([[ "$(git -C "$c18/super" rev-parse HEAD:sub)" == "$c18_substituted" ]] && echo yes || echo no)"
report "advance super-replace precondition: no-replace HEAD:sub is legitimate" \
  "$([[ "$(git --no-replace-objects -C "$c18/super" rev-parse HEAD:sub)" == "$c18_legitimate" ]] && echo yes || echo no)"
out="$(cd "$c18/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance super-replace: exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance super-replace: checks out the actual HEAD gitlink" \
  "$([[ "$(git -C "$c18/super/sub" rev-parse HEAD)" == "$c18_legitimate" ]] && echo yes || echo no)" \
  "actual=$(git -C "$c18/super/sub" rev-parse HEAD) expected=$c18_legitimate"

# 19. Replacement refs in the submodule must not change the tree materialised for the recorded SHA.
#     Git otherwise leaves HEAD naming the requested target while checking out substituted contents.
c19="$tmp/c19"
mk_super "$c19"
c19_parent="$(git -C "$c19/remote-sub" rev-parse HEAD)"
(
  cd "$c19/remote-sub"
  echo legitimate >file.txt
  git add file.txt
  git commit -q -m legitimate
)
c19_target="$(git -C "$c19/remote-sub" rev-parse HEAD)"
(
  cd "$c19/remote-sub"
  git checkout -q --detach "$c19_parent"
  echo substituted >file.txt
  git add file.txt
  git commit -q -m substituted
)
c19_substituted="$(git -C "$c19/remote-sub" rev-parse HEAD)"
git -C "$c19/super/sub" fetch -q origin "$c19_target"
git -C "$c19/super/sub" fetch -q origin "$c19_substituted"
git -C "$c19/super/sub" replace "$c19_target" "$c19_substituted"
(
  cd "$c19/super"
  git update-index --cacheinfo "160000,$c19_target,sub"
  git commit -q -m "record target pin"
)
report "advance submodule-replace precondition: ordinary target tree is substituted" \
  "$([[ "$(git -C "$c19/super/sub" show "$c19_target:file.txt")" == "substituted" ]] && echo yes || echo no)"
report "advance submodule-replace precondition: no-replace target tree is legitimate" \
  "$([[ "$(git --no-replace-objects -C "$c19/super/sub" show "$c19_target:file.txt")" == "legitimate" ]] && echo yes || echo no)"
out="$(cd "$c19/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance submodule-replace: exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance submodule-replace: materialises the recorded commit's real tree" \
  "$([[ "$(cat "$c19/super/sub/file.txt")" == "legitimate" ]] && echo yes || echo no)" \
  "contents=$(cat "$c19/super/sub/file.txt")"

# 20. The old pin may ignore a path that the new pin starts tracking. Ordinary checkout overwrites
#     that local ignored file; --no-overwrite-ignore must instead abort and preserve it.
c20="$tmp/c20"
mk_super "$c20"
(
  cd "$c20/remote-sub"
  echo future.txt >.gitignore
  git add .gitignore
  git commit -q -m "ignore future path"
)
c20_old="$(git -C "$c20/remote-sub" rev-parse HEAD)"
git -C "$c20/super/sub" fetch -q origin "$c20_old"
git -C "$c20/super/sub" checkout -q --detach "$c20_old"
(
  cd "$c20/super"
  git update-index --cacheinfo "160000,$c20_old,sub"
  git commit -q -m "record ignore pin"
)
(
  cd "$c20/remote-sub"
  git rm -q .gitignore
  echo tracked-by-target >future.txt
  git add future.txt
  git commit -q -m "track future path"
)
c20_target="$(git -C "$c20/remote-sub" rev-parse HEAD)"
(
  cd "$c20/super"
  git update-index --cacheinfo "160000,$c20_target,sub"
  git commit -q -m "bump to tracked path"
)
echo precious-local-work >"$c20/super/sub/future.txt"
report "advance ignored-file precondition: status is empty" \
  "$([[ -z "$(git -C "$c20/super/sub" status --porcelain)" ]] && echo yes || echo no)"
out="$(cd "$c20/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance ignored-file: exits non-zero" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance ignored-file: preserves ignored local work" \
  "$([[ "$(cat "$c20/super/sub/future.txt")" == "precious-local-work" ]] && echo yes || echo no)" \
  "contents=$(cat "$c20/super/sub/future.txt")"

# 21. A caller may have submodule.recurse=true in the populated submodule. The outer detach must
#     override that setting: --advance owns only the named checkout and must not mutate nested
#     submodules implicitly while moving it to the recorded pin.
c21="$tmp/c21"
mkdir -p "$c21"
git init -q "$c21/remote-nested"
(
  cd "$c21/remote-nested"
  echo old >nested.txt
  git add nested.txt
  git commit -q -m old
)
c21_nested_old="$(git -C "$c21/remote-nested" rev-parse HEAD)"
(
  cd "$c21/remote-nested"
  echo new >nested.txt
  git add nested.txt
  git commit -q -m new
)
c21_nested_new="$(git -C "$c21/remote-nested" rev-parse HEAD)"
git init -q "$c21/remote-sub"
(
  cd "$c21/remote-sub"
  echo outer >outer.txt
  git add outer.txt
  git commit -q -m init
  git submodule add -q ../remote-nested nested
  git -C nested checkout -q --detach "$c21_nested_old"
  git add .gitmodules nested
  git commit -q -m "record old nested pin"
)
c21_outer_old="$(git -C "$c21/remote-sub" rev-parse HEAD)"
(
  cd "$c21/remote-sub"
  git -C nested checkout -q --detach "$c21_nested_new"
  git add nested
  git commit -q -m "record new nested pin"
)
c21_outer_new="$(git -C "$c21/remote-sub" rev-parse HEAD)"
git init -q "$c21/super"
(
  cd "$c21/super"
  echo root >root.txt
  git add root.txt
  git commit -q -m init
  git submodule add -q ../remote-sub sub
  git -C sub checkout -q --detach "$c21_outer_old"
  git -C sub submodule update -q --init nested
  git add sub
  git commit -q -m "record old outer pin"
  git update-index --cacheinfo "160000,$c21_outer_new,sub"
  git commit -q -m "bump outer pin"
)
git -C "$c21/super/sub" config submodule.recurse true
report "advance no-recurse precondition: nested checkout is at the old pin" \
  "$([[ "$(git -C "$c21/super/sub/nested" rev-parse HEAD)" == "$c21_nested_old" ]] && echo yes || echo no)"
out="$(cd "$c21/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance no-recurse: fails closed on the stale nested checkout" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance no-recurse: names the nested mismatch" \
  "$(grep -q 'nested submodule checkout does not match' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
report "advance no-recurse: moves the named checkout to the recorded pin" \
  "$([[ "$(git -C "$c21/super/sub" rev-parse HEAD)" == "$c21_outer_new" ]] && echo yes || echo no)"
report "advance no-recurse: leaves the nested checkout untouched" \
  "$([[ "$(git -C "$c21/super/sub/nested" rev-parse HEAD)" == "$c21_nested_old" ]] && echo yes || echo no)" \
  "actual=$(git -C "$c21/super/sub/nested" rev-parse HEAD) expected=$c21_nested_old"
# A local ignore rule can hide that mismatch from the top-level status pre-check. Repeating
# --advance at the now-current outer pin must still run the explicit recursive validation.
git -C "$c21/super/sub" config submodule.nested.ignore all
report "advance already-at-pin precondition: status hides the stale nested checkout" \
  "$([[ -z "$(git -C "$c21/super/sub" status --porcelain --untracked-files=all)" ]] && echo yes || echo no)"
out="$(cd "$c21/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance already-at-pin: still fails closed on the stale nested checkout" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance already-at-pin: still names the nested mismatch" \
  "$(grep -q 'nested submodule checkout does not match' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 22. Removing an initialized nested submodule makes recursive status vacuous because the target no
#     longer declares that gitlink. The old nested repository remains as residue, and a target-side
#     ignore rule hides it from both status and a single-force clean dry run. The stronger embedded-
#     repository probe must detect it on the transition and on an already-at-pin retry.
git -C "$c21/super/sub/nested" checkout -q --detach "$c21_nested_new"
(
  cd "$c21/remote-sub"
  git rm -qf nested
  printf 'nested/\n' >.gitignore
  git add .gitignore .gitmodules
  git commit -q -m "remove nested submodule"
)
c22_outer_removed="$(git -C "$c21/remote-sub" rev-parse HEAD)"
(
  cd "$c21/super"
  git update-index --cacheinfo "160000,$c22_outer_removed,sub"
  git commit -q -m "record outer pin without nested"
)
report "advance removed-nested precondition: named checkout is clean" \
  "$([[ -z "$(git -C "$c21/super/sub" status --porcelain --untracked-files=all)" ]] && echo yes || echo no)"
out="$(cd "$c21/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance removed-nested: fails closed on residual files" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance removed-nested: names the residual checkout" \
  "$(grep -q 'residual files after advancing' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
report "advance removed-nested: moves the named checkout to the recorded pin" \
  "$([[ "$(git -C "$c21/super/sub" rev-parse HEAD)" == "$c22_outer_removed" ]] && echo yes || echo no)"
report "advance removed-nested: preserves the old nested repository for explicit handling" \
  "$([[ -e "$c21/super/sub/nested/.git" ]] && echo yes || echo no)"
report "advance removed-nested retry precondition: ignored residue is hidden from status" \
  "$([[ -z "$(git -C "$c21/super/sub" status --porcelain --untracked-files=all --ignore-submodules=none)" ]] && echo yes || echo no)"
out="$(cd "$c21/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance removed-nested retry: still fails closed at the recorded pin" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance removed-nested retry: still names the residual checkout" \
  "$(grep -q 'residual files after advancing' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

if [[ $fail -ne 0 ]]; then
  echo "submodule-init self-test: FAILURES above" >&2
  exit 1
fi
echo "submodule-init self-test: all cases passed"
