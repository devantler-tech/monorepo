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
#     Each case keeps its twin, because both directions must hold: the fail-OPEN
#     ones must flag, and the false-POSITIVE ones must pass. A fixture without its
#     twin can be satisfied by breaking the rule in the other direction.
# ---------------------------------------------------------------------------
# Bash removes the quotes, so grep receives the ordinary -q option: both
# spellings exit 141 on a matching pipeline, and a walk over the raw word reads
# `"-q"` as an operand.
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

# Masking a body is the one thing this guard does that can HIDE code, so a `<<`
# that is only TEXT must never start one. Each fixture below puts a real offender
# where the false body would be, so it passes only if nothing was masked.
f="$(mkscript "quoted-heredoc-operator.sh" \
  'EOF() { :; }' \
  "printf '%s\\n' '<<EOF'" \
  'printf "%s" "$v" | grep -q NEEDLE' \
  'EOF')"
run_guard "$f" && rc=0 || rc=$?
report "a quoted <<WORD is text, not a heredoc operator" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

f="$(mkscript "commented-heredoc-operator.sh" \
  '# see <<EOF for details' \
  'printf "%s" "$v" | grep -q NEEDLE' \
  'EOF')"
run_guard "$f" && rc=0 || rc=$?
report "a <<WORD inside a comment is not a heredoc operator either" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# Inside DOUBLE quotes a backslash escapes the next character, so the run does not
# end at `\"` and the `<<EOF` after it is still text. Ending the run there masked
# the pipeline below as heredoc data.
f="$(mkscript "escaped-quote-in-double-quotes.sh" \
  'printf "%s\n" "text\" <<EOF"' \
  'printf "%s" "$v" | grep -q NEEDLE' \
  'EOF')"
run_guard "$f" && rc=0 || rc=$?
report "an escaped quote does not end a double-quoted run" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# The ASYMMETRY control, and the reason the rule above is not simply "backslash
# escapes": inside SINGLE quotes a backslash is LITERAL, so `'text\'` really does
# end at the second quote and the `<<EOF` after it IS an operator.
#
# The pipeline sits INSIDE the body deliberately. Placing it after the terminator
# instead makes this pass whether or not the asymmetry is honoured — verified: an
# implementation escaping inside single quotes too keeps the run open, finds no
# heredoc at all, and still reports an offender below. Here, that implementation
# scans the body and reports it, while the correct one masks it.
f="$(mkscript "literal-backslash-in-single-quotes.sh" \
  "cat 'text\\' <<EOF" \
  'x | grep -q MATCH' \
  'EOF')"
run_guard "$f" && rc=0 || rc=$?
report "a backslash inside single quotes is literal, so the quote still closes" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# Its control: masking must still happen for a REAL operator, or the two
# assertions above would pass simply because heredocs stopped working.
f="$(mkscript "real-operator-still-masks.sh" \
  "cat <<'EOF'" \
  'x | grep -q MATCH' \
  'EOF')"
run_guard "$f" && rc=0 || rc=$?
report "positive control: an unquoted operator still hides its body" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# One command line can open SEVERAL heredocs, read in order. Tracking only the
# first left the second body unaccounted for in both directions at once.
f="$(mkscript "two-heredocs-one-line.sh" \
  'cat <<FIRST <<SECOND' \
  'first payload' \
  'FIRST' \
  'producer | grep -q MATCH' \
  'SECOND' \
  'echo done')"
run_guard "$f" && rc=0 || rc=$?
report "clean: the SECOND heredoc's payload is data too" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# The more serious half: a directive in that second payload must not exempt the
# file. This fixture puts a REAL offender after both terminators, so a pass here
# means the whole file stopped being scanned.
f="$(mkscript "allow-file-in-second-heredoc.sh" \
  'cat <<FIRST <<SECOND' \
  'first payload' \
  'FIRST' \
  '# pipefail-grep-guard: allow-file — payload, not a directive' \
  'SECOND' \
  'printf "%s" "$v" | grep -q REAL')"
run_guard "$f" && rc=0 || rc=$?
report "an allow-file line in the second payload does not exempt the file" \
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

