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
  # `command grep`, never bare `grep`: under an agent harness the bare name can
  # resolve to a shim that drains its input instead of exiting at the first
  # match, and this probe is the one assertion that must exercise the REAL grep.
  # Through such a shim the piped form never fails, so the proof reports the
  # class refuted while it is live — the guard's own header measured 0/200 that
  # way against 200/200 through the system binary.
  cat "$probe_payload" | command grep -q NEEDLE >/dev/null 2>&1
  piped_rc=$?
  command grep -q NEEDLE <"$probe_payload" >/dev/null 2>&1
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

# A wrapper carrying its OWN options still reaches grep.
flag_case "env with an option before grep" \
  'printf "%s" "$v" | env -i grep -q NEEDLE'
flag_case "command with an option before grep" \
  'printf "%s" "$v" | command -p grep -q NEEDLE'

# GNU grep permutes options that follow operands to the front unless
# POSIXLY_CORRECT is set, so this IS an early exit — on the Linux runner where
# the required check actually executes. Stopping the walk at the operand
# reported it clean on exactly that platform.
flag_case "an option AFTER the pattern operand (GNU permutes it)" \
  'printf "%s" "$v" | grep PATTERN -q'
flag_case "an option after the operand, clustered" \
  'printf "%s" "$v" | grep PATTERN file -ql'

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
# GNU documents a max count of -1 as infinity: grep does not stop, so there is no
# writer to kill. Treating the -m letter as unconditionally early-exiting blocked
# a pipeline that cannot race.
clean_case "-m-1 is infinity, not an early exit" \
  'printf "%s" "$v" | grep -m-1 PATTERN'
clean_case "--max-count=-1 is infinity" \
  'printf "%s" "$v" | grep --max-count=-1 PATTERN'
clean_case "--max-count -1 as a separate word" \
  'printf "%s" "$v" | grep --max-count -1 PATTERN'

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

# The comment itself ends in a backslash. Bash continues the pipeline on the
# executable text, so letting the backslash branch win would rebuild the probe
# from the unstripped comment and hide the grep behind it.
f="$(mkscript "cont-comment-backslash.sh" \
  'printf "%s" "$v" | # rationale \' \
  '  grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "flags: a trailing comment ending in a backslash still continues the pipe" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# The whole-file directive must be a comment that BEGINS with it. A file that
# merely MENTIONS the phrase — this guard's own header and constant do — must
# still be scanned, or the guard silently exempts itself and its self-gate is
# decorative.
f="$(mkscript "allow-file-mention-only.sh" \
  '# The pipefail-grep-guard: allow-file directive is described here in prose.' \
  'MARKER="pipefail-grep-guard: allow-file"' \
  'printf "%s" "$v" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "flags: a file that only MENTIONS allow-file is still scanned" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# ...and the positive control: a real directive still exempts the file.
f="$(mkscript "allow-file-real-directive.sh" \
  '# pipefail-grep-guard: allow-file — this fixture is about the offending form' \
  'printf "%s" "$v" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "the real allow-file directive still exempts the whole file" \
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

# The escape hatch must not be reachable from EXECUTABLE text. A substring test
# let an assignment carrying the marker skip the line while still running the
# offending pipeline — the same self-exemption the whole-file directive already
# closes, one level down.
f="$(mkscript "allow-marker-in-code.sh" \
  'marker="pipefail-grep-guard: allow"; printf "%s" "$v" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "the marker in EXECUTABLE text does not suppress the finding" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A `${v#…}` expansion puts a `#` on the line without opening a comment, so the
# introducer must be anchored at line start or after whitespace.
f="$(mkscript "allow-marker-param-expansion.sh" \
  'x="${v#pipefail-grep-guard: allow}"; printf "%s" "$x" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "a '#' inside a parameter expansion is not a comment introducer" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# An assignment prefix may quote a value containing whitespace. The unquoted-only
# form stopped matching at the space, so the pipeline read as containing no grep.
f="$(mkscript "assign-quoted-value-double.sh" \
  'printf "%s" "$v" | LC_ALL="C UTF-8" grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "a double-quoted assignment value with whitespace does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

f="$(mkscript "assign-quoted-value-single.sh" \
  "printf '%s' \"\$v\" | LC_ALL='C UTF-8' grep -q NEEDLE")"
