#!/usr/bin/env bash
# submodule-agents-drift.sh — does any pinned submodule AGENTS.md still state a retired rule? (#2534)
#
# WHY THIS EXISTS
# Every submodule carries its own AGENTS.md, and agents working in this repository read the copy at
# the revision this repository PINS. When the portfolio contract retires a rule — the human
# promotion gate, "never merge external PRs", the old role name — each submodule's copy has to follow,
# and so does its pin. Nothing read those files back, so ten of them kept telling agents to wait for
# a human who was not coming, and the drift stayed invisible for weeks.
#
# This reads each devantler-tech submodule's AGENTS.md at its pinned revision and reports any
# superseded claim. Only one blob is fetched per submodule: an anonymous, shallow, blobless fetch of
# the pinned commit, so no token and no full clone are needed.
#
# WHAT COUNTS AS DRIFT
#   go-signal             the retired human promotion gate ("... is the go-signal")
#   never-self-merge      "never self-merge your own unreviewed drafts"
#   never-merge-external  "never merge external PRs"
#   old-role              the maintenance role introduced as the Daily AI Assistant/Engineer
#   old-prefix            output told to start with the Daily AI prefix, unless "legacy" appears in
#                         the same statement (the legacy prefixes legitimately stay recognised)
# Text is compared lowercased, with line breaks and Markdown emphasis flattened, so reflowing a
# paragraph or emphasising part of a phrase cannot hide a claim. "AUTOMATION-OWNED (NO-ACTION)" is
# deliberately not a pattern: the root contract still uses it for dependency-bot issues, and tenant
# scaffolds keep it on purpose.
#
# WHICH URLS ARE FETCHED
# .gitmodules is part of the tree being checked, so a pull request controls it. Only
# https://github.com/devantler-tech/<repo> (or its SSH form) is ever fetched. Other GitHub owners are
# out of scope and never fetched. Any other destination is UNKNOWN and never fetched. Local fixture
# paths are accepted only with --allow-local-urls, which exists for the test suite. Transfers that
# stall below a minimum speed are abandoned, so a hung remote cannot hold the check open.
#
# EXCEPTIONS
# .claude/submodule-agents-drift-exceptions.tsv lists pins known to lag, one per line:
#   <path> TAB <full 40-character revision> TAB <reason>
# A row matches only its exact revision. Moving the pin makes the row stale, and a stale row fails,
# so the list can only shrink. A private repository cannot be read anonymously and needs a row too.
#
#   exit 0  every in-scope pinned AGENTS.md is clean, absent, or excepted at its exact revision
#   exit 1  DRIFT or a STALE-EXCEPTION
#   exit 2  UNKNOWN — something could not be read, parsed, or safely fetched; never read it as clean
set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: submodule-agents-drift.sh [--root <superproject>] [--ref <revision>] [--exceptions <file>]
                                 [--allow-local-urls]
       submodule-agents-drift.sh --resolve-url <url>

  --root <dir>         superproject to check (default: the repository containing this script)
  --ref <revision>     revision whose gitlinks are checked (default: HEAD)
  --exceptions <file>  exceptions TSV (default: <root>/.claude/submodule-agents-drift-exceptions.tsv)
  --allow-local-urls   also accept absolute local paths as submodule URLs (test fixtures only)
  --resolve-url <url>  print the URL a submodule URL is fetched from, then exit
USAGE
}

die_unknown() {
  printf 'submodule-agents-drift: UNKNOWN — %s\n' "$1" >&2
  exit 2
}

# resolve_url rewrites a GitHub SSH URL to anonymous HTTPS; any other URL is returned unchanged.
resolve_url() {
  case "$1" in
    git@github.com:*) printf 'https://github.com/%s\n' "${1#git@github.com:}" ;;
    ssh://git@github.com/*) printf 'https://github.com/%s\n' "${1#ssh://git@github.com/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

root=""
ref="HEAD"
exceptions=""
allow_local=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-local-urls)
      allow_local=1
      shift
      ;;
    --root | --ref | --exceptions | --resolve-url)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      case "$1" in
        --root) root=$2 ;;
        --ref) ref=$2 ;;
        --exceptions) exceptions=$2 ;;
        --resolve-url) resolve_url "$2"; exit 0 ;;
      esac
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [ -z "$root" ]; then
  root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd) || die_unknown "cannot resolve the repository root"