# ---------------------------------------------------------------------------
# 2g. What is an OPERATOR and what is merely text that looks like one. Every
#     fail-open below puts a real offender where the false masking would hide it,
#     so each passes only if nothing was wrongly masked.
# ---------------------------------------------------------------------------
# An unquoted delimiter is an ordinary shell WORD: `cat <<+++` is valid.
f="$(mkscript "punctuation-delimiter-unquoted.sh" \
  'cat <<+++' \
  '# pipefail-grep-guard: allow-file — payload, not a directive' \
  '+++' \
  'printf "%s" "$v" | grep -q REAL')"
run_guard "$f" && rc=0 || rc=$?
report "an unquoted punctuation delimiter still hides its payload from the directive" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A plain `<<EOF` needs its terminator at column 0; an indented one is payload.
# Ending the body there makes the REST of the payload read as code, so a payload
# directive line exempts the file.
f="$(mkscript "indented-terminator-is-payload.sh" \
  'cat <<EOF' \
  '  EOF' \
  '# pipefail-grep-guard: allow-file — payload, not a directive' \
  'EOF' \
  'printf "%s" "$v" | grep -q REAL')"
run_guard "$f" && rc=0 || rc=$?
report "a space-indented line does not terminate a plain heredoc" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# ...and its control: `<<-` DOES accept a tab-indented terminator, so the body
# really ends there and the offender below it is scanned.
f="$(mkscript "dash-heredoc-tab-terminator.sh" \
  'cat <<-EOF' \
  'payload' \
  "$(printf '\tEOF')" \
  'printf "%s" "$v" | grep -q REAL')"
run_guard "$f" && rc=0 || rc=$?
report "positive control: <<- accepts a tab-indented terminator" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# An unquoted backslash is removed by bash, so grep receives an ordinary -q.
flag_case "a backslash-escaped early-exit option is still that option" \
  'printf "%s" "$v" | grep \-q NEEDLE'

# A pipeline inside a quoted string is documentation, not code.
clean_case "a quoted pipeline is text the script prints, not a pipeline it runs" \
  "printf '%s\\n' 'producer | grep -q MATCH'"

# `|` ends a word, so a `#` straight after it opens a comment with no space.
f="$(mkscript "comment-attached-to-pipe.sh" \
  'producer |# note' \
  '  grep -q MATCH')"
run_guard "$f" && rc=0 || rc=$?
report "a comment attached to the pipe does not stop the join" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A tracked *.sh symlink to a character device is readable and endless. Reading it
# hung this required job; it must fail in a controlled way instead.
ln -s /dev/zero "$tmp/hang.sh" 2>/dev/null || true
if [[ -L "$tmp/hang.sh" ]]; then
  out="$(ulimit -t 10; "$guard" "$tmp/hang.sh" 2>&1)" && rc=0 || rc=$?
  report "a non-regular tracked script is a controlled error, not a hang" \
    "$(yn test "$rc" -eq 2)" "rc=$rc out=$out"
fi

# A `#` also opens a comment straight after an OPERATOR, with no whitespace:
# `:;# <<EOF` is a comment, so its `<<EOF` must not open a body over real code.
# Same class as the `|#` continuation case above, at the heredoc scanner instead.
for op in ';' '&' '|'; do
  f="$(mkscript "comment-after-operator-$(printf '%s' "$op" | tr -c 'a-zA-Z0-9' '-').sh" \
    ":${op}# <<EOF" \
    'printf "%s" "$v" | grep -q NEEDLE' \
    'EOF')"
  run_guard "$f" && rc=0 || rc=$?
  report "a comment opened straight after '$op' is not a heredoc operator" \
    "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"
done

# Its control: a `#` that follows a WORD character is not an introducer — a
# `${v#pat}` expansion must not truncate the line, or a real heredoc after one
# stops being recognised and its payload is scanned as code.
f="$(mkscript "parameter-expansion-hash-not-a-comment.sh" \
  'x=${v#pat}' \
  'cat <<EOF' \
  'y | grep -q Z' \
  'EOF')"
run_guard "$f" && rc=0 || rc=$?
report "positive control: a \${v#pat} expansion still leaves the heredoc detectable" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# A delimiter is a WORD, and a word is adjacent fragments that need not agree on
# quoting: bash removes the quotes, so all three of these name `EOF`. Storing the
# raw spelling meant the terminator was never found and the payload was scanned as
# executable code — a false positive on a valid script.
for spelling in 'E"OF"' "E'OF'" '\EOF'; do
  f="$(mkscript "mixed-delimiter-$(printf '%s' "$spelling" | tr -c 'a-zA-Z0-9' '-').sh" \
    "cat <<$spelling" \
    'producer | grep -q MATCH' \
    'EOF')"
  run_guard "$f" && rc=0 || rc=$?
  report "clean: the delimiter <<$spelling names EOF after quote removal" \
    "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"
