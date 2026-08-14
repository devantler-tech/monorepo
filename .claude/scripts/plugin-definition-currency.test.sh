#!/usr/bin/env bash
#
# Guards `plugin-definition-currency.sh` and the contract rule it enforces.
#
# The defect it exists for (monorepo#2847): the deployment verifies the whole definition chain except
# its last link. One control tracks the gitlink against upstream, another hashes the desired state
# against the repository submodule at that gitlink — but nothing compares either against the copy the
# runtime actually loaded. That copy has no writer, so its staleness is unbounded rather than
# self-healing. Measured 2026-08-14 on the Claude instance: 7 of 9 definition files differed from the
# pin and had not moved in 20 days, while both existing controls read clean.
#
# The fixtures are hermetic — a local git repository stands in for the pinned plugin revision — so
# this suite needs no network and no runtime install, and finishes well inside the tool's call
# ceiling. That matters here: a validation script that cannot be run in one call does not get run.
#
# BOTH the behaviour and the contract prose are pinned. The script alone would let a later edit drop
# the rule that tells a run to execute it, leaving a correct check nobody invokes; the prose alone
# would let the check rot into something that cannot fire. Neither assertion covers the other.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo_root}/.claude/scripts/plugin-definition-currency.sh"
constitution="${repo_root}/AGENTS.md"

pass_count=0
fail() {
  echo "plugin-definition-currency: FAIL — $*" >&2
  exit 1
}
ok() {
  pass_count=$((pass_count + 1))
  echo "  ok — $*"
}

[ -x "${script}" ] || fail "${script} is missing or not executable"
[ -r "${constitution}" ] || fail "cannot read ${constitution}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# ── the fixture "pinned revision" ─────────────────────────────────────────────
# A real git repository, so the script exercises its local-object-database path exactly as it does
# against the live submodule. Two agents and two skills, plus a README and a manifest that the
# selector must ignore.
pin_repo="${tmp}/consumer/libraries/agent-plugins"
mkdir -p "${pin_repo}/plugins/agentic-engineering/agents" \
         "${pin_repo}/plugins/agentic-engineering/skills/alpha" \
         "${pin_repo}/plugins/agentic-engineering/skills/beta" \
         "${pin_repo}/plugins/agentic-engineering/.claude-plugin"
p="${pin_repo}/plugins/agentic-engineering"
printf 'reviewed engineer definition\n' > "${p}/agents/agentic-engineer.agent.md"
printf 'reviewed improver definition\n'  > "${p}/agents/agent-improver.agent.md"
printf 'reviewed alpha procedure\n'      > "${p}/skills/alpha/SKILL.md"
printf 'reviewed beta procedure\n'       > "${p}/skills/beta/SKILL.md"
printf 'readme prose\n'                  > "${p}/README.md"
printf '{"version":"9.9.9"}\n'           > "${p}/.claude-plugin/plugin.json"

git -C "${pin_repo}" init -q
git -C "${pin_repo}" config user.email t@example.invalid
git -C "${pin_repo}" config user.name t
git -C "${pin_repo}" add -A
git -C "${pin_repo}" commit -qm pin
gitlink="$(git -C "${pin_repo}" rev-parse HEAD)"

run() { "${script}" --repo-root "${tmp}/consumer" --gitlink "${gitlink}" --installed "$1" 2>&1; }

# A helper that builds an "installed" copy identical to the pin, which each case then perturbs in
# exactly one way. Isolating one conjunct per fixture is what makes a firing attributable.
make_install() {
  local dest="$1"
  mkdir -p "${dest}"
  cp -R "${p}/agents" "${p}/skills" "${p}/README.md" "${dest}/"
}

# ── 1. NEGATIVE CONTROL — an identical install must NOT fire ──────────────────
# Without this the suite proves nothing: a check that always reports drift would pass every other
# case here while being useless in production.
cur="${tmp}/install-current"
make_install "${cur}"
if out="$(run "${cur}")"; then
  case "${out}" in
    *CURRENT*) ok "an install matching the pin exits 0 and reports CURRENT" ;;
    *) fail "matching install exited 0 but did not report CURRENT: ${out}" ;;
  esac
else
  fail "matching install must exit 0, got $? — the check fires on a current install: ${out}"
fi

