#!/usr/bin/env bash
# Reap abandoned per-session worktrees under <repo>/.claude/worktrees/.
#
# Usage: worktree-cleanup.sh <repo_path> <manifest> [dry-run|apply] [min_age_hours]
#   dry-run (default) — report what WOULD be reaped; write NOTHING to the manifest
#   apply             — record each removal to the manifest, then remove
#   Any other MODE value exits non-zero: a typo must not silently mean "delete", and
#   must not pollute the restore ledger (same contract as branch-cleanup.sh).
#   min_age_hours (default 24) — never reap a worktree younger than this.
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
# Submodule gitlink drift (` M applications/ksail`) and stray tool dirs (`?? .codex/`)
# are NOT authored work — they are an artifact of the submodule checkout sitting at a
# different, already-committed commit. They are treated as noise ONLY after the
# submodule itself is confirmed clean and fully pushed.
#
# In apply mode every removal is recorded (path -> branch -> sha -> evidence) to the
# manifest BEFORE the removal, and the write is verified — no restore record, no
# removal. dry-run never touches the manifest.
set -uo pipefail

REPO_PATH=${1:-}
MANIFEST=${2:-}
MODE=${3:-dry-run}
MIN_AGE_HOURS=${4:-24}

die() { printf 'worktree-cleanup: %s\n' "$1" >&2; exit 2; }

[ -n "$REPO_PATH" ] || die "usage: worktree-cleanup.sh <repo_path> <manifest> [dry-run|apply] [min_age_hours]"
[ -n "$MANIFEST" ] || die "usage: worktree-cleanup.sh <repo_path> <manifest> [dry-run|apply] [min_age_hours]"
[ -d "$REPO_PATH" ] || die "repo_path is not a directory: $REPO_PATH"

case "$MODE" in
  apply|dry-run) ;;
  *) die "invalid MODE '$MODE' (expected 'apply' or 'dry-run')" ;;
esac

case "$MIN_AGE_HOURS" in
  ''|*[!0-9]*) die "min_age_hours must be a non-negative integer, got '$MIN_AGE_HOURS'" ;;
esac

TOPLEVEL=$(git -C "$REPO_PATH" rev-parse --show-toplevel 2>/dev/null) \
  || die "not a git repository: $REPO_PATH"
# Resolve through symlinks so the lsof CWD comparison below is apples-to-apples
# (/tmp is a symlink to /private/tmp on macOS; an unresolved prefix would silently
# match nothing and every worktree would read as "no live process").
TOPLEVEL=$(cd "$TOPLEVEL" && pwd -P) || die "cannot resolve toplevel"
WT_ROOT="$TOPLEVEL/.claude/worktrees"

if [ ! -d "$WT_ROOT" ]; then
  printf 'worktree-cleanup: no worktree root at %s — nothing to do\n' "$WT_ROOT"
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

now=$(date +%s)
reaped=0; kept=0; freed_kb=0

record() { # path branch sha evidence
  local line
  line=$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")
  printf '%s\n' "$line" >> "$MANIFEST" || return 1
  # Verify the WHOLE record landed, not just the path: a path substring is already
  # present whenever the same worktree was reaped in an earlier sweep, so a
  # path-only check would confirm a write that never happened.
  grep -qxF -- "$line" "$MANIFEST" || return 1
  return 0
}

keep() { kept=$((kept+1)); printf 'KEEP   %-52s %s\n' "$(basename "$1")" "$2"; }

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
is_locked_now() {
  local target=$1 out rc line p resolved
  out=$(git -C "$TOPLEVEL" worktree list --porcelain 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    return 0   # cannot prove it is unlocked
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
  [ -n "$status" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    code=${line:0:2}; path=${line:3}
    case "$code" in
      '??')
        case "$path" in
          .codex/|.agents/|.DS_Store|.claude/worktrees/) ;;
          *) REAL_CHANGES=$((REAL_CHANGES+1)) ;;
        esac
        ;;
      ' M')
        # ONLY the unstaged form is drift. A STAGED gitlink update (`M ` / `MM`) is
        # deliberate authored intent, and it lives solely in this worktree's own index —
        # removing the worktree destroys it with no commit to recover from. Those fall
        # through to the default branch below and count as real work.
        if [ -e "$wt/$path/.git" ]; then
          sub_status=$(git -C "$wt/$path" status --porcelain 2>/dev/null)
          sub_sha=$(git -C "$wt/$path" rev-parse HEAD 2>/dev/null)
          sub_unpushed=$(git -C "$wt/$path" rev-list --count "$sub_sha" --not --remotes 2>/dev/null)
          if [ -n "$sub_status" ] || [ -z "$sub_unpushed" ] || [ "$sub_unpushed" -gt 0 ]; then
            REAL_CHANGES=$((REAL_CHANGES+1))
          fi
        else
          REAL_CHANGES=$((REAL_CHANGES+1))
        fi
        ;;
      *) REAL_CHANGES=$((REAL_CHANGES+1)) ;;
    esac
  done <<< "$status"
  return 0
}

