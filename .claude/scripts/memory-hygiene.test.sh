#!/usr/bin/env bash
#
# Self-test for memory-hygiene.sh — proves the guard actually FIRES on an
# over-cap memory file (the whole point: portfolio-status.md truncated at run
# start four times while an advisory prose rule sat inside it), that a
# within-budget store stays silent, that the MEMORY.md index is held to its own
# tighter bound, that deliberately-large archives are exempt, and that the tool
# never mutates the store it inspects.
#
# The mutation assertion is the important one: a memory guard that "helpfully"
# rewrote a file could clobber a sibling instance's concurrent append — the exact
# collision the 778th run hit and stood down from.
#
# Fixtures are throwaway files in a temp dir — no real memory touched.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$script_dir/memory-hygiene.sh"

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

# Writes a file of approximately N kilobytes.
mkfile() {
  local path="$1" kb="$2"
  : > "$path"
  local i
  for (( i = 0; i < kb; i++ )); do
    printf '%1024s\n' '' >> "$path"
  done
}

# Capture the exit code explicitly: a bare `run ...` call must not let the tool's
# (expected) non-zero status trip `set -e` and abort the suite mid-way.
run() { local rc=0; "$tool" "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
run_out() { "$tool" "$@" 2>&1 || true; }

# ---------------------------------------------------------------------------
# A store comfortably inside budget passes.
# ---------------------------------------------------------------------------
store="$tmp/under"
mkdir -p "$store"
mkfile "$store/portfolio-status.md" 10
mkfile "$store/learnings.md" 10
mkfile "$store/MEMORY.md" 5
check "under-threshold store exits 0" "0" "$(run --dir "$store")"

# ---------------------------------------------------------------------------
# RED case: an over-cap topic file must FIRE. This is the regression that
# matters — if this ever returns 0, the guard has stopped guarding.
# ---------------------------------------------------------------------------
store="$tmp/over"
mkdir -p "$store"
mkfile "$store/portfolio-status.md" 80   # the 74KB 2026-07-18 breach, rounded up
mkfile "$store/MEMORY.md" 5
check "over-threshold topic file exits 1" "1" "$(run --dir "$store")"

out="$(run_out --dir "$store")"
if grep -q "OVER" <<<"$out" && grep -q "portfolio-status.md" <<<"$out"; then
  pass "over-threshold file is named in the report"
else
  fail "over-threshold file is named in the report (got: $out)"
fi
if grep -qi "append" <<<"$out"; then
  pass "report carries the multi-writer append guidance"
else
  fail "report carries the multi-writer append guidance"
fi

# ---------------------------------------------------------------------------
# The index is held to a TIGHTER bound than topic files: a MEMORY.md that would
# pass as a topic file must still fail as an index.
# ---------------------------------------------------------------------------
store="$tmp/index"
mkdir -p "$store"
mkfile "$store/MEMORY.md" 30             # under 48K topic bound, over 24K index bound
check "oversized MEMORY.md index exits 1" "1" "$(run --dir "$store")"

store="$tmp/index-ok"
mkdir -p "$store"
mkfile "$store/MEMORY.md" 30
check "index bound is configurable" "0" "$(run --dir "$store" --index-kb 48)"

# ---------------------------------------------------------------------------
# Archives are deliberately huge and are NOT read at run start — holding them to
# the budget would report a permanent, un-actionable failure.
# ---------------------------------------------------------------------------
store="$tmp/archive"
mkdir -p "$store"
mkfile "$store/portfolio-status-archive-2026-07-16.md" 200
mkfile "$store/learnings-archive-2026-07-12.md" 200
check "archives are exempt" "0" "$(run --dir "$store")"

# ---------------------------------------------------------------------------
# Non-markdown files and nested dirs are out of scope.
# ---------------------------------------------------------------------------
store="$tmp/scope"
mkdir -p "$store/nested"
mkfile "$store/manifest.tsv" 200
mkfile "$store/nested/deep.md" 200
check "non-markdown and nested files are out of scope" "0" "$(run --dir "$store")"

# ---------------------------------------------------------------------------
# READ-ONLY: the store must be byte-identical after a run that reports failure.
# ---------------------------------------------------------------------------
store="$tmp/readonly"
mkdir -p "$store"
mkfile "$store/portfolio-status.md" 80
before="$(find "$store" -type f -exec shasum {} \; | sort)"
run --dir "$store" >/dev/null
after="$(find "$store" -type f -exec shasum {} \; | sort)"
check "store is unmodified by a failing run" "$before" "$after"

# ---------------------------------------------------------------------------
# Usage errors are distinguishable from a threshold breach (exit 2, not 1), so a
# run-loop step can tell "misconfigured" from "consolidate now".
# ---------------------------------------------------------------------------
check "missing --dir exits 2" "2" "$(run)"
check "nonexistent dir exits 2" "2" "$(run --dir "$tmp/does-not-exist")"
check "non-numeric threshold exits 2" "2" "$(run --dir "$tmp/under" --threshold-kb abc)"
check "zero threshold exits 2" "2" "$(run --dir "$tmp/under" --threshold-kb 0)"
check "unknown flag exits 2" "2" "$(run --dir "$tmp/under" --bogus)"

# ---------------------------------------------------------------------------
# FAIL CLOSED when the store cannot be enumerated. Process substitution discards
# find's exit status, so an enumeration failure would otherwise look identical
# to "no memory files" and exit 0 — fail-open on the guard's own target case.
# A `find` shim that fails stands in for a permission/filesystem denial.
# ---------------------------------------------------------------------------
shim="$tmp/shim"
mkdir -p "$shim"
cat > "$shim/find" <<'SHIM'
#!/usr/bin/env bash
echo "find: simulated enumeration failure" >&2
exit 1
SHIM
chmod +x "$shim/find"
shim_rc=0
PATH="$shim:$PATH" "$tool" --dir "$tmp/under" >/dev/null 2>&1 || shim_rc=$?
check "enumeration failure fails CLOSED (exit 2, not 0)" "2" "$shim_rc"

# ---------------------------------------------------------------------------
# An empty store is not an error — a fresh deployment has no memory yet.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/empty"
check "empty store exits 0" "0" "$(run --dir "$tmp/empty")"

# ---------------------------------------------------------------------------
# Default view is SIGNAL-ONLY: on a ~100-file store, listing every file buries
# the breach. Only OVER and near-threshold entries show unless --all is given.
# ---------------------------------------------------------------------------
store="$tmp/view"
mkdir -p "$store"
mkfile "$store/portfolio-status.md" 80   # OVER
mkfile "$store/caches.md" 46             # near (>=90% of 48K)
mkfile "$store/small-topic.md" 4         # quiet
out="$(run_out --dir "$store")"
if grep -q "portfolio-status.md" <<<"$out"; then
  pass "default view lists the OVER file"
else fail "default view lists the OVER file (got: $out)"; fi
if grep -q "near.*caches.md" <<<"$out"; then
  pass "default view warns on a near-threshold file"
else fail "default view warns on a near-threshold file (got: $out)"; fi
if grep -q "small-topic.md" <<<"$out"; then
  fail "default view stays quiet about healthy files (got: $out)"
else pass "default view stays quiet about healthy files"; fi

out="$(run_out --dir "$store" --all)"
if grep -q "small-topic.md" <<<"$out"; then
  pass "--all lists healthy files too"
else fail "--all lists healthy files too (got: $out)"; fi
check "--all does not change the exit code" "1" "$(run --dir "$store" --all)"

# ---------------------------------------------------------------------------
# --quiet suppresses the report but preserves the exit code (for run-loop use).
# ---------------------------------------------------------------------------
check "--quiet preserves the failing exit code" "1" "$(run --dir "$tmp/over" --quiet)"
if [[ -z "$("$tool" --dir "$tmp/over" --quiet 2>&1 || true)" ]]; then
  pass "--quiet emits no output"
else
  fail "--quiet emits no output"
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
