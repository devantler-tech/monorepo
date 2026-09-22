#!/usr/bin/env bash
# coderabbit-summary-verdict.test.sh — RED/GREEN proof for coderabbit-summary-verdict.sh
# (monorepo#2653). Every negative case is paired with the ablation that isolates the conjunct
# deciding it, so a pass cannot come from the wrong check.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
tool="${here}/coderabbit-summary-verdict.sh"
fixtures="${here}/fixtures"
green_fixture="${fixtures}/coderabbit-summary-green-platform-4039.txt"
green_head="47702cc36a99d2a28b81793199cbae1c68819a60"
limited_fixture="${fixtures}/coderabbit-summary-rate-limited-platform-4041.txt"
limited_head="e1b1f5e8dbb367c0e6378fa040c1512921acb00c"
walkthrough_fixture="${fixtures}/coderabbit-summary-walkthrough-only-monorepo-2714.txt"
other_head="0123456789abcdef0123456789abcdef01234567"

tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -e abort inside an EXIT trap as exit 0, so require completion.
on_exit() {
  local status=$?
  rm -rf "${tmp}"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then exit 1; fi
}
trap on_exit EXIT
failures=0
checks=0

expect() { # expect <name> <want-rc> <want-line> <head> <input-file>
  local name="$1" want_rc="$2" want="$3" head="$4" input="$5" got rc
  checks=$((checks + 1))
  set +e
  got="$(bash "${tool}" --head "${head}" --input "${input}" 2>"${tmp}/stderr")"
  rc=$?
  set -e
  if [ "${rc}" != "${want_rc}" ] || [ "${got}" != "${want}" ]; then
    echo "FAIL ${name}: want rc=${want_rc} '${want}', got rc=${rc} '${got}' ($(cat "${tmp}/stderr"))" >&2
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

for f in "${green_fixture}" "${limited_fixture}" "${walkthrough_fixture}"; do
  [ -s "${f}" ] || { echo "FAIL fixture missing or empty: ${f}" >&2; exit 1; }
done

# RED: the predicate this replaces — summary marker plus "names the head" — ACCEPTS the
# rate-limit shell, because the shell carries a range header naming the full current head.
checks=$((checks + 1))
if grep -Fq 'summarize by coderabbit.ai' "${limited_fixture}" && grep -Fq "${limited_head}" "${limited_fixture}"; then
  echo "ok   RED: old names-the-head predicate would accept the rate-limit shell"
else
  echo "FAIL RED precondition: the rate-limit fixture no longer names its head" >&2
  failures=$((failures + 1))
fi

# GREEN on the real finding-free summary, at its own head only.
expect "real green summary at its head" 0 "GREEN" "${green_head}" "${green_fixture}"
expect "real green summary at another head" 1 "NONE range-other-head" "${other_head}" "${green_fixture}"

# The rate-limit shell is rejected by the did-not-run marker.
expect "real rate-limit shell naming the head" 1 "NONE did-not-run" "${limited_head}" "${limited_fixture}"
# Ablation: the same marker injected into the real green summary is what flips it.
{ cat "${green_fixture}"; printf '\n> ## Review limit reached\n'; } >"${tmp}/green-plus-limit.txt"
expect "green + did-not-run marker" 1 "NONE did-not-run" "${green_head}" "${tmp}/green-plus-limit.txt"

# A walkthrough-only summary is not a verdict, even when the head sha appears in it.
expect "real walkthrough-only summary" 1 "NONE no-recent-review" "${green_head}" "${walkthrough_fixture}"
{ cat "${walkthrough_fixture}"; printf '\nCommits: %s\n' "${green_head}"; } >"${tmp}/walkthrough-names-head.txt"
expect "walkthrough that names the head" 1 "NONE no-recent-review" "${green_head}" "${tmp}/walkthrough-names-head.txt"

# Ablation: deleting ONLY the verdict line from the real green summary is what flips it.
grep -vF 'No actionable comments were generated in the recent review' "${green_fixture}" >"${tmp}/no-verdict.txt"
expect "green minus verdict line" 1 "NONE no-verdict" "${green_head}" "${tmp}/no-verdict.txt"

# Ablation: deleting ONLY the range header is what flips it.
grep -vF 'Reviewing files that changed' "${green_fixture}" >"${tmp}/no-range.txt"
expect "green minus range header" 1 "NONE no-range" "${green_head}" "${tmp}/no-range.txt"

# A range header naming the head OUTSIDE the recent_review block does not count.
awk -v h="${green_head}" '
  /Reviewing files that changed/ { next }
  { print }
  /<!-- walkthrough_start -->/ { print "Reviewing files that changed from the base of the PR and between " h " and " h "." }
' "${green_fixture}" >"${tmp}/range-outside.txt"
expect "range header only in walkthrough" 1 "NONE no-range" "${green_head}" "${tmp}/range-outside.txt"

# Findings in the recent review are reported, never read as green.
sed 's/No actionable comments were generated in the recent review. 🎉/**Actionable comments posted: 2**/' \
  "${green_fixture}" >"${tmp}/findings.txt"
expect "recent review with findings" 1 "FINDINGS 2" "${green_head}" "${tmp}/findings.txt"

# A body larger than a pipe buffer must be judged the same way. Piping it into an early-exiting
# `grep -q` under pipefail reports a match as a miss, which turned both of these into
# `not-a-summary`; for the did-not-run check that same miss would read a refusal as a green.
pad() { local i; for i in $(seq 1 4000); do printf 'padding line %s abcdefghijklmnopqrstuvwxyz0123456789\n' "${i}"; done; }
{ cat "${green_fixture}"; pad; } >"${tmp}/big-green.txt"
expect "large green summary" 0 "GREEN" "${green_head}" "${tmp}/big-green.txt"
{ cat "${green_fixture}"; printf '\n> ## Review limit reached\n'; pad; } >"${tmp}/big-limited.txt"
expect "large summary with a did-not-run marker" 1 "NONE did-not-run" "${green_head}" "${tmp}/big-limited.txt"

# Not a summary comment at all.
printf 'Reviewing files that changed from the base of the PR and between %s and %s.\n' "${green_head}" "${green_head}" >"${tmp}/plain.txt"
expect "non-summary body" 1 "NONE not-a-summary" "${green_head}" "${tmp}/plain.txt"

# Usage: an abbreviated head is refused rather than prefix-matched.
checks=$((checks + 1))
set +e
bash "${tool}" --head "${green_head:0:8}" --input "${green_fixture}" >/dev/null 2>&1
rc=$?
set -e
if [ "${rc}" = "2" ]; then echo "ok   abbreviated head refused"; else
  echo "FAIL abbreviated head: want rc=2, got ${rc}" >&2
  failures=$((failures + 1))
fi

# The contract names the requirement and the helper, so a reader of either finds the other.
for surface in "${root}/AGENTS.md" "${root}/.claude/agents/portfolio-surveyor.md"; do
  checks=$((checks + 1))
  if grep -Fq 'coderabbit-summary-verdict.sh' "${surface}" &&
    grep -Fq 'No actionable comments were generated in the recent review' "${surface}"; then
    echo "ok   contract: ${surface#"${root}"/} names the verdict line and the helper"
  else
    echo "FAIL contract: ${surface#"${root}"/} must name the verdict line and coderabbit-summary-verdict.sh" >&2
    failures=$((failures + 1))
  fi
done

completed=1
echo "coderabbit-summary-verdict: ${checks} checks, ${failures} failures"
[ "${failures}" -eq 0 ]
