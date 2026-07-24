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
    --) shift; break ;;
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

# Copy via a temp name in the destination dir, then rename — so a crash mid-copy
# never leaves a partial file that looks like a successful backup.
atomic_cp() {
  local src="$1" dest="$2"
  local dest_dir tmp
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir"
  tmp="$(mktemp "$dest_dir/.memory-backup.XXXXXX")"
  # mktemp creates an empty file; replace it with the source contents.
  cp -p "$src" "$tmp"
  mv -f "$tmp" "$dest"
}

if [[ "$mode" == "file" ]]; then
  if [[ ! -f "$target" ]]; then
    echo "memory-backup: not a readable file: $target" >&2
    exit 2
  fi
  parent="$(cd "$(dirname "$target")" && pwd)"
  base="$(basename "$target")"
  if [[ -z "$backup_dir" ]]; then
    backup_dir="$parent/.memory-backups"
  fi
  dest="$backup_dir/${base}.${ts}"
  if [[ -e "$dest" ]]; then
    echo "memory-backup: refusing to overwrite existing backup: $dest" >&2
    exit 2
  fi
  atomic_cp "$target" "$dest"
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
memory_dir="$(cd "$target" && pwd)"
if [[ -z "$backup_dir" ]]; then
  backup_dir="$memory_dir/.memory-backups"
fi
store_dest="$backup_dir/store.${ts}"
if [[ -e "$store_dest" ]]; then
  echo "memory-backup: refusing to overwrite existing snapshot: $store_dest" >&2
  exit 2
fi

if ! file_list="$(find "$memory_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)"; then
  echo "memory-backup: failed to enumerate memory files in $memory_dir" >&2
  exit 2
fi
if [[ -z "$file_list" ]]; then
  echo "memory-backup: no top-level *.md files in $memory_dir" >&2
  exit 2
fi

mkdir -p "$store_dest"
count=0
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  base="$(basename "$file")"
  atomic_cp "$file" "$store_dest/$base"
  count=$(( count + 1 ))
done <<< "$file_list"

printf 'Backed up %s file(s) from %s -> %s\n' "$count" "$memory_dir" "$store_dest"
printf 'Restore one file: cp %q/<basename> %q/<basename>\n' "$store_dest" "$memory_dir"
exit 0
