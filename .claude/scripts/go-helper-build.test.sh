#!/usr/bin/env bash
# A blocked compiler must not hold a run-loop guard indefinitely (monorepo#4673).
# Exercise the real launcher; fake only the Go process and its cache availability.
set -Eeuo pipefail

# Keep the plain CI invocation while exercising macOS's actual Bash 3.2.
if [ "$BASH" != /bin/bash ] && [ -x /bin/bash ]; then exec /bin/bash "$0" "$@"; fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/go-helper-build-test.XXXXXX")"
finished=0
# Release this test's fixtures without turning an interrupted suite into a pass.
cleanup() {
  local rc=$?
  rm -rf -- "$tmp"
  if [ "$finished" != 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
timer="$(command -v gtimeout || command -v timeout)" || {
  echo 'UNKNOWN: GNU timeout is required for the build deadline regression' >&2
  exit 2
}
mkdir "$tmp/bin"
cat > "$tmp/bin/go" <<'GO'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = env ]; then printf '%s\n' "$MOCK_SHARED_CACHE"; exit 0; fi
printf '%s\t%s\n' "${GOCACHE:-unset}" "${GOMODCACHE:-unset}" >> "$MOCK_CALLS"
echo "$$" >> "$MOCK_PIDS"
count=$(wc -l < "$MOCK_CALLS" | tr -d ' ')
case "$MOCK_MODE:$count" in
  stall:1|retry-fails:1|both-stall:*) trap '' TERM; exec sleep 30 ;;
    compile:*) echo 'compile: deliberate syntax error' >&2; exit 1 ;;
    empty:*) exit 0 ;;
  retry-fails:2) echo 'compile: deliberate retry failure' >&2; exit 1 ;;
esac
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then output=$2; break; fi
  shift
done
[ -n "$output" ]
cat > "$output" <<'GUARD'
#!/usr/bin/env bash
echo helper-verdict-executed
exit "$MOCK_GUARD_STATUS"
GUARD
chmod +x "$output"
GO
chmod +x "$tmp/bin/go"

# Run the real launcher with one controlled compiler/cache scenario. Check the
# result, attempt count, cache cleanup and owned-process termination together.
run_case() {
  local mode=$1 verdict=$2 expected=$3 expected_calls=$4
  local case_dir="$tmp/$mode-$verdict" rc=0 actual_calls cache modules pid
  mkdir -p "$case_dir/tmp"
  : > "$case_dir/calls"
  : > "$case_dir/pids"
  "$timer" --kill-after=1 12 env PATH="$tmp/bin:$PATH" TMPDIR="$case_dir/tmp" \
    GO_HELPER_BUILD_TIMEOUT_SECONDS=1 GO_HELPER_BUILD_RETRY_TIMEOUT_SECONDS=1 \
    GO_HELPER_BUILD_KILL_AFTER_SECONDS=1 \
    GOCACHE="$case_dir/shared-build" GOMODCACHE="$case_dir/shared-modules" \
    MOCK_SHARED_CACHE="$case_dir/shared-build" MOCK_MODE="$mode" \
    MOCK_CALLS="$case_dir/calls" MOCK_PIDS="$case_dir/pids" MOCK_GUARD_STATUS="$verdict" \
    "$BASH" "$here/memory-hygiene.sh" --layout codex > "$case_dir/out" 2>&1 || rc=$?
  if [ "$rc" -ne "$expected" ]; then
    echo "FAIL: $mode must return $expected, got $rc" >&2
    cat "$case_dir/out" >&2
    exit 1
  fi
  actual_calls=$(wc -l < "$case_dir/calls" | tr -d ' ')
  if [ "$actual_calls" -ne "$expected_calls" ]; then
    echo "FAIL: $mode expected $expected_calls builds, got $actual_calls" >&2
    exit 1
  fi
  if [ "$expected_calls" -eq 2 ]; then
    IFS=$'\t' read -r cache modules < <(sed -n '2p' "$case_dir/calls")
    case "$cache" in /tmp/go-helper-cache.*/build) ;; *) echo 'FAIL: retry build cache is not isolated on internal temporary storage' >&2; exit 1 ;; esac
    [ "$modules" = "${cache%/build}/modules" ] || { echo 'FAIL: module cache was not isolated together with build cache' >&2; exit 1; }
    [ ! -e "${cache%/build}" ] || { echo 'FAIL: private retry cache leaked' >&2; exit 1; }
  fi
  while IFS= read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "FAIL: owned compiler process $pid survived its deadline" >&2
      exit 1
    fi
  done < "$case_dir/pids"
  case "$mode" in
    compile) grep -q 'compile: deliberate syntax error' "$case_dir/out" || { echo 'FAIL: compiler diagnostic lost' >&2; exit 1; } ;;
    retry-fails) grep -q 'compile: deliberate retry failure' "$case_dir/out" || { echo 'FAIL: retry diagnostic lost' >&2; exit 1; } ;;
  esac
  case "$mode" in
    compile|retry-fails|both-stall|empty)
      if grep -q helper-verdict-executed "$case_dir/out"; then echo 'FAIL: a failed build executed a guard' >&2; exit 1; fi ;;
    *) grep -q helper-verdict-executed "$case_dir/out" || { echo 'FAIL: successful build never exercised the actual guard' >&2; exit 1; } ;;
  esac
  echo "PASS: $mode returns status $expected with $expected_calls build(s)"
}

