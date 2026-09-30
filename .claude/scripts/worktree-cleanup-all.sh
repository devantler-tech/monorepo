#!/usr/bin/env bash
# Sweep abandoned per-session worktrees across the monorepo AND every initialised
# submodule, in one invocation. This is the entry point the scheduled LaunchAgent
# calls; worktree-cleanup.sh holds the per-repo safety contract.
#
# Usage: worktree-cleanup-all.sh [dry-run|apply] [min_age_hours] [salvage_age_hours]
#   dry-run (default) — report only
#   apply             — reap, recording every removal to a timestamped manifest
#   salvage_age_hours (default 336 = 14 days; 0 = off) — preserve abandoned work to
#     refs/salvaged/* and then reap, so the sweep converges (#2831; see worktree-cleanup.sh)
#
# Manifests live OUTSIDE the repository (they name local paths and branches and must
# never be committed): ~/.claude/worktree-cleanup-manifests/<repo>-<utc>.tsv
#
# Before each repository, it also sweeps worktrees NESTED in its session worktrees' submodules
# (<repo>/.claude/worktrees/<slug>/<sub>/.claude/worktrees/*), with salvage off (#3673).
#
# The Codex sibling's worktrees under ~/.codex/worktrees are deliberately NOT swept:
# that lane is owned by the sibling instance (AGENTS.md, Writer namespaces).
set -uo pipefail

MODE=${1:-dry-run}
MIN_AGE_HOURS=${2:-24}
SALVAGE_AGE_HOURS=${3:-336}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/worktree-cleanup.sh"
[ -x "$SUT" ] || { printf 'worktree-cleanup-all: missing %s\n' "$SUT" >&2; exit 2; }

# Validate arguments HERE, not only in the per-repo script. If no repository happens to
# have a .claude/worktrees/ directory, every per-repo call returns before validating,
# and a malformed launcher invocation (`worktree-cleanup-all.sh alpply 24`) would print
# "done" and exit 0 — a misconfigured scheduled job that looks healthy.
case "$MODE" in
  apply|dry-run) ;;
  *) printf "worktree-cleanup-all: invalid MODE '%s' (expected 'apply' or 'dry-run')\n" \
       "$MODE" >&2; exit 2 ;;
esac
case "$MIN_AGE_HOURS" in
  ''|*[!0-9]*) printf "worktree-cleanup-all: min_age_hours must be a non-negative integer, got '%s'\n" \
                 "$MIN_AGE_HOURS" >&2; exit 2 ;;
esac
case "$SALVAGE_AGE_HOURS" in
  ''|*[!0-9]*) printf "worktree-cleanup-all: salvage_age_hours must be a non-negative integer, got '%s'\n" \
                 "$SALVAGE_AGE_HOURS" >&2; exit 2 ;;
esac

# Repo root. WORKTREE_CLEANUP_ROOT lets the script run from outside the checkout
# (the scheduled launcher does exactly that); otherwise it is two levels up from
# .claude/scripts.
if [ -n "${WORKTREE_CLEANUP_ROOT:-}" ]; then
  ROOT=$(cd "$WORKTREE_CLEANUP_ROOT" 2>/dev/null && pwd -P) \
    || { printf 'worktree-cleanup-all: WORKTREE_CLEANUP_ROOT not a directory: %s\n' \
         "$WORKTREE_CLEANUP_ROOT" >&2; exit 2; }
else
  ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
