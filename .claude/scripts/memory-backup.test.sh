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

# ---------------------------------------------------------------------------
# Two instances racing for the SAME destination: exactly one may win.
#
# The store is multi-writer, so two runs can select an identical backup path
# (same basename, same --backup-dir, same second). Both clear the `-e` check
# long before either finishes copying, so the publish step is what has to
# exclude — a plain rename lets the slower one silently replace the winner's
# backup and both report success.
#
# The sources are large enough that both pre-checks provably complete before
# either copy does, so the interleaving is forced rather than hoped for.
# ---------------------------------------------------------------------------
race_a="$tmp/race-a"
race_b="$tmp/race-b"
race_backups="$tmp/race-backups"
mkdir -p "$race_a" "$race_b"
# ~16 MB each, distinguishable by content.
awk 'BEGIN { s = sprintf("%0*d", 1023, 0); for (i = 0; i < 16384; i++) print "A" s }' \
  > "$race_a/learnings.md"
awk 'BEGIN { s = sprintf("%0*d", 1023, 0); for (i = 0; i < 16384; i++) print "B" s }' \
  > "$race_b/learnings.md"
export MEMORY_BACKUP_TS=20260724T003003Z
race_dest="$race_backups/learnings.md.${MEMORY_BACKUP_TS}"

"$tool" --backup-dir "$race_backups" "$race_a/learnings.md" >/dev/null 2>&1 &
pid_a=$!
"$tool" --backup-dir "$race_backups" "$race_b/learnings.md" >/dev/null 2>&1 &
pid_b=$!
rc_a=0; wait "$pid_a" || rc_a=$?
rc_b=0; wait "$pid_b" || rc_b=$?

# `cond && incr` would abort the whole test under `set -e` on the false branch.
winners=0
if [[ "$rc_a" -eq 0 ]]; then winners=$(( winners + 1 )); fi
if [[ "$rc_b" -eq 0 ]]; then winners=$(( winners + 1 )); fi
check "concurrent same-destination backups: exactly one wins" "1" "$winners"

# Whichever won, the published backup must be byte-identical to ITS source —
# never a clobbered or interleaved mixture.
if [[ -f "$race_dest" ]]; then
  race_sum="$(shasum "$race_dest" | awk '{print $1}')"
  sum_a="$(shasum "$race_a/learnings.md" | awk '{print $1}')"
  sum_b="$(shasum "$race_b/learnings.md" | awk '{print $1}')"
  if [[ "$race_sum" == "$sum_a" || "$race_sum" == "$sum_b" ]]; then
    pass "surviving backup is one intact source, not a mixture"
  else
    fail "surviving backup is one intact source, not a mixture"
  fi
else
  fail "surviving backup is one intact source, not a mixture (no backup published)"
fi

# No temp scratch may be left behind by either racer.
leftovers="$(find "$race_backups" -maxdepth 1 -name '.memory-backup.*' | wc -l | tr -d ' ')"
check "publish race leaves no temp files behind" "0" "$leftovers"

rm -rf "$race_a" "$race_b" "$race_backups"

# ---------------------------------------------------------------------------
# A failed --all run must leave NO snapshot directory behind.
#
# A half-populated store.<ts> is indistinguishable from a complete one, so a
# later restore silently recovers a subset of the store — and the directory
# also blocks a retry at that timestamp.
# ---------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  pass "failed --all leaves no partial snapshot (skipped: running as root)"
else
  partial="$tmp/partial"
  mkdir -p "$partial"
  printf 'first\n'  > "$partial/AAA-readable.md"
  printf 'second\n' > "$partial/ZZZ-unreadable.md"
  # Enumeration sorts, so the readable file is copied first and the snapshot is
  # already non-empty when the unreadable one fails.
  chmod 000 "$partial/ZZZ-unreadable.md"
  export MEMORY_BACKUP_TS=20260724T003004Z
  partial_rc="$(run --all "$partial")"
  chmod 644 "$partial/ZZZ-unreadable.md"

  if [[ "$partial_rc" == "0" ]]; then
    fail "failed --all exits non-zero (got 0 — the unreadable source did not fail the copy)"
  else
    pass "failed --all exits non-zero"
  fi
  partial_snap="$partial/.memory-backups/store.${MEMORY_BACKUP_TS}"
  if [[ -e "$partial_snap" ]]; then
    fail "failed --all leaves no partial snapshot (found $partial_snap)"
  else
    pass "failed --all leaves no partial snapshot"
  fi
fi

if [[ "$failures" -eq 0 ]]; then
  printf '\nAll memory-backup self-tests passed.\n'
  exit 0
fi
printf '\n%d memory-backup self-test(s) FAILED.\n' "$failures"
exit 1
