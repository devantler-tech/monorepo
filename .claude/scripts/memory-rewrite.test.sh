#!/usr/bin/env bash
#
# Self-test for memory-rewrite.sh — RED-proves the two real clobber modes from
# monorepo#2293: an empty/non-positive keep-through bound (the sed `1,-1p`
# footgun), and a rebuild that is empty or drastically smaller than the
# original. Also asserts backups are written and reported, and that an
# intentional shrink needs --allow-shrink.
#
# Fixtures are throwaway files in a temp dir — no real memory touched.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$script_dir/memory-rewrite.sh"

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

run() { local rc=0; "$tool" "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# ---------------------------------------------------------------------------
# Happy path: full rewrite from --from keeps content and reports a backup.
# ---------------------------------------------------------------------------
target="$tmp/happy.md"
printf '%s\n' '---' 'version: 1' '---' '# Notes' '' 'old body line' > "$target"
new="$tmp/happy-new.md"
printf '%s\n' '---' 'version: 1' '---' '# Notes' '' 'new body line' 'another' > "$new"
rc=0
out="$("$tool" --file "$target" --from "$new" 2>&1)" || rc=$?
check "happy rewrite exit code" "0" "$rc"
if grep -q 'new body line' "$target" && grep -q '# Notes' "$target"; then
  pass "happy rewrite installs new content"
else
  fail "happy rewrite installs new content"
fi
if grep -q 'backup=' <<<"$out"; then
  pass "happy rewrite reports backup= path"
  bak="$(sed -n 's/.*backup=//p' <<<"$out" | awk '{print $1}' | head -1)"
  if [[ -f "$bak" ]] && grep -q 'old body line' "$bak"; then
    pass "backup file preserves prior content"
  else
    fail "backup file preserves prior content (bak='$bak')"
  fi
else
  fail "happy rewrite reports backup= path (got: $out)"
fi

# ---------------------------------------------------------------------------
# RED case 1: empty / non-positive --keep-through bound must refuse BEFORE
# touching the target (the empty-grep → sed 1,-1p clobber).
# ---------------------------------------------------------------------------
target="$tmp/bound.md"
printf '%s\n' '# Heading' 'line2' 'line3' 'line4' 'line5' > "$target"
before="$(cat "$target")"
suffix="$tmp/suffix.md"
printf '%s\n' 'replacement section' > "$suffix"

rc=0
out="$("$tool" --file "$target" --keep-through '' --suffix "$suffix" 2>&1)" || rc=$?
check "empty keep-through exits non-zero" "2" "$rc"
check "empty keep-through leaves target untouched" "$before" "$(cat "$target")"
if grep -qi 'keep-through' <<<"$out"; then
  pass "empty keep-through names the bound in the error"
else
  fail "empty keep-through names the bound in the error (got: $out)"
fi

rc=0
out="$("$tool" --file "$target" --keep-through 0 --suffix "$suffix" 2>&1)" || rc=$?
check "zero keep-through exits non-zero" "2" "$rc"
check "zero keep-through leaves target untouched" "$before" "$(cat "$target")"

rc=0
out="$("$tool" --file "$target" --keep-through -3 --suffix "$suffix" 2>&1)" || rc=$?
check "negative keep-through exits non-zero" "2" "$rc"
check "negative keep-through leaves target untouched" "$before" "$(cat "$target")"

# ---------------------------------------------------------------------------
# RED case 2: empty / near-empty rebuild must refuse (the sed-error → empty
# `{…}` block still producing output, then mv clobber).
# ---------------------------------------------------------------------------
target="$tmp/empty-rebuild.md"
{
  printf '%s\n' '---' 'version: 1' '---' '# Portfolio status'
  local_i=0
  for (( local_i = 0; local_i < 40; local_i++ )); do
    printf 'tick note line %s with enough bytes to matter for shrink detection\n' "$local_i"
  done
} > "$target"
before="$(cat "$target")"
empty_new="$tmp/empty-new.md"
: > "$empty_new"

rc=0
out="$("$tool" --file "$target" --from "$empty_new" 2>&1)" || rc=$?
check "empty rebuild exits non-zero" "1" "$rc"
check "empty rebuild leaves target untouched" "$before" "$(cat "$target")"
if grep -qiE 'empty|refuse|rejected' <<<"$out"; then
  pass "empty rebuild error mentions refusal"
else
  fail "empty rebuild error mentions refusal (got: $out)"
fi

tiny_new="$tmp/tiny-new.md"
# Keep frontmatter + heading so only the shrink guard fires (not structure).
printf '%s\n' '---' 'version: 1' '---' '# Portfolio status' 'x' > "$tiny_new"
rc=0
out="$("$tool" --file "$target" --from "$tiny_new" 2>&1)" || rc=$?
check "drastic shrink exits non-zero by default" "1" "$rc"
check "drastic shrink leaves target untouched" "$before" "$(cat "$target")"
if grep -qiE 'shrink|smaller|allow-shrink' <<<"$out"; then
  pass "drastic shrink error mentions shrink / allow-shrink"
else
  fail "drastic shrink error mentions shrink / allow-shrink (got: $out)"
fi

# Opt-in shrink is allowed when explicitly requested (and still backs up).
rc=0
out="$("$tool" --file "$target" --from "$tiny_new" --allow-shrink 2>&1)" || rc=$?
check "allow-shrink permits intentional shrink" "0" "$rc"
if grep -q '^# Portfolio status$' "$target" && grep -q 'backup=' <<<"$out"; then
  pass "allow-shrink installs tiny content with backup"
else
  fail "allow-shrink installs tiny content with backup (got out: $out / file: $(cat "$target"))"
fi

# ---------------------------------------------------------------------------
# keep-through assemble path succeeds with a positive bound.
# ---------------------------------------------------------------------------
target="$tmp/assemble.md"
printf '%s\n' '# Heading' 'keep-me-1' 'keep-me-2' 'drop-me' 'drop-me-2' > "$target"
suffix="$tmp/suffix2.md"
printf '%s\n' '## Replacement' 'fresh content' > "$suffix"
rc=0
out="$("$tool" --file "$target" --keep-through 3 --suffix "$suffix" 2>&1)" || rc=$?
check "assemble with positive keep-through exits 0" "0" "$rc"
if grep -q 'keep-me-2' "$target" && grep -q 'fresh content' "$target" && ! grep -q 'drop-me' "$target"; then
  pass "assemble keeps prefix and appends suffix"
else
  fail "assemble keeps prefix and appends suffix (got: $(cat "$target"))"
fi

# ---------------------------------------------------------------------------
# Structure guard: original had a markdown heading; new content without one
# is refused.
# ---------------------------------------------------------------------------
target="$tmp/heading.md"
printf '%s\n' '# Real heading' 'body body body body body body body body' > "$target"
before="$(cat "$target")"
nohead="$tmp/nohead.md"
printf '%s\n' 'just prose with no heading at all, padded enough not to trip shrink alone.......' > "$nohead"
rc=0
out="$("$tool" --file "$target" --from "$nohead" 2>&1)" || rc=$?
check "lost heading exits non-zero" "1" "$rc"
check "lost heading leaves target untouched" "$before" "$(cat "$target")"

# ---------------------------------------------------------------------------
# Usage errors.
# ---------------------------------------------------------------------------
check "missing --file exits 2" "2" "$(run --from "$new")"
check "missing content source exits 2" "2" "$(run --file "$tmp/happy.md")"

# ---------------------------------------------------------------------------
if [[ "$failures" -eq 0 ]]; then
  printf '\nAll memory-rewrite tests passed.\n'
  exit 0
fi
printf '\n%d memory-rewrite test(s) FAILED.\n' "$failures"
exit 1
