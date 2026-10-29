#!/usr/bin/env bash
# Exercise the public launcher with synthetic files only (#2990).
set -Eeuo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
memory_archive_test_finished=0
# shellcheck disable=SC2329 # Invoked indirectly by EXIT.
cleanup() {
  local rc=$?
  rm -rf "$work"
  if [[ "$memory_archive_test_finished" != 1 && "$rc" == 0 ]]; then
    echo 'memory-archive.test: aborted before completion; reporting UNKNOWN' >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT
source_file="$work/MEMORY With Spaces.md"
archive_file="$work/Archive With Spaces.md"
printf '# Store\r\n### Old\r\nmove\r\n#### Addendum\r\nchild\r\n### Current\r\nkeep' >"$source_file"
cp "$source_file" "$work/expected-original"
printf '# Store\r\n### Current\r\nkeep' >"$work/expected-source"
printf '### Old\r\nmove\r\n#### Addendum\r\nchild\r\n' >"$work/expected-archive"
if ! bash "$script_dir/memory-archive.sh" "$source_file" '^### Old$' "$archive_file" >"$work/receipt"; then
  echo 'FAIL: complete public archive invocation did not succeed' >&2
  exit 1
fi
cmp "$source_file" "$work/expected-source"
cmp "$archive_file" "$work/expected-archive"
grep -qF 'memory-archive: complete backup=' "$work/receipt"
displaced_file="$(find "$work" -type f -name displaced-source)"
[[ -n "$displaced_file" ]] || {
  echo 'actual displaced source was not retained' >&2
  exit 1
}
cmp "$displaced_file" "$work/expected-original"
rc=0
bash "$script_dir/memory-archive.sh" "$source_file" '^### Old$' "$archive_file" >"$work/refused" 2>&1 || rc=$?
[[ "$rc" == 2 ]] || {
  echo 'repeat must refuse the existing archive' >&2
  exit 1
}
grep -qF 'archive already exists; overwrite is forbidden' "$work/refused" || {
  echo 'repeat refusal did not name the existing archive' >&2
  exit 1
}
cmp "$source_file" "$work/expected-source"
cmp "$archive_file" "$work/expected-archive"
rc=0
bash "$script_dir/memory-archive.sh" "$source_file" >"$work/usage" 2>&1 || rc=$?
[[ "$rc" == 2 ]] || {
  echo 'incomplete public arguments must be usage exit 2' >&2
  exit 1
}
grep -qF 'Usage: memory-archive.sh' "$work/usage" || {
  echo 'incomplete arguments did not print usage' >&2
  exit 1
}
bash "$script_dir/memory-archive.sh" --help >"$work/help"
grep -qF 'heading-regex' "$work/help"
memory_archive_test_finished=1
echo 'PASS: public archive launcher preserves literal paths, exact bytes, refusal and usage status'
