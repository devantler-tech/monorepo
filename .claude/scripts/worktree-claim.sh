#!/usr/bin/env bash
# worktree-claim.sh — own a per-run worktree so a sibling cannot squat it unseen.
#
# WHY THIS EXISTS (monorepo#2284)
#   The claim protocol covers the issue (assignee), the branch (pushed ref), and
#   the PR. A worktree directory is claimed by nothing. Two consecutive ticks
#   lost validated work because a sibling edited files inside a worktree this
#   session created while every GitHub-side claim signal read clean — the
#   collision surfaced only as "File has been modified since read" after work
#   was already underway.
#
#   This helper atomically acquires an ownership marker when creating or
#   entering a worktree. A live foreign marker is treated like a live issue
#   claim: pick another lane. Markers expire after ~2 hours so a crashed
#   session parks nothing permanently (same window as issue claims).
#
# USAGE
#   .claude/scripts/worktree-claim.sh add  <repo_path> <worktree_path> <branch> <owner-token>
#       Create the worktree and write the marker. <branch> is created when it does not exist;
#       when it already exists — locally, or only on origin, as an open PR's branch does — the
#       worktree attaches to it at that branch's tip instead of forking a new one.
#       A relative worktree_path is resolved from repo_path.
#   .claude/scripts/worktree-claim.sh check <worktree_path> <my-owner-token>
#       Read-only diagnostic: exit 0 if free / mine / expired; exit 3 if a live
#       foreign claim exists. This does not reserve the worktree.
#   .claude/scripts/worktree-claim.sh acquire <worktree_path> <owner-token>
#       Atomically acquire a free/expired worktree or renew the current owner's
#       lease. Exit 3 without changing the marker when another live owner wins.
#   .claude/scripts/worktree-claim.sh mark  <worktree_path> <owner-token>
#       Compatibility alias for `acquire`.
#
# MARKER
#   Path: <worktree>/.claude-worktree-owner  (gitignored locally by agents; never
#   staged — it is session state, not product content).
#   Format (two lines, KEY=value):
#     owner=<slug>
#     created_at=<ISO-8601 UTC, e.g. 2026-07-21T07:40:00Z>
#
# EXIT CODES
#   0  success / free-or-mine-or-expired
#   1  usage / argument error
#   2  git or filesystem failure
#   3  live foreign claim (check or acquire mode)

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=worktree-claim-lib.sh
. "$SCRIPT_DIR/worktree-claim-lib.sh" || {
  echo "worktree-claim: cannot load shared claim protocol" >&2
  exit 2
}

usage() {
  cat >&2 <<'EOF'
usage:
  worktree-claim.sh add   <repo_path> <worktree_path> <branch> <owner-token>
  worktree-claim.sh check <worktree_path> <my-owner-token>
  worktree-claim.sh acquire <worktree_path> <owner-token>
  worktree-claim.sh mark  <worktree_path> <owner-token>
EOF
  exit 1
}

fail() {
  echo "worktree-claim: $*" >&2
  exit 2
}

write_marker() {
  local wt="$1" owner="$2"
  local marker="$wt/$WORKTREE_CLAIM_MARKER_NAME"
  # Atomic-ish write: temp then mv, so a concurrent reader never sees a half
  # file. Do not stage this path — it is per-session state.
  local tmp
  tmp="$(mktemp "$wt/.claude-worktree-owner.XXXXXX")"
  printf 'owner=%s\ncreated_at=%s\n' "$owner" "$(worktree_claim_utc_now)" >"$tmp"
  mv -f "$tmp" "$marker"
}

trap 'worktree_claim_lock_release >/dev/null 2>&1 || true' EXIT
trap 'exit 2' HUP INT TERM

acquire_lock() {
  local wt=$1 rc=0
  worktree_claim_lock_acquire "$wt" || rc=$?
  case "$rc" in
    0) ;;
    1) fail "timed out waiting for ownership lock: $wt" ;;
    *) fail "malformed, unreadable, or unavailable ownership lock: $wt" ;;
  esac
  [ "$WORKTREE_CLAIM_LOCK_RECOVERED" -eq 1 ] &&
    echo "worktree-claim: recovered stale ownership lock: $WORKTREE_CLAIM_LOCK_REF" >&2
  return 0
}

release_lock() {
  local ref=${WORKTREE_CLAIM_LOCK_REF:-unknown}
  worktree_claim_lock_release || fail "ownership lock changed owner before release: $ref"
}

ignore_marker() {
  local wt="$1"
  local exclude
  exclude="$(git -C "$wt" rev-parse --git-path info/exclude)" ||
    fail "cannot resolve git exclude file for worktree: $wt"
  mkdir -p "$(dirname "$exclude")"
  if ! grep -qxF "/$WORKTREE_CLAIM_MARKER_NAME*" "$exclude" 2>/dev/null; then
    if [ -s "$exclude" ] && [ -n "$(tail -c 1 "$exclude")" ]; then
      printf '\n' >>"$exclude"
    fi
    printf '/%s*\n' "$WORKTREE_CLAIM_MARKER_NAME" >>"$exclude"
  fi
}

