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
# Gitdir-only checkout: `update --init` writes the `.git` link and then no files. The directory is
# not empty, so the STILL EMPTY guard cannot see it, and isolation alone would pass. The pinned
# commit has a tracked file, so a correct checkout would contain it.
c11b="$tmp/c11b"
mk_super "$c11b"
git -C "$c11b/super" submodule --quiet deinit -f sub >/dev/null
gitdir_only_shim="$tmp/shim-gitdir-only"
mkdir -p "$gitdir_only_shim"
cat >"$gitdir_only_shim/git" <<SHIM
#!/usr/bin/env bash
# Run 'submodule update' for real, then strip every checked-out entry except the .git link.
for a in "\$@"; do [[ "\$a" == "submodule" ]] && seen_sub=1; [[ "\$a" == "update" ]] && seen_upd=1; done
"$real_git" "\$@" || exit \$?
if [[ -n "\${seen_sub:-}" && -n "\${seen_upd:-}" ]]; then
  find sub -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
fi
SHIM
chmod +x "$gitdir_only_shim/git"
out="$(cd "$c11b/super" && PATH="$gitdir_only_shim:$PATH" "$helper" sub 2>&1)" && rc=0 || rc=$?
report "gitdir-only init precondition: only the .git link was left" \
  "$([[ "$(ls -A "$c11b/super/sub")" == ".git" ]] && echo yes || echo no)" "$(ls -A "$c11b/super/sub" | tr '\n' ' ')"
report "gitdir-only init: fails, names the incomplete checkout, and never reports isolated" \
  "$([[ $rc -ne 0 ]] && grep -q 'INCOMPLETE' <<<"$out" && ! grep -q 'isolated ✓' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
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
c12_excludes="$c12/excludes"
printf 'ignored.log\n' >"$c12_excludes"
git -C "$c12/super/sub" config core.excludesFile "$c12_excludes"
echo reusable-cache >"$c12/super/sub/ignored.log"
report "advance ignored-artifact precondition: status stays clean before the transition" \
  "$([[ -z "$(git -C "$c12/super/sub" status --porcelain --untracked-files=all)" ]] && echo yes || echo no)"
out="$(cd "$c12/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance: exits 0" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
report "advance: checkout moved to the recorded pin" \
  "$([[ "$(git -C "$c12/super/sub" rev-parse HEAD)" == "$new_sha" ]] && echo yes || echo no)"
report "advance ignored-artifact: preserves the artifact across the transition" \
  "$([[ "$(cat "$c12/super/sub/ignored.log")" == "reusable-cache" ]] && echo yes || echo no)"
report "advance: does not leave a shared core.worktree" \
  "$([[ -z "$(git config -f "$c12/super/.git/modules/sub/config" core.worktree 2>/dev/null || true)" ]] && echo yes || echo no)"
out="$(cd "$c12/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "advance: --check passes afterwards" "$([[ $rc -eq 0 ]] && echo yes || echo no)" "$out"
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

# Matching the nested gitlink is not enough: ignore=all can hide tracked dirt from the outer status,
# and recursive submodule status reports only the matching commit marker.
git -C "$c21/super/sub/nested" checkout -q --detach "$c21_nested_new"
echo locally-modified >>"$c21/super/sub/nested/nested.txt"
report "advance nested-dirty precondition: parent status hides the tracked edit" \
  "$([[ -z "$(git -C "$c21/super/sub" status --porcelain --untracked-files=all)" ]] && echo yes || echo no)"
report "advance nested-dirty precondition: recursive status still reports a matching pin" \
  "$(sub_status="$(git -C "$c21/super/sub" submodule status --recursive)" && grep -q '^ ' <<<"$sub_status" && echo yes || echo no)"
out="$(cd "$c21/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance nested-dirty: fails closed at the recorded outer pin" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance nested-dirty: names the residual checkout" \
  "$(grep -q 'residual files after advancing' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
git -C "$c21/super/sub/nested" restore nested.txt

# Hidden index flags suppress the same tracked edit even from the nested repository's own status.
# Validate both forms at every initialized level, not only in the named outer checkout.
for flag in assume-unchanged skip-worktree; do
  git -C "$c21/super/sub/nested" update-index "--$flag" nested.txt
  echo "hidden-$flag" >>"$c21/super/sub/nested/nested.txt"
  report "advance nested-hidden-$flag precondition: parent status is empty" \
    "$([[ -z "$(git -C "$c21/super/sub" status --porcelain --untracked-files=all --ignore-submodules=none)" ]] && echo yes || echo no)"
  out="$(cd "$c21/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
  report "advance nested-hidden-$flag: fails closed at the recorded outer pin" \
    "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
  report "advance nested-hidden-$flag: names the hidden nested index flags" \
    "$(grep -q 'nested submodule has assume-unchanged/skip-worktree files' <<<"$out" && echo yes || echo no)" \
    "rc=$rc $out"
  report "advance nested-hidden-$flag: preserves the hidden edit" \
    "$(grep -q "hidden-$flag" "$c21/super/sub/nested/nested.txt" && echo yes || echo no)"
  git -C "$c21/super/sub/nested" update-index --no-assume-unchanged nested.txt
  git -C "$c21/super/sub/nested" update-index --no-skip-worktree nested.txt
  git -C "$c21/super/sub/nested" restore nested.txt
done

