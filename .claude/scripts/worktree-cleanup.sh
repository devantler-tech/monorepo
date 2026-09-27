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
#   KEEP  - the main worktree, and anything outside <repo>/.claude/worktrees/
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
#   KEEP  - a worktree whose modified submodule itself has uncommitted or unpushed work
#   KEEP  - a worktree locked at removal time, re-checked live (never overridden by
#           --force, and never removed by the rm -rf fallback either)
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
#                                   deletions and untracked non-ignored files), parent HEAD
#   refs/salvaged/<id>/reflog/<sha> - every HEAD-reflog, ORIG_HEAD or FETCH_HEAD commit reachable from no remote
# Restore: `git worktree add --detach <path> refs/salvaged/<id>/head`, then
# `git -C <path> read-tree refs/salvaged/<id>/index` for the staged index and
# `git -C <path> restore --source=refs/salvaged/<id>/worktree --worktree -- .` for the working
# tree. `restore` does not overlay, so paths the salvaged tree deleted are deleted again.
# The salvaged blobs are the working tree's exact bytes (conversion_blocker checks that), but
# `restore` runs checkout-side conversions (smudge filters, eol=crlf) on the way out; for a
# byte-exact copy of one path read the blob raw: `git cat-file blob refs/salvaged/<id>/worktree:<path>`.
# Every other gate is unchanged, and salvage fails closed to the old KEEP:
#   KEEP  - a salvage candidate whose submodule holds uncommitted or unpushed work (the
#           submodule's repository lives inside the worktree's admin dir and dies with it)
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
# bytes. A submodule repository's local branch or lightweight tag NAME that points at a
# commit a remote already has is not kept: the commit survives on the remote, and a fetch
# brings every remote tag back, so the only thing lost is a local label. Blocking on it
# would keep nearly every submodule, since fetched tags are indistinguishable offline.
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

REPO_PATH=${1:-}
MANIFEST=${2:-}
MODE=${3:-dry-run}
MIN_AGE_HOURS=${4:-24}
SALVAGE_AGE_HOURS=${5:-0}
# Changed plus untracked bytes above which a tree is kept rather than copied into the
# object store: a stray multi-gigabyte artifact would otherwise become permanent history.
SALVAGE_MAX_KB=${WORKTREE_SALVAGE_MAX_KB:-102400}

