#!/usr/bin/env bash
# Sweep abandoned per-session worktrees across the monorepo AND every initialised
# submodule, in one invocation. This is the entry point the scheduled LaunchAgent and
# every run's pre-flight call; worktree-cleanup.sh holds the per-repo safety contract.
#
# Usage: worktree-cleanup-all.sh [dry-run|apply] [min_age_hours] [salvage_age_hours] [--lane claude|codex]
#   dry-run (default) — report only
#   apply             — reap, recording every removal to a timestamped manifest
#   salvage_age_hours (default 336 = 14 days; 0 = off) — preserve abandoned work to
#     refs/salvaged/* and then reap, so the sweep converges (#2831; see worktree-cleanup.sh)
#   --lane (default claude) — whose worktrees to sweep. Each lane sweeps ONLY its own roots
#     (maintainer direction 2026-09-29: "Claude runs should clean up claude, and Codex runs
#     should clean up codex." — #3676):
#       claude — <repo>/.claude/worktrees of the monorepo and every submodule
#       codex  — <repo>/.codex/worktrees of the monorepo and every submodule (and each
#                submodule's worktrees in the monorepo's), plus the monorepo's worktrees in
#                the Codex app's worktree dir
#                (WORKTREE_CLEANUP_CODEX_APP_ROOT, default ~/.codex/worktrees)
#
# Manifests live OUTSIDE the repository (they name local paths and branches and must
# never be committed): ~/.claude/worktree-cleanup-manifests/<repo>-<utc>.tsv for the claude
# lane, and the codex/ subdirectory of it for the codex lane, so the two never share a file.
#
# Before each worktree root it sweeps, in either lane, it also sweeps worktrees NESTED in the
# submodules of that root's session worktrees (<session>/<sub>/.claude/worktrees/*), with salvage
# off (#3673). That is where the per-run worktree helper puts a run's worktree for a submodule,
# whichever lane the session belongs to (#3713).
set -uo pipefail

# Positional arguments keep their old meaning and order; --lane may appear anywhere. An empty
# positional still means its default, as it did before the lane selector existed.
LANE=claude; P1=""; P2=""; P3=""; npos=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane)
      [ "$#" -ge 2 ] || { printf 'worktree-cleanup-all: --lane needs a value (claude or codex)\n' >&2; exit 2; }
      LANE=$2; shift 2; continue ;;
    --lane=*) LANE=${1#--lane=}; shift; continue ;;
  esac
  npos=$((npos + 1))
  case "$npos" in
    1) P1=$1 ;;
    2) P2=$1 ;;
    3) P3=$1 ;;
    *) printf "worktree-cleanup-all: unexpected argument '%s'\n" "$1" >&2; exit 2 ;;
  esac
  shift
done
MODE=${P1:-dry-run}
MIN_AGE_HOURS=${P2:-24}
SALVAGE_AGE_HOURS=${P3:-336}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/worktree-cleanup.sh"
[ -x "$SUT" ] || { printf 'worktree-cleanup-all: missing %s\n' "$SUT" >&2; exit 2; }
# The nested pass honours a parent session's ownership marker with the same rules the
# per-repo sweep applies to the parent itself.
# shellcheck source=worktree-claim-lib.sh
. "$SCRIPT_DIR/worktree-claim-lib.sh" \
  || { printf 'worktree-cleanup-all: cannot load shared claim protocol\n' >&2; exit 2; }

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
case "$LANE" in
  claude|codex) ;;
  *) printf "worktree-cleanup-all: invalid --lane '%s' (expected 'claude' or 'codex')\n" "$LANE" >&2; exit 2 ;;
esac

