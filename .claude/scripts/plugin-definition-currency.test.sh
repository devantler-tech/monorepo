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
cursor_loader="${repo_root}/.claude/loaders/cursor-daily-ai-engineer.md"

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
[ -r "${cursor_loader}" ] || fail "cannot read ${cursor_loader}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# ── the fixture "pinned revision" ─────────────────────────────────────────────
# A real git repository, so the script exercises its local-object-database path exactly as it does
# against the live submodule. Two agents, two skills, and the provider-neutral required runtime
# asset, plus a README and a manifest that the selector must ignore.
pin_repo="${tmp}/consumer/libraries/agent-plugins"
mkdir -p "${pin_repo}/plugins/agentic-engineering/agents" \
         "${pin_repo}/plugins/agentic-engineering/skills/alpha" \
         "${pin_repo}/plugins/agentic-engineering/skills/beta" \
         "${pin_repo}/plugins/agentic-engineering/.claude-plugin" \
         "${pin_repo}/plugins/agentic-engineering/scripts" \
         "${tmp}/consumer/.claude/plugin-consumption"
p="${pin_repo}/plugins/agentic-engineering"
printf 'reviewed engineer definition\n' > "${p}/agents/agentic-engineer.agent.md"
printf 'reviewed improver definition\n'  > "${p}/agents/agent-improver.agent.md"
printf 'reviewed alpha procedure\n'      > "${p}/skills/alpha/SKILL.md"
printf 'reviewed beta procedure\n'       > "${p}/skills/beta/SKILL.md"
printf '#!/bin/sh\necho classified\n'    > "${p}/scripts/classify-default-branch-ci-runs.sh"
chmod +x "${p}/scripts/classify-default-branch-ci-runs.sh"
fixture_runtime_sha="$(shasum -a 256 "${p}/scripts/classify-default-branch-ci-runs.sh" | awk '{print $1}')"
printf 'readme prose\n'                  > "${p}/README.md"
printf '{"version":"9.9.9"}\n'           > "${p}/.claude-plugin/plugin.json"
cat > "${tmp}/consumer/.claude/plugin-consumption/agentic-engineering.desired-state.json" <<JSON
{
  "spec": {
    "source": {
      "requiredRuntimeAssets": [
        {
          "path": "scripts/classify-default-branch-ci-runs.sh",
          "sha256": "${fixture_runtime_sha}",
          "executable": true
        }
      ]
    }
  }
}
JSON
fixture_desired_state="${tmp}/consumer/.claude/plugin-consumption/agentic-engineering.desired-state.json"
write_desired_state_fixture() {
  local consumer_root="$1"
  mkdir -p "${consumer_root}/.claude/plugin-consumption"
  cp "${fixture_desired_state}" \
    "${consumer_root}/.claude/plugin-consumption/agentic-engineering.desired-state.json"
}
add_runtime_asset_fixture() {
  local plugin_root="$1"
  mkdir -p "${plugin_root}/scripts"
  cp "${p}/scripts/classify-default-branch-ci-runs.sh" \
    "${plugin_root}/scripts/classify-default-branch-ci-runs.sh"
  chmod +x "${plugin_root}/scripts/classify-default-branch-ci-runs.sh"
}

git -C "${pin_repo}" init -q
git -C "${pin_repo}" config user.email t@example.invalid
git -C "${pin_repo}" config user.name t
git -C "${pin_repo}" add -A
git -C "${pin_repo}" -c commit.gpgsign=false commit -qm pin
gitlink="$(git -C "${pin_repo}" rev-parse HEAD)"

run() { "${script}" --repo-root "${tmp}/consumer" --gitlink "${gitlink}" --installed "$1" 2>&1; }

# A helper that builds an "installed" copy identical to the pin, which each case then perturbs in
# exactly one way. Isolating one conjunct per fixture is what makes a firing attributable.
make_install() {
  local dest="$1"
  mkdir -p "${dest}"
  cp -R "${p}/agents" "${p}/skills" "${p}/scripts" "${p}/README.md" "${dest}/"
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

# ── 3b. Required runtime assets are part of the LOADED surface ────────────────
# The surveyor executes this provider-neutral classifier. Checking only agents/ and skills/ reports
# CURRENT while the runtime actually runs stale bytes, has no classifier at all, or cannot execute
# it. Each state gets its own fixture so a single broad failure cannot satisfy all three claims.
runtime_rel="scripts/classify-default-branch-ci-runs.sh"

runtime_changed="${tmp}/install-runtime-changed"
make_install "${runtime_changed}"
printf '#!/bin/sh\necho stale\n' > "${runtime_changed}/${runtime_rel}"
set +e; out="$(run "${runtime_changed}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a changed required runtime asset must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT    ${runtime_rel}"*) ok "a changed required runtime asset exits 1 and names the file" ;;
  *) fail "exit 1 but the changed runtime asset was not named: ${out}" ;;
esac

runtime_missing="${tmp}/install-runtime-missing"
make_install "${runtime_missing}"
rm "${runtime_missing}/${runtime_rel}"
set +e; out="$(run "${runtime_missing}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a missing required runtime asset must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"MISSING  ${runtime_rel}"*) ok "a missing required runtime asset exits 1 and names the file" ;;
  *) fail "exit 1 but the missing runtime asset was not named: ${out}" ;;
esac

runtime_mode="${tmp}/install-runtime-mode"
make_install "${runtime_mode}"
chmod -x "${runtime_mode}/${runtime_rel}"
set +e; out="$(run "${runtime_mode}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a non-executable required runtime asset must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"mode differs"*) ok "a required runtime asset's lost executable bit is caught" ;;
  *) fail "exit 1 but the runtime asset mode difference was not reported: ${out}" ;;
esac

# A leaf-only symlink check still follows a symlinked parent directory. Redirect scripts/ to a
# directory with identical classifier bytes and require the component walk to reject the path.
runtime_parent_symlink="${tmp}/install-runtime-parent-symlink"
make_install "${runtime_parent_symlink}"
runtime_symlink_target="${tmp}/runtime-symlink-target"
mkdir -p "${runtime_symlink_target}"
cp "${runtime_parent_symlink}/${runtime_rel}" \
  "${runtime_symlink_target}/classify-default-branch-ci-runs.sh"
rm "${runtime_parent_symlink}/${runtime_rel}"
rmdir "${runtime_parent_symlink}/scripts"
ln -s "${runtime_symlink_target}" "${runtime_parent_symlink}/scripts"
set +e; out="$(run "${runtime_parent_symlink}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a symlinked runtime asset parent must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT    ${runtime_rel}"*SYMLINK*) ok "a symlinked runtime asset parent is caught with identical leaf bytes" ;;
  *) fail "exit 1 but the symlinked runtime asset parent was not reported: ${out}" ;;
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
  add_runtime_asset_fixture "${op}"
  write_desired_state_fixture "${tmp}/odd-${case_name}"
  if [ "${case_name}" = depth ]; then
    odd_path="skills/group/nested/SKILL.md"
  else
    odd_path="skills/my skill/SKILL.md"
  fi
  mkdir -p "${op}/$(dirname "${odd_path}")"
  printf 'a definition the old shape filter would have dropped\n' > "${op}/${odd_path}"
  git -C "${odd_repo}" init -q
  git -C "${odd_repo}" config user.email t@example.invalid
  git -C "${odd_repo}" config user.name t
  git -C "${odd_repo}" add -A
  git -C "${odd_repo}" -c commit.gpgsign=false commit -qm pin
  odd_link="$(git -C "${odd_repo}" rev-parse HEAD)"

  # The install deliberately does NOT contain the odd path — that is the invisible-on-both-sides case.
  odd_install="${tmp}/install-odd-${case_name}"
  mkdir -p "${odd_install}"
  cp -R "${op}/agents" "${odd_install}/"
  cp -R "${op}/scripts" "${odd_install}/"
  mkdir -p "${odd_install}/skills/alpha"
  cp "${op}/skills/alpha/SKILL.md" "${odd_install}/skills/alpha/SKILL.md"

  set +e
  out="$("${script}" --repo-root "${tmp}/odd-${case_name}" --gitlink "${odd_link}" \
                     --installed "${odd_install}" 2>&1)"; rc=$?
  set -e
  # The load-bearing property: NEVER exit 0. Comparing every file under agents/ and skills/ means
  # both shapes are now ordinary definitions, so each is reported MISSING rather than needing a
  # special unclassified state — strictly stronger than the drop this case was written against.
  [ "${rc}" -ne 0 ] || fail "FAIL OPEN (${case_name}): a pinned path absent from the install reported success: ${out}"
  [ "${rc}" -eq 1 ] || fail "an odd-shaped pinned path must be compared and exit 1, got ${rc}: ${out}"
  case "${out}" in
    *"MISSING  ${odd_path}"*) ok "an odd-shaped pinned path (${case_name}) is compared, not dropped" ;;
    *) fail "exit 1 but the odd-shaped path was not named (${case_name}): ${out}" ;;
  esac
