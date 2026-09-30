#!/usr/bin/env bash
#
# Tests gnu-only-syntax-guard.sh (monorepo#3273): each GNU-only construct is flagged by the right
# rule on the right line, each portable equivalent passes, and every way the guard could report a
# clean pass without having scanned anything reports unknown instead.
#
# shellcheck disable=SC2016,SC1003 # fixture lines are literal script text; nothing in them should expand here

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="${script_dir}/gnu-only-syntax-guard.sh"
scripts_agents="${script_dir}/AGENTS.md"

tmp="$(mktemp -d)"
test_finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [[ "$test_finished" != 1 && $rc -eq 0 ]]; then
    echo "gnu-only-syntax-guard test: aborted before finishing; reporting failure" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

fail() {
  echo "gnu-only-syntax-guard test: FAIL — $*" >&2
  exit 1
}

passed=0
ok() { passed=$((passed + 1)); }

# run FILE... — captures stdout in $out, stderr in $err and the status in $rc.
run() {
  rc=0
  bash "$guard" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
  out="$(cat "$tmp/out")"
  err="$(cat "$tmp/err")"
}

# expect_finding NAME RULE LINE FILE — exactly that rule on that line, and exit 1.
expect_finding() {
  run "$4"
  [[ $rc -eq 1 ]] || fail "$1: expected exit 1, got $rc (out: $out; err: $err)"
  case "$out" in
    *"$4:$3: $2: "*) ;;
    *) fail "$1: expected '$2' at line $3, got: $out" ;;
  esac
  ok
}

expect_clean() {
  run "$2"
  [[ $rc -eq 0 ]] || fail "$1: expected exit 0, got $rc (out: $out; err: $err)"
  [[ -z "$(printf '%s' "$out" | grep -v '^gnu-only-syntax-guard: OK' || true)" ]] ||
    fail "$1: clean run printed findings: $out"
  ok
}

fixture() {
  local name="$1"
  shift
  printf '%s\n' '#!/usr/bin/env bash' "$@" >"$tmp/$name.sh"
  printf '%s' "$tmp/$name.sh"
}

# --- Rule: find -newer?t @<epoch> -----------------------------------------------------------------
f="$(fixture newermt-bare 'find "$dir" -newermt @1788603160 -print')"
expect_finding "bare -newermt @epoch" find-newermt-epoch 2 "$f"
f="$(fixture newermt-quoted 'x=1' 'find "$dir" -type f -newermt "@$since" 2>/dev/null')"
expect_finding "double-quoted -newermt @epoch" find-newermt-epoch 3 "$f"
f="$(fixture newermt-single "find . -newerct '@0'")"
expect_finding "single-quoted -newerct @epoch" find-newermt-epoch 2 "$f"
f="$(fixture newer-portable 'touch -t "$stamp" "$ref"' 'find "$dir" -newer "$ref" -print')"
expect_clean "touch -t reference file with -newer" "$f"
f="$(fixture newermt-datestring 'find . -newermt "2026-01-01 00:00"')"
expect_clean "-newermt with a date string BSD find parses" "$f"

# --- Rule: date -d without a BSD form nearby ------------------------------------------------------
f="$(fixture date-lone 'now=$(date -u -d "10 days ago" +%s)')"
expect_finding "lone date -u -d" date-d-without-bsd 2 "$f"
f="$(fixture date-epoch 'a=1' 'b=2' 'out=$(date -d "@$e" +%H)')"
expect_finding "lone date -d @epoch" date-d-without-bsd 4 "$f"
f="$(fixture date-cluster 'out=$(date -ud "$raw" +%s)')"
expect_finding "combined -ud flag cluster" date-d-without-bsd 2 "$f"
f="$(fixture date-long 'out=$(date --date="$raw" +%s)')"
expect_finding "long --date option" date-d-without-bsd 2 "$f"
f="$(fixture date-v 'stamp=$(date -u -v-10d +%Y%m%d%H%M 2>/dev/null) ||' \
  '  stamp=$(date -u -d "10 days ago" +%Y%m%d%H%M 2>/dev/null)')"
