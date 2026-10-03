#!/usr/bin/env bash
# Reap abandoned per-session worktrees under <repo>/.claude/worktrees/.
#
# Usage: worktree-cleanup.sh <repo_path> <manifest> [dry-run|apply] [min_age_hours] [salvage_age_hours]
#   dry-run (default) — report what WOULD be reaped; write NOTHING to the manifest
#   apply             — record each removal to the manifest, then remove
#   Any other MODE value exits non-zero: a typo must not silently mean "delete", and
#   must not pollute the restore ledger (same contract as branch-cleanup.sh).
#   min_age_hours (default 24) — never reap a worktree younger than this.
#   salvage_age_hours (default 0 = off) — preserve, then reap, a worktree whose only KEEP
#     reason is abandoned work once it is at least this old (see SALVAGE below).
#   WORKTREE_CLEANUP_WT_ROOT (env, default <repo>/.claude/worktrees) — the absolute path of
#     the worktree root to sweep. Each agent lane owns its own roots and sweeps only those
#     (maintainer direction 2026-09-29, #3676); worktree-cleanup-all.sh --lane passes them.
#     Every rule below applies unchanged to any root. A symlinked root, and a root holding
#     the repository's own checkout, are refused.
#
# WHY THIS EXISTS
#   The harness creates a per-session worktree at <repo>/.claude/worktrees/<slug> and
#   nothing ever removes it. The owning session structurally CANNOT remove it — that
#   directory is the session's own working directory, and sessions frequently end
#   abruptly (crash, timeout, closed window) with no teardown. So cleanup must come
#   from OUTSIDE the session. Left unswept the directories accumulate without bound
#   until the disk fills and new sessions cannot start at all.
#   It also silently disables branch-cleanup.sh: a branch checked out by a worktree is
#   permanently in that script's KEEP set, so every leaked worktree pins its branch too.
#
# SAFETY CONTRACT (fail-closed — every ambiguity resolves to KEEP, every
# infrastructure failure ABORTS before anything is removed):
#   KEEP  - the main worktree, and anything outside the worktree root
#   KEEP  - a worktree that is the CWD of a LIVE process (a running session)
#   KEEP  - a worktree younger than min_age_hours
#   KEEP  - a LOCKED worktree (git locks mean "in use"; we never override)
#   KEEP  - a worktree with an unexpired Agentic Engineer ownership claim
#   KEEP  - a worktree whose ownership mutex is held while a claim is acquired/renewed
#   KEEP  - ANY worktree holding commits not reachable from a remote ref. This one test
#           (`git rev-list <head> --not --remotes`) covers both an unpushed branch and a
#           detached HEAD left on an orphan commit — the only states where removing the
#           directory would destroy the sole copy of real work.
#   KEEP  - a worktree with modified TRACKED files, other than UNSTAGED gitlink drift
#   KEEP  - a worktree with untracked files outside the known tool-noise set
#   KEEP  - a worktree whose modified submodule itself has uncommitted work, or any of whose
#           submodule repositories — drifted or not, checked out or not (#3683) — holds a ref
#           or reflog entry reaching a commit its remote lacks (the removal deletes them all).
#           A commit is on the remote when a remote-tracking ref reaches it, a tag GitHub
#           holds at the same object reaches it, or it is a merged PR's head (or an ancestor
#           of one) in the submodule's own devantler-tech repository (#3674)
#   KEEP  - a worktree locked at removal time, re-checked live (never overridden by
#           --force, and never removed by the rm -rf fallback either)
#   ABORT - a caller-chosen root that is relative, a symlink, or holds the checkout being
#           swept or the main worktree
#   ABORT - on any infrastructure failure (worktree list, lsof — including a partial
#           enumeration that exits nonzero — or a manifest write), and the multi-repo
#           wrapper propagates that abort instead of reporting a successful sweep
#
# Every reaped commit also gets a refs/reaped/<sha> ref, so the manifest's SHA stays
# restorable even if a stale remote-tracking ref is later pruned and gc runs.
#
# SALVAGE (#2831) — only when salvage_age_hours > 0. A worktree whose ONLY remaining KEEP
# reason is abandoned work (unpushed or reflog-only commits, or uncommitted changes) is
# otherwise kept forever, so the sweep never converges and the disk fills. Past the
# salvage age such a worktree is preserved first, then reaped: its work is written to
# local refs in the repository that outlives the worktree, the refs are verified, the
# manifest names them, and only then is the directory removed.
#   refs/salvaged/<id>/head       - the worktree's HEAD commit (covers unpushed commits)
#   refs/salvaged/<id>/index      - a commit of the staged index, parent HEAD
#   refs/salvaged/<id>/worktree   - a commit of the whole working tree (tracked edits,
#                                   deletions and untracked non-ignored files outside the
#                                   top-level .codex/ and .agents/ tool noise), parent HEAD
#   refs/salvaged/<id>/reflog/<sha> - every HEAD-reflog, ORIG_HEAD or FETCH_HEAD commit reachable from no remote
#   refs/salvaged/<id>/commit-editmsg - the COMMIT_EDITMSG bytes, when present (a message a hook rejected)
#   refs/salvaged/<id>/config-worktree - the config.worktree bytes, when present (per-worktree settings)
# Restore: `git worktree add --detach <path> refs/salvaged/<id>/head`, then
# `git -C <path> read-tree refs/salvaged/<id>/index` for the staged index and
# `git -C <path> restore --source=refs/salvaged/<id>/worktree --worktree -- .` for the working
# tree. `restore` does not overlay, so paths the salvaged tree deleted are deleted again.
# The salvaged blobs are the working tree's exact bytes (conversion_blocker checks that), but
# `restore` runs checkout-side conversions (smudge filters, eol=crlf) on the way out; for a
# byte-exact copy of one path read the blob raw: `git cat-file blob refs/salvaged/<id>/worktree:<path>`.
# Every other gate is unchanged, and salvage fails closed to the old KEEP:
#   KEEP  - a salvage candidate holding any repository besides its own (an initialised
#           submodule, or an embedded repository even when ignored): removal deletes it
#   KEEP  - untracked content git would record as an embedded repository (a gitlink
#           only, not the files), or more than SALVAGE_MAX_KB of changed/untracked data
#   KEEP  - any failure to build, write or verify a salvage ref, and any change to the
#           working tree or index between the snapshot and the removal
# Residual window: the last comparison against the snapshot runs under the ownership mutex
# immediately before the removal, and a process whose CWD is inside the worktree keeps it.
# A process writing in from OUTSIDE between that comparison and the removal is not seen;
# no user-space check can close that without a filesystem lock git does not take. Salvage
# only runs on a worktree abandoned for the salvage age, so such a writer is not expected.
# What salvage preserves is content: commits, tag objects, and working-tree and index
# bytes, for single-repository worktrees only.
#
# Submodule gitlink drift (` M applications/ksail`) and stray tool dirs (`?? .codex/`)
# are NOT authored work — they are an artifact of the submodule checkout sitting at a
# different, already-committed commit. They are treated as noise ONLY after the
# submodule itself is confirmed clean and fully pushed.
#
# In apply mode every removal is recorded to the manifest BEFORE the removal, and the
# write is verified — no restore record, no removal. dry-run never touches the manifest.
# Rows are `path -> branch -> sha -> evidence -> outcome`, where outcome is `pending`
# (written before deleting) or `reaped` (appended only once the directory is gone).
#
# READING THE LEDGER — the rule is TOTAL, because the completion write can itself fail
# after a successful removal (disk full, permissions changed mid-run). Outcome alone is
# therefore not sufficient; reconcile it against the path:
#
#   reaped                      -> deleted
#   pending + path EXISTS       -> aborted attempt (nothing was removed)
#   pending + path ABSENT       -> deleted; the completion write failed
#
# The third case exits NON-ZERO so the failure is never silent, and the wrapper
# propagates it. Tooling that keys solely on `reaped` would misread that case as an
# abort and leave a real deletion unaccounted for.
set -uo pipefail
# Every git call names its repository explicitly. An inherited location variable would
# silently redirect those calls (a hook's GIT_INDEX_FILE, say), so the snapshot would
# describe one repository's state while the removal deletes another's.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_NAMESPACE
# The sweep only reads a worktree's index, so it must never rewrite it: `git status`
# otherwise refreshes the index opportunistically, which moves its mtime and would make the
# sweep's own reads look like fresh work to work_age_h (#3642). Optional locks off stops
# exactly that write; required writes (the salvage snapshot's own GIT_INDEX_FILE) are unaffected.
# Porcelain `git diff` against the worktree rewrites the index even so: use diff-index.
export GIT_OPTIONAL_LOCKS=0

REPO_PATH=${1:-}
MANIFEST=${2:-}
MODE=${3:-dry-run}
MIN_AGE_HOURS=${4:-24}
SALVAGE_AGE_HOURS=${5:-0}
# Changed plus untracked bytes above which a tree is kept rather than copied into the
# object store: a stray multi-gigabyte artifact would otherwise become permanent history.
SALVAGE_MAX_KB=${WORKTREE_SALVAGE_MAX_KB:-102400}

die() { printf 'worktree-cleanup: %s\n' "$1" >&2; exit 2; }

# physical_path <dir> — the directory's canonical path, from the kernel (getcwd). bash's
# builtin `pwd -P` resolves symlinks but keeps the letter case it was handed, so on a
# case-insensitive filesystem a worktree git registered as `.Codex/worktrees/x` never equals
# the on-disk `.codex/worktrees/x` it names (the reference host had dozens of Codex
# worktrees spelled that way, #3676). The external pwd reports the on-disk spelling.
physical_path() { (cd "$1" 2>/dev/null && /bin/pwd -P); }
# fold_case — lower-cases stdin, for the comparisons that must err towards a MATCH (a live
# CWD, a lock): two spellings can name one directory, and a missed match there would read as
# "no session" or "not locked". A spurious match only ever keeps a worktree.
fold_case() { tr '[:upper:]' '[:lower:]'; }

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) \
  || die "cannot resolve script directory"
# shellcheck source=worktree-claim-lib.sh
. "$SCRIPT_DIR/worktree-claim-lib.sh" || die "cannot load shared claim protocol"

[ -n "$REPO_PATH" ] || die "usage: worktree-cleanup.sh <repo_path> <manifest> [dry-run|apply] [min_age_hours] [salvage_age_hours]"
[ -n "$MANIFEST" ] || die "usage: worktree-cleanup.sh <repo_path> <manifest> [dry-run|apply] [min_age_hours] [salvage_age_hours]"
[ -d "$REPO_PATH" ] || die "repo_path is not a directory: $REPO_PATH"

case "$MODE" in
  apply|dry-run) ;;
  *) die "invalid MODE '$MODE' (expected 'apply' or 'dry-run')" ;;
esac

case "$MIN_AGE_HOURS" in
  ''|*[!0-9]*) die "min_age_hours must be a non-negative integer, got '$MIN_AGE_HOURS'" ;;
esac
case "$SALVAGE_AGE_HOURS" in
  ''|*[!0-9]*) die "salvage_age_hours must be a non-negative integer, got '$SALVAGE_AGE_HOURS'" ;;
esac
case "$SALVAGE_MAX_KB" in
  ''|*[!0-9]*) die "WORKTREE_SALVAGE_MAX_KB must be a non-negative integer, got '$SALVAGE_MAX_KB'" ;;
esac

TOPLEVEL=$(git -C "$REPO_PATH" rev-parse --show-toplevel 2>/dev/null) \
  || die "not a git repository: $REPO_PATH"