done

# A quoted pinned path must fail closed even when ordinary records sort before it. The old sentinel
# check looked for a literal two-character `\n`, so a trailing QUOTED record escaped detection; the
# missing unusual definition then disappeared from both comparison sides and reported CURRENT.
quoted_root="${tmp}/quoted-pinned"
quoted_repo="${quoted_root}/libraries/agent-plugins"
quoted_plugin="${quoted_repo}/plugins/agentic-engineering"
mkdir -p "${quoted_plugin}/agents"
printf 'reviewed engineer definition\n' > "${quoted_plugin}/agents/agentic-engineer.agent.md"
printf 'quoted path definition\n' > "${quoted_plugin}/agents/odd\\name.md"
add_runtime_asset_fixture "${quoted_plugin}"
write_desired_state_fixture "${quoted_root}"
git -C "${quoted_repo}" init -q
git -C "${quoted_repo}" config user.email t@example.invalid
git -C "${quoted_repo}" config user.name t
git -C "${quoted_repo}" add -A
git -C "${quoted_repo}" -c commit.gpgsign=false commit -qm pin
quoted_link="$(git -C "${quoted_repo}" rev-parse HEAD)"
quoted_install="${tmp}/install-quoted-pinned"
mkdir -p "${quoted_install}/agents"
cp "${quoted_plugin}/agents/agentic-engineer.agent.md" "${quoted_install}/agents/"
cp -R "${quoted_plugin}/scripts" "${quoted_install}/"
set +e
out="$("${script}" --repo-root "${quoted_root}" --gitlink "${quoted_link}" \
                  --installed "${quoted_install}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "a mixed ordinary-plus-quoted pinned tree must be UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"path git had to quote"*) ok "a quoted pinned path is detected anywhere in the sorted tree" ;;
  *) fail "quoted pinned path did not name the fail-closed reason: ${out}" ;;
esac

# ── 7c. A missing option VALUE is UNKNOWN, not DRIFT ──────────────────────────
# `shift 2` on a lone trailing flag returns 1, and under `set -e` that exited the script with 1 — the
# code that tells a caller the definition is stale. A typo would have produced a silent, output-free
# drift verdict, which is the most misleading failure this script can have.
for flag in --runtime --repo-root --gitlink --installed --plugins-root --codex-home --cursor-ref; do
  set +e; out="$("${script}" "${flag}" 2>&1)"; rc=$?; set -e
  [ "${rc}" -eq 2 ] || fail "a missing value for ${flag} must exit 2, got ${rc}: ${out}"
done
ok "a missing option value exits 2, never 1 (DRIFT)"

# Header growth must not silently truncate --help. A fixed line range did exactly that when the
# runtime selector expanded Usage, dropping part of the exit-code contract from operator output.
out="$("${script}" --help)" || fail "--help must exit 0"
case "${out}" in
  *"--runtime claude|codex|cursor"*"collapsing them is how a currency check becomes decoration"*)
    ok "--help prints the complete runtime-aware header and exit contract" ;;
  *) fail "--help truncated the runtime-aware header: ${out}" ;;
esac

# ── 7d. Registry resolution — the only path production actually uses ──────────
# Every case above passes --installed, so without these the jq expression, the single-path check and
# all three of their die paths ship untested.
reg_root="${tmp}/plugins-root"
mkdir -p "${reg_root}"
printf '{"version":2,"plugins":{"agentic-engineering@devantler-plugins":[{"installPath":"%s"}]}}\n' \
  "${cur}" > "${reg_root}/installed_plugins.json"
if out="$("${script}" --runtime claude --repo-root "${tmp}/consumer" --gitlink "${gitlink}" --plugins-root "${reg_root}")"; then
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

# ── 7e. The INSTALLED tree is compared by the SAME rule as the pinned tree ────
# The mirror of 7b. A filename-filtered scan of the install skipped odd-shaped installed files, so
# the fail-open was only moved, not closed. Comparing every file under agents/ and skills/ makes each
# an ordinary EXTRA.
for odd in "skills/alpha/references/notes.md" "agents/sub/nested.agent.md"; do
  inst="${tmp}/install-oddshape-$(printf '%s' "${odd}" | tr '/.' '__')"
  make_install "${inst}"
  mkdir -p "${inst}/$(dirname "${odd}")"
  printf 'a file the old shape filter would have skipped
' > "${inst}/${odd}"
  set +e; out="$(run "${inst}")"; rc=$?; set -e
  [ "${rc}" -ne 0 ] || fail "FAIL OPEN: an odd-shaped INSTALLED path (${odd}) reported success: ${out}"
  case "${out}" in
    *"EXTRA    ${odd}"*) ok "an odd-shaped installed path (${odd}) is compared, not skipped" ;;
    *) fail "the installed path was not reported (${odd}): ${out}" ;;
  esac
done

# ── 7f. A supporting file in a skill package is part of the surface ───────────
# A SKILL.md can read or execute files beside it, so their drift is behaviourally relevant. Comparing
# only depth-three SKILL.md would miss it AND would have pinned the check at permanent UNKNOWN the
# first time upstream shipped a reference file.
sup_repo="${tmp}/sup/libraries/agent-plugins"
sp="${sup_repo}/plugins/agentic-engineering"
mkdir -p "${sp}/agents" "${sp}/skills/alpha/references"
printf 'reviewed engineer definition
' > "${sp}/agents/agentic-engineer.agent.md"
printf 'reviewed alpha procedure
'      > "${sp}/skills/alpha/SKILL.md"
printf 'reviewed reference material
'   > "${sp}/skills/alpha/references/notes.md"
add_runtime_asset_fixture "${sp}"
write_desired_state_fixture "${tmp}/sup"
git -C "${sup_repo}" init -q
git -C "${sup_repo}" config user.email t@example.invalid
git -C "${sup_repo}" config user.name t
git -C "${sup_repo}" add -A
git -C "${sup_repo}" -c commit.gpgsign=false commit -qm pin
sup_link="$(git -C "${sup_repo}" rev-parse HEAD)"
sup_inst="${tmp}/install-sup"
mkdir -p "${sup_inst}"
cp -R "${sp}/agents" "${sp}/skills" "${sp}/scripts" "${sup_inst}/"
# Identical package must be CURRENT -- the permanent-UNKNOWN regression this guards against.
if out="$("${script}" --repo-root "${tmp}/sup" --gitlink "${sup_link}" --installed "${sup_inst}" 2>&1)"; then
  ok "a skill package with supporting files reports CURRENT when identical"
else
  fail "an identical multi-file skill package must exit 0, got $?: ${out}"
fi
# ...and a drifted supporting file must be caught.
printf 'superseded reference material
' > "${sup_inst}/skills/alpha/references/notes.md"
set +e; out="$("${script}" --repo-root "${tmp}/sup" --gitlink "${sup_link}" --installed "${sup_inst}" 2>&1)"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a drifted supporting file must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT    skills/alpha/references/notes.md"*) ok "a drifted supporting file inside a skill is caught" ;;
  *) fail "exit 1 but the supporting file was not named: ${out}" ;;
esac

# ── 7g. An install path containing WHITESPACE still resolves ──────────────────
# Enumerating the two directories through a joined, deliberately word-split string turned a MATCHING
# install under such a path into UNKNOWN.
ws="${tmp}/my install dir"
make_install "${ws}"
if out="$(run "${ws}")"; then
  ok "an install path containing spaces reports CURRENT, not UNKNOWN"
else
  fail "an install path containing spaces must exit 0, got $?: ${out}"
fi

# ── 7h. MODE is compared, not just content ───────────────────────────────────
# A skill helper that loses its executable bit hashes identically, so a content-only comparison
# reports `match` and the verdict is CURRENT — while a SKILL.md invoking that helper fails.
mode_repo="${tmp}/mode/libraries/agent-plugins"
mp="${mode_repo}/plugins/agentic-engineering"
mkdir -p "${mp}/agents" "${mp}/skills/alpha"
printf 'reviewed engineer definition\n' > "${mp}/agents/agentic-engineer.agent.md"
printf 'reviewed alpha procedure\n'      > "${mp}/skills/alpha/SKILL.md"
printf '#!/bin/sh\necho helper\n'        > "${mp}/skills/alpha/helper.sh"
chmod +x "${mp}/skills/alpha/helper.sh"
add_runtime_asset_fixture "${mp}"
write_desired_state_fixture "${tmp}/mode"
git -C "${mode_repo}" init -q
git -C "${mode_repo}" config user.email t@example.invalid
git -C "${mode_repo}" config user.name t
git -C "${mode_repo}" add -A
git -C "${mode_repo}" -c commit.gpgsign=false commit -qm pin
mode_link="$(git -C "${mode_repo}" rev-parse HEAD)"
mode_inst="${tmp}/install-mode"
mkdir -p "${mode_inst}"
cp -R "${mp}/agents" "${mp}/skills" "${mp}/scripts" "${mode_inst}/"
# Identical, executable bit intact -> CURRENT. Without this the next assertion could pass trivially.
if "${script}" --repo-root "${tmp}/mode" --gitlink "${mode_link}" --installed "${mode_inst}" >/dev/null 2>&1; then
  ok "an executable helper with its mode intact reports CURRENT"
