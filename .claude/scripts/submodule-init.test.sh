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

if [[ $fail -ne 0 ]]; then
  echo "submodule-init self-test: FAILURES above" >&2
  exit 1
fi
echo "submodule-init self-test: all cases passed"
