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
constitution="${repo_root}/.claude/guides/definition-and-plugin.md"
portable_loader="${repo_root}/.claude/loaders/portable-agentic-engineer.md"

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
[ -r "${portable_loader}" ] || fail "cannot read ${portable_loader}"

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

# The source backend is selected explicitly and must not imply a runtime-loaded attestation.
if out="$("${script}" --runtime git-ref --loaded-ref "${gitlink}" \
                      --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; then
  case "${out}" in
    *"CURRENT"*"source parity only"*"does not attest the loaded session"*)
      ok "the generic selector checks an explicit commit and labels its limited evidence" ;;
    *) fail "matching source check overstated or omitted its evidence boundary: ${out}" ;;
  esac
else
  fail "generic git-ref selector must accept a pinned commit, got $? — ${out}"
fi

for invalid_ref in '' origin/main --help; do
  set +e
  out="$("${script}" --runtime git-ref --loaded-ref "${invalid_ref}" \
                     --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
  set -e
  [ "${rc}" -eq 2 ] || fail "missing or ambiguous source ref must be UNKNOWN, got ${rc}: ${out}"
  case "${out}" in
    *"requires --loaded-ref"*|*"fully qualified ref or full commit ID"*)
      ok "missing, ambiguous, or option-shaped source ref is rejected" ;;
    *) fail "invalid source ref was rejected for an unrelated reason: ${out}" ;;
  esac
done
set +e
out="$("${script}" --runtime git-ref --repo-root "${tmp}/consumer" \
                   --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "omitted source ref must be UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"requires --loaded-ref"*) ok "the source backend never assumes a default ref" ;;
  *) fail "omitted source ref was not diagnosed: ${out}" ;;
esac
set +e
out="$("${script}" --runtime claude --loaded-ref "${gitlink}" \
                   --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "installed backend must reject source-ref evidence, got ${rc}: ${out}"
case "${out}" in
  *"only valid with --runtime git-ref"*) ok "a source ref cannot substitute for installed-state evidence" ;;
  *) fail "source ref on installed backend was rejected for an unrelated reason: ${out}" ;;
esac

for obsolete_runtime in cursor antigravity; do
  set +e
  out="$("${script}" --runtime "${obsolete_runtime}" --repo-root "${tmp}/consumer" \
                     --gitlink "${gitlink}" 2>&1)"; rc=$?
  set -e
  [ "${rc}" -eq 2 ] || fail "obsolete runtime selector must be UNKNOWN, got ${rc}: ${out}"
  case "${out}" in
    *"unsupported runtime"*) ok "obsolete runtime selector is rejected" ;;
    *) fail "obsolete runtime selector did not name the unsupported selector: ${out}" ;;
  esac
done
set +e
out="$("${script}" --cursor-ref "${gitlink}" --repo-root "${tmp}/consumer" \
                   --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "obsolete ref option must be UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"unknown argument"*) ok "obsolete ref option is rejected" ;;
  *) fail "obsolete ref option was not rejected as an unknown argument: ${out}" ;;
esac

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

# ── 7a. An EMPTY submodule directory is not the submodule ─────────────────────
# A fresh worktree has the directory but nothing in it, and `git -C` there answers from the consumer
# repository around it. When that repository holds the pinned commit, a check that trusted the
# directory read the consumer's objects with the wrong path prefix and found no files at all. It
# must take the forge route instead; with no .gitmodules here that route stops before the network.
shadow="${tmp}/shadow"
git init -q "${shadow}"
write_desired_state_fixture "${shadow}"
mkdir -p "${shadow}/libraries/agent-plugins"
git -C "${shadow}" fetch -q "${pin_repo}" "${gitlink}"
git -C "${shadow}" cat-file -e "${gitlink}^{commit}" \
  || fail "fixture: the consumer repository does not hold the pinned commit, so this case proves nothing"
set +e; out="$("${script}" --repo-root "${shadow}" --installed "${cur}" --gitlink "${gitlink}" 2>&1)"; rc=$?; set -e
[ "${rc}" -eq 2 ] || fail "an empty submodule directory with no forge route must exit 2, got ${rc}: ${out}"
case "${out}" in
  *"yielded no tree entries"*)
    fail "an empty submodule directory was read through the consumer repository: ${out}" ;;
  *"no .gitmodules url"*) ok "an empty submodule directory takes the forge route, not the consumer repository's objects" ;;
  *) fail "an empty submodule directory exited 2 for an unrelated reason: ${out}" ;;
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
for flag in --runtime --repo-root --gitlink --adopted-ref --remote --installed --plugins-root --codex-home --loaded-ref; do
  set +e; out="$("${script}" "${flag}" 2>&1)"; rc=$?; set -e
  [ "${rc}" -eq 2 ] || fail "a missing value for ${flag} must exit 2, got ${rc}: ${out}"
done
ok "a missing option value exits 2, never 1 (DRIFT)"

# Header growth must not silently truncate --help. A fixed line range did exactly that when the
# runtime selector expanded Usage, dropping part of the exit-code contract from operator output.
out="$("${script}" --help)" || fail "--help must exit 0"
case "${out}" in
  *"--runtime claude|codex|git-ref"*"collapsing them is how a currency check becomes decoration"*)
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

# The forge branch receives decoded JSON paths, then @tsv escapes tabs/newlines/backslashes. Without
# a pre-serialization rejection, an actual tab in the reviewed path collides with a literal `\t` in
# the installed path and can report CURRENT for different filenames.
cat > "${shim}/gh" <<'SHIM'
#!/bin/sh
cat "${FORGE_TREE_FIXTURE:?}"
SHIM
chmod +x "${shim}/gh"
forge_install="${tmp}/install-forge-escaped"
mkdir -p "${forge_install}/agents" "${forge_install}/scripts"
printf 'reviewed engineer definition\n' > "${forge_install}/agents/agentic-engineer.agent.md"
printf 'escaped collision bytes\n' > "${forge_install}/agents/a\\tb"
cp "${p}/scripts/classify-default-branch-ci-runs.sh" "${forge_install}/scripts/"
ordinary_sha="$(git hash-object --no-filters "${forge_install}/agents/agentic-engineer.agent.md")"
escaped_sha="$(git hash-object --no-filters "${forge_install}/agents/a\\tb")"
runtime_sha="$(git hash-object --no-filters "${forge_install}/scripts/classify-default-branch-ci-runs.sh")"
forge_tree_fixture="${tmp}/forge-escaped-tree.json"
jq -n --arg ordinary "${ordinary_sha}" --arg escaped "${escaped_sha}" --arg runtime "${runtime_sha}" '
  {truncated:false,tree:[
    {type:"blob",mode:"100644",sha:$ordinary,
     path:"plugins/agentic-engineering/agents/agentic-engineer.agent.md"},
    {type:"blob",mode:"100644",sha:$escaped,
     path:"plugins/agentic-engineering/agents/a\tb"},
    {type:"blob",mode:"100755",sha:$runtime,
     path:"plugins/agentic-engineering/scripts/classify-default-branch-ci-runs.sh"}
  ]}' > "${forge_tree_fixture}"
set +e
out="$(FORGE_TREE_FIXTURE="${forge_tree_fixture}" PATH="${shim}:${PATH}" "${script}" \
        --repo-root "${tmp}/trunc" --installed "${forge_install}" \
        --gitlink 2222222222222222222222222222222222222222 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "an escape-bearing forge path must be UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"forge tree contains an unsafe path"*) ok "forge paths with TSV-colliding escapes fail closed" ;;
  *) fail "unsafe forge path did not name the serialization reason: ${out}" ;;
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

# ── 7l. The script keeps NO temporary file, so it needs no EXIT trap ──────────
# An EXIT trap that removes one can turn a `set -u` abort into exit 0 on bash 3.2 (monorepo#3414),
# and exit 0 is this script's CURRENT. The installed listing is held in a variable instead, which
# removes that whole class rather than guarding it. Asserted on the source because the property is
# the absence of a construct, which no fixture can exercise.
if grep -Eq '^[[:space:]]*trap .* EXIT|mktemp' "${script}"; then
  fail "the currency check must not create a temporary file or install an EXIT trap"
fi
ok "the script holds no temporary file and installs no EXIT trap"

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
  config-error)
    printf 'failed to load configuration\n' >&2
    exit 1 ;;
esac
SHIMBIN
chmod +x "${codex_shim}/codex"
PATH="${codex_shim}:${PATH}"
export PATH

# Build production-like PATHs missing each structured-query dependency. A shim that exists but exits
# 1 models a runtime/config failure, not an unavailable CLI; every one of these states is UNKNOWN.
path_without_codex=""
old_ifs="${IFS}"
IFS=:
for path_dir in ${PATH}; do
  [ -x "${path_dir}/codex" ] && continue
  path_without_codex="${path_without_codex}${path_without_codex:+:}${path_dir}"
