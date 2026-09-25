#!/usr/bin/env bash
#
# Guards the writer contract for the Agent Improver and for the Agentic Engineer's
# merged spend mandate: each must resolve reviewed sources and own selected
# engineering work from finding through merge. Spend is a dimension of the primary
# engineer, NOT a second scheduled role, so this test also pins that merge shut —
# a resurrected standalone FinOps agent, role, or schedule fails closed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
settings="${repo_root}/.claude/settings.json"
desired_state="${repo_root}/.claude/plugin-consumption/agentic-engineering.desired-state.json"
engineer_agent="${repo_root}/.claude/agents/daily-maintainer.md"
surveyor_agent="${repo_root}/.claude/agents/portfolio-surveyor.md"
surveyor_hook_resolver="${repo_root}/.claude/scripts/portfolio-surveyor-forge-hook.sh"
portable_loader="${repo_root}/.claude/loaders/portable-agentic-engineer.md"
maintenance_overlay="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
engineering_overlay="${repo_root}/.claude/skills/product-engineering/SKILL.md"
self_improvement_overlay="${repo_root}/.claude/skills/self-improvement/SKILL.md"
finops_skill="${repo_root}/.claude/skills/finops/SKILL.md"
lifestyle_floor="${repo_root}/.claude/finops/lifestyle-floor.md"
snapshot="${repo_root}/.claude/scripts/finops-snapshot.sh"
workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "agent-role delivery contract: FAIL — $*" >&2
  exit 1
}

sha256_bytes() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required to verify pinned agent definition integrity"
  fi
}

sha256_file() { sha256_bytes "$1"; }

