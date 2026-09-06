#!/usr/bin/env bash
# python-ban-guard.sh — keep Python off this repository's executable surfaces.
#
# WHY THIS EXISTS
#   AGENTS.md → *Scripting stack — bash or Go, never Python* is constitutional: every script
#   surface here is bash or Go. The rule had no standing enforcement, so three weeks after the
#   last `.py` file was removed (#2231) a `python3 -c` harness landed in an agent-authored
#   contract test, passed CI and two review rounds, and was found only by chance (#2769). The
#   migration epic (#2140) removes the stock; this guard removes the flow: it fails a change
#   that introduces a Python source file or a Python invocation, and its message names the rule
#   and what to write instead — a guard that blocks without naming the fix is a DevEx tax.
#
# WHAT IT SCANS
#   Tracked files only (`git ls-files`), because "a tracked file introduces" is the contract, and
#   only this repository — submodules are separate repositories with their own guards (#2140
#   owns widening). Two checks per file:
#     1. A Python SOURCE file: `*.py`, `*.pyi`, `*.pyw`, or a shebang naming python.
#     2. A Python INVOCATION on an executable surface — every tracked text file except prose
#        (`*.md`, `*.mdx`): `python`, `python3`, `python3.12`, `pip`, `pip2`, `pip2.7`, `pip3`, `pip3.12` or `pytest` in
#        COMMAND POSITION. In the remaining compatibility heuristic described below, after
#        unquoted `#` comments and quotes are stripped, a line is cut into
#        command segments at `;`, `|`, `&`, `(`, a backtick, `{`, and at `-c` / `run:` (which
#        open a nested command; YAML `shell:` selects one); in each segment the first token that is not a `VAR=` prefix, a
#        `-flag`, or a command-wrapping word (`exec`, `xargs`, `env`, `sudo`, `time`, `command`,
#        `nohup`, `nice`, `timeout`, `stdbuf`, `setsid`, `ionice`, `doas`,
#        `if`/`then`/`else`/`do`/`while`/`until`/`!`) is the command. Wrappers consume their
#        option operands and exclude non-executing modes before selecting a child. So
#        `bash -c "python3 -m x"` and `FOO=1 python3 x` flag, while `echo "install python3"` and
#        a YAML `name: Install python deps` do not. Executable paths are matched by basename.
#        Dockerfile RUN/CMD/ENTRYPOINT shell and JSON operands are scanned; those words are
#        not command wrappers in other files.
#        Backslash-newline continuations outside single quotes join before matching command names.
#        Unquoted escapes before executable-name/path characters retain their executable identity.
#        Shell sources, workflow command fields, other YAML command/run/shell operands,
#        package scripts, Make recipes and Dockerfile operands use the Go parser.
#        YAML argv sequences preserve complete scalar boundaries. Go generate directives
#        and aliases are parsed before the remaining Go text reaches the compatibility route.
#        Make resolves literal local definitions only; functions, referenced values, includes,
#        conditional values and host environment are not evaluated. Dynamic recipe prefixes fail closed.
#        Other non-prose
#        textual formats retain the legacy invocation heuristic; their language semantics
#        are not exhaustively analysed, and quoted snippets in those formats can still be
#        reported by the heuristic. Module extensions use that same compatibility route,
#        not shell parsing; this does not add a JavaScript parser. Malformed declared shell/YAML sources exit 2.
#
# THE CARVE-OUT (#2324) — recognised by INVOCATION, never by file extension
#   An embedded interpreter that admits only Python is dictated by the host tool, not chosen by
#   us: `blender --background --python bake.py`. Here Blender is the command and `--python`
#   is its argument; an unrelated Python command on that line is still checked. A `.py` file
#   still trips check 1 in THIS repository on purpose: the sanctioned
#   instance lives in a submodule (world-at-ruin), which this guard never scans.
#
# ALLOW-FILE MARKER
#   A file that is ABOUT the offending form — this guard's self-test quotes `python3 -c` as
#   fixture text — declares `python-ban-guard: allow-file — <reason>` in a parsed comment. The
#   reason is mandatory: a bare marker is reported as a finding, never honoured.
#
# USAGE
#   python-ban-guard.sh [<repo-dir>]   # default: the repository this script lives in
#   exit 0  clean
#   exit 1  findings — one line per finding (path:line: what — the rule), then a count
#   exit 2  usage error, or <repo-dir> is not a git repository
#
# python-ban-guard: allow-file — this file names every form it rejects, as documentation.
set -Eeuo pipefail

