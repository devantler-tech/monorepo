#!/usr/bin/env bash
# pr-worktree-holder.test.sh — behavioural proof for pr-worktree-holder.sh (monorepo#3067).
#
# monorepo#3053 read idle on every published-event signal while two live sessions worked in its
# worktree. The helper answers from the host's processes instead, so this test pins, against real
# git checkouts and a scripted process table:
#   - a process holds its own checkout, that checkout's populated submodules and, for a per-session
#     worktree only, the product worktrees nested in those submodules;
#   - a main checkout never claims the per-session worktrees nested inside it;
#   - the asking session is `self`, while another session in the same worktree and a sibling in a
#     different worktree stay `live`;
#   - a failed or empty `lsof`, or a failed `ps`, is `unknown:` and exit 2, never `none`;
#   - a worktree lock holds its worktree while the process it names lives with the recorded start
#     time, releases it once that process exited or the pid was reused, and is `unknown:` when the
#     helper cannot read it (monorepo#3780: an isolated subagent keeps no process in its worktree
#     between its commands, so only the harness's lock names its session);
#   - a linked worktree holds the worktrees of its own repository registered inside it, at any
#     depth, with their submodules, whether it is held by a working directory or by a live lock,
#     and a listing of them that fails is `unknown:` (monorepo#3818: a session's per-run worktree
#     sits inside its session worktree and has no process and no lock of its own);
#   - the locks read include those of each superproject above, and of each populated submodule
#     below, every checkout a process works in or the helper is asked from (monorepo#3825: a lock
#     lives in its worktree's repository, which need not be the one its owner or the asker stands
#     in), and a listing of one of those that fails is `unknown:`;
#   - a locked worktree whose path holds a tab is `unknown:` for every PR asked about unless its
#     process exited, never a row that splits and reads `none` (monorepo#3825).
# `lsof` and `ps` are shims driven by FIXTURE_* variables; the helper itself reads no environment.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${here}/pr-worktree-holder.sh"
checks=0
failures=0
finished=0
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/pr-worktree-holder-test.XXXXXX")"
trap 'rm -rf -- "${sandbox}"; if [ "${finished}" != 1 ]; then echo "pr-worktree-holder.test.sh: aborted before finishing" >&2; exit 1; fi' EXIT
sandbox="$(cd "${sandbox}" && /bin/pwd -P)"

[ -x "${tool}" ] || { echo "FAIL cannot execute ${tool}" >&2; exit 1; }

# Fixture repositories only: never the caller's global or system git configuration.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() {
  git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    -c init.defaultBranch=main -c protocol.file.allow=always "$@"
}

# ── Checkouts ───────────────────────────────────────────────────────────────────────────────────
main="${sandbox}/main"
w1="${main}/.claude/worktrees/w1"
w2="${main}/.claude/worktrees/w2"
g init -q "${sandbox}/product-origin"
g -C "${sandbox}/product-origin" commit -q --allow-empty -m init
g init -q "${main}"
g -C "${main}" commit -q --allow-empty -m init
g -C "${main}" submodule --quiet add "${sandbox}/product-origin" product
g -C "${main}" commit -q -m 'add product'
g -C "${main}" config remote.origin.url git@github.com:devantler-tech/demo.git
g -C "${main}/product" config remote.origin.url https://github.com/devantler-tech/product.git
# The main checkout's own submodule registers a worktree inside itself. A main checkout never claims
# what is nested in it, so a process at the main checkout must not hold this branch.
g -C "${main}/product" worktree add -q -b claude/product-main-nested "${main}/product/.claude/worktrees/nested"
# Two per-session worktrees, nested in the main checkout exactly as the harness creates them.
g -C "${main}" worktree add -q -b claude/feature-1 "${w1}"
g -C "${main}" worktree add -q -b claude/feature-2 "${w2}"
# Session w1 populates the product submodule, works on a branch there, and keeps a per-run product
# worktree inside it, as the git-and-worktrees guide prescribes.
g -C "${w1}" submodule --quiet update --init product
g -C "${w1}/product" config remote.origin.url git@github.com:devantler-tech/product.git
g -C "${w1}/product" switch -q -c claude/product-7
g -C "${w1}/product" worktree add -q -b claude/product-8 "${w1}/product/.claude/worktrees/maint-1"
# Session w1 also keeps per-run worktrees of the SAME repository inside its own worktree, one of
# them nested in another, and works on a product branch in the first one's submodule
# (monorepo#3818). No process sits in any of them and none is locked.
w1_run="${w1}/.claude/worktrees/maint-1"
g -C "${main}" worktree add -q -b claude/nested-20 "${w1_run}"
g -C "${main}" worktree add -q -b claude/deep-21 "${w1_run}/.claude/worktrees/deep"
g -C "${w1_run}" submodule --quiet update --init product
g -C "${w1_run}/product" config remote.origin.url git@github.com:devantler-tech/product.git
g -C "${w1_run}/product" switch -q -c claude/product-22
# Session w2 keeps one too. It has no populated submodule, so the only worktree listing its tree
# needs is the one of its own nested worktrees.
g -C "${main}" worktree add -q -b claude/nested-23 "${w2}/.claude/worktrees/maint-2"
# On a volume that ignores letter case, git lists a worktree under the spelling it was added with,
# which need not be the spelling it reports for the worktree around it. Linux runners keep case,
# so there the differently spelled path would be another directory and the case is skipped.
case_blind=0
if [ -d "${sandbox}/MAIN" ]; then
  case_blind=1
  g -C "${main}" worktree add -q -b claude/nested-24 "${main}/.CLAUDE/Worktrees/W2/.claude/worktrees/maint-3"
fi
# Session w3 is mid-rebase on its branch: HEAD is detached and the branch is named only in the
# rebase state (the shape `git rebase` leaves while it stops on a conflict).
w3="${main}/.claude/worktrees/w3"
g -C "${main}" worktree add -q -b claude/rebasing-10 "${w3}"
w3_gitdir="$(g -C "${w3}" rev-parse --path-format=absolute --git-dir)"
g -C "${w3}" switch -q --detach
mkdir -p "${w3_gitdir}/rebase-merge"
# Written without a trailing newline: the branch must still be read.
printf 'refs/heads/claude/rebasing-10' >"${w3_gitdir}/rebase-merge/head-name"
# A standalone clone elsewhere on the host whose remote is not called `origin`.
elsewhere="${sandbox}/elsewhere"
g init -q "${elsewhere}"
g -C "${elsewhere}" commit -q --allow-empty -m init
g -C "${elsewhere}" remote add upstream https://github.com/devantler-tech/tool
g -C "${elsewhere}" switch -q -c claude/tool-11

# Guard the fixture itself: w1's submodule must be its own checkout, not a path inside w1, and w3
# must really be detached.
[ "$(g -C "${w1}/product" rev-parse --show-toplevel)" = "${w1}/product" ] ||
  { echo "FAIL fixture: w1/product is not a populated submodule checkout" >&2; exit 1; }
if g -C "${w3}" symbolic-ref -q HEAD >/dev/null; then
  echo "FAIL fixture: w3 is not detached" >&2
  exit 1
fi

