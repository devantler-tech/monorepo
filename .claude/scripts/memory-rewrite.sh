#!/usr/bin/env bash
#
# memory-rewrite.sh — fail-closed whole-file rewrite for the shared durable
# memory store (monorepo#2293).
#
# The footgun this closes: agents "surgically" trim a section with
#   s=$(grep -n '^## …' "$f" | cut -d: -f1)
#   { sed -n "1,$((s-1))p" "$f"; echo replacement; } > /tmp/new && mv /tmp/new "$f"
# When grep matches nothing (a sibling restructured the file), s is empty,
# sed gets `1,-1p`, errors and emits nothing, the `{…}` block still produces
# a near-empty stream, and `mv` permanently clobbers an unversioned file.
# Measured 2026-07-20: two independent ticks destroyed learnings.md and
# portfolio-status.md the same day; neither was recoverable.
#
# This helper backs up first, refuses empty/non-positive keep-through bounds,
# refuses empty or drastically-shrunk rebuilds (unless --allow-shrink), refuses
# a rebuild that drops a markdown heading the original had, and only then
# swaps. Prefer a non-clobbering append when you can; use this only when a
# whole-file rewrite is genuinely required.
#
# Usage:
#   memory-rewrite.sh --file <path> --from <new-content-path> [options]
#   memory-rewrite.sh --file <path> --stdin [options]
#   memory-rewrite.sh --file <path> --keep-through <N> --suffix <path> [options]
#
# Options:
#   --allow-shrink          permit a rebuild smaller than --max-shrink-pct of the original
#   --max-shrink-pct N      refuse when new size < (100-N)% of old (default: 50)
#   --backup-dir <dir>      directory for the pre-swap backup (default: same dir as --file)
#
# Exit codes:
#   0  rewrite applied; stdout carries `backup=<path>`
#   1  content refused (empty, shrink, lost heading) — target untouched
#   2  usage / bound error — target untouched
set -Eeuo pipefail

DEFAULT_MAX_SHRINK_PCT=50

file=""
from=""
stdin=0
keep_through=""
suffix=""
allow_shrink=0
max_shrink_pct="$DEFAULT_MAX_SHRINK_PCT"
backup_dir=""

usage() {
  sed -n '/^# Usage:/,/^#   2 /p' "$0" | sed 's/^# \{0,1\}//'
}

fail_usage() {
  echo "memory-rewrite: $*" >&2
  usage >&2
  exit 2
}

fail_content() {
  echo "memory-rewrite: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) file="${2-}"; shift 2 || fail_usage "--file needs a path" ;;
    --from) from="${2-}"; shift 2 || fail_usage "--from needs a path" ;;
    --stdin) stdin=1; shift ;;
    --keep-through) keep_through="${2-}"; shift 2 || fail_usage "--keep-through needs a line number" ;;
    --suffix) suffix="${2-}"; shift 2 || fail_usage "--suffix needs a path" ;;
    --allow-shrink) allow_shrink=1; shift ;;
    --max-shrink-pct) max_shrink_pct="${2-}"; shift 2 || fail_usage "--max-shrink-pct needs an integer" ;;
    --backup-dir) backup_dir="${2-}"; shift 2 || fail_usage "--backup-dir needs a path" ;;
    -h|--help) usage; exit 0 ;;
    *) fail_usage "unknown argument '$1'" ;;
  esac
done

[[ -n "$file" ]] || fail_usage "--file is required"
[[ -f "$file" ]] || fail_usage "target file not found: $file"

# Exactly one content source.
source_count=0
[[ -n "$from" ]] && source_count=$((source_count + 1))
[[ "$stdin" -eq 1 ]] && source_count=$((source_count + 1))
[[ -n "$keep_through" || -n "$suffix" ]] && source_count=$((source_count + 1))
[[ "$source_count" -eq 1 ]] || fail_usage "provide exactly one of --from, --stdin, or --keep-through/--suffix"

if ! [[ "$max_shrink_pct" =~ ^[0-9]+$ ]]; then
  fail_usage "--max-shrink-pct must be a non-negative integer (got '$max_shrink_pct')"