# A stale shared core.worktree can redirect the nested repository at another session while its HEAD
# still matches the gitlink. Parent status and recursive pin markers both remain clean under ignore=all.
c21_nested_gitdir="$(git -C "$c21/super/sub/nested" rev-parse --path-format=absolute --git-common-dir)"
c21_nested_decoy="$c21/nested-other-session"
mkdir -p "$c21_nested_decoy"
git config -f "$c21_nested_gitdir/config" core.worktree "$c21_nested_decoy"
c21_nested_top="$(git -C "$c21/super/sub/nested" rev-parse --show-toplevel)"
report "advance nested-isolation precondition: nested checkout resolves to the decoy" \
  "$([[ "$c21_nested_top" -ef "$c21_nested_decoy" ]] && echo yes || echo no)" \
  "got=$c21_nested_top configured=$(git config -f "$c21_nested_gitdir/config" core.worktree 2>/dev/null || true)"
report "advance nested-isolation precondition: parent status stays empty" \
  "$([[ -z "$(git -C "$c21/super/sub" status --porcelain --untracked-files=all)" ]] && echo yes || echo no)"
out="$(cd "$c21/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "advance nested-isolation: fails closed at the recorded outer pin" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "advance nested-isolation: names the nested isolation failure" \
  "$(grep -q 'nested submodule isolation' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
git config -f "$c21_nested_gitdir/config" --unset-all core.worktree

# 22. Removing an initialized nested submodule makes recursive status vacuous because the target no
#     longer declares that gitlink. The old nested repository remains as residue, and a target-side
#     ignore rule hides it from both status and a single-force clean dry run. The stronger embedded-
#     repository probe must detect it on the transition and on an already-at-pin retry.
git -C "$c21/super/sub/nested" checkout -q --detach "$c21_nested_new"
git -C "$c21/super/sub" config --unset submodule.nested.ignore
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
  "$(grep -q 'embedded repository residue after advancing' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
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
  "$(grep -q 'embedded repository residue after advancing' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# --- --sync (monorepo#2833): after the superproject moves from <from> to a PR head, every changed
# gitlink must end on HEAD's pin. Detaching moves only the superproject; these cases prove the
# submodule half: a changed pin is advanced, an added submodule is populated, a removed one that
# left content behind is refused, and every failure is loud.
c40="$tmp/c40"
mk_super "$c40"
c40_from="$(git -C "$c40/super" rev-parse HEAD)"
(
  cd "$c40/remote-sub"
  echo next >file.txt
  git add file.txt
  git commit -q -m next
)
c40_new="$(git -C "$c40/remote-sub" rev-parse HEAD)"
(
  cd "$c40/super"
  git update-index --cacheinfo "160000,$c40_new,sub"
  git commit -q -m "bump sub"
)
report "sync fixture: the superproject is on the bump while sub is still on the old pin" \
  "$([[ "$(git -C "$c40/super" submodule status -- sub)" == +* ]] && echo yes || echo no)"
out="$(cd "$c40/super" && "$helper" --sync HEAD 2>&1)" && rc=0 || rc=$?
report "sync: no change since <from> is a no-op that exits 0" \
  "$([[ $rc -eq 0 ]] && grep -q 'in sync with HEAD' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
echo dirt >"$c40/super/sub/dirt.txt"
out="$(cd "$c40/super" && "$helper" --sync "$c40_from" 2>&1)" && rc=0 || rc=$?
report "sync: a dirty checkout on a changed pin fails closed" \
  "$([[ $rc -ne 0 ]] && grep -q 'dirty working tree' <<<"$out" && ! grep -q 'in sync with HEAD' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
rm "$c40/super/sub/dirt.txt"
out="$(cd "$c40/super" && "$helper" --sync "$c40_from" 2>&1)" && rc=0 || rc=$?
report "sync: a changed pin is advanced and the run exits 0" \
  "$([[ $rc -eq 0 ]] && [[ "$(git -C "$c40/super/sub" rev-parse HEAD)" == "$c40_new" ]] && echo yes || echo no)" "rc=$rc $out"
report "sync: the changed path reads as in sync afterwards" \
  "$([[ "$(git -C "$c40/super" submodule status -- sub)" == ' '* ]] && echo yes || echo no)"
out="$(cd "$c40/super" && "$helper" --sync not-a-commit 2>&1)" && rc=0 || rc=$?
report "sync: an unknown <from> fails closed" \
  "$([[ $rc -ne 0 ]] && grep -q 'is not a commit' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# Added and removed submodules, driven from a linked superproject worktree (the agent execution
# model), where a detach onto a commit that introduces a submodule leaves an empty directory.
c41="$tmp/c41"
mk_super "$c41"
git init -q "$c41/remote-sub2"
(
  cd "$c41/remote-sub2"
  echo two >two.txt
  git add two.txt
  git commit -q -m init
)
c41_from="$(git -C "$c41/super" rev-parse HEAD)"
git config --file "$GIT_CONFIG_GLOBAL" "url.$c41/remote-sub2.insteadOf" https://github.com/devantler-tech/remote-sub2
(
  cd "$c41/super"
  git submodule add -q https://github.com/devantler-tech/remote-sub2 sub2
  git commit -q -m "add sub2"
)
c41_target="$(git -C "$c41/super" rev-parse HEAD)"
git -C "$c41/super" worktree add -q --detach "$c41/wt" "$c41_from"
git -C "$c41/wt" checkout -q --detach "$c41_target"
report "sync add fixture: the detach leaves the new submodule empty" \
  "$([[ -d "$c41/wt/sub2" && -z "$(ls -A "$c41/wt/sub2")" ]] && echo yes || echo no)"
# A configured update command must not run: --sync initialises with --checkout.
git -C "$c41/wt" config submodule.sub2.update "!touch $c41/update-command-ran"
out="$(cd "$c41/wt" && "$helper" --sync "$c41_from" 2>&1)" && rc=0 || rc=$?
report "sync: an added submodule is populated at HEAD's pin" \
  "$([[ $rc -eq 0 && -f "$c41/wt/sub2/two.txt" ]] && [[ "$(git -C "$c41/wt/sub2" rev-parse HEAD)" == "$(git -C "$c41/wt" rev-parse HEAD:sub2)" ]] && echo yes || echo no)" "rc=$rc $out"