# Prose guards must survive re-wrapping: a boundary sentence that happens to break
# across two lines is still present, so match against a whitespace-flattened copy
# rather than letting a paragraph reflow read as a removed protection.
flatten() { tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '; }
constitution_flat="$(flatten "${constitution}")"
engineer_flat="$(flatten "${engineer_agent}")"
maintenance_overlay_flat="$(flatten "${maintenance_overlay}")"

assert_prose() {
  case "${constitution_flat}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}
assert_engineer_prose() {
  case "${engineer_flat}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}
assert_maintenance_prose() {
  case "${maintenance_overlay_flat}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}
# A presence-only guard passes happily while the claim it replaced is still sitting
# three paragraphs up, so a corrected fact needs BOTH halves pinned: the new statement
# present AND the superseded one absent. Every contradiction found in this contract so
# far survived exactly that way.
refute_prose() {
  case "${constitution_flat}" in
    *"$1"*) fail "$2" ;;
  esac
}

grep -Fq '### Agent definition locations' "${constitution}" ||
  fail "consumer does not define Agent definition locations"
grep -Fq '### Authority model' "${constitution}" ||
  fail "consumer does not define Authority model"
grep -Fq 'plugins/agentic-engineering/agents/agent-improver.agent.md' "${constitution}" ||
  fail "consumer does not name the upstream Agent Improver source"

# The bundled SKILL.md is SYNCED from devantler-tech/agent-skills (it carries
# metadata.github-repo and the update-agent-skills workflow re-pulls it), so an edit there
# is silently reverted. The consumer listed it as an authoring surface until 2026-07-25,
# which would route a generic fix into a file that discards it.
#
skill_path='plugins/agentic-engineering/skills/agent-improvement/SKILL.md'

# Owner, path, provenance value and the non-authoring rule must all appear in ONE bullet.
# Asserting any of them against the whole contract is a scope hole — verified: changing the
# real owner to agent-plugins and appending an unrelated copy of the expected phrase
# elsewhere satisfied a global check. Extraction therefore starts at the OWNER line (the
# bullet's first line), not at the path line, so the owner declaration is bound to this skill.
# Stop at the next SIBLING BULLET as well as at a blank line. Markdown bullets are normally
# consecutive with no blank line between them, so a blank-line-only terminator swallowed the
# following bullet too — and the "same bullet" binding this guard claims could then be
# satisfied by text that had moved into that sibling.
skill_bullet="$(awk '
  !inb && /\*\*`devantler-tech\/agent-skills`\*\* authors `agent-improvement\/`/ { inb = 1; print; next }
  inb {
    if ($0 ~ /^[[:space:]]*$/) exit
    if ($0 ~ /^[[:space:]]*[-*+] /) exit
    print
  }
' "${constitution}" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
[ -n "${skill_bullet}" ] ||
  fail "consumer does not name agent-skills as the owner of bundled skills"
assert_bullet() {
  case "${skill_bullet}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}
assert_bullet "${skill_path}\` carries" \
  "the agent-skills owner bullet does not name the bundled agent-improvement/SKILL.md"
assert_bullet 'github-repo: https://github.com/devantler-tech/agent-skills' \
  "the agent-skills owner bullet does not name devantler-tech/agent-skills as the upstream"
assert_bullet 'It is a synced artifact, **not** an authoring surface' \
  "the agent-skills owner bullet does not mark that copy a non-authoring surface"

# Provenance is a per-FILE question: the same plugin directory holds synced skills and
# locally-authored agents, so a per-directory rule is wrong in one direction or the other.
#
# An UNINITIALISED submodule is a normal local state, not contract drift. Detect it first, or
# a fresh checkout reports "the skill is missing upstream" and hides the actionable fix.
plugin_root="${repo_root}/libraries/agent-plugins/plugins/agentic-engineering"
[ -d "${plugin_root}" ] ||
  fail "libraries/agent-plugins is not initialised, so the bundled skill cannot be checked. Initialise it with
       .claude/scripts/submodule-init.sh libraries/agent-plugins"

bundled_skill="${plugin_root}/skills/agent-improvement/SKILL.md"
[ -f "${bundled_skill}" ] ||
  fail "bundled agent-improvement/SKILL.md is missing at the pinned plugin revision — AGENTS.md routes generic skill edits through this path, so its absence invalidates the contract text"

# Query the frontmatter STRUCTURALLY, at the exact YAML path `metadata.github-repo`.
#
# A line-oriented grep cannot express this and kept failing in new ways: it accepted the value
# under a different mapping (`examples.github-repo`), accepted a body example after the real
# field was deleted, and treated frontmatter with no closing delimiter as valid. yq resolves
# the real path or returns null, which is the property actually wanted — and it is SHORTER than
# the hand-rolled extraction it replaces, so this closes the hole while cutting complexity.
command -v yq >/dev/null ||
  fail "yq is required to verify the bundled skill's provenance structurally. Install it (brew install yq; it is preinstalled on GitHub ubuntu runners)"
# `|| skill_upstream=''` is load-bearing under `set -e`: yq exits non-zero on unparseable
# frontmatter (e.g. no closing delimiter), which would abort the script SILENTLY — a failing
# test with no message, indistinguishable from a crash. Capture the failure and let the
# assertion below report it with the actionable text.
skill_upstream="$(yq --front-matter=extract '.metadata.github-repo // ""' "${bundled_skill}" 2>/dev/null)" ||
  skill_upstream=''
[ "${skill_upstream}" = 'https://github.com/devantler-tech/agent-skills' ] ||
  fail "bundled agent-improvement/SKILL.md does not declare metadata.github-repo = https://github.com/devantler-tech/agent-skills (got: '${skill_upstream:-<none or unparseable frontmatter>}') — re-check the owning repository before trusting the contract text"

# Every machine-readable entrypoint pointer must resolve to an agent the pinned plugin
# actually BUNDLES. Derived from the submodule rather than hard-coded, so the next upstream
# rename cannot leave this consumer pointing at a file that no longer exists — which is
# exactly what happened when the entrypoint moved automated-ai-engineer -> agentic-engineer
# (agent-plugins#89, plugin 4.0.0) and the two sides were updated on different axes.
# FAILS CLOSED on a missing submodule. An earlier revision skipped the check when the
# directory was absent, which made it a no-op in CI (actions/checkout does not initialise
# submodules), so the guard against entrypoint drift would never have run where it matters.
plugin_agents="${repo_root}/libraries/agent-plugins/plugins/agentic-engineering/agents"
plugin_scripts="${repo_root}/libraries/agent-plugins/plugins/agentic-engineering/scripts"
entrypoint="$(jq -r '.spec.source.entrypoint' "${desired_state}")"
[ -d "${plugin_agents}" ] ||
  fail "cannot resolve the entrypoint: ${plugin_agents} is missing. Initialise it with
       .claude/scripts/submodule-init.sh libraries/agent-plugins
       (CI does this in the workflow step before this test)."
[ -f "${plugin_agents}/${entrypoint}.agent.md" ] ||
  fail "desired state entrypoint '${entrypoint}' does not resolve to a bundled agent in ${plugin_agents}"
canonical_engineer="${plugin_agents}/${entrypoint}.agent.md"
canonical_surveyor="${plugin_agents}/portfolio-surveyor.agent.md"
canonical_improver="${plugin_agents}/agent-improver.agent.md"
canonical_ci_classifier="${plugin_scripts}/classify-default-branch-ci-runs.sh"
canonical_forge_guard="${plugin_scripts}/forge-readonly-guard.sh"
canonical_thread_counter="${plugin_scripts}/count-unresolved-review-threads.sh"
canonical_surveyor_hook="${plugin_scripts}/surveyor-forge-readonly.sh"
canonical_routing_evaluator="${plugin_scripts}/evaluate-inference-routing.sh"
[ -f "${canonical_surveyor}" ] ||
  fail "pinned plugin does not bundle portfolio-surveyor.agent.md"
[ -f "${canonical_improver}" ] ||
  fail "pinned plugin does not bundle agent-improver.agent.md"
if [ ! -f "${canonical_ci_classifier}" ] \
  || [ ! -x "${canonical_ci_classifier}" ] \
  || [ -L "${canonical_ci_classifier}" ]; then
  fail "pinned plugin does not bundle the regular executable default-branch classifier"
fi
if [ ! -f "${canonical_forge_guard}" ] \
  || [ ! -x "${canonical_forge_guard}" ] \
  || [ -L "${canonical_forge_guard}" ]; then
  fail "pinned plugin does not bundle the regular executable read-only forge guard"
fi
if [ ! -f "${canonical_surveyor_hook}" ] \
  || [ ! -x "${canonical_surveyor_hook}" ] \
  || [ -L "${canonical_surveyor_hook}" ]; then
  fail "pinned plugin does not bundle the regular executable surveyor forge-guard hook adapter"
fi
if [ ! -f "${canonical_routing_evaluator}" ] \
  || [ ! -x "${canonical_routing_evaluator}" ] \
  || [ -L "${canonical_routing_evaluator}" ]; then
  fail "pinned plugin does not bundle the regular executable inference-routing evaluator"
fi
grep -Fq '../scripts/classify-default-branch-ci-runs.sh' "${canonical_surveyor}" ||
  fail "pinned portfolio surveyor does not delegate default-branch CI to the bundled classifier"
grep -Fq 'refuses partial or capped' "${canonical_surveyor}" ||
  fail "pinned portfolio surveyor does not fail closed on incomplete default-branch CI evidence"
grep -Fq 'manual dispatch, and GitHub-managed dynamic runs' "${canonical_surveyor}" ||
  fail "pinned portfolio surveyor does not treat managed dynamic runs as default-branch events"
# A successful filtered API call is not proof that GitHub returned the requested head. The
# classifier must validate every returned row before the surveyor may report a current-head
# failure, and hexadecimal case in the requested SHA must not change that identity check.
# shellcheck disable=SC2016 # jq variables are literal classifier source text.
grep -Fq '.head_sha != $expected_head_sha or .head_branch != $expected_branch' "${canonical_ci_classifier}" ||
  fail "pinned default-branch classifier does not reject workflow runs from another head or branch"
grep -Fq "head_sha=\$(printf '%s' \"\$head_sha\" | tr 'A-F' 'a-f')" "${canonical_ci_classifier}" ||
  fail "pinned default-branch classifier does not normalize an uppercase requested SHA before comparison"
# Classifier unavailability is an unknown observation, not evidence of a fire. Preserve the
# surveyor's three-way verdict while keeping independently known fire and other mandatory-query
# failures dominant.
# shellcheck disable=SC2016 # Markdown backticks are literal contract text.
grep -Fq 'When the classifier exits 2, emit only `QUERY-UNKNOWN step-4-classifier`' "${canonical_surveyor}" ||
  fail "pinned portfolio surveyor can replace a failed classifier with unreviewed in-band reads"
# shellcheck disable=SC2016 # Markdown backticks are literal contract text.
grep -Fq 'Any other mandatory-query failure also wins as `nothing_on_fire: false`.' "${canonical_surveyor}" ||
  fail "pinned portfolio surveyor does not preserve mandatory-query failure precedence over classifier unknown"
# The legacy consumer overlay remains on the deployed path until its migration is complete. It must
# not shadow the reviewed plugin with the superseded Boolean rule.
# shellcheck disable=SC2016 # Markdown backticks are literal contract text.
grep -Fq 'When the classifier exits 2, emit only `QUERY-UNKNOWN step-4-classifier`' "${surveyor_agent}" ||
  fail "consumer portfolio-surveyor overlay does not preserve classifier failure as unavailable evidence"
# shellcheck disable=SC2016 # Markdown backticks are literal contract text.
grep -Fq 'Any other mandatory-query failure also wins as `nothing_on_fire: false`.' "${surveyor_agent}" ||
  fail "consumer portfolio-surveyor overlay can let classifier unknown mask another mandatory-query failure"
declared_runtime_asset_sha() {
  jq -er --arg path "$1" '
    .spec.source.requiredRuntimeAssets
    | select(type == "array" and length == 5)
    | map(select(
          type == "object"
          and keys == ["executable", "path", "sha256"]
          and .path == $path
          and .executable == true
        ))
    | select(length == 1)
    | .[0].sha256
  ' "${desired_state}" 2>/dev/null
}
for runtime_asset in \
  "scripts/classify-default-branch-ci-runs.sh:${canonical_ci_classifier}" \
  "scripts/count-unresolved-review-threads.sh:${canonical_thread_counter}" \
  "scripts/forge-readonly-guard.sh:${canonical_forge_guard}" \
  "scripts/surveyor-forge-readonly.sh:${canonical_surveyor_hook}" \
  "scripts/evaluate-inference-routing.sh:${canonical_routing_evaluator}"; do
  runtime_asset_path="${runtime_asset%%:*}"
  canonical_runtime_asset="${runtime_asset#*:}"
  if ! declared_runtime_asset_sha="$(declared_runtime_asset_sha "${runtime_asset_path}")"; then
    fail "consumer desired state does not carry exactly five executable path-and-digest runtime assets including ${runtime_asset_path}"
  fi
  [ "${declared_runtime_asset_sha}" = "$(sha256_bytes "${canonical_runtime_asset}")" ] ||
    fail "consumer desired-state ${runtime_asset_path} sha256 does not match the pinned executable bytes"
done
[ ! -e "${repo_root}/.claude/scripts/classify-main-ci-runs.sh" ] ||
  fail "consumer still carries a local copy of the generic default-branch classifier"

# The consumer copy used to omit role integrity fields while the pinned plugin resource already
# carried them. That let the gitlink advance without proving that the machine-readable entrypoint,
# delegated surveyor, and Improver still named the reviewed bytes. Resolve all digests from the
# pinned files, not from a floating default branch or a copied constant.
consumer_entrypoint_sha="$(jq -r '.spec.source.entrypointSha256 // ""' "${desired_state}")"
consumer_surveyor_sha="$(jq -r '.spec.roles["portfolio-surveyor"].definitionSha256 // ""' "${desired_state}")"
consumer_improver_sha="$(jq -r '.spec.roles["agent-improver"].definitionSha256 // ""' "${desired_state}")"
consumer_improver_skill_sha="$(jq -r '.spec.roles["agent-improver"].skillSha256 // ""' "${desired_state}")"
[ "${consumer_entrypoint_sha}" = "$(sha256_file "${canonical_engineer}")" ] ||
  fail "consumer desired-state entrypointSha256 does not match the pinned agentic-engineer definition"
[ "${consumer_surveyor_sha}" = "$(sha256_file "${canonical_surveyor}")" ] ||
  fail "consumer desired-state portfolio-surveyor definitionSha256 does not match the pinned definition"
[ "${consumer_improver_sha}" = "$(sha256_file "${canonical_improver}")" ] ||
  fail "consumer desired-state agent-improver definitionSha256 does not match the pinned definition"
[ "${consumer_improver_skill_sha}" = "$(sha256_file "${bundled_skill}")" ] ||
  fail "consumer desired-state agent-improver skillSha256 does not match the pinned agent-improvement skill"

canonical_engineer_flat="$(flatten "${canonical_engineer}")"
assert_canonical_engineer_prose() {
  case "${canonical_engineer_flat}" in
    *"$1"*) ;;
    *) fail "$2" ;;
  esac
}
jq -e --arg e "${entrypoint}" '
  (.spec.roles | has($e))
  and .spec.runtime.scheduler.schedules[$e].definitionFrom
      == ("plugin:agentic-engineering/" + $e)
  and .spec.source.updatePolicy == "latest-reviewed-default-branch"
  and .spec.source.refreshTiming == "before-starting-each-run"
' "${desired_state}" > /dev/null ||
  fail "desired state role, schedule, and reviewed-plugin refresh policy must match its declared entrypoint '${entrypoint}'"
# Backticks are literal Markdown, not command substitution.
# shellcheck disable=SC2016
assert_prose "entrypoint **\`${entrypoint}\`**" \
  "consumer prose names an entrypoint other than the declared '${entrypoint}'"

# Definition ownership has two layers. Portable role behaviour belongs in the reviewed
# plugin (or a bundled skill's provenance-recorded upstream); deployment facts belong in
# this consumer's AGENTS.md. A local provider wrapper may route to those sources, but must
# not become a second generic definition. This is the drift shape that left the legacy
# daily-maintainer agent carrying a near-complete copy of agentic-engineer after the plugin
# became canonical.
# Markdown backticks are literal; no shell expansion is intended.
# shellcheck disable=SC2016
assert_prose 'The reviewed plugin is canonical for portable role behaviour; this `AGENTS.md` is canonical only for this deployment' \
  "consumer does not distinguish the plugin role from the deployment contract"
assert_prose 'Never use the bare word *constitution* as an edit destination' \
  "consumer permits an ambiguous constitution reference to bypass definition routing"
assert_prose 'is migration inventory, not a second canonical source' \
  "consumer can mistake unextracted generic prose for a local authoring source"
assert_engineer_prose 'compatibility alias, not a second role definition' \
  "legacy daily-maintainer agent does not declare itself a thin compatibility alias"
assert_engineer_prose 'Generic role behaviour belongs in the reviewed plugin' \
  "legacy daily-maintainer agent does not route generic changes to the plugin"
assert_engineer_prose 'latest-reviewed-default-branch' \
  "legacy daily-maintainer agent does not declare the reviewed-plugin refresh policy"
if grep -Eq '^## (How you operate|Spend stewardship)' "${engineer_agent}"; then
  fail "legacy daily-maintainer agent duplicates canonical plugin role sections"
fi
[ "$(wc -l < "${engineer_agent}")" -le 45 ] ||
  fail "legacy daily-maintainer agent is no longer a thin provider compatibility alias"
for deployment_skill in \
  portfolio-maintenance \
  product-engineering \
  self-improvement \
  finops; do
  DEPLOYMENT_SKILL="${deployment_skill}" yq --front-matter=extract -e \
    '[ (.skills // [])[] | select(. == strenv(DEPLOYMENT_SKILL)) ] | length == 1' \
    "${engineer_agent}" >/dev/null ||
    fail "legacy daily-maintainer alias does not attach deployment skill ${deployment_skill}"
done
memory_hygiene_line="$(grep -nF '.claude/scripts/memory-hygiene.sh --layout legacy --dir' \
  "${engineer_agent}" | head -n 1 | cut -d: -f1 || true)"
memory_load_line="$(grep -nF "Load the runtime's native persistent memory" \
  "${engineer_agent}" | head -n 1 | cut -d: -f1 || true)"
[ -n "${memory_hygiene_line}" ] && [ -n "${memory_load_line}" ] &&
  [ "${memory_hygiene_line}" -lt "${memory_load_line}" ] ||
  fail "legacy daily-maintainer alias must run legacy memory hygiene before loading persistent memory"
for compatibility_overlay in \
  "${maintenance_overlay}" \
  "${engineering_overlay}" \
  "${self_improvement_overlay}"; do
  grep -Fq 'Deployment compatibility overlay — not a generic authoring source' \
    "${compatibility_overlay}" ||
    fail "${compatibility_overlay#"${repo_root}/"} does not route portable changes upstream"
done
grep -Fq 'Classify each target by the file-level ownership and authority rules' \
  "${self_improvement_overlay}" ||
  fail "self-improvement distillation does not classify definition ownership before choosing a repository"
grep -Fq 'metadata.github-repo' "${self_improvement_overlay}" ||
  fail "self-improvement distillation does not route synced skills by structured provenance"
if grep -Fq '`.claude/agents/*`, `.claude/skills/*`' "${self_improvement_overlay}"; then
  fail "self-improvement distillation still routes every local agent or skill change to the monorepo"
fi
grep -Fq 'agentic-engineer.agent.md' "${portable_loader}" ||
  fail "portable loader does not resolve the canonical plugin role"
portable_loader_flat="$(flatten "${portable_loader}")"
case "${portable_loader_flat}" in
  *'spec.source'*'latest-reviewed-default-branch'*'before-starting-each-run'*) ;;
  *) fail "portable loader drops the desired-state before-run reviewed-source refresh policy" ;;
