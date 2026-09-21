#!/usr/bin/env bash
# Verify that every contract test has a command that RUNS it in CI, not merely wiring (monorepo#2586).
#
# A contract test can assert its own paths-filter entry, job block and aggregate-status entries, but it
# cannot assert that it ran: delete the `run:` step that invokes it and the job still succeeds as a
# checkout-only job, the aggregate accepts it, and the script never runs to complain. This check sits
# outside every test job and asks the question from the other side: for each `*.test.sh` in the
# scripts directory, is there a command that runs it?
#
# A test counts as invoked when a workflow `run:` step runs it in COMMAND position — `bash <path>`,
# `sh <path>`, `source <path>`, `. <path>` or `<path>` itself — or when a test that is itself invoked
# does the same (the python-ban-guard suite runs its parts from one parent). A path that is only an
# argument to another command (`shellcheck <path>`), a paths-filter entry or a comment does not count:
# those are exactly what survives when the `bash` line is deleted.
#
# The check's own script must be invoked by the workflow too, and its test is one of the enumerated
# `*.test.sh` files, so neither can exempt itself.
#
# It reads commands, not control flow. A run command inside a shell function that is never called,
# in a branch that is never taken, or after an `exit` still counts. Reaching any of those means
# editing the invoking line itself, which is a visible, reviewed change; what this check exists to
# catch is the invoking line disappearing while everything around it keeps passing.
#
# Usage: contract-test-invocation.sh [workflow] [scripts-dir]
#        (defaults: .github/workflows/ci.yaml .claude/scripts; paths as the workflow names them)
# Exit codes: 0 every test invoked · 1 at least one is not (each printed) · 2 usage or unreadable input.
set -euo pipefail