# ── 2. A CHANGED definition fires, and names the file ─────────────────────────
chg="${tmp}/install-changed"
make_install "${chg}"
printf 'superseded improver definition\n' > "${chg}/agents/agent-improver.agent.md"
set +e; out="$(run "${chg}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a changed definition must exit 1, got ${rc}"
case "${out}" in
  *"DRIFT    agents/agent-improver.agent.md"*) ok "a changed definition exits 1 and names the file" ;;
  *) fail "exit 1 but the changed file was not named: ${out}" ;;
esac
# The untouched files must still report as matching, or "names the file" is vacuous.
case "${out}" in
  *"match    agents/agentic-engineer.agent.md"*) ok "an untouched definition still reports match" ;;
  *) fail "the untouched engineer definition was not reported as matching: ${out}" ;;
esac

# ── 3. A MISSING definition fires ─────────────────────────────────────────────
# Distinct from case 2: an absent role is not a differing role, and a hash comparison that only
# walks the installed side would silently skip it.
mis="${tmp}/install-missing"
make_install "${mis}"
rm "${mis}/skills/beta/SKILL.md"
set +e; out="$(run "${mis}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a missing definition must exit 1, got ${rc}"
case "${out}" in
  *"MISSING  skills/beta/SKILL.md"*) ok "a definition absent from the install exits 1 as MISSING" ;;
  *) fail "exit 1 but the missing file was not named: ${out}" ;;
esac

# ── 4. An EXTRA definition fires ──────────────────────────────────────────────
# A role the runtime can still dispatch that the reviewed revision no longer describes. A check
# driven only by the reviewed list cannot see this, which is why it is asserted separately.
ext="${tmp}/install-extra"
make_install "${ext}"
mkdir -p "${ext}/skills/ghost"
printf 'a role the pin does not describe\n' > "${ext}/skills/ghost/SKILL.md"
set +e; out="$(run "${ext}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "an extra definition must exit 1, got ${rc}"
case "${out}" in
  *"EXTRA    skills/ghost/SKILL.md"*) ok "a definition absent from the pin exits 1 as EXTRA" ;;
  *) fail "exit 1 but the extra file was not named: ${out}" ;;
esac

# ── 5. Non-definition files are EXCLUDED ──────────────────────────────────────
# Firing on a README or a version bump that moves no definition would train the reader to ignore the
# check, which is the same outcome as not having one.
noi="${tmp}/install-noise"
make_install "${noi}"
printf 'entirely different readme\n' > "${noi}/README.md"
mkdir -p "${noi}/.claude-plugin"
printf '{"version":"0.0.1"}\n' > "${noi}/.claude-plugin/plugin.json"
if out="$(run "${noi}")"; then
  ok "a differing README and manifest do not fire — only definitions count"
else
  fail "the check fired on non-definition files: ${out}"
fi

# ── 6. FAIL CLOSED — an unresolvable install is UNKNOWN, never CURRENT ────────
# The load-bearing exit code. "I could not check" reported as 0 is how a currency check becomes
# decoration, and it is the failure mode a caller is least likely to notice.
set +e; out="$("${script}" --repo-root "${tmp}/consumer" --gitlink "${gitlink}" \
                           --installed "${tmp}/does-not-exist" 2>&1)"; rc=$?; set -e
[ "${rc}" -eq 2 ] || fail "an unresolvable install must exit 2 (UNKNOWN), got ${rc}: ${out}"
ok "an unresolvable install exits 2, not 0"

# ── 7. FAIL CLOSED — an unreachable pinned revision is UNKNOWN ────────────────
set +e; out="$("${script}" --repo-root "${tmp}/consumer" --installed "${cur}" \
                           --gitlink 0000000000000000000000000000000000000000 2>&1)"; rc=$?; set -e
[ "${rc}" -eq 2 ] || fail "an unreachable pinned revision must exit 2 (UNKNOWN), got ${rc}: ${out}"
# The MESSAGE is asserted, not just the code. Exit 2 alone would still pass if the local-object
# branch broke entirely and every case silently fell through to the forge — and it also pins that
# this suite makes no network call: the fixture has no .gitmodules, so slug resolution dies first.
case "${out}" in
  *"no .gitmodules url"*) ok "an unreachable pinned revision exits 2 without reaching the network" ;;
  *) fail "exit 2 but not by the expected network-free path — did it call out to the forge? ${out}" ;;
esac

