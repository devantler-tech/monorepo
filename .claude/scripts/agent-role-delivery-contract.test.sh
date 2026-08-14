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
cursor_loader="${repo_root}/.claude/loaders/cursor-daily-ai-engineer.md"
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

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required to verify pinned agent definition integrity"
  fi
}

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
entrypoint="$(jq -r '.spec.source.entrypoint' "${desired_state}")"
[ -d "${plugin_agents}" ] ||
  fail "cannot resolve the entrypoint: ${plugin_agents} is missing. Initialise it with
       .claude/scripts/submodule-init.sh libraries/agent-plugins
       (CI does this in the workflow step before this test)."
[ -f "${plugin_agents}/${entrypoint}.agent.md" ] ||
  fail "desired state entrypoint '${entrypoint}' does not resolve to a bundled agent in ${plugin_agents}"
canonical_engineer="${plugin_agents}/${entrypoint}.agent.md"
canonical_surveyor="${plugin_agents}/portfolio-surveyor.agent.md"
[ -f "${canonical_surveyor}" ] ||
  fail "pinned plugin does not bundle portfolio-surveyor.agent.md"

# The consumer copy used to omit both integrity fields while the pinned plugin resource already
# carried them. That let the gitlink advance without proving that the machine-readable entrypoint
# and delegated surveyor still named the reviewed bytes. Resolve both digests from the pinned files,
# not from a floating default branch or a copied constant.
consumer_entrypoint_sha="$(jq -r '.spec.source.entrypointSha256 // ""' "${desired_state}")"
consumer_surveyor_sha="$(jq -r '.spec.roles["portfolio-surveyor"].definitionSha256 // ""' "${desired_state}")"
[ "${consumer_entrypoint_sha}" = "$(sha256_file "${canonical_engineer}")" ] ||
  fail "consumer desired-state entrypointSha256 does not match the pinned agentic-engineer definition"
[ "${consumer_surveyor_sha}" = "$(sha256_file "${canonical_surveyor}")" ] ||
  fail "consumer desired-state portfolio-surveyor definitionSha256 does not match the pinned definition"

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
grep -Fq 'agentic-engineer.agent.md' "${cursor_loader}" ||
  fail "Cursor adapter does not resolve the canonical plugin role"
grep -Fq '.claude/scripts/submodule-init.sh libraries/agent-plugins' "${cursor_loader}" ||
  fail "Cursor adapter does not pass the plugin path to submodule-init"
grep -Fq 'git -C libraries/agent-plugins fetch origin main' "${cursor_loader}" ||
  fail "Cursor adapter does not refresh the reviewed plugin default branch before loading it"
grep -Fq 'git -C libraries/agent-plugins show origin/main:plugins/agentic-engineering/agents/agentic-engineer.agent.md' \
  "${cursor_loader}" ||
  fail "Cursor adapter does not load the agent from the refreshed reviewed plugin ref"
for cursor_overlay in \
  '.claude/skills/portfolio-maintenance/SKILL.md' \
  '.claude/skills/product-engineering/SKILL.md' \
  '.claude/skills/self-improvement/SKILL.md'; do
  grep -Fq "${cursor_overlay}" "${cursor_loader}" ||
    fail "Cursor adapter does not load deployment overlay ${cursor_overlay}"
done
if grep -Fq '.claude/agents/daily-maintainer.md' "${cursor_loader}"; then
  fail "Cursor adapter still boots from the legacy local alias"
fi

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
# The automation-owned carve-out answers "whose job is it to MUTATE these PRs" correctly, and used to
# answer "is that automation still alive" by accident, with "never look". A six-day total stall of the
# gitsubmodule ecosystem went unreported that way, freezing every submodule pin including the one that
# carries the agent definitions (#2779/#2780). Four separate protections, four separate assertions:
# the scoping, the aggregate keying, the both-halves window, and the restated prohibitions. Deleting
# any one alone must fail on its own message — the others stay green without it, which is exactly why
# they are not one compound check.
assert_prose 'This carve-out bounds action on INDIVIDUAL PRs; it never licenses ignoring whether the automation still runs' \
  "the automation-owned carve-out no longer separates per-PR hands-off from the automation's own liveness"