run_guard "$f" && rc=0 || rc=$?
report "a single-quoted assignment value with whitespace does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A shell WORD is adjacent fragments that need not agree on quoting, so matching
# only the fully-quoted and fully-unquoted shapes left the mixed one unmatched.
f="$(mkscript "assign-mixed-quoting.sh" \
  'printf "%s" "$v" | LC_ALL=C" UTF-8" grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "a mixed quoted/unquoted assignment value does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# An expansion can carry whitespace inside one assignment word.
f="$(mkscript "assign-command-substitution.sh" \
  "printf '%s' \"\$v\" | A=\$(printf 'C UTF-8') grep -q NEEDLE")"
run_guard "$f" && rc=0 || rc=$?
report "a command substitution in an assignment value does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

f="$(mkscript "assign-backtick-substitution.sh" \
  'printf "%s" "$v" | A=`printf "C UTF-8"` grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "a backtick substitution in an assignment value does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

f="$(mkscript "assign-parameter-expansion.sh" \
  'printf "%s" "$v" | A=${x-a b} grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "a parameter expansion in an assignment value does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# 🔴 The KNOWN LIMIT, pinned as fact rather than left as a surprise. Both cases
# below are the SAME defect: the pattern cannot tell a closing delimiter from a
# character that merely looks like one, because that needs shell-quote tracking
# inside the expansion. Nesting is one instance of it, not the rule — an earlier
# version of this suite pinned only the nested case and the comment claimed
# general non-nested support, which was an overclaim.
# These tests assert the CURRENT behaviour (exit 0) deliberately. If either
# starts failing, a real parser has replaced the layer and the expectation
# should be inverted — see monorepo#2797. Not a licence to leave it; a refusal
# to pretend the gap is narrower than it is.
f="$(mkscript "assign-nested-substitution-KNOWN-LIMIT.sh" \
  "printf '%s' \"\$v\" | A=\$(echo \$(printf 'C UTF-8')) grep -q NEEDLE")"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: a NESTED command substitution is not detected" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

f="$(mkscript "assign-quoted-paren-substitution-KNOWN-LIMIT.sh" \
  "printf '%s' \"\$v\" | A=\$(printf ') ') grep -q NEEDLE")"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: an UNNESTED substitution containing a quoted ')' is not detected either" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# ...and the OPENING delimiter, because the class excludes both. An earlier
# version of the documented boundary named only the closing one, which described
# the regex as more capable than it is.
f="$(mkscript "assign-open-paren-substitution-KNOWN-LIMIT.sh" \
  "printf '%s' \"\$v\" | A=\$(printf '(') grep -q NEEDLE")"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: a quoted OPENING '(' inside a substitution is not detected either" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# ...and ARITHMETIC expansion, which is a DIFFERENT construct rather than a `$(…)`
# carrying a paren as data — `$((` is two opening delimiters, so the class stops at
# the second one. Worth pinning separately because the boundary above reads as being
# about a delimiter appearing as data, and a reader would reasonably assume a plain
# `$((1 + 2))` is supported.
f="$(mkscript "assign-arithmetic-expansion-KNOWN-LIMIT.sh" \
  "printf '%s' \"\$v\" | A=\$((1 + 2)) grep -q NEEDLE")"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: an arithmetic expansion containing whitespace is not detected" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# The WHITESPACE is what makes the case above escape, so pin the other side too: with
# no spaces the whole `$((1+2))` is consumed by the bare-fragment alternative and the
# grep IS found. Without this, a later change that widens the expansion classes could
# lose the no-space case and nothing would notice.
f="$(mkscript "assign-arithmetic-expansion-no-space.sh" \
  "printf '%s' \"\$v\" | A=\$((1+2)) grep -q NEEDLE")"
run_guard "$f" && rc=0 || rc=$?
report "an arithmetic expansion with NO whitespace does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# Double quotes DO honour backslash escapes, so `\"` is a literal quote and does
# not end the fragment — the space after it is still inside the quoted value.
f="$(mkscript "assign-escaped-dquote.sh" \
  'printf "%s" "$v" | A="x\" y" grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "an escaped double quote inside a quoted assignment value does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# ANSI-C quoting also honours escapes. Not reported by a reviewer — covered because
# enumerating the quoting rules is what stops the next shape of this class.
f="$(mkscript "assign-ansi-c-quoting.sh" \
  "printf '%s' \"\$v\" | A=\$'x\\' y' grep -q NEEDLE")"
