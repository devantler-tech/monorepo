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
# not judged.
#
# It also denies, with its own reason, an `until`/`while` loop that sleeps 5 s or more and whose
# condition only compares the clock (`until [ "$(date -u +%H%M)" -ge 1130 ]`; a counter beside it
# is allowed). Runs adapted to the remote-loop denial by waiting for a chosen minute, reading
# GitHub once, and waiting again: 70 such loops blocked 11,860 s in the 7 days to 2026-11-14,
# 19 of them in one run right after the runtime refused its `sleep` (monorepo#5043).
#
# Everything else exits 0: a loop that waits on a local process (the clock may be its deadline),
# a short sampling loop (sleep under 5 s), a `for` over a list of repositories, a settle `sleep`
# outside any loop, and every backgrounded call.
#
# MONITOR (monorepo#5028). A `Monitor` call IS the watcher this guard asks for. A hook whose
# matcher is only `Bash` also receives Monitor calls, as tool_name "Bash" with just `command`
# and `description`, which is indistinguishable from a foreground Bash call (payload captured
# on the live runtime, 2026-11-13). Under a matcher that names `Monitor` the same call arrives
# once, as tool_name "Monitor". So settings.json registers this guard under `Bash|Monitor`,
# never `Bash` alone, and the first check below admits every tool that is not Bash.
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
  # Drop heredoc bodies: a script written to a file is not executed by this call. A heredoc
  # fed to a shell interpreter IS executed, so its body is kept (hdx).
  hd != "" {
    if ($0 == hd || $0 ~ "^\t*" hd "$") { hd = ""; next }
    if (hdx) text = text " ; " $0
    next
  }
  {
    line = $0
    if (match(line, /(^|[^<])<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
      pre = substr(line, 1, RSTART)
      tag = substr(line, RSTART, RLENGTH); sub(/^[^<]?<<-?[[:space:]]*/, "", tag); gsub(/["\047]/, "", tag)
      hd = tag
      hdx = (pre ~ /(^|[;&|[:space:]])(bash|sh|zsh|dash|ksh)([[:space:]]+-[A-Za-z]+)*[[:space:]]*.?$/)
    }
    text = text " ; " line
  }
  END {
    text = unquote(text)
    gsub(/&&|\|\||[;|(){}`]/, " ; ", text)
    n = split(text, t, /[[:space:]]+/)
    found = 0; cmdpos = 1
    for (i = 1; i <= n && !found; i++) {
      w = t[i]
      if (w == "") continue
      if (cmdpos && (w == "until" || w == "while" || (w == "for" && counted(i)))) {
        depth = 0; s = 0; r = 0; cp = 1; c = 0; o = 0; prev = ""
        for (j = i + 1; j <= n; j++) {
          x = t[j]
          if (x == "") continue
          if (cp && x == "do") depth++
          else if (cp && x == "done") { depth--; if (depth <= 0) break }
          # The loop condition (before its first `do`) is a clock wait when `date` is its only
          # command: `[`/`test` operands, `$(`/`$var` words and comparison operators are not
          # commands, and a file test (`[ -f x ]`) or any other command makes it a local wait.
          if (depth == 0 && cp && x != ";") {
            if (x == "date") c = 1
            else if (x != "[" && x != "[[" && x != "test" && x != "!" && x != "]" && x != "]]" && x !~ /^\$/ && x !~ /^-/ && x !~ /^[<>=!]+$/) o = 1
          }
          if (depth == 0 && x ~ /^-[A-Za-z]$/ && (prev == "[" || prev == "[[" || prev == "test" || prev == "!")) o = 1
          prev = x
          if (cp && x == "sleep" && seconds(t[j + 1]) >= 5) s = 1
          if (cp && (x == "gh" || x == "kubectl" || x == "flux" || x == "talosctl" || x == "curl")) r = 1
          if (cp && x == "git") {
            k = j + 1; if (t[k] == "-C") k += 2
            if (t[k] == "ls-remote" || t[k] == "fetch") r = 1
          }
          cp = (x == ";" || (cp && (x == "do" || x == "then" || x == "else" || x == "if" || x == "elif" || x == "while" || x == "until" || x == "!" || x == "[" || x == "[[" || x ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) || x ~ /=["\047]?\$$/ || x ~ /^["\047]?\$$/ )
        }
        if (s && r) found = 1
        if (s && c && !o && w != "for") clock = 1
      }
      cmdpos = (w == ";" || (cmdpos && (w == "do" || w == "then" || w == "else" || w == "if" || w == "elif" || w == "!" || w ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) || w ~ /=["\047]?\$$/ || w ~ /^["\047]?\$$/)
    }
    print (found ? "deny" : clock ? "deny-clock" : "allow")
  }
  # Quoted text is an argument, never a command: drop single-quoted text, and keep only the
  # command substitutions ($(...) and backticks) inside double quotes, which the shell runs.
  # The one exception is the script argument of `<shell> -c`, which IS run: it is kept whole.
  function unquote(s,   out, i, c, q, d, b, x, rest, e) {
    out = ""; q = ""; d = 0; b = 0; x = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (x) { if (c == q) { q = ""; x = 0; out = out " ; " } else out = out c; continue }
      if (q == "\047") { if (c == "\047") q = ""; continue }
      if (q == "\"") {
        if (c == "\\") { i++; continue }
        if (d > 0) {
          out = out c
          if (c == "(") d++
          else if (c == ")") d--
          continue
        }
        if (b) { out = out c; if (c == "`") b = 0; continue }
        if (c == "$" && substr(s, i + 1, 1) == "(") { out = out "$("; i++; d = 1; continue }
        if (c == "`") { out = out c; b = 1; continue }
        if (c == "\"") { q = ""; continue }
        continue
      }
      if (c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
      if (c == "\047" || c == "\"") {
        # A quoted number ("30", "30s", or single-quoted) is still an operand such as a sleep duration:
        # keep it, but only when the quoted literal is the WHOLE word. A fragment glued to another
        # (`"$delay""30"`) is part of a value this scanner cannot evaluate, so it is not a number.
        rest = substr(s, i + 1); e = index(rest, c)
        if (e > 1 && substr(rest, 1, e - 1) ~ /^[0-9][0-9.]*[smhd]?$/ &&
            (i == 1 || substr(s, i - 1, 1) ~ /[[:space:];&|(]/) &&
            (i + e + 1 > length(s) || substr(s, i + e + 1, 1) ~ /[[:space:];&|)<>]/)) {
          out = out substr(rest, 1, e - 1); i += e; continue
        }
        q = c
        if (out ~ /(^|[^A-Za-z0-9_])(bash|sh|zsh|dash|ksh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[[:space:]]+$/) { x = 1; out = out " ; " }
        continue
      }
      out = out c
    }
    return out
  }
  # A sleep operand in seconds, honouring the s/m/h/d suffix `sleep` accepts (`1m` is 60, not 1).
  # Anything else is a value this scanner cannot evaluate, so it counts as zero.
  function seconds(w,   u) {
    sub(/[<>&].*$/, "", w)   # `sleep 30>/dev/null`: a redirection is not part of the operand
    if (w !~ /^[0-9][0-9.]*[smhd]?$/) return 0
    u = substr(w, length(w))
    return (w + 0) * (u == "m" ? 60 : u == "h" ? 3600 : u == "d" ? 86400 : 1)
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
if [ "${verdict}" = deny-clock ]; then
  cat >&2 <<'EOF'
deny: foreground clock-wait loop. A loop that only sleeps until a clock time blocks the run just
as a poll loop does (.claude/guides/tool-call-discipline.md, "NEVER foreground-block on a remote
wait"), and waiting for a minute and then reading GitHub once is the same wait cut into pieces.
Do other work and arm ONE watcher for the condition itself: the Monitor tool, or the same call
with run_in_background. In a delegated run with nothing else to do, stop and report the state
to your parent.
EOF
  exit 2
fi
exit 0
