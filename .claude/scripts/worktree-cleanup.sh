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
#   KEEP  - a worktree whose HEAD reflog, ORIG_HEAD or FETCH_HEAD names a commit no remote
#           ref reaches. Here a commit origin advertises right now counts as on the remote
#           too (a pull request's head, a claim tip), read once per sweep (#2831)
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
#   ABORT - a shared git directory that cannot be resolved (where the main checkout's
#           submodule repositories live): unread is not the same as absent
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
#   refs/salvaged/<id>/module-files - a tree of every file of each submodule repository outside its
#                                   object store, when the worktree holds submodules, at its
#                                   path under the admin directory (modules/<path>/config,
#                                   .../description, .../hooks/..., .../info/exclude, .../logs/...)
#   refs/salvaged/<id>/resolve-undo - a tree of the index's resolve-undo stages, when present, as
#                                   `stage<N>/<path>` (1 base, 2 ours, 3 theirs). Git has no
#                                   command that writes them back into an index; read a stage
#                                   with `git cat-file blob refs/salvaged/<id>/resolve-undo:stage2/<path>`.
#                                   A clean, fully pushed worktree is reaped without salvage,
#                                   but its index dies too, so this one ref is written for it
#                                   as well and the manifest row names it (resolve-undo=<ref>)
#   refs/salvaged/<id>/submodules - the record of each submodule whose work was carried (below),
#                                   one tab-separated line each: its repository's path under
#                                   the git directory, the path its checkout had inside the
#                                   worktree, the repository that now holds the work, and
#                                   the three objects; then a line per extra ref
# SUBMODULE WORK. Work held inside a submodule is not in any of the refs above: a linked
# worktree's submodule repository lives under its admin directory (modules/<name>) and the
# removal deletes it. It is carried instead into the repository that outlives the worktree
# for that submodule, the main checkout's own, under the SAME name, and the manifest row
# gains one `submodule=<label>` field for each. <label> is that repository's path under the
# git directory: modules/<name>, or modules/<a>/modules/<b> for a submodule of a submodule.
# It follows the submodule's NAME, which is its path only by default, so it does not say
# where the submodule is checked out. The repository itself is <git directory>/<label>:
#   refs/salvaged/<id>/head       - the submodule's HEAD commit
#   refs/salvaged/<id>/index      - a commit of its staged index, parent HEAD
#   refs/salvaged/<id>/worktree   - a commit of its whole working tree, parent HEAD, taken as
#                                   the parent's is (untracked files in, ignored files out)
#   refs/salvaged/<id>/commit/<sha> - each commit a ref, reflog, ORIG_HEAD or FETCH_HEAD of it
#                                   reaches that its origin does not advertise (tips only)
#   refs/salvaged/<id>/object/<sha> - each tag it holds that its origin does not advertise
# The copy is a local `git fetch` between the two directories: no network and never a push.
# It is then read back from the receiving repository (each ref at the object sent, both
# trees equal to the snapshot, nothing they reach missing) before the manifest names it,
# and read back once more, with the parent's record, immediately before the removal. The
# size cap counts what the copy adds to that repository: the snapshot's changed data and
# every object the carried commits reach that it does not already hold. A submodule back
# on its recorded commit whose repository alone holds such commits (nothing in the
# parent's status) makes the worktree a salvage candidate in the same way, past the
# salvage age. Which branch or tag held a commit is in the parent's
# module-files tree (<label>/refs/..., packed-refs, logs/...).
# The Claude desktop app writes an empty `claude-desktop-worktree` file into the admin
# directory of each session worktree it creates (#4152). That empty regular file is one of
# two entries git did not write that the removal may delete: the manifest row of any reaped
# worktree that held it gains a `desktop-marker=empty` field. To restore the marker, recreate
# the worktree first (the restore steps above), then run, against that existing directory,
# `: > "$(git -C <dir> rev-parse --absolute-git-dir)/claude-desktop-worktree"`. With
# content, or as a link or directory, it keeps the worktree like any unlisted entry.
# The other is `CLAUDE_BASE`, where Claude Code records the commit a subagent worktree
# started from (#2831). Salvage deletes it only when it holds one object id of a commit a
# remote-tracking ref reaches, so the commit itself survives on that remote; only the pointer
# is lost. Any other content, a link or a directory keeps the worktree.
# Restore a submodule's work from the manifest row alone, with D=<git directory>/<label>
# (the git directory is the main checkout's .git):
#   git --git-dir="$D" --work-tree="$D" worktree add --detach <dir> refs/salvaged/<id>/head
#   git -C <dir> read-tree refs/salvaged/<id>/index
#   git -C <dir> restore --source=refs/salvaged/<id>/worktree --worktree -- .
# That needs no checkout of the submodule anywhere. To work in the main checkout's own
# checkout of it instead, it is the directory whose `git rev-parse --absolute-git-dir` is
# $D (`git -C <main> submodule foreach --recursive 'git rev-parse --absolute-git-dir'`
# lists them); the record's second column is the path it had inside the removed worktree.
# Restore: `git worktree add --detach <path> refs/salvaged/<id>/head`, then
# `git -C <path> read-tree refs/salvaged/<id>/index` for the staged index and
# `git -C <path> restore --source=refs/salvaged/<id>/worktree --worktree -- .` for the working
# tree. `restore` does not overlay, so paths the salvaged tree deleted are deleted again.
# The salvaged blobs are the working tree's exact bytes (conversion_blocker checks that), but
# `restore` runs checkout-side conversions (smudge filters, eol=crlf) on the way out; for a
# byte-exact copy of one path read the blob raw: `git cat-file blob refs/salvaged/<id>/worktree:<path>`.
# Every other gate is unchanged, and salvage fails closed to the old KEEP:
#   KEEP  - a salvage candidate holding any repository besides its own that the removal
#           would cost something: an embedded repository even when ignored, or a submodule
#           repository that is neither pristine (module_repository_pristine: only what a
#           clone of its remote holds, checked out clean inside the worktree) nor one whose
#           work can be carried as above
#   KEEP  - submodule work with nowhere to go, or that cannot be carried whole: the main
#           checkout has no repository for that submodule, or one that is a symbolic link,
#           borrows its objects, is a partial clone, cannot be written, or names another
#           origin than the submodule's; the submodule repository holds a stash or any ref
#           outside branches and tags, a hook, a setting or exclude rule of its own, an
#           operation in progress, a worktree of its own (even one whose directory is
#           gone), resolve-undo stages, intent-to-add or conflicted index entries, or files
#           its index hides from status; its checkout holds an embedded repository, or
#           ignored files under its own agent worktree root (.claude/worktrees,
#           .codex/worktrees); or it holds more than 50 commits and tags to carry, or its
#           files and commits together would add more than the size cap
#   KEEP  - carried work that no longer reads back from the receiving repository, or whose
#           record in the parent changed, between the copy and the removal
#   KEEP  - a worktree holding a worktree registered to one of its submodules, exactly as
#           without salvage: that rule runs first and nothing here relaxes it
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
# bytes, of the worktree's own repository and of each submodule carried as above. A
# submodule's ignored files are not kept, like the worktree's own, and neither is anything
# the list above refuses, which is why such a submodule keeps the worktree.

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
# The repository's shared git directory, canonical: the main checkout's own submodule
# repositories live under its modules/ and outlive every linked worktree (module_durable).
# Not resolving it is a failed read of the repository, like the toplevel above, and not
# proof that no such repository exists: reading it as "nowhere to carry to" would report
# worktrees as stuck on work nobody looked for a home for. So it aborts.
COMMON_DIR=$(git -C "$TOPLEVEL" rev-parse --git-common-dir 2>/dev/null) && [ -n "$COMMON_DIR" ] \
  || die "cannot resolve the shared git directory of $TOPLEVEL"
