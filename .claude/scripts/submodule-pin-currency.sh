#!/usr/bin/env bash
# Is the submodule gitlink pin still current with the product's own default branch?
#
# WHY THIS EXISTS
# `submodule-init.sh` checks a submodule out at the SUPERPROJECT'S GITLINK PIN, and that is correct
# behaviour: reading a reviewed plugin definition at a known revision depends on exactly it. But a
# NEW product work branch cut from whatever that left checked out is based on the pin too — and the
# pin lags the product's `main` by however long it has been since a bump merged.
#
# The failure is silent and expensive. Every local measurement is internally consistent and
# externally wrong: a scanner genuinely reports findings at the pin, the repository's own scan
# script agrees because it also runs at the pin, and the build is green — all correct about a tree
# that is not the one the PR merges into. Nothing surfaces until `mergeStateStatus` resolves DIRTY,
# by which point a full claim -> build -> validate -> PR cycle has been spent reproducing work that
# already merged. It degrades exactly when dependency automation is unhealthy, because that is when
# pins sit still (see #2779).
#
# This answers the question BEFORE the work starts, with a fetch and a rev-list.
#
#   exit 0  CURRENT   the pin is the tip of the product's default branch
#   exit 1  BEHIND    the pin is N commits behind; base a new work branch on origin/<branch>
#   exit 2  UNKNOWN   no verdict produced — never read this as CURRENT
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: submodule-pin-currency.sh <submodule-path> [--branch <name>]

  <submodule-path>  path of a submodule tracked in .gitmodules, relative to the superproject root
  --branch <name>   default branch to compare against (default: resolved from origin/HEAD, else main)
USAGE
}

die_unknown() {
  printf 'submodule-pin-currency: UNKNOWN — %s\n' "$1" >&2
  exit 2
}

sub=""
branch=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      branch="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 2
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      [ -z "$sub" ] || { usage; exit 2; }
      sub="$1"
      shift
      ;;
  esac
done
[ -n "$sub" ] || { usage; exit 2; }

# Strip a trailing slash so `platform/` and `platform` name the same submodule.
sub="${sub%/}"

super="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  die_unknown "not inside a git working tree"

[ -f "$super/.gitmodules" ] ||
  die_unknown "no .gitmodules at $super"

# Tracked-submodule check. Without it a plain directory would be compared against its PARENT
# repository's history, because `git -C <not-a-repo>` silently resolves upward.
git -C "$super" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null |
  awk '{print $2}' | grep -qxF -- "$sub" ||
  die_unknown "$sub is not a submodule path in .gitmodules"

[ -d "$super/$sub" ] ||
  die_unknown "$sub is not present on disk — run .claude/scripts/submodule-init.sh $sub first"

# The submodule must be its OWN working tree. An uninitialised path resolves to the superproject,
# which would then be compared against itself and report a confident, meaningless CURRENT.
subtop="$(git -C "$super/$sub" rev-parse --show-toplevel 2>/dev/null)" ||
  die_unknown "$sub is not populated — run .claude/scripts/submodule-init.sh $sub first"
subabs="$(cd "$super/$sub" && pwd -P)"
[ "$(cd "$subtop" && pwd -P)" = "$subabs" ] ||
  die_unknown "$sub is not an isolated working tree (resolves to $subtop) — run .claude/scripts/submodule-init.sh $sub"

# The pin, read from THIS commit. --no-replace-objects so a refs/replace entry cannot make the
# gitlink resolve through a replacement commit while HEAD still prints the expected value.
pin="$(git -C "$super" --no-replace-objects rev-parse "HEAD:$sub" 2>/dev/null)" ||
  die_unknown "cannot resolve the gitlink for $sub at HEAD"
[ -n "$pin" ] || die_unknown "empty gitlink for $sub"

if [ -z "$branch" ]; then
  # origin/HEAD when the clone recorded it; otherwise main. Never guessed from local branches,
  # which say what this checkout happens to hold rather than what the product's default branch is.
  if head_ref="$(git -C "$subabs" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; then
    branch="${head_ref#refs/remotes/origin/}"
  else
    branch="main"
  fi
fi

git -C "$subabs" fetch --quiet origin "$branch" 2>/dev/null ||
  die_unknown "cannot fetch origin/$branch in $sub"

tip="$(git -C "$subabs" rev-parse FETCH_HEAD 2>/dev/null)" ||
  die_unknown "cannot resolve origin/$branch in $sub"

# The pin must be an object this clone actually has, or the count below is about nothing.
git -C "$subabs" cat-file -e "${pin}^{commit}" 2>/dev/null ||
  die_unknown "the pinned commit $pin is not present in $sub"

# Order is load-bearing: `<pin>..<tip>` counts commits on the tip that the pin lacks. The reverse
# reports 0 for a pin that is behind, which is a false CURRENT.
behind="$(git -C "$subabs" rev-list --count "${pin}..${tip}" 2>/dev/null)" ||
  die_unknown "cannot count $pin..origin/$branch in $sub"
case "$behind" in
  '' | *[!0-9]*) die_unknown "non-numeric commit count for $sub" ;;
esac

printf 'submodule        : %s\n' "$sub"
printf 'pinned gitlink   : %s\n' "$pin"
printf 'default branch   : origin/%s (%s)\n' "$branch" "$tip"

if [ "$behind" -eq 0 ]; then
  printf '\nCURRENT — the pin is the tip of origin/%s.\n' "$branch"
  exit 0
fi

printf '\nBEHIND — the pin is %s commit(s) behind origin/%s.\n' "$behind" "$branch"
printf 'Base a NEW work branch on origin/%s, not on the checked-out pin:\n' "$branch"
printf '  git -C %s checkout -b <lane>/<area>-<desc>-<issue> %s\n' "$sub" "$tip"
printf 'Reading a pinned plugin definition is UNCHANGED and must still use the gitlink.\n'
exit 1