done

# Its control: an UNBALANCED quote is not a delimiter this can trust, so nothing
# is masked and the payload stays scanned — the conservative direction.
f="$(mkscript "unbalanced-delimiter-quote.sh" \
  'cat <<E"OF' \
  'producer | grep -q MATCH' \
  'EOF')"
run_guard "$f" && rc=0 || rc=$?
report "an unparsable delimiter masks nothing rather than guessing" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# A command substitution is EXECUTABLE even inside double quotes, so the common
# capture form really does run the pipeline and really does exhibit the hazard.
# Masking the whole quoted run hid it.
flag_case "a pipeline inside a double-quoted command substitution still runs" \
  'out="$({ printf "MATCH\n"; head -c 200000 /dev/zero; } | grep -q MATCH)"'

# ...and its control: the same text as DATA, with no substitution, is not a
# pipeline at all.
clean_case "the same text as a plain quoted string is not a pipeline" \
  "printf '%s\\n' 'out=| grep -q MATCH'"

# Single quotes suppress command substitution entirely, so a `$(` inside them is
# literal text. Treating it as executable — as the substitution support briefly
# did — exposed the inner pipeline and reported a safe script.
clean_case "a \$( inside single quotes is literal, not a substitution" \
  "printf '%s\\n' 'example: \$(producer | grep -q MATCH)'"

# ...and its twin, so the control above cannot pass by substitution support
# simply being removed: inside DOUBLE quotes the same text really does run.
flag_case "a \$( inside double quotes is a substitution and does run" \
  'printf "%s\n" "$(producer | grep -q MATCH)"'

# A trailing comment is prose. This is the probe-site twin of the heredoc
# scanner's rule, and both now go through one implementation.
clean_case "pipeline-shaped prose in a trailing comment is not a pipeline" \
  "printf 'ok\\n' # producer | grep -q MATCH"

# ...its control: the same line with the pipeline BEFORE the comment is real.
flag_case "a real pipeline carrying a trailing comment still flags" \
  'printf "%s" "$v" | grep -q MATCH # intentional'

# A plain heredoc terminates only on a line that is EXACTLY the delimiter — a
# trailing space makes it payload. Accepting it ended the body early, and the
# rest of the payload was then read as code.
f="$(mkscript "terminator-with-trailing-space.sh" \
  'cat <<EOF' \
  'EOF ' \
  '# pipefail-grep-guard: allow-file — payload, not a directive' \
  'EOF' \
  'printf "%s" "$v" | grep -q REAL')"
run_guard "$f" && rc=0 || rc=$?
report "a delimiter with trailing whitespace does not terminate a heredoc" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# ---------------------------------------------------------------------------
# 2h. The rollout gate. Enforcement ships LATENT, so both states are pinned here:
#     the sweep is conditional and the self-test is not.
# ---------------------------------------------------------------------------
ci="$here/../../.github/workflows/ci.yaml"
if [[ -r "$ci" ]]; then
  report "the repository-wide sweep is gated behind a default-off variable" \
    "$(yn grep -q "if: vars.ENFORCE_PIPEFAIL_GREP_GUARD == 'true'" "$ci")" "ci=$ci"
  report "the OFF state reports rather than silently skipping" \
    "$(yn grep -q "if: vars.ENFORCE_PIPEFAIL_GREP_GUARD != 'true'" "$ci")" "ci=$ci"
  # The self-test must NOT be gated: latent code that stops being tested is how a
  # flag flip turns into a surprise.
  report "the self-test itself is not gated" \
    "$(yn test "$(grep -c 'pipefail-grep-guard.test.sh' "$ci")" -ge 1)" "ci=$ci"
fi

# An empty assignment value is still an assignment prefix: `LC_ALL= grep -q` runs
# grep with that variable cleared.
flag_case "an EMPTY assignment prefix still reaches the grep" \
  'producer | LC_ALL= grep -q MATCH'