run_guard "$f" && rc=0 || rc=$?
report "an ANSI-C quoted assignment value does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# ...and the deliberate ASYMMETRY: single quotes do NOT honour escapes — a
# backslash inside them is literal — so `[^']*` is correct and must not be
# "fixed" to match the others. This pins that the single-quoted form still works.
f="$(mkscript "assign-single-quote-literal-backslash.sh" \
  "printf '%s' \"\$v\" | B='x\\\" y' grep -q NEEDLE")"
run_guard "$f" && rc=0 || rc=$?
report "a literal backslash inside a single-quoted assignment value still reaches the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A bare fragment may also carry a backslash-escaped character, including an
# escaped SPACE — `LC_ALL=C\ UTF-8` is a single word.
f="$(mkscript "assign-escaped-space.sh" \
  'printf "%s" "$v" | LC_ALL=C\ UTF-8 grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "an escaped space in an assignment value does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# ...and two assignment prefixes, the second one quoted — the fragment grammar
# must not consume the space that separates the prefixes from each other.
f="$(mkscript "assign-two-prefixes.sh" \
  'printf "%s" "$v" | A=1 B="x y" grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "two assignment prefixes, the second quoted, still reach the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A wrapper option can take its value as the FOLLOWING word. `-u` matched the
# bare-option alternative, but `UNUSED` then sat between the prefix and `grep`
# where nothing matched it, so the pipeline read as "no grep here".
f="$(mkscript "env-value-option.sh" \
  'producer | env -u UNUSED grep -q MATCH')"
run_guard "$f" && rc=0 || rc=$?
report "a value-consuming wrapper option (env -u NAME) does not hide the grep" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# ...and the false-POSITIVE direction: a shell operator ends grep's command, so
# the next command's flags are not grep's. This grep reads its input to the end.
f="$(mkscript "operator-ends-command.sh" \
  'printf "MATCH\n" | grep MATCH && sort -m /dev/null')"
run_guard "$f" && rc=0 || rc=$?
report "clean: '&& sort -m' is a separate command, not grep's early exit" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# Bash ends a comment at the newline, so a whole-line comment ending in `\` does
# NOT continue: the next line runs on its own and must still be scanned.
f="$(mkscript "comment-backslash-no-join.sh" \
  '# ordinary comment \' \
  'printf "%s" "$v" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "a whole-line comment ending in backslash does not swallow the next line" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# Any number of comment-only lines may sit between a trailing pipe and its
# command. The old 8-join cap stopped here and scanned the truncated probe.
f="$(mkscript "nine-comment-joins.sh" \
  'producer |' '# c1' '# c2' '# c3' '# c4' '# c5' '# c6' '# c7' '# c8' '# c9' \
  '  grep -q MATCH')"
run_guard "$f" && rc=0 || rc=$?
report "nine comment lines between the pipe and the grep do not hide it" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A heredoc body is DATA. A payload line that looks like the whole-file directive
# must not exempt the script — that fail-open is reachable by anyone who can add
# a heredoc.
f="$(mkscript "allow-file-in-heredoc.sh" \
  'cat <<EOF' \
  '# pipefail-grep-guard: allow-file — documentation only' \
  'EOF' \
  'printf "%s" "$v" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "an allow-file directive inside a heredoc body does not exempt the file" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# ...and its positive control: the SAME directive as a real comment still exempts.
f="$(mkscript "allow-file-real-after-heredoc.sh" \
  '# pipefail-grep-guard: allow-file — this fixture is about the offending form' \
  'cat <<EOF' \
  'payload' \
  'EOF' \
  'printf "%s" "$v" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "positive control: a real allow-file comment still exempts a file with a heredoc" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

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
# ...and the replacement it names must not silently drop the producer's exit
# status. Measured: the piped form returns the producer's 42, `< <(cmd)` returns
# 0 for the same producer, and the capture form returns 42. Asserted against the
# SAME output as the two reports above, so all four pin one message.
report "the fix line offers the form that keeps the producer's status" \
  "$(yn grep -q 'out="$(cmd)" then <<<"$out"' <<<"$out")" "out=$out"
report "the fix line warns that process substitution discards that status" \
  "$(yn grep -q 'DISCARDS the producer status' <<<"$out")" "out=$out"