done
IFS="${old_ifs}"
[ -n "${path_without_codex}" ] || fail "could not construct a PATH without codex"
if PATH="${path_without_codex}" command -v codex >/dev/null 2>&1; then
  fail "the no-Codex PATH still resolves codex"
fi
PATH="${path_without_codex}" command -v jq >/dev/null 2>&1 \
  || fail "the no-Codex PATH lost jq"

path_without_jq=""
IFS=:
for path_dir in ${PATH}; do
  [ -x "${path_dir}/jq" ] && continue
  path_without_jq="${path_without_jq}${path_without_jq:+:}${path_dir}"
done
IFS="${old_ifs}"
# On Linux, jq commonly shares /usr/bin with bash and git (and /bin may be a symlink to that same
# directory). Removing jq's directory must not make the script itself unlaunchable or fail its
# earlier git prerequisite, because then this fixture never reaches the jq fail-closed branch.
no_jq_runtime_bin="${tmp}/no-jq-runtime-bin"
mkdir -p "${no_jq_runtime_bin}"
ln -s "$(command -v bash)" "${no_jq_runtime_bin}/bash"
ln -s "$(command -v git)" "${no_jq_runtime_bin}/git"
path_without_jq="${no_jq_runtime_bin}${path_without_jq:+:}${path_without_jq}"
[ -n "${path_without_jq}" ] || fail "could not construct a PATH without jq"
if PATH="${path_without_jq}" command -v jq >/dev/null 2>&1; then
  fail "the no-jq PATH still resolves jq"
fi
PATH="${path_without_jq}" command -v codex >/dev/null 2>&1 \
  || fail "the no-jq PATH lost the Codex shim"

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

# An installed runtime command that rejects the config is authoritative failure evidence, not an
# unavailable CLI. Falling through to the line parser can find a later valid-looking table inside a
# malformed document and report CURRENT even though Codex could not load any effective state.
set +e
out="$(CODEX_SHIM_MODE=config-error "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "a failed Codex runtime-state query must be UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"runtime state query failed"*) ok "a Codex config/runtime error never falls back to static CURRENT" ;;
  *) fail "failed Codex state query did not name the UNKNOWN reason: ${out}" ;;
esac

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

# ── 7n. GIT_REF compares an explicitly declared source revision ───────────────
# A caller may name a fully qualified ref or a full commit ID. This checks source parity only,
# without assuming how any harness loads its definitions or querying another instance's install.
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
if out="$("${script}" --runtime git-ref --loaded-ref refs/remotes/origin/main --repo-root "${tmp}/consumer" \
                      --gitlink "${gitlink}" 2>&1)"; then
  case "${out}" in
    *CURRENT*) ;;
    *) fail "Git-ref matching ref exited 0 without reporting CURRENT: ${out}" ;;
  esac
  case "${out}" in
    *"refs/remotes/origin/main"*) ok "A matching source revision reports CURRENT" ;;
    *) fail "Git-ref matching ref did not name its source ref: ${out}" ;;
  esac
else
  fail "A matching source revision must exit 0, got $? — ${out}"
fi

printf 'newer upstream prose\n' > "${p}/README.md"
git -C "${pin_repo}" add plugins/agentic-engineering/README.md
git -C "${pin_repo}" -c commit.gpgsign=false commit -qm ref-drift
ref_drift="$(git -C "${pin_repo}" rev-parse HEAD)"
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${ref_drift}"
set +e
out="$("${script}" --runtime git-ref --loaded-ref refs/remotes/origin/main --repo-root "${tmp}/consumer" \
                  --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "a drifted source revision must exit 1, got ${rc}: ${out}"
case "${out}" in
  *DRIFT*"${ref_drift}"*"${gitlink}"*) ok "a drifted source revision fires and names both commits" ;;
  *) fail "Source revision drift did not name source and pinned commits: ${out}" ;;
esac

git -C "${pin_repo}" update-ref -d refs/remotes/origin/main
set +e
out="$("${script}" --runtime git-ref --loaded-ref refs/remotes/origin/main --repo-root "${tmp}/consumer" \
                  --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "an unresolved source revision must exit 2, got ${rc}: ${out}"
case "${out}" in
  *"cannot resolve source revision"*) ok "an unresolved source ref is UNKNOWN and names the reason" ;;
  *) fail "missing Git-ref ref did not name the reason: ${out}" ;;
esac

set +e
out="$("${script}" --runtime git-ref --loaded-ref refs/remotes/origin/main --installed "${cur}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "Git-ref with an install override must exit 2, got ${rc}: ${out}"
case "${out}" in
  *"does not accept --installed"*) ok "Git-ref cannot be pointed at another lane's installed copy" ;;
  *) fail "Git-ref install override was rejected without naming the reason: ${out}" ;;
esac

# These cases share the pinned repository with later checks. They must leave both the checkout and
# the source ref exactly as they found them, or a later assertion can inherit Git-ref-case state and
# pass or fail for the wrong reason.
git -C "${pin_repo}" switch --detach --quiet "${gitlink}"
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
[ "$(git -C "${pin_repo}" rev-parse HEAD)" = "${gitlink}" ] \
  || fail "Git-ref cases did not restore the shared pin fixture HEAD"
[ -z "$(git -C "${pin_repo}" status --porcelain)" ] \
  || fail "Git-ref cases left the shared pin fixture dirty"
[ "$(git -C "${pin_repo}" rev-parse refs/remotes/origin/main)" = "${gitlink}" ] \
  || fail "Git-ref cases did not restore the shared source ref"
ok "Git-ref cases restore the shared pin fixture before later checks"

# The source check must resolve an unambiguous ref.
# A tag can legally contain a slash, so a tag named `origin/main` makes the shorthand ambiguous:
# plain `git show origin/main:<path>` then follows the tag while the check follows
# `refs/remotes/origin/main` and can report CURRENT over different bytes.
printf 'UNREVIEWED ambiguous-ref agent\n' > "${p}/agents/agentic-engineer.agent.md"
git -C "${pin_repo}" add plugins/agentic-engineering/agents/agentic-engineer.agent.md
git -C "${pin_repo}" -c commit.gpgsign=false commit -qm ambiguous-loader-ref
ambiguous_loader_commit="$(git -C "${pin_repo}" rev-parse HEAD)"
git -C "${pin_repo}" tag origin/main "${ambiguous_loader_commit}"
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
if out="$("${script}" --runtime git-ref --loaded-ref refs/remotes/origin/main \
                      --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; then
  case "${out}" in
    *CURRENT*"source parity only"*) ok "a shadowing tag cannot change the fully qualified source ref" ;;
    *) fail "qualified source check did not report source parity: ${out}" ;;
  esac
else
  fail "qualified source check followed the shadowing tag, got $? — ${out}"
fi
set +e
out="$("${script}" --runtime git-ref --loaded-ref origin/main \
                   --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "an ambiguous source shorthand must be UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"fully qualified ref or full commit ID"*) ok "an ambiguous source shorthand cannot produce a verdict" ;;
  *) fail "ambiguous source shorthand was rejected for an unrelated reason: ${out}" ;;
esac
git -C "${pin_repo}" tag -d origin/main >/dev/null
git -C "${pin_repo}" switch --detach --quiet "${gitlink}"
[ "$(git -C "${pin_repo}" rev-parse HEAD)" = "${gitlink}" ] \
  || fail "the ambiguous source-ref case did not restore the shared pin fixture HEAD"
[ -z "$(git -C "${pin_repo}" status --porcelain)" ] \
  || fail "ambiguous source-ref case left the shared pin fixture dirty"
ok "the ambiguous source-ref cases restore the shared pin fixture"

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
    /^## Agentic engineering plugin contract$/ { ins = 1; next }
    ins && /^## / { exit }
    ins { print }
  ' "${constitution}" | tr '\n' ' '
)"
[ -n "${section}" ] || fail "could not extract the plugin contract section from the definition-and-plugin guide"

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
# deployed adapter must name itself or another instance can silently inspect the wrong copy.
for runtime in claude codex git-ref; do
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
  *"--loaded-ref"*"source parity"*)
    ok "the contract requires an explicit ref and limits the verdict to source parity" ;;
  *) fail "the plugin contract section does not bound the declared source-ref check" ;;
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
# Most cases pass --gitlink explicitly, which skips the `ls-tree` resolution every real caller uses.
# AGENTS.md requires --no-replace-objects there: a refs/replace entry for the adopted commit makes
# ls-tree read the REPLACEMENT's gitlink while `rev-parse` still prints the expected commit, so the
# run compares against a pin nobody reviewed. Asserted in the fail-OPEN direction — without the flag
# this reports CURRENT, which is the dangerous verdict. The adopted revision is named as a commit so
# the case stays hermetic; section 14 covers reading it from a remote.
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
git -C "${rc_root}" update-index --add --cacheinfo "160000,${ref_drift},libraries/agent-plugins"
git -C "${rc_root}" -c commit.gpgsign=false commit -qm decoy-pin
rc_decoy="$(git -C "${rc_root}" rev-parse HEAD)"
git -C "${rc_root}" checkout -q -
git -C "${rc_root}" replace "${rc_true}" "${rc_decoy}"
# The loader ref matches the DECOY's gitlink, so a replacement-poisoned read sees them as equal.
git -C "${rc_root}/libraries/agent-plugins" update-ref refs/remotes/origin/main "${ref_drift}"
set +e
out="$("${script}" --runtime git-ref --loaded-ref refs/remotes/origin/main --repo-root "${rc_root}" \
                  --adopted-ref "${rc_true}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "a replace-poisoned pin must still report DRIFT (exit 1), got ${rc}: ${out}"
