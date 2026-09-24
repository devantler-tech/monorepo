#!/usr/bin/env bash
# portfolio-map-drift.test.sh — RED/GREEN coverage for the Portfolio map drift check (#2811).
#
# The defect this guards against is a FALSE CLEAN: a tracked devantler-tech submodule the Portfolio
# map does not list, reported as in scope. So most assertions are about ways a clean verdict could be
# manufactured: a repository named only outside the map section, an unrecognised URL spelling that is
# skipped instead of reported, an exclusion without a reason, and an exclusion that outlives its need.
# Fixtures are plain files in a scratch directory; nothing depends on the network or the checkout.

# The fixture texts quote Markdown code spans, so backticks inside single quotes are intentional.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/portfolio-map-drift.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

TMP=$(mktemp -d)
# Bash 3.2 hands an EXIT trap $?=0 after a `set -u` abort, so reaching the end is the only way a
# zero status may leave this script.
finished=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$finished" != 1 ] && [ "$rc" -eq 0 ]; then
    echo "portfolio-map-drift.test: aborted before finishing; reporting failure" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

fails=0
asserts=0
case_n=0
# note_fail records one failed assertion and keeps going, so one run reports every failure.
note_fail() { echo "FAIL: $1" >&2; fails=$(( fails + 1 )); }

# mkroot <gitmodules-body> <agents-body> [exclusions-body] — build a fixture superproject; prints its dir.
mkroot() {
  case_n=$(( case_n + 1 ))
  local dir="$TMP/case$case_n"
  mkdir -p "$dir/.claude"
  printf '%s\n' "$1" >"$dir/.gitmodules"
  printf '%s\n' "$2" >"$dir/AGENTS.md"
  if [ $# -ge 3 ]; then printf '%s\n' "$3" >"$dir/.claude/portfolio-map-exclusions.tsv"; fi
  printf '%s' "$dir"
}

# expect <name> <want-exit> <want-pattern|-> <dir> — run the check and assert exit code and output.
expect() {
  local name=$1 want=$2 pattern=$3 dir=$4 out rc
  asserts=$(( asserts + 1 ))
  set +e
  out=$(bash "$SCRIPT" --root "$dir" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne "$want" ]; then
    note_fail "$name: exit $rc, want $want. Output: $out"
    return
  fi
  if [ "$pattern" != "-" ] && ! grep -Eq -- "$pattern" <<<"$out"; then
    note_fail "$name: output lacks /$pattern/. Output: $out"
  fi
}

MODULES='[submodule "platform"]
	path = platform
	url = git@github.com:devantler-tech/platform.git
[submodule "applications/ksail"]
	path = applications/ksail
	url = https://github.com/devantler-tech/ksail
[submodule "github/personal/profile"]
	path = github/personal/profile
	url = git@github.com:devantler/devantler.git'

MAP_BOTH='# AGENTS.md

## Portfolio map

| Product | Repo | Path | Per-repo AGENTS.md |
|---|---|---|---|
| KSail | `devantler-tech/ksail` | `applications/ksail` | x |
| Platform | `devantler-tech/platform` (renamed) | `platform` | x |

## Stack map

| Building block | Good for | Owning repo |
|---|---|---|'

MAP_KSAIL_ONLY='## Portfolio map

| Product | Repo | Path | Per-repo AGENTS.md |
|---|---|---|---|
| KSail | `devantler-tech/ksail` | `applications/ksail` | x |

## Retired products

| Product | Repo | Path |
|---|---|---|
| Platform | `devantler-tech/platform` | `platform` |'

# GREEN: both devantler-tech submodules mapped (SSH with .git and HTTPS without it both parse);
# the submodule owned by another account is out of scope and must not be reported.
d=$(mkroot "$MODULES" "$MAP_BOTH")
expect "clean map" 0 'CLEAN \(2 devantler-tech submodules\)' "$d"
clean_out=$(bash "$SCRIPT" --root "$d")
if grep -q 'devantler/devantler\|profile' <<<"$clean_out"; then
  note_fail "another owner's submodule was checked"
fi
asserts=$(( asserts + 1 ))

# RED: platform sits in the Repo column of a table in a LATER section, which must not count.
d=$(mkroot "$MODULES" "$MAP_KSAIL_ONLY")
expect "repo outside the map section" 1 '^MISSING platform \(platform\)' "$d"

# An unrecognised URL spelling is UNKNOWN, never skipped.
d=$(mkroot "$MODULES
[submodule \"x\"]
	path = x
	url = ssh://git@example.com/devantler-tech/x.git" "$MAP_BOTH")
expect "unrecognised URL" 2 'UNKNOWN unrecognised submodule URL for x' "$d"

# No Portfolio map section at all is UNKNOWN, not "nothing mapped".
d=$(mkroot "$MODULES" '# AGENTS.md

## Stack map')
expect "no map section" 2 "UNKNOWN no '## Portfolio map' section" "$d"

# A deliberate exclusion with a reason clears a missing repository.
d=$(mkroot "$MODULES" "$MAP_KSAIL_ONLY" "$(printf 'platform\tretired from the portfolio')")
expect "reasoned exclusion" 0 '^EXCLUDED platform' "$d"

# An exclusion without a reason is not accepted.
d=$(mkroot "$MODULES" "$MAP_KSAIL_ONLY" 'platform')
expect "exclusion without reason" 2 'UNKNOWN exclusion row without a reason' "$d"

# An exclusion for a repository already in the map is stale.
d=$(mkroot "$MODULES" "$MAP_BOTH" "$(printf 'ksail\tno longer needed')")
expect "stale exclusion: already mapped" 1 '^STALE-EXCLUSION ksail is already in the Portfolio map' "$d"

# An exclusion for a repository that is not a tracked devantler-tech submodule is stale.
d=$(mkroot "$MODULES" "$MAP_BOTH" "$(printf 'devantler\tpersonal profile')")
expect "stale exclusion: not a submodule" 1 '^STALE-EXCLUSION devantler is not a tracked devantler-tech submodule' "$d"

# A .gitmodules with no devantler-tech submodule is UNKNOWN, never a vacuous clean.
d=$(mkroot '[submodule "p"]
	path = p
	url = git@github.com:devantler/devantler.git' "$MAP_BOTH")
expect "no devantler-tech submodules" 2 'UNKNOWN no devantler-tech submodules' "$d"

# The real repository must be clean: every tracked devantler-tech submodule is mapped or excluded.
asserts=$(( asserts + 1 ))
if ! out=$(bash "$SCRIPT" 2>&1); then
  note_fail "the repository's own Portfolio map drifts: $out"
fi

if [ "$fails" -ne 0 ]; then
  echo "portfolio-map-drift.test: $fails of $asserts assertions FAILED" >&2
  exit 1
fi
finished=1
echo "portfolio-map-drift.test: all $asserts assertions passed"