# ── Locked worktrees (monorepo#3780) ────────────────────────────────────────────────────────────
# A second repository, so every case that asks about the first one runs with no lock in sight. Its
# worktrees sit where the harness puts them and carry the reason the harness writes when it locks
# one. Copied from a host running Claude Code 2.1.286, the start time as `ps -o lstart=` pads it:
#   claude agent agent-ad7725be40d52b9c8 (pid 17903 start Fri Oct  2 14:59:59 2026)
hub="${sandbox}/hub"
hub_wt="${hub}/.claude/worktrees"
start_theirs='Fri Oct  2 14:59:59 2026'
start_mine='Sat Oct  3 08:05:07 2026'
start_s1='Thu Oct  1 23:00:10 2026'
g init -q "${hub}"
g -C "${hub}" commit -q --allow-empty -m init
g -C "${hub}" submodule --quiet add "${sandbox}/product-origin" product
g -C "${hub}" commit -q -m 'add product'
g -C "${hub}" config remote.origin.url git@github.com:devantler-tech/hub.git
# hub_worktree <name> <branch> [<lock reason>] — a worktree, locked when a reason is given.
hub_worktree() {
  g -C "${hub}" worktree add -q -b "$2" "${hub_wt}/$1"
  if [ "$#" -ge 3 ]; then g -C "${hub}" worktree lock --reason "$3" "${hub_wt}/$1"; fi
}
me="$$"
# The two sessions' own worktrees: where their long-lived processes have their working directory.
# The asking session's is locked by that session itself, as the harness does for a worktree session.
hub_worktree theirs claude/theirs-30
hub_worktree mine claude/mine-31 "claude session mine (pid ${me} start ${start_mine})"
# a1: another session's subagent, mid-flight. Nothing has a working directory in it, and it has
# populated the product submodule and works on a branch there.
hub_worktree agent-a1 worktree-agent-a1 "claude agent agent-a1 (pid 9000002 start ${start_theirs})"
g -C "${hub_wt}/agent-a1" submodule --quiet update --init product
g -C "${hub_wt}/agent-a1/product" config remote.origin.url git@github.com:devantler-tech/product.git
g -C "${hub_wt}/agent-a1/product" switch -q -c claude/product-32
# a2: its session exited. a3: its session exited and the pid now belongs to another process.
hub_worktree agent-a2 worktree-agent-a2 "claude agent agent-a2 (pid 9000099 start ${start_theirs})"
hub_worktree agent-a3 worktree-agent-a3 "claude agent agent-a3 (pid 9000003 start ${start_theirs})"
# a4, a5, a8: locks the helper cannot read as a process identity: someone else's reason, no reason
# at all, and the harness's form with the start time in another shape.
hub_worktree agent-a4 worktree-agent-a4 'left locked by hand'
hub_worktree agent-a5 worktree-agent-a5
g -C "${hub}" worktree lock "${hub_wt}/agent-a5"
hub_worktree agent-a8 worktree-agent-a8 'claude agent agent-a8 (pid 9000002 start 2026-10-02T14:59:59Z)'
# a6, a7: the form the harness writes when it could not read its own start time.
hub_worktree agent-a6 worktree-agent-a6 'claude agent agent-a6 (pid 9000003)'
hub_worktree agent-a7 worktree-agent-a7 'claude agent agent-a7 (pid 9000099)'
# a9, a10: two subagents of the ASKING session. Both locks name the one session process.
hub_worktree agent-a9 worktree-agent-a9 "claude agent agent-a9 (pid ${me} start ${start_mine})"
hub_worktree agent-a10 worktree-agent-a10 "claude agent agent-a10 (pid ${me} start ${start_mine})"
# s1: another session's own locked worktree (its name may hold a slash).
hub_worktree s1 claude/s1-33 "claude session team/s1 (pid 9000011 start ${start_s1})"
# a11: an unreadable lock on a worktree whose directory is gone. The registration outlives it.
hub_worktree agent-a11 worktree-agent-a11 'left locked by hand'
rm -rf -- "${hub_wt}/agent-a11"
# a12: a live lock on a worktree whose `.git` entry is gone. Its directory now resolves to the main
# checkout around it, which the lock was never on.
hub_worktree agent-a12 worktree-agent-a12 "claude agent agent-a12 (pid 9000002 start ${start_theirs})"
rm -f -- "${hub_wt}/agent-a12/.git"

# Per-run worktrees nested inside locked ones (monorepo#3818), themselves unlocked: in a1 (its
# session lives), in a2 (its session exited) and in a9 (the asking session's own subagent).
g -C "${hub}" worktree add -q -b claude/nested-60 "${hub_wt}/agent-a1/.claude/worktrees/maint-9"
g -C "${hub}" worktree add -q -b claude/nested-61 "${hub_wt}/agent-a2/.claude/worktrees/maint-9"
g -C "${hub}" worktree add -q -b claude/nested-62 "${hub_wt}/agent-a9/.claude/worktrees/maint-9"

# a13: a subagent of the ASKING session whose locked worktree is registered inside that session's
# own worktree.
g -C "${hub}" worktree add -q -b worktree-agent-a13 "${hub_wt}/mine/.claude/worktrees/agent-a13"
g -C "${hub}" worktree lock --reason "claude agent agent-a13 (pid ${me} start ${start_mine})" "${hub_wt}/mine/.claude/worktrees/agent-a13"

# Guard the fixture itself: git must list the harness's reason exactly as written, a1's submodule
# must be its own checkout, and a11 must still be registered and locked.
hub_list="$(g -C "${hub}" worktree list --porcelain)"
grep -qxF "locked claude agent agent-a1 (pid 9000002 start ${start_theirs})" <<<"${hub_list}" ||
  { echo "FAIL fixture: git does not list a1's lock reason as written" >&2; exit 1; }
[ "$(grep -c '^locked' <<<"${hub_list}")" = 15 ] ||
  { echo "FAIL fixture: expected 15 locked worktrees in the hub repository" >&2; exit 1; }
[ "$(g -C "${hub_wt}/agent-a1/product" rev-parse --show-toplevel)" = "${hub_wt}/agent-a1/product" ] ||
  { echo "FAIL fixture: agent-a1/product is not a populated submodule checkout" >&2; exit 1; }
grep -qxF "worktree ${hub_wt}/agent-a11" <<<"${hub_list}" ||
  { echo "FAIL fixture: agent-a11 is no longer registered" >&2; exit 1; }
[ "$(g -C "${hub_wt}/agent-a12" rev-parse --show-toplevel)" = "${hub}" ] ||
  { echo "FAIL fixture: agent-a12 does not resolve to the main checkout around it" >&2; exit 1; }

# ── Locks in another repository than the one asked from (monorepo#3825) ─────────────────────────
# A lock lives in the registry of its worktree's repository. The hub's main checkout has populated
# its product submodule, and that submodule's repository registers two locked worktrees of its
# own: one whose session lives and one whose session exited. Neither is in the hub's registry.
hub_product="${hub}/product"
g -C "${hub_product}" config remote.origin.url git@github.com:devantler-tech/product.git
g -C "${hub_product}" worktree add -q -b claude/product-70 "${hub_product}/.claude/worktrees/sub-live"
g -C "${hub_product}" worktree lock --reason "claude agent sub-live (pid 9000002 start ${start_theirs})" \
  "${hub_product}/.claude/worktrees/sub-live"
g -C "${hub_product}" worktree add -q -b claude/product-71 "${hub_product}/.claude/worktrees/sub-gone"
g -C "${hub_product}" worktree lock --reason "claude agent sub-gone (pid 9000099 start ${start_theirs})" \
  "${hub_product}/.claude/worktrees/sub-gone"
[ "$(g -C "${hub_product}" rev-parse --show-superproject-working-tree)" = "${hub}" ] ||
  { echo "FAIL fixture: hub/product is not a submodule checkout of the hub" >&2; exit 1; }
[ "$(g -C "${hub_product}" worktree list --porcelain | grep -c '^locked')" = 2 ] ||
  { echo "FAIL fixture: expected 2 locked worktrees in the hub's product submodule" >&2; exit 1; }
[ "$(g -C "${hub}" worktree list --porcelain | grep -c '^locked')" = 15 ] ||
  { echo "FAIL fixture: the product submodule's locks leaked into the hub's registry" >&2; exit 1; }

# A chain of ten repositories, each a populated submodule of the one before: deeper than the scan
# follows downwards from its top, and with more superprojects than it follows upwards from its
# bottom. Half way down, everything is within reach in both directions.
chain="${sandbox}/chain"
g init -q "${chain}/r9"
g -C "${chain}/r9" commit -q --allow-empty -m init
for level in 8 7 6 5 4 3 2 1 0; do
  g init -q "${chain}/r${level}"
  g -C "${chain}/r${level}" commit -q --allow-empty -m init
  g -C "${chain}/r${level}" submodule --quiet add "${chain}/r$((level + 1))" sub
  g -C "${chain}/r${level}" commit -q -m 'add sub'
done
g clone -q --recurse-submodules "${chain}/r0" "${chain}/deep" 2>/dev/null
chain_top="${chain}/deep"
chain_mid="${chain_top}/sub/sub/sub/sub/sub"
chain_bottom="${chain_mid}/sub/sub/sub/sub"
[ "$(g -C "${chain_bottom}" rev-parse --show-toplevel)" = "${chain_bottom}" ] ||
  { echo "FAIL fixture: the ten-level chain is not populated to its bottom" >&2; exit 1; }
# A checkout whose `.gitmodules` cannot be parsed: which submodules it has is unknown.
broken="${sandbox}/broken"
g init -q "${broken}"
g -C "${broken}" commit -q --allow-empty -m init
printf '[submodule "x"\n\tpath = x\n' >"${broken}/.gitmodules"
broken_rc=0
g config -f "${broken}/.gitmodules" --get-regexp '^submodule\..*\.path$' >/dev/null 2>&1 || broken_rc=$?
# 0 would be a file git reads, and 1 a readable file that names no path: neither is the fixture.
[ "${broken_rc}" -gt 1 ] ||
  { echo "FAIL fixture: git reads the broken .gitmodules (exit ${broken_rc})" >&2; exit 1; }
# A populated submodule at a path that holds a tab. Its repository registers a worktree elsewhere,
# at a path without one, and a live session locked it: the lock row is ordinary, and it is the
# registry's own path that no tab-separated table can carry.
tabsub="${sandbox}/tabsub"
tabsub_path="pro"$'\t'"duct"
g init -q "${tabsub}"
g -C "${tabsub}" commit -q --allow-empty -m init
g -C "${tabsub}" submodule --quiet add "${sandbox}/product-origin" "${tabsub_path}"
g -C "${tabsub}" commit -q -m 'add product'
g -C "${tabsub}/${tabsub_path}" config remote.origin.url git@github.com:devantler-tech/product.git
g -C "${tabsub}/${tabsub_path}" worktree add -q -b claude/product-90 "${sandbox}/tabsub-wt"
g -C "${tabsub}/${tabsub_path}" worktree lock \
  --reason "claude agent tabsub (pid 9000002 start ${start_theirs})" "${sandbox}/tabsub-wt"
