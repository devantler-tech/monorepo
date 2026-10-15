#!/usr/bin/env bash
# Apply the agreed retention to Codex's saved transcripts.
#
# Why this exists: Codex keeps every session transcript forever, under `sessions/` while a
# thread is live and `archived_sessions/` once it is finished. On 2026-10-12 they held about
# 26 GB of the agent host's disk with no retention at all, and the host kept reading below
# its low-space threshold (monorepo#4136). The maintainer chose, on 2026-10-15, to let the
# clean-up helper apply a retention to them (option 2 of the ask recorded on #4136).
#
# The default age is 14 days, not shorter: the Agent Improver measures the Codex lane over
# 14-day windows read from exactly these files, so a shorter cut would silently shrink the
# evidence it scores the lane on. Values below 7 are refused, so a typo cannot reach a
# transcript a live thread may still resume.
#
# Usage:
#   codex-transcript-retention.sh [dry-run|apply] [min_age_days]
#
# Defaults: dry-run, 14 days.
#
# Exit: 0 every root was read; 2 a usage error, or a root or the open-file list that could not
# be read (logged as UNKNOWN -- nothing is removed from a root that is UNKNOWN, and the summary
# is then partial, never clean).
#
# Environment (all optional):
#   CODEX_TRANSCRIPT_RETENTION_HOME   the Codex home; default ${CODEX_HOME:-$HOME/.codex}
#   CODEX_TRANSCRIPT_RETENTION_LSOF   the open-file lister; default `lsof`
#
# SAFETY -- this deletes, so every rule below fails closed:
#   * Only regular files named rollout-*.jsonl or rollout-*.jsonl.zst directly or below
#     <home>/sessions and <home>/archived_sessions are considered. Symbolic links are never
#     followed or removed, and a root that is itself a symbolic link is refused.
#   * Only files this user owns, last written longer ago than min_age_days.
#   * A file any process holds open is KEPT. When the open-file list cannot be read, nothing
#     is removed at all.
#   * The age is checked again immediately before each removal.
#   * Nothing else in the Codex home is touched: not the thread database, not the logs, not
#     the worktrees (those carry work in progress and are swept by the Codex lane's own
#     worktree clean-up, which keeps anything uncommitted or unpushed).
set -uo pipefail

MODE=${1:-dry-run}
MIN_AGE_DAYS=${2:-14}
MIN_ALLOWED_DAYS=7

log() { printf 'codex-transcript-retention: %s\n' "$*"; }

case "$MODE" in
  dry-run | apply) ;;
  *)
    log "mode must be dry-run or apply, got ${MODE}" >&2
    exit 2
    ;;
esac
# Bound the digits before arithmetic: a leading zero would be read as octal and a long value
# would wrap. `10#` forces base ten.
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

CODEX_HOME_DIR=${CODEX_TRANSCRIPT_RETENTION_HOME:-${CODEX_HOME:-${HOME:-}/.codex}}
LSOF=${CODEX_TRANSCRIPT_RETENTION_LSOF:-lsof}
ME=$(id -u) || { log 'UNKNOWN: cannot read the current user id' >&2; exit 2; }

if [ ! -e "$CODEX_HOME_DIR" ]; then
  log "no Codex home at ${CODEX_HOME_DIR}; nothing to do"
  exit 0
fi
if [ -L "$CODEX_HOME_DIR" ] || [ ! -d "$CODEX_HOME_DIR" ]; then
  log "UNKNOWN: ${CODEX_HOME_DIR} is not a plain directory; refusing"
  exit 2
fi
# The open-file list names files by their physical path (on macOS /tmp is /private/tmp), so
# compare from the physical path too, or an open transcript would not be recognised as open.
CODEX_HOME_DIR=$(cd -P -- "$CODEX_HOME_DIR" && pwd -P) || {
  log 'UNKNOWN: cannot resolve the Codex home'
  exit 2
}

# list_old <root> <out> writes every transcript under <root> past the age line, one per line,
# sorted. Transcript names never hold a newline; a path that does is left out of <out> and
# counted in <out>.odd, so it is kept and the root reported UNKNOWN rather than mis-split.
list_old() {
  find "$1" -type f -user "$ME" \( -name 'rollout-*.jsonl' -o -name 'rollout-*.jsonl.zst' \) \
    -mmin +"$MIN_AGE_MINUTES" -print0 > "$2.nul" 2>/dev/null || return 1
  tr '\0\n' '\n\001' < "$2.nul" > "$2.raw" || return 1
  grep -c $'\001' "$2.raw" > "$2.odd"
  grep -v $'\001' "$2.raw" | LC_ALL=C sort -u > "$2"
  return 0
}

# total_bytes <list> prints the summed size of the files a newline list names (BSD stat on
# the agent host, GNU stat elsewhere). A file gone in the meantime adds nothing.
total_bytes() {
  if [ ! -s "$1" ]; then printf '0'; return; fi
  if [ "$(uname -s)" = Darwin ]; then
    tr '\n' '\0' < "$1" | xargs -0 stat -f %z -- 2>/dev/null | awk '{ s += $1 } END { printf "%d", s }'
  else
    tr '\n' '\0' < "$1" | xargs -0 stat -c %s -- 2>/dev/null | awk '{ s += $1 } END { printf "%d", s }'
  fi
}