esac
case "${portable_loader_flat}" in
  *'hotSwapDuringRun: false'*) ;;
  *) fail "portable loader permits replacing the running definition during a refresh" ;;
esac
case "${portable_loader_flat}" in
  *'rollout-verification evidence, not a runtime version lock'*) ;;
  *) fail "portable loader turns the consumer gitlink into a runtime version lock" ;;
esac
case "${portable_loader_flat}" in
  *'DRIFT'*'UNKNOWN'*"consumer's pinned gitlink"*) ;;
  *) fail "portable loader drops the reviewed pinned fallback on drift or unknown state" ;;
esac
case "${portable_loader_flat}" in
  *'source parity only'*'does not attest the loaded session'*) ;;
  *) fail "portable loader overstates a source-ref comparison as loaded-session evidence" ;;
esac
grep -Fq "consumer's pinned gitlink" "${portable_loader}" ||
  fail "portable loader does not name the reviewed consumer pin for fallback verification"
grep -Fq 'deployment overlays declared by the consumer' "${portable_loader}" ||
  fail "portable loader does not resolve the declared overlays"
grep -Fq 'verified state' "${portable_loader}" ||
  fail "portable loader does not resolve native capability evidence"
grep -Fq 'inline fallback' "${portable_loader}" ||
  fail "portable loader drops the authorized inline fallback"

grep -Fq 'Agent Improver scorecard store' "${constitution}" ||
  fail "Memory does not name the Agent Improver scorecard store"
grep -Fq 'open verification-hypothesis store' "${constitution}" ||
  fail "Memory does not name the Agent Improver hypothesis store"

# Naming the two stores is NOT the same as requiring a run to read across them. Each assertion below
# pins a distinct clause, so deleting one fails on its own line rather than being masked by another.
# These use assert_prose (whitespace-flattened) and carry the ORDERING and the SEMANTICS, not just a
# recognisable prefix or heading: a prefix-only pin stays green while the clause that gives it meaning
# is deleted, which is a fixture that proves nothing.
assert_prose "reads the SIBLING instance's scorecard and hypothesis store too, before it scores or opens any hypothesis" \
  "Memory does not require the sibling-store cross-read BEFORE scoring or opening a hypothesis (the ordering is the rule)"
assert_prose "sibling's pending hypothesis binds your signature-overlap decisions" \
  "Memory does not bind signature-overlap decisions on a sibling's PENDING hypothesis"
assert_prose 'a signature the sibling has already **settled** is **not re-measured**' \
  "Memory does not forbid re-measuring a signature the sibling has already settled"
assert_prose 'whatever direction that verdict took and whichever window produced it' \
  "Memory does not extend the no-re-measure rule to negative verdicts and earlier windows, so both could be re-measured"
assert_prose 'A sibling `NO-VERDICT`, `NOT-YET-DUE`, or an explicitly unmet measurement floor is **unsettled**, and those stay measurable' \
  "Memory does not classify NO-VERDICT/NOT-YET-DUE/unmet-floor as unsettled, so pending hypotheses could be frozen"
# Without the escape below a settled verdict becomes PERMANENT: the signature could change, or new
# evidence arrive, and the hypothesis could still never be measured again.
assert_prose 'until new evidence or a changed signature invalidates it' \
  "Memory does not let new evidence or a changed signature invalidate a settled sibling verdict, so verdicts would be permanent"
# The confidentiality half is privacy-critical and is NOT covered by the read/verdict assertions above:
# every one of them still passes with the cross-publishing and read-only prohibitions deleted.
assert_prose 'cross-*reading* them is mandatory, cross-*publishing* them is not permitted, and nothing read this way enters a repository artifact or public comment' \
  "Memory does not prohibit cross-publishing the sibling store or leaking it into a repository artifact or public comment"
assert_prose "The sibling's file remains **its** single source of truth — read it, never write it" \
  "Memory does not keep the sibling store read-only, so a run could write to another instance's ledger"
# The agent-improvement skill's no-change research fallback needs a consumer-declared cursor store and
# writer; without them every Improver run that reaches it records QUERY-UNKNOWN (measured on every such
# run of both instances from 2026-08-15 to 2026-09-05). Each clause below is pinned on its own line.
assert_prose 'Agent Improver research register and cursor' \
  "Memory does not name the Agent Improver research register and cursor, so the research fallback stays QUERY-UNKNOWN on every no-change run"
assert_prose 'The single cursor writer is the Claude machine-local Agent Improver' \
  "Memory does not declare the single research-cursor writer, so no instance may claim the cursor and the fallback never completes a pass"
assert_prose 'never researches or advances the cursor' \
  "Memory does not keep the non-writer instance off the research cursor, so two instances could advance it"

# Same WHITELIST discipline for the research-register block (review round 1 on #3215 named the unpinned
# clauses one by one — budget, routing, fallback — which is the blacklist that never converges). The
# three named assertions above keep their specific messages; this pins the whole paragraph verbatim.
research_fixture="${repo_root}/.claude/scripts/fixtures/agent-improver-research-register.txt"
[ -r "${research_fixture}" ] ||
  fail "research-register fixture is missing: ${research_fixture}"
research_block="$(awk '
  /^   \*\*Agent Improver research register and cursor\*\*/ { f = 1 }
  f { print }
  f && /named as the blocker\.$/ { exit }
' "${constitution}")"
[ -n "${research_block}" ] ||
  fail "Could not locate the research-register block in AGENTS.md — its opening anchor was removed or reworded"
if ! printf '%s\n' "${research_block}" | diff -q - "${research_fixture}" >/dev/null 2>&1; then
  fail "The research-register block no longer matches its fixture. Intentional edits must update .claude/scripts/fixtures/agent-improver-research-register.txt in the same commit"
fi

# WHITELIST, not another named clause. Four review rounds each found "clause N is unpinned" — a
# blacklist that never converges, because the next round just names clause N+1. The named assertions
# above stay for their specific failure messages; this one closes the CLASS by pinning the whole block
# verbatim, so ANY deletion or alteration inside it fails, including a clause nobody thought to name.
# Extracted by ANCHOR rather than line number so unrelated edits elsewhere in AGENTS.md cannot shift it.
sibling_fixture="${repo_root}/.claude/scripts/fixtures/agent-improver-sibling-ledger.txt"
[ -r "${sibling_fixture}" ] ||
  fail "sibling-ledger fixture is missing: ${sibling_fixture}"
# Read the REAL terminating line; never fabricate it. An earlier version printed a literal
# "   write it." after seeing "read it, never" and exited, so qualifying the rule on its continuation
# line (e.g. "write it unless its verdict is stale.") produced the ORIGINAL text and the diff passed —
# a fail-open in the very check meant to close the class. The named assertion misses it too, because
# the flattened prefix "read it, never write it" is still a substring of the weakened sentence.
sibling_block="$(awk '
  /^   🔴 \*\*Each Agent Improver run reads the SIBLING/ { f = 1 }
  f { print }
  f && stop { exit }
  f && /read it, never$/ { stop = 1 }
' "${constitution}")"
[ -n "${sibling_block}" ] ||
  fail "Could not locate the sibling-ledger block in AGENTS.md — its opening anchor was removed or reworded"
if ! printf '%s\n' "${sibling_block}" | diff -q - "${sibling_fixture}" >/dev/null 2>&1; then
  fail "The sibling-ledger block no longer matches its fixture. Intentional edits must update .claude/scripts/fixtures/agent-improver-sibling-ledger.txt in the same commit; run: diff <(awk '/Each Agent Improver run reads the SIBLING/,/write it\./' AGENTS.md) ${sibling_fixture}"
fi

for authority_row in \
  '| **Prose tightening**' \
  '| **Prose loosening**' \
  '| **Enforcement tightening**' \
  '| **Enforcement loosening**'; do
  grep -Fq "${authority_row}" "${constitution}" ||
    fail "Authority model is missing ${authority_row}"
done
grep -Fq 'FULL SYMMETRIC AUTHORITY' "${constitution}" ||
  fail "consumer does not preserve the maintainer-granted symmetric authority"
# The never-widen-enforcement prohibition is ACTOR-SCOPED. Stated unconditionally it
# contradicts the Authority model row above, which grants the agent-improver autonomous
# enforcement loosening — and a scheduled improver reading it would defer a fix it is
# mandated to apply. Both halves are pinned: the scoping AND the exception, because
# deleting either one alone silently recreates the contradiction (#2248).
assert_prose "for *this* engineer that edit is the maintainer's alone" \
  "the never-widen-enforcement prohibition is no longer scoped to the Agentic Engineer"
assert_prose 'holds a different grant, and *Authority model* authorises it to loosen enforcement' \
  "consumer no longer exempts the agent-improver from the never-widen-enforcement prohibition"
# Dependency automation gets a bounded first attempt, then the engineer owns the stalled PR. These
# assertions pin the positive self-progressing evidence, the per-PR intervention boundary, fail-closed
# reads, and the unchanged issue-only no-action guard independently (#2779).
assert_prose '**Dependency-automation PRs are conditional operate work.** Dependency-automation issues remain **AUTOMATION-OWNED (NO-ACTION).**' \
  "consumer does not split conditional dependency PR work from automation-owned issues"