expect_clean "BSD -v fallback on the previous line" "$f"
f="$(fixture date-j 'out=$(date -u -d "${base}Z" +%s 2>/dev/null) || out=""' \
  '[ -n "$out" ] || out=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$base" +%s 2>/dev/null)')"
expect_clean "BSD -j -f fallback on the next line" "$f"
f="$(fixture date-r 'out=$(date -r "$e" +%H 2>/dev/null) || out=""' 'x=1' 'y=2' \
  '[ -n "$out" ] || out=$(date -d "@$e" +%H)')"
expect_clean "BSD -r fallback three lines above" "$f"
f="$(fixture date-far 'out=$(date -r "$e" +%H 2>/dev/null) || out=""' 'a=1' 'b=2' 'c=3' \
  '[ -n "$out" ] || out=$(date -d "@$e" +%H)')"
expect_finding "BSD fallback four lines away does not count" date-d-without-bsd 6 "$f"
f="$(fixture date-comment-bsd '# date -u -v-1d is the BSD form' 'out=$(date -u -d "1 day ago")')"
expect_finding "a BSD form in a comment is not a fallback" date-d-without-bsd 3 "$f"
f="$(fixture not-date 'apt-get update -d' 'x=$(mydate -d now)' 'candidate -d 3')"
expect_clean "words that merely end in date are not date" "$f"
f="$(fixture date-plain 'now=$(date -u +%Y-%m-%dT%H:%M:%SZ)')"
expect_clean "date without -d" "$f"

f="$(fixture date-long-opt-first 'out=$(date --utc -d yesterday +%s)')"
expect_finding "long option before -d" date-d-without-bsd 2 "$f"
f="$(fixture date-long-opt-value 'out=$(date --utc --date="$raw" +%s)')"
expect_finding "long option before --date=" date-d-without-bsd 2 "$f"
f="$(fixture date-long-opt-bsd 'out=$(date --utc -d "$raw" +%s 2>/dev/null) ||' \
  '  out=$(date -u -j -f "%Y-%m-%d" "$raw" +%s)')"
expect_clean "long option before -d with a BSD fallback" "$f"

# --- Backslash-continued commands are judged as one command ---------------------------------------
f="$(fixture newermt-continued 'x=1' 'find "$dir" -newermt \' '  @0 -print')"
expect_finding "-newermt and @epoch split across a continuation" find-newermt-epoch 3 "$f"
f="$(fixture date-continued 'out=$(date -u \' '  -d "@$e" +%H)')"
expect_finding "date and -d split across a continuation" date-d-without-bsd 2 "$f"
f="$(fixture date-continued-bsd 'out=$(date -u -d "@$e" +%H 2>/dev/null) ||' \
  '  out=$(date -u \' '    -r "$e" +%H)')"
expect_clean "BSD fallback split across a continuation" "$f"
f="$(fixture even-backslashes 'printf "%s\n" "a\\\\"' 'find . -newermt @1')"
expect_finding "an escaped backslash does not continue the line" find-newermt-epoch 3 "$f"

# --- A fallback counts only when it is code, and the window counts commands -----------------------
f="$(fixture bsd-in-comment 'x=1 # BSD uses date -r' 'now=$(date -d yesterday)')"
expect_finding "a BSD form in a trailing comment is not a fallback" date-d-without-bsd 3 "$f"
f="$(fixture bsd-in-string 'echo "BSD uses date -v-1d"' 'now=$(date -d yesterday)')"
expect_finding "a BSD form in a quoted string is not a fallback" date-d-without-bsd 3 "$f"
f="$(fixture bsd-in-dq-substitution 'out="$(date -r "$e" +%H 2>/dev/null)" ||' \
  '  out="$(date -d "@$e" +%H)"')"
expect_clean "a BSD form inside a double-quoted substitution is code" "$f"
f="$(fixture window-skips-blanks 'out=$(date -r "$e" +%H 2>/dev/null) || out=""' 'x=1' '' \
  '# a comment line' '' 'y=2' '[ -n "$out" ] || out=$(date -d "@$e" +%H)')"