# ── 7b. FAIL OPEN REGRESSION — an unrecognised pinned path is never silently dropped ──
# The defect this guards: the selector recognises two shapes and had no else branch, so any other
# path under agents/ or skills/ fell out of the reviewed list entirely. It was then invisible on BOTH
# sides — the reviewed loop never checked it, and the EXTRA sweep only fires when it IS installed. So
# "pinned but unrecognised AND absent from the install" reported CURRENT with a role definition
# missing from the runtime. Two independent triggers, asserted separately because they have different
# causes: an unexpected directory depth, and a space in the path (which awk's default field splitting
# truncated out of existence).
for case_name in depth space; do
  odd_repo="${tmp}/odd-${case_name}/libraries/agent-plugins"
  op="${odd_repo}/plugins/agentic-engineering"
  mkdir -p "${op}/agents" "${op}/skills/alpha"
  printf 'reviewed engineer definition\n' > "${op}/agents/agentic-engineer.agent.md"
  printf 'reviewed alpha procedure\n'      > "${op}/skills/alpha/SKILL.md"
  if [ "${case_name}" = depth ]; then
    mkdir -p "${op}/skills/group/nested"
    printf 'a definition at an unexpected depth\n' > "${op}/skills/group/nested/SKILL.md"
  else
    mkdir -p "${op}/skills/my skill"
    printf 'a definition whose path contains a space\n' > "${op}/skills/my skill/SKILL.md"
  fi
  git -C "${odd_repo}" init -q
  git -C "${odd_repo}" config user.email t@example.invalid
  git -C "${odd_repo}" config user.name t
  git -C "${odd_repo}" add -A
  git -C "${odd_repo}" commit -qm pin
  odd_link="$(git -C "${odd_repo}" rev-parse HEAD)"

  # The install deliberately does NOT contain the odd path — that is the invisible-on-both-sides case.
  odd_install="${tmp}/install-odd-${case_name}"
  mkdir -p "${odd_install}"
  cp -R "${op}/agents" "${odd_install}/"
  mkdir -p "${odd_install}/skills/alpha"
  cp "${op}/skills/alpha/SKILL.md" "${odd_install}/skills/alpha/SKILL.md"

  set +e
  out="$("${script}" --repo-root "${tmp}/odd-${case_name}" --gitlink "${odd_link}" \
                     --installed "${odd_install}" 2>&1)"; rc=$?
  set -e
  # The load-bearing property both cases share: NEVER exit 0. What each becomes afterwards differs,
  # and the difference is the point — the two fixes are not the same fix.
  [ "${rc}" -ne 0 ] || fail "FAIL OPEN (${case_name}): a pinned path absent from the install reported success: ${out}"
  if [ "${case_name}" = depth ]; then
    # Still unrecognisable by shape, so the honest answer is UNKNOWN rather than a verdict.
    [ "${rc}" -eq 2 ] || fail "an unclassifiable pinned path must exit 2 (UNKNOWN), got ${rc}: ${out}"
    case "${out}" in
      *UNCLASSIFIED*|*"could not be classified"*) ok "a pinned path at an unexpected depth exits 2, never CURRENT" ;;
      *) fail "exit 2 but the unclassified path was not reported: ${out}" ;;
    esac
  else
    # Tab-aware parsing PROMOTES this one: the path is no longer truncated, so it classifies as an
    # ordinary skill definition and is correctly reported MISSING. Asserting UNKNOWN here would pin
    # the bug rather than the fix.
    [ "${rc}" -eq 1 ] || fail "a pinned path containing a space must classify and exit 1, got ${rc}: ${out}"
    case "${out}" in
      *"MISSING  skills/my skill/SKILL.md"*) ok "a pinned path containing a space is parsed, not dropped" ;;
      *) fail "exit 1 but the spaced path was not named — is it still being truncated? ${out}" ;;
    esac
  fi
done

# ── 7c. A missing option VALUE is UNKNOWN, not DRIFT ──────────────────────────
# `shift 2` on a lone trailing flag returns 1, and under `set -e` that exited the script with 1 — the
# code that tells a caller the definition is stale. A typo would have produced a silent, output-free
# drift verdict, which is the most misleading failure this script can have.
for flag in --repo-root --gitlink --installed --plugins-root; do
  set +e; out="$("${script}" "${flag}" 2>&1)"; rc=$?; set -e
  [ "${rc}" -eq 2 ] || fail "a missing value for ${flag} must exit 2, got ${rc}: ${out}"