assert_prose 'self-progressing only while' \
  "consumer does not require positive current evidence before yielding a dependency PR"
assert_prose 'unable to reach merge without a new agent action' \
  "consumer does not make individually stalled dependency PRs actionable"
assert_prose 'A missing or failed join is `QUERY-UNKNOWN` for that PR, never `NO-ACTION`' \
  "consumer fails open when dependency-PR liveness cannot be read"
assert_prose 'An untouched bot-generated head keeps the repository automation' \
  "consumer does not preserve the existing untouched-bot automation path"
assert_prose 'Any agent-authored adaptation commit restores the ordinary current-head semantic-review gate' \
  "consumer lets agent adaptations bypass semantic review"
assert_prose 'convert the PR to draft before the first adaptation push' \
  "consumer lacks a durable draft fence for dependency-PR adaptations"
assert_prose 'Draft state is the durable fence' \
  "consumer trusts reversible auto-merge disarming as the adaptation fence"
assert_prose 'never select, triage-as-work, edit, or close an issue authored by one of those exact identities' \
  "consumer no longer protects dependency-automation control issues"
refute_prose 'One bot PR being red, stale, conflicting or review-less remains none of our business' \
  "retired per-PR hands-off rule remains in the consumer"
refute_prose 'Every prohibition above stands unchanged and absolute' \
  "retired absolute dependency-PR mutation prohibition remains in the consumer"
grep -Fq 'An issue, recommendation, or draft PR is not completion' "${constitution}" ||
  fail "consumer permits a write-capable role to stop before merge"
grep -Fq '### Writer namespaces' "${constitution}" ||
  fail "consumer does not record namespaces for its scheduled writers"
assert_prose 'Roles sharing one instance also share its claim protocol, draft ownership and checkout discipline' \
  "consumer does not bind shared roles to one instance's ownership"
assert_prose 'an absent, duplicated or unsupported mapping leaves mutation unavailable' \
  "consumer does not fail closed for unmapped role schedules"
grep -Fq 'agent-instances.json' "${constitution}" ||
  fail "consumer does not resolve registered writer namespaces"
assert_prose 'the in-session read-back is necessary but not sufficient' \
  "runtime-local delivery incorrectly treats an in-session read-back as persistence proof"
assert_prose 're-read after at least one dispatch of that schedule' \
  "runtime-local delivery does not require a post-dispatch persistence check"
assert_prose 'a reverted value with an advanced marker means the runtime overwrote the file' \
  "runtime-local delivery does not recognise the dispatch-time rewrite failure mode"
for marker_baseline in \
  '`CLAUDE_ENGINEER_MARKER_BASELINE`' \
  '`CLAUDE_IMPROVER_MARKER_BASELINE`' \
  '`CODEX_ENGINEER_MARKER_BASELINE`' \
  '`CODEX_IMPROVER_MARKER_BASELINE`'; do
  assert_prose "${marker_baseline}" \
    "runtime-local delivery does not name ${marker_baseline} for persistence verification"
done
assert_prose 'authoritative `scheduled-tasks.json` record selected by exact task id plus pointer path' \
  "runtime-local delivery does not require the authoritative Claude scheduler record"
assert_prose '`lastRunAt` as its marker; the `SKILL.md` description is not scheduler state' \
  "runtime-local delivery can mistake Claude loader prose for deployed cadence"
# The natural guess, `~/.claude/scheduled-tasks.json`, does not exist, and searching `$HOME` for the
# real store timed out a run (#2656), so the contract names the path the scripts already read.
assert_prose 'That record lives at `~/Library/Application Support/Claude/claude-code-sessions/<session-uuid>/<task-uuid>/scheduled-tasks.json`, not under `~/.claude`.' \
  "runtime-local delivery does not say where the Claude scheduler record lives"
assert_prose 'never a `.bak-<epoch>` sibling' \
  "runtime-local delivery can select a stale Claude scheduler backup"
grep -Fq 'Library/Application Support/Claude/claude-code-sessions' "${repo_root}/.claude/scripts/agent-telemetry.sh" ||
  fail "the contract's Claude scheduler path no longer matches the store agent-telemetry.sh reads"
assert_prose 'A missing or ambiguous store, missing baseline, marker that did not advance, or incomplete recurrence rule is `UNKNOWN`, never `MATCH`.' \
  "runtime-local delivery does not fail closed on incomplete persistence evidence"

# --- Scheduled cadence is not delivered cadence (#2716) -----------------------
# The schedule fires hourly in both machine-local lanes; only ONE of them keeps it.
# The Claude runtime refuses a dispatch that would overlap the previous run of the
# same task and drops it silently, so a third of ticks never happen — while Codex
# starts the overlapping run instead. A run that plans off "the next tick" is
# therefore wrong about a third of the time on one lane and right on the other,
# which is the undeliberate instance asymmetry this contract must state outright.
assert_prose '`per_task_limit`' \
  "cadence does not name the mechanism by which Claude dispatches are dropped"
assert_prose 'Claude dispatched 108/161' \
  "cadence does not state the measured Claude dispatch shortfall"
assert_prose 'Codex dispatched 161/161' \
  "cadence does not state the Codex control that makes the shortfall a lane asymmetry"
assert_prose 'never time anything off' \
  "cadence does not tell a run to stop planning against the next scheduled tick"

# Same-lane schedules deliberately overlap and share one writer namespace. Mere task presence or
# post-start activity is therefore not a global stop signal: the claim protocol must arbitrate the
# exact artifact instead. Pin both arms so a future edit cannot restore starvation or erase the
# scoped conflict fence while preserving progress.
assert_prose 'same-lane task presence or post-start activity alone is never a global stand-down condition' \
  "cadence still permits a scheduled role to no-op merely because another same-lane task is active"
assert_prose 'a live conflicting claim, exact shared-artifact contention, or an unsafe runtime-local mutation' \
  "cadence does not preserve the artifact-scoped conditions that still require stand-down"

# A complete portfolio census is health evidence, not a global mutation lease. Measured survey runs
# repeatedly stopped after one of 80+ unrelated PR joins failed or hit a cap, even though earlier
# candidates already had complete head, control, claim, CI, conflict, and review evidence. Clearance
# must therefore be candidate-scoped: preserve UNKNOWN for the failed join and for broad health/issue
# descent, while continuing through the ordered PR queue with fully joined independent candidates.
assert_maintenance_prose 'Clearance is per candidate, never per portfolio' \
  "portfolio maintenance still couples all mutation to a complete portfolio-wide join"
assert_maintenance_prose 'cheap exhaustive enumeration' \
  "portfolio maintenance does not separate cheap ordering from candidate deepening"
assert_maintenance_prose "candidate repository's default-head health" \
  "candidate clearance does not preserve repository-local default-head safety evidence"
assert_maintenance_prose 'unrelated failed or capped joins remain `QUERY-UNKNOWN`' \
  "portfolio maintenance does not preserve uncertainty for incomplete unrelated joins"
assert_maintenance_prose 'never block an independently fully joined candidate' \
  "portfolio maintenance still permits unrelated query failures to freeze cleared work"
assert_maintenance_prose 'A candidate repository query failure blocks that candidate' \
  "portfolio maintenance can act after the candidate repository query fails"
assert_maintenance_prose 'An attempted in-shard join failure emits `QUERY-UNKNOWN <repo> #<n> — failed=<component>:<reason>`' \
  "portfolio maintenance does not define the candidate-scoped producer row for failed joins"
assert_maintenance_prose 'never-attempted candidates remain `NOT-DEEPENED`' \
  "portfolio maintenance conflates failed attempted joins with candidates outside the shard"
assert_maintenance_prose 'issue descent remains blocked until the actionable-PR queue is completely classified' \
  "portfolio maintenance can descend into issues while higher-priority PR state is unknown"
assert_maintenance_prose 'pass the prior digest' \
  "portfolio maintenance does not pass continuation state when requesting the next survey shard"
assert_maintenance_prose 'cursor is invalidated when any recorded candidate head changes' \
  "portfolio maintenance can reuse stale shard state after a candidate head changes"
# A `per_task_limit` record is a per-MINUTE liveness sample of "a run is currently open",
# not a per-slot drop record — so counting those records, raw or hour-bucketed, counts a
# slot that merely started LATE as one that never ran. Measured 2026-08-12 over 164 slots:
# 37 of 66 refused hours dispatched anyway. Without this distinction every run re-derives
# the rate from the skip store and gets a different answer; four measurements across both
# instances spanned 32.9%-58.3% doing exactly that. Pin the METHOD, not only the number,
# or the wrong method comes back the next time someone re-measures.
assert_prose 'liveness sample' \
  "cadence does not say what a per_task_limit record actually samples"
assert_prose 'delayed into the next hour' \
  "cadence does not distinguish a delayed dispatch from a dropped one"
# The two assertions above are satisfied by the historical EXPLANATION alone, so an edit that
# dropped the correction while keeping the story would still pass them — which would leave the
# discredited method as the operative instruction. Pin the DIRECTIVE and the corrected reading,
# not only the account of why the old one was wrong.
assert_prose 'comparing actual dispatches to scheduled slots' \
  "cadence does not name the only method that yields a drop rate"
assert_prose '133 of 164 slots' \
  "cadence does not state the corrected, transcript-cross-validated dispatch count"
# A zero skip count cannot establish the Improver's health: the second failure cause carries no
# skip record at all, and one of its two instances IS an Improver dispatch. Reading that zero as
# a clean bill is the same absence-as-evidence error, one lane over.
assert_prose 'zero skip count is exactly why not' \
  "cadence still infers Improver health from an absent skip record"
# `constitution_flat` collapses newlines to single spaces, so the superseded sentence is matched
# in its flattened form — it was wrapped across two lines in the source.
refute_prose 'The Agent Improver is otherwise unaffected' \
  "cadence again declares the Improver unaffected on the strength of a zero skip count"
# The superseded absolute. Left in place it reads as the operative rule, because it is
# stated as a flat invariant while the correction reads as a caveat about it.
refute_prose 'next scheduled tick is always one hour later' \
  "cadence still asserts an unconditional hourly next tick alongside its own refutation"

