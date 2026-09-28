#!/usr/bin/env bash
# Hermetic test for review-request-lock.sh (monorepo#2894).
#
# `gh` is stubbed on PATH by a small ref store that behaves like the GitHub REST git-refs API:
# creating a ref that exists fails with HTTP 422 "Reference already exists", and the create is
# atomic (O_EXCL via noclobber), so the concurrency case exercises a real race rather than a
# sequence. No network, no token.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lock="${script_dir}/review-request-lock.sh"
tmp="$(mktemp -d)"
review_lock_test_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$review_lock_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "review-request-lock.test: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

store="$tmp/store"
mkdir -p "$tmp/bin" "$store/refs" "$store/blobs" "$store/pulls"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal GitHub REST stand-in for the git refs, trees, commits and pulls endpoints.
set -euo pipefail
store="${GH_STUB_STORE:?}"
[ "$1" = api ] || { echo "stub: only 'gh api' is supported" >&2; exit 1; }
shift
method=GET path="" jq="" declare_ref="" declare_sha="" content=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --jq) jq="$2"; shift 2 ;;
    --paginate) shift ;;
    -f | -F)
      case "$2" in
        ref=*) declare_ref="${2#ref=}" ;;
        sha=*) declare_sha="${2#sha=}" ;;
        content=*) content="${2#content=}" ;;
        "tree[][content]="*) content="${2#"tree[][content]="}" ;;
        message=*) content="${2#message=}" ;;
      esac
      shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
if [ -n "${GH_STUB_FAIL:-}" ] && [[ "${method} ${path}" == *${GH_STUB_FAIL}* ]]; then
  echo '{"message":"Server Error","status":"502"}'; echo "gh: Server Error (HTTP 502)" >&2; exit 1
fi
rest="${path#repos/o/r/}"
case "${method} ${rest}" in
  "POST git/trees")
    sha="$(printf 'tree %s' "$content" | shasum | cut -c1-40)"
    echo "$sha" ;;
  "POST git/commits")
    sha="$(printf 'commit %s %s' "$content" "$RANDOM$RANDOM" | shasum | cut -c1-40)"
    printf '%s' "$content" >"$store/blobs/$sha"
    echo "$sha" ;;
  "POST git/refs")
    f="$store/${declare_ref}"
    mkdir -p "$(dirname "$f")"
    if ! (set -o noclobber; printf '%s' "$declare_sha" >"$f") 2>/dev/null; then
      echo '{"message":"Reference already exists","status":"422"}'
      echo "gh: Reference already exists (HTTP 422)" >&2
      exit 1
    fi
    echo "$declare_ref" ;;
  "PATCH git/refs/"*)
    f="$store/refs/${rest#git/refs/}"
    [ -f "$f" ] || { echo '{"message":"Not Found"}'; exit 1; }
    printf '%s' "$declare_sha" >"$f"
    echo "refs/${rest#git/refs/}" ;;
  "DELETE git/refs/"*)
    f="$store/refs/${rest#git/refs/}"
    [ -f "$f" ] || { echo '{"message":"Not Found"}'; exit 1; }
    rm -f "$f" ;;
  "GET git/ref/"*)
    f="$store/refs/${rest#git/ref/}"
    [ -f "$f" ] || { echo '{"message":"Not Found","status":"404"}'; exit 1; }
    cat "$f"; echo ;;
  "GET git/commits/"*)
    f="$store/blobs/${rest#git/commits/}"
    [ -f "$f" ] || { echo '{"message":"Not Found"}'; exit 1; }
    cat "$f" ;;
  "GET git/matching-refs/"*)
    prefix="${rest#git/matching-refs/}"
    (cd "$store" && find refs -type f | sort | while IFS= read -r r; do
      case "$r" in "refs/${prefix}"*) echo "$r" ;; esac
    done) ;;
  "GET pulls/"*)
    f="$store/pulls/${rest#pulls/}"
    [ -f "$f" ] || { echo '{"message":"Not Found"}'; exit 1; }
    cat "$f"; echo ;;
  *) echo "stub: unsupported ${method} ${path}" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_STUB_STORE="$store"

