#!/usr/bin/env bash
#
# Takes a timestamped copy of a durable-memory file (or the whole store) BEFORE
# a destructive consolidate/rewrite, so a trim cannot erase unrecoverable
# history. The memory store is multi-writer, un-versioned, and outside git —
# without a backup, a size-threshold consolidation is a one-way delete
# (monorepo#2304: ~48KB of learnings lost on 2026-07-20 with no restore path).
#
# This script ONLY copies. It never edits, truncates, or consolidates the
# source — the agent still decides what to keep after the backup lands.
#
# Usage:
#   memory-backup.sh [--backup-dir <dir>] <file>
#   memory-backup.sh --all [--backup-dir <dir>] <memory-dir>
#
# Default backup root is <parent>/.memory-backups/ (sibling of the file, or
# inside the memory dir for --all). Nested under the store so it stays with
# the runtime that owns the memory; hygiene ignores nested dirs (maxdepth 1).
#
# Single-file layout:  .memory-backups/<basename>.<UTC-timestamp>
# Whole-store layout:  .memory-backups/store.<UTC-timestamp>/<basename>
#
# Exit codes:
#   0  backup written; path + restore command printed on stdout
#   2  usage error, missing source, or copy failure
set -Eeuo pipefail

mode="file"
backup_dir=""
target=""

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) mode="all"; shift ;;
    --backup-dir) backup_dir="${2-}"; shift 2 || exit 2 ;;
    -h|--help) usage; exit 0 ;;
    --)
      shift
      if [[ -n "$target" || $# -eq 0 ]]; then
        echo "memory-backup: -- must be followed by exactly one file (or memory-dir with --all)" >&2
        usage >&2
        exit 2
      fi
      target="$1"
      shift
      if [[ $# -ne 0 ]]; then
        echo "memory-backup: unexpected extra argument '$1'" >&2
        usage >&2
        exit 2
      fi
      break
      ;;
    -*)
      echo "memory-backup: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$target" ]]; then
        echo "memory-backup: unexpected extra argument '$1'" >&2
        usage >&2
        exit 2
      fi
      target="$1"
      shift
      ;;
  esac
done

if [[ -z "$target" ]]; then
  echo "memory-backup: a file (or memory-dir with --all) is required" >&2
  usage >&2
  exit 2
fi

# Tests pin the timestamp so golden paths stay deterministic; production uses UTC now.
ts="${MEMORY_BACKUP_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
if ! [[ "$ts" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
  echo "memory-backup: MEMORY_BACKUP_TS must look like YYYYMMDDTHHMMSSZ (got '$ts')" >&2
  exit 2
fi

# Copy via a temp name in the destination dir, then publish — so a crash mid-copy
# never leaves a partial file that looks like a successful backup.
#
# Publishing uses `ln`, not a rename: the store is multi-writer, and any caller's
# existence check is a separate syscall from the publish, so two instances that
# select the same destination in the same second both clear that check long before
# either finishes copying. A rename would let the slower one silently replace the
# winner's backup while both report success; a hard link inside the destination
# directory is a single exclusive create, so exactly one racer can win.
#
# Returns 3 when the destination already exists (lost the publish race), 1 on any
# other copy failure.
atomic_cp() {
  local src="$1" dest="$2"
  local dest_dir tmp rc
  dest_dir="$(dirname -- "$dest")"
  if ! mkdir -p -- "$dest_dir"; then
    return 1
  fi
  if ! tmp="$(mktemp "$dest_dir/.memory-backup.XXXXXX")"; then
    return 1
  fi
  # mktemp creates an empty file; replace it with the source contents.
  if ! cp -p "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  rc=0
  ln "$tmp" "$dest" 2>/dev/null || rc=$?
  rm -f "$tmp"
  if (( rc != 0 )); then
    if [[ -e "$dest" ]]; then
      return 3
    fi
    return 1
  fi
  return 0
}

resolve_backup_dir() {
  local dir="$1"
  if ! mkdir -p -- "$dir"; then
    echo "memory-backup: failed to create backup directory: $dir" >&2
    return 1
  fi
  if ! (cd -- "$dir" && pwd -P); then
    echo "memory-backup: failed to resolve backup directory: $dir" >&2
    return 1
  fi
}

if [[ "$mode" == "file" ]]; then
  if [[ ! -f "$target" ]]; then
    echo "memory-backup: not a readable file: $target" >&2
    exit 2
  fi
  parent="$(cd -- "$(dirname -- "$target")" && pwd -P)"
  base="$(basename -- "$target")"
  target="$parent/$base"
  if [[ -z "$backup_dir" ]]; then
    backup_dir="$parent/.memory-backups"
  fi
  if ! backup_dir="$(resolve_backup_dir "$backup_dir")"; then
    exit 2
  fi
  dest="$backup_dir/${base}.${ts}"
  if [[ -e "$dest" ]]; then
    echo "memory-backup: refusing to overwrite existing backup: $dest" >&2
    exit 2
  fi
  cp_rc=0
  atomic_cp "$target" "$dest" || cp_rc=$?
  if (( cp_rc == 3 )); then
    # Another instance published this exact path while we were copying.
    echo "memory-backup: refusing to overwrite existing backup: $dest" >&2
    exit 2
  fi
  if (( cp_rc != 0 )); then
    echo "memory-backup: failed to back up $target -> $dest" >&2
    exit 2
  fi
  printf 'Backed up %s -> %s\n' "$target" "$dest"
  printf 'Restore: cp %q %q\n' "$dest" "$target"
  exit 0
fi

# --all: snapshot every top-level *.md in the memory dir (including archives —
# a recovery snapshot should be complete, not budget-filtered).
if [[ ! -d "$target" ]]; then
  echo "memory-backup: not a directory: $target" >&2
  exit 2
fi
memory_dir="$(cd -- "$target" && pwd -P)"
if [[ -z "$backup_dir" ]]; then
  backup_dir="$memory_dir/.memory-backups"
fi
if ! backup_dir="$(resolve_backup_dir "$backup_dir")"; then
  exit 2
fi
store_dest="$backup_dir/store.${ts}"

if ! file_list="$(find "$memory_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)"; then
  echo "memory-backup: failed to enumerate memory files in $memory_dir" >&2
  exit 2
fi
if [[ -z "$file_list" ]]; then
  echo "memory-backup: no top-level *.md files in $memory_dir" >&2
  exit 2
fi

# Copy into a hidden sibling first. The final name must never exist until every
# file has landed: EXIT traps cannot run after SIGKILL or a host crash, so
# populating store.<ts> directly can publish a partial snapshot that looks
# restorable. A same-parent rename publishes the completed directory atomically.
if [[ -e "$store_dest" || -L "$store_dest" ]]; then
  echo "memory-backup: refusing to overwrite existing snapshot: $store_dest" >&2
  exit 2
fi
if ! store_tmp="$(mktemp -d "$backup_dir/.store.${ts}.XXXXXX")"; then
  echo "memory-backup: failed to create temporary snapshot in $backup_dir" >&2
  exit 2
fi

# The publish lock preserves the old same-timestamp exclusivity without making
# the final path visible early. Racers may each finish a private copy, but only
# one can rename into store.<ts>; every loser removes its unpublished temp tree.
publish_lock=""
trap 'if [[ -n "$store_tmp" && -d "$store_tmp" ]]; then rm -rf "$store_tmp"; fi; if [[ -n "$publish_lock" && -d "$publish_lock" ]]; then rm -rf "$publish_lock"; fi' EXIT

count=0
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  base="$(basename -- "$file")"
  if ! atomic_cp "$file" "$store_tmp/$base"; then
    echo "memory-backup: failed to copy $file into $store_dest" >&2
    exit 2
  fi
  count=$(( count + 1 ))
done <<< "$file_list"

lock_candidate="${store_dest}.publish-lock"
if ! mkdir "$lock_candidate" 2>/dev/null; then
  echo "memory-backup: refusing to overwrite existing or in-progress snapshot: $store_dest" >&2
  exit 2
fi
publish_lock="$lock_candidate"
if [[ -e "$store_dest" || -L "$store_dest" ]]; then
  echo "memory-backup: refusing to overwrite existing snapshot: $store_dest" >&2
  exit 2
fi
if ! mv -- "$store_tmp" "$store_dest"; then
  echo "memory-backup: failed to publish completed snapshot: $store_dest" >&2
  exit 2
fi
store_tmp=""
rm -rf "$publish_lock"
publish_lock=""
trap - EXIT

printf 'Backed up %s file(s) from %s -> %s\n' "$count" "$memory_dir" "$store_dest"
printf 'Restore one file: cp %q/<basename> %q/<basename>\n' "$store_dest" "$memory_dir"
exit 0