case "$COMMON_DIR" in /*) ;; *) COMMON_DIR="$TOPLEVEL/$COMMON_DIR" ;; esac
COMMON_DIR=$(physical_path "$COMMON_DIR") && [ -n "$COMMON_DIR" ] \
  || die "cannot resolve the shared git directory of $TOPLEVEL to a canonical path"

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
gh_bounded() { run_bounded "$GH_BIN" "$@"; }

# run_bounded <command> [args...] — the command with the same deadline; prints its stdout,
# returns its status or 124.
# The command runs in its own process group (job control), and the deadline stops the whole
# group: git hands a remote read to a transport helper (ssh, git-remote-https), and a signal
# to git alone leaves that helper running after the sweep has given up on it.
run_bounded() {
  local tmp pid rc ticks=0 had_monitor=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/worktree-cleanup-gh.XXXXXX") || return 2
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  "$@" >"$tmp" 2>/dev/null &
  pid=$!
  [ "$had_monitor" -eq 1 ] || set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((GH_DEADLINE_S * 5)) ]; then
      # Negative pid = the group; the single pid is the fallback where job control gave none.
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      # TERM can be ignored, and `wait` on a command that ignores it never returns. So it
      # gets two seconds, then the group is killed, and only then is the command reaped.
      ticks=0
      while kill -0 "$pid" 2>/dev/null && [ "$ticks" -lt 10 ]; do sleep 0.2; ticks=$((ticks + 1)); done
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      { wait "$pid"; } 2>/dev/null
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

# remote_held_commits -> sets REMOTE_HELD to every commit origin advertises right now that the
# local object store also holds, one per line. Read once per sweep, and only when a worktree
# first needs it.
# `--not --remotes` knows only the remote-tracking refs this checkout happens to have, and a
# commit can be on the remote without one: a pull request's head (refs/pull/<n>/head, which
# GitHub keeps after the branch is deleted), a claim tip, or a branch pushed by refspec and
# never fetched back. Measured on the host 2026-10-11: 20 of the 34 worktrees kept for a
# reflog-only commit were kept for one origin advertised (#2831).
# Any failure, a timeout included, leaves the list empty or short, which only ever keeps more,
# and sets REMOTE_HELD_FAILED so the sweep ends UNKNOWN (exit 2) instead of calling worktrees
# it could not ask about abandoned.
# Call it from the main shell, never inside $(): a subshell would drop the result and every
# worktree would ask origin again.
# The answer is as of the read, and origin can drop a ref afterwards. Unlike a remote-tracking
# ref, an advertisement keeps nothing locally, so apply pins every commit accepted this way
# under refs/reaped before the removal.
REMOTE_HELD=""
REMOTE_HELD_READ=0
REMOTE_HELD_FAILED=0
remote_held_commits() {
  [ "$REMOTE_HELD_READ" -eq 0 ] || return 0
  REMOTE_HELD_READ=1
  local rows ids
  # No GIT_SSH_COMMAND here: it outranks core.sshCommand and GIT_SSH, so setting it would
  # replace a transport the repository configured. The deadline bounds a prompt instead.
  rows=$(GIT_TERMINAL_PROMPT=0 run_bounded git -C "$TOPLEVEL" ls-remote origin) || { REMOTE_HELD_FAILED=1; return 0; }
  # An advertised line is `<object id><TAB><ref>`; anything else is not evidence.
  ids=$(awk -F'\t' 'NF == 2 && $1 ~ /^([0-9a-f]{40}|[0-9a-f]{64})$/ { print $1 }' <<< "$rows" | sort -u) || { REMOTE_HELD_FAILED=1; return 0; }
  # No id from a non-empty answer is an answer this could not read, not an empty remote.
  if [ -z "$ids" ]; then
    [ -z "$rows" ] || REMOTE_HELD_FAILED=1
    return 0
  fi
  REMOTE_HELD=$(git -C "$TOPLEVEL" cat-file --batch-check='%(objectname) %(objecttype)' <<< "$ids" \
                2>/dev/null | awk '$2 == "commit" { print $1 }') || { REMOTE_HELD=""; REMOTE_HELD_FAILED=1; }
}

# not_remote_held <commits> -> prints those of <commits> (one per line) that no commit origin
# advertises reaches. With nothing advertised, prints them all. When the comparison itself
# fails, prints them all and returns 1, so the caller can end the sweep UNKNOWN.
# Reads REMOTE_HELD only; the caller runs remote_held_commits first.
not_remote_held() {
  local commits=$1 out
  [ -n "$commits" ] || return 0
  if [ -z "$REMOTE_HELD" ]; then printf '%s\n' "$commits"; return 0; fi
  if out=$( { printf '%s\n' "$commits"; sed 's/^/^/' <<< "$REMOTE_HELD"; } \
            | git -C "$TOPLEVEL" rev-list --no-walk --stdin 2>/dev/null); then
    [ -z "$out" ] || printf '%s\n' "$out"
  else
    printf '%s\n' "$commits"
    return 1
  fi
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
# What the pending manifest row says of the desktop app's marker (empty|absent); "" before a row.
DESKTOP_MARKER_RECORDED=""
DESKTOP_MARKER_UNREAD=0; DESKTOP_MARKER_NOW=""; DESKTOP_MARKER_NOTE=""

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

  if [ -n "$SALVAGE_TREE" ]; then
    # Everything that waits on the network comes first: each submodule's remote is asked again
    # here, not answered from what an earlier worktree in this sweep was told, and GitHub is
    # asked whatever that needs. Those reads can each take up to the deadline, and a change
    # made while one is waiting must still meet the local comparisons, so every local
    # comparison below runs after this, and the pristine check is repeated at the end from
    # the answers just read, with nothing left to wait on.
    MODULE_REMOTE_FRESH=1
    if nested_repository_blocker "$wt"; then
      MODULE_REMOTE_FRESH=0
      keep "$wt" "$SALVAGE_NOTE, after the salvage snapshot ($SALVAGE_REF)"; return 1
    fi
    MODULE_REMOTE_FRESH=0
  fi
  st=$(porcelain_status "$wt") \
    || { keep "$wt" "cannot re-read or classify status before removal"; return 1; }
  count_real_changes "$wt" "$st"
  if [ -n "$SALVAGE_TREE" ]; then
    # Salvaged: the work may be uncommitted, so compare it with the snapshot instead.
    # Anything written after the snapshot is not in the salvage refs and must not be lost.
    local now_tree now_index
    # The submodule changes counted at the scan were expected and are held by the checks
    # below (each submodule repository pristine, or carried exactly as it now is). Any other
    # count means a submodule changed since.
    if [ "$REAL_SUBMODULE_CHANGES" -ne "$SCAN_SUBMODULE_CHANGES" ]; then
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
    # The submodule repositories whose work was carried, re-read from the plan the check
    # above just rebuilt: the same repositories, each with the same HEAD, index, working
    # tree and commits as the copy the main checkout's repository now holds. A file edited
    # in a submodule after the snapshot changes none of the parent's trees.
    if ! module_carry_signature; then
      keep "$wt" "cannot re-snapshot a submodule's work before removal ($SALVAGE_NOTE)"; return 1
    fi
    if [ "$CARRY_SIGNATURE" != "$SALVAGE_CARRIED" ]; then
      keep "$wt" "a submodule's work changed after the salvage snapshot ($SALVAGE_REF)"; return 1
    fi
    # The source still matches what was sent. The copy is read again as well, from the
    # repository that received it: nothing locks that repository, and a ref deleted or
    # moved there since the copy was verified (a prune, a gc, another tool, a person) would
    # leave the manifest naming work that the removal is about to make the last copy of.
    local vi=0
    while [ "$vi" -lt "${#CARRIED_DURABLE[@]}" ]; do
      if ! module_carry_verify "${CARRIED_DURABLE[$vi]}" "${CARRIED_LABEL[$vi]}" "$SALVAGE_REF" \
             "${CARRIED_ITREE[$vi]}" "${CARRIED_WTREE[$vi]}" "${CARRIED_SPECS[$vi]}"; then
        keep "$wt" "a submodule's carried work no longer verifies before removal ($SALVAGE_NOTE)"; return 1
      fi
      vi=$((vi + 1))
    done
    # And the parent's record of what went where: the ref still at the blob written (its id
    # is its bytes), and the blob still in the object store.
    if [ -n "$SALVAGE_CARRIED" ]; then
      if [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$SALVAGE_REF/submodules" 2>/dev/null)" != "$SALVAGE_CARRIED_BLOB" ] \
         || ! git -C "$TOPLEVEL" cat-file -e "$SALVAGE_CARRIED_BLOB" 2>/dev/null; then
        keep "$wt" "the record of the carried submodule work changed before removal ($SALVAGE_REF/submodules)"; return 1
      fi
    fi
    # Last of all, and purely local: the submodule repositories' files against what they
    # were before the snapshot.
    local now_fp
    if ! now_fp=$(modules_fingerprint "$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)"); then
      # Not compared, so neither changed nor unchanged, and not a clean sweep.
      REMOTE_MODULE_FAILED=1
      keep "$wt" "cannot re-read its submodule repositories before removal ($SALVAGE_REF)"; return 1
    fi
    if [ "$now_fp" != "$SALVAGE_MODULES_FP" ]; then
      keep "$wt" "a submodule repository changed after the salvage snapshot ($SALVAGE_REF)"; return 1
    fi
    # And against the copy that was actually kept: a file changed after the fingerprint above
    # was first taken, captured in that state and then changed back matches the fingerprint
    # again, while the kept copy holds bytes that are no longer the ones being removed.
    if ! module_files_tree "$wt"; then
      REMOTE_MODULE_FAILED=1
      keep "$wt" "cannot re-read its submodule repositories before removal ($SALVAGE_REF)"; return 1
    fi
    if [ "$MODULE_FILES_TREE" != "$SALVAGE_MODULE_TREE" ]; then
      keep "$wt" "a submodule repository no longer matches its kept copy ($SALVAGE_REF)"; return 1
    fi
  elif [ -n "$salvage_reason" ]; then
    # Salvage candidate before its snapshot: its changes are expected and are about to be
    # preserved. So are the submodule changes the scan counted, which the salvage blockers
    # judge next (carried, or kept); more of them than that is work that arrived since.
    if [ "$REAL_SUBMODULE_CHANGES" -gt "$SCAN_SUBMODULE_CHANGES" ]; then
      keep "$wt" "submodule work appeared during the sweep"; return 1
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
    # A commit made and reset away since the initial scan leaves HEAD and status as they
    # were and lives only in the reflog the removal deletes. The scan accounted for the
    # ids it read, so any other set means the worktree was used since.
    local now_ids
    now_ids=$(worktree_ref_ids "$wt") || { keep "$wt" "cannot re-read the reflog before removal"; return 1; }
    if [ "$now_ids" != "$SCAN_REF_IDS" ]; then
      keep "$wt" "the HEAD reflog, ORIG_HEAD or FETCH_HEAD changed during the sweep"; return 1
    fi
  fi

  # Status alone cannot cover this: not being visible to status is exactly what the
  # assume-unchanged and skip-worktree bits do.
  idx=$(git -C "$wt" ls-files -v 2>/dev/null) \
    || { keep "$wt" "cannot re-read index flags before removal"; return 1; }
  if grep -q '^[a-zS]' <<< "$idx"; then
    keep "$wt" "assume-unchanged/skip-worktree flags appeared during the sweep"; return 1
  fi

  # Once the index's resolve-undo stages are saved (by salvage, or by resolve_undo_preserve
  # for a plain reap), a later conflict resolution adds stages no ref holds. They change
  # neither the status nor either tree compared above.
  if [ "$RESOLVE_UNDO_SAVED" -eq 1 ]; then
    if ! resolve_undo_tree "$wt" || [ "$RESOLVE_UNDO_TREE" != "$SALVAGE_RESOLVE_UNDO" ]; then
      keep "$wt" "the index's resolve-undo entries changed after they were saved"; return 1
    fi
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
  # Last, after everything above that can wait on a network or a snapshot: the desktop app's
  # marker (#4152) must still be what the manifest row says. Written, or given content,
  # after the row, it would be deleted unrecorded.
  # This is the one place the comparison is made, by decision (#4155): no check can be
  # atomic with the removal, so a later one only narrows the window. What stays open is an
  # empty file appearing between here and the delete in a worktree idle past the reap age;
  # the min-age, live-process and lock gates bound it as they bound every other gate here.
  if [ -n "$DESKTOP_MARKER_RECORDED" ]; then
    desktop_marker_read "$wt" \
      || { keep "$wt" "$DESKTOP_MARKER_NOTE, after the manifest row was written"; return 1; }
    if [ "$DESKTOP_MARKER_NOW" != "$DESKTOP_MARKER_RECORDED" ]; then
      keep "$wt" "the desktop app's marker changed after the manifest row was written"; return 1
    fi
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
  # The subset of REAL_CHANGES held in a submodule. A linked worktree's submodule repository
  # lives in its admin dir and dies with it, so the parent's salvage refs cannot hold them;
  # salvage carries them to the main checkout's repository for that submodule when there is
  # one (module_carry_plan), and keeps the worktree when there is not.
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
          # Nothing is written from here, so the exposure is documented instead of hidden
          # behind an ineffective write. (Salvage does have a durable place, the main
          # checkout's repository for the same submodule, and writes there in apply only.)
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
  local work rc
  work=$(work_age_h "$2"); rc=$?
  # work_age_h runs in a subshell, so its "could not list the submodule repositories" comes
  # back as status 2 and the sweep is marked here: kept, but not examined.
  [ "$rc" -ne 2 ] || REMOTE_MODULE_FAILED=1
  [ "$rc" -eq 0 ] || return 1
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
# Read both fields together: salvage checks every submodule repository file twice,
# and separate stat processes made those scans a measured hot path (#4394).
file_changed() {
  local times m c style
  for style in gnu bsd; do
    case "$style" in
      gnu) times=$(stat -c '%Y %Z' "$1" 2>/dev/null) || continue ;;
      bsd) times=$(stat -f '%m %c' "$1" 2>/dev/null) || continue ;;
    esac
    IFS=' ' read -r m c <<< "$times"
    case "$m" in ''|*[!0-9]*) continue ;; esac
    case "$c" in ''|*[!0-9]*) continue ;; esac
    [ "$times" = "$m $c" ] || continue
    [ "$c" -gt "$m" ] && m=$c
    printf '%s\n' "$m"
    return 0
  done
  return 1
}

# reflog_newest <reflog-file> -> seconds since the epoch of the reflog's newest entry, 0 when
# it has none. git's reflog expiry (`git gc`, `git reflog expire`) rewrites every reflog file
# to drop old entries, which moves the file's mtime and ctime although nobody worked there:
# one such run at 2026-10-15 rewrote all 164 worktree reflogs on this host at once and
# restarted the salvage clock of every abandoned worktree (#4359). An entry's own timestamp
# survives that rewrite and moves only when HEAD moves. Fails when the newest line is not a
# well-formed entry, so the caller can fall back to the file's time (fail closed).
reflog_newest() {
  local out
  [ -s "$1" ] || { printf '0\n'; return 0; }
  out=$(awk '
    NF { last = $0 }
    END {
      if (last == "") { print 0; exit 0 }
      head = last; t = index(head, "\t"); if (t) head = substr(head, 1, t - 1)
      n = split(head, f, " ")
      if (n < 4 || f[1] !~ /^[0-9a-f]+$/ || f[2] !~ /^[0-9a-f]+$/ \
          || f[n-1] !~ /^[0-9]+$/ || f[n] !~ /^[+-][0-9][0-9][0-9][0-9]$/) exit 1
      print f[n-1]
    }' "$1") || return 1
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$out"
}

# work_age_h <worktree> -> whole hours since the newest work salvage would carry: every
# staged, modified or untracked (non-ignored) path, the index, and the HEAD reflog's newest
# entry. Editing a tracked file does not touch the worktree directory's mtime, so the
# directory alone can make a fresh edit look weeks old. Each path counts by its later of mtime and ctime, so a
# `chmod +x` is work; the index counts so that staging bytes that are already old is work
# too. The sweep never rewrites the index itself (GIT_OPTIONAL_LOCKS=0 above), so its mtime
# moves only with someone's git activity in that worktree (#3642). Non-zero on a read
# failure (the caller then keeps).
work_age_h() {
  local wt=$1 admin list p m newest=0 unreadable=0
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] || return 1
  newest=$(changed_paths_newest "$wt") || return 1
  if [ -e "$admin/index" ]; then
    m=$(file_changed "$admin/index") || return 1
    [ "$m" -gt "$newest" ] && newest=$m
  fi
  # The HEAD reflog counts by its newest entry, not its file time (reflog_newest, #4359). A
  # commit made with a backdated GIT_COMMITTER_DATE writes a backdated entry, but it also
  # rewrites the index, which still counts above.
  p="$admin/logs/HEAD"
  if [ -e "$p" ] || [ -L "$p" ]; then
    if [ -f "$p" ] && [ ! -L "$p" ] && m=$(reflog_newest "$p"); then :; else
      m=$(file_changed "$p") || return 1
    fi
    [ "$m" -gt "$newest" ] && newest=$m
  fi
  # Work done inside a submodule touches nothing above. Salvage now removes a worktree whose
  # submodules are pristine, so use of one counts as use of the worktree (#2831): every
  # file of each submodule repository outside its object store, since a new branch writes
  # only a ref, a reflog and a setting. Directories are not counted: git's own reads leave a
  # repository directory's time changed (measured on the host), so every sweep would make
  # each worktree look freshly used.
  if [ -d "$admin/modules" ] && [ ! -L "$admin/modules" ]; then
    list=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-age.XXXXXX") || return 1
    if ! module_state_files "$admin/modules" > "$list"; then
      # 2, not 1: the submodule repositories could not be listed, which the caller reports.
      rm -f "$list"; return 2
    fi
    while IFS= read -r -d '' p; do
      m=$(file_changed "$p") || { unreadable=1; break; }
      [ "$m" -gt "$newest" ] && newest=$m
    done < "$list"
    rm -f "$list"
    # 2 again: a submodule repository file that could not be read was not examined.
    [ "$unreadable" -eq 0 ] || return 2
    # Salvage also carries a submodule's uncommitted work (module_carry_plan), and editing a
    # file in a submodule's checkout touches none of its repository's files. So each
    # checkout's own changed and untracked paths count, like the worktree's above.
    local wt_real
    wt_real=$(physical_path "$wt") || return 1
    m=$(module_checkouts_newest "$admin/modules" "$wt_real") || return 2
    [ "$m" -gt "$newest" ] && newest=$m
  fi
  [ "$newest" -gt 0 ] || { echo 999999; return 0; }
  echo $(( (now - newest) / 3600 ))
}

# module_checkouts_newest <modules-dir> <worktree-realpath> -> prints the newest change time
# (changed_paths_newest) among the checkouts of the submodule repositories under a modules/
# directory; 0 when none has a changed path. Repositories are found from the top down, as
# module_state_files finds them: a directory holding a HEAD or an objects entry is one, and
# its own modules/ is walked the same way. One with no checkout inside the worktree
# (module_checkout) has no working tree to age. Non-zero when something cannot be listed, a
# checkout that exists cannot be resolved, or its changed paths cannot be read.
module_checkouts_newest() {
  local dir=$1 wt_real=$2 entry m rc newest=0
  dir_listable "$dir" || return 1
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if [ -L "$entry" ] || [ ! -d "$entry" ]; then continue; fi
    dir_listable "$entry" || return 1
    if [ -e "$entry/HEAD" ] || [ -L "$entry/HEAD" ] || [ -e "$entry/objects" ] || [ -L "$entry/objects" ]; then
      module_checkout "$entry" "$wt_real"; rc=$?
      case "$rc" in
        0) m=$(changed_paths_newest "$MODULE_CHECKOUT") || return 1
           [ "$m" -le "$newest" ] || newest=$m ;;
        1) ;;
        *) return 1 ;;
      esac
      if [ -d "$entry/modules" ] && [ ! -L "$entry/modules" ]; then
        m=$(module_checkouts_newest "$entry/modules" "$wt_real") || return 1
        [ "$m" -le "$newest" ] || newest=$m
      fi
    else
      m=$(module_checkouts_newest "$entry" "$wt_real") || return 1
      [ "$m" -le "$newest" ] || newest=$m
    fi
  done
  printf '%s\n' "$newest"
}


# changed_paths_newest <checkout> -> prints the newest change time (file_changed) among the
# checkout's staged, modified and untracked (non-ignored) paths; 0 when it has none.
# Non-zero on a read failure.
changed_paths_newest() {
  local wt=$1 list p d m newest=0 unreadable=0
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
  printf '%s\n' "$newest"
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
  # Salvage carries them in their own ref (resolve_undo_tree), so they only count
  # towards the cap here (#2831).
  sz=$(resolve_undo_kb "$wt") || { SALVAGE_NOTE="cannot read or size the index's resolve-undo entries"; return 0; }
  total_kb=$((total_kb + sz))
  # The submodule repositories' files are kept too (module_files_tree), so they count here.
  local admin_dir
  admin_dir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin_dir" ] \
    || { SALVAGE_NOTE="cannot locate the worktree's admin directory"; return 0; }
  sz=$(module_files_kb "$admin_dir") || { REMOTE_MODULE_FAILED=1; SALVAGE_NOTE="cannot list or size the submodule repositories' files"; return 0; }
  total_kb=$((total_kb + sz))
  # So does the changed and untracked data of each submodule whose work is carried
  # (module_carry_plan summed it while nested_repository_blocker ran, above).
  total_kb=$((total_kb + MODULE_CARRY_KB))
  if [ "$total_kb" -gt "$SALVAGE_MAX_KB" ]; then
    SALVAGE_NOTE="more than ${SALVAGE_MAX_KB} KB of changed or untracked data to salvage"; return 0
  fi
  changed_data_kb "$wt" "$total_kb" || return 0
  # The snapshot must record exactly HEAD's gitlinks (snapshot_tree refuses otherwise), so
  # check the same thing read-only here and dry-run cannot promise a salvage apply refuses.
  gitlink_blocker "$wt" && return 0
  worktree_state_blocker "$wt" && return 0
  conversion_blocker "$wt" && return 0
  return 1
}

# changed_data_kb <checkout> <kb-so-far> -> sets CHANGED_KB to <kb-so-far> plus the size of
# the checkout's changed, untracked and staged data, the bytes a snapshot of it makes
# permanent. Non-zero, with SALVAGE_NOTE, when that passes SALVAGE_MAX_KB, when an untracked
# path is an embedded repository, or on any read failure. Read-only. Used for the worktree
# and for each submodule checkout whose work is carried.
CHANGED_KB=0
changed_data_kb() {
  local wt=$1 total_kb=$2 list rc f sz
  CHANGED_KB=0
  # NUL-delimited: the default output C-quotes unusual names, which would hide them from
  # both the embedded-repository test and the size sum. tr keeps NULs out of $( ).
  # Untracked tool noise is sized as the snapshot takes it: not at all (salvage_pathspec).
  salvage_pathspec "$wt"
  list=$( { git -C "$wt" ls-files -z -m \
            && git -C "$wt" ls-files -z -o --exclude-standard -- "${SALVAGE_PATHSPEC[@]}"; } \
          2>/dev/null | tr '\0' '\n'); rc=$?
  if [ "$rc" -ne 0 ]; then SALVAGE_NOTE="cannot list changed files for salvage"; return 1; fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */) SALVAGE_NOTE="untracked embedded repository ($f) cannot be salvaged"; return 1 ;;
    esac
    [ -f "$wt/$f" ] || continue          # a deletion or a directory holds no bytes here
    sz=$(wc -c < "$wt/$f" 2>/dev/null) || { SALVAGE_NOTE="cannot size $f for salvage"; return 1; }
    sz=$(printf '%s' "$sz" | tr -d ' ')
    total_kb=$((total_kb + (sz + 1023) / 1024))
    if [ "$total_kb" -gt "$SALVAGE_MAX_KB" ]; then
      SALVAGE_NOTE="more than ${SALVAGE_MAX_KB} KB of changed or untracked data to salvage"
      return 1
    fi
  done <<< "$list"
  # The STAGED index is salvaged too (refs/salvaged/<id>/index), and `ls-files -m -o`
  # sees neither index-versus-HEAD changes nor a staged blob the working tree has since
  # overwritten. Size each changed index blob from the object store instead, so a large
  # staged-only addition cannot slip under the cap and be made permanent by a salvage ref.
  # --raw -z alternates a `:modes shas status` field with its path field.
  list=$(git -C "$wt" diff --cached --raw --no-renames --no-abbrev -z 2>/dev/null | tr '\0' '\n'); rc=$?
  if [ "$rc" -ne 0 ]; then SALVAGE_NOTE="cannot list staged changes for salvage"; return 1; fi
  local meta newmode newsha
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    IFS= read -r f || { SALVAGE_NOTE="cannot parse staged changes for salvage"; return 1; }
    # meta: `:oldmode newmode oldsha newsha status`
    # shellcheck disable=SC2086  # split the space-separated metadata field on purpose
    set -- $meta
    newmode=$2; newsha=$4
    case "$newmode" in 000000|160000) continue ;; esac   # a deletion, or a gitlink (no bytes here)
    sz=$(git -C "$wt" cat-file -s "$newsha" 2>/dev/null) || { SALVAGE_NOTE="cannot size staged $f for salvage"; return 1; }
    total_kb=$((total_kb + (sz + 1023) / 1024))
    if [ "$total_kb" -gt "$SALVAGE_MAX_KB" ]; then
      SALVAGE_NOTE="more than ${SALVAGE_MAX_KB} KB of changed or untracked data to salvage"
      return 1
    fi
  done <<< "$list"
  CHANGED_KB=$total_kb
  return 0
}

# resolve_undo_entries <worktree> <file> -> writes one NUL-terminated
# `<mode> <sha>\tstage<N>/<path>` record to <file> for every resolve-undo entry in the index:
# the stages of a conflict that was resolved, which git keeps so the resolution can be
# redone. They are in no tree, and a clean worktree whose merge was committed long ago
# still holds them (#2831). Non-zero when the index cannot be read or a record does not
# parse; an empty <file> means the index holds none.
resolve_undo_entries() {
  local wt=$1 out=$2 raw rec meta path mode sha stage rest
  raw=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-reuc.XXXXXX") || return 1
  if ! git -C "$wt" ls-files -z --resolve-undo > "$raw" 2>/dev/null; then rm -f "$raw"; return 1; fi
  : > "$out" || { rm -f "$raw"; return 1; }
  while IFS= read -r -d '' rec; do
    # rec: `<mode> <sha> <stage>\t<path>`; the path may itself hold tabs.
    meta=${rec%%$'\t'*}; path=${rec#*$'\t'}
    IFS=' ' read -r mode sha stage rest <<< "$meta"
    if [ "$meta" = "$rec" ] || [ -z "$path" ] || [ -n "$rest" ]; then rm -f "$raw"; return 1; fi
    case "$mode" in ''|*[!0-7]*) rm -f "$raw"; return 1 ;; esac
    case "$sha" in ''|*[!0-9a-f]*) rm -f "$raw"; return 1 ;; esac
    case "$stage" in 1|2|3) ;; *) rm -f "$raw"; return 1 ;; esac
    printf '%s %s\tstage%s/%s\0' "$mode" "$sha" "$stage" "$path" >> "$out" || { rm -f "$raw"; return 1; }
  done < "$raw"
  rm -f "$raw"
}

# resolve_undo_kb <worktree> -> prints the size in KB of the blobs the resolve-undo entries
# name, rounded up per blob, so the salvage cap covers what the resolve-undo ref makes
# permanent. Read-only. Non-zero on a read failure.
resolve_undo_kb() {
  local wt=$1 list rec meta mode sha sz kb=0 failed=0
  list=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-reuc-list.XXXXXX") || return 1
  if ! resolve_undo_entries "$wt" "$list"; then rm -f "$list"; return 1; fi
  while IFS= read -r -d '' rec; do
    meta=${rec%%$'\t'*}
    IFS=' ' read -r mode sha <<< "$meta"
    [ "$mode" = 160000 ] && continue                     # a gitlink holds no bytes here
    sz=$(git -C "$wt" cat-file -s "$sha" 2>/dev/null) || { failed=1; break; }
    kb=$((kb + (sz + 1023) / 1024))
  done < "$list"
  rm -f "$list"
  [ "$failed" -eq 0 ] || return 1
  printf '%s\n' "$kb"
}

