#!/usr/bin/env bash
# Per-tick branch hygiene: delete spent claude/* branches locally and on the remote.
#
# SAFETY CONTRACT (fail-closed):
#   KEEP  - any branch that is the head of an OPEN PR       (deleting it would CLOSE the PR)
#   KEEP  - any branch checked out by a worktree            (git refuses anyway; we skip explicitly)
#   KEEP  - the default branch, and anything not claude/*   (never touch codex/* = the sibling's lane)
#   LOCAL - delete when not in KEEP (squash-merge means `-d` can't see merges, so `-D` + manifest)
#   REMOTE- delete ONLY with positive evidence: an associated MERGED/CLOSED PR, or age > MAX_AGE_DAYS
#           with no PR at all. A recent no-PR branch may be a LIVE session -> left alone.
#
# Every deletion is recorded (branch -> sha) to the manifest so it can be restored from the SHA.
set -uo pipefail

REPO_PATH="$1"; SLUG="$2"; MANIFEST="$3"; MODE="${4:-apply}"
MAX_AGE_DAYS=14
NOW=$(date -u +%s)

cd "$REPO_PATH" || exit 1
git fetch origin --prune -q 2>/dev/null

DEFAULT=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
DEFAULT="${DEFAULT:-main}"

# --- KEEP set -------------------------------------------------------------
keep=$(mktemp); trap 'rm -f "$keep" "$prs"' EXIT
{
  gh pr list --repo "devantler-tech/$SLUG" --state open --limit 300 \
    --json headRefName --jq '.[].headRefName' 2>/dev/null
  git worktree list --porcelain 2>/dev/null | awk '/^branch /{sub("refs/heads/","",$2); print $2}'
  printf '%s\n' "$DEFAULT"
} >>"$keep"

# --- PR state map for remote decisions ------------------------------------
prs=$(mktemp)
gh pr list --repo "devantler-tech/$SLUG" --state all --limit 500 \
  --json headRefName,state --jq '.[]|"\(.headRefName)\t\(.state)"' 2>/dev/null >"$prs"

is_kept() { grep -Fxq "$1" "$keep"; }
pr_state() { awk -F'\t' -v b="$1" '$1==b{print $2; exit}' "$prs"; }

l_del=0; r_del=0; l_keep=0; r_keep=0

# --- LOCAL ----------------------------------------------------------------
while IFS= read -r b; do
  [ -z "$b" ] && continue
  if is_kept "$b"; then l_keep=$((l_keep+1)); continue; fi
  sha=$(git rev-parse "$b" 2>/dev/null)
  printf '%s\tlocal\t%s\t%s\n' "$SLUG" "$b" "$sha" >>"$MANIFEST"
  if [ "$MODE" = "apply" ]; then git branch -D "$b" >/dev/null 2>&1 && l_del=$((l_del+1)); else l_del=$((l_del+1)); fi
done < <(git branch --list 'claude/*' --format='%(refname:short)')

# --- REMOTE ---------------------------------------------------------------
while IFS= read -r rb; do
  b="${rb#origin/}"
  [ -z "$b" ] && continue
  if is_kept "$b"; then r_keep=$((r_keep+1)); continue; fi
  st=$(pr_state "$b")
  if [ "$st" != "MERGED" ] && [ "$st" != "CLOSED" ]; then
    # No PR evidence -> only reap if clearly stale (never nuke a live session's branch).
    ts=$(git log -1 --format=%ct "$rb" 2>/dev/null || echo "$NOW")
    age=$(( (NOW - ${ts:-$NOW}) / 86400 ))
    if [ "$age" -lt "$MAX_AGE_DAYS" ]; then r_keep=$((r_keep+1)); continue; fi
    st="NO-PR-stale-${age}d"
  fi
  sha=$(git rev-parse "$rb" 2>/dev/null)
  printf '%s\tremote\t%s\t%s\t%s\n' "$SLUG" "$b" "$sha" "$st" >>"$MANIFEST"
  if [ "$MODE" = "apply" ]; then git push origin --delete "$b" >/dev/null 2>&1 && r_del=$((r_del+1)); else r_del=$((r_del+1)); fi
done < <(git branch -r --list 'origin/claude/*' --format='%(refname:short)')

# --- return to default ----------------------------------------------------
cur=$(git branch --show-current 2>/dev/null)
if [ "$cur" != "$DEFAULT" ] && [ -n "$cur" ]; then
  git checkout "$DEFAULT" -q 2>/dev/null && sw="-> $DEFAULT" || sw="(could not switch: dirty/worktree)"
else sw="already on $DEFAULT"; fi

printf '%-24s local: -%-4s keep %-3s | remote: -%-3s keep %-3s | %s\n' \
  "$SLUG" "$l_del" "$l_keep" "$r_del" "$r_keep" "$sw"