case "${out}" in
  *"${gitlink}"*) ok "the pin is resolved without replacement objects" ;;
  *) fail "the pin was read through refs/replace — reported the decoy gitlink: ${out}" ;;
esac

# ── 7r. Effective Codex state has NO line-oriented TOML fallback ──────────────
# A valid multiline TOML string can contain text that looks exactly like plugin headers and values.
# If the runtime query cannot run, no line parser can distinguish those strings from registration;
# the only safe verdict is UNKNOWN, even when a stale cache and plausible-looking config remain.
cat > "${codex_home}/config.toml" <<'TOML'
decoy = '''
[plugins."agentic-engineering@devantler-plugins"]
enabled = true
'''
TOML
set +e
out="$(PATH="${path_without_codex}" "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "an unavailable Codex query must be UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"codex is required"*) ok "an unavailable Codex query never parses TOML-looking strings" ;;
  *) fail "unavailable Codex query did not name the UNKNOWN reason: ${out}" ;;
esac
set +e
out="$(PATH="${path_without_jq}" "${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "an unavailable Codex JSON parser must be UNKNOWN, got ${rc}: ${out}"
case "${out}" in
  *"jq is required"*) ok "an unavailable JSON parser never falls back to config text" ;;
  *) fail "unavailable Codex JSON parser did not name the UNKNOWN reason: ${out}" ;;
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
# A source reader using plain `git show <ref>:<path>` resolves THROUGH refs/replace.
# A replacement inside the submodule changes the bytes it reads while leaving BOTH
# compared revisions identical — `--no-replace-objects rev-parse` still returns the original commit.
# A revision equality check therefore cannot establish the source bytes and must refuse a verdict.
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
printf 'UNREVIEWED replacement content\n' > "${p}/README.md"
git -C "${pin_repo}" add plugins/agentic-engineering/README.md
git -C "${pin_repo}" -c commit.gpgsign=false commit -qm replacement-payload
sub_replacement="$(git -C "${pin_repo}" rev-parse HEAD)"
git -C "${pin_repo}" update-ref refs/remotes/origin/main "${gitlink}"
git -C "${pin_repo}" replace "${gitlink}" "${sub_replacement}"
set +e
out="$("${script}" --runtime git-ref --loaded-ref refs/remotes/origin/main --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 2 ] || fail "a replace ref inside the submodule must be UNKNOWN (exit 2), got ${rc}: ${out}"
case "${out}" in
  *UNKNOWN*"refs/replace/"*) ok "a submodule replace ref refuses a verdict instead of reporting CURRENT" ;;
  *) fail "submodule replace ref did not name the replacement refs: ${out}" ;;
esac
# The same UNKNOWN must remain visible under --quiet: say() is suppressed, so the reason has to
# travel on stderr (every other UNKNOWN path already does via die()).
set +e
quiet_out="$("${script}" --runtime git-ref --loaded-ref refs/remotes/origin/main --quiet --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; quiet_rc=$?
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
# hard-coded to refs/replace/* then returns nothing while a reader's plain `git show` still
# resolves through the replacement — so the branch proceeds to a revision comparison, which
# --no-replace-objects answers with the pin, and reports CURRENT over unreviewed bytes. The
# enumeration has to follow the namespace Git is actually honouring, not the default one.
git -C "${pin_repo}" update-ref "refs/evil/${gitlink}" "${sub_replacement}"
set +e
out="$(GIT_REPLACE_REF_BASE=refs/evil/ "${script}" --runtime git-ref --loaded-ref refs/remotes/origin/main \
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
# git-ref, where a source reader can follow refs/replace. Neither covers the read every OTHER runtime
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
out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 0 ] || fail "the CURRENT case must exit 0, got ${rc}: ${out}"
case "${out}" in
  *"booted"*)
    ok "a CURRENT verdict states that it describes the install, not the booted definition" ;;
  *) fail "CURRENT verdict does not distinguish the install from the booted copy: ${out}" ;;
esac

# ── 7ab. Ignored loaded files must block a Codex reinstall ────────────────────
# `status --porcelain` deliberately omits ignored untracked files, but the Codex marketplace
# installer copies them from the snapshot. An ignored agent, skill resource, or runtime asset can
# therefore pass a clean-tree gate and become loaded after reinstall unless it is inventoried
# separately across every loaded surface.
printf 'stale under ignored-file check\n' > "${codex_install}/agents/agent-improver.agent.md"
set +e
out="$("${script}" --runtime codex --codex-home "${codex_home}" \
                  --repo-root "${tmp}/consumer" --gitlink "${gitlink}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "codex drift must exit 1, got ${rc}: ${out}"
ignored_scan_command="$(printf '%s\n%s' \
  '         git -C <snapshot> ls-files --others --ignored --exclude-standard -- \' \
  '           <prefix>/agents <prefix>/skills <runtime-asset>        # must print NOTHING')"
case "${out}" in
  *"${ignored_scan_command}"*)
    ok "the Codex reinstall rejects ignored files across every loaded surface" ;;
  *) fail "Codex remediation can reinstall an ignored loaded file: ${out}" ;;
esac
cp "${p}/agents/agent-improver.agent.md" "${codex_install}/agents/agent-improver.agent.md"

# ── 7x. The test script itself must stay executable ───────────────────────────
# It carries a shebang and is invoked directly by local callers; CI happening to run it through
# `bash` masks a lost mode bit, so assert the bit rather than relying on the runner.
if [ -x "${script%/*}/plugin-definition-currency.test.sh" ]; then
  ok "the test script keeps its executable bit"
else
  fail "the test script lost its executable bit (mode must stay 100755)"
fi
# ── 7y. TWO declared runtime assets still produce a verdict (monorepo#2984) ───
# The declaration carried exactly one runtime asset until the pin advanced, so the list the selector
# receives had no newline in it and this path was unreachable. `main` now declares two, and on BSD
# awk a literal newline inside a `-v` assignment is a parse error — so the control that tells a run
# whether it loaded the pinned definition returned exit 2 (UNKNOWN) on the agent host, printing only
# `awk: newline in string ...`. UNKNOWN is never CURRENT, so this is a dead control rather than a
# wrong answer, and nothing about it recovers on its own.
#
# The fixture is SEPARATE from the single-asset pin above on purpose: adding a second asset to that
# one would change the input of every case in this file, and a firing would stop being attributable.
# It is also a stronger claim than "the script does not crash" — a matching install must still be
# reported CURRENT, so a fix that merely stopped reading the list would fail here.
multi_pin="${tmp}/multi/libraries/agent-plugins"
mp="${multi_pin}/plugins/agentic-engineering"
mkdir -p "${mp}/agents" "${mp}/skills/alpha" "${mp}/scripts" \
         "${tmp}/multi/.claude/plugin-consumption"
printf 'reviewed engineer definition\n' > "${mp}/agents/agentic-engineer.agent.md"
printf 'reviewed alpha procedure\n'     > "${mp}/skills/alpha/SKILL.md"
printf '#!/bin/sh\necho classified\n'   > "${mp}/scripts/classify-default-branch-ci-runs.sh"
printf '#!/bin/sh\necho guarded\n'      > "${mp}/scripts/forge-readonly-guard.sh"
chmod +x "${mp}/scripts/classify-default-branch-ci-runs.sh" "${mp}/scripts/forge-readonly-guard.sh"
multi_sha_a="$(shasum -a 256 "${mp}/scripts/classify-default-branch-ci-runs.sh" | awk '{print $1}')"
multi_sha_b="$(shasum -a 256 "${mp}/scripts/forge-readonly-guard.sh" | awk '{print $1}')"
cat > "${tmp}/multi/.claude/plugin-consumption/agentic-engineering.desired-state.json" <<JSON
{
  "spec": {
    "source": {
      "requiredRuntimeAssets": [
        { "path": "scripts/classify-default-branch-ci-runs.sh", "sha256": "${multi_sha_a}", "executable": true },
        { "path": "scripts/forge-readonly-guard.sh", "sha256": "${multi_sha_b}", "executable": true }
      ]
    }
  }
}
JSON
git -C "${multi_pin}" init -q
git -C "${multi_pin}" config user.email t@example.invalid
git -C "${multi_pin}" config user.name t
git -C "${multi_pin}" add -A
git -C "${multi_pin}" -c commit.gpgsign=false commit -qm pin
multi_gitlink="$(git -C "${multi_pin}" rev-parse HEAD)"
multi_install="${tmp}/install-multi"
mkdir -p "${multi_install}"
cp -R "${mp}/agents" "${mp}/skills" "${mp}/scripts" "${multi_install}/"
set +e
out="$("${script}" --repo-root "${tmp}/multi" --gitlink "${multi_gitlink}" \
                   --installed "${multi_install}" 2>&1)"; rc=$?
