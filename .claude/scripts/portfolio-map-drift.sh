#!/usr/bin/env bash
# portfolio-map-drift.sh — does the AGENTS.md Portfolio map list every devantler-tech submodule? (#2811)
#
# WHY THIS EXISTS
# The Portfolio map is the contract section a run reads to learn what is in scope. A tracked
# devantler-tech submodule missing from it is invisible to the work queue: its issues never reach
# the ladder and its state never reaches a survey. Two submodules sat outside the map for weeks
# because nothing compared the two lists.
#
# WHAT IS COMPARED
# Every .gitmodules URL owned by devantler-tech (git@github.com:devantler-tech/<repo>[.git] or
# https://github.com/devantler-tech/<repo>[.git]) against the `devantler-tech/<repo>` names in the
# Repo column of the Portfolio map table. Submodules owned by anyone else are out of scope. A URL of
# any other shape is UNKNOWN, never skipped, so an unexpected spelling cannot hide a repository.
#
# EXCLUSIONS
# .claude/portfolio-map-exclusions.tsv lists deliberate omissions, one per line:
#   <repo> TAB <reason>
# A row must give a reason. A row whose repository is already in the map, or is not a tracked
# devantler-tech submodule, is STALE and fails, so the list can only shrink.
#
#   exit 0  every devantler-tech submodule is in the map or deliberately excluded
#   exit 1  MISSING or STALE-EXCLUSION
#   exit 2  UNKNOWN — a file could not be read or parsed; never read it as clean
set -uo pipefail

# usage prints the calling convention to stderr.
usage() {
  cat >&2 <<'USAGE'
Usage: portfolio-map-drift.sh [--root <superproject>] [--exclusions <file>]

  --root <dir>         superproject to check (default: the repository containing this script)
  --exclusions <file>  exclusions TSV (default: <root>/.claude/portfolio-map-exclusions.tsv)
USAGE
}

# die_unknown reports why no verdict could be produced and exits 2 (UNKNOWN, never clean).
die_unknown() { echo "UNKNOWN $*" >&2; exit 2; }

root=""
exclusions=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { usage; exit 2; }; root=$2; shift 2 ;;
    --exclusions) [ $# -ge 2 ] || { usage; exit 2; }; exclusions=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [ -z "$root" ]; then
  script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || die_unknown "cannot resolve script directory"
  root=$(git -C "$script_dir" rev-parse --show-toplevel) || die_unknown "cannot resolve repository root"
fi
[ -n "$exclusions" ] || exclusions="$root/.claude/portfolio-map-exclusions.tsv"

gitmodules="$root/.gitmodules"
agents="$root/AGENTS.md"
[ -r "$gitmodules" ] || die_unknown "cannot read $gitmodules"
[ -r "$agents" ] || die_unknown "cannot read $agents"

# Submodules: "<path> <repo>" for every devantler-tech URL.
if ! urls=$(git config -f "$gitmodules" --get-regexp '^submodule\..*\.url$'); then
  die_unknown "no submodule URLs readable from $gitmodules"
fi
submodules=""
while IFS=' ' read -r key url; do
  [ -n "$key" ] || continue
  path=${key#submodule.}
  path=${path%.url}
  case "$url" in
    git@github.com:*/*) rest=${url#git@github.com:} ;;
    https://github.com/*/*) rest=${url#https://github.com/} ;;
    *) die_unknown "unrecognised submodule URL for $path" ;;
  esac
  owner=${rest%%/*}
  repo=${rest#*/}
  repo=${repo%.git}
  case "$repo" in
    ''|*/*) die_unknown "unrecognised submodule URL for $path" ;;
  esac
  [ "$owner" = "devantler-tech" ] || continue
  submodules="$submodules$path $repo
"
done <<EOF
$urls
EOF
[ -n "$submodules" ] || die_unknown "no devantler-tech submodules found in $gitmodules"

# Map: the first `devantler-tech/<repo>` code span in the Repo column of each Portfolio map row.
if ! mapped=$(awk -F'|' '
    /^## Portfolio map[[:space:]]*$/ { in_map = 1; seen = 1; next }
    in_map && /^## / { in_map = 0 }
    in_map && /^\|/ {
      col = $3
      if (match(col, /`devantler-tech\/[A-Za-z0-9._-]+`/)) {
        print substr(col, RSTART + 16, RLENGTH - 17)
      }
    }
    END { if (!seen) exit 3 }
  ' "$agents"); then
  die_unknown "no '## Portfolio map' section in $agents"
fi
[ -n "$mapped" ] || die_unknown "no devantler-tech repositories parsed from the Portfolio map"

# in_list <needle> <newline-separated list> succeeds when the list holds the needle exactly.
in_list() {
  local needle=$1 item
  while IFS= read -r item; do
    [ "$item" = "$needle" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

excluded=""
if [ -e "$exclusions" ]; then
  [ -r "$exclusions" ] || die_unknown "cannot read $exclusions"
  tab=$(printf '\t')
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *"$tab"*) ;;
      *) die_unknown "exclusion row without a reason: $line" ;;
    esac
    ex_repo=${line%%"$tab"*}
    ex_reason=${line#*"$tab"}
    if [ -z "$ex_repo" ] || [ -z "$ex_reason" ]; then
      die_unknown "exclusion row without a reason: $line"
    fi
    excluded="$excluded$ex_repo
"
  done <"$exclusions"
fi

sub_repos=$(printf '%s' "$submodules" | awk '{ print $2 }')
drift=0
checked=0
while IFS=' ' read -r path repo; do
  [ -n "$path" ] || continue
  checked=$((checked + 1))
  if in_list "$repo" "$mapped"; then
    echo "OK $repo"
  elif in_list "$repo" "$excluded"; then
    echo "EXCLUDED $repo"
  else
    echo "MISSING $repo ($path) is a tracked submodule absent from the AGENTS.md Portfolio map"
    drift=1
  fi
done <<EOF
$submodules
EOF

while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  if in_list "$repo" "$mapped"; then
    echo "STALE-EXCLUSION $repo is already in the Portfolio map"
    drift=1
  elif ! in_list "$repo" "$sub_repos"; then
    echo "STALE-EXCLUSION $repo is not a tracked devantler-tech submodule"
    drift=1
  fi
done <<EOF
$excluded
EOF

[ "$checked" -gt 0 ] || die_unknown "no submodules were checked"
if [ "$drift" -ne 0 ]; then
  echo "portfolio-map-drift: DRIFT — add each MISSING repository to the Portfolio map, or record why it is excluded in $exclusions"
  exit 1
fi
echo "portfolio-map-drift: CLEAN ($checked devantler-tech submodules)"
exit 0