expect_clean "blank and comment lines do not count toward the window" "$f"
f="$(fixture gnu-in-heredoc 'cat <<EOF' 'now=$(date -d yesterday)' 'EOF' 'x=1')"
expect_clean "a here-document body is data" "$f"
f="$(fixture after-heredoc 'cat <<-"EOF"' '	body' '	EOF' 'now=$(date -d yesterday)')"
expect_finding "code after a <<- here-document is scanned" date-d-without-bsd 5 "$f"
f="$(fixture here-string 'read -r x <<<"$y"' 'now=$(date -d yesterday)')"
expect_finding "a here-string is not a here-document" date-d-without-bsd 3 "$f"
f="$(fixture arithmetic-shift 'x=$(( 1 << 2 ))' 'now=$(date -d yesterday)')"
expect_finding "an arithmetic shift is not a here-document" date-d-without-bsd 3 "$f"
f="$(fixture multiline-string 'msg="first line' 'date -r is BSD"' 'now=$(date -d yesterday)')"
expect_finding "a multi-line string is data across its lines" date-d-without-bsd 4 "$f"

# --- Command boundaries, command positions and nested code ----------------------------------------
f="$(fixture date-attached 'out=$(date -dtomorrow +%s)')"
expect_finding "attached -dSTRING does not excuse itself" date-d-without-bsd 2 "$f"
f="$(fixture backtick-in-dq 'out="prefix `date -d yesterday +%s`"')"
expect_finding "a backtick substitution inside double quotes is code" date-d-without-bsd 2 "$f"
f="$(fixture semicolons 'date -r "$e"; a=1; b=2; c=3; d=4; date -d tomorrow')"
expect_finding "semicolons separate commands in the window" date-d-without-bsd 2 "$f"
f="$(fixture and-or-list 'out=$(date -r "$e") || out="" && w=1' 'y=2' 'z=3' '[ -n "$out" ] || out=$(date -d "@$e")')"
expect_clean "|| and && join one command" "$f"
f="$(fixture if-else 'if t="$(date -u -v-3H +%s 2>/dev/null)"; then' '  :' 'else' \
  '  t="$(date -u -d "3 hours ago" +%s)"' 'fi')"
expect_clean "then, else and : are not commands in the window" "$f"
f="$(fixture arithmetic-shift-name 'x=$((1 << bits))' 'now=$(date -d yesterday)')"
expect_finding "a shift by a named operand is not a here-document" date-d-without-bsd 3 "$f"
f="$(fixture bsd-as-argument "printf '%s\\n' date -r epoch" 'now=$(date -d yesterday)')"
expect_finding "date -r as a plain argument is not a fallback" date-d-without-bsd 3 "$f"
f="$(fixture quoted-find-example "printf '%s\\n' 'find . -newermt @0'")"
expect_clean "a quoted find example is data" "$f"
f="$(fixture numeric-heredoc 'cat <<123' 'now=$(date -d yesterday)' '123' 'x=1')"
expect_clean "a numeric here-document delimiter is honoured" "$f"
f="$(fixture bash-c "bash -c 'date -d yesterday +%s'")"
expect_finding "a bash -c payload is code" date-d-without-bsd 2 "$f"
f="$(fixture eval-find 'eval "find . -newermt @0"')"
expect_finding "an eval payload is code" find-newermt-epoch 2 "$f"
f="$(fixture sh-c-fallback "sh -c 'date -r 1 2>/dev/null || date -d @1'")"
expect_clean "a fallback inside the same payload counts" "$f"