read_marker() {
  # Sets MARKER_OWNER and MARKER_CREATED_AT from the file, or leaves them empty.
  local marker="$1"
  MARKER_OWNER=""
  MARKER_CREATED_AT=""
  [ -f "$marker" ] || return 0
  # shellcheck disable=SC2034
  while IFS='=' read -r key val; do
    case "$key" in
      owner) MARKER_OWNER="$val" ;;
      created_at) MARKER_CREATED_AT="$val" ;;
    esac
  done <"$marker"
}

cmd_acquire() {
  local wt="$1" owner="$2"
  [ -d "$wt" ] || fail "worktree path is not a directory: $wt"
  [ -n "$owner" ] || usage
  wt="$(cd "$wt" && pwd -P)" || fail "cannot resolve worktree path: $wt"
  acquire_lock "$wt"
  ignore_marker "$wt"
  local marker="$wt/$WORKTREE_CLAIM_MARKER_NAME" action="acquired"
  read_marker "$marker"
  if [ -e "$marker" ]; then
    if [ -z "${MARKER_OWNER:-}" ] || [ -z "${MARKER_CREATED_AT:-}" ]; then
      fail "malformed ownership marker (owner and created_at are required): $marker"
    fi
    if [ "$MARKER_OWNER" = "$owner" ]; then
      action="renewed"
    else
      local created_epoch now_epoch age
      created_epoch="$(worktree_claim_iso_to_epoch "$MARKER_CREATED_AT")" ||
        fail "unparseable ownership marker timestamp: $MARKER_CREATED_AT"
      now_epoch="$(date -u +%s)"
      age=$((now_epoch - created_epoch))
      if [ "$age" -lt "$WORKTREE_CLAIM_TTL_SECS" ]; then
        echo "worktree-claim: LIVE foreign claim owner=$MARKER_OWNER created_at=$MARKER_CREATED_AT age=${age}s — stand down" >&2
        release_lock
        exit 3
      fi
      action="transferred expired claim"
    fi
  fi
  write_marker "$wt" "$owner"
  release_lock
  echo "worktree-claim: $action $wt owner=$owner"
}

cmd_mark() {
  cmd_acquire "$1" "$2"
}

# add_worktree_on places the worktree on <branch>, creating that branch only when it does not already
# exist. Rung 1 of the work-selection ladder is "finish an open PR", whose branch necessarily predates
# the worktree, so a hardcoded `-b` made the mandated claim helper unusable for the single most common
# case: it exited 2 with `a branch named '<x>' already exists`, and the caller then improvised a bare
# `git worktree add` that writes NO ownership marker (monorepo#2776).
#
# The remote arm is the one that has to be right rather than merely working. On a fresh checkout an
# open PR's branch has no local ref, so `-b` SUCCEEDS and silently forks the PR from local HEAD — a
# worktree that looks correct, carries none of the PR's commits, and would revert it under a plausible
# diff. Attaching to the fetched remote tip is what makes "resume the PR" mean the PR.
# warn_if_local_branch_is_behind reports that an existing local branch trails origin, so attaching to
# it does not silently target an obsolete head. Advisory like every other remote call here: it never
# decides whether `add` succeeds, and it stays SILENT unless it can positively show the branch is
# behind — a warning that fires on every ordinary attach is trained away as noise.
warn_if_local_branch_is_behind() {
  local repo="$1" branch="$2" wt="$3" behind="" fetch_rc=0

  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 0
  # KEEP the fetch's status. Discarding it with `|| true` is what made the silent case unsafe: on a
  # failed or timed-out refresh the comparison below runs against whatever the last successful fetch
  # left behind, so a local ref equal to that obsolete cache counts 0 and the function reports
  # nothing — indistinguishable from a genuinely current branch. `behind=0` is only meaningful when
  # the ref it was measured against was actually refreshed.
  bounded_remote "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" \
    git -C "$repo" fetch --quiet origin \
    "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || fetch_rc=$?
  # Same reasoning as the zero-answer arm below, which is why it cannot be a bare `return 0`: with no
  # tracking ref at all there is nothing to measure, and silence is the output that MEANS "current".
  # A failed refresh is the case where that silence is a lie — and it is the common one here, since
  # resuming an open PR on a fresh checkout is exactly "no cached ref".
  if ! git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    if [ "$fetch_rc" -ne 0 ]; then
      base_freshness_unknown "origin/$branch (refresh failed)"
    fi
    return 0
  fi

  # Count only commits origin has that the local ref lacks. A branch that is merely AHEAD is ordinary
  # unpushed work and says nothing about staleness.
  behind="$(git -C "$repo" rev-list --count "refs/heads/$branch..refs/remotes/origin/$branch" 2>/dev/null)" || return 0
  case "$behind" in
    '' | 0)
      # A non-zero `behind` stays reportable even on a failed refresh — origin demonstrably has those
      # commits, so the warning is true and useful. Only the ZERO answer is uninformative, and only
      # when the refresh failed; say so instead of returning the silence that means "current".
      #
      # Spelled as an `if`, not `[ ... ] && cmd`: under `set -e` that AND-list exits non-zero whenever
      # the test is FALSE, and a standalone list in statement position is not an exempt context — so
      # the common case (refresh succeeded) would abort the claim.
      if [ "$fetch_rc" -ne 0 ]; then
        base_freshness_unknown "origin/$branch (refresh failed)"
      fi
      return 0
      ;;
  esac

  echo "worktree-claim: NOTE local '$branch' is $behind commit(s) behind origin — attaching to the" >&2
  echo "worktree-claim:      LOCAL ref, so this worktree does not carry origin's newer commits." >&2
  # The remediation must MOVE something. `fetch` was already run above and only updates
  # refs/remotes/origin/<branch>, so printing it advertises a command this function has just
  # executed and which leaves the worktree exactly as stale — the operator follows the hint,
  # observes nothing change, and learns to distrust the warning. Name the fast-forward in the
  # WORKTREE, which is where the branch is now checked out and the only place HEAD can advance.
  # `--ff-only` is deliberate: it advances the clean case and REFUSES a diverged branch rather than
  # writing a merge commit nobody asked for, which is the same reason `add` never moves the ref
  # itself.
  echo "worktree-claim:      Reconcile before working:  git -C $(shquote "$wt") merge --ff-only $(shquote "origin/$branch")" >&2
  return 0
}