else
  fail "an identical install with an executable helper must exit 0"
fi
chmod -x "${mode_inst}/skills/alpha/helper.sh"
set +e; out="$("${script}" --repo-root "${tmp}/mode" --gitlink "${mode_link}" --installed "${mode_inst}" 2>&1)"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a lost executable bit must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"mode differs"*) ok "a lost executable bit is caught even though the content hash matches" ;;
  *) fail "exit 1 but the mode difference was not reported: ${out}" ;;
esac

# ── 7i. A TRUNCATED forge tree is UNKNOWN, never a comparison ─────────────────
# GitHub marks an over-large recursive Trees response `truncated`. Comparing it as if complete is a
# fail-open: a pinned file the API omitted is also absent from the reviewed set, so an install missing
# that file reports CURRENT. Exercised with a gh shim so the case is hermetic.
shim="${tmp}/shim"
mkdir -p "${shim}"
cat > "${shim}/gh" <<'SHIM'
#!/bin/sh
printf '{"truncated":true,"tree":[]}\n'
SHIM
chmod +x "${shim}/gh"
mkdir -p "${tmp}/trunc"
write_desired_state_fixture "${tmp}/trunc"
cat > "${tmp}/trunc/.gitmodules" <<'GM'
[submodule "libraries/agent-plugins"]
	path = libraries/agent-plugins
	url = git@github.com:devantler-tech/agent-plugins.git
GM
# A gitlink absent from the local object database forces the forge branch.
set +e
out="$(PATH="${shim}:${PATH}" "${script}" --repo-root "${tmp}/trunc" --installed "${cur}" \
        --gitlink 1111111111111111111111111111111111111111 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "a truncated forge tree must exit 2 (UNKNOWN), got ${rc}: ${out}"
case "${out}" in
  *TRUNCATED*) ok "a truncated forge tree exits 2 rather than comparing a partial tree" ;;
  *) fail "exit 2 but not because of truncation: ${out}" ;;
esac

# ── 7j. A SYMLINK is not a definition ────────────────────────────────────────
# -f, `git hash-object` and -x all FOLLOW a symlink, so an installed definition replaced by a link to
# an identical file passed every single test and reported CURRENT.
sym="${tmp}/install-symlink"
make_install "${sym}"
printf 'reviewed improver definition\n' > "${tmp}/decoy.md"
rm "${sym}/agents/agent-improver.agent.md"
ln -s "${tmp}/decoy.md" "${sym}/agents/agent-improver.agent.md"
set +e; out="$(run "${sym}")"; rc=$?; set -e
[ "${rc}" -ne 0 ] || fail "FAIL OPEN: a definition replaced by a symlink to identical bytes reported success: ${out}"
case "${out}" in
  *"SYMLINK"*) ok "a definition installed as a symlink is drift, even with identical bytes" ;;
  *) fail "exit ${rc} but the symlink was not reported: ${out}" ;;
esac

# ── 7k. An EXTRA SYMLINK is still an unreviewed definition ───────────────────
# The pinned-path loop above catches a symlink only when it replaces a reviewed path. The installed
# tree sweep must independently enumerate links, or a new link under agents/ or skills/ disappears
# from both comparisons and the runtime can expose an unpinned definition while this reports CURRENT.
extra_sym="${tmp}/install-extra-symlink"
make_install "${extra_sym}"
mkdir -p "${extra_sym}/skills/ghost"
ln -s "${tmp}/decoy.md" "${extra_sym}/skills/ghost/SKILL.md"
set +e; out="$(run "${extra_sym}")"; rc=$?; set -e
[ "${rc}" -ne 0 ] || fail "FAIL OPEN: an extra definition symlink reported success: ${out}"
case "${out}" in
  *"EXTRA    skills/ghost/SKILL.md"*) ok "an extra definition symlink is caught by the installed-tree sweep" ;;
  *) fail "exit ${rc} but the extra symlink was not reported: ${out}" ;;
esac

# ── 7l. DELIBERATELY NOT TESTED — the mktemp guard ───────────────────────────
# `mktemp`'s failure path is guarded in the script (an unwritable TMPDIR would otherwise exit 1 under
# `set -e`, and 1 is the DRIFT verdict, so an infrastructure failure would read as a finding about the
# install). There is no assertion here because there is no portable way to force it: BSD/macOS mktemp
# IGNORES an unusable TMPDIR and falls back to the system temp dir, so the obvious test passes on
# every implementation regardless of the guard — verified by ablation, which did not fire.
# A vacuous assertion is worse than none: it manufactures confidence in an untested path. Left absent
# and explained rather than left green and meaningless.

# A `codex` shim keeps this suite hermetic. The lane asks the runtime for effective state, so a real
# `codex` on PATH would answer about the HOST rather than this fixture — and its answer for a fixture
# home is "no installed plugins", which is a legitimate *disabled* verdict and would make every case
# below fail for an unrelated reason. CODEX_SHIM_MODE selects what the runtime reports.
codex_shim="${tmp}/codex-shim"
mkdir -p "${codex_shim}"
cat > "${codex_shim}/codex" <<'SHIMBIN'
#!/bin/sh
# only implements: plugin list --json
case "${CODEX_SHIM_MODE:-enabled}" in
  enabled)
    printf '{"installed":[{"pluginId":"agentic-engineering@devantler-plugins","enabled":true}],"available":[]}\n' ;;
  disabled)
    printf '{"installed":[{"pluginId":"agentic-engineering@devantler-plugins","enabled":false}],"available":[]}\n' ;;
  feature-off)
    printf '{"installed":[],"available":[]}\n' ;;
  unavailable)
    exit 1 ;;
esac
SHIMBIN
chmod +x "${codex_shim}/codex"
PATH="${codex_shim}:${PATH}"
export PATH

# ── 7m. CODEX resolves the copy its own runtime loaded ────────────────────────
# Codex has no Claude-style installed_plugins.json. Its enabled plugin is served from the versioned
# cache under CODEX_HOME, so the lane must inspect that cache rather than silently falling back to
# Claude's registry. Start with the negative control: one enabled, matching cached copy must pass.
codex_home="${tmp}/codex-home"
codex_install="${codex_home}/plugins/cache/devantler-plugins/agentic-engineering/9.9.9"
mkdir -p "${codex_home}"
cat > "${codex_home}/config.toml" <<'TOML'
[plugins."agentic-engineering@devantler-plugins"]
enabled = true
TOML
make_install "${codex_install}"
if out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                      --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; then
  case "${out}" in
    *CURRENT*) ;;
    *) fail "Codex matching cache exited 0 without reporting CURRENT: ${out}" ;;
  esac
  case "${out}" in
    *"${codex_install}"*) ok "Codex resolves its one enabled cached copy and reports CURRENT" ;;
    *) fail "Codex matching cache did not name its loaded copy: ${out}" ;;
  esac
else
  fail "Codex matching cache must exit 0, got $? — ${out}"
fi

printf 'stale Codex improver definition\n' > "${codex_install}/agents/agent-improver.agent.md"
set +e
out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "a drifted Codex cache must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT    agents/agent-improver.agent.md"*) ok "a drifted Codex cached definition fires" ;;
  *) fail "Codex drift did not name the changed definition: ${out}" ;;
esac
cp "${p}/agents/agent-improver.agent.md" "${codex_install}/agents/agent-improver.agent.md"

# More than one version is deliberately UNKNOWN. Picking newest-looking, first, or last would guess
# which cache the runtime loaded and could report CURRENT for a copy this process never executed.
codex_extra="${codex_home}/plugins/cache/devantler-plugins/agentic-engineering/10.0.0"
make_install "${codex_extra}"
set +e
out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "ambiguous Codex caches must exit 2, got ${rc}: ${out}"
case "${out}" in
  *"2 cached copies"*) ok "multiple Codex caches are UNKNOWN rather than guessed" ;;
  *) fail "ambiguous Codex cache did not name the reason: ${out}" ;;