# --- Comments and the opt-out marker --------------------------------------------------------------
f="$(fixture comment '  # find . -newermt @1 and date -d "x" are GNU-only')"
expect_clean "comment lines are ignored" "$f"
f="$(fixture opt-out 'out=$(date -d "@$e") # gnu-only-ok: Linux-only CI step')"
expect_clean "opt-out marker with a reason" "$f"
f="$(fixture opt-out-empty 'out=$(date -d "@$e") # gnu-only-ok:')"
expect_finding "opt-out marker without a reason is not honoured" date-d-without-bsd 2 "$f"
f="$(fixture opt-out-single-quoted "label='# gnu-only-ok: display'; now=\$(date -d yesterday)")"
expect_finding "a single-quoted marker is data, not an opt-out" date-d-without-bsd 2 "$f"
f="$(fixture opt-out-double-quoted 'label=" # gnu-only-ok: display"; now=$(date -d yesterday)')"
expect_finding "a double-quoted marker is data, not an opt-out" date-d-without-bsd 2 "$f"
f="$(fixture opt-out-after-quotes "now=\$(date -d '@1' +%s) # gnu-only-ok: Linux-only CI step")"
expect_clean "a real comment after balanced quotes is honoured" "$f"
f="$(fixture opt-out-escaped-quote 'label="\" # gnu-only-ok: display"; now=$(date -d yesterday)')"
expect_finding "an escaped quote does not end the string before a marker" date-d-without-bsd 2 "$f"
f="$(fixture opt-out-ansi-c "label=\$'\\' # gnu-only-ok: display'; now=\$(date -d yesterday)")"
expect_finding "a marker inside \$'…' quotes is data" date-d-without-bsd 2 "$f"
f="$(fixture hash-not-comment 'n=${#arr[@]}; now=$(date -d yesterday) # gnu-only-ok: Linux-only')"
expect_clean "\${#…} is not a comment, and the real trailing comment still counts" "$f"

# --- Several files in one run: findings keep their own file and line ------------------------------
a="$(fixture multi-a 'x=1' 'find . -newermt @1')"
b="$(fixture multi-b 'y=$(date -d "@1")')"
run "$a" "$b"
[[ $rc -eq 1 ]] || fail "multi-file: expected exit 1, got $rc"
case "$out" in *"$a:3: find-newermt-epoch: "*) ;; *) fail "multi-file: lost $a:3 in: $out" ;; esac
case "$out" in *"$b:2: date-d-without-bsd: "*) ;; *) fail "multi-file: lost $b:2 in: $out" ;; esac
ok
# The BSD form in file A must not excuse file B's GNU form across the file boundary.
a="$(fixture boundary-a 'x=1' 'x=2' 'x=3' 'x=4' 'z=$(date -u -v-1d)')"
b="$(fixture boundary-b 'y=$(date -d "@1")')"
run "$a" "$b"
[[ $rc -eq 1 ]] || fail "file boundary: a BSD form in the previous file excused a GNU form (rc=$rc)"
case "$out" in *"$b:2: date-d-without-bsd: "*) ;; *) fail "file boundary: lost $b:2 in: $out" ;; esac
ok