# Without this the signal collapses back into a per-PR judgement, which is precisely the thing the
# carve-out forbids reasoning about — reintroducing the hands-off pressure it was meant to sidestep.
assert_prose 'Key that signal on the AGGREGATE, never on a PR' \
  "queue liveness is no longer keyed on the aggregate, so it could be read as a per-PR hygiene state"
assert_prose 'nothing created *and* nothing merged over a window materially longer than its configured schedule' \
  "the dead-queue condition no longer requires BOTH nothing-created and nothing-merged over a window"
# The addition must never read as a partial re-opening of the hands-off rule. If this restatement goes,
# an observation duty sits next to the prohibitions with nothing saying they still bind absolutely.
assert_prose 'Every prohibition above stands unchanged and absolute' \
  "the queue-liveness clause no longer restates the mutation prohibitions as unchanged"
# Found by ablation while writing the four above: deleting "One bot PR being red, stale, conflicting or
# review-less remains none of our business" left all four GREEN. That sentence is what keeps the
# per-PR case explicitly OUT of the new duty, so without it a run could start treating one red bot PR
# as the liveness signal — the exact hands-off pressure this clause exists to avoid.
assert_prose 'One bot PR being red, stale, conflicting or review-less remains none of our business' \
  "the queue-liveness clause no longer keeps a single red/stale/conflicting bot PR out of scope"
# Without the positive-evidence requirement the aggregate fires on a HEALTHY ecosystem that simply has
# nothing to update — zero created and zero merged is the correct output then — and sends a run to
# "repair" working automation. Raised as a P2 by Codex on #2782.
assert_prose 'Report it only with positive evidence that the automation was **prevented** from delivering' \
  "the dead-queue signal no longer requires positive evidence, so a quiet healthy ecosystem would fire it"