tabsub_common="$(g -C "${tabsub}/${tabsub_path}" rev-parse --path-format=absolute --git-common-dir)"
case "${tabsub_common}" in
  *$'\t'*) ;;
  *) echo "FAIL fixture: the tabbed submodule's git directory has no tab in its path" >&2; exit 1 ;;
esac
# A populated submodule whose superproject has no `.gitmodules` in its working tree, as a sparse
# checkout or an edit in progress leaves it. The index still holds the gitlink, and the submodule's
# repository registers a worktree a live session locked.
nomodules="${sandbox}/nomodules"
g init -q "${nomodules}"
g -C "${nomodules}" commit -q --allow-empty -m init
g -C "${nomodules}" submodule --quiet add "${sandbox}/product-origin" product
g -C "${nomodules}" commit -q -m 'add product'
g -C "${nomodules}/product" config remote.origin.url git@github.com:devantler-tech/product.git
g -C "${nomodules}/product" worktree add -q -b claude/product-91 "${sandbox}/nomodules-wt"
g -C "${nomodules}/product" worktree lock \
  --reason "claude agent nomodules (pid 9000002 start ${start_theirs})" "${sandbox}/nomodules-wt"
rm "${nomodules}/.gitmodules"
[ "$(g -C "${nomodules}" ls-files -s product | cut -d' ' -f1)" = 160000 ] ||
  { echo "FAIL fixture: the index of the checkout without .gitmodules holds no gitlink" >&2; exit 1; }
# A populated submodule at a path that holds a newline, named only by `.gitmodules` (its gitlink is
# not staged). git writes the path escaped and reads it back as two lines unless asked for NULs.
nlsub="${sandbox}/nlsub"
nlsub_path="pro"$'\n'"duct"
g init -q "${nlsub}"
g -C "${nlsub}" commit -q --allow-empty -m init
g clone -q "${sandbox}/product-origin" "${nlsub}/${nlsub_path}"
g config -f "${nlsub}/.gitmodules" submodule.safe.path "${nlsub_path}"
g config -f "${nlsub}/.gitmodules" submodule.safe.url "${sandbox}/product-origin"
g -C "${nlsub}/${nlsub_path}" config remote.origin.url git@github.com:devantler-tech/product.git
g -C "${nlsub}/${nlsub_path}" worktree add -q -b claude/product-92 "${sandbox}/nlsub-wt"
g -C "${nlsub}/${nlsub_path}" worktree lock \
  --reason "claude agent nlsub (pid 9000002 start ${start_theirs})" "${sandbox}/nlsub-wt"
[ "$(g config -f "${nlsub}/.gitmodules" --get-regexp '^submodule\..*\.path$' | wc -l | tr -d ' ')" = 2 ] ||
  { echo "FAIL fixture: git prints the newline path of .gitmodules on one line" >&2; exit 1; }
# A repository whose own path holds a newline, with a worktree elsewhere that a live session
# locked. git prints each of its paths on two lines, and the first line of each is the directory
# above it, which is a repository too: read a line to a value, the checkout is that other one.
g init -q "${sandbox}/nlouter"
g -C "${sandbox}/nlouter" commit -q --allow-empty -m init
nlrepo="${sandbox}/nlouter/"$'\n'"inner"
g init -q "${nlrepo}"
g -C "${nlrepo}" commit -q --allow-empty -m init
g -C "${nlrepo}" config remote.origin.url git@github.com:devantler-tech/nlrepo.git
g -C "${nlrepo}" worktree add -q -b claude/nl-93 "${sandbox}/nlrepo-wt"
g -C "${nlrepo}" worktree lock \
  --reason "claude agent nlrepo (pid 9000002 start ${start_theirs})" "${sandbox}/nlrepo-wt"
[ "$(g -C "${nlrepo}" rev-parse --show-toplevel | wc -l | tr -d ' ')" = 2 ] ||
  { echo "FAIL fixture: git prints the newline checkout's path on one line" >&2; exit 1; }
# Two checkouts whose `.gitmodules` names a path that leads out of them, by a step up and by a
# symbolic link. Both lead to the checkout above whose submodule's registry holds a live lock: a
# scan that followed either would be reading a repository that is no part of the one it stands in.
escape_up="${sandbox}/escape-up"
escape_link="${sandbox}/escape-link"
for escape in "${escape_up}" "${escape_link}"; do
  g init -q "${escape}"
  g -C "${escape}" commit -q --allow-empty -m init
  g -C "${escape}" config remote.origin.url git@github.com:devantler-tech/escape.git
  g config -f "${escape}/.gitmodules" submodule.out.url "${sandbox}/product-origin"
done
g config -f "${escape_up}/.gitmodules" submodule.out.path ../nomodules
ln -s ../nomodules "${escape_link}/out"
g config -f "${escape_link}/.gitmodules" submodule.out.path out
[ -e "${escape_up}/../nomodules/.git" ] && [ -e "${escape_link}/out/.git" ] ||
  { echo "FAIL fixture: the paths that leave their checkout do not lead to a repository" >&2; exit 1; }
# locked_submodule <superproject> <path> <branch> <worktree> — a superproject with the product
# repository as a populated submodule at <path>, whose registry holds a worktree a live session
# locked on <branch>.
locked_submodule() {
  g init -q "$1"
  g -C "$1" commit -q --allow-empty -m init
  g -C "$1" submodule --quiet add "${sandbox}/product-origin" "$2"
  g -C "$1" commit -q -m 'add product'
  g -C "$1/$2" config remote.origin.url git@github.com:devantler-tech/product.git
  g -C "$1/$2" worktree add -q -b "$3" "$4"
  g -C "$1/$2" worktree lock --reason "claude agent $3 (pid 9000002 start ${start_theirs})" "$4"
}
# A submodule at a path that holds the byte the scan uses to stand for a newline.
ctrlsub="${sandbox}/ctrlsub"
locked_submodule "${ctrlsub}" "pro"$'\001'"duct" claude/product-94 "${sandbox}/ctrlsub-wt"
# A checkout whose index file is gone, and whose working tree has no `.gitmodules`: git lists an
# empty index without complaint, while the commit checked out holds the submodule.
noindex="${sandbox}/noindex"
locked_submodule "${noindex}" product claude/product-95 "${sandbox}/noindex-wt"
rm "${noindex}/.gitmodules" "${noindex}/.git/index"
[ -z "$(g -C "${noindex}" ls-files -s)" ] ||
  { echo "FAIL fixture: git still lists entries for the checkout whose index was removed" >&2; exit 1; }
# A submodule below a directory this user may not look into (the mode is set where it is asked).
noperm="${sandbox}/noperm"
locked_submodule "${noperm}" inner/product claude/product-96 "${sandbox}/noperm-wt"
# A populated submodule whose `.git` entry names a git directory that is not there.
corrupt="${sandbox}/corrupt"
g init -q "${corrupt}"
g -C "${corrupt}" commit -q --allow-empty -m init
g -C "${corrupt}" submodule --quiet add "${sandbox}/product-origin" product
g -C "${corrupt}" commit -q -m 'add product'
printf 'gitdir: %s\n' "${sandbox}/no-such-git-directory" >"${corrupt}/product/.git"
if g -C "${corrupt}/product" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "FAIL fixture: git still resolves the submodule whose .git entry was broken" >&2
  exit 1
fi

# ── A locked worktree whose path holds a tab (monorepo#3825) ────────────────────────────────────
# A third repository, so the row no table can carry is in sight only for the cases that ask it.
tabs="${sandbox}/tabs"
tab_wt="${tabs}/.claude/worktrees/agent"$'\t'"tab"
g init -q "${tabs}"
g -C "${tabs}" commit -q --allow-empty -m init
g -C "${tabs}" config remote.origin.url git@github.com:devantler-tech/tabs.git
g -C "${tabs}" worktree add -q -b worktree-agent-tab "${tab_wt}"
g -C "${tabs}" worktree lock --reason "claude agent agent-tab (pid 9000002 start ${start_theirs})" "${tab_wt}"
g -C "${tabs}" worktree add -q -b claude/plain-80 "${tabs}/.claude/worktrees/plain"
tabs_list="$(g -C "${tabs}" worktree list --porcelain)"
grep -qxF "worktree ${tab_wt}" <<<"${tabs_list}" ||
  { echo "FAIL fixture: git does not list the tabbed worktree path raw" >&2; exit 1; }