# Shared automation is a reuse boundary, not a centralisation target. A product's own
# action or workflow belongs beside that product until a second real repository consumes
# the same product-neutral contract. Pin all three parts so "this might be reusable later"
# cannot silently move product policy into an organisation-wide repository.
assert_prose 'demonstrated consumers in at least two repositories' \
  "shared automation does not require demonstrated multi-repository consumption"
assert_prose 'Product-specific actions, workflows, paths, permissions, secrets, release semantics, and policy stay in the product repository they serve' \
  "consumer contract does not keep product-specific automation close to its source"
assert_prose 'Possible future reuse, superficial similarity, or a desire to centralise is not evidence' \
  "consumer contract still permits speculative workflow centralisation"
assert_prose 'World at Ruin-specific automation therefore stays in `devantler-tech/world-at-ruin`' \
  "consumer contract does not pin the named World at Ruin locality example"

# --- The merged spend mandate -------------------------------------------------
# Spend is a dimension of the Agentic Engineer. The consumer must supply the Spend
# contract the plugin entrypoint resolves, and must keep the money boundary that
# used to live in the standalone agent — merging a mandate into a larger definition
# is exactly where a boundary gets quietly dropped by a later edit.
grep -Fq '### Spend contract' "${constitution}" ||
  fail "consumer does not define the Spend contract section the engineer resolves"
grep -Fq '| **Spend contract** |' "${constitution}" ||
  fail "plugin contract table does not map the Spend contract section"

# Resolve the source from the Spend contract itself. The same desired-state path
# appears elsewhere in AGENTS.md, which must not satisfy a missing declaration.
assert_spend_configuration() {
  local contract="$1" state="$2" declared_source
  jq -e '.spec.roles["agentic-engineer"].spendStewardshipEnabled
    | type == "boolean" and . == false' "${state}" >/dev/null 2>&1 ||
    fail "consumer spend stewardship must remain explicitly boolean false"
  declared_source="$(awk -F '|' '
    /^### Spend contract( |$)/ { in_spend = 1; next }
    in_spend && /^#/ { in_spend = 0 }
    in_spend && $2 ~ /^[[:space:]]*\*\*Effective desired state\*\*[[:space:]]*$/ {
      sources++
      if (!match($3, /\]\([^()]+\)/)) exit 1
      source = substr($3, RSTART + 2, RLENGTH - 3)
    }
    END { if (sources != 1) exit 1; print source }
  ' "${contract}")" ||
    fail "Spend contract must declare exactly one effective desired-state document"
  [ "${declared_source}" = '.claude/plugin-consumption/agentic-engineering.desired-state.json' ] ||
    fail "Spend contract effective desired-state document must resolve to the consumer mirror"
}
assert_spend_configuration "${constitution}" "${desired_state}"
cmp -s "${desired_state}" "${plugin_root}/resources/provider-neutral.desired-state.json" ||
  fail "consumer desired-state mirror differs from the pinned canonical document"

# Exercise the same check on invalid inputs; no runtime registry or live spend
# source is involved. A correct path outside the Spend contract cannot mask drift.
(
  spend_tmp="$(mktemp -d)"
  trap 'rm -rf "${spend_tmp}"' EXIT
  for invalid_flag in missing null '"false"' 0 '[]' '{}' true; do
    if [ "${invalid_flag}" = missing ]; then
      jq 'del(.spec.roles["agentic-engineer"].spendStewardshipEnabled)' \
        "${desired_state}" > "${spend_tmp}/state.json"
    else
      jq --argjson flag "${invalid_flag}" \
        '.spec.roles["agentic-engineer"].spendStewardshipEnabled = $flag' \
        "${desired_state}" > "${spend_tmp}/state.json"
    fi
    if (assert_spend_configuration "${constitution}" "${spend_tmp}/state.json") \
      > "${spend_tmp}/failure" 2>&1; then
      fail "spend configuration accepted invalid flag ${invalid_flag}"
    fi
    grep -Fq 'must remain explicitly boolean false' "${spend_tmp}/failure" ||
      fail "invalid spend flag failed for an unrelated reason"
  done
  for invalid_source in missing wrong duplicate outside; do
    awk -v scenario="${invalid_source}" '
      /^\| \*\*Effective desired state\*\* \|/ {
        if (scenario == "missing" || scenario == "outside") next
        if (scenario == "wrong") sub(/\]\([^)]*\)/, "](wrong.json)")
        if (scenario == "duplicate") print
      }
      { print }
    ' "${constitution}" > "${spend_tmp}/AGENTS.md"
    if [ "${invalid_source}" = outside ]; then
      printf '\n### Unrelated example\n' >> "${spend_tmp}/AGENTS.md"
      awk '/^\| \*\*Effective desired state\*\* \|/' "${constitution}" \
        >> "${spend_tmp}/AGENTS.md"
    fi
    if (assert_spend_configuration "${spend_tmp}/AGENTS.md" "${desired_state}") \
      > "${spend_tmp}/failure" 2>&1; then
      fail "spend configuration accepted ${invalid_source} effective source"
    fi
    grep -Fq 'Spend contract' "${spend_tmp}/failure" ||
      fail "invalid spend source failed for an unrelated reason"
  done
)
assert_prose 'never moves money' \
  "Spend contract does not preserve the never-move-money boundary"
assert_prose 'private financial data never reaches a public artifact' \
  "Spend contract does not preserve the financial-confidentiality boundary"
assert_prose 'no personalised investment advice' \
  "Spend contract does not preserve the no-investment-advice boundary"
assert_prose 'Protected-outcomes floor' \
  "Spend contract does not name the protected-outcomes floor the cost pass vetoes against"
assert_prose 'fails closed on the cost dimension only' \
  "Spend contract does not fail closed on the cost dimension when its facts are missing"
# Feature-flag-first: the decision-producing half must ship default-off, gated on the private
# channel, so an unresolved destination cannot leave the ask path live.
assert_prose 'DEFAULT-OFF until the private channel resolves' \
  "Spend contract does not gate the decision-producing half default-off"
# The channel restriction applies only after the upstream opt-in and deployment
# prerequisites resolve; its presence must never imply that spend is enabled.
assert_prose 'Spend stewardship is disabled in the effective desired state; ordinary operate and advance work continue.' \
  "Spend contract does not keep disabled spend separate from ordinary engineering"
assert_prose 'Only after the reviewed entrypoint resolves explicit spend enablement and the required deployment facts' \
  "Spend contract does not require upstream opt-in and prerequisites before a cost pass"
assert_prose "the cost pass run steps 1–4 of its run loop and **stop before step 5's ask**" \
  "Spend contract does not tie the stop to the unresolved channel and the financial-ask boundary"
assert_prose 'Resolving the channel is a further prerequisite for financial decisions, never spend opt-in; both are maintainer acts, never agent ones.' \
  "Spend contract does not reserve activation to the maintainer"
refute_prose 'rather than a config toggle' \
  "Spend contract still treats the private channel as the only spend gate"
# The unresolved-channel state must read the same everywhere. This site previously said
# "route anything blocking through the run report", which contradicted the gate by letting a
# financial decision be parked in the report instead of not being produced at all.
assert_prose 'route only **non-financial** blockers through the run report' \
  "Spend contract lets a financial decision be parked in the run report while the channel is unresolved"

for spend_source in "${finops_skill}" "${lifestyle_floor}" "${snapshot}"; do
  [ -f "${spend_source}" ] ||
    fail "Spend contract names a source that does not exist: ${spend_source}"
done

# The canonical plugin actor must carry the merged mandate. The local alias deliberately does
# not repeat it; asserting these boundaries there would force the duplication this contract bans.
assert_canonical_engineer_prose 'Spend stewardship — the money side of the same portfolio' \
  "canonical plugin engineer does not carry the merged spend mandate"
assert_canonical_engineer_prose 'You never move money' \
  "canonical plugin engineer does not carry the never-move-money boundary"
grep -Fq 'drive the reviewed head to merge' "${finops_skill}" ||
  fail "spend run loop does not drive its engineering PR through merge"

[ ! -e "${repo_root}/.claude/agents/agent-improver.md" ] ||
  fail "deployment-local Agent Improver fork still exists"
[ ! -e "${repo_root}/.claude/skills/agent-improvement/SKILL.md" ] ||
  fail "deployment-local Agent Improver skill fork still exists"
[ ! -e "${repo_root}/.claude/agents/finops-engineer.md" ] ||
  fail "standalone FinOps agent still exists; spend is merged into the primary engineer"

jq -e '
  .enabledPlugins == {"agentic-engineering@devantler-plugins": true}
' "${settings}" > /dev/null ||
  fail "runtime settings do not enable only the reviewed agentic-engineering plugin"

# The plugin can ship a tool-neutral guard and Claude's JSON adapter, but only the
# consumer can attach a hook to this deployment's surveyor. Verify the native agent
# frontmatter structurally: an UNSCOPED project-wide Bash hook would also constrain the
# engineer's legitimate write lane, while a prose promise would not intercept anything.
# The plugin agent type ignores this frontmatter, so it is reached instead by the
# agent_type-scoped project hook that surveyor-hook-dispatch.test.sh pins (monorepo#3057).
# The hook expands this variable in Claude, not in this test.
# shellcheck disable=SC2016
expected_surveyor_hook='"$CLAUDE_PROJECT_DIR"/.claude/scripts/portfolio-surveyor-forge-hook.sh'
SURVEYOR_HOOK_COMMAND="${expected_surveyor_hook}" yq --front-matter=extract -e '
  (.hooks | has("PreToolUse"))
  and (.hooks | keys | length == 1)
  and (.hooks.PreToolUse | length == 1)
  and (.hooks.PreToolUse[0] | has("hooks"))
  and (.hooks.PreToolUse[0] | has("matcher"))
  and (.hooks.PreToolUse[0] | keys | length == 2)
  and (.hooks.PreToolUse[0].matcher == "Bash")
  and (.hooks.PreToolUse[0].hooks | length == 1)
  and (.hooks.PreToolUse[0].hooks[0] | has("command"))
  and (.hooks.PreToolUse[0].hooks[0] | has("type"))
  and (.hooks.PreToolUse[0].hooks[0] | keys | length == 2)
  and (.hooks.PreToolUse[0].hooks[0].type == "command")
  and (.hooks.PreToolUse[0].hooks[0].command == strenv(SURVEYOR_HOOK_COMMAND))