for wt in "$WT_ROOT"/*/; do
  [ -d "$wt" ] || continue
  wt=${wt%/}
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || { keep "$wt" "unreadable"; continue; }
  name=$(basename "$wt")

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
  if is_locked_now "$wt_real"; then
    keep "$wt" "locked"; continue
  fi

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

  # KEEP: unresolvable HEAD
  sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { keep "$wt" "no HEAD"; continue; }
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached)")

  # KEEP: commits not reachable from any remote — the sole-copy-of-real-work test.
  # Covers an unpushed branch and an orphan detached HEAD in one call.
  unpushed=$(git -C "$TOPLEVEL" rev-list --count "$sha" --not --remotes 2>/dev/null)
  if [ -z "$unpushed" ]; then
    keep "$wt" "cannot determine push state"; continue      # fail closed
  fi
  if [ "$unpushed" -gt 0 ]; then
    keep "$wt" "$unpushed unpushed commit(s) on $branch"; continue
  fi

  # KEEP: real working-tree changes. Submodule gitlinks and known tool-noise dirs are
  # filtered out; everything else counts as authored work.
  status=$(git -C "$wt" status --porcelain 2>/dev/null) || {
    keep "$wt" "cannot read status"; continue; }
  count_real_changes "$wt" "$status"
  if [ "$REAL_CHANGES" -gt 0 ]; then
    keep "$wt" "$REAL_CHANGES uncommitted change(s)"; continue
  fi

  # --- REAP ------------------------------------------------------------------------
  sz_kb=$(du -sk "$wt" 2>/dev/null | cut -f1); sz_kb=${sz_kb:-0}
  if [ "$MODE" = "dry-run" ]; then
    printf 'REAP   %-52s %s (%s MB)\n' "$name" "$branch" "$((sz_kb/1024))"
    reaped=$((reaped+1)); freed_kb=$((freed_kb+sz_kb))
    continue
  fi

  if ! record "$wt_real" "$branch" "$sha" "reachable-from-remote;no-live-process;age=${age_h}h"; then
    keep "$wt" "MANIFEST WRITE FAILED — refusing to remove"; continue
  fi
  # Containment assertion before ANY recursive delete. $wt_real is derived from a glob
  # under $WT_ROOT and should always sit beneath it, but `rm -rf` is unforgiving enough
  # that the invariant is asserted rather than assumed — a bug upstream of here must not become a recursive delete of the checkout (or of /).
  # (belt-and-braces; the glob already constrains it)
  case "$wt_real" in
    "$WT_ROOT"/?*) : ;;
    *) keep "$wt" "REFUSING to remove: '$wt_real' is not under '$WT_ROOT'"; continue ;;
  esac

  # Re-check the lock against LIVE state, not the snapshot taken at startup. A lock
  # acquired while this sweep was running would otherwise be overridden by --force,
  # which git documents as "force removal even if worktree is dirty or locked".
  if is_locked_now "$wt_real"; then
    keep "$wt" "locked (acquired since the startup snapshot)"; continue
  fi

  # Keep the reaped commit reachable so the manifest's SHA stays restorable. Without
  # this, a stale remote-tracking ref can make a commit look pushed, and a later
  # fetch --prune + gc would collect the only copy — leaving a manifest entry that
  # cannot be restored. One ref per commit; the name is the SHA, so it is idempotent.
  # This is a PRECONDITION of removal, not best-effort: no restore ref, no deletion —
  # the same rule the manifest write already follows.
  if ! git -C "$TOPLEVEL" update-ref "refs/reaped/$sha" "$sha" 2>/dev/null; then
    keep "$wt" "could not write refs/reaped/$sha — refusing to remove"; continue
  fi

  if git -C "$TOPLEVEL" worktree remove --force "$wt_real" 2>/dev/null \
     || { ! is_locked_now "$wt_real" && rm -rf "$wt_real" && git -C "$TOPLEVEL" worktree prune; }; then
    printf 'REAPED %-52s %s (%s MB)\n' "$name" "$branch" "$((sz_kb/1024))"
    reaped=$((reaped+1)); freed_kb=$((freed_kb+sz_kb))
  else
    keep "$wt" "removal FAILED"
  fi
done

# Drop admin entries whose directory is already gone.
if [ "$MODE" = "apply" ]; then
  git -C "$TOPLEVEL" worktree prune 2>/dev/null || true
fi

printf '\nworktree-cleanup: mode=%s reaped=%d kept=%d freed=%d MB\n' \
  "$MODE" "$reaped" "$kept" "$((freed_kb/1024))"