fi
printf -v max_shrink_pct '%d' "$((10#$max_shrink_pct))"
if [[ "$max_shrink_pct" -lt 0 || "$max_shrink_pct" -gt 99 ]]; then
  fail_usage "--max-shrink-pct must be 0..99 (got '$max_shrink_pct')"
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/memory-rewrite.XXXXXX")"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

new_path="$workdir/new"

if [[ -n "$from" ]]; then
  [[ -f "$from" ]] || fail_usage "--from file not found: $from"
  cp "$from" "$new_path"
elif [[ "$stdin" -eq 1 ]]; then
  cat > "$new_path"
else
  # Assemble: lines 1..N of the target + suffix. Bound must be a positive integer —
  # this is the empty-grep failure mode made explicit.
  if [[ -z "$keep_through" ]]; then
    fail_usage "--keep-through is empty or missing (refusing the sed 1,-1p footgun)"
  fi
  # Reject a leading minus before base-10 normalisation — bash `$((10#-3))` is a
  # syntax error and would exit 1 under `set -e` instead of the usage exit 2.
  if [[ "$keep_through" == -* ]]; then
    fail_usage "--keep-through must be >= 1 (got '$keep_through'); refusing empty/non-positive bound"
  fi
  if ! [[ "$keep_through" =~ ^[0-9]+$ ]]; then
    fail_usage "--keep-through must be an integer (got '$keep_through')"
  fi
  # Normalise leading zeros via 10#; reject non-positive.
  printf -v keep_through '%d' "$((10#$keep_through))"
  if [[ "$keep_through" -lt 1 ]]; then
    fail_usage "--keep-through must be >= 1 (got '$keep_through'); refusing empty/non-positive bound"
  fi
  [[ -n "$suffix" ]] || fail_usage "--keep-through requires --suffix"
  [[ -f "$suffix" ]] || fail_usage "--suffix file not found: $suffix"
  target_lines="$(wc -l < "$file" | tr -d '[:space:]')"
  if [[ "$keep_through" -gt "$target_lines" ]]; then
    fail_usage "--keep-through $keep_through exceeds file line count $target_lines"
  fi
  {
    sed -n "1,${keep_through}p" "$file"
    cat "$suffix"
  } > "$new_path"
fi

old_bytes="$(wc -c < "$file" | tr -d '[:space:]')"
new_bytes="$(wc -c < "$new_path" | tr -d '[:space:]')"

if [[ "$new_bytes" -eq 0 ]]; then
  fail_content "refused empty rebuild of $file (new content is 0 bytes); target untouched"
fi

if [[ "$allow_shrink" -eq 0 ]]; then
  # Keep at least (100 - max_shrink_pct)% of the original size.
  min_bytes=$(( old_bytes * (100 - max_shrink_pct) / 100 ))
  # Always require at least 1 byte when old was non-empty (covered above).
  if [[ "$old_bytes" -gt 0 && "$new_bytes" -lt "$min_bytes" ]]; then
    fail_content "refused drastic shrink of $file: new=${new_bytes}B old=${old_bytes}B (below $((100 - max_shrink_pct))% keep); re-run with --allow-shrink if intentional"
  fi
fi

# Structure guard: if the original had a markdown heading, the rebuild must too.
if grep -qE '^#{1,6}[[:space:]]' "$file"; then
  if ! grep -qE '^#{1,6}[[:space:]]' "$new_path"; then
    fail_content "refused rebuild of $file: original had a markdown heading and the new content does not; target untouched"
  fi
fi

# Frontmatter guard: if the original opened with YAML frontmatter, keep it.
if head -n 1 "$file" | grep -qx -- '---'; then
  if ! head -n 1 "$new_path" | grep -qx -- '---'; then
    fail_content "refused rebuild of $file: original had YAML frontmatter and the new content does not; target untouched"
  fi
fi

# Backup first, then atomic-ish replace via temp + mv in the same directory.
if [[ -z "$backup_dir" ]]; then
  backup_dir="$(dirname "$file")"
fi
mkdir -p "$backup_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
base="$(basename "$file")"
backup_path="$backup_dir/${base}.bak.${stamp}.$$"
cp "$file" "$backup_path"

swap="$file.memory-rewrite.$$"
cp "$new_path" "$swap"
mv "$swap" "$file"

printf 'memory-rewrite: ok file=%s backup=%s new_bytes=%s\n' "$file" "$backup_path" "$new_bytes"
exit 0
