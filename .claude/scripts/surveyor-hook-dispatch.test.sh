#!/usr/bin/env bash
# Behaviour and wiring tests for .claude/scripts/surveyor-hook-dispatch.sh (monorepo#3057).
#
# The dispatch is the deployment-level seam that reaches the PLUGIN surveyor agent type,
# which ignores frontmatter hooks. Its whole job is to forward exactly the two surveyor
# agent types to the real forge hook and to touch nothing else — so its interesting
# failures are (a) forwarding an engineer's call into the guard, which would deny the
# engineer's own write lane, and (b) NOT forwarding a surveyor's call, which is the gap
# this closes. Both are asserted positively below, against a stub target that records
# whether it ran and what it received; the real forge hook is exercised by the delivery
# contract test, not here.
#
# The behaviour half runs a COPY of the dispatch beside a stub `portfolio-surveyor-forge-hook.sh`
# in a temp directory: the dispatch resolves its target from its own location, so placing
# the copy there is the seam. The wiring half asserts settings.json actually attaches it —
# a dispatch no hook calls protects nothing.

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly root_dir
readonly dispatch="${root_dir}/.claude/scripts/surveyor-hook-dispatch.sh"
readonly settings="${root_dir}/.claude/settings.json"

fail=0
fail_case() {
  echo "::error::$1"
  fail=1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

cp "${dispatch}" "${tmp}/surveyor-hook-dispatch.sh"
chmod +x "${tmp}/surveyor-hook-dispatch.sh"
cat > "${tmp}/portfolio-surveyor-forge-hook.sh" <<'EOF'
#!/usr/bin/env bash
# Stub target: record that it ran and echo stdin back so forwarding is verifiable.
printf 'ran\n' >> "${STUB_LOG}"
cat > "${STUB_LOG}.stdin"
exit 7
EOF
chmod +x "${tmp}/portfolio-surveyor-forge-hook.sh"

# run <name> <stdin> ; sets `rc`, and `ran` (0/1) from the stub log.
run() {
  local name="$1" input="$2"
  export STUB_LOG="${tmp}/${name}.log"
  rm -f "${STUB_LOG}" "${STUB_LOG}.stdin"
  set +e
  if [ "${input}" = "__EMPTY__" ]; then
    "${tmp}/surveyor-hook-dispatch.sh" </dev/null >"${tmp}/${name}.out" 2>"${tmp}/${name}.err"
  else
    printf '%s' "${input}" | "${tmp}/surveyor-hook-dispatch.sh" >"${tmp}/${name}.out" 2>"${tmp}/${name}.err"
  fi
  rc=$?
  set -e
  if [ -f "${STUB_LOG}" ]; then ran=1; else ran=0; fi
}

write_probe='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 1 --repo devantler-tech/monorepo"}}'

# --- Forwarded: both surveyor agent types reach the target, with stdin intact -------------
for agent in portfolio-surveyor agentic-engineering:portfolio-surveyor; do
  payload="$(jq -cn --arg a "${agent}" --argjson p "${write_probe}" '$p + {agent_type: $a}')"
  run "fwd-${agent//:/_}" "${payload}"
  [ "${ran}" -eq 1 ] || fail_case "${agent}: the call was NOT forwarded to the forge hook"
  [ "${rc}" -eq 7 ] || fail_case "${agent}: the target's exit status (7) was not propagated, got ${rc}"
  [ "$(cat "${STUB_LOG}.stdin" 2>/dev/null)" = "${payload}" ] ||
    fail_case "${agent}: stdin did not reach the target verbatim"
done

# --- Not forwarded: the engineer and every other agent are untouched ----------------------
run "top-level" "${write_probe}"
[ "${ran}" -eq 0 ] || fail_case "a top-level (no agent_type) call was forwarded into the guard"
[ "${rc}" -eq 0 ] || fail_case "a top-level call did not exit 0, got ${rc}"
[ ! -s "${tmp}/top-level.out" ] || fail_case "a top-level call produced stdout (would be read as a hook decision)"

payload="$(jq -cn --argjson p "${write_probe}" '$p + {agent_type: "Explore"}')"
run "explore" "${payload}"
[ "${ran}" -eq 0 ] || fail_case "an Explore agent's call was forwarded into the guard"
[ "${rc}" -eq 0 ] || fail_case "an Explore agent's call did not exit 0, got ${rc}"

# A NAME that merely contains the surveyor's — exact match only, as the trust gate requires.
payload="$(jq -cn --argjson p "${write_probe}" '$p + {agent_type: "portfolio-surveyor-evil"}')"
run "lookalike" "${payload}"
[ "${ran}" -eq 0 ] || fail_case "a lookalike agent_type was forwarded (substring match)"

# --- Malformed input fails OPEN for the caller, never into the guard ----------------------
run "empty" "__EMPTY__"
if [ "${ran}" -ne 0 ] || [ "${rc}" -ne 0 ]; then
  fail_case "empty stdin did not exit 0 without forwarding (ran=${ran} rc=${rc})"
fi
run "garbage" "not json at all {"
if [ "${ran}" -ne 0 ] || [ "${rc}" -ne 0 ]; then
  fail_case "unparseable stdin did not exit 0 without forwarding (ran=${ran} rc=${rc})"
fi

# --- A missing or non-executable target for a SURVEYOR fails CLOSED -----------------------
payload="$(jq -cn --argjson p "${write_probe}" '$p + {agent_type: "portfolio-surveyor"}')"
chmod -x "${tmp}/portfolio-surveyor-forge-hook.sh"
run "no-target" "${payload}"
chmod +x "${tmp}/portfolio-surveyor-forge-hook.sh"
[ "${rc}" -eq 2 ] || fail_case "a surveyor call with a non-executable target did not exit 2, got ${rc}"
[ "${ran}" -eq 0 ] || fail_case "a non-executable target somehow ran"

# --- Ablation: the forwarding is what the surveyor cases prove ----------------------------
# Neutralise the case arm (keep the script otherwise intact) and assert the surveyor case
# now fails — so the assertions above cannot pass on a dispatch that forwards nothing.
sed 's/^  portfolio-surveyor|agentic-engineering:portfolio-surveyor) ;;$/  never-matches) ;;/' \
  "${dispatch}" > "${tmp}/surveyor-hook-dispatch.sh"
grep -q 'never-matches' "${tmp}/surveyor-hook-dispatch.sh" || fail_case "ablation did not apply; the case arm was not found"
run "ablated" "${payload}"
[ "${ran}" -eq 0 ] || fail_case "ablation control: a dispatch with no surveyor arm still forwarded (test is vacuous)"

# --- Wiring: settings.json attaches exactly this dispatch as a Bash PreToolUse hook -------
# shellcheck disable=SC2016
expected='"$CLAUDE_PROJECT_DIR"/.claude/scripts/surveyor-hook-dispatch.sh'
EXPECTED_DISPATCH="${expected}" jq -e '
  (.hooks.PreToolUse | type == "array")
  and ([.hooks.PreToolUse[] | select(.matcher == "Bash")
        | .hooks[] | select(.type == "command" and .command == env.EXPECTED_DISPATCH)] | length == 1)
' "${settings}" >/dev/null ||
  fail_case "settings.json does not attach surveyor-hook-dispatch.sh as a Bash PreToolUse command hook"

# A project-wide hook that forwarded EVERYTHING would deny the engineer's write lane; the
# only project-level Bash hook may be this dispatch, which scopes by agent_type.
jq -e '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]] | length == 1' "${settings}" >/dev/null ||
  fail_case "settings.json carries more than one project-level Bash PreToolUse hook"

if [ ! -f "${dispatch}" ] || [ ! -x "${dispatch}" ] || [ -L "${dispatch}" ]; then
  fail_case "surveyor-hook-dispatch.sh is not a regular executable"
fi

if [ "${fail}" -ne 0 ]; then
  exit 1
fi
echo "surveyor-hook-dispatch: surveyor types forwarded verbatim, everything else untouched, wired in settings.json."