# ── Shims ───────────────────────────────────────────────────────────────────────────────────────
shims="${sandbox}/shims"
mkdir -p "${shims}"
cat >"${shims}/lsof" <<'SHIM'
#!/usr/bin/env bash
cat "${FIXTURE_LSOF:?}"
exit "${FIXTURE_LSOF_RC:-0}"
SHIM
# The real process table (so the helper's own ancestry is real), with one row replaced and the
# scripted holder rows appended. The start-time read behind a worktree lock is answered from a
# fixture, and only when asked in the spelling the harness recorded: the C locale and UTC.
cat >"${shims}/ps" <<'SHIM'
#!/usr/bin/env bash
if [ "${FIXTURE_PS_FAIL:-0}" = 1 ]; then exit 1; fi
case " $* " in
  *' lstart= '*)
    if [ "${FIXTURE_STARTS_FAIL:-0}" = 1 ] || [ "${TZ:-}" != UTC ] || [ "${LC_ALL:-}" != C ]; then exit 1; fi
    cat "${FIXTURE_PS_STARTS:?}"
    exit 0
    ;;
esac
/bin/ps "$@" | awk -v row="${FIXTURE_SELF_ROW:-}" '
  BEGIN { split(row, r, " ") }
  row != "" && $1 == r[1] { print row; next }
  { print }'
cat "${FIXTURE_PS_EXTRA:?}"
SHIM
chmod +x "${shims}/lsof" "${shims}/ps"
# A git that cannot list worktrees and is the real one for everything else, on PATH only for the
# case that needs it.
gitshim="${sandbox}/gitshim"
mkdir -p "${gitshim}"
real_git="$(command -v git)"
cat >"${gitshim}/git" <<SHIM
#!/usr/bin/env bash
case " \$* " in
  *' worktree list '*)
    if [ -n "\${FIXTURE_LIST_FAIL_AT:-}" ]; then
      # Only the listing asked of that one checkout fails.
      case " \$* " in *" -C \${FIXTURE_LIST_FAIL_AT} "*) exit 1 ;; esac
    elif [ -n "\${FIXTURE_RESOLVE_FAIL_AT:-}" ]; then
      :
    else
      # The first FIXTURE_LIST_OK listings succeed; every later one fails.
      n=\$((\$(cat "${gitshim}/count" 2>/dev/null || echo 0) + 1))
      echo "\${n}" >"${gitshim}/count"
      [ "\${n}" -le "\${FIXTURE_LIST_OK:-0}" ] || exit 1
    fi
    ;;
esac
# With FIXTURE_RESOLVE_FAIL_AT, that one checkout cannot be resolved and every listing succeeds.
# A value that begins with super: fails only the question of what its superproject is.
case "\${FIXTURE_RESOLVE_FAIL_AT:-}" in
  '') ;;
  super:*)
    case " \$* " in
      *" -C \${FIXTURE_RESOLVE_FAIL_AT#super:} rev-parse --show-superproject-working-tree "*) exit 128 ;;
    esac
    ;;
  *)
    case " \$* " in *" -C \${FIXTURE_RESOLVE_FAIL_AT} rev-parse "*) exit 128 ;; esac
    ;;
esac
exec "${real_git}" "\$@"
SHIM
# Beside it, a tr and a sed that fail only the step that turns a NUL-terminated list of submodules
# into lines, when FIXTURE_SUBLIST_FAIL names them, and are the real ones otherwise.
real_tr="$(command -v tr)"
real_sed="$(command -v sed)"
cat >"${gitshim}/tr" <<SHIM
#!/usr/bin/env bash
if [ "\${FIXTURE_SUBLIST_FAIL:-}" = tr ]; then
  case "\${1:-}" in '\n\0'*) exit 1 ;; esac
fi
exec "${real_tr}" "\$@"
SHIM
cat >"${gitshim}/sed" <<SHIM
#!/usr/bin/env bash
if [ "\${FIXTURE_SUBLIST_FAIL:-}" = sed ]; then
  case "\${2:-}" in 's/^160000 '*) cat >/dev/null; exit 1 ;; esac
fi
exec "${real_sed}" "\$@"
SHIM
# And a sort that fails only the sort of the checkouts the lock scan starts from.
real_sort="$(command -v sort)"
cat >"${gitshim}/sort" <<SHIM
#!/usr/bin/env bash
if [ "\${FIXTURE_SUBLIST_FAIL:-}" = sort ]; then
  case "\${!#}" in */scan) exit 1 ;; esac
fi
exec "${real_sort}" "\$@"
SHIM
chmod +x "${gitshim}/git" "${gitshim}/tr" "${gitshim}/sed" "${gitshim}/sort"

lsof_full="${sandbox}/lsof-full"
cat >"${lsof_full}" <<LSOF
p${me}
fcwd
n${w1}
p9000001
fcwd
n${w1}
p9000002
fcwd
n${w1}
p9000003
fcwd
n${w2}
p9000004
fcwd
n${w2}
p9000005
fcwd
n${main}
p9000006
fcwd
n${w1}/product
p9000007
fcwd
n/
p9000008
fcwd
n${w2}
p9000009
fcwd
n${w3}
p9000010
fcwd
n${elsewhere}
p9000013
fcwd
n${w2}
p9000014
fcwd
n${w2}
p9000016
fcwd
n${w2}
p9000017
fcwd
n${w2}
LSOF
# 9000008 is in the lsof output but not in the process table: it exited before ps ran. 9000011 and
# 9000012 are in the table but work nowhere unless a test's lsof file says so. In w2, 9000013 is a
# shell at its prompt and 9000016 a terminal-tab shell whose only child is another shell: neither
# does work. 9000014 is a login shell running `make`, so it is busy.
ps_extra="${sandbox}/ps-extra"
cat >"${ps_extra}" <<PS
9000001 ${me} go
9000002 1 /usr/local/bin/claude
9000003 1 node
9000004 ${me} sleep
9000005 1 git
9000006 1 sleep
9000007 1 bash
9000009 1 git
9000010 1 vim
9000011 1 codex
9000012 1 disclaimer
9000013 1 zsh
9000014 1 -bash
9000015 9000014 make
9000016 1 zsh (kiro-cli-term)
9000017 9000016 zsh
9000018 ${me} go
PS
lsof_empty="${sandbox}/lsof-empty"
: >"${lsof_empty}"
lsof_outer="${sandbox}/lsof-outer"
cat "${lsof_full}" >"${lsof_outer}"
printf 'p9000011\nfcwd\nn%s\n' "${w2}" >>"${lsof_outer}"
lsof_wrapper="${sandbox}/lsof-wrapper"
cat "${lsof_full}" >"${lsof_wrapper}"
# ...and a fourth holder of the asker's own, so the name list is capped while the count is not.
printf 'p9000012\nfcwd\nn%s\np9000018\nfcwd\nn%s\n' "${w1}" "${w1}" >>"${lsof_wrapper}"
lsof_idle_shells="${sandbox}/lsof-idle-shells"
printf 'p9000013\nfcwd\nn%s\np9000016\nfcwd\nn%s\np9000017\nfcwd\nn%s\n' "${w2}" "${w2}" "${w2}" >"${lsof_idle_shells}"
lsof_busy_shell="${sandbox}/lsof-busy-shell"
printf 'p9000013\nfcwd\nn%s\np9000014\nfcwd\nn%s\n' "${w2}" "${w2}" >"${lsof_busy_shell}"
# The hub repository: each session's process sits in its own worktree and NOTHING has a working
# directory in a subagent's worktree, which is the state between two of a worker's commands.
lsof_hub="${sandbox}/lsof-hub"
printf 'p%s\nfcwd\nn%s\np9000002\nfcwd\nn%s\np9000003\nfcwd\nn/\n' "${me}" "${hub_wt}/mine" "${hub_wt}/theirs" >"${lsof_hub}"
lsof_hub_s1="${sandbox}/lsof-hub-s1"
cat "${lsof_hub}" >"${lsof_hub_s1}"
printf 'p9000011\nfcwd\nn%s\n' "${hub_wt}/s1" >>"${lsof_hub_s1}"
# ...and with a process in the worktree whose lock cannot be read: a rival, then the asker's own.
lsof_hub_rival="${sandbox}/lsof-hub-rival"
printf 'p%s\nfcwd\nn%s\np9000003\nfcwd\nn%s\n' "${me}" "${hub_wt}/mine" "${hub_wt}/agent-a4" >"${lsof_hub_rival}"
lsof_hub_own="${sandbox}/lsof-hub-own"
printf 'p%s\nfcwd\nn%s\np9000001\nfcwd\nn%s\n' "${me}" "${hub_wt}/mine" "${hub_wt}/agent-a4" >"${lsof_hub_own}"
# What `ps -A -o pid= -o lstart=` prints for the processes a lock may name. 9000003 holds the pid
# a3's lock names, with another start time; 9000099 is not running.
ps_starts="${sandbox}/ps-starts"
{
  printf '%7s %s    \n' "${me}" "${start_mine}"
  printf '%7s %s    \n' 9000002 "${start_theirs}"
  printf '%7s %s    \n' 9000003 'Sat Oct  3 09:30:00 2026'
  printf '%7s %s    \n' 9000011 "${start_s1}"
} >"${ps_starts}"
starts_fail=0
list_fail=0
list_ok=0
list_fail_at=''
resolve_fail_at=''
sublist_fail=''
# Only the asking session, at w1; only a process at the main checkout; only another process at w2.
lsof_w2_only="${sandbox}/lsof-w2-only"
printf 'p9000003\nfcwd\nn%s\n' "${w2}" >"${lsof_w2_only}"
lsof_w1_only="${sandbox}/lsof-w1-only"
printf 'p%s\nfcwd\nn%s\n' "${me}" "${w1}" >"${lsof_w1_only}"
# The asking session at w1 and its own child working inside the worktree nested there.
lsof_w1_child="${sandbox}/lsof-w1-child"
printf 'p%s\nfcwd\nn%s\np9000001\nfcwd\nn%s\n' "${me}" "${w1}" "${w1_run}" >"${lsof_w1_child}"
lsof_main_only="${sandbox}/lsof-main-only"
printf 'p9000005\nfcwd\nn%s\n' "${main}" >"${lsof_main_only}"