# ---------------------------------------------------------------------------
# 2f. Where the command actually ENDS, and what is code rather than data.
#     Every case below was reported as a live defect and reproduced by running
#     the pipeline before it was fixed, so each keeps its twin: the fail-OPEN
#     ones must still flag, and the false-POSITIVE ones must still pass.
# ---------------------------------------------------------------------------
# Bash removes the quotes, so grep receives the ordinary -q option. Measured:
# both spellings exit 141 on a matching pipeline, and the walk read `"-q"` as an
# operand and called it clean.
flag_case "a QUOTED early-exit option is still that option" \
  'printf "%s" "$v" | grep "-q" NEEDLE'
flag_case "a single-quoted early-exit option too" \
  "printf \"%s\" \"\$v\" | grep '-q' NEEDLE"
# Its control: quote removal must not promote a value-consumed word to a flag.
# `-e` takes the next word, so the `-q` here is grep's PATTERN and the grep reads
# its input to the end.
clean_case "a quoted -q consumed by -e is a pattern, not a flag" \
  'printf "%s" "$v" | grep -e "-q" "$file"'

# Bash operators need no surrounding whitespace, so the walk ran past `MATCH;`
# into the NEXT command and read its flags as grep's.
clean_case "an attached semicolon ends the command before the next one's flags" \
  'printf "%s" "$v" | grep MATCH; sort -m /dev/null'
clean_case "an attached && does the same" \
  'printf "%s" "$v" | grep MATCH&& sort -m /dev/null'
# `|` ends a command exactly as `;` and `&` do. Listing only two of the three let
# the same rule reach opposite verdicts on the two spellings.
clean_case "an attached pipe ends it too, like its ; twin" \
  'printf "%s" "$v" | grep MATCH| sort -q x'
# The separator characters are DATA once quoted, and a second copy of this rule
# further down the walk disagreed: quote removal ran first, so the bare `;`
# matched an operator arm and the walk returned clean over a real early exit.
flag_case "a quoted separator as the whole pattern does not end the command" \
  "printf \"%s\" \"\$v\" | grep ';' -q"
flag_case "...but an early exit BEFORE that separator is still reported" \
  'printf "%s" "$v" | grep -q MATCH; sort -m /dev/null'
# Its control: an operator INSIDE quotes is an ordinary character, so the walk
# must keep going and still see the option that follows.
flag_case "a semicolon inside the pattern does not end the command" \
  'printf "%s" "$v" | grep "a;b" -q'

# A trailing comment is prose, not argv. Warning a reader off `-q` in a comment
# made this required check reject the safe line that comment describes.
clean_case "a trailing comment mentioning -q is not an option" \
  'printf "%s" "$v" | grep MATCH # do not replace this with -q'
flag_case "...but a real early exit carrying a trailing comment still flags" \
  'printf "%s" "$v" | grep -q MATCH # intentional'
# Its control: a `#` that OPENS a quoted pattern is not a comment introducer.
flag_case "a hash inside the pattern does not start a comment" \
  'printf "%s" "$v" | grep "#p" -q'

# A heredoc body is the script's OUTPUT. Scanning it as code made every
# documentation- or fixture-generating script demand a suppression.
f="$(mkscript "heredoc-payload.sh" \
  'cat <<DOC' \
  'producer | grep -q MATCH' \
  'DOC')"
run_guard "$f" && rc=0 || rc=$?
report "clean: a heredoc payload is data, not a pipeline that runs" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# Its control, and the reason the terminator must be FOUND before anything is
# masked: `<<` also appears as a left shift, and over-detecting an opener would
# hide real code from a required check. No line equals `bits`, so nothing is
# masked and the hazard below is still reported.
f="$(mkscript "shift-not-heredoc.sh" \
  'width=$(( total << bits ))' \
  'printf "%s" "$v" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "an unterminated <<word is not a heredoc, so the code after it is still scanned" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A heredoc whose opener sits on a line the CONTINUATION JOIN swallows is still a
# heredoc. Detecting openers as the scan reached them missed exactly these, since
# the join consumes lines without visiting them, and the payload was then scanned
# as code.
f="$(mkscript "heredoc-after-join.sh" \
  'producer |' \
  "  cat <<'DOC'" \
  'x | grep -q MATCH' \
  'DOC' \
  'echo done')"
