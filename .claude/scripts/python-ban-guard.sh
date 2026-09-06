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
#        (`*.md`, `*.mdx`): `python`, `python3`, `python3.12`, `pip`, `pip3` or `pytest` in
#        COMMAND POSITION, matched by the command's BASENAME so `/usr/bin/python3` counts. A
#        `#` comment is cut off quote-aware (a `#` inside quotes is text), then quotes are
#        stripped and the line is cut into command segments at `;`, `|`, `&`, `(`, a backtick,
#        `{`, `[`, `]`, `,`, and at `-c`, YAML `run:` and Dockerfile `RUN`/`CMD`/`ENTRYPOINT`
#        (which open a nested command); in each segment the first token that is not a `VAR=`
#        prefix, a `-flag`, or a command-wrapping word (`exec`, `xargs`, `env`, `sudo`, `time`,
#        `command`, `nohup`, `if`/`then`/`else`/`do`/`while`/`until`/`!`) is the command. So
#        `bash -c "python3 -m x"`, `FOO=1 python3 x` and `RUN python3 x` flag, while
#        `echo "install python3"` and a YAML `name: Install python deps` do not.
#        Two known limits of that heuristic, accepted for a ~170-line bash guard: a flag's
#        ARGUMENT is read as the command (`sudo -u nobody pip3 …` reads `nobody`), and quotes
#        are stripped before segmenting, so a quoted alternation such as
#        `grep -E '(npm ci|pytest)'` reads `pytest` as a command — a file that legitimately
#        lists interpreters as text declares the allow-file marker below.
#
# THE CARVE-OUT (#2324) — recognised by INVOCATION, never by file extension
#   An embedded interpreter that admits only Python is dictated by the host tool, not chosen by
#   us: `blender --background --python bake.py`. The ONE command segment carrying both `blender`
#   and `--python` is skipped; other commands on the same line are still scanned. A `.py` file
#   still trips check 1 in THIS repository on purpose: the sanctioned instance lives in a
#   submodule (world-at-ruin), which this guard never scans.
#
# ALLOW-FILE MARKER
#   A file that is ABOUT the offending form — this guard's self-test quotes `python3 -c` as
#   fixture text — declares `python-ban-guard: allow-file — <reason>` anywhere in its text. The
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

rule='AGENTS.md → "Scripting stack — bash or Go, never Python": write it in bash (jq for data shaping) and migrate it to Go when it grows. The one carve-out is an embedded interpreter that admits only Python, recognised by its invocation (`blender --background --python …`), never by file extension. A file that is ABOUT the offending form may declare `python-ban-guard: allow-file — <reason>`.'

findings=0
report() {
  printf 'python-ban-guard: %s\n' "$1"
  findings=$((findings + 1))
}

# Print one `path:line: Python invocation `<hit>`` per offending line of $2 (displayed as $1).
scan_invocations() {
  awk -v path="$1" -v sq="'" '
    # Index of the first token from `from` that is a command: not empty, not a -flag, not a
    # VAR= prefix, not a wrapping word. Returns n + 1 when the segment has none.
    function first_command(tok, from, n,    i, t) {
      for (i = from; i <= n; i++) {
        t = tok[i]
        if (t == "" || t ~ /^-/ || t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || index(wrappers, " " t " ") > 0) continue
        return i
      }
      return n + 1
    }
    # Cut a shell comment off `s`, QUOTE-AWARE: a `#` opens a comment only at line start or
    # after whitespace, and only outside single or double quotes — `echo "a # b"; python3 …`
    # keeps its invocation. (A backslash-escaped quote inside double quotes is not modelled.)
    function strip_comment(s,    i, c, q) {
      q = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = ""; continue }
        if (c == "\"" || c == sq) { q = c; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/)) return substr(s, 1, i - 1)
      }
      return s
    }
    BEGIN {
      # The interpreter pattern lives HERE and nowhere else; the self-test ablates this line.
      interp = "^(python[23]?([.][0-9]+)?|pip3?|pytest)$"
      # Words that wrap a command rather than being one: the walk skips them and reads on.
      wrappers = " exec xargs env sudo time command nohup if then elif else do while until ! "
    }
    {
      line = strip_comment($0)
      # Quotes do not hide an invocation: `bash -c "python3 …"` still runs it.
      gsub(/"/, " ", line)
      gsub(sq, " ", line)
      # A YAML `run:` and a Dockerfile `RUN`/`CMD`/`ENTRYPOINT` open a command: cut a new
      # segment there. The exec-form brackets and commas are separators too.
      gsub(/(^|[[:space:]])(run:|RUN|CMD|ENTRYPOINT)([[:space:]]|$)/, " ; ", line)
      nseg = split(line, seg, /[][;|&(`{,]+/)
      for (s = 1; s <= nseg; s++) {
        # The embedded-interpreter carve-out, keyed on the invocation shape and scoped to the
        # ONE segment that carries it: commands sharing its line are still scanned.
        if (seg[s] ~ /(^|[^[:alnum:]_.-])blender([[:space:]]|$)/ && seg[s] ~ /--python([[:space:]=]|$)/) continue
        n = split(seg[s], tok, /[[:space:]]+/)
        i = first_command(tok, 1, n)
        # A shell given -c runs the string after it: the command is what follows the -c.
        while (i <= n && tok[i] ~ /^(bash|sh|zsh|dash|ksh)$/) {
          k = 0
          for (j = i + 1; j <= n; j++) if (tok[j] == "-c") { k = j; break }
          if (k == 0) break
          i = first_command(tok, k + 1, n)
        }
        if (i > n) continue
        # Match the command by its BASENAME, so `/usr/bin/python3` is the same invocation.
        base = tok[i]
        sub(/.*\//, "", base)
        if (base ~ interp) {
          # Name the interpreter and its first argument, so the reader sees the form at a glance.
          hit = tok[i]
          if (i < n && tok[i + 1] != "") hit = hit " " tok[i + 1]
          printf "%s:%d: Python invocation `%s`\n", path, NR, hit
        }
      }
    }' "$2"
}

while IFS= read -r -d '' path; do
  file="$top/$path"
  [ -f "$file" ] || continue                     # a gitlink, or a path missing from the tree
  case "$path" in
    *.py|*.pyi|*.pyw)
      report "$path: Python source file"
      continue ;;
  esac
  case "$path" in *.md|*.mdx) continue ;; esac  # prose is not an executable surface
  grep -Iq . "$file" 2>/dev/null || continue     # binary, or empty
  if head -n 1 "$file" | grep -Eq '^#![^#]*([/[:space:]]|-S|--split-string=)python[0-9.]*([[:space:]]|$)'; then
    report "$path: Python source file (its shebang names python)"
    continue
  fi
  if grep -Fq 'python-ban-guard: allow-file' "$file"; then
    if grep -Eq 'python-ban-guard: allow-file — [^[:space:]]' "$file"; then
      continue
    fi
    report "$path: bare \`python-ban-guard: allow-file\` marker carries no reason; a marker states WHY the file is about the form, or it is a finding"
    continue
  fi
  hits="$(scan_invocations "$path" "$file")"
  if [ -n "$hits" ]; then
    while IFS= read -r hit; do
      report "$hit"
    done <<<"$hits"
  fi
done < <(git -C "$top" ls-files -z)

if [ "$findings" -gt 0 ]; then
  printf 'python-ban-guard: %d finding(s) in %s\n%s\n' "$findings" "$top" "$rule" >&2
  exit 1
fi
echo "python-ban-guard: clean — no Python source file or invocation on a tracked executable surface in $top"
