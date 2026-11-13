#!/usr/bin/env bash
# Project-level PreToolUse hook: deny a FOREGROUND Bash poll loop on a remote system.
#
# WHY THIS EXISTS (monorepo#5010)
# The tool-call-discipline guide forbids foreground-blocking on a remote wait and names
# `Monitor` as the waiter. The runtime's own busy-wait guard catches only a `sleep N && <poll>`
# chain, so the loop form passes untouched. Measured 2026-11-12T11Z -> 2026-11-13T11Z over the
# 65 scheduled Engineer runs (subagents included): 72 foreground loops that slept while polling,
# blocking 12,385 s (3.4 h) of run wall-clock; 27 of them hit the Bash timeout and were moved to
# the background anyway. The same shape ran at about one per run in October, so the prose alone
# has not changed it.
#
# WHAT IT DENIES
# A Bash call that is not `run_in_background` and holds a loop — `until …`, `while …`, or a
# `for` over a counted range (`$(seq …)`, `{1..N}`) — whose own condition or body runs BOTH a
# `sleep <n>` of 5 s or more and a remote read (`gh`, `kubectl`, `flux`, `talosctl`, `curl`,
# `git ls-remote`, `git fetch`). The loop is found by command position, from its keyword to its
# matching `done`, and heredoc bodies are dropped first, so a script being WRITTEN to a file is
# not judged. Everything else exits 0: a loop that waits on a local process, a short sampling
# loop (sleep under 5 s), a `for` over a list of repositories, a settle `sleep` outside any
# loop, and every backgrounded call.
#
# CODEX has no entry: a Codex hook needs the operator's trust approval (see
# surveyor-hook-dispatch.sh), so that lane keeps the prose rule only.
#
# FAIL DIRECTION, STATED
# This is a wall-clock guard, not a safety control. Missing, empty or unparseable input exits
# 0 so a malformed event never stops a run. A denial exits 2 with the reason on stderr, which
# the runtime shows to the agent.

set -euo pipefail

input=$(cat 2>/dev/null || true)
[ -n "${input}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

fields=$(printf '%s' "${input}" | jq -r '
  if (.tool_name // "") != "Bash" then "skip"
  elif (.tool_input.run_in_background // false) == true then "skip"
  else "check\n" + (.tool_input.command // "") end' 2>/dev/null || true)
[ "${fields%%$'\n'*}" = check ] || exit 0
cmd=${fields#*$'\n'}

verdict=$(printf '%s\n' "${cmd}" | awk '
  # Drop heredoc bodies: a script written to a file is not executed by this call.
  hd != "" { if ($0 == hd || $0 ~ "^\t*" hd "$") hd = ""; next }
  {
    line = $0
    if (match(line, /(^|[^<])<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
      tag = substr(line, RSTART, RLENGTH); sub(/^[^<]?<<-?[[:space:]]*/, "", tag); gsub(/["\047]/, "", tag)
      hd = tag
    }
    text = text " ; " line
  }
  END {
    gsub(/&&|\|\||[;|(){}`]/, " ; ", text)
    n = split(text, t, /[[:space:]]+/)
    found = 0; cmdpos = 1
    for (i = 1; i <= n && !found; i++) {
      w = t[i]
      if (w == "") continue
      if (cmdpos && (w == "until" || w == "while" || (w == "for" && counted(i)))) {
        depth = 0; s = 0; r = 0; cp = 1
        for (j = i + 1; j <= n; j++) {
          x = t[j]
          if (x == "") continue
          if (cp && x == "do") depth++
          else if (cp && x == "done") { depth--; if (depth <= 0) break }
          if (cp && x == "sleep" && t[j + 1] ~ /^[0-9]/ && t[j + 1] + 0 >= 5) s = 1
          if (cp && (x == "gh" || x == "kubectl" || x == "flux" || x == "talosctl" || x == "curl")) r = 1
          if (cp && x == "git") {
            k = j + 1; if (t[k] == "-C") k += 2
            if (t[k] == "ls-remote" || t[k] == "fetch") r = 1
          }
          cp = (x == ";" || (cp && (x == "do" || x == "then" || x == "else" || x == "if" || x == "elif" || x == "while" || x == "until" || x == "!" || x == "[" || x == "[[")) || x ~ /=["\047]?\$$/ || x ~ /^["\047]?\$$/ )
        }
        if (s && r) found = 1
      }
      cmdpos = (w == ";" || (cmdpos && (w == "do" || w == "then" || w == "else" || w == "if" || w == "elif" || w == "!")) || w ~ /=["\047]?\$$/ || w ~ /^["\047]?\$$/)
    }
    print (found ? "deny" : "allow")
  }
  function counted(i,   j) {
    for (j = i + 1; j <= n && t[j] != "do"; j++)
      if (t[j] == "seq" || t[j] ~ /^[0-9]+\.\.[0-9]+$/) return 1
    return 0
  }
' 2>/dev/null || echo allow)

if [ "${verdict}" = deny ]; then
  cat >&2 <<'EOF'
deny: foreground remote poll loop. A loop that sleeps while polling GitHub or a cluster blocks
the run until it times out (.claude/guides/tool-call-discipline.md, "NEVER foreground-block on a
remote wait"). Arm ONE watcher instead and go do other work: the Monitor tool with this
until-loop, or the same call with run_in_background. In a delegated run, make one bounded
read of the condition, or stop and report the state to your parent.
EOF
  exit 2
fi
exit 0
