#!/usr/bin/env bash
# Functional controls for the bounded automation-ledger reader (monorepo#4533).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="${MEMORY_READER_UNDER_TEST:-${here}/automation-memory-read.sh}"
tmp="$(mktemp -d)"
memory_read_test_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$memory_read_test_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    printf 'automation-memory-read.test: aborted before finishing; reporting failure rather than a clean pass\n' >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
run() {
  local name=$1 want=$2 rc=0
  shift 2
  "$BASH" "$tool" "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?
  if [ "$rc" = "$want" ]; then pass "$name"; else fail "$name: rc=$rc want=$want"; fi
}
unknown() {
  local name=$1
  shift
  run "$name" 2 "$@"
  [ ! -s "$tmp/out" ] || fail "$name printed a partial successful body"
  grep -q 'UNKNOWN' "$tmp/err" || fail "$name did not explain UNKNOWN"
}
cat > "$tmp/memory.md" <<'EOF'
## Old
old note

## Middle
middle note

## New
latest café 🦀
EOF
cp "$tmp/memory.md" "$tmp/original"
cat > "$tmp/recent" <<'EOF'
## Middle
middle note

## New
latest café 🦀
EOF
cat > "$tmp/old" <<'EOF'
## Old
old note

EOF

# Missing sections, split Unicode, reversed order or an off-by-one page boundary break these.
run recent 0 --file "$tmp/memory.md" --sections 2 --max-bytes 2048
sed '1,2d' "$tmp/out" > "$tmp/body"
cmp -s "$tmp/body" "$tmp/recent" || fail 'recent sections are incomplete or reordered'
grep -q 'sections=2 omitted_older=1 next_before_line=4 ' "$tmp/out" || fail 'continuation metadata'
digest="$(sed -n '1s/.*sha256=\([0-9a-f]*\).*/\1/p' "$tmp/out")"
run continuation 0 --file "$tmp/memory.md" --sections 2 --max-bytes 2048 --before-line 4 --expected-sha256 "$digest"
sed '1,2d' "$tmp/out" > "$tmp/body"
cmp -s "$tmp/body" "$tmp/old" || fail 'continuation skipped or duplicated a section'
grep -q 'omitted_older=0 next_before_line=0 ' "$tmp/out" || fail 'final page omission metadata'
cmp -s "$tmp/memory.md" "$tmp/original" || fail 'reader changed source bytes'
unknown unbound-continuation --file "$tmp/memory.md" --before-line 4

# Headings inside examples must not detach a note from the fence and context it belongs to.
cat > "$tmp/fenced.md" <<'EOF'
## Old
old
## New
context
```markdown
## Example heading
example
```
after example
EOF
cat > "$tmp/fenced-expected" <<'EOF'
## New
context
```markdown
## Example heading
example
```
after example
EOF
run fenced-example 0 --file "$tmp/fenced.md" --sections 1
sed '1,2d' "$tmp/out" > "$tmp/body"
cmp -s "$tmp/body" "$tmp/fenced-expected" || fail 'fenced example detached from its note'
grep -q 'sections=1 omitted_older=1 next_before_line=3 ' "$tmp/out" || fail 'example heading counted as a section'
cat > "$tmp/tilde.md" <<'EOF'
## Old
old
## New
   ~~~~markdown
## Example one
~~~
## Example two
~~~~ trailing text
## Example three
   ~~~~
after example
EOF
cat > "$tmp/tilde-expected" <<'EOF'
## New
   ~~~~markdown
## Example one
~~~
## Example two
~~~~ trailing text
## Example three
   ~~~~
