#!/usr/bin/env bash
# bot-pr-adaptation-push.sh — fence a dependency bot's pull request, THEN push an agent's
# adaptation commit to it (monorepo#3885).
#
# WHY THIS EXISTS
#   A dependency bot's pull request merges by repository automation as soon as its checks pass.
#   That is right for a head the bot generated, and wrong for a head carrying an agent's commit,
#   which must be reviewed first. The merge policy therefore says: convert the pull request to a
#   draft, disable auto-merge and confirm both BEFORE the first adaptation push. Nothing enforced
#   that order. On 2026-10-06 a run pushed an adaptation to monorepo#3884 while auto-merge was
#   armed, and it merged on its checks alone about a minute after they went green.
#   This helper is the one way to push such a commit: the fence comes first, is read back, and
#   the push happens only when both states are confirmed at the head that was observed.
#
# USAGE
#   bot-pr-adaptation-push.sh --repo <owner>/<repo> --pr <n> --repo-dir <checkout> --commit <sha>
#                             [--remote <name>]
#
#   --repo-dir  a local checkout of that repository holding the commit
#   --commit    the FULL 40-character sha to push. It must descend from the pull request's current
#               head: the push is never forced, so a branch that moved is refused by the remote.
#   --remote    the git remote to push to; default origin
#
# OUTPUT (stdout)
#   FENCED <repo>#<n> draft=true auto_merge=none head=<sha>
#   PUSHED <repo>#<n> <commit> -> <branch>
#
# EXIT CODES
#   0  the pull request was fenced, both states were confirmed, and the commit is the branch head
#   1  refused, nothing pushed: not an open dependency-bot pull request from this repository, the
#      head moved, the commit does not descend from the head, or a state did not hold after the
#      fence was applied (each printed as REFUSED)
#   2  UNKNOWN: a usage error, a failed or unreadable read, a failed fence step or a failed push.
#      Never read 2 as fenced or as pushed. A pull request this helper already converted to a
#      draft stays a draft: that is the safe side, and the next call finds it fenced.
set -euo pipefail

prog=bot-pr-adaptation-push
bot_pr_adaptation_push_finished=0
# shellcheck disable=SC2329  # invoked by the EXIT trap below
on_exit() {
  local rc=$?
  if [ "$bot_pr_adaptation_push_finished" != 1 ] && [ "$rc" -ne 1 ] && [ "$rc" -ne 2 ]; then
    printf '%s: aborted before finishing — UNKNOWN\n' "$prog" >&2
    rc=2
  fi
  exit "$rc"
}
trap on_exit EXIT

unknown() {
  printf '%s: UNKNOWN — %s\n' "$prog" "$1" >&2
  exit 2
}
refuse() {
  printf 'REFUSED %s\n' "$1"
  bot_pr_adaptation_push_finished=1
  exit 1
}

repo='' pr='' repo_dir='' commit='' remote=origin
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo | --pr | --repo-dir | --commit | --remote)
      [ "$#" -ge 2 ] || unknown "$1 needs a value"
      case "$1" in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --repo-dir) repo_dir=$2 ;;
        --commit) commit=$2 ;;
        --remote) remote=$2 ;;
      esac
      shift 2
      ;;
    *) unknown "unexpected argument: $1" ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || unknown "--repo must be <owner>/<repo>"
[[ "$pr" =~ ^[1-9][0-9]{0,8}$ ]] || unknown "--pr must be a pull request number"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || unknown "--commit must be a full 40-character lowercase sha"
[[ "$remote" =~ ^[A-Za-z0-9._-]+$ ]] || unknown "--remote must be a remote name"
[ -n "$repo_dir" ] && [ -d "$repo_dir" ] || unknown "--repo-dir must be an existing checkout"
git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 || unknown "not a git checkout: $repo_dir"
git -C "$repo_dir" cat-file -e "${commit}^{commit}" 2>/dev/null ||
  unknown "commit ${commit} is not in ${repo_dir}"

# The exact identities whose pull requests repository automation merges unattended.
BOT_AUTHORS='app/renovate app/dependabot'
FIELDS=state,isDraft,author,headRefName,headRefOid,autoMergeRequest,isCrossRepository

