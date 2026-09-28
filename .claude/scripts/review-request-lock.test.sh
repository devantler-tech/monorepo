#!/usr/bin/env bash
# Hermetic test for review-request-lock.sh (monorepo#2894).
#
# `gh` is stubbed on PATH by a small ref store that behaves like the GitHub REST git API:
# creating a ref that exists fails with HTTP 422 "Reference already exists", and the create is
# atomic (O_EXCL via noclobber), so the race cases exercise a real race rather than a sequence.
# The stub offers NO ref update, so any code path that relies on a non-atomic update fails here.
# No network, no token.
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
mkdir -p "$tmp/bin" "$store/refs" "$store/objects" "$store/pulls"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal GitHub REST stand-in for the git refs, tags and pulls endpoints.
set -euo pipefail
store="${GH_STUB_STORE:?}"
[ "$1" = api ] || { echo "stub: only 'gh api' is supported" >&2; exit 1; }
shift
method=GET path="" paginate=0 declare_ref="" declare_sha="" message=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --jq) shift 2 ;;
    --paginate) paginate=1; shift ;;
    -f | -F)
      case "$2" in
        ref=*) declare_ref="${2#ref=}" ;;
        sha=*) declare_sha="${2#sha=}" ;;
        message=*) message="${2#message=}" ;;
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
  "POST git/tags")
    sha="$(printf 'tag %s %s' "$message" "$RANDOM$RANDOM" | shasum | cut -c1-40)"
    printf '%s' "$message" >"$store/objects/$sha"
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
  "DELETE git/refs/"*)
    f="$store/refs/${rest#git/refs/}"
    [ -f "$f" ] || { echo '{"message":"Not Found"}'; exit 1; }
    rm -f "$f" ;;
  "GET git/ref/"*)
    f="$store/refs/${rest#git/ref/}"
    [ -f "$f" ] || { echo '{"message":"Not Found","status":"404"}'; exit 1; }
    cat "$f"; echo ;;
  "GET git/tags/"*)
    f="$store/objects/${rest#git/tags/}"
    [ -f "$f" ] || { echo '{"message":"Not Found"}'; exit 1; }
    cat "$f" ;;
  "GET git/matching-refs/"*)
    prefix="${rest#git/matching-refs/}"
    # Without --paginate only the first page (GH_STUB_PAGE refs) comes back, as on GitHub.
    limit=1000000
    [ "$paginate" = 1 ] || limit="${GH_STUB_PAGE:-1000000}"
    (cd "$store" && find refs -type f | sort -t/ -k5,5n -k1,4 | while IFS= read -r r; do
      case "$r" in "refs/${prefix}"*) echo "$r" ;; esac
    done) | head -n "$limit" ;;
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

# acq <label> <want-exit> <want> <pr> <head> <provider> <owner> [extra...]
acq() {
  local label="$1" rc="$2" want="$3" pr="$4" h="$5" p="$6" o="$7"
  shift 7
  expect "$label" "$rc" "$want" acquire --repo o/r --pr "$pr" --head "$h" --provider "$p" --owner "$o" "$@"
}

lock_dir() { printf '%s' "$store/refs/agent-review-lock/$1/$2"; }
generations() { find "$(lock_dir "$1" "$2")" -type f 2>/dev/null | sed 's#.*/##' | sort -n; }
has_lock() { [ -n "$(generations "$1" "$2")" ]; }
lock_owner_of() { # lock_owner_of <pr> <head> — owner recorded in the newest generation
  local g sha
  g="$(generations "$1" "$2" | tail -n 1)"
  sha="$(cat "$(lock_dir "$1" "$2")/$g")"
  sed -n 's/^owner=//p' "$store/objects/$sha"
}