# pr <owner/repo> <n> <head> [<head-owner>] [<head-repo>] — one gh pr view --json
# url,headRefName,headRepositoryOwner,headRepository object; the head defaults to the base repository.
pr() {
  local base_owner="${1%%/*}" base_name="${1#*/}"
  jq -nc --arg repo "$1" --arg n "$2" --arg head "$3" --arg owner "${4:-${base_owner}}" \
    --arg name "${5:-${base_name}}" \
    '{url: "https://github.com/\($repo)/pull/\($n)", headRefName: $head,
      headRepositoryOwner: {id: "x", login: $owner}, headRepository: {id: "y", name: $name}}'
}

# expect <label> <asking-dir> <self-row> <want-rc> <want-stdout> <stdin> [lsof-file] [lsof-rc] [ps-fail]
# `starts_fail=1` fails the start-time read and `list_fail=1` the worktree listing, for the cases
# that set them; with `list_fail=1`, the first `list_ok` listings still succeed, or, when
# `list_fail_at` names a checkout, only the listing asked of that checkout fails.
expect() {
  local label="$1" dir="$2" self_row="$3" want_rc="$4" want_out="$5" payload="$6"
  local lsof_file="${7:-${lsof_full}}" lsof_rc="${8:-0}" ps_fail="${9:-0}" out rc=0
  local path="${shims}:${PATH}"
  if [ "${list_fail}" = 1 ]; then path="${gitshim}:${path}"; fi
  rm -f -- "${gitshim}/count"
  checks=$((checks + 1))
  out="$(cd "${dir}" && PATH="${path}" FIXTURE_LSOF="${lsof_file}" FIXTURE_LSOF_RC="${lsof_rc}" \
    FIXTURE_PS_FAIL="${ps_fail}" FIXTURE_PS_EXTRA="${ps_extra}" FIXTURE_SELF_ROW="${self_row}" \
    FIXTURE_PS_STARTS="${ps_starts}" FIXTURE_STARTS_FAIL="${starts_fail}" FIXTURE_LIST_OK="${list_ok}" \
    FIXTURE_LIST_FAIL_AT="${list_fail_at}" FIXTURE_RESOLVE_FAIL_AT="${resolve_fail_at}" \
    FIXTURE_SUBLIST_FAIL="${sublist_fail}" \
    "${tool}" --input - <<<"${payload}" 2>/dev/null)" || rc=$?
  if [ "${rc}" = "${want_rc}" ] && [ "${out}" = "${want_out}" ]; then
    echo "ok   ${label}"
  else
    printf 'FAIL %s\n  want rc=%s [%s]\n  got  rc=%s [%s]\n' "${label}" "${want_rc}" "${want_out}" "${rc}" "${out}" >&2
    failures=$((failures + 1))
  fi
}

# The asking session: the test shell plays its `claude` process. Its parent is cut to 1 so a real
# session process further up (when this test itself runs under one) cannot stand in for it.
session="${me} 1 claude"
plain="${me} 1 testshell"

# ── Who holds what ──────────────────────────────────────────────────────────────────────────────
expect "another session in the asker's own worktree is live; the asker and its child are self" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#1 holder=live:1:9000002/claude+self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/demo 1 claude/feature-1)"
expect "a sibling's process in another worktree is live even though it descends from the session" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#2 holder=live:3:9000003/node,9000004/sleep,9000014/-bash" \
  "$(pr devantler-tech/demo 2 claude/feature-2)"
expect "a session at its worktree root holds the branch in its populated submodule" \
  "${w1}" "${session}" 0 \
  "devantler-tech/product#7 holder=live:2:9000002/claude,9000006/sleep+self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/product 7 claude/product-7)"
expect "a per-session worktree holds the product worktree nested in its submodule" \
  "${w1}" "${session}" 0 \
  "devantler-tech/product#8 holder=live:1:9000002/claude+self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/product 8 claude/product-8)"
expect "a main checkout never claims a worktree nested in its own submodule" \
  "${w1}" "${session}" 0 \
  "devantler-tech/product#9 holder=none" \
  "$(pr devantler-tech/product 9 claude/product-main-nested)"
expect "a branch no checkout has is none" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#3 holder=none" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)"
expect "the same branch name in another repository is not a match" \
  "${w1}" "${session}" 0 \
  "devantler-tech/other#4 holder=none" \
  "$(pr devantler-tech/other 4 claude/feature-2)"
expect "a fork head is not examined locally" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#5 holder=fork" \
  "$(pr devantler-tech/demo 5 claude/feature-1 someone)"
expect "a checkout detached mid-rebase still holds the branch it is rebasing" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#10 holder=live:1:9000009/git" \
  "$(pr devantler-tech/demo 10 claude/rebasing-10)"
expect "any remote names the repository, not only one called origin" \
  "${w1}" "${session}" 0 \
  "devantler-tech/tool#11 holder=live:1:9000010/vim" \
  "$(pr devantler-tech/tool 11 claude/tool-11)"
expect "a cross-repository head inside the organisation is matched on the HEAD repository" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#12 holder=live:1:9000010/vim" \
  "$(pr devantler-tech/demo 12 claude/tool-11 devantler-tech tool)"
expect "a base-repository checkout of the same branch name is not a cross-repository head's checkout" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#13 holder=none" \
  "$(pr devantler-tech/demo 13 claude/feature-2 devantler-tech other)"

# ── Who is self ─────────────────────────────────────────────────────────────────────────────────
expect "asked from w2, the session's process in w2 is self and its process in w1 is live" \
  "${w2}" "${session}" 0 \
  "devantler-tech/demo#2 holder=live:2:9000003/node,9000014/-bash+self:1:9000004/sleep" \
  "$(pr devantler-tech/demo 2 claude/feature-2)"
expect "asked from w2, the asker's own ancestor is still self wherever it works" \
  "${w2}" "${session}" 0 \
  "devantler-tech/demo#1 holder=live:2:9000002/claude,9000001/go+self:1:${me}/claude" \
  "$(pr devantler-tech/demo 1 claude/feature-1)"
expect "asked from inside a submodule, the asker's tree is the whole superproject checkout" \
  "${w1}/product" "${session}" 0 \
  "devantler-tech/product#7 holder=live:2:9000002/claude,9000006/sleep+self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/product 7 claude/product-7)"
expect "with no session process among the ancestors, only the asker's own ancestry is self" \
  "${w1}" "${plain}" 0 \
  "devantler-tech/demo#1 holder=live:2:9000002/claude,9000001/go+self:1:${me}/testshell" \
  "$(pr devantler-tech/demo 1 claude/feature-1)"
expect "the session's own launcher above it (the app's wrapper) is self, not a rival" \
  "${w1}" "${me} 9000012 claude" 0 \
  "devantler-tech/demo#1 holder=live:1:9000002/claude+self:4:${me}/claude,9000001/go,9000012/disclaimer" \
  "$(pr devantler-tech/demo 1 claude/feature-1)" "${lsof_wrapper}"
expect "shells waiting at a prompt hold nothing, even a terminal tab with a shell under it" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#2 holder=none" \
  "$(pr devantler-tech/demo 2 claude/feature-2)" "${lsof_idle_shells}"
expect "a shell running a command holds its checkout" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#2 holder=live:1:9000014/-bash" \
  "$(pr devantler-tech/demo 2 claude/feature-2)" "${lsof_busy_shell}"
expect "an outer session that launched the asking one is live, not part of the asker" \
  "${w1}" "${me} 9000011 claude" 0 \
  "devantler-tech/demo#2 holder=live:4:9000011/codex,9000003/node,9000004/sleep" \
  "$(pr devantler-tech/demo 2 claude/feature-2)" "${lsof_outer}"

# ── Worktree locks (monorepo#3780) ──────────────────────────────────────────────────────────────
mine="${hub_wt}/mine"
expect "a locked worktree is held while the process its lock names lives, with no process inside it" \
  "${w1}" "${session}" 0 \
  "devantler-tech/hub#40 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/hub 40 worktree-agent-a1)" "${lsof_hub}"
expect "the lock is read from the repository asked from, with no process working anywhere in it" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#40 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/hub 40 worktree-agent-a1)"
expect "a lock holds the checkouts its worktree owns: the branch in its populated submodule" \
  "${mine}" "${session}" 0 \
  "devantler-tech/product#32 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/product 32 claude/product-32)" "${lsof_hub}"
