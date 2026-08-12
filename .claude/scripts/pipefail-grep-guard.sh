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
#     grep -q PAT <<<"$var"          # value already in a variable
#     grep -q PAT < <(cmd)           # output of a command
#     grep -q PAT file               # a file
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
max_count_is_finite() { case "$1" in -*) return 1 ;; *) return 0 ;; esac; }

early_exit_flag() {
  local rest="$1" tok skip_next=0 letters i ch mval want_mval=0
  # shellcheck disable=SC2086 # deliberate word splitting: rest is an argv tail
  set -- $rest
  for tok in "$@"; do
    # The previous option named -m/--max-count without an attached value, so this
    # word IS that value and decides whether grep stops early.
    if ((want_mval)); then
      want_mval=0
      if max_count_is_finite "$tok"; then
        printf '%s' "-m $tok"
        return 0
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
      # A shell operator ENDS this grep's command. Everything after it belongs to
      # a different command, and reading its flags as grep's produced a false
      # POSITIVE: in `printf 'MATCH\n' | grep MATCH && sort -m /dev/null` the
      # grep reads its input to completion and is perfectly safe, but the walk
      # ran on into `sort -m` and reported an early exit that cannot happen.
      # `--` still terminates option parsing; these terminate the command.
      '&&' | '||' | ';' | ';;' | '|' | '|&' | '&') return 1 ;;
      --) return 1 ;;
      --quiet | --silent | --files-with-matches)
        printf '%s' "$tok"
        return 0
        ;;
      --max-count=*)
        if max_count_is_finite "${tok#--max-count=}"; then
          printf '%s' "$tok"
          return 0
        fi
        continue
        ;;
      --max-count)
        want_mval=1
        continue
        ;;
      # Long options that take their value as the FOLLOWING word. Without this,
      # `grep --regexp PAT -q` reads PAT as the pattern operand and returns
      # before ever seeing -q, so the guard calls a hazardous line clean.
      --regexp | --file | --after-context | --before-context | --context | \
        --binary-files | --devices | --directories | --label | --include | \
        --exclude | --exclude-dir | --exclude-from | --group-separator)
        skip_next=1
        continue
        ;;
      --*) continue ;;
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
                printf '%s' "$tok"
                return 0
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
# The four fragment forms a shell assignment value can take, written out ONCE
# from the actual quoting rules rather than added one at a time as each is
# reported. Four consecutive review rounds found four shapes of this same grammar
# (quoted value, mixed fragments, escaped space, escaped quote), each fix shaped
# by the example that exposed it and survived by the next — so this enumerates
# the rules instead. Every line below was confirmed by RUNNING it, not read off a
# manual:
#   "…"    double quotes DO honour backslash escapes   ->  A="x\" y"   is  x" y
#   $'…'   ANSI-C quoting DOES honour escapes          ->  $'x\' y'    is  x' y
#   '…'    single quotes do NOT — a backslash is       ->  B='x\" y'   is  x\" y
#          LITERAL, so `[^']*` is CORRECT here and
#          "fixing" it to match the others would be
#          wrong. Asymmetry on purpose.
#   bare   backslash escapes work                      ->  C=x\ y      is  x y
_ASSIGN_VALUE='("([^"\\]|\\.)*"|\$'"$_SQ"'([^'"$_SQ"'\\]|\\.)*'"$_SQ"'|'"$_SQ"'[^'"$_SQ"']*'"$_SQ"'|([^[:space:]"'"$_SQ"'\\]|\\.)+)+'
PIPE_GREP_RE='(^|[^|])\|&?[[:space:]]*((((-[uCS]|--unset|--chdir|--split-string)[[:space:]]+[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*='"$_ASSIGN_VALUE"'|command|env|-[^[:space:]]*)[[:space:]]+)*)([^[:space:]]*/)?(grep|egrep|fgrep)([[:space:]]|$)'
unset _SQ _ASSIGN_VALUE

findings=0