esac
rm -rf "${codex_extra}"

sed 's/enabled = true/enabled = false/' "${codex_home}/config.toml" > "${codex_home}/config.disabled"
mv "${codex_home}/config.disabled" "${codex_home}/config.toml"
set +e
out="$(CODEX_SHIM_MODE=disabled "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "a disabled Codex plugin must exit 2, got ${rc}: ${out}"
case "${out}" in
  *"not enabled"*) ok "a disabled Codex plugin is UNKNOWN, not a cached CURRENT" ;;
  *) fail "disabled Codex plugin did not name the reason: ${out}" ;;
esac
sed 's/enabled = false/enabled = true/' "${codex_home}/config.toml" > "${codex_home}/config.enabled"
mv "${codex_home}/config.enabled" "${codex_home}/config.toml"

# An explicit install override is useful to the Claude fixture suite, but in another named lane it
# would let a caller point at Claude's copy and manufacture a verdict about bytes Codex never loaded.
set +e
out="$("${script}" --runtime codex --installed "${cur}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "Codex with an install override must exit 2, got ${rc}: ${out}"
case "${out}" in
  *"does not accept --installed"*) ok "Codex cannot be pointed at another lane's installed copy" ;;
  *) fail "Codex install override was rejected without naming the reason: ${out}" ;;
esac

# ── 7n. CURSOR compares the exact submodule ref its loader reads ──────────────
# The Cursor loader fetches and reads origin/main directly from the submodule object database. It
# has no installed plugin copy, so this lane compares that resolved commit with the consumer pin.
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
if out="$("${script}" --runtime cursor --repo-root "${tmp}/consumer" \
                      --gitlink "${gitlink}" 2>&1)"; then
  case "${out}" in
    *CURRENT*) ;;
    *) fail "Cursor matching ref exited 0 without reporting CURRENT: ${out}" ;;
  esac
  case "${out}" in
    *"refs/remotes/origin/main"*) ok "Cursor matching loaded revision reports CURRENT" ;;
    *) fail "Cursor matching ref did not name its source ref: ${out}" ;;
  esac
else
  fail "Cursor matching loaded revision must exit 0, got $? — ${out}"
fi

printf 'newer upstream prose\n' > "${p}/README.md"
git -C "${pin_repo}" add plugins/agentic-engineering/README.md
git -C "${pin_repo}" -c commit.gpgsign=false commit -qm cursor-drift
cursor_drift="$(git -C "${pin_repo}" rev-parse HEAD)"
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${cursor_drift}"
set +e
out="$("${script}" --runtime cursor --repo-root "${tmp}/consumer" \
                  --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "a drifted Cursor loaded revision must exit 1, got ${rc}: ${out}"
case "${out}" in
  *DRIFT*"${cursor_drift}"*"${gitlink}"*) ok "a drifted Cursor loaded revision fires and names both commits" ;;
  *) fail "Cursor revision drift did not name loaded and pinned commits: ${out}" ;;
esac

git -C "${pin_repo}" update-ref -d refs/remotes/origin/main
set +e
out="$("${script}" --runtime cursor --repo-root "${tmp}/consumer" \
                  --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "an unresolved Cursor loaded revision must exit 2, got ${rc}: ${out}"
case "${out}" in
  *"cannot resolve Cursor loaded revision"*) ok "an unresolved Cursor ref is UNKNOWN and names the reason" ;;
  *) fail "missing Cursor ref did not name the reason: ${out}" ;;
esac

set +e
out="$("${script}" --runtime cursor --installed "${cur}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "Cursor with an install override must exit 2, got ${rc}: ${out}"
case "${out}" in
  *"does not accept --installed"*) ok "Cursor cannot be pointed at another lane's installed copy" ;;
  *) fail "Cursor install override was rejected without naming the reason: ${out}" ;;
esac

# These cases share the pinned repository with later checks. They must leave both the checkout and
# the loader ref exactly as they found them, or a later assertion can inherit Cursor-case state and
# pass or fail for the wrong reason.
git -C "${pin_repo}" switch --detach --quiet "${gitlink}"
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
[ "$(git -C "${pin_repo}" rev-parse HEAD)" = "${gitlink}" ] \
  || fail "Cursor cases did not restore the shared pin fixture HEAD"
[ -z "$(git -C "${pin_repo}" status --porcelain)" ] \
  || fail "Cursor cases left the shared pin fixture dirty"
[ "$(git -C "${pin_repo}" rev-parse refs/remotes/origin/main)" = "${gitlink}" ] \
  || fail "Cursor cases did not restore the shared loader ref"
ok "Cursor cases restore the shared pin fixture before later checks"

# The loader must resolve the same unambiguous remote-tracking ref the currency check verifies.
# A tag can legally contain a slash, so a tag named `origin/main` makes the shorthand ambiguous:
# plain `git show origin/main:<path>` then follows the tag while the check follows
# `refs/remotes/origin/main` and can report CURRENT over different bytes.
printf 'UNREVIEWED ambiguous-ref agent\n' > "${p}/agents/agentic-engineer.agent.md"
git -C "${pin_repo}" add plugins/agentic-engineering/agents/agentic-engineer.agent.md
git -C "${pin_repo}" -c commit.gpgsign=false commit -qm ambiguous-loader-ref
ambiguous_loader_commit="$(git -C "${pin_repo}" rev-parse HEAD)"
git -C "${pin_repo}" tag origin/main "${ambiguous_loader_commit}"
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
loader_ref="$(sed -n \
  's/.*git -C libraries\/agent-plugins show \([^:][^:]*\):plugins\/agentic-engineering\/agents\/agentic-engineer\.agent\.md.*/\1/p' \
  "${cursor_loader}" | tail -n 1)"
[ -n "${loader_ref}" ] || fail "could not extract the Cursor loader definition ref"
loaded_agent="$(git -C "${pin_repo}" show \
  "${loader_ref}:plugins/agentic-engineering/agents/agentic-engineer.agent.md" 2>/dev/null)"
pinned_agent="$(git -C "${pin_repo}" show \
  "${gitlink}:plugins/agentic-engineering/agents/agentic-engineer.agent.md")"
[ "${loaded_agent}" = "${pinned_agent}" ] \
  || fail "Cursor loader ref '${loader_ref}' resolved ambiguous content instead of the verified remote-tracking ref"
git -C "${pin_repo}" tag -d origin/main >/dev/null
git -C "${pin_repo}" switch --detach --quiet "${gitlink}"
[ -z "$(git -C "${pin_repo}" status --porcelain)" ] \
  || fail "ambiguous Cursor loader case left the shared pin fixture dirty"
ok "Cursor loader reads the unambiguous remote-tracking ref the currency check verifies"

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

# Each remaining instruction is pinned on its own. Asserting only the check name and the fallback
# would let a contract-only edit strip the exit semantics, the refresh path, or the cache prohibition
# while this test stayed green — the same silent-loosening hole the both-halves rule exists to close.
case "${section}" in
  *UNKNOWN*) ok "the contract names the UNKNOWN verdict" ;;
  *) fail "the plugin contract section does not name the UNKNOWN (exit 2) verdict" ;;
esac
case "${section}" in
  *"never read it as current"*) ok "the contract says UNKNOWN is not current" ;;
  *) fail "the plugin contract section does not say an UNKNOWN result must not be read as current" ;;
esac
# UNKNOWN must also not become a stop condition — a diagnostic that halts every plugin-sourced role
# is the passive self-blocking this contract forbids elsewhere.
case "${section}" in
  *"never let it halt a run"*) ok "the contract says UNKNOWN must not halt a run" ;;
  *) fail "the plugin contract section does not say an UNKNOWN must not halt a run" ;;
esac
# The needle is the FLOW, not the bare "/plugin" token: that token also appears in
# `.claude/plugin-consumption/...` and in this check's own path, so a bare match is satisfied by
# unrelated prose and the assertion never fires. Occurrence-counted before choosing.
case "${section}" in
  *"marketplace update flow"*) ok "the contract names the supported refresh flow" ;;
  *) fail "the plugin contract section does not name the /plugin marketplace update refresh flow" ;;
esac
case "${section}" in
  *"Never edit the plugin cache"*) ok "the contract forbids editing the plugin cache" ;;
  *) fail "the plugin contract section does not forbid editing the plugin cache" ;;
esac
case "${section}" in
  *"blob identity"*) ok "the contract pins comparison by blob identity, not a version string" ;;
  *) fail "the plugin contract section does not require comparison by blob identity" ;;