done
ok "a missing option value exits 2, never 1 (DRIFT)"

# ── 7d. Registry resolution — the only path production actually uses ──────────
# Every case above passes --installed, so without these the jq expression, the single-path check and
# all three of their die paths ship untested.
reg_root="${tmp}/plugins-root"
mkdir -p "${reg_root}"
printf '{"version":2,"plugins":{"agentic-engineering@devantler-plugins":[{"installPath":"%s"}]}}\n' \
  "${cur}" > "${reg_root}/installed_plugins.json"
if out="$("${script}" --repo-root "${tmp}/consumer" --gitlink "${gitlink}" --plugins-root "${reg_root}")"; then
  case "${out}" in
    *"${cur}"*) ok "a single registry entry resolves to its installPath" ;;
    *) fail "resolved from the registry but did not use its installPath: ${out}" ;;
  esac
else
  fail "a well-formed registry with a matching install must exit 0, got $?: ${out}"
fi

printf '{"version":2,"plugins":{"agentic-engineering@devantler-plugins":[{"installPath":"%s"},{"installPath":"%s"}]}}\n' \
  "${cur}" "${cur}" > "${reg_root}/installed_plugins.json"
set +e; out="$("${script}" --repo-root "${tmp}/consumer" --gitlink "${gitlink}" --plugins-root "${reg_root}" 2>&1)"; rc=$?; set -e
[ "${rc}" -eq 2 ] || fail "an ambiguous registry (2 install paths) must exit 2, got ${rc}: ${out}"
ok "an ambiguous registry exits 2 rather than picking one"

printf 'not json at all\n' > "${reg_root}/installed_plugins.json"
set +e; out="$("${script}" --repo-root "${tmp}/consumer" --gitlink "${gitlink}" --plugins-root "${reg_root}" 2>&1)"; rc=$?; set -e
[ "${rc}" -eq 2 ] || fail "a malformed registry must exit 2, got ${rc}: ${out}"
ok "a malformed registry exits 2, not a raw jq status"

rm -f "${reg_root}/installed_plugins.json"
set +e; out="$("${script}" --repo-root "${tmp}/consumer" --gitlink "${gitlink}" --plugins-root "${reg_root}" 2>&1)"; rc=$?; set -e
[ "${rc}" -eq 2 ] || fail "an absent registry must exit 2, got ${rc}: ${out}"
ok "an absent registry exits 2"

# ── 8. The remediation is NAMED in the failure output ─────────────────────────
# The deployment's own "fail with the fix" rule: a guard that blocks without naming the resolving
# action is a friction tax, and it trains the reader to route around it. It must also keep saying
# that the cache is not the thing to edit, or the cheapest-looking fix is the forbidden one.
out="$(run "${chg}" || true)"
case "${out}" in
  *"/plugin"*) ok "the failure output names the supported refresh path" ;;
  *) fail "the failure output does not name how to refresh: ${out}" ;;
esac
case "${out}" in
  *"Never edit the plugin cache"*) ok "the failure output still forbids editing the cache" ;;
  *) fail "the failure output does not forbid the cache edit: ${out}" ;;
esac

# ── 9. The CONTRACT names the rule and its remediation ────────────────────────
# Scoped to the plugin-contract section rather than the whole file: these phrases appear in this
# script's own header and in the run report, so a file-wide match would pass while the operative
# section said nothing. Flattened because every sentence wraps across source lines.
section="$(
  awk '
    /^### Agentic engineering plugin contract$/ { ins = 1; next }
    ins && /^### / { exit }
    ins { print }
  ' "${constitution}" | tr '\n' ' '
)"
[ -n "${section}" ] || fail "could not extract the plugin contract section from AGENTS.md"

case "${section}" in
  *"plugin-definition-currency.sh"*) ok "the contract names the check" ;;
  *) fail "the plugin contract section does not name plugin-definition-currency.sh" ;;
esac
case "${section}" in
  *"read the reviewed definition at the pinned gitlink"*)
    ok "the contract names what to do on drift" ;;
  *) fail "the plugin contract section does not say to follow the reviewed definition on drift" ;;
esac

echo "plugin-definition-currency: ${pass_count} assertions passed"