scan_file() {
  local file="$1"
  [[ -r "$file" ]] || die "cannot read $file"

  local -a lines=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    lines+=("$line")
  done <"$file"

  # Index-based, never `"${lines[@]}"`: bash 3.2 (the macOS system bash) treats
  # an empty array's `[@]` expansion as an unbound variable under `set -u`, so
  # the array form aborts the whole run on the first empty file.
  local n=${#lines[@]} i probe probe_test base j joins start
  # The whole-file directive is honoured only from a SYNTACTIC comment. A heredoc
  # body is data, not code — a payload line reading
  # `# pipefail-grep-guard: allow-file — documentation only` looks identical to
  # the real directive, and exempting the entire script on the strength of quoted
  # data is a fail-open reachable by anyone who can add a heredoc. Track heredoc
  # bodies and skip them. Anything unrecognised stays scanned, so a parsing gap
  # here costs a missed exemption (safe) rather than a missed hazard.
  local hd_term=""
  for ((i = 0; i < n; i++)); do
    if [[ -n "$hd_term" ]]; then
      # The terminator is matched on its own line, optionally indented — `<<-`
      # strips leading TABS, and a plain `<<` requires column 0, but accepting
      # either only ends the body sooner, which resumes scanning.
      [[ "${lines[i]}" =~ ^[[:space:]]*"$hd_term"[[:space:]]*$ ]] && hd_term=""
      continue
    fi
    if [[ "${lines[i]}" =~ \<\<-?[[:space:]]*\'?\"?([A-Za-z_][A-Za-z0-9_]*)\'?\"? ]]; then
      hd_term="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "${lines[i]}" =~ $ALLOW_FILE_RE ]] && return 0
  done

  for ((i = 0; i < n; i++)); do
    probe="${lines[i]}"
    start=$i

    # Join continuations so a pipeline split across lines is still one probe:
    # a trailing `\`, or a trailing single `|` with grep on the next line.
    joins=0
    j=$i
    # NO join cap. There used to be one at 8, which silently stopped the walk and
    # then scanned the truncated probe as if the grep were not there — a pipeline
    # with nine comment-only lines before its `grep -q` read as clean. The
    # end-of-file bound below is the only one that is actually correct, and it
    # terminates: each absorbed line is skipped by `i=$j`, so the whole scan stays
    # linear in the file. Failing closed on the cap instead was tried and is
    # worse — it reported 18 ordinary multi-line commands in this repository as
    # unscannable, which is a DevEx tax paid on every run for no security gain.
    while ((j + 1 < n)); do
      # A trailing comment does not end a pipeline — `producer | # note` still
      # continues on the next line. Strip one for the CONTINUATION TEST only,
      # never from the probe itself, where quoting makes stripping unreliable.
      # Over-stripping here can only join more lines, which is the safe
      # direction: the regex still has to match for anything to be reported.
      probe_test="${probe%%[[:space:]]#*}"
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

    [[ "$probe" =~ $PIPE_GREP_RE ]] || continue

    # Re-walk every pipe-into-grep on the probe, not just the first: one line
    # can carry two of them (`… | grep -q A && … | grep -q B`).
    local tail_="$probe" head_ rest flag
    while [[ "$tail_" =~ $PIPE_GREP_RE ]]; do
      head_="${BASH_REMATCH[0]}"
      rest="${tail_#*"$head_"}"
      if flag="$(early_exit_flag "$rest")"; then
        printf '%s:%d: %s\n' "$file" "$((start + 1))" "$(sed 's/^[[:space:]]*//' <<<"${lines[start]}")"
        printf '    grep %s stops at the first match; the writer dies of SIGPIPE and pipefail reports THAT.\n' "$flag"
        printf '    fix: feed grep without a pipe — grep %s PAT <<<"$var", or < <(cmd), or from a file.\n' "$flag"
        findings=$((findings + 1))
        break
      fi
      tail_="$rest"
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
      case "$first" in
        '#!'*sh | '#!'*sh[[:space:]]*) targets+=("$f") ;;
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