report "sync: the added submodule is isolated in the linked worktree" \
  "$(grep -q 'sub2 — isolated' <<<"$out" && echo yes || echo no)" "$out"
report "sync: an unchanged uninitialised submodule is left alone" \
  "$([[ -z "$(ls -A "$c41/wt/sub" 2>/dev/null)" ]] && echo yes || echo no)"
git -C "$c41/wt" checkout -q --detach "$c41_from" 2>/dev/null || true
report "sync remove fixture: the old submodule's content is left behind" \
  "$([[ -f "$c41/wt/sub2/two.txt" ]] && echo yes || echo no)"
out="$(cd "$c41/wt" && "$helper" --sync "$c41_target" 2>&1)" && rc=0 || rc=$?
report "sync: a removed submodule that left content behind fails closed" \
  "$([[ $rc -ne 0 ]] && grep -q "'sub2' is no longer a submodule at HEAD" <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# A submodule re-added at a newer pin, while this worktree still holds the old checkout, is moved
# with --advance: init mode would only repair it and leave it on the old commit.
c42="$tmp/c42"
mk_super "$c42"
(
  cd "$c42/super"
  git rm -q --cached sub
  git commit -q -m "stop tracking sub"
)
c42_from="$(git -C "$c42/super" rev-parse HEAD)"
(
  cd "$c42/remote-sub"
  echo newer >file.txt
  git add file.txt
  git commit -q -m newer
)
c42_new="$(git -C "$c42/remote-sub" rev-parse HEAD)"
(
  cd "$c42/super"
  git update-index --add --cacheinfo "160000,$c42_new,sub"
  git commit -q -m "re-add sub at a newer pin"
)
out="$(cd "$c42/super" && "$helper" --sync "$c42_from" 2>&1)" && rc=0 || rc=$?
report "sync: a re-added submodule still checked out here is advanced to the new pin" \
  "$([[ $rc -eq 0 ]] && [[ "$(git -C "$c42/super/sub" rev-parse HEAD)" == "$c42_new" ]] && echo yes || echo no)" "rc=$rc $out"

# A gitlink replaced by a tracked directory leaves HEAD's own files there, which is not residue.
c43="$tmp/c43"
mk_super "$c43"
c43_from="$(git -C "$c43/super" rev-parse HEAD)"
(
  cd "$c43/super"
  git rm -q sub
  mkdir sub
  echo tracked >sub/plain.txt
  git add sub/plain.txt
  git commit -q -m "replace the submodule with a tracked directory"
)
out="$(cd "$c43/super" && "$helper" --sync "$c43_from" 2>&1)" && rc=0 || rc=$?
report "sync: a gitlink replaced by a tracked directory is not refused as residue" \
  "$([[ $rc -eq 0 ]] && grep -q 'sub — removed at HEAD' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# A removed submodule's directory that cannot be listed is unexamined, so the run must fail.
c44="$tmp/c44"
mk_super "$c44"
c44_from="$(git -C "$c44/super" rev-parse HEAD)"
(
  cd "$c44/super"
  git rm -q sub
  git commit -q -m "remove sub"
)
mkdir -p "$c44/super/sub/leftover"
chmod 000 "$c44/super/sub"
out="$(cd "$c44/super" && "$helper" --sync "$c44_from" 2>&1)" && rc=0 || rc=$?
chmod 755 "$c44/super/sub"
if ls -A "$c44/super/sub" >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
  report "sync: an unreadable removed-submodule directory fails closed" \
    "$([[ $rc -ne 0 ]] && grep -q "cannot inspect 'sub'" <<<"$out" && echo yes || echo no)" "rc=$rc $out"
fi

# Round 3 of review on #3625.
report "sync: a configured submodule update command does not run" \
  "$([[ ! -e "$c41/update-command-ran" ]] && echo yes || echo no)"

# Anything HEAD does not track beside a tracked directory that replaced the gitlink is residue.
echo leftover >"$c43/super/sub/leftover.txt"
out="$(cd "$c43/super" && "$helper" --sync "$c43_from" 2>&1)" && rc=0 || rc=$?
report "sync: an untracked leftover beside a replacing tracked directory fails closed" \
  "$([[ $rc -ne 0 ]] && grep -q "content HEAD does not track" <<<"$out" && echo yes || echo no)" "rc=$rc $out"
rm -f "$c43/super/sub/leftover.txt"

# A path git would quote in plain raw output (here non-ASCII) is checked at its real location.
c48="$tmp/c48"
mk_super "$c48"
(
  cd "$c48/super"
  git submodule add -q ../remote-sub "mód"
  git commit -q -m "add a non-ASCII submodule path"
)
c48_from="$(git -C "$c48/super" rev-parse HEAD)"
(
  cd "$c48/super"
  git rm -q --cached "mód"
  git config -f .gitmodules --remove-section "submodule.mód"
  git add .gitmodules
  git commit -q -m "remove it but leave the checkout"
)
out="$(cd "$c48/super" && "$helper" --sync "$c48_from" 2>&1)" && rc=0 || rc=$?
report "sync: a removed non-ASCII submodule that left its repository behind fails closed" \
  "$([[ $rc -ne 0 ]] && grep -q "still holds its old repository" <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# A PR can register any URL. An added submodule outside devantler-tech is refused before anything