# tree_kb <worktree> <tree> -> prints the size in KB of every blob in <tree>, rounded up per
# blob. Non-zero on a read failure or a size that does not parse.
tree_kb() {
  local wt=$1 tree=$2 list rec meta mode type sha size kb=0 failed=0
  list=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-tree-list.XXXXXX") || return 1
  if ! git -C "$wt" ls-tree -r -l -z "$tree" > "$list" 2>/dev/null; then rm -f "$list"; return 1; fi
  while IFS= read -r -d '' rec; do
    # rec: `<mode> <type> <sha> <size>\t<path>`, the size padded and `-` for a gitlink.
    meta=${rec%%$'\t'*}
    read -r mode type sha size <<< "$meta"
    [ "$type" = blob ] || continue
    case "$size" in ''|*[!0-9]*) failed=1; break ;; esac
    kb=$((kb + (size + 1023) / 1024))
  done < "$list"
  rm -f "$list"
  [ "$failed" -eq 0 ] || return 1
  printf '%s\n' "$kb"
}

# resolve_undo_tree <worktree> -> sets RESOLVE_UNDO_TREE to a tree holding every resolve-undo
# stage as `stage<N>/<path>`, or to nothing when the index holds none. Built in a temporary
# index, so the worktree's own index is never written. Non-zero on any failure.
resolve_undo_tree() {
  local wt=$1 dir tree
  RESOLVE_UNDO_TREE=""
  dir=$(mktemp -d "${TMPDIR:-/tmp}/wt-salvage-reuc-index.XXXXXX") || return 1
  if ! resolve_undo_entries "$wt" "$dir/entries"; then rm -rf "$dir"; return 1; fi
  if [ ! -s "$dir/entries" ]; then rm -rf "$dir"; return 0; fi
  if ! GIT_INDEX_FILE="$dir/index" git -C "$wt" update-index -z --index-info < "$dir/entries" 2>/dev/null \
     || ! tree=$(GIT_INDEX_FILE="$dir/index" git -C "$wt" write-tree 2>/dev/null) || [ -z "$tree" ]; then
    rm -rf "$dir"; return 1
  fi
  rm -rf "$dir"
  RESOLVE_UNDO_TREE=$tree
}

# --- pristine submodule repositories (#2831) ------------------------------------------
# Salvage records only the parent repository, and the removal deletes every submodule
# repository under the admin directory's modules/ with all it holds. Until now any such
# repository kept the worktree, so nothing in it had to be classified; measured on the host
# 2026-10-12, that kept 12 abandoned worktrees (4.1 GB) whose submodules held nothing.
# A submodule repository is PRISTINE when nothing in it could be work, so the removal loses
# nothing salvage would have had to carry. The test is a whitelist over what the repository
# directory contains, not a list of the ways work can hide in one, so anything unlisted
# keeps the worktree.
# Not compared, and lost with the removal as they are for the worktree's own repository:
# files the checkout ignores, and objects no ref, reflog or pseudo-ref names (a dropped
# stash, an expired reflog entry). Every other file of the repository, whether the check
# accepts it by name or by what it holds, is kept by its bytes (module_files_tree).

# module_origin_url <git-dir> -> prints the origin URL exactly as the repository's own
# config file records it. Not `git remote get-url`, which answers after the host's URL
# rewrites: the question here is what the repository names, and its config file is the one
# place whose keys are held to a whitelist.
module_origin_url() { git config --file "$1/config" --get remote.origin.url 2>/dev/null; }

# module_origin_portfolio <git-dir> — exit 0 only when the repository's origin is a
# devantler-tech repository on GitHub (portfolio_repo). Nothing else is asked or accepted:
#   - a local path can be another view of the repository being removed (a checkout whose
#     .git points back here, an object store borrowed from here), so what it advertises
#     proves no second copy exists;
#   - the URL comes from repository content (.gitmodules), and an unattended sweep must not
#     let content choose where it connects. A portfolio origin is a destination this
#     deployment already reads.
module_origin_portfolio() { [ -n "$(portfolio_repo "$(module_origin_url "$1" || true)")" ]; }

# dir_listable <dir> — exit 0 only when the directory's entries can be read. A glob over a
# directory that cannot be read matches nothing and says nothing: the loop over it runs no
# times, exactly as for an empty directory. Every walk below asks this first.
dir_listable() { [ -d "$1" ] && ls -A "$1" > /dev/null 2>&1; }

# module_state_files <modules-dir> -> prints, NUL-terminated, every file under a modules/
# directory that is not inside a repository's object store. Repositories are found the way
# module_tree_pristine finds them, from the top down: a directory holding a HEAD or an
# objects entry is a repository; its own objects/ entry is left out, its modules/ entry is
# walked the same way, and everything else in it is listed in full. A directory that is not
# a repository is walked for the ones below it. Nothing is recognised by its name alone, so
# a branch namespace that happens to hold entries called HEAD, config and objects is listed
# like any other ref. Non-zero when something cannot be listed.
module_state_files() {
  local dir=$1 entry sub
  dir_listable "$dir" || return 1
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if [ -L "$entry" ] || [ ! -d "$entry" ]; then
      [ -f "$entry" ] && [ ! -L "$entry" ] && printf '%s\0' "$entry"
      continue
    fi
    dir_listable "$entry" || return 1
    if [ -e "$entry/HEAD" ] || [ -L "$entry/HEAD" ] || [ -e "$entry/objects" ] || [ -L "$entry/objects" ]; then
      for sub in "$entry"/* "$entry"/.[!.]* "$entry"/..?*; do
        [ -e "$sub" ] || [ -L "$sub" ] || continue
        case "${sub##*/}" in
          objects) continue ;;
          modules) if [ -d "$sub" ] && [ ! -L "$sub" ]; then module_state_files "$sub" || return 1; fi; continue ;;
        esac
        if [ -d "$sub" ] && [ ! -L "$sub" ]; then
          find "$sub" -type f -print0 2>/dev/null || return 1
        elif [ -f "$sub" ] && [ ! -L "$sub" ]; then
          printf '%s\0' "$sub"
        fi
      done
    else
      module_state_files "$entry" || return 1
    fi
  done
  return 0
}

# modules_fingerprint <admin> -> prints one id for the name, executable bit and bytes of every file under
# the admin directory's modules/ outside the object stores (empty when there is none).
# Taken before the snapshot and compared immediately before the removal: a branch created,
# a setting changed or another commit checked out in a submodule after the snapshot leaves
# the parent's tree and index exactly as snapshotted, and can leave the repository
# pristine too. Non-zero on any read failure.
modules_fingerprint() {
  local admin=$1 names f blob mode
  # An empty or missing admin directory is a lookup that failed in the caller, not a
  # worktree without submodules.
  [ -n "$admin" ] && [ -d "$admin" ] || return 1
  if [ ! -e "$admin/modules" ] && [ ! -L "$admin/modules" ]; then return 0; fi
  [ -d "$admin/modules" ] && [ ! -L "$admin/modules" ] || return 1
  names=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-modules.XXXXXX") || return 1
  if ! module_state_files "$admin/modules" > "$names.raw" || ! LC_ALL=C sort -z < "$names.raw" > "$names"; then
    rm -f "$names.raw"
    rm -f "$names"; return 1
  fi
  rm -f "$names.raw"
  # One record per file: whether it is executable (the one mode bit module_files_tree
  # records), the id of its own bytes, and its name, NUL-terminated. Hashing each file on
  # its own keeps the boundaries: bytes moved from the end of one file to the start of the
  # next would leave a single concatenated stream unchanged.
  : > "$names.records" || { rm -f "$names"; return 1; }
  while IFS= read -r -d '' f; do
    blob=$(git hash-object --no-filters -- "$f" 2>/dev/null) && [ -n "$blob" ] \
      || { rm -f "$names" "$names.records"; return 1; }
    mode=-; [ -x "$f" ] && mode=x
    printf '%s %s %s\0' "$mode" "$blob" "$f" >> "$names.records" || { rm -f "$names" "$names.records"; return 1; }
  done < "$names"
  if ! git hash-object --stdin < "$names.records" 2>/dev/null; then
    rm -f "$names" "$names.records"; return 1
  fi
  rm -f "$names" "$names.records"
}

# module_remote_rows <git-dir> -> sets MODULE_REMOTE_ROWS to what the repository's origin
# advertises right now (`<object id><TAB><ref>` lines; empty for an empty remote). Returns 1
# when the repository names no origin, and 2 when origin could not be read or its answer not
# parsed, which also sets REMOTE_MODULE_FAILED so the sweep ends UNKNOWN. One read per remote
# URL per sweep: every worktree that populated a submodule asks about the same remote. Call
# it from the main shell, never inside $(), or the answers kept for the sweep are dropped.
MODULE_REMOTE_URLS=()
MODULE_REMOTE_ANSWERS=()
MODULE_REMOTE_ROWS=""
MODULE_REMOTE_FRESH=0
REMOTE_MODULE_FAILED=0
module_remote_rows() {
  local g=$1 url rows i=0
  MODULE_REMOTE_ROWS=""
  # Read over HTTPS at the address built from the validated repository name, whichever form
  # the repository's config spells it in. An SSH read would go through the host's OpenSSH
  # configuration, where a Host rule can send github.com anywhere, and that configuration
  # cannot be switched off without losing the key it supplies.
  url=$(portfolio_repo "$(module_origin_url "$g" || true)") && [ -n "$url" ] || return 1
  url="https://github.com/$url.git"
  while [ "$i" -lt "${#MODULE_REMOTE_URLS[@]}" ]; do
    if [ "${MODULE_REMOTE_URLS[$i]}" = "$url" ]; then
      # The check that immediately precedes a removal asks again (MODULE_REMOTE_FRESH): a
      # branch or tag deleted upstream since the kept answer was read is no longer held.
      [ "$MODULE_REMOTE_FRESH" -eq 0 ] || break
      MODULE_REMOTE_ROWS=${MODULE_REMOTE_ANSWERS[$i]}; return 0
    fi
    i=$((i + 1))
  done
  # Asked by the URL that was just validated, with the host's and the environment's git
  # configuration out of the way: a url.<base>.insteadOf rule there would send `origin`
  # somewhere else, a local mirror included, while the repository still names GitHub. The
  # repository's own config holds whitelisted keys only, none of which rewrites a URL.
  # The environment is rebuilt from a short list as well: a proxy, a certificate bundle, an
  # SSH command or a config override inherited by the sweep would each choose what answers.
  # The one credential source is gh, for a private repository; without gh a private one
  # cannot be read, which keeps its worktree.
  local helper=()
  [ -z "$GH_BIN" ] || helper=(-c "credential.https://github.com.helper=!$GH_BIN auth git-credential")
  rows=$(run_bounded env -i PATH="$PATH" HOME="${HOME:-}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
         TMPDIR="${TMPDIR:-/tmp}" \
         GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
         git --git-dir="$g" --work-tree="$g" -c credential.helper= ${helper[@]+"${helper[@]}"} \
         ls-remote -- "$url") \
    || { REMOTE_MODULE_FAILED=1; return 2; }
  # An answer holding anything but advertised lines is one this could not read.
  if [ -n "$rows" ] && grep -Evq '^([0-9a-f]{40}|[0-9a-f]{64})	[^	]+$' <<< "$rows"; then
    REMOTE_MODULE_FAILED=1; return 2
  fi
  MODULE_REMOTE_URLS[i]=$url; MODULE_REMOTE_ANSWERS[i]=$rows
  MODULE_REMOTE_ROWS=$rows
}

# module_held_by_remote <git-dir> — exit 0 when origin, as it answers right now, holds
# everything the repository's refs and reflogs reach; 1 with MODULE_NOTE when it does not;
# 2 when origin could not be read. Reads MODULE_REMOTE_ROWS (module_remote_rows first).
# The local remote-tracking refs are NOT the evidence: one can be stale (its branch deleted
# upstream) or written by hand, and unlike the worktree's own repository, nothing of a
# submodule repository survives the removal. So:
#   - every local tag is advertised at exactly the same object (an annotated tag made here
#     is an object no clone would bring back, even on a pushed commit);
#   - every commit a ref or reflog reaches is reachable from a commit origin advertises: a
#     branch, a tag, or a pull request's head, which GitHub keeps after its branch is gone.
# A clone that has not fetched for weeks does not hold the commits origin advertises today,
# so its own branch tips cannot be shown reachable from them locally. Each such tip is asked
# about instead (module_tip_behind_remote), newest first as in
# submodule_repository_disposable, and at most SUBMODULE_TIP_LIMIT of them.
module_held_by_remote() {
  local g=$1 local_tags missing ids held tip asked=0 rc
  local_tags=$(module_git "$g" for-each-ref --format='%(objectname)%09%(refname)' refs/tags 2>/dev/null) || return 2
  if [ -n "$local_tags" ]; then
    missing=$(awk 'NR == FNR { held[$0]; next } NF && !($0 in held)' \
              <(printf '%s\n' "$MODULE_REMOTE_ROWS") <(printf '%s\n' "$local_tags")) || return 2
    if [ -n "$missing" ]; then MODULE_NOTE="it holds a tag its remote lacks"; return 1; fi
  fi
  # Advertised ids this store holds as commits. An annotated tag is advertised twice, the
  # second time peeled (`^{}`) to its commit, so tag objects themselves are not needed.
  ids=$(awk -F'\t' 'NF == 2 { print $1 }' <<< "$MODULE_REMOTE_ROWS" | sort -u) || return 2
  held=""
  if [ -n "$ids" ]; then
    held=$(module_git "$g" cat-file --batch-check='%(objectname) %(objecttype)' <<< "$ids" 2>/dev/null \
           | awk '$2 == "commit" { print "^" $1 }') || return 2
  fi
  while :; do
    # No blank line may reach --stdin, and `held` is empty for an empty remote.
    tip=$(module_git "$g" rev-list --topo-order --max-count=1 --all --reflog --stdin \
          < <(grep . <<< "$MODULE_LOG_IDS"$'\n'"$MODULE_PACKED_IDS"$'\n'"$held" || true) 2>/dev/null) || return 2
    [ -n "$tip" ] || return 0
    asked=$((asked + 1))
    if [ "$asked" -gt "$SUBMODULE_TIP_LIMIT" ]; then
      MODULE_NOTE="it holds more than $SUBMODULE_TIP_LIMIT tips its remote does not advertise"; return 1
    fi
    module_tip_behind_remote "$g" "$tip"; rc=$?
    case "$rc" in
      0) held="$held"$'\n'"^$tip" ;;
      1) MODULE_NOTE="it holds commit(s) its remote does not advertise (${tip:0:12})"; return 1 ;;
      # Kept without evidence either way, so the sweep must not end as a clean pass.
      *) REMOTE_MODULE_FAILED=1
         MODULE_NOTE="cannot ask GitHub whether its remote still holds ${tip:0:12}"; return 1 ;;
    esac
  done
}

# module_gh <gh args...> — gh under the deadline, in an environment rebuilt from a short list:
# Go's HTTP stack takes a proxy and a certificate bundle from the environment (HTTPS_PROXY,
# SSL_CERT_FILE), and gh takes its host, token and config directory from it, so anything
# the sweep inherited could choose what answers. gh's own stored login is what remains.
module_gh() {
  run_bounded env -i PATH="$PATH" HOME="${HOME:-}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
    TMPDIR="${TMPDIR:-/tmp}" "$GH_BIN" "$@"
}

# module_descends <owner/repo> <commit> <advertised-commit> — exit 0 when GitHub says the
# advertised commit descends from <commit> or is it; 1 when it does not, or has never
# received <commit>; 2 when GitHub could not be asked. Definitive answers are kept for the
# sweep: every worktree's clone of a submodule lags its remote the same way.
MODULE_COMPARE_ANSWERS=$'\n'
module_descends() {
  local repo=$1 tip=$2 adv=$3 out rc key="$1 $2 $3"
  case "$MODULE_COMPARE_ANSWERS" in
    *$'\n'"$key 0"$'\n'*) return 0 ;;
    *$'\n'"$key 1"$'\n'*) return 1 ;;
  esac
  # Asked of github.com by name: an inherited GH_HOST would send the question elsewhere.
  # compare/<base>...<head> reports the head relative to the base: `ahead` or `identical`
  # means the advertised commit contains <commit>.
  out=$(module_gh api --hostname github.com "repos/$repo/compare/$tip...$adv" --jq '.status'); rc=$?
  if [ "$rc" -eq 0 ]; then
    case "$out" in
      ahead|identical) rc=0 ;;
      behind|diverged) rc=1 ;;
      *) return 2 ;;
    esac
  else
    # GitHub answers a commit it has never received with a definitive 404, whose error body
    # gh prints on stdout. Any other failure, a timeout included, stays unknown.
    case "$out" in *'"status":"404"'*) rc=1 ;; *) return 2 ;; esac
  fi
  MODULE_COMPARE_ANSWERS="$MODULE_COMPARE_ANSWERS$key $rc"$'\n'
  return "$rc"
}

