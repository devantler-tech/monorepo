#!/usr/bin/env bash
# pipefail-grep-guard.sh — reject piping a writer into a grep that exits early.
#
# WHY THIS EXISTS
#   `grep -q` stops reading at its FIRST match and exits 0. The writer upstream
#   is then killed by SIGPIPE (or its `write` returns EPIPE), so it exits
#   non-zero. Under `set -o pipefail` the pipeline reports the WRITER's failure,
#   not grep's success — so a pipeline that MATCHED reports failure.
#
#   Measured on this host (bash 3.2, BSD grep), needle first, payload after:
#
#     printf … | grep -q NEEDLE     ->  status 141, PIPESTATUS=(141 0)
#                                       i.e. writer SIGPIPE'd, grep matched.
#
#   It is a race between grep's exit and the writer's next write. The variable
#   that decides it is HOW MUCH IS STILL UNWRITTEN AFTER THE MATCH — not the
#   total payload size. Re-measured with /usr/bin/grep, 50 reps, every fixture
#   first asserted to match under the no-pipe control:
#
#     match FIRST + 8 KB tail   50/50      match LAST after 8 KB      0/50
#     match FIRST + 1 KB tail   47/50      one short anchored line    0/50
#     match FIRST + 100 B tail   0/50
#
#   So a site whose match lands at or near the END of the stream, or whose
#   stream is tiny, never fires; a site where the match can land early with
#   >=1 KB still unwritten fires ~94-100%. (An earlier run recorded 80/100 at a
#   100-byte payload, which this run could not reproduce — the two differ in
#   whether those bytes sat before or after the match. Treat the tail as the
#   variable and re-measure rather than trusting either figure.)
#
#   A short fixture can pass a hundred times and the same line still flip in
#   production. Do not try to prove or refute this class with a length test.
#
#   !! MEASURING THIS UNDER AN AGENT HARNESS: check `which grep` FIRST. If it
#   prints a FUNCTION BODY rather than a path, `grep` has been shimmed (Claude
#   Code redirects it to ugrep), and the shim does NOT reproduce this class --
#   the same 4 KB fixture read 0/200 through it and 200/200 through
#   /usr/bin/grep. The shim is inherited by `bash script.sh` children, so
#   writing the repro to a file does not escape it. Call /usr/bin/grep or
#   `command grep` explicitly, or the class looks refuted when it is live.
#
#   Both polarities break, and the second one FAILS OPEN:
#     if  cmd | grep -q PAT   -> matched, reported as not-matched  (noisy)
#     if ! cmd | grep -q PAT  -> matched, reported as matched-not  (SILENT)
#   The second shape is how six guard assertions in board-add.test.sh stopped
#   guarding while still printing `ok`.
#
#   The flag family is the discriminator, confirmed by execution rather than
#   read from a manual: -q/--quiet/--silent, -l/--files-with-matches and
#   -m/--max-count all stop early and all reproduce it; -c, -L and a plain grep
#   read their input to the end and never do. One exception: a NEGATIVE max count
#   is infinity (`grep -m-1`), so grep does not stop and that form is clean.
#
#   Options are recognised AFTER the pattern operand too. GNU permutes them to
#   the front unless POSIXLY_CORRECT is set, so `grep PATTERN -q` is an early exit
#   on the Linux runner this check runs on. Only `--` ends option parsing.
#
# THE FIX THIS GUARD ASKS FOR
#   Feed grep without a pipe, so there is no writer to kill:
#     grep -q PAT <<<"$var"                  # value already in a variable
#     out="$(cmd)"; grep -q PAT <<<"$out"    # output of a command
#     grep -q PAT file                       # a file
#
#   `grep -q PAT < <(cmd)` also removes the pipe, but it is the one replacement
#   that CHANGES WHAT THE ASSERTION COVERS: a process substitution's exit status
#   is reported nowhere, so a producer that fails is silently accepted. Measured
#   on this host, needle present in every case:
#
#     { printf 'MATCH\n'; exit 42; } | grep -q MATCH          ->  42
#     grep -q MATCH < <({ printf 'MATCH\n'; exit 42; })       ->   0
#     out="$({ printf 'MATCH\n'; exit 42; })"                 ->  42
#
#   A pipeline that was validating BOTH successful production and a match keeps
#   both only in the capture form, which is why that is what the finding prints.
#   Reach for process substitution where the producer's status genuinely does not
#   matter, or where it is checked separately.
#
# SCOPE
#   Every tracked shell script, not only the ones that set pipefail themselves.
#   A file-local pipefail test would fail open on a sourced library:
#   worktree-claim-lib.sh sets no pipefail of its own and always runs inside a
#   caller that does. The here-string form is correct either way.
#
#   Every tracked shell script means exactly that: a file is in scope when it is
#   named `*.sh` OR its shebang names a shell, so an extensionless `bin/check`
#   is scanned too.
#
#   The command right after the pipe must be grep itself — optionally behind
#   VAR=value prefixes, a `command`/`env` wrapper, or an absolute path, since
#   this header tells the reader to reach for exactly those spellings to escape
#   a harness shim. `producer | xargs grep -l …` is the same hazard and is
#   NOT detected — xargs would take the SIGPIPE instead. There is no instance of
#   it in this repository, so the pattern stays narrow rather than growing an
#   xargs argument parser; extend it here if one ever appears.
#
#   ⚠️ KNOWN, MEASURED LIMIT of the same kind: `producer | env -S 'grep -q MATCH'`
#   runs grep and exhibits the hazard, and is NOT detected — GNU env's
#   `-S`/`--split-string` builds the command from inside a quoted VALUE, so the
#   command name does not appear as a word where this grammar looks for it.
#   Detecting it means parsing an option's value as a command line, which is the
#   wrapper-level twin of the quoting problem that monorepo#2797 replaces this
#   layer to solve. There is no instance in this repository. Deferred there rather
#   than patched here: the prefix grammar matches command WORDS, so a command built
#   inside an option value is outside what it can express, and widening the grammar
#   moves which spelling escapes rather than closing the class.
#
# ESCAPE HATCH
#   A line carrying `pipefail-grep-guard: allow` AFTER A `#` is skipped, so a
#   fixture that must contain the offending text stays possible without turning
#   the guard off. Say why in the same comment. The `#` is required: the marker
#   sitting in executable text — an assignment, a string — does NOT disable the
#   check, or the escape hatch would be reachable by the code it exempts.
#
#   A COMMENT LINE BEGINNING WITH `pipefail-grep-guard: allow-file` skips the
#   whole file. It must open the comment — a mention inside prose, backticks or a
#   string does not count, which is why this very paragraph does not disable the
#   guard on its own source.
#   That is for a file whose SUBJECT is this bug — this guard's own self-test
#   both quotes the offending form as fixture text and executes it on purpose.
#   Both markers are plain text in a reviewable diff; neither disables the job.
#
# USAGE
#   pipefail-grep-guard.sh [path ...]
#       With no paths, scans every tracked shell script in the repository —
#       `*.sh` by name, plus any tracked file whose shebang names a shell.
#
# EXIT CODES
#   0  no offending pipeline found
#   1  at least one offending pipeline found (each is printed)
#   2  usage, or the repository/file could not be read

set -Eeuo pipefail
# The option walk distinguishes -l from -L, so pattern matching must stay
# case-sensitive whatever the caller's shell options are.
shopt -u nocasematch

# The line-level directive is matched only where a `#` introduces it, never as a
# bare substring of the logical line. A substring test let EXECUTABLE text carry
# the escape hatch — `marker='pipefail-grep-guard: allow'; printf … | grep -q X`
# skipped the line while running the very pipeline this guard exists to catch.
# That is the same fail-open the whole-file directive already closes, one level
# down, so it gets the same treatment: the marker must sit after a `#` that
# begins at line start or after whitespace (so a `${v#…}` expansion is not a
# comment introducer).
# ⚠️ RESIDUAL, stated rather than papered over: a `#` inside a QUOTED string
# ahead of the marker still reads as an introducer. Deciding that needs real
# quote tracking, which this file deliberately does not do (see the trailing-
# comment note at the probe site). The bar this clears is the reported hole —
# executable text with no `#` at all — not every constructible bypass.
ALLOW_LINE_RE='(^|[[:space:]])#.*pipefail-grep-guard:[[:space:]]*allow'

