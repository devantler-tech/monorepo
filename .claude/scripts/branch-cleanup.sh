#!/usr/bin/env bash
# Per-tick branch hygiene: delete spent claude/* branches locally and on the remote.
#
# SAFETY CONTRACT (fail-closed — every ambiguity resolves to KEEP, every
# infrastructure failure ABORTS the phase that depends on it):
#   KEEP  - any branch that is the head of an OPEN PR       (deleting it would CLOSE the PR)
#   KEEP  - any branch checked out by a worktree            (git refuses anyway; we skip explicitly)
#   KEEP  - the default branch, and anything not claude/*   (never touch codex/* = the sibling's lane)
#   LOCAL - delete when not in KEEP (squash-merge means `-d` can't see merges, so `-D` + manifest)
#   REMOTE- delete ONLY with positive evidence: an associated MERGED/CLOSED PR whose recorded head
#           SHA equals the branch's CURRENT SHA (same incarnation — a re-pushed branch invalidates
#           old PR evidence). Commit age is NOT evidence (commit time != push time), so no-PR
#           branches are REPORTED as candidates, never deleted.
#   CAS   - every remote delete uses --force-with-lease pinned to the evidence SHA, so a branch a
#           concurrent session moves between evidence-gathering and deletion is rejected, and the
#           open-PR keep-set is re-fetched immediately before the delete loop.
#
# Every deletion is recorded (branch -> sha) to the manifest BEFORE the delete, and the write is
# verified — no restore record, no deletion.
set -uo pipefail

REPO_PATH="$1"; SLUG="$2"; MANIFEST="$3"; MODE="${4:-apply}"
errors=0

cd "$REPO_PATH" || exit 1

# Stale refs make every later judgement wrong — abort the whole run on fetch failure.
if ! git fetch origin --prune -q 2>/dev/null; then
  echo "$SLUG: ABORT — git fetch failed; refusing to act on stale refs" >&2
  exit 1
fi

DEFAULT=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
DEFAULT="${DEFAULT:-main}"

# Verified manifest write: no restore record, no deletion.
manifest_write() {
  if ! printf '%s\n' "$1" >>"$MANIFEST" 2>/dev/null; then
    echo "$SLUG: ABORT — manifest write to '$MANIFEST' failed; refusing to delete without a restore record" >&2
    exit 1
  fi
}

# Fetch the open-PR head list; ABORT on failure (an empty keep-set on a failed
# query is the catastrophic fail-open: it would delete every open PR's branch).
fetch_open_heads() {
  local out
  if ! out=$(gh pr list --repo "devantler-tech/$SLUG" --state open --limit 300 \
      --json headRefName --jq '.[].headRefName' 2>/dev/null); then
    echo "$SLUG: ABORT — open-PR query failed; keep-set cannot be trusted" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

# --- KEEP set -------------------------------------------------------------
keep=$(mktemp); prs=$(mktemp); keep2=$(mktemp)
trap 'rm -f "$keep" "$prs" "$keep2"' EXIT
{
  fetch_open_heads
  git worktree list --porcelain 2>/dev/null | awk '/^branch /{sub("refs/heads/","",$2); print $2}'
  printf '%s\n' "$DEFAULT"
} >>"$keep"

# --- PR evidence map for remote decisions ----------------------------------
# newest-first per branch: state + the head SHA the PR evidence belongs to.
if ! gh pr list --repo "devantler-tech/$SLUG" --state all --limit 500 \
    --json headRefName,state,headRefOid \
    --jq '.[]|"\(.headRefName)\t\(.state)\t\(.headRefOid)"' 2>/dev/null >"$prs"; then
  echo "$SLUG: ABORT — PR-state query failed; remote evidence unavailable" >&2
  exit 1
fi

is_kept() { grep -Fxq "$1" "$keep"; }
pr_evidence() { awk -F'\t' -v b="$1" '$1==b{print $2 "\t" $3; exit}' "$prs"; }

l_del=0; r_del=0; l_keep=0; r_keep=0; candidates=0

# --- LOCAL ----------------------------------------------------------------
while IFS= read -r b; do
  [ -z "$b" ] && continue
  if is_kept "$b"; then l_keep=$((l_keep+1)); continue; fi
  sha=$(git rev-parse "$b" 2>/dev/null) || continue
  manifest_write "$(printf '%s\tlocal\t%s\t%s' "$SLUG" "$b" "$sha")"
  if [ "$MODE" = "apply" ]; then
    if git branch -D "$b" >/dev/null 2>&1; then l_del=$((l_del+1));
    else echo "$SLUG: WARN — local delete of '$b' failed" >&2; errors=$((errors+1)); fi
  else l_del=$((l_del+1)); fi
done < <(git branch --list 'claude/*' --format='%(refname:short)')

# --- REMOTE ---------------------------------------------------------------
# Re-fetch the open-PR keep-set IMMEDIATELY before the delete loop: a PR opened
# while we were working must re-protect its branch (ABORTs on query failure).
fetch_open_heads >"$keep2"
re_kept() { grep -Fxq "$1" "$keep2" || grep -Fxq "$1" "$keep"; }

while IFS= read -r rb; do
  b="${rb#origin/}"
  [ -z "$b" ] && continue
  if re_kept "$b"; then r_keep=$((r_keep+1)); continue; fi
  sha=$(git rev-parse "$rb" 2>/dev/null) || { r_keep=$((r_keep+1)); continue; }
  ev=$(pr_evidence "$b"); st="${ev%%$'\t'*}"; ev_sha="${ev#*$'\t'}"
  if [ "$st" != "MERGED" ] && [ "$st" != "CLOSED" ]; then
    # No PR evidence. Commit age is NOT push age — a recent push of old commits
    # would look stale — so no-PR branches are candidates to REPORT, never delete.
    candidates=$((candidates+1)); r_keep=$((r_keep+1)); continue
  fi
  if [ "$ev_sha" != "$sha" ]; then
    # The PR evidence belongs to an older incarnation of this branch name; the
    # current ref carries commits no PR accounts for. Keep it.
    r_keep=$((r_keep+1)); continue
  fi
  manifest_write "$(printf '%s\tremote\t%s\t%s\t%s' "$SLUG" "$b" "$sha" "$st")"
  if [ "$MODE" = "apply" ]; then
    # CAS delete: rejected if the remote ref moved off the evidence SHA.
    if git push --force-with-lease="refs/heads/$b:$sha" origin ":refs/heads/$b" >/dev/null 2>&1; then
      r_del=$((r_del+1))
    else
      echo "$SLUG: WARN — remote delete of '$b' rejected (ref moved or push failed); kept" >&2
      r_keep=$((r_keep+1))
    fi
  else r_del=$((r_del+1)); fi
done < <(git branch -r --list 'origin/claude/*' --format='%(refname:short)')

# --- return to default ----------------------------------------------------
cur=$(git branch --show-current 2>/dev/null)
if [ "$cur" != "$DEFAULT" ]; then
  git checkout "$DEFAULT" -q 2>/dev/null
  now=$(git branch --show-current 2>/dev/null)
  if [ "$now" = "$DEFAULT" ]; then sw="-> $DEFAULT";
  else sw="FAILED to reach $DEFAULT (on '${now:-detached}')"; errors=$((errors+1)); fi
else sw="already on $DEFAULT"; fi

printf '%-24s local: -%-4s keep %-3s | remote: -%-3s keep %-3s cand %-3s | %s\n' \
  "$SLUG" "$l_del" "$l_keep" "$r_del" "$r_keep" "$candidates" "$sw"

[ "$errors" -gt 0 ] && exit 3
exit 0