# module_tip_behind_remote <git-dir> <commit> — exit 0 when GitHub says something origin
# advertises right now descends from <commit>; 1 when nothing asked about does (the commit
# was rewritten away upstream, or never pushed) or the remote is not a portfolio
# repository; 2 when GitHub could not be asked. Reads MODULE_REMOTE_ROWS. Asked about, in
# order:
#   - the branch of the same name as each local remote-tracking ref that reaches the commit
#     (up to three), and origin's HEAD: a clone that fell behind a branch that moved on;
#   - the head of each pull request GitHub associates with the commit (up to five), and only
#     when origin advertises that head as refs/pull/<n>/head: an earlier push of a branch
#     that was merged and deleted. GitHub keeps that ref after the branch is gone.
MODULE_GH_SOCKET=""
MODULE_PULLS_KEYS=()
MODULE_PULLS_ROWS=()
module_tip_behind_remote() {
  local g=$1 tip=$2 repo names name adv rc unknown=0 rows number head
  repo=$(portfolio_repo "$(module_origin_url "$g" || true)")
  [ -n "$repo" ] || return 1
  [ -n "$GH_BIN" ] || return 2
  # gh can be told to send its requests somewhere else: through a Unix socket
  # (http_unix_socket), to another API host (api_host), from its config or a GH_CONFIG_DIR
  # the sweep inherited. Whatever answers there would be what vouches for a commit, so with
  # any setting whose name speaks of a socket, a host or a proxy set, nothing is asked. A
  # read that failed says nothing about the settings, so nothing is asked then either.
  # Read once per sweep.
  if [ -z "$MODULE_GH_SOCKET" ]; then
    local settings
    settings=$(module_gh config list --host github.com) || return 2
    [ -n "$settings" ] || return 2
    if grep -Eiq '^[^=]*(socket|host|proxy)[^=]*=.' <<< "$settings"; then MODULE_GH_SOCKET="set"; else MODULE_GH_SOCKET="none"; fi
  fi
  [ "$MODULE_GH_SOCKET" = none ] || return 2
  names=$(module_git "$g" for-each-ref --contains "$tip" --format='%(refname)' refs/remotes/origin 2>/dev/null) || return 2
  names=$(sed -n 's#^refs/remotes/origin/#refs/heads/#p' <<< "$names" | sed -n '1,3p')
  # A ref name holds no whitespace, so the list splits safely.
  for name in $names HEAD; do
    adv=$(awk -F'\t' -v r="$name" '$2 == r { print $1; exit }' <<< "$MODULE_REMOTE_ROWS")
    if [ -z "$adv" ] || [ "$adv" = "$tip" ]; then continue; fi
    module_descends "$repo" "$tip" "$adv"; rc=$?
    case "$rc" in 0) return 0 ;; 1) ;; *) unknown=1 ;; esac
  done
  # Which pull requests hold a commit is kept for the sweep like the comparisons, so the
  # check repeated before a removal asks nothing it was already told.
  local i=0 known=0
  while [ "$i" -lt "${#MODULE_PULLS_KEYS[@]}" ]; do
    if [ "${MODULE_PULLS_KEYS[$i]}" = "$repo $tip" ]; then rows=${MODULE_PULLS_ROWS[$i]}; known=1; break; fi
    i=$((i + 1))
  done
  if [ "$known" -eq 0 ]; then
    rows=$(module_gh api --hostname github.com --paginate "repos/$repo/commits/$tip/pulls" --jq '.[] | "\(.number)\t\(.head.sha)"'); rc=$?
    if [ "$rc" -ne 0 ]; then
      # As in submodule_head_spent: a commit GitHub has never received is a definitive 422.
      case "$rows" in *"No commit found for SHA: $tip\""*) rows="" ;; *) return 2 ;; esac
    fi
    MODULE_PULLS_KEYS[i]="$repo $tip"; MODULE_PULLS_ROWS[i]=$rows
  fi
  while IFS=$'\t' read -r number head; do
    [ -n "$number" ] || continue
    case "$number" in *[!0-9]*) continue ;; esac
    adv=$(awk -F'\t' -v r="refs/pull/$number/head" '$2 == r { print $1; exit }' <<< "$MODULE_REMOTE_ROWS")
    if [ -z "$adv" ] || [ "$adv" != "$head" ]; then continue; fi
    module_descends "$repo" "$tip" "$adv"; rc=$?
    case "$rc" in 0) return 0 ;; 1) ;; *) unknown=1 ;; esac
  done <<< "$(sed -n '1,5p' <<< "$rows")"
  [ "$unknown" -eq 0 ] || return 2
  return 1
}

# module_config_pristine <file> <allowed-keys-pattern> — exit 0 when every key in that
# config file matches the extended regular expression; 1, with MODULE_NOTE naming the first
# other key, when one does not; 2 when the file cannot be read. Read with --file, so an
# include is a key like any other (and not followed).
module_config_pristine() {
  local file=$1 allowed=$2 keys other
  keys=$(git config --file "$file" --name-only --list -z 2>/dev/null | tr '\0\n' '\n\001') || return 2
  case "$keys" in *$'\001'*) MODULE_NOTE="a configuration key holds a newline"; return 1 ;; esac
  other=$(grep -Ev "^($allowed)\$" <<< "$keys" | grep -v '^$' | head -1) || true
  if [ -n "$other" ]; then MODULE_NOTE="its configuration sets $other"; return 1; fi
  return 0
}

# module_commit_editmsg_spent <git-dir> — exit 0 when COMMIT_EDITMSG is absent, empty, or the
# message of a commit the HEAD reflog names (the newest 50 ids are tried). Every commit made
# in a submodule leaves the file behind, and those commits are checked against the remote
# separately; a message that matches none of them is a draft that was never committed.
module_commit_editmsg_spent() {
  local g=$1 f="$1/COMMIT_EDITMSG" want ids id got unread=0
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 0; fi
  # From here a read that fails is 2, not 1: a message that could not be compared is not a
  # draft that was found.
  [ -r "$f" ] || return 2
  want=$(git stripspace --strip-comments < "$f" 2>/dev/null) || return 2
  [ -n "$want" ] || return 0
  if [ ! -e "$g/logs/HEAD" ] && [ ! -L "$g/logs/HEAD" ]; then return 1; fi
  [ -f "$g/logs/HEAD" ] && [ ! -L "$g/logs/HEAD" ] || return 1
  [ -r "$g/logs/HEAD" ] || return 2
  ids=$(awk '{ print $2; print $1 }' "$g/logs/HEAD") || return 2
  ids=$(grep -E '^([0-9a-f]{40}|[0-9a-f]{64})$' <<< "$ids" | grep -Ev '^0+$' \
        | awk '{ line[NR] = $0 } END { for (i = NR; i >= 1; i--) if (!seen[line[i]]++) print line[i] }' \
        | sed -n '1,50p') || true
  for id in $ids; do
    # An id whose object is gone has no message to compare; one that is there and cannot be
    # shown is a failed read.
    module_git "$g" cat-file -e "$id" 2>/dev/null || continue
    got=$(module_git "$g" show -s --format=%B "$id" 2>/dev/null) || { unread=1; continue; }
    got=$(git stripspace --strip-comments <<< "$got" 2>/dev/null) || { unread=1; continue; }
    [ "$got" = "$want" ] && return 0
  done
  [ "$unread" -eq 0 ] || return 2
  return 1
}

# checkout_matches_index <checkout> — exit 0 when every regular file the index tracks hashes,
# as `git add` would store it, to the blob the index records; 1 when one does not or is
# missing; 2 when that cannot be read. Status answers the same question from the file's
# size and times, and trusts them: with core.trustctime=false in the host's configuration, an
# edit that keeps a file's size and puts its mtime back reads as unchanged. A symbolic link
# is compared by its target, which is what its blob holds. A gitlink holds no bytes here.
checkout_matches_index() {
  local co=$1 entries paths want got all links meta path target
  all=$(git -C "$co" ls-files -s -z 2>/dev/null | tr '\0\n' '\n\001') || return 2
  case "$all" in *$'\001'*) return 2 ;; esac
  links=$(awk -F'\t' '$1 ~ /^120000 /' <<< "$all") || return 2
  while IFS=$'\t' read -r meta path; do
    [ -n "$meta" ] || continue
    [ -L "$co/$path" ] || return 1
    target=$(readlink "$co/$path" 2>/dev/null) || return 2
    # shellcheck disable=SC2086  # meta is `mode sha stage`
    set -- $meta
    [ "$(printf '%s' "$target" | git hash-object --stdin 2>/dev/null)" = "$2" ] || return 1
  done <<< "$links"
  entries=$all
  entries=$(awk -F'\t' '$1 ~ /^100(644|755) /' <<< "$entries") || return 2
  [ -n "$entries" ] || return 0
  paths=$(sed 's/^[^	]*	//' <<< "$entries")
  want=$(awk '{ print $2 }' <<< "$entries")
  # A missing file makes hash-object fail, which is a difference, not an unreadable index.
  got=$(cd "$co" 2>/dev/null && git hash-object --stdin-paths <<< "$paths" 2>/dev/null) || return 1
  [ "$got" = "$want" ] || return 1
  return 0
}