expect "a lock whose process exited holds nothing" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#41 holder=none" \
  "$(pr devantler-tech/hub 41 worktree-agent-a2)" "${lsof_hub}"
expect "a lock whose pid now belongs to a process with another start time holds nothing" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#42 holder=none" \
  "$(pr devantler-tech/hub 42 worktree-agent-a3)" "${lsof_hub}"
expect "a lock that records no start time holds nothing once its process exited" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#46 holder=none" \
  "$(pr devantler-tech/hub 46 worktree-agent-a7)" "${lsof_hub}"
expect "an unreadable lock on a worktree whose directory is gone holds nothing: no checkout is left" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#50 holder=none" \
  "$(pr devantler-tech/hub 50 worktree-agent-a11)" "${lsof_hub}"
expect "a live lock on a worktree that lost its .git entry does not hold the checkout around it" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#52 holder=none" \
  "$(pr devantler-tech/hub 52 main)" "${lsof_hub}"
expect "a lock reason that is not the harness's is unknown, never none" \
  "${mine}" "${session}" 2 \
  "devantler-tech/hub#43 holder=unknown:lock-reason" \
  "$(pr devantler-tech/hub 43 worktree-agent-a4)" "${lsof_hub}"
expect "a lock with no reason at all is unknown, never none" \
  "${mine}" "${session}" 2 \
  "devantler-tech/hub#44 holder=unknown:lock-reason" \
  "$(pr devantler-tech/hub 44 worktree-agent-a5)" "${lsof_hub}"
expect "a start time in another shape is unknown, never a reused pid" \
  "${mine}" "${session}" 2 \
  "devantler-tech/hub#47 holder=unknown:lock-reason" \
  "$(pr devantler-tech/hub 47 worktree-agent-a8)" "${lsof_hub}"
expect "a lock that records no start time is unknown while its pid is alive: owner or reused pid" \
  "${mine}" "${session}" 2 \
  "devantler-tech/hub#45 holder=unknown:lock-reason" \
  "$(pr devantler-tech/hub 45 worktree-agent-a6)" "${lsof_hub}"
expect "an unreadable lock is unknown for the PR it serves only; the others are still answered" \
  "${mine}" "${session}" 2 \
  "devantler-tech/hub#41 holder=none
devantler-tech/hub#43 holder=unknown:lock-reason
devantler-tech/hub#40 holder=live:1:9000002/claude" \
  "$(jq -sc . <<<"$(pr devantler-tech/hub 41 worktree-agent-a2) $(pr devantler-tech/hub 43 worktree-agent-a4) $(pr devantler-tech/hub 40 worktree-agent-a1)")" \
  "${lsof_hub}"
expect "a rival working in the worktree answers live: an unreadable lock can only add holders" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#43 holder=live:1:9000003/node" \
  "$(pr devantler-tech/hub 43 worktree-agent-a4)" "${lsof_hub_rival}"
expect "the asker's own process in the worktree does not vouch for a lock it cannot read" \
  "${hub_wt}/agent-a4" "${session}" 2 \
  "devantler-tech/hub#43 holder=unknown:lock-reason" \
  "$(pr devantler-tech/hub 43 worktree-agent-a4)" "${lsof_hub_own}"
expect "a subagent asking from its own locked worktree is self" \
  "${hub_wt}/agent-a9" "${session}" 0 \
  "devantler-tech/hub#48 holder=self:1:${me}/claude" \
  "$(pr devantler-tech/hub 48 worktree-agent-a9)" "${lsof_hub}"
expect "a sibling subagent's locked worktree stays live, though one session process locked both" \
  "${hub_wt}/agent-a10" "${session}" 0 \
  "devantler-tech/hub#48 holder=live:1:${me}/claude" \
  "$(pr devantler-tech/hub 48 worktree-agent-a9)" "${lsof_hub}"
expect "asked from the session's own worktree, the worktree it locked for a subagent is live" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#48 holder=live:1:${me}/claude" \
  "$(pr devantler-tech/hub 48 worktree-agent-a9)" "${lsof_hub}"
expect "with no session process among the ancestors, a lock naming the asker's own pid is still live elsewhere" \
  "${mine}" "${plain}" 0 \
  "devantler-tech/hub#48 holder=live:1:${me}/testshell" \
  "$(pr devantler-tech/hub 48 worktree-agent-a9)" "${lsof_hub}"
expect "a session's lock on its own worktree holds it between that session's commands" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#49 holder=live:1:9000011/codex" \
  "$(pr devantler-tech/hub 49 claude/s1-33)" "${lsof_hub}"
expect "a session sitting in the worktree it locked is counted once" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#49 holder=live:1:9000011/codex" \
  "$(pr devantler-tech/hub 49 claude/s1-33)" "${lsof_hub_s1}"
expect "a session sitting in the worktree it locked is answered by its working directory: still self for its subagent" \
  "${hub_wt}/agent-a9" "${session}" 0 \
  "devantler-tech/hub#51 holder=self:1:${me}/claude" \
  "$(pr devantler-tech/hub 51 claude/mine-31)" "${lsof_hub}"
ps_starts_real="${ps_starts}"
ps_starts="${sandbox}/ps-starts-odd"
printf '%7s %s\n' 9000002 '2026-10-02 14:59:59' >"${ps_starts}"
expect "a live start time this host prints in another shape is unknown, never a reused pid" \
  "${mine}" "${session}" 2 \
  "devantler-tech/hub#40 holder=unknown:lock-reason" \
  "$(pr devantler-tech/hub 40 worktree-agent-a1)" "${lsof_hub}"
ps_starts="${sandbox}/ps-starts-partial"
printf '%7s %s    \n' 9000003 'Sat Oct  3 09:30:00 2026' >"${ps_starts}"
expect "a live pid missing from the start-time read is unknown: exited since, or a partial read" \
  "${mine}" "${session}" 2 \
  "devantler-tech/hub#40 holder=unknown:lock-reason" \
  "$(pr devantler-tech/hub 40 worktree-agent-a1)" "${lsof_hub}"
ps_starts="${ps_starts_real}"
starts_fail=1
expect "start times that cannot be read are unknown, never a reused pid" \
  "${mine}" "${session}" 2 \
  "devantler-tech/hub#40 holder=unknown:ps-failed
devantler-tech/hub#41 holder=unknown:ps-failed" \
  "$(jq -sc . <<<"$(pr devantler-tech/hub 40 worktree-agent-a1) $(pr devantler-tech/hub 41 worktree-agent-a2)")" \
  "${lsof_hub}"
starts_fail=0
list_fail=1
expect "a worktree list that cannot be read is unknown, never none" \
  "${mine}" "${session}" 2 \
  "devantler-tech/hub#41 holder=unknown:worktree-list" \
  "$(pr devantler-tech/hub 41 worktree-agent-a2)" "${lsof_hub}"
list_fail=0

# ── Locks in another repository than the one asked from (monorepo#3825) ─────────────────────────
# Nobody works in any repository: every lock below is found from where the asker stands, or not
# at all.
lsof_nowhere="${sandbox}/lsof-nowhere"
printf 'p%s\nfcwd\nn/\np9000002\nfcwd\nn/\n' "${me}" >"${lsof_nowhere}"
# The lock's owner sits at the hub's main checkout; the asker is in an unrelated repository.
lsof_owner_at_hub="${sandbox}/lsof-owner-at-hub"
printf 'p%s\nfcwd\nn%s\np9000002\nfcwd\nn%s\n' "${me}" "${w1}" "${hub}" >"${lsof_owner_at_hub}"
# Some other process sits inside the hub's product submodule; nobody is in the hub itself.
lsof_in_submodule="${sandbox}/lsof-in-submodule"
printf 'p%s\nfcwd\nn%s\np9000003\nfcwd\nn%s\n' "${me}" "${w1}" "${hub_product}" >"${lsof_in_submodule}"
expect "a lock in a submodule's registry is read when its owner works outside it and the asker stands in the superproject" \
  "${hub}" "${session}" 0 \
  "devantler-tech/product#70 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/product 70 claude/product-70)" "${lsof_nowhere}"
expect "a lock in the superproject's registry is read when the asker stands inside a submodule and nobody is in the superproject" \
  "${hub_product}" "${session}" 0 \
  "devantler-tech/hub#40 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/hub 40 worktree-agent-a1)" "${lsof_nowhere}"
expect "a lock in a submodule's registry is read when its owner sits at the superproject's main checkout" \
  "${w1}" "${session}" 0 \
  "devantler-tech/product#70 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/product 70 claude/product-70)" "${lsof_owner_at_hub}"
expect "a lock in the superproject's registry is read when the only process near it works inside a submodule" \
  "${w1}" "${session}" 0 \
  "devantler-tech/hub#40 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/hub 40 worktree-agent-a1)" "${lsof_in_submodule}"
expect "a lock found in a submodule's registry still holds nothing once its process exited" \
  "${hub}" "${session}" 0 \
  "devantler-tech/product#71 holder=none" \
  "$(pr devantler-tech/product 71 claude/product-71)" "${lsof_nowhere}"