add_worktree_on() {
  local repo="$1" wt="$2" branch="$3" pinned_tip=""

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    # Local branch exists: attach to it. git still refuses if it is checked out in another worktree,
    # which is the single-checkout rule doing its job — never bypass it.
    #
    # But a local ref left by an earlier run can sit far behind origin, and attaching silently is how
    # a worktree once came up 56 commits behind its own PR — work targets an obsolete head and only
    # the push reveals it, by which time the build is spent. Say so. The branch is NOT moved: a
    # fast-forward here would be a mutation of existing local state, and a diverged branch could be
    # carrying commits that exist nowhere else.
    warn_if_local_branch_is_behind "$repo" "$branch" "$wt"
    git -C "$repo" worktree add "$wt" "$branch"
    return
  fi

  # No local branch. `no tracking ref` is NOT proof the branch is new — it equally means the fetch
  # never answered, and a failed fetch leaves refs/remotes/origin/<branch> untouched. Creating from
  # HEAD on that reading is the silent fork this function exists to prevent, and it is reachable on a
  # mere TIMEOUT of the bounded call, where the network is fine again seconds later and the run does
  # go on to push. So classify the remote before deciding, rather than inferring from absence.
  #
  # A repo with no origin is checked first and separately: nothing can host the branch there, so
  # creating it is correct — and `ls-remote` cannot distinguish that from an unreachable remote,
  # since both exit 128.
  if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo" worktree add -b "$branch" "$wt"
    return
  fi

  # `--exit-code` is the discriminator: 0 = the branch exists on origin, 2 = origin answered and does
  # not have it, anything else = we could not ask (transport, auth, timeout).
  # Keep the OUTPUT, not just the exit code: `ls-remote` prints `<sha>\t<ref>`, so the answer that
  # tells us the branch exists also tells us origin's true tip. That is the only freshness reference
  # available when the fetch below fails, and discarding it is what let a stale cached ref attach
  # silently.
  local ls_rc=0 ls_out="" remote_tip=""
  ls_out="$(bounded_remote "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" \
    git -C "$repo" ls-remote --exit-code --heads origin "refs/heads/$branch" 2>/dev/null)" || ls_rc=$?
  remote_tip="${ls_out%%[![:xdigit:]]*}"

  case "$ls_rc" in
    0)
      # Exists on origin. Refresh the tracking ref so we attach to the CURRENT tip rather than a
      # stale one, then attach. A fetch failure here still leaves a usable lineage below.
      #
      # KEEP the status. A SUCCESSFUL fetch is itself the freshness proof — it wrote the ref from
      # origin just now — so it must outrank the `ls-remote` snapshot taken moments earlier. Judging
      # freshness by comparing the two instead reports a false "could not refresh / STALE" whenever
      # origin advanced between the two calls: the fetch retrieved the NEWER tip, the worktree
      # attached to it, and the operator was told to re-fetch something already current.
      local fetch_rc=0
      bounded_remote "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" \
        git -C "$repo" fetch --quiet origin \
        "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || fetch_rc=$?
      # The fetch is advisory, but the attach below is NOT: it names `origin/$branch`, so if the
      # fetch failed and nothing cached that ref, `worktree add --track` dies on
      # `invalid reference` and `add` FAILS — remote state deciding whether `add` succeeds, which
      # is the property the `*)` arm below is written to preserve. `ls-remote` succeeding and the
      # fetch failing is not exotic: `bounded_remote` gives the fetch a short timeout, so a merely
      # SLOW remote trips it while the network is fine, and a branch this checkout has never
      # fetched has no cached ref to fall back on — exactly the resume-an-open-PR case `add` gained
      # this arm for.
      if ! git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        # We KNOW the branch exists on origin (ls-remote said so) and we could not retrieve it, so
        # creating it locally forks a real PR branch. Say that precisely rather than reusing the
        # `*)` wording, which reports the opposite situation (origin unreachable, existence
        # unknown). The claim protocol compares the remote tip by SHA before pushing, so the fork
        # is caught there — the same safety net the `*)` arm relies on.
        echo "worktree-claim: NOTE '$branch' EXISTS on origin but could not be fetched; creating it" >&2
        echo "worktree-claim:      locally from HEAD — this is a FORK, not a resume. Re-fetch and" >&2
        echo "worktree-claim:      reset onto origin/$branch before committing or pushing." >&2
        git -C "$repo" worktree add -b "$branch" "$wt"
        return
      fi
      # A cached ref EXISTS — but existence is not freshness. Only a FAILED fetch leaves that in
      # doubt: the ref is then whatever the last successful fetch wrote, and attaching to it resumes
      # the PR at an obsolete head. `ls-remote` already told us origin's tip, so compare and say so
      # when they differ. Advisory like everything else here: it never decides whether `add`
      # succeeds. After a successful fetch there is nothing to compare — the ref IS origin's tip.
      local cached_tip=""
      cached_tip="$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch")" || cached_tip=""
      if [ "$fetch_rc" -ne 0 ] && [ -n "$remote_tip" ] && [ -n "$cached_tip" ] && [ "$remote_tip" != "$cached_tip" ]; then
        echo "worktree-claim: NOTE could not refresh '$branch'; the cached origin/$branch is STALE" >&2
        echo "worktree-claim:      (cached ${cached_tip%"${cached_tip#??????????}"} vs origin ${remote_tip%"${remote_tip#??????????}"}). Attaching to the cached tip —" >&2
        echo "worktree-claim:      re-fetch and reset before committing, or this resumes an old head." >&2
      fi
      # PIN the starting point to the immutable SHA we just verified, and create the worktree from
      # THAT rather than from the symbolic `origin/$branch`.
      #
      # Two defects close together here. Git resolves a symbolic starting point when `worktree add`
      # runs, not when the comparison above completed, so a sibling fetch landing in that gap moves
      # the ref and the worktree is silently created at a commit nothing verified. And `--track`
      # requires the starting point to be a ref git considers a trackable remote branch, which it is
      # not in a single-branch clone or any checkout whose `remote.origin.fetch` does not map this
      # branch — the explicit fetch above still creates the ref, but the add is refused with
      # `cannot set up tracking information` and no worktree exists.
      #
      # A SHA answers both: it cannot move, and it needs no tracking metadata to be a valid base.
      pinned_tip="$cached_tip"
      ;;
    2)
      # origin answered and does not have this branch — genuinely new work.
      git -C "$repo" worktree add -b "$branch" "$wt"
      return
      ;;
    *)
      # Could not ask. A stale tracking ref is still this branch's own lineage, so prefer it over a
      # fork and say plainly that its freshness is unverified.
      if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        base_freshness_unknown "origin/$branch (remote lookup failed)"
        # Pin here too. This arm attaches to the cached ref, so it carries the same re-resolution
        # race and the same `--track` refspec constraint as the arm above.
        pinned_tip="$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch")" || pinned_tip=""
      else
        # Nothing to attach to and no way to ask. Creating the branch stays the behaviour here
        # BECAUSE remote state must never decide whether `add` succeeds — that is a pinned property
        # of this helper (four "advisory, not fatal" assertions), and failing would block ordinary
        # new-branch work during any network hiccup. Announce the ambiguity instead of hiding it: the
        # claim protocol independently compares the remote tip by SHA before pushing, so a fork is
        # caught there rather than silently kept.
        echo "worktree-claim: NOTE could not reach origin to check whether '$branch' already exists;" >&2
        echo "worktree-claim:      creating it locally — VERIFY the remote tip before pushing, because" >&2
        echo "worktree-claim:      an existing remote branch would be forked, not resumed." >&2
        git -C "$repo" worktree add -b "$branch" "$wt"
        return
      fi
      ;;
  esac

  # Both surviving arms resolved the tip to an immutable SHA. Fall back to the symbolic ref only if
  # neither could — that is the pre-existing behaviour, not a new path, and it stays reachable rather
  # than turning an unresolvable ref into a hard failure of `add`.
  if [ -n "$pinned_tip" ]; then
    git -C "$repo" worktree add -b "$branch" "$wt" "$pinned_tip"
    # Tracking is a convenience, restored separately and advisorily. `worktree add --track` couples it
    # to branch creation, so its refusal takes the whole add down with it; a separate call cannot.
    # `|| true` is what keeps that true — the worktree is already correctly created at the verified
    # SHA, and a missing upstream must never undo it.
    #
    # In an ordinary clone this writes exactly what `--track` wrote (`branch.<b>.remote=origin`,
    # `branch.<b>.merge=refs/heads/<b>`), so tracking behaviour is unchanged. In a narrow-refspec
    # clone it also refuses, for the same root reason the add did: git decides "is this a remote
    # branch" from `remote.origin.fetch`, not from the ref existing. That residual is deliberate and
    # bounded — the worktree is created on the right commit and simply carries no upstream, where
    # before it did not exist at all. The two config keys are NOT written by hand to force it: git
    # refuses because `git fetch` under that refspec would never update the ref, so the tracking it
    # declined to set up would be misleading rather than merely absent.
    git -C "$repo" branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1 || true
  else
    git -C "$repo" worktree add --track -b "$branch" "$wt" "origin/$branch"
  fi
}