run_guard "$f" && rc=0 || rc=$?
report "clean: a heredoc opened on a joined continuation line still hides its body" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# The other half of the same rule: a heredoc opener can itself END in a pipe, so
# the continuation join is offered the body as the next line. Skipping body lines
# as probe STARTS does not cover this — the probe starts on the opener, which is
# real code — so the join has to refuse them too, or payload text is appended to a
# live probe and matched there.
f="$(mkscript "heredoc-opener-ends-in-pipe.sh" \
  "cat <<'DOC' |" \
  'x | grep -q MATCH' \
  'DOC' \
  'echo done')"
run_guard "$f" && rc=0 || rc=$?
report "clean: the join does not pull a heredoc body into a live probe" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# ...and code after a heredoc that DOES terminate is scanned normally.
f="$(mkscript "code-after-heredoc.sh" \
  'cat <<DOC' \
  'just text' \
  'DOC' \
  'printf "%s" "$v" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "code after a closed heredoc is still scanned" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# The identifier-only opener pattern read `<<'---'` as no heredoc at all, so its
# payload was honoured as the whole-file directive and the real hazard below it
# went unreported — the same fail-open the heredoc tracking exists to close.
f="$(mkscript "punctuation-heredoc-delimiter.sh" \
  "cat <<'---'" \
  '# pipefail-grep-guard: allow-file — payload, not a directive' \
  '---' \
  'printf "%s" "$v" | grep -q NEEDLE')"
run_guard "$f" && rc=0 || rc=$?
report "a punctuation heredoc delimiter still hides its payload from the directive" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A here-string has no body, so it must never open one. The fixture is built so
# that dropping the exclusion is not merely harmless: the here-string's value
# ALSO appears as a lone line further down, so the terminator search succeeds and
# the pipeline between them is masked as payload. Without that coincidence the
# terminator rule masks the mistake and the assertion passes either way — which
# is the whole reason this case is spelled out rather than written the obvious
# way round.
f="$(mkscript "here-string-not-heredoc.sh" \
  'grep -q NEEDLE <<<"EOF"' \
  'printf "%s" "$v" | grep -q NEEDLE' \
  'EOF')"
run_guard "$f" && rc=0 || rc=$?
report "a here-string opens no heredoc, so the code below it is still scanned" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# Splitting the argv tail must not also do PATHNAME EXPANSION, or the guard's
# verdict depends on the caller's working directory. The fixture is run from a
# directory holding a file whose NAME contains a separator, so an expanded glob
# ends the command before the `-q` that follows it — the same finding, decided by
# where the sweep happened to be started from.
globdir="$tmp/globcwd"
mkdir -p "$globdir"
: >"$globdir/a;b.txt"
f="$(mkscript "glob-in-argv.sh" 'printf "%s" "$v" | grep *.txt -q')"
out="$(cd "$globdir" && "$guard" "$f" 2>&1)" && rc=0 || rc=$?
report "a glob in grep's arguments is not expanded against the caller's cwd" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# Reporting only the first offender on a logical line costs the reader a whole
# CI round to discover the second edit this blocking check requires.
f="$(mkscript "two-on-one-line.sh" 'printf A | grep -q A && printf B | grep -q B')"
out="$("$guard" "$f" 2>&1)" && rc=0 || rc=$?
report "both offenders on one logical line are reported, not just the first" \
  "$(yn test "$(grep -c 'stops at the first match' <<<"$out")" -eq 2)" "rc=$rc out=$out"

# Two offenders on one logical line share a file:line and a flag, so each block
# must say which of them it is — otherwise the pair is byte-identical and reads
# like one finding printed twice.
report "a pair on one line is numbered, so the two blocks are distinguishable" \
  "$(yn test "$(grep -c '\[[12] of 2 on this line\]' <<<"$out")" -eq 2)" "out=$out"
# ...and a lone finding is NOT numbered, or every ordinary report grows a count
# that is always "1 of 1".
f="$(mkscript "single-offender.sh" 'printf "%s" "$v" | grep -q A')"
run_guard "$f" && rc=0 || rc=$?
report "a single offender carries no of-N counter" \
  "$(yn test "$(grep -c 'on this line' <<<"$out")" -eq 0)" "rc=$rc out=$out"

if ((fail != 0)); then
  echo "pipefail-grep-guard self-test: FAILURES above" >&2
  exit 1
fi
echo "pipefail-grep-guard self-test: all cases passed"
