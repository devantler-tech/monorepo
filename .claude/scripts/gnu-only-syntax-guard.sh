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
# Rules (extend the rule block in the awk program when a new instance is measured):
#   find-newermt-epoch  `-newer?t @…` — BSD find cannot parse an `@<epoch>` date. Use a `touch -t`
#                       reference file with `-newer` instead.
#   date-d-without-bsd  `date … -d` / `--date` with no BSD form (`date … -v`, `-j` or `-r`) within
#                       three commands. The dual-dialect idiom tries one form and falls back to the
#                       other; a GNU form on its own fails on macOS.
#
# How a script is read. A small lexer splits each script into commands the way the shell does: a
# backslash-newline or an open quote joins the next line, `;` and a lone `&` end a command (`&&`,
# `||` and `|` join parts of one), a `#` that starts a word begins a comment, single, double and
# $'…' quotes and backslash escapes are tracked, `$(…)` and backticks inside double quotes are code
# again, `$((…))`/`((…))` is arithmetic, a quoted `bash -c`/`sh -c`/`eval` argument is code, and
# here-document bodies are data and skipped. Rules read only a command's code (quoted data removed),
# so a form mentioned in a string or comment is neither a finding nor a fallback. A BSD fallback
# must also be `date` in command position; a GNU form is flagged wherever `date` appears in code,
# which over-flags rather than under-flags. Bare keywords (`then`, `fi`, …) and `:` do not count
# toward the window. A finding is reported at the command's first line. A quote or here-document
# left open at the end of a file is unknown.
#
# A command may opt out with a trailing comment `# gnu-only-ok: <reason>` when it only ever runs on
# GNU (for example a Linux-only CI step). Only a real comment counts, never quoted data.
#
# Usage: gnu-only-syntax-guard.sh [FILE...]
#   With no FILE, scans every bash-shebanged .claude/scripts/*.sh except this guard and its test,
#   whose fixtures contain the flagged constructs on purpose.
# Exit: 0 no finding, 1 findings (one `path:line: rule: text` each), 2 unknown (usage error, an
# unreadable, empty or unterminated file, nothing to scan, or any abort before the scan finished).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only reaching a verdict may leave with 0 or 1. Any other exit — a failed command under `set -e`,
# or bash 3.2 reporting a `set -u` abort as 0 to the trap — is unknown, never a finding or a pass.
gnu_only_guard_finished=0
cleanup() {
  local rc=$?
  if [[ "$gnu_only_guard_finished" != 1 ]]; then
    [[ $rc -eq 2 ]] || echo "gnu-only-syntax-guard: aborted before finishing (status $rc); reporting unknown" >&2
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
      sed -n '2,38p' "${BASH_SOURCE[0]}"
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

operands=()
for f in "${files[@]}"; do
  [[ -f "$f" && -r "$f" ]] || unknown "cannot read $f"
  # An empty file has no content to examine, so it cannot be reported clean.
  [[ -s "$f" ]] || unknown "$f is empty — nothing was examined"
  # awk reads an operand shaped like `name=value` as an assignment, not a file; `./` prevents that.
  case "$f" in
    /*) operands+=("$f") ;;
    *) operands+=("./$f") ;;
  esac
done

scan="$(
  awk -v q="'" '
    BEGIN {
      # The `@` of `-newer?t @…` may be bare, quoted (`Q@` in the code view) or inside a payload.
      newer_epoch = "-newer[A-Za-z]t[ \t]+(Q|[\"" q "])?@"
      opts = "([ \t]+(-[A-Za-z]+|--[A-Za-z][A-Za-z-]*(=[^ \t]*)?))*[ \t]+"
      # A GNU form is flagged wherever `date` appears in code (over-flagging is the safe direction);
      # `-[A-Za-z]*d` also covers the attached `-dSTRING` form.
      gnu_date_re = "(^|[^A-Za-z0-9_.-])date" opts "(-[A-Za-z]*d|--date)"
      # A BSD fallback counts only where the shell invokes `date` as a command, and only with the
      # BSD flags (`-v`, `-j`, `-r`, optionally after `-n`, `-u`, `-R`, `-I`).
      cmd_pos = "(^|[;&|(`!{]|\\$\\()[ \t]*(([A-Za-z_][A-Za-z0-9_]*=[^ \t]*|command|exec|env|builtin)[ \t]+)*([^ \t;&|()]*/)?date"
      bsd_date_re = cmd_pos opts "-[nuRI]*[vjr]"
      # A quoted argument to these runs as code.
      payload_re = "((^|[^A-Za-z0-9_.-])([bdkz]|ba|da)?sh([ \t]+-[A-Za-z]+)*[ \t]+-[A-Za-z]*c|(^|[^A-Za-z0-9_])eval)[ \t]*$"
    }

    function reset_file() {
      count = 0; joining = 0; hn = 0; hcur = 0; in_heredoc = 0
      sd = 0; st[0] = "N"
      delete nc; delete co; delete cm; delete raw; delete start; delete pd; delete bt; delete pay
    }
    function begin_command(text) {
      count++
      nc[count] = ""; co[count] = ""; cm[count] = ""; raw[count] = text; start[count] = FNR
    }
    function emit(s) { nc[count] = nc[count] s; co[count] = co[count] s }
    # A `#` starts a comment only at the start of a word.
    function word_start(s) { return s == "" || substr(s, length(s), 1) ~ /[ \t\n;&|()]/ }
    function push(mode) { sd++; st[sd] = mode; pd[sd] = 0; bt[sd] = 0; pay[sd] = 0 }

    # Read a here-document operator at line position i (just past `<<`); queue its delimiter and
    # return the position after it.
    function heredoc_op(line, i,   n, c, d, dash) {
      n = length(line); dash = 0
      if (substr(line, i, 1) == "-") { dash = 1; i++ }
      while (i <= n && substr(line, i, 1) ~ /[ \t]/) i++
      d = ""
      while (i <= n) {
        c = substr(line, i, 1)
        if (c ~ /[ \t;&|()<>]/) break
        if (c != q && c != "\"" && c != "\\") d = d c
        i++
      }
      if (d != "") { hn++; hq[hn] = d; hdash[hn] = dash }
      return i
    }

    # Lex one physical line into the current command, starting a new command at each top-level
    # `;` or lone `&`. Returns 1 when the command continues on the next line (backslash-newline, or
    # an open quote, substitution or arithmetic), 0 when it ends here.
    function lex(line,   i, n, c, m, run) {
      n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1); m = st[sd]
        if (m == "S") {
          if (c == q) { if (pay[sd]) co[count] = co[count] ";"; nc[count] = nc[count] c; sd--; i++; continue }
          nc[count] = nc[count] c; if (pay[sd]) co[count] = co[count] c
          i++; continue
        }
        if (m == "A" || m == "D") {
          if (c == "\\") {
            nc[count] = nc[count] substr(line, i, 2); if (pay[sd]) co[count] = co[count] substr(line, i, 2)
            i += 2; continue
          }
          if ((m == "A" && c == q) || (m == "D" && c == "\"")) {
            if (pay[sd]) co[count] = co[count] ";"
            nc[count] = nc[count] c; sd--; i++; continue
          }
          if (m == "D" && !pay[sd] && c == "$" && substr(line, i + 1, 1) == "(") {
            # A command substitution inside double quotes is code again.
            nc[count] = nc[count] "$("; co[count] = co[count] " $("
            push("N"); i += 2; continue
          }
          if (m == "D" && !pay[sd] && c == "`") {
            nc[count] = nc[count] c; co[count] = co[count] " `"
            push("N"); bt[sd] = 1; i++; continue
          }
          nc[count] = nc[count] c; if (pay[sd]) co[count] = co[count] c
          i++; continue
        }
        if (m == "M") {
          # Arithmetic: `<<` is a shift and `#` is not a comment; only the closing `))` matters.
          if (c == "(") pd[sd]++
          if (c == ")") {
            if (pd[sd] == 0 && substr(line, i + 1, 1) == ")") { emit("))"); sd--; i += 2; continue }
            if (pd[sd] > 0) pd[sd]--
          }
          emit(c); i++; continue
        }
        # Code.
        if (c == "\\") {
          if (i == n) return 1
          emit(substr(line, i, 2)); i += 2; continue
        }
        if (c == "#" && word_start(nc[count])) { cm[count] = substr(line, i); return 0 }
        if (c == q || c == "\"" || (c == "$" && substr(line, i + 1, 1) == q)) {
          run = (c == "$") ? "$" q : c
          if (co[count] ~ payload_re) { push(c == "$" ? "A" : (c == q ? "S" : "D")); pay[sd] = 1; nc[count] = nc[count] run; co[count] = co[count] ";" }
          else {
            push(c == "$" ? "A" : (c == q ? "S" : "D"))
            nc[count] = nc[count] run
            co[count] = co[count] "Q" (substr(line, i + length(run), 1) == "@" ? "@" : "")
          }
          i += length(run); continue
        }
        if (substr(line, i, 3) == "$((") { emit("$(("); push("M"); i += 3; continue }
        if (substr(line, i, 2) == "((") { emit("(("); push("M"); i += 2; continue }
        if (sd > 0 && bt[sd] && c == "`") { emit(c); sd--; i++; continue }
        if (sd > 0 && !bt[sd] && c == "(") pd[sd]++
        if (sd > 0 && !bt[sd] && c == ")") {
          if (pd[sd] == 0) { emit(c); sd--; i++; continue }
          pd[sd]--
        }
        if (substr(line, i, 3) == "<<<") { emit("<<<"); i += 3; continue }
        if (substr(line, i, 2) == "<<") { emit("<<"); i = heredoc_op(line, i + 2); continue }
        # `;` and a lone `&` end a command; `&&`, `||` and `|` join the parts of one list, and `>&`,
        # `&>` are redirections.
        if (sd == 0 && substr(line, i, 2) ~ /^(&&|\|\|)$/) { emit(substr(line, i, 2)); i += 2; continue }
        if (sd == 0 && (c == ";" || (c == "&" && substr(line, i - 1, 1) !~ /[<>]/ && substr(line, i + 1, 1) != ">"))) {
          run = c
          while (i + length(run) <= n && substr(line, i + length(run), 1) == ";") run = run ";"
          emit(run); i += length(run)
          begin_command(line)
          continue
        }
        emit(c); i++
      }
      if (sd > 0) { emit("\n"); return 1 }
      return 0
    }

    # Blank entries, bare keywords (`then`, `fi`, `do`, …) and the `:` no-op are not commands.
    function is_command(k,   s) {
      s = nc[k]; gsub(/[ \t\n;&]/, "", s)
      return s != "" && s !~ /^(then|else|elif|fi|do|done|esac|in|[{}]|:)$/
    }
    function opted_out(k) { return cm[k] ~ /^#[ \t]*gnu-only-ok:[ \t]*[^ \t]/ }
    function report(file, k, rule,   s) {
      s = raw[k]; sub(/^[ \t]+/, "", s)
      printf "F\t%s:%d: %s: %s\n", file, start[k], rule, s
    }

    function flush(file,   k, i, j, n, idx, lo, hi, has_bsd, last) {
      if (joining || in_heredoc) {
        printf "U\t%s: a quote, continuation or here-document is still open at the end of the file\n", file
      }
      # Index the commands, so the fallback window counts commands rather than lines. A trailing
      # comment belongs to the last command on its line, which is where it was recorded.
      n = 0
      for (k = 1; k <= count; k++) if (is_command(k)) { n++; idx[n] = k }
      last = ""
      for (j = 1; j <= n; j++) {
        k = idx[j]
        if (opted_out(k)) continue
        if (co[k] ~ newer_epoch) report(file, k, "find-newermt-epoch")
        if (co[k] ~ gnu_date_re) {
          has_bsd = 0
          lo = j - 3; if (lo < 1) lo = 1
          hi = j + 3; if (hi > n) hi = n
          for (i = lo; i <= hi; i++) if (co[idx[i]] ~ bsd_date_re) has_bsd = 1
          if (!has_bsd) report(file, k, "date-d-without-bsd")
        }
      }
      printf "S\t%s\n", file
    }

    FNR == 1 {
      if (NR > 1) flush(prev)
      reset_file()
    }
    {
      prev = FILENAME
      line = $0
      if (in_heredoc) {
        # A here-document body is data. It ends at a line equal to its delimiter (tabs stripped
        # first for `<<-`); several queued here-documents are read in order.
        term = line
        if (hdash[hcur]) sub(/^\t+/, "", term)
        if (term == hq[hcur]) {
          hcur++
          if (hcur > hn) { in_heredoc = 0; hn = 0 }
        }
        next
      }
      if (!joining) begin_command(line)
      else raw[count] = raw[count] " " line
      joining = lex(line)
      if (!joining && hn > 0) { in_heredoc = 1; hcur = 1 }
    }
    END { if (NR > 0) flush(prev) }
  ' "${operands[@]}"
)" || unknown "the scan itself failed"

# Every file must have been read to the end, or a clean result would cover content never examined.
scanned=0
findings=""
while IFS= read -r row; do
  case "$row" in
    S$'\t'*) scanned=$((scanned + 1)) ;;
    F$'\t'*) findings+="${row#F$'\t'}"$'\n' ;;
    U$'\t'*) unknown "${row#U$'\t'}" ;;
    '') ;;
    *) unknown "unexpected scanner output: $row" ;;
  esac
done <<<"$scan"
[[ $scanned -eq ${#operands[@]} ]] ||
  unknown "scanned ${scanned} of ${#operands[@]} file(s) — refusing to report on the rest"

gnu_only_guard_finished=1
if [[ -n "$findings" ]]; then
  printf '%s' "$findings"
  echo "gnu-only-syntax-guard: GNU-only syntax found — probe the way the script runs (bash -c), not the interactive shell" >&2
  exit 1
fi
echo "gnu-only-syntax-guard: OK — ${#files[@]} bash script(s) scanned"