run_case stall 0 0 2
run_case ordinary 0 0 1
run_case ordinary 1 1 1
run_case ordinary 2 2 1
run_case compile 0 2 1
run_case empty 0 2 1
run_case retry-fails 0 2 2
run_case both-stall 0 2 2

# In particular, timeout's zero duration would disable its watchdog. Reject it
# before invoking a compiler, rather than accepting an unbounded configuration.
for invalid in 0 601 invalid; do
  : > "$tmp/invalid-calls"
  invalid_rc=0
  env PATH="$tmp/bin:$PATH" GO_HELPER_BUILD_TIMEOUT_SECONDS="$invalid" \
    MOCK_SHARED_CACHE="$tmp/shared" MOCK_MODE=ordinary MOCK_GUARD_STATUS=0 \
    MOCK_CALLS="$tmp/invalid-calls" MOCK_PIDS="$tmp/invalid-pids" \
    "$BASH" "$here/memory-hygiene.sh" --layout codex > "$tmp/invalid-out" 2>&1 || invalid_rc=$?
  if [ "$invalid_rc" -ne 2 ] || [ -s "$tmp/invalid-calls" ] || ! grep -q 'deadlines must be positive' "$tmp/invalid-out"; then
    echo "FAIL: invalid deadline $invalid was not refused before compilation" >&2
    exit 1
  fi
done
echo 'PASS: zero, excessive and invalid deadlines cannot disable the watchdog'

# Exercise the production builder and runner with the actual compiler as well.
# The minimal local module has no external module dependencies.
mkdir "$tmp/module"
printf 'module example.test/go-helper-build\n\ngo 1.24.0\n' > "$tmp/module/go.mod"
printf 'package main\nfunc main() { println("real-helper-executed") }\n' > "$tmp/module/main.go"
real_rc=0
"$BASH" -c '. "$1"; go_helper_run "$2" .' bash "$here/go-helper-build.sh" "$tmp/module" > "$tmp/real-out" 2>&1 || real_rc=$?
if [ "$real_rc" -ne 0 ] || ! grep -q real-helper-executed "$tmp/real-out"; then
  echo 'FAIL: actual Go build/run did not execute the local helper' >&2
  cat "$tmp/real-out" >&2
  exit 1
fi
printf 'package main\nfunc main( {\n' > "$tmp/module/main.go"
real_rc=0
"$BASH" -c '. "$1"; go_helper_run "$2" .' bash "$here/go-helper-build.sh" "$tmp/module" > "$tmp/real-error" 2>&1 || real_rc=$?
if [ "$real_rc" -eq 0 ] || ! grep -q 'main.go' "$tmp/real-error" || grep -q real-helper-executed "$tmp/real-error"; then
  echo 'FAIL: real compiler error was hidden or a failed build ran' >&2
  exit 1
fi
echo 'PASS: actual Go program runs and actual compiler errors remain failures'

# Exercise both real library traps after a reached unset-variable abort, also
# on the host's Bash 3.2. A library is sourced rather than executed by the
# generic standalone-script trap census.
for kind in build run; do
  awk -v handler="cleanup_go_helper_$kind" '
    { print }
    $0 ~ "^[[:space:]]*trap " handler " EXIT$" {
      print "  printf reached > \"$GO_HELPER_TEST_REACHED\""
      print "  : \"${GO_HELPER_TEST_UNSET}\""
      found++
    }
    END { if (found != 1) exit 2 }
  ' "$here/go-helper-build.sh" > "$tmp/injected-$kind.sh"
  abort_rc=0
  env -u GO_HELPER_TEST_UNSET GO_HELPER_TEST_REACHED="$tmp/reached-$kind" \
    "$BASH" -c 'set -e; . "$1"; if [ "$2" = build ]; then go_helper_build "$3" "$4" .; else go_helper_run "$3" .; fi' \
    bash "$tmp/injected-$kind.sh" "$kind" "$tmp/module" "$tmp/abort-bin" > "$tmp/abort-$kind" 2>&1 || abort_rc=$?
  if [ "$abort_rc" -eq 0 ] || [ ! -f "$tmp/reached-$kind" ]; then
    echo "FAIL: the reached $kind trap did not preserve an unset-variable abort (status $abort_rc)" >&2
    cat "$tmp/abort-$kind" >&2
    exit 1
  fi
done
echo 'PASS: both library traps fail closed after a reached abort'

# Every production compiler entrypoint participates; future direct builds/runs
# must not silently bypass the bounded shared path.
repo_root=$(cd "$here/../.." && pwd)
git -C "$repo_root" ls-files -z -- .claude/scripts > "$tmp/sources" || exit 2
[ -s "$tmp/sources" ] || exit 2
while IFS= read -r -d '' source; do
  case "$source" in *.test.sh|*/go-helper-build.sh) continue ;; *.sh) ;; *) continue ;; esac
  scan_rc=0
  grep -Eq 'go (-C.* )?(build|run) ' "$repo_root/$source" || scan_rc=$?
  if [ "$scan_rc" -ne 1 ]; then
    echo "FAIL: production Go compilation bypasses the shared build path, or cannot be examined: $source" >&2
    exit 1
  fi
done < "$tmp/sources"
echo 'PASS: no production helper bypasses the shared build path'
finished=1