# Resolve through symlinks so the lsof CWD comparison below is apples-to-apples
# (/tmp is a symlink to /private/tmp on macOS; an unresolved prefix would silently
# match nothing and every worktree would read as "no live process").
TOPLEVEL=$(physical_path "$TOPLEVEL") || die "cannot resolve toplevel"
if [ -n "${WORKTREE_CLEANUP_WT_ROOT:-}" ]; then
  WT_ROOT=$WORKTREE_CLEANUP_WT_ROOT
  while [ "${WT_ROOT%/}" != "$WT_ROOT" ]; do WT_ROOT=${WT_ROOT%/}; done
  case "$WT_ROOT" in
    /?*) ;;
    *) die "WORKTREE_CLEANUP_WT_ROOT must be an absolute path other than /, got '$WORKTREE_CLEANUP_WT_ROOT'" ;;
  esac
  # A `.` or `..` component would let the lexical checks below pass on one directory while
  # canonicalisation lands on another (`.codex/../.claude/worktrees`), so it is refused outright.
  case "/$WT_ROOT/" in
    */./* | */../*) die "worktree root must not contain . or .. components, got '$WORKTREE_CLEANUP_WT_ROOT'" ;;
  esac
  # Refused, never followed: the root bounds every removal, so it must be the directory it
  # names (the same rule worktree-cleanup-all.sh applies to a symlinked submodule path).
  if [ -L "$WT_ROOT" ]; then
    die "worktree root is a symlink — refusing to follow it: $WT_ROOT"
  fi
  # The lane directory above it is checked the same way: `.codex` linked to `.claude`, or to
  # another `.codex` elsewhere, would move the sweep outside the root the caller named. Deeper
  # ancestors (/tmp -> /private/tmp) do not choose the lane, so they may resolve.
  if [ -L "${WT_ROOT%/*}" ]; then
    die "worktree root's lane directory is a symlink — refusing to follow it: ${WT_ROOT%/*}"
  fi
  # An absent root is a clean "nothing to sweep"; one that cannot be inspected is not. Find the
  # nearest existing ancestor: it must be a directory this run can read and search.
  if [ ! -e "$WT_ROOT" ]; then
    probe=${WT_ROOT%/*}
    while [ -n "$probe" ] && [ ! -e "$probe" ]; do probe=${probe%/*}; done
    [ -n "$probe" ] || probe=/
    if [ ! -d "$probe" ] || [ ! -r "$probe" ] || [ ! -x "$probe" ]; then
      die "worktree root $WT_ROOT cannot be inspected: $probe is not a readable directory"
    fi
  fi
  # Canonical, like every candidate and registration below (physical_path): /tmp is
  # /private/tmp on macOS, and the caller may spell the directory in another case.
  if [ -e "$WT_ROOT" ]; then
    WT_ROOT=$(physical_path "$WT_ROOT") \
      || die "cannot resolve worktree root $WORKTREE_CLEANUP_WT_ROOT"
  fi
else
  WT_ROOT="$TOPLEVEL/.claude/worktrees"
fi
# The fixed default root can never hold the checkout being swept from; a caller-chosen one
# could, and every git call below runs through that checkout.
case "$TOPLEVEL/" in
  "$WT_ROOT"/*) die "worktree root $WT_ROOT holds the checkout being swept ($TOPLEVEL) — refusing" ;;
esac

# --- squash-merge evidence (#2678) ---------------------------------------------------
# The portfolio squash-merges and deletes the merged branch, so a merged branch's own
# commits are never ancestors of main and, once the remote branch is pruned, sit on no
# remote ref at all. The graph test alone therefore keeps every such worktree forever.
# The commit graph cannot answer "is this merged"; only PR state can (the same rule
# branch-cleanup.sh follows). A branch counts as spent only when GitHub records a
# MERGED or CLOSED PR for it whose head is exactly this worktree's HEAD, and no PR for
# it is still OPEN. GitHub keeps that head under refs/pull/<n>/head, and this script
# writes refs/reaped/<sha> before any removal, so the commits stay recoverable.
#
# The repository is derived from origin and must be devantler-tech on github.com;
# anything else yields no evidence (KEEP) without a query.
# portfolio_repo <origin-url> -> prints devantler-tech/<name>, or nothing for any other URL.
portfolio_repo() {
  local url=$1 name=""
  case "$url" in
    https://github.com/devantler-tech/*)       name=${url#https://github.com/devantler-tech/} ;;
    git@github.com:devantler-tech/*)           name=${url#git@github.com:devantler-tech/} ;;
    ssh://git@github.com/devantler-tech/*)     name=${url#ssh://git@github.com/devantler-tech/} ;;
  esac
  name=${name%.git}
  case "$name" in
    ''|*[!A-Za-z0-9._-]*) ;;
    *) printf 'devantler-tech/%s\n' "$name" ;;
  esac
}
origin_url=$(git -C "$TOPLEVEL" remote get-url origin 2>/dev/null || true)
GH_REPO=$(portfolio_repo "$origin_url")

# The scheduled sweep runs under launchd, whose default PATH (/usr/bin:/bin:/usr/sbin:/sbin)
# holds no Homebrew directory. Without this fallback every query would fail and the
# evidence gate would silently keep everything, exactly as before the fix.
GH_BIN=$(command -v gh 2>/dev/null || true)
if [ -z "$GH_BIN" ]; then
  for gh_candidate in /opt/homebrew/bin/gh /usr/local/bin/gh; do
    if [ -x "$gh_candidate" ]; then GH_BIN=$gh_candidate; break; fi
  done
fi

# A stalled API call must not stall the sweep: launchd starts no second copy while one
# runs, so a hung query would block every later sweep. It gets a wall-clock deadline, and a
# query that outlives it fails like any other failed query, so the worktree is KEPT.
GH_DEADLINE_S=${WORKTREE_CLEANUP_GH_DEADLINE:-60}
case "$GH_DEADLINE_S" in ''|*[!0-9]*|0) GH_DEADLINE_S=60 ;; esac

# gh_bounded <gh args...> — gh with a deadline; prints its stdout, returns its status or 124.
gh_bounded() {
  local tmp pid rc ticks=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/worktree-cleanup-gh.XXXXXX") || return 2
  "$GH_BIN" "$@" >"$tmp" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((GH_DEADLINE_S * 5)) ]; then
      kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$tmp"
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid"
  rc=$?
  cat "$tmp"
  rm -f "$tmp"
  return "$rc"
}

# still_the_reviewed_worktree <wt> <branch> <sha> <merged_head> — re-read under the mutex.
# Nothing locks the branch, HEAD or the remote PR: a checkout can move the worktree to
# another branch at the same SHA, and a PR can reopen after the first query. Returns 0
# only when every fact the removal decision rested on still holds; otherwise sets
# IDENTITY_NOTE and returns 1.
IDENTITY_NOTE=""
still_the_reviewed_worktree() {
  local wt=$1 branch=$2 sha=$3 merged=$4 now branch_now
  IDENTITY_NOTE=""
  now=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { IDENTITY_NOTE="cannot re-read HEAD before removal"; return 1; }
  if [ "$now" != "$sha" ]; then IDENTITY_NOTE="HEAD moved during the sweep ($sha -> $now)"; return 1; fi
  branch_now=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached)")
  if [ "$branch_now" != "$branch" ]; then IDENTITY_NOTE="branch changed during the sweep ($branch -> $branch_now)"; return 1; fi
  if [ -n "$merged" ]; then
    pr_proves_spent "$branch" "$sha"
    case $? in
      0) ;;
      2) IDENTITY_NOTE="PR evidence could not be re-verified before removal ($PR_EVIDENCE_NOTE)"; return 1 ;;
      *) IDENTITY_NOTE="PR evidence no longer holds before removal (open PR or head moved)"; return 1 ;;
    esac
  fi
  return 0
}

# pr_proves_spent <branch> <sha> — exit 0 only on positive evidence; 1 when there is
# none; 2 when the query failed (PR_EVIDENCE_NOTE says why). Never reaps on doubt.
PR_EVIDENCE_NOTE=""
pr_proves_spent() {
  local branch=$1 sha=$2 open rows rc state head proven=1
  PR_EVIDENCE_NOTE=""
  [ -n "$GH_REPO" ] || return 1
  if [ -z "$GH_BIN" ]; then PR_EVIDENCE_NOTE="PR evidence unavailable: gh not found"; return 2; fi
  case "$branch" in ''|'(detached)') return 1 ;; esac
  # OPEN is asked on its own: the history query below is capped, so an OPEN pull request
  # older than its last 100 rows would be missed there while a MERGED row proved the head.
  open=$(gh_bounded pr list --repo "$GH_REPO" --state open --head "$branch" --limit 1 \
         --json number --jq length)
  rc=$?
  if [ "$rc" -ne 0 ] || ! [[ "$open" =~ ^[0-9]+$ ]]; then
    PR_EVIDENCE_NOTE="PR evidence unavailable"
    [ "$rc" -eq 124 ] && PR_EVIDENCE_NOTE="PR evidence unavailable: query exceeded ${GH_DEADLINE_S}s"
    return 2
  fi
  [ "$open" -eq 0 ] || return 1
  rows=$(gh_bounded pr list --repo "$GH_REPO" --state all --head "$branch" --limit 100 \
         --json state,headRefOid --jq '.[] | "\(.state)\t\(.headRefOid)"')
  rc=$?
  if [ "$rc" -ne 0 ]; then
    PR_EVIDENCE_NOTE="PR evidence unavailable"
    [ "$rc" -eq 124 ] && PR_EVIDENCE_NOTE="PR evidence unavailable: query exceeded ${GH_DEADLINE_S}s"
    return 2
  fi
  while IFS=$'\t' read -r state head; do
    [ -n "$state" ] || continue
    case "$state" in
      OPEN) return 1 ;;
      MERGED|CLOSED) [ "$head" = "$sha" ] && proven=0 ;;
    esac
  done <<< "$rows"
  return "$proven"
}

# module_git <git-dir> <args...> — git on exactly that submodule repository. Never `git -C`:
# when the directory is not a readable repository, discovery walks up and answers for the
# worktree's admin directory instead, so a broken submodule repository would read as clean.
# The work tree is pinned too, because a submodule repository's core.worktree names its
# checkout, and git refuses to run at all once that checkout is gone (deinitialised).
module_git() { local g=$1; shift; git --git-dir="$g" --work-tree="$g" "$@"; }

# submodule_head_spent <submodule-git-dir> <sha> — exit 0 only when GitHub records a MERGED
# pull request in the submodule's own devantler-tech repository whose head commit is exactly
# <sha>, and no OPEN one with that head (#3674). A submodule's squash-merged commit sits on
# no remote-tracking ref once its branch is deleted, so the graph test alone kept every such
# worktree forever (10 of 13 submodule-unpushed KEEPs on 2026-09-29). The lookup is by
# commit, not branch, because a submodule checkout is usually detached. GitHub keeps the head
# under refs/pull/<n>/head, so the commit stays recoverable after the worktree goes.
# Exit 1 when there is no such evidence (a non-portfolio remote, a malformed SHA, an open or
# closed-unmerged PR), and 2 when it could not be read (gh missing, a failed or timed-out
# query): the same three states as pr_proves_spent, so a transient failure is never
# reported as abandoned work. Either way the caller keeps the worktree.
# The lookup relies on GitHub returning a squash-merged PR for its own head commit, which is
# not on the default branch. That is observed behaviour (checked 2026-09-29 against three
# squash-merged heads), not documented behaviour; if it ever stops, rows come back without
# the merged PR and the worktree is kept, never reaped.
submodule_head_spent() {
  local sub=$1 sha=$2 repo rows state merged_at head proven=1
  [ -n "$GH_BIN" ] || return 2
  case "$sha" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#sha}" -eq 40 ] || return 1
  repo=$(portfolio_repo "$(module_git "$sub" remote get-url origin 2>/dev/null || true)")
  [ -n "$repo" ] || return 1
  # merged_at is null on an open or closed-unmerged PR. It is printed as `-`, never as an
  # empty field: tab is IFS whitespace, so `read` would collapse the empty field and shift
  # the head SHA into merged_at, and an OPEN PR's veto would be silently skipped.
  local query_rc
  rows=$(gh_bounded api --paginate "repos/$repo/commits/$sha/pulls" \
         --jq '.[] | "\(.state)\t\(.merged_at // "-")\t\(.head.sha)"'); query_rc=$?
  if [ "$query_rc" -ne 0 ]; then
    # GitHub answers a commit it has never received with HTTP 422 "No commit found for SHA",
    # and gh prints that error body on stdout. That is definitive, not transient: the commit
    # was never pushed, so it is unpushed work (observed on the host 2026-09-29). Any other
    # failure, a timeout included, stays UNKNOWN.
    case "$rows" in *"No commit found for SHA: $sha\""*) return 1 ;; esac
    return 2
  fi
  while IFS=$'\t' read -r state merged_at head; do
    [ -n "$state" ] || continue
    [ "$head" = "$sha" ] || continue
    case "$state" in
      open) return 1 ;;
      closed) [ "$merged_at" != "-" ] && proven=0 ;;
    esac
  done <<< "$rows"
  return "$proven"
}

# submodule_repository_disposable <git-dir> — exit 0 when a submodule repository holds nothing
# its remote lacks; 1 when it holds local-only work (SUBMODULE_LOCAL_ONLY names one such
# commit, SUBMODULE_TIP_NOTE says when the tip limit stopped the search); 2 when that could not
# be determined.
# A linked worktree's submodule repository lives in the worktree's admin directory, so the
# removal deletes all of it, not just the checked-out HEAD. A local branch, tag or stash, or a
# commit reset away that only a reflog still names, would be lost with it (#3674 review). So
# every commit any ref or reflog entry reaches must be on the remote: reachable from a
# remote-tracking ref or from a tag GitHub holds at the same object (remote_backed_tags), or
# be the head of a merged PR, with its ancestors. That evidence is asked for tip by tip, newest
# first, because a run that worked inside a submodule leaves each merged branch's commits in
# the reflog after the branch is gone; at most SUBMODULE_TIP_LIMIT tips are asked about.
SUBMODULE_LOCAL_ONLY=""
SUBMODULE_TIP_NOTE=""
SUBMODULE_TIP_LIMIT=20
submodule_repository_disposable() {
  local g=$1 tip rc asked=0 exclude
  SUBMODULE_LOCAL_ONLY=""; SUBMODULE_TIP_NOTE=""
  # The common case asks nothing: no ref or reflog entry reaches past the remote-tracking refs.
  tip=$(module_git "$g" rev-list --max-count=1 --all --reflog --not --remotes 2>/dev/null) || return 2
  [ -n "$tip" ] || return 0
  remote_backed_tags "$g" || return 2
  exclude=$BACKED_TAGS
  while :; do
    # --topo-order prints no commit before its descendants, so each one asked about is a tip
    # whose evidence, if any, also covers the older local-only commits beneath it.
    # shellcheck disable=SC2086  # exclude is a space-separated list of refs and shas
    tip=$(module_git "$g" rev-list --topo-order --max-count=1 --all --reflog --not --remotes $exclude \
          2>/dev/null) || return 2
    [ -n "$tip" ] || return 0
    SUBMODULE_LOCAL_ONLY=$tip
    asked=$((asked + 1))
    if [ "$asked" -gt "$SUBMODULE_TIP_LIMIT" ]; then
      SUBMODULE_TIP_NOTE="; more than $SUBMODULE_TIP_LIMIT local-only tips, the rest not asked about"
      return 1
    fi
    submodule_head_spent "$g" "$tip"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    exclude="$exclude $tip"
  done
}

# remote_backed_tags <repo> -> sets BACKED_TAGS to every tag (refs/tags/<name>) whose commit no
# remote-tracking ref reaches but that the submodule's GitHub repository holds at exactly the
# same object. A clone fetches every tag, and a release tag on a commit no branch still
# reaches is on the remote, not local work: every ksail clone carries five (measured on the
# host 2026-10-02), which would otherwise keep every worktree that populated it forever. A tag
# GitHub lacks or holds elsewhere, and any tag outside the portfolio, stays unbacked, so its
# commits still need other evidence. Returns 2 when the tags or GitHub could not be read.
# Sets a global rather than printing: remote_has_tag's cache must outlive the call.
BACKED_TAGS=""
remote_backed_tags() {
  local g=$1 rows commits lo repo obj ref rc
  BACKED_TAGS=""
  # `:` cannot occur in a ref name; %(*objectname) is empty for a lightweight tag.
  rows=$(module_git "$g" for-each-ref --format='%(objectname):%(*objectname):%(refname)' refs/tags \
         2>/dev/null) || return 2
  [ -n "$rows" ] || return 0
  commits=$(awk -F: '{ print ($2 != "" ? $2 : $1) }' <<< "$rows" | sort -u) || return 2
  # shellcheck disable=SC2086  # one object id per word
  lo=$(module_git "$g" rev-list --no-walk $commits --not --remotes 2>/dev/null) || return 2
  [ -n "$lo" ] || return 0
  repo=$(portfolio_repo "$(module_git "$g" remote get-url origin 2>/dev/null || true)")
  [ -n "$repo" ] || return 0
  # Only the tags on a local-only commit are asked about (five of ksail's 1451).
  rows=$(LO="$lo" awk -F: 'BEGIN { n = split(ENVIRON["LO"], a, "\n"); for (i = 1; i <= n; i++) s[a[i]] = 1 }
                           s[($2 != "" ? $2 : $1)]' <<< "$rows") || return 2
  while IFS=: read -r obj _ ref; do
    [ -n "$ref" ] || continue
    remote_has_tag "$repo" "$ref" "$obj"; rc=$?
    case "$rc" in
      0) BACKED_TAGS="$BACKED_TAGS $ref" ;;
      1) ;;
      *) return 2 ;;
    esac
  done <<< "$rows"
  return 0
}

# remote_has_tag <owner/repo> <refs/tags/name> <object> — exit 0 when GitHub holds that tag at
# exactly <object> (a tag object for an annotated tag, as for-each-ref reports it); 1 when it
# does not, or the name holds a character that cannot be put in the request path as is; 2 when
# the query failed. Definitive answers are kept for the run: every worktree that populated a
# submodule carries the same tags, and asking once per worktree would cost hundreds of calls.
TAG_ANSWERS=$'\n'
remote_has_tag() {
  local repo=$1 ref=$2 obj=$3 name out rc key="$1 $2 $3"
  case "$TAG_ANSWERS" in
    *$'\n'"$key 0"$'\n'*) return 0 ;;
    *$'\n'"$key 1"$'\n'*) return 1 ;;
  esac
  [ -n "$GH_BIN" ] || return 2
  name=${ref#refs/tags/}
  case "$name" in ''|*[!A-Za-z0-9._/+-]*) return 1 ;; esac
  out=$(gh_bounded api "repos/$repo/git/ref/tags/$name" --jq '.object.sha'); rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$out" = "$obj" ]; then rc=0; else rc=1; fi
  else
    # A tag GitHub has never had is a definitive 404, whose error body gh prints on stdout.
    case "$out" in *'"status":"404"'*) rc=1 ;; *) return 2 ;; esac
  fi
  TAG_ANSWERS="$TAG_ANSWERS$key $rc"$'\n'
  return "$rc"
}

# submodule_repositories <worktree> <admin> <worktree-realpath> -> prints the git directory of
# every submodule repository the removal deletes, one per line (#3683): every repository under
# the admin directory's modules/, whether its checkout drifted, sits exactly on its gitlink, or
# is gone (deinitialised), nested submodules' included; and every populated submodule's whose
# git directory sits inside the working tree (a clone `git submodule add` adopted in place).
# A repository is a HEAD entry beside an objects entry, the layout nested_repository_blocker
# recognises; the HEAD files under a repository's logs/ and refs/ have no objects beside them.
# A symlinked modules/ is not followed (the removal deletes the link, not what it names), nor
# is a repository elsewhere listed: both outlive the removal. Non-zero when the set cannot be
# read in full, including a path holding a newline.
submodule_repositories() {
  local wt=$1 admin=$2 wt_real=$3 heads h d gitdirs g g_real
  if [ -d "$admin/modules" ] && [ ! -L "$admin/modules" ]; then
    heads=$(find "$admin/modules" -name HEAD -print0 2>/dev/null | tr '\0\n' '\n\001') || return 1
    case "$heads" in *$'\001'*) return 1 ;; esac
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      d=${h%/HEAD}
      if [ -e "$d/objects" ] || [ -L "$d/objects" ]; then printf '%s\n' "$d"; fi
    done <<< "$heads"
  elif [ -e "$admin/modules" ] && [ ! -L "$admin/modules" ]; then
    return 1
  fi
  gitdirs=$(git -C "$wt" submodule foreach --quiet --recursive 'git rev-parse --absolute-git-dir' \
            2>/dev/null) || return 1
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    g_real=$(physical_path "$g") || return 1
    case "$g_real/" in "$wt_real"/*) printf '%s\n' "$g_real" ;; esac
  done <<< "$gitdirs"
  return 0
}

# submodule_repositories_disposable <worktree> <worktree-realpath> — exit 0 when no submodule
# repository the removal deletes holds work its remote lacks; 1 when one does; 2 when that could
# not be determined. SUBMODULE_NOTE names the repository, and the commit or the reason.
SUBMODULE_NOTE=""
submodule_repositories_disposable() {
  local wt=$1 wt_real=$2 admin repos g label rc
  SUBMODULE_NOTE=""
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] \
    || { SUBMODULE_NOTE="cannot locate the admin directory"; return 2; }
  repos=$(submodule_repositories "$wt" "$admin" "$wt_real") \
    || { SUBMODULE_NOTE="cannot list the submodule repositories"; return 2; }
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    label=${g#"$admin"/}; label=${label#"$wt_real"/}
    submodule_repository_disposable "$g"; rc=$?
    case "$rc" in
      0) ;;
      1) SUBMODULE_NOTE="$label at ${SUBMODULE_LOCAL_ONLY:0:12}$SUBMODULE_TIP_NOTE"; return 1 ;;
      *) SUBMODULE_NOTE="$label${SUBMODULE_LOCAL_ONLY:+ at ${SUBMODULE_LOCAL_ONLY:0:12}}"; return 2 ;;
    esac
  done <<< "$repos"
  return 0
}

if [ ! -d "$WT_ROOT" ]; then
  # Nothing to sweep, and nothing to unregister: a run removes the registrations of the
  # worktrees it reaped itself, and no others (#3716). This used to run a repository-wide
  # `git worktree prune`, which cannot be limited to one root. It also dropped another
  # lane's registration whose directory was only briefly unavailable, and that worktree
  # came back with a broken link to its repository. `git gc` still expires a registration
  # whose directory stays gone (gc.worktreePruneExpire).
  printf 'worktree-cleanup: no worktree root at %s — nothing to sweep\n' "$WT_ROOT"
  exit 0
fi

# --- infrastructure: the live-process CWD set -------------------------------------
# A failure here must ABORT, never yield an empty set: an empty set would read as
# "no session is live" and reap every worktree currently in use.
# lsof's own exit status is checked SEPARATELY from the filtering pipeline. A partial
# enumeration (permission/scan failure) can still print plenty of CWDs while exiting
# nonzero; treating that truncated list as complete would silently drop a live session
# and reap it. Non-empty is NOT the same as complete.
LIVE_RAW=$(lsof -a -d cwd -F n 2>/dev/null); lsof_rc=$?
if [ "$lsof_rc" -ne 0 ]; then
  die "lsof exited $lsof_rc — refusing to run on a possibly partial CWD list"
fi
# Case-folded: lsof reports whatever spelling a process reached its directory by.
LIVE_CWDS=$(printf '%s\n' "$LIVE_RAW" | grep '^n' | sed 's/^n//' | fold_case | sort -u)
if [ -z "$LIVE_CWDS" ]; then
  die "lsof returned no CWDs at all — refusing to run (cannot prove which worktrees are live)"
fi

# --- infrastructure: the registered-worktree list ----------------------------------
WT_LIST=$(git -C "$TOPLEVEL" worktree list --porcelain 2>/dev/null) \
  || die "cannot list worktrees for $TOPLEVEL"
[ -n "$WT_LIST" ] || die "empty worktree list for $TOPLEVEL"

# The set of paths git actually knows as worktrees, symlink-resolved. ONLY these are
# ever candidates. Without this filter any ordinary directory placed under
# .claude/worktrees/ enters the loop; having no .git file, every `git -C "$dir"` call
# walks up to the main checkout, whose clean+pushed state then makes the directory look
# eligible — and the rm -rf fallback deletes its arbitrary contents.
REGISTERED=$(printf '%s\n' "$WT_LIST" | awk '/^worktree /{print substr($0,10)}' \
  | while IFS= read -r p; do physical_path "$p"; done)

# The repository's main worktree (git always lists it first) is never a candidate either. It
# is registered, so under a caller-chosen root that held it every gate could pass, and
# `git worktree remove` refuses a main worktree, which would leave only the rm -rf fallback.
MAIN_WT=$(awk '/^worktree /{print substr($0,10); exit}' <<< "$WT_LIST")
[ -n "$MAIN_WT" ] || die "cannot identify the main worktree of $TOPLEVEL"
MAIN_WT_REAL=$(physical_path "$MAIN_WT") || MAIN_WT_REAL=$MAIN_WT
case "$MAIN_WT_REAL/" in
  "$WT_ROOT"/*) die "worktree root $WT_ROOT holds the main worktree ($MAIN_WT_REAL) — refusing" ;;
esac

now=$(date +%s)
reaped=0; kept=0; stuck=0; salvaged=0; freed_kb=0; unmeasured=0

# record <path> <branch> <sha> <evidence> <outcome>
# The outcome column is what stops a row claiming a removal that never happened. The
# durability rule requires writing BEFORE deleting, but four gates can still abort
# after that point (containment, the lock and live re-checks, the restore-ref write),
# so a row alone cannot mean "reaped". `pending` is written first; a second `reaped`
# row is appended only after the directory is actually gone. Restore tooling keys on
# `reaped`; a `pending` with no matching `reaped` is an aborted attempt, not a deletion.
record() { # path branch sha evidence outcome
  local line
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5")
  printf '%s\n' "$line" >> "$MANIFEST" || return 1
  # Verify the WHOLE record landed, not just the path: a path substring is already
  # present whenever the same worktree was reaped in an earlier sweep, so a
  # path-only check would confirm a write that never happened.
  grep -qxF -- "$line" "$MANIFEST" || return 1
  return 0
}

# Label a candidate by its path RELATIVE to WT_ROOT, not its basename: nested worktrees
# (<session>/.claude/worktrees/<name>) are swept too, and two of them under different parents
# share a basename, so a basename-only label cannot say which one a line is about. Identical
# to the basename for a direct child, which is every pre-existing case.
wt_label() { local l=${1#"$WT_ROOT"/}; printf '%s' "${l:-$(basename "$1")}"; }
keep() { kept=$((kept+1)); printf 'KEEP   %-52s %s\n' "$(wt_label "$1")" "$2"; }
# keep_stuck: a KEEP this sweep can never turn into a REAP by itself (#2831). It is used only
# past every transient gate (claim, live process, lock, age), for a tree that holds its only
# copy of some work: unpushed or reflog-only commits, or uncommitted changes. Nothing clears
# those except a person or agent salvaging the work, so they are counted separately;
# otherwise `kept` mixes them with trees that will age out and a growing pile of abandoned
# work reads as "nothing to do". A keep that a later sweep may still resolve (PR evidence
# unavailable) or that may hold no work at all (index flags on a clean file) is not stuck.
keep_stuck() { stuck=$((stuck+1)); keep "$1" "$2"; }

trap 'worktree_claim_lock_release >/dev/null 2>&1 || true' EXIT
trap 'exit 2' HUP INT TERM

# is_locked_now <resolved-worktree-path> — re-queries git rather than consulting a
# startup snapshot, so a lock taken DURING the sweep is still honoured.
#
# FAILS CLOSED: if git cannot be queried, the answer is "locked". This runs immediately
# before `rm -rf`, so "I could not tell" must never resolve to "safe to delete".
#
# Compares the recorded path BOTH raw and symlink-resolved. git prints worktree paths
# as they were recorded at `worktree add` time, while $wt_real is physical_path normalised; if
# the repo was ever reached through a symlinked prefix the two differ and a plain
# comparison would silently miss the lock.
# is_live_now <resolved-worktree-path> — re-enumerates live CWDs instead of trusting
# the startup snapshot. A multi-repo sweep runs for minutes, so a session can start or
# resume inside an eligible worktree after the snapshot was taken; removing its CWD
# out from under it is exactly what the live gate exists to prevent.
# FAILS CLOSED: an lsof failure means "live", never "safe to delete". ~0.7s per call,
# paid only for worktrees that have already passed every other gate.
# Returns 0 = live, 1 = idle, 2 = COULD NOT DETERMINE. The third state matters: folding
# it into "live" made an infrastructure failure indistinguishable from a running session,
# so the run reported KEEP and exited 0 looking healthy while the sweep was blind.
is_live_now() {
  local target=$1 raw rc cwd
  raw=$(lsof -a -d cwd -F n 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$raw" ] || return 2
  # Case-folded on both sides, like the startup snapshot.
  raw=$(printf '%s\n' "$raw" | fold_case) || return 2
  target=$(printf '%s' "$target" | fold_case) || return 2
  while IFS= read -r cwd; do
    case "$cwd" in
      n*) cwd=${cwd#n} ;;
      *) continue ;;
    esac
    [ "$cwd" = "$target" ] && return 0
    [ "${cwd#"$target"/}" != "$cwd" ] && return 0
  done <<< "$raw"
  return 1
}

# Returns 0 = locked, 1 = unlocked, 2 = COULD NOT DETERMINE — the same three-way
# contract as is_live_now, and for the same reason: collapsing "the query failed" into
# "locked" makes an infrastructure failure indistinguishable from a real lock, so the
# run reports KEEP and exits 0 looking healthy while it could not actually check.
is_locked_now() {
  local target=$1 out rc line p resolved
  out=$(git -C "$TOPLEVEL" worktree list --porcelain 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    return 2
  fi
  p=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) p=${line#worktree } ;;
      locked*)
        [ "$p" = "$target" ] && return 0
        resolved=$(physical_path "$p") || resolved=""
        if [ -n "$resolved" ] && [ "$resolved" = "$target" ]; then return 0; fi
        # Two spellings of one directory on a case-insensitive filesystem (`.Codex`/`.codex`).
        if [ "$(printf '%s' "$p" | fold_case)" = "$(printf '%s' "$target" | fold_case)" ]; then
          return 0
        fi
        ;;
    esac
  done <<< "$out"
  return 1
}

# recheck_mutable_gates <worktree> <resolved-path> -> 0 = still safe to remove,
# 1 = KEEP (already reported). Aborts on any unverifiable state.
#
# Every gate here reads state that another process can change WHILE the sweep runs, so
# it must be re-evaluated as late as possible — and, critically, called again before the
# `rm -rf` fallback: the first `worktree remove` attempt can fail slowly, and a session
# may enter the worktree in that window. One function, called at both points, is what
# keeps the two paths from drifting apart.
recheck_mutable_gates() {
  local wt=$1 target=$2 rc st idx
  ownership_claim_state "$wt"; rc=$?
  case "$rc" in
    0) keep "$wt" "active ownership claim ($CLAIM_DETAIL)"; return 1 ;;
    2) keep "$wt" "ambiguous ownership claim ($CLAIM_DETAIL)"; return 1 ;;
  esac

  is_locked_now "$target"; rc=$?
  case "$rc" in
    0) keep "$wt" "locked (acquired during the sweep)"; return 1 ;;
    2) die "cannot query worktree locks for $target — refusing to remove on an unverifiable lock state" ;;
  esac

  is_live_now "$target"; rc=$?
  case "$rc" in
    0) keep "$wt" "live process CWD (started during the sweep)"; return 1 ;;
    2) die "lsof re-check failed for $target — refusing to continue on an unverifiable live set" ;;
  esac

  st=$(porcelain_status "$wt") \
    || { keep "$wt" "cannot re-read or classify status before removal"; return 1; }
  count_real_changes "$wt" "$st"
  if [ -n "$SALVAGE_TREE" ]; then
    # Salvaged: the work may be uncommitted, so compare it with the snapshot instead.
    # Anything written after the snapshot is not in the salvage refs and must not be lost.
    local now_tree now_index
    if [ "$REAL_SUBMODULE_CHANGES" -gt 0 ]; then
      keep "$wt" "submodule work appeared after the salvage snapshot"; return 1
    fi
    snapshot_tree "$wt" || { keep "$wt" "cannot re-snapshot the working tree before removal ($SALVAGE_NOTE)"; return 1; }
    now_tree=$SNAPSHOT_TREE
    now_index=$(git -C "$wt" write-tree 2>/dev/null) || { keep "$wt" "cannot re-read the index before removal"; return 1; }
    if [ "$now_tree" != "$SALVAGE_TREE" ] || [ "$now_index" != "$SALVAGE_INDEX_TREE" ]; then
      keep "$wt" "working tree or index changed after the salvage snapshot ($SALVAGE_REF)"; return 1
    fi
    # A commit made and reset away after the snapshot lives only in this worktree's reflog,
    # which the removal deletes. Every reflog-only commit must already be under the salvage
    # refs; any other means the worktree was touched after the snapshot.
    local now_orphans o
    now_orphans=$(reflog_orphans "$wt") || { keep "$wt" "cannot re-read the reflog before removal"; return 1; }
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$SALVAGE_REF/reflog/$o" 2>/dev/null)" = "$o" ] \
        || { keep "$wt" "a reflog-only commit appeared after the salvage snapshot ($SALVAGE_REF)"; return 1; }
    done <<< "$now_orphans"
    local now_msg
    if ! now_msg=$(admin_file_blobs "$wt") || [ "$now_msg" != "$SALVAGE_ADMIN_BLOBS" ]; then
      keep "$wt" "COMMIT_EDITMSG or config.worktree changed after the salvage snapshot ($SALVAGE_REF)"; return 1
    fi
    if ! admin_backpointer_ok "$wt"; then
      keep "$wt" "the worktree's gitfile no longer names its own admin directory ($SALVAGE_REF)"; return 1
    fi
    # A repository initialised after the snapshot (a submodule, or one the parent ignores),
    # or a file dropped into an uninitialised submodule's directory, changes nothing the
    # checks above compare, and the removal would delete it. The
    # configuration that decides whether status can see an edit (conversion_blocker) can
    # change after the snapshot too, and then every comparison above is blind to the edit.
    if nested_repository_blocker "$wt" || gitlink_blocker "$wt" || worktree_state_blocker "$wt" \
       || conversion_blocker "$wt"; then
      keep "$wt" "$SALVAGE_NOTE, after the salvage snapshot ($SALVAGE_REF)"; return 1
    fi
  elif [ -n "$salvage_reason" ]; then
    # Salvage candidate before its snapshot: its changes are expected and are about to be
    # preserved, but not work in a submodule, which salvage cannot capture.
    if [ "$REAL_SUBMODULE_CHANGES" -gt 0 ]; then
      keep "$wt" "submodule work appeared during the sweep (cannot be salvaged)"; return 1
    fi
    # The salvage age is measured from the newest work, and new work since the initial
    # scan resets it: never salvage-and-remove a worktree someone is using again.
    if ! salvage_eligible "$age_h" "$wt"; then
      keep "$wt" "work changed during the sweep (newer than the salvage age)"; return 1
    fi
  elif [ "$REAL_CHANGES" -gt 0 ]; then
    keep "$wt" "$REAL_CHANGES uncommitted change(s) appeared during the sweep"; return 1
  else
    # A plain reap's submodule repositories, re-read like its status: a commit made in one
    # since the initial scan dies with the removal too (#3683).
    submodule_repositories_disposable "$wt" "$target"
    case $? in
      0) ;;
      1) keep "$wt" "submodule work appeared during the sweep ($SUBMODULE_NOTE)"; return 1 ;;
      *) keep "$wt" "cannot re-read its submodule repositories before removal ($SUBMODULE_NOTE)"; return 1 ;;
    esac
  fi

  # Status alone cannot cover this: not being visible to status is exactly what the
  # assume-unchanged and skip-worktree bits do.
  idx=$(git -C "$wt" ls-files -v 2>/dev/null) \
    || { keep "$wt" "cannot re-read index flags before removal"; return 1; }
  if grep -q '^[a-zS]' <<< "$idx"; then
    keep "$wt" "assume-unchanged/skip-worktree flags appeared during the sweep"; return 1
  fi

  # A submodule-owned worktree created after the initial scan is invisible to every check
  # above when .claude/worktrees/ is ignored, and an abandoned one holds no live CWD. The
  # recursive removal would take its uncommitted files with it (#2588).
  local sub_nested
  if ! sub_nested=$(submodule_owned_worktree "$wt" "$target"); then
    keep "$wt" "cannot re-enumerate submodule-owned worktrees before removal"; return 1
  fi
  if [ -n "$sub_nested" ]; then
    keep "$wt" "a submodule-owned worktree appeared during the sweep (${sub_nested#"$target"/})"; return 1
  fi
  return 0
}

# submodule_owned_worktree <worktree> <worktree-realpath> -> prints the first worktree
# registered to an initialised submodule (recursively) that lies inside <worktree>, other
# than the submodule's own checkout. Prints nothing when there is none. Returns non-zero
# when any submodule or its worktree list cannot be read, so the caller fails closed.
# Top-level for the same bash 3.2 reason as count_real_changes below.
submodule_owned_worktree() {
  local wt=$1 wt_real=$2 subs sub sub_real wts line path path_real
  subs=$(git -C "$wt" submodule foreach --quiet --recursive \
           'printf "%s\n" "$toplevel/$sm_path"' 2>/dev/null) || return 1
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    sub_real=$(physical_path "$sub") || return 1
    wts=$(git -C "$sub" worktree list --porcelain 2>/dev/null) || return 1
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) path=${line#worktree } ;;
        *) continue ;;
      esac
      # A pruned-but-registered path no longer resolves; compare it as written, which is
      # still enough to see that it sits inside the candidate.
      path_real=$(physical_path "$path") || path_real=$path
      [ "$path_real" = "$sub_real" ] && continue
      case "$path_real/" in
        "$wt_real"/*) printf '%s\n' "$path_real"; return 0 ;;
      esac
    done <<< "$wts"
  done <<< "$subs"
  return 0
}

# porcelain_status <worktree> -> prints one porcelain entry per line (`XY path`), with
# every path VERBATIM. The default porcelain output C-quotes a path holding non-ASCII or
# other unusual bytes, and a quoted submodule path then fails the `$wt/$path/.git` test
# in count_real_changes — so its uncommitted files were counted as ordinary work that
# salvage can capture, and deleted with the worktree. `-z` never quotes. The rename and
# copy SOURCE path that `-z` emits as a separate field is dropped, so every line keeps
# the `XY path` shape. Non-zero when status cannot be read
# (pipefail is set) or cannot be split faithfully: a path holding a newline would be cut
# into several records here, so it fails closed instead of being classified by a
# truncated path. NUL becomes the record separator and a real newline becomes \001, so
# either kind of path is detected rather than split.
porcelain_status() {
  local out
  out=$(git -C "$1" status --porcelain -z --untracked-files=all --ignore-submodules=none 2>/dev/null \
        | tr '\0\n' '\n\001') || return 1
  case "$out" in
    *$'\001'*) return 1 ;;
  esac
  printf '%s\n' "$out" \
    | awk 'skip { skip = 0; next } { print } /^([RC].|.[RC]) / { skip = 1 }'
}

# count_real_changes <worktree> <porcelain-status> -> sets $REAL_CHANGES
# Counts porcelain entries that represent AUTHORED work. Submodule gitlink drift and
# known tool-noise dirs are excluded — but a gitlink counts as real work the moment the
# submodule itself is dirty or holds unpushed commits (fail-closed on any doubt).
#
# NOTE: this is a top-level function on purpose. macOS ships bash 3.2, which cannot
# parse a `case` inside a $( ) command substitution ("syntax error near `;;'"), so this
# logic must NOT be inlined into a command substitution.
count_real_changes() {
  local wt=$1 status=$2 line code path sub_status sub_sha sub_unpushed sub_gitdir sub_rc
  REAL_CHANGES=0
  # The subset of REAL_CHANGES held in a submodule. Salvage cannot preserve those: a
  # linked worktree's submodule repository lives in its admin dir and dies with it.
  REAL_SUBMODULE_CHANGES=0
  # The subset of those whose evidence could not be read (a failed GitHub query). A later
  # sweep may prove them spent, so they keep the worktree without marking it stuck.
  SUBMODULE_EVIDENCE_UNKNOWN=0
  [ -n "$status" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    code=${line:0:2}; path=${line:3}
    case "$code" in
      '??')
        case "$path" in
          # Both shapes must be matched: without --untracked-files=all git collapses an
          # untracked directory to `.codex/`, and with it every file is listed
          # individually (`.codex/x`). Matching only the collapsed form silently turned
          # these into "real work" once the flag was added.
          .codex/|.codex/*|.agents/|.agents/*|.DS_Store|*/.DS_Store) ;;
          # NOTE: `.claude/worktrees/` is deliberately NOT in this set. A session
          # worktree can itself contain nested worktrees, and an untracked
          # `?? .claude/worktrees/` is the parent's ONLY signal that they exist —
          # ignoring it let a reap of the parent recursively delete a nested worktree
          # holding the sole copy of uncommitted work.
          *) REAL_CHANGES=$((REAL_CHANGES+1)) ;;
        esac
        ;;
      ' M')
        # ONLY the unstaged form is drift. A STAGED gitlink update (`M ` / `MM`) is
        # deliberate authored intent, and it lives solely in this worktree's own index —
        # removing the worktree destroys it with no commit to recover from. Those fall
        # through to the default branch below and count as real work.
        if [ -e "$wt/$path/.git" ]; then
          # Capture the QUERY's status too: a failed `git status` yields an empty
          # sub_status, which would otherwise read as "submodule is clean" and permit
          # deleting its uncommitted files.
          sub_status=$(git -C "$wt/$path" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)
          sub_status_rc=$?
          sub_sha=$(git -C "$wt/$path" rev-parse HEAD 2>/dev/null)
          sub_unpushed=$(git -C "$wt/$path" rev-list --count "$sub_sha" --not --remotes 2>/dev/null)
          if [ "$sub_status_rc" -ne 0 ] || [ -n "$sub_status" ] || [ -z "$sub_unpushed" ]; then
            REAL_CHANGES=$((REAL_CHANGES+1)); REAL_SUBMODULE_CHANGES=$((REAL_SUBMODULE_CHANGES+1))
          else
            # A clean submodule is disposable only when its repository holds nothing its
            # remote lacks (submodule_repository_disposable). A HEAD no remote-tracking ref
            # reaches still qualifies when it is exactly a merged PR's head (#3674).
            sub_rc=2
            if sub_gitdir=$(git -C "$wt/$path" rev-parse --absolute-git-dir 2>/dev/null) \
               && [ -n "$sub_gitdir" ]; then
              submodule_repository_disposable "$sub_gitdir"; sub_rc=$?
            fi
            case "$sub_rc" in
              0) ;;
              2) REAL_CHANGES=$((REAL_CHANGES+1)); REAL_SUBMODULE_CHANGES=$((REAL_SUBMODULE_CHANGES+1))
                 SUBMODULE_EVIDENCE_UNKNOWN=$((SUBMODULE_EVIDENCE_UNKNOWN+1)) ;;
              *) REAL_CHANGES=$((REAL_CHANGES+1)); REAL_SUBMODULE_CHANGES=$((REAL_SUBMODULE_CHANGES+1)) ;;
            esac
          fi
          # ACCEPTED LIMITATION, stated rather than papered over: this treats the drift as
          # disposable because the submodule commit is reachable from a remote-tracking
          # ref, and that ref can be STALE (upstream deleted or force-pushed).
          # An earlier attempt to mitigate it with a refs/reaped ref inside the submodule
          # was WRONG twice over and is deliberately not reinstated: for a linked
          # worktree the submodule repository lives under
          # .git/worktrees/<id>/modules/..., which `worktree remove` deletes — so the ref
          # died with the thing it was meant to outlive — and because this function also
          # runs in dry-run, it made "report only" mutate the repository.
          # There is no durable place to preserve a linked worktree's submodule object
          # from here, so the exposure is documented instead of hidden behind an
          # ineffective write.
        else
          REAL_CHANGES=$((REAL_CHANGES+1))
        fi
        ;;
      *)
        REAL_CHANGES=$((REAL_CHANGES+1))
        # A staged gitlink update (or any other change on a submodule path) is submodule state.
        [ -e "$wt/$path/.git" ] && REAL_SUBMODULE_CHANGES=$((REAL_SUBMODULE_CHANGES+1))
        ;;
    esac
  done <<< "$status"
  return 0
}

