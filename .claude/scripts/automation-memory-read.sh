#!/usr/bin/env bash
# Read complete recent automation-memory sections within a byte budget (monorepo#4533).
# Line tails do not bound long entries. This reader preserves the ledger and exposes omissions;
# it never treats an unread, oversized or concurrently changed source as a complete memory read.
# Usage: automation-memory-read.sh --file PATH [--sections N] [--max-bytes N]
#         [--before-line N --expected-sha256 SHA]
# Defaults: three sections, 12000 total output bytes. Exit 0 = bounded snapshot, 2 = UNKNOWN.
# Omitted older sections remain relevant: continue at next_before_line with the returned digest,
# or search the source for the specific unresolved fact. An omitted section is never a cleared item.
set -euo pipefail
export LC_ALL=C
file="" sections=3 max_bytes=12000 before_line=0 expected="" expected_set=0
unknown() { printf 'automation-memory-read: UNKNOWN %s\n' "$1" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --file|--sections|--max-bytes|--before-line|--expected-sha256)
      [ "$#" -ge 2 ] || unknown 'missing option value'
      case "$1" in
        --file) file=$2 ;;
        --sections) sections=$2 ;;
        --max-bytes) max_bytes=$2 ;;
        --before-line) before_line=$2 ;;
        --expected-sha256) expected=$2; expected_set=1 ;;
      esac
      shift 2 ;;
    --help|-h) sed -n '2,9p' "$0"; exit 0 ;;
    *) unknown 'unknown option' ;;
  esac
done
for n in "$sections" "$max_bytes" "$before_line"; do
  [[ "$n" =~ ^(0|[1-9][0-9]*)$ ]] || unknown 'expected a canonical nonnegative integer'
  [ "${#n}" -le 7 ] || unknown 'integer exceeds supported bounds'
done
[ "$sections" -gt 0 ] && [ "$sections" -le 10000 ] || unknown 'sections must be 1..10000'
[ "$max_bytes" -ge 1024 ] && [ "$max_bytes" -le 1048576 ] || unknown 'max-bytes must be 1024..1048576'
if [ "$expected_set" = 1 ]; then
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || unknown 'malformed expected digest'
fi
[ "$before_line" = 0 ] || [ "$expected_set" = 1 ] || unknown 'continuation requires expected source digest'
[ -n "$file" ] && [ -f "$file" ] && [ -r "$file" ] || unknown 'missing or unreadable regular file'
case "$file" in /*) ;; *) file="$PWD/$file" ;; esac

tmp="$(mktemp -d)" || unknown 'cannot allocate snapshot'
automation_memory_read_finished=0
cleanup() {
  local rc=$?
  if ! rm -rf "$tmp"; then rc=2; fi
  if [ "$automation_memory_read_finished" != 1 ] && [ "$rc" -eq 0 ]; then
    printf 'automation-memory-read: UNKNOWN aborted before finishing\n' >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT

fingerprint() {
  local value
  if value="$(stat -f '%d:%i:%z:%m:%c' "$file" 2>/dev/null)"; then
    printf '%s\n' "$value"
  else
    stat -c '%d:%i:%s:%Y:%Z' "$file" 2>/dev/null
  fi
}
digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
before="$(fingerprint)" && [ -n "$before" ] || unknown 'cannot stat source'
cat "$file" > "$tmp/source" || unknown 'failed snapshot read'
[ -s "$tmp/source" ] || unknown 'empty source'
last="$(tail -c 1 "$tmp/source" | od -An -tu1 | tr -d ' \n')" || unknown 'cannot inspect final record'
[ "$last" = 10 ] || unknown 'partial final record (missing newline)'
sha="$(digest "$tmp/source")" || unknown 'cannot hash snapshot'
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || unknown 'malformed snapshot digest'
live_sha="$(digest "$file")" || unknown 'cannot verify source digest'
[[ "$live_sha" =~ ^[0-9a-f]{64}$ ]] || unknown 'malformed source digest'
after="$(fingerprint)" || unknown 'cannot re-stat source'
[ "$before" = "$after" ] && [ "$sha" = "$live_sha" ] || unknown 'source changed during read'
[ -z "$expected" ] || [ "$sha" = "$expected" ] || unknown 'source digest changed; restart paging'

# LC_ALL=C makes lengths byte counts without changing the source bytes. Keep whole sections,
# including their original newlines. Fenced examples are opaque, so their apparent headings never
# detach from the containing note (CommonMark 0.31.2 section4.5). Native section headings are the
# unindented ## lines outside those examples. The metadata allowance is checked before output.
if ! awk -v cap="$((max_bytes - 512))" -v count="$sections" -v before="$before_line" -v sha="$sha" '
  function example(line, probe, ch, n, rest, inside) {
    inside=(fence_char != "")
    probe=line
    sub(/^ ? ? ?/, "", probe)
    ch=substr(probe,1,1)
    if (ch != "`" && ch != "~") return inside
    n=0
    while (substr(probe,n+1,1) == ch) n++
    rest=substr(probe,n+1)
    if (inside) {
      if (ch == fence_char && n >= fence_size && rest ~ /^[ \t]*$/) fence_char=""
      return 1
    }
    if (n >= 3 && (ch == "~" || index(rest,"`") == 0)) {
      fence_char=ch; fence_size=n
      return 1
    }
    return 0
  }
  NR == 1 { part=1; start[part]=1 }
  {
    opaque=example($0)
    if (NR > 1 && !opaque && /^##[[:space:]]/) { part++; start[part]=NR }
    text[part]=text[part] $0 "\n"; size[part]+=length($0)+1; end[part]=NR
  }
  END {
    last=part
    if (before != 0) {
      boundary=(before == NR+1)
      for (i=1; i<=part; i++) if (start[i] == before) boundary=1
      if (!boundary) { print "invalid continuation boundary" > "/dev/stderr"; exit 2 }
      while (last > 0 && start[last] >= before) last--
    }
    if (last == 0) { print "no eligible section" > "/dev/stderr"; exit 2 }
    first=last+1; used=0; picked=0
    for (i=last; i>=1 && picked<count; i--) {
      if (used+size[i] > cap) break
      used+=size[i]; picked++; first=i
    }
    if (picked == 0) {
      printf "oversized section start=%d end=%d bytes=%d\n", start[last],end[last],size[last] > "/dev/stderr"
      exit 2
    }
    next_line=(first > 1 ? start[first] : 0)
    printf "MEMORY-READ sha256=%s sections=%d omitted_older=%d next_before_line=%d body_bytes=%d\n---\n", sha,picked,first-1,next_line,used
    for (i=first; i<=last; i++) printf "%s",text[i]
  }
' "$tmp/source" > "$tmp/result" 2> "$tmp/reason"; then
  reason="$(cat "$tmp/reason")" || reason='selection failed'
  unknown "$reason"
fi
bytes="$(wc -c < "$tmp/result" | tr -d ' ')" || unknown 'cannot verify output size'
[ "$bytes" -le "$max_bytes" ] || unknown 'output exceeds requested byte budget'
cat "$tmp/result" || unknown 'cannot emit snapshot'
automation_memory_read_finished=1
