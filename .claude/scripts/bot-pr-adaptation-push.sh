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
#   --remote    the git remote to push to; default origin. Its configured URL must name
#               <owner>/<repo> on github.com, or the pull request is left untouched. Rewrite
#               rules (insteadOf) are not followed: what proves delivery is the pull request
#               showing the commit as its head, which is required before PUSHED is said.
#
# OUTPUT (stdout)
#   FENCED <repo>#<n> draft=true auto_merge=none head=<sha>
#   PUSHED <repo>#<n> <commit> -> <branch>
#
# EXIT CODES
#   0  the pull request was fenced, both states were confirmed, and the pull request itself
#      shows the commit as its head, still as an open draft
#   1  refused, nothing pushed: not an open dependency-bot pull request from this repository, the
#      head moved, the commit does not descend from the head, or a state did not hold after the
#      fence was applied (each printed as REFUSED)
#   2  UNKNOWN: a usage error, a remote that is not the pull request's repository, a failed or
#      unreadable read, a failed fence step, a failed push, or any abort.
#      Never read 2 as fenced or as pushed. A pull request this helper already converted to a
#      draft stays a draft: that is the safe side, and the next call finds it fenced.
set -euo pipefail

prog=bot-pr-adaptation-push
# The verdict is recorded only by the three places that reach one, and the EXIT trap reports
# nothing else. An abort is therefore always UNKNOWN, whatever status it carried: an errexit
# abort exits 1, which would otherwise read as "refused, nothing pushed" even after the push
# (a closed reader failing the last line is enough), and bash 3.2 hands the trap a 0 after a
# `set -u` abort.
bot_pr_adaptation_push_verdict=''
# shellcheck disable=SC2329  # invoked by the EXIT trap below
on_exit() {
  if [ -z "$bot_pr_adaptation_push_verdict" ]; then
    printf '%s: aborted before finishing — UNKNOWN\n' "$prog" >&2 || true
    exit 2
  fi
  exit "$bot_pr_adaptation_push_verdict"
}
trap on_exit EXIT

unknown() {
  # Recorded BEFORE the message: with stderr closed the printf fails, and an errexit abort
  # here must still end as UNKNOWN.
  bot_pr_adaptation_push_verdict=2
  printf '%s: UNKNOWN — %s\n' "$prog" "$1" >&2 || true
  exit 2
}
refuse() {
  bot_pr_adaptation_push_verdict=1
  printf 'REFUSED %s\n' "$1" || bot_pr_adaptation_push_verdict=2
  exit "$bot_pr_adaptation_push_verdict"
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
[[ "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || unknown "--remote must be a remote name"
[ -n "$repo_dir" ] && [ -d "$repo_dir" ] || unknown "--repo-dir must be an existing checkout"
git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 || unknown "not a git checkout: $repo_dir"
git -C "$repo_dir" cat-file -e "${commit}^{commit}" 2>/dev/null ||
  unknown "commit ${commit} is not in ${repo_dir}"

# The remote must BE the pull request's repository. Without this the fence goes on one
# repository and the commit to another: a second remote carrying the same branch name accepts
# the push, reads back as pushed, and the pull request never receives the commit. The URL is
# read as configured (the push URL when one is set), and only the GitHub spellings of
# <owner>/<repo> are accepted; anything else, a path or `.` included, is UNKNOWN.
# Every configured value is read: git pushes to ALL push URLs, so a second one would receive
# the commit unchecked. Exactly one is accepted.
remote_url=$(git -C "$repo_dir" config --get-all "remote.${remote}.pushurl" 2>/dev/null) ||
  remote_url=$(git -C "$repo_dir" config --get-all "remote.${remote}.url" 2>/dev/null) ||
  unknown "no remote named ${remote} in ${repo_dir}"
[ "$(printf '%s\n' "$remote_url" | grep -c .)" -eq 1 ] ||
  unknown "remote ${remote} has more than one URL; this helper pushes to exactly one"
remote_slug=''
case "$remote_url" in
  https://github.com/*) remote_slug=${remote_url#https://github.com/} ;;
  git@github.com:*) remote_slug=${remote_url#git@github.com:} ;;
  ssh://git@github.com/*) remote_slug=${remote_url#ssh://git@github.com/} ;;
esac
remote_slug=${remote_slug%/}
remote_slug=${remote_slug%.git}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
[ -n "$remote_slug" ] && [ "$(lower "$remote_slug")" = "$(lower "$repo")" ] ||
  unknown "remote ${remote} does not point at ${repo}"

# How long the pull request is given to show the pushed commit as its head (step 5).
HEAD_WAIT_SECONDS=${BOT_PR_ADAPTATION_PUSH_HEAD_WAIT_SECONDS:-3}
[[ "$HEAD_WAIT_SECONDS" =~ ^[0-9]{1,2}$ ]] ||
  unknown "BOT_PR_ADAPTATION_PUSH_HEAD_WAIT_SECONDS must be a number of seconds below 100"

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
git -C "$repo_dir" push -- "$remote" "${commit}:refs/heads/${branch}" >/dev/null 2>&1 ||
  unknown "the push to ${branch} was rejected or failed; ${repo}#${pr} stays fenced"
remote_head=$(git -C "$repo_dir" ls-remote -- "$remote" "refs/heads/${branch}" 2>/dev/null | awk 'NR == 1 { print $1 }') ||
  unknown "could not read ${branch} back after the push"
[ "$remote_head" = "$commit" ] ||
  unknown "after the push ${branch} is at '${remote_head}', not ${commit}"

# 5. The pull request itself must now show the commit as its head, still as an open draft.
#    The branch read above proves only what the remote holds; this is what proves the commit
#    reached THIS pull request, and it is what automation reacts to. The head can trail the
#    push by a moment, so it is read again each second up to the wait, never assumed.
waited=0
while :; do
  parse_pr "$(read_pr)"
  [ "$pr_head" != "$commit" ] && [ "$waited" -lt "$HEAD_WAIT_SECONDS" ] || break
  sleep 1
  waited=$((waited + 1))
done
[ "$pr_head" = "$commit" ] ||
  unknown "${repo}#${pr} shows ${pr_head} as its head, not the pushed ${commit} — check it now"
[ "$pr_draft" = true ] && [ "$pr_state" = OPEN ] ||
  unknown "${repo}#${pr} is no longer an open draft after the push — check it now"
printf 'PUSHED %s#%s %s -> %s\n' "$repo" "$pr" "$commit" "$branch"
bot_pr_adaptation_push_verdict=0
exit 0
