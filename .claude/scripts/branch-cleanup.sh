#!/usr/bin/env bash
# Per-tick branch hygiene: delete spent agent-lane branches locally and/or on the remote.
#
# Usage: branch-cleanup.sh <repo_path> <slug> <manifest> [apply|dry-run] [namespace]
#   namespace = claude (default) | cursor
#     claude — local + remote sweep of claude/* (this host's local lane)
#     cursor — REMOTE-ONLY sweep of cursor/* (cloud lane has no local checkout here;
#              local Claude runs this so spent cursor/* remotes do not accumulate forever)
#   codex is intentionally unsupported — the Codex sibling owns its own local lane.
#
# SAFETY CONTRACT (fail-closed — every ambiguity resolves to KEEP, every
# infrastructure failure ABORTS the phase that depends on it):
#   KEEP  - any branch that is the head of an OPEN PR       (deleting it would CLOSE the PR)
#   KEEP  - any branch checked out by a worktree            (git refuses anyway; we skip explicitly)
#   KEEP  - the default branch
#   KEEP  - anything outside the selected namespace's prefix (never touch the other lanes'
#           namespaces from this invocation — run once per namespace)
#   LOCAL - delete when not in KEEP (squash-merge means `-d` can't see merges, so `-D` + manifest).
#           Local deletion runs ONLY for namespace=claude — no other lane has a local checkout on
#           this host (monorepo#2298).
#   REMOTE- delete ONLY with positive evidence: an associated MERGED/CLOSED PR whose recorded head
#           SHA equals the branch's CURRENT SHA (same incarnation — a re-pushed branch invalidates
#           old PR evidence). Commit age is NOT evidence (commit time != push time), so no-PR
#           branches are REPORTED as candidates, never deleted. Same evidence gate for every
#           namespace (claude and cursor alike).
#   CAS   - every remote delete uses --force-with-lease pinned to the evidence SHA, so a branch a
#           concurrent session moves between evidence-gathering and deletion is rejected, and the
#           open-PR keep-set is re-fetched immediately before the delete loop.
#
# Every deletion is recorded (branch -> sha) to the manifest BEFORE the delete, and the write is
# verified — no restore record, no deletion.
set -uo pipefail

REPO_PATH="$1"; SLUG="$2"; MANIFEST="$3"; MODE="${4:-apply}"; NAMESPACE="${5:-claude}"
errors=0

case "$NAMESPACE" in
  claude|cursor) ;;
  codex)
    echo "$SLUG: ABORT — namespace 'codex' is owned by the Codex sibling; refusing to sweep it" >&2
    exit 2
    ;;
  *)
    echo "$SLUG: ABORT — unknown namespace '$NAMESPACE' (expected claude|cursor)" >&2
    exit 2
    ;;
esac

PREFIX="$NAMESPACE"
# Local sweep only for the lane that actually has local checkouts on this host.
DO_LOCAL=0
[ "$NAMESPACE" = "claude" ] && DO_LOCAL=1

cd "$REPO_PATH" || exit 1

# DEFAULT reads the LOCAL origin/HEAD (set at clone) and needs no fresh fetch,
# so the checkout-restoration path can be armed BEFORE fetching.
DEFAULT=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
DEFAULT="${DEFAULT:-main}"

# Return the checkout to where it belongs, FIRST (and again on any abort, via
# trap): a repo left on its tick's claude/* branch would otherwise keep that
# branch in the worktree keep-set forever, and an abort must not strand the
# checkout. A DETACHED start is preserved as-is — an initialized submodule sits
# detached at its superproject pin, and checking out the default branch there
# would silently move it off the pin (superproject drift).
START_BRANCH=$(git branch --show-current 2>/dev/null)
return_to_default() {
  local cur
  cur=$(git branch --show-current 2>/dev/null)
  if [ -z "$START_BRANCH" ]; then
    sw="detached start (submodule pin) — left as-is"
    return
  fi
  if [ "$cur" != "$DEFAULT" ]; then
    git checkout "$DEFAULT" -q 2>/dev/null
    local now
    now=$(git branch --show-current 2>/dev/null)
    if [ "$now" = "$DEFAULT" ]; then sw="-> $DEFAULT";
    else sw="FAILED to reach $DEFAULT (on '${now:-detached}')"; errors=$((errors+1)); fi
  else sw="already on $DEFAULT"; fi
}
sw=""
# Arm restoration BEFORE the fetch (superseded by the tmpfile trap below once it
# is installed): an attached claude/* checkout whose fetch then fails must still
# be returned to the default branch, or it stays worktree-protected on the next
# sweep and defeats the end-of-tick return-and-reap guarantee.
trap 'return_to_default' EXIT
return_to_default