# The whole-file directive is matched as a COMMENT LINE THAT BEGINS WITH IT, not
# as a substring anywhere in the file. A substring test made this guard exempt
# ITSELF: the phrase appears in its own header prose and again in the constant
# below, so scanning `pipefail-grep-guard.sh` returned before inspecting a single
# executable line — and the workflow's self-gate could never have caught a
# pipe-to-quiet-grep introduced into this very file. Requiring the directive to
# open its comment keeps a deliberate `# pipefail-grep-guard: allow-file — why`
# working while a mention inside prose, backticks or an assignment does not.
ALLOW_FILE_RE='^[[:space:]]*#[[:space:]]*pipefail-grep-guard:[[:space:]]*allow-file([[:space:]]|$)'

die() {
  echo "pipefail-grep-guard: $*" >&2
  exit 2
}

usage() {
  sed -n '/^# USAGE/,/^# EXIT CODES/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

case "${1:-}" in
  -h | --help) usage ;;
esac

# --- the option walk -------------------------------------------------------
# Given everything that follows `grep` on the line, decide whether grep was
# asked to stop at the first match. Options are read in the normal way: stop at
# `--` or at the first non-option word, so a PATTERN or filename that merely
# contains "-q" is never mistaken for a flag.
#
# Cluster letters are matched case-sensitively on purpose. `-L` reads its input
# to the end (it must, to prove the absence of a match) and is NOT an offender;
# `-l` is.
#
# `-m`/`--max-count` is early-exiting for every value EXCEPT a negative one: GNU
# documents -1 as infinity, where grep does not stop, so `grep -m-1` reads to the
# end and is not this hazard. Treating the letter as unconditionally early-exiting
# blocked a pipeline that cannot race.
#
# The walk does NOT stop at the first operand. GNU grep permutes options that
# follow operands to the front unless POSIXLY_CORRECT is set, so
# `producer | grep PATTERN -q` IS an early exit on the Linux CI runner — stopping
# at PATTERN reported the hazard clean on the very platform the required check
# runs. Only `--` ends option parsing.
# True only for a max-count that can actually stop grep mid-stream. Two values
# cannot: a NEGATIVE count is infinity, and ZERO selects nothing, so grep never
# reaches a match to stop at and the pipeline's failure means "no match" in both
# the ordinary and the negated form — which is the correct reading rather than
# the misreported-match this guard exists to catch. Reporting either blocks a
# safe command, the false-positive direction that keeps enforcement latent.
#
# Zero is decided by VALUE, never by a leading-`0` glob: `-m01` is one, so a
# pattern like `0*` would read a real early exit as harmless — the fail-open
# direction. Strip leading zeros and test what remains, which needs no arithmetic
# on an unvalidated string.
max_count_is_finite() {
  local v="$1"
  case "$v" in
    -*) return 1 ;;        # negative: infinity, grep reads to the end
    '') return 1 ;;        # no value: grep errors out, so the pipeline never races
    *[!0-9]*) return 0 ;;  # not a bare decimal — stay conservative and report it
  esac
  while [ "${v#0}" != "$v" ]; do v="${v#0}"; done
  [ -n "$v" ] || return 1  # every digit was a zero
  return 0
}

# Take the next whitespace-delimited token from `$1`, honouring single and double
# quotes so a quoted value containing a space stays ONE token. Sets `_env_tok` to
# the token exactly as written (quotes included), so the caller can strip precisely
# it off the front. `env -S` splits its string with those quoting rules, so a raw
# whitespace split reads `#!/usr/bin/env -S LABEL='a b' bash` as the two tokens
# `LABEL='a` and `b'` — making `b'` the command, resolving to no shell, and
# dropping the file from the sweep. An unterminated quote consumes the remainder,
# which is what a shell would do with the same malformed line.
env_next_token() {
  local s="$1" i=0 c q='' out=''
  while [[ "$i" -lt "${#s}" ]]; do
    c="${s:i:1}"
    if [[ -n "$q" ]]; then
      out="$out$c"
      [[ "$c" == "$q" ]] && q=''
    else
      case "$c" in
        [[:space:]]) break ;;
        \' | \") q="$c" && out="$out$c" ;;
        *) out="$out$c" ;;
      esac
    fi
    i=$((i + 1))
  done
  _env_tok="$out"
}

# Strip ONE balanced layer of quotes, so `env -S 'bash' -x` resolves to `bash`
# rather than to a name no shell list can match.
env_dequote() {
  local w="$1"
  case "$w" in
    \'*\') w="${w#\'}" && w="${w%\'}" ;;
    \"*\") w="${w#\"}" && w="${w%\"}" ;;
  esac
  printf '%s' "$w"
}

# Resolve the command `env` would execute, given a shebang line with `#!` already
# removed. env's own options come first, so the operand is not simply the second
# word. Value-taking options consume their value; `-S`/`--split-string` introduces
# a command line whose FIRST word is the command, attached (`-Sbash`) or separate
# (`-S bash`); `--` ends option parsing. Prints the empty string when no operand
# remains, which resolves to no shell and leaves the file out of scope — the same
# answer as before for a shebang that genuinely names none.
env_operand() {
  local rest="$1" tok _env_tok
  rest="${rest#"${rest%%[![:space:]]*}"}"
  rest="${rest#"${rest%%[[:space:]]*}"}" # drop env's own path
  while :; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    [[ -n "$rest" ]] || break
    env_next_token "$rest"
    tok="$_env_tok"
    case "$tok" in
      --) rest="${rest#--}"; break ;;
      -S | --split-string) rest="${rest#"$tok"}" ;;
      --split-string=*) rest="${rest#--split-string=}" ;;
      -S?*) rest="${rest#-S}" ;;
      --unset=* | --chdir=*) rest="${rest#"$tok"}" ;;
      -u | -C | --unset | --chdir)
        # Consume the option AND the separate word carrying its value — through the
        # same quote-aware reader, since that value can be quoted too.
        rest="${rest#"$tok"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        env_next_token "$rest"
        rest="${rest#"$_env_tok"}"
        ;;
      -*) rest="${rest#"$tok"}" ;;
      [A-Za-z_]*=*) rest="${rest#"$tok"}" ;; # NAME=value assignment
      *) break ;;
    esac
  done
  rest="${rest#"${rest%%[![:space:]]*}"}"
  env_next_token "$rest"
  env_dequote "$_env_tok"
}