fi
# When this script runs from inside a session worktree, sweep the MAIN checkout, not
# the worktree copy — otherwise the sweep only ever sees its own nested tree.
case "$ROOT" in
  */.claude/worktrees/*) ROOT=${ROOT%%/.claude/worktrees/*} ;;
esac
# Use rev-parse's OUTPUT, not just its status. It walks upward, so a root pointing at
# some subdirectory of the checkout passes the check while ROOT stays wrong — the
# wrapper then finds no worktree dir and no .gitmodules, prints "done" and exits 0
# having swept nothing.
ROOT_TOPLEVEL=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) \
  || { printf 'worktree-cleanup-all: not a git repository: %s\n' "$ROOT" >&2; exit 2; }
ROOT_TOPLEVEL=$(cd "$ROOT_TOPLEVEL" && pwd -P) \
  || { printf 'worktree-cleanup-all: cannot resolve toplevel of %s\n' "$ROOT" >&2; exit 2; }
if [ "$ROOT_TOPLEVEL" != "$ROOT" ]; then
  printf 'worktree-cleanup-all: %s is not a repository root (its root is %s) — using the root\n' \
    "$ROOT" "$ROOT_TOPLEVEL" >&2
  ROOT="$ROOT_TOPLEVEL"
fi

MANIFEST_DIR="$HOME/.claude/worktree-cleanup-manifests"
mkdir -p "$MANIFEST_DIR" || { printf 'cannot create %s\n' "$MANIFEST_DIR" >&2; exit 2; }
TS=$(date -u +%Y%m%dT%H%M%SZ)

printf '=== worktree-cleanup-all  mode=%s  min_age=%sh  salvage_age=%sh  root=%s ===\n' \
  "$MODE" "$MIN_AGE_HOURS" "$SALVAGE_AGE_HOURS" "$ROOT"

# nested_failed <what> — a nested pass failed. Say so, keep going, and exit 2 at the end: the
# failure is confined to one session worktree, and 2 is this directory's UNKNOWN code, where
# the per-repo script's own exit code could read as a finding (1).
NESTED_FAILED=0
nested_failed() {
  printf 'worktree-cleanup-all: %s — continuing; this run will exit non-zero\n' "$1" >&2
  NESTED_FAILED=2
}

sweep() { # <repo_path> [salvage_age_hours, default the wrapper's] [abort|continue on failure]
  local path=$1 salvage=${2:-$SALVAGE_AGE_HOURS} on_fail=${3:-abort} label toplevel expected
  # NOTE: no early return for a missing .claude/worktrees. The per-repo script has its
  # own no-root path that still prunes stale registrations — returning here made that
  # path unreachable through the wrapper, the only way it is ever invoked. A path that is
  # not a repository at all is handled by the toplevel check below (it resolves to the
  # parent, so the mismatch SKIPs it) rather than by a guard that pre-empts that report.
  # Only sweep a repo whose toplevel resolves to ITSELF. A submodule with broken
  # worktree isolation resolves into the main checkout, and sweeping through that
  # alias would operate on the wrong tree (AGENTS.md, Execution model).
  # These ABORT rather than `return 0`. A repository that has a .claude/worktrees/ but
  # whose metadata cannot be read is an infrastructure failure, and silently skipping it
  # let the scheduled wrapper print "done" and exit 0 with that repo never swept. A nested
  # pass (on_fail=continue) records the failure instead, for the reason given further down.
  toplevel=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || {
    if [ "$on_fail" = continue ]; then nested_failed "cannot resolve repository at $path"; return 0; fi
    printf 'worktree-cleanup-all: ABORTING — cannot resolve repository at %s\n' "$path" >&2
    exit 2; }
  expected=$(cd "$path" && pwd -P) || {
    if [ "$on_fail" = continue ]; then nested_failed "cannot resolve physical path of $path"; return 0; fi
    printf 'worktree-cleanup-all: ABORTING — cannot resolve physical path of %s\n' "$path" >&2
    exit 2; }
  if [ "$toplevel" != "$expected" ]; then
    # Both conditions land here and both must SKIP, but they are NOT the same finding
    # and their remedies are opposite, so they are reported apart. Discriminate on the
    # path's OWN git metadata (a directory for a plain repo, a gitdir FILE for a
    # submodule): absent means there is nothing checked out here and the toplevel
    # merely resolved up to the parent; present means a real repository is aliased
    # somewhere else, which is the dangerous case.
    if [ ! -e "$path/.git" ]; then
      printf '\n### SKIP %s (not initialised: no git metadata; toplevel resolved to %s)\n' \
        "$path" "$toplevel"
      printf '###      remedy: .claude/scripts/submodule-init.sh %s\n' "$path"
    else
      printf '\n### SKIP %s (broken isolation: toplevel=%s)\n' "$path" "$toplevel"
      printf '###      remedy: repair this submodule in place — sessions editing here collide in one tree\n'
    fi
    return 0
  fi
  # "$ROOT" is QUOTED: unquoted it is a glob pattern, so a root path containing
  # [, * or ? would strip the wrong prefix (or none) and mislabel the manifest.
  local rel=${path#"$ROOT"/}
  if [ "$path" = "$ROOT" ]; then rel="(root)"; label=monorepo
  else
    # A nested pass's path runs through .claude/worktrees/ (the root's, or a submodule's).
    # Drop those segments: a leading one would make every such manifest a hidden file.
    case "$rel" in
      *.claude/worktrees/*)
        label="nested-$(printf '%s' "$rel" | sed 's#\.claude/worktrees/##g' | tr '/' '-')" ;;
      *) label=$(printf '%s' "$rel" | tr '/' '-') ;;
    esac
  fi
  printf '\n### %s\n' "$rel"
  # Capture the sweep's OWN status, not the pipeline's tail. An infrastructure abort
  # (lsof, worktree list, manifest write) must not be reported as a successful sweep by
  # the scheduled entrypoint — and must stop the run rather than continuing into the
  # remaining repositories, since the same failure very likely applies to them too.
  local out rc
  out=$("$SUT" "$path" "$MANIFEST_DIR/$label-$TS.tsv" "$MODE" "$MIN_AGE_HOURS" "$salvage" 2>&1); rc=$?
  # dry-run writes no manifest, so its per-worktree REAP/KEEP lines are the ONLY record
  # of what an apply run would touch — never truncate them. apply has the manifest, so
  # a summary is enough there.
  # On FAILURE always print the full output. The summary is the last few lines, but an
  # abort's reason is on stderr somewhere above it — truncating to `tail -3` hid exactly
  # the message needed to diagnose a failing scheduled run (observed: the log showed the
  # repo heading and then nothing but a non-zero exit).
  if [ "$MODE" = "dry-run" ] || [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | tail -3
  fi
  if [ "$rc" -ne 0 ]; then
    # A nested pass's failure is confined to one session worktree's own submodule
    # repository. Aborting on it would stop every later sweep, root included, on every
    # run until someone repaired that one repository, and the disk would fill again. Its
    # worktrees stay (the root sweep keeps the parent that holds them), the run goes on,
    # and the wrapper still exits non-zero at the end so the failure is never silent.
    if [ "$on_fail" = continue ]; then
      nested_failed "sweep of $rel failed (exit $rc)"
      return 0
    fi
    printf 'worktree-cleanup-all: ABORTING — sweep of %s failed (exit %d)\n' "$rel" "$rc" >&2
    exit "$rc"
  fi
}

# nested_live_cwds — refresh the working directory of every live process. A
# snapshot from an earlier session worktree may be stale by the time a later
# nested sweep starts. An empty or failed read must never permit a sweep.
NESTED_LIVE=""
nested_live_cwds() {
  local raw
  raw=$(lsof -a -d cwd -F n 2>/dev/null) || return 1
  NESTED_LIVE=$(printf '%s\n' "$raw" | sed -n 's/^n//p' | sort -u)
  [ -n "$NESTED_LIVE" ] || return 1
}

nested_session_is_live() { # <physical session worktree>
  local wt_real=$1 cwd
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    if [ "$cwd" = "$wt_real" ] || [ "${cwd#"$wt_real"/}" != "$cwd" ]; then return 0; fi
  done <<< "$NESTED_LIVE"
  return 1
}

# sweep_nested_submodule_worktrees <repo> — sweep the worktrees nested in the initialised
# submodules of each of <repo>'s session worktrees, BEFORE <repo> itself is swept (#3673).
#
# A run inside a session worktree can populate a submodule there and add a linked worktree
# of that submodule's repository under <session>/<sub>/.claude/worktrees/. That repository
# lives in the session worktree's own admin directory, so no other sweep ever visits it, and
# the repo's own sweep rightly keeps the parent: the nested worktree would die with it. The
# parent was therefore kept forever (about 20 of 84 kept worktrees on 2026-09-29). Reaping
# the nested one first lets the same run's sweep reconsider the parent.
#
# Salvage is OFF for these passes. Its refs would be written into the session worktree's own
# submodule repository, which is deleted with the parent, so it would promise preservation it
# cannot deliver. Only a nested worktree with nothing to lose is reaped; every other per-repo
# KEEP rule applies unchanged. A session worktree a live process works in is left whole, the
# same protection the repo's own sweep gives it. Every failure here is confined to one session
# worktree, so it is recorded (nested_failed) rather than aborting the run.
sweep_nested_submodule_worktrees() {
  local repo=$1 session_root="$1/.claude/worktrees" session_real wts wt wt_real
  local subs sub sub_real sub_wts
  [ -d "$session_root" ] || return 0
  session_real=$(cd "$session_root" 2>/dev/null && pwd -P) || {
    nested_failed "cannot resolve $session_root"; return 0; }
  wts=$(git -C "$repo" worktree list --porcelain 2>/dev/null) || {
    nested_failed "cannot list the worktrees of $repo"; return 0; }
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    # A registration whose directory is gone has nothing nested; the repo's sweep prunes it.
    [ -d "$wt" ] || continue
    wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || { nested_failed "cannot resolve $wt"; continue; }
    case "$wt_real" in
      "$session_real"/?*) ;;
      *) continue ;;          # the main checkout, or a worktree outside the session root
    esac
    nested_live_cwds || { nested_failed "cannot read live process CWDs (lsof) for $wt_real"; continue; }
    if nested_session_is_live "$wt_real"; then
      printf '\n### SKIP %s (a live process works inside it — its nested worktrees are left alone)\n' \
        "${wt_real#"$ROOT"/}"
      continue
    fi
    # Populated submodules only, recursively. A session worktree whose submodules cannot be
    # listed is not swept here; the repo's own gates still keep it, so nothing is deleted on
    # the strength of a listing that failed.
    # shellcheck disable=SC2016  # $toplevel and $sm_path are expanded by `submodule foreach`
    if ! subs=$(git -C "$wt_real" submodule foreach --quiet --recursive \
                  'printf "%s\n" "$toplevel/$sm_path"' 2>/dev/null); then
      printf '\n### SKIP %s (cannot list its submodules)\n' "${wt_real#"$ROOT"/}"
      nested_failed "cannot list the submodules of ${wt_real#"$ROOT"/}"
      continue
    fi
    while IFS= read -r sub; do
      [ -n "$sub" ] || continue
      [ -d "$sub/.claude/worktrees" ] || continue
      if [ -L "$sub" ]; then
        printf '\n### SKIP %s (submodule path is a symlink — refusing to follow it)\n' "${sub#"$ROOT"/}"
        continue
      fi
      sub_real=$(cd "$sub" 2>/dev/null && pwd -P) || { nested_failed "cannot resolve $sub"; continue; }
      case "$sub_real" in
        "$wt_real"/?*) ;;
        *) printf '\n### SKIP %s (escapes its session worktree: %s)\n' "${sub#"$ROOT"/}" "$sub_real"
           continue ;;
      esac
      # Sweep only a repository that has a linked worktree to sweep. The emptied
      # .claude/worktrees stays behind after a reap, and would otherwise cost a full per-repo
      # pass (lsof, worktree list) on every later run.
      sub_wts=$(git -C "$sub_real" worktree list --porcelain 2>/dev/null) || {
        nested_failed "cannot list the worktrees of ${sub_real#"$ROOT"/}"; continue; }
      [ "$(grep -c '^worktree ' <<< "$sub_wts")" -gt 1 ] || continue
      # Recheck after submodule enumeration: a process may have entered the
      # parent since the earlier check, and this call is about to delete below it.
      nested_live_cwds || { nested_failed "cannot refresh live process CWDs (lsof) for $wt_real"; break; }
      if nested_session_is_live "$wt_real"; then
        printf '\n### SKIP %s (a live process works inside it — its nested worktrees are left alone)\n' \
          "${wt_real#"$ROOT"/}"
        break
      fi
      sweep "$sub_real" 0 continue
    done <<< "$subs"
  done <<< "$(printf '%s\n' "$wts" | awk '/^worktree /{print substr($0,10)}')"
}

sweep_nested_submodule_worktrees "$ROOT"
sweep "$ROOT"

# Every submodule, from .gitmodules (never a hard-coded list — the portfolio gains and
# loses submodules over time).
# The read is status-checked: an unreadable .gitmodules yields an empty list, which is
# indistinguishable from "no submodules", and would silently degrade this to a
# root-only sweep while still reporting success. `cut -d' ' -f2-` (not `awk '{print $2}'`)
# so a submodule path containing whitespace is not truncated.
if [ -f "$ROOT/.gitmodules" ]; then
  # Two distinct statuses, checked INDEPENDENTLY. `--get-regexp` exits nonzero both when
  # the file is unparseable AND when it simply matches nothing, so it cannot distinguish
  # them alone. The probe below settles it — but its own status must be captured too:
  # on a malformed .gitmodules BOTH commands fail and produce no output, and testing
  # only the probe's emptiness would read that as "no submodules" and silently degrade
  # the scheduled sweep to the root repository.
  raw=$(git -C "$ROOT" config -f "$ROOT/.gitmodules" \
          --get-regexp '^submodule\..*\.path$' 2>/dev/null); get_rc=$?
  probe=$(git -C "$ROOT" config -f "$ROOT/.gitmodules" --list 2>/dev/null); probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    printf 'worktree-cleanup-all: ABORTING — .gitmodules is unreadable or malformed\n' >&2
    exit 2
  fi
  if [ "$get_rc" -ne 0 ] && [ -n "$probe" ]; then
    printf 'worktree-cleanup-all: ABORTING — cannot read submodule paths from .gitmodules\n' >&2
    exit 2
  fi
  submodules=$(printf '%s\n' "$raw" | cut -d' ' -f2-)
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    # .gitmodules is repository content, and the config parser happily accepts a path
    # like `../outside`. Concatenating that escapes ROOT, and if the resulting location
    # is another repository with .claude/worktrees the scheduled apply run would reap
    # worktrees outside the portfolio entirely. Resolve and require containment.
    # An absent path is an uninitialised submodule — nothing to sweep, skip quietly.
    # A path that EXISTS but cannot be resolved is an infrastructure failure (permissions,
    # a broken mount), and skipping it silently let the wrapper still print "done" and
    # exit 0 with that repository never swept.
    [ -e "$ROOT/$sub" ] || continue
    # A SYMLINK at the gitlink path resolves elsewhere: `pwd -P` would follow it to an
    # unrelated repository while the index query still validates the original lexical
    # path as a genuine gitlink, so the sweep would run against the link target.
    if [ -L "$ROOT/$sub" ]; then
      printf '\n### SKIP %s (gitlink path is a symlink — refusing to follow it)\n' "$sub"
      continue
    fi
    sub_real=$(cd "$ROOT/$sub" 2>/dev/null && pwd -P) || {
      printf 'worktree-cleanup-all: ABORTING — %s exists but cannot be resolved\n' "$sub" >&2
      exit 2; }
    case "$sub_real" in
      "$ROOT"/?*) ;;
      *) printf '\n### SKIP %s (escapes the portfolio root: %s)\n' "$sub" "$sub_real"
         continue ;;
    esac
    # Containment is necessary but not sufficient: a stale or malformed .gitmodules entry
    # can name an ordinary nested repository inside ROOT, which is not a portfolio
    # submodule and must not be swept. Require the path to be a real gitlink (mode
    # 160000) in the parent's index.
    # The query's status is captured separately: an unreadable or corrupt index makes the
    # substitution empty, which would read as "not a gitlink" and silently skip a real
    # submodule while the run still reported success.
    # `:(literal)` because a pathspec is a GLOB by default: a .gitmodules path containing
    # pathspec metacharacters would otherwise validate a DIFFERENT index entry — `mods/[ab]`
    # matches a real `mods/a` gitlink — so the check would pass on one path while apply mode
    # swept the ordinary nested repository at the literal path.
    stage=$(git -C "$ROOT" ls-files --stage -- ":(literal)$sub" 2>/dev/null); stage_rc=$?
    if [ "$stage_rc" -ne 0 ]; then
      printf 'worktree-cleanup-all: ABORTING — cannot read the index to validate %s\n' "$sub" >&2
      exit 2
    fi
    # Exactly one entry, whose RECORDED path is exactly $sub, and it is a gitlink. The literal
    # pathspec above already prevents the glob match; comparing the returned pathname is the
    # belt-and-braces half, and it also rejects the multi-line result a future pathspec change
    # could reintroduce — `cut -c1-6` reads only the first line, so two entries would be judged
    # by whichever sorted first.
    if [ "$(printf '%s\n' "$stage" | grep -c .)" -ne 1 ] ||
      [ "$(printf '%s' "$stage" | cut -f2-)" != "$sub" ] ||
      [ "$(printf '%s' "$stage" | cut -c1-6)" != "160000" ]; then
      printf '\n### SKIP %s (not a gitlink in the index — not a portfolio submodule)\n' "$sub"
      continue
    fi
    sweep_nested_submodule_worktrees "$sub_real"
    sweep "$sub_real"
  done <<< "$submodules"
fi

printf '\n=== done (manifests in %s) ===\n' "$MANIFEST_DIR"
if [ "$NESTED_FAILED" -ne 0 ]; then
  printf 'worktree-cleanup-all: a nested submodule sweep failed — see above\n' >&2
  exit "$NESTED_FAILED"
fi
