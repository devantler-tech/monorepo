#!/usr/bin/env bash
# Apply the agreed retention to the Codex automations' per-run evidence folders.
#
# Why this exists: every Codex automation keeps one folder per run under
# <CODEX_HOME>/automations/<automation>/evidence/<run>/ and nothing ever removed one. They held
# about 56 GB on 2026-11-25 and kept the agent host below its low-space threshold, so every lane
# skipped builds and tests (monorepo#5189). The maintainer chose, on 2026-11-25, to delete a run's
# evidence folder once it is more than 14 days old and no open pull request or issue links to it,
# keeping and listing anything that cannot be judged (option A of monorepo#5193).
#
# Usage:
#   codex-evidence-retention.sh [dry-run|apply] [min_age_days]
#
# Defaults: dry-run, 14 days. Values below 14 are refused.
#
# Exit: 0 every evidence folder was judged or deferred; 2 a usage error, or a root, the open-file
# list or a GitHub lookup that could not be read (logged as UNKNOWN -- what could not be judged is
# kept, and the summary is then partial, never clean).
#
# Environment (all optional):
#   CODEX_EVIDENCE_RETENTION_HOME     the Codex home; default ${CODEX_HOME:-$HOME/.codex}
#   CODEX_EVIDENCE_RETENTION_LSOF     the open-file lister; default lsof from PATH, then
#                                     /usr/sbin, /usr/bin, /bin
#   CODEX_EVIDENCE_RETENTION_GH       the GitHub CLI used for the link lookup; default gh from PATH
#   CODEX_EVIDENCE_RETENTION_OWNER    the GitHub organisation searched; default devantler-tech
#   CODEX_EVIDENCE_RETENTION_LOOKUPS  most GitHub searches one run makes; default 40. Folders past
#                                     it are deferred to a later run (kept, counted, not UNKNOWN).
#   CODEX_EVIDENCE_RETENTION_PAUSE    seconds between searches; default 2 (the search API allows
#                                     30 a minute)
#
# SAFETY -- this deletes, so every rule below fails closed. A folder <run> directly below
# <home>/automations/<automation>/evidence is removed only when ALL of these hold; anything that
# cannot be read is KEPT:
#   * It is a plain directory owned by this user, holds nothing owned by anyone else, and its name
#     uses only letters, digits, '.', '_' and '-'. Neither the automations folder, the automation
#     folder nor its evidence folder is a symbolic link.
#   * Nothing inside it (file, directory or link) was written within min_age_days.
#   * No process holds a file open, or has its working directory, at or below it. The open-file
#     list counts only when lsof exits 0 with a non-empty list.
#   * A GitHub search of the organisation's open issues and pull requests (titles, bodies and
#     comments) for its name returns zero results, complete. Names are searched five to a query;
#     any hit keeps all five.
#   * Immediately before removal its age, ownership and open files are read again.
# Nothing outside the evidence folders is touched.
set -euo pipefail

MODE=${1:-dry-run}
MIN_AGE_DAYS=${2:-14}
MIN_ALLOWED_DAYS=14
BATCH=5

log() { printf 'codex-evidence-retention: %s\n' "$*"; }

case "$MODE" in
  dry-run | apply) ;;
  *)
    log "mode must be dry-run or apply, got ${MODE}" >&2
    exit 2
    ;;
esac
case "$MIN_AGE_DAYS" in
  '' | *[!0-9]*)
    log 'min_age_days must be a whole number of days' >&2
    exit 2
    ;;
esac
if [ "${#MIN_AGE_DAYS}" -gt 5 ]; then
  log "min_age_days is out of range: ${MIN_AGE_DAYS}" >&2
  exit 2
fi
MIN_AGE_DAYS=$((10#$MIN_AGE_DAYS))
if [ "$MIN_AGE_DAYS" -lt "$MIN_ALLOWED_DAYS" ]; then
  log "min_age_days must be at least ${MIN_ALLOWED_DAYS}, got ${MIN_AGE_DAYS}" >&2
  exit 2
fi
MIN_AGE_MINUTES=$((MIN_AGE_DAYS * 1440))

LOOKUPS=${CODEX_EVIDENCE_RETENTION_LOOKUPS:-40}
PAUSE=${CODEX_EVIDENCE_RETENTION_PAUSE:-2}
OWNER=${CODEX_EVIDENCE_RETENTION_OWNER:-devantler-tech}
case "$LOOKUPS" in '' | *[!0-9]*) log 'CODEX_EVIDENCE_RETENTION_LOOKUPS must be a whole number' >&2; exit 2 ;; esac
case "$PAUSE" in '' | *[!0-9]*) log 'CODEX_EVIDENCE_RETENTION_PAUSE must be a whole number of seconds' >&2; exit 2 ;; esac
case "$OWNER" in '' | *[!A-Za-z0-9-]*) log 'CODEX_EVIDENCE_RETENTION_OWNER must be a GitHub organisation name' >&2; exit 2 ;; esac

