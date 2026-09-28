#!/usr/bin/env bash
# review-request-lock.sh — atomic cross-instance arbitration for a review request (monorepo#2894).
#
# WHY THIS EXISTS
#   Rung 1 of the work-selection ladder sends every instance to the same open PR, and the claim
#   protocol's `agent-claim/<issue>` tip is retired the moment a PR opens, so nothing arbitrates PR
#   work between instances. The request marker re-read before posting is not atomic with the post:
#   a sibling that read the comments a few seconds earlier cannot see a request that is not yet
#   posted. Measured 2026-09-14 → 2026-09-28 across 23 repositories: 2,001 request keys
#   (PR + head + provider), 13 duplicated within 60 s and 6 within 30 s (4, 9, 10, 11, 25, 27 s).
#   Each duplicate spends a metered review for nothing.
#
#   The retired pre-trigger reservation COMMENT failed because it was a second comment posted by the
#   same run 1–2 s before its own trigger — no sibling could observe it in time. This lock is not a
#   comment: it is a git ref created through the REST API, and GitHub refuses to create a ref that
#   already exists (HTTP 422). The create IS the read, so exactly one instance wins a key.
#
# MECHANISM
#   ref   refs/agent-review-lock/<pr>/<head>/<generation>
#         (outside refs/heads and refs/tags, so it triggers no workflow, matches no ruleset and
#         never shows up as a branch)
#   value an annotated tag object on the PR head whose message records `owner=<token>`,
#         `created_epoch=<seconds>` and the provider (no commit is created)
#   One lock per PR head, whatever the provider: only one review request may be in flight per head,
#   and the holder moves to the next provider under the same lock. Every state change is the
#   CREATE of a ref, never an update — the REST API has no compare-and-swap on update — so an
#   expired lock is taken over by creating the next generation, which exactly one contender can do.
#   acquire never deletes a lock: a stale worker must not remove a newer head's live lock. Locks
#   for closed PRs and superseded heads are removed by `sweep`, which reads the PR's live head.
#
# USAGE
#   review-request-lock.sh acquire --repo <owner/repo> --pr <n> --head <40-hex sha>
#                                  --provider <cr|codex|bugbot> --owner <token> [--lease-minutes N]
#   review-request-lock.sh sweep   --repo <owner/repo> [--apply]
#
#   acquire  run immediately BEFORE posting a review-request comment.
#   sweep    lists (or with --apply deletes) every lock whose PR is closed or whose head is no
#            longer the PR's head.
#
# EXIT CODES
#   acquire: 0 this owner holds the lock — post the request
#            1 another owner holds a live lock — do not post; move to the next rung-1 item
#            2 unknown (usage error, failed API read) — do not post
#   sweep:   0 done, 2 unknown (a failed read; nothing is reported as clean)
set -euo pipefail

PREFIX="agent-review-lock"

die() {
  echo "review-request-lock: $*" >&2
  exit 2
}

usage() {
  sed -n '31,44p' "$0" >&2
  exit 2
}

now_epoch() {
  if [ -n "${REVIEW_LOCK_NOW:-}" ]; then
    printf '%s' "${REVIEW_LOCK_NOW}"
  else
    date -u +%s
  fi
}

# api <args...> — run `gh api`, capturing stdout+stderr in $api_out; returns gh's status.
api_out=""
api() {
  local rc=0
  api_out="$(gh api "$@" 2>&1)" || rc=$?
  return "${rc}"
}

# new_lock_object — an annotated tag object on the PR head whose message is the lock record. It
# creates no commit: the object it points at is the PR's own head commit.
new_lock_object() {
  local content
  content="$(printf '%s\nowner=%s\ncreated_epoch=%s\npr=%s\nhead=%s\nprovider=%s\n' \
    "${PREFIX}" "${owner}" "$(now_epoch)" "${pr}" "${head}" "${provider}")"
  api -X POST "repos/${repo}/git/tags" -f tag="${PREFIX}" -f message="${content}" \
    -f object="${head}" -f type=commit --jq .sha ||
    die "could not create the lock object: ${api_out}"
  [[ "${api_out}" =~ ^[0-9a-f]{40}$ ]] || die "unexpected lock object sha: ${api_out}"
  printf '%s' "${api_out}"
}

# read_lock <key> — sets lock_owner, lock_created and lock_provider from that lock's record.
read_lock() {
  local sha content
  api "repos/${repo}/git/ref/$1" --jq .object.sha || die "could not read $1: ${api_out}"
  sha="${api_out}"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "unexpected lock sha for $1: ${sha}"
  api "repos/${repo}/git/tags/${sha}" --jq .message || die "could not read lock object ${sha}: ${api_out}"
  content="${api_out}"
  lock_owner="$(printf '%s\n' "${content}" | sed -n 's/^owner=//p' | head -n 1)"
  lock_created="$(printf '%s\n' "${content}" | sed -n 's/^created_epoch=//p' | head -n 1)"
  lock_provider="$(printf '%s\n' "${content}" | sed -n 's/^provider=//p' | head -n 1)"
  [ -n "${lock_owner}" ] && [[ "${lock_created}" =~ ^[0-9]+$ ]] ||
    die "lock $1 carries no owner/created_epoch — refusing to guess"
}