# Resolve the reviewed consumer's portfolio before visiting any submodule checkout.
# Reading parent metadata is allowed; Git commands inside an excluded child are not.
PORTFOLIO_CONTRACT="$SCRIPT_DIR/../../AGENTS.md"
PORTFOLIO_REPOS=$(awk '
  /^## Portfolio map$/ { in_map=1; found=1; next }
  in_map && /^## / { in_map=0 }
  in_map && /^\|/ {
    n=split($0, col, "|")
    if (n >= 4 && col[3] ~ /^[[:space:]]*`devantler-tech\// &&
        index(col[3], "**archived ") == 0) {
      repo=col[3]; sub(/^[[:space:]]*`devantler-tech\//, "", repo)
      sub(/`.*$/, "", repo); print repo
    }
  }
  END { if (!found) exit 2 }
' "$PORTFOLIO_CONTRACT" 2>/dev/null); portfolio_rc=$?
if [ "$portfolio_rc" -ne 0 ] || [ -z "$PORTFOLIO_REPOS" ]; then
  printf 'worktree-cleanup-all: cannot resolve the reviewed Portfolio map\n' >&2
  exit 2
fi

# 0: mapped portfolio URL; 1: known exclusion; 2: unknown metadata.
portfolio_url_state() {
  local url=$1 slug owner repo
  case "$url" in
    https://github.com/*) slug=${url#https://github.com/} ;;
    git@github.com:*) slug=${url#git@github.com:} ;;
    *) return 2 ;;
  esac
  slug=${slug%.git}
  case "$slug" in
    */*) owner=${slug%%/*}; repo=${slug#*/} ;;
    *) return 2 ;;
  esac
  case "$owner" in ''|*[!a-zA-Z0-9_.-]*) return 2 ;; esac
  case "$repo" in
    ''|*[!a-zA-Z0-9_.-]*) return 2 ;;
  esac
  [ "$owner" = devantler-tech ] || return 1
  while IFS= read -r slug; do
    [ "$repo" = "$slug" ] && return 0
  done <<< "$PORTFOLIO_REPOS"
  return 1
}

# Collect only eligible paths in ELIGIBLE. 'submodule foreach' enters every populated child
# before its owner can be checked, so recursive discovery uses parent metadata.
eligible_submodules() {
  local parent=$1 recursive=$2 retain=${3:-$1} raw get_rc probe probe_rc record key sub url url_rc state
  local child real stage stage_rc index entry indexed_path matches
  index=$(git -C "$parent" -c core.quotePath=false ls-files --stage 2>/dev/null) || {
    printf 'worktree-cleanup-all: unknown submodule eligibility (cannot read the index)\n' >&2
    return 2
  }
  if [ -L "$parent/.gitmodules" ] ||
     { [ -e "$parent/.gitmodules" ] && [ ! -f "$parent/.gitmodules" ]; }; then
    printf 'worktree-cleanup-all: unknown submodule eligibility (unsafe metadata file)\n' >&2
    return 2
  fi
  if [ ! -f "$parent/.gitmodules" ]; then
    if grep -q '^160000 ' <<< "$index"; then
      printf 'worktree-cleanup-all: unknown submodule eligibility (gitlinks lack metadata)\n' >&2
      return 2
    fi
    return 0
  fi
  raw=$(git -C "$parent" config -f "$parent/.gitmodules" \
    --get-regexp '^submodule\..*\.path$' 2>/dev/null); get_rc=$?
  probe=$(git -C "$parent" config -f "$parent/.gitmodules" --list 2>/dev/null); probe_rc=$?
  if [ "$probe_rc" -ne 0 ] || { [ "$get_rc" -ne 0 ] && [ -n "$probe" ]; }; then
    printf 'worktree-cleanup-all: cannot list its submodules — .gitmodules is unreadable or malformed\n' >&2
    return 2
  fi
  # Git's recursive status gates use the index too. Every gitlink needs exactly
  # one metadata entry before any child may be visited, even after metadata deletion.
  while IFS= read -r entry; do
    case "$entry" in 160000\ *) ;; *) continue ;; esac
    indexed_path=${entry#*$'\t'}; matches=0
    while IFS= read -r record; do
      [ "${record#* }" != "$indexed_path" ] || matches=$((matches + 1))
    done <<< "$raw"
    if [ "$matches" -ne 1 ]; then
      printf 'worktree-cleanup-all: unknown submodule eligibility (missing or ambiguous path metadata)\n' >&2
      return 2
    fi
  done <<< "$index"
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    key=${record%% *}; sub=${record#* }
    url=$(git -C "$parent" config -f "$parent/.gitmodules" --get-all "${key%.path}.url" 2>/dev/null); url_rc=$?
    if [ "$url_rc" -ne 0 ] || [ "$(printf '%s\n' "$url" | grep -c .)" -ne 1 ]; then
      printf 'worktree-cleanup-all: unknown submodule eligibility (missing or ambiguous URL)\n' >&2
      return 2
    fi
    portfolio_url_state "$url"; state=$?
    case "$state" in
      1) printf '### SKIP %s (outside the reviewed Portfolio map)\n' "$sub" >&2
         [ "$recursive" -eq 0 ] || retain_parent "$retain"
         continue ;;
      2) printf 'worktree-cleanup-all: unknown submodule eligibility (unrecognized URL)\n' >&2; return 2 ;;
    esac
    child="$parent/$sub"
    if [ "$recursive" -eq 0 ]; then ELIGIBLE="${ELIGIBLE}$child"$'\n'; continue; fi
    [ -e "$child" ] || continue
    if [ -L "$child" ]; then
      printf '### SKIP %s (submodule path is a symlink — refusing to follow it)\n' "$sub" >&2
      continue
    fi
    # An unpopulated submodule is an empty directory. Git would resolve its index
    # from the parent, so do not recurse until the child has its own repository.
    [ -e "$child/.git" ] || continue
    real=$(cd "$child" 2>/dev/null && pwd -P) || return 2
    case "$real" in
      "$parent"/?*) ;;
      *) printf '### SKIP %s (escapes its session worktree)\n' "$sub" >&2; continue ;;
    esac
    stage=$(git -C "$parent" ls-files --stage -- ":(literal)$sub" 2>/dev/null); stage_rc=$?
    [ "$stage_rc" -eq 0 ] || return 2
    if [ "$(printf '%s\n' "$stage" | grep -c .)" -ne 1 ] ||
      [ "$(printf '%s' "$stage" | cut -f2-)" != "$sub" ] ||
      [ "$(printf '%s' "$stage" | cut -c1-6)" != 160000 ]; then
      printf '### SKIP %s (not a gitlink in the index — not a portfolio submodule)\n' "$sub" >&2
      continue
    fi
    ELIGIBLE="${ELIGIBLE}$real"$'\n'
    eligible_submodules "$real" 1 "$retain" || return 2
  done <<< "$raw"
  return 0
}

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
# A linked worktree the rewrite above cannot see — a Codex run's own checkout, which may not
# even sit under the main checkout — names its main checkout through its common git
# directory. Sweep that. A layout that proves nothing (a submodule's modules/ gitdir, a
# separate git dir) leaves ROOT as it was.
if ! COMMON=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null) \
   || ! COMMON=$(cd "$ROOT" && cd "$COMMON" && pwd -P); then
  printf 'worktree-cleanup-all: cannot resolve the common git directory of %s\n' "$ROOT" >&2
  exit 2
fi
case "$COMMON" in
  */.git)
    MAIN=${COMMON%/.git}
    if ! MAIN_TOPLEVEL=$(git -C "$MAIN" rev-parse --show-toplevel 2>/dev/null) \
       || ! MAIN_TOPLEVEL=$(cd "$MAIN_TOPLEVEL" && pwd -P); then
      MAIN_TOPLEVEL=""
    fi
    if [ "$MAIN" != "$ROOT" ] && [ "$MAIN_TOPLEVEL" = "$MAIN" ]; then
      printf 'worktree-cleanup-all: %s is a linked worktree — using its main checkout %s\n' \
        "$ROOT" "$MAIN" >&2
      ROOT=$MAIN
    fi
    ;;
esac

MANIFEST_DIR="$HOME/.claude/worktree-cleanup-manifests"
[ "$LANE" = claude ] || MANIFEST_DIR="$MANIFEST_DIR/$LANE"
mkdir -p "$MANIFEST_DIR" || { printf 'cannot create %s\n' "$MANIFEST_DIR" >&2; exit 2; }
TS=$(date -u +%Y%m%dT%H%M%SZ)
CODEX_APP_ROOT=${WORKTREE_CLEANUP_CODEX_APP_ROOT:-$HOME/.codex/worktrees}

printf '=== worktree-cleanup-all  lane=%s  mode=%s  min_age=%sh  salvage_age=%sh  root=%s ===\n' \
  "$LANE" "$MODE" "$MIN_AGE_HOURS" "$SALVAGE_AGE_HOURS" "$ROOT"

# nested_failed <what> — a nested pass failed. Say so, keep going, and exit 2 at the end: the
# failure is confined to one session worktree, and 2 is this directory's UNKNOWN code, where
# the per-repo script's own exit code could read as a finding (1).
NESTED_FAILED=0
# Session worktrees the per-repo sweep must keep, one physical path per line: a nested pass
# left recovery refs in them that could not be handed off (see handoff_reaped_refs).
RETAIN=""
# retain_parent <physical session worktree> — keep it this run. Every nested-pass failure that
# stops before handoff_reaped_refs has run for all of its submodules calls this: refs/reaped
# left by an earlier run may still be inside it, and nothing has verified a durable copy.
retain_parent() { RETAIN="${RETAIN}$1"$'\n'; }
nested_failed() {
  printf 'worktree-cleanup-all: %s — continuing; this run will exit non-zero\n' "$1" >&2
  NESTED_FAILED=2
}

sweep() { # <repo_path> [worktree_root, empty = worktree-cleanup.sh's default] [salvage_age_hours] [abort|continue]
  local path=$1 wt_root=${2:-} salvage=${3:-$SALVAGE_AGE_HOURS} on_fail=${4:-abort} label toplevel expected
  # NOTE: no early return for a missing .claude/worktrees. The per-repo script reports a
  # missing root itself, and the wrapper is the only way it is ever invoked. A path that is
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
    # A nested pass's path runs through a lane's worktree root: .claude/worktrees/ or
    # .codex/worktrees/ (the root's, or a submodule's), or the Codex app's worktree dir outside
    # the checkout, whose path stays absolute. Drop those segments and the leading slash: a
    # leading dot or slash would make every such manifest a hidden file or an absolute path.
    case "$rel" in
      /*|*.claude/worktrees/*|*.codex/worktrees/*)
        label="nested-$(printf '%s' "${rel#/}" \
          | sed -e 's#\.claude/worktrees/##g' -e 's#\.codex/worktrees/##g' | tr '/' '-')" ;;
      *) label=$(printf '%s' "$rel" | tr '/' '-') ;;
    esac
  fi
  if [ -n "$wt_root" ]; then printf '\n### %s  [%s]\n' "$rel" "$wt_root"
  else printf '\n### %s\n' "$rel"; fi
  # The per-repository cleanliness gates inspect descendants. Retain candidates
  # containing excluded repositories BEFORE those gates can enter them, in either lane.
  local scope_root=${wt_root:-$path/.claude/worktrees} registered candidate candidate_real
  if [ -d "$scope_root" ]; then
    scope_root=$(cd "$scope_root" && pwd -P) || {
      if [ "$on_fail" = continue ]; then nested_failed "cannot resolve worktree root $scope_root"; return 0; fi
      printf 'worktree-cleanup-all: ABORTING — cannot resolve worktree root %s\n' "$scope_root" >&2
      exit 2; }
    registered=$(git -C "$path" worktree list --porcelain 2>/dev/null) || {
      if [ "$on_fail" = continue ]; then nested_failed "cannot list worktrees of $path"; return 0; fi
      printf 'worktree-cleanup-all: ABORTING — cannot list worktrees of %s\n' "$path" >&2
      exit 2; }
    while IFS= read -r candidate; do
      case "$candidate" in worktree\ *) candidate=${candidate#worktree } ;; *) continue ;; esac
      candidate_real=$(cd "$candidate" 2>/dev/null && pwd -P) || continue
      case "$candidate_real" in "$scope_root"/?*) ;; *) continue ;; esac
      ELIGIBLE=""
      if ! eligible_submodules "$candidate_real" 1; then
        retain_parent "$candidate_real"
        nested_failed "unknown submodule eligibility in a cleanup candidate"
      fi
    done <<< "$registered"
  fi
  # Capture the sweep's OWN status, not the pipeline's tail. An infrastructure abort
  # (lsof, worktree list, manifest write) must not be reported as a successful sweep by
  # the scheduled entrypoint — and must stop the run rather than continuing into the
  # remaining repositories, since the same failure very likely applies to them too.
  # The root is always passed explicitly, so an inherited WORKTREE_CLEANUP_WT_ROOT can never
  # point one lane's sweep at another lane's root.
  local out rc
  out=$(WORKTREE_CLEANUP_WT_ROOT="$wt_root" WORKTREE_CLEANUP_RETAIN="$RETAIN" \
    "$SUT" "$path" "$MANIFEST_DIR/$label-$TS.tsv" "$MODE" "$MIN_AGE_HOURS" "$salvage" 2>&1); rc=$?
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

# handoff_reaped_refs <repo> <session worktree> <nested submodule> — copy the nested
# repository's refs/reaped/* into the same submodule's repository in <repo>'s own checkout,
# and verify every one arrived.
#
# The per-repo sweep writes refs/reaped/<sha> before each removal, so a reaped commit stays
# restorable after a stale remote-tracking ref is pruned. A nested pass writes them into the
# session worktree's own submodule repository, under the session's admin directory, which
# the root sweep deletes with the parent. Copied here they outlive it. Returns 1, with the
# reason in HANDOFF_NOTE, whenever that cannot be done and verified; the caller then keeps
# the parent. The emptied nested repository is rechecked on every run, so a later run
# completes the handoff once the checkout's copy of the submodule is populated.
HANDOFF_NOTE=""
handoff_reaped_refs() {
  local repo=$1 wt_real=$2 sub_real=$3 sub_gitdir wt_gitdir refs rel durable durable_real
  local durable_gitdir ref sha
  sub_gitdir=$(git -C "$sub_real" rev-parse --absolute-git-dir 2>/dev/null) || {
    HANDOFF_NOTE="cannot resolve the nested repository"; return 1; }
  refs=$(git --git-dir="$sub_gitdir" for-each-ref --format='%(refname) %(objectname)' \
           refs/reaped/ 2>/dev/null) || { HANDOFF_NOTE="cannot list its refs/reaped"; return 1; }
  [ -n "$refs" ] || return 0
  wt_gitdir=$(git -C "$wt_real" rev-parse --absolute-git-dir 2>/dev/null) || {
    HANDOFF_NOTE="cannot resolve the session's admin directory"; return 1; }
  case "$sub_gitdir" in
    "$wt_gitdir"/?*) ;;
    *) return 0 ;;   # not under the parent's admin directory, so it outlives the parent
  esac
  rel=${sub_real#"$wt_real"/}
  durable="$repo/$rel"
  if [ -L "$durable" ] || [ ! -d "$durable" ]; then
    HANDOFF_NOTE="$rel is not populated in ${repo#"$ROOT"/}; remedy: .claude/scripts/submodule-init.sh"
    return 1
  fi
  durable_real=$(cd "$durable" 2>/dev/null && pwd -P) || {
    HANDOFF_NOTE="cannot resolve $durable"; return 1; }
  if [ "$(git -C "$durable_real" rev-parse --show-toplevel 2>/dev/null)" != "$durable_real" ]; then
    HANDOFF_NOTE="$rel is not a repository of its own in ${repo#"$ROOT"/}"; return 1
  fi
  durable_gitdir=$(git -C "$durable_real" rev-parse --absolute-git-dir 2>/dev/null) || {
    HANDOFF_NOTE="cannot resolve the repository of $durable_real"; return 1; }
  case "$durable_gitdir" in
    "$wt_gitdir"|"$wt_gitdir"/*) HANDOFF_NOTE="its only copy is inside the session"; return 1 ;;
  esac
  git --git-dir="$durable_gitdir" fetch --quiet --no-tags --no-write-fetch-head \
    "$sub_gitdir" 'refs/reaped/*:refs/reaped/*' 2>/dev/null || {
    HANDOFF_NOTE="could not copy refs/reaped into $durable_real"; return 1; }
  while read -r ref sha; do
    [ "$(git --git-dir="$durable_gitdir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null)" = "$sha" ] || {
      HANDOFF_NOTE="$ref did not arrive in $durable_real"; return 1; }
  done <<< "$refs"
}

# sweep_nested_submodule_worktrees <repo> [session_root] — sweep the worktrees nested in the
# initialised submodules of each of <repo>'s session worktrees under [session_root] (default
# <repo>/.claude/worktrees), BEFORE <repo> itself is swept in that root (#3673).
#
# A run inside a session worktree can populate a submodule there and add a linked worktree
# of that submodule's repository under <session>/<sub>/.claude/worktrees/. That repository
# lives in the session worktree's own admin directory, so no other sweep ever visits it, and
# the repo's own sweep rightly keeps the parent: the nested worktree would die with it. The
# parent was therefore kept forever (about 20 of 84 kept worktrees on 2026-09-29). Reaping
# the nested one first lets the same run's sweep reconsider the parent. The nested root is
# .claude/worktrees in a Codex session too: the per-run worktree helper resolves the mandated
# `.claude/worktrees/maint-<runid>` from the submodule, whichever lane runs it (#3713).
#
# Salvage is OFF for these passes. Its refs would be written into the session worktree's own
# submodule repository, which is deleted with the parent, so it would promise preservation it
# cannot deliver. Only a nested worktree with nothing to lose is reaped; every other per-repo
# KEEP rule applies unchanged. A session worktree a live process works in is left whole, the
# same protection the repo's own sweep gives it. Every failure here is confined to one session
# worktree, so it is recorded (nested_failed) rather than aborting the run.
sweep_nested_submodule_worktrees() {
  local repo=$1 session_root=${2:-$1/.claude/worktrees} session_real wts wt wt_real
  local subs sub sub_real sub_wts
  [ -d "$session_root" ] || return 0
  session_real=$(cd "$session_root" 2>/dev/null && pwd -P) || {
    nested_failed "cannot resolve $session_root"; return 0; }
  wts=$(git -C "$repo" worktree list --porcelain 2>/dev/null) || {
    nested_failed "cannot list the worktrees of $repo"; return 0; }
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    # A registration whose directory is gone has nothing nested to sweep.
    [ -d "$wt" ] || continue
    wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || { nested_failed "cannot resolve $wt"; continue; }
    case "$wt_real" in
      "$session_real"/?*) ;;
      *) continue ;;          # the main checkout, or a worktree outside the session root
    esac
    nested_live_cwds || { retain_parent "$wt_real"
      nested_failed "cannot read live process CWDs (lsof) for $wt_real"; continue; }
    if nested_session_is_live "$wt_real"; then
      printf '\n### SKIP %s (a live process works inside it — its nested worktrees are left alone)\n' \
        "${wt_real#"$ROOT"/}"
      continue
    fi
    # Scope each child from parent metadata before entering its checkout.
    ELIGIBLE=""
    if ! eligible_submodules "$wt_real" 1; then
      printf '\n### SKIP %s (cannot list its submodules)\n' "${wt_real#"$ROOT"/}"
      retain_parent "$wt_real"
      nested_failed "cannot list the submodules of ${wt_real#"$ROOT"/}"
      continue
    fi
    subs=$ELIGIBLE
    while IFS= read -r sub; do
      [ -n "$sub" ] || continue
      [ -d "$sub/.claude/worktrees" ] || continue
      if [ -L "$sub" ]; then
        printf '\n### SKIP %s (submodule path is a symlink — refusing to follow it)\n' "${sub#"$ROOT"/}"
        continue
      fi
      sub_real=$(cd "$sub" 2>/dev/null && pwd -P) || { retain_parent "$wt_real"
        nested_failed "cannot resolve $sub"; continue; }
      case "$sub_real" in
        "$wt_real"/?*) ;;
        *) printf '\n### SKIP %s (escapes its session worktree: %s)\n' "${sub#"$ROOT"/}" "$sub_real"
           continue ;;
      esac
      # Sweep only a repository that has a linked worktree to sweep. The emptied
      # .claude/worktrees stays behind after a reap, and would otherwise cost a full per-repo
      # pass (lsof, worktree list) on every later run.
      sub_wts=$(git -C "$sub_real" worktree list --porcelain 2>/dev/null) || {
        retain_parent "$wt_real"
        nested_failed "cannot list the worktrees of ${sub_real#"$ROOT"/}"; continue; }
      if [ "$(grep -c '^worktree ' <<< "$sub_wts")" -gt 1 ]; then
        # Recheck after submodule enumeration: a process may have entered the
        # parent since the earlier check, and this call is about to delete below it.
        nested_live_cwds || { retain_parent "$wt_real"
          nested_failed "cannot refresh live process CWDs (lsof) for $wt_real"; break; }
        if nested_session_is_live "$wt_real"; then
          printf '\n### SKIP %s (a live process works inside it — its nested worktrees are left alone)\n' \
            "${wt_real#"$ROOT"/}"
          break
        fi
        # A claimed parent is owned even with no process inside it. The repo's sweep keeps
        # it, but only after this pass would already have removed the worktree below it.
        # Check here, immediately before deleting, and treat a malformed marker as a claim.
        ownership_claim_state "$wt_real"
        case $? in
          0) printf '\n### SKIP %s (active ownership claim: %s — its nested worktrees are left alone)\n' \
               "${wt_real#"$ROOT"/}" "$CLAIM_DETAIL"
             break ;;
          2) printf '\n### SKIP %s (ambiguous ownership claim: %s — its nested worktrees are left alone)\n' \
               "${wt_real#"$ROOT"/}" "$CLAIM_DETAIL"
             break ;;
        esac
        sweep "$sub_real" "" 0 continue
      fi
      # Runs whether or not this run reaped anything here: refs left by an earlier run whose
      # handoff failed are handed off as soon as it can succeed. dry-run writes nothing.
      if [ "$MODE" = apply ] && ! handoff_reaped_refs "$repo" "$wt_real" "$sub_real"; then
        printf '\n### RETAIN %s (%s: %s — its reaped commits'"'"' recovery refs would die with it)\n' \
          "${wt_real#"$ROOT"/}" "${sub_real#"$wt_real"/}" "$HANDOFF_NOTE"
        retain_parent "$wt_real"
        nested_failed "could not hand off the recovery refs of ${sub_real#"$ROOT"/}"
      fi
    done <<< "$subs"
  done <<< "$(printf '%s\n' "$wts" | awk '/^worktree /{print substr($0,10)}')"
}

# sweep_root <repo_path> [worktree_root, empty = <repo_path>/.claude/worktrees] — first the
# worktrees nested in the submodules of that root's session worktrees, which only this lane's
# sweep can reach (#3673, #3713), then the root itself, which can then reconsider the parents.
sweep_root() {
  sweep_nested_submodule_worktrees "$1" "${2:-}"
  sweep "$1" "${2:-}"
}

# sweep_lane <repo_path> — every worktree root the selected lane owns, for that repository's
# registrations, and no other root. Codex runs also keep a submodule's worktrees in the
# MONOREPO's .codex/worktrees (measured on the reference host), so each submodule is swept
# there too; the Codex app's worktree dir holds monorepo worktrees only.
sweep_lane() {
  case "$LANE" in
    claude)
      sweep_root "$1"
      ;;
    codex)
      sweep_root "$1" "$1/.codex/worktrees"
      if [ "$1" = "$ROOT" ]; then sweep_root "$1" "$CODEX_APP_ROOT"
      else sweep_root "$1" "$ROOT/.codex/worktrees"; fi
      ;;
  esac
}

sweep_lane "$ROOT"

# Scope every child before checking its checkout or invoking the per-repository sweep.
ELIGIBLE=""
if ! eligible_submodules "$ROOT" 0; then
  printf "worktree-cleanup-all: ABORTING — submodule eligibility is unknown\n" >&2
  exit 2
fi
submodules=$ELIGIBLE
if [ -n "$submodules" ]; then
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    sub=${sub#"$ROOT"/}
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
    sweep_lane "$sub_real"
  done <<< "$submodules"
fi

printf '\n=== done (manifests in %s) ===\n' "$MANIFEST_DIR"
if [ "$NESTED_FAILED" -ne 0 ]; then
  printf 'worktree-cleanup-all: a nested submodule sweep failed — see above\n' >&2
  exit "$NESTED_FAILED"
fi