head_a='0123456789abcdef0123456789abcdef01234567'
head_b='89abcdef0123456789abcdef0123456789abcdef'
fails=0
bad() {
  echo "FAIL: $*" >&2
  fails=$((fails + 1))
}

# expect <label> <want-exit> <want-substring|-> <args...>
expect() {
  local label="$1" want_rc="$2" want="$3" rc=0 out
  shift 3
  out="$("$lock" "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    bad "${label}: expected exit ${want_rc}, got ${rc}: ${out}"
  elif [ "$want" != "-" ] && [[ "$out" != *"$want"* ]]; then
    bad "${label}: output lacks '${want}': ${out}"
  else
    echo "  ok   ${label}"
  fi
}

acq() { # acq <pr> <head> <provider> <owner> [extra...]
  local pr="$1" h="$2" p="$3" o="$4"
  shift 4
  printf '%s\n' acquire --repo o/r --pr "$pr" --head "$h" --provider "$p" --owner "$o" "$@"
}
run_acq() { # run_acq <label> <want-exit> <want> <pr> <head> <provider> <owner> [extra...]
  local label="$1" rc="$2" want="$3"
  shift 3
  local -a args=()
  while IFS= read -r a; do args+=("$a"); done < <(acq "$@")
  expect "$label" "$rc" "$want" "${args[@]}"
}
lock_owner_of() { # lock_owner_of <pr> <head> <provider>
  local sha
  sha="$(cat "$store/refs/agent-review-lock/$1/$2/$3")"
  sed -n 's/^owner=//p' "$store/blobs/$sha"
}

export REVIEW_LOCK_NOW=1000000

echo "acquire:"
run_acq "a fresh key is acquired" 0 "ACQUIRED agent-review-lock/7/${head_a}/cr" 7 "$head_a" cr claude-run1
[ "$(lock_owner_of 7 "$head_a" cr)" = claude-run1 ] || bad "the lock blob does not record its owner"
run_acq "the owner re-acquiring its own lock proceeds (a retry is not a duplicate)" 0 "HELD" 7 "$head_a" cr claude-run1
run_acq "another instance inside the lease stands down" 1 "LOCKED agent-review-lock/7/${head_a}/cr owner=claude-run1 age=0s" 7 "$head_a" cr codex-run9
REVIEW_LOCK_NOW=$((1000000 + 29 * 60)) run_acq "still locked one minute before the lease ends" 1 "LOCKED" 7 "$head_a" cr codex-run9
run_acq "another provider on the same head is a different key" 0 "ACQUIRED agent-review-lock/7/${head_a}/codex" 7 "$head_a" codex codex-run9
run_acq "the same head on another PR is a different key" 0 "ACQUIRED" 8 "$head_a" cr codex-run9
REVIEW_LOCK_NOW=$((1000000 + 30 * 60)) run_acq "an expired lock is taken over" 0 "takeover-after=1800s" 7 "$head_a" cr codex-run9
[ "$(lock_owner_of 7 "$head_a" cr)" = codex-run9 ] || bad "takeover did not rewrite the owner"
run_acq "a shorter --lease-minutes is honoured" 1 "lease=60s" 7 "$head_a" cr claude-run1 --lease-minutes 1
REVIEW_LOCK_NOW=$((1000000 + 30 * 60 + 61)) run_acq "…and expires on it" 0 "ACQUIRED" 7 "$head_a" cr claude-run1 --lease-minutes 1

echo "pruning:"
run_acq "a new head is acquired" 0 "ACQUIRED agent-review-lock/7/${head_b}/cr" 7 "$head_b" cr claude-run2
[ ! -e "$store/refs/agent-review-lock/7/${head_a}/cr" ] || bad "old-head cr lock on PR 7 was not pruned"
[ ! -e "$store/refs/agent-review-lock/7/${head_a}/codex" ] || bad "old-head codex lock on PR 7 was not pruned"
[ -e "$store/refs/agent-review-lock/8/${head_a}/cr" ] || bad "pruning PR 7 deleted PR 8's lock"
[ -e "$store/refs/agent-review-lock/7/${head_b}/cr" ] || bad "pruning deleted the lock it had just acquired"

