#!/usr/bin/env bash
#
# Reports when the durable-memory content loaded at run start has grown past the
# point where it will be TRUNCATED. The guard supports both author-managed
# Markdown stores and Codex's generated projection layout:
#   - legacy/Claude: MEMORY.md is the index and root topic files are boot inputs;
#   - Codex: memory_summary.md is the boot projection, while MEMORY.md and
#     any temporary consolidation inputs are runtime-managed sources.
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
# a boot-loaded file is still fully readable, not after it has already been cut.
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
# Layout selection is automatic and fail-closed: Codex is identified by its two
# persistent projections, memory_summary.md and MEMORY.md. Temporary inputs such
# as raw_memories.md and rollout_summaries/ are not required. Use --all to show
# runtime-managed files that were deliberately excluded from the boot budget.
#
# Exit codes:
#   0  every boot-loaded file is within its threshold
#   1  at least one boot-loaded file is over threshold
#   2  usage error, or the memory directory does not exist
set -Eeuo pipefail

# ~2.4 bytes/token on this store's prose (74KB measured at ~31k tokens), so 48KB
# lands near 20k tokens — comfortably inside the ~25k cap with headroom for the
# growth a single tick adds.
DEFAULT_THRESHOLD_KB=48
# The run-start index/projection gets a tighter bound than topic files. This is
# MEMORY.md for legacy/Claude stores and memory_summary.md for Codex.
DEFAULT_INDEX_KB=24
LEGACY_INDEX_FILE="MEMORY.md"

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

# Validate as a STRING first, then normalise to base 10. Bash arithmetic treats
# a leading zero as octal, so `--threshold-kb 048` would pass the regex and then
# blow up in every later `(( ))` — and because those failures happen inside the
# scan loop, the script would report "no memory files found" and exit 0, failing
# OPEN with a file sitting right there. Normalising here keeps the arithmetic
# total.
for name in threshold_kb index_kb; do
  v="${!name}"
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "memory-hygiene: thresholds must be positive integers (got '$v')" >&2
    exit 2
  fi
  printf -v "$name" '%d' "$((10#$v))"
  if [[ "${!name}" -le 0 ]]; then
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

# Codex keeps its bounded run-start projection separate from the generated,
# searchable registry. INIT/no-op stores guarantee only these two persistent
# files; raw_memories.md is a temporary consolidation input and rollout
# summaries may not exist yet.
layout="legacy"
index_file="$LEGACY_INDEX_FILE"
if [[ -f "$dir/memory_summary.md" ]]; then
  if [[ ! -f "$dir/$LEGACY_INDEX_FILE" ]]; then
    echo "memory-hygiene: incomplete Codex memory layout: missing $LEGACY_INDEX_FILE" >&2
    exit 2
  fi
  layout="codex"
  index_file="memory_summary.md"
elif [[ -f "$dir/raw_memories.md" || -d "$dir/rollout_summaries" ]]; then
  echo "memory-hygiene: incomplete Codex memory layout: missing memory_summary.md" >&2
  exit 2
fi

if [[ "$layout" == "codex" ]]; then
  summary_version=""
  IFS= read -r summary_version < "$dir/$index_file" || true
  if [[ "$summary_version" != "v1" ]]; then
    echo "memory-hygiene: malformed Codex boot projection: $index_file (expected v1 header)" >&2
    exit 2
  fi
fi

is_runtime_managed_source() {
  [[ "$layout" == "codex" ]] || return 1
  [[ "$(basename "$1")" != "$index_file" ]]
}

over_count=0
checked=0

# Enumerate BEFORE the loop and check the status explicitly. Piping find into
# the loop via process substitution discards its exit status, so a permission
# denial or filesystem error would leave checked=0 and exit 0 — reporting "no
# memory files" and FAILING OPEN on the very case this guard exists to catch.
# A check that silently skips its own target case is worse than no check.
if ! file_list="$(find "$dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null)"; then
  echo "memory-hygiene: failed to enumerate memory files in $dir" >&2
  exit 2
fi

# Sorted for deterministic output (test-stable, diff-friendly across runs).
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  is_archive "$file" && continue
  if is_runtime_managed_source "$file"; then
    if [[ "$show_all" -eq 1 ]]; then
      say "skip                  $(basename "$file") (Codex runtime-managed source)"
    fi
    continue
  fi

  base="$(basename "$file")"
  bytes=$(wc -c < "$file" | tr -d '[:space:]')

  if [[ "$base" == "$index_file" ]]; then
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
done <<< "$(printf '%s' "$file_list" | sort)"

if [[ "$checked" -eq 0 ]]; then
  say "memory-hygiene: no memory files found in $dir"
  exit 0
fi

if [[ "$over_count" -gt 0 ]]; then
  say ""
  if [[ "$layout" == "codex" ]]; then
    say "memory-hygiene: $over_count/$checked boot projection file(s) OVER threshold."
    say "  Refresh the Codex boot projection through the runtime's supported memory-maintenance path."
    say "  Restart the run afterward; this session already received the old projection."
    say "  Do not rewrite MEMORY.md or raw_memories.md; they are runtime-managed sources."
  else
    say "memory-hygiene: $over_count/$checked file(s) OVER threshold — consolidate this tick."
    say "  These will TRUNCATE at run start and silently hide carry-forwards."
    say "  Memory is a multi-writer surface: re-read immediately before writing and"
    say "  prefer a non-clobbering append over a whole-file rewrite."
  fi
  exit 1
fi

say "memory-hygiene: all $checked file(s) within threshold."
exit 0