esac
# The command is lane-scoped: a bare invocation still defaults to Claude for compatibility, so each
# deployed adapter must name itself or Codex/Cursor can silently inspect the wrong lane.
for runtime in claude codex cursor; do
  case "${section}" in
    *"--runtime ${runtime}"*) ok "the contract names the ${runtime} runtime selector" ;;
    *) fail "the plugin contract section does not name --runtime ${runtime}" ;;
  esac
done
case "${section}" in
  *"more than one cached version"*UNKNOWN*)
    ok "the contract makes ambiguous Codex caches UNKNOWN rather than guessed" ;;
  *) fail "the plugin contract section does not fail closed on ambiguous Codex caches" ;;
esac
case "${section}" in
  *"refs/remotes/origin/main"*)
    ok "the contract binds Cursor verification to the ref its loader reads" ;;
  *) fail "the plugin contract section does not name Cursor's loaded submodule ref" ;;
esac

# ── 10. The fallback must be EXECUTABLE, not just named ───────────────────────
# monorepo#2854: naming the reviewed definition as the fallback is not enough, because neither way a
# run can reach it works unaided. The submodule holding it is empty in a fresh per-run worktree
# (measured 2026-08-15: most live worktrees carried zero entries there), and where it IS populated —
# the shared checkout — it sits at whatever revision it was last left on rather than this commit's
# gitlink (measured the same day: bfde8656 against a pinned 564a6a0f, differing by 311 inserted and
# 43 deleted lines across all four definition files). The second is the fail-open: it returns a
# plausible definition, so the run believes it complied while following an unreviewed revision.
# Measured impact: of the 5 sessions that saw DRIFT that day, only 2 read any reviewed definition.
# Matched as COMPLETE commands including their path argument. A bare "submodule-init.sh" would still
# pass if an edit retargeted it at another submodule, and a bare "rev-parse HEAD" would pass if the
# read-back were pointed somewhere other than the path just materialised — which is precisely the
# wrong-revision read this section exists to stop.
case "${section}" in
  *".claude/scripts/submodule-init.sh libraries/agent-plugins"*)
    ok "the contract names the exact materialisation command and its target" ;;
  *) fail "the plugin contract section does not name the exact command that materialises the reviewed definition" ;;
esac
# The materialisation alone is still fail-open — it is the revision ASSERTION that converts a
# wrong-revision read from a silent pass into a stop. Pinned separately so an edit cannot drop the
# check while keeping the command, and bound to the SAME path so the two cannot drift apart.
case "${section}" in
  *"git -C libraries/agent-plugins rev-parse HEAD"*)
    ok "the contract reads the revision back from the path it materialised" ;;
  *) fail "the plugin contract section does not read the materialised revision back from that same path" ;;
esac
case "${section}" in
  *"must equal the pinned revision"*)
    ok "the contract requires the materialised revision to equal the pin" ;;
  *) fail "the plugin contract section does not require the materialised revision to equal the pin" ;;
esac
# The shared checkout is the specific trap, so it is named rather than left to inference: a run that
# has not been told the populated copy can be the WRONG copy has no reason to suspect it.
case "${section}" in
  *"shared checkout"*)
    ok "the contract warns that the populated shared checkout may be the wrong revision" ;;
  *) fail "the plugin contract section does not warn about the shared checkout's revision" ;;
esac
# Detecting the mismatch is only half of it: the run also has to be told what to DO. Re-running the
# materialisation is the intuitive move and it cannot work — handed an already-populated submodule the
# helper repairs isolation and refuses `git submodule update`, exiting `isolated ✓` on the stale
# revision. Without this assertion the contract could name the comparison and leave the recovery to
# guesswork, which lands straight back on the stale definition.
case "${section}" in
  *"a STOP, not a retry"*)
    ok "the contract says a revision mismatch stops rather than retries" ;;
  *) fail "the plugin contract section does not say a revision mismatch is a stop rather than a retry" ;;
esac
case "${section}" in
  *"fresh isolated worktree"*)
    ok "the contract names the recovery for a revision mismatch" ;;
  *) fail "the plugin contract section does not name the recovery path after a revision mismatch" ;;
esac

# ── 11. The fallback must survive the cases that BREAK a working tree ─────────
# Codex review of monorepo#2855 (3×P1, all verified against the scripts): the section 10 procedure
# assumed a usable working tree, and each of its three assumptions fails in a case the fallback is
# actually reached in.
#
# (a) The pin was sourced from "the pinned revision the check printed" — but every `die` in
# plugin-definition-currency.sh exits BEFORE its reporting block (the pin prints at the `say` well
# after the last `die`), so an UNKNOWN prints no pin at all. UNKNOWN is exactly when this fallback is
# reached, so the instruction was unfollowable in its own trigger case. Matched as the complete
# `HEAD:<path>` form: a bare "rev-parse" already appears above for the read-back.
#
# The match starts at `rev-parse`, NOT at `git`, because git-level flags sit between the two — the
# section's pin line carries `--no-replace-objects` there, and a literal starting at `git` asserts
# command SPELLING where the intent is that the pin comes from the gitlink rather than the check's
# stdout. Hardening that command would then falsify this assertion, which is what it must not do.
# `HEAD:<path>` is still what discriminates: the read-back above is `rev-parse HEAD` with no
# colon-path, and the byte-comparison loop reads `rev-parse "HEAD:$f"`, so neither satisfies this.
case "${section}" in
  *"rev-parse HEAD:libraries/agent-plugins"*)
    ok "the contract resolves the pin independently of the check's output" ;;
  *) fail "the plugin contract section does not name a pin source independent of the check" ;;
esac
# (b) A working-tree-free path must exist, because BOTH tree-based paths can fail: the submodule is
# empty in a fresh worktree and `submodule-init.sh` can die STILL EMPTY there (its own comment
# records `git submodule update --init` exiting 0 having populated nothing, observed from a linked
# superproject). Without this, the prescribed recovery dead-ends and the run stops rather than
# reading the reviewed definition. Matched on the repo-qualified contents path so the assertion
# cannot be satisfied by an unrelated `gh api` elsewhere in the section.
case "${section}" in
  *"repos/devantler-tech/agent-plugins/contents"*)
    ok "the contract names a read that needs no working tree" ;;
  *) fail "the plugin contract section does not name a working-tree-free read of the reviewed definition" ;;
esac
case "${section}" in
  *"STILL EMPTY"*)
    ok "the contract says a STILL EMPTY materialisation is not the end of the run" ;;
  *) fail "the plugin contract section does not tell a run what to do when materialisation populates nothing" ;;
esac
# (c) HEAD == pin does not establish CONTENT. Handed an already-populated submodule the helper
# repairs isolation in place and refuses `git submodule update`, so a modified tracked definition
# survives with HEAD still at the pin — the revision assertion passes over unreviewed instructions.
# Bound to the same path as the revision read so the two cannot drift apart.
case "${section}" in
  *"git -C libraries/agent-plugins status --porcelain"*)
    ok "the contract asserts the materialised tree is clean, not just its revision" ;;
  *) fail "the plugin contract section does not require the materialised submodule tree to be clean" ;;
esac
# status alone is blind to assume-unchanged/skip-worktree, which is how a foreign edit hides from it
# — the same hidden-index hole the Git-safety contract already closes for checkout.
case "${section}" in
  *"ls-files -v"*)
    ok "the contract closes the hidden-index hole in that cleanliness check" ;;
  *) fail "the plugin contract section does not close the hidden-index hole in its cleanliness check" ;;
esac

# ── 12. The prose must pin the OUTCOME, not merely name the tool ──────────────
# CodeRabbit on monorepo#2855: naming `STILL EMPTY`, `status --porcelain` and `ls-files -v` proves
# only that the document mentions them — not that STILL EMPTY routes to the forge read, nor that the
# status output is required to be EMPTY. A contract that names a command without its required outcome
# is the same "named but not executable" gap section 10 exists to close, one level down.
#
# Patterns below are SINGLE-quoted: they contain `$(` and `${`, which inside a double-quoted case
# pattern would be command-substituted / expanded, silently changing what is matched.
#
# Split around the git-level flag slot for the reason given at the pin-source assertion above: the
# section's pin line carries `--no-replace-objects` between `git` and `rev-parse`, and each of the
# two segments occurs exactly once in the section, so the split cannot be satisfied vacuously.
case "${section}" in
  *'pin=$(git '*'rev-parse HEAD:libraries/agent-plugins)'*)
    ok "the contract BINDS the resolved pin to a variable" ;;
  *) fail "the plugin contract section does not bind the resolved pin to a variable" ;;
esac
# The bind is only worth anything if the forge request consumes it — a resolved-then-retyped revision
# is exactly the wrong-revision read this section exists to stop.
case "${section}" in
  *'?ref=${pin}'*)
    ok "the forge read consumes the pin that was just resolved" ;;
  *) fail "the plugin contract section does not pass the resolved pin to the forge read" ;;