# GNU accepts any UNAMBIGUOUS ABBREVIATION of a long option, so these are the
# early-exit options under another spelling. Matched by prefix rather than by
# enumeration — grep's option set is finite, unlike the shell syntax elsewhere.
flag_case "an abbreviated --quiet is still --quiet" \
  'producer | grep --quie MATCH'
flag_case "an abbreviated --silent too" \
  'producer | grep --sil MATCH'
flag_case "an abbreviated --max-count with a finite value" \
  'producer | grep --max-c=1 MATCH'
# ...and the controls: a negative max count is still infinity, and a long option
# that is NOT an abbreviation of an early-exit one stays harmless.
clean_case "an abbreviated --max-count of -1 is still infinity" \
  'producer | grep --max-c=-1 MATCH'
clean_case "an unrelated long option is not an abbreviation of an early exit" \
  'producer | grep --invert-match MATCH'

# Abbreviation applies to VALUE-TAKING options too. This is the case that moves
# with the fix: `--reg` is `--regexp`, so `-q` is its value — grep's PATTERN, not
# an early exit — and reporting it blocks a valid script.
clean_case "an abbreviated --regexp consumes the following word as its value" \
  'producer | grep --reg -q MATCH'
# The two below pin the FLAG direction and are deliberately NOT discriminating
# for value-consumption: an operand does not stop the walk, so a real `-q` behind
# a value is found either way (ablation: removing the consumption loop fails only
# the case above). They guard against a future change that stops the walk early.
flag_case "a real -q behind a consumed --regexp value is still found" \
  'producer | grep --regexp PAT -q MATCH'
flag_case "an attached --regexp= value consumes nothing extra" \
  'producer | grep --regexp=PAT -q MATCH'

# ---------------------------------------------------------------------------
# 2i. KNOWN LIMITS, pinned as fact rather than left as surprises.
#
#     Each is reproduced and deliberately NOT patched: closing them needs real
#     shell parsing — arithmetic contexts, grouping parentheses, and a masker that
#     preserves command words — which the guard's line-oriented matching cannot
#     express, and which monorepo#2797 owns. Widening a regex moves which spelling
#     escapes rather than closing the class.
#
#     They are asserted at their CURRENT behaviour so the gaps are visible, a
#     change to any of them is deliberate, and a Go implementation inherits them
#     as a ready-made corpus. Enforcement is default-off, so none of them gates
#     anything today.
# ---------------------------------------------------------------------------
# The SPACED form is the one that reaches this gap: `$((total << bits))` is
# handled, so the fixture must keep its inner spaces to exercise it.
f="$(mkscript "known-limit-arith-shift.sh" \
  'width=$(( total << bits ))' \
  'producer | grep -q MATCH' \
  'bits')"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: a spaced arithmetic shift can look like a heredoc opener" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# An early-exit flag is required to reach this gap: without one the walk finds
# nothing to report, so `$(( producer | grep ))` is clean for a different reason.
f="$(mkscript "known-limit-arith-or.sh" 'value=$(( a | grep -q ))')"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: arithmetic bitwise-OR can read as a pipeline" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

f="$(mkscript "known-limit-grouping-parens.sh" 'out="$( (:) ; producer | grep -q MATCH )"')"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: a grouping ')' inside a substitution ends it early" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

