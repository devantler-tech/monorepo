#!/usr/bin/env bash
# bash-parse-guard.sh — fail when a tracked bash script no longer parses.
#
# WHY THIS EXISTS (monorepo#3172)
#   A test script that cannot parse must fail on its own signal. On macOS bash 3.2 a script
#   that dies on a parse error AFTER installing `trap 'rm -rf "$tmp"' EXIT` exits with the
#   trap's status — 0 — so a structurally broken `.test.sh` reports success with no
#   assertion run and nothing to read. It was noticed only because `bash -n` disagreed with
#   the suite's exit status (agent-skills#103). Whether a given bash masks the status is a
#   per-version accident; `bash -n` reports a parse error on every version, so this guard
#   checks the property directly instead of depending on the runtime status.
#
# WHAT IT SCANS
#   Every file this repository tracks whose name ends in `.sh` or `.bash`. Gitlinks are
#   skipped: submodules are separate repositories with their own CI. Each file is parsed
#   with `bash -n` by the bash running this guard, so the CI matrix checks both the bash 5
#   on the Linux runners and the bash 3.2 the agent host runs these scripts with.
#
# USAGE
#   bash-parse-guard.sh [<repo-dir>]   # default: the repository this script lives in
#   exit 0  every tracked script parses
#   exit 1  findings — each unparseable script with bash's own message, then a count
#   exit 2  usage error, not a git repository, a failed enumeration, or nothing to check
set -euo pipefail

[ $# -le 1 ] || { echo "usage: bash-parse-guard.sh [<repo-dir>]" >&2; exit 2; }
if [ $# -eq 1 ]; then
  repo="$1"
else
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" ||
  { echo "bash-parse-guard: not a git repository: $repo" >&2; exit 2; }

tmp="$(mktemp -d)" || { echo "bash-parse-guard: cannot allocate a temporary directory" >&2; exit 2; }
# Reaching the last line is the only way a zero status leaves this script: bash 3.2 can hand
# an EXIT trap a 0 for an abort, and the trap's own status then becomes the script's.
bash_parse_guard_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$bash_parse_guard_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "bash-parse-guard: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT

# `ls-files -s` names the mode, so a gitlink (160000) is never mistaken for a script.
if ! git -C "$top" ls-files -s -z >"$tmp/index"; then
  echo "bash-parse-guard: cannot enumerate tracked files in $top" >&2
  exit 2
fi

checked=0
findings=0
while IFS= read -r -d '' entry; do
  mode="${entry%% *}"
  path="${entry#*$'\t'}"
  [ "$mode" != 160000 ] || continue
  case "$path" in
    *.sh | *.bash) ;;
    *) continue ;;
  esac
  file="$top/$path"
  if [ ! -f "$file" ]; then
    echo "bash-parse-guard: $path: tracked but not present in the working tree" >&2
    exit 2
  fi
  checked=$((checked + 1))
  if ! "$BASH" -n -- "$file" 2>"$tmp/err"; then
    findings=$((findings + 1))
    echo "bash-parse-guard: $path does not parse:"
    sed 's/^/  /' "$tmp/err"
  fi
done <"$tmp/index"

# An empty sweep proves nothing: it is what a broken enumeration looks like.
if [ "$checked" -eq 0 ]; then
  echo "bash-parse-guard: no tracked .sh or .bash file found in $top; nothing was checked" >&2
  exit 2
fi
if [ "$findings" -gt 0 ]; then
  echo "bash-parse-guard: $findings of $checked tracked script(s) do not parse under bash ${BASH_VERSION}." >&2
  echo "bash-parse-guard: fix the syntax error reported above; a script that cannot parse can still exit 0 from its EXIT trap." >&2
  exit 1
fi
bash_parse_guard_finished=1
echo "bash-parse-guard: OK — all $checked tracked script(s) parse under bash ${BASH_VERSION}"