# Stale refs make every later judgement wrong — abort the whole run on fetch
# failure (the EXIT trap above still returns the checkout to the default first).
if ! git fetch origin --prune -q 2>/dev/null; then
  echo "$SLUG: ABORT — git fetch failed; refusing to act on stale refs" >&2
  exit 1
fi

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
trap 'rm -f "$keep" "$prs" "$keep2"; return_to_default' EXIT
# Capture the worktree enumeration SEPARATELY and ABORT on failure: the REMOTE
# delete loop trusts this one snapshot for its worktree KEEP rule (the local loop
# re-checks per branch, the remote loop does not), so a silently-empty list here
# could let a checked-out lane branch with merged/closed PR evidence have its
# upstream deleted — violating the documented worktree KEEP guarantee. A failed
# enumeration means the keep-set cannot be trusted.
if ! wt_branches=$(git worktree list --porcelain 2>/dev/null); then
  echo "$SLUG: ABORT — worktree enumeration failed; keep-set cannot be trusted" >&2
  exit 1
fi
{
  fetch_open_heads
  printf '%s\n' "$wt_branches" | awk '/^branch /{sub("refs/heads/","",$2); print $2}'
  printf '%s\n' "$DEFAULT"
} >>"$keep"

# --- PR evidence map for remote decisions ----------------------------------
# newest-first per branch: state + the head SHA the PR evidence belongs to.
# Bounded evidence is FAIL-CLOSED: a merged PR older than the newest 1000
# results yields "no evidence" => KEEP/candidate, never a deletion.
if ! gh pr list --repo "devantler-tech/$SLUG" --state all --limit 1000 \
    --json headRefName,state,headRefOid,headRepositoryOwner \
    --jq '.[]|select(.headRepositoryOwner.login=="devantler-tech")|"\(.headRefName)\t\(.state)\t\(.headRefOid)"' 2>/dev/null >"$prs"; then
  echo "$SLUG: ABORT — PR-state query failed; remote evidence unavailable" >&2
  exit 1
fi

is_kept() { grep -Fxq "$1" "$keep"; }

# HANDS-OFF the maintainer's INTERACTIVE Claude work. The maintainer also drives
# Claude Code interactively; those sessions use the harness's random-slug worktree
# branch `claude/<adjective>-<name>-<6hex>` (e.g. claude/unruffled-kepler-f3e922),
# marked HANDS-OFF in AGENTS.md. This routine's OWN branches are `claude/<area>-<desc>`
# and never carry a trailing 6-hex slug, so skip anything that does — fail-closed (an
# ambiguous match is KEPT, never reaped), so a merged/closed interactive PR's branch is
# never mistaken for one of this routine's spent per-run worktrees.
# Cursor/Codex lanes do not use that harness pattern — only apply under namespace=claude.
is_interactive_slug() {
  [ "$NAMESPACE" = "claude" ] || return 1
  local last="${1##*-}"
  [[ "$last" =~ ^[0-9a-f]{6}$ ]]
}
pr_evidence() { awk -F'\t' -v b="$1" '$1==b{print $2 "\t" $3; exit}' "$prs"; }

l_del=0; r_del=0; l_keep=0; r_keep=0; candidates=0; r_rej=0