# --- salvage (#2831) ----------------------------------------------------------------
# salvage_pathspec <worktree> -> sets SALVAGE_PATHSPEC: `.` plus excludes that leave
# UNTRACKED top-level tool noise out of salvage (#3641) — the same `.codex/` and `.agents/`
# directories count_real_changes treats as disposable. A runtime cache there is not the
# author's work, and a salvage ref would make it permanent. Tracked paths below them are
# still captured, since they are listed by other means.
# Only a real DIRECTORY gets an exclude, and the `/**` glob matches only its contents: a
# file or symlink named `.codex` is authored work to count_real_changes (its noise patterns
# need the slash), so it is salvaged. A symlink also must not get one, because `git add`
# refuses any pathspec "beyond a symbolic link" and salvage would then always KEEP.
# Never empty, so the expansion is safe under `set -u` on bash 3.2.
salvage_pathspec() {
  local d
  SALVAGE_PATHSPEC=(.)
  for d in .codex .agents; do
    if [ -d "$1/$d" ] && [ ! -L "$1/$d" ]; then
      SALVAGE_PATHSPEC+=(":(exclude,top,glob)$d/**")
    fi
  done
}

# salvage_eligible <age_h> <worktree> — 0 when salvage is on and the worktree is old enough
# for it: both its directory and its newest work (see work_age_h).
salvage_eligible() {
  [ "$SALVAGE_AGE_HOURS" -gt 0 ] && [ "$1" -ge "$SALVAGE_AGE_HOURS" ] || return 1
  local work
  work=$(work_age_h "$2") || return 1
  [ "$work" -ge "$SALVAGE_AGE_HOURS" ]
}