# module_checkout <git-dir> <worktree-realpath> -> sets MODULE_CHECKOUT to the physical path
# of the repository's checkout. Exit 1 when the repository has no checkout that is a
# directory inside the worktree whose .git is a plain file naming exactly this repository:
# one checked out elsewhere, or not at all, holds an index nothing here can compare with a
# working tree. Exit 2 when that could not be established because something that exists
# could not be read; the caller reports that as unread, not as "no checkout".
MODULE_CHECKOUT=""
module_checkout() {
  local g=$1 wt_real=$2 rel="" co back g_real f rc
  MODULE_CHECKOUT=""
  # Read from the files themselves: `git config` on the repository changes into its work
  # tree first and fails outright when that is gone, which is the ordinary "no checkout".
  # `config --get` answers 1 for a key that is not set and anything else for a failed read.
  for f in "$g/config.worktree" "$g/config"; do
    [ -e "$f" ] || continue
    rel=$(git config --file "$f" --get core.worktree 2>/dev/null); rc=$?
    case "$rc" in 0) [ -z "$rel" ] || break ;; 1) rel="" ;; *) return 2 ;; esac
  done
  [ -n "$rel" ] || return 1
  case "$rel" in /*) co=$rel ;; *) co="$g/$rel" ;; esac
  if [ ! -e "$co" ] && [ ! -L "$co" ]; then return 1; fi
  # Something that is there but is no directory (the submodule replaced by a file) is not a
  # checkout either.
  [ -d "$co" ] || return 1
  co=$(physical_path "$co") || return 2
  case "$co/" in "$wt_real"/?*) ;; *) return 1 ;; esac
  if [ ! -e "$co/.git" ] && [ ! -L "$co/.git" ]; then return 1; fi
  [ -f "$co/.git" ] && [ ! -L "$co/.git" ] || return 1
  back=$(git -C "$co" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$back" ] || return 2
  back=$(physical_path "$back") || return 2
  g_real=$(physical_path "$g") || return 2
  [ "$back" = "$g_real" ] || return 1
  MODULE_CHECKOUT=$co
}

# module_repository_pristine <git-dir> <worktree-realpath> <admin> — exit 0 when the
# submodule repository is pristine (see above); 1 with MODULE_NOTE saying what is not. Any
# read failure is a 1. On success the checkout is added to VERIFIED_CHECKOUTS. <admin> is
# the worktree's admin directory, which only names its own submodules' repositories in a note.
# A fourth argument `carry` asks the other question (module_tree_pristine asks it only of a
# repository that is not pristine, and only when module_durable found where its work can
# go): can everything in it that is not pristine be CARRIED? Then the checks that find
# work no longer fail; they note it. Uncommitted and untracked files in the checkout, a
# commit or tag the remote does not advertise, and a drafted commit message are carried or
# kept by their bytes (module_carry_plan, module_files_tree). Every check about the
# repository's shape, its configuration and what status can see still fails as before.
MODULE_NOTE=""
VERIFIED_CHECKOUTS=""
MODULE_LOG_IDS=""
MODULE_PACKED_IDS=""
module_repository_pristine() {
  local g=$1 wt_real=$2 entry name co out ids rc line carry=0 carry_ids=""
  [ "${4:-}" != carry ] || carry=1
  MODULE_NOTE=""
  MODULE_LOG_IDS=""
  MODULE_PACKED_IDS=""
  dir_listable "$g" || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="it cannot be listed"; return 1; }
  for name in hooks info branches; do
    if [ -e "$g/$name" ] && [ ! -L "$g/$name" ] && [ -d "$g/$name" ] && ! dir_listable "$g/$name"; then
      REMOTE_MODULE_FAILED=1; MODULE_NOTE="its $name cannot be listed"; return 1
    fi
  done
  # 1. Every entry of the repository directory is one git itself writes into a clone, and
  #    of the kind git writes. An operation in progress, a bisect log, a per-repository
  #    worktree, a split index and anything else unlisted is state nothing here inspects.
  for entry in "$g"/* "$g"/.[!.]* "$g"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      HEAD|config|config.worktree|description|index|packed-refs|FETCH_HEAD|ORIG_HEAD|COMMIT_EDITMSG)
        [ -f "$entry" ] && [ ! -L "$entry" ] || { MODULE_NOTE="its $name is not a plain file"; return 1; } ;;
      hooks|info|logs|refs|objects|branches|modules)
        [ -d "$entry" ] && [ ! -L "$entry" ] || { MODULE_NOTE="its $name is not a plain directory"; return 1; } ;;
      *) MODULE_NOTE="it holds $name"; return 1 ;;
    esac
  done
  [ -f "$g/HEAD" ] && [ -f "$g/config" ] && [ -d "$g/objects" ] \
    || { MODULE_NOTE="it lacks a HEAD, config or object store"; return 1; }
  # 2. hooks/ holds git's own samples only; info/ only an exclude file with no rule of its own;
  #    branches/ nothing; and the object store borrows from no other.
  for entry in "$g/hooks"/* "$g/hooks"/.[!.]* "$g/hooks"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "${entry##*/}" in
      *.sample) [ -f "$entry" ] && [ ! -L "$entry" ] || { MODULE_NOTE="hooks/${entry##*/} is not a plain file"; return 1; } ;;
      *) MODULE_NOTE="it holds the hook ${entry##*/}"; return 1 ;;
    esac
  done
  for entry in "$g/info"/* "$g/info"/.[!.]* "$g/info"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if [ "${entry##*/}" != exclude ] || [ ! -f "$entry" ] || [ -L "$entry" ]; then
      MODULE_NOTE="it holds info/${entry##*/}"; return 1
    fi
    # The one rule allowed is the one worktree-claim.sh appends for its ownership marker
    # (229 submodule repositories on the host carried it, measured 2026-10-12).
    out=$(grep -Ev '^[[:space:]]*(#.*)?$' "$entry" | grep -vxF "/$WORKTREE_CLAIM_MARKER_NAME*" | head -1) || true
    if [ -n "$out" ]; then MODULE_NOTE="its info/exclude holds a rule of its own"; return 1; fi
  done
  for entry in "$g/branches"/* "$g/branches"/.[!.]* "$g/branches"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    MODULE_NOTE="it holds branches/${entry##*/}"; return 1
  done
  for name in alternates http-alternates; do
    if [ -e "$g/objects/info/$name" ] || [ -L "$g/objects/info/$name" ]; then
      MODULE_NOTE="its object store borrows from another (objects/info/$name)"; return 1
    fi
  done
  # 3. Its configuration is what a clone and a submodule checkout write, plus an identity.
  #    A filter, a hooks path, a second remote or an include is not.
  local keys='core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode|worktree)|extensions\.worktreeconfig|remote\.origin\.(url|fetch)|branch\..*\.(remote|merge)|submodule\..*\.(url|active)|user\.(name|email)'
  module_config_pristine "$g/config" "$keys"; rc=$?
  case "$rc" in 0) ;; 1) return 1 ;; *) REMOTE_MODULE_FAILED=1; MODULE_NOTE="its configuration cannot be read"; return 1 ;; esac
  if [ -e "$g/config.worktree" ]; then
    module_config_pristine "$g/config.worktree" 'core\.worktree'; rc=$?
    case "$rc" in 0) ;; 1) return 1 ;; *) REMOTE_MODULE_FAILED=1; MODULE_NOTE="its config.worktree cannot be read"; return 1 ;; esac
  fi
  if [ "$(git config --file "$g/config" --bool --get core.bare 2>/dev/null || true)" = true ]; then
    MODULE_NOTE="it is configured bare"; return 1
  fi
  # 4. It is checked out inside this worktree, and that checkout holds no change: none
  #    status reports, none an index flag hides, none a filter or conversion hides, and no
  #    resolve-undo stage (which is in no tree).
  module_checkout "$g" "$wt_real"; rc=$?
  case "$rc" in
    0) ;;
    1) MODULE_NOTE="it has no checkout inside the worktree"; return 1 ;;
    *) REMOTE_MODULE_FAILED=1; MODULE_NOTE="its checkout cannot be resolved"; return 1 ;;
  esac
  co=$MODULE_CHECKOUT
  out=$(git -C "$co" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its checkout's status cannot be read"; return 1; }
  if [ -n "$out" ] && [ "$carry" -eq 0 ]; then MODULE_NOTE="its checkout holds changes"; return 1; fi
  out=$(git -C "$co" ls-files -v 2>/dev/null) || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its index flags cannot be read"; return 1; }
  if grep -q '^[a-zS]' <<< "$out"; then
    MODULE_NOTE="its index hides files from status (assume-unchanged or skip-worktree)"; return 1
  fi
  out=$(git -C "$co" ls-files --resolve-undo 2>/dev/null) || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its resolve-undo entries cannot be read"; return 1; }
  if [ -n "$out" ]; then MODULE_NOTE="its index holds resolve-undo entries"; return 1; fi
  checkout_matches_index "$co"; rc=$?
  case "$rc" in
    0) ;;
    # Carried: the snapshot hashes every file afresh (snapshot_tree starts from an index
    # with no file times in it), so an edit status cannot see is in the tree it records.
    1) [ "$carry" -eq 1 ] || { MODULE_NOTE="a tracked file in its checkout differs from the index"; return 1; } ;;
    *) REMOTE_MODULE_FAILED=1; MODULE_NOTE="its checkout cannot be compared with its index"; return 1 ;;
  esac
  # A nested submodule that was never initialised is a plain directory to git: status calls
  # the outer checkout clean whatever is dropped into it, and nothing else looks there. An
  # initialised one has a .git, and its repository is checked in 9 like this one.
  out=$(git -C "$co" ls-files -s -z 2>/dev/null | tr '\0\n' '\n\001') \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its index cannot be read"; return 1; }
  case "$out" in *$'\001'*) MODULE_NOTE="a path in its index holds a newline"; return 1 ;; esac
  # The path is everything after the FIRST tab: a path can hold tabs of its own.
  out=$(grep '^160000 ' <<< "$out" | sed 's/^[^	]*	//') || true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -e "$co/$line/.git" ] || [ -L "$co/$line/.git" ]; then continue; fi
    if [ -L "$co/$line" ] || { [ -e "$co/$line" ] && [ ! -d "$co/$line" ]; }; then
      MODULE_NOTE="its nested submodule path $line is not a directory"; return 1
    fi
    if [ -d "$co/$line" ] && [ -n "$(ls -A "$co/$line" 2>/dev/null || echo unreadable)" ]; then
      MODULE_NOTE="its uninitialised nested submodule directory $line is not empty"; return 1
    fi
  done <<< "$out"
  local saved_note=$SALVAGE_NOTE
  if conversion_blocker "$co"; then
    # Its `cannot ...` notes are reads that failed, not conversions found.
    case "$SALVAGE_NOTE" in cannot*) REMOTE_MODULE_FAILED=1 ;; esac
    MODULE_NOTE="in its checkout, $SALVAGE_NOTE"; SALVAGE_NOTE=$saved_note; return 1
  fi
  SALVAGE_NOTE=$saved_note
  # 5. Its refs are branches, remote-tracking refs and tags, each a plain file or packed;
  #    a stash, a replace ref, notes or a bisect ref is none of those. Every reflog is a
  #    plain file too: git reads through a symlinked one, and the walk below would not.
  out=""
  for name in logs refs; do
    [ -d "$g/$name" ] || continue
    out=$(find "$g/$name" ! -type d ! -type f -print 2>/dev/null) \
      || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its $name cannot be listed"; return 1; }
    [ -z "$out" ] || break
  done
  if [ -n "$out" ]; then MODULE_NOTE="a ref or reflog of it is not a plain file"; return 1; fi
  # packed-refs first, by its shape: a record git cannot parse is left out of every listing
  # (with a warning, or by failing the listing, depending on the version of git), and such a
  # record can be the only thing that names a commit. A record is `<id> <refname>`, and no
  # ref name holds a space; a `^<id>` line peels the annotated tag above it.
  if [ -e "$g/packed-refs" ]; then
    [ -r "$g/packed-refs" ] || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its packed-refs cannot be read"; return 1; }
    out=$(grep -Ev '^(#.*|\^[0-9a-f]{40,64}|[0-9a-f]{40,64} refs/[^ ]+)$' "$g/packed-refs" | sed -n '1p') || true
    if [ -n "$out" ]; then MODULE_NOTE="its packed-refs holds a malformed record"; return 1; fi
  fi
  out=$(module_git "$g" for-each-ref --format='%(refname)' 2>/dev/null) \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its refs cannot be read"; return 1; }
  out=$(grep -Ev '^refs/(heads|remotes|tags)/' <<< "$out" | grep -v '^$' | head -1) || true
  if [ -n "$out" ]; then MODULE_NOTE="it holds the ref $out"; return 1; fi
  # A tag ref may name a tag object, which is compared with the remote's. HEAD and every
  # other ref must name a commit: the walk in 8 peels a tag object to its commit, so a tag
  # object only such a ref names would be lost unseen.
  out=$(module_git "$g" for-each-ref --format='%(objecttype) %(refname)' refs/heads refs/remotes 2>/dev/null) \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its refs cannot be read"; return 1; }
  out=$(awk 'NF && $1 != "commit" { print $2; exit }' <<< "$out")
  if [ -n "$out" ]; then MODULE_NOTE="its ref $out names an object that is not a commit"; return 1; fi
  out=$(module_git "$g" rev-parse --verify --quiet HEAD 2>/dev/null) && [ -n "$out" ] \
    && [ "$(module_git "$g" cat-file -t "$out" 2>/dev/null)" = commit ] \
    || { MODULE_NOTE="its HEAD names no commit"; return 1; }
  # Every file under refs/ is a ref git enumerates, and every file under logs/ the reflog of
  # one (or of HEAD). A leftover lock or scratch file there can hold the only pointer to a
  # commit, and neither for-each-ref nor the walk below would ever look at it.
  local refnames stray
  refnames=$(module_git "$g" for-each-ref --format='%(refname)' 2>/dev/null) || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its refs cannot be read"; return 1; }
  for name in refs logs; do
    [ -d "$g/$name" ] || continue
    # Listed relative to the repository (refs/...) or to logs/ (HEAD, refs/...), so each
    # line is a ref name as for-each-ref spells it.
    if [ "$name" = refs ]; then
      stray=$(cd "$g" 2>/dev/null && find refs -type f -print0 2>/dev/null | tr '\0\n' '\n\001') || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its refs cannot be listed"; return 1; }
    else
      stray=$(cd "$g/logs" 2>/dev/null && find . -type f -print0 2>/dev/null | tr '\0\n' '\n\001' | sed 's#^\./##') || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its logs cannot be listed"; return 1; }
    fi
    # Listed NUL-terminated and read by line: a name holding a newline would otherwise fall
    # apart into lines that can each be the name of a real ref. No ref name holds one.
    case "$stray" in *$'\001'*) MODULE_NOTE="its $name holds a file whose name holds a newline"; return 1 ;; esac
    [ -n "$stray" ] || continue
    stray=$(awk 'NR == FNR { known[$0]; next } NF && !($0 in known) && $0 != "HEAD"' \
            <(printf '%s\n' "$refnames") <(printf '%s\n' "$stray") | sed -n '1p') \
      || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its $name cannot be compared with its refs"; return 1; }
    if [ -n "$stray" ]; then MODULE_NOTE="its $name holds a file that is no ref ($stray)"; return 1; fi
  done
  # packed-refs holds refs too, and git drops a record it cannot parse from every listing
  # with only a warning. Each record is `<id> <refname>`, or a peeled `^<id>` under an
  # annotated tag; the name of every one must be a ref that was enumerated above.
  if [ -e "$g/packed-refs" ]; then
    [ -r "$g/packed-refs" ] || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its packed-refs cannot be read"; return 1; }
    stray=$(awk 'NR == FNR { known[$0]; next }
                 /^#/ || /^\^[0-9a-f]+$/ || /^$/ { next }
                 { name = $0; sub(/^[0-9a-f]+ /, "", name)
                   if (name == $0 || !(name in known)) { print; exit } }' \
            <(printf '%s\n' "$refnames") "$g/packed-refs") \
      || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its packed-refs cannot be read"; return 1; }
    if [ -n "$stray" ]; then MODULE_NOTE="its packed-refs holds an entry git does not list as a ref"; return 1; fi
    # The ids are checked as well as the names. A record under a loose ref of the same name is
    # stale and names whatever the ref pointed at before, and a `^<id>` line is trusted by
    # nothing here to be the peel of the tag above it. So every id the file holds is either a
    # commit, handed to the remote check in 8 by name, or a tag object that some tag ref
    # points at (those are compared with the remote's); anything else keeps the worktree.
    local packed_ids tag_ids
    packed_ids=$(sed -n -e 's/^\([0-9a-f]\{40,64\}\) .*/\1/p' -e 's/^\^\([0-9a-f]\{40,64\}\)$/\1/p' "$g/packed-refs" | sort -u) \
      || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its packed-refs cannot be read"; return 1; }
    if [ -n "$packed_ids" ]; then
      tag_ids=$(module_git "$g" for-each-ref --format='%(objectname)' refs/tags 2>/dev/null) \
        || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its tags cannot be read"; return 1; }
      out=$(module_git "$g" cat-file --batch-check='%(objectname) %(objecttype)' <<< "$packed_ids" 2>/dev/null) \
        || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its packed-refs objects cannot be read"; return 1; }
      stray=$(awk 'NR == FNR { if (NF) tags[$1]; next }
                   NF != 2 { print; exit }
                   $2 == "commit" || $2 == "missing" { next }
                   $2 == "tag" && ($1 in tags) { next }
                   { print; exit }' <(printf '%s\n' "$tag_ids") <(printf '%s\n' "$out")) \
        || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its packed-refs objects cannot be read"; return 1; }
      if [ -n "$stray" ]; then MODULE_NOTE="its packed-refs names an object no ref accounts for"; return 1; fi
      MODULE_PACKED_IDS=$(awk 'NF == 2 && $2 == "commit" { print $1 }' <<< "$out")
    fi
  fi
  # 6. Everything a reflog, ORIG_HEAD or FETCH_HEAD names is a commit (a tag object named
  #    only there would be lost unseen), and the pseudo-refs' commits are on the remote.
  #    The reflogs' commits are covered by the remote check in 8.
  if [ -d "$g/logs" ]; then
    ids=$(find "$g/logs" -type f -exec awk '{ print tolower($1); print tolower($2) }' {} + 2>/dev/null) \
      || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its reflogs cannot be read"; return 1; }
    if [ -n "$ids" ]; then
      if grep -Evq '^([0-9a-f]{40}|[0-9a-f]{64})$' <<< "$ids"; then MODULE_NOTE="a reflog of it is malformed"; return 1; fi
      ids=$(grep -Ev '^0+$' <<< "$ids" | sort -u)
      if [ -n "$ids" ]; then
        out=$(module_git "$g" cat-file --batch-check='%(objectname) %(objecttype)' <<< "$ids" 2>/dev/null) \
          || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its reflog objects cannot be read"; return 1; }
        # Kept for 8: git drops a reflog line whose metadata it cannot parse from its own
        # walk, ids and all, so each id read here is handed to the remote check by name.
        MODULE_LOG_IDS=$(awk 'NF == 2 && $2 == "commit" { print $1 }' <<< "$out")
        out=$(awk 'NF != 2 || ($2 != "commit" && $2 != "missing") { print; exit }' <<< "$out")
        if [ -n "$out" ]; then MODULE_NOTE="a reflog of it names an object that is not a commit"; return 1; fi
      fi
    fi
  fi
  ids=$(pseudo_ref_commits "$g") || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its ORIG_HEAD or FETCH_HEAD cannot be read"; return 1; }
  if [ -n "$ids" ]; then
    for line in $ids; do
      [ "$(module_git "$g" cat-file -t "$line" 2>/dev/null)" = commit ] \
        || { MODULE_NOTE="its ORIG_HEAD or FETCH_HEAD names an object that is not a commit"; return 1; }
    done
    # shellcheck disable=SC2086  # one sha per word
    out=$(module_git "$g" rev-list --no-walk $ids --not --remotes 2>/dev/null) \
      || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its ORIG_HEAD or FETCH_HEAD commits cannot be checked"; return 1; }
    if [ -n "$out" ] && [ "$carry" -eq 0 ]; then MODULE_NOTE="its ORIG_HEAD or FETCH_HEAD names a commit its remote lacks"; return 1; fi
    # Carried: handed to the remote comparison in 8 by name, like the reflogs' commits.
    carry_ids=$ids
  fi
  # 7. A COMMIT_EDITMSG is the message of a commit already made, not a draft.
  module_commit_editmsg_spent "$g"; rc=$?
  case "$rc" in
    0) ;;
    # Carried: a draft is kept by its bytes with the repository's other files (module_files_tree).
    1) [ "$carry" -eq 1 ] || { MODULE_NOTE="its COMMIT_EDITMSG is not the message of a commit it made"; return 1; } ;;
    *) REMOTE_MODULE_FAILED=1; MODULE_NOTE="its COMMIT_EDITMSG cannot be compared with its commits"; return 1 ;;
  esac
  # 8. Every commit a ref or reflog reaches, and every tag, is held by the remote as it
  #    answers now (module_held_by_remote).
  module_origin_portfolio "$g" || { MODULE_NOTE="its origin is not a portfolio repository on GitHub"; return 1; }
  module_remote_rows "$g"; rc=$?
  case "$rc" in
    0) ;;
    1) MODULE_NOTE="it names no origin"; return 1 ;;
    *) MODULE_NOTE="its remote cannot be read"; return 1 ;;
  esac
  if [ "$carry" -eq 1 ]; then
    # Nothing is asked of GitHub here: a commit or tag origin does not advertise is carried,
    # whether or not origin would turn out to hold it some other way.
    module_carry_plan "$g" "$co" "${g#"$3"/}" "$carry_ids" "${co#"$wt_real"/}" || return 1
  else
    module_held_by_remote "$g"; rc=$?
    case "$rc" in
      0) ;;
      1) return 1 ;;
      *) REMOTE_MODULE_FAILED=1
         MODULE_NOTE="cannot compare it with what its remote advertises"; return 1 ;;
    esac
  fi
  VERIFIED_CHECKOUTS="$VERIFIED_CHECKOUTS$co"$'\n'
  # 9. Its own submodules' repositories, by the same rule.
  if [ -d "$g/modules" ]; then
    module_tree_pristine "$g/modules" "$wt_real" "$3" || return 1
  fi
  return 0
}

# module_tree_pristine <modules-dir> <worktree-realpath> <admin> — exit 0 when everything
# under a modules/ directory is a pristine submodule repository or a plain directory leading
# to one; 1 with MODULE_NOTE (prefixed with the repository's path under the admin directory)
# otherwise. A submodule at `a/b` puts its repository at modules/a/b, so a directory that is
# not itself a repository is walked; any other entry there is content nothing classifies.
module_tree_pristine() {
  local dir=$1 wt_real=$2 admin=$3 entry label
  dir_listable "$dir" || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="${dir#"$admin"/} cannot be listed"; return 1; }
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    label=${entry#"$admin"/}
    if [ ! -d "$entry" ] || [ -L "$entry" ]; then
      MODULE_NOTE="$label is not a submodule repository"; return 1
    fi
    if [ -e "$entry/HEAD" ] || [ -L "$entry/HEAD" ] || [ -e "$entry/objects" ] || [ -L "$entry/objects" ]; then
      local unknown_before=$REMOTE_MODULE_FAILED pristine_note durable_rc
      if ! module_repository_pristine "$entry" "$wt_real" "$admin"; then
        # Not pristine. Its work can still be carried when the main checkout holds a
        # repository for the same submodule (module_durable). Where there is none, this is
        # the KEEP it always was, with the reason the pristine check gave.
        pristine_note=$MODULE_NOTE
        module_durable "$entry" "$admin"; durable_rc=$?
        case "$durable_rc" in
          0) ;;
          1) MODULE_NOTE="$label: $pristine_note"; return 1 ;;
          *) MODULE_NOTE="$label: $pristine_note; its work cannot be carried either: $DURABLE_NOTE"; return 1 ;;
        esac
        module_repository_pristine "$entry" "$wt_real" "$admin" carry \
          || { MODULE_NOTE="$label: $MODULE_NOTE"; return 1; }
        # The pristine check may have called this repository unread only because GitHub could
        # not be asked about a commit. Carrying asks GitHub nothing, so that no longer leaves
        # the worktree kept unexamined.
        REMOTE_MODULE_FAILED=$unknown_before
      fi
    else
      module_tree_pristine "$entry" "$wt_real" "$admin" || return 1
    fi
  done
  return 0
}

# --- carrying a submodule's work (#2831) ------------------------------------------------
# A submodule repository that is not pristine holds work, and the parent's salvage refs
# cannot hold it: they live in the parent repository, and the submodule's objects are in a
# repository under the worktree's admin directory, which the removal deletes. Until now
# that kept the worktree for good (18 worktrees, about 7.5 GB, on the host 2026-10-13).
# There is one repository that holds the same submodule and outlives the worktree: the main
# checkout's own, at the same path under the shared git directory's modules/. When it is
# there, is an ordinary repository, and names the same devantler-tech repository as its
# origin, the submodule's work is carried into it before the removal, under the same
# refs/salvaged/<id>/ name the parent uses:
#   head            - the submodule's HEAD commit
#   index           - a commit of its staged index, parent HEAD
#   worktree        - a commit of its whole working tree, parent HEAD, taken exactly as the
#                     parent's is (snapshot_tree: untracked files included, ignored files not)
#   commit/<sha>    - every commit a ref, reflog, ORIG_HEAD or FETCH_HEAD of it reaches that
#                     its origin does not advertise right now (the tips; history comes along)
#   object/<sha>    - every tag it holds that its origin does not advertise at that object
# They are copied with a local `git fetch` from the worktree's repository (no network, no
# push), then read back from the receiving repository: each ref at exactly the object sent,
# the two trees equal to the ones snapshotted, and every object they need present. Only
# then does the manifest name them. Anything else is the KEEP it always was: no repository
# to carry to, one that names another origin or cannot be written, a submodule repository
# whose shape, settings or index the pristine check refuses for a reason other than the
# work itself (a stash, a hook, a submodule-owned worktree, an operation in progress,
# resolve-undo stages, hidden index flags), an embedded repository, or any step that fails.

# module_plan_reset — forget the submodule repositories found to need carrying. The plan is
# rebuilt by every nested_repository_blocker run, which is every time salvage is judged.
PLAN_G=(); PLAN_CO=(); PLAN_DURABLE=(); PLAN_LABEL=(); PLAN_IDS=(); PLAN_HISTORY_KB=(); PLAN_REL=()
MODULE_CARRY_KB=0
# More refs than this for one submodule repository is not a worktree's abandoned work.
SUBMODULE_CARRY_LIMIT=50
module_plan_reset() {
  PLAN_G=(); PLAN_CO=(); PLAN_DURABLE=(); PLAN_LABEL=(); PLAN_IDS=(); PLAN_HISTORY_KB=(); PLAN_REL=()
  MODULE_CARRY_KB=0
}

