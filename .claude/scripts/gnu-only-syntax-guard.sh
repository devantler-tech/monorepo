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
#                       three lines. The dual-dialect idiom tries one form and falls back to the
#                       other; a GNU form on its own fails on macOS.
#
# A line may opt out with a trailing `# gnu-only-ok: <reason>` when it only ever runs on GNU (for
# example a Linux-only CI step). Comment lines are ignored.
#
# Usage: gnu-only-syntax-guard.sh [FILE...]
#   With no FILE, scans every bash-shebanged .claude/scripts/*.sh except this guard and its test,
#   whose fixtures contain the flagged constructs on purpose.
# Exit: 0 no finding, 1 findings (one `path:line: rule: text` each), 2 unknown (usage error,
# unreadable file, or nothing to scan).

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

files=()
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h | --help)
      sed -n '2,27p' "${BASH_SOURCE[0]}"
      gnu_only_guard_finished=1
      exit 0
      ;;
    -*)
      echo "gnu-only-syntax-guard: unknown option: $1" >&2
      exit 2
      ;;
  esac
  files=("$@")
else
  for f in "$script_dir"/*.sh; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
      gnu-only-syntax-guard.sh | gnu-only-syntax-guard.test.sh) continue ;;
    esac
    first_line=""
    IFS= read -r first_line <"$f" || true
    case "$first_line" in
      '#!'*bash*) files+=("$f") ;;
    esac
  done
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "gnu-only-syntax-guard: no bash scripts to scan — refusing to report a clean pass" >&2
  exit 2
fi

for f in "${files[@]}"; do
  if [[ ! -f "$f" || ! -r "$f" ]]; then
    echo "gnu-only-syntax-guard: cannot read $f" >&2
    exit 2
  fi
done

findings="$(
  awk -v q="'" '
    BEGIN { newer_epoch = "-newer[A-Za-z]t[ \t]+[\"" q "]?@" }
    function is_code(s) { return s !~ /^[ \t]*#/ }
    function opted_out(s) { return s ~ /#[ \t]*gnu-only-ok:[ \t]*[^ \t]/ }
    function report(file, n, rule, s) {
      sub(/^[ \t]+/, "", s)
      printf "%s:%d: %s: %s\n", file, n, rule, s
    }
    function flush(file,   i, j, lo, hi, has_bsd) {
      for (i = 1; i <= count; i++) {
        if (!code[i] || opted_out(text[i])) continue
        if (text[i] ~ newer_epoch) report(file, i, "find-newermt-epoch", text[i])
        if (gnu_date[i]) {
          has_bsd = 0
          lo = i - 3; if (lo < 1) lo = 1
          hi = i + 3; if (hi > count) hi = count
          for (j = lo; j <= hi; j++) if (code[j] && bsd_date[j]) has_bsd = 1
          if (!has_bsd) report(file, i, "date-d-without-bsd", text[i])
        }
      }
    }
    FNR == 1 {
      if (NR > 1) flush(prev)
      count = 0
      delete text; delete code; delete gnu_date; delete bsd_date
    }
    {
      prev = FILENAME
      count++
      text[count] = $0
      code[count] = is_code($0)
      # `date` as a command word: start of line or after a non-word character such as `(` or `|`.
      gnu_date[count] = ($0 ~ /(^|[^A-Za-z0-9_.-])date([ \t]+-[A-Za-z]+)*[ \t]+(-[A-Za-z]*d|--date)/)
      bsd_date[count] = ($0 ~ /(^|[^A-Za-z0-9_.-])date([ \t]+-[A-Za-z]+)*[ \t]+-[A-Za-z]*[vjr]/)
    }
    END { if (NR > 0) flush(prev) }
  ' "${files[@]}"
)" || {
  echo "gnu-only-syntax-guard: the scan itself failed" >&2
  exit 2
}

gnu_only_guard_finished=1
if [[ -n "$findings" ]]; then
  printf '%s\n' "$findings"
  echo "gnu-only-syntax-guard: GNU-only syntax found — probe the way the script runs (bash -c), not the interactive shell" >&2
  exit 1
fi
echo "gnu-only-syntax-guard: OK — ${#files[@]} bash script(s) scanned"
