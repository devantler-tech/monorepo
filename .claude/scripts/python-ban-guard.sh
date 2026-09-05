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
#        command position (line start, or after `|`, `;`, `&`, `(`, a backtick, a quote, or
#        `exec`/`xargs`/`env`/`sudo`/`time`/`command`/`nohup`), with `#` comments stripped first.
#
# THE CARVE-OUT (#2324) — recognised by INVOCATION, never by file extension
#   An embedded interpreter that admits only Python is dictated by the host tool, not chosen by
#   us: `blender --background --python bake.py`. A line carrying both `blender` and `--python`
#   is skipped. A `.py` file still trips check 1 in THIS repository on purpose: the sanctioned
#   instance lives in a submodule (world-at-ruin), which this guard never scans.
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
    {
      line = $0
      # A `#` at line start or after whitespace opens a comment: a commented-out or
      # merely-mentioned invocation is not an executable one.
      if (match(line, /(^|[[:space:]])#/)) line = substr(line, 1, RSTART - 1)
      # The embedded-interpreter carve-out, keyed on the invocation shape.
      if (line ~ /(^|[^[:alnum:]_.-])blender([[:space:]]|$)/ && line ~ /--python([[:space:]=]|$)/) next
      # Quotes do not hide an invocation: `bash -c "python3 …"` still runs it.
      gsub(/"/, " ", line)
      gsub(sq, " ", line)
      if (match(line, /(^|[[:space:];&|(`]|exec[[:space:]]+|xargs[[:space:]]+|env[[:space:]]+|sudo[[:space:]]+|time[[:space:]]+|command[[:space:]]+|nohup[[:space:]]+)(python[23]?([.][0-9]+)?|pip3?|pytest)([[:space:]]|$)/)) {
        # Name the interpreter and its first argument, so the reader sees the form at a glance.
        rest = substr(line, RSTART)
        n = split(rest, tok, /[[:space:]]+/)
        hit = ""
        for (i = 1; i <= n; i++) {
          if (hit == "" && tok[i] ~ /^[;&|(`]*(python[23]?([.][0-9]+)?|pip3?|pytest)$/) {
            hit = tok[i]
            sub(/^[;&|(`]+/, "", hit)
            if (i < n && tok[i + 1] != "") hit = hit " " tok[i + 1]
          }
        }
        printf "%s:%d: Python invocation `%s`\n", path, NR, hit
      }
    }' "$2"
}

while IFS= read -r -d '' path; do
  file="$top/$path"
  [ -f "$file" ] || continue                     # a gitlink, or a path missing from the tree
  case "$path" in
    *.py|*.pyi|*.pyw)
      report "$path: Python source file — $rule"
      continue ;;
  esac
  grep -Iq . "$file" 2>/dev/null || continue     # binary, or empty
  if head -n 1 "$file" | grep -Eq '^#![^[:space:]]*(/|[[:space:]])python[0-9.]*([[:space:]]|$)'; then
    report "$path: Python source file (its shebang names python) — $rule"
    continue
  fi
  if grep -Fq 'python-ban-guard: allow-file' "$file"; then
    if grep -Eq 'python-ban-guard: allow-file — [^[:space:]]' "$file"; then
      continue
    fi
    report "$path: bare \`python-ban-guard: allow-file\` marker carries no reason; a marker states WHY the file is about the form, or it is a finding — $rule"
    continue
  fi
  case "$path" in *.md|*.mdx) continue ;; esac  # prose is not an executable surface
  hits="$(scan_invocations "$path" "$file")"
  if [ -n "$hits" ]; then
    while IFS= read -r hit; do
      report "$hit — $rule"
    done <<<"$hits"
  fi
done < <(git -C "$top" ls-files -z)

if [ "$findings" -gt 0 ]; then
  printf 'python-ban-guard: %d finding(s) in %s\n' "$findings" "$top" >&2
  exit 1
fi
echo "python-ban-guard: clean — no Python source file or invocation on a tracked executable surface in $top"