cmd_add() {
  local repo="$1" wt="$2" branch="$3" owner="$4"
  [ -d "$repo" ] || fail "repo path is not a directory: $repo"
  [ -n "$wt" ] && [ -n "$branch" ] && [ -n "$owner" ] || usage
  local repo_abs
  repo_abs="$(cd "$repo" && pwd -P)" || fail "cannot resolve repo path: $repo"
  case "$wt" in
    /*) ;;
    *) wt="$repo_abs/$wt" ;;
  esac
  if [ -e "$wt" ]; then
    fail "worktree path already exists: $wt"
  fi
  # Create parent so git worktree add can place the tree.
  mkdir -p "$(dirname "$wt")"
  if ! add_worktree_on "$repo" "$wt" "$branch"; then
    fail "git worktree add failed for $wt (branch $branch)"
  fi
  # Claim BEFORE the advisory freshness check, not after. That check makes up to two bounded remote
  # calls, so it can hold the newly-created tree unclaimed for the length of both timeouts — a window
  # in which a concurrent run can take the marker, leaving this invocation to create the worktree and
  # branch and then exit 3 without the lane it just built. Ownership is the point of `add`; freshness
  # is a NOTE, so the note waits.
  cmd_acquire "$wt" "$owner"
  # `|| true`: the check is advisory by contract, so its status must never decide whether `add`
  # succeeded. Every path in it returns 0 today, but relying on that couples the claim's exit code to
  # the internals of a NOTE -- one future `return 1` on an unresolvable comparison would abort the
  # claim under `set -e`, after the worktree and branch were already created.
  warn_if_base_is_stale "$repo" "$wt" || true
  echo "worktree-claim: added $wt on $branch owner=$owner"
}

# base_freshness_unknown reports that the comparison could not be made. Both unresolvable paths emit
# it: staying silent would be indistinguishable from "base is current", which is the exact confusion
# the staleness check below exists to remove.
base_freshness_unknown() {
  echo "worktree-claim: NOTE could not resolve $1 — base freshness UNKNOWN, verify before" >&2
  echo "worktree-claim:      concluding anything about current upstream behaviour." >&2
}

# How long an advisory remote call may take before it is abandoned. Short on purpose: this runs on
# the creation path of every worktree, and its answer is a NOTE, never a gate.
WORKTREE_CLAIM_REMOTE_TIMEOUT_DEFAULT=10
WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="${WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS:-$WORKTREE_CLAIM_REMOTE_TIMEOUT_DEFAULT}"

# The bound is handed straight to `sleep`, so a malformed value makes that `sleep` fail instantly and
# collapses the bound to roughly zero: the remote is abandoned before it can answer, and a REACHABLE
# remote is then reported UNKNOWN for a reason nothing states.
#
# The accept condition is "all digits AND at least one non-zero digit", which is deliberately not the
# same as "not equal to 0". Zero is a well-formed integer that is not a bound, and it has infinitely
# many spellings: `00` and `000` are digit-only, are not the literal `0`, and `sleep` returns from all
# of them immediately. Matching a VALUE rather than a set of spellings is what makes this closed --
# an earlier round rejected only `0` and let `00` through. `0001` is accepted, and correctly so: it
# is an unusual spelling of a genuine 1-second bound.
#
# Validated HERE, once, rather than inside bounded_remote: both call sites redirect that function's
# stderr (`2>/dev/null`, so an advisory remote failure cannot abort the claim), which would swallow
# the notice at exactly the moment it matters. Reporting the rejection is the point -- falling back
# silently would trade one invisible failure for another.
# The RANGE matters as much as the spelling, and both ends defeat the bound. `sleep` is what enforces
# it, and BSD sleep (the primary host) rejects a value at/above ~2^31 outright -- usage error, returns
# instantly -- so the killer fires immediately and TERMs a perfectly reachable remote: the bound
# collapses to ~0 and every claim reports UNKNOWN. GNU sleep accepts the same value and waits ~317
# years, i.e. no bound at all. A merely large in-range value (`600000`, the "someone meant
# milliseconds" case) is unbounded on both. So accept only 1..3600.
#
# LENGTH is checked BEFORE the numeric comparison, and that ordering is load-bearing: `[` parses its
# operands as machine integers, so `[ 99999999999999999999 -ge 1 ]` does not return false -- it errors
# ("integer expression expected") with status 2, which inside an `if` is indistinguishable from a
# clean false and would fail OPEN. Digits-only is established first, so the length test is safe.
case "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" in
  *[!0-9]* | '') worktree_claim_timeout_usable=no ;;
  *[1-9]*)
    if [ "${#WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS}" -le 4 ] &&
      [ "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" -ge 1 ] &&
      [ "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" -le 3600 ]; then
      worktree_claim_timeout_usable=yes
    else
      worktree_claim_timeout_usable=no
    fi
    ;;
  *) worktree_claim_timeout_usable=no ;;
esac
if [ "$worktree_claim_timeout_usable" = no ]; then
  echo "worktree-claim: NOTE ignoring unusable WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS=" \
    "'$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS', using ${WORKTREE_CLAIM_REMOTE_TIMEOUT_DEFAULT}s" >&2
  WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS="$WORKTREE_CLAIM_REMOTE_TIMEOUT_DEFAULT"
fi
unset worktree_claim_timeout_usable

# bounded_remote runs an advisory remote git call that can never hang the claim.
#
# Both remote calls below happen inside cmd_add, where the freshness check is explicitly allowed to
# fail — so a remote that never answers must not block worktree creation. Two different hangs are
# possible and they need different fixes: a credential or passphrase PROMPT waits forever (closed by
# GIT_TERMINAL_PROMPT and ssh BatchMode), and an UNREACHABLE host waits on TCP (closed by the timer).
#
# Deliberately not coreutils `timeout`: it is absent from a stock macOS, which is both this script's
# primary host and one leg of the CI matrix, so a timeout-based bound would silently not apply on the
# platform that needs it most. The killer subshell below is portable to bash 3.2.
#
# Two non-obvious details, both verified rather than assumed:
#   * the command is `wait`ed on, not polled with `kill -0` — a finished child stays a zombie until it
#     is reaped, so a poll loop would spin until the deadline instead of returning immediately;
#   * the killer's stdout is redirected, because it would otherwise inherit and hold open a caller's
#     pipe, making every call take the full timeout even when git answered instantly.
bounded_remote() {
  local secs="$1"
  shift
  local cmd_pid killer_pid rc=0 had_monitor=0
  # Job control gives the background command its OWN process group, which is what makes the whole
  # transport tree killable. git delegates to a helper (`git remote-ext`, ssh, git-remote-https); a
  # kill aimed at the git pid alone leaves that helper reparented and running to ITS native timeout,
  # and `add` can time out twice per call, so an unresponsive remote accumulates them.
  case "$-" in *m*) had_monitor=1 ;; esac
  set -m
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" "$@" &
  cmd_pid=$!
  # The killer is started while job control is STILL on, so it too gets its own process group. That
  # is what makes it killable as a tree: the subshell's `sleep` is a separate child, and a signal to
  # the subshell's pid alone does not reach it -- so on the fast path, where the command answers long
  # before the deadline, the timer's `sleep` outlived the call and ran to its full duration. Every
  # normal `add` leaked one or two of them.
  (
    sleep "$secs"
    # Negative pid = the process GROUP. Falls back to the single pid if the group is already gone
    # (or job control was unavailable), so a host without it degrades to the previous behaviour
    # rather than failing to time out at all.
    kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  killer_pid=$!
  [ "$had_monitor" -eq 1 ] || set +m
  # `wait` reports a signal-killed job on the SHELL's stderr, so it is silenced here rather than at
  # each call site.
  { wait "$cmd_pid" || rc=$?; } 2>/dev/null
  # Group first, so the timer's own `sleep` child goes with it; single pid only as the fallback for
  # a host where job control was unavailable and no separate group exists.
  kill -TERM -"$killer_pid" 2>/dev/null || kill -TERM "$killer_pid" 2>/dev/null || true
  { wait "$killer_pid" || true; } 2>/dev/null
  # SIGTERM is catchable AND ignorable, so the timer's TERM only *asks* the tree to stop. `wait`
  # above returns as soon as GIT exits -- git honours TERM -- but a transport helper that ignores it
  # survives, reparented, running to its own native timeout. `add` then reports success while
  # leaving a process behind, and it can do so twice per call.
  #
  # The sweep has to be HERE rather than as a second stage inside the killer: `wait` returns the
  # moment git dies and the very next line kills the killer, so anything scheduled after a grace
  # period in that subshell is cancelled before it ever runs. (Verified -- a grace-then-KILL written
  # inside the killer left the orphan alive, and the test failed identically with and without it.)
  #
  # SIGKILL cannot be trapped, so this is what actually reaps the group. No grace period is owed:
  # `wait` has already returned, so the command is finished and every remaining group member is by
  # definition a descendant that outlived it. Sleeping first would also charge the delay to EVERY
  # call, including the fast success path, to no purpose. On that path the group is already empty
  # and the kill is a silent no-op.
  kill -KILL -"$cmd_pid" 2>/dev/null || true
  return "$rc"
}

# shquote renders "$1" as one single-quoted shell word, so a path or ref containing spaces, newlines,
# or shell metacharacters prints as a single safely reusable argument rather than something that
# would re-split or be interpreted if pasted back into a shell.
#
# The escaping is a parameter expansion rather than `$(… | sed …)`: command substitution strips
# TRAILING NEWLINES, so a path ending in one was quoted as a different path than the one being
# operated on — and this output is a command the reader is invited to paste and run.
shquote() {
  local escaped=${1//\'/\'\\\'\'}
  printf "'%s'" "$escaped"
}

# warn_if_base_is_stale reports how far the new worktree's base is behind the remote default branch.
#
# A submodule worktree is created at the PINNED gitlink, not at the remote default branch, and git
# says nothing about the gap. That silence is the whole defect: a tree tens of commits stale reads
# exactly like a current one, so "this code is missing X" can be true of the pin and false upstream.
# Measured twice on the same issue (ksail#6203, pin 7ac8e7bb) — the second time it reached a public
# root-cause comment asserting a security hole that two merged PRs had already closed. A prose rule
# did not prevent either occurrence, because the moment you need it is the moment you have no reason
# to suspect anything. So the check is unconditional and its output lands at creation time.
#
# Advisory, never fatal: creating a worktree at the pin is legitimate (a monorepo-coordinated change
# pins deliberately), and an offline or restricted host must still be able to claim one.
warn_if_base_is_stale() {
  local repo="$1" wt="$2" default_ref default_branch behind remote_tip tipref
  # Ask the REMOTE for its current default branch. refs/remotes/origin/HEAD is local metadata written
  # at clone time and never refreshed, so once a repository's default moves (main → trunk) the stale
  # pointer makes this compare against a branch the remote no longer defaults to — and report "not
  # behind" while the tree is arbitrarily stale, which is precisely the silence this check removes.
  # `|| true`: with `set -o pipefail` a repo that has no origin at all (or an unreachable one) would
  # otherwise abort the whole claim on an advisory check that is explicitly allowed to fail.
  default_branch="$(bounded_remote "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" \
    git -C "$repo" ls-remote --symref origin HEAD 2>/dev/null |
    awk '$1 == "ref:" && $2 ~ /^refs\/heads\// { sub("^refs/heads/", "", $2); print $2; exit }' || true)"
  if [ -z "$default_branch" ]; then
    # Remote discovery FAILED, and that is not the same as "the default is probably main". The local
    # pointer and the conventional guess are exactly the stale sources this function was written to
    # stop trusting: if the remote default has moved, the old branch usually still exists and still
    # fetches, so comparing against it yields behind=0 and reports a current base for an arbitrarily
    # stale tree — the silent false-current this check exists to remove, reached by the fallback
    # rather than by the bug it replaced.
    #
    # Claiming still succeeds (advisory, never fatal); only the freshness VERDICT becomes UNKNOWN.
    base_freshness_unknown "origin/HEAD"
    return 0
  fi
  # The name came from the REMOTE, so it is untrusted input on a path that feeds `git fetch`. Passed
  # positionally, a name beginning with `-` is parsed as an OPTION, not a branch: a remote whose HEAD
  # symrefs to `refs/heads/--upload-pack=<cmd>` makes this run `git fetch … --upload-pack=<cmd>`, and
  # git honours it — an arbitrary-command primitive on the creation path of every worktree. The awk
  # above now requires the symref to live under refs/heads/, and this rejects anything that is not a
  # plain branch name. Rejection is advisory like every other failure here: UNKNOWN, never fatal.
  case "$default_branch" in
  -* | *[!A-Za-z0-9._/-]*)
    base_freshness_unknown "origin/HEAD"
    return 0
    ;;
  esac
  default_ref="origin/$default_branch"
  # Fetch into a PRIVATE per-invocation ref rather than reading FETCH_HEAD afterwards. FETCH_HEAD is
  # shared mutable state of "$repo" — the path every concurrent lane passes — so any other fetch there
  # (a sibling claim, branch-cleanup, submodule-init) between the fetch and the read replaces it, and
  # the comparison silently answers about the WRONG branch: measured as a stale tree reported with no
  # warning at all, which is exactly the false-current this check exists to remove.
  #
  # `+refs/heads/<b>:<tipref>` also removes two further defects of the positional form: the refspec is
  # what is fetched regardless of the repository's `remote.origin.fetch` mapping (the narrowed-refspec
  # case), and a leading `-` can no longer reach git's option parser even if the guard above is ever
  # loosened. `--no-recurse-submodules` because git defaults to on-demand recursion: on a superproject
  # with moved gitlinks — precisely the stale base this warns about — the advisory call would fetch
  # every changed submodule inside its timeout and degrade to UNKNOWN on the repo it exists for.
  # `--no-tags` for the same reason: this needs one commit, not the tag graph.
  tipref="refs/worktree-claim/tip-$$"
  if ! bounded_remote "$WORKTREE_CLAIM_REMOTE_TIMEOUT_SECS" \
    git -C "$repo" fetch --quiet --no-tags --no-recurse-submodules \
    origin "+refs/heads/$default_branch:$tipref" 2>/dev/null; then
    git -C "$repo" update-ref -d "$tipref" 2>/dev/null || true
    base_freshness_unknown "$default_ref"
    return 0
  fi
  # Compare against the tip THIS invocation fetched, never against refs/remotes/origin/*. A positional
  # `git fetch origin <branch>` retrieves the branch but leaves the tracking ref alone wherever the
  # repository's `remote.origin.fetch` mapping does not cover it — narrowed, customised, or a remote
  # added without one. origin/<branch> then stays frozen while resolving perfectly, so every guard here
  # passes and the ANSWER is silently wrong: measured on a stale origin/main with the remote three
  # commits ahead, this reported no gap at all. The explicit refspec above writes the tip into a ref
  # this call owns, so the value read back cannot disagree with what was retrieved, and — unlike
  # FETCH_HEAD — no concurrent fetch in "$repo" can overwrite it in between.
  #
  # Resolve the private ref this invocation just wrote, then delete it immediately — it is a scratch
  # value, not state any later run should inherit. Deleting BEFORE the emptiness test keeps the ref
  # from surviving the UNKNOWN path too.
  remote_tip="$(git -C "$repo" rev-parse --verify --quiet "$tipref^{commit}" 2>/dev/null)" || remote_tip=""
  git -C "$repo" update-ref -d "$tipref" 2>/dev/null || true
  if [ -z "$remote_tip" ]; then
    base_freshness_unknown "$default_ref"
    return 0
  fi
  # A FAILED rev-list is an unavailable comparison, not a current base. Folding it into `|| echo 0`
  # made the normalisation below accept it and the numeric test skip silently — reporting neither a
  # warning nor UNKNOWN, which is the same silent "looks current" this check exists to remove.
  if ! behind="$(git -C "$wt" rev-list --count "HEAD..$remote_tip" 2>/dev/null)"; then
    base_freshness_unknown "$default_ref"
    return 0
  fi
  # A non-integer (empty, or an error string) from a command that nonetheless SUCCEEDED must be
  # handled before the numeric test, or `[ "$behind" -gt 0 ]` fails OPEN inside an if and silently
  # skips the very warning this exists for. It takes the UNKNOWN path rather than normalising to 0:
  # folding it to 0 also stopped the fail-open, but it bought that by rendering an unestablished
  # comparison exactly like a current base — the same silence the FAILED-rev-list branch above
  # refuses, and the one this whole check exists to remove.
  case "$behind" in '' | *[!0-9]*)
    base_freshness_unknown "$default_ref"
    return 0
    ;;
  esac
  [ "$behind" -gt 0 ] || return 0
  echo "worktree-claim: WARNING base is $behind commit(s) behind $default_ref" >&2
  echo "worktree-claim:      This tree does NOT show current $default_ref. Anything you conclude here" >&2
  echo "worktree-claim:      about 'current behaviour' may already be changed or fixed upstream." >&2
  # The hint must not send the reader to `origin/<branch>`, which is the very ref the measurement
  # above refuses to trust — under a NARROWED `remote.origin.fetch` the tracking ref is not updated
  # by the fetch and stays frozen at its old value. It still resolves, so the rebase reports
  # "Current branch main is up to date." and leaves the tree exactly as stale as the warning just
  # said it was. Measured: 3 commits behind, old hint run, still 3 commits behind. That is the same
  # silent false-current this function exists to remove, reintroduced inside its own remedy — and
  # worse than a hard failure, because git agrees with the user and the warning reads as noise.
  #
  # A MOVED default is NOT a second instance of this, though it looks like one: the claim's fetch
  # carries the repository's configured refspec in addition to the command-line one, so an ordinary
  # consumer gains refs/remotes/origin/<newbranch> as a side effect and the old hint would have run
  # there. Only the narrowed-mapping case is real; the negative control below pins that distinction
  # so this comment cannot quietly generalise back.
  #
  # What was MEASURED is the fetched branch tip, so that is what must be rebased onto. FETCH_HEAD is
  # per-worktree and BOTH halves run in "$wt", so the value read back is the one just written there —
  # a fetch in "$repo" would reintroduce the shared-mutable-state trap the measurement avoids.
  echo "worktree-claim:      Rebase before analysing:  git -C $(shquote "$wt") fetch origin $(shquote "$default_branch") &&" >&2
  echo "worktree-claim:                                git -C $(shquote "$wt") rebase FETCH_HEAD" >&2
}

cmd_check() {
  local wt="$1" me="$2"
  [ -n "$me" ] || usage
  if [ ! -d "$wt" ]; then
    # No directory → nothing to squat; caller may create.
    echo "worktree-claim: free (path absent)"
    exit 0
  fi
  local marker="$wt/$WORKTREE_CLAIM_MARKER_NAME"
  read_marker "$marker"
  if [ ! -e "$marker" ]; then
    echo "worktree-claim: free (no live marker)"
    exit 0
  fi
  if [ -z "${MARKER_OWNER:-}" ] || [ -z "${MARKER_CREATED_AT:-}" ]; then
    fail "malformed ownership marker (owner and created_at are required): $marker"
  fi
  if [ "$MARKER_OWNER" = "$me" ]; then
    echo "worktree-claim: mine (owner=$MARKER_OWNER)"
    exit 0
  fi
  local created_epoch now_epoch age
  created_epoch="$(worktree_claim_iso_to_epoch "$MARKER_CREATED_AT")" ||
    fail "unparseable ownership marker timestamp: $MARKER_CREATED_AT"
  now_epoch="$(date -u +%s)"
  age=$((now_epoch - created_epoch))
  if [ "$age" -ge "$WORKTREE_CLAIM_TTL_SECS" ]; then
    echo "worktree-claim: free (expired age=${age}s owner=$MARKER_OWNER)"
    exit 0
  fi
  echo "worktree-claim: LIVE foreign claim owner=$MARKER_OWNER created_at=$MARKER_CREATED_AT age=${age}s — stand down" >&2
  exit 3
}

main() {
  [ $# -ge 1 ] || usage
  local mode="$1"
  shift
  case "$mode" in
    add)
      [ $# -eq 4 ] || usage
      cmd_add "$1" "$2" "$3" "$4"
      ;;
    check)
      [ $# -eq 2 ] || usage
      cmd_check "$1" "$2"
      ;;
    acquire)
      [ $# -eq 2 ] || usage
      cmd_acquire "$1" "$2"
      ;;
    mark)
      [ $# -eq 2 ] || usage
      cmd_mark "$1" "$2"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