set -e
case "${rc}:${out}" in
  0:*CURRENT*)
    ok "a two-runtime-asset declaration still yields a verdict, not UNKNOWN" ;;
  2:*)
    fail "two declared runtime assets produced UNKNOWN (exit 2) — the asset list is reaching a \`-v\` assignment that cannot hold a newline: ${out}" ;;
  *)
    fail "two declared runtime assets on a matching install must exit 0 and report CURRENT, got ${rc}: ${out}" ;;
esac

# A verdict alone is not enough: the selector must include every declared asset. Mutating the
# second entry must therefore produce DRIFT and name that asset, or the guard can run successfully
# while silently leaving part of the loaded surface unchecked.
printf '#!/bin/sh\necho tampered\n' > "${multi_install}/scripts/forge-readonly-guard.sh"
chmod +x "${multi_install}/scripts/forge-readonly-guard.sh"
set +e
out="$("${script}" --repo-root "${tmp}/multi" --gitlink "${multi_gitlink}" \
                   --installed "${multi_install}" 2>&1)"; rc=$?
set -e
[ "${rc}" -eq 1 ] \
  || fail "drift in the second declared runtime asset must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT"*"scripts/forge-readonly-guard.sh"*)
    ok "drift in the second declared runtime asset is selected and named" ;;
  *)
    fail "drift in the second declared runtime asset was not named: ${out}" ;;
esac

# ── 14. The verdict is measured against the ADOPTED pin (monorepo#3230) ───────
# The check used to read the pin from the working tree it ran in, and a DRIFT verdict opens a
# lane-drift tracker. Two measured false positives came from that one assumption: a rollout branch
# holding an unmerged bump read DRIFT for a lane byte-identical to the adopted pin (2026-09-06), and
# a checkout taken before a rollout merged read DRIFT for an install already on the live pin
# (2026-09-24). The verdict now uses the pin the default branch records, and the working tree's own
# pin is a separate, named fact that never changes the verdict or the exit status.
#
# `forge` stands in for the remote: the tip of its default branch is what the deployment adopted.
# `work` is a clone of it, and is the working tree the check runs in.
adopt="${tmp}/adopt"
forge="${adopt}/forge"
work="${adopt}/work"
mkdir -p "${forge}"
git -C "${forge}" init -q
git -C "${forge}" symbolic-ref HEAD refs/heads/main
git -C "${forge}" config user.email t@example.invalid
git -C "${forge}" config user.name t
write_desired_state_fixture "${forge}"
git -C "${forge}" add .claude/plugin-consumption/agentic-engineering.desired-state.json
git -C "${forge}" -c commit.gpgsign=false commit -qm 'declare the runtime assets'
# A consumer revision that records NO gitlink, for the unreadable-adopted-pin arm below.
unpinned_commit="$(git -C "${forge}" rev-parse HEAD)"
git -C "${forge}" update-index --add --cacheinfo "160000,${gitlink},libraries/agent-plugins"
git -C "${forge}" -c commit.gpgsign=false commit -qm 'adopt the reviewed pin'
adopted_commit="$(git -C "${forge}" rev-parse HEAD)"

git clone -q "${forge}" "${work}"
git -C "${work}" config user.email t@example.invalid
git -C "${work}" config user.name t
# A clone leaves the submodule path empty, as a fresh worktree does. Give it the plugin's object
# database so the pinned trees are read locally and the suite stays off the network.
rm -rf "${work}/libraries/agent-plugins"
mkdir -p "${work}/libraries"
cp -R "${pin_repo}" "${work}/libraries/agent-plugins"
wsub="${work}/libraries/agent-plugins"
wp="${wsub}/plugins/agentic-engineering"

adopt_run() { "${script}" --repo-root "${work}" "$@" 2>&1; }
assert_no_notice() {
  case "$1" in
    *"ROLLOUT —"*|*"SUPERSEDED —"*|*"UNADOPTED —"*) fail "$2: ${1}" ;;
  esac
}

# 14a. Working tree == adopted. The pin comes from the REMOTE, and the output says so.
if out="$(adopt_run --installed "${cur}")"; then
  case "${out}" in
    *"pinned revision : ${gitlink}"*"pin source      : adopted"*"origin refs/heads/main (${adopted_commit}), read from the remote by this check at ${forge}"*CURRENT*)
      ok "the pin is read from the remote's default branch, and the output names that source and where it is" ;;
    *) fail "the adopted pin's source was not reported: ${out}" ;;
  esac
  assert_no_notice "${out}" "a working tree on the adopted pin must carry no notice"
  ok "a working tree on the adopted pin carries no notice"
else
  fail "an install on the adopted pin must exit 0, got $? — ${out}"
fi
# The arm that must keep firing: a stale install against the adopted pin is still DRIFT.
set +e; out="$(adopt_run --installed "${chg}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a stale install against the adopted pin must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT    agents/agent-improver.agent.md"*"DRIFT — 1 finding(s)"*)
    ok "a stale install against the adopted pin still reads DRIFT" ;;
  *) fail "exit 1 but the stale definition was not named: ${out}" ;;
esac
assert_no_notice "${out}" "a real drift on the adopted pin must not be explained away by a notice"

# 14b. ROLLOUT — the branch proposes a bump that has not merged. The proposed plugin revision changes
# a definition AND adds a runtime asset, and the rollout declares that asset, exactly as a real
# rollout does.
printf 'proposed engineer definition\n' > "${wp}/agents/agentic-engineer.agent.md"
printf '#!/bin/sh\necho guarded\n' > "${wp}/scripts/forge-readonly-guard.sh"
chmod +x "${wp}/scripts/forge-readonly-guard.sh"
git -C "${wsub}" add plugins/agentic-engineering/agents/agentic-engineer.agent.md \
  plugins/agentic-engineering/scripts/forge-readonly-guard.sh
git -C "${wsub}" -c commit.gpgsign=false commit -qm 'proposed plugin revision'
proposed_pin="$(git -C "${wsub}" rev-parse HEAD)"
proposed_install="${tmp}/install-proposed"
mkdir -p "${proposed_install}"
cp -R "${wp}/agents" "${wp}/skills" "${wp}/scripts" "${proposed_install}/"
guard_sha="$(shasum -a 256 "${wp}/scripts/forge-readonly-guard.sh" | awk '{print $1}')"
write_rollout_declaration() {
  cat > "$1/.claude/plugin-consumption/agentic-engineering.desired-state.json" <<JSON
{
  "spec": {
    "source": {
      "requiredRuntimeAssets": [
        { "path": "scripts/classify-default-branch-ci-runs.sh", "sha256": "${fixture_runtime_sha}", "executable": true },
        { "path": "scripts/forge-readonly-guard.sh", "sha256": "${guard_sha}", "executable": true }
      ]
    }
  }
}
JSON
}
git -C "${work}" checkout -q -b claude/rollout
write_rollout_declaration "${work}"
git -C "${work}" add .claude/plugin-consumption/agentic-engineering.desired-state.json
git -C "${work}" update-index --cacheinfo "160000,${proposed_pin},libraries/agent-plugins"
git -C "${work}" -c commit.gpgsign=false commit -qm 'propose a plugin bump'
rollout_commit="$(git -C "${work}" rev-parse HEAD)"

# The fixture must really reproduce the defect, or the assertions after it prove nothing: measured
# against the PROPOSED pin, the same install differs.
set +e; out="$(adopt_run --gitlink "${proposed_pin}" --installed "${cur}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] \
  || fail "control: the install must differ from the proposed pin, got ${rc}: ${out}"
ok "control — measured against the proposed pin, the same install differs"

set +e; out="$(adopt_run --installed "${cur}")"; rc=$?; set -e
case "${rc}" in
  0) ;;
  1) fail "a current install under an unmerged bump read DRIFT — the working tree's pin was used as the basis: ${out}" ;;
  *) fail "a current install under an unmerged bump must exit 0, got ${rc} — the runtime-asset declaration must come from the adopted revision, not the rollout's working tree: ${out}" ;;