# read_pr prints one validated line: <state> <isDraft> <auto> <cross> <head> <author> <branch>,
# where <auto> is `armed` or `none`. A read that fails, or that lacks any field, is UNKNOWN: a
# missing autoMergeRequest must never read as "not armed".
read_pr() {
  local json line
  json=$(gh pr view "$pr" --repo "$repo" --json "$FIELDS" 2>/dev/null) ||
    unknown "could not read ${repo}#${pr}"
  line=$(jq -r '
    select(type == "object"
      and (.state | type == "string")
      and (.isDraft | type == "boolean")
      and (.isCrossRepository | type == "boolean")
      and has("autoMergeRequest")
      and (.headRefOid | type == "string")
      and (.headRefName | type == "string")
      and (.author.login | type == "string"))
    | [.state, (.isDraft | tostring),
       (if .autoMergeRequest == null then "none" else "armed" end),
       (.isCrossRepository | tostring), .headRefOid, .author.login, .headRefName]
    | join(" ")' <<<"$json" 2>/dev/null) || unknown "unparseable read of ${repo}#${pr}"
  [ -n "$line" ] || unknown "incomplete read of ${repo}#${pr}"
  printf '%s' "$line"
}

parse_pr() {
  # The branch name is last and may not hold a space, so a seven-field line is the only shape.
  read -r pr_state pr_draft pr_auto pr_cross pr_head pr_author pr_branch pr_extra <<<"$1"
  [ -z "${pr_extra:-}" ] && [ -n "${pr_branch:-}" ] || unknown "unexpected read of ${repo}#${pr}"
  [[ "$pr_head" =~ ^[0-9a-f]{40}$ ]] || unknown "unexpected head sha for ${repo}#${pr}"
}

# 1. What is this pull request? Everything below is refused unless it is an open pull request
#    from one of the dependency bots, on a branch of this repository.
parse_pr "$(read_pr)"
[ "$pr_state" = OPEN ] || refuse "${repo}#${pr} is ${pr_state}, not open"
case " $BOT_AUTHORS " in
  *" $pr_author "*) ;;
  *) refuse "${repo}#${pr} is authored by ${pr_author}, not a dependency bot" ;;
esac
[ "$pr_cross" = false ] || refuse "${repo}#${pr} comes from a fork"
# The branch name is the bot's, so it is data: it reaches git only as a full ref, and only when
# it is made of ordinary ref characters.
[[ "$pr_branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] && [[ "$pr_branch" != *..* ]] ||
  refuse "${repo}#${pr} has a branch name this helper will not push to"
observed_head=$pr_head
branch=$pr_branch
[ "$commit" != "$observed_head" ] || refuse "${commit} is already the head of ${repo}#${pr}"
git -C "$repo_dir" cat-file -e "${observed_head}^{commit}" 2>/dev/null ||
  unknown "the head ${observed_head} is not in ${repo_dir}; fetch the branch first"
git -C "$repo_dir" merge-base --is-ancestor "$observed_head" "$commit" 2>/dev/null ||
  refuse "${commit} does not descend from the head ${observed_head}"

# 2. Fence it. Draft first: it is the durable half, because repository automation can re-arm
#    auto-merge after a push but never merges a draft.
if [ "$pr_draft" != true ]; then
  gh pr ready "$pr" --repo "$repo" --undo >/dev/null 2>&1 ||
    unknown "could not convert ${repo}#${pr} to a draft"
fi
if [ "$pr_auto" != none ]; then
  gh pr merge "$pr" --repo "$repo" --disable-auto >/dev/null 2>&1 ||
    unknown "could not disable auto-merge on ${repo}#${pr}"
fi

# 3. Read both states back, whatever the first read said: a fence nobody confirmed is not one.
parse_pr "$(read_pr)"
[ "$pr_state" = OPEN ] || refuse "${repo}#${pr} is ${pr_state}, not open"
[ "$pr_draft" = true ] || refuse "${repo}#${pr} is still not a draft"
[ "$pr_auto" = none ] || refuse "${repo}#${pr} still has auto-merge armed"
[ "$pr_head" = "$observed_head" ] ||
  refuse "the head of ${repo}#${pr} moved from ${observed_head} to ${pr_head}; it stays fenced"
printf 'FENCED %s#%s draft=true auto_merge=none head=%s\n' "$repo" "$pr" "$observed_head"

# 4. Push, never forced: the commit descends from the observed head, so a branch that moved
#    since is rejected by the remote. The branch is then read back; the push's own status is not
#    the evidence.
git -C "$repo_dir" push "$remote" "${commit}:refs/heads/${branch}" >/dev/null 2>&1 ||
  unknown "the push to ${branch} was rejected or failed; ${repo}#${pr} stays fenced"
remote_head=$(git -C "$repo_dir" ls-remote "$remote" "refs/heads/${branch}" 2>/dev/null | awk 'NR == 1 { print $1 }') ||
  unknown "could not read ${branch} back after the push"
[ "$remote_head" = "$commit" ] ||
  unknown "after the push ${branch} is at '${remote_head}', not ${commit}"

# 5. The push is what automation reacts to, so the draft state is confirmed once more.
parse_pr "$(read_pr)"
[ "$pr_draft" = true ] && [ "$pr_state" = OPEN ] ||
  unknown "${repo}#${pr} is no longer an open draft after the push — check it now"
printf 'PUSHED %s#%s %s -> %s\n' "$repo" "$pr" "$commit" "$branch"
bot_pr_adaptation_push_finished=1
exit 0