# file_mtime <path> -> seconds since the epoch, GNU form first, BSD second, digits only.
file_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null || true) ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

# file_changed <path> -> the later of the path's mtime and its inode-change time (ctime).
# Metadata-only activity (`chmod +x`, a rename, a hard link) moves ctime but not mtime, and
# `touch` can set an mtime in the past but never a ctime (#3642). Fails when mtime cannot
# be read and when ctime cannot: mtime alone would let a fresh chmod read as old.
file_changed() {
  local m c
  m=$(file_mtime "$1") || return 1
  c=$(stat -c %Z "$1" 2>/dev/null || true)
  case "$c" in ''|*[!0-9]*) c=$(stat -f %c "$1" 2>/dev/null || true) ;; esac
  case "$c" in ''|*[!0-9]*) return 1 ;; esac
  [ "$c" -gt "$m" ] && m=$c
  printf '%s\n' "$m"
}

# work_age_h <worktree> -> whole hours since the newest work salvage would carry: every
# staged, modified or untracked (non-ignored) path, the index, and the HEAD reflog. Editing
# a tracked file does not touch the worktree directory's mtime, so the directory alone can
# make a fresh edit look weeks old. Each path counts by its later of mtime and ctime, so a
# `chmod +x` is work; the index counts so that staging bytes that are already old is work
# too. The sweep never rewrites the index itself (GIT_OPTIONAL_LOCKS=0 above), so its mtime
# moves only with someone's git activity in that worktree (#3642). Non-zero on a read
# failure (the caller then keeps).
work_age_h() {
  local wt=$1 admin list p d m newest=0 unreadable=0
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] || return 1
  list=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-age.XXXXXX") || return 1
  # Plumbing diff-index, never porcelain `git diff`: the porcelain refreshes and rewrites
  # the index whatever GIT_OPTIONAL_LOCKS says, so every sweep would restart the age it is
  # measuring. Without that refresh a stat-only change is listed too, which can only make a
  # tree look newer, never older.
  if ! { git -C "$wt" diff-index -z --name-only HEAD && git -C "$wt" ls-files -z -o --exclude-standard; } \
       > "$list" 2>/dev/null; then
    rm -f "$list"; return 1
  fi
  while IFS= read -r -d '' p; do
    # A deleted path has no mtime; its nearest surviving ancestor changed when it went.
    # The parent alone is not enough: `mv a/old a/new` leaves no `a/old`, and the moved
    # children keep their old times, so only `a` records the rename. A path (or ancestor)
    # that exists but cannot be read is a failure, never an old path.
    d="$wt/$p"
    until [ -e "$d" ] || [ -L "$d" ]; do d=$(dirname "$d"); done
    m=$(file_changed "$d") || { unreadable=1; break; }
    [ "$m" -gt "$newest" ] && newest=$m
  done < "$list"
  rm -f "$list"
  [ "$unreadable" -eq 0 ] || return 1
  for p in "$admin/index" "$admin/logs/HEAD"; do
    [ -e "$p" ] || continue
    m=$(file_changed "$p") || return 1
    [ "$m" -gt "$newest" ] && newest=$m
  done
  [ "$newest" -gt 0 ] || { echo 999999; return 0; }
  echo $(( (now - newest) / 3600 ))
}