after example
EOF
run tilde-fence 0 --file "$tmp/tilde.md" --sections 1
sed '1,2d' "$tmp/out" > "$tmp/body"
cmp -s "$tmp/body" "$tmp/tilde-expected" || fail 'tilde fence ended on a short or non-closing line'
cat > "$tmp/closed-example.md" <<'EOF'
## Old
```markdown
## Literal example
````
## Latest
keep only this
EOF
cat > "$tmp/latest-expected" <<'EOF'
## Latest
keep only this
EOF
run heading-after-fence 0 --file "$tmp/closed-example.md" --sections 1
sed '1,2d' "$tmp/out" > "$tmp/body"
cmp -s "$tmp/body" "$tmp/latest-expected" || fail 'closing fence hides a later real heading'
cat > "$tmp/invalid-fence.md" <<'EOF'
## Old
``` invalid`info
## Latest
keep only this
EOF
run invalid-fence-info 0 --file "$tmp/invalid-fence.md" --sections 1
sed '1,2d' "$tmp/out" > "$tmp/body"
cmp -s "$tmp/body" "$tmp/latest-expected" || fail 'invalid fence opener hides a real heading'

# A line count cannot bound this fixture. The complete newest section fits; the old one does not.
{ printf '## Huge old\n'; printf '%08000d\n' 0; printf '## Latest\nkeep this\n'; } > "$tmp/large.md"
run byte-bound 0 --file "$tmp/large.md" --sections 10 --max-bytes 1024
[ "$(wc -c < "$tmp/out" | tr -d ' ')" -le 1024 ] || fail 'output exceeds requested byte budget'
grep -q '^keep this$' "$tmp/out" || fail 'byte-bound lost newest note'
if grep -q '0000000000000000' "$tmp/out"; then fail 'oversized older section leaked into body'; fi
grep -q 'sections=1 omitted_older=1 next_before_line=3 ' "$tmp/out" || fail 'byte-bound omissions hidden'
large_digest="$(sed -n '1s/.*sha256=\([0-9a-f]*\).*/\1/p' "$tmp/out")"
unknown oversized-newest --file "$tmp/large.md" --before-line 3 --sections 2 --max-bytes 1024 --expected-sha256 "$large_digest"
grep -q 'oversized section' "$tmp/err" || fail 'oversized section reason missing'

printf '## Pending\nunfinished' > "$tmp/partial.md"
: > "$tmp/empty.md"
unknown partial-final-record --file "$tmp/partial.md"
unknown empty --file "$tmp/empty.md"
unknown missing --file "$tmp/absent.md"
unknown wrong-digest --file "$tmp/memory.md" --expected-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
unknown no-eligible-section --file "$tmp/memory.md" --before-line 1 --expected-sha256 "$digest"
unknown bad-budget --file "$tmp/memory.md" --max-bytes 0
unknown ambiguous-integer --file "$tmp/memory.md" --max-bytes 01024
unknown bad-count --file "$tmp/memory.md" --sections nope
unknown empty-expected-digest --file "$tmp/memory.md" --expected-sha256 ''
unknown unknown-option --file "$tmp/memory.md" --discard
printf 'plain legacy note\n' > "$tmp/plain.md"
run no-heading 0 --file "$tmp/plain.md"
grep -q '^plain legacy note$' "$tmp/out" || fail 'unheaded record lost'

# Deterministic metadata/read failures exercise the race and failed-snapshot branches.
mkdir "$tmp/stat-bin" "$tmp/cat-bin" "$tmp/hash-bin"
cat > "$tmp/stat-bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n=0
[ ! -f "$STAT_COUNTER" ] || read -r n < "$STAT_COUNTER"
n=$((n + 1))
printf '%s\n' "$n" > "$STAT_COUNTER"
printf 'changed-%s\n' "$n"
EOF
cat > "$tmp/cat-bin/cat" <<'EOF'
#!/usr/bin/env bash
exit 71
EOF
cat > "$tmp/hash-bin/shasum" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/stat-bin/stat" "$tmp/cat-bin/cat" "$tmp/hash-bin/shasum"
STAT_COUNTER="$tmp/stat-count" PATH="$tmp/stat-bin:$PATH" unknown changed-source --file "$tmp/memory.md"
PATH="$tmp/cat-bin:$PATH" unknown failed-snapshot --file "$tmp/memory.md"
PATH="$tmp/hash-bin:$PATH" unknown empty-successful-digest --file "$tmp/memory.md"

memory_read_test_finished=1
if [ "$fails" -gt 0 ]; then printf 'automation-memory-read tests: FAIL (%s)\n' "$fails"; exit 1; fi
printf 'automation-memory-read tests: PASS\n'