expect "a lock in a repository unrelated to the asker and to every process is out of sight" \
  "${w1}" "${session}" 0 \
  "devantler-tech/product#70 holder=none" \
  "$(pr devantler-tech/product 70 claude/product-70)" "${lsof_nowhere}"
# Every other listing succeeds, so only the scan of the submodule's registry can answer unknown.
list_fail=1
list_fail_at="${hub_product}"
expect "a submodule's worktree list that cannot be read is unknown, never none" \
  "${hub}" "${session}" 2 \
  "devantler-tech/product#71 holder=unknown:worktree-list" \
  "$(pr devantler-tech/product 71 claude/product-71)" "${lsof_nowhere}"
list_fail=0
list_fail_at=''
# A registry the scan knows of and does not reach may hold a lock on any PR asked about, so
# passing it over is unknown, never none. Nobody holds this branch anywhere: every `unknown:` below
# comes from the scan alone.
# `list_fail=1` puts the git shim on the path; with `resolve_fail_at` set it fails no listing.
list_fail=1
resolve_fail_at="${hub}"
expect "a superproject that cannot be resolved is unknown: its registry was never read" \
  "${hub_product}" "${session}" 2 \
  "devantler-tech/hub#40 holder=unknown:lock-scan" \
  "$(pr devantler-tech/hub 40 worktree-agent-a1)" "${lsof_nowhere}"
resolve_fail_at="super:${hub_product}"
expect "a checkout git cannot say the superproject of is unknown" \
  "${hub_product}" "${session}" 2 \
  "devantler-tech/hub#40 holder=unknown:lock-scan" \
  "$(pr devantler-tech/hub 40 worktree-agent-a1)" "${lsof_nowhere}"
list_fail=0
resolve_fail_at=''
expect "a populated submodule whose .git entry cannot be read is unknown: its registry was never read" \
  "${corrupt}" "${session}" 2 \
  "devantler-tech/demo#3 holder=unknown:lock-scan" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)" "${lsof_nowhere}"
expect "a registry whose own path holds a tab is unknown: the scan's table cannot carry it" \
  "${tabsub}" "${session}" 2 \
  "devantler-tech/product#90 holder=unknown:lock-scan" \
  "$(pr devantler-tech/product 90 claude/product-90)" "${lsof_nowhere}"
expect "a lock in a submodule's registry is read when the superproject's working tree has no .gitmodules" \
  "${nomodules}" "${session}" 0 \
  "devantler-tech/product#91 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/product 91 claude/product-91)" "${lsof_nowhere}"
# Half a list of submodules would read as a whole one, so a step that fails while the list is built
# is unknown. `list_fail=1` puts the shims on the path; with `sublist_fail` set they fail no listing.
list_fail=1
resolve_fail_at='nowhere'
for sublist_fail in tr sed sort; do
  expect "a list the scan needs that could not be built (${sublist_fail} failed) is unknown, never none" \
    "${nomodules}" "${session}" 2 \
    "devantler-tech/product#91 holder=unknown:lock-scan" \
    "$(pr devantler-tech/product 91 claude/product-91)" "${lsof_nowhere}"
done
sublist_fail=''
expect "with those steps working, the same question on the same path is answered" \
  "${nomodules}" "${session}" 0 \
  "devantler-tech/product#91 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/product 91 claude/product-91)" "${lsof_nowhere}"
list_fail=0
resolve_fail_at=''
expect "a checkout whose own path holds a newline is unknown: git's answer about it cannot be read" \
  "${nlrepo}" "${session}" 2 \
  "devantler-tech/nlrepo#93 holder=unknown:lock-scan" \
  "$(pr devantler-tech/nlrepo 93 claude/nl-93)" "${lsof_nowhere}"
expect "a path .gitmodules names by a step up is not followed out of the checkout" \
  "${escape_up}" "${session}" 0 \
  "devantler-tech/product#91 holder=none" \
  "$(pr devantler-tech/product 91 claude/product-91)" "${lsof_nowhere}"
expect "a path .gitmodules names through a symbolic link is not followed out of the checkout" \
  "${escape_link}" "${session}" 0 \
  "devantler-tech/product#91 holder=none" \
  "$(pr devantler-tech/product 91 claude/product-91)" "${lsof_nowhere}"
expect "a submodule at a path that holds the byte standing for a newline is unknown, never none" \
  "${ctrlsub}" "${session}" 2 \
  "devantler-tech/product#94 holder=unknown:lock-scan" \
  "$(pr devantler-tech/product 94 claude/product-94)" "${lsof_nowhere}"
expect "an index that lists nothing under a commit that holds files is unknown: the index is gone" \
  "${noindex}" "${session}" 2 \
  "devantler-tech/product#95 holder=unknown:lock-scan" \
  "$(pr devantler-tech/product 95 claude/product-95)" "${lsof_nowhere}"
# root may look into any directory, so this case cannot be set up as root.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "${noperm}/inner"
  expect "a submodule below a directory that may not be looked into is unknown, never none" \
    "${noperm}" "${session}" 2 \
    "devantler-tech/product#96 holder=unknown:lock-scan" \
    "$(pr devantler-tech/product 96 claude/product-96)" "${lsof_nowhere}"
  chmod 755 "${noperm}/inner"
fi
expect "the same submodule is read once its directory may be looked into" \
  "${noperm}" "${session}" 0 \
  "devantler-tech/product#96 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/product 96 claude/product-96)" "${lsof_nowhere}"
expect "a populated submodule at a path that holds a newline is unknown: no list here can carry it" \
  "${nlsub}" "${session}" 2 \
  "devantler-tech/product#92 holder=unknown:lock-scan" \
  "$(pr devantler-tech/product 92 claude/product-92)" "${lsof_nowhere}"
expect "a .gitmodules that cannot be parsed is unknown: which submodules it names was never read" \
  "${broken}" "${session}" 2 \
  "devantler-tech/demo#3 holder=unknown:lock-scan" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)" "${lsof_nowhere}"
expect "populated submodules nested deeper than the scan follows are unknown" \
  "${chain_top}" "${session}" 2 \
  "devantler-tech/demo#3 holder=unknown:lock-scan" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)" "${lsof_nowhere}"
expect "more superprojects above the asker than the scan follows are unknown" \
  "${chain_bottom}" "${session}" 2 \
  "devantler-tech/demo#3 holder=unknown:lock-scan" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)" "${lsof_nowhere}"
expect "a chain within reach in both directions is still answered" \
  "${chain_mid}" "${session}" 0 \
  "devantler-tech/demo#3 holder=none" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)" "${lsof_nowhere}"

# ── A locked worktree whose path holds a tab (monorepo#3825) ────────────────────────────────────
expect "a live lock on a worktree whose path holds a tab is unknown, never none" \
  "${tabs}" "${session}" 2 \
  "devantler-tech/tabs#81 holder=unknown:lock-reason" \
  "$(pr devantler-tech/tabs 81 worktree-agent-tab)" "${lsof_nowhere}"
expect "nothing can say which PRs that worktree serves, so every PR asked with it is unknown" \
  "${tabs}" "${session}" 2 \
  "devantler-tech/tabs#80 holder=unknown:lock-reason
devantler-tech/demo#3 holder=unknown:lock-reason" \
  "$(jq -sc . <<<"$(pr devantler-tech/tabs 80 claude/plain-80) $(pr devantler-tech/demo 3 claude/nobody-3)")" \
  "${lsof_nowhere}"
g -C "${tabs}" worktree unlock "${tab_wt}"
g -C "${tabs}" worktree lock --reason "claude agent agent-tab (pid 9000003 start ${start_theirs})" "${tab_wt}"
expect "a lock on a tabbed path whose pid now belongs to another process holds nothing" \
  "${tabs}" "${session}" 0 \
  "devantler-tech/tabs#81 holder=none" \
  "$(pr devantler-tech/tabs 81 worktree-agent-tab)" "${lsof_nowhere}"
g -C "${tabs}" worktree unlock "${tab_wt}"
g -C "${tabs}" worktree lock --reason "claude agent agent-tab (pid 9000099 start ${start_theirs})" "${tab_wt}"
expect "a lock on a tabbed path whose process exited holds nothing" \
  "${tabs}" "${session}" 0 \
  "devantler-tech/tabs#81 holder=none
devantler-tech/tabs#80 holder=none" \
  "$(jq -sc . <<<"$(pr devantler-tech/tabs 81 worktree-agent-tab) $(pr devantler-tech/tabs 80 claude/plain-80)")" \
  "${lsof_nowhere}"
g -C "${tabs}" worktree unlock "${tab_wt}"
g -C "${tabs}" worktree lock --reason 'left locked by hand' "${tab_wt}"
expect "a lock on a tabbed path that is not the harness's is unknown, never none" \
  "${tabs}" "${session}" 2 \
  "devantler-tech/tabs#81 holder=unknown:lock-reason" \
  "$(pr devantler-tech/tabs 81 worktree-agent-tab)" "${lsof_nowhere}"