# latest_generation — prints the highest lock generation for this PR head (0 = none). Paginated:
# a key that outgrew one page must never hide its newest generation.
latest_generation() {
  local refs ref g max=0
  api --paginate "repos/${repo}/git/matching-refs/${base}/" --jq '.[].ref' ||
    die "could not list ${base}: ${api_out}"
  refs="${api_out}"
  while IFS= read -r ref; do
    [ -n "${ref}" ] || continue
    g="${ref#refs/"${base}"/}"
    [[ "${g}" =~ ^[1-9][0-9]*$ ]] || die "unrecognised lock ref ${ref}"
    if [ "${g}" -gt "${max}" ]; then
      max="${g}"
    fi
  done <<<"${refs}"
  printf '%s' "${max}"
}

acquire() {
  local gen next key age=0 lock
  base="${PREFIX}/${pr}/${head}"
  gen="$(latest_generation)"
  next=1
  if [ "${gen}" -gt 0 ]; then
    read_lock "${base}/${gen}"
    if [ "${lock_owner}" = "${owner}" ]; then
      echo "HELD ${base}/${gen} owner=${owner} provider=${provider}"
      return 0
    fi
    age=$(($(now_epoch) - lock_created))
    if [ "${age}" -lt $((lease_minutes * 60)) ]; then
      echo "LOCKED ${base}/${gen} owner=${lock_owner} provider=${lock_provider} age=${age}s lease=$((lease_minutes * 60))s"
      return 1
    fi
    next=$((gen + 1))
  fi

  key="${base}/${next}"
  lock="$(new_lock_object)"
  if api -X POST "repos/${repo}/git/refs" -f ref="refs/${key}" -f sha="${lock}" --jq .ref; then
    if [ "${next}" -gt 1 ]; then
      echo "ACQUIRED ${key} owner=${owner} provider=${provider} takeover-after=${age}s"
    else
      echo "ACQUIRED ${key} owner=${owner} provider=${provider}"
    fi
    return 0
  fi
  case "${api_out}" in
    *"Reference already exists"*) ;;
    *) die "could not create ${key}: ${api_out}" ;;
  esac
  read_lock "${key}"
  echo "LOCKED ${key} owner=${lock_owner} provider=${lock_provider} (another instance created it first)"
  return 1
}

sweep() {
  local refs ref rest n h verdict pr_state pr_head kept=0 swept=0
  local seen=" "
  api --paginate "repos/${repo}/git/matching-refs/${PREFIX}/" --jq '.[].ref' ||
    die "could not list locks: ${api_out}"
  refs="${api_out}"
  while IFS= read -r ref; do
    [ -n "${ref}" ] || continue
    rest="${ref#refs/"${PREFIX}"/}"
    n="${rest%%/*}"
    rest="${rest#*/}"
    h="${rest%%/*}"
    [[ "${n}" =~ ^[0-9]+$ ]] || die "unrecognised lock ref ${ref}"
    case "${seen}" in
      *" ${n}="*)
        pr_state="${seen#*" ${n}="}"
        pr_state="${pr_state%% *}"
        ;;
      *)
        api "repos/${repo}/pulls/${n}" --jq '.state + ":" + .head.sha' ||
          die "could not read PR #${n}: ${api_out}"
        pr_state="${api_out}"
        seen="${seen}${n}=${pr_state} "
        ;;
    esac
    pr_head="${pr_state#*:}"
    case "${pr_state%%:*}" in
      open)
        if [ "${h}" = "${pr_head}" ]; then verdict=keep; else verdict=superseded; fi
        ;;
      closed) verdict=closed ;;
      *) die "PR #${n} has unrecognised state '${pr_state}'" ;;
    esac
    if [ "${verdict}" = keep ]; then
      kept=$((kept + 1))
      continue
    fi
    swept=$((swept + 1))
    if [ "${apply}" -eq 1 ]; then
      api -X DELETE "repos/${repo}/git/${ref}" || die "could not delete ${ref}: ${api_out}"
      echo "deleted (${verdict}) ${ref}"
    else
      echo "would-delete (${verdict}) ${ref}"
    fi
  done <<<"${refs}"
  echo "review-request-lock sweep ${repo}: kept=${kept} $([ "${apply}" -eq 1 ] && echo deleted || echo would-delete)=${swept}"
}

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
repo="" pr="" head="" provider="" owner="" lease_minutes=30 apply=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo | --pr | --head | --provider | --owner | --lease-minutes)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --repo) repo="$2" ;;
        --pr) pr="$2" ;;
        --head) head="$2" ;;
        --provider) provider="$2" ;;
        --owner) owner="$2" ;;
        --lease-minutes) lease_minutes="$2" ;;
      esac
      shift 2
      ;;
    --apply)
      apply=1
      shift
      ;;
    -h | --help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be <owner>/<repo>, got '${repo}'"
case "${cmd}" in
  acquire)
    [[ "${pr}" =~ ^[1-9][0-9]*$ ]] || die "--pr must be a PR number, got '${pr}'"
    [[ "${head}" =~ ^[0-9a-f]{40}$ ]] || die "--head must be a full 40-character lowercase sha, got '${head}'"
    case "${provider}" in cr | codex | bugbot) ;; *) die "--provider must be cr, codex or bugbot, got '${provider}'" ;; esac
    [[ "${owner}" =~ ^[A-Za-z0-9._-]{1,100}$ ]] || die "--owner must match [A-Za-z0-9._-]{1,100}, got '${owner}'"
    [[ "${lease_minutes}" =~ ^[1-9][0-9]*$ ]] || die "--lease-minutes must be a positive integer"
    [ "${apply}" -eq 0 ] || die "--apply applies to sweep only"
    acquire
    ;;
  sweep)
    [ -z "${pr}${head}${provider}${owner}" ] || die "sweep takes only --repo and --apply"
    sweep
    ;;
  *) usage ;;
esac
