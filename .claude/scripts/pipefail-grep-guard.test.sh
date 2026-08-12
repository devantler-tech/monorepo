#!/usr/bin/env bash
#
# Self-test for pipefail-grep-guard.sh.
#
# Two halves, deliberately:
#
#   1. A BEHAVIOURAL proof that the class the guard rejects is real on this
#      host — the offending pipeline is executed and shown to report failure on
#      a successful match, and the here-string replacement is shown to report
#      success. Without this the guard is a regex nobody can justify.
#   2. Detection cases, each with a control whose needle is genuinely ABSENT.
#      A control that still contains the thing being detected proves nothing,
#      so every "must not flag" case here differs from its "must flag" twin in
#      the one character that matters.
#
# Fixtures are throwaway files under mktemp; no repository file is read except
# the guard itself.
#
# pipefail-grep-guard: allow-file — this file is ABOUT the offending form: it
# quotes every spelling of it as fixture text and executes one on purpose to
# prove the class is real. Scanning it would report its own subject matter.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/pipefail-grep-guard.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0

report() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "yes" ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name${detail:+ — $detail}"
    fail=1
  fi
}

yn() { if "$@"; then echo yes; else echo no; fi; }

# Write $2.. as a shell script at $1 and return its path.
mkscript() {
  local path="$tmp/$1"
  shift
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf '%s\n' "$@"
  } >"$path"
  printf '%s' "$path"
}

# Run the guard over one fixture. Sets $out and returns the guard's status.
run_guard() {
  out="$("$guard" "$1" 2>&1)" && return 0 || return $?
}

# ---------------------------------------------------------------------------
# 1. The behavioural proof: the class is real, and the fix works.
# ---------------------------------------------------------------------------
# Needle first, then a payload large enough that grep exits while the writer
# still has bytes to push. This is a race, so it is size-BIASED and not
# size-determined; the loop below reports how often it fired rather than
# asserting a single run, and the assertion is "at least once in 50".
probe_payload="$tmp/payload"
{
  echo NEEDLE
  head -c 200000 /dev/zero | tr '\0' 'x'
  echo
} >"$probe_payload"

piped_failures=0
herestring_failures=0
matched=0
for _ in $(seq 1 50); do
  set +e
  cat "$probe_payload" | grep -q NEEDLE >/dev/null 2>&1
  piped_rc=$?
  grep -q NEEDLE <"$probe_payload" >/dev/null 2>&1
  here_rc=$?
  set -e
  ((piped_rc != 0)) && piped_failures=$((piped_failures + 1))
  ((here_rc != 0)) && herestring_failures=$((herestring_failures + 1))
  ((here_rc == 0)) && matched=$((matched + 1))
done

report "behaviour: the needle IS present (so any failure is spurious, not a real no-match)" \
  "$(yn test "$matched" -eq 50)" "unpiped grep matched $matched/50"
report "behaviour: piping a writer into 'grep -q' reports FAILURE on a successful match" \
  "$(yn test "$piped_failures" -gt 0)" "piped form failed $piped_failures/50"
report "behaviour: the pipe-free form the guard asks for never reports that failure" \
  "$(yn test "$herestring_failures" -eq 0)" "pipe-free form failed $herestring_failures/50"

# ---------------------------------------------------------------------------
# 2a. Must FLAG — each early-exit spelling.
# ---------------------------------------------------------------------------
flag_case() {
  local name="$1" line="$2" f
  f="$(mkscript "flag-$(echo "$name" | tr -c 'a-zA-Z0-9' '-').sh" "$line")"
  run_guard "$f" && rc=0 || rc=$?
  report "flags: $name" "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"
}

flag_case "printf into grep -q" \
  'printf "%s" "$v" | grep -q NEEDLE'
flag_case "grep -qF" \
  'printf "%s" "$v" | grep -qF NEEDLE'
flag_case "grep -Fq (letters the other way round)" \
  'printf "%s" "$v" | grep -Fq NEEDLE'
flag_case "grep -qE" \
  'printf "%s" "$v" | grep -qE "NEE(DLE)"'
flag_case "long option --quiet" \
  'printf "%s" "$v" | grep --quiet NEEDLE'
flag_case "long option --silent" \
  'printf "%s" "$v" | grep --silent NEEDLE'
flag_case "grep -l (also stops at the first match)" \
  'find . -type f | xargs grep -l NEEDLE | grep -l NEEDLE'
flag_case "grep -m1 (also stops at the first match)" \
  'printf "%s" "$v" | grep -m1 NEEDLE'
flag_case "grep --max-count=1" \
  'printf "%s" "$v" | grep --max-count=1 NEEDLE'
flag_case "egrep -q" \
  'printf "%s" "$v" | egrep -q NEEDLE'
flag_case "an env-var prefix before grep" \
  'printf "%s" "$v" | LC_ALL=C grep -q NEEDLE'
flag_case "a |& pipe carrying stderr too" \
  'build_it |& grep -q NEEDLE'