work=$(mktemp -d) || { log 'UNKNOWN: cannot create a work directory' >&2; exit 2; }
retention_finished=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf -- "$work"
  if [ "$retention_finished" != 1 ] && [ "$status" != 2 ]; then
    log "UNKNOWN: aborted before finishing (status ${status})" >&2
    exit 2
  fi
}
trap on_exit EXIT

if [ -n "${CODEX_EVIDENCE_RETENTION_HOME:-}" ]; then
  CODEX_HOME_DIR=$CODEX_EVIDENCE_RETENTION_HOME
elif [ -n "${CODEX_HOME:-}" ]; then
  CODEX_HOME_DIR=$CODEX_HOME
elif [ -n "${HOME:-}" ]; then
  CODEX_HOME_DIR=$HOME/.codex
else
  log 'UNKNOWN: no Codex home is set (CODEX_EVIDENCE_RETENTION_HOME, CODEX_HOME or HOME)'
  exit 2
fi
ME=$(id -u) || { log 'UNKNOWN: cannot read the current user id' >&2; exit 2; }
ROOT=$CODEX_HOME_DIR/automations

# "Absent" is believed only when the parent directory can be searched.
if [ ! -e "$ROOT" ] && [ ! -L "$ROOT" ]; then
  root_parent=$CODEX_HOME_DIR
  if [ ! -e "$root_parent" ] && [ ! -L "$root_parent" ]; then root_parent=$(dirname -- "$root_parent"); fi
  if [ -d "$root_parent" ] && [ ! -L "$root_parent" ] && [ -x "$root_parent" ]; then
    log "no Codex automations at ${ROOT}; nothing to do"
    retention_finished=1
    exit 0
  fi
  log "UNKNOWN: ${ROOT} cannot be examined (its parent cannot be searched)"
  exit 2
fi
if [ -L "$ROOT" ] || [ ! -d "$ROOT" ]; then
  log "UNKNOWN: ${ROOT} is not a plain directory; refusing"
  exit 2
fi
# lsof names paths physically (on macOS /tmp is /private/tmp), so compare physical paths.
ROOT=$(cd -P -- "$ROOT" && pwd -P) || { log 'UNKNOWN: cannot resolve the automations root'; exit 2; }