esac
# Ordering matters: the pin must be resolved BEFORE it is consumed, or the documented sequence cannot
# be executed top-to-bottom as written.
case "${section}" in
  *'pin=$(git '*'rev-parse HEAD:libraries/agent-plugins)'*'?ref=${pin}'*)
    ok "the pin is resolved before the forge read consumes it" ;;
  *) fail "the plugin contract section resolves the pin after the forge read that consumes it" ;;
esac
case "${section}" in
  *"fall back to the forge read"*)
    ok "STILL EMPTY routes to the forge read rather than ending the run" ;;
  *) fail "the plugin contract section does not route a STILL EMPTY materialisation to the forge read" ;;
esac
case "${section}" in
  *"must print nothing"*)
    ok "the cleanliness check pins its required outcome, not just its command" ;;
  *) fail "the plugin contract section does not require the cleanliness check to print nothing" ;;
esac

# ── 13. The byte check must FAIL CLOSED, not merely exist ────────────────────
# CodeRabbit on monorepo#2855 (🟠 Major, verified on fixtures): the byte-comparison loop is the one
# assertion that survives a clean/smudge filter, so a hole in IT has no backstop. Three failure paths
# made the naive form report success on a check that never ran, and the emptiest evidence produced
# the strongest-looking result:
#   (a) piping `ls-tree` into the loop takes the WHILE's status, so an enumeration failure runs the
#       body zero times and prints nothing — identical output to a verified tree;
#   (b) in an UNINITIALISED submodule every git call fails, so `want` and `got` are BOTH empty and
#       `[ "$want" = "$got" ]` compares EQUAL — and an empty submodule is precisely the state this
#       fallback is reached in;
#   (c) `ls-tree` without `--no-replace-objects` enumerates a replaced tree while the lookups beside
#       it do not, spanning two object namespaces inside one comparison.
# Each assertion below pins the OUTCOME (a marker is emitted / a value is rejected), per section 12.
case "${section}" in
  *'--no-replace-objects ls-tree -r --name-only HEAD'*)
    ok "the byte check enumerates in the same object namespace it compares in" ;;
  *) fail "the byte check's ls-tree does not carry --no-replace-objects (two object namespaces)" ;;
esac
# Matched contiguously ON PURPOSE: the flag appears three times in this section, so a split pattern
# would be satisfied by the pin line's occurrence even if ls-tree lost the flag entirely.
case "${section}" in
  *'BYTES-UNKNOWN <enumeration failed>'*)
    ok "an enumeration failure is reported rather than read as no-differences" ;;
  *) fail "the byte check does not report an enumeration failure (silent pass on a check that never ran)" ;;
esac
case "${section}" in
  *'[ -n "$want" ] && [ -n "$got" ]'*)
    ok "the byte check rejects empty hashes instead of comparing them equal" ;;
  *) fail "the byte check does not reject empty hashes (two failed lookups would compare EQUAL)" ;;
esac
# The markers are worthless if the prose still says only a DIFFER means trouble.
case "${section}" in
  *"unproven is not proven"*)
    ok "the contract counts BYTES-UNKNOWN as a failure, not as a pass" ;;
  *) fail "the contract does not say an unverifiable byte check fails closed" ;;
esac
# Command substitution strips the trailing newline, so a bare `printf '%s'` makes `read` return false
# on the final entry and drops the LAST file from the sweep unchecked — a silent partial verification.
case "${section}" in
  *"printf '%s\\n' \"\$files\""*)
    ok "the byte check sweeps every file, including the last" ;;
  *) fail "the byte check drops its last entry (printf without a trailing newline)" ;;
esac


# ── 7q. The PIN ITSELF must be resolved without replacement objects ───────────
# Every other case passes --gitlink explicitly, so nothing exercised the `ls-tree HEAD` resolution
# that every real caller uses. AGENTS.md requires --no-replace-objects there: a refs/replace entry
# for HEAD makes ls-tree read the REPLACEMENT's gitlink while `rev-parse HEAD` still prints the
# expected commit, so the run compares against a pin nobody reviewed. Asserted in the fail-OPEN
# direction — without the flag this reports CURRENT, which is the dangerous verdict.
rc_root="${tmp}/replace-consumer"
mkdir -p "${rc_root}/libraries"
cp -R "${pin_repo}" "${rc_root}/libraries/agent-plugins"
write_desired_state_fixture "${rc_root}"
git -C "${rc_root}" init -q
git -C "${rc_root}" config user.email t@example.com
git -C "${rc_root}" config user.name t
git -C "${rc_root}" update-index --add --cacheinfo "160000,${gitlink},libraries/agent-plugins"
git -C "${rc_root}" -c commit.gpgsign=false commit -qm true-pin
rc_true="$(git -C "${rc_root}" rev-parse HEAD)"
# A decoy commit carrying a DIFFERENT gitlink, built on a side branch so HEAD never moves by reset.
git -C "${rc_root}" checkout -q -b decoy
git -C "${rc_root}" update-index --add --cacheinfo "160000,${cursor_drift},libraries/agent-plugins"
git -C "${rc_root}" -c commit.gpgsign=false commit -qm decoy-pin
rc_decoy="$(git -C "${rc_root}" rev-parse HEAD)"
git -C "${rc_root}" checkout -q -
git -C "${rc_root}" replace "${rc_true}" "${rc_decoy}"
# The loader ref matches the DECOY's gitlink, so a replacement-poisoned read sees them as equal.
git -C "${rc_root}/libraries/agent-plugins" update-ref refs/remotes/origin/main "${cursor_drift}"
set +e
out="$("${script}" --runtime cursor --repo-root "${rc_root}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "a replace-poisoned pin must still report DRIFT (exit 1), got ${rc}: ${out}"
case "${out}" in
  *"${gitlink}"*) ok "the pin is resolved without replacement objects" ;;
  *) fail "the pin was read through refs/replace — reported the decoy gitlink: ${out}" ;;
esac

# ── 7r. Codex enablement is an EFFECTIVE-STATE question, not a line match ─────
# Codex loads `enabled = true # keep enabled` as enabled. An exact-line regex rejects the trailing
# comment and exits UNKNOWN before inspecting the cache, so a correctly-configured lane reports that
# it cannot be checked.
cat > "${codex_home}/config.toml" <<'TOML'
[plugins."agentic-engineering@devantler-plugins"]
enabled = true # keep this lane enabled
TOML
set +e
out="$(CODEX_SHIM_MODE=unavailable "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 0 ] || fail "a trailing TOML comment must stay enabled (exit 0), got ${rc}: ${out}"
case "${out}" in
  *CURRENT*) ok "Codex enablement tolerates a valid trailing TOML comment" ;;
  *) fail "commented-but-enabled Codex config did not report CURRENT: ${out}" ;;
esac
cat > "${codex_home}/config.toml" <<'TOML'
[plugins."agentic-engineering@devantler-plugins"]
enabled = true
TOML

# ── 7r-bis. The tolerance must cover the TABLE HEADER, not only the value line ─
# TOML permits a comment after a table expression, and Codex loads the plugin regardless. 7r proves
# the value line tolerates one; the header comparison is a separate exact-equality test, so a lane
# configured this way is enabled in Codex while this check dies UNKNOWN before it ever reads the
# cache — the check silently stops covering a healthy lane rather than reporting on it.
cat > "${codex_home}/config.toml" <<'TOML'
[plugins."agentic-engineering@devantler-plugins"] # managed plugin
enabled = true
TOML
set +e
out="$(CODEX_SHIM_MODE=unavailable "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 0 ] || fail "a commented table header must stay enabled (exit 0), got ${rc}: ${out}"
case "${out}" in
  *CURRENT*) ok "Codex enablement tolerates a comment after the table header" ;;
  *) fail "commented-header Codex config did not report CURRENT: ${out}" ;;
esac
# A comment must never make a DISABLED lane read as enabled: the tolerance is about the header's
# trailing comment only, never about the value it introduces.
cat > "${codex_home}/config.toml" <<'TOML'
[plugins."agentic-engineering@devantler-plugins"] # managed plugin
enabled = false
TOML
set +e
out="$(CODEX_SHIM_MODE=unavailable "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "a commented header with enabled=false must stay UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"not enabled"*) ok "a commented header does not enable a disabled Codex plugin" ;;
  *) fail "commented-header disabled config was not reported as not enabled: ${out}" ;;
esac
cat > "${codex_home}/config.toml" <<'TOML'
[plugins."agentic-engineering@devantler-plugins"]
enabled = true
TOML