# race <n> <label> <pr> <head> <now> <owner-prefix> — n simultaneous acquires; sets winners/losers/winner.
race() {
  local n="$1" label="$2" pr="$3" h="$4" now="$5" prefix="$6" i
  for i in $(seq 1 "$n"); do
    ( rc=0
      REVIEW_LOCK_NOW="$now" "$lock" acquire --repo o/r --pr "$pr" --head "$h" --provider cr \
        --owner "${prefix}-$i" >"$tmp/${prefix}-$i.out" 2>&1 || rc=$?
      echo "$rc" >"$tmp/${prefix}-$i.rc" ) &
  done
  wait
  winners=0 losers=0 winner=""
  for i in $(seq 1 "$n"); do
    case "$(cat "$tmp/${prefix}-$i.rc")" in
      0) winners=$((winners + 1)); winner="${prefix}-$i" ;;
      1) losers=$((losers + 1)) ;;
      *) bad "${label}: ${prefix}-$i exited unexpectedly: $(cat "$tmp/${prefix}-$i.out")" ;;
    esac
  done
}

export REVIEW_LOCK_NOW=1000000

echo "acquire:"
acq "a fresh key is acquired" 0 "ACQUIRED agent-review-lock/7/${head_a}/1 owner=claude-run1 provider=cr" 7 "$head_a" cr claude-run1
[ "$(lock_owner_of 7 "$head_a")" = claude-run1 ] || bad "the lock object does not record its owner"
acq "the owner re-acquiring its own lock proceeds (a retry is not a duplicate)" 0 "HELD" 7 "$head_a" cr claude-run1
acq "the owner moving to the next provider keeps its lock" 0 "HELD agent-review-lock/7/${head_a}/1 owner=claude-run1 provider=codex" 7 "$head_a" codex claude-run1
acq "another instance inside the lease stands down" 1 "LOCKED agent-review-lock/7/${head_a}/1 owner=claude-run1 provider=cr age=0s" 7 "$head_a" cr codex-run9
acq "another instance on ANOTHER provider stands down too (one request per head)" 1 "LOCKED" 7 "$head_a" bugbot codex-run9
REVIEW_LOCK_NOW=$((1000000 + 29 * 60)) acq "still locked one minute before the lease ends" 1 "LOCKED" 7 "$head_a" cr codex-run9
acq "the same head on another PR is a different key" 0 "ACQUIRED" 8 "$head_a" cr codex-run9
REVIEW_LOCK_NOW=$((1000000 + 30 * 60)) acq "an expired lock is taken over as the next generation" 0 "ACQUIRED agent-review-lock/7/${head_a}/2 owner=codex-run9 provider=cr takeover-after=1800s" 7 "$head_a" cr codex-run9
[ "$(lock_owner_of 7 "$head_a")" = codex-run9 ] || bad "takeover did not record the new owner"
[ "$(generations 7 "$head_a" | tr '\n' ' ')" = "1 2 " ] || bad "takeover rewrote generation 1 instead of creating generation 2"
acq "a shorter --lease-minutes is honoured" 1 "lease=60s" 7 "$head_a" cr claude-run1 --lease-minutes 1
REVIEW_LOCK_NOW=$((1000000 + 30 * 60 + 61)) acq "…and expires on it" 0 "ACQUIRED agent-review-lock/7/${head_a}/3" 7 "$head_a" cr claude-run1 --lease-minutes 1

echo "heads:"
acq "a new head is acquired independently" 0 "ACQUIRED agent-review-lock/7/${head_b}/1" 7 "$head_b" cr claude-run2
has_lock 7 "$head_a" || bad "acquiring a new head deleted the previous head's lock (a stale worker could delete a live one)"
acq "a stale worker on the previous head never touches the new head's lock" 1 "LOCKED" 7 "$head_a" cr stale-run
has_lock 7 "$head_b" || bad "a stale-head acquire removed the current head's lock"

echo "pagination:"
mkdir -p "$(lock_dir 12 "$head_a")"
for g in 1 2 3 4 5; do
  sha="$(printf 'old %s' "$g" | shasum | cut -c1-40)"
  printf 'agent-review-lock\nowner=old-%s\ncreated_epoch=1\n' "$g" >"$store/objects/$sha"
  printf '%s' "$sha" >"$(lock_dir 12 "$head_a")/$g"
done
GH_STUB_PAGE=2 acq "the generation scan reads every page, so a later page's newest lock is not missed" 0 "ACQUIRED agent-review-lock/12/${head_a}/6" 12 "$head_a" cr claude-run1

echo "race:"
race 8 "first-acquire race" 42 "$head_a" 1000000 racer
if [ "$winners" -eq 1 ] && [ "$losers" -eq 7 ] && [ "$(lock_owner_of 42 "$head_a")" = "$winner" ]; then
  echo "  ok   eight simultaneous acquires produce exactly one winner, and the lock names it"