# contacts it. The URL uses the reserved `.invalid` domain, so even a regression cannot reach a real
# host.
c49="$tmp/c49"
mk_super "$c49"
c49_from="$(git -C "$c49/super" rev-parse HEAD)"
(
  cd "$c49/super"
  git config -f .gitmodules submodule.outside.path outside
  git config -f .gitmodules submodule.outside.url https://example.invalid/someone-else/outside
  git update-index --add --cacheinfo "160000,$(git -C "$c49/remote-sub" rev-parse HEAD),outside"
  git add .gitmodules
  git commit -q -m "add a submodule outside the portfolio"
)
out="$(cd "$c49/super" && "$helper" --sync "$c49_from" 2>&1)" && rc=0 || rc=$?
report "sync: an added submodule outside devantler-tech is refused before cloning" \
  "$([[ $rc -ne 0 ]] && grep -q "outside devantler-tech" <<<"$out" && [[ -z "$(ls -A "$c49/super/outside" 2>/dev/null)" ]] && echo yes || echo no)" "rc=$rc $out"

# Round 4 of review on #3625.
# An added submodule whose path contains a space is compared whole and populated.
c54="$tmp/c54"
mk_super "$c54"
c54_from="$(git -C "$c54/super" rev-parse HEAD)"
git config --file "$GIT_CONFIG_GLOBAL" "url.$c54/remote-sub.insteadOf" https://github.com/devantler-tech/remote-sub-c54
(
  cd "$c54/super"
  git config -f .gitmodules "submodule.with space.path" "with space"
  git config -f .gitmodules "submodule.with space.url" https://github.com/devantler-tech/remote-sub-c54
  git update-index --add --cacheinfo "160000,$(git -C "$c54/remote-sub" rev-parse HEAD),with space"
  git add .gitmodules
  git commit -q -m "add a submodule whose path has a space"
)
mkdir -p "$c54/super/with space"
out="$(cd "$c54/super" && "$helper" --sync "$c54_from" 2>&1)" && rc=0 || rc=$?
report "sync: an added submodule path containing a space is populated" \
  "$([[ $rc -eq 0 && -f "$c54/super/with space/file.txt" ]] && echo yes || echo no)" "rc=$rc $out"

# `submodule update --init` clones a URL already recorded in the superproject's config, so a stale
# recorded URL outside the portfolio is refused even when .gitmodules names a portfolio repository.
c55="$tmp/c55"
mk_super "$c55"
c55_from="$(git -C "$c55/super" rev-parse HEAD)"
(
  cd "$c55/super"
  git config -f .gitmodules submodule.extra.path extra
  git config -f .gitmodules submodule.extra.url https://github.com/devantler-tech/remote-sub-c55
  git update-index --add --cacheinfo "160000,$(git -C "$c55/remote-sub" rev-parse HEAD),extra"
  git add .gitmodules
  git commit -q -m "add a portfolio submodule"
  git config submodule.extra.url https://example.invalid/someone-else/stale
)
out="$(cd "$c55/super" && "$helper" --sync "$c55_from" 2>&1)" && rc=0 || rc=$?
report "sync: a stale recorded submodule URL outside devantler-tech is refused" \
  "$([[ $rc -ne 0 ]] && grep -q "outside devantler-tech" <<<"$out" && [[ -z "$(ls -A "$c55/super/extra" 2>/dev/null)" ]] && echo yes || echo no)" "rc=$rc $out"

# A removed submodule's directory that can be listed but not searched hides its `.git`.
c56="$tmp/c56"
mk_super "$c56"
c56_from="$(git -C "$c56/super" rev-parse HEAD)"
(
  cd "$c56/super"
  git rm -q --cached sub
  git config -f .gitmodules --remove-section submodule.sub
  git add .gitmodules
  git commit -q -m "remove sub but leave the checkout"
)
chmod 444 "$c56/super/sub"
out="$(cd "$c56/super" && "$helper" --sync "$c56_from" 2>&1)" && rc=0 || rc=$?
chmod 755 "$c56/super/sub"
if [ "$(id -u)" -ne 0 ]; then
  report "sync: a listable but unsearchable removed-submodule directory fails closed" \
    "$([[ $rc -ne 0 ]] && grep -q "cannot inspect 'sub'" <<<"$out" && echo yes || echo no)" "rc=$rc $out"
fi