esac
case "${out}" in
  *"pinned revision : ${gitlink}"*CURRENT*"ROLLOUT —"*"working tree : ${proposed_pin}"*"adopted      : ${gitlink}"*)
    ok "a current install under an unmerged bump is CURRENT, and the proposal is reported as ROLLOUT" ;;
  *) fail "the rollout was not reported distinctly from the verdict: ${out}" ;;
esac
case "${out}" in
  *"DRIFT"*) fail "a rollout in progress must not print any DRIFT line: ${out}" ;;
  *) ok "a rollout in progress prints no DRIFT signal at all" ;;
esac
# Both facts, distinctly: the verdict's own counts, and the proposal's — measured with the
# declaration the proposal itself carries, which is why the second runtime asset is counted.
case "${out}" in
  *"CURRENT — 5 pinned loaded file(s) match"*"Against the working tree's pin the installed copy shows 2 finding(s) across 6 file(s)."*)
    ok "the install's state against the proposed pin is reported as a second, separate fact" ;;
  *) fail "the comparison against the proposed pin was not reported: ${out}" ;;
esac
case "${out}" in
  *"never open, update or close a lane-drift"*"tracker on this notice"*)
    ok "the notice says it is not a lane-drift signal" ;;
  *) fail "the notice does not say what it must not be used for: ${out}" ;;
esac
# --quiet changes what is printed, never what is decided.
adopt_run --installed "${cur}" --quiet >/dev/null \
  || fail "a rollout in progress must exit 0 under --quiet too, got $?"
ok "the exit status under a rollout is unchanged by --quiet"

# An install that has already moved to the PROPOSED pin is drift against the adopted one: it serves a
# revision the deployment has not adopted. The notice says which pin it does match.
set +e; out="$(adopt_run --installed "${proposed_install}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "an install on an unadopted pin must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT —"*"ROLLOUT —"*"Against the working tree's pin the installed copy matches all 6 file(s)."*)
    ok "an install on the proposed pin is DRIFT against the adopted one, and the notice says what it matches" ;;
  *) fail "an install on the proposed pin was not reported as drift from the adopted one: ${out}" ;;
esac
# An install matching NEITHER pin: DRIFT, with the notice reporting findings rather than a match.
set +e; out="$(adopt_run --installed "${chg}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "an install matching neither pin must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT — 1 finding(s)"*"ROLLOUT —"*"Against the working tree's pin the installed copy shows 3 finding(s) across 6 file(s)."*)
    ok "an install matching neither pin is DRIFT, counted against each pin separately" ;;
  *) fail "an install matching neither pin was not counted against both: ${out}" ;;
esac
# The Claude remediation must not send the refresh at the working tree's pin.
case "${out}" in
  *"--gitlink ${gitlink}"*) ok "the drift remediation names the adopted pin for the refresh" ;;
  *) fail "the drift remediation does not bind the refresh to the adopted pin: ${out}" ;;
esac

# --adopted-ref names an already-fetched revision, and the output says it was not refreshed.
if out="$(adopt_run --adopted-ref refs/remotes/origin/main --installed "${cur}")"; then
  case "${out}" in
    *"caller-named — the gitlink at refs/remotes/origin/main (${adopted_commit}), named by --adopted-ref and NOT refreshed by this check"*"CALLER-NAMED PIN"*"UNCHECKED"*"ROLLOUT —"*)
      ok "--adopted-ref names the adopted revision and is reported as not refreshed" ;;
    *) fail "--adopted-ref did not report its source: ${out}" ;;
  esac
else
  fail "--adopted-ref on a current install must exit 0, got $? — ${out}"
fi

# The source-parity backend uses the same basis.
if out="$(adopt_run --runtime git-ref --loaded-ref "${gitlink}")"; then
  case "${out}" in
    *CURRENT*"source parity only"*"ROLLOUT —"*"The declared source revision is not the working tree's pin."*)
      ok "git-ref measures source parity against the adopted pin under a rollout" ;;
    *) fail "git-ref under a rollout did not report the adopted basis: ${out}" ;;
  esac
else
  fail "a source on the adopted pin must exit 0 under a rollout, got $? — ${out}"
fi
set +e; out="$(adopt_run --runtime git-ref --loaded-ref "${proposed_pin}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "a source on an unadopted pin must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT —"*"ROLLOUT —"*"The declared source revision is the working tree's pin."*)
    ok "a source on the proposed pin is DRIFT, and the notice says it is the proposal" ;;
  *) fail "a source on the proposed pin was not reported against the adopted one: ${out}" ;;
esac

# 14c. FAIL CLOSED — an adopted pin that cannot be read is UNKNOWN, never the working tree's pin.
# Back on the default branch the working tree's own pin MATCHES the install, so a silent fallback to
# it would print CURRENT and exit 0. That is what makes these arms discriminating.
git -C "${work}" checkout -q main
expect_adopted_unknown() {
  local label="$1" needle="$2"; shift 2
  set +e; out="$(adopt_run --installed "${cur}" "$@")"; rc=$?; set -e
  [ "${rc}" -eq 2 ] || fail "${label} must exit 2 (UNKNOWN), got ${rc}: ${out}"
  case "${out}" in
    *CURRENT*|*"DRIFT —"*) fail "${label} produced a verdict — it fell back to another pin: ${out}" ;;
  esac
  case "${out}" in
    *"${needle}"*) ok "${label} is UNKNOWN and names the reason" ;;
    *) fail "${label} exited 2 for an unrelated reason: ${out}" ;;
  esac
}
expect_adopted_unknown "an adopted ref that does not exist" "cannot resolve the adopted revision" \
  --adopted-ref refs/remotes/origin/absent
expect_adopted_unknown "a remote that is not configured" "'absent' is not a configured remote" \
  --remote absent
expect_adopted_unknown "an adopted revision that records no gitlink" "no gitlink for" \
  --adopted-ref "${unpinned_commit}"
# A revision that resolves but whose tree is not in the object database: its gitlink cannot be
# read at all. Falling back to the working tree's pin here would print CURRENT (monorepo#3824).
treeless_commit="$(printf 'tree %s\nauthor t <t@example.invalid> 0 +0000\ncommitter t <t@example.invalid> 0 +0000\n\na tree nobody has\n' \
  0123456789abcdef0123456789abcdef01234567 | git -C "${work}" hash-object -t commit -w --stdin)"
git -C "${work}" cat-file -e "${treeless_commit}^{commit}" \
  || fail "fixture: the commit with a missing tree was not written"
if git -C "${work}" ls-tree "${treeless_commit}" >/dev/null 2>&1; then
  fail "fixture: the tree of ${treeless_commit} is readable, so this arm proves nothing"
fi
expect_adopted_unknown "an adopted revision whose tree cannot be read" \
  "cannot read the tree of the adopted revision ${treeless_commit}" --adopted-ref "${treeless_commit}"
expect_adopted_unknown "a short adopted ref" "remote-tracking ref (refs/remotes/...) or full commit ID" \
  --adopted-ref origin/main
expect_adopted_unknown "an adopted ref beside an explicit pin" "pass only one" \
  --adopted-ref refs/remotes/origin/main --gitlink "${gitlink}"
expect_adopted_unknown "an option-shaped remote name" "must name a git remote" \
  --remote --upload-pack=true
git init -q --bare "${adopt}/empty.git"
git -C "${work}" remote add empty "${adopt}/empty.git"
expect_adopted_unknown "a remote with no default-branch commit" "advertised no default-branch commit" \
  --remote empty
git -C "${work}" remote remove empty
case "${out}" in
  *"--adopted-ref refs/remotes/origin/main"*"never used instead"*)
    ok "the UNKNOWN names the supported recovery and rules out the working-tree fallback" ;;
  *) fail "the UNKNOWN does not name its recovery: ${out}" ;;
esac
# The remote that every real caller uses, made unreachable.
git -C "${work}" remote set-url origin "${adopt}/gone"
expect_adopted_unknown "an unreachable remote" "cannot read the default branch of remote 'origin'"
case "${out}" in
  *"refs/remotes/origin/main' &&"*"A failed fetch leaves the old ref in place"*)
    ok "the recovery runs the check only when its fetch succeeded" ;;
  *) fail "the recovery lets a failed fetch be followed by a check of the stale ref: ${out}" ;;
esac
git -C "${work}" remote set-url origin "${forge}"