# --- LOCAL (claude only) --------------------------------------------------
if [ "$DO_LOCAL" -eq 1 ]; then
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    if is_kept "$b"; then l_keep=$((l_keep+1)); continue; fi
    if is_interactive_slug "$b"; then l_keep=$((l_keep+1)); continue; fi
    sha=$(git rev-parse "$b" 2>/dev/null) || continue
    # Never lose unpushed work: delete only when the tip is reachable from SOME
    # remote ref, OR a MERGED/CLOSED PR accounts for this exact sha (a
    # squash-merged branch whose remote ref was already pruned is reachable
    # from nothing, yet its work is safely in the PR record). Otherwise keep as
    # a candidate.
    ev=$(pr_evidence "$b"); st="${ev%%$'\t'*}"; ev_sha="${ev#*$'\t'}"
    if [ -z "$(git branch -r --contains "$sha" 2>/dev/null | head -1)" ] &&
       { [ "$st" != "MERGED" ] && [ "$st" != "CLOSED" ] || [ "$ev_sha" != "$sha" ]; }; then
      candidates=$((candidates+1)); l_keep=$((l_keep+1)); continue
    fi
    manifest_write "$(printf '%s\tlocal\t%s\t%s' "$SLUG" "$b" "$sha")"
    if [ "$MODE" = "apply" ]; then
      # update-ref -d BYPASSES the checked-out-branch refusal `git branch -D`
      # has, so re-check the live worktree list right before deleting — a
      # concurrent session may have checked the branch out since the keep-set
      # snapshot. Capture the enumeration SEPARATELY and fail CLOSED (keep) if it
      # errors: piping the failing command straight into grep would let a
      # transient worktree-metadata read error read as "checked out nowhere",
      # and update-ref would then delete a branch live in another worktree,
      # leaving that worktree on a dangling/unborn HEAD.
      if ! wt_list=$(git worktree list --porcelain 2>/dev/null); then
        echo "$SLUG: keep '$b' — worktree enumeration failed; refusing to delete (fail-closed)" >&2
        l_keep=$((l_keep+1)); errors=$((errors+1)); continue
      fi
      if printf '%s\n' "$wt_list" | grep -Fxq "branch refs/heads/$b"; then
        echo "$SLUG: keep '$b' — checked out by a worktree since the snapshot" >&2
        l_keep=$((l_keep+1)); continue
      fi
      # CAS delete: update-ref -d with the expected old value refuses if a
      # concurrent session re-pointed the ref after evidence-gathering.
      if git update-ref -d "refs/heads/$b" "$sha" >/dev/null 2>&1; then l_del=$((l_del+1));
      else echo "$SLUG: WARN — local delete of '$b' rejected (ref moved) or failed" >&2; errors=$((errors+1)); fi
    else l_del=$((l_del+1)); fi
  done < <(git branch --list "${PREFIX}/*" --format='%(refname:short)')
fi

# --- REMOTE ---------------------------------------------------------------
# Re-fetch the open-PR keep-set IMMEDIATELY before the delete loop: a PR opened
# while we were working must re-protect its branch (ABORTs on query failure).
fetch_open_heads >"$keep2"
re_kept() { grep -Fxq "$1" "$keep2" || grep -Fxq "$1" "$keep"; }

while IFS= read -r rb; do
  b="${rb#origin/}"
  [ -z "$b" ] && continue
  if re_kept "$b"; then r_keep=$((r_keep+1)); continue; fi
  if is_interactive_slug "$b"; then r_keep=$((r_keep+1)); continue; fi
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
    # Final per-branch TOCTOU guard: a PR can open between the loop-level
    # keep-set refresh and this very deletion. Fail closed on query failure.
    # RESIDUAL RISK (accepted, no server-side conditional delete exists): a PR
    # opened in the milliseconds between this query and the push below would
    # be closed by the deletion; the manifest sha makes that restorable
    # (push the sha back, reopen the PR).
    open_now=$(gh pr list --repo "devantler-tech/$SLUG" --state open --head "$b" \
      --json number --jq 'length' 2>/dev/null)
    if [ -z "$open_now" ] || [ "$open_now" != "0" ]; then
      echo "$SLUG: keep '$b' — open-PR recheck non-empty or failed" >&2
      r_keep=$((r_keep+1)); continue
    fi
    # CAS delete: rejected if the remote ref moved off the evidence SHA.
    if git push --force-with-lease="refs/heads/$b:$sha" origin ":refs/heads/$b" >/dev/null 2>&1; then
      r_del=$((r_del+1))
    else
      echo "$SLUG: WARN — remote delete of '$b' rejected (ref moved or push failed); kept" >&2
      r_rej=$((r_rej+1)); r_keep=$((r_keep+1))
    fi
  else r_del=$((r_del+1)); fi
done < <(git branch -r --list "origin/${PREFIX}/*" --format='%(refname:short)')

printf '%-24s ns=%-6s local: -%-4s keep %-3s | remote: -%-3s keep %-3s rej %-2s cand %-3s | %s\n' \
  "$SLUG" "$NAMESPACE" "$l_del" "$l_keep" "$r_del" "$r_keep" "$r_rej" "$candidates" "$sw"

[ "$errors" -gt 0 ] && exit 3
exit 0