# --- Origin identity (monorepo#2941): a checkout that resolves to itself can still be the wrong
# repository. The submodule must have, as its origin, the repository .gitmodules registers.
c30="$tmp/c30"
mk_super "$c30"
git init -q "$c30/other-repo"
out="$(cd "$c30/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity control: the matching origin passes --check" \
  "$([[ $rc -eq 0 ]] && grep -q 'sub — isolated' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
git -C "$c30/super/sub" remote set-url origin "$c30/other-repo"
out="$(cd "$c30/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity: a foreign origin fails --check" \
  "$([[ $rc -ne 0 ]] && echo yes || echo no)" "rc=$rc $out"
report "origin identity: names the wrong repository" \
  "$(grep -q 'sub — WRONG REPOSITORY' <<<"$out" && echo yes || echo no)" "$out"
report "origin identity: never prints isolated for it" \
  "$(grep -q 'sub — isolated' <<<"$out" && echo no || echo yes)" "$out"
out="$(cd "$c30/super" && "$helper" sub 2>&1)" && rc=0 || rc=$?
report "origin identity: init mode also refuses a foreign origin" \
  "$([[ $rc -ne 0 ]] && grep -q 'WRONG REPOSITORY' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
git -C "$c30/super/sub" remote remove origin
out="$(cd "$c30/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity: a missing origin fails closed" \
  "$([[ $rc -ne 0 ]] && grep -q 'cannot verify which repository' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

norm() {
  # shellcheck source=/dev/null
  . "$helper" >/dev/null 2>&1
  normalize_url "$1"
}
report "normalize_url: SSH and HTTPS spellings of one repository compare equal" \
  "$([[ "$(norm git@github.com:devantler-tech/World-At-Ruin.git)" == "$(norm https://github.com/devantler-tech/world-at-ruin)" ]] && echo yes || echo no)" \
  "$(norm git@github.com:devantler-tech/World-At-Ruin.git) vs $(norm https://github.com/devantler-tech/world-at-ruin)"
report "normalize_url: ssh:// and credentialed https:// reduce to host/owner/repo" \
  "$([[ "$(norm ssh://git@github.com/devantler-tech/ksail.git)" == "github.com/devantler-tech/ksail" && "$(norm https://x@github.com/devantler-tech/ksail/)" == "github.com/devantler-tech/ksail" ]] && echo yes || echo no)"
report "normalize_url: a different repository stays different" \
  "$([[ "$(norm git@github.com:devantler-tech/monorepo.git)" != "$(norm git@github.com:devantler-tech/agent-plugins.git)" ]] && echo yes || echo no)"
report "normalize_url: cleartext http:// never equals the https:// or SSH spelling" \
  "$([[ "$(norm http://github.com/devantler-tech/ksail)" != "$(norm https://github.com/devantler-tech/ksail)" && "$(norm git://github.com/devantler-tech/ksail)" != "$(norm git@github.com:devantler-tech/ksail.git)" ]] && echo yes || echo no)"
report "normalize_url: a non-GitHub host keeps its path case, and folds its host" \
  "$([[ "$(norm https://Git.Example.com/Org/Repo)" == "https://git.example.com/Org/Repo" ]] && echo yes || echo no)" \
  "$(norm https://Git.Example.com/Org/Repo)"

# Origin identity is checked BEFORE repair: a foreign checkout is refused untouched. Control: the
# matching checkout is repaired (repair pins core.worktree into config.worktree).
c31="$tmp/c31"
mk_super "$c31"
out="$(cd "$c31/super" && "$helper" sub 2>&1)" && rc=0 || rc=$?
report "origin before repair control: the matching checkout is repaired" \
  "$([[ $rc -eq 0 ]] && [[ -n "$(git config -f "$c31/super/.git/modules/sub/config.worktree" core.worktree 2>/dev/null || true)" ]] && echo yes || echo no)" "rc=$rc $out"
c32="$tmp/c32"
mk_super "$c32"
git init -q "$c32/other-repo"
git -C "$c32/super/sub" remote set-url origin "$c32/other-repo"
out="$(cd "$c32/super" && "$helper" sub 2>&1)" && rc=0 || rc=$?
report "origin before repair: a foreign checkout is refused" \
  "$([[ $rc -ne 0 ]] && grep -q 'refusing to repair it' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
report "origin before repair: the foreign checkout's config is left untouched" \
  "$([[ ! -e "$c32/super/.git/modules/sub/config.worktree" ]] && echo yes || echo no)"

# The expectation for a relative registration comes from .gitmodules, never from the mutable
# recorded submodule.<name>.url: pointing both that value and the origin at a foreign repository
# must still fail.
c33="$tmp/c33"
mk_super "$c33"
git init -q "$c33/other-repo"
git -C "$c33/super" config submodule.sub.url "$c33/other-repo"
git -C "$c33/super/sub" remote set-url origin "$c33/other-repo"
out="$(cd "$c33/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "relative registration: a rewritten submodule.<name>.url cannot vouch for a foreign origin" \
  "$([[ $rc -ne 0 ]] && grep -q 'sub — WRONG REPOSITORY' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

report "normalize_url: only https, ssh and scp-like spellings drop their scheme (file://, ftp:// stay distinct)" \
  "$([[ "$(norm file://github.com/devantler-tech/ksail)" != "$(norm https://github.com/devantler-tech/ksail)" && "$(norm ftp://github.com/devantler-tech/ksail)" != "$(norm https://github.com/devantler-tech/ksail)" && "$(norm SSH://git@github.com/devantler-tech/ksail)" == "$(norm https://github.com/devantler-tech/ksail)" ]] && echo yes || echo no)"

# Several origin URLs are ambiguous: git fetches from the first, `config --get` reads the last, so
# a matching last value could hide a foreign first one.
c36="$tmp/c36"
mk_super "$c36"
c36_own="$(git -C "$c36/super/sub" config --get remote.origin.url)"
git init -q "$c36/other-repo"
git -C "$c36/super/sub" config --replace-all remote.origin.url "$c36/other-repo"
git -C "$c36/super/sub" config --add remote.origin.url "$c36_own"
out="$(cd "$c36/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity: several origin URLs fail closed even when the last one matches" \
  "$([[ $rc -ne 0 ]] && grep -q 'sub — cannot verify which repository' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# The origin is checked BEFORE the probe worktree is created, so a rejected repository's hooks never
# run. Control first: with the right origin, the probe's checkout does run post-checkout.
c37="$tmp/c37"
mk_super "$c37"
c37_hook="$(git -C "$c37/super/sub" rev-parse --path-format=absolute --git-common-dir)/hooks/post-checkout"
printf '#!/bin/sh\ntouch "%s"\n' "$c37/hook-ran" >"$c37_hook"
chmod +x "$c37_hook"
out="$(cd "$c37/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin before probe control: the probe's checkout runs the submodule's post-checkout hook" \
  "$([[ $rc -eq 0 && -e "$c37/hook-ran" ]] && echo yes || echo no)" "rc=$rc $out"
rm -f "$c37/hook-ran"
git init -q "$c37/other-repo"
git -C "$c37/super/sub" remote set-url origin "$c37/other-repo"
out="$(cd "$c37/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin before probe: a foreign checkout is rejected without running its hooks" \
  "$([[ $rc -ne 0 && ! -e "$c37/hook-ran" ]] && grep -q 'sub — WRONG REPOSITORY' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# A nested checkout is checked against the .gitmodules of the parent that declares it.
c38="$tmp/c38"
mkdir -p "$c38"
git init -q "$c38/remote-nested"
(
  cd "$c38/remote-nested"
  echo n >n.txt
  git add n.txt
  git commit -q -m init
)
git init -q "$c38/remote-sub"
(
  cd "$c38/remote-sub"
  echo outer >outer.txt
  git add outer.txt
  git commit -q -m init
  git submodule add -q ../remote-nested nested
  git commit -q -m "add nested"
)
git init -q "$c38/super"
(
  cd "$c38/super"
  echo root >root.txt
  git add root.txt
  git commit -q -m init
  git submodule add -q ../remote-sub sub
  git -C sub submodule update -q --init nested
  git commit -q -m "add sub"
)
out="$(cd "$c38/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "nested origin control: a nested checkout of the declared repository passes --advance" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc $out"
git init -q "$c38/other-repo"
git -C "$c38/super/sub/nested" remote set-url origin "$c38/other-repo"
out="$(cd "$c38/super" && "$helper" --advance sub 2>&1)" && rc=0 || rc=$?
report "nested origin: a nested checkout of a foreign repository fails --advance" \
  "$([[ $rc -ne 0 ]] && grep -q 'sub/nested — WRONG REPOSITORY' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# Round 3 of review on #3624: a sparse fresh checkout, an insteadOf rewrite, a doubly-registered
# path, and a credential in a mismatching origin URL.
c11c="$tmp/c11c"
mk_super "$c11c"
git -C "$c11c/super" submodule --quiet deinit -f sub >/dev/null
sparse_shim="$tmp/shim-sparse"
mkdir -p "$sparse_shim"
cat >"$sparse_shim/git" <<SHIM
#!/usr/bin/env bash
# Run 'submodule update' for real, then hide the pinned file behind skip-worktree and delete it.
for a in "\$@"; do [[ "\$a" == "submodule" ]] && seen_sub=1; [[ "\$a" == "update" ]] && seen_upd=1; done
"$real_git" "\$@" || exit \$?
if [[ -n "\${seen_sub:-}" && -n "\${seen_upd:-}" ]]; then
  "$real_git" -C sub update-index --skip-worktree file.txt && rm -f sub/file.txt
fi
SHIM
chmod +x "$sparse_shim/git"
out="$(cd "$c11c/super" && PATH="$sparse_shim:$PATH" "$helper" sub 2>&1)" && rc=0 || rc=$?
report "sparse init precondition: status hides the missing pinned file" \
  "$([[ ! -e "$c11c/super/sub/file.txt" && -z "$(git -C "$c11c/super/sub" status --porcelain --untracked-files=no)" ]] && echo yes || echo no)"
report "sparse init: a fresh checkout with skip-worktree files fails and never reports isolated" \
  "$([[ $rc -ne 0 ]] && grep -q 'hidden by skip-worktree' <<<"$out" && ! grep -q 'isolated ✓' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

c45="$tmp/c45"
mk_super "$c45"
c45_own="$(git -C "$c45/super/sub" config --get remote.origin.url)"
git init -q "$c45/other-repo"
git -C "$c45/super/sub" config "url.$c45/other-repo.insteadOf" "$c45_own"
out="$(cd "$c45/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity: an insteadOf rewrite to a foreign repository fails --check" \
  "$([[ $rc -ne 0 ]] && grep -q 'sub — WRONG REPOSITORY' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

c46="$tmp/c46"
mk_super "$c46"
git -C "$c46/super" config -f .gitmodules submodule.dup.path sub
git -C "$c46/super" config -f .gitmodules submodule.dup.url ../elsewhere
out="$(cd "$c46/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity: a path registered twice in .gitmodules fails closed" \
  "$([[ $rc -ne 0 ]] && grep -q 'registers this path more than once' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

c47="$tmp/c47"
mk_super "$c47"
git -C "$c47/super/sub" remote set-url origin "https://someone:not-a-real-token@example.invalid/org/repo"
out="$(cd "$c47/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity: a mismatching credentialed origin is reported without its credential" \
  "$([[ $rc -ne 0 ]] && grep -q 'sub — WRONG REPOSITORY' <<<"$out" && ! grep -q 'not-a-real-token' <<<"$out" && grep -q 'https://example.invalid/org/repo' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# Round 4 of review on #3624.
report "normalize_url: a non-GitHub host keeps its transport (HTTPS and SSH stay distinct)" \
  "$([[ "$(norm https://git.example.com/org/repo)" != "$(norm git@git.example.com:org/repo)" ]] && echo yes || echo no)"
report "normalize_url: a local path keeps its .git suffix" \
  "$([[ "$(norm "$tmp/absent/product.git")" != "$(norm "$tmp/absent/product")" ]] && echo yes || echo no)"
c52="$tmp/c52"
mk_super "$c52"
git -C "$c52/super/sub" remote set-url origin "https://example.invalid/org/repo?access_token=not-a-real-secret#frag"
out="$(cd "$c52/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity: a query or fragment in a mismatching origin is not printed" \
  "$([[ $rc -ne 0 ]] && grep -q 'sub — WRONG REPOSITORY' <<<"$out" && ! grep -q 'not-a-real-secret' <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# A relative registration resolves against the branch's tracking remote, as git resolves it, not
# against `origin` when the branch tracks something else.
c53="$tmp/c53"
mk_super "$c53"
git -C "$c53/super" remote add upstream "$c53/up/super"
git -C "$c53/super" remote add origin "$c53/fork/super"
git -C "$c53/super" config branch.main.remote upstream
git -C "$c53/super/sub" remote set-url origin "$c53/fork/remote-sub"
out="$(cd "$c53/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity: a relative URL resolves against the tracking remote, not origin" \
  "$([[ $rc -ne 0 ]] && grep -q 'sub — WRONG REPOSITORY' <<<"$out" && echo yes || echo no)" "rc=$rc $out"
git -C "$c53/super/sub" remote set-url origin "$c53/up/remote-sub"
out="$(cd "$c53/super" && "$helper" --check 2>&1)" && rc=0 || rc=$?
report "origin identity control: the tracking remote's sibling passes" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc $out"

# Round 5 of review on #3625.
# 1. Check ancestors before declaring removed paths clean
c57="$tmp/c57"
mk_super "$c57"
(
  cd "$c57/super"
  mkdir -p parent
  git config -f .gitmodules submodule.nested.path parent/sub
  git config -f .gitmodules submodule.nested.url ../remote-sub
  git update-index --add --cacheinfo "160000,$(git -C "$c57/remote-sub" rev-parse HEAD),parent/sub"
  git add .gitmodules
  git commit -q -m "add parent/sub"
)
c57_from="$(git -C "$c57/super" rev-parse HEAD)"
(
  cd "$c57/super"
  git rm -q --cached parent/sub
  git config -f .gitmodules --remove-section submodule.nested
  git add .gitmodules
  git commit -q -m "remove parent/sub"
)
chmod 000 "$c57/super/parent"
out="$(cd "$c57/super" && "$helper" --sync "$c57_from" 2>&1)" && rc=0 || rc=$?
chmod 755 "$c57/super/parent"
if [ "$(id -u)" -ne 0 ]; then
  report "sync: an unsearchable ancestor of a removed path fails closed" \
    "$([[ $rc -ne 0 ]] && grep -q "cannot inspect 'parent/sub'" <<<"$out" && echo yes || echo no)" "rc=$rc $out"
fi

# 2. Validate the populated checkout's remote before advancing
c58="$tmp/c58"
mk_super "$c58"
c58_from="$(git -C "$c58/super" rev-parse HEAD)"
(
  cd "$c58/remote-sub"
  echo v2 >file.txt
  git commit -q -a -m v2
)
c58_new="$(git -C "$c58/remote-sub" rev-parse HEAD)"
(
  cd "$c58/super"
  git update-index --cacheinfo "160000,$c58_new,sub"
  git commit -q -m "bump sub"
)
git -C "$c58/super/sub" remote set-url origin "https://example.invalid/outside/repo"
out="$(cd "$c58/super" && "$helper" --sync "$c58_from" 2>&1)" && rc=0 || rc=$?
report "sync: a populated submodule with foreign origin remote is refused before advance" \
  "$([[ $rc -ne 0 ]] && grep -q "WRONG REPOSITORY" <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 3. Dangling .git entries as removal residue
c60="$tmp/c60"
mk_super "$c60"
c60_from="$(git -C "$c60/super" rev-parse HEAD)"
(
  cd "$c60/super"
  git rm -q sub
  git commit -q -m "remove sub"
)
mkdir -p "$c60/super/sub"
ln -s "$tmp/absent-target" "$c60/super/sub/.git"
out="$(cd "$c60/super" && "$helper" --sync "$c60_from" 2>&1)" && rc=0 || rc=$?
report "sync: a dangling .git symlink in a removed path fails closed" \
  "$([[ $rc -ne 0 ]] && grep -q "still holds its old repository" <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 4. Nested submodule removal with accessible ancestor terminates and syncs
c61="$tmp/c61"
mk_super "$c61"
mkdir -p "$c61/super/parent"
(
  cd "$c61/super"
  git submodule add -q ../remote-sub parent/sub
  git commit -q -m "add parent/sub"
)
c61_from="$(git -C "$c61/super" rev-parse HEAD)"
(
  cd "$c61/super"
  git rm -q parent/sub
  git config -f .gitmodules --remove-section submodule.parent/sub 2>/dev/null || true
  git add .gitmodules
  git commit -q -m "remove parent/sub"
  rm -rf parent
)
out="$(cd "$c61/super" && "$helper" --sync "$c61_from" 2>&1)" && rc=0 || rc=$?
report "sync: a clean nested removal terminates and reports nothing left behind" \
  "$([[ $rc -eq 0 ]] && grep -q "nothing left behind" <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# 5. Retained submodule repository with foreign remote under .git/modules fails closed
c62="$tmp/c62"
mk_super "$c62"
c62_from="$(git -C "$c62/super" rev-parse HEAD)"
(
  cd "$c62/super"
  # Add a portfolio-registered submodule
  git config -f .gitmodules "submodule.retained.path" "retained"
  git config -f .gitmodules "submodule.retained.url" "https://github.com/devantler-tech/allowed-repo"
  # Add commit tree entry for gitlink
  git update-index --add --cacheinfo "160000,$(git -C "$c62/remote-sub" rev-parse HEAD),retained"
  git add .gitmodules
  git commit -q -m "add retained"
  # Simulate retained module repository in .git/modules/retained with foreign remote
  mkdir -p .git/modules/retained
  git init -q --bare .git/modules/retained
  git -C .git/modules/retained remote add origin "https://example.invalid/outside/repo"
)
out="$(cd "$c62/super" && "$helper" --sync "$c62_from" 2>&1)" && rc=0 || rc=$?
report "sync: a retained submodule repository with foreign origin remote is refused before init" \
  "$([[ $rc -ne 0 ]] && grep -q "registered to a repository outside devantler-tech" <<<"$out" && echo yes || echo no)" "rc=$rc $out"

# Round 7 of review on #3625.
# 6. An added submodule whose path begins with a space keeps it through every path consumer.
c63="$tmp/c63"
mk_super "$c63"
c63_from="$(git -C "$c63/super" rev-parse HEAD)"
git config --file "$GIT_CONFIG_GLOBAL" "url.$c63/remote-sub.insteadOf" https://github.com/devantler-tech/remote-sub-c63
(
  cd "$c63/super"
  git config -f .gitmodules "submodule.leading.path" " leading"
  git config -f .gitmodules "submodule.leading.url" https://github.com/devantler-tech/remote-sub-c63
  git update-index --add --cacheinfo "160000,$(git -C "$c63/remote-sub" rev-parse HEAD), leading"
  git add .gitmodules
  git commit -q -m "add a submodule whose path starts with a space"
)
out="$(cd "$c63/super" && "$helper" --sync "$c63_from" 2>&1)" && rc=0 || rc=$?
report "sync: an added submodule path with a leading space is populated" \
  "$([[ $rc -eq 0 && -f "$c63/super/ leading/file.txt" ]] && echo yes || echo no)" "rc=$rc $out"

# 7. An added path spelled as pathspec magic populates only itself, never another registration.
c64="$tmp/c64"
mk_super "$c64"
git init -q "$c64/foreign"
(
  cd "$c64/foreign"
  echo foreign >file.txt
  git add file.txt
  git commit -q -m init
  cd "$c64/super"
  git config -f .gitmodules submodule.foreign.path foreign
  git config -f .gitmodules submodule.foreign.url "$c64/foreign"
  git update-index --add --cacheinfo "160000,$(git -C "$c64/foreign" rev-parse HEAD),foreign"
  git add .gitmodules
  git commit -q -m "register a submodule outside the portfolio, never initialised"
)
c64_from="$(git -C "$c64/super" rev-parse HEAD)"
git config --file "$GIT_CONFIG_GLOBAL" "url.$c64/remote-sub.insteadOf" https://github.com/devantler-tech/remote-sub-c64
(
  cd "$c64/super"
  git config -f .gitmodules "submodule.magic.path" ':(glob)*'
  git config -f .gitmodules "submodule.magic.url" https://github.com/devantler-tech/remote-sub-c64
  git update-index --add --cacheinfo "160000,$(git -C "$c64/remote-sub" rev-parse HEAD),:(glob)*"
  git add .gitmodules
  git commit -q -m "add a submodule whose path is pathspec magic"
)
out="$(cd "$c64/super" && "$helper" --sync "$c64_from" 2>&1)" && rc=0 || rc=$?
report "sync: a pathspec-magic path never initialises another submodule" \
  "$([[ -z "$(ls -A "$c64/super/foreign" 2>/dev/null)" ]] && echo yes || echo no)" "rc=$rc $out"

# Round 8 of review on #3625.
# 8. An added submodule whose path contains a newline is preserved without record splitting.
c65="$tmp/c65"
mk_super "$c65"
c65_from="$(git -C "$c65/super" rev-parse HEAD)"
git config --file "$GIT_CONFIG_GLOBAL" "url.$c65/remote-sub.insteadOf" https://github.com/devantler-tech/remote-sub-c65
nl_path=$'path\nwith\nnewline'
(
  cd "$c65/super"
  git config -f .gitmodules "submodule.nl.path" "$nl_path"
  git config -f .gitmodules "submodule.nl.url" https://github.com/devantler-tech/remote-sub-c65
  git update-index --add --cacheinfo "160000,$(git -C "$c65/remote-sub" rev-parse HEAD),$nl_path"
  git add .gitmodules
  git commit -q -m "add a submodule whose path has a newline"
)
out="$(cd "$c65/super" && "$helper" --sync "$c65_from" 2>&1)" && rc=0 || rc=$?
report "sync: a submodule path with a newline is populated whole" \
  "$([[ $rc -eq 0 && -f "$c65/super/$nl_path/file.txt" ]] && echo yes || echo no)" "rc=$rc $out"
check_out="$(cd "$c65/super" && "$helper" --check 2>&1)" && check_rc=0 || check_rc=$?
report "check: a populated submodule with a newline passes worktree isolation check" \
  "$([[ $check_rc -eq 0 ]] && echo yes || echo no)" "rc=$check_rc $check_out"

# 9. A removed submodule replaced by a tracked symlink pointing to another repo is not flagged as .git residue
c66="$tmp/c66"
mk_super "$c66"
(
  cd "$c66/super"
  git submodule add -q ../remote-sub sub-target
  git submodule add -q ../remote-sub sub-old
  git commit -q -m "add two submodules"
)
c66_from="$(git -C "$c66/super" rev-parse HEAD)"
(
  cd "$c66/super"
  git rm -q sub-old
  git config -f .gitmodules --remove-section submodule.sub-old 2>/dev/null || true
  rm -rf .git/modules/sub-old sub-old
  ln -s sub-target sub-old
  git add sub-old .gitmodules
  git commit -q -m "replace sub-old with symlink to sub-target"
)
out="$(cd "$c66/super" && "$helper" --sync "$c66_from" 2>&1)" && rc=0 || rc=$?
report "sync: removed submodule replaced by symlink to another repo is clean" \
  "$([[ $rc -eq 0 ]] && echo yes || echo no)" "rc=$rc $out"

# 10. Abort during sync preserves failure exit code
c67="$tmp/c67"
mk_super "$c67"
c67_from="$(git -C "$c67/super" rev-parse HEAD)"
(
  cd "$c67/super"
  git rm -q sub
  git config -f .gitmodules --remove-section submodule.sub 2>/dev/null || true
  git add .gitmodules
  git commit -q -m "remove sub"
  mkdir -p sub
  echo "dirty" > sub/untracked.txt
)
out="$(cd "$c67/super" && "$helper" --sync "$c67_from" 2>&1)" && rc=0 || rc=$?
report "sync: abort on dirty removed submodule preserves non-zero exit code" \
  "$([[ $rc -ne 0 ]] && grep -q "still holds content HEAD does not track" <<<"$out" && echo yes || echo no)" "rc=$rc $out"

if [[ $fail -ne 0 ]]; then
  echo "submodule-init self-test: FAILURES above" >&2
  exit 1
fi
echo "submodule-init self-test: all cases passed"