flag_case "a negated pipeline (the fail-OPEN direction)" \
  'if ! printf "%s" "$v" | grep -q NEEDLE; then echo bad; fi'
flag_case "the second pipeline on one line" \
  'printf "%s" "$a" | grep -c NEEDLE && printf "%s" "$b" | grep -q NEEDLE'

# grep reached through a wrapper or an absolute path. This file's own header
# tells the reader to call `command grep` / /usr/bin/grep to escape the harness
# shim, so these are the spellings a script following that advice contains — and
# a bare-name-only match let every one of them through as clean.
flag_case "command grep (the spelling this guard's own docs recommend)" \
  'printf "%s" "$v" | command grep -q NEEDLE'
flag_case "env grep" \
  'printf "%s" "$v" | env grep -q NEEDLE'
flag_case "an absolute path to grep" \
  'printf "%s" "$v" | /usr/bin/grep -q NEEDLE'
flag_case "a wrapper AND an env-var prefix together" \
  'printf "%s" "$v" | LC_ALL=C command grep -q NEEDLE'

# Options whose value is the FOLLOWING word. The walk used to read that value as
# the pattern operand and stop, so a -q after it was never seen.
flag_case "-e PATTERN before -q" \
  'printf "%s" "$v" | grep -e PATTERN -q'
flag_case "--regexp PATTERN before -q" \
  'printf "%s" "$v" | grep --regexp PATTERN -q'
flag_case "-f FILE before -q" \
  'printf "%s" "$v" | grep -f patterns.txt -q'
flag_case "a cluster ending in -e before -q" \
  'printf "%s" "$v" | grep -ie PATTERN -q'

# ---------------------------------------------------------------------------
# 2b. Must NOT flag — each control differs from a flagged twin in exactly the
#     character that matters, so a control that "passes" for the wrong reason
#     would show up as a flagged twin passing too.
# ---------------------------------------------------------------------------
clean_case() {
  local name="$1" line="$2" f
  f="$(mkscript "clean-$(echo "$name" | tr -c 'a-zA-Z0-9' '-').sh" "$line")"
  run_guard "$f" && rc=0 || rc=$?
  report "clean: $name" "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"
}

clean_case "a here-string (the prescribed fix)" \
  'grep -q NEEDLE <<<"$v"'
clean_case "process substitution (the prescribed fix for a command)" \
  'grep -q NEEDLE < <(printf "%s" "$v")'
clean_case "reading a file (the prescribed fix for a file)" \
  'grep -q NEEDLE "$file"'
clean_case "a logical OR, not a pipe" \
  'cached "$1" || grep -qF -- "$1" "$keepfile"'
clean_case "a logical OR with spaces around it" \
  'test -n "$v" || grep -q NEEDLE "$f"'
clean_case "grep -c reads to the end" \
  'printf "%s" "$v" | grep -c NEEDLE'
clean_case "grep -L must read to the end to prove absence" \
  'printf "%s" "$v" | grep -L NEEDLE'
clean_case "a plain grep reads to the end" \
  'printf "%s" "$v" | grep NEEDLE'
clean_case "a pattern that merely contains -q" \
  'printf "%s" "$v" | grep -F -- "-q is not a flag here"'
clean_case "an arithmetic -eq after the pipeline" \
  'if [ "$(printf "%s" "$v" | grep -Fc NEEDLE)" -eq 2 ]; then echo ok; fi'
clean_case "a whole-line comment describing the bug" \
  '# Here-string, not printf | grep -q: grep -q exits at the first match.'
clean_case "an indented whole-line comment describing the bug" \
  '    # was: printf "%s" "$out" | grep -q PAT'
# The twin of the -e cases above: here the cluster's value is ATTACHED, so the
# trailing q is the pattern rather than a flag. Reading the token as a whole
# instead of letter by letter reported this as an offender.
clean_case "-eq is -e with the pattern q, not an early exit" \
  'printf "%s" "$v" | grep -eq PAT'
clean_case "a wrapper in front of a grep that reads to the end" \
  'printf "%s" "$v" | command grep -c NEEDLE'
clean_case "a path-qualified name that merely ENDS in grep" \
  'printf "%s" "$v" | /opt/bin/notgrep -q NEEDLE'

# ---------------------------------------------------------------------------
# 2c. Multi-line pipelines, the dedup regression, and the escape hatch.
# ---------------------------------------------------------------------------
f="$(mkscript "cont-backslash.sh" \
  'if commands_in "$f" 2>/dev/null \' \
  '   | grep -qE "NEEDLE"; then echo hit; fi')"
run_guard "$f" && rc=0 || rc=$?
report "flags: a pipeline continued with a trailing backslash" "$(yn test "$rc" -eq 1)" "rc=$rc"
report "flags: that pipeline is reported ONCE, not once per line it spans" \
  "$(yn test "$(grep -c 'stops at the first match' <<<"$out")" -eq 1)" "out=$out"
report "flags: it is reported at the line the pipeline STARTS on" \
  "$(yn grep -q ':3: ' <<<"$out")" "out=$out"