# salvage_blocker <worktree> -> 0 and SALVAGE_NOTE set when the tree must NOT be salvaged;
# 1 when nothing blocks it. Read-only, so dry-run reports what apply would actually do.
# An untracked directory listed with a trailing `/` holds its own .git: `git add` would
# record a bare gitlink and none of its files. Any read failure blocks.
salvage_blocker() {
  local wt=$1 list rc f total_kb=0 sz
  SALVAGE_NOTE=""
  if ! admin_backpointer_ok "$wt"; then
    SALVAGE_NOTE="the worktree's gitfile does not name its own admin directory"; return 0
  fi
  nested_repository_blocker "$wt" && return 0
  total_kb=$(admin_files_kb "$wt") || { SALVAGE_NOTE="cannot size the admin directory's files"; return 0; }
  # A conflicted index cannot be written as a tree, so apply would fail at salvage_write
  # and KEEP the worktree. The operation markers are not a reliable witness (conflict
  # entries survive a removed MERGE_HEAD), so ask the index itself, or dry-run would
  # report a SALVAGE that apply can never perform.
  list=$(git -C "$wt" ls-files -u 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then SALVAGE_NOTE="cannot read the index for conflicts"; return 0; fi
  if [ -n "$list" ]; then SALVAGE_NOTE="the index holds unmerged (conflicted) entries"; return 0; fi
  # A resolved conflict keeps its three stages as resolve-undo data, which write-tree drops.
  list=$(git -C "$wt" ls-files --resolve-undo 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then SALVAGE_NOTE="cannot read the index for resolve-undo entries"; return 0; fi
  if [ -n "$list" ]; then SALVAGE_NOTE="the index holds resolve-undo entries (salvage cannot carry them)"; return 0; fi
  # NUL-delimited: the default output C-quotes unusual names, which would hide them from
  # both the embedded-repository test and the size sum. tr keeps NULs out of $( ).
  # Untracked tool noise is sized as the snapshot takes it: not at all (salvage_pathspec).
  salvage_pathspec "$wt"
  list=$( { git -C "$wt" ls-files -z -m \
            && git -C "$wt" ls-files -z -o --exclude-standard -- "${SALVAGE_PATHSPEC[@]}"; } \
          2>/dev/null | tr '\0' '\n'); rc=$?
  if [ "$rc" -ne 0 ]; then SALVAGE_NOTE="cannot list changed files for salvage"; return 0; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */) SALVAGE_NOTE="untracked embedded repository ($f) cannot be salvaged"; return 0 ;;
    esac
    [ -f "$wt/$f" ] || continue          # a deletion or a directory holds no bytes here
    sz=$(wc -c < "$wt/$f" 2>/dev/null) || { SALVAGE_NOTE="cannot size $f for salvage"; return 0; }
    sz=$(printf '%s' "$sz" | tr -d ' ')
    total_kb=$((total_kb + (sz + 1023) / 1024))
    if [ "$total_kb" -gt "$SALVAGE_MAX_KB" ]; then
      SALVAGE_NOTE="more than ${SALVAGE_MAX_KB} KB of changed or untracked data to salvage"
      return 0
    fi
  done <<< "$list"
  # The STAGED index is salvaged too (refs/salvaged/<id>/index), and `ls-files -m -o`
  # sees neither index-versus-HEAD changes nor a staged blob the working tree has since
  # overwritten. Size each changed index blob from the object store instead, so a large
  # staged-only addition cannot slip under the cap and be made permanent by a salvage ref.
  # --raw -z alternates a `:modes shas status` field with its path field.
  list=$(git -C "$wt" diff --cached --raw --no-renames --no-abbrev -z 2>/dev/null | tr '\0' '\n'); rc=$?
  if [ "$rc" -ne 0 ]; then SALVAGE_NOTE="cannot list staged changes for salvage"; return 0; fi
  local meta newmode newsha
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    IFS= read -r f || { SALVAGE_NOTE="cannot parse staged changes for salvage"; return 0; }
    # meta: `:oldmode newmode oldsha newsha status`
    # shellcheck disable=SC2086  # split the space-separated metadata field on purpose
    set -- $meta
    newmode=$2; newsha=$4
    case "$newmode" in 000000|160000) continue ;; esac   # a deletion, or a gitlink (no bytes here)
    sz=$(git -C "$wt" cat-file -s "$newsha" 2>/dev/null) || { SALVAGE_NOTE="cannot size staged $f for salvage"; return 0; }
    total_kb=$((total_kb + (sz + 1023) / 1024))
    if [ "$total_kb" -gt "$SALVAGE_MAX_KB" ]; then
      SALVAGE_NOTE="more than ${SALVAGE_MAX_KB} KB of changed or untracked data to salvage"
      return 0
    fi
  done <<< "$list"
  # The snapshot must record exactly HEAD's gitlinks (snapshot_tree refuses otherwise), so
  # check the same thing read-only here and dry-run cannot promise a salvage apply refuses.
  gitlink_blocker "$wt" && return 0
  worktree_state_blocker "$wt" && return 0
  conversion_blocker "$wt" && return 0
  return 1
}

# nested_repository_blocker <worktree> -> 0, with SALVAGE_NOTE, when the worktree holds any
# repository besides its own: an initialised submodule (whose repository lives under the
# admin directory's modules/) or any other .git entry below its top level, including one the
# parent ignores or one inside a tracked directory. Salvage records only the parent
# repository, and the removal deletes the others with every commit, ref, index and reflog
# they hold, so salvage covers single-repository worktrees only. Found by walking the
# filesystem, never through git's own listing, which is exactly what an ignore rule hides
# from. Any read failure blocks.
nested_repository_blocker() {
  local wt=$1 admin found
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] \
    || { SALVAGE_NOTE="cannot locate the worktree's admin directory"; return 0; }
  if [ -e "$admin/modules" ] || [ -L "$admin/modules" ]; then
    SALVAGE_NOTE="holds submodule repositories (salvage covers single-repository worktrees only)"
    return 0
  fi
  # A .git entry marks a repository with a working tree; a bare repository has none, so it
  # is recognised by its own layout: an objects/ entry beside a HEAD entry. Git resolves an
  # objects/ symlink normally, so a symlink counts as well as a directory, and refs/ is not
  # required: a repository whose empty refs/ was lost still holds packed-refs and objects.
  local objs o
  if ! found=$(find "$wt" -mindepth 2 -name .git -prune -print 2>/dev/null) \
     || ! objs=$(find "$wt" -mindepth 2 -name objects \( -type d -o -type l \) -prune -print 2>/dev/null); then
    SALVAGE_NOTE="cannot search the worktree for nested repositories"; return 0
  fi
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    if [ -e "${o%/objects}/HEAD" ] || [ -L "${o%/objects}/HEAD" ]; then
      found=${found:-${o%/objects}}
    fi
  done <<< "$objs"
  if [ -n "$found" ]; then
    SALVAGE_NOTE="holds a nested repository (${found%%$'\n'*}; salvage covers single-repository worktrees only)"
    return 0
  fi
  return 1
}

# gitlink_blocker <worktree> -> 0, with SALVAGE_NOTE, unless every gitlink in HEAD is still a
# gitlink in the index and a directory in the working tree, and the index has no gitlink HEAD
# lacks. Those are the conditions under which the snapshot keeps HEAD's gitlink set.
gitlink_blocker() {
  local wt=$1 head_links idx_links p
  head_links=$(git -C "$wt" ls-tree -r HEAD 2>/dev/null | awk -F'\t' '$1 ~ /^160000 /{print $2}') \
    || { SALVAGE_NOTE="cannot list HEAD gitlinks"; return 0; }
  idx_links=$(git -C "$wt" ls-files -s 2>/dev/null | awk -F'\t' '$1 ~ /^160000 /{print $2}') \
    || { SALVAGE_NOTE="cannot list staged gitlinks"; return 0; }
  if [ "$head_links" != "$idx_links" ]; then
    SALVAGE_NOTE="a submodule was added, removed or replaced (the snapshot cannot record it)"; return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -L "$wt/$p" ] || [ ! -d "$wt/$p" ]; then
      SALVAGE_NOTE="submodule directory $p was deleted or replaced (the snapshot cannot record it)"; return 0
    fi
    # Only an uninitialised submodule gets this far (nested_repository_blocker keeps an
    # initialised one). Status reports files dropped into its directory as clean, the
    # snapshot records only the gitlink, and the removal would delete them.
    if [ -n "$(ls -A "$wt/$p" 2>/dev/null || echo unreadable)" ]; then
      SALVAGE_NOTE="uninitialised submodule directory $p is not empty (cannot be salvaged)"; return 0
    fi
  done <<< "$head_links"
  return 1
}

# worktree_state_blocker <worktree> -> 0, with SALVAGE_NOTE, when the worktree holds state the
# salvage refs cannot carry: a per-worktree ref (refs/worktree/*, refs/bisect/*, …) lives in
# the admin directory the removal deletes and need not be in HEAD's reflog; an intent-to-add
# entry has no blob, so the staged-index tree silently drops it.
worktree_state_blocker() {
  local wt=$1 admin refs ita entry
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] \
    || { SALVAGE_NOTE="cannot locate the worktree's admin directory"; return 0; }
  # A whitelist over what the removal deletes: every entry of the admin directory must be
  # one salvage either captures or can lose. Anything else — a sequencer, rebase or merge
  # state, a bisect log, a split index — is state the salvage refs cannot carry, so an
  # unlisted entry blocks rather than each operation's markers being enumerated.
  for entry in "$admin"/* "$admin"/.[!.]* "$admin"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "${entry##*/}" in
      HEAD|ORIG_HEAD|FETCH_HEAD|COMMIT_EDITMSG|commondir|gitdir|index|config.worktree|logs|refs|modules)
        entry_type_ok "$entry" || { SALVAGE_NOTE="the worktree's ${entry##*/} is not the kind of entry git writes there"; return 0; } ;;
      *) SALVAGE_NOTE="the worktree's git state holds ${entry##*/} (salvage cannot carry it)"; return 0 ;;
    esac
  done
  if [ -d "$admin/logs" ]; then
    # Only the HEAD reflog is read (worktree_ref_ids) and preserved; any other entry under
    # logs/ would be deleted unread.
    refs=$(find "$admin/logs" -mindepth 1 ! -path "$admin/logs/HEAD" 2>/dev/null) \
      || { SALVAGE_NOTE="cannot list the worktree's reflogs"; return 0; }
    if [ -n "$refs" ]; then
      SALVAGE_NOTE="the worktree's logs/ holds more than the HEAD reflog (salvage cannot carry it)"; return 0
    fi
  fi
  if [ -d "$admin/refs" ]; then
    # The ownership mutex is itself a per-worktree ref; it guards the removal and carries no
    # work, so it is the one ref excluded — and only exactly: the ref worktree-claim-lib
    # derives from this worktree's path, pointing at a blob that is the lock's own two-line
    # pid=/created_at= payload. Any other ref (a sibling hash, a commit, extra data) blocks.
    refs=$(find "$admin/refs" ! -type d 2>/dev/null) \
      || { SALVAGE_NOTE="cannot list per-worktree refs"; return 0; }
    local r name body mutex_ref=""
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      name=${r#"$admin"/}
      case "$name" in
        "$WORKTREE_CLAIM_LOCK_REF_PREFIX"/*) ;;
        *) SALVAGE_NOTE="per-worktree refs exist (salvage cannot carry them)"; return 0 ;;
      esac
      body=""
      if [ -z "$mutex_ref" ]; then
        mutex_ref="$WORKTREE_CLAIM_LOCK_REF_PREFIX/$(printf '%s' "$wt" | git -C "$wt" hash-object --stdin 2>/dev/null)" \
          || mutex_ref="unresolvable"
      fi
      # A regular, non-symlink loose ref only: git would block reading a FIFO.
      if [ "$name" != "$mutex_ref" ] || [ -L "$r" ] || [ ! -f "$r" ] \
         || [ "$(git -C "$wt" cat-file -t "$name" 2>/dev/null)" != blob ] \
         || ! body=$(git -C "$wt" cat-file blob "$name" 2>/dev/null) \
         || ! printf '%s\n' "$body" | awk 'NR == 1 && /^pid=[0-9]+$/ { p = 1; next }
              NR == 2 && /^created_at=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { c = 1; next }
              { bad = 1 } END { exit !(p && c && !bad && NR == 2) }'; then
        SALVAGE_NOTE="per-worktree ref $name is not an ownership mutex (salvage cannot carry it)"; return 0
      fi
    done <<< "$refs"
  fi
  # Read the index flag itself (CE_INTENT_TO_ADD, bit 29 of the --debug flags): a worktree
  # diff calls a deleted intent-to-add path D, not A, yet write-tree still drops it.
  ita=$(git -C "$wt" ls-files --debug 2>/dev/null \
        | awk '/^  size: .*flags: / { f = $NF; if (length(f) == 8 && substr(f, 1, 1) ~ /[2367abef]/) n++ } END { print n + 0 }') \
    || { SALVAGE_NOTE="cannot list intent-to-add entries"; return 0; }
  if [ "$ita" != 0 ]; then
    SALVAGE_NOTE="intent-to-add index entries exist (salvage cannot carry them)"; return 0
  fi
  # The salvage refs keep only commits, so a tag object only ORIG_HEAD or FETCH_HEAD names
  # would lose its only reference with the admin directory. One a ref also holds would not.
  local pseudo_tags
  pseudo_tags=$(pseudo_ref_unreferenced_tags "$wt") || { SALVAGE_NOTE="cannot read the worktree's pseudo-refs"; return 0; }
  if [ -n "$pseudo_tags" ]; then
    SALVAGE_NOTE="ORIG_HEAD or FETCH_HEAD names a tag (salvage cannot carry it)"; return 0
  fi
  return 1
}

# entry_type_ok <path> -> 0 when a whitelisted git-directory entry has the type git gives it:
# the directory-shaped names are real directories, everything else a file (a symlink to a
# file counts, as git reads through it). Anything else is state the checks never inspect.
entry_type_ok() {
  case "${1##*/}" in
    logs|refs|modules|objects|branches) [ -d "$1" ] && [ ! -L "$1" ] ;;
    *) [ -f "$1" ] ;;
  esac
}

# conversion_blocker <worktree> -> 0, with SALVAGE_NOTE, unless `git add` would store every
# present path's exact working-tree bytes and see every change. A whitelist over the bytes,
# not a list of the things that rewrite them: for every tracked, staged or untracked path,
# the object `git add` would write (every filter, ident, encoding, text/eol/crlf attribute
# and core.autocrlf applied) must equal the object of the raw file. A lossy clean filter
# that maps an edit back to the indexed bytes fails this too, although status cannot see it.
conversion_blocker() {
  local wt=$1 paths present filtered raw p
  # With core.fileMode=false an executable-bit change is invisible to `add`. With
  # core.ignoreCase=true on a case-SENSITIVE filesystem a case-only rename reads as a
  # deletion and the renamed file is never added. The admin dir's HEAD, looked up as
  # `head`, tells the filesystem's case sensitivity without writing anything.
  local filemode ignorecase admin
  filemode=$(git -C "$wt" config --bool --get core.fileMode 2>/dev/null) || filemode=""
  if [ "$filemode" = false ]; then
    SALVAGE_NOTE="core.fileMode=false hides mode changes (salvage would not keep them)"; return 0
  fi
  ignorecase=$(git -C "$wt" config --bool --get core.ignoreCase 2>/dev/null) || ignorecase=""
  if [ "$ignorecase" = true ]; then
    admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] \
      || { SALVAGE_NOTE="cannot locate the worktree's admin directory"; return 0; }
    if [ ! -e "$admin/head" ]; then
      SALVAGE_NOTE="core.ignoreCase=true on a case-sensitive filesystem (salvage could lose a case-only rename)"; return 0
    fi
  fi
  salvage_pathspec "$wt"
  paths=$( { git -C "$wt" ls-files -z -c \
             && git -C "$wt" ls-files -z -o --exclude-standard -- "${SALVAGE_PATHSPEC[@]}" \
             && git -C "$wt" diff --cached --name-only -z; } 2>/dev/null | tr '\0\n' '\n\001') \
    || { SALVAGE_NOTE="cannot list the paths for the conversion check"; return 0; }
  case "$paths" in *$'\001'*) SALVAGE_NOTE="a path holds a newline (cannot check its bytes)"; return 0 ;; esac
  # A symlink stores its target unconverted and a deleted path has no bytes left to lose;
  # a directory is a gitlink (a submodule, checked on its own) or a replaced file whose
  # contents `add -A` snapshots path by path; every other present path is hashed.
  # Only a regular file is hashed: a FIFO would block hash-object forever, and a socket or
  # device holds no bytes `add` can store, so any other file type blocks.
  local special=""
  present=$(while IFS= read -r p; do
              [ -n "$p" ] && [ ! -L "$wt/$p" ] && [ -f "$wt/$p" ] && printf '%s\n' "$p"
            done <<< "$paths" | sort -u)
  special=$(while IFS= read -r p; do
              [ -n "$p" ] || continue
              [ -L "$wt/$p" ] || [ -d "$wt/$p" ] || [ -f "$wt/$p" ] || [ ! -e "$wt/$p" ] || printf '%s\n' "$p"
            done <<< "$paths" | head -1)
  if [ -n "$special" ]; then
    SALVAGE_NOTE="$special is a special file (salvage cannot carry it)"; return 0
  fi
  [ -n "$present" ] || return 1
  filtered=$(git -C "$wt" hash-object --stdin-paths <<< "$present" 2>/dev/null) \
    && raw=$(git -C "$wt" hash-object --no-filters --stdin-paths <<< "$present" 2>/dev/null) \
    && [ "$(wc -l <<< "$filtered")" = "$(wc -l <<< "$present")" ] \
    || { SALVAGE_NOTE="cannot hash the working tree for the conversion check"; return 0; }
  if [ "$filtered" != "$raw" ]; then
    SALVAGE_NOTE="a path has a filter or conversion that changes its bytes (salvage would not keep the exact bytes)"; return 0
  fi
  return 1
}

