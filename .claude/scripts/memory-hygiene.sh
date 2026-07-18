#!/usr/bin/env bash
#
# Reports when a durable-memory file has grown past the point where it will be
# TRUNCATED at run start, so consolidation becomes a signalled, mandated hygiene
# item instead of something a run happens to notice.
#
# Why this exists (monorepo#2223): the memory store is read at the start of every
# run, and the "keep it short" rule lives as prose INSIDE the file it governs —
# visible only to a run that already read it successfully. portfolio-status.md
# has breached the Read cap four times (82KB 07-01, 83KB 07-12, 122KB 07-16,
# 74KB 07-18). Truncation is silent from the agent's perspective: the run
# continues with a partial cursor and no signal that carry-forwards, stand-down
# notes, or HANDS-OFF records beyond the cut are missing. That exact blinding
# caused a documented misstep on 2026-06-05.
#
# Thresholds sit BELOW the Read tool's ~25k-token cap so the warning fires while
# the file is still fully readable, not after it has already been cut.
#
# STRICTLY READ-ONLY: this reports and exits. It never edits, rewrites, prunes,
# or deletes memory. Consolidation is a judgement call that needs the agent's
# full context (what is still an open carry-forward vs. a merged one), and — as
# the 778th run found — memory is a multi-writer surface where a whole-file
# rewrite can clobber a sibling instance's concurrent append. Prefer appending.
#
# Usage:
#   memory-hygiene.sh [--dir <memory-dir>] [--threshold-kb N] [--index-kb N]
#                     [--all] [--quiet]
#
# By default only OVER-threshold and near-threshold (>=90%) files are listed, so
# a run-start step stays readable on a store of ~100 files. --all lists every
# file; --quiet suppresses output entirely and reports via the exit code alone.
#
# Exit codes:
#   0  every checked file is within its threshold
#   1  at least one file is over threshold (consolidate it this tick)
#   2  usage error, or the memory directory does not exist
set -Eeuo pipefail

# ~2.4 bytes/token on this store's prose (74KB measured at ~31k tokens), so 48KB
# lands near 20k tokens — comfortably inside the ~25k cap with headroom for the
# growth a single tick adds.
DEFAULT_THRESHOLD_KB=48
# MEMORY.md is the INDEX every run reads first and is required to be one short
# line per entry, so it gets a tighter bound than the topic files it points at.
DEFAULT_INDEX_KB=24
INDEX_FILE="MEMORY.md"

dir=""
threshold_kb="$DEFAULT_THRESHOLD_KB"
index_kb="$DEFAULT_INDEX_KB"
quiet=0
show_all=0

usage() {
  sed -n '/^# Usage:/,/^#   2 /p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="${2-}"; shift 2 || exit 2 ;;
    --threshold-kb) threshold_kb="${2-}"; shift 2 || exit 2 ;;
    --index-kb) index_kb="${2-}"; shift 2 || exit 2 ;;
    --all) show_all=1; shift ;;
    --quiet) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "memory-hygiene: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

for v in "$threshold_kb" "$index_kb"; do
  if ! [[ "$v" =~ ^[0-9]+$ ]] || [[ "$v" -eq 0 ]]; then
    echo "memory-hygiene: thresholds must be positive integers (got '$v')" >&2
    exit 2
  fi
done

if [[ -z "$dir" ]]; then
  echo "memory-hygiene: --dir is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -d "$dir" ]]; then
  echo "memory-hygiene: memory directory not found: $dir" >&2
  exit 2
fi

say() { [[ "$quiet" -eq 1 ]] || printf '%s\n' "$*"; }

# Archives are deliberately large and are explicitly NOT read at run start
# ("consult only if a topic file proves to be missing something"), so holding
# them to the run-start budget would report a permanent, un-actionable failure.
is_archive() { [[ "$(basename "$1")" == *archive* ]]; }

over_count=0
checked=0

# Sorted for deterministic output (test-stable, diff-friendly across runs).
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  is_archive "$file" && continue

  base="$(basename "$file")"
  bytes=$(wc -c < "$file" | tr -d '[:space:]')

  if [[ "$base" == "$INDEX_FILE" ]]; then
    limit_kb="$index_kb"
  else
    limit_kb="$threshold_kb"
  fi
  limit_bytes=$(( limit_kb * 1024 ))

  checked=$(( checked + 1 ))
  kb=$(( (bytes + 1023) / 1024 ))

  if [[ "$bytes" -gt "$limit_bytes" ]]; then
    over_count=$(( over_count + 1 ))
    say "$(printf 'OVER %5sK / %3sK  %s' "$kb" "$limit_kb" "$base")"
  elif [[ "$show_all" -eq 1 ]]; then
    say "$(printf 'ok   %5sK / %3sK  %s' "$kb" "$limit_kb" "$base")"
  elif [[ $(( bytes * 100 / limit_bytes )) -ge 90 ]]; then
    # Near-limit files are the ones about to become next tick's breach, so they
    # are worth surfacing even in the quiet default view.
    say "$(printf 'near %5sK / %3sK  %s' "$kb" "$limit_kb" "$base")"
  fi
done < <(find "$dir" -maxdepth 1 -type f -name '*.md' | sort)

if [[ "$checked" -eq 0 ]]; then
  say "memory-hygiene: no memory files found in $dir"
  exit 0
fi

if [[ "$over_count" -gt 0 ]]; then
  say ""
  say "memory-hygiene: $over_count/$checked file(s) OVER threshold — consolidate this tick."
  say "  These will TRUNCATE at run start and silently hide carry-forwards."
  say "  Memory is a multi-writer surface: re-read immediately before writing and"
  say "  prefer a non-clobbering append over a whole-file rewrite."
  exit 1
fi

say "memory-hygiene: all $checked file(s) within threshold."
exit 0