# WHITELIST, not a fifth named clause chased by a sixth. The two preceding definition PRs converged
# only after inverting a blacklist, because each review round merely named the next unpinned clause.
# The named assertions above stay for their specific failure messages; this pins the whole block so a
# clause nobody thought to name cannot be weakened silently. Extracted by ANCHOR, never line number.
# BOTH anchor lines are READ FROM THE FILE — an extractor that prints a terminating line it invented
# cannot detect a change to the thing it invents, which is a fail-open of exactly this check's shape.
#
# The expected text is INLINE rather than a fixture file. The Agent Improver's grant names AGENTS.md,
# `.claude/scripts/*.test.sh` and `.github/workflows/ci.yaml`; a new `.claude/scripts/fixtures/*.txt`
# is not obviously inside it, and an ambiguous authority question fails closed. Inlining is equally
# strong — this is a committed verbatim copy, not a synthesised expectation — and it removes the
# question entirely.
#
# Written to a temp file by a PLAIN heredoc redirect, never `$(cat <<'EOF' … )`. bash 3.2 — the
# /bin/bash macOS still ships, and what a local pre-push run uses — scans a command substitution for
# its closing paren while tracking quotes, so a lone apostrophe in the heredoc body (this text has
# one, in "ecosystem's") swallows the `)` and the whole file fails to parse. CI's bash 5 parses it
# fine, so the nested form would be green in CI and broken on every developer machine.
queue_expected_file="$(mktemp "${TMPDIR:-/tmp}/queue-block.XXXXXX")"
trap 'rm -f "${queue_expected_file}"' EXIT
cat > "${queue_expected_file}" <<'QUEUE_BLOCK_EOF'
🔴 **This carve-out bounds action on INDIVIDUAL PRs; it never licenses ignoring whether the automation
still runs.** Every prohibition above stands unchanged and absolute — no review request, no comment, no
rebase/recreate, no rerun, no adaptation commit, no arming auto-merge, no merge, no closing an
automation-authored issue — whatever state the PR is in. But *whose job is it to mutate these PRs* and
*is the automation that owns them still alive* are *different questions*, and answering only the first
silently answered the second with "never look". Measured 2026-08-11: the `gitsubmodule` ecosystem had
merged nothing since 2026-08-05T20:15Z and created nothing since 2026-08-06T20:14Z, jammed at its
five-PR limit by five PRs that cannot drain — four never received a CI run at all, the fifth is red —
while the same daily job kept creating npm PRs under that ecosystem's own limit. Every submodule pin in the portfolio froze for six days,
including `libraries/agent-plugins`, the source of the agent definitions every run loads
([monorepo#2779](https://github.com/devantler-tech/monorepo/issues/2779)).
**Key that signal on the AGGREGATE, never on a PR.** One bot PR being red, stale, conflicting or
review-less remains none of our business, exactly as the paragraph above says. The reportable condition
is that the **whole ecosystem produced nothing** — nothing created *and* nothing merged over a window
materially longer than its configured schedule — which no per-PR state can express.
🔴 **Silence alone is NOT the signal — a quiet ecosystem is usually just quiet.** When nothing needs
updating, zero creations and zero merges are the *correct* output, so the aggregate on its own would
send a run to "repair" healthy automation. Report it only with positive evidence that the automation was
**prevented** from delivering: it sits at its configured open-PR limit, or an update is demonstrably
available and has gone unproposed, or its own most recent run is failing or absent. No such evidence,
no signal. Derive that evidence by querying the forge directly — the survey digest is a per-PR
`AUTOMATION-OWNED (NO-ACTION)` line and carries no aggregate history, so it cannot answer this
([monorepo#2783](https://github.com/devantler-tech/monorepo/issues/2783)). Then treat it as a **currency
signal**: report it, and fix its cause on an **agent-owned** branch, exactly as a merged bump that
breaks `main` is repaired without ever touching the bot PR branch.
QUEUE_BLOCK_EOF
# Exit ON the terminating line, not one line after it. A deferred-exit form captures the blank line
# that follows the paragraph, and the two capture paths then disagree: a file redirect keeps that
# blank while `$(…)` strips it, so the pinned copy and the live block can never compare equal.
# Anchor on the TAIL of the terminating sentence only. An anchor carrying the words that precede it
# on the same line breaks whenever an unrelated edit re-wraps the paragraph — which happened during
# this very PR — and the extractor then runs to EOF instead of failing cleanly.
queue_block="$(awk '
  /^🔴 \*\*This carve-out bounds action on INDIVIDUAL PRs/ { f = 1 }
  f { print }
  f && /without ever touching the bot PR branch\.$/ { exit }
' "${constitution}")"
[ -n "${queue_block}" ] ||
  fail "automation-owned queue-liveness block not found in ${constitution} (anchors moved or removed)"
printf '%s\n' "${queue_block}" | diff -u "${queue_expected_file}" - > /dev/null ||
  fail "automation-owned queue-liveness block differs from the copy pinned in this test; update both deliberately in one commit"
grep -Fq 'An issue, recommendation, or draft PR is not completion' "${constitution}" ||
  fail "consumer permits a write-capable role to stop before merge"
grep -Fq '### Writer namespaces' "${constitution}" ||
  fail "consumer does not record namespaces for its scheduled writers"
# Backticks are literal Markdown, not command substitution.
# shellcheck disable=SC2016
grep -Fq 'The `agent-improver` schedule intentionally shares its provider instance' \
  "${constitution}" ||
  fail "consumer does not declare the intentional provider-lane sharing model"
# shellcheck disable=SC2016
for writer_namespace in '`claude/*`' '`codex/*`' '`cursor/*`'; do
  grep -Fq "${writer_namespace}" "${constitution}" ||
    fail "consumer does not record writer namespace ${writer_namespace}"
done
grep -Fq 'remain undeployed and read-only' "${constitution}" ||
  fail "consumer does not fail closed for unmapped Cursor role schedules"
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

# --- The merged spend mandate -------------------------------------------------
# Spend is a dimension of the Agentic Engineer. The consumer must supply the Spend
# contract the plugin entrypoint resolves, and must keep the money boundary that
# used to live in the standalone agent — merging a mandate into a larger definition
# is exactly where a boundary gets quietly dropped by a later edit.
grep -Fq '### Spend contract' "${constitution}" ||
  fail "consumer does not define the Spend contract section the engineer resolves"
grep -Fq '| **Spend contract** |' "${constitution}" ||
  fail "plugin contract table does not map the Spend contract section"
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
# Match the WHOLE clause, not just "stops before": the weak form survives even if the
# contract loses what stops, under which condition, and that resolving it is the maintainer's.
assert_prose "the cost pass runs steps 1–4 of its run loop and **stops before step 5's ask**" \
  "Spend contract does not tie the stop to the unresolved channel and the financial-ask boundary"
assert_prose 'Resolving the channel is what flips the second half on — a maintainer act, never an agent one' \
  "Spend contract does not reserve activation to the maintainer"
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

echo "agent-role delivery contract: all assertions passed"