fi
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || die_unknown "not a git repository: $root"
[ -n "$exceptions" ] || exceptions="$root/.claude/submodule-agents-drift-exceptions.tsv"

scratch=$(mktemp -d) || die_unknown "cannot create a scratch directory"
trap 'rm -rf "$scratch"' EXIT

worst=0
bump() {
  if [ "$1" -gt "$worst" ]; then
    worst=$1
  fi
}

# --- Exceptions: validated up front; a malformed row is UNKNOWN, never skipped. ------------------
: >"$scratch/exceptions"
if [ -f "$exceptions" ]; then
  row=0
  while IFS= read -r line || [ -n "$line" ]; do
    row=$((row + 1))
    case "$line" in
      '' | '#'*) continue ;;
    esac
    IFS=$'\t' read -r ex_path ex_rev ex_reason ex_extra <<<"$line"
    if [ -z "${ex_path:-}" ] || [ -z "${ex_reason:-}" ] || [ -n "${ex_extra:-}" ] ||
      ! [[ ${ex_rev:-} =~ ^[0-9a-f]{40}$ ]]; then
      die_unknown "malformed exceptions row $row in $exceptions (want: path TAB 40-char revision TAB reason)"
    fi
    printf '%s\t%s\n' "$ex_path" "$ex_rev" >>"$scratch/exceptions"
  done <"$exceptions"
fi

# --- Enumerate the gitlinks and their URLs at the revision. -------------------------------------
tree=$(git -C "$root" --no-replace-objects ls-tree -r "$ref") || die_unknown "cannot list $ref in $root"
printf '%s\n' "$tree" | awk -F'\t' '{ split($1, meta, " "); if (meta[2] == "commit") print $2 "\t" meta[3] }' \
  >"$scratch/gitlinks" || die_unknown "cannot parse the tree at $ref"

if [ -s "$scratch/gitlinks" ]; then
  git -C "$root" --no-replace-objects show "$ref:.gitmodules" >"$scratch/gitmodules" 2>/dev/null ||
    die_unknown "submodules are pinned at $ref but .gitmodules cannot be read"
  git config -f "$scratch/gitmodules" --get-regexp '^submodule\..*\.path$' >"$scratch/paths" 2>/dev/null ||
    die_unknown "cannot parse .gitmodules at $ref"
fi