# The pin source names the repository that ANSWERED, not just the remote's name (monorepo#3824). A
# url.<base>.insteadOf rewrite sends a remote somewhere else while its name and its configured URL
# stay the same, so the name alone would hide which repository the pin was read from.
git -C "${work}" remote add rewritten "https://rewritten.invalid/consumer.git"
git -C "${work}" config "url.${forge}.insteadOf" "https://rewritten.invalid/consumer.git"
if out="$(adopt_run --installed "${cur}" --remote rewritten)"; then
  case "${out}" in
    *"rewritten refs/heads/main (${adopted_commit}), read from the remote by this check at ${forge}"*CURRENT*)
      ok "the pin source prints the location a rewritten remote resolved to" ;;
    *) fail "the pin source does not name where the rewritten remote resolved to: ${out}" ;;
  esac
  case "${out}" in
    *rewritten.invalid*) fail "the pin source printed the configured URL, not the one git contacted: ${out}" ;;
    *) ok "the pin source does not print the URL the rewrite replaced" ;;
  esac
else
  fail "a rewritten remote that reaches the adopted pin must exit 0, got $? — ${out}"
fi
git -C "${work}" config --unset "url.${forge}.insteadOf"
git -C "${work}" remote remove rewritten
# The check refuses an HTTP redirect, but a setting scoped to the remote's URL outranks the one it
# passes: git takes the closest match to the URL. With such a setting the read may follow a
# redirect to a repository the pin source does not name, so the check stops before it reads.
git -C "${work}" remote add redirecting "https://redirecting.invalid/consumer.git"
git -C "${work}" config "http.https://redirecting.invalid/.followRedirects" true
expect_adopted_unknown "a URL-scoped setting that lets the read follow a redirect" \
  "follow an HTTP redirect" --remote redirecting
git -C "${work}" config --unset "http.https://redirecting.invalid/.followRedirects"
git -C "${work}" remote remove redirecting
# A URL can carry a token, and this line is copied into reports. The stand-in runs the command git
# asks the remote for on this machine, so an ssh URL with credentials in it reaches the fixture.
cat > "${adopt}/local-ssh" <<'SSH'
#!/bin/sh
for last in "$@"; do :; done
exec sh -c "$last"
SSH
chmod +x "${adopt}/local-ssh"
git -C "${work}" remote add withtoken "ssh://tokenuser7f3a:hunter2@token.invalid${forge}"
set +e
out="$(GIT_SSH_COMMAND="${adopt}/local-ssh" GIT_SSH_VARIANT=ssh adopt_run --installed "${cur}" --remote withtoken)"; rc=$?
set -e
git -C "${work}" remote remove withtoken
[ "${rc}" -eq 0 ] || fail "a remote reached over the ssh stand-in must exit 0, got ${rc}: ${out}"
case "${out}" in
  *hunter2*|*tokenuser7f3a*) fail "the pin source printed the credentials written into the remote URL: ${out}" ;;
esac
case "${out}" in
  *"read from the remote by this check at ssh://token.invalid${forge}"*)
    ok "the pin source prints a remote URL without the credentials written into it" ;;
  *) fail "the pin source does not name the remote's location without its credentials: ${out}" ;;
esac
# A token is written into a URL in more places than before the host: the query and the fragment
# carry one too. The stand-in above cannot reach a repository through a URL with a query, so the
# function that prints the location is asked directly. It keeps what names the repository (scheme,
# host and port, path) and drops the rest, and prints any byte that is not printable ASCII as `?`,
# since the line is copied into reports.
printable_url_source="$(awk '/^printable_url\(\) \{$/ { on = 1 } on { print } on && /^\}$/ { exit }' "${script}")"
[ -n "${printable_url_source}" ] || fail "cannot find printable_url in ${script}"
eval "${printable_url_source}"
expect_printable() { # <url> <what must be printed> <case name>
  local got
  got="$(printable_url "$1")"
  [ "${got}" = "$2" ] || fail "$3: printed '${got}', want '$2'"
  case "${got}" in *s3cr3t*) fail "$3: the secret written into the URL was printed: ${got}" ;; esac
  ok "$3"
}
expect_printable 'https://host.example/org/repo.git?token=s3cr3t' 'https://host.example/org/repo.git' \
  "the pin source leaves out a URL's query"
expect_printable 'https://host.example/org/repo.git#s3cr3t' 'https://host.example/org/repo.git' \
  "the pin source leaves out a URL's fragment"
expect_printable 'https://user:s3cr3t@host.example:8443/org/repo.git?access_token=s3cr3t#s3cr3t' \
  'https://host.example:8443/org/repo.git' \
  "the pin source keeps scheme, host, port and path, and nothing else"
expect_printable 'https://host.example?token=s3cr3t' 'https://host.example' \
  "the pin source leaves out a query that follows the host directly"
expect_printable 's3cr3t@host.example:org/repo.git' 'host.example:org/repo.git' \
  "the pin source leaves out the user of an scp-style location"
expect_printable '/srv/git/a?b#c.git' '/srv/git/a?b#c.git' \
  "the pin source prints a plain path whole"
# git also takes locations that are no URL: an address only a helper program understands, and a
# whole command line. Nothing of those is known to be safe to print, so only the transport is.
expect_printable 'ext::auth-proxy --token s3cr3t host.example org/repo' 'ext::<address not shown>' \
  "the pin source prints only the transport of a command-line location"
expect_printable 'vault::s3cr3t@host.example/org/repo' 'vault::<address not shown>' \
  "the pin source prints only the transport of a helper's own address"
expect_printable 's3cr3t token@host.example:org/repo.git' 'host.example:org/repo.git' \
  "the pin source prints only the host and path of an scp-style location with an odd user"
expect_printable 'host name with s3cr3t:org/repo.git' '<location not shown>' \
  "the pin source prints nothing of a location it cannot read as one of the known forms"
expect_printable "https://host.example/org/repo.git"$'\n'"pin source      : forged"$'\033'"[2K" \
  'https://host.example/org/repo.git?pin source      : forged?[2K' \
  "the pin source prints a line break or an escape byte in a URL as a question mark"

# Anything this checkout wrote itself cannot show what the deployment adopted. Each of these named
# the working tree's own HEAD and, before they were refused, printed CURRENT with "adopted" beside it.
expect_adopted_unknown "a local branch as the adopted ref" "is a local ref" \
  --adopted-ref refs/heads/main
expect_adopted_unknown "a local tag as the adopted ref" "is a local ref" \
  --adopted-ref refs/tags/anything
expect_adopted_unknown "this repository named as its own remote" "'.' is not a configured remote" \
  --remote .
expect_adopted_unknown "a path named as the remote" "is not a configured remote" \
  --remote "${work}"
git -C "${work}" remote add self "${work}"
expect_adopted_unknown "a configured remote that points back at this repository" \
  "points back at this repository" --remote self
git -C "${work}" remote remove self

# The same repository reached by a file:// URL, or by a path relative to it, is still this
# repository. `[ -d ]` on the raw URL saw neither, and the check then printed CURRENT for the
# working tree's own HEAD.
git -C "${work}" remote add self "file://${work}"
expect_adopted_unknown "a file:// remote that points back at this repository" \
  "points back at this repository" --remote self
git -C "${work}" remote set-url self "."
expect_adopted_unknown "a relative-path remote that points back at this repository" \
  "points back at this repository" --remote self
git -C "${work}" remote remove self

# A repository that names its ssh command in core.sshCommand must keep it. The stand-in records
# that it was the transport; replaced by plain `ssh`, it is never called.
cat > "${adopt}/configured-ssh" <<SSH
#!/bin/sh
: > "${adopt}/configured-ssh.called"
exit 1
SSH
chmod +x "${adopt}/configured-ssh"
git -C "${work}" remote add viassh "ssh://configured.invalid/consumer.git"
git -C "${work}" config core.sshCommand "${adopt}/configured-ssh"
set +e
out="$(env -u GIT_SSH_COMMAND -u GIT_SSH PLUGIN_CURRENCY_REMOTE_TIMEOUT_SECS=5 \
  "${script}" --repo-root "${work}" --installed "${cur}" --remote viassh 2>&1)"; rc=$?
set -e
git -C "${work}" config --unset core.sshCommand
git -C "${work}" remote remove viassh
[ "${rc}" -eq 2 ] || fail "an ssh command that fails must exit 2 (UNKNOWN), got ${rc}: ${out}"
[ -e "${adopt}/configured-ssh.called" ] \
  || fail "core.sshCommand was replaced by plain ssh: the configured transport was never called"
ok "the repository's core.sshCommand stays the transport when GIT_SSH_COMMAND is unset"

# A transport that is not OpenSSH takes none of OpenSSH's options (ssh.variant): plink, putty, a
# wrapper of one's own. This stand-in fails when it is handed one, and otherwise runs the command
# git asks the remote for on this machine, so the remote is reached only when nothing was added.
mkdir -p "${adopt}/odd"
cat > "${adopt}/odd/strict" <<'SSH'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in -o*) exit 64 ;; esac
done
for last in "$@"; do :; done
exec sh -c "$last"
SSH
cp "${adopt}/odd/strict" "${adopt}/odd/ssh"
chmod +x "${adopt}/odd/strict" "${adopt}/odd/ssh"
git -C "${work}" remote add viaplain "ssh://plain.invalid${forge}"
set +e
out="$(GIT_SSH_COMMAND="${adopt}/odd/strict" GIT_SSH_VARIANT=simple adopt_run --installed "${cur}" --remote viaplain)"; rc=$?
set -e
[ "${rc}" -eq 0 ] \
  || fail "a transport declared as not OpenSSH must be run as configured, got ${rc}: ${out}"