die() { printf 'worktree-cleanup: %s\n' "$1" >&2; exit 2; }

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
TOPLEVEL=$(cd "$TOPLEVEL" && pwd -P) || die "cannot resolve toplevel"
WT_ROOT="$TOPLEVEL/.claude/worktrees"

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
GH_REPO=""
origin_url=$(git -C "$TOPLEVEL" remote get-url origin 2>/dev/null || true)
gh_repo_name=""
case "$origin_url" in
  https://github.com/devantler-tech/*)       gh_repo_name=${origin_url#https://github.com/devantler-tech/} ;;
  git@github.com:devantler-tech/*)           gh_repo_name=${origin_url#git@github.com:devantler-tech/} ;;
  ssh://git@github.com/devantler-tech/*)     gh_repo_name=${origin_url#ssh://git@github.com/devantler-tech/} ;;
esac
gh_repo_name=${gh_repo_name%.git}
case "$gh_repo_name" in
  ''|*[!A-Za-z0-9._-]*) ;;
  *) GH_REPO="devantler-tech/$gh_repo_name" ;;
esac

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

if [ ! -d "$WT_ROOT" ]; then
  # Still prune. A repository whose worktree directories (and .claude/worktrees itself)
  # are already gone can retain STALE registrations, and those keep pinning their
  # branches in branch-cleanup.sh's keep-set — the coupling this tool exists to break.
  # Returning early here left exactly that state unrepairable.
  if [ "$MODE" = "apply" ]; then
    git -C "$TOPLEVEL" worktree prune 2>/dev/null \
      || die "no worktree root at $WT_ROOT and 'git worktree prune' failed — stale registrations remain"
  fi
  printf 'worktree-cleanup: no worktree root at %s — pruned stale registrations only\n' "$WT_ROOT"
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
LIVE_CWDS=$(printf '%s\n' "$LIVE_RAW" | grep '^n' | sed 's/^n//' | sort -u)
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
  | while IFS= read -r p; do (cd "$p" 2>/dev/null && pwd -P); done)

now=$(date +%s)
reaped=0; kept=0; stuck=0; salvaged=0; freed_kb=0

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

# ownership_claim_state <worktree> -> 0 active, 1 absent/expired, 2 malformed.
# A malformed marker is ambiguous session state and therefore a KEEP, never a reap.
ownership_claim_state() {
  local wt=$1 marker="$1/$WORKTREE_CLAIM_MARKER_NAME" owner="" created_at="" key val created_epoch now_epoch age
  CLAIM_DETAIL=""
  [ -e "$marker" ] || return 1
  [ -f "$marker" ] || { CLAIM_DETAIL="marker is not a regular file"; return 2; }
  while IFS='=' read -r key val; do
    case "$key" in
      owner) owner=$val ;;
      created_at) created_at=$val ;;
    esac
  done < "$marker"
  if [ -z "$owner" ] || [ -z "$created_at" ]; then
    CLAIM_DETAIL="marker lacks owner or created_at"
    return 2
  fi
  created_epoch=$(worktree_claim_iso_to_epoch "$created_at") || {
    CLAIM_DETAIL="marker has unparseable created_at"
    return 2
  }
  now_epoch=$(date -u +%s)
  age=$((now_epoch - created_epoch))
  if [ "$age" -lt "$WORKTREE_CLAIM_TTL_SECS" ]; then
    CLAIM_DETAIL="owner=$owner created_at=$created_at"
    return 0
  fi
  return 1
}

# is_locked_now <resolved-worktree-path> — re-queries git rather than consulting a
# startup snapshot, so a lock taken DURING the sweep is still honoured.
#
# FAILS CLOSED: if git cannot be queried, the answer is "locked". This runs immediately
# before `rm -rf`, so "I could not tell" must never resolve to "safe to delete".
#
# Compares the recorded path BOTH raw and symlink-resolved. git prints worktree paths
# as they were recorded at `worktree add` time, while $wt_real is pwd -P normalised; if
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
        resolved=$(cd "$p" 2>/dev/null && pwd -P) || resolved=""
        if [ -n "$resolved" ] && [ "$resolved" = "$target" ]; then return 0; fi
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
    # The same for a submodule: a commit made there and reset back to the gitlink changes
    # nothing the checks above compare, and the removal deletes the submodule's repository.
    # The configuration that decides whether status can see an edit (conversion_blocker) can
    # change after the snapshot too, and then every comparison above is blind to the edit.
    if submodule_local_only_blocker "$wt" || admin_modules_blocker "$wt" || worktree_state_blocker "$wt" \
       || conversion_blocker "$wt"; then
      keep "$wt" "$SALVAGE_NOTE, after the salvage snapshot ($SALVAGE_REF)"; return 1
    fi
  elif [ -n "$salvage_reason" ]; then
    # Salvage candidate before its snapshot: its changes are expected and are about to be
    # preserved, but not work in a submodule, which salvage cannot capture.
    if [ "$REAL_SUBMODULE_CHANGES" -gt 0 ]; then
      keep "$wt" "submodule work appeared during the sweep (cannot be salvaged)"; return 1
    fi
  elif [ "$REAL_CHANGES" -gt 0 ]; then
    keep "$wt" "$REAL_CHANGES uncommitted change(s) appeared during the sweep"; return 1
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
    sub_real=$(cd "$sub" 2>/dev/null && pwd -P) || return 1
    wts=$(git -C "$sub" worktree list --porcelain 2>/dev/null) || return 1
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) path=${line#worktree } ;;
        *) continue ;;
      esac
      # A pruned-but-registered path no longer resolves; compare it as written, which is
      # still enough to see that it sits inside the candidate.
      path_real=$(cd "$path" 2>/dev/null && pwd -P) || path_real=$path
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
  local wt=$1 status=$2 line code path sub_status sub_sha sub_unpushed
  REAL_CHANGES=0
  # The subset of REAL_CHANGES held in a submodule. Salvage cannot preserve those: a
  # linked worktree's submodule repository lives in its admin dir and dies with it.
  REAL_SUBMODULE_CHANGES=0
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
          if [ "$sub_status_rc" -ne 0 ] || [ -n "$sub_status" ] \
             || [ -z "$sub_unpushed" ] || [ "$sub_unpushed" -gt 0 ]; then
            REAL_CHANGES=$((REAL_CHANGES+1)); REAL_SUBMODULE_CHANGES=$((REAL_SUBMODULE_CHANGES+1))
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
# salvage_eligible <age_h> — 0 when salvage is on and the worktree is old enough for it.
salvage_eligible() {
  [ "$SALVAGE_AGE_HOURS" -gt 0 ] && [ "$1" -ge "$SALVAGE_AGE_HOURS" ]
}

# salvage_blocker <worktree> -> 0 and SALVAGE_NOTE set when the tree must NOT be salvaged;
# 1 when nothing blocks it. Read-only, so dry-run reports what apply would actually do.
# An untracked directory listed with a trailing `/` holds its own .git: `git add` would
# record a bare gitlink and none of its files. Any read failure blocks.
salvage_blocker() {
  local wt=$1 list rc f total_kb=0 sz
  SALVAGE_NOTE=""
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
  list=$(git -C "$wt" ls-files -z -m -o --exclude-standard 2>/dev/null | tr '\0' '\n'); rc=$?
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
  # A linked worktree's submodule repositories live in its admin directory and are deleted
  # with it, and salvage records only their gitlinks.
  submodule_local_only_blocker "$wt" && return 0
  admin_modules_blocker "$wt" && return 0
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
      HEAD|ORIG_HEAD|FETCH_HEAD|COMMIT_EDITMSG|commondir|gitdir|index|config.worktree|logs|refs|modules) ;;
      *) SALVAGE_NOTE="the worktree's git state holds ${entry##*/} (salvage cannot carry it)"; return 0 ;;
    esac
  done
  if [ -d "$admin/refs" ]; then
    # The ownership mutex this sweep holds is itself a per-worktree ref; it guards the
    # removal and carries no work, so it is the one ref excluded.
    refs=$(find "$admin/refs" ! -type d ! -path "$admin/$WORKTREE_CLAIM_LOCK_REF_PREFIX/*" 2>/dev/null) \
      || { SALVAGE_NOTE="cannot list per-worktree refs"; return 0; }
    if [ -n "$refs" ]; then
      SALVAGE_NOTE="per-worktree refs exist (salvage cannot carry them)"; return 0
    fi
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
  # would lose its only reference with the admin directory.
  local pseudo
  pseudo=$(pseudo_ref_commits "$admin") || { SALVAGE_NOTE="cannot read the worktree's pseudo-refs"; return 0; }
  if pseudo_ref_tag "$admin" "$pseudo"; then
    SALVAGE_NOTE="ORIG_HEAD or FETCH_HEAD names a tag (salvage cannot carry it)"; return 0
  fi
  return 1
}

