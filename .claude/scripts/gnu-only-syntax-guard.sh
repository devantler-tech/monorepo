#!/usr/bin/env bash
#
# Flags GNU-only command syntax in bash-shebanged helper scripts (monorepo#3273).
#
# Why this needs a guard. The interactive shell on the agent host is zsh with wrapped tools, while a
# `#!/usr/bin/env bash` script runs the BSD binaries in /usr/bin. A command hand-verified in the
# interactive shell can therefore fail inside the script, and with the usual `2>/dev/null` the
# failure reads as an empty result rather than an error. `find -newermt @<epoch>` did exactly that in
# claude-lane-liveness.sh: BSD find rejects it, the enumeration came back empty, and a healthy lane
# was reported NOT-PRODUCING. Hand-verification cannot catch this class, so a static check does.
#
# Rules (extend the awk block below when a new instance is measured):
#   find-newermt-epoch  `-newer?t @…` — BSD find cannot parse an `@<epoch>` date. Use a `touch -t`
#                       reference file with `-newer` instead.
#   date-d-without-bsd  `date … -d` / `--date` with no BSD form (`date … -v`, `-j` or `-r`) within
#                       three commands. The dual-dialect idiom tries one form and falls back to the
#                       other; a GNU form on its own fails on macOS.
#
# Rules are judged per logical command: a line ending in `\` is joined with the next, as the shell
# joins it, and a finding is reported at the command's first line.
#
# A command may opt out with a trailing shell comment `# gnu-only-ok: <reason>` when it only ever runs
# on GNU (for example a Linux-only CI step). The marker counts only as a real comment — after
# whitespace and outside quotes — so quoted data cannot switch the check off. Comment lines are
# ignored.
#
# Usage: gnu-only-syntax-guard.sh [FILE...]
#   With no FILE, scans every bash-shebanged .claude/scripts/*.sh except this guard and its test,
#   whose fixtures contain the flagged constructs on purpose.
# Exit: 0 no finding, 1 findings (one `path:line: rule: text` each), 2 unknown (usage error, an
# unreadable or empty file, or nothing to scan).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A guard that exits 0 without having run is worse than one that errors: bash 3.2 can report a
# `set -u` abort as 0 to an EXIT trap. Reaching the end is the only way a zero status leaves.
gnu_only_guard_finished=0
cleanup() {
  local rc=$?
  if [[ "$gnu_only_guard_finished" != 1 && $rc -eq 0 ]]; then
    echo "gnu-only-syntax-guard: aborted before finishing; reporting unknown rather than a clean pass" >&2
    rc=2
  fi
  exit "$rc"
}
trap cleanup EXIT

unknown() {
  echo "gnu-only-syntax-guard: $*" >&2
  exit 2
}

files=()
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h | --help)
      sed -n '2,31p' "${BASH_SOURCE[0]}"
      gnu_only_guard_finished=1
      exit 0
      ;;
    -*) unknown "unknown option: $1" ;;
  esac
  files=("$@")
else
  for f in "$script_dir"/*.sh; do
    [[ -e "$f" ]] || continue
    case "$(basename "$f")" in
      gnu-only-syntax-guard.sh | gnu-only-syntax-guard.test.sh) continue ;;
    esac
    # A candidate that cannot be read might be a bash script with a finding: never skip it.
    [[ -f "$f" && -r "$f" ]] || unknown "cannot read $f"
    first_line=""
    IFS= read -r first_line <"$f" || [[ -n "$first_line" ]] || unknown "cannot read a shebang from $f"
    case "$first_line" in
      '#!'*bash*) files+=("$f") ;;
    esac
  done
fi

if [[ ${#files[@]} -eq 0 ]]; then
  unknown "no bash scripts to scan — refusing to report a clean pass"
fi

for f in "${files[@]}"; do
  [[ -f "$f" && -r "$f" ]] || unknown "cannot read $f"
  # An empty file has no content to examine, so it cannot be reported clean.
  [[ -s "$f" ]] || unknown "$f is empty — nothing was examined"
done

findings="$(
  awk -v q="'" '
    BEGIN {
      newer_epoch = "-newer[A-Za-z]t[ \t]+[\"" q "]?@"
      # `date` as a command word, then any mix of short (-u) and long (--utc, --foo=bar) options.
      date_opts = "(^|[^A-Za-z0-9_.-])date([ \t]+(-[A-Za-z]+|--[A-Za-z][A-Za-z-]*(=[^ \t]*)?))*[ \t]+"
      gnu_date_re = date_opts "(-[A-Za-z]*d|--date)"
      bsd_date_re = date_opts "-[A-Za-z]*[vjr]"
    }
    function is_code(s) { return s !~ /^[ \t]*#/ }
    # A marker counts only as a real trailing comment: preceded by whitespace (or the line start) and
    # with balanced single and double quotes before it, so a quoted "# gnu-only-ok:" is data.
    function opted_out(s,   pre, sq, dq) {
      if (!match(s, /(^|[ \t])#[ \t]*gnu-only-ok:[ \t]*[^ \t]/)) return 0
      pre = substr(s, 1, RSTART - 1)
      sq = gsub(q, "", pre)
      dq = gsub(/"/, "", pre)
      return (sq % 2 == 0 && dq % 2 == 0)
    }
    function report(file, n, rule, s) {
      sub(/^[ \t]+/, "", s)
      printf "%s:%d: %s: %s\n", file, n, rule, s
    }
    function flush(file,   i, j, lo, hi, has_bsd) {
      for (i = 1; i <= count; i++) {
        if (!code[i] || opted_out(text[i])) continue
        if (text[i] ~ newer_epoch) report(file, start[i], "find-newermt-epoch", text[i])
        if (text[i] ~ gnu_date_re) {
          has_bsd = 0
          lo = i - 3; if (lo < 1) lo = 1
          hi = i + 3; if (hi > count) hi = count
          for (j = lo; j <= hi; j++) if (code[j] && text[j] ~ bsd_date_re) has_bsd = 1
          if (!has_bsd) report(file, start[i], "date-d-without-bsd", text[i])
        }
      }
    }
    FNR == 1 {
      if (NR > 1) flush(prev)
      count = 0
      continuing = 0
      delete text; delete code; delete start
    }
    {
      prev = FILENAME
      line = $0
      if (continuing) {
        # Join a continued command the way the shell does: drop the backslash-newline.
        text[count] = text[count] line
      } else {
        count++
        text[count] = line
        start[count] = FNR
        code[count] = is_code(line)
      }
      # An odd run of trailing backslashes escapes the newline; an even run is literal backslashes.
      continuing = 0
      if (code[count] && match(line, /\\+$/) && RLENGTH % 2 == 1) {
        continuing = 1
        sub(/\\$/, "", text[count])
      }
    }
    END { if (NR > 0) flush(prev) }
  ' "${files[@]}"
)" || unknown "the scan itself failed"

gnu_only_guard_finished=1
if [[ -n "$findings" ]]; then
  printf '%s\n' "$findings"
  echo "gnu-only-syntax-guard: GNU-only syntax found — probe the way the script runs (bash -c), not the interactive shell" >&2
  exit 1
fi
echo "gnu-only-syntax-guard: OK — ${#files[@]} bash script(s) scanned"