# module_durable <git-dir> <admin> — exit 0 with MODULE_DURABLE set to the main checkout's
# repository for the same submodule: the one at the same path under the shared git
# directory as <git-dir> has under the worktree's admin directory. Exit 1 when there is
# none. Exit 2, with DURABLE_NOTE, when something is there that work must not be carried
# into: not a plain repository directory reached without a symbolic link, one whose object
# store borrows from another or is a partial clone (an object it reports may not be in it),
# one that names another origin than the submodule's (or not a devantler-tech repository on
# GitHub), or one that cannot be read or written. Read-only.
MODULE_DURABLE=""
DURABLE_NOTE=""
module_durable() {
  local g=$1 admin=$2 rel d d_real name keys a b
  MODULE_DURABLE=""; DURABLE_NOTE=""
  case "$g" in "$admin"/modules/?*) rel=${g#"$admin"/} ;; *) return 1 ;; esac
  d="$COMMON_DIR/$rel"
  if [ ! -e "$d" ] && [ ! -L "$d" ]; then return 1; fi
  if [ -L "$d" ] || [ ! -d "$d" ]; then
    DURABLE_NOTE="the main checkout's $rel is not a plain directory"; return 2
  fi
  # COMMON_DIR is canonical, so any difference is a symbolic link on the way, and what it
  # names need not outlive the worktree.
  d_real=$(physical_path "$d") && [ "$d_real" = "$d" ] \
    || { DURABLE_NOTE="the main checkout's $rel is reached through a symbolic link"; return 2; }
  for name in HEAD config; do
    [ -f "$d/$name" ] && [ ! -L "$d/$name" ] \
      || { DURABLE_NOTE="the main checkout's $rel is not a repository (no plain $name)"; return 2; }
  done
  for name in objects refs; do
    [ -d "$d/$name" ] && [ ! -L "$d/$name" ] \
      || { DURABLE_NOTE="the main checkout's $rel is not a repository (no plain $name directory)"; return 2; }
  done
  for name in alternates http-alternates; do
    if [ -e "$d/objects/info/$name" ] || [ -L "$d/objects/info/$name" ]; then
      DURABLE_NOTE="the main checkout's $rel borrows its objects from another repository"; return 2
    fi
  done
  keys=$(git config --file "$d/config" --name-only --list 2>/dev/null) \
    || { DURABLE_NOTE="the main checkout's $rel has a configuration that cannot be read"; return 2; }
  if grep -Eiq '^(extensions\.partialclone|remote\..*\.(promisor|partialclonefilter))$' <<< "$keys"; then
    DURABLE_NOTE="the main checkout's $rel is a partial clone"; return 2
  fi
  # The copy is a fetch run in this repository, so its own configuration applies to it. A
  # rule that rewrites URLs could point the source path at another repository or a network
  # endpoint, and an include could bring such a rule from a file not read here.
  if grep -Eiq '^(url\..*\.(insteadof|pushinsteadof)|include\.path|includeif\..*\.path)$' <<< "$keys"; then
    DURABLE_NOTE="the main checkout's $rel rewrites URLs or includes other configuration"; return 2
  fi
  if [ -e "$d/config.worktree" ] || [ -L "$d/config.worktree" ]; then
    keys=$(git config --file "$d/config.worktree" --name-only --list 2>/dev/null) \
      || { DURABLE_NOTE="the main checkout's $rel has a worktree configuration that cannot be read"; return 2; }
    if grep -Eiq '^(url\..*\.(insteadof|pushinsteadof)|include\.path|includeif\..*\.path)$' <<< "$keys"; then
      DURABLE_NOTE="the main checkout's $rel rewrites URLs or includes other configuration"; return 2
    fi
  fi
  a=$(portfolio_repo "$(module_origin_url "$d" || true)")
  b=$(portfolio_repo "$(module_origin_url "$g" || true)")
  if [ -z "$a" ] || [ "$a" != "$b" ]; then
    DURABLE_NOTE="the main checkout's $rel does not name the same origin"; return 2
  fi
  module_git "$d" rev-parse --git-dir > /dev/null 2>&1 \
    || { DURABLE_NOTE="the main checkout's $rel cannot be read as a repository"; return 2; }
  if [ ! -w "$d" ] || [ ! -w "$d/objects" ] || [ ! -w "$d/refs" ]; then
    DURABLE_NOTE="the main checkout's $rel cannot be written to"; return 2
  fi
  MODULE_DURABLE=$d
}

# intent_to_add_count <checkout> -> prints how many index entries carry the intent-to-add
# flag (CE_INTENT_TO_ADD, bit 29 of the --debug flags). Read from the flag itself: a
# worktree diff calls a deleted intent-to-add path D, not A, yet write-tree still drops it.
intent_to_add_count() {
  git -C "$1" ls-files --debug 2>/dev/null \
    | awk '/^  size: .*flags: / { f = $NF; if (length(f) == 8 && substr(f, 1, 1) ~ /[2367abef]/) n++ } END { print n + 0 }'
}

# module_carry_plan <git-dir> <checkout> <label> <pseudo-ref-commits> <checkout-path> — the last part of the
# carry question (module_repository_pristine ... carry): exit 0 after adding the repository
# to the plan, with the commits and tags to carry; 1 with MODULE_NOTE when something in it
# could not be carried faithfully. Reads MODULE_DURABLE, MODULE_REMOTE_ROWS and the ids the
# pristine check collected. Read-only, so dry-run reports what apply would do.
module_carry_plan() {
  local g=$1 co=$2 label=$3 extra=$4 rel=$5 durable=$MODULE_DURABLE out n head_links idx_links saved_note
  local local_tags missing objects="" ids held="" set tips refs
  [ -n "$durable" ] || { MODULE_NOTE="there is no repository to carry its work to"; return 1; }
  # The label goes into the manifest, one `submodule=<label>` field among `;`-separated ones.
  case "$label" in
    *[[:cntrl:]]*|*\;*) MODULE_NOTE="its path cannot be named in the manifest"; return 1 ;;
  esac
  # The checkout's path inside the worktree goes into the kept record, one tab-separated
  # field on one line. It is not the label: the label is the repository's place under the
  # git directory, which follows the submodule's NAME (and nests as modules/a/modules/b).
  case "$rel" in
    ''|/*|*[[:cntrl:]]*) MODULE_NOTE="its checkout's path cannot be written in the salvage record"; return 1 ;;
  esac
  # What the parent's own snapshot refuses, refused here for the same reasons: a conflicted
  # index cannot be written as a tree, an intent-to-add entry has no blob, and a submodule
  # added or removed inside this one is not what its HEAD records.
  out=$(git -C "$co" ls-files -u 2>/dev/null) \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its index cannot be read for conflicts"; return 1; }
  if [ -n "$out" ]; then MODULE_NOTE="its index holds unmerged (conflicted) entries"; return 1; fi
  n=$(intent_to_add_count "$co") \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its intent-to-add entries cannot be listed"; return 1; }
  if [ "$n" != 0 ]; then MODULE_NOTE="its index holds intent-to-add entries (they cannot be carried)"; return 1; fi
  head_links=$(git -C "$co" ls-tree -r HEAD 2>/dev/null | awk -F'\t' '$1 ~ /^160000 /{print $2}') \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its HEAD gitlinks cannot be listed"; return 1; }
  idx_links=$(git -C "$co" ls-files -s 2>/dev/null | awk -F'\t' '$1 ~ /^160000 /{print $2}') \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its staged gitlinks cannot be listed"; return 1; }
  if [ "$head_links" != "$idx_links" ]; then
    MODULE_NOTE="a submodule of it was added, removed or replaced (the snapshot cannot record it)"; return 1
  fi
  # An untracked embedded repository, and the size of what the snapshot would make
  # permanent, counted with the other carried checkouts towards the one cap.
  saved_note=$SALVAGE_NOTE
  if ! changed_data_kb "$co" "$MODULE_CARRY_KB"; then
    case "$SALVAGE_NOTE" in cannot*) REMOTE_MODULE_FAILED=1 ;; esac
    MODULE_NOTE="in its checkout, $SALVAGE_NOTE"; SALVAGE_NOTE=$saved_note; return 1
  fi
  SALVAGE_NOTE=$saved_note
  # The snapshot leaves ignored files behind, as the parent's does. A submodule's own agent
  # worktree root is the one place where that is never build output: whatever sits there
  # was a session's working directory, and the submodule may well ignore the whole root.
  out=$(git -C "$co" status --porcelain --ignored=matching --untracked-files=all \
          -- .claude/worktrees .codex/worktrees 2>/dev/null) \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its checkout's ignored files cannot be listed"; return 1; }
  if grep -q '^!!' <<< "$out"; then
    MODULE_NOTE="its checkout holds ignored files under an agent worktree root (the snapshot would leave them behind)"; return 1
  fi
  # Tags origin does not advertise at exactly the same object.
  local_tags=$(module_git "$g" for-each-ref --format='%(objectname)%09%(refname)' refs/tags 2>/dev/null) \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its tags cannot be read"; return 1; }
  if [ -n "$local_tags" ]; then
    missing=$(awk 'NR == FNR { held[$0]; next } NF && !($0 in held)' \
              <(printf '%s\n' "$MODULE_REMOTE_ROWS") <(printf '%s\n' "$local_tags")) \
      || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its tags cannot be compared with its remote's"; return 1; }
    objects=$(awk -F'\t' 'NF { print $1 }' <<< "$missing" | sort -u)
  fi
  # Commits: everything a ref, a reflog or a pseudo-ref reaches, less what the commits
  # origin advertises reach (as module_held_by_remote lists them). Only the tips are named;
  # the copy brings their history.
  ids=$(awk -F'\t' 'NF == 2 { print $1 }' <<< "$MODULE_REMOTE_ROWS" | sort -u) \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its remote's answer cannot be read"; return 1; }
  if [ -n "$ids" ]; then
    held=$(module_git "$g" cat-file --batch-check='%(objectname) %(objecttype)' <<< "$ids" 2>/dev/null \
           | awk '$2 == "commit" { print "^" $1 }') \
      || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its remote's commits cannot be looked up"; return 1; }
  fi
  set=$(module_git "$g" rev-list --parents --all --reflog --stdin \
        < <(grep . <<< "$MODULE_LOG_IDS"$'\n'"$MODULE_PACKED_IDS"$'\n'"$extra"$'\n'"$held" || true) 2>/dev/null) \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its commits cannot be listed"; return 1; }
  tips=$(awk 'NF { c[$1]; for (i = 2; i <= NF; i++) p[$i] } END { for (k in c) if (!(k in p)) print k }' <<< "$set" | sort) \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its commits cannot be listed"; return 1; }
  refs=$( { [ -z "$tips" ] || awk '{ print "commit/" $0 }' <<< "$tips"
            [ -z "$objects" ] || awk '{ print "object/" $0 }' <<< "$objects"; } )
  if grep -Evq '^(commit|object)/([0-9a-f]{40}|[0-9a-f]{64})$' <<< "${refs:-commit/0000000000000000000000000000000000000000}"; then
    REMOTE_MODULE_FAILED=1; MODULE_NOTE="its commits cannot be listed"; return 1
  fi
  if [ -n "$refs" ] && [ "$(grep -c . <<< "$refs")" -gt "$SUBMODULE_CARRY_LIMIT" ]; then
    MODULE_NOTE="it holds more than $SUBMODULE_CARRY_LIMIT commits and tags its remote does not advertise"; return 1
  fi
  # The cap also covers the commits themselves: the copy brings every object the carried
  # HEAD, commits and tags reach that the receiving repository lacks, and a local commit
  # can hold any amount of data without a single changed or untracked file.
  local head history_kb
  head=$(module_git "$g" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) && [ -n "$head" ] \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="its HEAD cannot be read"; return 1; }
  history_kb=$(module_history_kb "$g" "$durable" "$head"$'\n'"$(awk -F/ 'NF == 2 { print $2 }' <<< "$refs")") \
    || { REMOTE_MODULE_FAILED=1; MODULE_NOTE="what carrying its commits would add to the main checkout's repository cannot be measured"; return 1; }
  case "$history_kb" in ''|*[!0-9]*) REMOTE_MODULE_FAILED=1; MODULE_NOTE="what carrying its commits would add to the main checkout's repository cannot be measured"; return 1 ;; esac
  if [ "$((CHANGED_KB + history_kb))" -gt "$SALVAGE_MAX_KB" ]; then
    MODULE_NOTE="carrying its commits and files would add more than ${SALVAGE_MAX_KB} KB to the main checkout's repository"; return 1
  fi
  n=${#PLAN_G[@]}
  PLAN_G[n]=$g; PLAN_CO[n]=$co; PLAN_DURABLE[n]=$durable; PLAN_LABEL[n]=$label; PLAN_IDS[n]=$refs
  PLAN_HISTORY_KB[n]=$history_kb; PLAN_REL[n]=$rel
  MODULE_CARRY_KB=$((CHANGED_KB + history_kb))
  return 0
}

# index_tree <checkout> <git-dir> -> prints the tree of the checkout's staged index, written
# from a COPY of the index file. `git write-tree` records the trees it computed back into
# the index it read, and a submodule's index is one of the files the sweep fingerprints and
# keeps (modules_fingerprint, module_files_tree), so the real one must not be rewritten.
index_tree() {
  local dir tree rc
  dir=$(mktemp -d "${TMPDIR:-/tmp}/wt-salvage-sub-index.XXXXXX") || return 1
  if [ -e "$2/index" ] && ! cp "$2/index" "$dir/index" 2>/dev/null; then rm -rf "$dir"; return 1; fi
  tree=$(GIT_INDEX_FILE="$dir/index" git -C "$1" write-tree 2>/dev/null); rc=$?
  rm -rf "$dir"
  [ "$rc" -eq 0 ] && [ -n "$tree" ] || return 1
  printf '%s\n' "$tree"
}

# module_carry_snapshot <plan-index> -> sets CARRY_HEAD, CARRY_ITREE and CARRY_WTREE to the
# planned repository's HEAD commit and the trees of its staged index and whole working
# tree. Writes objects into the worktree's own copy of the submodule repository only.
# Non-zero, with SALVAGE_NOTE, on any failure.
CARRY_HEAD=""; CARRY_ITREE=""; CARRY_WTREE=""
module_carry_snapshot() {
  local g=${PLAN_G[$1]} co=${PLAN_CO[$1]} label=${PLAN_LABEL[$1]}
  CARRY_HEAD=$(module_git "$g" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) && [ -n "$CARRY_HEAD" ] \
    || { SALVAGE_NOTE="cannot read the HEAD of $label"; return 1; }
  CARRY_ITREE=$(index_tree "$co" "$g") \
    || { SALVAGE_NOTE="cannot write the staged index of $label as a tree"; return 1; }
  snapshot_tree "$co" || { SALVAGE_NOTE="$label: $SALVAGE_NOTE"; return 1; }
  CARRY_WTREE=$SNAPSHOT_TREE
}

# carry_record <plan-index> <head> <index-tree> <worktree-tree> -> prints what was (or would
# now be) carried for that repository. One tab-separated line: the repository's path under
# the git directory (the manifest's label), the path its checkout had inside the worktree,
# the repository that received the work, and the HEAD commit, index tree and working-tree
# tree; then one line per extra ref. The same text is the kept record
# (refs/salvaged/<id>/submodules) and what the check before the removal compares.
carry_record() {
  printf '%s\t%s\t%s\t%s %s %s\n%s\n' "${PLAN_LABEL[$1]}" "${PLAN_REL[$1]}" "${PLAN_DURABLE[$1]}" "$2" "$3" "$4" "${PLAN_IDS[$1]}"
}

# module_carry_signature -> sets CARRY_SIGNATURE to the carry_record of every planned
# repository as it is right now (empty when nothing is planned). Non-zero, with
# SALVAGE_NOTE, when one cannot be snapshotted.
CARRY_SIGNATURE=""
module_carry_signature() {
  local i=0
  CARRY_SIGNATURE=""
  while [ "$i" -lt "${#PLAN_G[@]}" ]; do
    module_carry_snapshot "$i" || return 1
    CARRY_SIGNATURE="$CARRY_SIGNATURE$(carry_record "$i" "$CARRY_HEAD" "$CARRY_ITREE" "$CARRY_WTREE")"$'\n'
    i=$((i + 1))
  done
  return 0
}

# module_carry_write <plan-index> <base> <head> <index-tree> <worktree-tree> -> copies the
# planned repository's work into the main checkout's repository for that submodule under
# <base>/ and verifies it there. Non-zero, with SALVAGE_NOTE, on any failure; refs already
# written stay (they only preserve data) and the caller KEEPs the worktree.
module_carry_write() {
  local g=${PLAN_G[$1]} co=${PLAN_CO[$1]} durable=${PLAN_DURABLE[$1]} label=${PLAN_LABEL[$1]}
  local base=$2 head=$3 itree=$4 wtree=$5 icommit wcommit out line specs n
  icommit=$(salvage_commit "$co" "$itree" "$head" "salvage: staged index of submodule $label") && [ -n "$icommit" ] \
    || { SALVAGE_NOTE="cannot commit the staged index of $label"; return 1; }
  wcommit=$(salvage_commit "$co" "$wtree" "$head" "salvage: working tree of submodule $label") && [ -n "$wcommit" ] \
    || { SALVAGE_NOTE="cannot commit the working tree of $label"; return 1; }
  # A fetch moves an existing ref forward without a word, so the names must be new. The
  # name holds the second, the worktree's path and its HEAD, so anything there is not this.
  out=$(module_git "$durable" for-each-ref --format='%(refname)' "$base" 2>/dev/null) \
    || { SALVAGE_NOTE="cannot read the refs of the main checkout's $label"; return 1; }
  if [ -n "$out" ]; then SALVAGE_NOTE="$base already exists in the main checkout's $label"; return 1; fi
  specs=("$head:$base/head" "$icommit:$base/index" "$wcommit:$base/worktree")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    specs+=("${line#*/}:$base/$line")
  done <<< "${PLAN_IDS[$1]}"
  # A local copy between two directories: no network, no push, no hook, no housekeeping in
  # the receiving repository, and nothing taken from the host's configuration (a URL
  # rewrite there could name another source). The source is an absolute path.
  if ! GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1 \
       module_git "$durable" -c core.hooksPath=/dev/null -c gc.auto=0 -c maintenance.auto=false \
         -c protocol.allow=never -c protocol.file.allow=always -c uploadpack.allowAnySHA1InWant=true \
         fetch --quiet --no-tags --no-recurse-submodules --no-write-fetch-head --no-auto-maintenance \
         -- "$g" "${specs[@]}" > /dev/null 2>&1; then
    SALVAGE_NOTE="cannot copy the work of $label into the main checkout's repository for it"; return 1
  fi
  # Read back from the repository that outlives the worktree, and remembered so the same
  # reading can be repeated immediately before the removal (recheck_mutable_gates).
  out=$(printf '%s\n' "${specs[@]}")
  module_carry_verify "$durable" "$label" "$base" "$itree" "$wtree" "$out" || return 1
  n=${#CARRIED_DURABLE[@]}
  CARRIED_DURABLE[n]=$durable; CARRIED_LABEL[n]=$label; CARRIED_ITREE[n]=$itree; CARRIED_WTREE[n]=$wtree
  CARRIED_SPECS[n]=$out
  return 0
}

