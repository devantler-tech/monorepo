#!/usr/bin/env bash
# test-inputs: .claude/guides/** .claude/scripts/zsh-equals-word-contract.test.sh
# test-inputs: .github/workflows/ci.yaml
#
# Guards the tool-call-discipline rule that a Bash call never starts an unquoted word with `=`
# (monorepo#5075).
#
# Why: the Claude lane's Bash tool runs zsh, where a word beginning with `=` is replaced by the
# path of the command it names. `echo ===` therefore looks for a command `==`, prints
# `== not found`, exits 1 and skips every later command in the call. 58 agent calls in about 45
# sessions failed this way in the 7 days to 2026-11-15, almost all on a separator between reads.
#
# Checked properties:
#   1. the rule sits in the guide's Latency discipline section, with the failing example and the
#      two safe forms it prescribes;
#   2. when zsh is installed, each prescribed safe form keeps the rest of the call running, and the
#      failing example really stops it (the ablation: the hazard the rule describes is real here).
# The guide text is always checked. The zsh leg runs wherever zsh exists (the agent host, macOS
# runners); a host without zsh says so by name rather than reporting that leg as passed.
#
# Exit codes: 0 every check that could run held · 1 a check failed

# shellcheck disable=SC2016 # the backticks and `=` are literal guide text, not expansions
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guide="${GUIDE_FILE:-${repo_root}/.claude/guides/tool-call-discipline.md}"

fail() {
  echo "zsh equals-word contract: FAIL — $*" >&2
  exit 1
}

[ -r "${guide}" ] || fail "cannot read ${guide}"

# 1. The rule lives in the Latency discipline section (read it from its heading to the next one).
section="$(awk '
  /^## Latency discipline/ { inside = 1; next }
  inside && /^## /         { exit }
  inside                   { print }
' "${guide}")"
[ -n "${section}" ] || fail "no '## Latency discipline' section in ${guide}"

grep -qF 'Never start an unquoted word with `=`' <<<"${section}" ||
  fail "the Latency discipline section no longer states the unquoted-'=' rule"
grep -qF 'echo ===' <<<"${section}" || fail "the rule no longer names the failing example 'echo ==='"
grep -qF '== not found' <<<"${section}" || fail "the rule no longer quotes zsh's '== not found' error"
grep -qF "printf '%s\\n' '==='" <<<"${section}" || fail "the rule no longer prescribes printf '%s\\n' '==='"
grep -qF 'echo ---' <<<"${section}" || fail "the rule no longer prescribes 'echo ---'"

# 2. Behaviour under zsh: a safe separator keeps the call running; the bare one stops it.
if ! command -v zsh >/dev/null 2>&1; then
  echo "zsh equals-word contract: OK (guide text checked; zsh is not installed here, so the behaviour leg did not run)"
  exit 0
fi

run_zsh() { # <separator command> — prints what the three-part call printed; status is zsh's
  zsh -f -c "echo before; $1; echo after" 2>&1
}

for safe in "printf '%s\\n' '==='" 'echo ---'; do
  out="$(run_zsh "${safe}")" || fail "zsh exited non-zero for the prescribed separator ${safe}: ${out}"
  grep -qx 'after' <<<"${out}" || fail "the prescribed separator ${safe} did not let the call finish: ${out}"
done

# Ablation: the failing example must stop the call, or the rule guards nothing on this zsh.
if out="$(run_zsh 'echo ===')"; then
  fail "zsh ran 'echo ===' successfully (${out}); the hazard the rule describes did not reproduce"
fi
grep -qF '== not found' <<<"${out}" || fail "'echo ===' failed for another reason: ${out}"
if grep -qx 'after' <<<"${out}"; then
  fail "'echo ===' failed but the call still ran its next command: ${out}"
fi

echo "zsh equals-word contract: OK (guide text and zsh behaviour checked)"