' "${surveyor_agent}" >/dev/null ||
  fail "portfolio-surveyor does not carry exactly one agent-scoped Bash PreToolUse forge hook"

# GH_TELEMETRY is process state, not command text. The guard deliberately refuses an
# env-prefixed gh command, so the runtime must supply the disabling value to the shell
# before the candidate command reaches the hook.
jq -e '
  .env == {"GH_TELEMETRY": "0"}
' "${settings}" >/dev/null ||
  fail "runtime settings do not export GH_TELEMETRY=0 to the surveyor shell"

if [ ! -f "${surveyor_hook_resolver}" ] \
  || [ ! -x "${surveyor_hook_resolver}" ] \
  || [ -L "${surveyor_hook_resolver}" ]; then
  fail "consumer does not provide a regular executable resolver for the reviewed surveyor hook adapter"
fi

# Exercise the complete consumer-to-plugin path without running any candidate command.
# A fixture registry points the resolver at the pinned, reviewed plugin tree already
# initialised by this contract's CI job. The real adapter and real guard then classify
# one read and one write, so a resolver that merely finds a file cannot satisfy this.
hook_tmp="$(mktemp -d)"
trap 'rm -rf "${hook_tmp}"' EXIT
hook_config="${hook_tmp}/claude"
hook_registry="${hook_config}/plugins/installed_plugins.json"
mkdir -p "$(dirname "${hook_registry}")"
write_hook_registry() {
  jq -n --arg install_path "$1" '{
    version: 2,
    plugins: {
      "agentic-engineering@devantler-plugins": [
        {installPath: $install_path}
      ]
    }
  }' > "${hook_registry}"
}
run_surveyor_hook() {
  local payload="$1"
  if [ "${GH_TELEMETRY+x}" = x ]; then
    printf '%s\n' "${payload}" |
      CLAUDE_CONFIG_DIR="${hook_config}" GH_TELEMETRY="${GH_TELEMETRY}" \
        "${surveyor_hook_resolver}"
  else
    printf '%s\n' "${payload}" |
      CLAUDE_CONFIG_DIR="${hook_config}" "${surveyor_hook_resolver}"
  fi
}

write_hook_registry "${plugin_root}"
GH_TELEMETRY=0
export GH_TELEMETRY
safe_payload='{"tool_input":{"command":"gh pr list --repo devantler-tech/monorepo --state open"}}'
run_surveyor_hook "${safe_payload}" >/dev/null ||
  fail "consumer surveyor hook refused a guard-approved forge read"

write_payload='{"tool_input":{"command":"gh pr merge 1 --repo devantler-tech/monorepo"}}'
set +e
write_output="$(run_surveyor_hook "${write_payload}" 2>&1)"
write_status=$?
set -e
[ "${write_status}" -eq 2 ] ||
  fail "consumer surveyor hook did not block a forge write (exit ${write_status})"
case "${write_output}" in
  *'gh pr merge is not a read verb'*) ;;
  *) fail "consumer surveyor hook blocked a write without the reviewed guard's reason" ;;
esac

# The reviewed guard admits a consuming deployment's own classifier only when this
# deployment declares it. The declaration is what ACTIVATES the capability, so it is
# asserted behaviourally: without it the surveyor falls back to hand-deriving PR
# ownership, which decides whether a `devantler` comment is the maintainer's control
# channel or the agent's own output.
consumer_classifier="${repo_root}/.claude/scripts/pr-ownership-disclosure.sh"
if [ ! -f "${consumer_classifier}" ] \
  || [ ! -x "${consumer_classifier}" ] \
  || [ -L "${consumer_classifier}" ]; then
  fail "consumer does not provide a regular executable PR-ownership classifier"
fi

classifier_payload="$(jq -nc --arg cls "${consumer_classifier}" '{
  tool_input: {
    command: ("gh pr view 1 --repo devantler-tech/monorepo --json body --jq '.body' | "
      + $cls + " --input -")
  }
}')"
run_surveyor_hook "${classifier_payload}" >/dev/null ||
  fail "consumer surveyor hook refused the declared PR-ownership classifier"

# The declaration must be NARROW. A blanket "any local program may filter a forge read"
# would let `cat ~/.config/gh/hosts.yml`-shaped reads through in the same position, so
# an undeclared program in the identical pipeline shape must still be refused.
undeclared_payload="$(jq -nc --arg other "${repo_root}/.claude/scripts/memory-hygiene.sh" '{
  tool_input: {
    command: ("gh pr view 1 --repo devantler-tech/monorepo --json body | " + $other + " --input -")
  }
}')"
set +e
undeclared_output="$(run_surveyor_hook "${undeclared_payload}" 2>&1)"
undeclared_status=$?
set -e
[ "${undeclared_status}" -eq 2 ] ||
  fail "consumer surveyor hook admitted an UNDECLARED local program (exit ${undeclared_status})"
case "${undeclared_output}" in
  *'is not on the read-only allowlist'*) ;;
  *) fail "undeclared program was refused for the wrong reason: ${undeclared_output}" ;;
esac

# A declared classifier in LEADING position is reading something local, not filtering a
# forge read — the guard must still require the pipeline to start at the forge.
leading_payload="$(jq -nc --arg cls "${consumer_classifier}" '{
  tool_input: {command: ($cls + " --input - | jq .")}
}')"
set +e
leading_output="$(run_surveyor_hook "${leading_payload}" 2>&1)"
leading_status=$?
set -e
[ "${leading_status}" -eq 2 ] ||
  fail "consumer surveyor hook admitted the classifier in leading position (exit ${leading_status})"
case "${leading_output}" in
  *'must begin with a forge command'*) ;;
  *) fail "leading classifier was refused for the wrong reason: ${leading_output}" ;;
esac

# Declaring the classifier only ACTIVATES it if the overlay tells the surveyor to type the
# same word. The guard compares the declared entry to the invoked program by exact string
# equality and expands nothing — `$PWD/…` stays a literal and `$(…)` is refused outright —
# so a relative call site leaves the capability declared and unreachable. Measured
# 2026-08-29: two real surveyor sidechains were denied
# `'.claude/scripts/pr-ownership-disclosure.sh' is not on the read-only allowlist`, 14h after
# the declaration merged, while the assertions above stayed green because they exercise the
# absolute form the overlay never prescribed. Every classifier token is a documented call site;
# only the declared absolute path and its exact `<repo-root>/…` documentation form are admitted.
classifier_site_violations() {
  awk \
    -v absolute="${repo_root}/.claude/scripts/pr-ownership-disclosure.sh" \
    -v documented='<repo-root>/.claude/scripts/pr-ownership-disclosure.sh' '
    {
      line = $0
      while (match(line, /[^[:space:]"`'"'"']*pr-ownership-disclosure\.sh/)) {
        tok = substr(line, RSTART, RLENGTH)
        if (tok != absolute && tok != documented) {
          printf "%d:%s\n", NR, tok
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

bare_classifier_fixture="${hook_tmp}/surveyor-bare-classifier.md"
printf '%s\n' 'pr-ownership-disclosure.sh --input -' > "${bare_classifier_fixture}"
bare_classifier_sites="$(classifier_site_violations "${bare_classifier_fixture}")"
case "${bare_classifier_sites}" in
  *'1:pr-ownership-disclosure.sh'*) ;;
  *) fail "surveyor classifier-site check did not reject a bare classifier command" ;;
esac

unrelated_classifier_fixture="${hook_tmp}/surveyor-unrelated-classifier.md"
printf '%s\n' '/tmp/pr-ownership-disclosure.sh --input -' > "${unrelated_classifier_fixture}"
unrelated_classifier_sites="$(classifier_site_violations "${unrelated_classifier_fixture}")"
case "${unrelated_classifier_sites}" in
  *'1:/tmp/pr-ownership-disclosure.sh'*) ;;
  *) fail "surveyor classifier-site check admitted an unrelated absolute classifier path" ;;
esac

invalid_classifier_sites="$(classifier_site_violations "${surveyor_agent}")"
[ -z "${invalid_classifier_sites}" ] ||
  fail "surveyor overlay documents a NON-ABSOLUTE call to the declared classifier, which the guard refuses by construction. Prescribe the absolute form (\`<repo-root>/.claude/scripts/pr-ownership-disclosure.sh\`), since the guard expands neither \$PWD nor command substitution: ${invalid_classifier_sites}"

# The exact path is not sufficient: the guard also requires the FIRST pipeline segment to be a
# forge command. Pin the documented call as one admitted unit so a local producer such as `printf`
# cannot leave the classifier unreachable while the path-only assertion above stays green.
documented_classifier_call='gh pr view <n> --repo devantler-tech/<repo> --json body --jq .body | <repo-root>/.claude/scripts/pr-ownership-disclosure.sh --input -'
grep -Fq "${documented_classifier_call}" "${surveyor_agent}" ||
  fail "surveyor overlay does not prescribe the forge-first classifier call that the read-only guard admits"

# Ground that lexical assertion in the guard's own behaviour so it cannot decay into a style
# rule: the relative form must really be refused, and for this reason.
relative_payload="$(jq -nc '{
  tool_input: {
    command: "gh pr view 1 --repo devantler-tech/monorepo --json body --jq .body | .claude/scripts/pr-ownership-disclosure.sh --input -"
  }
}')"
set +e
relative_output="$(run_surveyor_hook "${relative_payload}" 2>&1)"
relative_status=$?
set -e
[ "${relative_status}" -eq 2 ] ||
  fail "surveyor hook admitted a RELATIVE classifier call (exit ${relative_status})"
case "${relative_output}" in
  *'is not on the read-only allowlist'*) ;;
  *) fail "relative classifier call was refused for the wrong reason: ${relative_output}" ;;
esac

# The programmed-bot review-exemption classifier is declared the same way (monorepo#3123). Before
# it was, every surveyor call was refused and each release or updater PR reached the orchestrator
# as QUERY-UNKNOWN, so exempt PRs sat green and unmerged. Pin both halves: the hook admits the
# documented stdin pipeline, and the overlay names the classifier only by its absolute call site.
exemption_classifier="${repo_root}/.claude/scripts/programmed-bot-review-exemption.sh"
exemption_program="'{repo:\"homebrew-tap\",commits:add}'"
exemption_payload="$(jq -nc --arg cls "${exemption_classifier}" --arg prog "${exemption_program}" '{
  tool_input: {
    command: ("gh api --paginate --slurp repos/devantler-tech/homebrew-tap/pulls/1/commits | jq -c "
      + $prog + " | " + $cls + " --input -")
  }
}')"
run_surveyor_hook "${exemption_payload}" >/dev/null ||
  fail "consumer surveyor hook refused the declared programmed-bot exemption classifier (monorepo#3123)"