# unclassified_module_content <modules-dir> -> prints the first non-directory entry below
# <modules-dir> that lies in no repository (a directory holding HEAD and objects/), searching
# each repository's own modules/ the same way. Prints nothing when every file is accounted
# for; non-zero on a read failure, so the caller fails closed.
unclassified_module_content() {
  local dir=$1 list entry nested
  [ -d "$dir" ] || return 0
  list=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-modules.XXXXXX") || return 1
  # Repositories are printed and pruned; any other non-directory is stray. NUL-delimited, so
  # a path holding a newline is neither split nor skipped.
  if ! find "$dir" -mindepth 1 \
         \( -type d -exec test -f '{}/HEAD' \; -exec test -d '{}/objects' \; -print0 -prune \) \
         -o \( ! -type d -print0 \) > "$list" 2>/dev/null; then
    rm -f "$list"; return 1
  fi
  local entries=()
  while IFS= read -r -d '' entry; do entries+=("$entry"); done < "$list"
  rm -f "$list"
  for entry in ${entries[@]+"${entries[@]}"}; do
    if [ -d "$entry" ] && [ ! -L "$entry" ]; then
      nested=$(unclassified_module_content "$entry/modules") || return 1
      [ -z "$nested" ] || { printf '%s\n' "$nested"; return 0; }
    else
      printf '%s\n' "$entry"; return 0
    fi
  done
  return 0
}

# pseudo_ref_tag <gitdir> <shas> -> 0 when any of the (pseudo-ref) objects is not a commit, or
# its type cannot be read. `rev-list` would peel an annotated tag to its commit and preserve
# only that, losing the tag object's message or signature.
pseudo_ref_tag() {
  local g=$1 sha
  for sha in $2; do
    [ "$(git --git-dir="$g" --work-tree="$g" cat-file -t "$sha" 2>/dev/null)" = commit ] || return 0
  done
  return 1
}