# ── Worktrees nested in a linked worktree (monorepo#3818) ───────────────────────────────────────
expect "a per-session worktree holds the worktree of its own repository nested inside it" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#20 holder=live:1:9000002/claude+self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/demo 20 claude/nested-20)"
expect "asked by the session that owns the outer worktree alone, its nested worktree is self" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#20 holder=self:1:${me}/claude" \
  "$(pr devantler-tech/demo 20 claude/nested-20)" "${lsof_w1_only}"
expect "the asking session's own process working inside the nested worktree is self" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#20 holder=self:2:${me}/claude,9000001/go" \
  "$(pr devantler-tech/demo 20 claude/nested-20)" "${lsof_w1_child}"
expect "asked from a sibling session's worktree, the nested worktree is live" \
  "${w2}" "${session}" 0 \
  "devantler-tech/demo#20 holder=live:2:9000002/claude,9000001/go+self:1:${me}/claude" \
  "$(pr devantler-tech/demo 20 claude/nested-20)"
expect "a worktree nested in a nested one is held too" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#21 holder=self:1:${me}/claude" \
  "$(pr devantler-tech/demo 21 claude/deep-21)" "${lsof_w1_only}"
expect "a nested worktree brings its populated submodule's branch with it" \
  "${w1}" "${session}" 0 \
  "devantler-tech/product#22 holder=self:1:${me}/claude" \
  "$(pr devantler-tech/product 22 claude/product-22)" "${lsof_w1_only}"
expect "a process at the main checkout does not hold the worktrees nested in it, at any depth" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#2 holder=none
devantler-tech/demo#20 holder=none" \
  "$(jq -sc . <<<"$(pr devantler-tech/demo 2 claude/feature-2) $(pr devantler-tech/demo 20 claude/nested-20)")" \
  "${lsof_main_only}"
expect "a live lock holds the worktree nested inside the worktree it locked" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#60 holder=live:1:9000002/claude" \
  "$(pr devantler-tech/hub 60 claude/nested-60)" "${lsof_hub}"
expect "a lock whose process exited does not hold the worktree nested inside it" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#61 holder=none" \
  "$(pr devantler-tech/hub 61 claude/nested-61)" "${lsof_hub}"
expect "a subagent asking from its own locked worktree owns the worktree nested inside it" \
  "${hub_wt}/agent-a9" "${session}" 0 \
  "devantler-tech/hub#62 holder=self:1:${me}/claude" \
  "$(pr devantler-tech/hub 62 claude/nested-62)" "${lsof_hub}"
expect "asked from the session's own worktree, a worktree nested in its subagent's is live" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#62 holder=live:1:${me}/claude" \
  "$(pr devantler-tech/hub 62 claude/nested-62)" "${lsof_hub}"
# The lock scan lists the repository's worktrees first, and that listing succeeds here. The second
# listing is the one of w2's own nested worktrees. The asker sits in w2 as well, so its own tree
# is listed once more: three listings in all.
expect "a worktree the asker's session locked for a subagent stays live when it sits inside the asker's own worktree" \
  "${mine}" "${session}" 0 \
  "devantler-tech/hub#63 holder=live:1:${me}/claude" \
  "$(pr devantler-tech/hub 63 worktree-agent-a13)" "${lsof_hub}"
if [ "${case_blind}" = 1 ]; then
  expect "a nested worktree listed under another letter case is still held" \
    "${w1}" "${session}" 0 \
    "devantler-tech/demo#24 holder=live:1:9000003/node" \
    "$(pr devantler-tech/demo 24 claude/nested-24)" "${lsof_w2_only}"
else
  echo "skip a nested worktree listed under another letter case (this volume keeps case)"
fi
list_fail=1
list_ok=1
expect "a listing of a held worktree's nested worktrees that fails is unknown, never none" \
  "${w2}" "${session}" 2 \
  "devantler-tech/demo#23 holder=unknown:worktree-list" \
  "$(pr devantler-tech/demo 23 claude/nested-23)" "${lsof_w2_only}"
list_ok=3
expect "the same question through the same shim is answered once every listing succeeds" \
  "${w2}" "${session}" 0 \
  "devantler-tech/demo#23 holder=live:1:9000003/node" \
  "$(pr devantler-tech/demo 23 claude/nested-23)" "${lsof_w2_only}"
list_fail=0
list_ok=0

# ── Several PRs at once ─────────────────────────────────────────────────────────────────────────
expect "an array answers every PR in input order" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#3 holder=none
devantler-tech/demo#2 holder=live:3:9000003/node,9000004/sleep,9000014/-bash
devantler-tech/demo#5 holder=fork" \
  "$(jq -sc . <<<"$(pr devantler-tech/demo 3 claude/nobody-3) $(pr devantler-tech/demo 2 claude/feature-2) $(pr devantler-tech/demo 5 x someone)")"
expect "paginated arrays answer every PR in page order" \
  "${w1}" "${session}" 0 \
  "devantler-tech/demo#3 holder=none
devantler-tech/demo#5 holder=fork" \
  "[$(pr devantler-tech/demo 3 claude/nobody-3)]
[$(pr devantler-tech/demo 5 x someone)]"
expect "an empty PR list prints nothing" "${w1}" "${session}" 0 "" '[]'

# ── UNKNOWN is never none ───────────────────────────────────────────────────────────────────────
expect "a partial lsof (output, but a nonzero exit) is unknown, not the holders it printed" \
  "${w1}" "${session}" 2 \
  "devantler-tech/demo#2 holder=unknown:lsof-failed
devantler-tech/demo#5 holder=fork" \
  "$(jq -sc . <<<"$(pr devantler-tech/demo 2 claude/feature-2) $(pr devantler-tech/demo 5 x someone)")" \
  "${lsof_full}" 1
expect "a failed lsof with no output is unknown, never none" \
  "${w1}" "${session}" 2 \
  "devantler-tech/demo#3 holder=unknown:lsof-failed" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)" "${lsof_empty}" 1
expect "an lsof that lists no working directory at all is unknown, never none" \
  "${w1}" "${session}" 2 \
  "devantler-tech/demo#3 holder=unknown:lsof-empty" \
  "$(pr devantler-tech/demo 3 claude/nobody-3)" "${lsof_empty}" 0
expect "a failed process-table read is unknown" \
  "${w1}" "${session}" 2 \
  "devantler-tech/demo#2 holder=unknown:ps-failed" \
  "$(pr devantler-tech/demo 2 claude/feature-2)" "${lsof_full}" 0 1

# ── Unreadable input ────────────────────────────────────────────────────────────────────────────
expect "a PR without a head branch is unknown input" "${w1}" "${session}" 2 \
  "devantler-tech/demo#6 holder=unknown:input" \
  '{"url":"https://github.com/devantler-tech/demo/pull/6","headRepositoryOwner":{"login":"devantler-tech"}}'
expect "a PR without a head owner is unknown input, not a guess at fork or not" "${w1}" "${session}" 2 \
  "devantler-tech/demo#6 holder=unknown:input" \
  '{"url":"https://github.com/devantler-tech/demo/pull/6","headRefName":"claude/feature-2"}'
expect "a same-owner PR without its head repository is unknown input, not keyed to the base" "${w1}" "${session}" 2 \
  "devantler-tech/demo#6 holder=unknown:input" \
  '{"url":"https://github.com/devantler-tech/demo/pull/6","headRefName":"claude/feature-2","headRepositoryOwner":{"login":"devantler-tech"},"headRepository":null}'
expect "a URL that is not a pull request is unknown input" "${w1}" "${session}" 2 \
  "pr[0] holder=unknown:input" \
  '{"url":"https://github.com/devantler-tech/demo/issues/6","headRefName":"x","headRepositoryOwner":{"login":"devantler-tech"}}'
expect "a non-object array element is unknown input; the others are still answered" "${w1}" "${session}" 2 \
  "devantler-tech/demo#3 holder=none
pr[1] holder=unknown:input" \
  "[$(pr devantler-tech/demo 3 claude/nobody-3),\"oops\"]"
expect "stdin that is not JSON is unknown input" "${w1}" "${session}" 2 "? holder=unknown:input" 'not json'
expect "a JSON scalar is unknown input" "${w1}" "${session}" 2 "? holder=unknown:input" '"text"'
expect "empty stdin is unknown input" "${w1}" "${session}" 2 "? holder=unknown:input" ''

# ── Usage ───────────────────────────────────────────────────────────────────────────────────────
checks=$((checks + 1))
usage_rc=0
"${tool}" </dev/null >/dev/null 2>&1 || usage_rc=$?
if [ "${usage_rc}" = 2 ]; then
  echo "ok   no --input - is a usage error (exit 2)"
else
  echo "FAIL no --input - must exit 2, got ${usage_rc}" >&2
  failures=$((failures + 1))
fi

finished=1
if [ "${failures}" -ne 0 ]; then
  echo "pr-worktree-holder.test.sh: ${failures} of ${checks} checks FAILED" >&2
  exit 1
fi
echo "pr-worktree-holder.test.sh: all ${checks} checks passed"