resolve_lsof() {
  local candidate
  if [ -n "${CODEX_EVIDENCE_RETENTION_LSOF:-}" ]; then
    [ -x "$CODEX_EVIDENCE_RETENTION_LSOF" ] && { printf '%s' "$CODEX_EVIDENCE_RETENTION_LSOF"; return 0; }
    return 1
  fi
  candidate=$(command -v lsof 2>/dev/null) && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  for candidate in /usr/sbin/lsof /usr/bin/lsof /bin/lsof; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# open_snapshot <out> writes every path a process holds open (working directories included),
# lower-cased so a case-insensitive volume's other spelling still matches. Only a zero exit with
# a non-empty list counts: a partial enumeration can print paths and still fail.
open_snapshot() {
  [ -n "$LSOF" ] || return 1
  "$LSOF" -n -F n > "$1.raw" 2>/dev/null || return 1
  [ -s "$1.raw" ] || return 1
  sed -n 's/^n//p' "$1.raw" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u > "$1" || return 1
  [ -s "$1" ]
}

# held <dir> <open> succeeds when the open-file list names <dir> or anything below it.
held() {
  LC_ALL=C awk -v d="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')" '
    $0 == d || index($0, d "/") == 1 { found = 1; exit }
    END { exit found ? 0 : 1 }' "$2"
}

# fresh <dir> succeeds when anything at or below <dir> was written within the age line, and
# fails with status 2 when the tree could not be read completely (kept, never judged old).
fresh() {
  find "$1" -mmin -"$MIN_AGE_MINUTES" -print > "$work/fresh" 2>/dev/null || return 2
  [ -s "$work/fresh" ]
}

# foreign <dir> succeeds when anything at or below <dir> is owned by another user, or fails with
# status 2 when that cannot be read.
foreign() {
  find "$1" ! -user "$ME" -print > "$work/foreign" 2>/dev/null || return 2
  [ -s "$work/foreign" ]
}

dir_kb() {
  local k
  k=$(du -sk -- "$1" 2>/dev/null | awk 'NR==1{print $1}') || return 1
  case "$k" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$k"
}

# linked <name>... prints the number of open issues and pull requests in the organisation that
# mention any of the names, or fails when the search could not be read completely.
linked() {
  local q='' n out total incomplete
  for n in "$@"; do
    if [ -z "$q" ]; then q="\"${n}\""; else q="${q} OR \"${n}\""; fi
  done
  [ -n "$GH" ] || return 1
  out=$("$GH" api -X GET search/issues -f "q=org:${OWNER} is:open ${q}" -f per_page=1 \
    --jq '[.total_count, .incomplete_results] | @tsv' < /dev/null 2>/dev/null) || return 1
  total=${out%%$'\t'*}
  incomplete=${out#*$'\t'}
  case "$total" in '' | *[!0-9]*) return 1 ;; esac
  [ "$incomplete" = false ] || return 1
  printf '%s' "$total"
}

LSOF=$(resolve_lsof) || LSOF=''
GH=${CODEX_EVIDENCE_RETENTION_GH:-$(command -v gh 2>/dev/null || true)}
[ -z "$GH" ] || [ -x "$GH" ] || GH=''

if ! open_snapshot "$work/open"; then
  log "UNKNOWN: the open-file list could not be read; nothing under ${ROOT} is removed"
  retention_finished=1
  exit 2
fi

unknown=0
examined=0
removed=0
kept_young=0
kept_open=0
kept_linked=0
kept_work=0
deferred=0
failed=0
lookups=0
kb_total=0
: > "$work/candidates"

# 1. Judge each evidence folder locally; the survivors are candidates for the link lookup.
if ! find "$ROOT" -mindepth 1 -maxdepth 1 -print0 > "$work/automations.nul" 2>/dev/null; then
  log "UNKNOWN: ${ROOT} could not be listed; nothing removed"
  retention_finished=1
  exit 2
fi
while IFS= read -r -d '' a; do
  [ -L "$a" ] && { log "kept ${a}: the automation folder is a symbolic link"; continue; }
  [ -d "$a" ] || continue
  ev=$a/evidence
  if [ ! -e "$ev" ] && [ ! -L "$ev" ]; then continue; fi
  if [ -L "$ev" ] || [ ! -d "$ev" ]; then
    log "kept ${ev}: not a plain directory"
    continue
  fi
  if ! find "$ev" -mindepth 1 -maxdepth 1 -type d -print0 > "$work/runs.nul" 2>/dev/null; then
    log "UNKNOWN: ${ev} could not be listed; kept"
    unknown=$((unknown + 1))
    continue
  fi
  while IFS= read -r -d '' d; do
    examined=$((examined + 1))
    name=${d##*/}
    case "$name" in
      '' | *[!A-Za-z0-9._-]* | .*)
        log 'kept an evidence folder whose name cannot be searched safely'
        kept_work=$((kept_work + 1))
        continue
        ;;
    esac
    rc=0
    fresh "$d" || rc=$?
    if [ "$rc" -eq 0 ]; then kept_young=$((kept_young + 1)); continue; fi
    if [ "$rc" -eq 2 ]; then
      log "UNKNOWN: ${d} could not be read completely; kept"
      unknown=$((unknown + 1))
      continue
    fi
    rc=0
    foreign "$d" || rc=$?
    if [ "$rc" -ne 1 ]; then
      if [ "$rc" -eq 0 ]; then
        log "kept ${d}: holds files owned by another user"
        kept_work=$((kept_work + 1))
      else
        log "UNKNOWN: ownership under ${d} could not be read; kept"
        unknown=$((unknown + 1))
      fi
      continue
    fi
    if held "$d" "$work/open"; then
      log "kept ${d}: a process is using it"
      kept_open=$((kept_open + 1))
      continue
    fi
    printf '%s\n' "$d" >> "$work/candidates"
  done < "$work/runs.nul"
done < "$work/automations.nul"

# remove_one <dir> applies (or, in dry-run, reports) the removal of one judged folder.
remove_one() {
  local d=$1 kb fresh_rc foreign_rc
  kb=$(dir_kb "$d") || {
    log "UNKNOWN: the size of ${d} could not be read; kept"
    unknown=$((unknown + 1))
    return 0
  }
  if [ "$MODE" != apply ]; then
    log "would remove ${d} (~$((kb / 1024)) MB)"
    removed=$((removed + 1))
    kb_total=$((kb_total + kb))
    return 0
  fi
  # Read age, ownership and open files again immediately before the removal.
  if ! open_snapshot "$work/open.now"; then
    log "UNKNOWN: the open-file list could not be read again; ${d} is kept"
    unknown=$((unknown + 1))
    return 0
  fi
  fresh_rc=0
  fresh "$d" || fresh_rc=$?
  foreign_rc=0
  foreign "$d" || foreign_rc=$?
  if [ -L "$d" ] || held "$d" "$work/open.now" || [ "$fresh_rc" -ne 1 ] || [ "$foreign_rc" -ne 1 ]; then
    log "kept ${d}: changed since it was scanned"
    kept_work=$((kept_work + 1))
    return 0
  fi
  rm -rf -- "$d" 2>/dev/null || : # judged by what is left, below
  if [ ! -e "$d" ] && [ ! -L "$d" ]; then
    log "removed ${d} (~$((kb / 1024)) MB)"
    removed=$((removed + 1))
    kb_total=$((kb_total + kb))
  else
    log "removal of ${d} failed"
    failed=$((failed + 1))
  fi
}

# 2. Look each batch of candidates up on GitHub, within the run's lookup budget.
#    Oldest names first, so a deferred backlog drains from its oldest end.
awk -F/ '{ print $NF "\t" $0 }' "$work/candidates" | LC_ALL=C sort | cut -f 2- > "$work/ordered"
# read_batch reads up to BATCH candidate paths from stdin (bash 3.2 has no mapfile).
read_batch() {
  local line
  batch_dirs=()
  batch_names=()
  while [ "${#batch_dirs[@]}" -lt "$BATCH" ] && IFS= read -r line; do
    batch_dirs+=("$line")
    batch_names+=("${line##*/}")
  done
}
stop_lookups=0
exec 3< "$work/ordered"
while :; do
  read_batch <&3
  [ "${#batch_dirs[@]}" -gt 0 ] || break
  if [ "$stop_lookups" -eq 1 ] || [ "$lookups" -ge "$LOOKUPS" ]; then
    deferred=$((deferred + ${#batch_dirs[@]}))
    continue
  fi
  [ "$lookups" -eq 0 ] || [ "$PAUSE" -eq 0 ] || sleep "$PAUSE"
  lookups=$((lookups + 1))
  if ! hits=$(linked "${batch_names[@]}"); then
    log "UNKNOWN: the GitHub search for ${#batch_dirs[@]} evidence folder(s) could not be read; they and the rest are kept"
    unknown=$((unknown + 1))
    deferred=$((deferred + ${#batch_dirs[@]}))
    stop_lookups=1
    continue
  fi
  if [ "$hits" -gt 0 ]; then
    for d in "${batch_dirs[@]}"; do log "kept ${d}: an open issue or pull request may link to it"; done
    kept_linked=$((kept_linked + ${#batch_dirs[@]}))
    continue
  fi
  for d in "${batch_dirs[@]}"; do remove_one "$d"; done
done
exec 3<&-

mb=$((kb_total / 1024))
kept=$((kept_young + kept_open + kept_linked + kept_work + deferred))
if [ "$MODE" = apply ]; then
  log "summary: age>${MIN_AGE_DAYS}d examined=${examined} removed=${removed} kept=${kept} (young=${kept_young} in_use=${kept_open} linked=${kept_linked} other=${kept_work} deferred=${deferred}) lookups=${lookups} failed=${failed} reclaimed=~${mb} MB"
else
  log "summary: age>${MIN_AGE_DAYS}d examined=${examined} would remove=${removed} kept=${kept} (young=${kept_young} in_use=${kept_open} linked=${kept_linked} other=${kept_work} deferred=${deferred}) lookups=${lookups} would reclaim=~${mb} MB (dry-run: nothing deleted)"
fi
if [ "$failed" -gt 0 ]; then
  log "UNKNOWN: ${failed} removal(s) failed"
  unknown=$((unknown + 1))
fi
retention_finished=1
[ "$unknown" -eq 0 ] || exit 2
exit 0