workflow="${1:-.github/workflows/ci.yaml}"
scripts_dir="${2:-.claude/scripts}"
[[ $# -le 2 ]] || { echo "usage: contract-test-invocation.sh [workflow] [scripts-dir]" >&2; exit 2; }
[[ -r "$workflow" ]] || { echo "contract-test-invocation: cannot read $workflow" >&2; exit 2; }
[[ -d "$scripts_dir" ]] || { echo "contract-test-invocation: no directory $scripts_dir" >&2; exit 2; }
command -v yq >/dev/null || { echo "contract-test-invocation: yq is required" >&2; exit 2; }
scripts_dir="${scripts_dir%/}"
self="contract-test-invocation.sh"

tmp="$(mktemp -d)"
# Reaching the end is the only way a zero status leaves this script: bash 3.2 reports $? as 0 to an
# EXIT trap after a `set -u` abort, which would otherwise read as a clean pass.
finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [[ "$finished" != 1 && $rc -eq 0 ]]; then
    echo "contract-test-invocation: aborted before finishing; reporting failure rather than a clean pass" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

# targets <file> — every word run in command position, one per line. Continuation lines are joined
# first, then each line is split into commands at ; & && || | |& outside quotes, and each command's
# leading keywords, negation and variable assignments are skipped. Heredoc bodies are data, not
# commands, so they are skipped up to their closing delimiter.
#
# Interpreter options are an ALLOW-LIST, not a list of exceptions: `bash`/`sh` count as running the
# next word only when every option before it is a cluster of -e -u -v -x, or -o/+o with its operand.
# Anything else — `-n` (parse only), `-s` (read stdin), `-c` (run a string), an unrecognised option —
# does not count, so a spelling this parser does not understand fails closed as NOT-INVOKED rather
# than being read as coverage.
targets() {
  awk '
    BEGIN { SEP = sprintf("%c", 1); STEP = "#contract-test-invocation:step-boundary#" }
    # Each workflow run step is its own shell: a trailing continuation or an unclosed heredoc in one
    # step never reaches the next, so the boundary between steps ends the pending command and resets
    # the heredoc queue.
    $0 == STEP { if (pending != "") emit(pending); pending = ""; HQH = HQN; next }
    # Pending heredocs form a queue: bodies follow in the order their operators appeared, and each
    # body ends only at its own delimiter, so a later delimiter inside an earlier body is still data.
    HQH < HQN { t = $0; if (HQDASH[HQH]) sub(/^\t+/, "", t); if (t == HQ[HQH]) HQH++; next }
    { line = (pending == "" ? $0 : pending " " $0); pending = "" }
    line ~ /\\$/ { sub(/\\$/, "", line); pending = line; next }
    { emit(line) }
    END { if (pending != "") emit(pending) }
    # Rewrites ; && || | to a separator byte and drops a # comment, but only outside quotes: a
    # separator inside a quoted argument is text, not a command boundary. A << or <<- outside quotes
    # (never the <<< here-string) records the heredoc delimiter, so the body lines that follow are skipped.
    # The whole delimiter word after quote removal, as the shell reads it: it ends at the first
    # unquoted blank or operator character, so END-OF-DATA and 123 are delimiters in full.
    function delimiter(s,   w, i, n, c, q) {
      w = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\047" || c == "\"") {
          q = c
          for (i++; i <= n && substr(s, i, 1) != q; i++) w = w substr(s, i, 1)
          continue
        }
        if (c == "\\") { i++; w = w substr(s, i, 1); continue }
        if (c ~ /[ \t;&|<>()]/) break
        w = w c
      }
      return w
    }
    function commands(l,   out, i, c, q, len, rest, dash, word) {
      out = ""; q = ""; len = length(l)
      for (i = 1; i <= len; i++) {
        c = substr(l, i, 1)
        if (q == "") {
          if (c == "\\") { out = out c substr(l, i + 1, 1); i++; continue }
          if (c == "\047" || c == "\"") { q = c; out = out c; continue }
          # A # begins a comment after a blank or a control operator: `true;# bash x.test.sh` runs nothing.
          if (c == "#" && (i == 1 || substr(l, i - 1, 1) ~ /[ \t;&|()]/)) break
          if (c == "<" && substr(l, i + 1, 1) == "<" && substr(l, i + 2, 1) != "<" && (i == 1 || substr(l, i - 1, 1) != "<")) {
            rest = substr(l, i + 2); dash = 0
            if (substr(rest, 1, 1) == "-") { dash = 1; rest = substr(rest, 2) }
            sub(/^[ \t]+/, "", rest)
            word = delimiter(rest)
            if (word != "") { HQ[HQN] = word; HQDASH[HQN] = dash; HQN++ }
          }
          if (c == ";") { out = out SEP; continue }
          if (c == "&" && substr(l, i + 1, 1) == "&") { out = out SEP; i++; continue }
          # A lone & ends a background command; &> and >& / <& are redirections, not boundaries.
          if (c == "&" && substr(l, i + 1, 1) != ">" && (i == 1 || substr(l, i - 1, 1) !~ /[<>]/)) { out = out SEP; continue }
          if (c == "|") { if (substr(l, i + 1, 1) ~ /[|&]/) i++; out = out SEP; continue }
        } else if (q == "\"" && c == "\\") { out = out c substr(l, i + 1, 1); i++; continue }
        else if (c == q) q = ""
        out = out c
      }
      return out
    }
    function emit(l,   n, cmds, i, w, nw, j, t) {
      n = split(commands(l), cmds, SEP)
      for (i = 1; i <= n; i++) {
        nw = split(cmds[i], w, /[ \t]+/)
        j = 1
        while (j <= nw && (w[j] == "" || w[j] ~ /^(if|then|do|else|elif|while|until|time|!|\(|\{)$/ || w[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) j++
        if (j > nw) continue
        if (w[j] ~ /^(bash|sh|source|\.)$/) {
          j++
          while (j <= nw) {
            if (w[j] ~ /^-[euvx]+$/) { j++; continue }
            if (w[j] ~ /^[-+]o$/) { j += 2; continue }
            break
          }
          if (j <= nw && w[j] ~ /^[-+]/) continue
        }
        if (j > nw) continue
        t = w[j]; gsub(/["\047]/, "", t); sub(/^\.\//, "", t)
        print t
      }
    }' "$1"
}

ls "$scripts_dir" >"$tmp/listing" 2>/dev/null || { echo "contract-test-invocation: cannot list $scripts_dir" >&2; exit 2; }
grep -E '\.test\.sh$' "$tmp/listing" | LC_ALL=C sort >"$tmp/tests" || true
[[ -s "$tmp/tests" ]] || { echo "contract-test-invocation: no *.test.sh under $scripts_dir — refusing an empty pass" >&2; exit 2; }

yq -r '.jobs | keys | .[]' "$workflow" >"$tmp/jobs" 2>"$tmp/err" ||
  { echo "contract-test-invocation: cannot list jobs in $workflow: $(cat "$tmp/err")" >&2; exit 2; }
[[ -s "$tmp/jobs" ]] || { echo "contract-test-invocation: $workflow declares no jobs" >&2; exit 2; }

: >"$tmp/direct"
while IFS= read -r job; do
  J="$job" yq -r '.jobs[strenv(J)].steps[]? | (.run // "") + "\n#contract-test-invocation:step-boundary#"' "$workflow" >"$tmp/run" 2>"$tmp/err" ||
    { echo "contract-test-invocation: cannot read the run steps of job $job: $(cat "$tmp/err")" >&2; exit 2; }
  targets "$tmp/run" | awk -v d="$scripts_dir/" 'index($0, d) == 1 { print substr($0, length(d) + 1) }' >>"$tmp/direct"
done <"$tmp/jobs"

# Transitive closure over tests that run other tests from their own directory. A target counts when it
# is written under the scripts directory, or under `$here` / `${here}` — the variable every test in this
# directory sets to its own location. Other variables are not resolved: `"$fixtures/child.test.sh"`
# could point anywhere, so it covers nothing. The remainder keeps its subdirectory, so
# `$here/fixtures/child.test.sh` never covers a top-level `child.test.sh` of the same name.
LC_ALL=C sort -u "$tmp/direct" >"$tmp/covered"
while :; do
  cp "$tmp/covered" "$tmp/before"
  while IFS= read -r t; do
    [[ -f "$scripts_dir/$t" ]] || continue
    targets "$scripts_dir/$t" | awk -v d="$scripts_dir/" '
      index($0, d) == 1 { print substr($0, length(d) + 1); next }
      /^\$(here|\{here\})\// { t = $0; sub(/^\$(here|\{here\})\//, "", t); print t }' >>"$tmp/covered"
  done <"$tmp/before"
  LC_ALL=C sort -u "$tmp/covered" -o "$tmp/covered"
  cmp -s "$tmp/before" "$tmp/covered" && break
done

fail=0
while IFS= read -r t; do
  grep -qxF -- "$t" "$tmp/covered" && continue
  # Name the jobs that still point at the script, so a deleted run step points at its job: a job whose
  # own text mentions it, or a job gated on a paths-filter key that lists it (a job whose only mention
  # was the deleted run step is still gated on its filter).
  mentions=""
  P="$scripts_dir/$t" yq -r '.jobs.changes.steps[]? | select(.with.filters) | .with.filters' "$workflow" 2>/dev/null |
    P="$scripts_dir/$t" yq -r 'to_entries[] | select([.value[]? | tostring | contains(strenv(P))] | any) | .key' \
      >"$tmp/keys" 2>/dev/null || : >"$tmp/keys"
  while IFS= read -r job; do
    [[ "$job" == changes ]] && continue
    hit=0
    J="$job" yq -o=json '.jobs[strenv(J)]' "$workflow" 2>/dev/null | grep -qF -- "$scripts_dir/$t" && hit=1
    if [[ "$hit" == 0 ]]; then
      cond="$(J="$job" yq -r '.jobs[strenv(J)].if // ""' "$workflow" 2>/dev/null || true)"
      while IFS= read -r key; do
        [[ -n "$key" && "$cond" == *"outputs.$key "* || -n "$key" && "$cond" == *"outputs.$key" ]] && hit=1
      done <"$tmp/keys"
    fi
    [[ "$hit" == 1 ]] && mentions="${mentions:+$mentions, }$job"
  done <"$tmp/jobs"
  if [[ -n "$mentions" ]]; then
    echo "NOT-INVOKED $t: job(s) $mentions are wired to it but no run step executes it"
  else
    echo "NOT-INVOKED $t: no workflow job or invoked test executes it"
  fi
  fail=1
done <"$tmp/tests"

if ! grep -qxF -- "$self" "$tmp/direct"; then
  echo "NOT-INVOKED $self: the workflow must run this check itself"
  fail=1
fi

finished=1
if [[ "$fail" != 0 ]]; then exit 1; fi
echo "contract-test-invocation: all $(wc -l <"$tmp/tests" | tr -d ' ') contract tests are executed by $workflow"
