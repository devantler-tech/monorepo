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

# Byte-exact "the tool left this file alone" assertion. A `"$(cat …)"` capture
# strips trailing newlines on BOTH sides, so a refused rewrite that changed only
# trailing newline bytes would satisfy a string comparison — precisely the
# clobber these guards exist to catch. Compare the file against a pristine copy
# instead, the same way the backup assertion above does.
check_unchanged() {
  local desc="$1" reference="$2" target="$3"
  if cmp -s "$reference" "$target"; then pass "$desc"; else
    fail "$desc (target no longer byte-identical to its pre-run copy)"
  fi
}

run() { local rc=0; "$tool" "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# ---------------------------------------------------------------------------
# Happy path: full rewrite from --from keeps content and reports a backup.
# ---------------------------------------------------------------------------
target="$tmp/happy.md"
printf '%s\n' '---' 'version: 1' '---' '# Notes' '' 'old body line' > "$target"
# Keep a pristine copy: the backup assertion below compares bytes, because a
# substring check passes on a backup that carried the probe line and lost
# everything else — which is the failure a backup exists to prevent.
happy_original="$tmp/happy-original.md"
cp "$target" "$happy_original"
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
  if [[ -f "$bak" ]] && cmp -s "$happy_original" "$bak"; then
    pass "backup file is byte-identical to the pre-rewrite target"
  else
    fail "backup file is byte-identical to the pre-rewrite target (bak='$bak')"
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
bound_original="$tmp/bound-original.md"
cp "$target" "$bound_original"
suffix="$tmp/suffix.md"
printf '%s\n' 'replacement section' > "$suffix"

rc=0
out="$("$tool" --file "$target" --keep-through '' --suffix "$suffix" 2>&1)" || rc=$?
check "empty keep-through exits non-zero" "2" "$rc"
check_unchanged "empty keep-through leaves target untouched" "$bound_original" "$target"
if grep -qi 'keep-through' <<<"$out"; then
  pass "empty keep-through names the bound in the error"
else
  fail "empty keep-through names the bound in the error (got: $out)"
fi

rc=0
out="$("$tool" --file "$target" --keep-through 0 --suffix "$suffix" 2>&1)" || rc=$?
check "zero keep-through exits non-zero" "2" "$rc"
check_unchanged "zero keep-through leaves target untouched" "$bound_original" "$target"

rc=0
out="$("$tool" --file "$target" --keep-through -3 --suffix "$suffix" 2>&1)" || rc=$?
check "negative keep-through exits non-zero" "2" "$rc"
check_unchanged "negative keep-through leaves target untouched" "$bound_original" "$target"

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
rebuild_original="$tmp/empty-rebuild-original.md"
cp "$target" "$rebuild_original"
empty_new="$tmp/empty-new.md"
: > "$empty_new"

rc=0
out="$("$tool" --file "$target" --from "$empty_new" 2>&1)" || rc=$?
check "empty rebuild exits non-zero" "1" "$rc"
check_unchanged "empty rebuild leaves target untouched" "$rebuild_original" "$target"
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
check_unchanged "drastic shrink leaves target untouched" "$rebuild_original" "$target"
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
heading_original="$tmp/heading-original.md"
cp "$target" "$heading_original"
nohead="$tmp/nohead.md"
printf '%s\n' 'just prose with no heading at all, padded enough not to trip shrink alone.......' > "$nohead"
rc=0
out="$("$tool" --file "$target" --from "$nohead" 2>&1)" || rc=$?
check "lost heading exits non-zero" "1" "$rc"
check_unchanged "lost heading leaves target untouched" "$heading_original" "$target"

# ---------------------------------------------------------------------------
# Frontmatter guard: original opened with YAML frontmatter; a replacement that
# keeps a heading but drops the frontmatter is refused.
#
# Distinct from the heading guard above — this replacement HAS a heading, so
# only the frontmatter check can reject it.
# ---------------------------------------------------------------------------
target="$tmp/frontmatter.md"
printf '%s\n' '---' 'name: notes' '---' '# Real heading' 'body body body body body body body' > "$target"
fm_guard_original="$tmp/frontmatter-original.md"
cp "$target" "$fm_guard_original"
nofm="$tmp/nofm.md"
printf '%s\n' '# Real heading' 'body body body body body body body body body body body' > "$nofm"
rc=0
out="$("$tool" --file "$target" --from "$nofm" 2>&1)" || rc=$?
check "lost frontmatter exits non-zero" "1" "$rc"
check_unchanged "lost frontmatter leaves target untouched" "$fm_guard_original" "$target"

# ---------------------------------------------------------------------------
# Happy path via --stdin. The other --stdin fixture below only ever exercises
# the REJECTION path, so without this the success path of a whole input mode
# goes untested — and a silent corruption there would land straight in an
# unversioned store. Asserts the replacement is installed byte-exactly and the
# backup still matches the pre-rewrite original.
# ---------------------------------------------------------------------------
target="$tmp/stdin-happy.md"
printf '%s\n' '---' 'version: 1' '---' '# Notes' '' 'original stdin body' 'padding so the shrink guard is not what rejects this' > "$target"
stdin_original="$tmp/stdin-happy-original.md"
cp "$target" "$stdin_original"
stdin_new="$tmp/stdin-happy-new.md"
printf '%s\n' '---' 'version: 1' '---' '# Notes' '' 'rewritten stdin body' 'padding so the shrink guard is not what rejects this' > "$stdin_new"
rc=0
out="$("$tool" --file "$target" --stdin < "$stdin_new" 2>&1)" || rc=$?
check "stdin rewrite exit code" "0" "$rc"
# Byte-exact, not a grep: a substring check passes on a truncated write that
# happens to retain the probe line, which is the corruption that matters here.
check_unchanged "stdin rewrite installs the piped content byte-for-byte" "$stdin_new" "$target"
if grep -q 'backup=' <<<"$out"; then
  pass "stdin rewrite reports backup= path"
  bak="$(sed -n 's/.*backup=//p' <<<"$out" | awk '{print $1}' | head -1)"
  if [[ -f "$bak" ]] && cmp -s "$stdin_original" "$bak"; then
    pass "stdin backup is byte-identical to the pre-rewrite target"
  else
    fail "stdin backup is byte-identical to the pre-rewrite target (bak='$bak')"
  fi
else
  fail "stdin rewrite reports backup= path (got: $out)"
fi

# ---------------------------------------------------------------------------
# Staleness guard: a sibling rewrites the shared file WHILE the candidate is
# being assembled. The stale candidate must not silently replace that newer
# content — the store is multi-writer and unversioned, so a clobber here is
# exactly the loss this helper exists to prevent.
#
# Deterministic, not timing-hopeful: the candidate is fed through a FIFO, so
# the tool provably blocks mid-run until the test decides to deliver it.
# ---------------------------------------------------------------------------
stale_dir="$tmp/stale"
stale_tmp="$stale_dir/tmp"
mkdir -p "$stale_dir" "$stale_tmp"
stale_target="$stale_dir/portfolio-status.md"
printf '%s\n' '# Status' 'original body line' 'padding so the shrink guard is not what rejects this' > "$stale_target"
stale_cand="$stale_dir/candidate.md"
printf '%s\n' '# Status' 'candidate body line' 'padding so the shrink guard is not what rejects this' > "$stale_cand"
fifo="$stale_dir/stdin.fifo"
mkfifo "$fifo"

# Private TMPDIR so the readiness barrier below cannot match a concurrent run's workdir.
# `set -e` would kill the subshell on the tool's expected non-zero exit before it
# could record the code, so capture it explicitly.
( srt=0
  TMPDIR="$stale_tmp" "$tool" --file "$stale_target" --stdin < "$fifo" >/dev/null 2>&1 || srt=$?
  echo "$srt" > "$stale_dir/rc" ) &
stale_pid=$!
exec 9> "$fifo"

# Barrier: the tool creates its workdir after it has captured the original's
# identity, so its appearance proves we are past that point and blocked on stdin.
stale_ready=0
for _ in $(seq 1 400); do
  if compgen -G "$stale_tmp/memory-rewrite.*" > /dev/null 2>&1; then stale_ready=1; break; fi
  sleep 0.05
done

# The sibling write, landing after the tool read the original.
printf '%s\n' '# Status' 'SIBLING WROTE THIS LINE' 'padding so the shrink guard is not what rejects this' > "$stale_target"
sibling_original="$stale_dir/sibling-original.md"
cp "$stale_target" "$sibling_original"

cat "$stale_cand" >&9
exec 9>&-
wait "$stale_pid" || true
stale_rc="$(cat "$stale_dir/rc" 2>/dev/null || echo missing)"

if [[ "$stale_ready" -ne 1 ]]; then
  fail "staleness guard barrier (tool workdir never appeared — test could not synchronise)"
else
  check "stale rewrite exits non-zero" "1" "$stale_rc"
  check_unchanged "stale rewrite does NOT clobber the sibling's write" "$sibling_original" "$stale_target"
fi

# ---------------------------------------------------------------------------
# RED case: frontmatter opened but never closed. A line-1-only check accepts
# this, and a markdown consumer then reads the whole body as an unterminated
# metadata block. The candidate is built to trip ONLY this guard — it keeps a
# heading (structure guard passes) and is one line shorter than the target
# (shrink guard passes) — so a failure here can mean nothing else.
# ---------------------------------------------------------------------------
fm_target="$tmp/unclosed-frontmatter.md"
{
  printf '%s\n' '---' 'version: 1' '---' '# Notes'
  for (( fm_i = 0; fm_i < 40; fm_i++ )); do
    printf 'body line %s with enough bytes to stay clear of the shrink guard\n' "$fm_i"
  done
} > "$fm_target"
fm_original="$tmp/unclosed-frontmatter-original.md"
cp "$fm_target" "$fm_original"

fm_new="$tmp/unclosed-frontmatter-new.md"
{
  # Opening delimiter and a heading, but the closing `---` is gone.
  printf '%s\n' '---' 'version: 1' '# Notes'
  for (( fm_i = 0; fm_i < 40; fm_i++ )); do
    printf 'body line %s with enough bytes to stay clear of the shrink guard\n' "$fm_i"
  done
} > "$fm_new"

rc=0
out="$("$tool" --file "$fm_target" --from "$fm_new" 2>&1)" || rc=$?
check "unclosed frontmatter exits non-zero" "1" "$rc"
check_unchanged "unclosed frontmatter leaves target untouched" "$fm_original" "$fm_target"
# Match the guard's own wording, not 'frontmatter'/'close' — those also occur in
# the fixture's FILENAME, which the success path echoes back as `backup=<path>`,
# so a looser pattern passes even when the guard is removed entirely.
if grep -qF 'never closes it' <<<"$out"; then
  pass "unclosed frontmatter error mentions the missing close"
else
  fail "unclosed frontmatter error mentions the missing close (got: $out)"
fi

# Control: the same candidate WITH its closing delimiter is accepted, so the
# guard rejects the missing delimiter rather than the fixture's shape.
fm_ok="$tmp/closed-frontmatter-new.md"
{
  printf '%s\n' '---' 'version: 1' '---' '# Notes'
  for (( fm_i = 0; fm_i < 40; fm_i++ )); do
    printf 'body line %s with enough bytes to stay clear of the shrink guard\n' "$fm_i"
  done
} > "$fm_ok"
rc=0
out="$("$tool" --file "$fm_target" --from "$fm_ok" 2>&1)" || rc=$?
check "closed frontmatter is accepted (positive control)" "0" "$rc"

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