else
  bad "race: winners=${winners} losers=${losers}"
fi
race 8 "takeover race" 42 "$head_a" $((1000000 + 31 * 60)) taker
if [ "$winners" -eq 1 ] && [ "$losers" -eq 7 ] && [ "$(lock_owner_of 42 "$head_a")" = "$winner" ] &&
  [ "$(generations 42 "$head_a" | tail -n 1)" = 2 ]; then
  echo "  ok   eight simultaneous takeovers of an expired lock produce exactly one winner, at generation 2"
else
  bad "takeover race: winners=${winners} losers=${losers}"
fi

echo "fail closed:"
GH_STUB_FAIL="POST repos/o/r/git/refs" acq "a non-422 create failure is UNKNOWN, never a win" 2 "could not create" 9 "$head_a" cr claude-run1
GH_STUB_FAIL="POST repos/o/r/git/tags" acq "a failed lock-object write is UNKNOWN" 2 "could not create the lock object" 9 "$head_a" cr claude-run1
GH_STUB_FAIL="GET repos/o/r/git/matching-refs/" acq "a failed generation scan is UNKNOWN" 2 "could not list" 7 "$head_b" cr codex-run3
GH_STUB_FAIL="GET repos/o/r/git/ref/" acq "an unreadable existing lock is UNKNOWN, never a loss or a win" 2 "could not read" 7 "$head_b" cr codex-run3
junk="$(printf 'no owner here' | shasum | cut -c1-40)"
printf 'no owner here' >"$store/objects/$junk"
mkdir -p "$(lock_dir 10 "$head_a")"
printf '%s' "$junk" >"$(lock_dir 10 "$head_a")/1"
acq "a lock with no owner is UNKNOWN, never taken over" 2 "carries no owner" 10 "$head_a" cr claude-run1
[ "$(generations 10 "$head_a" | tr '\n' ' ')" = "1 " ] || bad "a malformed lock was taken over"

echo "usage:"
acq "an abbreviated head is refused" 2 "full 40-character" 7 0123456 cr claude-run1
acq "an unknown provider is refused" 2 "--provider must be" 7 "$head_a" copilot claude-run1
acq "an owner with a slash is refused" 2 "--owner must match" 7 "$head_a" cr "claude/run1"
expect "a missing --repo is refused" 2 "--repo must be" acquire --pr 7 --head "$head_a" --provider cr --owner x
expect "sweep refuses acquire-only flags" 2 "sweep takes only" sweep --repo o/r --pr 7

echo "sweep:"
rm -rf "$store/refs/agent-review-lock/10" "$store/refs/agent-review-lock/12"
printf 'open:%s' "$head_b" >"$store/pulls/7"
printf 'closed:%s' "$head_a" >"$store/pulls/8"
printf 'closed:%s' "$head_a" >"$store/pulls/42"
# PR 7: head_a generations 1-3 are superseded, head_b/1 is live; PR 8: 1 closed; PR 42: 2 closed.
expect "dry-run lists closed-PR and superseded-head locks and keeps the live head" 0 "kept=1 would-delete=6" sweep --repo o/r
has_lock 8 "$head_a" || bad "dry-run deleted a lock"
expect "--apply deletes exactly those" 0 "kept=1 deleted=6" sweep --repo o/r --apply
! has_lock 8 "$head_a" || bad "--apply left a closed PR's lock"
! has_lock 7 "$head_a" || bad "--apply left a superseded head's lock"
has_lock 7 "$head_b" || bad "--apply deleted the live head's lock"
mkdir -p "$(lock_dir 11 "$head_a")"
printf x >"$(lock_dir 11 "$head_a")/1"
expect "an unreadable PR state is UNKNOWN, never swept" 2 "could not read PR #11" sweep --repo o/r --apply
has_lock 11 "$head_a" || bad "a lock with an unknown PR state was deleted"

review_lock_test_finished=1
if [ "$fails" -gt 0 ]; then
  echo "review-request-lock.test: ${fails} failure(s)" >&2
  exit 1
fi
echo "review-request-lock.test: all passed"