# Replace the CONTENTS of quoted runs with `x`, so a character that is only
# meaningful OUTSIDE quotes is not read as meaningful inside them. Sets `_masked`
# to a string of exactly the same length as its input, so an index into one also
# indexes the other.
#
# Deliberately NOT a general quoting model — it is a single-line, single-purpose
# primitive for "is this character quoted": it does not track quotes across lines,
# and `$'…'` is treated as a `'…'` run preceded by a `$`, which is right for
# locating operators and wrong for reading the value. Its one caller uses it only
# to decide whether a `<<` is an operator; see monorepo#2797 for the tokenizer
# that would let the argv walk share it.
mask_quoted() {
  local s="$1" out="" c q="" i esc=0 depth=0
  local -a saved_q=()
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    # A COMMAND SUBSTITUTION IS EXECUTABLE EVEN INSIDE DOUBLE QUOTES. Masking the
    # whole quoted run hid the pipeline in the common assertion form
    # `out="$(producer | grep -q MATCH)"`, which really does run and really does
    # exhibit this hazard. So `$(` suspends the quoted run and its body is emitted
    # as code; the matching `)` resumes it. Depth is tracked because a
    # substitution can contain another.
    # ...but ONLY where bash would actually substitute. Single quotes suppress it
    # entirely, so `'example: $(producer | grep -q MATCH)'` is literal text;
    # entering this branch regardless exposed that text as code and reported a
    # safe script. The state test must come first.
    if [[ "$q" != "'" && "$c" == '$' && "${s:i+1:1}" == '(' ]]; then
      saved_q[depth]="$q"
      depth=$((depth + 1))
      q=""
      esc=0
      out+='$('
      i=$((i + 1))
      continue
    fi
    if [[ -z "$q" && "$c" == ')' ]] && ((depth > 0)); then
      depth=$((depth - 1))
      q="${saved_q[depth]}"
      [[ "$q" == "'" ]] && esc=0
      out+=')'
      continue
    fi
    # ANSI-C quoting: `$'…'` DOES honour backslash escapes, unlike a plain `'…'`.
    # Treating it as an ordinary single-quoted run ended it at the `\'` in
    # `A=$'x\' y'`, so the rest of the line read as quoted and a REAL pipeline
    # after it was masked away — a fail-open the suite caught.
    if [[ -z "$q" && "$c" == '$' && "${s:i+1:1}" == "'" ]]; then
      q="'"
      esc=1
      out+=xx
      i=$((i + 1))
      continue
    fi
    if [[ -n "$q" ]]; then
      if ((esc)) && [[ "$c" == '\' ]] && ((i + 1 < ${#s})); then
        out+=xx
        i=$((i + 1))
        continue
      fi
      # THE TWO QUOTE TYPES ESCAPE DIFFERENTLY, and treating them alike breaks
      # one case or the other. Inside DOUBLE quotes a backslash escapes the next
      # character, so `"text\" <<EOF"` is one word and its `<<EOF` is TEXT —
      # closing the run at that escaped quote made it read as an operator and
      # masked the code below. Inside SINGLE quotes a backslash is LITERAL, so
      # `'text\'` really does end at the second quote and a following `<<EOF` IS
      # an operator. Both were confirmed by running bash, not read from a manual.
      if [[ "$q" == '"' && "$c" == '\' ]] && ((i + 1 < ${#s})); then
        out+=xx
        i=$((i + 1))
        continue
      fi
      if [[ "$c" == "$q" ]]; then
        q=""
        esc=0 # must clear with the run, or a later plain '…' inherits escaping
      fi
      out+=x
      continue
    fi
    case "$c" in
      \" | \')
        q="$c"
        out+=x
        ;;
      \\)
        # A backslash escapes the next character, so neither can be an operator.
        out+=x
        if ((i + 1 < ${#s})); then
          out+=x
          i=$((i + 1))
        fi
        ;;
      *) out+="$c" ;;
    esac
  done
  _masked="$out"
}

# Cut a syntactic trailing comment off a line, given its masked copy ($1) and the
# raw line ($2). Sets `_code_mask` and `_code_raw` to the executable part; returns
# 1 when the whole line is comment.
#
# ONE IMPLEMENTATION, because this rule kept drifting. `#` introduces a comment at
# line start, after whitespace, or STRAIGHT AFTER AN OPERATOR — `:;# <<EOF` and
# `producer |# note` are comments with no whitespace anywhere. This file decides
# "where does code end" in several places, and each site that grew its own version
# of the rule became a defect: one missed operator-adjacent comments in the heredoc
# scanner, another let pipeline-shaped prose in a trailing comment be matched as a
# live pipeline.
#
# Reading the MASKED copy is what makes it safe: a `#` inside quotes is already an
# `x`, and a `${v#…}` expansion is not an introducer either, since its `#` follows
# a word character.
strip_comment() {
  local m="$1" raw="$2" i depth=0
  _code_mask="$m"
  _code_raw="$raw"
  for ((i = 0; i < ${#m}; i++)); do
    # Track `${…}` nesting. Bash does not start a comment inside a parameter
    # expansion, so a `#` there is expansion syntax whatever precedes it.
    #
    # The "follows a word character" rule below already covers `${v#pat}`, but it
    # does NOT cover a `#` that follows one of the introducer characters INSIDE
    # the expansion: `${v:-|#foo}` truncates the line at the `|#`, discarding
    # every command after it. That is a SILENT MISS — the pipeline the guard
    # exists to catch simply disappears before the scan sees it.
    if [[ "${m:i:1}" == '$' && "${m:i+1:1}" == '{' ]]; then
      depth=$((depth + 1))
      ((i++))
      continue
    fi
    if ((depth > 0)) && [[ "${m:i:1}" == '}' ]]; then
      depth=$((depth - 1))
      continue
    fi
    [[ "${m:i:1}" == '#' ]] || continue
    ((depth > 0)) && continue
    ((i == 0)) && return 1
    case "${m:i-1:1}" in
      [[:space:]] | ';' | '&' | '|' | '(' | ')')
        _code_mask="${m:0:i}"
        _code_raw="${raw:0:i}"
        return 0
        ;;
    esac
  done
  return 0
}

# --- cross-line quote state ------------------------------------------------
# The quote state at the END of a line, given the state at its start:
#   0 code, 1 inside '…', 2 inside "…"
#
# The whole-file allow directive is honoured only from a SYNTACTIC comment, and
# a physical line inside a multi-line STRING is data exactly as a heredoc body
# is. Without this, a quoted payload containing a line that begins
# `# pipefail-grep-guard: allow-file` exempted the entire script — a fail-open
# anyone who can add a string could reach.
#
# Deliberately biased: where this cannot tell, it prefers to report a line as
# QUOTED. Being wrong that way costs a missed exemption and the file is scanned
# anyway; being wrong the other way skips the whole file, which is the direction
# that hides hazards.
#
# Single quotes honour no escapes; double quotes and code do. A `#` that starts a
# comment ends the line's quote significance, so an apostrophe in prose
# (`# don't`) cannot leak an open quote into the following lines.
_QUOTE_STATE=0
advance_quote_state() {
  local s="$1" st="$2" i c prev=''
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$st" in
      0)
        case "$c" in
          '\') ((i++)) ;;
          "'") st=1 ;;
          '"') st=2 ;;
          '#')
            # Same introducer rule as strip_comment: a `#` opens a comment only
            # at the start of a word.
            if [[ -z "$prev" ]]; then break; fi
            case "$prev" in
              [[:space:]] | ';' | '&' | '|' | '(' | ')') break ;;
            esac
            ;;
        esac
        ;;
      1) [[ "$c" == "'" ]] && st=0 ;;
      2)
        case "$c" in
          '\') ((i++)) ;;
          '"') st=0 ;;
        esac
        ;;
    esac
    prev="$c"
  done
  _QUOTE_STATE="$st"
}