work=$(mktemp -d) || { log 'UNKNOWN: cannot create a work directory' >&2; exit 2; }
retention_finished=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf -- "$work"
  if [ "$retention_finished" != 1 ] && [ "$status" = 0 ]; then
    log "UNKNOWN: aborted before finishing" >&2
    exit 2
  fi
}
trap on_exit EXIT

# One list of every path any process holds open, taken once. Field output (-F n) prints one
# `n<path>` line per open file, which keeps paths with spaces whole.
open_list="$work/open"
lsof_ok=1
if ! command -v "$LSOF" >/dev/null 2>&1; then
  lsof_ok=0
else
  "$LSOF" -n -F n > "$work/lsof.raw" 2>/dev/null
  lsof_rc=$?
  # lsof exits 1 when it could not inspect some processes; a non-empty list is still usable.
  if [ "$lsof_rc" -gt 1 ] || [ ! -s "$work/lsof.raw" ]; then
    lsof_ok=0
  else
    sed -n "s/^n//p" "$work/lsof.raw" | LC_ALL=C sort -u > "$open_list"
  fi
fi


unknown=0
candidates=0
removed=0
kept_open=0
kept_young=0
failed=0
bytes=0

count() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else printf '0'; fi; }

for name in sessions archived_sessions; do
  root="$CODEX_HOME_DIR/$name"
  [ -e "$root" ] || continue
  if [ -L "$root" ] || [ ! -d "$root" ]; then
    log "UNKNOWN: ${root} is not a plain directory; nothing removed from it"
    unknown=$((unknown + 1))
    continue
  fi
  old="$work/$name.old"
  if ! list_old "$root" "$old"; then
    log "UNKNOWN: ${root} could not be read completely; nothing removed from it"
    unknown=$((unknown + 1))
    continue
  fi
  odd=$(cat "$old.odd" 2>/dev/null)
  case "$odd" in '' | *[!0-9]*) odd=0 ;; esac
  if [ "$odd" -gt 0 ]; then
    log "UNKNOWN: ${odd} path(s) under ${root} hold a line break; kept"
    unknown=$((unknown + 1))
  fi
  n=$(count "$old")
  candidates=$((candidates + n))
  [ "$lsof_ok" = 1 ] || continue

  # Drop every path a process holds open (both lists sorted the same way).
  closed="$work/$name.closed"
  LC_ALL=C comm -23 "$old" "$open_list" > "$closed"
  c=$(count "$closed")
  kept_open=$((kept_open + n - c))

  if [ "$MODE" != apply ]; then
    removed=$((removed + c))
    b=$(total_bytes "$closed")
    bytes=$((bytes + b))
    continue
  fi

  # Ask again, immediately before removal, which of them are still past the age line, and
  # remove only those: a transcript written to since the first read is kept.
  again="$work/$name.again"
  if ! list_old "$root" "$again"; then
    log "UNKNOWN: ${root} could not be read again before removal; nothing removed from it"
    unknown=$((unknown + 1))
    continue
  fi
  doomed="$work/$name.doomed"
  LC_ALL=C comm -12 "$closed" "$again" > "$doomed"
  d=$(count "$doomed")
  kept_young=$((kept_young + c - d))
  b=$(total_bytes "$doomed")
  [ "$d" -eq 0 ] || tr '\n' '\0' < "$doomed" | xargs -0 rm -f -- 2>/dev/null
  # Count what is really gone rather than trusting rm's status for a whole batch.
  left=0
  while IFS= read -r f; do
    if [ -e "$f" ] || [ -L "$f" ]; then left=$((left + 1)); fi
  done < "$doomed"
  removed=$((removed + d - left))
  failed=$((failed + left))
  if [ "$left" -eq 0 ]; then bytes=$((bytes + b)); fi
done

if [ "$lsof_ok" != 1 ]; then
  log "UNKNOWN: the open-file list could not be read; ${candidates} transcript(s) past ${MIN_AGE_DAYS} days kept"
  unknown=$((unknown + 1))
fi

mb=$((bytes / 1048576))
if [ "$MODE" = apply ]; then
  log "summary: age>${MIN_AGE_DAYS}d candidates=${candidates} removed=${removed} kept_open=${kept_open} kept_written=${kept_young} failed=${failed} reclaimed=~${mb} MB"
else
  log "summary: age>${MIN_AGE_DAYS}d candidates=${candidates} would remove=${removed} kept_open=${kept_open} would reclaim=~${mb} MB (dry-run: nothing deleted)"
fi
if [ "$failed" -gt 0 ]; then
  log "UNKNOWN: ${failed} removal(s) failed"
  unknown=$((unknown + 1))
fi
retention_finished=1
[ "$unknown" -eq 0 ] || exit 2
exit 0
