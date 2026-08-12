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
#   It is a race between grep's exit and the writer's next write, so it is
#   size-BIASED, not size-determined: 80/100 failures at a 100-byte payload and
#   100/100 from ~1 KB up. A short fixture can pass a hundred times and the same
#   line still flip in production. Do not try to prove or refute this class with
#   a length test.
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
#   read their input to the end and never do.
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
#   The command right after the pipe must be grep itself (optionally behind
#   VAR=value prefixes). `producer | xargs grep -l …` is the same hazard and is
#   NOT detected — xargs would take the SIGPIPE instead. There is no instance of
#   it in this repository, so the pattern stays narrow rather than growing an
#   xargs argument parser; extend it here if one ever appears.
#
# ESCAPE HATCH
#   A line carrying `pipefail-grep-guard: allow` (in a comment) is skipped, so a
#   fixture that must contain the offending text stays possible without turning
#   the guard off. Say why in the same comment.
#
#   `pipefail-grep-guard: allow-file` anywhere in a file skips the whole file.
#   That is for a file whose SUBJECT is this bug — this guard's own self-test
#   both quotes the offending form as fixture text and executes it on purpose.
#   Both markers are plain text in a reviewable diff; neither disables the job.
#
# USAGE
#   pipefail-grep-guard.sh [path ...]
#       With no paths, scans every tracked *.sh file in the repository.
#
# EXIT CODES
#   0  no offending pipeline found
#   1  at least one offending pipeline found (each is printed)
#   2  usage, or the repository/file could not be read

set -Eeuo pipefail
# The option walk distinguishes -l from -L, so pattern matching must stay
# case-sensitive whatever the caller's shell options are.
shopt -u nocasematch

ALLOW_MARKER='pipefail-grep-guard: allow'
ALLOW_FILE_MARKER='pipefail-grep-guard: allow-file'

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
early_exit_flag() {
  local rest="$1" tok
  # shellcheck disable=SC2086 # deliberate word splitting: rest is an argv tail
  set -- $rest
  for tok in "$@"; do
    case "$tok" in
      --) return 1 ;;
      --quiet | --silent | --files-with-matches | --max-count | --max-count=*)
        printf '%s' "$tok"
        return 0
        ;;
      --*) continue ;;
      -*)
        # A short-option cluster. q, l and m are the early-exit letters; no
        # other lowercase grep short option uses those characters.
        if [[ "${tok#-}" == *[qlm]* ]]; then
          printf '%s' "$tok"
          return 0
        fi
        continue
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# --- the line scan ---------------------------------------------------------
# A single `|` (never `||`), optional `VAR=value` prefixes, then grep. The
# leading `(^|[^|])` is what keeps `||` out: in `a || grep -q x` the character
# before the second pipe is itself a pipe.
PIPE_GREP_RE='(^|[^|])\|&?[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*)(grep|egrep|fgrep)([[:space:]]|$)'

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
  local n=${#lines[@]} i probe j joins start
  for ((i = 0; i < n; i++)); do
    [[ "${lines[i]}" == *"$ALLOW_FILE_MARKER"* ]] && return 0
  done

  for ((i = 0; i < n; i++)); do
    probe="${lines[i]}"
    start=$i

    # Join continuations so a pipeline split across lines is still one probe:
    # a trailing `\`, or a trailing single `|` with grep on the next line.
    joins=0
    j=$i
    while ((joins < 4 && j + 1 < n)); do
      if [[ "$probe" =~ \\$ ]] || { [[ "$probe" =~ [^|]\|[[:space:]]*$ ]] && [[ ! "$probe" =~ \|\|[[:space:]]*$ ]]; }; then
        probe="${probe%\\} ${lines[j + 1]}"
        j=$((j + 1))
        joins=$((joins + 1))
      else
        break
      fi
    done
    # A joined line belongs to this logical line and must not be re-scanned as
    # a probe of its own; otherwise one pipeline is reported once per line it
    # spans.
    i=$j

    # Whole-line comments never execute. A trailing comment on a real command
    # line is not stripped — quoting makes that unreliable, and the option walk
    # already refuses to read a word that is not an option.
    [[ "${lines[start]}" =~ ^[[:space:]]*# ]] && continue
    [[ "$probe" == *"$ALLOW_MARKER"* ]] && continue

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
    while IFS= read -r f; do
      targets+=("$f")
    done < <(git ls-files '*.sh')
    ((${#targets[@]} > 0)) || die "no tracked *.sh files found"
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
