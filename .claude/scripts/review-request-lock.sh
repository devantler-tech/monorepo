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
#   ref   refs/agent-review-lock/<pr>/<head>/<provider>   (outside refs/heads and refs/tags, so it
#         triggers no workflow, matches no ruleset and never shows up as a branch)
#   value a parentless commit whose message records `owner=<token>` and `created_epoch=<seconds>`
#   A lock older than the lease may be taken over. After the lease, the request marker the winner
#   posted is visible to every sibling, so the marker re-read governs from then on.
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
  sed -n '25,38p' "$0" >&2
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

new_lock_commit() {
  local content tree
  content="$(printf '%s\nowner=%s\ncreated_epoch=%s\npr=%s\nhead=%s\nprovider=%s\n' \
    "${PREFIX}" "${owner}" "$(now_epoch)" "${pr}" "${head}" "${provider}")"
  # GitHub documents refs as pointing at commits, so the record is a parentless commit whose
  # message holds it (its one-file tree carries the same text for anyone browsing the ref).
  api -X POST "repos/${repo}/git/trees" -f "tree[][path]=lock" -f "tree[][mode]=100644" \
    -f "tree[][type]=blob" -f "tree[][content]=${content}" --jq .sha ||
    die "could not create the lock tree: ${api_out}"
  [[ "${api_out}" =~ ^[0-9a-f]{40}$ ]] || die "unexpected tree sha: ${api_out}"
  tree="${api_out}"
  api -X POST "repos/${repo}/git/commits" -f message="${content}" -f tree="${tree}" --jq .sha ||
    die "could not create the lock commit: ${api_out}"
  [[ "${api_out}" =~ ^[0-9a-f]{40}$ ]] || die "unexpected commit sha: ${api_out}"
  printf '%s' "${api_out}"
}

# read_lock — sets lock_owner and lock_created from the current lock value.
read_lock() {
  local sha content
  api "repos/${repo}/git/ref/${key}" --jq .object.sha || die "could not read ${key}: ${api_out}"
  sha="${api_out}"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "unexpected lock sha for ${key}: ${sha}"
  api "repos/${repo}/git/commits/${sha}" --jq .message || die "could not read lock commit ${sha}: ${api_out}"
  content="${api_out}"
  lock_owner="$(printf '%s\n' "${content}" | sed -n 's/^owner=//p' | head -n 1)"
  lock_created="$(printf '%s\n' "${content}" | sed -n 's/^created_epoch=//p' | head -n 1)"
  [ -n "${lock_owner}" ] && [[ "${lock_created}" =~ ^[0-9]+$ ]] ||
    die "lock ${key} carries no owner/created_epoch — refusing to guess"
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

acquire() {
  local lock age
  key="${PREFIX}/${pr}/${head}/${provider}"
  lock="$(new_lock_commit)"
  if api -X POST "repos/${repo}/git/refs" -f ref="refs/${key}" -f sha="${lock}" --jq .ref; then
    prune_other_heads
    echo "ACQUIRED ${key} owner=${owner}"
    return 0
  fi
  case "${api_out}" in
    *"Reference already exists"*) ;;
    *) die "could not create ${key}: ${api_out}" ;;
  esac

  read_lock
  if [ "${lock_owner}" = "${owner}" ]; then
    echo "HELD ${key} owner=${owner}"
    return 0
  fi
  age=$(($(now_epoch) - lock_created))
  if [ "${age}" -lt $((lease_minutes * 60)) ]; then
    echo "LOCKED ${key} owner=${lock_owner} age=${age}s lease=$((lease_minutes * 60))s"
    return 1
  fi

  # Expired: take it over, then read back. The REST API offers no compare-and-swap on update, so
  # two simultaneous takeovers can both win; by then the first request's marker is visible and the
  # caller's marker re-read is what arbitrates.
  api -X PATCH "repos/${repo}/git/refs/${key}" -f sha="${lock}" -F force=true --jq .ref ||
    die "could not take over expired ${key}: ${api_out}"
  read_lock
  if [ "${lock_owner}" != "${owner}" ]; then
    echo "LOCKED ${key} owner=${lock_owner} (lost the takeover)"
    return 1
  fi
  prune_other_heads
  echo "ACQUIRED ${key} owner=${owner} takeover-after=${age}s"
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