[ $# -le 1 ] || { echo "usage: python-ban-guard.sh [<repo-dir>]" >&2; exit 2; }
if [ $# -eq 1 ]; then
  repo="$1"
else
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" ||
  { echo "python-ban-guard: not a git repository: $repo" >&2; exit 2; }

# Keep NUL-delimited paths intact, and inspect the producer's exit status before scanning.
tracked_paths="$(mktemp)" || { echo "python-ban-guard: cannot allocate tracked-file list" >&2; exit 2; }
parser_binary="$(mktemp)" || { echo "python-ban-guard: cannot allocate parser binary" >&2; rm -f -- "$tracked_paths"; exit 2; }
trap 'rm -f -- "$tracked_paths" "$parser_binary"' EXIT
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! go -C "$script_dir/python-ban-guard-go" build -o "$parser_binary" .; then
  echo "python-ban-guard: cannot build command parser" >&2
  exit 2
fi
if ! git -C "$top" ls-files -z >"$tracked_paths"; then
  echo "python-ban-guard: cannot enumerate tracked files in $top" >&2
  exit 2
fi

rule='AGENTS.md → "Scripting stack — bash or Go, never Python": write it in bash (jq for data shaping) and migrate it to Go when it grows. The one carve-out is an embedded interpreter that admits only Python, recognised by its invocation (`blender --background --python …`), never by file extension. A file that is ABOUT the offending form may declare `python-ban-guard: allow-file — <reason>`.'

findings=0
# Emit one finding and include it in the final failure count.
report() {
  printf 'python-ban-guard: %s\n' "$1"
  findings=$((findings + 1))
}

# Print one `path:line: Python invocation `<hit>`` per offending line of $2 (displayed as $1).
scan_invocations() {
  # Commands use ASCII syntax; unrelated invalid UTF-8 bytes must not abort the scan.
  LC_ALL=C awk -v path="$1" -v sq="'" '
    # Compare executable basenames while preserving full paths in diagnostics.
    function executable_name(token) {
      sub(/^.*\//, "", token)
      return token
    }
    # Only an unquoted, unescaped hash at a token boundary starts a comment.
    # Expose a trailing escape outside single quotes so the caller can join physical lines.
    function without_comment(text,    i, c, quote, escaped, boundary) {
      quote = ""
      escaped = 0
      boundary = 1
      continues = 0
      for (i = 1; i <= length(text); i++) {
        c = substr(text, i, 1)
        if (escaped) { escaped = 0; boundary = 0; continue }
        if (c == "\\" && quote != sq) { escaped = 1; boundary = 0; continue }
        if (quote != "") {
          if (c == quote) quote = ""
          continue
        }
        if (c == sq || c == "\"") { quote = c; boundary = 0; continue }
        if (c == "#" && boundary) return substr(text, 1, i - 1)
        boundary = c ~ /[[:space:]]/
      }
      continues = escaped && quote != sq
      return text
    }
    # Recognize unquoted boundaries used by the compatibility command segments.
    function word_boundary(c) {
      return c == "" || c ~ /[[:space:];|&({]/ || c == "`"
    }
    # Normalize unquoted escapes and preserve empty words before quote stripping.
    # Keep literal backslashes and escapes for shell punctuation intact.
    function word_escapes(text,    i, c, following, quote, result, boundary, after, pair) {
      quote = ""
      result = ""
      boundary = 1
      for (i = 1; i <= length(text); i++) {
        c = substr(text, i, 1)
        if (c == "\\" && quote != sq) {
          following = substr(text, i + 1, 1)
          if (quote == "" && (following ~ /^[A-Za-z0-9_.-]$/ || following == "/")) result = result following
          else result = result c following
          i++
          boundary = 0
          continue
        }
        # Keep an explicit empty argv word when later quote stripping would erase it.
        # Only whole unescaped words qualify; empty quotes can also join real text.
        if (quote == "" && boundary && (c == sq || c == "\"")) {
          after = i
          pair = substr(text, after, 2)
          while (pair == sq sq || pair == "\"\"") {
            after += 2
            pair = substr(text, after, 2)
          }
          if (after > i && word_boundary(substr(text, after, 1))) {
            result = result "__python_ban_guard_empty_word__"
            i = after - 1
            boundary = 0
            continue
          }
        }
        if (c == sq || c == "\"") {
          if (quote == "") quote = c
          else if (quote == c) quote = ""
          boundary = 0
        } else {
          boundary = quote == "" && word_boundary(c)
        }
        result = result c
      }
      return result
    }
    # Resolve an exact or uniquely abbreviated GNU long option to its short form.
    function wrapper_long(name, key,    parts, pair, count, j, result) {
      count = split(long_options[name], parts, " ")
      result = ""
      for (j = 1; j <= count; j++) {
        split(parts[j], pair, ":")
        if (pair[1] == key) return pair[2]
        if (index(pair[1], key) == 1) {
          if (result != "") return ""
          result = pair[2]
        }
      }
      return result
    }
    # Return the selected child index; options and their values remain data.
    function wrapped_command(name, tok, from, n,    i, t, options, option, attached, j, key, mode) {
      mode = 0
      for (i = from; i <= n;) {
        t = tok[i]
        if (t == "") { i++; continue }
        if (t == "--") { i++; break }
        if (t !~ /^-/ || t == "-") break
        i++
        attached = 0
        if (t ~ /^--/) {
          key = substr(t, 3)
          attached = index(key, "=") > 0
          sub(/=.*/, "", key)
          options = wrapper_long(name, key)
          if (options == "") return n + 1
          # Optional long operands must be attached with =; short arity can differ.
          if (index(optional_options[name] optional_long_options[name], options) > 0) continue
          if (attached && index(value_options[name], options) == 0) return n + 1
        } else options = substr(t, 2)
        for (j = 1; j <= length(options); j++) {
          option = substr(options, j, 1)
          if (index(stop_options[name], option) > 0) return n + 1
          if (index(optional_options[name], option) > 0) break
          if (index(value_options[name], option) > 0) {
            mode = 1
            if (!attached && j == length(options)) {
              while (i <= n && tok[i] == "") i++
              if (i > n) return n + 1
              i++
            }
            break
          }
          if (index(flag_options[name], option) == 0) return n + 1
        }
      }
      if (name == "stdbuf" && !mode) return n + 1
      while (i <= n && tok[i] == "") i++
      if (name == "timeout" && i <= n) i++
      while (i <= n && tok[i] == "") i++
      if (name == "sudo") {
        while (i <= n && (tok[i] == "" || tok[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) i++
      }
      return i
    }
    # Return the first command after assignments and wrappers, or n + 1 if absent.
    function first_command(tok, from, n,    i, t, wrapper, env_options, selected) {
      wrapper = ""
      env_options = 0
      selected = 0
      for (i = from; i <= n; i++) {
        t = tok[i]
        if (t == "") continue
        if (selected && (t ~ /^-/ || t ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) return i
        if (wrapper == "env") {
          if (env_options) {
            if (t == "--" || t == "-") { env_options = 0; continue }
            if (t ~ /^-[iv]*[uCaP]$/ || t == "--unset" || t == "--chdir" || t == "--argv0") { i++; continue }
            if (t == "--help" || t == "--version") return n + 1
            while (t ~ /^-[iv]*S./ || t ~ /^--split-string=./) {
              if (t ~ /^-[iv]*S./) sub(/^-[iv]*S/, "", t)
              else sub(/^--split-string=/, "", t)
              tok[i] = t
            }
            if (t ~ /^-/) continue
          }
          if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { env_options = 0; continue }
        }
        if (wrapper == "nice" && (t == "--help" || t == "--version")) return n + 1
        if (wrapper == "nice" && (t == "-n" || t == "--adjustment")) { i++; continue }
        if (wrapper != "env" && (t ~ /^-/ || t ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) continue
        if (index(extended_wrappers, " " executable_name(t) " ") > 0) {
          i = wrapped_command(executable_name(t), tok, i + 1, n) - 1
          wrapper = ""
          env_options = 0
          selected = 1
          continue
        }
        if (index(wrappers, " " executable_name(t) " ") > 0) {
          wrapper = executable_name(t)
          env_options = wrapper == "env"
          selected = 0
          continue
        }
        return i
      }
      return n + 1
    }
    BEGIN {
      # Legacy fallback pattern; the self-test ablates both scanner engines.
      interp = "^(python[23]?([.][0-9]+)?|pip[23]?([.][0-9]+)?|pytest)$"
      extended_wrappers = " timeout stdbuf setsid ionice doas sudo exec xargs command nohup time "
      flag_options["timeout"] = "fpv"; value_options["timeout"] = "ks"; stop_options["timeout"] = "HV"
      long_options["timeout"] = "kill-after:k signal:s foreground:f preserve-status:p verbose:v help:H version:V"
      value_options["stdbuf"] = "ioe"; stop_options["stdbuf"] = "HV"
      long_options["stdbuf"] = "input:i output:o error:e help:H version:V"
      flag_options["setsid"] = "cfw"; stop_options["setsid"] = "hV"
      long_options["setsid"] = "ctty:c fork:f wait:w help:h version:V"
      flag_options["ionice"] = "t"; value_options["ionice"] = "cn"; stop_options["ionice"] = "pPuhV"
      long_options["ionice"] = "class:c classdata:n ignore:t pid:p pgid:P uid:u help:h version:V"
      flag_options["doas"] = "n"; value_options["doas"] = "au"; stop_options["doas"] = "CLs"
      flag_options["xargs"] = "0oprtx"; value_options["xargs"] = "adEIJLnPRSs"; stop_options["xargs"] = "HV"
      optional_options["xargs"] = "eil"; optional_long_options["xargs"] = "L"
      long_options["xargs"] = "arg-file:a delimiter:d eof:e replace:i max-lines:L max-args:n max-procs:P max-chars:s process-slot-var:a null:0 open-tty:o interactive:p no-run-if-empty:r verbose:t exit:x show-limits:0 help:H version:V"
      flag_options["sudo"] = "ABbEHkNnPSis"; value_options["sudo"] = "acCDghpRrtTu"; stop_options["sudo"] = "VKvleU?"
      optional_long_options["sudo"] = "E"
      long_options["sudo"] = "auth-type:a login-class:c close-from:C chdir:D group:g host:h prompt:p chroot:R role:r type:t command-timeout:T user:u preserve-env:E preserve-groups:P set-home:H askpass:A background:b bell:B login:i shell:s reset-timestamp:k remove-timestamp:K stdin:S non-interactive:n no-update:N edit:e list:l validate:v other-user:U version:V help:?"
      flag_options["time"] = "ahlpqv"; value_options["time"] = "fo"; stop_options["time"] = "HV"
      long_options["time"] = "append:a portability:p quiet:q verbose:v format:f output:o help:H version:V"
      flag_options["exec"] = "cl"; value_options["exec"] = "a"
      flag_options["command"] = "p"; stop_options["command"] = "vV"
      stop_options["nohup"] = "HV"; long_options["nohup"] = "help:H version:V"
      # Words that wrap a command rather than being one: the walk skips them and reads on.
      wrappers = " env nice if then elif else do while until ! "
    }
    {
      first_line = NR
      logical_line = $0
      line = without_comment(logical_line)
      while (continues) {
        read_status = (getline next_line)
        if (read_status < 0) {
          printf "python-ban-guard: %s:%d: cannot read continued command\n", path, first_line > "/dev/stderr"
          exit 2
        }
        if (read_status == 0) break
        logical_line = substr(logical_line, 1, length(logical_line) - 1) next_line
        line = without_comment(logical_line)
      }
      # Dockerfile RUN, CMD and ENTRYPOINT own their command operand: RUN runs it at build
      # time, while CMD and ENTRYPOINT declare the command the image itself runs, so a
      # container whose Python entrypoint is written there — most often in exec form — is
      # exactly as much an invocation as a RUN. JSON punctuation separates argv;
      # a Python-looking argument of echo remains data, not a command.
      if (executable_name(path) ~ /^(Dockerfile([.].+)?|.+[.]Dockerfile)$/ &&
          toupper(line) ~ /^[[:space:]]*(RUN|CMD|ENTRYPOINT)[[:space:]]+/) {
        sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", line)
        operand = line
        while (operand ~ /^[[:space:]]*--[^[:space:]]+[[:space:]]+/) sub(/^[[:space:]]*--[^[:space:]]+[[:space:]]+/, "", operand)
        if (operand ~ /^[[:space:]]*\[/) {
          line = operand
          gsub(/\[|\]|,/, " ", line)
        }
      }
      # Recognize command prefixes before normalization can change their spelling.
      gsub(/(^|[[:space:]])run:([[:space:]]|$)/, " ; ", line)
      line = word_escapes(line)
      # Quotes do not hide an invocation: `bash -c "python3 …"` still runs it.
      gsub(/"/, " ", line)
      gsub(sq, " ", line)
      nseg = split(line, seg, /[;|&(`{]+/)
      for (s = 1; s <= nseg; s++) {
        n = split(seg[s], tok, /[[:space:]]+/)
        i = first_command(tok, 1, n)
        # A shell given -c runs the string after it: the command is what follows the -c.
        while (i <= n && executable_name(tok[i]) ~ /^(bash|sh|zsh|dash|ksh)$/) {
          k = 0
          for (j = i + 1; j <= n; j++) if (tok[j] == "-c") { k = j; break }
          if (k == 0) break
          i = first_command(tok, k + 1, n)
        }
        if (i > n) continue
        if (executable_name(tok[i]) ~ interp) {
          # Name the interpreter and its first argument, so the reader sees the form at a glance.
          hit = tok[i]
          if (i < n && tok[i + 1] != "") hit = hit " " tok[i + 1]
          printf "%s:%d: Python invocation `%s`\n", path, first_line, hit
        }
      }
    }' "$2"
}

while IFS= read -r -d '' path; do
  file="$top/$path"
  # Reject tracked links before any content probe, including dangling links.
  if [ -L "$file" ]; then
    echo "python-ban-guard: $path: symlink inputs are not supported" >&2
    exit 2
  fi
  [ -f "$file" ] || continue                     # a gitlink, or a path missing from the tree
  case "$path" in
    *.py|*.pyi|*.pyw)
      report "$path: Python source file"
      continue ;;
  esac
  grep -Iq . "$file" 2>/dev/null || continue     # binary, or empty
  parser_rc=0
  hits="$("$parser_binary" "$path" "$file")" || parser_rc=$?
  case "$parser_rc" in
    0) ;;
    3)
      legacy_hits="$(scan_invocations "$path" "$file")"
      if [ -n "$legacy_hits" ]; then hits="${hits:+$hits$'\n'}$legacy_hits"; fi ;;
    *) exit 2 ;;
  esac
  if [ -n "$hits" ]; then
    while IFS= read -r hit; do
      report "$hit"
    done <<<"$hits"
  fi
done <"$tracked_paths"

if [ "$findings" -gt 0 ]; then
  printf 'python-ban-guard: %d finding(s) in %s\n%s\n' "$findings" "$top" "$rule" >&2
  exit 1
fi
echo "python-ban-guard: clean — no Python source file or invocation on a tracked executable surface in $top"
