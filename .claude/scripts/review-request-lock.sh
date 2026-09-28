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
#   ref   refs/agent-review-lock/<pr>/<head>/<provider>/<generation>
#         (outside refs/heads and refs/tags, so it triggers no workflow, matches no ruleset and
#         never shows up as a branch)
#   value an annotated tag object on the PR head whose message records `owner=<token>` and
#         `created_epoch=<seconds>` (no commit is created)
#   A lock older than the lease is taken over by creating the next generation, never by updating
#   a ref, so a takeover is as atomic as the first acquire. By then the request marker the
#   winner posted is visible to every sibling, so the marker re-read also governs.
#
# USAGE
#   review-request-lock.sh acquire --repo <owner/repo> --pr <n> --head <40-hex sha>
#                                  --provider <cr|codex|bugbot> --owner <token> [--lease-minutes N]
#   review-request-lock.sh sweep   --repo <owner/repo> [--apply]
#
#   acquire  run immediately BEFORE posting a review-request comment. It also deletes this PR's
#            locks for other heads, which can no longer matter.
#   sweep    lists (or with --apply deletes) every lock whose PR is no longer open.
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
  sed -n '28,41p' "$0" >&2
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

# new_lock_object — an annotated tag object on the PR head whose message records the owner and the
# creation time. It adds no commit anywhere: the object it points at is the PR's own head commit.
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

# read_lock <key> — sets lock_owner and lock_created from that lock's record.
read_lock() {
  local sha content
  api "repos/${repo}/git/ref/$1" --jq .object.sha || die "could not read $1: ${api_out}"
  sha="${api_out}"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "unexpected lock sha for $1: ${sha}"
  api "repos/${repo}/git/tags/${sha}" --jq .message || die "could not read lock object ${sha}: ${api_out}"
  content="${api_out}"
  lock_owner="$(printf '%s\n' "${content}" | sed -n 's/^owner=//p' | head -n 1)"
  lock_created="$(printf '%s\n' "${content}" | sed -n 's/^created_epoch=//p' | head -n 1)"
  [ -n "${lock_owner}" ] && [[ "${lock_created}" =~ ^[0-9]+$ ]] ||
    die "lock $1 carries no owner/created_epoch — refusing to guess"
}

# latest_generation — prints the highest lock generation for this PR, head and provider (0 = none).
latest_generation() {
  local refs ref g max=0
  api "repos/${repo}/git/matching-refs/${base}/" --jq '.[].ref' || die "could not list ${base}: ${api_out}"
  refs="${api_out}"
  while IFS= read -r ref; do
    [ -n "${ref}" ] || continue
    g="${ref#refs/"${base}"/}"
    [[ "${g}" =~ ^[1-9][0-9]*$ ]] || die "unrecognised lock ref ${ref}"
    [ "${g}" -gt "${max}" ] && max="${g}"
  done <<<"${refs}"
  printf '%s' "${max}"
}

# prune_other_heads — delete this PR's locks for heads other than the current one. Best effort:
# a stale-head lock arbitrates nothing, so a failure here never changes the verdict.
prune_other_heads() {
  local refs ref
  api "repos/${repo}/git/matching-refs/${PREFIX}/${pr}/" --jq '.[].ref' || return 0
  refs="${api_out}"
  while IFS= read -r ref; do
    case "${ref}" in
      "refs/${PREFIX}/${pr}/${head}/"*) ;;
      "refs/${PREFIX}/${pr}/"*) api -X DELETE "repos/${repo}/git/${ref}" || true ;;
    esac
  done <<<"${refs}"
}

# Every state change is a CREATE of a new ref, never an update: the REST API has no
# compare-and-swap on update, so an expired lock is taken over by creating the next generation
# `<base>/<n+1>`, which exactly one contender can do.
acquire() {
  local gen next key age=0 lock
  base="${PREFIX}/${pr}/${head}/${provider}"
  gen="$(latest_generation)"
  next=1
  if [ "${gen}" -gt 0 ]; then
    read_lock "${base}/${gen}"
    if [ "${lock_owner}" = "${owner}" ]; then
      echo "HELD ${base}/${gen} owner=${owner}"
      return 0
    fi
    age=$(($(now_epoch) - lock_created))
    if [ "${age}" -lt $((lease_minutes * 60)) ]; then
      echo "LOCKED ${base}/${gen} owner=${lock_owner} age=${age}s lease=$((lease_minutes * 60))s"
      return 1
    fi
    next=$((gen + 1))
  fi

  key="${base}/${next}"
  lock="$(new_lock_object)"
  if api -X POST "repos/${repo}/git/refs" -f ref="refs/${key}" -f sha="${lock}" --jq .ref; then
    prune_other_heads
    if [ "${next}" -gt 1 ]; then
      echo "ACQUIRED ${key} owner=${owner} takeover-after=${age}s"
    else
      echo "ACQUIRED ${key} owner=${owner}"
    fi
    return 0
  fi
  case "${api_out}" in
    *"Reference already exists"*) ;;
    *) die "could not create ${key}: ${api_out}" ;;
  esac
  read_lock "${key}"
  echo "LOCKED ${key} owner=${lock_owner} (another instance created it first)"
  return 1
}

sweep() {
  local refs ref n state kept=0 swept=0
  local seen=" "
  api --paginate "repos/${repo}/git/matching-refs/${PREFIX}/" --jq '.[].ref' ||
    die "could not list locks: ${api_out}"
  refs="${api_out}"
  while IFS= read -r ref; do
    [ -n "${ref}" ] || continue
    n="${ref#refs/"${PREFIX}"/}"
    n="${n%%/*}"
    [[ "${n}" =~ ^[0-9]+$ ]] || die "unrecognised lock ref ${ref}"
    state=""
    case "${seen}" in
      *" ${n}=open "*) state=open ;;
      *" ${n}=closed "*) state=closed ;;
    esac
    if [ -z "${state}" ]; then
      api "repos/${repo}/pulls/${n}" --jq .state || die "could not read PR #${n}: ${api_out}"
      state="${api_out}"
      seen="${seen}${n}=${state} "
    fi
    case "${state}" in
      open)
        kept=$((kept + 1))
        ;;
      closed)
        swept=$((swept + 1))
        if [ "${apply}" -eq 1 ]; then
          api -X DELETE "repos/${repo}/git/${ref}" || die "could not delete ${ref}: ${api_out}"
          echo "deleted ${ref}"
        else
          echo "would-delete ${ref}"
        fi
        ;;
      *) die "PR #${n} has unrecognised state '${state}'" ;;
    esac
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