f="$(mkscript "cont-trailing-pipe.sh" \
  'printf "%s" "$v" |' \
  '  grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "flags: a pipeline whose pipe ends the line and grep starts the next" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A comment between the pipe and the grep. The join used to append the comment,
# which destroyed the trailing `|` it tested for on the next iteration, so the
# pipeline was dropped and the standalone grep line skipped.
f="$(mkscript "cont-comment-between.sh" \
  'printf "%s" "$v" |' \
  '  # explaining what the next line does' \
  '  grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "flags: a comment line between the pipe and the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

f="$(mkscript "cont-trailing-comment.sh" \
  'printf "%s" "$v" | # note' \
  '  grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "flags: a trailing comment after the pipe does not end the pipeline" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# NEGATIVE CONTROL: comment-skipping must not invent a pipeline where the
# previous line never ended in one, or every comment above a grep would flag.
f="$(mkscript "cont-comment-no-pipe.sh" \
  'printf "%s" "$v" > /tmp/x' \
  '  # an unrelated comment' \
  '  grep -q NEEDLE /tmp/x')"
run_guard "$f" && rc=0 || rc=$?
report "clean: a comment above a grep with no preceding pipe stays clean" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

f="$(mkscript "cont-trailing-or.sh" \
  'cached "$1" ||' \
  '  grep -q NEEDLE "$f"')"
run_guard "$f" && rc=0 || rc=$?
report "clean: a trailing '||' joined to a grep on the next line is still not a pipe" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

f="$(mkscript "allow-marker.sh" \
  'printf "%s" "$v" | grep -q NEEDLE # pipefail-grep-guard: allow — fixture text')"
run_guard "$f" && rc=0 || rc=$?
report "the escape hatch suppresses a line that must keep the offending text" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# NEGATIVE CONTROL for the escape hatch: the same line without the marker must
# flag. Otherwise "suppressed" would be indistinguishable from "never detected".
f="$(mkscript "allow-marker-control.sh" \
  'printf "%s" "$v" | grep -q NEEDLE # ordinary comment, no marker')"
run_guard "$f" && rc=0 || rc=$?
report "negative control: the same line WITHOUT the marker still flags" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# ---------------------------------------------------------------------------
# 2d. Multiple findings, multiple files, and the exit contract.
# ---------------------------------------------------------------------------
f1="$(mkscript "multi-a.sh" 'printf "%s" "$v" | grep -q A' 'printf "%s" "$v" | grep -q B')"
f2="$(mkscript "multi-b.sh" 'printf "%s" "$v" | grep -q C')"
out="$("$guard" "$f1" "$f2" 2>&1)" && rc=0 || rc=$?
report "reports every offending line across every named file" \
  "$(yn test "$(grep -c 'stops at the first match' <<<"$out")" -eq 3)" "rc=$rc out=$out"

f="$(mkscript "all-clean.sh" 'grep -q NEEDLE <<<"$v"' 'echo done')"
out="$("$guard" "$f" 2>&1)" && rc=0 || rc=$?
report "a clean file exits 0 and says so" \
  "$(yn test "$rc" -eq 0)" "rc=$rc"
report "the clean message names what was checked" \
  "$(yn grep -q 'no writer piped into an early-exiting grep' <<<"$out")" "out=$out"

out="$("$guard" "$tmp/does-not-exist.sh" 2>&1)" && rc=0 || rc=$?
report "an unreadable path is a usage error (exit 2), not a silent pass" \
  "$(yn test "$rc" -eq 2)" "rc=$rc out=$out"

# An empty file must scan cleanly rather than abort the run. Under `set -u`,
# bash 3.2 — the macOS system bash this guard also runs on — treats an empty
# array's `[@]` expansion as an unbound variable, so the natural array walk
# kills the whole sweep on the first empty script it meets.
: >"$tmp/empty.sh"
out="$("$guard" "$tmp/empty.sh" 2>&1)" && rc=0 || rc=$?
report "an empty file scans clean instead of aborting the sweep" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"
if [[ -x /bin/bash ]]; then
  out="$(/bin/bash "$guard" "$tmp/empty.sh" 2>&1)" && rc=0 || rc=$?
  report "...also under /bin/bash, which may be 3.2" \
    "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"
fi

# ---------------------------------------------------------------------------
# 2e. The finding must carry the fix, not just the complaint.
# ---------------------------------------------------------------------------
f="$(mkscript "message.sh" 'printf "%s" "$v" | grep -q NEEDLE')"
out="$("$guard" "$f" 2>&1)" && rc=0 || rc=$?
report "the finding names the offending flag" \
  "$(yn grep -q 'grep -q stops at the first match' <<<"$out")" "out=$out"
report "the finding tells the reader what to write instead" \
  "$(yn grep -q 'fix: feed grep without a pipe' <<<"$out")" "out=$out"

if ((fail != 0)); then
  echo "pipefail-grep-guard self-test: FAILURES above" >&2
  exit 1
fi
echo "pipefail-grep-guard self-test: all cases passed"