# --- Unknown, never a clean pass ------------------------------------------------------------------
run "$tmp/does-not-exist.sh"
[[ $rc -eq 2 ]] || fail "missing file: expected exit 2, got $rc"
ok
run --bogus
[[ $rc -eq 2 ]] || fail "unknown option: expected exit 2, got $rc"
ok
: >"$tmp/empty.sh"
run "$tmp/empty.sh"
[[ $rc -eq 2 ]] || fail "an explicit empty file: expected exit 2, got $rc (out: $out)"
ok
f="$(fixture clean-partner 'x=1')"
run "$f" "$tmp/empty.sh"
[[ $rc -eq 2 ]] || fail "a clean file next to an empty one: expected exit 2, got $rc (out: $out)"
ok
f="$(fixture unterminated 'msg="never closed' 'now=$(date -d yesterday)')"
run "$f"
[[ $rc -eq 2 ]] || fail "an unterminated quote: expected exit 2, got $rc (out: $out)"
ok
f="$(fixture unterminated-heredoc 'cat <<EOF' 'now=$(date -d yesterday)')"
run "$f"
[[ $rc -eq 2 ]] || fail "an unterminated here-document: expected exit 2, got $rc (out: $out)"
ok
# An operand shaped like an awk assignment is still read as a file.
mkdir "$tmp/assign"
printf '%s\n' '#!/usr/bin/env bash' 'now=$(date -d yesterday)' >"$tmp/assign/input=bad"
rc=0
(cd "$tmp/assign" && bash "$guard" 'input=bad') >"$tmp/out" 2>"$tmp/err" </dev/null || rc=$?
[[ $rc -eq 1 ]] || fail "an assignment-shaped operand: expected exit 1, got $rc ($(cat "$tmp/out") $(cat "$tmp/err"))"
grep -q 'input=bad:2: date-d-without-bsd' "$tmp/out" || fail "an assignment-shaped operand was not scanned: $(cat "$tmp/out")"
ok
# Any abort before the verdict is unknown (2), never a finding (1): a failing `sed` under --help.
mkdir "$tmp/nosed"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$tmp/nosed/sed"
chmod +x "$tmp/nosed/sed"
rc=0
PATH="$tmp/nosed:$PATH" bash "$guard" --help >"$tmp/out" 2>"$tmp/err" || rc=$?
[[ $rc -eq 2 ]] || fail "an abort under --help: expected exit 2, got $rc"
ok
mkdir "$tmp/empty-scripts"
cp "$guard" "$tmp/empty-scripts/gnu-only-syntax-guard.sh"
rc=0
bash "$tmp/empty-scripts/gnu-only-syntax-guard.sh" >"$tmp/out" 2>"$tmp/err" || rc=$?
[[ $rc -eq 2 ]] || fail "default scan of a directory with no bash scripts: expected exit 2, got $rc"
ok
# The default scan picks up a bash-shebanged sibling and skips a non-bash one.
printf '%s\n' '#!/bin/sh' 'find . -newermt @1' >"$tmp/empty-scripts/posix.sh"
printf '%s\n' '#!/usr/bin/env bash' 'find . -newermt @1' >"$tmp/empty-scripts/helper.sh"
rc=0
bash "$tmp/empty-scripts/gnu-only-syntax-guard.sh" >"$tmp/out" 2>"$tmp/err" || rc=$?
[[ $rc -eq 1 ]] || fail "default scan: expected the bash sibling's finding (exit 1), got $rc"
grep -q 'helper.sh:2: find-newermt-epoch' "$tmp/out" || fail "default scan: bash sibling not flagged: $(cat "$tmp/out")"
if grep -q 'posix.sh' "$tmp/out"; then fail "default scan: scanned a non-bash script"; fi
ok
# An unreadable candidate next to a clean, readable one is unknown, never a clean pass. Skipped when
# running as root, which reads a mode-000 file anyway.
if [[ "$(id -u)" != 0 ]]; then
  rm "$tmp/empty-scripts/posix.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'x=1' >"$tmp/empty-scripts/helper.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'find . -newermt @1' >"$tmp/empty-scripts/hidden.sh"
  chmod 000 "$tmp/empty-scripts/hidden.sh"
  rc=0
  bash "$tmp/empty-scripts/gnu-only-syntax-guard.sh" >"$tmp/out" 2>"$tmp/err" || rc=$?
  chmod 644 "$tmp/empty-scripts/hidden.sh"
  [[ $rc -eq 2 ]] || fail "default scan with an unreadable candidate: expected exit 2, got $rc ($(cat "$tmp/out"))"
  grep -q 'cannot read .*hidden.sh' "$tmp/err" || fail "default scan: unknown did not name the unreadable file: $(cat "$tmp/err")"
  ok
fi

# --- The real helper suite is clean ---------------------------------------------------------------
run
[[ $rc -eq 0 ]] || fail "the repository's bash scripts have GNU-only findings: $out"
case "$out" in
  *"gnu-only-syntax-guard: OK — "[1-9]*" bash script(s) scanned"*) ;;
  *) fail "the repository scan did not report a positive script count: $out" ;;
esac
ok

# --- The rule is stated where script authors read it ---------------------------------------------
[[ -r "$scripts_agents" ]] || fail "cannot read $scripts_agents"
grep -q 'Probe the way the script runs' "$scripts_agents" ||
  fail ".claude/scripts/AGENTS.md does not state the probe-the-way-the-script-runs rule"
grep -q 'gnu-only-syntax-guard.sh' "$scripts_agents" ||
  fail ".claude/scripts/AGENTS.md does not name gnu-only-syntax-guard.sh"
ok

test_finished=1
echo "gnu-only-syntax-guard test: OK — ${passed} checks passed"
