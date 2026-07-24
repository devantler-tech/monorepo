#!/usr/bin/env bash
#
# Self-test for memory-backup.sh — proves a destructive-edit precursor actually
# lands a recoverable copy (monorepo#2304), that --all snapshots the whole
# top-level store, that an existing backup is never overwritten, and that the
# source file is left byte-identical.
#
# Fixtures are throwaway files in a temp dir — no real memory touched.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$script_dir/memory-backup.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; failures=$(( failures + 1 )); }

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$desc"; else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

# Capture exit code without tripping set -e on an expected failure.
run() { local rc=0; "$tool" "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

export MEMORY_BACKUP_TS=20260724T003000Z

# ---------------------------------------------------------------------------
# Single-file backup lands under .memory-backups/ with the pinned timestamp,
# prints a restore command, and leaves the source untouched.
# ---------------------------------------------------------------------------
store="$tmp/single"
mkdir -p "$store"
printf 'keep-me learnings theme\n' > "$store/learnings.md"
before="$(shasum "$store/learnings.md" | awk '{print $1}')"
rc=0
out="$("$tool" "$store/learnings.md" 2>&1)" || rc=$?
check "single-file backup exits 0" "0" "$rc"

dest="$store/.memory-backups/learnings.md.${MEMORY_BACKUP_TS}"
if [[ -f "$dest" ]]; then
  pass "timestamped backup file exists"
else
  fail "timestamped backup file exists (missing $dest)"
fi
check "backup content matches source" "$(cat "$store/learnings.md")" "$(cat "$dest")"
check "source unchanged after backup" "$before" "$(shasum "$store/learnings.md" | awk '{print $1}')"
if grep -q "Restore: cp" <<<"$out"; then
  pass "stdout carries a restore command"
else
  fail "stdout carries a restore command (got: $out)"
fi

# ---------------------------------------------------------------------------
# A second backup at the same timestamp must REFUSE to overwrite (fail closed).
# ---------------------------------------------------------------------------
check "refuses to overwrite existing backup" "2" "$(run "$store/learnings.md")"

# ---------------------------------------------------------------------------
# --all snapshots every top-level *.md, including archives.
# ---------------------------------------------------------------------------
store="$tmp/all"
mkdir -p "$store"
printf 'a\n' > "$store/MEMORY.md"
printf 'b\n' > "$store/learnings.md"
printf 'c\n' > "$store/learnings-archive-2026-07-12.md"
export MEMORY_BACKUP_TS=20260724T003001Z
rc=0
out="$("$tool" --all "$store" 2>&1)" || rc=$?
check "--all exits 0" "0" "$rc"
snap="$store/.memory-backups/store.${MEMORY_BACKUP_TS}"
if [[ -d "$snap" ]]; then
  pass "whole-store snapshot directory exists"
else
  fail "whole-store snapshot directory exists"
fi
check "snapshot includes MEMORY.md" "a" "$(cat "$snap/MEMORY.md")"
check "snapshot includes learnings.md" "b" "$(cat "$snap/learnings.md")"
check "snapshot includes archive" "c" "$(cat "$snap/learnings-archive-2026-07-12.md")"
if grep -q "3 file" <<<"$out"; then
  pass "--all reports file count"
else
  fail "--all reports file count (got: $out)"
fi

# ---------------------------------------------------------------------------
# Usage / missing source → exit 2 (distinct from success).
# ---------------------------------------------------------------------------
check "no args exits 2" "2" "$(run)"
check "missing file exits 2" "2" "$(run "$tmp/does-not-exist.md")"
check "missing dir with --all exits 2" "2" "$(run --all "$tmp/no-such-dir")"

empty="$tmp/empty"
mkdir -p "$empty"
check "empty store with --all exits 2" "2" "$(run --all "$empty")"

# ---------------------------------------------------------------------------
# Custom --backup-dir is honoured.
# ---------------------------------------------------------------------------
store="$tmp/custom"
alt="$tmp/alt-backups"
mkdir -p "$store"
printf 'x\n' > "$store/portfolio-status.md"
export MEMORY_BACKUP_TS=20260724T003002Z
check "custom --backup-dir exits 0" "0" "$(run --backup-dir "$alt" "$store/portfolio-status.md")"
if [[ -f "$alt/portfolio-status.md.${MEMORY_BACKUP_TS}" ]]; then
  pass "backup lands in --backup-dir"
else
  fail "backup lands in --backup-dir"
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\nAll memory-backup self-tests passed.\n'
  exit 0
fi
printf '\n%d memory-backup self-test(s) FAILED.\n' "$failures"
exit 1