echo "race:"
# Eight instances race one key at the same instant; exactly one may win.
for i in 1 2 3 4 5 6 7 8; do
  ( rc=0
    "$lock" acquire --repo o/r --pr 42 --head "$head_a" --provider cr --owner "racer-$i" >"$tmp/race-$i.out" 2>&1 || rc=$?
    echo "$rc" >"$tmp/race-$i.rc" ) &
done
wait
winners=0 losers=0
for i in 1 2 3 4 5 6 7 8; do
  case "$(cat "$tmp/race-$i.rc")" in
    0) winners=$((winners + 1)); winner="racer-$i" ;;
    1) losers=$((losers + 1)) ;;
    *) bad "racer-$i exited unexpectedly: $(cat "$tmp/race-$i.out")" ;;
  esac
done
if [ "$winners" -eq 1 ] && [ "$losers" -eq 7 ] && [ "$(lock_owner_of 42 "$head_a" cr)" = "$winner" ]; then
  echo "  ok   eight simultaneous acquires produce exactly one winner, and the lock names it"
else
  bad "race: winners=${winners} losers=${losers}"
fi

echo "fail closed:"
GH_STUB_FAIL="POST repos/o/r/git/refs" run_acq "a non-422 create failure is UNKNOWN, never a win" 2 "could not create" 9 "$head_a" cr claude-run1
GH_STUB_FAIL="POST repos/o/r/git/commits" run_acq "a failed lock-commit write is UNKNOWN" 2 "could not create the lock commit" 9 "$head_a" cr claude-run1
GH_STUB_FAIL="GET repos/o/r/git/ref/" run_acq "an unreadable existing lock is UNKNOWN, never a loss or a win" 2 "could not read" 7 "$head_b" cr codex-run3
junk="$(printf 'no owner here' | shasum | cut -c1-40)"
printf 'no owner here' >"$store/blobs/$junk"
mkdir -p "$store/refs/agent-review-lock/10/${head_a}"
printf '%s' "$junk" >"$store/refs/agent-review-lock/10/${head_a}/cr"
run_acq "a lock with no owner is UNKNOWN, never taken over" 2 "carries no owner" 10 "$head_a" cr claude-run1
[ "$(cat "$store/refs/agent-review-lock/10/${head_a}/cr")" = "$junk" ] || bad "a malformed lock was overwritten"

echo "usage:"
run_acq "an abbreviated head is refused" 2 "full 40-character" 7 0123456 cr claude-run1
run_acq "an unknown provider is refused" 2 "--provider must be" 7 "$head_a" copilot claude-run1
run_acq "an owner with a slash is refused" 2 "--owner must match" 7 "$head_a" cr "claude/run1"
expect "a missing --repo is refused" 2 "--repo must be" acquire --pr 7 --head "$head_a" --provider cr --owner x
expect "sweep refuses acquire-only flags" 2 "sweep takes only" sweep --repo o/r --pr 7

echo "sweep:"
rm -rf "$store/refs/agent-review-lock/10"
printf 'open' >"$store/pulls/7"
printf 'closed' >"$store/pulls/8"
printf 'closed' >"$store/pulls/42"
expect "dry-run lists locks of closed PRs and keeps open ones" 0 "kept=1 would-delete=2" sweep --repo o/r
[ -e "$store/refs/agent-review-lock/8/${head_a}/cr" ] || bad "dry-run deleted a lock"
expect "--apply deletes only closed PRs' locks" 0 "kept=1 deleted=2" sweep --repo o/r --apply
[ ! -e "$store/refs/agent-review-lock/8/${head_a}/cr" ] || bad "--apply left a closed PR's lock"
[ -e "$store/refs/agent-review-lock/7/${head_b}/cr" ] || bad "--apply deleted an open PR's lock"
mkdir -p "$store/refs/agent-review-lock/11/${head_a}"
printf 'x' >"$store/refs/agent-review-lock/11/${head_a}/cr"
expect "an unreadable PR state is UNKNOWN, never swept" 2 "could not read PR #11" sweep --repo o/r --apply
[ -e "$store/refs/agent-review-lock/11/${head_a}/cr" ] || bad "a lock with an unknown PR state was deleted"

review_lock_test_finished=1
if [ "$fails" -gt 0 ]; then
  echo "review-request-lock.test: ${fails} failure(s)" >&2
  exit 1
fi
echo "review-request-lock.test: all passed"