# module_carry_verify <durable> <label> <base> <index-tree> <worktree-tree> <specs> — reads
# carried work back from the repository that received it: each `<object>:<ref>` line of
# <specs> names a ref that is at exactly that object, which is there; <base>/index and
# <base>/worktree have the two trees; and nothing those objects reach is missing. Non-zero,
# with SALVAGE_NOTE, when any of it does not hold. Read-only.
CARRIED_DURABLE=(); CARRIED_LABEL=(); CARRIED_ITREE=(); CARRIED_WTREE=(); CARRIED_SPECS=()
SALVAGE_CARRIED_BLOB=""
module_carried_reset() {
  CARRIED_DURABLE=(); CARRIED_LABEL=(); CARRIED_ITREE=(); CARRIED_WTREE=(); CARRIED_SPECS=()
  SALVAGE_CARRIED_BLOB=""
}
module_carry_verify() {
  local durable=$1 label=$2 base=$3 itree=$4 wtree=$5 spec_lines=$6 spec id ref ids=()
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    id=${spec%%:*}; ref=${spec#*:}
    if [ "$(module_git "$durable" rev-parse --verify --quiet "$ref" 2>/dev/null)" != "$id" ] \
       || ! GIT_NO_LAZY_FETCH=1 module_git "$durable" cat-file -e "$id" 2>/dev/null; then
      SALVAGE_NOTE="$ref does not verify in the main checkout's $label"; return 1
    fi
    ids+=("$id")
  done <<< "$spec_lines"
  [ "${#ids[@]}" -ge 3 ] || { SALVAGE_NOTE="$base holds no carried work to verify for $label"; return 1; }
  [ "$(module_git "$durable" rev-parse --verify --quiet "$base/index^{tree}" 2>/dev/null)" = "$itree" ] \
    && [ "$(module_git "$durable" rev-parse --verify --quiet "$base/worktree^{tree}" 2>/dev/null)" = "$wtree" ] \
    || { SALVAGE_NOTE="$base trees do not verify in the main checkout's $label"; return 1; }
  # Everything the carried refs reach, with nothing left out: a branch, remote or tag of
  # the receiving repository at a carried commit does not prove it holds what that commit
  # reaches, and the copy sends nothing for a commit the receiver says it already has.
  GIT_NO_LAZY_FETCH=1 module_git "$durable" rev-list --objects --quiet "${ids[@]}" > /dev/null 2>&1 \
    || { SALVAGE_NOTE="the work of $label is not complete in the main checkout's repository for it"; return 1; }
  return 0
}

# module_history_kb <git-dir> <durable> <ids> -> prints the size in KB of every object the
# ids (one per line) reach that the receiving repository does not already hold: what the
# copy would add to it. "Already holds" is everything its refs reach, read from the refs
# themselves, so an object it has but no ref keeps is counted, which only errs towards
# keeping. Sizes are the objects' own, as elsewhere under the cap. Read-only, and computed
# when the plan is made, so dry-run and apply reach the same verdict. Non-zero on any
# failed read.
module_history_kb() {
  local g=$1 durable=$2 want=$3 have held="" objs
  have=$(GIT_NO_LAZY_FETCH=1 module_git "$durable" for-each-ref --format='%(objectname)' 2>/dev/null) || return 1
  if [ -n "$have" ]; then
    held=$(sort -u <<< "$have" | module_git "$g" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
           | awk '$2 == "commit" || $2 == "tag" { print "^" $1 }') || return 1
  fi
  objs=$(grep . <<< "$want"$'\n'"$held" | module_git "$g" rev-list --objects --stdin 2>/dev/null) || return 1
  [ -n "$objs" ] || { echo 0; return 0; }
  awk '{ print $1 }' <<< "$objs" | module_git "$g" cat-file --batch-check='%(objectsize)' 2>/dev/null \
    | awk 'NF != 1 || $1 !~ /^[0-9]+$/ { bad = 1 } { b += $1 } END { if (bad) exit 1; print int((b + 1023) / 1024) }'
}

# nested_repository_blocker <worktree> -> 0, with SALVAGE_NOTE, when the worktree holds any
# repository besides its own that the removal would cost something: a submodule repository
# under the admin directory's modules/ that is neither pristine nor one whose work can be
# carried (module_repository_pristine), or
# any other .git entry below its top level, including one the parent ignores or one inside a
# tracked directory. Salvage records only the parent repository, and the removal deletes
# the others with every commit, ref, index and reflog they hold. Found by walking the
# filesystem, never through git's own listing, which is exactly what an ignore rule hides
# from. Any read failure blocks. Sets VERIFIED_CHECKOUTS to the pristine submodules'
# checkouts, which gitlink_blocker reads.
nested_repository_blocker() {
  local wt=$1 admin found wt_real
  VERIFIED_CHECKOUTS=""
  module_plan_reset
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] \
    || { SALVAGE_NOTE="cannot locate the worktree's admin directory"; return 0; }
  wt_real=$(physical_path "$wt") || { SALVAGE_NOTE="cannot resolve the worktree's path"; return 0; }
  if [ -e "$admin/modules" ] || [ -L "$admin/modules" ]; then
    if [ ! -d "$admin/modules" ] || [ -L "$admin/modules" ]; then
      SALVAGE_NOTE="holds submodule repositories salvage cannot clear (modules is not a plain directory)"
      return 0
    fi
    if ! module_tree_pristine "$admin/modules" "$wt_real" "$admin"; then
      SALVAGE_NOTE="holds submodule repositories salvage cannot clear ($MODULE_NOTE)"
      return 0
    fi
  fi
  # A .git entry marks a repository with a working tree; a bare repository has none, so it
  # is recognised by its own layout: an objects/ entry beside a HEAD entry. Git resolves an
  # objects/ symlink normally, so a symlink counts as well as a directory, and refs/ is not
  # required: a repository whose empty refs/ was lost still holds packed-refs and objects.
  local objs o gits d
  # NUL-terminated, then read by line: a path holding a newline would otherwise fall apart
  # into lines that can each be the path of a checkout already accounted for.
  if ! gits=$(find "$wt" -mindepth 2 -name .git -prune -print0 2>/dev/null | tr '\0\n' '\n\001') \
     || ! objs=$(find "$wt" -mindepth 2 -name objects \( -type d -o -type l \) -prune -print0 2>/dev/null | tr '\0\n' '\n\001'); then
    SALVAGE_NOTE="cannot search the worktree for nested repositories"; return 0
  fi
  case "$gits$objs" in
    *$'\001'*) SALVAGE_NOTE="holds a nested repository at a path with a newline in it (salvage carries no repository but the worktree's own)"; return 0 ;;
  esac
  # A pristine submodule's checkout is the one .git entry that is accounted for: a plain
  # file naming a repository checked above. Every other one still marks a repository the
  # removal would delete unexamined (a path holding a newline never matches, so it blocks).
  found=""
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    d=$(physical_path "${o%/.git}") || d=""
    if [ -n "$d" ] && [ -f "$o" ] && [ ! -L "$o" ]; then
      case $'\n'"$VERIFIED_CHECKOUTS" in *$'\n'"$d"$'\n'*) continue ;; esac
    fi
    found=$o; break
  done <<< "$gits"
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    if [ -e "${o%/objects}/HEAD" ] || [ -L "${o%/objects}/HEAD" ]; then
      found=${found:-${o%/objects}}
    fi
  done <<< "$objs"
  if [ -n "$found" ]; then
    SALVAGE_NOTE="holds a nested repository (${found%%$'\n'*}; salvage carries no repository but the worktree's own)"
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
    # An initialised submodule gets this far only when nested_repository_blocker, which
    # every caller runs first, found its repository pristine and its checkout clean.
    local p_real
    if p_real=$(physical_path "$wt/$p"); then
      case $'\n'"$VERIFIED_CHECKOUTS" in *$'\n'"$p_real"$'\n'*) continue ;; esac
    fi
    # Otherwise it is uninitialised. Status reports files dropped into its directory as
    # clean, the snapshot records only the gitlink, and the removal would delete them.
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
      # The Claude desktop app drops an empty marker into each session worktree's admin
      # directory (#4152). An empty regular file carries nothing to lose, and the manifest
      # row notes it; with content, or as a link or directory, it is unlisted state.
      claude-desktop-worktree)
        # Through the one reader, so a look that failed is not taken for a marker with content.
        desktop_marker_lookup "$admin" >/dev/null
        case $? in
          0) ;;
          1) SALVAGE_NOTE="the worktree's ${entry##*/} is not the empty marker the desktop app writes (salvage cannot carry it)"; return 0 ;;
          *) DESKTOP_MARKER_UNREAD=1
             SALVAGE_NOTE="cannot read the worktree's git state for the desktop app's marker"; return 0 ;;
        esac ;;
      # Claude Code records the commit a subagent worktree started from (#2831). Naming a
      # commit a remote-tracking ref reaches, it carries nothing the removal could lose.
      CLAUDE_BASE)
        claude_base_on_remote "$wt" "$entry" \
          || { SALVAGE_NOTE="the worktree's CLAUDE_BASE does not name a commit a remote holds (salvage cannot carry it)"; return 0; } ;;
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

# claude_base_on_remote <worktree> <file> -> 0 only when <file> is a regular file holding one
# object id, at most newline-terminated, of a commit some remote-tracking ref reaches. Any
# other content, a link, a directory or a failed read is 1, so the worktree is kept.
claude_base_on_remote() {
  local wt=$1 file=$2 id size unreached
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  id=$(cat "$file" 2>/dev/null) && size=$(wc -c < "$file" 2>/dev/null) || return 1
  size=$((size + 0))
  [[ "$id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  [ "$size" -eq "${#id}" ] || [ "$size" -eq $((${#id} + 1)) ] || return 1
  [ "$(git -C "$wt" cat-file -t "$id" 2>/dev/null)" = commit ] || return 1
  unreached=$(git -C "$wt" rev-list --max-count=1 "$id" --not --remotes 2>/dev/null) || return 1
  [ -z "$unreached" ]
}

# desktop_marker_lookup <admin directory> -> prints `empty` or `absent`. 1 when the name
# holds anything but the empty file (a verdict: keep). 2 when the look itself failed (no
# verdict). This is the one reader of the marker (#4155): every caller decides from it, so
# a failed look is never read as "no marker", as "not empty" or as examined. Both answers
# come from a status-checked `find`, which reports an entry it cannot stat by failing; a
# link is not followed, so only an empty regular file matches the second look.
desktop_marker_lookup() {
  local found
  found=$(find "$1" -maxdepth 1 -name claude-desktop-worktree 2>/dev/null) || return 2
  [ -n "$found" ] || { printf 'absent\n'; return 0; }
  found=$(find "$1" -maxdepth 1 -name claude-desktop-worktree -type f -size 0 2>/dev/null) || return 2
  [ -n "$found" ] || return 1
  printf 'empty\n'
}

# desktop_marker_state <worktree> -> desktop_marker_lookup on the worktree's admin
# directory; 2 as well when that directory cannot be located.
desktop_marker_state() {
  local admin
  admin=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] || return 2
  desktop_marker_lookup "$admin"
}

# desktop_marker_read <worktree> -> 0 with DESKTOP_MARKER_NOW (empty|absent); 1 with
# DESKTOP_MARKER_NOTE when the worktree must be kept. A failed read also sets
# DESKTOP_MARKER_UNREAD, which ends the sweep UNKNOWN: that worktree was kept unexamined.
desktop_marker_read() {
  local rc
  DESKTOP_MARKER_NOW=$(desktop_marker_state "$1"); rc=$?
  case "$rc" in
    0) return 0 ;;
    1) DESKTOP_MARKER_NOTE="the desktop app's marker is not the empty file it writes" ;;
    *) DESKTOP_MARKER_UNREAD=1; DESKTOP_MARKER_NOTE="cannot read the worktree's git state for the desktop app's marker" ;;
  esac
  DESKTOP_MARKER_NOW=""
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

# salvage_namespace <worktree> <sha> -> sets SALVAGE_BASE to a new refs/salvaged/<id>.
# Non-zero, with SALVAGE_NOTE, when no usable name can be derived.
salvage_namespace() {
  local wt=$1 sha=$2 path_id bn
  SALVAGE_BASE=""
  # The namespace must be unique per WORKTREE, not per basename: two registered nested
  # worktrees can share a basename and a HEAD, and salvaged in the same second they would
  # otherwise derive one namespace and the second would overwrite the first's refs —
  # leaving its uncommitted work unreferenced after both are reaped. A digest of the full
  # path separates them, and every ref is created with an empty old value, so a
  # collision that still happens fails (and KEEPs the worktree) instead of overwriting.
  path_id=$(printf '%s' "$wt" | git hash-object --stdin 2>/dev/null) && [ -n "$path_id" ] \
    || { SALVAGE_NOTE="cannot derive a salvage namespace for $wt"; return 1; }
  # Only ref-safe characters from the basename, so the namespace is always valid and dry-run
  # never promises a salvage apply would refuse; the path digest keeps it unique.
  bn=$(printf '%s' "$(basename "$wt")" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)
  SALVAGE_BASE="refs/salvaged/$(date -u +%Y%m%dT%H%M%SZ)-${bn}-${path_id:0:12}-${sha:0:12}"
  git check-ref-format "$SALVAGE_BASE/head" 2>/dev/null \
    || { SALVAGE_NOTE="unusable salvage ref name $SALVAGE_BASE"; SALVAGE_BASE=""; return 1; }
}

# module_files_kb <admin> -> prints the size in KB, rounded up per file, of the files
# module_files_tree keeps (0 when the worktree holds no submodule repository). Read-only, so
# salvage_blocker counts them too and dry-run cannot promise a salvage that apply then
# refuses for its size. Non-zero when the files cannot be listed or sized, which also sets
# REMOTE_MODULE_FAILED: files that were not read were not examined.
module_files_kb() {
  local admin=$1 list f sz kb=0
  if [ ! -d "$admin/modules" ] || [ -L "$admin/modules" ]; then echo 0; return 0; fi
  list=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-module-kb.XXXXXX") || return 1
  if ! module_state_files "$admin/modules" > "$list"; then rm -f "$list"; REMOTE_MODULE_FAILED=1; return 1; fi
  while IFS= read -r -d '' f; do
    sz=$(wc -c < "$f" 2>/dev/null) || { rm -f "$list"; REMOTE_MODULE_FAILED=1; return 1; }
    sz=$(printf '%s' "$sz" | tr -d ' ')
    case "$sz" in ''|*[!0-9]*) rm -f "$list"; REMOTE_MODULE_FAILED=1; return 1 ;; esac
    kb=$((kb + (sz + 1023) / 1024))
  done < "$list"
  rm -f "$list"
  printf '%s\n' "$kb"
}

# module_files_tree <worktree> -> sets MODULE_FILES_TREE to a tree holding every file of every
# submodule repository under the admin directory's modules/ outside the object stores, at
# its path under the admin directory (modules/<path>/config, .../description,
# .../hooks/<name>.sample, .../info/exclude, .../logs/..., .../COMMIT_EDITMSG, the index and
# the refs themselves); or to nothing when there is none. It is the same set of files
# modules_fingerprint compares. The pristine check accepts these files by name or by the
# keys and ids they hold, and each can still carry bytes someone wrote: a note in the
# description or in an exclude file's comments, an edited hook sample (git's own samples
# differ from version to version, so there is no known content to compare with), an identity
# in the config, a reflog message (`git update-ref -m`), a drafted commit message. So none
# is judged; all are kept (#2831). Their sizes are summed against SALVAGE_MAX_KB BEFORE
# anything is written, so an oversized file leaves no blob behind in the repository that
# outlives the worktree. Built in a temporary index there. Non-zero, with SALVAGE_NOTE, on
# any failure.
MODULE_FILES_TREE=""
module_files_tree() {
  local wt=$1 admin dir f rel blob mode tree sz kb=0
  MODULE_FILES_TREE=""
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] \
    || { SALVAGE_NOTE="cannot locate the worktree's admin directory"; return 1; }
  if [ ! -d "$admin/modules" ] || [ -L "$admin/modules" ]; then return 0; fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/wt-salvage-module-files.XXXXXX") \
    || { SALVAGE_NOTE="cannot create a temporary directory"; return 1; }
  # module_files_kb runs in a subshell here, so its failure flag is set again on this side.
  kb=$(module_files_kb "$admin") || { rm -rf "$dir"; REMOTE_MODULE_FAILED=1; SALVAGE_NOTE="cannot list or size the submodule repositories' files"; return 1; }
  if [ "$kb" -gt "$SALVAGE_MAX_KB" ]; then
    rm -rf "$dir"; SALVAGE_NOTE="the submodule repositories hold more than ${SALVAGE_MAX_KB} KB of files to keep"; return 1
  fi
  if ! module_state_files "$admin/modules" > "$dir/list"; then
    rm -rf "$dir"; REMOTE_MODULE_FAILED=1; SALVAGE_NOTE="cannot list the submodule repositories' files"; return 1
  fi
  : > "$dir/entries" || { rm -rf "$dir"; SALVAGE_NOTE="cannot write a temporary file"; return 1; }
  while IFS= read -r -d '' f; do
    rel=${f#"$admin"/}
    blob=$(git -C "$TOPLEVEL" hash-object -w --no-filters -- "$f" 2>/dev/null) && [ -n "$blob" ] \
      || { rm -rf "$dir"; SALVAGE_NOTE="cannot preserve a submodule repository file"; return 1; }
    mode=100644; [ -x "$f" ] && mode=100755
    printf '%s %s\t%s\0' "$mode" "$blob" "$rel" >> "$dir/entries" \
      || { rm -rf "$dir"; SALVAGE_NOTE="cannot write a temporary file"; return 1; }
  done < "$dir/list"
  if [ ! -s "$dir/entries" ]; then rm -rf "$dir"; return 0; fi
  if ! GIT_INDEX_FILE="$dir/index" git -C "$TOPLEVEL" update-index -z --index-info < "$dir/entries" 2>/dev/null \
     || ! tree=$(GIT_INDEX_FILE="$dir/index" git -C "$TOPLEVEL" write-tree 2>/dev/null) || [ -z "$tree" ]; then
    rm -rf "$dir"; SALVAGE_NOTE="cannot build the tree of submodule repository files"; return 1
  fi
  rm -rf "$dir"
  MODULE_FILES_TREE=$tree
}