exemption_sites="$(grep -o '[^[:space:]"`'"'"']*programmed-bot-review-exemption\.sh[^[:space:]`]*' "${surveyor_agent}" |
  grep -vxF '<repo-root>/.claude/scripts/programmed-bot-review-exemption.sh' || true)"
[ -z "${exemption_sites}" ] ||
  fail "surveyor overlay calls the exemption classifier by a form the guard refuses; use <repo-root>/.claude/scripts/programmed-bot-review-exemption.sh --input -: ${exemption_sites}"
grep -Fq '| <repo-root>/.claude/scripts/programmed-bot-review-exemption.sh --input -' "${surveyor_agent}" ||
  fail "surveyor overlay does not prescribe the forge-first stdin call to the exemption classifier"

# The unresolved-thread counter is declared too (monorepo#2670): a hand count of GraphQL pages
# once read an open Major thread as zero. Run the overlay's OWN documented pipeline through the
# hook, placeholders filled, so the prescription and the guard cannot drift apart.
# shellcheck disable=SC2016 # backticks are literal Markdown in the pattern, not a substitution
threads_command="$(grep -o '`gh api graphql --paginate [^`]*pr-unresolved-threads\.sh --input -`' "${surveyor_agent}" |
  tr -d '`' || true)"
[ "$(printf '%s\n' "${threads_command}" | grep -c .)" = 1 ] ||
  fail "surveyor overlay must prescribe exactly one guarded pr-unresolved-threads.sh pipeline (monorepo#2670)"
threads_command="${threads_command//<repo-root>/${repo_root}}"
threads_command="${threads_command//<repo>/monorepo}"
threads_command="${threads_command//<n>/2436}"
threads_payload="$(jq -nc --arg cmd "${threads_command}" '{tool_input: {command: $cmd}}')"
run_surveyor_hook "${threads_payload}" >/dev/null ||
  fail "consumer surveyor hook refused the overlay's unresolved-thread pipeline (monorepo#2670)"
threads_sites="$(grep -o '[^[:space:]"`'"'"']*pr-unresolved-threads\.sh[^[:space:]`]*' "${surveyor_agent}" |
  grep -vxF '<repo-root>/.claude/scripts/pr-unresolved-threads.sh' || true)"
[ -z "${threads_sites}" ] ||
  fail "surveyor overlay calls pr-unresolved-threads.sh by a form the guard refuses: ${threads_sites}"

# The CodeRabbit summary-verdict helper is declared too (monorepo#3529): the overlay told the
# surveyor to judge a summary with it (monorepo#2653) while the guard refused every call, 5 times in
# one day, and the refused surveyor fell back to judging the summary by eye. Run the overlay's OWN
# documented pipeline through the hook so the prescription and the declaration cannot drift apart.
# shellcheck disable=SC2016 # backticks are literal Markdown in the pattern, not a substitution
verdict_command="$(grep -o '`gh api [^`]*coderabbit-summary-verdict\.sh --input -`' "${surveyor_agent}" |
  tr -d '`' || true)"
[ "$(printf '%s\n' "${verdict_command}" | grep -c .)" = 1 ] ||
  fail "surveyor overlay must prescribe exactly one guarded coderabbit-summary-verdict.sh pipeline (monorepo#3529)"
verdict_command="${verdict_command//<repo-root>/${repo_root}}"
verdict_command="${verdict_command//<repo>/monorepo}"
verdict_command="${verdict_command//<comment-id>/5780024602}"
verdict_command="${verdict_command//<headRefOid>/aec327979c1f29383cce7aed0df46ab8e1f90b8f}"
verdict_payload="$(jq -nc --arg cmd "${verdict_command}" '{tool_input: {command: $cmd}}')"
run_surveyor_hook "${verdict_payload}" >/dev/null ||
  fail "consumer surveyor hook refused the overlay's CodeRabbit summary-verdict pipeline (monorepo#3529)"
verdict_sites="$(grep -o '[^[:space:]"`'"'"']*coderabbit-summary-verdict\.sh[^[:space:]`]*' "${surveyor_agent}" |
  grep -vxF '<repo-root>/.claude/scripts/coderabbit-summary-verdict.sh' || true)"
[ -z "${verdict_sites}" ] ||
  fail "surveyor overlay calls coderabbit-summary-verdict.sh by a form the guard refuses: ${verdict_sites}"

# The local-review-round classifier likewise (monorepo#2697): the contract prescribes it
# (monorepo#3487) while the guard refused 3 of the first 5 surveyor calls, and the refused
# surveyor judged the round by eye. Run the overlay's OWN pipeline through the hook.
# shellcheck disable=SC2016 # backticks are literal Markdown in the pattern, not a substitution
round_command="$(grep -o '`gh api [^`]*local-review-verdict\.sh --input -`' "${surveyor_agent}" |
  tr -d '`' || true)"
[ "$(printf '%s\n' "${round_command}" | grep -c .)" = 1 ] ||
  fail "surveyor overlay must prescribe exactly one guarded local-review-verdict.sh pipeline (monorepo#2697)"
round_command="${round_command//<repo-root>/${repo_root}}"
round_command="${round_command//<repo>/platform}"
round_command="${round_command//<n>/3001}"
round_command="${round_command//<headRefOid>/63c61e5a251ef35a83ab21e98ec6b4aaecddf26a}"
round_payload="$(jq -nc --arg cmd "${round_command}" '{tool_input: {command: $cmd}}')"
run_surveyor_hook "${round_payload}" >/dev/null ||
  fail "consumer surveyor hook refused the overlay's local-review-verdict pipeline (monorepo#2697)"
round_sites="$(grep -o '[^[:space:]"`'"'"']*local-review-verdict\.sh[^[:space:]`]*' "${surveyor_agent}" |
  grep -vxF '<repo-root>/.claude/scripts/local-review-verdict.sh' || true)"
[ -z "${round_sites}" ] ||
  fail "surveyor overlay calls local-review-verdict.sh by a form the guard refuses: ${round_sites}"

# The CodeRabbit review-object classifier likewise (monorepo#3572): the contract names it
# (monorepo#3571), and an undeclared helper leaves the surveyor judging review objects by eye.
# Run the overlay's OWN pipeline through the hook, and prove a relative-path call is refused so
# the declaration cannot be satisfied by a helper outside the reviewed checkout.
# shellcheck disable=SC2016 # backticks are literal Markdown in the pattern, not a substitution
object_command="$(grep -o '`gh api [^`]*coderabbit-review-verdict\.sh --input -`' "${surveyor_agent}" |
  tr -d '`' || true)"
[ "$(printf '%s\n' "${object_command}" | grep -c .)" = 1 ] ||
  fail "surveyor overlay must prescribe exactly one guarded coderabbit-review-verdict.sh pipeline (monorepo#3572)"
object_command="${object_command//<repo-root>/${repo_root}}"
object_command="${object_command//<repo>/monorepo}"
object_command="${object_command//<n>/3571}"
object_command="${object_command//<review-id>/5310251776}"
object_command="${object_command//<headRefOid>/0358c8e6be4fe701fc65b67910a37e5ae07de354}"
object_payload="$(jq -nc --arg cmd "${object_command}" '{tool_input: {command: $cmd}}')"
run_surveyor_hook "${object_payload}" >/dev/null ||
  fail "consumer surveyor hook refused the overlay's CodeRabbit review-object pipeline (monorepo#3572)"
relative_object_command="${object_command//${repo_root}\/.claude\/scripts\//.claude/scripts/}"
[ "${relative_object_command}" != "${object_command}" ] ||
  fail "negative control did not rewrite the review-object helper path (monorepo#3572)"
relative_object_payload="$(jq -nc --arg cmd "${relative_object_command}" '{tool_input: {command: $cmd}}')"
if run_surveyor_hook "${relative_object_payload}" >/dev/null 2>&1; then
  fail "consumer surveyor hook admitted a RELATIVE coderabbit-review-verdict.sh call (monorepo#3572)"
fi
object_sites="$(grep -o '[^[:space:]"`'"'"']*coderabbit-review-verdict\.sh[^[:space:]`]*' "${surveyor_agent}" |
  grep -vxF '<repo-root>/.claude/scripts/coderabbit-review-verdict.sh' || true)"
[ -z "${object_sites}" ] ||
  fail "surveyor overlay calls coderabbit-review-verdict.sh by a form the guard refuses: ${object_sites}"

unset GH_TELEMETRY
telemetry_probe="${hook_tmp}/telemetry-probe.sh"
# shellcheck disable=SC2016  # fixture must inspect its own child environment
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'cat >/dev/null' \
  'if [ "${GH_TELEMETRY+x}" = x ]; then printf "set\\n"; else printf "unset\\n"; fi' \
  > "${telemetry_probe}"
chmod +x "${telemetry_probe}"
real_surveyor_hook_resolver="${surveyor_hook_resolver}"
surveyor_hook_resolver="${telemetry_probe}"
telemetry_presence="$(run_surveyor_hook '{}')"
surveyor_hook_resolver="${real_surveyor_hook_resolver}"
[ "${telemetry_presence}" = unset ] ||
  fail "consumer surveyor hook test helper synthesizes GH_TELEMETRY when the runtime leaves it absent"

set +e
telemetry_output="$(run_surveyor_hook "${safe_payload}" 2>&1)"
telemetry_status=$?
set -e
[ "${telemetry_status}" -eq 2 ] ||
  fail "consumer surveyor hook allowed gh without disabling telemetry (exit ${telemetry_status})"
case "${telemetry_output}" in
  *'export GH_TELEMETRY=0 before any gh read'*) ;;
  *) fail "consumer surveyor hook refused missing telemetry without the reviewed guard's reason" ;;
esac