# ── 7s. Codex drift must not be sent to a Claude-only remediation ─────────────
# `codex plugin` exposes add/list/marketplace/remove and no update command, so telling a Codex
# operator to use the /plugin marketplace update flow prescribes an action that cannot repair this
# lane — and may refresh the sibling Claude installation instead.
printf 'stale under codex remediation\n' > "${codex_install}/agents/agent-improver.agent.md"
set +e
out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "codex drift must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"/plugin marketplace update"*)
    fail "Codex drift prescribes the Claude-only /plugin update flow: ${out}" ;;
  *) ok "Codex drift is not routed to the Claude /plugin update flow" ;;
esac
case "${out}" in
  *"codex plugin"*) ok "Codex drift names a codex-specific control-plane action" ;;
  *) fail "Codex drift names no codex-specific remediation: ${out}" ;;
esac
cp "${p}/agents/agent-improver.agent.md" "${codex_install}/agents/agent-improver.agent.md"

# ── 7t. A replace ref INSIDE the submodule defeats a revision comparison ──────
# The Cursor loader reads content with a plain `git show <ref>:<path>`, which resolves THROUGH
# refs/replace. So a replacement inside the submodule changes the bytes it loads while leaving BOTH
# compared revisions identical — `--no-replace-objects rev-parse` still returns the original commit.
# A revision equality check therefore cannot establish the loaded content and must refuse a verdict.
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
printf 'UNREVIEWED replacement content\n' > "${p}/README.md"
git -C "${pin_repo}" add plugins/agentic-engineering/README.md
git -C "${pin_repo}" -c commit.gpgsign=false commit -qm replacement-payload
sub_replacement="$(git -C "${pin_repo}" rev-parse HEAD)"
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
git -C "${pin_repo}" replace "${gitlink}" "${sub_replacement}"
set +e
out="$("${script}" --runtime cursor --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "a replace ref inside the submodule must be UNKNOWN (exit 2), got ${rc}: ${out}"
case "${out}" in
  *UNKNOWN*"refs/replace/"*) ok "a submodule replace ref refuses a verdict instead of reporting CURRENT" ;;
  *) fail "submodule replace ref did not name the replacement refs: ${out}" ;;
esac
# The same UNKNOWN must remain visible under --quiet: say() is suppressed, so the reason has to
# travel on stderr (every other UNKNOWN path already does via die()).
set +e
quiet_out="$("${script}" --runtime cursor --quiet --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; quiet_rc=$?
set -e
[ "${quiet_rc}" -eq 2 ] \
  || fail "a replace ref under --quiet must still be UNKNOWN (exit 2), got ${quiet_rc}: ${quiet_out}"
case "${quiet_out}" in
  *UNKNOWN*"refs/replace/"*)
    ok "a submodule replace ref names the replacement refs even under --quiet" ;;
  *) fail "submodule replace ref under --quiet hid the UNKNOWN reason: ${quiet_out}" ;;
esac
git -C "${pin_repo}" replace -d "${gitlink}"
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
# Put the shared pin fixture back: this case advanced HEAD and left unreviewed README bytes.
git -C "${pin_repo}" switch --detach --quiet "${gitlink}"
[ "$(git -C "${pin_repo}" rev-parse HEAD)" = "${gitlink}" ] \
  || fail "the submodule replace case did not restore the shared pin fixture HEAD"
[ -z "$(git -C "${pin_repo}" status --porcelain)" ] \
  || fail "the submodule replace case left the shared pin fixture dirty"

# ── 7ab. The replacement NAMESPACE is configurable, so a hard-coded scan misses it ─────
# GIT_REPLACE_REF_BASE moves Git's effective replacement namespace off refs/replace/. A scan
# hard-coded to refs/replace/* then returns nothing while the loader's plain `git show` still
# resolves through the replacement — so the branch proceeds to a revision comparison, which
# --no-replace-objects answers with the pin, and reports CURRENT over unreviewed bytes. The
# enumeration has to follow the namespace Git is actually honouring, not the default one.
git -C "${pin_repo}" update-ref "refs/evil/${gitlink}" "${sub_replacement}"
set +e
out="$(GIT_REPLACE_REF_BASE=refs/evil/ "${script}" --runtime cursor \
        --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] \
  || fail "a replacement in a configured namespace must be UNKNOWN (exit 2), got ${rc}: ${out}"
case "${out}" in
  *UNKNOWN*"refs/evil/"*)
    ok "a configured replacement namespace refuses a verdict instead of reporting CURRENT" ;;
  *) fail "the configured replacement namespace was not enumerated: ${out}" ;;
esac
git -C "${pin_repo}" update-ref -d "refs/evil/${gitlink}"
[ -z "$(git -C "${pin_repo}" status --porcelain)" ] \
  || fail "the configured-namespace case left the shared pin fixture dirty"

# ── 7v. A replace ref must not be able to REDEFINE the pinned tree ────────────
# 7q proves the PIN ITSELF is resolved without replacement objects, and 7t refuses a verdict for
# Cursor, whose loader reads through refs/replace. Neither covers the read every OTHER runtime
# makes: the pinned TREE is read with `cat-file`/`ls-tree`, which also resolve THROUGH refs/replace.
# A replacement therefore rewrites the REVIEWED side of the comparison itself, so an install
# carrying the unreviewed replacement bytes matches it and reports CURRENT. That is a fail-open on
# the one value everything downstream trusts, and it is reachable from the machine-local runtimes.
printf 'UNREVIEWED replacement definition\n' > "${p}/agents/agent-improver.agent.md"
git -C "${pin_repo}" add plugins/agentic-engineering/agents/agent-improver.agent.md
git -C "${pin_repo}" -c commit.gpgsign=false commit -qm tree-replacement-payload
tree_replacement="$(git -C "${pin_repo}" rev-parse HEAD)"
git -C "${pin_repo}" replace "${gitlink}" "${tree_replacement}"
repl_install="${tmp}/install-replacement"
make_install "${repl_install}"
add_runtime_asset_fixture "${repl_install}"
printf 'UNREVIEWED replacement definition\n' > "${repl_install}/agents/agent-improver.agent.md"
set +e
out="$(run "${repl_install}")"; rc=$?
set -e
[ "${rc}" -ne 0 ] \
  || fail "an install matching REPLACEMENT bytes reported CURRENT — the pinned tree was read through refs/replace: ${out}"
case "${out}" in
  *DRIFT*agent-improver*)
    ok "a replace ref cannot redefine the pinned tree — the install is compared against the reviewed bytes" ;;
  *) fail "expected DRIFT naming agent-improver against the reviewed pin, got rc=${rc}: ${out}" ;;
esac
git -C "${pin_repo}" replace -d "${gitlink}"
# Put the shared pin fixture back: this case advanced HEAD and left unreviewed definition bytes.
git -C "${pin_repo}" switch --detach --quiet "${gitlink}"
[ "$(git -C "${pin_repo}" rev-parse HEAD)" = "${gitlink}" ] \
  || fail "the pinned-tree replace case did not restore the shared pin fixture HEAD"
[ -z "$(git -C "${pin_repo}" status --porcelain)" ] \
  || fail "the pinned-tree replace case left the shared pin fixture dirty"

# ── 7u. The Codex reinstall must be gated on the pin ──────────────────────────
# `codex plugin add` installs the marketplace snapshot's LATEST. Prescribing a bare
# `marketplace upgrade` + `remove && add` therefore tells an operator to install whatever the tip is,
# which is the same hazard the Claude refresh path is explicitly gated against.
printf 'stale under codex pin gate\n' > "${codex_install}/agents/agent-improver.agent.md"
set +e
out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "codex drift must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"Check the snapshot's revision"*"${gitlink}"*)
    ok "the Codex reinstall is gated on the pinned revision" ;;
  *) fail "Codex remediation prescribes a reinstall without a pin gate: ${out}" ;;
esac
case "${out}" in
  *"snapshot NOT at the pin"*) ok "the Codex remediation says what to do when the snapshot is not at the pin" ;;
  *) fail "Codex remediation does not cover a snapshot ahead of the pin: ${out}" ;;
esac
cp "${p}/agents/agent-improver.agent.md" "${codex_install}/agents/agent-improver.agent.md"

# ── 7v. An empty effective result means NOT LOADED, never "ask the static table" ──
# Codex's plugin feature can be off while this plugin's table entry and cached copy both remain
# present. `codex plugin list --json` then correctly returns an empty `installed` array. Treating
# that as "no answer" and falling back to the config would report CURRENT for a definition the
# runtime never loaded — the config still says enabled = true.
set +e
out="$(CODEX_SHIM_MODE=feature-off "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "an unloaded Codex plugin must exit 2, got ${rc}: ${out}"
case "${out}" in
  *"not enabled"*) ok "an empty effective result is disabled, not a fallback to the static table" ;;
  *) fail "unloaded Codex plugin did not name the reason: ${out}" ;;