# resolve_undo_ref_write <base> <tree> -> writes and verifies <base>/resolve-undo.
resolve_undo_ref_write() {
  git -C "$TOPLEVEL" update-ref "$1/resolve-undo" "$2" "" 2>/dev/null \
    && [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$1/resolve-undo" 2>/dev/null)" = "$2" ]
}

# resolve_undo_preserve <worktree> <sha> -> for a worktree reaped WITHOUT salvage (clean and
# fully pushed): the removal still deletes the index, so its resolve-undo stages are written
# to a salvage namespace holding only that ref. Sets SALVAGE_RESOLVE_UNDO (the tree, or
# nothing when the index holds none) and RESOLVE_UNDO_REF. The cap is applied to the tree
# that is written, not to an earlier listing. Non-zero, with SALVAGE_NOTE, on any failure.
resolve_undo_preserve() {
  local wt=$1 sha=$2 kb
  SALVAGE_RESOLVE_UNDO=""; RESOLVE_UNDO_REF=""
  resolve_undo_tree "$wt" || { SALVAGE_NOTE="cannot preserve the index's resolve-undo entries"; return 1; }
  [ -n "$RESOLVE_UNDO_TREE" ] || return 0
  kb=$(tree_kb "$wt" "$RESOLVE_UNDO_TREE") || { SALVAGE_NOTE="cannot size the index's resolve-undo entries"; return 1; }
  if [ "$kb" -gt "$SALVAGE_MAX_KB" ]; then
    SALVAGE_NOTE="the index holds more than ${SALVAGE_MAX_KB} KB of resolve-undo stages"; return 1
  fi
  salvage_namespace "$wt" "$sha" || return 1
  resolve_undo_ref_write "$SALVAGE_BASE" "$RESOLVE_UNDO_TREE" \
    || { SALVAGE_NOTE="cannot write or verify $SALVAGE_BASE/resolve-undo"; return 1; }
  SALVAGE_RESOLVE_UNDO=$RESOLVE_UNDO_TREE; RESOLVE_UNDO_REF="$SALVAGE_BASE/resolve-undo"
}

# salvage_write <worktree> <sha> -> writes and verifies refs/salvaged/<id>/*, setting
# SALVAGE_REF, SALVAGE_TREE (whole working tree) and SALVAGE_INDEX_TREE (staged index).
# Returns non-zero, with SALVAGE_NOTE, on any failure; refs already written stay (they
# only preserve data) and the caller KEEPs the worktree.
salvage_write() {
  local wt=$1 sha=$2 base idx_tree wt_tree idx_commit wt_commit orphans o reuc_tree
  SALVAGE_MODULE_TREE=""
  SALVAGE_REF=""; SALVAGE_TREE=""; SALVAGE_INDEX_TREE=""; SALVAGE_ADMIN_BLOBS=""; SALVAGE_RESOLVE_UNDO=""
  SALVAGE_CARRIED=""; SALVAGE_SUBMODULES=""
  module_carried_reset
  salvage_namespace "$wt" "$sha" || return 1
  base=$SALVAGE_BASE
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
  # The resolve-undo stages are in neither tree above, and the removal deletes the index
  # that holds them. Their tree is built once, here: the cap sizes exactly the tree the
  # ref below makes permanent, so a stage added after an earlier listing is counted.
  local reuc_kb=0
  resolve_undo_tree "$wt" || { SALVAGE_NOTE="cannot preserve the index's resolve-undo entries"; return 1; }
  reuc_tree=$RESOLVE_UNDO_TREE
  if [ -n "$reuc_tree" ]; then
    reuc_kb=$(tree_kb "$wt" "$reuc_tree") || { SALVAGE_NOTE="cannot size the index's resolve-undo entries"; return 1; }
  fi
  # Every file of the submodule repositories outside their object stores, kept by its bytes.
  local mod_tree mod_kb=0
  module_files_tree "$wt" || return 1
  mod_tree=$MODULE_FILES_TREE
  if [ -n "$mod_tree" ]; then
    mod_kb=$(tree_kb "$wt" "$mod_tree") || { SALVAGE_NOTE="cannot size the submodule repositories' kept files"; return 1; }
  fi
  # The submodules whose work is carried (the plan the salvage blockers just built) are
  # snapshotted here too, before anything is written anywhere that lasts, so the one cap
  # covers what their refs make permanent as well.
  local ci=0 carry_kb=0 k carry_heads=() carry_itrees=() carry_wtrees=()
  while [ "$ci" -lt "${#PLAN_G[@]}" ]; do
    module_carry_snapshot "$ci" || return 1
    k=$(snapshot_kb "${PLAN_CO[$ci]}" "$CARRY_HEAD" "$CARRY_ITREE" "$CARRY_WTREE") \
      || { SALVAGE_NOTE="cannot size the snapshot of ${PLAN_LABEL[$ci]}"; return 1; }
    # Plus what the copy of its commits adds (measured with the plan, module_history_kb).
    carry_kb=$((carry_kb + k + ${PLAN_HISTORY_KB[$ci]}))
    carry_heads[ci]=$CARRY_HEAD; carry_itrees[ci]=$CARRY_ITREE; carry_wtrees[ci]=$CARRY_WTREE
    ci=$((ci + 1))
  done
  captured_kb=$((captured_kb + admin_kb + reuc_kb + mod_kb + carry_kb))
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
  if [ -n "$reuc_tree" ]; then
    resolve_undo_ref_write "$base" "$reuc_tree" \
      || { SALVAGE_NOTE="cannot write or verify $base/resolve-undo"; return 1; }
  fi
  if [ -n "$mod_tree" ]; then
    git -C "$TOPLEVEL" update-ref "$base/module-files" "$mod_tree" "" 2>/dev/null \
      && [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$base/module-files" 2>/dev/null)" = "$mod_tree" ] \
      || { SALVAGE_NOTE="cannot write or verify $base/module-files"; return 1; }
  fi
  # Each planned submodule's work goes to the main checkout's repository for it, under the
  # same name, and is verified there. The parent keeps the record of what went where.
  local carried="" carried_labels="" record_blob
  ci=0
  while [ "$ci" -lt "${#PLAN_G[@]}" ]; do
    module_carry_write "$ci" "$base" "${carry_heads[$ci]}" "${carry_itrees[$ci]}" "${carry_wtrees[$ci]}" || return 1
    carried="$carried$(carry_record "$ci" "${carry_heads[$ci]}" "${carry_itrees[$ci]}" "${carry_wtrees[$ci]}")"$'\n'
    carried_labels="${carried_labels:+$carried_labels;}submodule=${PLAN_LABEL[$ci]}"
    ci=$((ci + 1))
  done
  if [ -n "$carried" ]; then
    record_blob=$(printf '%s' "$carried" | git -C "$TOPLEVEL" hash-object -w --stdin 2>/dev/null) && [ -n "$record_blob" ] \
      && git -C "$TOPLEVEL" update-ref "$base/submodules" "$record_blob" "" 2>/dev/null \
      && [ "$(git -C "$TOPLEVEL" rev-parse --verify --quiet "$base/submodules" 2>/dev/null)" = "$record_blob" ] \
      || { SALVAGE_NOTE="cannot write or verify $base/submodules"; return 1; }
  fi
  SALVAGE_CARRIED=$carried; SALVAGE_SUBMODULES=$carried_labels; SALVAGE_CARRIED_BLOB=${record_blob:-}
  SALVAGE_MODULE_TREE=$mod_tree
  SALVAGE_RESOLVE_UNDO=$reuc_tree
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
  salvage_reason=""; SALVAGE_REF=""; SALVAGE_TREE=""; SALVAGE_INDEX_TREE=""; SALVAGE_ADMIN_BLOBS=""; SALVAGE_RESOLVE_UNDO=""; SALVAGE_NOTE=""
  RESOLVE_UNDO_SAVED=0; RESOLVE_UNDO_REF=""
  SCAN_REF_IDS=""
  SALVAGE_MODULES_FP=""
  SALVAGE_MODULE_TREE=""
  REMOTE_CLEARED=""
  SCAN_SUBMODULE_CHANGES=0; SALVAGE_CARRIED=""; SALVAGE_SUBMODULES=""; CARRY_SIGNATURE=""
  module_plan_reset
  module_carried_reset

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
      # Work held in a submodule is not in the parent's salvage refs. Whether it can be
      # carried to the main checkout's repository for that submodule is decided with the
      # other salvage blockers (nested_repository_blocker), after every gate below; when it
      # cannot, the worktree is kept there, as it was kept here before (#2831).
      SCAN_SUBMODULE_CHANGES=$REAL_SUBMODULE_CHANGES
      salvage_reason="${salvage_reason:+$salvage_reason; }$REAL_CHANGES uncommitted change(s), $REAL_SUBMODULE_CHANGES in a submodule"
    else
      salvage_reason="${salvage_reason:+$salvage_reason; }$REAL_CHANGES uncommitted change(s)"
    fi
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
  SCAN_REF_IDS=$reflog_shas
  if [ -n "$reflog_shas" ]; then
    # On a proven squash-merged branch, ancestors of the PR head are accounted for too;
    # a commit reset away from that history is not, and still keeps the worktree.
    # shellcheck disable=SC2086  # merged_head is empty or one sha
    if ! orphaned=$(git -C "$TOPLEVEL" rev-list --no-walk $reflog_shas --not --remotes $merged_head 2>/dev/null); then
      keep "$wt" "cannot check whether reflog or pseudo-ref commits are reachable"; continue
    fi
    # A commit origin advertises is not held only here, whatever the remote-tracking refs
    # say. Asked only when something is left to ask about, so most sweeps never ask.
    if [ -n "$orphaned" ]; then
      remote_held_commits
      unheld=$(not_remote_held "$orphaned") || REMOTE_HELD_FAILED=1
      # What origin accounted for. Nothing local keeps these once the reflog is gone, and
      # origin can drop the ref later, so apply pins each under refs/reaped before removal.
      REMOTE_CLEARED=$(awk 'NR == FNR { if (NF) held[$0]; next } NF && !($0 in held)' \
                       <(printf '%s\n' "$unheld") <(printf '%s\n' "$orphaned"))
      orphaned=$unheld
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
  # salvage_blocker holds each of its submodule repositories to the stricter pristine rule.
  # Past the salvage age, such a repository makes the worktree a salvage candidate too:
  # that work is abandoned like any other, and salvage carries it when it can (#2831). Every
  # gate above has already run, and the salvage blockers decide the rest.
  if [ -z "$salvage_reason" ]; then
    submodule_repositories_disposable "$wt" "$wt_real"; sub_rc=$?
    case "$sub_rc" in
      0) ;;
      1) if ! salvage_eligible "$age_h" "$wt"; then
           keep_stuck "$wt" "submodule repository holds commit(s) its remote lacks ($SUBMODULE_NOTE)"; continue
         fi
         # Without the note: it names a path, and this text goes into a manifest column.
         salvage_reason="a submodule repository holds commit(s) its remote lacks" ;;
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
  if [ -n "$salvage_reason" ]; then
    if salvage_blocker "$wt"; then
      keep_stuck "$wt" "$salvage_reason; not salvaged: $SALVAGE_NOTE"; continue
    fi
  else
    # The same cap resolve_undo_preserve applies, read-only, so dry-run reports what apply does.
    if ! reuc_kb=$(resolve_undo_kb "$wt"); then
      keep_stuck "$wt" "not reaped: cannot read or size the index's resolve-undo entries"; continue
    fi
    if [ "$reuc_kb" -gt "$SALVAGE_MAX_KB" ]; then
      keep_stuck "$wt" "not reaped: the index holds more than ${SALVAGE_MAX_KB} KB of resolve-undo stages"; continue
    fi
  fi
  # The desktop app's marker (#4152) dies with the admin directory on either path, so a
  # plain reap reads it too: anything but the empty file, or no file, keeps the worktree.
  DESKTOP_MARKER_RECORDED=""
  if ! desktop_marker_read "$wt"; then
    keep_stuck "$wt" "not reaped: $DESKTOP_MARKER_NOTE"; continue
  fi
  desktop_marker=$DESKTOP_MARKER_NOW
  if [ "$MODE" = "dry-run" ]; then
    if [ -n "$salvage_reason" ]; then
      # The plan salvage_blocker just built: how many submodules' work apply would carry.
      [ "${#PLAN_G[@]}" -eq 0 ] || salvage_reason="$salvage_reason; work of ${#PLAN_G[@]} submodule(s) carried to the main checkout's"
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
    # Before the blockers look, so a change they then see as harmless still shows below.
    if ! SALVAGE_MODULES_FP=$(modules_fingerprint "$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)"); then
      worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
      # Not examined, so not a clean sweep either.
      REMOTE_MODULE_FAILED=1
      keep_stuck "$wt" "$salvage_reason; not salvaged: cannot read its submodule repositories"; continue
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
  else
    # A plain reap deletes the index too. A merge that was committed and pushed leaves a
    # clean worktree whose index still holds the conflict's resolve-undo stages (#2831).
    if ! resolve_undo_preserve "$wt" "$sha"; then
      worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
      keep_stuck "$wt" "not reaped: $SALVAGE_NOTE"; continue
    fi
  fi
  RESOLVE_UNDO_SAVED=1

  # A manifest write failure is an INFRASTRUCTURE failure, not a per-worktree verdict:
  # the ledger is unwritable, so every subsequent removal would be unrecorded too.
  # Aborting (rather than keeping and carrying on) is what stops the wrapper reporting
  # a healthy sweep — which matters most under the disk pressure this tool exists for.
  # A squash-merged reap is NOT reachable from any remote; its commits survive only in the
  # PR head ref, so the ledger must say which of the two made the removal safe.
  reach_evidence="reachable-from-remote"
  [ -n "$merged_head" ] && reach_evidence="merged-pr-head"
  [ -n "$SALVAGE_REF" ] && reach_evidence="salvaged=$SALVAGE_REF ($salvage_reason)"
  # One `submodule=<path under the git directory>` field per submodule whose work was
  # carried: the same ref names exist in that repository of the main checkout.
  [ -n "$SALVAGE_SUBMODULES" ] && reach_evidence="$reach_evidence;$SALVAGE_SUBMODULES"
  [ -n "$RESOLVE_UNDO_REF" ] && reach_evidence="$reach_evidence;resolve-undo=$RESOLVE_UNDO_REF"
  # The desktop app's empty marker dies with the admin directory; the row keeps the fact,
  # so a restore can tell the folder was a desktop-app session (#4152). Read again under
  # the mutex; the shared final recheck compares it with the row: the row must say what is deleted.
  if ! desktop_marker_read "$wt"; then
    worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
    keep_stuck "$wt" "not reaped: $DESKTOP_MARKER_NOTE"; continue
  fi
  desktop_marker=$DESKTOP_MARKER_NOW
  [ "$desktop_marker" = empty ] && reach_evidence="$reach_evidence;desktop-marker=empty"
  DESKTOP_MARKER_RECORDED=$desktop_marker
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
  pin_failed=""
  while IFS= read -r pin; do
    [ -n "$pin" ] || continue
    git -C "$TOPLEVEL" update-ref "refs/reaped/$pin" "$pin" 2>/dev/null || { pin_failed=$pin; break; }
  done <<< "$REMOTE_CLEARED"
  if [ -n "$pin_failed" ]; then
    worktree_claim_lock_release || die "cannot release ownership mutex for $wt_real"
    keep "$wt" "could not write refs/reaped/$pin_failed — refusing to remove"; continue
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
if [ "$DESKTOP_MARKER_UNREAD" -ne 0 ]; then
  # A worktree whose admin directory could not be read was kept without a verdict (#4152).
  printf 'worktree-cleanup: UNKNOWN — could not read a worktree'"'"'s git state for the desktop app'"'"'s marker, so it was kept unexamined (#4152)\n'
  [ "$REMOTE_MODULE_FAILED" -ne 0 ] || [ "$REMOTE_HELD_FAILED" -ne 0 ] || exit 2
fi
if [ "$REMOTE_MODULE_FAILED" -ne 0 ]; then
  # The same reasoning as below, for a submodule's remote: its worktree was kept unexamined.
  printf 'worktree-cleanup: UNKNOWN — could not read a submodule repository or its remote, so the worktrees kept for it were kept unexamined (#2831)\n' >&2
  [ "$REMOTE_HELD_FAILED" -ne 0 ] || exit 2
fi
if [ "$REMOTE_HELD_FAILED" -ne 0 ]; then
  # Said last and with exit 2: the worktrees kept for a reflog-only commit above were kept
  # without evidence either way, so this sweep did not show they hold abandoned work.
  printf 'worktree-cleanup: UNKNOWN — could not establish which reflog-only commits origin holds, so the worktrees kept for one were kept unexamined (#2831)\n' >&2
  exit 2
fi