# --- heredoc detection -----------------------------------------------------
# Sets HEREDOC_TERMS/HEREDOC_COUNT to EVERY static delimiter the line opens, in
# the order bash reads their bodies, and returns 0 when there is at least one.
#
# One line can open more than one: `cat <<FIRST <<SECOND` reads FIRST's body, then
# SECOND's. Handling only the first delimiter left the second body unaccounted
# for in both directions at once — the scan read it as executable code (a false
# positive on output text), and the allow-file prepass read a payload line in it
# as a real whole-file directive, which exempted the script and hid a genuine
# offender below.
#
# A static delimiter is NOT restricted to identifiers either: `cat <<'---'` ends
# at a line reading `---`, and an identifier-only pattern read it as no heredoc.
#
# `<<<` is a HERE-STRING and opens no body. It is skipped PER OPERATOR rather than
# by rejecting the whole line, so a line carrying both still yields its heredoc.
#
# Scanning by hand rather than by regex: bash offers no repeated-match iteration,
# and the alternative — re-matching a growing anchored pattern per delimiter —
# was the shape that kept producing parsing gaps here. Each iteration consumes at
# least the `<<` it matched, so the walk always terminates.
#
# 🔴 THE `<<` MUST BE AN OPERATOR, NOT TEXT THAT LOOKS LIKE ONE. Masking a body is
# the one thing this guard does that can HIDE code, so a `<<` inside a quoted word
# or a comment must never start one. Both were live fail-opens:
#
#     printf '%s\n' '<<EOF'          # quoted: not a redirection
#     # see <<EOF for details        # a comment: not code at all
#     printf '%s' "$v" | grep -q X   <- masked, and silently unreported
#     EOF
#
# Deciding it needs the quote state of the line, so the operator search runs over
# a MASKED copy in which quoted content is replaced character-for-character. The
# delimiter is then read from the ORIGINAL at the same offset, because a delimiter
# may legitimately be quoted (`<<'---'`) and masking would erase its text.
HEREDOC_TERMS=()
HEREDOC_DASH=()
HEREDOC_COUNT=0
heredoc_delimiters() {
  local raw="$1" s d frag m i len dash
  HEREDOC_TERMS=()
  HEREDOC_DASH=()
  HEREDOC_COUNT=0
  # Cheap reject FIRST. Masking walks the line character by character, and this
  # runs on every line of every scanned file — doing it unconditionally pushed a
  # full sweep past five minutes, which is a real cost on a required check. The
  # overwhelming majority of lines contain no `<<` at all.
  [[ "$raw" == *'<<'* ]] || return 1
  # Second cheap reject: with nothing quotable on the line, the line IS its own
  # mask. `cat <<EOF` — the common form by far — takes neither walk.
  case "$raw" in
    *[\'\"\#\\]*)
      mask_quoted "$raw"
      m="$_masked"
      ;;
    *) m="$raw" ;;
  esac
  strip_comment "$m" "$raw" || return 1
  m="$_code_mask"
  raw="$_code_raw"
  len=${#m}
  for ((i = 0; i + 1 < len; i++)); do
    [[ "${m:i:2}" == '<<' ]] || continue
    # A third `<` makes it a here-string, which opens no body. Step past ALL
    # THREE: advancing by one would leave the overlapping `<<` at the next index
    # to be read as an opener, and `<<<"EOF"` would then mask the file from a
    # here-string's VALUE — which the suite caught as a regression here.
    if [[ "${m:i+2:1}" == '<' ]]; then
      i=$((i + 2))
      continue
    fi
    # Read the delimiter from the UNMASKED line at this offset.
    s="${raw:i+2}"
    dash=0
    if [[ "$s" == -* ]]; then
      # `<<-` strips leading TABS from the body and from its terminator. Which
      # form opened the body decides how its terminator is matched, so it is
      # recorded per delimiter rather than discarded here.
      dash=1
      s="${s#-}"
    fi
    while [[ "$s" == [[:space:]]* ]]; do s="${s#?}"; done
    # A DELIMITER IS A WORD, AND A WORD IS A RUN OF ADJACENT FRAGMENTS THAT NEED
    # NOT AGREE ON QUOTING. Bash removes the quotes, so `<<E"OF"` and `<<E'OF'`
    # both name the terminator `EOF`, and `<<+++` names `+++` — an unquoted
    # delimiter is an ordinary word, not an identifier.
    #
    # Storing the raw spelling meant the terminator was never found, the body was
    # never masked, and the payload was scanned as executable code: a FALSE
    # POSITIVE on a valid script. Handling only the fully-quoted and fully-bare
    # shapes is the same mistake the assignment-value grammar below already
    # records — a word is fragments, so parse fragments.
    #
    # An unbalanced quote leaves `d` empty and the opener is skipped, which masks
    # nothing. That is the conservative direction here: the payload stays scanned.
    d=""
    while [[ -n "$s" ]]; do
      case "$s" in
        "'"*)
          frag="${s#\'}"
          [[ "$frag" == *"'"* ]] || {
            d=""
            break
          }
          s="${frag#*\'}"
          d+="${frag%%\'*}"
          ;;
        '"'*)
          frag="${s#\"}"
          [[ "$frag" == *'"'* ]] || {
            d=""
            break
          }
          s="${frag#*\"}"
          d+="${frag%%\"*}"
          ;;
        \\?*)
          d+="${s:1:1}"
          s="${s:2}"
          ;;
        [[:space:]]* | ';'* | '&'* | '|'* | '<'* | '>'* | '('* | ')'*) break ;;
        *)
          frag="${s%%[[:space:];\&|<>()\'\"\\]*}"
          [[ -n "$frag" ]] || break
          d+="$frag"
          s="${s#"$frag"}"
          ;;
      esac
    done
    [[ -n "$d" ]] || continue
    HEREDOC_TERMS[HEREDOC_COUNT]="$d"
    HEREDOC_DASH[HEREDOC_COUNT]="$dash"
    HEREDOC_COUNT=$((HEREDOC_COUNT + 1))
  done
  ((HEREDOC_COUNT > 0))
}


# True when a line reading exactly $2 appears after index $1, i.e. the heredoc
# opened there actually CLOSES. `lines` and `n` are the caller's, as elsewhere in
# this file.
#
# This is what keeps heredoc skipping from becoming a fail-open in the executable
# scan: an opener pattern also matches a left shift, and a mis-detected one with
# no terminator would otherwise suppress every remaining line of the file.
# Sets HEREDOC_END to the terminator's index and returns 0; returns 1 when the
# body never closes. Handing back the index it just found lets the caller jump
# the body rather than re-matching the terminator regex on every line of it.
HEREDOC_END=-1
heredoc_terminates() {
  local from="$1" term="$2" dash="$3" k
  HEREDOC_END=-1
  for ((k = from + 1; k < n; k++)); do
    if is_heredoc_terminator "${lines[k]}" "$term" "$dash"; then
      HEREDOC_END=$k
      return 0
    fi
  done
  return 1
}

# True when line $1 is the terminator for delimiter $2 opened with the `<<-` form
# in $3 (1 for `<<-`, 0 for a plain `<<`).
#
# 🔴 ENDING THE BODY EARLY IS NOT THE SAFE DIRECTION, despite reading like it.
# A plain `<<EOF` requires its terminator at COLUMN 0; an indented `  EOF` is
# payload. Accepting any indentation ends the body at that payload line, and then
# the REST of the payload is treated as code — so a payload line reading
# `# pipefail-grep-guard: allow-file` becomes a real directive and exempts the
# whole file, hiding a genuine offender below. `<<-` strips leading TABS only,
# never spaces.
#
# One definition for all three callers: the two body-skipping loops below and the
# lookahead above. Splitting it let the reasoning above live at one site while
# the other copies read as unexplained.
is_heredoc_terminator() {
  # Literal prefilter first: the regex below is built from a runtime delimiter, so
  # it is recompiled per call, and this runs against every line a lookahead walks.
  # Measured ~3× cheaper over the repository than going straight to the regex.
  [[ "$1" == *"$2"* ]] || return 1
  # The delimiter must be ALONE on the line — no trailing whitespace either.
  # Allowing `EOF ` to terminate ended a body at a payload line, and everything
  # after it was then read as code, so a payload directive exempted the file.
  # `<<-` strips leading TABS and nothing else.
  if (($3)); then
    [[ "$1" =~ ^$'\t'*"$2"$ ]]
  else
    [[ "$1" == "$2" ]]
  fi
}