esac

# The fallback still exists for the case it is actually for: the CLI could not answer at all.
set +e
out="$(CODEX_SHIM_MODE=unavailable "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 0 ] || fail "an unavailable CLI must fall back to the config (exit 0), got ${rc}: ${out}"
case "${out}" in
  *CURRENT*) ok "the config fallback is reserved for a CLI that could not answer" ;;
  *) fail "CLI-unavailable fallback did not report CURRENT: ${out}" ;;
esac

# The fallback has to preserve the runtime's GLOBAL plugin feature gate too. A stale per-plugin
# table and cache can remain after `[features] plugins = false`; reading only the table would report
# CURRENT for a definition Codex cannot load whenever the CLI is unavailable.
cat > "${codex_home}/config.toml" <<'TOML'
[features]
plugins = false

[plugins."agentic-engineering@devantler-plugins"]
enabled = true
TOML
set +e
out="$(CODEX_SHIM_MODE=unavailable "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] \
  || fail "a globally disabled Codex plugin must stay UNKNOWN in config fallback, got ${rc}: ${out}"
case "${out}" in
  *"not enabled"*) ok "the config fallback honours the global Codex plugin feature gate" ;;
  *) fail "global Codex plugin disablement did not name the reason: ${out}" ;;
esac

# TOML permits whitespace inside table brackets. This is the same global feature table, not an
# unknown section; missing it lets the later enabled plugin table manufacture CURRENT.
cat > "${codex_home}/config.toml" <<'TOML'
[ features ] # global gates
plugins = false

[plugins."agentic-engineering@devantler-plugins"]
enabled = true
TOML
set +e
out="$(CODEX_SHIM_MODE=unavailable "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] \
  || fail "a spaced global feature table must stay UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"not enabled"*) ok "the config fallback honours whitespace in the global feature header" ;;
  *) fail "spaced global feature header did not name the disabled reason: ${out}" ;;
esac

# TOML's dotted-key spelling is the same effective global gate. Codex itself documents
# `features.<name>=false` for CLI overrides, so the static fallback must not treat this valid form as
# an unrelated top-level key and then trust the stale enabled plugin table below it.
cat > "${codex_home}/config.toml" <<'TOML'
features.plugins = false

[plugins."agentic-engineering@devantler-plugins"]
enabled = true
TOML
set +e
out="$(CODEX_SHIM_MODE=unavailable "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] \
  || fail "a dotted globally disabled Codex plugin must stay UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"not enabled"*) ok "the config fallback honours the dotted global Codex plugin feature gate" ;;
  *) fail "dotted global Codex plugin disablement did not name the reason: ${out}" ;;
esac

# Every dotted TOML key segment may be quoted. These spellings resolve to the same effective
# `features.plugins = false` value and must not let the stale enabled plugin table manufacture a
# CURRENT verdict when the runtime CLI is unavailable.
for dotted_gate in '"features".plugins = false' 'features."plugins" = false' \
                   "'features'.plugins = false" "features.'plugins' = false"; do
  printf '%s\n\n%s\n%s\n' "${dotted_gate}" \
    '[plugins."agentic-engineering@devantler-plugins"]' 'enabled = true' \
    > "${codex_home}/config.toml"
  set +e
  out="$(CODEX_SHIM_MODE=unavailable "${script}" --runtime codex --codex-home "${codex_home}" \
                    --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
  set -e
  [ "${rc}" -eq 2 ] \
    || fail "quoted dotted gate '${dotted_gate}' must stay UNKNOWN, got ${rc}: ${out}"
done
ok "the config fallback honours quoted dotted global feature keys"
cat > "${codex_home}/config.toml" <<'TOML'
[plugins."agentic-engineering@devantler-plugins"]
enabled = true
TOML

# ── 7w. The Codex remediation must never advance the snapshot before installing ──
# `marketplace upgrade` moves the snapshot to the upstream tip, so a precondition checked BEFORE it
# is invalidated by it: a following `add` installs a revision nobody reviewed.
printf 'stale under snapshot-advance check\n' > "${codex_install}/agents/agent-improver.agent.md"
set +e
out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "codex drift must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"do NOT run"*"marketplace upgrade"*)
    ok "the Codex remediation forbids advancing the snapshot before installing" ;;
  *) fail "Codex remediation still prescribes upgrade-then-install: ${out}" ;;
esac
case "${out}" in
  *"reinstall WITHOUT upgrading"*)
    ok "the at-the-pin path reinstalls without advancing the snapshot" ;;
  *) fail "Codex remediation has no snapshot-preserving path: ${out}" ;;
esac
cp "${p}/agents/agent-improver.agent.md" "${codex_install}/agents/agent-improver.agent.md"

# ── 7y. The at-the-pin reinstall must verify BYTES, not just the revision ──────
# A revision equality is a claim about the commit id, never about the working-tree content. A dirty
# file, a clean/smudge filter, or a replacement object all leave `rev-parse` reporting the pinned
# revision while the bytes on disk differ — so a revision-only precondition hands `add` a snapshot
# carrying unreviewed definitions and reports the reinstall as safe. This is the same four-assertion
# doctrine the consumer contract already requires when reading a definition at the pin.
printf 'stale under snapshot-bytes check\n' > "${codex_install}/agents/agent-improver.agent.md"
set +e
out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "codex drift must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"EVERY definition file"*)
    ok "the at-the-pin path verifies every definition byte, not just the revision" ;;
  *) fail "Codex remediation gates the reinstall on the revision alone: ${out}" ;;
esac
case "${out}" in
  *"status --porcelain"*)
    ok "the at-the-pin path also requires a clean snapshot tree" ;;
  *) fail "Codex remediation does not require a clean snapshot tree: ${out}" ;;
esac
case "${out}" in
  *"--no-replace-objects rev-parse HEAD:<f>"*)
    ok "snapshot expected-blob reads bypass replacement objects" ;;
  *) fail "Codex remediation reads expected snapshot blobs through replacements: ${out}" ;;
esac
case "${out}" in
  *"ls-tree HEAD -- <runtime-asset>"*"test -x <snapshot>/<runtime-asset>"*)
    ok "snapshot verification checks executable runtime-asset modes" ;;
  *) fail "Codex remediation can reinstall a non-executable required helper: ${out}" ;;
esac
cp "${p}/agents/agent-improver.agent.md" "${codex_install}/agents/agent-improver.agent.md"

# ── 7z. The reinstall must not delete the working plugin before it can restore ──
# `codex plugin remove` deletes the plugin from local config AND cache. Prescribing `remove && add`
# means a failed `add` — bad snapshot, disk error, interrupted run — leaves the lane with no
# definition to load and no way to self-repair, turning a drift report into an outage. The ordering
# must not depend on `add` being idempotent over an existing install, which the CLI does not
# document.
printf 'stale under destructive-order check\n' > "${codex_install}/agents/agent-improver.agent.md"
set +e
out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "codex drift must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"config entry"*)
    ok "the reinstall preserves the config entry the removal deletes" ;;
  *) fail "Codex remediation removes the only copy with no backup: ${out}" ;;
esac
case "${out}" in
  *"rather than editing the cache"*)
    ok "a failed add is an outage to surface, never a hand-restored cache" ;;
  *) fail "Codex remediation has no recovery for a failed add: ${out}" ;;
esac
cp "${p}/agents/agent-improver.agent.md" "${codex_install}/agents/agent-improver.agent.md"

# ── 7aa. A CURRENT verdict must not be read as "this process is current" ───────
# The check inspects the INSTALLED copy on disk. The running process executes whatever it loaded at
# startup, and a refresh needs a restart to take effect — so a CURRENT verdict produced after a
# concurrent refresh says nothing about the definition this process is still executing. Leaving that
# unstated is the fail-open direction: the run reports itself current while following a superseded
# definition.
set +e
out="$(CODEX_SHIM_MODE=unavailable "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 0 ] || fail "the CURRENT case must exit 0, got ${rc}: ${out}"
case "${out}" in
  *"booted"*)
    ok "a CURRENT verdict states that it describes the install, not the booted definition" ;;
  *) fail "CURRENT verdict does not distinguish the install from the booted copy: ${out}" ;;
esac

# ── 7x. The test script itself must stay executable ───────────────────────────
# It carries a shebang and is invoked directly by local callers; CI happening to run it through
# `bash` masks a lost mode bit, so assert the bit rather than relying on the runner.
if [ -x "${script%/*}/plugin-definition-currency.test.sh" ]; then
  ok "the test script keeps its executable bit"
else
  fail "the test script lost its executable bit (mode must stay 100755)"
fi
echo "plugin-definition-currency: ${pass_count} assertions passed"
