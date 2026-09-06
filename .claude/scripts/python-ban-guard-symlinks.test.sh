#!/usr/bin/env bash
# python-ban-guard: allow-file — inert symlink fixtures exercise input rejection without executing their contents.
set -Eeuo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
tmp="$(cd -- "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fail=0
count=0
go -C "$here/python-ban-guard-go" build -o "$tmp/parser" .
mkdir -p "$tmp/outside" "$tmp/bin"
printf '%s\n' 'python3 --version' >"$tmp/outside/command"
printf '%s\n' '# python-ban-guard: allow-file — inert external fixture' 'python3 --version' >"$tmp/outside/exempt"
: >"$tmp/outside/empty"

# The probes record only attempts to read this test's inert symlink path.
SYMLINK_REAL_GREP="$(command -v grep)"
SYMLINK_REAL_HEAD="$(command -v head)"
SYMLINK_REAL_AWK="$(command -v awk)"
export SYMLINK_REAL_GREP SYMLINK_REAL_HEAD SYMLINK_REAL_AWK
cat >"$tmp/bin/reader" <<'SH'
#!/usr/bin/env bash
set -eu
tool=${0##*/}
for arg in "$@"; do
  if [[ "$arg" == "$SYMLINK_PROBE_PATH" ]]; then
    printf '%s\n' "$tool" >>"$SYMLINK_READER_LOG"
  fi
done
case "$tool" in
  grep) exec "$SYMLINK_REAL_GREP" "$@" ;;
  head) exec "$SYMLINK_REAL_HEAD" "$@" ;;
  awk) exec "$SYMLINK_REAL_AWK" "$@" ;;
esac
SH
chmod +x "$tmp/bin/reader"
for tool in grep head awk; do ln -s reader "$tmp/bin/$tool"; done

# report records each independent boundary assertion without hiding later failures.
report() {
  count=$((count + 1))
  if [[ "$2" == yes ]]; then
    printf 'PASS symlink %s\n' "$1"
  else
    printf 'FAIL symlink %s: %s\n' "$1" "$3" >&2
    fail=1
  fi
}

# new_repo creates a tracked-file fixture isolated from every real checkout.
new_repo() {
  repo="$tmp/$1"
  mkdir -p "$repo/tools"
  git -C "$repo" init -q
}

# run_guard invokes the production entrypoint with probes for the inert link path.
run_guard() {
  rc=0
  out="$(PATH="$tmp/bin:$PATH" SYMLINK_PROBE_PATH="$repo/$path" \
    SYMLINK_READER_LOG="$tmp/readers" bash "$1" "$repo" 2>&1)" || rc=$?
}

# check_link verifies rejection by both the shell entrypoint and standalone parser.
check_link() {
  local name=$1 target=$2
  path=$3
  new_repo "$name"
  if [[ "$target" == internal ]]; then
    printf '%s\n' 'python3 --version' >"$repo/target"
    target=../target
  fi
  ln -s "$target" "$repo/$path"
  git -C "$repo" add -- "$path"
  rm -f "$tmp/readers"
  run_guard "$here/python-ban-guard.sh"
  report "$name guard rejects before reading" \
    "$([[ $rc -eq 2 && "$out" == *'symlink inputs are not supported'* && ! -e "$tmp/readers" ]] && echo yes || echo no)" \
    "rc=$rc readers=$([[ -e "$tmp/readers" ]] && echo reached || echo none): $out"
  rc=0
  out="$("$tmp/parser" "$path" "$repo/$path" 2>&1)" || rc=$?
  report "$name standalone parser rejects" \
    "$([[ $rc -eq 2 && "$out" == *'symlink inputs are not supported'* ]] && echo yes || echo no)" "rc=$rc: $out"
}

check_link outside-shell "$tmp/outside/command" tools/check.sh
check_link fallback "$tmp/outside/command" tools/check.task
check_link internal-shell internal tools/check.sh
check_link broken "$tmp/outside/missing" tools/check.sh
check_link prose "$tmp/outside/command" README.md
check_link exempt-target "$tmp/outside/exempt" tools/check.sh
check_link source-suffix "$tmp/outside/command" tools/check.py
check_link empty-target "$tmp/outside/empty" tools/check.sh

# check_regular preserves ordinary command, argument, prose and exemption behavior.
check_regular() {
  local name=$1 source=$2 expected=$3
  path=$4
  new_repo "$name"
  printf '%s\n' "$source" >"$repo/$path"
  git -C "$repo" add -- "$path"
  run_guard "$here/python-ban-guard.sh"
  report "$name regular-file control" "$([[ $rc -eq $expected ]] && echo yes || echo no)" "rc=$rc: $out"
}

check_regular safe 'echo ready' 0 tools/check.sh
check_regular argument-data 'echo "python3 --version"' 0 tools/check.sh
check_regular prose-data 'The python3 --version command prints a version.' 0 README.md
check_regular exempt $'# python-ban-guard: allow-file — inert test fixture\npython3 --version' 0 tools/check.sh
check_regular invocation 'python3 --version' 1 tools/check.sh

# With only the shell check removed, the Go check still rejects the link, but
# grep has already opened its target. This pins the need for both boundaries.
mkdir -p "$tmp/ablated"
cp -R "$here/python-ban-guard-go" "$tmp/ablated/python-ban-guard-go"
# Match the source's literal variable reference, not this fixture's environment.
# shellcheck disable=SC2016
sed 's/if \[ -L "\$file" \]; then/if false; then/' \
  "$here/python-ban-guard.sh" >"$tmp/ablated/python-ban-guard.sh"
new_repo ablation
path=tools/check.sh
ln -s "$tmp/outside/command" "$repo/$path"
git -C "$repo" add -- "$path"
rm -f "$tmp/readers"
run_guard "$tmp/ablated/python-ban-guard.sh"
report 'removing shell boundary exposes a read before Go rejection' \
  "$([[ $rc -eq 2 && "$out" == *'symlink inputs are not supported'* && -s "$tmp/readers" ]] && \
    ! cmp -s "$here/python-ban-guard.sh" "$tmp/ablated/python-ban-guard.sh" && echo yes || echo no)" "rc=$rc: $out"

printf 'python-ban-guard symlink self-test: %s cases\n' "$count"
exit "$fail"