ok "a transport declared as not OpenSSH is handed none of OpenSSH's options"
# Declared in the repository's configuration instead, for a command that happens to be named ssh:
# the name alone would say OpenSSH.
git -C "${work}" config core.sshCommand "${adopt}/odd/ssh"
git -C "${work}" config ssh.variant simple
set +e
out="$(env -u GIT_SSH_COMMAND -u GIT_SSH -u GIT_SSH_VARIANT "${script}" --repo-root "${work}" \
  --installed "${cur}" --remote viaplain 2>&1)"; rc=$?
set -e
git -C "${work}" config --unset core.sshCommand
git -C "${work}" config --unset ssh.variant
git -C "${work}" remote remove viaplain
[ "${rc}" -eq 0 ] \
  || fail "ssh.variant must decide what a command named ssh is handed, got ${rc}: ${out}"
ok "the repository's ssh.variant is honoured for a command named ssh"

# A remote that accepts the call and never answers must end as UNKNOWN inside the deadline. The
# transport here is an ssh stand-in that only sleeps: unbounded, the check would wait on it for the
# whole sleep.
cat > "${adopt}/silent-ssh" <<'SSH'
#!/bin/sh
sleep 60
SSH
chmod +x "${adopt}/silent-ssh"
git -C "${work}" remote add silent "ssh://silent.invalid/consumer.git"
silent_started=${SECONDS}
set +e
out="$(GIT_SSH_COMMAND="${adopt}/silent-ssh" PLUGIN_CURRENCY_REMOTE_TIMEOUT_SECS=2 \
  adopt_run --installed "${cur}" --remote silent)"; rc=$?
set -e
silent_elapsed=$((SECONDS - silent_started))
git -C "${work}" remote remove silent
[ "${rc}" -eq 2 ] || fail "a silent remote must exit 2 (UNKNOWN), got ${rc}: ${out}"
case "${out}" in
  *"cannot read the default branch of remote 'silent'"*"within 2s"*) ;;
  *) fail "a silent remote exited 2 for an unrelated reason: ${out}" ;;
esac
[ "${silent_elapsed}" -lt 30 ] \
  || fail "a silent remote held the check for ${silent_elapsed}s — the deadline did not apply"
ok "a remote that never answers is UNKNOWN within the deadline (${silent_elapsed}s)"
set +e
out="$(PLUGIN_CURRENCY_REMOTE_TIMEOUT_SECS=soon adopt_run --installed "${cur}")"; rc=$?
set -e
case "${rc}:${out}" in
  2:*"PLUGIN_CURRENCY_REMOTE_TIMEOUT_SECS must be a whole number"*)
    ok "a malformed deadline is UNKNOWN, not an unbounded call" ;;
  *) fail "a malformed deadline was accepted (exit ${rc}): ${out}" ;;
esac

# 14d. SUPERSEDED — the default branch adopts the bump AFTER this checkout was taken. The working
# tree still holds the previous pin and does not even have the commit that moved it.
write_rollout_declaration "${forge}"
git -C "${forge}" add .claude/plugin-consumption/agentic-engineering.desired-state.json
git -C "${forge}" update-index --cacheinfo "160000,${proposed_pin},libraries/agent-plugins"
git -C "${forge}" -c commit.gpgsign=false commit -qm 'adopt the proposed pin'
readopted_commit="$(git -C "${forge}" rev-parse HEAD)"
if git -C "${work}" cat-file -e "${readopted_commit}^{commit}" 2>/dev/null; then
  fail "fixture: the working tree already has the commit it is supposed to be behind"
fi
set +e; out="$(adopt_run --installed "${proposed_install}")"; rc=$?; set -e
[ "${rc}" -eq 0 ] \
  || fail "an install on the live pin must exit 0 from a checkout taken before the rollout merged, got ${rc}: ${out}"
case "${out}" in
  *"pinned revision : ${proposed_pin}"*"origin refs/heads/main (${readopted_commit})"*CURRENT*"SUPERSEDED —"*"working tree : ${gitlink}"*"adopted      : ${proposed_pin}"*"Against the working tree's pin the installed copy shows 1 finding(s) across 5 file(s)."*)
    ok "an install on the live pin is CURRENT from a superseded checkout, which is reported as SUPERSEDED" ;;
  *) fail "the superseded checkout was not reported distinctly: ${out}" ;;
esac
# The check brought in the one commit it needed and moved no ref of the working repository.
git -C "${work}" cat-file -e "${readopted_commit}^{commit}" 2>/dev/null \
  || fail "the adopted commit was not made available to the comparison"
[ "$(git -C "${work}" rev-parse refs/remotes/origin/main)" = "${adopted_commit}" ] \
  || fail "the check moved the working repository's remote-tracking ref"
[ ! -e "${work}/.git/FETCH_HEAD" ] || fail "the check wrote FETCH_HEAD in the working repository"
ok "reading the adopted pin fetches that commit only and moves no ref"
# The same checkout with the install still on the PREVIOUS pin: that is real drift, because the
# install is behind what the deployment adopted.
set +e; out="$(adopt_run --installed "${cur}")"; rc=$?; set -e
[ "${rc}" -eq 1 ] || fail "an install behind the adopted pin must exit 1, got ${rc}: ${out}"
case "${out}" in
  *"DRIFT —"*"SUPERSEDED —"*"Against the working tree's pin the installed copy matches all 5 file(s)."*)
    ok "an install behind the adopted pin is DRIFT even though it matches the checkout's own pin" ;;
  *) fail "an install behind the adopted pin was not reported as drift: ${out}" ;;
esac
# A stale remote-tracking ref named explicitly is honoured, and labelled as the caller's to refresh.
# This is why the default asks the remote: read from this ref, the stale install above is CURRENT.
if out="$(adopt_run --adopted-ref refs/remotes/origin/main --installed "${cur}")"; then
  case "${out}" in
    *"NOT refreshed by this check"*) ok "a named adopted ref is used as given and labelled as not refreshed" ;;
    *) fail "a named adopted ref was not labelled as the caller's to refresh: ${out}" ;;
  esac
else
  fail "a named adopted ref must be used as given, got $? — ${out}"
fi

# The default branch's tip is advertised, but its commit cannot be brought in (monorepo#3824). The
# working tree's own pin matches this install, so a fallback to it would print CURRENT and exit 0:
# the install is in fact behind what the deployment adopted, as the arm above shows.
git -C "${forge}" -c commit.gpgsign=false commit -q --allow-empty -m 'a tip the working repository does not have'
unfetched_commit="$(git -C "${forge}" rev-parse HEAD)"
if git -C "${work}" cat-file -e "${unfetched_commit}^{commit}" 2>/dev/null; then
  fail "fixture: the working repository already has the tip it is supposed to be unable to fetch"
fi
real_git_path="$(command -v git)"
mkdir -p "${adopt}/fetchless"
cat > "${adopt}/fetchless/git" <<SHIM
#!/bin/sh
# The real git for everything except bringing objects in. Each call that talks to the remote is
# written down first, with its arguments.
case " \$* " in
  *" ls-remote --symref "* | *" fetch "*) printf '%s\n' "\$*" >> "${adopt}/fetchless/remote-calls" ;;
esac
for arg in "\$@"; do
  if [ "\$arg" = fetch ]; then
    : > "${adopt}/fetchless/refused"
    exit 128
  fi
done
exec "${real_git_path}" "\$@"
SHIM
chmod +x "${adopt}/fetchless/git"
PATH="${adopt}/fetchless:${PATH}" expect_adopted_unknown "a default-branch tip that cannot be fetched" \
  "the default-branch tip ${unfetched_commit} of remote 'origin' is not in the local object database and could not be fetched"
[ -e "${adopt}/fetchless/refused" ] \
  || fail "fixture: the check never tried to fetch the advertised tip, so this arm proves nothing"
if git -C "${work}" cat-file -e "${unfetched_commit}^{commit}" 2>/dev/null; then
  fail "fixture: the advertised tip reached the working repository although its fetch was refused"