f="$(mkscript "known-limit-quoted-command-word.sh" 'producer | "grep" -q MATCH')"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: a quoted command word is erased by masking" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# Legacy backtick substitution is executable inside double quotes, exactly as
# `$()` is — the masker suspends only the latter.
f="$(mkscript "known-limit-backtick-substitution.sh" 'out="`producer | grep -q MATCH`"')"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: a backtick substitution inside double quotes is masked as data" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# Bash quote-removes `<<"E\"OF"` to the delimiter E"OF; the fragment parser stops
# at the escaped quote, so the heredoc is not recognised and its payload is
# scanned as code.
f="$(mkscript "known-limit-escaped-delimiter.sh" \
  'cat <<"E\"OF"' \
  'producer | grep -q MATCH' \
  'E"OF')"
run_guard "$f" && rc=0 || rc=$?
report "KNOWN LIMIT: an escaped quote inside a delimiter word is not dequoted" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# `xargs` consumes the producer's ENTIRE stream and hands grep filenames, so grep
# never reads the pipe, nothing is SIGPIPEd, and the pipeline exits 0. While the
# assignment arm accepted a bare NAME, every such wrapper read as an environment
# prefix and this safe line was reported as an offender.
clean_case "a stream-consuming wrapper is not an assignment prefix" \
  'producer | xargs grep -q MATCH'
# The control differs in the one character that decides it: with `=` this IS an
# assignment prefix, so the grep behind it is still reached.
flag_case "an assignment prefix proper still reaches the grep" \
  'producer | WRAPPED=1 grep -q MATCH'

# ---------------------------------------------------------------------------
# 2i. Shebang classification, which only runs in the repository-wide sweep and
#     therefore needs a throwaway git repository rather than a bare fixture file.
# ---------------------------------------------------------------------------
# The sweep identifies extensionless scripts by their INTERPRETER. A `*sh` suffix
# test misses every versioned shell, so `#!/usr/bin/ksh93` was skipped while the
# sweep still reported the repository clean — silent omission, the one direction
# that fails open.
mkrepo() {
  local dir="$tmp/$1" shebang="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "guard-test@example.invalid"
  git -C "$dir" config user.name "guard test"
  printf '%s\nproducer | grep -q MATCH\n' "$shebang" >"$dir/tool"
  # A benign `*.sh` so the target set is never empty. The guard fail-closes with
  # exit 2 on a repository containing no shell scripts at all, which would other-
  # wise be indistinguishable from "the interpreter was correctly not swept".
  printf '#!/usr/bin/env bash\ntrue\n' >"$dir/noop.sh"
  git -C "$dir" add tool noop.sh
  git -C "$dir" -c commit.gpgsign=false commit -qm fixture
  printf '%s' "$dir"
}

r="$(mkrepo "shebang-versioned" '#!/usr/bin/ksh93')"
out="$(cd "$r" && "$guard" 2>&1)" && rc=0 || rc=$?
report "a version-suffixed shebang is swept, not silently skipped" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

r="$(mkrepo "shebang-via-env" '#!/usr/bin/env bash')"
out="$(cd "$r" && "$guard" 2>&1)" && rc=0 || rc=$?
report "an env-dispatched shebang resolves to the shell in its argument" \
  "$(yn test "$rc" -eq 1)" "rc=$rc out=$out"

# The control keeps the needle and changes only the interpreter: a non-shell
# script is not this guard's subject, so the same line must stay clean.
r="$(mkrepo "shebang-not-a-shell" '#!/usr/bin/perl')"
out="$(cd "$r" && "$guard" 2>&1)" && rc=0 || rc=$?
report "a non-shell interpreter is not swept" \
  "$(yn test "$rc" -eq 0)" "rc=$rc out=$out"

# Bash starts no comment inside a parameter expansion, so a `#` there is
# expansion syntax however it is preceded. Treating `${v:-|#foo}`'s hash as an
# introducer truncated the line and discarded every command behind it — the
# pipeline vanished before the scan reached it, which is a silent miss.
flag_case "a hash inside a parameter expansion does not truncate the line" \
  'x=${v:-|#foo}; producer | grep -q MATCH'
# The control differs only in being a REAL trailing comment: the pipeline behind
# a genuine `#` is not code, so it must stay clean.
clean_case "a genuine trailing comment still ends the code" \
  'x=1 # producer | grep -q MATCH'

# --- release-flag expiry ---------------------------------------------------
# `ENFORCE_PIPEFAIL_GREP_GUARD` gates the repository-wide sweep in ci.yaml. It is
# a RELEASE flag, so it is short-lived by contract and #2821 owns activating then
# removing it. This assertion is the forcing function: from the expiry date it
# fails, so the flag cannot quietly become permanent debt.
#
# Removing the flag means removing this case in the same change — a guard for a
# flag that no longer exists would fail forever with nothing to fix.
#
# `date -u +%Y%m%d` is the one spelling BSD and GNU agree on; every relative-date
# form differs between them, which is why the comparison is a plain integer.
flag_expiry=20260930
today="$(date -u +%Y%m%d)"
report "the ENFORCE_PIPEFAIL_GREP_GUARD release flag has not passed its expiry" \
  "$(yn test "$today" -lt "$flag_expiry")" \
  "today=$today expiry=$flag_expiry — activate and remove the flag per #2821"

if ((fail != 0)); then
  echo "pipefail-grep-guard self-test: FAILURES above" >&2
  exit 1
fi
echo "pipefail-grep-guard self-test: all cases passed"