# snapshot_tree <worktree> -> sets SNAPSHOT_TREE to the tree of the WHOLE working tree
# (tracked edits, deletions, untracked non-ignored files except salvage_pathspec noise),
# built in a throwaway index so the
# worktree's own index is never touched. Returns non-zero, with SALVAGE_NOTE, when the
# snapshot would not be faithful: a gitlink that HEAD does not have means git staged an
# embedded repository as a pointer instead of its files. It sets globals rather than
# printing, so a caller never runs it in a $( ) subshell that would discard SALVAGE_NOTE.
#
# Every path HEAD or the worktree's real index tracks is captured, ignored or not: `add -A`
# skips an ignored path the throwaway index does not already hold, so a force-added ignored
# file (in the real index, not in HEAD) and a `rm --cached` one (in HEAD, not in the index)
# would otherwise lose their working-tree bytes with the removal.
snapshot_tree() {
  local wt=$1 idx tree head_links snap_links tracked p
  SALVAGE_NOTE=""; SNAPSHOT_TREE=""
  idx=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-index.XXXXXX") || { SALVAGE_NOTE="cannot create a temporary index"; return 1; }
  tracked=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-paths.XXXXXX") || { rm -f "$idx"; SALVAGE_NOTE="cannot create a temporary path list"; return 1; }
  rm -f "$idx"
  # Untracked tool noise stays out of the snapshot (salvage_pathspec). `add -u` then
  # records edits and deletions of every TRACKED path, the noise directories included.
  salvage_pathspec "$wt"
  if ! GIT_INDEX_FILE=$idx git -C "$wt" read-tree HEAD 2>/dev/null \
     || ! GIT_INDEX_FILE=$idx git -C "$wt" add -A -- "${SALVAGE_PATHSPEC[@]}" 2>/dev/null \
     || ! GIT_INDEX_FILE=$idx git -C "$wt" add -u -- . 2>/dev/null; then
    rm -f "$idx" "$tracked"; SALVAGE_NOTE="cannot stage the working tree for salvage"; return 1
  fi
  # NUL-delimited end to end, and only files or symlinks still present: a deletion is
  # already recorded by `add -A`, and a directory is a gitlink the check below compares.
  if ! { git -C "$wt" ls-tree -r -z --name-only HEAD && git -C "$wt" ls-files -z; } \
         > "$tracked.all" 2>/dev/null; then
    rm -f "$idx" "$tracked" "$tracked.all"; SALVAGE_NOTE="cannot list the tracked paths for salvage"; return 1
  fi
  while IFS= read -r -d '' p; do
    if [ -L "$wt/$p" ] || [ -f "$wt/$p" ]; then
      printf '%s\0' "$p"
    fi
  done < "$tracked.all" > "$tracked"
  rm -f "$tracked.all"
  if [ -s "$tracked" ] \
     && ! GIT_LITERAL_PATHSPECS=1 GIT_INDEX_FILE=$idx git -C "$wt" add -f \
            --pathspec-from-file="$tracked" --pathspec-file-nul 2>/dev/null; then
    rm -f "$idx" "$tracked"; SALVAGE_NOTE="cannot stage the tracked paths for salvage"; return 1
  fi
  rm -f "$tracked"
  head_links=$(git -C "$wt" ls-tree -r HEAD 2>/dev/null | awk -F'\t' '$1 ~ /^160000 /{print $2}') \
    || { rm -f "$idx"; SALVAGE_NOTE="cannot list HEAD gitlinks"; return 1; }
  snap_links=$(GIT_INDEX_FILE=$idx git -C "$wt" ls-files -s 2>/dev/null | awk -F'\t' '$1 ~ /^160000 /{print $2}') \
    || { rm -f "$idx"; SALVAGE_NOTE="cannot list staged gitlinks"; return 1; }
  if [ "$head_links" != "$snap_links" ]; then
    rm -f "$idx"; SALVAGE_NOTE="the snapshot would record an embedded repository as a gitlink"; return 1
  fi
  tree=$(GIT_INDEX_FILE=$idx git -C "$wt" write-tree 2>/dev/null) \
    || { rm -f "$idx"; SALVAGE_NOTE="cannot write the snapshot tree"; return 1; }
  rm -f "$idx"
  SNAPSHOT_TREE=$tree
}

# salvage_commit <worktree> <tree> <parent> <message> -> prints a commit. Local-only
# bookkeeping, so it is never signed and never depends on the user's identity config.
salvage_commit() {
  GIT_AUTHOR_NAME=worktree-cleanup GIT_AUTHOR_EMAIL=worktree-cleanup@localhost \
  GIT_COMMITTER_NAME=worktree-cleanup GIT_COMMITTER_EMAIL=worktree-cleanup@localhost \
    git -C "$1" commit-tree --no-gpg-sign "$2" -p "$3" -m "$4" 2>/dev/null
}

# snapshot_kb <worktree> <head> <index-tree> <worktree-tree> -> prints the KB of the blobs
# the two salvage trees add or change relative to <head>, each distinct blob counted once.
# Non-zero on any read failure or a missing object, so the caller fails closed.
snapshot_kb() {
  local wt=$1 head=$2 shas
  shas=$( { git -C "$wt" diff-tree -r --no-renames --no-abbrev "$head" "$3" \
            && git -C "$wt" diff-tree -r --no-renames --no-abbrev "$head" "$4"; } 2>/dev/null \
          | awk '$2 != "160000" && $4 !~ /^0+$/ { print $4 }' | sort -u) || return 1
  [ -n "$shas" ] || { echo 0; return 0; }
  git -C "$wt" cat-file --batch-check='%(objectsize)' <<< "$shas" 2>/dev/null \
    | awk 'NF != 1 { bad = 1 } { kb += int(($1 + 1023) / 1024) } END { if (bad) exit 1; print kb + 0 }'
}

# reflog_orphans <repo> -> prints every commit only <repo>'s admin directory references (see
# worktree_ref_ids) that no remote-tracking ref reaches, one per line. Non-zero on any read
# failure, so callers fail closed.
reflog_orphans() {
  local ids out
  ids=$(worktree_ref_ids "$1") || return 1
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086  # one sha per word
  out=$(git -C "$1" rev-list --no-walk $ids --not --remotes 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  sort -u <<< "$out"
}

# worktree_ref_ids <repo> -> prints every commit that only <repo>'s admin directory may
# reference: both sides of each HEAD-reflog entry, plus ORIG_HEAD and FETCH_HEAD (a fetched
# ref deleted upstream, a reset-away tip). The admin directory dies with the worktree, so
# each is a commit the removal can orphan. Non-zero on any read failure.
# pseudo_ref_unreferenced_tags <worktree> -> prints each object ORIG_HEAD or FETCH_HEAD names
# that is not a commit and that no ref in the main repository points at (an unreadable type
# counts). Non-zero on a read failure.
pseudo_ref_unreferenced_tags() {
  local gitdir pseudo refd sha
  gitdir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$gitdir" ] || return 1
  pseudo=$(pseudo_ref_commits "$gitdir") || return 1
  [ -n "$pseudo" ] || return 0
  refd=$(git -C "$TOPLEVEL" for-each-ref --format='%(objectname)' 2>/dev/null) || return 1
  for sha in $pseudo; do
    [ "$(git --git-dir="$gitdir" --work-tree="$gitdir" cat-file -t "$sha" 2>/dev/null)" = commit ] \
      && continue
    grep -qxF -- "$sha" <<< "$refd" || printf '%s\n' "$sha"
  done
}

worktree_ref_ids() {
  local gitdir reflog pseudo
  gitdir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$gitdir" ] || return 1
  reflog=$(head_reflog_ids "$1" "$gitdir") || return 1
  pseudo=$(pseudo_ref_commits "$gitdir") || return 1
  printf '%s\n%s\n' "$reflog" "$pseudo" | awk 'NF && !seen[$0]++'
}

# head_reflog_ids <repo> <gitdir> -> prints the object id on EITHER side of every HEAD-reflog
# entry that the object store still holds. `reflog show` prints only the new side, and an
# expired or truncated reflog can keep an entry whose old side is named nowhere else. An id
# the store no longer has is skipped: an expired entry's object has nothing left to lose.
# Non-zero on any read failure or a malformed entry.
head_reflog_ids() {
  local repo=$1 log="$2/logs/HEAD" ids out
  if [ ! -e "$log" ] && [ ! -L "$log" ]; then return 0; fi
  [ -f "$log" ] && [ -r "$log" ] || return 1
  ids=$(awk '{ print tolower($1); print tolower($2) }' "$log") || return 1
  [ -n "$ids" ] || return 0
  if grep -Evq '^([0-9a-f]{40}|[0-9a-f]{64})$' <<< "$ids"; then return 1; fi
  ids=$(grep -Ev '^0+$' <<< "$ids" | awk '!seen[$0]++')
  [ -n "$ids" ] || return 0
  out=$(git -C "$repo" cat-file --batch-check='%(objectname) %(objecttype)' <<< "$ids" 2>/dev/null) \
    || return 1
  # HEAD only ever names commits. Anything else (a tag object, which rev-list would peel and
  # the salvage refs would then drop) is state salvage cannot carry: fail closed.
  awk 'NF != 2 { bad = 1; next } $2 == "missing" { next } $2 != "commit" { bad = 1; next } { print $1 }
       END { if (bad) exit 1 }' <<< "$out"
}

# pseudo_ref_commits <gitdir> -> prints each commit ORIG_HEAD or FETCH_HEAD in <gitdir> names
# that still exists (a missing object has nothing left to lose). Non-zero on a read failure.
pseudo_ref_commits() {
  local g=$1 f sha
  for f in ORIG_HEAD FETCH_HEAD; do
    [ -e "$g/$f" ] || [ -L "$g/$f" ] || continue
    # A regular file only (following a symlink): reading a FIFO would block the sweep.
    [ -f "$g/$f" ] && [ -r "$g/$f" ] || return 1
    while IFS= read -r sha || [ -n "$sha" ]; do
      # A plain `git fetch` records every other remote branch's tip as not-for-merge. Those
      # are not this worktree's work, and a squash-merged, deleted one would otherwise pin
      # it (or be salvaged) forever. Only the entries a merge of FETCH_HEAD acts on count.
      if [ "$f" = FETCH_HEAD ]; then
        case "$sha" in *"	not-for-merge	"*) continue ;; esac
      fi
      sha=$(printf '%s' "${sha%%[[:space:]]*}" | tr 'A-F' 'a-f')
      [ -n "$sha" ] || continue
      # A token that is not an object id means the file cannot be read as expected.
      case "$sha" in *[!0-9a-f]*) return 1 ;; esac
      case ${#sha} in 40|64) ;; *) return 1 ;; esac
      # An object the store no longer holds has nothing left to lose, as in head_reflog_ids.
      local type
      type=$(git --git-dir="$g" --work-tree="$g" cat-file --batch-check='%(objecttype)' \
        <<< "$sha" 2>/dev/null) || return 1
      case "$type" in *missing) continue ;; esac
      # Anything the store does hold must peel to a commit, or salvage cannot carry it.
      git --git-dir="$g" --work-tree="$g" cat-file -e "$sha^{commit}" 2>/dev/null || return 1
      printf '%s\n' "$sha"
    done < "$g/$f"
  done
  return 0
}

# salvage_write <worktree> <sha> -> writes and verifies refs/salvaged/<id>/*, setting
# SALVAGE_REF, SALVAGE_TREE (whole working tree) and SALVAGE_INDEX_TREE (staged index).
# Returns non-zero, with SALVAGE_NOTE, on any failure; refs already written stay (they
# only preserve data) and the caller KEEPs the worktree.
salvage_write() {
  local wt=$1 sha=$2 id base idx_tree wt_tree idx_commit wt_commit orphans o path_id
  SALVAGE_REF=""; SALVAGE_TREE=""; SALVAGE_INDEX_TREE=""; SALVAGE_ADMIN_BLOBS=""
  # The namespace must be unique per WORKTREE, not per basename: two registered nested
  # worktrees can share a basename and a HEAD, and salvaged in the same second they would
  # otherwise derive one namespace and the second would overwrite the first's refs —
  # leaving its uncommitted work unreferenced after both are reaped. A digest of the full
  # path separates them, and every ref below is created with an empty old value, so a
  # collision that still happens fails (and KEEPs the worktree) instead of overwriting.
  path_id=$(printf '%s' "$wt" | git hash-object --stdin 2>/dev/null) && [ -n "$path_id" ] \
    || { SALVAGE_NOTE="cannot derive a salvage namespace for $wt"; return 1; }
  # Only ref-safe characters from the basename, so the namespace is always valid and dry-run
  # never promises a salvage apply would refuse; the path digest keeps it unique.
  local bn
  bn=$(printf '%s' "$(basename "$wt")" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)
  id="$(date -u +%Y%m%dT%H%M%SZ)-${bn}-${path_id:0:12}-${sha:0:12}"
  base="refs/salvaged/$id"
  git check-ref-format "$base/head" 2>/dev/null || { SALVAGE_NOTE="unusable salvage ref name $base"; return 1; }
  idx_tree=$(git -C "$wt" write-tree 2>/dev/null) || { SALVAGE_NOTE="cannot write the staged index as a tree"; return 1; }
  snapshot_tree "$wt" || return 1
  wt_tree=$SNAPSHOT_TREE
  # The cap is enforced on what is actually captured, not only on the earlier listing: a
  # file written between that check and this snapshot is inside these trees, and the later
  # comparisons accept it because it matches the snapshot.
  local captured_kb
  captured_kb=$(snapshot_kb "$wt" "$sha" "$idx_tree" "$wt_tree") \
    || { SALVAGE_NOTE="cannot size the salvage snapshot"; return 1; }
  local admin_kb
  admin_kb=$(admin_files_kb "$wt") || { SALVAGE_NOTE="cannot size the admin directory's files"; return 1; }
  captured_kb=$((captured_kb + admin_kb))
  if [ "$captured_kb" -gt "$SALVAGE_MAX_KB" ]; then
    SALVAGE_NOTE="the snapshot holds more than ${SALVAGE_MAX_KB} KB of changed data"; return 1
  fi
  orphans=$(reflog_orphans "$wt") || { SALVAGE_NOTE="cannot find reflog-only commits"; return 1; }
  idx_commit=$(salvage_commit "$wt" "$idx_tree" "$sha" "salvage: staged index of $(basename "$wt")") \
    || { SALVAGE_NOTE="cannot commit the staged index"; return 1; }
  wt_commit=$(salvage_commit "$wt" "$wt_tree" "$sha" "salvage: working tree of $(basename "$wt")") \
    || { SALVAGE_NOTE="cannot commit the working tree"; return 1; }
  git -C "$TOPLEVEL" update-ref "$base/head" "$sha" "" 2>/dev/null \
    && git -C "$TOPLEVEL" update-ref "$base/index" "$idx_commit" "" 2>/dev/null \
    && git -C "$TOPLEVEL" update-ref "$base/worktree" "$wt_commit" "" 2>/dev/null \
    || { SALVAGE_NOTE="cannot write $base refs"; return 1; }
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    git -C "$TOPLEVEL" update-ref "$base/reflog/$o" "$o" "" 2>/dev/null \
      || { SALVAGE_NOTE="cannot write $base/reflog/$o"; return 1; }
    [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$base/reflog/$o" 2>/dev/null)" = "$o" ] \
      || { SALVAGE_NOTE="$base/reflog/$o does not verify"; return 1; }
  done <<< "$orphans"
  # Verify through the repository that outlives the worktree, not the worktree itself.
  [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$base/head" 2>/dev/null)" = "$sha" ] \
    && [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$base/index^{tree}" 2>/dev/null)" = "$idx_tree" ] \
    && [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$base/worktree^{tree}" 2>/dev/null)" = "$wt_tree" ] \
    || { SALVAGE_NOTE="$base refs do not verify"; return 1; }
  # COMMIT_EDITMSG and config.worktree die with the admin directory and are in no tree, so
  # their bytes are kept too (see SALVAGE_ADMIN_FILES).
  local kept line kref kblob
  kept=$(admin_file_blobs "$wt" -w) || { SALVAGE_NOTE="cannot preserve the admin directory's files"; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kref="$base/${line%% *}"; kblob=${line#* }
    git -C "$TOPLEVEL" update-ref "$kref" "$kblob" "" 2>/dev/null \
      && [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$kref" 2>/dev/null)" = "$kblob" ] \
      || { SALVAGE_NOTE="cannot write or verify $kref"; return 1; }
  done <<< "$kept"
  SALVAGE_REF=$base; SALVAGE_TREE=$wt_tree; SALVAGE_INDEX_TREE=$idx_tree; SALVAGE_ADMIN_BLOBS=$kept
  return 0
}

# The admin-directory files salvage keeps byte-for-byte, with the ref name each is kept under:
# a drafted message a hook rejected (COMMIT_EDITMSG) and per-worktree settings
# (config.worktree). Both die with the admin directory and neither is in any tree.
SALVAGE_ADMIN_FILES="COMMIT_EDITMSG:commit-editmsg config.worktree:config-worktree"

# admin_file_blobs <worktree> [-w] -> prints one `<ref-name> <blob>` line per kept admin file
# that exists (writing the objects with -w). Non-zero when one exists but is not a regular
# file, or cannot be read.
admin_file_blobs() {
  local admin pair f blob
  admin=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] || return 1
  for pair in $SALVAGE_ADMIN_FILES; do
    f="$admin/${pair%%:*}"
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
    [ -f "$f" ] && [ -r "$f" ] || return 1
    # shellcheck disable=SC2086  # $2 is empty or -w
    blob=$(git -C "$1" hash-object ${2:-} -- "$f" 2>/dev/null) && [ -n "$blob" ] || return 1
    printf '%s %s\n' "${pair#*:}" "$blob"
  done
}

# admin_files_kb <worktree> -> prints the kept admin files' size in KB, rounded up per file,
# so the salvage cap covers them too. Non-zero on a read failure.
admin_files_kb() {
  local admin pair f sz kb=0
  admin=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] || return 1
  for pair in $SALVAGE_ADMIN_FILES; do
    f="$admin/${pair%%:*}"
    [ -f "$f" ] || continue
    sz=$(wc -c < "$f" 2>/dev/null) || return 1
    sz=$(printf '%s' "$sz" | tr -d ' ')
    kb=$((kb + (sz + 1023) / 1024))
  done
  printf '%s\n' "$kb"
}