fi
ok "a refused fetch leaves the advertised tip out of the working repository"
# Both calls that talk to the remote refuse an HTTP redirect (monorepo#3824). git follows a redirect
# of its first request by default, so the pin could come from a repository the pin source line does
# not name. No web server stands behind this suite, so what is pinned is that both calls carry the
# setting: the read of the default branch, and the fetch of its tip.
remote_calls="$(cat "${adopt}/fetchless/remote-calls" 2>/dev/null || true)"
remote_reads="$(grep -c -- ' ls-remote --symref ' <<<"${remote_calls}" || true)"
remote_fetches="$(grep -c -- ' fetch ' <<<"${remote_calls}" || true)"
if [ "${remote_reads}" -ne 1 ] || [ "${remote_fetches}" -ne 1 ]; then
  fail "fixture: expected one read of the default branch and one fetch, saw ${remote_reads} and ${remote_fetches}: ${remote_calls}"
fi
remote_following="$(grep -v -- ' -c http.followRedirects=false ' <<<"${remote_calls}" || true)"
[ -z "${remote_following}" ] \
  || fail "a call to the remote would follow an HTTP redirect: ${remote_following}"
ok "the default-branch read and the fetch both refuse an HTTP redirect"

# 14e. UNADOPTED — the two pins differ and share no history, so which side moved is not established.
unrelated_commit="$(git -C "${work}" -c commit.gpgsign=false commit-tree -m 'unrelated root' "${rollout_commit}^{tree}")"
if out="$(adopt_run --adopted-ref "${unrelated_commit}" --installed "${proposed_install}")"; then
  case "${out}" in
    *CURRENT*"UNADOPTED —"*"working tree : ${gitlink}"*"adopted      : ${proposed_pin}"*)
      ok "pins that differ without common history are reported as UNADOPTED, not guessed" ;;
    *) fail "unrelated histories were not reported as UNADOPTED: ${out}" ;;
  esac
else
  fail "an install on the adopted pin must exit 0 whatever the working tree holds, got $? — ${out}"
fi

# ── 15. The CONTRACT says which pin the verdict uses, and what a notice is not ─
# The script alone would let a later edit of the guide go back to "the pinned gitlink" meaning the
# working tree's, and a run following that prose would file the tracker the script no longer asks for.
case "${section}" in
  *"measured against the pin this deployment has ADOPTED"*)
    ok "the contract says the verdict is measured against the adopted pin" ;;
  *) fail "the plugin contract section does not say which pin the verdict is measured against" ;;
esac
case "${section}" in
  *"it never changes the verdict or the exit code"*)
    ok "the contract says a working-tree notice never changes the verdict" ;;
  *) fail "the plugin contract section does not bound what a working-tree notice means" ;;
esac
for notice in ROLLOUT SUPERSEDED UNADOPTED; do
  case "${section}" in
    *"\`${notice}\` —"*) ok "the contract defines the ${notice} notice" ;;
    *) fail "the plugin contract section does not define the ${notice} notice" ;;
  esac
done
case "${section}" in
  *"the working tree's gitlink never stands in for it"*)
    ok "the contract says an unreadable adopted pin is UNKNOWN, never the working tree's pin" ;;
  *) fail "the plugin contract section allows a fallback to the working tree's gitlink" ;;
esac
case "${section}" in
  *"--adopted-ref <full-commit-id-or-remote-tracking-ref>"*"owns its freshness"*"only as fresh as the fetch behind it"*"follow that one, whatever the notice says"*)
    ok "the contract names the explicit adopted-ref form and who owns its freshness" ;;
  *) fail "the plugin contract section does not name --adopted-ref and its freshness owner" ;;
esac
# The tracker clause must key on the verdict, not on the notice — this is what stops an unmerged bump
# from filing a lane-drift tracker.
case "${section}" in
  *"only that verdict is a trigger"*"never opens, updates or closes a tracker"*)
    ok "the tracker clause keys on drift against the adopted pin, never on a notice" ;;
  *) fail "the tracker clause does not exclude a working-tree notice as a trigger" ;;
esac
# The refresh resolves its own pin from the working tree, so the contract has to bind it.
case "${section}" in
  *"pass the refresh the one the check printed: \`--gitlink <pinned revision>\`"*)
    ok "the contract binds the refresh to the adopted pin under a notice" ;;
  *) fail "the plugin contract section does not bind the refresh to the adopted pin" ;;
esac
# And the fallback read must not follow a proposal.
case "${section}" in
  *"is the reviewed pin only in a checkout that does not change it"*)
    ok "the contract says HEAD's gitlink is a proposal on a rollout branch" ;;
  *) fail "the plugin contract section lets the fallback follow an unmerged proposal" ;;
esac
# The always-on core says "the pinned gitlink" in one line every session reads. Since the verdict
# moved to the adopted pin there are two gitlinks that phrase could mean, and a run on a rollout
# branch would follow its own proposal (monorepo#3824). The line names the default branch in as few
# words as it can: that file and a nested one together sit within 20 bytes of what Codex reads, so
# the longer explanation stays in the guide, which the assertions above already pin.
core="${repo_root}/AGENTS.md"
[ -r "${core}" ] || fail "cannot read ${core}"
core_rule="$(awk '/^- \*\*Before acting on a plugin-sourced role\*\*/ { on = 1 } on && /^- / && !/Before acting on a plugin-sourced role/ { exit } on' "${core}")"
[ -n "${core_rule}" ] || fail "AGENTS.md no longer carries the plugin-sourced-role rule this test reads"
# Every mention of a gitlink in that rule must name the default branch, so adding the words in one
# place does not leave a bare "the pinned gitlink" beside it. The rule is read with its line breaks
# folded, so re-wrapping the paragraph cannot hide or fake a mention.
core_reading() {
  printf '%s\n' "$1" | awk '
    { text = text " " $0 }
    END {
      gsub(/[[:space:]]+/, " ", text)
      if (!index(text, "gitlink")) { print "none"; exit }
      gsub(/the default branch.s (pinned )?gitlink/, "", text)
      print (index(text, "gitlink") ? "bare" : "named")
    }'
}
case "$(core_reading "${core_rule}")" in
  named) ok "the always-on core says which pin \"the pinned gitlink\" means" ;;
  bare) fail "AGENTS.md names a gitlink without saying it is the default branch's: ${core_rule}" ;;
  *) fail "AGENTS.md no longer says which gitlink a run follows on DRIFT or UNKNOWN: ${core_rule}" ;;
esac
# Controls: the sentence this replaced reads as bare, and a rule naming no gitlink reads as none.
[ "$(core_reading "follow the reviewed definition at the pinned
  gitlink and report it")" = bare ] ||
  fail "the reading of the core rule accepts the bare phrase it exists to refuse"
[ "$(core_reading "follow the reviewed definition and report it")" = none ] ||
  fail "the reading of the core rule accepts a rule that names no gitlink"
ok "the reading of the core rule refuses the bare phrase and a rule with no gitlink"

# ── 16. ONE bounded remote call, in the two scripts that carry it (monorepo#3824) ──
# worktree-claim.sh and the currency check each bound their remote git calls with the same
# function. They were two copies, and a fix to one never reached the other: the currency check
# learned to keep the ssh command a repository configures and to set a connect timeout, and the
# claim helper went on replacing it with plain `ssh`. The statements must stay identical, so the
# comparison leaves out only comments and blank lines, where the two explain different callers.
bounded_statements() {
  awk '
    /^bounded_remote\(\) \{$/ { on = 1 }
    on && !/^[[:space:]]*#/ && !/^[[:space:]]*$/ { print }
    on && /^\}$/ { closed = 1; exit }
    END { if (!on || !closed) exit 1 }
  ' "$1"
}
claim_script="${repo_root}/.claude/scripts/worktree-claim.sh"
currency_copy="$(bounded_statements "${script}")" \
  || fail "cannot find a complete bounded_remote in ${script}"
claim_copy="$(bounded_statements "${claim_script}")" \
  || fail "cannot find a complete bounded_remote in ${claim_script}"
[ "$(printf '%s\n' "${currency_copy}" | wc -l)" -gt 10 ] \
  || fail "the bounded_remote read from ${script} is too short to be the function"
if [ "${currency_copy}" = "${claim_copy}" ]; then
  ok "the two copies of bounded_remote are the same statements"
else
  fail "bounded_remote differs between plugin-definition-currency.sh and worktree-claim.sh — make the same change in both:
$(diff <(printf '%s\n' "${currency_copy}") <(printf '%s\n' "${claim_copy}") || true)"
fi
# The comparison must be able to fail: one changed statement in a copy of either script is seen.
sed 's/-o BatchMode=yes //' "${claim_script}" > "${tmp}/worktree-claim.changed.sh"
changed_copy="$(bounded_statements "${tmp}/worktree-claim.changed.sh")" \
  || fail "cannot find bounded_remote in the changed copy"
[ "${changed_copy}" != "${currency_copy}" ] \
  || fail "control: a copy of worktree-claim.sh with one statement changed still compares equal"
ok "control — a changed statement in one copy is seen"

echo "plugin-definition-currency: ${pass_count} assertions passed"