gitdir_state_blocker() { # <submodule-gitdir> <label> -> 0 with SALVAGE_NOTE when it holds state
  # The same whitelist as the worktree's own admin directory, for a submodule repository the
  # removal deletes: every entry must be ordinary repository content. A bisect, sequencer,
  # rebase or merge state, a linked worktree's admin dir, or anything unknown blocks.
  local g=$1 label=$2 entry
  for entry in "$g"/* "$g"/.[!.]* "$g"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "${entry##*/}" in
      HEAD|ORIG_HEAD|FETCH_HEAD|COMMIT_EDITMSG|config|config.worktree|description|objects|refs|packed-refs|logs|index|modules|shallow|branches) ;;
      hooks|info)
        # A hook someone wrote may exist nowhere else (see custom_git_metadata).
        custom_git_metadata "$entry" \
          && { SALVAGE_NOTE="submodule $label has a customized ${entry##*/}/ ($SALVAGE_NOTE)"; return 0; } ;;
      worktrees)
        if [ -n "$(ls -A "$entry" 2>/dev/null || echo unreadable)" ]; then
          SALVAGE_NOTE="submodule $label has linked worktrees (removing it would orphan them)"; return 0
        fi ;;
      *) SALVAGE_NOTE="submodule $label holds ${entry##*/} (salvage cannot carry it)"; return 0 ;;
    esac
  done
  if [ -e "$g/refs/bisect" ]; then
    SALVAGE_NOTE="submodule $label is mid-bisect (salvage cannot carry it)"; return 0
  fi
  # `rev-list` checks commits only: an annotated tag (its message or signature), or a ref
  # straight to a tree or blob, is not covered by "every commit is on a remote". Measured on
  # the host, 1 of 284 retained submodule repositories holds such a ref, so refusing costs
  # almost nothing.
  local types
  types=$(git --git-dir="$g" --work-tree="$g" for-each-ref --format='%(objecttype)' 2>/dev/null) \
    || { SALVAGE_NOTE="cannot list the refs of submodule $label"; return 0; }
  if grep -qvx commit <<< "$types" && [ -n "$types" ]; then
    SALVAGE_NOTE="submodule $label has a ref to a tag, tree or blob (salvage cannot carry it)"; return 0
  fi
  # ORIG_HEAD and FETCH_HEAD are outside `rev-list --all --reflog`; a commit only they name
  # would die with the repository.
  # A reflog can hold the only reference to a tag object a ref once pointed at; `rev-list
  # --reflog` peels it. Every object any reflog names must therefore be a commit (a missing
  # object has nothing left to lose).
  local reflog_types
  reflog_types=$( { find "$g/logs" -type f -exec cat {} + 2>/dev/null || [ ! -d "$g/logs" ]; } \
                  | awk '{ for (i = 1; i <= 2; i++) if ((length($i) == 40 || length($i) == 64) && $i ~ /^[0-9a-f]+$/ && $i !~ /^0+$/) print $i }' \
                  | sort -u | git --git-dir="$g" --work-tree="$g" cat-file --batch-check='%(objecttype)' 2>/dev/null) \
    || { SALVAGE_NOTE="cannot read the reflogs of submodule $label"; return 0; }
  if grep -qvE '^(commit|.* missing)$' <<< "$reflog_types" && [ -n "$reflog_types" ]; then
    SALVAGE_NOTE="submodule $label has a reflog naming a tag, tree or blob (salvage cannot carry it)"; return 0
  fi
  local pseudo left sha
  pseudo=$(pseudo_ref_commits "$g") || { SALVAGE_NOTE="cannot read the pseudo-refs of submodule $label"; return 0; }
  if pseudo_ref_tag "$g" "$pseudo"; then
    SALVAGE_NOTE="submodule $label has ORIG_HEAD or FETCH_HEAD naming a tag (salvage cannot carry it)"; return 0
  fi
  if [ -n "$pseudo" ]; then
    # shellcheck disable=SC2086  # one sha per word
    left=$(git --git-dir="$g" --work-tree="$g" rev-list -n 1 $pseudo --not --remotes 2>/dev/null || echo unreadable)
    if [ -n "$left" ]; then
      SALVAGE_NOTE="submodule $label has a commit only ORIG_HEAD or FETCH_HEAD names (cannot be salvaged)"; return 0
    fi
  fi
  # A clean status proves nothing where `git` cannot see the change (see conversion_blocker).
  if [ "$(git --git-dir="$g" --work-tree="$g" config --bool --get core.fileMode 2>/dev/null)" = false ]; then
    SALVAGE_NOTE="submodule $label has core.fileMode=false (mode changes are invisible)"; return 0
  fi
  if [ "$(git --git-dir="$g" --work-tree="$g" config --bool --get core.ignoreCase 2>/dev/null)" = true ] && [ ! -e "$g/head" ]; then
    SALVAGE_NOTE="submodule $label has core.ignoreCase=true on a case-sensitive filesystem"; return 0
  fi
  return 1
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
  paths=$( { git -C "$wt" ls-files -z -c -o --exclude-standard \
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

# admin_modules_blocker <worktree> -> 0, with SALVAGE_NOTE, unless every submodule repository
# stored under the worktree's admin directory — including one whose gitlink was removed, which
# no index enumeration can find — holds only remote-reachable commits and, when its working
# tree still exists, is clean with no hidden-index flags. It checks what the removal would
# actually delete, not what the index happens to list.
admin_modules_blocker() {
  local wt=$1 admin heads h g w wpath wdir st flags label local_only rc wt_real
  admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$admin" ] \
    || { SALVAGE_NOTE="cannot locate the worktree's admin directory"; return 0; }
  [ -d "$admin/modules" ] || return 1
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) && [ -n "$wt_real" ] \
    || { SALVAGE_NOTE="cannot resolve the worktree path"; return 0; }
  heads=$(mktemp "${TMPDIR:-/tmp}/wt-salvage-heads.XXXXXX") \
    || { SALVAGE_NOTE="cannot create a temporary list"; return 0; }
  # A whitelist over what the removal deletes: every file below modules/ must belong to a
  # repository this function then inspects. An interrupted clone or a damaged repository with
  # no HEAD would otherwise be deleted without ever being looked at.
  local stray
  if ! stray=$(unclassified_module_content "$admin/modules"); then
    rm -f "$heads"; SALVAGE_NOTE="cannot inspect the submodule repositories of $wt"; return 0
  fi
  if [ -n "$stray" ]; then
    rm -f "$heads"; SALVAGE_NOTE="the worktree's modules/ holds content outside any repository (${stray#"$admin"/})"; return 0
  fi
  # NUL-delimited: a repository path holding a newline must not be split and skipped.
  find "$admin/modules" \( -type f -o -type l \) -name HEAD -print0 > "$heads" 2>/dev/null \
    || { rm -f "$heads"; SALVAGE_NOTE="cannot list the submodule repositories of $wt"; return 0; }
  local hs=()
  while IFS= read -r -d '' h; do hs+=("$h"); done < "$heads"
  rm -f "$heads"
  for h in ${hs[@]+"${hs[@]}"}; do
    [ -n "$h" ] || continue
    g=${h%/HEAD}
    [ -d "$g/objects" ] || continue                  # a reflog's logs/HEAD, not a repository
    label=${g#"$admin"/}; label=${label//$'\n'/?}   # one output line, even for a newline path
    gitdir_state_blocker "$g" "$label" && return 0
    # --work-tree pins a directory that exists: a removed submodule's core.worktree points at a
    # path that no longer does, and git would refuse every read of the repository.
    local_only=$(git --git-dir="$g" --work-tree="$g" rev-list -n 1 --all --reflog --not --remotes 2>/dev/null) \
      || { SALVAGE_NOTE="cannot read submodule repository $label"; return 0; }
    if [ -n "$local_only" ]; then
      SALVAGE_NOTE="submodule repository $label holds commits no remote has (cannot be salvaged)"; return 0
    fi
    # Exit 1 is the one "no checkout configured" answer; any other failure is unreadable.
    w=$(git --git-dir="$g" --work-tree="$g" config core.worktree 2>/dev/null); rc=$?
    [ "$rc" -eq 1 ] && continue
    [ "$rc" -eq 0 ] && [ -n "$w" ] || { SALVAGE_NOTE="cannot read the checkout of submodule repository $label"; return 0; }
    case "$w" in /*) wpath=$w ;; *) wpath=$g/$w ;; esac
    if ! wdir=$(cd "$wpath" 2>/dev/null && pwd -P); then
      # Only a checkout proven absent carries nothing to lose; one that exists but cannot be
      # entered right now may hold the only copy of its edits.
      path_is_absent "$wpath" && continue
      SALVAGE_NOTE="cannot enter the checkout of submodule repository $label"; return 0
    fi
    # The removal deletes this repository; a checkout outside the worktree would survive it
    # and be left without the repository it depends on.
    case "$wdir/" in
      "$wt_real"/?*) ;;
      *) SALVAGE_NOTE="submodule repository $label has a checkout outside the worktree ($wdir)"; return 0 ;;
    esac
    # A clean status proves nothing where a filter or conversion hides an edit from git.
    if GIT_DIR=$g GIT_WORK_TREE=$wdir conversion_blocker "$wdir"; then
      SALVAGE_NOTE="submodule ${wdir#"$wt"/}: $SALVAGE_NOTE"; return 0
    fi
    st=$(git --git-dir="$g" --work-tree="$wdir" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) \
      || { SALVAGE_NOTE="cannot read the status of submodule ${wdir#"$wt"/}"; return 0; }
    flags=$(git --git-dir="$g" --work-tree="$wdir" ls-files -v 2>/dev/null) \
      || { SALVAGE_NOTE="cannot read the index flags of submodule ${wdir#"$wt"/}"; return 0; }
    if [ -n "$st" ] || grep -q '^[a-zS]' <<< "$flags"; then
      SALVAGE_NOTE="submodule ${wdir#"$wt"/} has uncommitted or hidden-index changes (cannot be salvaged)"; return 0
    fi
    flags=$(git --git-dir="$g" --work-tree="$wdir" ls-files --resolve-undo 2>/dev/null) \
      || { SALVAGE_NOTE="cannot read the resolve-undo entries of submodule ${wdir#"$wt"/}"; return 0; }
    if [ -n "$flags" ]; then
      SALVAGE_NOTE="submodule ${wdir#"$wt"/} has resolve-undo index entries (cannot be salvaged)"; return 0
    fi
  done
  return 1
}

# submodule_local_only_blocker <repo> -> 0, with SALVAGE_NOTE set, when an initialised
# submodule of <repo> (recursively) holds any commit that no remote-tracking ref reaches, or
# cannot be read; 1 otherwise. Salvage keeps only a submodule's gitlink, so the rule is a
# whitelist: every commit a submodule knows locally — through HEAD, any branch or tag, or any
# reflog — must already be on a remote. A submodule clean at its gitlink shows no status
# entry at all, so status cannot answer this. Submodules are enumerated from the index's
# gitlinks, not `git submodule foreach`, which skips a populated submodule that is not
# registered as active and would fail open on it.
submodule_local_only_blocker() {
  local repo=$1 links line path local_only sub_st sub_flags sub_gitdir
  links=$(git -C "$repo" ls-files -s -z 2>/dev/null | tr '\0\n' '\n\001') \
    || { SALVAGE_NOTE="cannot list the gitlinks of $repo for salvage"; return 0; }
  case "$links" in
    *$'\001'*) SALVAGE_NOTE="a tracked path in $repo holds a newline (cannot classify it)"; return 0 ;;
  esac
  while IFS= read -r line; do
    case "$line" in 160000\ *) ;; *) continue ;; esac
    path=${line#*$'\t'}
    if [ ! -e "$repo/$path/.git" ] && [ ! -L "$repo/$path/.git" ]; then
      # Not initialised: nothing local to lose only when the directory is empty (or gone).
      # Status reports a populated uninitialised gitlink directory as clean, and the removal
      # would delete whatever files sit in it.
      [ -e "$repo/$path" ] || [ -L "$repo/$path" ] || continue
      [ -z "$(ls -A "$repo/$path" 2>/dev/null || echo unreadable)" ] && continue
      SALVAGE_NOTE="uninitialised submodule directory $path is not empty (cannot be salvaged)"; return 0
    fi
    local_only=$(git -C "$repo/$path" rev-list -n 1 --all --reflog --not --remotes 2>/dev/null) \
      || { SALVAGE_NOTE="cannot list the local commits of submodule $path"; return 0; }
    if [ -n "$local_only" ]; then
      SALVAGE_NOTE="submodule $path holds commits no remote has (cannot be salvaged)"; return 0
    fi
    sub_gitdir=$(git -C "$repo/$path" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$sub_gitdir" ] \
      || { SALVAGE_NOTE="cannot locate the repository of submodule $path"; return 0; }
    gitdir_state_blocker "$sub_gitdir" "$path" && return 0
    # Wherever its repository is stored (absorbed or an embedded .git directory), an
    # initialised submodule must be clean and carry no hidden-index flags: salvage keeps
    # only its gitlink, so an edit status cannot see would be deleted unrecorded.
    sub_st=$(git -C "$repo/$path" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) \
      || { SALVAGE_NOTE="cannot read the status of submodule $path"; return 0; }
    sub_flags=$(git -C "$repo/$path" ls-files -v 2>/dev/null) \
      || { SALVAGE_NOTE="cannot read the index flags of submodule $path"; return 0; }
    if [ -n "$sub_st" ] || grep -q '^[a-zS]' <<< "$sub_flags"; then
      SALVAGE_NOTE="submodule $path has uncommitted or hidden-index changes (cannot be salvaged)"; return 0
    fi
    sub_flags=$(git -C "$repo/$path" ls-files --resolve-undo 2>/dev/null) \
      || { SALVAGE_NOTE="cannot read the resolve-undo entries of submodule $path"; return 0; }
    if [ -n "$sub_flags" ]; then
      SALVAGE_NOTE="submodule $path has resolve-undo index entries (cannot be salvaged)"; return 0
    fi
    # A clean status proves nothing where a filter or conversion hides an edit from git.
    if conversion_blocker "$repo/$path"; then
      SALVAGE_NOTE="submodule $path: $SALVAGE_NOTE"; return 0
    fi
    submodule_local_only_blocker "$repo/$path" && return 0
  done <<< "$links"
  return 1
}

# snapshot_tree <worktree> -> sets SNAPSHOT_TREE to the tree of the WHOLE working tree
# (tracked edits, deletions, untracked non-ignored files), built in a throwaway index so the
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
  if ! GIT_INDEX_FILE=$idx git -C "$wt" read-tree HEAD 2>/dev/null \
     || ! GIT_INDEX_FILE=$idx git -C "$wt" add -A -- . 2>/dev/null; then
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

# reflog_orphans <repo> -> prints every HEAD-reflog commit of <repo> that no remote-tracking
# ref reaches, one per line. Non-zero on any read failure, so callers fail closed. Used for a
# worktree and for each of its initialised submodules.
reflog_orphans() {
  local reflog gitdir pseudo
  reflog=$(git -C "$1" reflog show --format=%H HEAD 2>/dev/null) || return 1
  # ORIG_HEAD and FETCH_HEAD live in the same admin directory and can name the only
  # reference to a commit (a fetched ref deleted upstream, a reset-away tip), so they are
  # preserved like the reflog.
  gitdir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$gitdir" ] || return 1
  pseudo=$(pseudo_ref_commits "$gitdir") || return 1
  [ -n "$reflog$pseudo" ] || return 0
  # shellcheck disable=SC2086  # one sha per word
  git -C "$1" rev-list --no-walk $reflog $pseudo --not --remotes 2>/dev/null | sort -u
}

# pseudo_ref_commits <gitdir> -> prints each commit ORIG_HEAD or FETCH_HEAD in <gitdir> names
# that still exists (a missing object has nothing left to lose). Non-zero on a read failure.
pseudo_ref_commits() {
  local g=$1 f sha
  for f in ORIG_HEAD FETCH_HEAD; do
    [ -e "$g/$f" ] || continue
    [ -r "$g/$f" ] || return 1
    while IFS= read -r sha; do
      sha=${sha%%[[:space:]]*}
      case "$sha" in *[!0-9a-f]*|'') continue ;; esac
      # A commit the object store cannot read right now is not proof there is nothing to lose.
      git --git-dir="$g" --work-tree="$g" cat-file -e "$sha^{commit}" 2>/dev/null || return 1
      printf '%s\n' "$sha"
    done < "$g/$f"
  done
  return 0
}

# path_is_absent <path> -> 0 only when <path> provably does not exist: its nearest existing
# ancestor can be searched, so the missing entry is a real ENOENT and not a permission or
# transient failure that hides an existing directory.
path_is_absent() {
  local p=$1 d
  [ -e "$p" ] || [ -L "$p" ] && return 1
  d=$(dirname "$p")
  while [ ! -e "$d" ]; do
    [ "$d" != / ] && [ "$d" != . ] || return 1
    d=$(dirname "$d")
  done
  [ -d "$d" ] && [ -x "$d" ]
}

# custom_git_metadata <dir> -> 0, with SALVAGE_NOTE, when a repository's hooks/ or info/
# directory holds anything but ordinary scaffolding: `*.sample` hooks, and info/exclude. A
# hook is code someone may have written nowhere else; an exclude rule only hides files and
# holds no work, and tooling appends to it (worktree-claim.sh's owner marker). Anything
# else, or a read failure, counts as customized.
custom_git_metadata() {
  local dir=$1 f
  # An unreadable directory would glob to nothing and read as pristine.
  if [ -L "$dir" ] || [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    SALVAGE_NOTE="unreadable or not a directory"; return 0
  fi
  for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    case "${dir##*/}/${f##*/}" in
      hooks/*.sample|info/exclude) [ -f "$f" ] && [ ! -L "$f" ] && continue ;;
    esac
    SALVAGE_NOTE=${f##*/}; return 0
  done
  return 1
}

# salvage_write <worktree> <sha> -> writes and verifies refs/salvaged/<id>/*, setting
# SALVAGE_REF, SALVAGE_TREE (whole working tree) and SALVAGE_INDEX_TREE (staged index).
# Returns non-zero, with SALVAGE_NOTE, on any failure; refs already written stay (they
# only preserve data) and the caller KEEPs the worktree.
salvage_write() {
  local wt=$1 sha=$2 id base idx_tree wt_tree idx_commit wt_commit orphans o path_id
  SALVAGE_REF=""; SALVAGE_TREE=""; SALVAGE_INDEX_TREE=""
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
  bn=$(printf '%s' "$(basename "$wt")" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')
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
  SALVAGE_REF=$base; SALVAGE_TREE=$wt_tree; SALVAGE_INDEX_TREE=$idx_tree
  return 0
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
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) \
    || die "cannot resolve candidate worktree $wt — refusing to continue on an uninspectable tree"
  name=$(wt_label "$wt")
  # Per-candidate salvage state; recheck_mutable_gates reads it, so it must never leak
  # from the previous candidate.
  salvage_reason=""; SALVAGE_REF=""; SALVAGE_TREE=""; SALVAGE_INDEX_TREE=""; SALVAGE_NOTE=""

  # KEEP: anything git does not know as a worktree. Never a deletion candidate.
  # here-string, NOT a pipe: grep -q exits at its first match, printf then takes SIGPIPE,
  # and under pipefail the pipeline reports failure — inverting this very test.
  if ! grep -qxF -- "$wt_real" <<< "$REGISTERED"; then
    keep "$wt" "not a registered worktree"; continue
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
  live=0
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    if [ "$cwd" = "$wt_real" ] || [ "${cwd#"$wt_real"/}" != "$cwd" ]; then
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
      if ! salvage_eligible "$age_h"; then
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
    if ! salvage_eligible "$age_h"; then
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

  # KEEP: commits in this worktree's own HEAD reflog that exist nowhere else. HEAD may be
  # remotely reachable while the reflog still holds an earlier unpushed commit (commit,
  # then reset back to a pushed one). The per-worktree reflog dies with the directory, so
  # that commit's only reference would go with it.
  reflog_shas=$(git -C "$wt" reflog show --format=%H HEAD 2>/dev/null); reflog_rc=$?
  if [ "$reflog_rc" -eq 0 ] && [ -n "$reflog_shas" ]; then
    # On a proven squash-merged branch, ancestors of the PR head are accounted for too;
    # a commit reset away from that history is not, and still keeps the worktree.
    # shellcheck disable=SC2086  # merged_head is empty or one sha
    orphaned=$(git -C "$TOPLEVEL" rev-list --no-walk $reflog_shas --not --remotes $merged_head 2>/dev/null | head -1)
    if [ -n "$orphaned" ]; then
      if ! salvage_eligible "$age_h"; then
        keep_stuck "$wt" "HEAD reflog holds commit(s) reachable from nowhere else (${orphaned:0:12})"
        continue
      fi
      salvage_reason="${salvage_reason:+$salvage_reason; }reflog-only commit(s)"
    fi
  fi

  # --- REAP ------------------------------------------------------------------------
  sz_kb=$(du -sk "$wt" 2>/dev/null | cut -f1); sz_kb=${sz_kb:-0}
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
      printf 'SALVAGE %-51s %s (%s; %s MB%s)\n' "$name" "$branch" "$salvage_reason" "$((sz_kb/1024))" "$ign_note"
      salvaged=$((salvaged+1))
    else
      printf 'REAP   %-52s %s (%s MB%s)\n' "$name" "$branch" "$((sz_kb/1024))" "$ign_note"
    fi
    reaped=$((reaped+1)); freed_kb=$((freed_kb+sz_kb))
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

  # The fallback's prune is deliberately OUTSIDE the success condition: `rm -rf` can
  # succeed while `prune` fails (git's admin dir unwritable), and folding prune into the
  # condition sent an actually-deleted worktree down the "removal FAILED" branch — the
  # run then exited 0 leaving a `pending` row for a path that is already gone.
  # Deletion success is judged by the directory being absent; a failed prune is a
  # separate, loud error.
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
    git -C "$TOPLEVEL" worktree prune 2>/dev/null \
      || die "REMOVED $wt_real but 'git worktree prune' failed — the deletion DID happen; run 'git -C $TOPLEVEL worktree prune' to clear its admin entry (restore ref: refs/reaped/$sha)"
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
    printf 'SALVAGED %-50s %s -> %s (%s MB%s)\n' "$name" "$branch" "$SALVAGE_REF" "$((sz_kb/1024))" "$ign_note"
    salvaged=$((salvaged+1))
  else
    printf 'REAPED %-52s %s (%s MB%s)\n' "$name" "$branch" "$((sz_kb/1024))" "$ign_note"
  fi
  reaped=$((reaped+1)); freed_kb=$((freed_kb+sz_kb))
done 3<<< "$CANDIDATES"

# Drop admin entries whose directory is already gone.
if [ "$MODE" = "apply" ]; then
  # Not best-effort: this prune is what clears missing-worktree registrations, and
  # branch-cleanup.sh builds its keep-set from `git worktree list`. A silently failed
  # prune therefore leaves stale entries pinning branches that should be sweepable.
  git -C "$TOPLEVEL" worktree prune 2>/dev/null \
    || die "reaped $reaped worktree(s) but 'git worktree prune' failed — stale registrations remain and will pin their branches in branch-cleanup.sh"
fi

printf '\nworktree-cleanup: mode=%s reaped=%d kept=%d stuck=%d salvaged=%d freed=%d MB\n' \
  "$MODE" "$reaped" "$kept" "$stuck" "$salvaged" "$((freed_kb/1024))"
if [ "$stuck" -gt 0 ]; then
  printf 'worktree-cleanup: %d of the kept worktree(s) hold abandoned work that no sweep will reap; salvage or discard it (#2831)\n' "$stuck"
fi