# admin_backpointer_ok <worktree> -> 0 only when the admin directory the worktree's .git file
# names points back at this worktree. A damaged or redirected gitfile would otherwise make
# every check inspect another worktree's admin while removal deletes this one's unexamined.
admin_backpointer_ok() {
  local wt=$1 admin back wt_real back_real
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] || return 1
  [ -f "$admin/gitdir" ] && [ -r "$admin/gitdir" ] || return 1
  back=$(head -n 1 "$admin/gitdir") && [ -n "$back" ] || return 1
  wt_real=$(physical_path "$wt") || return 1
  back_real=$(physical_path "$(dirname "$back")") || return 1
  [ "$back_real" = "$wt_real" ] && [ "$(basename "$back")" = .git ]
}

# reap_size_kb <worktree> -> prints the KB a removal frees: the working tree AND its admin
# directory (.git/worktrees/<id>), which the removal deletes with it (#3432). The admin
# directory holds every populated submodule's repository under modules/, so on the reference
# host it outweighed the working trees about 3 to 1, and a working-tree-only figure
# under-reported every sweep about 4x. It is measured here, before the removal, because it is
# gone afterwards; dry-run and apply measure at this same point, so they report the same
# figure. One du call, so a file hard-linked into both is counted once. An admin directory
# whose gitdir does not name this worktree is not the one the removal deletes, so only the
# working tree is counted then: the figure may under-count, never claim what was not freed.
reap_size_kb() {
  local wt=$1 admin output expected
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || admin=""
  if [ -n "$admin" ] && [ -d "$admin" ] && admin_backpointer_ok "$wt"; then
    set -- "$wt" "$admin"
  else
    set -- "$wt"
  fi
  expected=$#
  output=$(du -sk "$@" 2>/dev/null) || return 1
  [ -n "$output" ] || return 1
  awk -v expected="$expected" '
    $1 !~ /^[0-9]+$/ { invalid = 1 }
    { kb += $1 }
    END {
      if (invalid || NR != expected) exit 1
      print kb + 0
    }
  ' <<< "$output"
}

