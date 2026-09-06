#!/usr/bin/env bash
# Consumer-only routing contract: missing Codex enforcement chooses useful
# inline work, never an unguarded surveyor or a permanently blocked survey.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
file="${1:-${root}/AGENTS.md}"
fail() { printf 'Codex survey dispatch: FAIL — %s\n' "$1" >&2; exit 1; }
section="$(awk '
  /^<!-- codex-survey-dispatch:begin -->$/ { reading=1; starts++; next }
  /^<!-- codex-survey-dispatch:end -->$/ { reading=0; ends++; next }
  reading { print }
  END { if (starts != 1 || ends != 1 || reading) exit 1 }
' "${file}")" || fail 'missing or ambiguous consumer dispatch boundary'
section="$(printf '%s' "${section}" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
required=(
  'For Codex, run the survey inline in the engineer by default'
  'Missing agent-scoped enforcement is an unavailable read-only subagent capability'
  'even when the runtime can spawn agents'
  'Do not dispatch either surveyor type or a renamed substitute'
  'use the same reviewed pinned survey procedure and local compatibility overlay'
  'Scope queries to the Portfolio map'
  'no new maintainer permission is needed'
  'not a claim of native delegated enforcement'
  'runtime-authenticated discriminator at the actual pre-execution boundary'
  'ordinary reads succeed, writes are denied for every exposed surveyor type'
  "the engineer's own write path remains usable"
  'session_id is shared with the parent'
)
for phrase in "${required[@]}"; do
  [[ "${section}" == *"${phrase}"* ]] || fail "missing requirement: ${phrase}"
done
# The scoped checker must reject each lost clause, even if the same words are
# present elsewhere in the document. Exercise the actual checker on mutations.
if [[ $# -eq 0 ]]; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "${scratch}"' EXIT
  for phrase in "${required[@]}"; do
    shortened="${section/"${phrase}"/REMOVED}"
    printf '<!-- codex-survey-dispatch:begin -->\n%s\n<!-- codex-survey-dispatch:end -->\n%s\n' \
      "${shortened}" "${phrase}" >"${scratch}/AGENTS.md"
    if bash "${BASH_SOURCE[0]}" "${scratch}/AGENTS.md" >/dev/null 2>&1; then
      fail "out-of-section text hid a missing requirement: ${phrase}"
    fi
  done
fi
printf 'PASS: Codex missing-enforcement dispatch stays inline; native proof is separate\n'