# url_for prints the configured URL of the submodule whose path is $1, or nothing.
url_for() {
  local key value name
  while IFS=' ' read -r key value; do
    if [ "$value" = "$1" ]; then
      name=${key#submodule.}
      name=${name%.path}
      git config -f "$scratch/gitmodules" --get "submodule.$name.url"
      return
    fi
  done <"$scratch/paths"
}

re_github_repo='^https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)$'
# A repository name may start with a dot (.github), but a name made only of dots is a path trick.
re_dots_only='^\.+(\.git)?$'

# classify_url prints approved, out-of-scope, or unapproved for a resolved submodule URL.
classify_url() {
  local owner name
  if [[ $1 =~ $re_github_repo ]]; then
    owner=${BASH_REMATCH[1]}
    name=${BASH_REMATCH[2]}
    if [[ $name =~ $re_dots_only ]]; then
      echo unapproved
      return
    fi
    if [ "$owner" = "devantler-tech" ]; then
      echo approved
    else
      echo out-of-scope
    fi
    return
  fi
  if [ "$allow_local" -eq 1 ] && [[ $1 == /* ]]; then
    if [[ $1 == */devantler-tech/* ]]; then
      echo approved
    else
      echo out-of-scope
    fi
    return
  fi
  echo unapproved
}

re_go_signal='is the go-signal'
re_self_merge='never self-merge your own unreviewed drafts'
re_merge_external='never merge external (prs|pull requests)'
re_old_role='autonomous daily ai (assistant|engineer)'
re_old_prefix='generated by the daily ai (assistant|engineer)'
# How far before an old-prefix match "legacy" may appear and still belong to the same statement.
legacy_window=80

# check_body prints the drift labels found in the AGENTS.md text passed as $1.
check_body() {
  local lower flat labels="" rest match before window
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$1")
  flat=$(tr '\n' ' ' <<<"$lower" | tr -d '*`' | tr -s ' ')

  if [[ $flat =~ $re_go_signal ]]; then labels="$labels go-signal"; fi
  if [[ $flat =~ $re_self_merge ]]; then labels="$labels never-self-merge"; fi
  if [[ $flat =~ $re_merge_external ]]; then labels="$labels never-merge-external"; fi
  if [[ $flat =~ $re_old_role ]]; then labels="$labels old-role"; fi

  # Walk every old-prefix match in the normalised text; a match counts unless "legacy" appears in
  # the short window just before it.
  rest=$flat
  while [[ $rest =~ $re_old_prefix ]]; do
    match=${BASH_REMATCH[0]}
    before=${rest%%"$match"*}
    if [ "${#before}" -gt "$legacy_window" ]; then
      window=${before:$((${#before} - legacy_window))}
    else
      window=$before
    fi
    if ! [[ $window =~ legacy ]]; then
      labels="$labels old-prefix"
      break
    fi
    rest=${rest#*"$match"}
  done

  printf '%s' "${labels# }"
}

: >"$scratch/pinned"
index=0
while IFS=$'\t' read -r sub pin; do
  [ -n "$sub" ] || continue
  index=$((index + 1))
  short=${pin:0:8}
  printf '%s\t%s\n' "$sub" "$pin" >>"$scratch/pinned"

  raw_url=$(url_for "$sub")
  if [ -z "$raw_url" ]; then
    echo "UNKNOWN $sub $short no URL for this path in .gitmodules"
    bump 2
    continue
  fi
  url=$(resolve_url "$raw_url")

  # The URL is pull-request-controlled text: classify it before anything is fetched, and never echo
  # a rejected one back.
  case $(classify_url "$url") in
    out-of-scope)
      echo "OUT-OF-SCOPE $sub $short"
      continue
      ;;
    unapproved)
      echo "UNKNOWN $sub $short unapproved URL (only https://github.com/devantler-tech/<repo> is fetched)"
      bump 2
      continue
      ;;
  esac

  if grep -qxF "$(printf '%s\t%s' "$sub" "$pin")" "$scratch/exceptions"; then
    echo "EXCEPTED $sub $short"
    continue
  fi

  repo="$scratch/repo-$index"
  fetch_url=$url
  case "$fetch_url" in
    /*) fetch_url="file://$fetch_url" ;;
  esac
  if ! git init -q --bare "$repo" >/dev/null 2>&1 ||
    ! git -C "$repo" remote add origin "$fetch_url" >/dev/null 2>&1; then
    echo "UNKNOWN $sub $short cannot prepare a scratch repository"
    bump 2
    continue
  fi
  # Anonymous on purpose: with a credential helper a private repository reads fine locally and
  # fails in CI, so the local verdict would not predict the CI one. The low-speed limits abandon a
  # transfer that stalls instead of holding the check open.
  if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false git -C "$repo" -c credential.helper= \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 -c protocol.file.allow=always \
    fetch -q --depth 1 --filter=blob:none origin "$pin" >/dev/null 2>&1; then
    echo "UNKNOWN $sub $short cannot fetch the pinned revision from $url"
    bump 2
    continue
  fi

  if ! listing=$(git -C "$repo" ls-tree "$pin" -- AGENTS.md 2>/dev/null); then
    echo "UNKNOWN $sub $short cannot read the pinned tree"
    bump 2
    continue
  fi
  if [ -z "$listing" ]; then
    echo "NO-AGENTS-MD $sub $short"
    continue
  fi

  if ! body=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false git -C "$repo" -c credential.helper= \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 -c protocol.file.allow=always \
    show "$pin:AGENTS.md" 2>/dev/null); then
    echo "UNKNOWN $sub $short cannot read AGENTS.md at the pinned revision"
    bump 2
    continue
  fi

  labels=$(check_body "$body")
  if [ -n "$labels" ]; then
    echo "DRIFT $sub $short $labels"
    bump 1
  else
    echo "CLEAN $sub $short"
  fi
done <"$scratch/gitlinks"

# --- Stale exceptions: a row that no longer names a pinned revision must be removed. ------------
while IFS=$'\t' read -r ex_path ex_rev; do
  [ -n "$ex_path" ] || continue
  if ! grep -qxF "$(printf '%s\t%s' "$ex_path" "$ex_rev")" "$scratch/pinned"; then
    echo "STALE-EXCEPTION $ex_path ${ex_rev:0:8} no longer pinned at $ref; remove this row"
    bump 1
  fi
done <"$scratch/exceptions"

exit "$worst"
