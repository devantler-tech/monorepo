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

# The set of paths git actually knows as worktrees, symlink-resolved. ONLY these are
# ever candidates. Without this filter any ordinary directory placed under
# .claude/worktrees/ enters the loop; having no .git file, every `git -C "$dir"` call
# walks up to the main checkout, whose clean+pushed state then makes the directory look
# eligible — and the rm -rf fallback deletes its arbitrary contents.
REGISTERED=$(printf '%s\n' "$WT_LIST" | awk '/^worktree /{print substr($0,10)}' \
  | while IFS= read -r p; do (cd "$p" 2>/dev/null && pwd -P); done)

now=$(date +%s)
reaped=0; kept=0; freed_kb=0

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

  # KEEP: anything git does not know as a worktree. Never a deletion candidate.
  # here-string, NOT a pipe: grep -q exits at its first match, printf then takes SIGPIPE,
  # and under pipefail the pipeline reports failure — inverting this very test.
  if ! grep -qxF -- "$wt_real" <<< "$REGISTERED"; then
    keep "$wt" "not a registered worktree"; continue
  fi

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
  # --ignore-submodules=none is EXPLICIT too: submodule.<name>.ignore=all in .gitmodules
  # or local config makes status report a clean PARENT even when the submodule holds
  # uncommitted changes, so the submodule-cleanliness branch below never runs.
  # --untracked-files=all is EXPLICIT: a repo inheriting status.showUntrackedFiles=no
  # reports a clean worktree while holding non-ignored untracked authored files, and
  # apply mode would delete their only copy.
  status=$(git -C "$wt" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || {
    keep "$wt" "cannot read status"; continue; }

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
    keep "$wt" "$REAL_CHANGES uncommitted change(s)"; continue
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
  if [ "$MODE" = "dry-run" ]; then
    printf 'REAP   %-52s %s (%s MB%s)\n' "$name" "$branch" "$((sz_kb/1024))" "$ign_note"
    reaped=$((reaped+1)); freed_kb=$((freed_kb+sz_kb))
    continue
  fi

  # A manifest write failure is an INFRASTRUCTURE failure, not a per-worktree verdict:
  # the ledger is unwritable, so every subsequent removal would be unrecorded too.
  # Aborting (rather than keeping and carrying on) is what stops the wrapper reporting
  # a healthy sweep — which matters most under the disk pressure this tool exists for.
  if ! record "$wt_real" "$branch" "$sha" "reachable-from-remote;no-live-process;age=${age_h}h;ignored=${ign:-0}" pending; then
    die "cannot write the restore manifest ($MANIFEST) — aborting before any removal"
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

  # Same re-check for liveness: a session may have started here since the snapshot.
  is_live_now "$wt_real"; live_rc=$?
  case "$live_rc" in
    0) keep "$wt" "live process CWD (started since the startup snapshot)"; continue ;;
    2) die "lsof re-check failed for $wt_real — refusing to continue on an unverifiable live set" ;;
  esac

  # And re-check the working tree: a session may have written files between the status
  # gate above and this point, and `--force` would delete them regardless.
  recheck_status=$(git -C "$wt" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)
  recheck_rc=$?
  if [ "$recheck_rc" -ne 0 ]; then
    keep "$wt" "cannot re-read status before removal"; continue
  fi
  count_real_changes "$wt" "$recheck_status"
  if [ "$REAL_CHANGES" -gt 0 ]; then
    keep "$wt" "$REAL_CHANGES uncommitted change(s) appeared since the status gate"
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
  sha_now=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || {
    keep "$wt" "cannot re-read HEAD before removal"; continue; }
  if [ "$sha_now" != "$sha" ]; then
    keep "$wt" "HEAD moved during the sweep ($sha -> $sha_now)"; continue
  fi

  if ! git -C "$TOPLEVEL" update-ref "refs/reaped/$sha" "$sha" 2>/dev/null; then
    keep "$wt" "could not write refs/reaped/$sha — refusing to remove"; continue
  fi

  # The fallback's prune is deliberately OUTSIDE the success condition: `rm -rf` can
  # succeed while `prune` fails (git's admin dir unwritable), and folding prune into the
  # condition sent an actually-deleted worktree down the "removal FAILED" branch — the
  # run then exited 0 leaving a `pending` row for a path that is already gone.
  # Deletion success is judged by the directory being absent; a failed prune is a
  # separate, loud error.
  if git -C "$TOPLEVEL" worktree remove --force "$wt_real" 2>/dev/null \
     || { ! is_locked_now "$wt_real" && rm -rf "$wt_real" && [ ! -e "$wt_real" ] \
          && { git -C "$TOPLEVEL" worktree prune 2>/dev/null \
               || die "REMOVED $wt_real but 'git worktree prune' failed — the deletion DID happen; run 'git -C $TOPLEVEL worktree prune' to clear its admin entry (restore ref: refs/reaped/$sha)"; }; }; then
    # Completion row — written only now that the directory is actually gone.
    # The directory is already gone at this point, so a failed completion write cannot
    # be undone. Exit non-zero and say exactly how to read the resulting ledger, rather
    # than leaving an unmatched `pending` that looks like an aborted attempt.
    record "$wt_real" "$branch" "$sha" "removed" reaped \
      || die "REMOVED $wt_real but could not append its 'reaped' row. The deletion DID happen: a 'pending' row whose path no longer exists means deleted, not aborted (restore ref: refs/reaped/$sha)"
    printf 'REAPED %-52s %s (%s MB%s)\n' "$name" "$branch" "$((sz_kb/1024))" "$ign_note"
    reaped=$((reaped+1)); freed_kb=$((freed_kb+sz_kb))
  else
    keep "$wt" "removal FAILED"
  fi
done

# Drop admin entries whose directory is already gone.
if [ "$MODE" = "apply" ]; then
  # Not best-effort: this prune is what clears missing-worktree registrations, and
  # branch-cleanup.sh builds its keep-set from `git worktree list`. A silently failed
  # prune therefore leaves stale entries pinning branches that should be sweepable.
  git -C "$TOPLEVEL" worktree prune 2>/dev/null \
    || die "reaped $reaped worktree(s) but 'git worktree prune' failed — stale registrations remain and will pin their branches in branch-cleanup.sh"
fi

printf '\nworktree-cleanup: mode=%s reaped=%d kept=%d freed=%d MB\n' \
  "$MODE" "$reaped" "$kept" "$((freed_kb/1024))"