# Finding an executable at the registered path is insufficient: the runtime tree is
# independently mutable and can drift from the reviewed bytes. A changed adapter must
# fail before use even when its executable bit remains set.
tampered_plugin="${hook_tmp}/tampered-plugin"
cp -R "${plugin_root}" "${tampered_plugin}"
printf '\n# unreviewed drift\n' >> "${tampered_plugin}/scripts/surveyor-forge-readonly.sh"
chmod +x "${tampered_plugin}/scripts/surveyor-forge-readonly.sh"
write_hook_registry "${tampered_plugin}"
GH_TELEMETRY=0
export GH_TELEMETRY
set +e
tampered_output="$(run_surveyor_hook "${safe_payload}" 2>&1)"
tampered_status=$?
set -e
[ "${tampered_status}" -eq 2 ] ||
  fail "consumer surveyor hook trusted an adapter whose bytes differ from desired state (exit ${tampered_status})"
case "${tampered_output}" in
  *'sha256 does not match desired state'*) ;;
  *) fail "consumer surveyor hook refused a drifted adapter without an actionable digest reason" ;;
esac

# The guard can execute the sibling default-branch classifier for one admitted
# command shape. Verify that transitive executable before any candidate command,
# even when this particular command would not reach it.
tampered_classifier_plugin="${hook_tmp}/tampered-classifier-plugin"
cp -R "${plugin_root}" "${tampered_classifier_plugin}"
printf '\n# unreviewed drift\n' >> \
  "${tampered_classifier_plugin}/scripts/classify-default-branch-ci-runs.sh"
chmod +x "${tampered_classifier_plugin}/scripts/classify-default-branch-ci-runs.sh"
write_hook_registry "${tampered_classifier_plugin}"
set +e
tampered_classifier_output="$(run_surveyor_hook "${safe_payload}" 2>&1)"
tampered_classifier_status=$?
set -e
[ "${tampered_classifier_status}" -eq 2 ] ||
  fail "consumer surveyor hook trusted a transitive classifier whose bytes differ from desired state (exit ${tampered_classifier_status})"
case "${tampered_classifier_output}" in
  *'scripts/classify-default-branch-ci-runs.sh sha256 does not match desired state'*) ;;
  *) fail "consumer surveyor hook refused a drifted classifier without an actionable digest reason" ;;
esac

# The guard also admits the bundled unresolved-thread counter by its installed path,
# so the surveyor can execute it: a drifted counter must fail the same way.
tampered_counter_plugin="${hook_tmp}/tampered-counter-plugin"
cp -R "${plugin_root}" "${tampered_counter_plugin}"
printf '\n# unreviewed drift\n' >> \
  "${tampered_counter_plugin}/scripts/count-unresolved-review-threads.sh"
chmod +x "${tampered_counter_plugin}/scripts/count-unresolved-review-threads.sh"
write_hook_registry "${tampered_counter_plugin}"
set +e
tampered_counter_output="$(run_surveyor_hook "${safe_payload}" 2>&1)"
tampered_counter_status=$?
set -e
[ "${tampered_counter_status}" -eq 2 ] ||
  fail "consumer surveyor hook trusted a thread counter whose bytes differ from desired state (exit ${tampered_counter_status})"
case "${tampered_counter_output}" in
  *'scripts/count-unresolved-review-threads.sh sha256 does not match desired state'*) ;;
  *) fail "consumer surveyor hook refused a drifted thread counter without an actionable digest reason" ;;
esac

jq -e '
  .spec.guardrails | index(
    "Write-capable roles own selected engineering work from claim through exact-head review and merge; issue-only handoff is allowed only for a named external blocker or missing authority."
  ) != null
' "${desired_state}" > /dev/null ||
  fail "provider-neutral desired state does not preserve delivery ownership"

jq -e '
  .spec.guardrails | index(
    "Spend stewardship never moves money: prepare the financial decision, route it to the maintainer'"'"'s declared private channel, and keep private financial data out of every public artifact."
  ) != null
' "${desired_state}" > /dev/null ||
  fail "provider-neutral desired state does not preserve the never-move-money boundary"

# A resurrected standalone FinOps role or schedule would put a second scheduled writer
# back over the repositories the engineer already owns — the exact shape the merge removed.
jq -e '
  (.spec.roles | has("finops-engineer") | not)
  and (.spec.runtime.scheduler.schedules | has("finops-engineer") | not)
  and (.spec.consumer | has("requiredWhenFinOpsEnabled") | not)
  and (.spec.consumer.requiredWhenSpendStewardshipEnabled == ["Spend contract"])
' "${desired_state}" > /dev/null ||
  fail "desired state must resolve spend through the Spend contract, not a separate FinOps role"

# GitHub expression tokens are literal workflow syntax, not shell expansions.
# shellcheck disable=SC2016
grep -Fq 'agent-role-delivery-contract: ${{ steps.filter.outputs.agent-role-delivery-contract }}' "${workflow}" ||
  fail "CI does not export the agent-role delivery contract filter"
grep -Fq 'test-agent-role-delivery-contract:' "${workflow}" ||
  fail "CI does not define the agent-role delivery contract job"
grep -Fq 'run: bash .claude/scripts/agent-role-delivery-contract.test.sh' "${workflow}" ||
  fail "CI does not execute the agent-role delivery contract test"
# shellcheck disable=SC2016
grep -Fq '${{ needs.test-agent-role-delivery-contract.result }}' "${workflow}" ||
  fail "required checks do not aggregate the agent-role delivery contract"

# Bind each new consumer surface to THIS job's filter. A global grep is insufficient:
# portfolio-surveyor.md already appears under sibling jobs, so moving it out of this
# filter would otherwise leave a hook-only regression with no delivery-contract run.
agent_role_filter="$(awk '
  $0 == "            agent-role-delivery-contract:" { in_filter = 1; next }
  in_filter && $0 ~ /^            [a-z0-9-]+:$/ { exit }
  in_filter { print }
' "${workflow}")"
[ -n "${agent_role_filter}" ] ||
  fail "CI does not define the agent-role-delivery-contract path filter"
for guarded_surface in \
  ".claude/agents/portfolio-surveyor.md" \
  ".claude/scripts/portfolio-surveyor-forge-hook.sh"; do
  case "${agent_role_filter}" in
    *"- '${guarded_surface}'"*) ;;
    *) fail "agent-role delivery contract filter does not run for ${guarded_surface}" ;;
  esac
done

# The last-resort Slack channel must be reachable from an unattended run, and must say
# exactly what that reach is worth (monorepo#3014). Each guard pins one property whose loss
# would silently reopen that issue: the private destination, the unattended authorization,
# resolve-before-ask, the missing notification, and the delivered-only record.
assert_prose "as a DM to the maintainer's own Slack user" \
  "Maintainer channels no longer names the self-DM as the Slack destination"
assert_prose "never a channel. Every channel in the workspace is public" \
  "Maintainer channels no longer forbids posting a Slack ask to a public channel"
assert_prose "Unattended runs may send it" \
  "Maintainer channels no longer authorizes unattended runs to send the Slack ask"
assert_prose "the machine-local scheduler pointer must name this action too" \
  "Maintainer channels no longer requires the scheduler pointer to name the Slack action"
assert_prose "Try to resolve the blocker before asking" \
  "Maintainer channels lets an authority blocker become an ask without an attempt to resolve it"
assert_prose "It does not notify him." \
  "Maintainer channels overstates the Slack self-DM as a notification"
assert_prose "Never record an ask that was not delivered." \
  "Maintainer channels lets an undelivered Slack ask be recorded on a blocker line"
# "Once per blocker" alone contradicts the blocker-line rule that an authority ask goes
# stale after 14 days and must be renewed: a run reading it literally never re-raises.
assert_prose "renew it only when the blocker-line check reports it \`STALE-ASK\`" \
  "Maintainer channels forbids renewing a stale Slack ask, contradicting the STALE-ASK rule"
# The check reads a blocker record as the whole paragraph that starts with `**Blocker:**`,
# so an ask appended to a line that is followed by more prose is read as prose and
# stays NO-ASK. Measured 2026-09-13 on ksail#5515: a delivered, correctly spelled ask did
# not register until a blank line was added after it.
assert_prose "the ask must be the last thing in that paragraph, followed by a blank line" \
  "Maintainer channels lets a Slack ask be recorded where the blocker check cannot see it"
refute_prose "works from **unattended runs too**, via each agent's Slack tooling" \
  "Issue-driven still claims Slack works unattended without the destination and caveats"

# The plugin's maintainer-PR driving fact (agent-plugins#201) is read from the Trust gate
# section and defaults to hands-off when that section does not declare it. This deployment
# hands the engineer every PR, the maintainer's interactive ones included, so a missing
# declaration would silently stop it driving those. Pin the line INSIDE the section: the same
# words anywhere else in the file are not where the plugin looks.
trust_gate_flat="$(
  awk '/^### Trust gate/ { inside = 1; print; next } inside && /^### / { exit } inside' "${constitution}" |
    tr '\n' ' ' | tr -s '[:space:]' ' '
)"
[ -n "${trust_gate_flat}" ] ||
  fail "could not locate the '### Trust gate' section, so the maintainer-PR driving declaration cannot be checked"
# The section is ~1000 words; running to end-of-file (the next heading renamed) measures tens of
# thousands and would let a declaration elsewhere in the file pass as if it were in the section.
trust_gate_words="$(printf '%s' "${trust_gate_flat}" | wc -w | tr -d ' ')"
[ "${trust_gate_words}" -lt 4000 ] ||
  fail "Trust gate section extracted as ${trust_gate_words} words — its end anchor (the next '### ' heading) is missing, so the declaration check is no longer scoped to the section"
case "${trust_gate_flat}" in
  *'**Maintainer-PR driving: `attribution-only`.**'*) ;;
  *) fail "Trust gate does not declare 'Maintainer-PR driving: \`attribution-only\`' — the plugin would default to hands-off and stop driving the maintainer's interactive PRs this contract hands the engineer" ;;
esac
# The declaration is only as strong as the prose around it: wording that still calls the
# interactive-PR rule a hands-off rule tells the same reader the opposite.
refute_prose "interactive-PR HANDS-OFF rule" \
  "Issue-driven still calls the interactive-PR rule a hands-off rule, contradicting 'Maintainer-PR driving: attribution-only'"
refute_prose "the maintainer's interactive ones (HANDS-OFF)" \
  "Untrusted input still labels the interactive-PR distinction hands-off, contradicting 'Maintainer-PR driving: attribution-only'"

echo "agent-role delivery contract: all assertions passed"