# The candidate set is every directory directly under WT_ROOT, PLUS every registered worktree
# nested deeper beneath it. A session worktree can itself hold worktrees at
# <session>/.claude/worktrees/<name> — the agent write-boundary hook requires exactly that
# placement — and a single-level glob never sees them. They were therefore evaluated by no
# sweep at all, at any age, while ALSO pinning their parent through the "contains a registered
# worktree" gate below, so the pair leaked together permanently. Measured on the reference host:
# 6 of 7 live maint-* worktrees were nested and none appeared in a full dry-run.
#
# Only the NESTED half comes from the registered list. Direct children stay unresolved glob
# output so an unresolvable one still reaches the `die` below rather than being dropped here,
# and an unregistered stray directory still reaches the "not a registered worktree" KEEP.
#
# Deepest-first, so a nested child is considered before the parent containing it. `sort -s`
# keeps the lexicographic order `sort -u` established within one depth, so the order is
# deterministic.
CANDIDATES=$(
  {
    for d in "$WT_ROOT"/*/; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # Keep only paths at least TWO levels under WT_ROOT: a direct child is
      # `$WT_ROOT/<name>` and the glob above already covers it.
      #
      # Deliberately NOT a `case` — the host's /bin/bash is 3.2, which mis-parses a case
      # pattern's `)` inside `$( )` and dies with "syntax error near unexpected token `;;'".
      # (`case "$p" in ("$WT_ROOT"/*/*)` also works, but this form needs no parser lore.)
      rest=${p#"$WT_ROOT"/}
      [ "$rest" != "$p" ] || continue          # not under WT_ROOT at all
      [ "${rest#*/}" != "$rest" ] || continue  # direct child: no separator left
      printf '%s\n' "$p"
    done <<< "$REGISTERED"
  } | sort -u | awk '{ d=gsub(/\//,"/"); print d "\t" $0 }' | sort -s -k1,1nr | cut -f2-
)

# Read candidates on FD 3. The loop body calls git and lsof, and a command that reads stdin
# would otherwise consume the remaining candidate lines and silently shorten the sweep.
while IFS= read -r wt <&3; do
  [ -n "$wt" ] || continue
  # A nested candidate whose parent was removed earlier in this same run is already gone.
  [ -d "$wt" ] || continue
  # A candidate that EXISTS (the glob matched a directory) but cannot be resolved is an
  # infrastructure failure — permissions, a broken mount — not a verdict about this
  # worktree. Reporting it as an ordinary KEEP let the run exit 0 while silently unable
  # to inspect part of the tree.
  wt_real=$(physical_path "$wt") \
    || die "cannot resolve candidate worktree $wt — refusing to continue on an uninspectable tree"
  name=$(wt_label "$wt")
  # Per-candidate salvage state; recheck_mutable_gates reads it, so it must never leak
  # from the previous candidate.
  salvage_reason=""; SALVAGE_REF=""; SALVAGE_TREE=""; SALVAGE_INDEX_TREE=""; SALVAGE_ADMIN_BLOBS=""; SALVAGE_NOTE=""

  # KEEP: anything git does not know as a worktree. Never a deletion candidate.
  # here-string, NOT a pipe: grep -q exits at its first match, printf then takes SIGPIPE,
  # and under pipefail the pipeline reports failure — inverting this very test.
  if ! grep -qxF -- "$wt_real" <<< "$REGISTERED"; then
    keep "$wt" "not a registered worktree"; continue
  fi

  # KEEP: worktree-cleanup-all.sh reaped a worktree nested in this one's submodule and could
  # not hand that repository's refs/reaped to storage outliving this tree, so removing it
  # would delete the only recovery refs. One physical path per line; literal match.
  if [ -n "${WORKTREE_CLEANUP_RETAIN:-}" ] && grep -qxF -- "$wt_real" <<< "$WORKTREE_CLEANUP_RETAIN"; then
    keep "$wt" "nested recovery refs not yet handed off (worktree-cleanup-all.sh)"; continue
  fi

  # KEEP: a live per-run owner may use a clean tree without holding a process CWD.
  # Re-checked again immediately before removal by recheck_mutable_gates.
  ownership_claim_state "$wt"; claim_rc=$?
  case "$claim_rc" in
    0) keep "$wt" "active ownership claim ($CLAIM_DETAIL)"; continue ;;
    2) keep "$wt" "ambiguous ownership claim ($CLAIM_DETAIL)"; continue ;;
  esac

  # KEEP: a live session's CWD (the worktree itself, or any directory inside it).
  # Both comparisons are LITERAL. An earlier version matched descendants with
  # `grep "^$wt_real/"`, which treats the path as a REGEX: a worktree name containing
  # an unbalanced '[' made grep error out, the descendant check silently reported "no
  # match", and a live session working in a SUBDIRECTORY fell through to the reap
  # gates — a fail-OPEN on the one signal that protects running sessions.
  # Case-folded, like LIVE_CWDS: a spurious match only keeps.
  live=0
  wt_fold=$(printf '%s' "$wt_real" | fold_case)
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    if [ "$cwd" = "$wt_fold" ] || [ "${cwd#"$wt_fold"/}" != "$cwd" ]; then
      live=1; break
    fi
  done <<< "$LIVE_CWDS"
  if [ "$live" -eq 1 ]; then
    keep "$wt" "live process CWD"; continue
  fi

  # KEEP: locked (same symlink-resolved, fail-closed check used before removal)
  is_locked_now "$wt_real"; lock_rc=$?
  case "$lock_rc" in
    0) keep "$wt" "locked"; continue ;;
    2) die "cannot query worktree locks for $wt_real — refusing to continue on an unverifiable lock state" ;;
  esac

  # KEEP: too young.
  # Validate that mtime is NUMERIC rather than trusting stat's exit status. GNU stat
  # reads `-f` as "filesystem status", so `stat -f %m` does not fail on Linux — it
  # SUCCEEDS and prints a `File: ...` block, the `||` fallback never fires, and the
  # arithmetic below then treats `File:` as a variable name (unbound under set -u).
  # GNU form first, BSD second, each accepted only if it yields digits.
  mtime=$(stat -c %Y "$wt" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) mtime=$(stat -f %m "$wt" 2>/dev/null || true) ;; esac
  case "$mtime" in ''|*[!0-9]*) keep "$wt" "cannot stat"; continue ;; esac
  age_h=$(( (now - mtime) / 3600 ))
  if [ "$age_h" -lt "$MIN_AGE_HOURS" ]; then
    keep "$wt" "age ${age_h}h < ${MIN_AGE_HOURS}h"; continue
  fi

  # KEEP: an in-progress git operation. A worktree mid-rebase, -merge, -cherry-pick,
  # -revert or -bisect holds that operation's state (and often a stash of conflicted
  # work) only in its own admin directory, so removing it destroys work that no commit
  # and no reflog entry accounts for. `git rev-parse --git-path` resolves these per
  # worktree, which is what makes the check correct for a linked worktree.
  gitdir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null); gitdir_rc=$?
  if [ "$gitdir_rc" -ne 0 ] || [ -z "$gitdir" ]; then
    keep "$wt" "cannot resolve its git dir"; continue
  fi
  inprogress=""
  for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    if [ -e "$gitdir/$marker" ]; then inprogress=$marker; break; fi
  done
  if [ -n "$inprogress" ]; then
    keep "$wt" "git operation in progress ($inprogress)"; continue
  fi

  # KEEP: unresolvable HEAD
  sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { keep "$wt" "no HEAD"; continue; }
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached)")

  # KEEP: commits not reachable from any remote — the sole-copy-of-real-work test.
  # Covers an unpushed branch and an orphan detached HEAD in one call.
  unpushed=$(git -C "$TOPLEVEL" rev-list --count "$sha" --not --remotes 2>/dev/null)
  if [ -z "$unpushed" ]; then
    keep "$wt" "cannot determine push state"; continue      # fail closed
  fi
  # A squash-merged branch reads as unpushed forever; accept it only on PR evidence.
  merged_head=""
  if [ "$unpushed" -gt 0 ]; then
    pr_proves_spent "$branch" "$sha"; pr_rc=$?
    if [ "$pr_rc" -ne 0 ]; then
      note=""; [ -n "$PR_EVIDENCE_NOTE" ] && note=" ($PR_EVIDENCE_NOTE)"
      # rc 2 is "PR evidence unavailable": a later sweep may still prove the branch
      # spent, so it is not stuck.
      if [ "$pr_rc" -eq 2 ]; then
        keep "$wt" "$unpushed unpushed commit(s) on $branch$note"; continue
      fi
      if ! salvage_eligible "$age_h" "$wt"; then
        keep_stuck "$wt" "$unpushed unpushed commit(s) on $branch$note"; continue
      fi
      # Old enough to salvage: the later gates still run, and refs/salvaged/<id>/head
      # preserves these commits before any removal.
      salvage_reason="$unpushed unpushed commit(s) on $branch"
    else
      merged_head=$sha
    fi
  fi

  # KEEP: real working-tree changes. Submodule gitlinks and known tool-noise dirs are
  # filtered out; everything else counts as authored work.
  # --ignore-submodules=none is EXPLICIT too: submodule.<name>.ignore=all in .gitmodules
  # or local config makes status report a clean PARENT even when the submodule holds
  # uncommitted changes, so the submodule-cleanliness branch below never runs.
  # --untracked-files=all is EXPLICIT: a repo inheriting status.showUntrackedFiles=no
  # reports a clean worktree while holding non-ignored untracked authored files, and
  # apply mode would delete their only copy.
  status=$(porcelain_status "$wt") || {
    keep "$wt" "cannot read or classify status (unreadable, or a path holds a newline)"; continue; }

  # `git status` cannot see edits to files carrying the assume-unchanged or
  # skip-worktree index bits, so a worktree holding only such edits reads as clean.
  # Their presence alone is enough to keep it — the restore ref would preserve just the
  # committed version. `ls-files -v` marks them lowercase (assume-unchanged) or S/s
  # (skip-worktree).
  idx_flags=$(git -C "$wt" ls-files -v 2>/dev/null); idx_rc=$?
  if [ "$idx_rc" -ne 0 ]; then
    keep "$wt" "cannot read index flags"; continue
  fi
  # `S` (uppercase) is skip-worktree — the comment above said so while the pattern
  # matched lowercase only, so the very case that motivated this gate slipped through.
  # here-string for the same SIGPIPE+pipefail reason — as a pipe this gate silently
  # FAILED OPEN whenever ls-files -v output exceeded the pipe buffer.
  if grep -q '^[a-zS]' <<< "$idx_flags"; then
    keep "$wt" "assume-unchanged/skip-worktree files present (status cannot see edits)"
    continue
  fi
  count_real_changes "$wt" "$status"
  if [ "$REAL_CHANGES" -gt 0 ]; then
    # Only unreadable submodule evidence: not abandoned work, since the next sweep may prove
    # it spent, so keep without counting it stuck.
    if [ "$SUBMODULE_EVIDENCE_UNKNOWN" -eq "$REAL_CHANGES" ]; then
      keep "$wt" "$REAL_CHANGES submodule change(s) whose evidence could not be read (retried next sweep)"
      continue
    fi
    if ! salvage_eligible "$age_h" "$wt"; then
      keep_stuck "$wt" "$REAL_CHANGES uncommitted change(s)"; continue
    fi
    if [ "$REAL_SUBMODULE_CHANGES" -gt 0 ]; then
      keep_stuck "$wt" "$REAL_CHANGES uncommitted change(s), $REAL_SUBMODULE_CHANGES in a submodule (cannot be salvaged)"
      continue
    fi
    salvage_reason="${salvage_reason:+$salvage_reason; }$REAL_CHANGES uncommitted change(s)"
  fi

  # KEEP: a registered worktree nested INSIDE this one. The untracked-directory signal
  # is not enough — a repository that gitignores .claude/worktrees/ emits no status entry
  # for it at all, and reaping the parent would recursively delete the nested worktree
  # and any uncommitted work only it holds. The registered list is authoritative here and
  # owes nothing to ignore rules.
  nested=$(awk -v p="$wt_real/" 'index($0,p)==1' <<< "$REGISTERED" | head -1)
  if [ -n "$nested" ]; then
    keep "$wt" "contains a registered worktree ($(basename "$nested"))"; continue
  fi

  # KEEP: a worktree registered to an initialised SUBMODULE inside this one (#2588).
  # REGISTERED is the parent repository's list only, so a submodule's own worktrees —
  # e.g. <candidate>/applications/ksail/.claude/worktrees/<slug> — never appear in it.
  # Ask each initialised submodule's gitdir instead of matching paths: a path pattern
  # cannot tell such a worktree from an ordinary directory like .claude/scripts.
  # Any failure to enumerate is a KEEP, because an unreadable submodule proves nothing.
  if ! sub_nested=$(submodule_owned_worktree "$wt" "$wt_real"); then
    keep "$wt" "cannot enumerate submodule-owned worktrees"; continue
  fi
  if [ -n "$sub_nested" ]; then
    keep "$wt" "contains a submodule-owned worktree (${sub_nested#"$wt_real"/})"; continue
  fi

  # KEEP: commits that only this worktree's admin directory references — its HEAD reflog
  # (either side of an entry), ORIG_HEAD or FETCH_HEAD. HEAD may be remotely reachable while
  # the reflog still holds an earlier unpushed commit (commit, then reset back to a pushed
  # one). The admin directory dies with the worktree, so that commit's only reference would
  # go with it. An unreadable one is not proof there is nothing to lose.
  if ! reflog_shas=$(worktree_ref_ids "$wt"); then
    keep_stuck "$wt" "cannot read or classify the HEAD reflog, ORIG_HEAD or FETCH_HEAD"; continue
  fi
  if [ -n "$reflog_shas" ]; then
    # On a proven squash-merged branch, ancestors of the PR head are accounted for too;
    # a commit reset away from that history is not, and still keeps the worktree.
    # shellcheck disable=SC2086  # merged_head is empty or one sha
    if ! orphaned=$(git -C "$TOPLEVEL" rev-list --no-walk $reflog_shas --not --remotes $merged_head 2>/dev/null); then
      keep "$wt" "cannot check whether reflog or pseudo-ref commits are reachable"; continue
    fi
    orphaned=$(head -1 <<< "$orphaned")
    if [ -n "$orphaned" ]; then
      if ! salvage_eligible "$age_h" "$wt"; then
        keep_stuck "$wt" "reflog or pseudo-ref holds commit(s) reachable from nowhere else (${orphaned:0:12})"
        continue
      fi
      salvage_reason="${salvage_reason:+$salvage_reason; }reflog-only commit(s)"
    fi
  fi

  # KEEP: a tag object only ORIG_HEAD or FETCH_HEAD names. rev-list above peels it to its
  # commit, so a remotely reachable target reads as nothing to lose, but the tag's message
  # and signature die with the admin directory. Salvage cannot carry it either, so keep.
  # (When salvage is already wanted, its own blocker check refuses the tag with its reason.)
  if [ -z "$salvage_reason" ]; then
    if ! pseudo_tags=$(pseudo_ref_unreferenced_tags "$wt"); then
      keep_stuck "$wt" "cannot read or classify the HEAD reflog, ORIG_HEAD or FETCH_HEAD"; continue
    fi
    if [ -n "$pseudo_tags" ]; then
      keep_stuck "$wt" "ORIG_HEAD or FETCH_HEAD is the only reference to a tag object (${pseudo_tags:0:12})"
      continue
    fi
  fi

  # KEEP: a submodule repository the removal deletes holds work its remote lacks (#3683).
  # Status compares a submodule's checkout with its gitlink, and only a drifted one is
  # inspected above. A submodule sitting exactly on its recorded commit produces no status
  # line at all, yet its whole repository lives in this worktree's admin directory: a run that
  # committed on a local branch there and then returned to the gitlink commit leaves that
  # commit in a repository the removal deletes. So every submodule repository is held to the
  # drifted one's rule, drifted or not, checked out or not. A salvage candidate is skipped:
  # salvage_blocker refuses any worktree that holds a submodule repository at all.
  if [ -z "$salvage_reason" ]; then
    submodule_repositories_disposable "$wt" "$wt_real"; sub_rc=$?
    case "$sub_rc" in
      0) ;;
      1) keep_stuck "$wt" "submodule repository holds commit(s) its remote lacks ($SUBMODULE_NOTE)"; continue ;;
      *) keep "$wt" "cannot prove its submodule repositories hold nothing local-only ($SUBMODULE_NOTE; retried next sweep)"
         continue ;;
    esac
  fi

  # --- REAP ------------------------------------------------------------------------
  # The working tree plus its admin directory, sized before anything is removed.
  if sz_kb=$(reap_size_kb "$wt"); then
    size_note="$((sz_kb/1024)) MB"
  else
    sz_kb=""
    size_note="size unknown"
    unmeasured=$((unmeasured+1))
  fi
  # Ignored files are NOT a KEEP reason — 70 of 80 worktrees on the reference host carry
  # build output or caches, so keeping on them would make the sweep reclaim nothing and
  # leave the disk-full condition this tool exists for unresolved. They are counted and
  # surfaced instead, so what a reap discards is visible in the output and the manifest
  # rather than silent. (min_age_hours, the live/lock re-checks, the manifest and
  # refs/reaped are what bound the residual risk.)
  ign=$(git -C "$wt" status --porcelain --ignored=matching --untracked-files=all 2>/dev/null \
        | grep -c '^!!' ) || ign=0
  ign_note=""; [ "${ign:-0}" -gt 0 ] && ign_note=" +${ign} ignored"
  if [ -n "$salvage_reason" ] && salvage_blocker "$wt"; then
    keep_stuck "$wt" "$salvage_reason; not salvaged: $SALVAGE_NOTE"; continue
  fi
  if [ "$MODE" = "dry-run" ]; then
    if [ -n "$salvage_reason" ]; then
      printf 'SALVAGE %-51s %s (%s; %s%s)\n' "$name" "$branch" "$salvage_reason" "$size_note" "$ign_note"
      salvaged=$((salvaged+1))
    else
      printf 'REAP   %-52s %s (%s%s)\n' "$name" "$branch" "$size_note" "$ign_note"
    fi
    reaped=$((reaped+1))
    [ -n "$sz_kb" ] && freed_kb=$((freed_kb+sz_kb))
    continue
  fi

  worktree_claim_lock_acquire "$wt_real"; claim_lock_rc=$?
  case "$claim_lock_rc" in
    0) ;;
    1) keep "$wt" "ownership mutex held by another process"; continue ;;
    2) keep "$wt" "cannot verify/acquire ownership mutex"; continue ;;
  esac

  # SALVAGE: preserve the abandoned work BEFORE the manifest row and the removal, under
  # the mutex and after the mutable gates and identity re-check, so the snapshot is of the
  # tree that is about to be removed. recheck_mutable_gates then compares the tree against
  # this snapshot at every later point, so a change made after it is never deleted.
  if [ -n "$salvage_reason" ]; then
    if ! recheck_mutable_gates "$wt" "$wt_real"; then
      worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
      continue
    fi
    if ! still_the_reviewed_worktree "$wt" "$branch" "$sha" "$merged_head"; then
      worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
      keep "$wt" "$IDENTITY_NOTE"; continue
    fi
    # Re-apply the salvage blockers under the mutex: the first check ran before the lock,
    # so data written since then (a large file, a new submodule commit) would otherwise be
    # snapshotted past the cap, or deleted with the worktree.
    if salvage_blocker "$wt"; then
      worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
      keep_stuck "$wt" "$salvage_reason; not salvaged: $SALVAGE_NOTE"; continue
    fi
    if ! salvage_write "$wt" "$sha"; then
      worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
      keep_stuck "$wt" "$salvage_reason; not salvaged: $SALVAGE_NOTE"; continue
    fi
  fi

  # A manifest write failure is an INFRASTRUCTURE failure, not a per-worktree verdict:
  # the ledger is unwritable, so every subsequent removal would be unrecorded too.
  # Aborting (rather than keeping and carrying on) is what stops the wrapper reporting
  # a healthy sweep — which matters most under the disk pressure this tool exists for.
  # A squash-merged reap is NOT reachable from any remote; its commits survive only in the
  # PR head ref, so the ledger must say which of the two made the removal safe.
  reach_evidence="reachable-from-remote"
  [ -n "$merged_head" ] && reach_evidence="merged-pr-head"
  [ -n "$SALVAGE_REF" ] && reach_evidence="salvaged=$SALVAGE_REF ($salvage_reason)"
  if ! record "$wt_real" "$branch" "$sha" "$reach_evidence;no-live-process;age=${age_h}h;ignored=${ign:-0}" pending; then
    die "cannot write the restore manifest ($MANIFEST) — aborting before any removal"
  fi
  # Containment assertion before ANY recursive delete. $wt_real is derived from a glob
  # under $WT_ROOT and should always sit beneath it, but `rm -rf` is unforgiving enough
  # that the invariant is asserted rather than assumed — a bug upstream of here must not become a recursive delete of the checkout (or of /).
  # (belt-and-braces; the glob already constrains it)
  case "$wt_real" in
    "$WT_ROOT"/?*) : ;;
    *)
      worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
      keep "$wt" "REFUSING to remove: '$wt_real' is not under '$WT_ROOT'"; continue
      ;;
  esac

  if ! recheck_mutable_gates "$wt" "$wt_real"; then
    worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
    continue
  fi

  # Keep the reaped commit reachable so the manifest's SHA stays restorable. Without
  # this, a stale remote-tracking ref can make a commit look pushed, and a later
  # fetch --prune + gc would collect the only copy — leaving a manifest entry that
  # cannot be restored. One ref per commit; the name is the SHA, so it is idempotent.
  # This is a PRECONDITION of removal, not best-effort: no restore ref, no deletion —
  # the same rule the manifest write already follows.
  # HEAD is re-read immediately before it is preserved. A commit made between the
  # reachability check and here (a concurrent `git -C` whose CWD is outside the
  # worktree, so the liveness gate does not see it) leaves the working tree clean while
  # $sha still names the OLD commit — preserving that and deleting the worktree would
  # discard the new one.
  # The branch and the PR evidence are re-verified here too, under the mutex.
  if ! still_the_reviewed_worktree "$wt" "$branch" "$sha" "$merged_head"; then
    worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
    keep "$wt" "$IDENTITY_NOTE"; continue
  fi

  if ! git -C "$TOPLEVEL" update-ref "refs/reaped/$sha" "$sha" 2>/dev/null; then
    worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
    keep "$wt" "could not write refs/reaped/$sha — refusing to remove"; continue
  fi

  # The fallback's unregistration is deliberately OUTSIDE the success condition: `rm -rf`
  # can succeed while unregistering fails (git's admin dir unwritable), and folding it into
  # the condition sent an actually-deleted worktree down the "removal FAILED" branch — the
  # run then exited 0 leaving a `pending` row for a path that is already gone.
  # Deletion success is judged by the directory being absent; a failed unregistration is a
  # separate, loud error. It unregisters this worktree only: with the directory gone,
  # `git worktree remove` deletes just its admin entry, where a repository-wide
  # `git worktree prune` would also drop another lane's registration whose directory is
  # briefly unavailable (#3716).
  # The fallback re-runs the FULL mutable-gate set, not just the lock: the failed
  # `worktree remove` above can take time, and a session entering the worktree in that
  # window must still stop the recursive delete.
  # Written as a branch chain, NOT a && chain. Folded into one condition, a legitimate
  # KEEP from the fallback re-check (the worktree became locked/live/dirty since the
  # gates ran) made the whole condition false and fell into the `removal FAILED` abort —
  # so an ordinary, correct decision to spare a worktree would have killed the entire
  # scheduled sweep. "Keep it" and "could not remove it" must stay distinguishable.
  if git -C "$TOPLEVEL" worktree remove --force "$wt_real" 2>/dev/null; then
    # The per-worktree ref and gitdir were removed atomically with the worktree.
    worktree_claim_lock_forget
  elif ! recheck_mutable_gates "$wt" "$wt_real"; then
    worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
    continue    # legitimately KEPT and already reported by the gate
  elif ! still_the_reviewed_worktree "$wt" "$branch" "$sha" "$merged_head"; then
    worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
    keep "$wt" "$IDENTITY_NOTE"; continue
  elif rm -rf "$wt_real" && [ ! -e "$wt_real" ]; then
    worktree_claim_lock_release || die "REMOVED $wt_real but could not release its ownership mutex"
    git -C "$TOPLEVEL" worktree remove --force "$wt_real" 2>/dev/null \
      || die "REMOVED $wt_real but could not remove its registration — the deletion DID happen; run 'git -C $TOPLEVEL worktree remove --force $wt_real' to clear its admin entry (restore ref: refs/reaped/$sha)"
  else
    worktree_claim_lock_release || true
    die "removal FAILED for $wt_real after all gates passed (its manifest row is 'pending' and the directory still exists)"
  fi
  # Reached only when the directory is genuinely gone: every other path above either
  # continued (kept) or died (failed).
  # A failed completion write cannot be undone at this point, so exit non-zero and say
  # exactly how to read the resulting ledger rather than leaving an unmatched `pending`
  # that looks like an aborted attempt.
  record "$wt_real" "$branch" "$sha" "removed" reaped \
    || die "REMOVED $wt_real but could not append its 'reaped' row. The deletion DID happen: a 'pending' row whose path no longer exists means deleted, not aborted (restore ref: refs/reaped/$sha)"
  if [ -n "$SALVAGE_REF" ]; then
    printf 'SALVAGED %-50s %s -> %s (%s%s)\n' "$name" "$branch" "$SALVAGE_REF" "$size_note" "$ign_note"
    salvaged=$((salvaged+1))
  else
    printf 'REAPED %-52s %s (%s%s)\n' "$name" "$branch" "$size_note" "$ign_note"
  fi
  reaped=$((reaped+1))
  [ -n "$sz_kb" ] && freed_kb=$((freed_kb+sz_kb))
done 3<<< "$CANDIDATES"

# No closing `git worktree prune` (#3716). Every worktree reaped above lost its registration
# with its directory, or the run died saying it did not. A repository-wide prune cannot be
# limited to this root, so it would also drop another lane's registration whose directory
# is only briefly unavailable, and that worktree would come back with a broken link to its
# repository.

if [ "$unmeasured" -gt 0 ]; then
  printf '\nworktree-cleanup: mode=%s reaped=%d kept=%d stuck=%d salvaged=%d freed=%d MB unmeasured=%d\n' \
    "$MODE" "$reaped" "$kept" "$stuck" "$salvaged" "$((freed_kb/1024))" "$unmeasured"
else
  printf '\nworktree-cleanup: mode=%s reaped=%d kept=%d stuck=%d salvaged=%d freed=%d MB\n' \
    "$MODE" "$reaped" "$kept" "$stuck" "$salvaged" "$((freed_kb/1024))"
fi
if [ "$stuck" -gt 0 ]; then
  printf 'worktree-cleanup: %d of the kept worktree(s) hold abandoned work that no sweep will reap; salvage or discard it (#2831)\n' "$stuck"
fi
