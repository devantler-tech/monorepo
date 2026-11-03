#!/usr/bin/env bash
# Shared bootstrap for production Go helpers (monorepo#4673). Source this file,
# then call go_helper_build <module-directory> <output-binary> <package>.
# A stalled shared cache gets one bounded retry using private internal caches.
# Ordinary compiler failures stay failures. Existing caches are never removed.

# go_helper_build compiles package into binary from module with bounded attempts.
# Retry only a stalled build or a default-cache permission failure, using caches
# owned by this invocation. Return compiler failures and reject missing output.
go_helper_build() (
  set -uo pipefail
  if [ "$#" -ne 3 ]; then
    echo 'go-helper-build: expected module directory, output binary and package' >&2
    return 2
  fi
  local module=$1 binary=$2 package=$3 timer value
  local first_seconds=${GO_HELPER_BUILD_TIMEOUT_SECONDS:-30}
  local retry_seconds=${GO_HELPER_BUILD_RETRY_TIMEOUT_SECONDS:-180}
  local kill_seconds=${GO_HELPER_BUILD_KILL_AFTER_SECONDS:-2}
  local cache='' output='' default_cache='' rc=0 retry=0 finished=0
  for value in "$first_seconds" "$retry_seconds" "$kill_seconds"; do
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]] || [ "${#value}" -gt 3 ] || [ "$value" -gt 600 ]; then
      echo 'go-helper-build: deadlines must be positive integers no greater than 600 seconds' >&2
      return 2
    fi
  done
  if ! timer=$(command -v gtimeout || command -v timeout); then
    echo 'go-helper-build: GNU timeout is required; build was not started' >&2
    return 2
  fi

  # The subshell owns only its newly allocated private cache. Return from its
  # body: Bash 3.2 discards function locals before an explicit exit's EXIT trap.
  # An abrupt abort may still lose locals; missing state must never mean success.
  # shellcheck disable=SC2329 # Invoked by the subshell's EXIT trap.
  cleanup_go_helper_build() {
    local cleanup_rc=$?
    if [ -n "${cache:-}" ]; then
      # Go downloads read-only module directories. Change only directories in
      # this invocation's fresh cache; physical traversal does not follow links.
      if ! find -P "$cache" -type d -exec chmod u+w {} + || ! rm -rf -- "$cache"; then
        echo 'go-helper-build: failed to clean private Go cache' >&2
        cleanup_rc=2
      fi
    fi
    if [ "${finished:-0}" != 1 ] && [ "$cleanup_rc" -eq 0 ]; then
      echo 'go-helper-build: aborted before completion; reporting UNKNOWN' >&2
      cleanup_rc=2
    fi
    exit "$cleanup_rc"
  }
  trap cleanup_go_helper_build EXIT

  # timeout owns this compiler's process group; kill-after also bounds a build
  # that ignores TERM. It never searches for or signals unrelated Go processes.
  output=$("$timer" --kill-after="$kill_seconds" "$first_seconds" \
    go -C "$module" build -o "$binary" "$package" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    if [ ! -s "$binary" ] || [ ! -x "$binary" ]; then
      echo 'go-helper-build: compiler returned success without an executable' >&2
      return 2
    fi
    finished=1
    return 0
  fi
  [ -z "$output" ] || printf '%s\n' "$output" >&2
  case "$rc" in
    124|137) retry=1 ;;
    *)
      # Preserve the memory launcher's existing narrowly identified permission
      # recovery (#4479), including its explicit-cache and path-boundary controls.
      # Even discovery of the default cache identity has a deadline.
      if [ -z "${GOCACHE:-}" ] &&
         default_cache=$("$timer" --kill-after="$kill_seconds" "$first_seconds" go env GOCACHE 2>/dev/null) &&
         [[ "$default_cache" == /* && "$default_cache" != *$'\n'* ]] &&
         printf '%s\n' "$output" | GO_HELPER_DEFAULT_CACHE="$default_cache" awk '
           (index($0, ENVIRON["GO_HELPER_DEFAULT_CACHE"] "/") ||
            index($0, ENVIRON["GO_HELPER_DEFAULT_CACHE"] ":")) &&
           /operation not permitted|permission denied/ { found = 1 }
           END { exit !found }'; then
        retry=1
      fi
      ;;
  esac
  if [ "$retry" -ne 1 ]; then
    finished=1
    return "$rc"
  fi

  # /tmp is internal on the maintained host. TMPDIR and the normal cache paths
  # may themselves point onto the unavailable external volume.
  cache=$(mktemp -d /tmp/go-helper-cache.XXXXXX) || {
    echo 'go-helper-build: failed to allocate private Go cache' >&2
    return 2
  }
  mkdir -p "$cache/build" "$cache/modules" || return 2
  echo 'go-helper-build: shared build unavailable; retrying once with private build and module caches' >&2
  rc=0
  "$timer" --kill-after="$kill_seconds" "$retry_seconds" \
    env GOCACHE="$cache/build" GOMODCACHE="$cache/modules" \
    go -C "$module" build -o "$binary" "$package" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "go-helper-build: private build failed (status $rc); no guard verdict" >&2
    finished=1
    return "$rc"
  fi
  if [ ! -s "$binary" ] || [ ! -x "$binary" ]; then
    echo 'go-helper-build: retry returned success without an executable' >&2
    return 2
  fi
  finished=1
  return 0
)

# Preserve the runtime and argv of former `go run` callers while bounding only
# compilation. Each invocation owns its temporary executable.
go_helper_run() (
  set -uo pipefail
  [ "$#" -ge 2 ] || { echo 'go-helper-build: expected module and package' >&2; return 2; }
  local module=$1 package=$2 binary='' rc=0 finished=0
  shift 2
  binary=$(mktemp /tmp/go-helper-run.XXXXXX) || return 2
  # Remove only this invocation's executable and preserve an incomplete run as
  # UNKNOWN, including an unset-variable abort that Bash may otherwise call 0.
  # shellcheck disable=SC2329 # Invoked by this subshell's EXIT trap.
  cleanup_go_helper_run() {
    local cleanup_rc=$?
    if [ -n "${binary:-}" ]; then rm -f -- "$binary" || cleanup_rc=2; fi
    if [ "${finished:-0}" != 1 ] && [ "$cleanup_rc" -eq 0 ]; then cleanup_rc=2; fi
    exit "$cleanup_rc"
  }
  trap cleanup_go_helper_run EXIT
  go_helper_build "$module" "$binary" "$package" || return 2
  "$binary" "$@" || rc=$?
  finished=1
  return "$rc"
)