early_exit_flag() {
  local rest="$1" tok skip_next=0 letters i ch mval want_mval=0 was_quoted lopt
  # `-m`/`--max-count` is the one early-exit option a LATER option can undo: grep
  # keeps only the last value, and a negative one is infinity. So the max-count
  # verdict is held in `m_pending` and decided when the command ends, not at the
  # first occurrence — `grep -m1 -m-1 MATCH` reads the whole stream and is safe,
  # and reporting it blocks a valid command assembled from a default plus an
  # override. `-q`/`-l` still answer immediately: nothing later un-quiets grep.
  local m_pending=""
  # The split below wants WORD SPLITTING but not PATHNAME EXPANSION. Unquoted
  # `$rest` gets both, so a pattern like `grep *.log -q` would expand against the
  # working directory: with matching files the flag survives at a different
  # index, and with none bash leaves the word alone — so the walk's input depends
  # on the caller's cwd. The only caller runs this in a command substitution, so
  # the option dies with the subshell and needs no restore.
  set -f
  # shellcheck disable=SC2086 # deliberate word splitting: rest is an argv tail
  set -- $rest
  # THE THREE PRE-CHECKS BELOW ARE ORDER-DEPENDENT IN OPPOSITE DIRECTIONS — do
  # not reorder them without re-reading this. The comment test must run BEFORE
  # quote removal (`grep "#p" -q` passes #p as the PATTERN, so its -q is a real
  # early exit, and stripping first would read the word as a comment and return
  # clean); the separator test must run AFTER it, because it needs to know
  # whether the word was quoted.
  for tok in "$@"; do
    # A syntactic comment ends the command's arguments. `grep MATCH # keep -q`
    # is a plain grep that reads its input to the end, but walking past the
    # operand let the `-q` inside the comment read as an option and the guard
    # reported a hazard that does not exist.
    # `break`, not `return`: a max-count seen BEFORE the terminator is still in
    # effect, so the verdict is settled once after the loop. Every exit from this
    # walk goes through that one place.
    [[ "$tok" == \#* ]] && break
    # `set -- $rest` preserves quote CHARACTERS, so `grep "-q" MATCH` arrives as
    # the literal `"-q"` and the walk read it as an operand — while bash removes
    # the quotes and grep receives the ordinary option. That is a fail-OPEN: the
    # real pipeline exits 141 under pipefail while the guard reported it clean.
    # Strip one balanced layer, and remember that we did.
    was_quoted=0
    case "$tok" in
      \"*\") tok="${tok#\"}" && tok="${tok%\"}" && was_quoted=1 ;;
      \'*\') tok="${tok#\'}" && tok="${tok%\'}" && was_quoted=1 ;;
      # An unquoted backslash escapes the next character and is REMOVED, so
      # `grep \-q MATCH` hands grep an ordinary `-q`. Leaving it attached made the
      # walk read `\-q` as an operand and call a hazardous pipeline clean — the
      # same fail-open as the quoted spelling, one escape further out.
      \\*) tok="${tok#\\}" ;;
    esac
    # Bash operators do not need surrounding whitespace, so `grep MATCH; sort -m`
    # splits into the operand `MATCH;` — the command ends there and `sort`'s `-m`
    # is not grep's. Only an UNQUOTED separator ends it: inside quotes the
    # character is data (`grep "a;b" -q`), and treating that as a terminator
    # would stop before a real `-q` and fail open.
    #
    # `|` belongs in this class for the same reason `;` and `&` do. Listing only
    # two of the three made the rule contradict itself: `… | grep MATCH; sort -q x`
    # read clean while `… | grep MATCH| sort -q x` was reported, though bash ends
    # the command identically in both.
    #
    # ⚠️ RESIDUAL, stated rather than papered over, and NOT to be closed by adding
    # more spellings here. `was_quoted` is a quoting model bolted onto a splitter
    # that has none: it only sees quotes that begin and end one whitespace-free
    # word, so `grep "a ;b" -q`, `grep a\;b -q` and `grep $'a;b' -q` all read the
    # separator as unquoted and stop before a real `-q`. This is the same trap the
    # _ASSIGN_VALUE block below records — extending the character classes just
    # moves which spelling escapes. Deciding it needs one pass that tracks quote
    # state and emits (word, quoted?) pairs, which is monorepo#2797; add spellings
    # to that issue, not to this line.
    if ((was_quoted == 0)) && [[ "$tok" == *[\;\&\|]* ]]; then
      break
    fi
    # The previous option named -m/--max-count without an attached value, so this
    # word IS that value and decides whether grep stops early.
    if ((want_mval)); then
      want_mval=0
      if max_count_is_finite "$tok"; then
        m_pending="-m $tok"
      else
        # Infinity: grep reads to the end, and this REPLACES any earlier finite
        # value rather than merely failing to set one.
        m_pending=""
      fi
      continue
    fi
    # The previous option consumed this word as its VALUE, so it is not an
    # operand and must not stop the walk.
    if ((skip_next)); then
      skip_next=0
      continue
    fi
    case "$tok" in
      # `--` ends option parsing. There is deliberately NO arm for the shell
      # operators here: the unquoted-separator test above owns them, whether or not
      # whitespace surrounds them. A second copy would not merely duplicate that
      # rule, it would invert it on quoted input — quote removal runs first, so
      # `… | grep ';' -q` arrives here as a bare `;` and an operator arm would
      # report CLEAN over a real early exit, while the test above correctly treats
      # the quoted character as data.
      --) break ;;
      --quiet | --silent | --files-with-matches)
        printf '%s' "$tok"
        return 0
        ;;
      --max-count=*)
        if max_count_is_finite "${tok#--max-count=}"; then
          m_pending="$tok"
        else
          m_pending=""
        fi
        continue
        ;;
      --max-count)
        want_mval=1
        continue
        ;;
      --*)
        # GNU accepts any UNAMBIGUOUS ABBREVIATION of a long option, so
        # `grep --quie MATCH` is `--quiet` on the Linux runner this check gates.
        # Treating every unrecognised long option as harmless missed that.
        #
        # A prefix test rather than more spellings: grep's long options are a
        # finite, enumerable set, unlike the shell syntax the rest of this file
        # approximates. Over-approximating is safe here — an AMBIGUOUS
        # abbreviation makes grep itself exit with an error, so a pipeline this
        # reports either stops early or does not run at all.
        #
        # ⚠️ The premise is GNU's documented getopt_long behaviour, not something
        # this host can execute: it has BSD grep, and the runner has GNU.
        for lopt in --quiet --silent --files-with-matches; do
          if [[ "$lopt" == "$tok"* ]]; then
            printf '%s' "$tok"
            return 0
          fi
        done
        # `--max-count` carries a value, so abbreviate the NAME and keep the rule
        # that a negative count is infinity and therefore not an early exit.
        mval="${tok%%=*}"
        if [[ "--max-count" == "$mval"* ]]; then
          if [[ "$tok" == *=* ]]; then
            if max_count_is_finite "${tok#*=}"; then
              m_pending="$tok"
            else
              m_pending=""
            fi
            continue
          fi
          want_mval=1
          continue
        fi
        # Long options whose value is the FOLLOWING word. Matched by PREFIX for the
        # same reason as the early-exit options above — GNU accepts any unambiguous
        # abbreviation — and handling the full and abbreviated spellings in one
        # place is what keeps them from drifting apart.
        #
        # What consuming the value buys is precisely ONE direction: it prevents
        # FALSE POSITIVES. `grep --reg -q MATCH` is `--regexp` with the pattern
        # `-q`, so the line is safe, and without this the walk reads that `-q` as
        # an early-exit flag and blocks a valid script.
        #
        # It cannot cause a MISSED hazard, because an operand is not a stopping
        # point (see the `*)` arm): GNU permutes later options to the front, so the
        # walk continues past an unconsumed value and would still find a real `-q`
        # behind it. Measured by ablation — removing this loop fails only the
        # abbreviated clean case, not the two flag cases.
        #
        # An attached value (`--regexp=PAT`) consumes nothing extra, so it falls
        # through — there is no following word to skip.
        if [[ "$tok" != *=* ]]; then
          for lopt in --regexp --file --after-context --before-context --context \
            --binary-files --devices --directories --label --include \
            --exclude --exclude-dir --exclude-from --group-separator; do
            if [[ "$lopt" == "$tok"* ]]; then
              skip_next=1
              break
            fi
          done
        fi
        continue
        ;;
      -*)
        # Walk the short cluster letter by letter rather than testing the whole
        # token. A value-taking letter swallows the REST of the cluster when
        # there is one (`-ePAT`) and the next word when there is not (`-e PAT`),
        # so `-eq` is -e with pattern "q" — not an early exit.
        letters="${tok#-}"
        for ((i = 0; i < ${#letters}; i++)); do
          ch="${letters:i:1}"
          case "$ch" in
            q | l)
              printf '%s' "$tok"
              return 0
              ;;
            m)
              # -m takes a value: the rest of the cluster, else the next word.
              mval="${letters:i+1}"
              if [[ -z "$mval" ]]; then
                want_mval=1
              elif max_count_is_finite "$mval"; then
                m_pending="$tok"
              else
                m_pending=""
              fi
              break
              ;;
            e | f | A | B | C | D | d)
              if ((i + 1 >= ${#letters})); then skip_next=1; fi
              break
              ;;
          esac
        done
        continue
        ;;
      # NOT a stopping point: an operand. GNU permutes later options to the front,
      # so `grep PATTERN -q` is an early exit and the walk must keep going.
      *) continue ;;
    esac
  done
  # The command has ended — by running out of words or by hitting a terminator.
  # Only now is the max-count final, because any occurrence could have been
  # overridden by a later one.
  if [[ -n "$m_pending" ]]; then
    printf '%s' "$m_pending"
    return 0
  fi
  return 1
}

# --- the line scan ---------------------------------------------------------
# A single `|` (never `||`), optional `VAR=value` prefixes, then grep. The
# leading `(^|[^|])` is what keeps `||` out: in `a || grep -q x` the character
# before the second pipe is itself a pipe.
#
# `grep` may be reached through a wrapper or an absolute path, and the hazard is
# identical: this file's own header tells a reader to call `command grep` or
# /usr/bin/grep to escape the harness shim, so those are the spellings a script
# following this advice will actually contain. A bare-name-only regex would let
# every one of them through while the guard reported the file clean.
# A wrapper may carry its OWN options — `env -i grep -q`, `command -p grep -q` —
# so an optionless-only match walks past exactly the spellings that reach grep.
# A wrapper option may also take its value as the FOLLOWING word — `env -u NAME
# grep -q x`, `env -C DIR grep -q x`. `-u` matches the bare-option alternative,
# but `NAME` then sits between the prefix and `grep` where nothing matches it, so
# the whole pipeline read as "no grep here" and a real hazard went unreported.
# The two-word form is listed FIRST so it wins over the bare-option alternative.
# Kept to env's actual value-taking options rather than "any option plus any
# word": the loose form would match `foo | bar baz grep`, where grep is an
# argument to `bar` and not run at all — a false positive.
# An assignment prefix may quote a value containing whitespace, and a shell WORD
# is a sequence of adjacent fragments that need not agree on quoting:
# `LC_ALL="C UTF-8"`, `LC_ALL='C UTF-8'` and `LC_ALL=C" UTF-8"` are all one word.
# Matching only the fully-quoted or fully-unquoted shapes left the mixed form
# unmatched, so the pipeline read as containing no grep at all — the same
# fail-open twice over, because the value grammar was wrong rather than the quote
# characters. Model the value as one-or-more fragments instead, each a quoted run
# or a run of bare characters. `_SQ` exists because the pattern lives in a
# single-quoted string and cannot hold a bare `'`.
_SQ=\'
# The four fragment forms a shell assignment value can take, enumerated from the
# quoting rules rather than one shape at a time — a value is a WORD, and a word is
# adjacent fragments that need not agree on quoting, so matching a single shape
# leaves the others unmatched:
#   "…"    double quotes DO honour backslash escapes   ->  A="x\" y"   is  x" y
#   $'…'   ANSI-C quoting DOES honour escapes          ->  $'x\' y'    is  x' y
#   '…'    single quotes do NOT — a backslash is       ->  B='x\" y'   is  x\" y
#          LITERAL, so `[^']*` is CORRECT here and
#          "fixing" it to match the others would be
#          wrong. Asymmetry on purpose.
#   bare   backslash escapes work                      ->  C=x\ y      is  x y
# A value fragment may also be an EXPANSION whose content contains whitespace:
# `A=$(printf 'C UTF-8')`, `A=`cmd``, `A=${x-a b}`.
#
# 🔴 **THE LIMIT is NOT "nested substitutions"** — that description is too
# generous. The pattern stops at the first `)`, `}` or backtick, so it also fails
# on a **single, unnested** substitution whose command merely contains one as
# data: `A=$(printf ') ')` is a valid assignment word this will not consume.
#
# The real boundary is that this layer **cannot tell a delimiter from a
# character that looks like one**, because deciding that requires tracking shell
# quoting inside the substitution — the same parsing it cannot do outside it.
# Nesting is one instance of that, not the rule. There is no version of this
# constant that fixes it: extending the character classes moves which spelling
# escapes rather than closing the class.
#
# So what is supported is: an expansion whose content contains **NEITHER
# delimiter of its own kind — opening OR closing** — in any context. The classes
# below exclude both (`[^()]`, `[^{}]`), so `A=$(printf '(')` escapes exactly as
# `A=$(printf ')')` does. Excluding only the closing delimiter would be too
# generous: what these classes accept is always narrower than a prose summary of
# them, so read the classes rather than any description of them.
#
# That rule also excludes **arithmetic expansion**, and it is worth naming because
# it is a DIFFERENT construct rather than a `$(…)` carrying a paren as data: `$((`
# is two opening delimiters, so `[^()]*` stops at the second. `A=$((1 + 2))` is
# therefore not consumed. Whitespace is what decides it — `A=$((1+2))` has none, so
# the bare-fragment alternative swallows it whole and the grep IS still found. Both
# sides are pinned in the test suite.
# Everything outside it reads as no-match, which is a SILENT PASS — see
# monorepo#2797, which replaces the layer with a tokenizer. Extend that issue
# rather than these character classes.
_ASSIGN_VALUE='("([^"\\]|\\.)*"|\$'"$_SQ"'([^'"$_SQ"'\\]|\\.)*'"$_SQ"'|'"$_SQ"'[^'"$_SQ"']*'"$_SQ"'|\$\([^()]*\)|`[^`]*`|\$\{[^{}]*\}|([^[:space:]"'"$_SQ"'\\]|\\.)+)+'
# The assignment arm requires the `=`. A bare NAME would make this arm match any
# word at all, so every wrapper that merely PRECEDES grep would be read as an
# environment prefix — and the wrappers that matter are not transparent. `xargs`
# is the demonstrated case: `producer | xargs grep -q MATCH` is SAFE, because
# xargs consumes the producer's whole stream and grep reads the named files
# rather than the pipe, so nothing is SIGPIPEd. Reported as an offender it blocks
# a valid script, which is the failure direction that keeps enforcement latent.
#
# Transparent wrappers stay explicitly enumerated (`command`, `env`, and the
# value-taking `env` options above). An unlisted wrapper reads as no-match, i.e.
# the same silent pass the rest of this layer already has — see monorepo#2797.
PIPE_GREP_RE='(^|[^|])\|&?[[:space:]]*((((-[uCS]|--unset|--chdir|--split-string)[[:space:]]+[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=('"$_ASSIGN_VALUE"')?|command|env|-[^[:space:]]*)[[:space:]]+)*)([^[:space:]]*/)?(grep|egrep|fgrep)([[:space:]]|$)'
unset _SQ _ASSIGN_VALUE

findings=0

scan_file() {
  local file="$1"
  [[ -r "$file" ]] || die "cannot read $file"
  # A REGULAR file, not merely a readable one. A tracked `*.sh` symlink pointing
  # at a character device — `/dev/zero` is the demonstrated case — passes a
  # readability test and then feeds the line reader an endless stream with no
  # newline, so this required job hangs instead of failing. `-f` follows symlinks,
  # so a symlink to a real script still scans normally.
  [[ -f "$file" ]] || die "not a regular file: $file"

  local -a lines=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    lines+=("$line")
  done <"$file"

  # Index-based, never `"${lines[@]}"`: bash 3.2 (the macOS system bash) treats
  # an empty array's `[@]` expansion as an unbound variable under `set -u`, so
  # the array form aborts the whole run on the first empty file.
  local n=${#lines[@]} i probe probe_mask probe_code probe_test base j joins start
  # The whole-file directive is honoured only from a SYNTACTIC comment. A heredoc
  # body is data, not code — a payload line reading
  # `# pipefail-grep-guard: allow-file — documentation only` looks identical to
  # the real directive, and exempting the entire script on the strength of quoted
  # data is a fail-open reachable by anyone who can add a heredoc. Track heredoc
  # bodies and skip them. Anything unrecognised stays scanned, so a parsing gap
  # here costs a missed exemption (safe) rather than a missed hazard.
  # Pending terminators, consumed in the order bash reads their bodies. A QUEUE
  # rather than a single value, because one opener line can start several.
  local -a hd_pending=() hd_pending_dash=()
  local hd_n=0 hd_at=0 q qstate=0
  for ((i = 0; i < n; i++)); do
    if ((hd_at < hd_n)); then
      is_heredoc_terminator "${lines[i]}" "${hd_pending[hd_at]}" "${hd_pending_dash[hd_at]}" && hd_at=$((hd_at + 1))
      continue
    fi
    if heredoc_delimiters "${lines[i]}"; then
      hd_pending=()
      hd_n=0
      hd_at=0
      for ((q = 0; q < HEREDOC_COUNT; q++)); do
        hd_pending[hd_n]="${HEREDOC_TERMS[q]}"
        hd_pending_dash[hd_n]="${HEREDOC_DASH[q]}"
        hd_n=$((hd_n + 1))
      done
      continue
    fi
    # A line that STARTS inside a multi-line string is data, so a directive
    # spelled there is payload rather than an exemption. The state is advanced
    # for every line either way, so a later real directive is still seen once
    # the string closes.
    if ((qstate == 0)) && [[ "${lines[i]}" =~ $ALLOW_FILE_RE ]]; then
      return 0
    fi
    advance_quote_state "${lines[i]}" "$qstate"
    qstate=$_QUOTE_STATE
  done

  # Mark every heredoc BODY line before scanning, rather than detecting openers
  # as the scan reaches them. A heredoc body is DATA the shell only prints, never
  # code it runs, so a script that emits documentation or a fixture containing
  # `producer | grep -q MATCH` must not fail this required job over it.
  #
  # Precomputing is what makes that hold for EVERY opener. Detecting inline saw
  # only openers the scan visits, and the continuation join consumes lines
  # without visiting them — so an opener on a joined line was never detected and
  # its payload was scanned as code:
  #
  #     producer |
  #       cat <<'DOC'
  #     x | grep -q MATCH      <- reported, though it is output
  #     DOC
  #
  # Only a heredoc whose terminator actually EXISTS marks anything. `<<` is also a
  # left shift, and `width=$(( total << bits ))` matches the opener pattern while
  # naming no terminator — an unconditional skip ran to end of file and hid every
  # pipeline below it, which is a fail-OPEN on a required check. The prepass above
  # deliberately keeps the unconditional form: over-detecting there costs at most
  # a MISSED EXEMPTION, which is safe, while under-detecting is what let a payload
  # line pass as the whole-file directive.
  #
  # The opening line itself stays scanned: it holds real code before the `<<`, and
  # a pipeline there is a genuine hazard.
  # Deliberately NOT zero-filled: an unset element already evaluates to 0 inside
  # `(( ))` without tripping `set -u` (checked on bash 3.2, the macOS system bash
  # this also runs on), so pre-filling it was one whole extra pass over every
  # line of every scanned file for no change in behaviour.
  local -a hd_body=()
  local hd_from hd_last hd_ok
  for ((i = 0; i < n; i++)); do
    heredoc_delimiters "${lines[i]}" || continue
    # Each delimiter's body starts where the previous one ended, so walk them in
    # order. EVERY one must terminate before anything is marked: a partially
    # resolved opener would leave the tail of the file masked on a guess.
    hd_from=$i
    hd_last=$i
    hd_ok=1
    for ((q = 0; q < HEREDOC_COUNT; q++)); do
      if heredoc_terminates "$hd_from" "${HEREDOC_TERMS[q]}" "${HEREDOC_DASH[q]}"; then
        hd_last=$HEREDOC_END
        hd_from=$HEREDOC_END
      else
        hd_ok=0
        break
      fi
    done
    ((hd_ok)) || continue
    # Intermediate terminator lines are data too, so the whole span is marked.
    for ((j = i + 1; j <= hd_last; j++)); do hd_body[j]=1; done
    i=$hd_last
  done

  for ((i = 0; i < n; i++)); do
    ((hd_body[i])) && continue

    probe="${lines[i]}"
    start=$i

    # Join continuations so a pipeline split across lines is still one probe:
    # a trailing `\`, or a trailing single `|` with grep on the next line.
    joins=0
    j=$i
    # NO join cap: the end-of-file bound is the only correct one. A fixed cap
    # either truncates the probe — scanning it as if the grep were not there, so a
    # pipeline with more comment lines than the cap reads clean — or fails closed,
    # which marks ordinary multi-line commands unscannable. This terminates
    # regardless: each absorbed line is skipped by `i=$j`, so the scan stays linear
    # in the file.
    while ((j + 1 < n)); do
      # Never continue a command INTO a heredoc body: those lines are the
      # heredoc's data, so appending them would scan output as code.
      ((hd_body[j + 1])) && break
      # A trailing comment does not end a pipeline — `producer | # note` still
      # continues on the next line. Strip one for the CONTINUATION TEST only,
      # never from the probe itself, where quoting makes stripping unreliable.
      # Over-stripping here can only join more lines, which is the safe
      # direction: the regex still has to match for anything to be reported.
      probe_test="${probe%%[[:space:]]#*}"
      # `|` is an operator, so it ends a word and a `#` straight after it opens a
      # comment with no whitespace between: `producer |# note` continues on the
      # next line exactly as `producer | # note` does. Matching only the
      # whitespace-prefixed form left the comment text between the pipe and the
      # grep, so the line never joined and a real offender went unreported. Keep
      # the pipe — the continuation test below is what looks for it.
      case "$probe_test" in
        *'|#'*) probe_test="${probe_test%%|#*}|" ;;
      esac
      # The comment-stripped test comes FIRST when a comment was actually
      # stripped. A comment can itself end in a backslash (`producer | # why \`),
      # and bash continues that pipeline on the executable text — so letting the
      # backslash branch win would rebuild `base` from the unstripped comment and
      # leave its text between the pipe and the grep, where the regex cannot match.
      if [[ "$probe" != "$probe_test" ]] &&
        [[ "$probe_test" =~ [^|]\|[[:space:]]*$ ]] && [[ ! "$probe_test" =~ \|\|[[:space:]]*$ ]]; then
        base="$probe_test"
      elif [[ "${lines[j]}" =~ ^[[:space:]]*# ]] && [[ "$probe" =~ \\$ ]]; then
        # A WHOLE-LINE comment ending in `\` does not continue anything: bash
        # ends the comment at the newline and runs the next line on its own.
        # Joining here swallowed that next executable line into a comment probe,
        # so a real `producer | grep -q X` directly under `# note \` was never
        # scanned. Distinct from a TRAILING comment on a command line, handled
        # above — there the pipeline is real and the backslash does continue it.
        break
      elif [[ "$probe" =~ \\$ ]] ||
        { [[ "$probe" =~ [^|]\|[[:space:]]*$ ]] && [[ ! "$probe" =~ \|\|[[:space:]]*$ ]]; }; then
        base="${probe%\\}"
      elif [[ "$probe_test" =~ [^|]\|[[:space:]]*$ ]] && [[ ! "$probe_test" =~ \|\|[[:space:]]*$ ]]; then
        # A trailing comment sits between the pipe and the next line. Continue
        # from the STRIPPED form: appending to the unstripped one would leave
        # the comment text between the pipe and the grep, where the pipeline
        # regex cannot match it. This arm is only reachable when the unstripped
        # probe does NOT already end in a pipe, so a `#` inside quotes never
        # routes here and quoted text is never stripped.
        base="$probe_test"
      else
        break
      fi
      # Comment-only lines never execute, so a pipeline interrupted by one is
      # still a pipeline: skip the comment instead of appending it, which would
      # destroy the trailing `|` the next iteration tests for.
      if [[ "${lines[j + 1]}" =~ ^[[:space:]]*# ]]; then
        j=$((j + 1))
        joins=$((joins + 1))
        continue
      fi
      probe="${base} ${lines[j + 1]}"
      j=$((j + 1))
      joins=$((joins + 1))
    done
    # A joined line belongs to this logical line and must not be re-scanned as
    # a probe of its own; otherwise one pipeline is reported once per line it
    # spans.
    i=$j

    # Whole-line comments never execute. A trailing comment on a real command
    # line is not stripped — quoting makes that unreliable, and the option walk
    # already refuses to read a word that is not an option.
    [[ "${lines[start]}" =~ ^[[:space:]]*# ]] && continue
    [[ "$probe" =~ $ALLOW_LINE_RE ]] && continue

    # Cheap reject on the raw line first: this is the hot path, and the masking
    # walk below is per-character. Only a line that already looks like a
    # pipe-into-grep pays for it.
    [[ "$probe" =~ $PIPE_GREP_RE ]] || continue

    # THE PIPE MUST BE AN OPERATOR, NOT TEXT. `printf '%s\n' 'producer | grep -q
    # MATCH'` prints documentation and runs no pipeline at all, but a raw match
    # read the quoted text as live code and failed this required job — forcing
    # documentation and fixture generators to carry suppressions for code they
    # never execute. Match on the masked copy; the offsets still index the raw
    # line, which is where the option walk has to read its arguments from.
    case "$probe" in
      *[\'\"\\]*)
        mask_quoted "$probe"
        probe_mask="$_masked"
        ;;
      *) probe_mask="$probe" ;;
    esac
    # A trailing comment is prose, not code: `printf 'ok\n' # producer | grep -q X`
    # runs a plain printf. Matching the comment text reported an offender for a
    # line that executes no pipeline at all. Same rule, same implementation as the
    # heredoc scanner — this is the site where writing a second copy of it would
    # drift again.
    strip_comment "$probe_mask" "$probe" || continue
    probe_mask="$_code_mask"
    probe_code="$_code_raw"
    [[ "$probe_mask" =~ $PIPE_GREP_RE ]] || continue

    # Re-walk every pipe-into-grep on the probe, and REPORT every one of them:
    # one line can carry two (`… | grep -q A && … | grep -q B`), and stopping at
    # the first made the developer fix it, rerun CI, and only then discover the
    # second edit this blocking check requires.
    # Collect this line's offenders before printing any of them, so each block can
    # say WHICH one it is. Two offenders on one logical line share a file:line and
    # usually a flag, so the blocks are otherwise byte-identical and the reader
    # cannot tell a genuine pair from one finding reported twice. Naming the
    # matched fragment does NOT solve it — the match is the `| grep ` prefix,
    # identical for both — which only reading the real output made obvious.
    # Walk the MASKED copy to find each pipe-into-grep, and take the arguments
    # from the RAW copy at the same offset — masking preserves length, so one
    # index serves both. Reading arguments from the mask would hand the option
    # walk a row of `x`s instead of `-q`.
    local tail_m="$probe_mask" tail_r="$probe_code" head_ pre rest flag k off
    local -a line_flags=()
    local lf=0
    while [[ "$tail_m" =~ $PIPE_GREP_RE ]]; do
      head_="${BASH_REMATCH[0]}"
      pre="${tail_m%%"$head_"*}"
      off=$((${#pre} + ${#head_}))
      rest="${tail_r:off}"
      if flag="$(early_exit_flag "$rest")"; then
        line_flags[lf]="$flag"
        lf=$((lf + 1))
      fi
      tail_m="${tail_m:off}"
      tail_r="$rest"
    done
    # Trim once, outside the loop: every offender on this line prints the SAME
    # source line, so doing it per offender re-forked `sed` on an identical
    # string. Parameter expansion, so it does not fork at all.
    local shown="${lines[start]}"
    shown="${shown#"${shown%%[![:space:]]*}"}"
    for ((k = 0; k < lf; k++)); do
      flag="${line_flags[k]}"
      printf '%s:%d: %s\n' "$file" "$((start + 1))" "$shown"
      if ((lf > 1)); then
        printf '    [%d of %d on this line] grep %s stops at the first match; the writer dies of SIGPIPE and pipefail reports THAT.\n' \
          "$((k + 1))" "$lf" "$flag"
      else
        printf '    grep %s stops at the first match; the writer dies of SIGPIPE and pipefail reports THAT.\n' "$flag"
      fi
      # Why the capture form leads and process substitution carries a caveat:
      # see THE FIX THIS GUARD ASKS FOR in the header, which records the three
      # measured exit codes.
      printf '    fix: feed grep without a pipe — grep %s PAT <<<"$var", or out="$(cmd)" then <<<"$out", or from a file.\n' "$flag"
      printf '    note: < <(cmd) removes the pipe too, but DISCARDS the producer status — check it separately.\n'
      findings=$((findings + 1))
    done
  done
}

main() {
  local -a targets=()
  if (($# > 0)); then
    targets=("$@")
  else
    local repo
    repo="$(git rev-parse --show-toplevel 2>/dev/null)" ||
      die "not inside a git repository, and no paths were given"
    cd "$repo" || die "cannot enter $repo"
    # EVERY tracked shell script, which is not the same set as `*.sh`: a script
    # at a conventional extensionless path (`bin/check`) carries exactly this
    # hazard, and the guard claims to cover it. Identify those by SHEBANG — the
    # executable bit alone would sweep in every compiled helper and binary.
    # NUL-delimited, because git QUOTES any path outside its safe character set:
    # a tracked `tést.sh` comes back as the literal `"t\303\251st.sh"`, which
    # matches neither the `*.sh` case nor a readable file — so the mandatory
    # sweep skipped it and still reported the repository clean. A guard that
    # silently omits files fails open, which is the one direction that matters.
    local first
    while IFS= read -r -d '' f; do
      case "$f" in
        *.sh)
          targets+=("$f")
          continue
          ;;
      esac
      [[ -f "$f" && -r "$f" ]] || continue
      IFS= read -r first <"$f" 2>/dev/null || continue
      # Resolve the INTERPRETER, rather than asking whether the line ends in `sh`.
      # A suffix test misses every versioned shell — `#!/usr/bin/ksh93`,
      # `#!/usr/bin/bash5` — so those scripts were skipped while the sweep still
      # reported the repository clean. Omitting files silently is the one
      # direction that fails open, which is why this parses instead of matching.
      #
      # `#!/usr/bin/env bash` puts the shell in the ARGUMENT, so both words are
      # considered. Trailing digits and dots are stripped, so `ksh93` and `bash5`
      # resolve to `ksh`/`bash`; the result must then be a shell name exactly,
      # which keeps `shellcheck` (ends in `sh`, is not a shell) out.
      case "$first" in
        '#!'*)
          local shebang interp base
          shebang="${first#\#!}"
          # Collapse leading blanks, then split off the interpreter word.
          shebang="${shebang#"${shebang%%[![:space:]]*}"}"
          interp="${shebang%%[[:space:]]*}"
          base="${interp##*/}"
          # `env` runs an OPERAND, and its own options stand in front of it. The
          # first word after `env` is therefore not always the command: with
          # `#!/usr/bin/env -S bash` it is `-S`, which resolves to no shell and
          # omits the file from the sweep — the fail-open direction this whole
          # block exists to avoid. Walk env's options to reach the operand.
          case "$base" in
            env | env[0-9.]*) base="$(env_operand "$shebang")"; base="${base##*/}" ;;
          esac
          # Strip a version suffix: ksh93 -> ksh, bash5 -> bash, sh5.2 -> sh.
          while [[ "$base" == *[0-9.] ]]; do base="${base%[0-9.]}"; done
          case "$base" in
            sh | bash | dash | ksh | mksh | pdksh | ash | zsh | yash | busybox)
              targets+=("$f")
              ;;
          esac
          ;;
      esac
    done < <(git ls-files -z)
    ((${#targets[@]} > 0)) || die "no tracked shell scripts found"
  fi

  # Index-based for the same bash 3.2 reason as scan_file's array walk.
  local k
  for ((k = 0; k < ${#targets[@]}; k++)); do
    scan_file "${targets[k]}"
  done

  if ((findings > 0)); then
    printf '\npipefail-grep-guard: %d offending pipeline(s).\n' "$findings" >&2
    printf 'Each one reports FAILURE when it MATCHED. A negated one reports success and guards nothing.\n' >&2
    exit 1
  fi
  echo "pipefail-grep-guard: no writer piped into an early-exiting grep."
}

main "$@"
