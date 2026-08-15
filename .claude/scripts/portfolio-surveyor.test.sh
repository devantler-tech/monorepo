#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
classifier="${repo_root}/.claude/scripts/programmed-bot-review-exemption.sh"
surveyor="${repo_root}/.claude/agents/portfolio-surveyor.md"
constitution="${repo_root}/AGENTS.md"
maintenance_skill="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
monorepo_skill="${repo_root}/.claude/skills/products/monorepo/SKILL.md"
product_engineering_skill="${repo_root}/.claude/skills/product-engineering/SKILL.md"
agent_skills_card="${repo_root}/.claude/skills/products/agent-skills/SKILL.md"
ksail_card="${repo_root}/.claude/skills/products/ksail/SKILL.md"
platform_card="${repo_root}/.claude/skills/products/platform/SKILL.md"
platform_security_surveyor="${repo_root}/.claude/agents/platform-security-surveyor.md"
cursor_loader="${repo_root}/.claude/loaders/cursor-daily-ai-engineer.md"
ci_workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "portfolio surveyor contract: FAIL — $*" >&2
  exit 1
}

for security_definition in "${platform_card}" "${platform_security_surveyor}"; do
  grep -Fq 'Kubescape CR LISTs return spec-stripped skeletons.' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} can mistake a Kubescape LIST skeleton for empty scanner output"
  grep -Fq 'sample 2–3 objects per surface' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} does not require direct per-object Kubescape payload checks"
  grep -Fq 'directly GET every object whose payload contributes' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} can extrapolate cluster-wide findings from a liveness sample"
  # Literal Markdown code spans; command substitution is intentionally disabled.
  # shellcheck disable=SC2016
  grep -Fq 'both named `vulnerabilitymanifests` and their corresponding' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} does not require direct reads of both CVE object types"
  grep -Fq '(Grype matches or scanner version metadata) with coherent paired summaries' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} can accept manifest matches paired with an incoherent CVE summary"
  grep -Fq 'LIST metadata for coverage and freshness' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} does not define a bounded use for Kubescape LISTs"
  grep -Fq 'current workload/container inventory' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} can miss workloads with no vulnerability result object"
  grep -Fq 'report the cluster-wide result as unavailable or partial' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} can overclaim cluster-wide findings when bounded proof is unavailable"
  grep -Fq 'posture, CVE, and runtime each report unavailable or partial' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} does not represent bounded proof failures for every Kubescape surface"
  # Literal Markdown code spans; command substitution is intentionally disabled.
  # shellcheck disable=SC2016
  grep -Fq 'Every confirmed partial coverage gap must also appear in `deltas_needing_action`' "${security_definition}" ||
    fail "${security_definition#"${repo_root}/"} can report a scanner blind spot without making it actionable"
done

grep -Fq 'posture: score <x|unavailable:why>' "${platform_security_surveyor}" ||
  fail "platform security digest cannot represent unavailable posture findings"
grep -Fq 'coverage: posture=<complete|PARTIAL:why>' "${platform_security_surveyor}" ||
  fail "platform security digest does not expose per-surface coverage"
grep -Fq 'cve: crit/high all=<a>/<b>|<unavailable:why>' "${platform_security_surveyor}" ||
  fail "platform security digest cannot represent unavailable CVE findings"
grep -Fq 'runtime: <n|unavailable:why> new detections' "${platform_security_surveyor}" ||
  fail "platform security digest cannot represent unavailable runtime findings"
# An incoherent CVE pair is neither proven nor absent. Without a PARTIAL state the
# only choices are `yes` and `BROKEN`, so the digest reports a healthy scanner over
# evidence the prose has already called not-healthy.
grep -Fq 'cve=<yes|PARTIAL:why|BROKEN:why>' "${platform_security_surveyor}" ||
  fail "platform security digest has no PARTIAL state, so incoherent CVE evidence reads as a live scanner"
grep -Fq 'report `scanners_alive: cve=PARTIAL:<why>`' "${platform_security_surveyor}" ||
  fail "platform security surveyor does not route an incoherent CVE pair to the PARTIAL state"

[[ -x "${classifier}" ]] || fail "programmed-bot exemption classifier is missing or not executable"
grep -Fq '.claude/scripts/programmed-bot-review-exemption.sh' "${surveyor}" ||
  fail "surveyor does not delegate exemption decisions to the exact classifier"
grep -Fq 'programmed agent-skills updater PRs' "${constitution}" ||
  fail "constitution does not exempt programmed agent-skills updater PRs from review"
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq 'agent-plugins` updater PRs require semantic review' "${constitution}" ||
  fail "constitution can still send marketplace instruction updates through the no-review path"
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '`app/botantler-1` is narrowly trusted only for programmed agent-skills updater PRs' "${constitution}" ||
  fail "constitution either misses botantler updater PRs or trusts the App globally"
grep -Fq 'green_review=exempt-programmed-bot' "${surveyor}" ||
  fail "surveyor cannot report a programmed bot review exemption"
# An empty review object is the container GitHub creates for a reply to an existing
# review thread. It is authored by the bot, anchored to the current head, and has zero
# findings — so a green-review test that does not require a substantive body reports a
# clean review on a PR that had none, and a run following the digest merges unreviewed
# work. Measured live on platform#2973.
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq 'object **whose own `body` BEGINS WITH the recognised CodeRabbit review-artifact marker' "${surveyor}" ||
  fail "surveyor can count an empty CodeRabbit reply container as a green review"
grep -Fq 'An EMPTY review object is a reply container, not a review' "${surveyor}" ||
  fail "surveyor does not name the empty-review-container trap"
# A non-empty body is not enough, and neither is pairing it with the head's status: a run
# completing and *some* object carrying text are independent facts, so a non-empty reply
# container can satisfy both while no review of that object exists. Measured on
# monorepo#2677, where one head carried a bodylen=0 container AND a real review under a
# single `Review completed` status. The object must be identified positively instead.
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '`**Actionable comments posted:`' "${surveyor}" ||
  fail "surveyor does not positively identify a CodeRabbit review artifact, so a non-empty non-review body still passes"
grep -Fq 'the status only proves a run completed' "${surveyor}" ||
  fail "surveyor treats the head status as proof the matched object is a substantive review"
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq 'fails closed to `none`' "${surveyor}" ||
  fail "surveyor does not fail closed when the head carries no CodeRabbit status"
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq 'the `description` is the discriminator, never the state' "${surveyor}" ||
  fail "surveyor can read a CodeRabbit status state=success as proof a review ran"
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
# Exit 3 is no longer marketplace-only: an installed-skill update carrying a skill this suite does
# not own reaches it too, so pinning the `agent-plugins` phrasing would re-stale the moment that
# path fires.
grep -Fq 'Exit 3 means a genuine, trusted updater PR that still requires' "${surveyor}" ||
  fail "surveyor cannot distinguish review-bearing updater PRs from untrusted lookalikes"
grep -Fq 'installed-skill' "${surveyor}" ||
  fail "surveyor does not cover the installed-skill route to a review-required updater PR"
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '`botantler-1[bot]` is a candidate only for the programmed agent-skills updater classifier' "${surveyor}" ||
  fail "surveyor either misses botantler updater PRs or trusts the App outside the programmed path"
# The branch/title predicate selects a CLASSIFIER candidate. Letting it also gate whether the row is
# deepened at all leaves a non-matching botantler PR declared statically reviewable and mergeable
# while carrying no pentad and no active-work evidence — invisible rather than assessed.
grep -Fq 'The branch/title test gates the CLASSIFIER, never the deepening' "${surveyor}" ||
  fail "surveyor can skip deepening a non-updater botantler PR instead of treating it as external"
grep -Fq 'ordinary external-author deepening path' "${surveyor}" ||
  fail "surveyor does not route a non-candidate botantler PR through the external deepening path"
grep -Fq 'ksail-bot[bot]' "${surveyor}" ||
  fail "surveyor does not recognize the exact KSail App identity returned by search"
# The activity endpoint returns one page across EVERY ref, so a client-side ref filter is outrun by
# unrelated traffic: the branch's push falls off the page and `pushed:` reads unknown — likeliest
# exactly when a live ownership window would have parked the PR.
grep -Fq 'ref=refs/heads/<headRefName>' "${surveyor}" ||
  fail "surveyor filters repository activity client-side, so a busy repo hides a recent head push"
grep -Fq 'Filter by `ref` in the REQUEST, not only in the `jq`' "${surveyor}" ||
  fail "surveyor does not require server-side ref filtering on the push lookup"
# `none` is a merge blocker, so a diff with nothing to run must have its own state or the whole
# external docs/typo class is reported permanently blocked.
grep -Fq 'behaviour_observed=<check-name|static|none|unknown>' "${surveyor}" ||
  fail "surveyor digest cannot represent a static evaluation, so no-runtime-surface PRs read blocked"
grep -Fq 'That observation has THREE outcomes, not two' "${surveyor}" ||
  fail "surveyor does not distinguish nothing-to-exercise from nothing-exercises-it"
grep -Fq '/pulls/<n>/commits' "${surveyor}" ||
  fail "surveyor does not fetch complete current-head commit provenance"
grep -Fq 'AUTOMATION-OWNED and need NO agent action' "${constitution}" ||
  fail "constitution does not exempt Renovate/Dependabot dependency PRs from agent action"
grep -Fq '`cursor[bot]` on REST surfaces' "${constitution}" ||
  fail "constitution does not map the REST surface for the trusted app/cursor author"
grep -Fq 'Cursor Automation is a trusted PR author' "${constitution}" ||
  fail "constitution does not trust the maintainer-authorized Cursor Automation author"
grep -Fq 'For `app/cursor`, the acting local sibling' "${constitution}" ||
  fail "merge policy still tells the permission-limited Cursor App to arm its own merge"
# EVERY merge mutation carries both pins. `--auto` needs the head pin more than a direct merge does:
# arming defers the merge until checks settle, so a trusted App pushing inside that window gets its
# unevaluated commit merged by the arming already performed.
for merge_mutation in \
  'gh pr merge <n> --repo devantler-tech/<repo> --auto --squash --match-head-commit <sha>' \
  'gh pr merge <n> --repo devantler-tech/<repo> --auto --match-head-commit <sha>'; do
  grep -Fq "${merge_mutation}" "${constitution}" ||
    fail "an App auto-merge path omits --match-head-commit, so it can merge an unevaluated head"
done
# This pinned "`--auto` needs the head pin MORE than the direct merge does" until 2026-08-12. That
# sentence carried a false rider — that the pin makes GitHub refuse a merge of a head pushed after
# arming — and the rider was withdrawn, so pinning the sentence would have held the contract to a
# claim it no longer makes. The PROPERTY worth guarding is unchanged and is what this now asserts:
# that arming widens the evaluated-head gap to however long CI takes.
grep -Fq '`--auto` has the WIDEST exposure window' "${constitution}" ||
  fail "constitution does not explain why arming auto-merge widens the evaluated-head gap"
grep -Fq "The machine-local agents' **own** PRs" "${constitution}" ||
  fail "self-promotion rule still ambiguously includes the permission-limited Cursor cloud lane"
grep -Fq '`cursor[bot]` — **exact' "${surveyor}" ||
  fail "reference surveyor does not deepen PRs authored by the trusted Cursor Automation App"
grep -Fq 'siblings may build, run, review,' "${cursor_loader}" ||
  fail "Cursor loader still prevents trusted sibling instances from driving Cursor-authored PRs"
grep -Fq 'and drive your PRs' "${cursor_loader}" ||
  fail "Cursor loader does not authorize the sibling handoff through merge"
grep -Fq 'Product repositories are in scope' "${cursor_loader}" ||
  fail "Cursor loader still treats its empty boot checkout as a product-repository boundary"
grep -Fq 'submodule-init.sh' "${cursor_loader}" ||
  fail "Cursor loader does not document on-demand submodule-init for product work"
grep -Fq 'environment-membership-bound' "${cursor_loader}" ||
  fail "Cursor loader does not document the ManagePullRequest / open_git_pr membership constraint"
if grep -Fq 'any task requiring a submodule worktree are **not yours**' "${cursor_loader}"; then
  fail "Cursor loader still forbids product work that the cloud lane demonstrably delivers"
fi
if grep -Fq 'monorepo-native advance work' "${cursor_loader}"; then
  fail "Cursor loader still scopes the lane to monorepo-native-only"
fi
cursor_env_json="${repo_root}/.cursor/environment.json"
[ -f "${cursor_env_json}" ] ||
  fail "Cursor .cursor/environment.json is missing (product-scope AC)"
grep -Fq 'repositoryDependencies' "${cursor_env_json}" ||
  fail "Cursor environment.json does not declare repositoryDependencies"
grep -Fq 'npm ci' "${cursor_env_json}" ||
  fail "Cursor environment.json does not preserve the docs npm ci install"
grep -Fq 'github.com/devantler-tech/ksail' "${cursor_env_json}" ||
  fail "Cursor environment.json omits portfolio product repos from repositoryDependencies"
grep -Fq -- "- '.claude/loaders/cursor-daily-ai-engineer.md'" "${ci_workflow}" ||
  fail "Cursor loader changes do not trigger the portfolio surveyor contract job"
if grep -Fq '`app/cursor` is **not** in the contract' "${cursor_loader}"; then
  fail "Cursor loader still classifies its trusted App identity as external"
fi
if grep -Fq '**`app/cursor` is NOT a trusted PR AUTHOR' "${constitution}"; then
  fail "constitution still classifies the maintainer-authorized Cursor App as an external author"
fi
# Lane-agnostic on purpose: the reviewer roster grows (Codex, Cursor Bugbot, CodeRabbit, …), so
# assert the PROHIBITION, not the roster — naming lanes here breaks this test on every lane change.
grep -Fq 'Never request a review from any lane' "${constitution}" ||
  fail "constitution does not explicitly forbid dependency-bot review requests"
grep -Fq 'Do not inspect commit provenance' "${constitution}" ||
  fail "constitution may reclassify dependency-bot PRs after human commits"
grep -Fq 'arm auto-merge, or merge them' "${constitution}" ||
  fail "constitution does not leave dependency-bot merging to repository automation"
grep -Fq 'HEAD-MATCH DECIDES FIRST' "${surveyor}" ||
  fail "surveyor may rank the two Codex outcome surfaces by recency instead of by head sha"
grep -Fq 'Same-sha tie-break: FINDINGS WIN' "${surveyor}" ||
  fail "surveyor leaves two Codex artifacts at the same head undecided — traversal order picks the row"
grep -Fq 'starts with** the extracted sha' "${surveyor}" ||
  fail "surveyor does not state the Codex head match as a prefix of headRefOid"
# The marker sha is abbreviated, so an equality rule against the full 40-character oid can never
# hold — it would mis-report every green Codex review as stale. Guard the regression directly.
if grep -Fq "any major issues\` and that sha equals \`headRefOid\`" "${surveyor}"; then
  fail "surveyor compares the abbreviated Codex marker to headRefOid by equality — never satisfiable"
fi
# A non-matching but well-formed marker is a review of an OLDER head, not an absent review.
# Collapsing it to `none` hides a real artifact and provokes a needless re-request.
grep -Fq 'report it `codex-stale@<sha>`, never `none`' "${surveyor}" ||
  fail "surveyor may report a well-formed non-matching Codex marker as none instead of codex-stale"
grep -Fq 'absent,' "${surveyor}" ||
  fail "surveyor does not reserve none for an absent/malformed/too-short marker"
# Cursor Bugbot publishes BOTH "I found issues" and "I failed to run" as `conclusion: neutral`;
# only `output.title` separates them (measured 2026-07-21: 25 real reviews, then 34 consecutive
# `Error` runs). A rule keyed on `conclusion` alone reports a dead lane as a findings row, which
# hides the outage from the fallback ladder and sends the run hunting for comments that do not exist.
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '`green_review` as `none`, NOT as findings' "${surveyor}" ||
  fail "surveyor may route a failed Bugbot run to the findings state instead of to no-review"
grep -Fq 'bugbot-error@<sha>' "${surveyor}" ||
  fail "surveyor has no state for a Bugbot run that never happened"
grep -Fq '**Reviewed commit:**' "${surveyor}" ||
  fail "surveyor does not teach Codex comment-form greens (#2244 AC1)"
grep -Fq 'not-requested@' "${surveyor}" ||
  fail "surveyor does not distinguish not-requested from none (#2244 AC2)"
grep -Fq 'not-requested@' "${maintenance_skill}" ||
  fail "portfolio-maintenance skill omits not-requested green_review state (#2244)"
# Classification semantics (not mere token presence): zero TOTAL artifacts → not-requested;
# artifacts present with no current-head match → evidence-bearing none(...). Counting only
# current-head matches would misclassify a stale-green PR as never-requested.
grep -Fq 'count **total** review-output artifacts on the PR' "${surveyor}" ||
  fail "surveyor does not define not-requested from total (any-SHA) artifact counts"
grep -Fq 'zero current-head matches alone is not enough' "${surveyor}" ||
  fail "surveyor may treat zero current-head matches as not-requested when stale artifacts exist"
grep -Fq 'every **total** review-output count on the PR is zero' "${maintenance_skill}" ||
  fail "maintenance skill does not require total (any-SHA) zero for not-requested"
grep -Fq 'artifacts that **exist on the PR** but do not match the current head' "${maintenance_skill}" ||
  fail "maintenance skill does not define none(...) from existing artifacts with no head match"
grep -Fq 'Admissible evidence is a direct per-PR check of all three surfaces only' "${constitution}" ||
  fail "constitution fallback does not require per-PR three-surface evidence (#2244 AC3)"
grep -Fq 'Zero review-output on all three surfaces is `not-requested`, not `none`' "${surveyor}" ||
  fail "surveyor may still emit none(…0…) for the never-requested state (#2244)"
# That state tells the surveyor to emit a LANE-SIGNAL row, so the lane and reason enums must admit
# one. The grammar is written out twice, and BOTH sites are asserted: a producer without its schema
# means the outage is never reported at all, which is the failure this change exists to prevent.
# shellcheck disable=SC2016
[ "$(grep -Fc 'lane_signal=<coderabbit|codex|bugbot>:<rate-limit|usage-limit|error>' "${surveyor}")" -eq 2 ] ||
  fail "surveyor's LANE-SIGNAL grammar does not admit a bugbot usage-limit row at both definition sites"
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '| `output.title` |' "${constitution}" ||
  fail "constitution does not name the field that separates Bugbot's two neutral states"
grep -Fq 'Bugbot run failed' "${constitution}" ||
  fail "constitution does not name the marker that identifies a Bugbot run which never happened"
grep -Fq 'usage limit reached' "${constitution}" ||
  fail "constitution does not name the comment that identifies an exhausted Bugbot spend limit"
grep -Fq 'NOT retryable' "${constitution}" ||
  fail "constitution may send a run retrying a Bugbot usage limit that only the maintainer can lift"
grep -Fq 'AUTOMATION-OWNED (NO-ACTION)' "${surveyor}" ||
  fail "surveyor does not short-circuit dependency-bot PRs as no-action"
# #2365 — instrument GraphQL/core remaining at survey start+end before any optimisation. Without
# the budget line a tick that starts exhausted discovers blindness only through failed commands
# (and `gh pr checks` exits 1, indistinguishable from red CI). Pin the probe, the digest shape,
# and the EXHAUSTED_AT_START annotation so a later edit cannot silently drop attribution.
# shellcheck disable=SC2016
grep -Fq 'gh api rate_limit --jq' "${surveyor}" ||
  fail "surveyor does not sample gh api rate_limit at survey start/end"
grep -Fq 'budget: graphql=<start_remaining>→<end_remaining>/<limit> · core=<start_remaining>→<end_remaining>/<limit>' "${surveyor}" ||
  fail "surveyor digest template is missing the fixed-shape budget line"
grep -Fq 'EXHAUSTED_AT_START' "${surveyor}" ||
  fail "surveyor has no EXHAUSTED_AT_START marker for a tick that opens with graphql.remaining=0"
grep -Fq 'Always emit the `budget:` line' "${surveyor}" ||
  fail "surveyor digest rules do not require the budget line on every digest"
grep -Fq 'renovate[bot]' "${surveyor}" ||
  fail "surveyor does not bind no-action to the exact Renovate identity"
grep -Fq 'dependabot[bot]' "${surveyor}" ||
  fail "surveyor does not bind no-action to the exact Dependabot identity"
grep -Fq 'do **not** call' "${surveyor}" ||
  fail "surveyor still permits heavy dependency-PR deepening"
grep -Fq 'count it against' "${surveyor}" ||
  fail "surveyor may still turn dependency automation into operate work"
# Issue-side automation ownership (#2349): Renovate's Dependency Dashboard is an open issue by
# design and will head oldest-first forever unless the surveyor excludes exact author identities
# the same way it already does for dependency PRs. Match author only — never title/labels/age.
grep -Fq 'Short-circuit dependency-automation ISSUES' "${surveyor}" ||
  fail "surveyor does not short-circuit dependency-automation issues as no-action"
grep -Fq 'Exclude them from every oldest-actionable' "${surveyor}" ||
  fail "surveyor may still rank a Renovate Dependency Dashboard as oldest-actionable"
grep -Fq 'platform#313' "${surveyor}" ||
  fail "surveyor does not pin the live Dependency Dashboard counter-example"
grep -Fq 'Never select, triage-as-work, or close' "${surveyor}" ||
  fail "surveyor may still close or triage an automation-authored issue"
grep -Fq 'author,labels,updatedAt,url,assignees' "${surveyor}" ||
  fail "surveyor open-issue search omits author, so the issue-side filter cannot run"
grep -Fq 'Drop issues authored by the exact dependency-' "${surveyor}" ||
  fail "surveyor type sweeps may still rank automation-authored issues"
grep -Fq '.user.login, .title,' "${surveyor}" ||
  fail "surveyor type-sweep jq omits the author column the issue-side filter needs"
# Pin every spelling of the identity on BOTH surfaces, and pin the author-only prohibition itself:
# without these a later edit could drop one identity, or re-admit title/label/age matching, while
# the descriptive prose still reads correct and every other assertion still passes.
for identity in 'renovate[bot]' 'dependabot[bot]' 'app/renovate' 'app/dependabot'; do
  grep -Fq "${identity}" "${surveyor}" ||
    fail "surveyor omits automation identity: ${identity}"
  grep -Fq "${identity}" "${constitution}" ||
    fail "constitution omits automation identity: ${identity}"
done
grep -Fq 'Match **author login only** — never the title' "${surveyor}" ||
  fail "surveyor does not enforce exact author-only matching"
grep -Fq 'labels, or age' "${surveyor}" ||
  fail "surveyor does not prohibit label/age matching"
grep -Fq 'dependency PRs *and* issues are AUTOMATION-OWNED' "${constitution}" ||
  fail "constitution does not extend the automation-owned carve-out to issues"
grep -Fq 'Never select, triage-as-work, or close an automation-authored' "${constitution}" ||
  fail "constitution may still let agents close a Renovate Dependency Dashboard"
# The skip list in *Drain oldest-first* is a CLOSED set: "skip ONLY when one of these is true".
# A carve-out that forbids selecting an automation-authored issue without adding it to that set
# leaves the contract self-contradictory — told to claim the oldest issue and forbidden to work it.
# Pin the exclusion in BOTH normative selection surfaces, and pin the author-vs-label distinction
# that keeps it from colliding with "an `automation` label is NOT a valid skip reason".
grep -Fq 'authored by an exact dependency-automation identity' "${constitution}" ||
  fail "constitution skip list omits the automation-author exclusion (f)"
grep -Fq 'never actionable at all' "${constitution}" ||
  fail "constitution does not state that an automation-authored issue is never actionable"
grep -Fq 'keys on the AUTHOR, never the `automation` label' "${constitution}" ||
  fail "constitution does not separate the automation AUTHOR exclusion from the automation LABEL non-reason"
grep -Fq 'authored by an exact dependency-automation identity' "${maintenance_skill}" ||
  fail "run loop's select step omits the automation-author exclusion"
grep -Fq 'never actionable at all' "${maintenance_skill}" ||
  fail "run loop does not state that an automation-authored issue is never actionable"
# product-engineering re-enumerates the same closed skip set, so it drifts into the identical
# contradiction unless (f) is stated there too. (The other files that mention oldest-actionable
# merely defer to the contract and enumerate nothing, so they need no copy.)
grep -Fq 'authored by an exact dependency-automation' "${product_engineering_skill}" ||
  fail "advance playbook's skip set omits the automation-author exclusion (f)"
grep -Fq 'never actionable at all' "${product_engineering_skill}" ||
  fail "advance playbook does not state that an automation-authored issue is never actionable"
grep -Fq 'automation-owned dependency PRs' "${maintenance_skill}" ||
  fail "portfolio-maintenance skill does not defer dependency PRs to automation"
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '`agent-plugins` updater PRs require semantic review' "${maintenance_skill}" ||
  fail "portfolio-maintenance skill can still exempt marketplace instruction updates from review"
grep -Fq 'Compatibility overlay' "${maintenance_skill}" ||
  fail "plugin surveyor can run without the hardened local behavior before digest parity"
grep -Fq 'read and follow the local' "${maintenance_skill}" ||
  fail "plugin surveyor is not explicitly required to load the local compatibility overlay"
if grep -Fq '**Do not load** the local reference copy' "${maintenance_skill}"; then
  fail "run loop forbids the compatibility overlay even though plugin digest parity is not proven"
fi
grep -Fq 'automation-owned dependency PRs' "${monorepo_skill}" ||
  fail "monorepo product card still treats dependency PRs as agent work"
grep -Fq 'automation-owned dependency PRs' "${product_engineering_skill}" ||
  fail "product-engineering skill still treats dependency PRs as agent work"
grep -Fq 'automation-owned dependency PRs' "${agent_skills_card}" ||
  fail "agent-skills product card still treats dependency PRs as agent work"
grep -Fq 'never spend a review lane on exit-0 exemptions' "${agent_skills_card}" ||
  fail "agent-skills product card does not preserve the narrow no-review path"
grep -Fq 'classifier exits 3' "${agent_skills_card}" ||
  fail "agent-skills product card does not require semantic review for marketplace updates"
grep -Fq 'automation-owned dependency PRs' "${ksail_card}" ||
  fail "KSail product card still treats dependency PRs as agent work"
if grep -Fq 'Bot PRs are first-priority work, not background noise' "${constitution}"; then
  fail "constitution still tells agents to drive dependency-bot PRs"
fi
if grep -Fq 'Bundle Dependabot/Renovate PRs' "${monorepo_skill}"; then
  fail "monorepo product card still tells agents to bundle dependency PRs"
fi

expect_exempt() {
  local name="$1"
  shift
  "${classifier}" "$@" || fail "expected exemption: ${name}"
}

expect_review_gated() {
  local name="$1"
  shift
  local rc
  if "${classifier}" "$@"; then
    fail "unexpected exemption: ${name}"
  else
    rc=$?
  fi
  [[ "${rc}" -eq 1 ]] || fail "classifier errored for review-gated fixture: ${name}"
}

expect_review_required() {
  local name="$1"
  shift
  local rc
  if "${classifier}" "$@"; then
    fail "unexpected no-review exemption: ${name}"
  else
    rc=$?
  fi
  [[ "${rc}" -eq 3 ]] ||
    fail "classifier did not return trusted review-required state for ${name}: exit ${rc}"
}

expect_not_release_exempt() {
  local name="$1"
  shift
  local rc
  if "${classifier}" "$@"; then
    fail "unexpected release-bot exemption: ${name}"
  else
    rc=$?
  fi
  [[ "${rc}" -eq 1 ]] || fail "classifier errored for non-release fixture: ${name}"
}

expect_classifier_error() {
  local name="$1"
  shift
  local rc
  if "${classifier}" "$@"; then
    fail "unexpected exemption: ${name}"
  else
    rc=$?
  fi
  [[ "${rc}" -eq 2 ]] || fail "classifier did not fail closed for invalid fixture: ${name}"
}

# Every commit the surveyor normalizes carries the author/committer date pair, and the schema
# requires both (#2291). A commit created in one operation has the same timestamp in each, so that
# is the default here; only the World at Ruin amend fixtures state a diverging pair, which keeps the
# date discriminator visible in exactly the tests that exercise it instead of in all nineteen.
with_commit_dates() {
  jq -c 'map(
    .author_date = (.author_date // "2026-07-18T09:14:22Z")
    | .committer_date = (.committer_date // .author_date)
  )'
}

homebrew_commits_json() {
  local component="$1"
  local version="$2"
  local first_sha="$3"
  local head_sha="$4"

  jq -cn \
    --arg component "${component}" \
    --arg version "${version}" \
    --arg first_sha "${first_sha}" \
    --arg head_sha "${head_sha}" \
    '[
      {
        sha: $first_sha,
        author_login: "goreleaserbot",
        author_name: "goreleaserbot",
        author_email: "bot@goreleaser.com",
        committer_login: "goreleaserbot",
        committer_name: "goreleaserbot",
        committer_email: "bot@goreleaser.com",
        message: "Brew cask update for \($component) version \($version)"
      },
      {
        sha: $head_sha,
        author_login: "",
        author_name: "generator-bot",
        author_email: "generator-bot@users.noreply.github.com",
        committer_login: "",
        committer_name: "generator-bot",
        committer_email: "generator-bot@users.noreply.github.com",
        message: "style: autocorrect Casks (brew style --fix)"
      }
    ]' | with_commit_dates
}

# Measured from homebrew-tap #1238/#1241/#1242: World at Ruin's cask PRs come from its own CD
# workflow rather than GoReleaser, so they are a single tap-token commit.
#
# The optional third argument sets the committer date independently of the author date. The CD
# workflow creates the commit in one operation, so the real path leaves it unset and both dates
# match (verified against homebrew-tap #1324-#1332, 8/8 equal on 2026-07-28). Passing a later
# committer date reproduces `git commit --amend`, which is what a hand-edited cask body looks like
# on this arm — every identity field survives the rewrite, so the date pair is the only signal.
war_cask_commits_json() {
  local version="$1"
  local head_sha="$2"
  local committer_date="${3:-}"

  jq -cn \
    --arg version "${version}" \
    --arg head_sha "${head_sha}" \
    --arg committer_date "${committer_date}" \
    '[{
      sha: $head_sha,
      author_login: "devantler",
      author_name: "Nikolai Emil Damm",
      author_email: "ned@devantler.tech",
      committer_login: "devantler",
      committer_name: "Nikolai Emil Damm",
      committer_email: "ned@devantler.tech",
      message: "chore(cask): update world-at-ruin to \($version)"
    }
    | if $committer_date == "" then . else .committer_date = $committer_date end]' \
    | with_commit_dates
}

ksail_head="8fdc117e5892a57a82781fc3a4806ef1f21873af"
ksail_files='[".claude-plugin/marketplace.json",".github/plugin/marketplace.json","copilot-plugin/.claude-plugin/plugin.json","copilot-plugin/plugin.json"]'
ksail_commits="$(jq -cn --arg head "${ksail_head}" '[{
  sha: $head,
  author_login: "",
  author_name: "devantler-tech-bot[bot]",
  author_email: "devantler-tech-bot[bot]@users.noreply.github.com",
  committer_login: "",
  committer_name: "devantler-tech-bot[bot]",
  committer_email: "devantler-tech-bot[bot]@users.noreply.github.com",
  message: "chore(copilot-plugin): release v7.172.2"
}]' | with_commit_dates)"

ksail_cask_head="c58256924878560caff669a7c05df0d84c458b38"
ksail_cask_commits="$(homebrew_commits_json \
  "ksail" \
  "v7.172.2" \
  "c3dfd928eb6ff8fc8a9d2b1520862d45a565b0e8" \
  "${ksail_cask_head}")"
desktop_cask_head="e896ab6476c4333292b099af7240d1d61b3795f9"
desktop_cask_commits="$(homebrew_commits_json \
  "ksail-desktop" \
  "v7.172.2" \
  "5ebaed25a8e3c92f38f2c8c6f938186ebca7ffa5" \
  "${desktop_cask_head}")"
war_cask_head="9c1a4f2be1e7c5a0d3f8b6120e4a7d59c8b3f012"
war_cask_commits="$(war_cask_commits_json "v0.36.0" "${war_cask_head}")"

# Measured from homebrew-tap #1225: the tap's release branches are evergreen, so one open PR can
# carry several GoReleaser/autocorrect cycles before it is merged.
multi_cycle_cask_head="4d2e7a1c93b8f605e2a7c4d81f36b9075ea2c318"
multi_cycle_cask_commits="$(jq -cn \
  --arg head "${multi_cycle_cask_head}" \
  '[
    {sha: "1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d",
     author_login: "goreleaserbot", author_name: "goreleaserbot", author_email: "bot@goreleaser.com",
     committer_login: "goreleaserbot", committer_name: "goreleaserbot", committer_email: "bot@goreleaser.com",
     message: "Brew cask update for ksail version v7.176.0"},
    {sha: "2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e",
     author_login: "", author_name: "generator-bot", author_email: "generator-bot@users.noreply.github.com",
     committer_login: "", committer_name: "generator-bot", committer_email: "generator-bot@users.noreply.github.com",
     message: "style: autocorrect Casks (brew style --fix)"},
    {sha: "3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f",
     author_login: "goreleaserbot", author_name: "goreleaserbot", author_email: "bot@goreleaser.com",
     committer_login: "goreleaserbot", committer_name: "goreleaserbot", committer_email: "bot@goreleaser.com",
     message: "Brew cask update for ksail version v7.176.1"},
    {sha: $head,
     author_login: "", author_name: "generator-bot", author_email: "generator-bot@users.noreply.github.com",
     committer_login: "", committer_name: "generator-bot", committer_email: "generator-bot@users.noreply.github.com",
     message: "style: autocorrect Casks (brew style --fix)"}
  ]' | with_commit_dates)"

# An agent adaptation commit takes a cask PR off its programmed path and makes it review-bearing.
adapted_cask_head="7f6e5d4c3b2a19087f6e5d4c3b2a19087f6e5d4c"
adapted_cask_commits="$(jq -cn \
  --arg head "${adapted_cask_head}" \
  '[
    {sha: "8a7b6c5d4e3f2109a8b7c6d5e4f3210a9b8c7d6e",
     author_login: "goreleaserbot", author_name: "goreleaserbot", author_email: "bot@goreleaser.com",
     committer_login: "goreleaserbot", committer_name: "goreleaserbot", committer_email: "bot@goreleaser.com",
     message: "Brew cask update for ksail version v7.176.4"},
    {sha: $head,
     author_login: "devantler", author_name: "Nikolai Emil Damm", author_email: "ned@devantler.tech",
     committer_login: "devantler", committer_name: "Nikolai Emil Damm", committer_email: "ned@devantler.tech",
     message: "fix(cask): correct the sha256 by hand"}
  ]' | with_commit_dates)"

default_title_cask_head="5a5792bb83bd6b8469f10cd7e00abfe75c7f36be"
default_title_cask_commits="$(homebrew_commits_json \
  "ksail" \
  "v7.172.1" \
  "a22a9f9f56da9f5cdde4c037ec92eabf30768d72" \
  "${default_title_cask_head}")"

platform_head="1111111111111111111111111111111111111111"
platform_commits="$(jq -cn --arg head "${platform_head}" '[{
  sha: $head,
  author_login: "renovate[bot]",
  author_name: "renovate[bot]",
  author_email: "29139614+renovate[bot]@users.noreply.github.com",
  committer_login: "web-flow",
  committer_name: "GitHub",
  committer_email: "noreply@github.com",
  message: "chore(deps): update dependency devantler-tech/ksail to v7.172.1"
}]' | with_commit_dates)"

agent_plugins_skills_head="e9cf0d8f34ef5e235d11b5141d71bb067d96538d"
agent_plugins_skills_files='["plugins/github/skills/gh-stack/SKILL.md","plugins/gitops-kubernetes/skills/gitops-knowledge/SKILL.md"]'
agent_plugins_skills_commits="$(jq -cn --arg head "${agent_plugins_skills_head}" '[{
  sha: $head,
  author_login: "devantler",
  author_name: "devantler",
  author_email: "26203420+devantler@users.noreply.github.com",
  committer_login: "github-actions[bot]",
  committer_name: "github-actions[bot]",
  committer_email: "41898282+github-actions[bot]@users.noreply.github.com",
  message: "chore(deps): update agent skills"
}]' | with_commit_dates)"

agent_plugins_versioned_head="b6e8caf3166e0693ddae7159cd88783386af0b75"
agent_plugins_versioned_files='[".claude-plugin/marketplace.json",".github/plugin/marketplace.json","plugins/github/.claude-plugin/plugin.json","plugins/github/plugin.json","plugins/github/skills/gh-stack/SKILL.md"]'
agent_plugins_versioned_commits="$(jq -cn --arg head "${agent_plugins_versioned_head}" '[
  {
    sha: "af32046fa35e4c954f31ca6ba19d4a0659418af7",
    author_login: "devantler",
    author_name: "devantler",
    author_email: "26203420+devantler@users.noreply.github.com",
    committer_login: "github-actions[bot]",
    committer_name: "github-actions[bot]",
    committer_email: "41898282+github-actions[bot]@users.noreply.github.com",
    message: "chore(deps): update agent skills"
  },
  {
    sha: $head,
    author_login: "github-actions[bot]",
    author_name: "github-actions[bot]",
    author_email: "41898282+github-actions[bot]@users.noreply.github.com",
    committer_login: "github-actions[bot]",
    committer_name: "github-actions[bot]",
    committer_email: "41898282+github-actions[bot]@users.noreply.github.com",
    message: "chore(deps): bump versions of changed plugins"
  }
]' | with_commit_dates)"

multi_agent_skills_head="6666666666666666666666666666666666666666"
multi_agent_skills_commits="$(jq -cn --arg head "${multi_agent_skills_head}" '[
  {
    sha: "7777777777777777777777777777777777777777",
    author_login: "devantler",
    author_name: "devantler",
    author_email: "26203420+devantler@users.noreply.github.com",
    committer_login: "github-actions[bot]",
    committer_name: "github-actions[bot]",
    committer_email: "41898282+github-actions[bot]@users.noreply.github.com",
    message: "chore(deps): update agent skills"
  },
  {
    sha: $head,
    author_login: "github-merge-queue[bot]",
    author_name: "github-merge-queue",
    author_email: "118344674+github-merge-queue@users.noreply.github.com",
    committer_login: "github-actions[bot]",
    committer_name: "github-actions[bot]",
    committer_email: "41898282+github-actions[bot]@users.noreply.github.com",
    message: "chore(deps): update agent skills"
  }
]' | with_commit_dates)"

platform_skills_head="d668b9d0f52c22473abc75a7d7457505e3624cc6"
platform_skills_files='[".agents/skills/gitops-cluster-debug/SKILL.md",".agents/skills/gitops-knowledge/SKILL.md"]'
platform_skills_commits="$(jq -cn --arg head "${platform_skills_head}" '[{
  sha: $head,
  author_login: "github-merge-queue[bot]",
  author_name: "github-merge-queue",
  author_email: "118344674+github-merge-queue@users.noreply.github.com",
  committer_login: "github-actions[bot]",
  committer_name: "github-actions[bot]",
  committer_email: "41898282+github-actions[bot]@users.noreply.github.com",
  message: "chore(deps): update agent skills"
}]' | with_commit_dates)"

ksail_skills_head="fdffbf83c8c0c1cc01050dc3d5c79ab18c3a45b4"
ksail_skills_files='[".agents/skills/gh-stack/SKILL.md"]'
ksail_skills_commits="$(jq -cn --arg head "${ksail_skills_head}" '[{
  sha: $head,
  author_login: "github-merge-queue[bot]",
  author_name: "github-merge-queue",
  author_email: "118344674+github-merge-queue@users.noreply.github.com",
  committer_login: "github-actions[bot]",
  committer_name: "github-actions[bot]",
  committer_email: "41898282+github-actions[bot]@users.noreply.github.com",
  message: "chore(deps): update agent skills"
}]' | with_commit_dates)"

adapted_agent_skills_head="5555555555555555555555555555555555555555"
adapted_agent_skills_commits="$(jq -c --arg head "${adapted_agent_skills_head}" '. + [{
  sha: $head,
  author_login: "devantler",
  author_name: "Nikolai Emil Damm",
  author_email: "26203420+devantler@users.noreply.github.com",
  committer_login: "devantler",
  committer_name: "Nikolai Emil Damm",
  committer_email: "26203420+devantler@users.noreply.github.com",
  message: "fix: adapt generated skill update"
}]' <<<"${agent_plugins_skills_commits}" | with_commit_dates)"

adapted_ksail_head="2222222222222222222222222222222222222222"
adapted_ksail_commits="$(jq -c --arg head "${adapted_ksail_head}" '. + [{
  sha: $head,
  author_login: "devantler",
  author_name: "Nikolai Emil Damm",
  author_email: "26203420+devantler@users.noreply.github.com",
  committer_login: "devantler",
  committer_name: "Nikolai Emil Damm",
  committer_email: "26203420+devantler@users.noreply.github.com",
  message: "fix: adapt generated release"
}]' <<<"${ksail_commits}" | with_commit_dates)"

adapted_cask_head="3333333333333333333333333333333333333333"
adapted_cask_commits="$(jq -c --arg head "${adapted_cask_head}" '. + [{
  sha: $head,
  author_login: "devantler",
  author_name: "Nikolai Emil Damm",
  author_email: "26203420+devantler@users.noreply.github.com",
  committer_login: "devantler",
  committer_name: "Nikolai Emil Damm",
  committer_email: "26203420+devantler@users.noreply.github.com",
  message: "fix: adapt generated cask"
}]' <<<"${ksail_cask_commits}" | with_commit_dates)"

expect_exempt \
  "KSail programmed plugin release" \
  "ksail" \
  "app/ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${ksail_head}" \
  "${ksail_files}" \
  "${ksail_commits}"

expect_review_required \
  "agent-plugins skill-only update" \
  "agent-plugins" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${agent_plugins_skills_head}" \
  "${agent_plugins_skills_files}" \
  "${agent_plugins_skills_commits}"

expect_review_required \
  "agent-plugins update with generated version files" \
  "agent-plugins" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${agent_plugins_versioned_head}" \
  "${agent_plugins_versioned_files}" \
  "${agent_plugins_versioned_commits}"

# An installed skill root holds copies from many upstreams, and the copied frontmatter naming the
# upstream is written by that upstream. So authorization comes from the reviewed allowlist beside the
# classifier, and the frontmatter is only a corroborator that can withdraw the carve-out, never grant
# it (#2614). `ways-of-working` is the one genuinely suite-owned skill installed in each consumer.
suite_skill_owner="https://github.com/devantler-tech/agent-skills"
allowed_skills_files='[".agents/skills/ways-of-working/SKILL.md"]'
allowed_skills_owners="$(jq -cn --arg o "${suite_skill_owner}" '{
  ".agents/skills/ways-of-working": $o
}')"
# The attack this exists to stop: a third-party release edits its own frontmatter to claim the suite
# upstream, the updater copies that claim verbatim, and a payload-derived check would read it back as
# proof of ownership.
forged_owner_claim="$(jq -cn --arg o "${suite_skill_owner}" '{
  ".agents/skills/gh-stack": $o
}')"
# A skill that IS allowlisted but whose copied frontmatter no longer names the reviewed upstream —
# an upstream handover shows up here before anyone notices it anywhere else.
drifted_owner_claim='{".agents/skills/ways-of-working":"https://github.com/github/awesome-copilot"}'
lookalike_owner_claim="$(jq -cn --arg o "${suite_skill_owner}-v2" '{
  ".agents/skills/ways-of-working": $o
}')"
mixed_batch_files='[".agents/skills/ways-of-working/SKILL.md",".agents/skills/gh-stack/SKILL.md"]'
# `gh-stack` declaring its real third-party upstream — the honest, unforged case.
ksail_skills_owners='{".agents/skills/gh-stack":"https://github.com/github/gh-stack"}'

expect_exempt \
  "Platform update touching only an allowlisted suite-owned skill" \
  "platform" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${platform_skills_head}" \
  "${allowed_skills_files}" \
  "${platform_skills_commits}" \
  "${allowed_skills_owners}"

# The corroborator is what catches an upstream handover on a root we still allowlist, so a caller
# that omits it must NOT be handed the carve-out — a tripwire the caller may skip never fires.
expect_review_required \
  "an allowlisted skill with the corroborating map omitted entirely" \
  "ksail" \
  "app/ksail-bot" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${ksail_skills_head}" \
  "${allowed_skills_files}" \
  "${ksail_skills_commits}"

expect_review_required \
  "KSail update touching a third-party skill" \
  "ksail" \
  "app/ksail-bot" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${ksail_skills_head}" \
  "${ksail_skills_files}" \
  "${ksail_skills_commits}" \
  "${ksail_skills_owners:-}"

expect_review_required \
  "a third-party skill FORGING the suite upstream in its own frontmatter" \
  "ksail" \
  "app/ksail-bot" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${ksail_skills_head}" \
  "${ksail_skills_files}" \
  "${ksail_skills_commits}" \
  "${forged_owner_claim}"

expect_review_required \
  "an allowlisted skill whose declared upstream has drifted" \
  "platform" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${platform_skills_head}" \
  "${allowed_skills_files}" \
  "${platform_skills_commits}" \
  "${drifted_owner_claim}"

expect_review_required \
  "an allowlisted skill claimed by a prefix-extended lookalike upstream" \
  "platform" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${platform_skills_head}" \
  "${allowed_skills_files}" \
  "${platform_skills_commits}" \
  "${lookalike_owner_claim}"

expect_review_required \
  "a batch mixing an allowlisted skill with a third-party one" \
  "ksail" \
  "app/ksail-bot" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${ksail_skills_head}" \
  "${mixed_batch_files}" \
  "${ksail_skills_commits}" \
  "${allowed_skills_owners}"

expect_review_required \
  "an installed skill root absent from the allowlist" \
  "platform" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${platform_skills_head}" \
  "${platform_skills_files}" \
  "${platform_skills_commits}"

expect_review_required \
  "an allowlisted skill whose frontmatter was absent or unreadable" \
  "platform" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${platform_skills_head}" \
  "${allowed_skills_files}" \
  "${platform_skills_commits}" \
  '{".agents/skills/ways-of-working":null}'

expect_classifier_error \
  "agent-skills update with a malformed ownership map" \
  "platform" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${platform_skills_head}" \
  "${allowed_skills_files}" \
  "${platform_skills_commits}" \
  '[".agents/skills/ways-of-working"]'

# A malformed allowlist must fail closed rather than authorize. The classifier resolves the file
# relative to its own directory, so the fixture reproduces that layout exactly.
#
# ⚠️ Measured, so nobody over-credits these: with the corroborating map now REQUIRED, only the
# duplicate-root case is caught by the allowlist validation alone. Removing that validation leaves
# the other three still returning 3, because the map disagrees with the malformed row and catches
# them first. They are kept as behaviour regressions for the combined gate, not as proof of the
# parser — the parser's unique contribution is rejecting a duplicate root, which the map cannot see
# because `from_entries` silently keeps the last one and it agrees with the map.
expect_allowlist_rejects() {
  local name="$1" row="$2" tmp rc
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/scripts"
  cp "${classifier}" "${tmp}/scripts/"
  printf '%s\n' "${row}" >"${tmp}/skill-ownership-allowlist.tsv"
  # Pass a VALID corroborating map, so the only thing left to reject is the allowlist row itself.
  # Omitting it would make every case below pass for the missing-map reason instead.
  if "${tmp}/scripts/$(basename "${classifier}")" \
    "platform" "app/botantler-1" "deps/agent-skills-update" \
    "chore(deps): update agent skills" \
    "${platform_skills_head}" "${allowed_skills_files}" "${platform_skills_commits}" \
    "${allowed_skills_owners}"; then
    rm -rf "${tmp}"
    fail "malformed allowlist still granted the no-review carve-out: ${name}"
  else
    rc=$?
  fi
  rm -rf "${tmp}"
  [[ "${rc}" -eq 3 ]] ||
    fail "malformed allowlist did not take the review path: ${name} (exit ${rc})"
}

# Control: the same harness with a WELL-FORMED row must still authorize, or the four cases below
# would pass for the trivial reason that the relocated copy never works.
allowlist_control_tmp="$(mktemp -d)"
mkdir -p "${allowlist_control_tmp}/scripts"
cp "${classifier}" "${allowlist_control_tmp}/scripts/"
printf 'platform\t.agents/skills/ways-of-working\thttps://github.com/devantler-tech/agent-skills\n' \
  >"${allowlist_control_tmp}/skill-ownership-allowlist.tsv"
"${allowlist_control_tmp}/scripts/$(basename "${classifier}")" \
  "platform" "app/botantler-1" "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${platform_skills_head}" "${allowed_skills_files}" "${platform_skills_commits}" \
  "${allowed_skills_owners}" ||
  fail "relocated-classifier control failed: a well-formed allowlist must still grant exit 0"
rm -rf "${allowlist_control_tmp}"

expect_allowlist_rejects "empty owner column" \
  "$(printf 'platform\t.agents/skills/ways-of-working\t')"
expect_allowlist_rejects "owner drifted to another upstream" \
  "$(printf 'platform\t.agents/skills/ways-of-working\thttps://github.com/github/awesome-copilot')"
expect_allowlist_rejects "root outside the installed-skill tree" \
  "$(printf 'platform\t.github/workflows\thttps://github.com/devantler-tech/agent-skills')"
expect_allowlist_rejects "duplicate root" \
  "$(printf 'platform\t.agents/skills/ways-of-working\thttps://github.com/devantler-tech/agent-skills\nplatform\t.agents/skills/ways-of-working\thttps://github.com/devantler-tech/agent-skills')"

expect_exempt \
  "GoReleaser KSail cask" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "${ksail_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${ksail_cask_commits}"

expect_exempt \
  "GoReleaser KSail Desktop cask" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail-desktop" \
  "chore(cask): update ksail-desktop to v7.172.2" \
  "${desktop_cask_head}" \
  '["Casks/ksail-desktop.rb"]' \
  "${desktop_cask_commits}"

expect_exempt \
  "GoReleaser default cask title" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "Brew cask update for ksail version v7.172.1" \
  "${default_title_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${default_title_cask_commits}"

expect_exempt \
  "World at Ruin CD cask" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/world-at-ruin" \
  "chore(cask): update world-at-ruin to v0.36.0" \
  "${war_cask_head}" \
  '["Casks/world-at-ruin.rb"]' \
  "${war_cask_commits}"

# #2291. The tap token commits under the maintainer's own identity, so a `git commit --amend` that
# rewrites the cask body leaves every login, name, email, message, branch and path identical to a
# genuine release — the exemption used to survive it. The author/committer date pair is what an
# amend cannot preserve, so it is what re-gates the PR here.
war_amended_cask_commits="$(war_cask_commits_json \
  "v0.36.0" \
  "${war_cask_head}" \
  "2026-07-18T09:17:05Z")"

expect_review_gated \
  "World at Ruin cask whose commit was amended by hand" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/world-at-ruin" \
  "chore(cask): update world-at-ruin to v0.36.0" \
  "${war_cask_head}" \
  '["Casks/world-at-ruin.rb"]' \
  "${war_amended_cask_commits}"

# A surveyor that has not been updated to send both dates must fail closed rather than silently
# skipping the discriminator: without this the exemption would quietly widen back to what it was.
expect_classifier_error \
  "World at Ruin cask payload missing the commit date pair" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/world-at-ruin" \
  "chore(cask): update world-at-ruin to v0.36.0" \
  "${war_cask_head}" \
  '["Casks/world-at-ruin.rb"]' \
  "$(jq -c 'map(del(.author_date, .committer_date))' <<<"${war_cask_commits}")"

# The surveyor must be told to carry the pair, or a correct classifier is fed a payload that can
# never exercise it. Naming the output fields is not enough on its own: the discriminator only works
# if both values come from the raw commit object, so the source paths are asserted too. Taking
# either date from the PR-level view instead would still satisfy a field-name-only assertion while
# silently supplying a value the amend does not move.
grep -Fq 'author_date' "${surveyor}" ||
  fail "surveyor commit normalization does not carry author_date"
grep -Fq 'committer_date' "${surveyor}" ||
  fail "surveyor commit normalization does not carry committer_date"
grep -Fq '.commit.author.date' "${surveyor}" ||
  fail "surveyor does not source author_date from the raw commit object"
grep -Fq '.commit.committer.date' "${surveyor}" ||
  fail "surveyor does not source committer_date from the raw commit object"

expect_exempt \
  "GoReleaser cask carrying several release cycles" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.176.1" \
  "${multi_cycle_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${multi_cycle_cask_commits}"

expect_review_gated \
  "cask PR carrying a hand adaptation commit" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.176.4" \
  "${adapted_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${adapted_cask_commits}"

expect_review_gated \
  "World at Ruin cask claiming the wrong version in its commit" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/world-at-ruin" \
  "chore(cask): update world-at-ruin to v0.37.0" \
  "${war_cask_head}" \
  '["Casks/world-at-ruin.rb"]' \
  "${war_cask_commits}"


expect_review_gated \
  "cask title claiming a version no release cycle shipped" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v999.0.0" \
  "${multi_cycle_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${multi_cycle_cask_commits}"

expect_review_gated \
  "agent-skills updater lookalike from the wrong actor" \
  "agent-plugins" \
  "app/cursor" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${agent_plugins_skills_head}" \
  "${agent_plugins_skills_files}" \
  "${agent_plugins_skills_commits}"

expect_review_gated \
  "agent-skills updater lookalike from the wrong branch" \
  "agent-plugins" \
  "app/botantler-1" \
  "feature/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${agent_plugins_skills_head}" \
  "${agent_plugins_skills_files}" \
  "${agent_plugins_skills_commits}"

expect_review_gated \
  "agent-skills updater carrying a non-generated file" \
  "agent-plugins" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${agent_plugins_skills_head}" \
  '["README.md","plugins/github/skills/gh-stack/SKILL.md"]' \
  "${agent_plugins_skills_commits}"

expect_review_gated \
  "agent-skills updater carrying a human adaptation commit" \
  "agent-plugins" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${adapted_agent_skills_head}" \
  "${agent_plugins_skills_files}" \
  "${adapted_agent_skills_commits}"

expect_review_gated \
  "agent-skills updater carrying two otherwise compliant commits" \
  "agent-plugins" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${multi_agent_skills_head}" \
  "${agent_plugins_skills_files}" \
  "${multi_agent_skills_commits}"

expect_review_gated \
  "agent-skills updater shape in an unapproved repository" \
  "agent-skills" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${agent_plugins_skills_head}" \
  "${agent_plugins_skills_files}" \
  "${agent_plugins_skills_commits}"

expect_not_release_exempt \
  "Platform Renovate KSail bump" \
  "platform" \
  "app/renovate" \
  "renovate/ksail" \
  "chore(deps): update dependency devantler-tech/ksail to v7.172.1" \
  "${platform_head}" \
  '[".github/actions/deploy-prod/action.yml",".github/workflows/ci.yaml",".github/workflows/dr-rebuild.yaml","k8s/bases/infrastructure/controllers/ksail-operator/helm-release.yaml"]' \
  "${platform_commits}"

expect_not_release_exempt \
  "lookalike KSail release from the wrong actor" \
  "ksail" \
  "app/renovate" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${ksail_head}" \
  "${ksail_files}" \
  "${ksail_commits}"

expect_review_gated \
  "bare KSail bot alias is not an API identity" \
  "ksail" \
  "ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${ksail_head}" \
  "${ksail_files}" \
  "${ksail_commits}"

expect_review_gated \
  "GoReleaser cask with an extra file" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "${ksail_cask_head}" \
  '["Casks/ksail.rb","README.md"]' \
  "${ksail_cask_commits}"

expect_review_gated \
  "GoReleaser-shaped title from an unowned branch" \
  "homebrew-tap" \
  "devantler" \
  "feature/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "${ksail_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${ksail_cask_commits}"

expect_review_gated \
  "KSail release with a human adaptation commit" \
  "ksail" \
  "app/ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${adapted_ksail_head}" \
  "${ksail_files}" \
  "${adapted_ksail_commits}"

expect_review_gated \
  "GoReleaser cask with a human adaptation commit" \
  "homebrew-tap" \
  "devantler" \
  "goreleaser/ksail" \
  "chore(cask): update ksail to v7.172.2" \
  "${adapted_cask_head}" \
  '["Casks/ksail.rb"]' \
  "${adapted_cask_commits}"

expect_classifier_error \
  "stale commit list does not reach the supplied head" \
  "ksail" \
  "app/ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "4444444444444444444444444444444444444444" \
  "${ksail_files}" \
  "${ksail_commits}"

expect_classifier_error \
  "malformed commit provenance" \
  "ksail" \
  "app/ksail-bot" \
  "chore/copilot-plugin-v7.172.2" \
  "chore(copilot-plugin): release v7.172.2" \
  "${ksail_head}" \
  "${ksail_files}" \
  'not-json'

# Multi-lane claim visibility (monorepo#2300): Cursor cloud and Codex siblings claim under
# cursor/* and codex/*; a surveyor that only greps ^claude/ cannot see those pre-PR claims.
# The scan must also NOT be gated on assignees — app/cursor cannot assign, so a Cursor claim
# is branch-only until its draft PR opens.
grep -Fq "grep -E '^(claude|cursor|codex)/'" "${surveyor}" ||
  fail "surveyor claim-branch scan does not cover claude/, cursor/, and codex/ prefixes"
grep -Fq '(claude|cursor|codex)/*-<issue>' "${surveyor}" ||
  fail "surveyor CLAIMED matching does not name all three lane prefixes"
grep -Fq 'Do not gate this scan on assignees' "${surveyor}" ||
  fail "surveyor claim-branch scan is still gated on assignees (hides cursor/* claims)"
grep -Fq 'none(cursor-lane)' "${surveyor}" ||
  fail "surveyor CLAIMED digest does not allow cursor-lane branch-only claims"

# Claim-protocol P2s (#2250) — contract + echo sites must stay in sync.
grep -Fq 'Resolve the claim ref from the issue number' "${constitution}" ||
  fail "constitution missing issue-number claim-ref resolution (#2250)"
grep -Fq 'branch you actually pushed' "${constitution}" ||
  fail "constitution missing takeover tip verification (#2250)"
grep -Fq 'foreign `owner/repo#<issue>`' "${constitution}" ||
  fail "constitution missing same-repo PR-body claim filter (#2250)"
grep -Fq 'branch you actually pushed' "${maintenance_skill}" ||
  fail "portfolio-maintenance missing takeover tip echo (#2250)"
grep -Fq 'foreign `owner/repo#N`' "${product_engineering_skill}" ||
  fail "product-engineering missing same-repo body-ref echo (#2250)"
grep -Fq 'foreign `owner/repo#<issue>`' "${surveyor}" ||
  fail "surveyor missing same-repo PR-body claim filter (#2250)"
grep -Fq '…-<issue>-2' "${monorepo_skill}" ||
  fail "monorepo card missing takeover branch echo (#2250)"

# Behavioural fixture (#2250): EXERCISE the shipped claim-ref resolver rather than asserting that
# words describing it are present. The prose and the pattern can drift apart in either direction —
# prose promising legacy coverage the anchor cannot deliver, or an anchor widened past what the
# prose scopes — and only running it catches that.
claim_resolver="$(awk -F"'" '/\{print \$1, \$2\}/ && /refs\/heads\// {print $2; exit}' "${constitution}")"
case "${claim_resolver}" in
  '$2 ~ "^refs/heads/"'*) : ;;
  *) fail "could not extract the claim-ref resolver from the constitution (#2250)" ;;
esac

claim_resolved="$(printf '%s\n' \
  'aaaaaaa refs/heads/claude/war-foliage-spatial-hash-109' \
  'bbbbbbb refs/heads/claude/war-foliage-spatial-hash-109-2' \
  'ccccccc refs/heads/claude/war-armour-guard' \
  'ddddddd refs/heads/codex/war-foliage-spatial-hash-109' \
  'eeeeeee refs/heads/claude/war-thing-1109' |
  awk -v lane="claude" -v n="109" "${claim_resolver}")"

printf '%s\n' "${claim_resolved}" | grep -Fq 'refs/heads/claude/war-foliage-spatial-hash-109' ||
  fail "claim-ref resolver misses this lane's own numbered claim branch (#2250)"
printf '%s\n' "${claim_resolved}" | grep -Fq 'refs/heads/claude/war-foliage-spatial-hash-109-2' ||
  fail "claim-ref resolver misses a -2 takeover branch, the shape rule 3 tells you to push (#2250)"
! printf '%s\n' "${claim_resolved}" | grep -Fq 'refs/heads/codex/' ||
  fail "claim-ref resolver leaks a sibling lane's branch (#2250)"
! printf '%s\n' "${claim_resolved}" | grep -Fq 'war-thing-1109' ||
  fail "claim-ref resolver matches a longer number merely ending in the issue number (#2250)"

# The legacy pre-numbering shape is STRUCTURALLY invisible to number resolution. That is why rule 1's
# normalised-stem pass stays required, and why the resolver must never be reused as a rival scan —
# it would report "no claim" over a live legacy claim branch, the #96 collision all over again.
! printf '%s\n' "${claim_resolved}" | grep -Fq 'war-armour-guard' ||
  fail "claim-ref resolver now matches a legacy pre-numbering branch — rescope the contract (#2250)"
grep -Fq 'a legacy pre-numbering ref ending' "${constitution}" ||
  fail "constitution does not scope number resolution away from legacy claim refs (#2250)"
grep -Fq 'Number resolution does NOT subsume the legacy stem' "${surveyor}" ||
  fail "surveyor does not require the legacy stem pass alongside number resolution (#2250)"

# Candidate-scoped clearance must have a producer grammar, and bounded survey continuation must
# advance past already classified or named-blocker rows without trusting stale head state.
grep -Fq 'QUERY-UNKNOWN <repo> #<n> — failed=<component>:<reason>' "${surveyor}" ||
  fail "surveyor cannot emit a candidate-identifying failed-join row"
grep -Fq 'SHARD-CURSOR next=' "${surveyor}" ||
  fail "surveyor does not emit resumable shard state"
grep -Fq 'filter the explicitly supplied classified set before selecting the next eight' "${surveyor}" ||
  fail "surveyor can restart at the same first shard indefinitely"
grep -Fq 'invalidate the supplied state and restart at the earliest changed candidate' "${surveyor}" ||
  fail "surveyor can skip a candidate after its recorded head changes"
grep -Fq 'verified closed or merged is pruned from the supplied set' "${surveyor}" ||
  fail "surveyor treats a terminal candidate as cursor corruption and restarts completed shards"

# Behavioural continuation fixture: an unchanged ten-candidate queue must select disjoint shards,
# not merely carry words such as cursor or classified in the contract.
stable_queue=(repo#1 repo#2 repo#3 repo#4 repo#5 repo#6 repo#7 repo#8 repo#9 repo#10)
first_shard=("${stable_queue[@]:0:8}")
classified=" ${first_shard[*]} "
second_shard=()
for candidate in "${stable_queue[@]}"; do
  case "${classified}" in
    *" ${candidate} "*) continue ;;
  esac
  second_shard+=("${candidate}")
  [ "${#second_shard[@]}" -eq 8 ] && break
done
[ "${first_shard[*]}" = 'repo#1 repo#2 repo#3 repo#4 repo#5 repo#6 repo#7 repo#8' ] ||
  fail "continuation fixture selected an unexpected first shard"
[ "${second_shard[*]}" = 'repo#9 repo#10' ] ||
  fail "continuation fixture repeated classified candidates instead of advancing"

# monorepo#2482 — every agent instance reviews as `devantler`, so an `rd=` rule keyed on the login
# alone reports a sibling instance's own superseded CHANGES_REQUESTED as a permanent human gate and
# parks a finished PR. Measured live on monorepo#2432: a disclosed agent review blocked the PR for
# 3 days. Assert the classifier, BOTH digest-grammar sites, and the fail-closed direction.
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq 'A `devantler` CHANGES_REQUESTED is not self-evidently human' "${surveyor}" ||
  fail "surveyor still treats a devantler CHANGES_REQUESTED as self-evidently human"
# The sender-marker fallback is the branch a login-only rule drops, and the 843rd measured 71
# sibling comments in exactly that undisclosed shape — so it is the COMMON case, not a corner.
grep -Fq 'first-person automation sender marker naming an agent instance as the SENDER' "${surveyor}" ||
  fail "surveyor rd= classification omits the sibling sender-marker fallback"
# shellcheck disable=SC2016
grep -Fq 'rd=CHANGES_REQUESTED:agent(<author>)@<sha>' "${surveyor}" ||
  fail "surveyor cannot report an agent-authored CHANGES_REQUESTED distinctly"
# shellcheck disable=SC2016
grep -Fq 'rd=CHANGES_REQUESTED:human(<author>)@<sha>' "${surveyor}" ||
  fail "surveyor cannot report a human-authored CHANGES_REQUESTED distinctly"
# ANCHORING is load-bearing, not stylistic: the maintainer routinely quotes an agent's disclosed
# text when replying to it, so an "appears anywhere in the body" match would classify HIS review as
# agent output and route it to the dismissal path — the exact loss the fail-closed rule below is
# meant to prevent. Both files must require the marker at the START of the body.
grep -Fq 'first line only, never merely' "${surveyor}" ||
  fail "surveyor matches the disclosure anywhere in the body, so quoted agent text misclassifies a human review"
grep -Fq 'anywhere later is quoted material and classifies nothing' "${surveyor}" ||
  fail "surveyor does not state that a non-leading disclosure classifies nothing"
grep -Fq 'BEGINS WITH** the structural' "${constitution}" ||
  fail "constitution matches the disclosure anywhere in the body rather than at the start"
grep -Fq 'a disclosure merely appearing somewhere inside it classifies' "${constitution}" ||
  fail "constitution does not anchor both agent-authorship branches at the start of the body"
# Fail closed: discarding the maintainer's own control signal is the worse of the two errors.
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '**Ambiguity resolves to `human`.**' "${surveyor}" ||
  fail "surveyor does not resolve CHANGES_REQUESTED authorship ambiguity to human"
# ...but failing closed must NOT re-break the structural match: an unfamiliar actor word after the
# canonical prefix is still own-output (contract → Untrusted input), which a naive "anything unusual
# is human" reading would invert.
grep -Fq 'the prefix match stays **actor-word-agnostic**' "${surveyor}" ||
  fail "surveyor ambiguity rule overrides the actor-word-agnostic structural prefix match"
# Staleness is what makes a dismissal safe. Without it the classifier discards a sibling's LIVE
# current-head finding — the same class of loss the CodeRabbit rule already guards with
# "none is at the current head".
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '`coderabbitai[bot]` and agent-authored `devantler`), **none** is at the current head' "${surveyor}" ||
  fail "surveyor STALE-AGENT-DISMISSAL lacks the current-head staleness precondition"
grep -Fq 'An agent-authored block AT the current head is ordinary NEEDS-FIX feedback' "${surveyor}" ||
  fail "surveyor does not route a current-head agent finding to NEEDS-FIX"
# The sweep sentence must carry the qualifier too, or the rule reintroduces the login-only form
# it replaces (partial propagation: the classifier is fixed while its producer still emits the
# unqualified token, so the orchestrator never receives the distinction).
# shellcheck disable=SC2016
grep -Fq 'a **bot** reviewer keeps the plain' "${surveyor}" ||
  fail "surveyor does not keep a plain author form for bot reviewers at the sweep step"
# A mixed stale set (one CodeRabbit block + one agent block) satisfies NEITHER per-author class, so
# without a shared precondition set the PR parks forever — the failure this whole rule removes.
grep -Fq 'share ONE precondition set' "${surveyor}" ||
  fail "surveyor leaves a mixed CodeRabbit+agent stale block set unclassifiable, so it parks forever"
grep -Fq 'stale blocks still qualifies' "${constitution}" ||
  fail "constitution leaves a mixed non-human stale block set unclassifiable"
# Dismissal is ALWAYS the maintainer's — draft or promoted. This is not stylistic: an autonomous
# draft-dismissal path falsifies the failure-direction claim, because a maintainer review whose first
# line imitates the PUBLIC marker would then be discarded outright rather than merely parked.
grep -Fq 'ALWAYS the maintainer one-click — never an autonomous dismissal' "${surveyor}" ||
  fail "surveyor permits an autonomous dismissal, which lets an imitated marker discard a human review"
grep -Fq 'Do not reintroduce' "${surveyor}" ||
  fail "surveyor does not tie the autonomous-dismissal ban to the marker's forgeability"
grep -Fq 'Classifying is the surveyor' "${surveyor}" ||
  fail "surveyor does not separate classifying from mutating"

# Ownership must not be decided at the SET level either. Measured 2026-08-08: every per-PR row was
# correctly tagged OWNERSHIP-UNVERIFIED while the digest still asserted "Zero random-slug branches ->
# no maintainer-interactive PRs in the set" over a set containing platform#2985, which IS interactive.
# The aggregate is the worse form: it invites skipping the creation-record test for every devantler PR
# at once, and what that enables is driving or merging the maintainer's own work.
grep -Fq 'A lane-level ownership claim is the same assertion as a per-PR one, and is equally forbidden.' "${surveyor}" ||
  fail "surveyor bans only per-PR ownership assertions, so a set-level ownership claim stays allowed"
grep -Fq 'never emit a set-level claim that the maintainer-interactive class is empty' "${surveyor}" ||
  fail "surveyor may still report the maintainer-interactive class as empty"
# ...and the branch-shape hint must carry its own measured counterexample, or a reader re-derives
# "no random slug therefore routine-owned" from the hint itself.
grep -Fq 'the absence of a random slug is **not** evidence the PR is the routine' "${surveyor}" ||
  fail "surveyor still lets a missing random slug read as evidence of routine ownership"
grep -Fq 'The dismissal itself is ALWAYS the' "${constitution}" ||
  fail "constitution lets the engineer dismiss a review autonomously"
# The motivating case is a `devantler`-authored PR, which reports on the OWNERSHIP-UNVERIFIED row —
# so the classification must exist THERE, or the orchestrator never receives it for its own PRs.
grep -Fq 'stale_dismissal=<STALE-CR-DISMISSAL|STALE-AGENT-DISMISSAL|none>' "${surveyor}" ||
  fail "the devantler PR row cannot carry the stale-dismissal classification"
# One precondition set, stated once. Two paragraphs disagreeing made the mixed case decidable two ways.
grep -Fq 'review on the PR is NON-HUMAN' "${surveyor}" ||
  fail "the CodeRabbit paragraph still carries a CodeRabbit-only precondition that contradicts the union"
# ...and the PRECONDITION paragraph must not name a class either: naming one there mislabelled an
# all-agent set as STALE-CR-DISMISSAL. Precondition and naming live in exactly one place each.
grep -Fq 'class-NEUTRAL — it never names a class' "${surveyor}" ||
  fail "the shared-precondition paragraph names a dismissal class, so an all-agent set can be mislabelled"
# The prefix is public and reproducible (CodeRabbit emits it verbatim). It is only safe because the
# failure direction is one-way; a future reuse without that asymmetry would be an authentication hole.
grep -Fq 'CONVENTION, not authentication' "${surveyor}" ||
  fail "surveyor presents the public disclosure prefix as if it authenticated authorship"
grep -Fq 'public convention, not authentication' "${constitution}" ||
  fail "constitution presents the public disclosure prefix as if it authenticated authorship"
grep -Fq 'a first line that is itself **nested' "${surveyor}" ||
  fail "surveyor counts a quote-nested disclosure as an agent marker"
# Both guards, not one: "EVERY review is agent-authored" is what stops a newer agent review's
# classification from hiding an OLDER human block — the CodeRabbit rule carries the same guard.
grep -Fq 'still dismissable: **every** CHANGES_REQUESTED on the PR is **non-human**' "${surveyor}" ||
  fail "surveyor STALE-AGENT-DISMISSAL can fire while a human block is also open"
grep -Fq 'A single human-authored block anywhere on the PR defeats both classes outright' "${surveyor}" ||
  fail "surveyor does not let a human block defeat the stale-agent class"
# A bot reviewer is neither a sibling instance nor the maintainer, so forcing it into either
# qualifier leaves a CodeRabbit CHANGES_REQUESTED with no valid token and unstates the CR rule.
# shellcheck disable=SC2016
grep -Fq 'qualifier applies to `devantler` reviews ONLY' "${surveyor}" ||
  fail "surveyor forces the agent/human qualifier onto bot reviewers"
# A classifier with no schema slot is never reportable, so pin BOTH grammar rows independently.
grep -Fq 'CHANGES_REQUESTED:<author>@<sha>|CHANGES_REQUESTED:agent(devantler)@<sha>|CHANGES_REQUESTED:human(devantler)@<sha>|none>, mergeState=<…> → REVIEW-READY' "${surveyor}" ||
  fail "surveyor draft digest grammar lacks the bot form or the devantler qualifiers"
grep -Fq 'CHANGES_REQUESTED:<author>@<sha>|CHANGES_REQUESTED:agent(devantler)@<sha>|CHANGES_REQUESTED:human(devantler)@<sha>|none>, mergeState=<…> → MERGE-READY' "${surveyor}" ||
  fail "surveyor non-draft digest grammar lacks the bot form or the devantler qualifiers"
grep -Fq 'STALE-AGENT-DISMISSAL | STALE-CR-DISMISSAL' "${surveyor}" ||
  fail "surveyor non-draft digest grammar cannot emit STALE-AGENT-DISMISSAL"
grep -Fq 'STALE-CR-DISMISSAL | STALE-AGENT-DISMISSAL' "${surveyor}" ||
  fail "surveyor draft digest grammar cannot emit STALE-AGENT-DISMISSAL"

# The constitution carries the same defect: it declared the stale-dismissal class CodeRabbit-only
# and named `devantler` as the example of a human reviewer.
# shellcheck disable=SC2016
grep -Fq 'authorship by login alone cannot tell his block apart' "${constitution}" ||
  fail "constitution still separates maintainer from agent reviews by login alone"
grep -Fq 'when it **opens with** a leading 🤖 first-person automation' "${constitution}" ||
  fail "constitution omits the sender-marker fallback for CHANGES_REQUESTED authorship"
grep -Fq '**Ambiguity resolves to the maintainer**' "${constitution}" ||
  fail "constitution does not fail closed on ambiguous CHANGES_REQUESTED authorship"
grep -Fq 'and none sits at the current head' "${constitution}" ||
  fail "constitution lets an agent-authored review be dismissed without the staleness test"
grep -Fq 'head is ordinary feedback to fix or refute' "${constitution}" ||
  fail "constitution does not route a current-head agent finding to fix-or-refute"
# shellcheck disable=SC2016
grep -Fq 'case `STALE-AGENT-DISMISSAL`, so a run acts on the digest' "${constitution}" ||
  fail "constitution does not define the STALE-AGENT-DISMISSAL digest class"
if grep -Fq 'The class is **CodeRabbit-only**' "${constitution}"; then
  fail "constitution still declares the stale-dismissal class CodeRabbit-only"
fi

# ── gh --json field vocabularies are per-subcommand and DISJOINT (#2498) ──────
# `gh pr view` exposes 47 --json fields, `gh search prs` only 19, and neither
# accepts a GraphQL-only name. A prescribed field list that crosses that
# boundary fails at runtime with `Unknown JSON field`, which is exactly what the
# overlay used to do at three sites — 52 such errors in the 2026-07-20 → 07-27
# session corpus, the largest non-Edit tool-error signature in the window.
#
# The check is STRUCTURAL rather than a literal grep so it also catches a field
# list that is reworded or moved. The file is FLATTENED first: one of the three
# original defect sites spanned three source lines, so a line-based scan is
# blind to precisely the case that motivated this guard.
#
# The forbidden sets below are the measured cross-surface names, not the full
# vocabularies — a full mirror of `gh`'s field lists would go stale on the next
# CLI release and start failing on correct text.
pr_view_forbidden='reviewThreads merged baseRepository authorAssociation commentsCount isPullRequest isLocked repository'
search_forbidden='reviewThreads merged baseRepository mergedAt headRefName headRefOid headRepository mergeStateStatus reviewDecision statusCheckRollup files commits reviews latestReviews mergeable mergeCommit'

surveyor_flat="$(tr '\n' ' ' < "${surveyor}" | tr -s ' ')"

# Emit `<surface>\t<field-list>` for every prescribed command. The gap between
# the subcommand and its --json list must not contain another `gh `, so a list
# is never attributed to a subcommand it does not belong to.
json_specs="$(printf '%s' "${surveyor_flat}" | perl -ne '
  while (/gh (pr view|search prs|search issues|issue view)((?:(?!gh ).)*?)--json ([A-Za-z,]+)/g) {
    print "$1\t$3\n";
  }')"

[ -n "${json_specs}" ] ||
  fail "surveyor overlay: found no 'gh ... --json' commands to validate — the extractor broke"

while IFS="$(printf '\t')" read -r surface fields; do
  [ -n "${surface}" ] || continue
  case "${surface}" in
    'pr view'|'issue view') forbidden="${pr_view_forbidden}" ;;
    'search prs'|'search issues') forbidden="${search_forbidden}" ;;
    *) continue ;;
  esac
  for bad in ${forbidden}; do
    case ",${fields}," in
      *",${bad},"*)
        fail "surveyor overlay prescribes 'gh ${surface} --json ${fields}', but '${bad}' is not a valid ${surface} field — it fails at runtime with 'Unknown JSON field' (#2498)"
        ;;
    esac
  done
done <<EOF
${json_specs}
EOF

# --- GitHub-managed code scanning is not repository breakage (#2536) ----------
#
# A default-setup code-scanning run has no workflow file to fix and GitHub refuses to re-run it, so
# ranking it at rung 0 — which preempts everything — burns a run's opening minutes on something
# structurally unactionable that self-heals. It must still be REPORTED, because a failure persisting
# across several scheduled ticks is a real signal.

grep -Fq 'dynamic/github-code-scanning/' "${surveyor}" ||
  fail "surveyor must classify runs whose path starts 'dynamic/github-code-scanning/' as GitHub-managed (#2536)"

grep -Fq 'GITHUB-MANAGED-SCAN (NO-ACTION) <repo> <workflow> @<sha> failed' "${surveyor}" ||
  fail "surveyor must define the GITHUB-MANAGED-SCAN (NO-ACTION) digest line (#2536)"

grep -Fq 'a GITHUB-MANAGED (NO-ACTION) line never makes this false' "${surveyor}" ||
  fail "surveyor must state that a one-off GitHub-managed run never sets nothing_on_fire: false (#2536)"

# --- The carve-out is a PROPERTY test, not a path allow-list (#2704) ----------
#
# Keying the class on one enumerated path failed OPEN for every other managed path: measured
# 2026-08-07, all 21 red runs on ksail's main were `dynamic/dependabot/`, which the single-path form
# did not cover, so a run applying rung 0 literally would have declared a fire with no workflow file
# to repair and no way to re-run it.

grep -Fq 'dynamic/dependabot/' "${surveyor}" ||
  fail "surveyor must cover Dependabot's managed update runs, not only code scanning (#2704)"

grep -Fq 'GITHUB-MANAGED (NO-ACTION) <repo> <workflow> @<sha> failed' "${surveyor}" ||
  fail "surveyor must define the general GITHUB-MANAGED (NO-ACTION) digest line (#2704)"

grep -Fq 'GITHUB-MANAGED (REPEATED — ACTIONABLE)' "${surveyor}" ||
  fail "surveyor must define the general GITHUB-MANAGED (REPEATED — ACTIONABLE) digest line (#2704)"

# The property must require BOTH conditions. `event: dynamic` alone is not the test — the property
# that makes a run unfixable here is that no workflow file exists in the repository, and the
# surveyor must say so rather than matching a bare event.
grep -Fq 'no workflow file exists in the repository' "${surveyor}" ||
  fail "surveyor must define the managed class by 'no workflow file exists in the repository', not a bare event match (#2704)"

# The streak escalation is the SAFETY NET that makes broadening the class safe. If a future edit
# broadened the exemption without it, an actionable managed failure could hide indefinitely — so the
# surveyor must state the coupling explicitly, not merely happen to contain both rules.
grep -Fq 'escalation is what makes the property test safe' "${surveyor}" ||
  fail "surveyor must state that the streak escalation is what bounds the broadened property test (#2704)"

# The escalation is only a real safety net if the streak is counted over the right unit. One managed
# workflow_id can aggregate many INDEPENDENT jobs: measured 2026-08-07, ksail's dynamic/dependabot/
# runs share one workflow_id and carry a distinct name per dependency+directory. Counting consecutive
# reds across that mixed history would escalate two unrelated FIRST failures as a streak, and let an
# unrelated green break a genuine one — so broadening the class without this makes the escalation
# report noise instead of bounding the exemption.
grep -Fq 'not by `workflow_id` alone' "${surveyor}" ||
  fail "surveyor's streak walk must group by run name, not workflow_id alone (#2704)"

# 🔴 The RAW name is not that unit — Dependabot appends a per-run id ("… - Update #1510869626"), so
# ksail's 48 dynamic/dependabot/ runs on main carry 48 DISTINCT names. An exact-name filter returns
# one run, the streak can never reach 2, and (REPEATED — ACTIONABLE) can never fire — which would
# make the exemption permanent for every managed path instead of one run deep, destroying the safety
# net that justifies the property test. Require the id to be stripped before grouping, and pin the
# absence of the exact-match form so it cannot come back.
# Pin BOTH OPERANDS WHOLE, never an isolated fragment. A bare `sub(…)` / `$ENV.RUN_NAME` /
# `(.name // "")` token search passes as long as the token appears ANYWHERE in the document, so the
# moment prose quotes the old shape — documenting the superseded form is exactly the kind of edit
# that happens here — the assertion goes vacuous while the executable recipe regresses freely.
# Each grep below therefore matches one complete operand of the comparison as it appears in the
# recipe. They are split at the recipe's own line break because `grep -F` is line-oriented: the
# comparison spans two lines, so a single pattern containing `== (($ENV.RUN_NAME` can never match.
# (CodeRabbit raised the vacuity; its suggested one-line form had exactly that defect.)
grep -Fq 'select(((.name // "") | sub("( - Update)? #[0-9]+$"; "")) ==' "${surveyor}" ||
  fail "surveyor must normalise the API run name (null-safe, id stripped) as the comparison's left operand (#2704)"

grep -Fq '(($ENV.RUN_NAME // "") | sub("( - Update)? #[0-9]+$"; "")))]' "${surveyor}" ||
  fail "surveyor must normalise \$ENV.RUN_NAME (null-safe, id stripped) as the comparison's right operand (#2704)"

grep -Fq 'select(.name == $ENV.RUN_NAME)' "${surveyor}" &&
  fail "surveyor must not match the RAW run name — the per-run id caps every streak at 1 (#2704)"

# A run name is untrusted: a workflow's run-name: can be built from a pull-request title, so a name
# carrying a quote would terminate an interpolated jq string and the rest would parse as filter
# syntax. $ENV passes it as data. Pin the absence of the interpolated form too — fixing the query
# while leaving the old shape documented elsewhere would keep the injectable recipe in circulation.
grep -Fq 'select(.name == "<name>")' "${surveyor}" &&
  fail "surveyor must not interpolate an untrusted run name into the --jq filter (#2704)"

# $ENV closes the jq half only — the value still has to reach the environment intact. A single-quoted
# literal ends at the first apostrophe, and real run names carry them, so that form breaks in the
# shell before jq ever sees it. Require the variable handoff, and reject the literal-paste shape:
# without both, the boundary is merely relocated rather than closed.
grep -Fq 'RUN_NAME="$run_name" gh api' "${surveyor}" ||
  fail "surveyor must hand the run name to the environment as a variable, not a literal (#2704)"

grep -Fq "RUN_NAME='<name>'" "${surveyor}" &&
  fail "surveyor must not paste an untrusted run name in as a single-quoted literal (#2704)"

# AGENTS.md must carry the same property test, or the two surfaces disagree about what preempts a run.
grep -Fq 'dynamic/dependabot/' "${constitution}" ||
  fail "AGENTS.md rung-0 must cover Dependabot's managed runs, not only code scanning (#2704)"

grep -Fq 'never by an enumerated path' "${constitution}" ||
  fail "AGENTS.md rung-0 must state the managed carve-out as a property test, not a path list (#2704)"

# Both halves of the property, not just the paths it currently covers: an edit that dropped either
# condition would leave the greps above green while the carve-out silently stopped being a property.
grep -Fq 'event: dynamic' "${constitution}" ||
  fail "AGENTS.md must require the dynamic event for managed runs (#2704)"

grep -Fq 'path` under `dynamic/`' "${constitution}" ||
  fail "AGENTS.md must require a dynamic/ path for managed runs (#2704)"

# RED SET — the streak predicate must match telemetry's, which counts startup_failure as red. A
# managed run whose config will not parse concludes startup_failure on every attempt, so omitting it
# means such a run can never accumulate a streak and reports NO-ACTION forever with coverage dead.
grep -Fq 'failure`, `timed_out` OR `startup_failure`' "${surveyor}" ||
  fail "surveyor's managed streak must treat startup_failure as red, as telemetry does (#2704)"

grep -Fq 'failure OR timed_out OR startup_failure' "${surveyor}" ||
  fail "surveyor's REPEATED escalation must treat startup_failure as red (#2704)"

grep -Fq 'timed_out` or `startup_failure`) on the next run of `main`' "${constitution}" ||
  fail "AGENTS.md rung-0 must treat startup_failure as red for managed runs (#2704)"

# ESCALATION — the exemption covers only the FIRST failure of a streak. A scan still failing on the
# next scheduled run is ours to repair (build, code-scanning config, or advanced setup), and must not
# sit behind a permanent NO-ACTION line while security coverage is silently dead.
grep -Fq 'GITHUB-MANAGED-SCAN (REPEATED — ACTIONABLE)' "${surveyor}" ||
  fail "surveyor must escalate a GitHub-managed scan that fails on consecutive scheduled runs (#2536)"

grep -Fq 'Only the **first** failure of a streak is exempt' "${surveyor}" ||
  fail "surveyor must bound the GitHub-managed exemption to the first failure of a streak (#2536)"

grep -Fq 'but a (REPEATED — ACTIONABLE) one does' "${surveyor}" ||
  fail "surveyor must count a repeated GitHub-managed failure against nothing_on_fire (#2536)"

# NEGATIVE CONTROL — the repository's own failing workflow must remain rung-0 breakage. Without this,
# a future edit could exempt runs wholesale and every assertion above would still pass.
#
# Two assertions, because the digest LINE and the CLASSIFICATION are separable: an edit could keep the
# `CI red on main` template while quietly detaching it from `nothing_on_fire`, and the line's presence
# alone would not notice.
grep -Fq '<repo>: CI red on main @<sha>' "${surveyor}" ||
  fail "surveyor must still report a repository-owned failing workflow as CI red on main (#2536)"

grep -Fq 'true only if NO CI red on main' "${surveyor}" ||
  fail "surveyor must keep a repository-owned red on main driving nothing_on_fire: false — the GitHub-managed exemption must not detach the general rule (#2536)"

# The rung-0 definition in the constitution must carry the same carve-out, or the two surfaces
# disagree about what preempts a run.
grep -Fq 'A failing GitHub-*managed* run is NOT breakage' "${constitution}" ||
  fail "AGENTS.md rung-0 must state that a GitHub-managed run is not breakage (#2536)"

# The constitution must carry the STREAK BOUND too. Without this, AGENTS.md could be edited to exempt
# every repeated failure while the overlay still escalates — the two surfaces would then disagree about
# whether dead security scanning is breakage, and only the overlay assertion above would notice.
grep -Fq 'Only the first failure of a streak' "${constitution}" ||
  fail "AGENTS.md must bound the GitHub-managed exemption to the first failure of a streak (#2536)"

# The streak walk must use the same red set and the same branch filter as the red-set query, or it
# misclassifies timeout streaks and lets pull-request scans pollute the history.
grep -Fq 'Red means `failure`, `timed_out` OR `startup_failure`' "${surveyor}" ||
  fail "surveyor's streak walk must treat timed_out as red, matching the red set (#2536)"

grep -Fq 'runs?branch=main&per_page=100' "${surveyor}" ||
  fail "surveyor's streak walk must filter to main, or a PR-triggered managed run pollutes it (#2536)"

# The exemption must never rest on `event: dynamic` ALONE — `dynamic` stays a legitimate main-branch
# event, so a bare event match would exempt any future managed run type wholesale. #2704 broadened the
# class from one hard-coded path to a property, and this guard is what keeps that property honest: it
# requires BOTH the dynamic event and a `dynamic/` path, i.e. "no workflow file exists in the
# repository". The original #2536 wording ('never on `event: dynamic` alone') stated the same
# constraint; the assertion now pins the constraint itself rather than that one phrasing, so a
# rewording cannot drop the protection and a bare-event match still fails.
grep -Fq 'it is not a bare event match' "${surveyor}" ||
  fail "surveyor must not key the GitHub-managed exemption on 'event: dynamic' alone (#2536, #2704)"

grep -Fq 'Requiring **both** `event: dynamic` and a `dynamic/` path' "${surveyor}" ||
  fail "surveyor must require BOTH the dynamic event and a dynamic/ path for the managed carve-out (#2536, #2704)"

grep -Fq '`workflow_dispatch`, `dynamic`' "${surveyor}" ||
  fail "surveyor must keep 'dynamic' in the main-branch event list — the exemption is by path (#2536)"


# --- Ownership disclosure is a THREE-valued literal test, not a prefix boolean (#2762) ----------
# Measured 2026-08-11 (snapshot n=75; the corpus is live and drifts, so this documents the ORIGINAL
# defect rather than a current total): the two-valued
# `disclosure=<yes|no>` field was 100% precise when it said `yes` (26/26 routine) but carried NO
# information when it said `no` — 49 of 75 rows (65%), collapsing three classes that demand OPPOSITE
# actions: 5 maintainer-interactive (HANDS-OFF), 7 routine whose disclosure simply is not at position
# zero, and 37 with no marker at all. Acting on that conflation mutated two of the maintainer's
# interactive PRs (platform#2985, #3034) via `gh pr update-branch`.
grep -Fq 'disclosure=<routine|interactive|none>' "${surveyor}" ||
  fail "surveyor must emit the three-valued ownership disclosure field, not a yes/no boolean (#2762)"

# Position is a red herring and must never be reinstated as the discriminator: platform#2985 carries
# the maintainer literal at the START of the body and #3034 carries it as a trailing line, so an
# anchored check misses one of them whichever end it anchors to.
grep -Fq 'which literal, never where it sits' "${surveyor}" ||
  fail "surveyor must discriminate ownership by WHICH literal, not by its position (#2762)"

# The interactive literal must be searched over the WHOLE body.
grep -Fq 'Generated with [Claude Code]' "${surveyor}" ||
  fail "surveyor must name the maintainer-interactive literal it matches on (#2762)"

# Fail-safe precedence: the contract's own asymmetry — reading the maintainer's PR as the routine's
# licenses an unrequested mutation, while the reverse merely parks a PR a later run can pick up.
grep -Fq 'interactive wins' "${surveyor}" ||
  fail "surveyor must resolve a both-literals body to interactive, the fail-safe direction (#2762)"

# The constitution must name the literal rather than a position-based 'trailer', which is what made
# the prefix-only reading look correct.
grep -Fq 'Generated with [Claude Code]' "${constitution}" ||
  fail "AGENTS.md must name the maintainer-interactive literal (#2762)"

grep -Fq 'position is not the discriminator' "${constitution}" ||
  fail "AGENTS.md must state that the ownership discriminator is the literal, not its position (#2762)"


# The two literals are NOT symmetric, and collapsing them is the P1 Codex caught on #2767: only the
# interactive literal is decisive. `Generated by the` also appears on maintainer-interactive PRs, so
# it corroborates the orchestrator's creation record rather than replacing it — the surveyor keeps
# every such PR OWNERSHIP-UNVERIFIED and a `routine` value is never authority to write.
grep -Fq 'is decisive, `routine` is only corroborating' "${surveyor}" ||
  fail "surveyor must mark the routine literal corroborating, not decisive (#2762)"

grep -Fq 'NEVER does' "${constitution}" ||
  fail "AGENTS.md must deny the routine literal standalone ownership authority (#2762)"

# The literals carry no markdown emphasis. A bolded quotation of them in prose is what trains the
# next implementer to grep a string that matches nothing (the same trap recorded at t1058).
grep -Fq 'never grep a bolded form' "${constitution}" ||
  fail "AGENTS.md must warn that the ownership literals carry no markdown emphasis (#2762)"

grep -Fq 'never grep a bolded form' "${surveyor}" ||
  fail "surveyor must warn that the interactive literal carries no markdown emphasis (#2762)"

grep -Fq 'Generated **with** [Claude Code]' "${surveyor}" &&
  fail "surveyor must not quote the interactive literal in a bolded form that matches no real body (#2762)"


# Both literals use IDENTICAL matching syntax (a structural line, with fenced content NOT suppressed
# -- see the no-fence-state decision below); only the ownership
# WEIGHT differs -- interactive decides alone, routine only corroborates. An earlier revision of this
# PR matched them with different strictness; that framing was an artifact of fixing one literal at a
# time, and leaving it in the definition let an implementation legitimately match interactive loosely
# and recreate the permanent false HANDS-OFF (Codex P2). Both halves are pinned so neither drifts.
grep -Fq 'begins with the marker' "${surveyor}" ||
  fail "surveyor must line-anchor the routine literal, not match it anywhere (#2762)"

grep -Fq 'begins with the marker' "${constitution}" ||
  fail "AGENTS.md must line-anchor the routine literal (#2762)"

# NOT `grep -Fq 'anywhere'` — that word occurs in unrelated surveyor prose, so the assertion passed
# regardless of the rule and would have stayed green if the match were swapped for a body-start
# anchor (Codex P2 on #2767). Worse, ablating EVERY occurrence made it look like it fired. Pin a
# phrase that exists nowhere else and states the rule itself.
grep -Fq 'Both literals are matched as a STRUCTURAL LINE, anywhere in the body' "${surveyor}" ||
  fail "surveyor must match both literals as a structural line anywhere in the body (#2762)"

grep -Fq 'Never a bare substring, and never anchored to the body start' "${surveyor}" ||
  fail "surveyor must forbid BOTH a bare substring and a body-start anchor (#2762)"

grep -Fq 'structural line' "${constitution}" ||
  fail "AGENTS.md must require structural-line matching for the ownership literals (#2762)"

# The malformed-placement tolerance must not read as an emission convention (Codex P2 on #2767).
grep -Fq 'DEFECTS, not the convention' "${constitution}" ||
  fail "AGENTS.md must mark a below-heading disclosure a defect, not the convention (#2762)"

# `none` is a real third state with its own contract: it means neither literal was found, and it is
# a synonym for NEITHER party. Asserting only that the enum lists three spellings would pass on a
# definition that never says what `none` means (CodeRabbit 🟡 Minor on #2767).
grep -Fq 'neither literal' "${surveyor}" ||
  fail "surveyor must define \`none\` as neither literal present (#2762)"

grep -Fq 'not** a synonym for the maintainer' "${surveyor}" ||
  fail "surveyor must state that \`none\` is not a synonym for the maintainer's PR (#2762)"

grep -Fq 'resolves it from its creation record' "${surveyor}" ||
  fail "surveyor must route the \`none\` case to the orchestrator's creation record (#2762)"


# NO fenced-block suppression. Six review rounds each found one more container spelling past a fence
# detector, and a 1029-body portfolio differential (2026-08-11) showed the whole state machine changes
# ZERO verdicts. Both sites must state that absence explicitly, because a reader who finds no fence
# rule cannot otherwise tell a deliberate omission from an oversight — and re-adding one silently is
# exactly how the enumeration loop restarts.
for _site in "${surveyor}" "${constitution}"; do
  _n="$(basename "${_site}")"
  grep -Fq 'there is NO fenced-block suppression' "${_site}" ||
    fail "${_n} must state that fenced blocks are NOT suppressed when matching a marker (#2762)"
  # The absence is only defensible with its measurement and its named cost. Without the cost clause a
  # later round reads the omission as a bug and "fixes" it; without the measurement the omission has
  # no evidence behind it.
  grep -Fq '1029 portfolio PR bodies' "${_site}" ||
    fail "${_n} must carry the corpus size behind the no-fence decision (#2762)"
  # The cost is now an ATTRIBUTION cost, not a parked PR: the driving half of HANDS-OFF was retired
  # on 2026-08-08, so a fenced example misreads whose control channel a `devantler` comment is rather
  # than freezing the PR. What must still be stated is that the cost is named and measured.
  grep -Fq 'fences an example' "${_site}" ||
    fail "${_n} must name the accepted cost of dropping fence suppression (#2762)"
  grep -Fq 'measured incidence is **0**' "${_site}" ||
    fail "${_n} must state the measured incidence of that accepted cost (#2762)"
done

# The two rules that REMAIN serve the matcher, not example-suppression. The org PR template puts the
# disclosure under a `- ` bullet, so losing the container prefix loses real disclosures.
#
# The CONSTITUTION states them as prose, because a reader deciding whether a PR is the maintainer's
# needs the rule in front of them. The SURVEYOR does not restate them — it calls the classifier, whose
# Go tests pin the same two rules executably. Carrying the matcher as prose in both places is what
# produced the defect this split fixes: on 2026-08-11 a run reported `disclosure=none` for four live
# maintainer PRs whose interactive literal sat on the LAST line of the body, while the prose above it
# already forbade position anchoring and already named platform#3034 as the worked example (#2784).
grep -Fq 'container prefix' "${constitution}" ||
  fail "AGENTS.md must read a marker line through its Markdown container prefix (#2762)"
grep -Fq 'four or more spaces of indentation at the current depth' "${constitution}" ||
  fail "AGENTS.md must exclude Markdown indented code blocks from marker matching (#2762)"

# The surveyor must DELEGATE rather than re-derive. Without this the prose could quietly grow a second
# matcher back and drift from the classifier again.
# Match the COMPLETE invocation, not just the filename: a bare filename check still passes if the
# command form or its required --repo/--pr arguments are dropped, leaving an instruction that names
# the classifier without saying how to run it.
grep -Fq '.claude/scripts/pr-ownership-disclosure.sh --repo <owner>/<repo> --pr <n>' "${surveyor}" ||
  fail "portfolio-surveyor.md must carry the full ownership-classifier invocation (#2784)"
# The PRESCRIBED form reuses the body the deepening query already returned, so pin that invocation
# too — otherwise the doc could keep only the fetching mode and quietly reintroduce a second API
# request per candidate against the survey's own budget.
grep -Fq '.claude/scripts/pr-ownership-disclosure.sh --input -' "${surveyor}" ||
  fail "portfolio-surveyor.md must prescribe the body-reusing classifier invocation"

# And the classifier must exist, be executable, and actually pin the two matcher rules — otherwise the
# delegation above points at nothing and the guarantee is lost rather than moved.
_classifier="${repo_root}/.claude/scripts/pr-ownership-disclosure.sh"
_classifier_src="${repo_root}/.claude/scripts/pr-ownership-disclosure-go/main.go"
_classifier_test="${repo_root}/.claude/scripts/pr-ownership-disclosure-go/main_test.go"
[ -x "${_classifier}" ] ||
  fail "pr-ownership-disclosure.sh must exist and be executable (#2784)"
grep -Fq 'stripContainers' "${_classifier_src}" ||
  fail "the classifier must strip Markdown container prefixes (#2784)"
grep -Fq 'codeBlockIndent' "${_classifier_src}" ||
  fail "the classifier must exclude Markdown indented code blocks (#2784)"
# The regression itself, pinned executably rather than described.
grep -Fq 'TestBodyStartAnchorWouldFail' "${_classifier_test}" ||
  fail "the classifier's tests must pin the body-start-anchor regression (#2784)"

# BEHAVIOURAL fixture, not another prose pin. The assertions above pin what the definition SAYS; this
# pins that the stated rule, implemented literally, actually classifies the shapes we depend on. Codex
# correctly noted on #2767 that the grep assertions exercise no behaviour, so a rule could be worded
# correctly and still be unimplementable or wrong on the cases that matter.
# STRIP a line's Markdown container prefix, setting OWN_CONTENT / OWN_CODE. This is what makes the
# match STRUCTURAL rather than a bare substring: the org PR template puts the disclosure under a
# `- ` bullet, so a container-blind matcher misses real disclosures.
#
# The prefix is consumed and DISCARDED, never returned. It used to be returned as OWN_PREFIX so the
# fence detector could anchor a closer to its opener's depth; with no fence state, nothing reads it,
# and keeping it would be dead code that implies a comparison the classifier no longer makes.
#
# Containers consumed: up to three spaces of alignment, blockquote `>` markers (plus one optional
# following space), and `-`/`*` list markers. A list marker counts only when whitespace follows it,
# so `**bold` keeps its asterisks and stays ordinary prose.
#
# OWN_CODE marks a Markdown INDENTED CODE BLOCK — four or more spaces of indentation at the current
# container depth. Such a line is literal text and carries no disclosure marker. Without this,
# four-space-indented example markup is read as the real thing.
ownership_split() {
  local ln="$1" n c
  OWN_CONTENT=''; OWN_CODE=0
  while :; do
    n=0
    while :; do
      c="${ln:0:1}"
      case "${c}" in
        ' ')  n=$((n + 1)) ;;
        '	') n=$((n + 4)) ;;
        *) break ;;
      esac
      ln="${ln:1}"
      [ "${n}" -ge 4 ] && { OWN_CODE=1; break; }
    done
    [ "${OWN_CODE}" -eq 1 ] && break
    case "${ln}" in
      '>'*)
        ln="${ln#>}"
        # One space OR tab is the blockquote's own separator. Consuming only the space would leave a
        # tab to be counted as four columns by the indentation cap, so a tab-separated blockquote
        # would read as an indented code block and its marker would be MISSED -- the dangerous
        # direction, since a missed interactive marker makes the maintainer's PR look like ours.
        case "${ln}" in
          ' '*|'	'*) ln="${ln:1}" ;;
        esac
        continue ;;
      '-'' '*|'-''	'*|'*'' '*|'*''	'*)
        # Consume the list marker AND its separator, for the same reason the
        # blockquote branch above does: leaving a TAB behind lets the next pass
        # count it as four columns, read the line as an indented code block, and
        # discard the marker. The fix was applied to `>` and not here, so
        # `-<tab>🤖 Generated with [Claude Code]` -- a list-wrapped interactive
        # disclosure -- was classified `routine`, i.e. the maintainer's PR read
        # as ours. That is the expensive direction, so both branches must agree.
        ln="${ln:1}"
        case "${ln}" in
          ' '*|'	'*) ln="${ln:1}" ;;
        esac
        continue ;;
    esac
    break
  done
  OWN_CONTENT="${ln}"
}

# Sets OWN_INTER/OWN_ROUTINE. There is deliberately NO fence state here: a marker line counts wherever
# it appears. Six review rounds each found one more container spelling that got past a delimiter-aware
# fence detector, and a 1029-body portfolio differential (2026-08-11) measured that the whole state
# machine changes ZERO verdicts -- so it bought an unbounded enumeration and decided nothing. The cost
# of dropping it is a PR that FENCES an example of the interactive literal parking itself HANDS-OFF:
# the cheap direction (our own PR waits for a human), measured incidence 0.
ownership_scan() {
  local body ln content inter=0 routine=0
  body="$(printf '%b' "$1")"
  while IFS= read -r ln; do
    ownership_split "${ln}"
    content="${OWN_CONTENT}"

    # An indented code block is literal text at every level, so it carries no marker.
    if [ "${OWN_CODE}" -eq 1 ]; then continue; fi

    case "${content}" in '🤖'*) content="${content#🤖}" ;; esac
    while [ -n "${content}" ]; do
      case "${content}" in ' '*|'	'*) content="${content#?}" ;; *) break ;; esac
    done
    case "${content}" in
      'Generated with [Claude Code]'*) inter=1 ;;
      'Generated by the'*) routine=1 ;;
    esac
    # Process substitution, never a pipe: a piped `while` runs in a subshell, so `inter` and
    # `routine` would be set there and discarded, and every body would classify `none`. Measured:
    # a counter incremented in a piped loop reads 0 afterwards and 2 through process substitution.
  done < <(printf '%s\n' "${body}")
  OWN_INTER="${inter}"; OWN_ROUTINE="${routine}"
}

ownership_fixture() {
  ownership_scan "$1"
  # `interactive` wins ties: reading the maintainer's PR as ours licenses an unrequested mutation,
  # while the reverse merely parks one of ours until a human looks.
  if [ "${OWN_INTER}" -eq 1 ]; then printf 'interactive\n'
  elif [ "${OWN_ROUTINE}" -eq 1 ]; then printf 'routine\n'
  else printf 'none\n'; fi
}

expect_class() {
  got="$(ownership_fixture "$2")"
  [ "$got" = "$1" ] || fail "ownership classifier: expected $1, got $got — for: $3 (#2762)"
}

ROUTINE_LINE='> \xf0\x9f\xa4\x96 Generated by the Agentic Engineer'
INTER_LINE='> \xf0\x9f\xa4\x96 Generated with [Claude Code](https://claude.com/claude-code)'

expect_class interactive "${INTER_LINE}" 'leading marker line (#2985 shape)'
expect_class interactive "text\n\xf0\x9f\xa4\x96 Generated with [Claude Code](https://x)" 'trailing marker line (#3034 shape)'
expect_class routine     "### Motivation\n\n- ${ROUTINE_LINE}" 'disclosure under the org template heading'
expect_class routine     "${ROUTINE_LINE}\n\nbody" 'canonical routine disclosure'
expect_class none        'no marker at all here' 'unmarked body'
# the false-positive shape this PR closed: a bare substring match reads prose ABOUT the convention as
# a disclosure, so a PR discussing it parks itself HANDS-OFF forever. Line structure is what fixes it.
expect_class routine     "${ROUTINE_LINE}\n\nwe match Generated with [Claude Code] inline" 'marker quoted mid-sentence must NOT win'

# `interactive wins` is the fail-safe for a body carrying BOTH markers. No live PR carries both, so it
# is LATENT — which is exactly why it needs a fixture: nothing else fails if it is removed. Without
# these two cases, reordering the classifier to test ROUTINE before INTER leaves every other fixture
# green while the mixed case silently becomes `routine`, i.e. "safe to drive the maintainer's PR".
# Both orders are asserted, because precedence must not depend on which marker appears first.
expect_class interactive "${ROUTINE_LINE}\n\n${INTER_LINE}" 'both markers, routine first -> interactive wins'
expect_class interactive "${INTER_LINE}\n\n${ROUTINE_LINE}" 'both markers, interactive first -> interactive wins'

# Markdown-bold text is NOT a marker line. `[\s>*\-]*` accepted `**` as a prefix, so a bolded literal
# in ordinary prose classified as a disclosure — the same false-positive family as the mid-sentence
# and fenced cases, and the reason the contract says the literals carry no emphasis (CodeRabbit).
expect_class none    '**Generated with [Claude Code](https://x)**' 'BOLD interactive text is not a marker'
expect_class none    '**Generated by the Agentic Engineer**'       'BOLD routine text is not a marker'

# THE ACCEPTED COST, pinned deliberately so a later round cannot read it as a bug and "fix" it. With
# no fence state, a body that FENCES an example of the interactive literal classifies `interactive`
# and parks itself HANDS-OFF. That is the CHEAP direction -- our own PR waits for a human -- and its
# measured incidence across 1029 portfolio bodies (2026-08-11) is 0. Six review rounds each found one
# more container spelling past a delimiter-aware detector; deleting these fixtures is how that
# enumeration restarts, so they state the trade instead of hiding it.
expect_class interactive "${ROUTINE_LINE}\n\n\`\`\`\n${INTER_LINE}\n\`\`\`" 'a FENCED interactive example still classifies interactive (accepted cost)'
expect_class interactive "${ROUTINE_LINE}\n\n> \`\`\`markdown\n> > \xf0\x9f\xa4\x96 Generated with [Claude Code](https://x)\n> \`\`\`" 'a fence nested in a blockquote suppresses nothing'

# THE DIRECTION THAT MATTERS: a fence must never swallow a REAL trailing marker, because that drives
# the maintainer's PR. Each of these was a live defect under some fence implementation -- an unclosed
# fence, a mixed delimiter, a shorter inner run -- and all three are now structurally unreachable,
# which is the point of removing the state machine rather than repairing it a seventh time.
expect_class interactive "${ROUTINE_LINE}\n\n\`\`\`\nx\n\`\`\`\n${INTER_LINE}" 'a marker after a closed fence counts'
expect_class interactive "${ROUTINE_LINE}\n\n\`\`\`\nx\n${INTER_LINE}" 'an UNCLOSED fence cannot swallow a real trailing marker'
expect_class interactive "${ROUTINE_LINE}\n\n\`\`\`\n~~~\nx\n\`\`\`\n${INTER_LINE}" 'a mixed-delimiter body cannot swallow a real trailing marker'
expect_class interactive "${ROUTINE_LINE}\n\n\`\`\`\`\n\`\`\`\nx\n\`\`\`\n\`\`\`\`\n${INTER_LINE}" 'a nested shorter run cannot swallow a real trailing marker'

# A fence TOKEN is not itself a marker line. Without this, a matcher that stopped distinguishing
# delimiters from content would still pass everything above.
expect_class none "\`\`\`\n\`\`\`\n~~~\n~~~" 'fence tokens alone carry no marker'

# INDENTED CODE BLOCK -- four or more spaces at the current depth is Markdown's literal-text form and
# carries no marker. One of the two rules that REMAIN, because it serves the matcher.
# The marker here is BARE -- no `>` in front. With a blockquoted marker the split stops at the
# indentation cap before it would consume the `>`, so the line fails to match for that reason
# instead and the assertion passes with the code-block skip deleted -- measured vacuous.
expect_class routine "${ROUTINE_LINE}\n\nExample:\n\n    \xf0\x9f\xa4\x96 Generated with [Claude Code](https://x)" 'a four-space indented code block is not a marker line'
# A tab counts as four columns, so the cap reaches it too.
expect_class routine "${ROUTINE_LINE}\n\nExample:\n\n\t\xf0\x9f\xa4\x96 Generated with [Claude Code](https://x)" 'a tab-indented code block is not a marker line'
# Negative control: three spaces is alignment, not code. Without it the cap swallows every indented
# line and discards a REAL marker -- the direction that costs the maintainer's PR.
expect_class interactive "${ROUTINE_LINE}\n\n   ${INTER_LINE}" 'three spaces is alignment: the marker still counts'
# A tab is the blockquote's separator, not content indentation. Counting it as four columns would
# hide a REAL interactive marker -- the direction that costs the maintainer's PR, not just a parked one.
expect_class interactive "${ROUTINE_LINE}\n\n>\t\xf0\x9f\xa4\x96 Generated with [Claude Code](https://x)" 'a tab-separated blockquote marker still counts'
# The SAME hazard one container over. The blockquote branch consumed its separator and the list
# branch did not, so a tab-separated LIST marker hit the four-column cap and the disclosure was
# discarded -- the maintainer's PR reading as ours. A rule applied to one container and not its
# sibling is the recurring shape here, so this fixture pins the pair together.
expect_class interactive "${ROUTINE_LINE}\n\n-\t\xf0\x9f\xa4\x96 Generated with [Claude Code](https://x)" 'a tab-separated LIST marker still counts'

echo "portfolio surveyor contract: all assertions passed"

# ── the four ownership-signal defects Codex found on #2723 ────────────────────────────────────────
# All four share one shape: a takeover decision resting on a value that is either unreadable, not
# actually fetched, or produced by the acting run itself. Each is pinned in the surface that has to
# carry it, and each fails on its own.
constitution_flat="$(tr '\n' ' ' < "${constitution}" | tr -s ' ')"

# (1) The acting lane's own push must not read as a rival. Pin BOTH halves: the table row's exclusion,
#     and the survey field that makes it applicable without re-deriving the lane.
case "${constitution_flat}" in
  *'within the last **~2h**, **by anyone but you**'*) ;;
  *) fail "AGENTS.md active-work row still counts the acting lane's own push as someone else's" ;;
esac
#     The lane ALONE is not enough: it names a namespace shared with the Agent Improver, which is the
#     very case (2) below says must stay live. The consumer's rule is a match on branch and sha, so
#     the signal has to carry that identity rather than leaving it to be recovered from some other
#     field's payload — assert the complete emitted identity, never a lane-only token.
#     Bind this to EVERY emitted `active=` shape, not to the document. A flattened-document match is
#     satisfied by the explanatory prose above, so an `active=` template could regress to a lane-only
#     token while this assertion still passed — coverage that reads real and proves nothing. Compare
#     the count of lines emitting an `active=` template against those opening it with the complete
#     identity: any template that drops the branch+sha makes the two differ.
#     The needle is the identity ITSELF, not `active=<pushed:…` — the template opens with the
#     `none|` alternative so that the joined-signal grammar is expressible (a flat `<a|b|…|none>`
#     choice cannot say "emit every signal that holds"). Anchoring the needle to the old opening
#     would count zero and report every template as identity-less, which is a false failure; anchoring
#     it to the identity keeps the property this assertion actually guards — every emitted template
#     spells the complete branch+sha, never a lane-only token.
active_templates=$(grep -c 'active=<' "${surveyor}" || true)
active_with_identity=$(grep -c 'pushed:<age>@<lane>:<headRefName>@<headRefOid>|' "${surveyor}" || true)
if [ "${active_templates}" -eq 0 ]; then
  fail "no active= template found in the surveyor, so the push-identity assertion would be vacuous"
fi
if [ "${active_templates}" -ne "${active_with_identity}" ]; then
  fail "an active= template omits the branch+sha identity (${active_with_identity}/${active_templates} carry it), so the consumer cannot attribute a push to its own run"
fi
case "${surveyor_flat}" in
  *'The branch and sha are part of the SIGNAL, not left to be cross-referenced'*) ;;
  *) fail "the surveyor does not state that the push identity travels in the signal itself" ;;
esac
#     NEGATIVE assertion: the retired lane-plus-creation-record discount must not survive alongside
#     the branch+sha rule. Carrying both is worse than carrying only the old one, because a consumer
#     may follow either — and the lane is SHARED with the Agent Improver, so the retired form
#     authorises discounting a live sibling push and writing over active work.
#     Match the AUTHORISING CONSTRUCTION, not one sentence — a reworded grant would otherwise pass.
#     Note the phrase "creation record" alone cannot be blacklisted: the document uses it correctly in
#     the prohibition that explains WHY the lane is insufficient, so keying on it would fail on
#     compliant text. Key on a discount being GRANTED by namespace or creation record instead.
for retired_grant in \
  'discounts a signal from its **own** namespace when its creation record covers that PR' \
  'creation record covers that PR' \
  'own namespace, and my creation record' \
  'authorises discounting' \
  'authorizes discounting'; do
  case "${surveyor_flat}" in
    *"${retired_grant}"*)
      fail "the retired namespace-plus-creation-record discount is still authorised alongside the branch+sha rule (matched: ${retired_grant})" ;;
  esac
done
#     The positive binding above is the real protection: this negative is defence-in-depth and cannot
#     be made reword-proof by enumeration, which is why the discount condition is also asserted
#     positively below.
case "${surveyor_flat}" in
  *'only when that exact branch and sha are ones THIS RUN pushed'*) ;;
  *) fail "the surveyor does not scope the discount to what this run actually pushed" ;;
esac

# (2) `pushed:unknown` must be defined AND expiring — live-forever parks the PR, idle authorises a
#     takeover on data the survey admits it could not read.
case "${surveyor_flat}" in
  *'counts as LIVE while the PR'*'own newest observable timestamp (`updatedAt`) is inside the ~2h window, and stops counting once that elapses'*) ;;
  *) fail "the surveyor leaves pushed:unknown without an expiring ownership meaning" ;;
esac

# (3) A thread-only human reply must be read from the FLAT REST surface. Nesting `comments` inside the
#     GraphQL thread query paginates PER THREAD, so one cursor cannot drain it and a thread past 100
#     comments silently drops its newest — exactly where a live human reply sits. A bounded `first:`/
#     `last:` window has the same hole one size along, so the fix is the surface, not the page size.
case "${surveyor_flat}" in
  *'repos/<owner>/<repo>/pulls/<n>/comments" --paginate'*) ;;
  *) fail "the surveyor does not read thread replies from the flat, fully-drainable REST surface" ;;
esac
case "${surveyor_flat}" in
  *'GraphQL paginates a nested connection **per thread**'*) ;;
  *) fail "the surveyor does not record why nesting the comments connection is unsafe" ;;
esac
# ...and the SECOND consumer of that query. Narrowing the GraphQL thread query to `isResolved` broke
# the candidate-maintainer-comment path, which still said to take thread replies from it — recreating
# the same incomplete-data condition one section over. That path is the maintainer's control channel,
# so a dropped reply is direction never acted on, not merely a delayed takeover.
case "${surveyor_flat}" in
  *'gh api "repos/devantler-tech/<repo>/pulls/<n>/comments" --paginate'*) ;;
  *) fail "the candidate-comment path does not read thread replies from the flat REST endpoint" ;;
esac
case "${surveyor_flat}" in
  *'Both other reads remain required — a maintainer steer can live in any of the three'*) ;;
  *) fail "the candidate-comment path does not require ALL THREE candidate-comment surfaces" ;;
esac

# (4) `nothing_on_fire: true` alongside undeepened PRs asserts health the survey never measured.
case "${surveyor_flat}" in
  *'nothing_on_fire: <true|false|unknown>'*) ;;
  *) fail "the digest cannot express an unassessed portfolio" ;;
esac
case "${surveyor_flat}" in
  *'EMIT `unknown` WHENEVER ANY `QUERY-UNKNOWN`, `NOT-DEEPENED (budget)`, `NOT-DEEPENED (next-shard)`, OR `DISCOVERY-TRUNCATED (prs, 300 cap)` ROW EXISTS'*) ;;
  *) fail "the digest may still claim nothing_on_fire while PRs went unassessed or undiscovered" ;;
esac
# A survey that tries to deepen the whole portfolio before returning can spend the complete dispatch
# on joins and deliver no candidate to the writer. Bound the expensive shard, preserve global UNKNOWN,
# and make the already-deepened rows explicitly usable instead of treating the remainder as a global
# mutation lock.
case "${surveyor_flat}" in
  *'at most eight actionable PRs per digest'*) ;;
  *) fail "the surveyor still attempts an unbounded all-PR deepening pass before returning" ;;
esac
case "${surveyor_flat}" in
  *'After eight candidate deepening attempts, whether each join succeeded or failed'*) ;;
  *) fail "failed joins can still evade the eight-candidate deepening bound" ;;
esac
case "${surveyor_flat}" in
  *'NOT-DEEPENED (next-shard)'*) ;;
  *) fail "the digest cannot distinguish deliberate bounded deferral from API-budget exhaustion" ;;
esac
case "${surveyor_flat}" in
  *'deepened rows remain candidate-actionable'*) ;;
  *) fail "the surveyor still lets an incomplete later shard freeze fully joined candidates" ;;
esac
case "${surveyor_flat}" in
  *'issue descent remains blocked'*) ;;
  *) fail "the surveyor can descend into issues while the higher-priority PR queue is incomplete" ;;
esac
# Truncated discovery is unassessed coverage exactly as an undeepened PR is, so both must drive the
# health field — but only the PR one. Pinning the issue row's EXCLUSION matters as much: issues are
# rungs 2-4, so letting them set `unknown` would report a backlog gap as portfolio breakage and pin
# the ladder at rung 0 on every survey above the cap.
case "${surveyor_flat}" in
  *'the issue-truncation row never affects this field'*) ;;
  *) fail "truncated issue discovery may still drive nothing_on_fire, mislabelling a backlog gap as breakage" ;;
esac
# The rows themselves must exist in the emitted grammar, or the fallback above requires output the
# digest has no shape for — the same promised-but-unemittable defect this round is closing elsewhere.
for truncation_row in 'DISCOVERY-TRUNCATED (prs, 300 cap)' 'DISCOVERY-TRUNCATED (issues, 300 cap)'; do
  case "${surveyor_flat}" in
    *"- ${truncation_row}"*) ;;
    *) fail "the digest grammar defines no ${truncation_row} row, so truncation cannot be reported" ;;
  esac
done

echo "portfolio surveyor contract: ownership-signal assertions passed"

# ── Signals the grammar PROMISED that no implementation could actually emit ───────────────────────
# Each of these is the same defect shape: a rule elsewhere requires a value, and the emitted grammar
# has no alternative for it — so a conforming implementation must either break the grammar or drop
# the signal. Dropping reads as `active=none`, which authorises exactly the takeover the signal
# exists to prevent. Assert against the EMITTED templates, never the prose describing them: the
# explanatory paragraphs contain these tokens too, so a flat-document match passes while every
# template omits them (that is how the identity token stayed inert for weeks).

# (6) `pushed:unknown@<updatedAt-age>` — required whenever fork activity is unreadable.
active_templates=$(grep -c 'active=<' "${surveyor}" || true)
active_with_unknown=$(grep 'active=<' "${surveyor}" | grep -cF 'pushed:unknown@<updatedAt-age>' || true)
if [ "${active_templates}" -eq 0 ]; then
  fail "no active= template found in the surveyor, so the pushed:unknown assertion would be vacuous"
fi
if [ "${active_templates}" -ne "${active_with_unknown}" ]; then
  fail "an active= template omits pushed:unknown@<updatedAt-age> (${active_with_unknown}/${active_templates} carry it), so the surveyor must break its own grammar or collapse an unreadable push to none"
fi

# (6a) `active=` carries EVERY signal that holds, not the strongest one. The template's `|` reads as
#      a choice, and a one-of encoding is lossy for an any-of test whose consumer DISCOUNTS some
#      alternatives: the orchestrator discards `pushed:` when the branch and SHA are its own, so a
#      row that emitted only the push collapses to unowned and a concurrent human-comment signal —
#      true at the same instant, never emitted — is gone. That authorises the takeover the signal
#      exists to prevent, which is the same defect shape as (6), one level up.
case "${surveyor_flat}" in
  *'emit EVERY signal that holds, `+`-joined'*) ;;
  *) fail "the active= field does not state that every holding signal is emitted, so a one-of encoding can drop a live signal the consumer needed" ;;
esac
case "${surveyor_flat}" in
  *'the consumer discounts some of them'*) ;;
  *) fail "the active= field does not say the consumer discounts some alternatives, which is why a strongest-only encoding is lossy" ;;
esac

# (6b) The deepened read must refresh the two fields that are NOT derivable from the head SHA.
#      `updatedAt` backs `pushed:unknown@<updatedAt-age>`, which on a fork (where push activity is
#      deliberately unread) is the only activity evidence there is; `title` feeds the updater
#      branch/title predicate, and editing a title changes no SHA. Aging or classifying from the
#      org-search snapshot therefore stays wrong for as long as the survey runs, while every
#      head-derived field looks correctly refreshed.
deepen_read=$(grep -F 'gh pr view <n> --repo devantler-tech/<repo> --json number,state' "${surveyor}" || true)
if [ -z "${deepen_read}" ]; then
  fail "the deepened per-PR read was not found, so the field-list assertions would be vacuous"
fi
for _field in updatedAt title; do
  case "${deepen_read}" in
    *",${_field},"*) ;;
    *) fail "the deepened per-PR read omits ${_field}, so a value that changes without the head SHA is consumed from the stale org-search snapshot" ;;
  esac
done
case "${surveyor_flat}" in
  *'SUPERSEDES the org-search value'*) ;;
  *) fail "the surveyor does not state that deepened fields supersede the org-search snapshot" ;;
esac

# (7) A same-repository branch outside the three agent namespaces (`deps/agent-skills-update`, a
#     release branch) had NO legal <lane> value, though those PRs are inside the takeover test.
case "${surveyor_flat}" in
  *'`base` for any other same-repository branch'*) ;;
  *) fail "the surveyor defines no lane token for a same-repo branch outside the agent namespaces, so a trusted-bot push cannot be reported" ;;
esac

# (8) `merge-group:` was unreachable: the queue's checks run on a synthetic ref, so neither
#     statusCheckRollup nor autoMergeRequest can supply it, and no query was prescribed.
case "${surveyor_flat}" in
  *'mergeQueue(branch:"main")'*) ;;
  *) fail "the surveyor promises a merge-group signal but prescribes no query that can produce it" ;;
esac
case "${surveyor_flat}" in
  *'`autoMergeRequest` stays **`null` while queued**'*) ;;
  *) fail "the surveyor does not record why autoMergeRequest cannot stand in for the merge-queue read" ;;
esac

# (9) Truncated discovery must not claim a fire nobody observed. `false` asserts live breakage, which
#     pins the ladder at rung 0 on every survey while the portfolio sits above the cap; and truncated
#     ISSUE discovery is lower-rung work that must not touch the health field at all.
case "${surveyor_flat}" in
  *'`DISCOVERY-TRUNCATED (prs, 300 cap)` and set `nothing_on_fire: unknown`'*) ;;
  *) fail "truncated PR discovery still claims an observed fire instead of an unassessed portfolio" ;;
esac
case "${surveyor_flat}" in
  *'Truncated ISSUE discovery is reported SEPARATELY and never touches `nothing_on_fire` at all'*) ;;
  *) fail "truncated issue discovery still feeds the health field, mislabelling a backlog gap as breakage" ;;
esac

# (10) The fork-activity read is an authenticated GET against a repository OUTSIDE the portfolio,
#      which this agent's own Portfolio-only rule and the constitutional boundary both forbid even
#      read-only. The signal is not worth the breach, and it does not have to be: `pushed:unknown`
#      is defined as EXPIRING, so a fork degrades to a weaker self-clearing value rather than either
#      an unauthorized read or a permanent park.
case "${surveyor_flat}" in
  *'NEVER a fork'*) ;;
  *) fail "the surveyor may still read a fork's activity, breaching the portfolio boundary" ;;
esac
case "${surveyor_flat}" in
  *'compare the owner to `devantler-tech`, and read activity'*) ;;
  *) fail "the surveyor does not gate the activity read on the head repo being in-scope" ;;
esac

echo "portfolio surveyor contract: promised-but-unemittable signal assertions passed"

# ── Codex's round on the same signals: three ways a takeover decision can still be wrong ──────────
# (5) The flat-endpoint read must KEEP THE BODY. Login+timestamp cannot separate the maintainer from
#     an agent instance — they share the `devantler` login — and this signal is defined as the newest
#     HUMAN comment, so without a body there is no disclosure marker to apply and an agent's own
#     inline reply parks the PR against a signal the routine produced itself.
case "${surveyor_flat}" in
  *'\(.user.login)\t\(.created_at)\t\(.body)'*) ;;
  *) fail "the flat comment read discards the body, so the disclosure test cannot be applied" ;;
esac

# (6) A lane is NOT one writer: the Agent Improver shares each machine-local namespace, so discounting
#     a push on lane + creation record alone discards a live SIBLING push and licenses writing over
#     work in progress.
case "${surveyor_flat}" in
  *'match it against the pushes you made this run'*) ;;
  *) fail "the own-push discount keys on the lane rather than on what this run actually pushed" ;;
esac
case "${constitution_flat}" in
  *'Lane membership is not enough, because a lane is not one writer'*) ;;
  *) fail "AGENTS.md lets lane membership alone discount a push, discarding sibling activity" ;;
esac

# (7) `--match-head-commit` pins the ARMING, not the later auto-merge, so the widest exposure window
#     is unprotected. The contract previously claimed the pin closed it; that claim was withdrawn.
case "${constitution_flat}" in
  *'the thing being allowed is the **arming**, not the later merge'*) ;;
  *) fail "AGENTS.md does not state that --match-head-commit fails to cover the auto-merge window" ;;
esac
case "${constitution_flat}" in
  *'the arming is never the completion'*) ;;
  *) fail "AGENTS.md does not require confirming what actually landed after arming auto-merge" ;;
esac

echo "portfolio surveyor contract: takeover-signal round-2 assertions passed"

# (8) The post-arm confirmation must compare `headRefOid`, never `mergeCommit`. `mergeCommit` names the
#     commit created ON THE BASE, a different object from the head that merged under EVERY strategy —
#     a squash condenses the branch into a new commit, a merge commit is new by definition, a rebase
#     rewrites what it replays, and the merge-queue path deliberately drops `--squash` and lets the
#     queue choose — measured on this repo's own #2795, head `789ac1145e…` -> merge `9c7a132930…`.
#     Keying the check on it would fire on every valid merge, and a guard that always fires is one
#     people learn to ignore.
case "${constitution_flat}" in
  *'compare **`headRefOid`** to'*) ;;
  *) fail "the post-arm confirmation does not compare headRefOid" ;;
esac
case "${constitution_flat}" in
  *'Compare `headRefOid`, NOT `mergeCommit`'*) ;;
  *) fail "the contract does not warn that mergeCommit is not a source-head identity field" ;;
esac

# (9) …and it must WAIT for `state: MERGED`. Read straight after arming — the natural next step —
#     the PR is still OPEN carrying the head just evaluated, so the SHAs match and the check reports
#     success at the one moment it cannot have observed the merge. That is worse than no check: it
#     manufactures a passing record for precisely the window the guard covers. The merge can also
#     land after the run ends, and a merged PR leaves the open-PR enumeration, so an unconfirmed
#     arming is never revisited unless it is carried forward explicitly.
case "${constitution_flat}" in
  *'The comparison counts ONLY once `state` reads `MERGED`'*) ;;
  *) fail "the post-arm confirmation can be satisfied by a read taken while the PR is still OPEN" ;;
esac
case "${constitution_flat}" in
  *'no longer contains it'*) ;;
  *) fail "the contract does not require carrying an unconfirmed arming forward past the open-PR enumeration" ;;
esac

# (10) `app/botantler-1` is NEVER `--auto`-eligible — not on any classifier result, exit 0 included.
#      Its permission comes from what the classifier returned for a SPECIFIC COMMIT, and `--auto`
#      carries no condition forward: it defers the merge and re-evaluates nothing, so an updater push
#      during that window lands a head the classifier never ran on, possibly one that needs the very
#      review the exit-0 path waives. The head pin does not help: it gates the arming, not the later
#      merge, so the post-arm check only detects the breach after it reaches `main`. The three
#      eligible authors are eligible by AUTHOR, which a later head cannot change — which is exactly
#      why this one merges directly at the head it was evaluated on instead.
#
#      Assert the EXCLUSION, not a phrasing of the direct-merge outcome. The predecessor of this
#      assertion pinned "merges DIRECTLY … never with `--auto`" while the contract's own author
#      matrix, two sentences earlier, still listed the updater among four `--auto`-eligible authors —
#      so the contract contradicted itself and this guard stayed green over it, and the deployed
#      overlay went on authorising the arming. The exclusion is the property; the merge command is
#      its consequence and is pinned separately below.
case "${constitution_flat}" in
  *'is NEVER `--auto`-eligible — not even on exit 0'*) ;;
  *) fail "a conditional classifier exemption may still be armed with --auto and inherited by an unevaluated head" ;;
esac
case "${constitution_flat}" in
  *'re-run the classifier at the current head'*) ;;
  *) fail "the contract does not require re-running the classifier at the head it actually merges" ;;
esac
# The reason must be stated for ANY strategy, not just squash. An earlier version said "every merge
# here is a squash", which contradicts the merge-queue section below it — that path deliberately drops
# `--squash` because the queue picks the strategy — and would have left the check looking optional
# wherever the claim visibly did not hold.
case "${constitution_flat}" in
  *'not a source-head identity field under ANY merge strategy'*) ;;
  *) fail "the mergeCommit warning is scoped to one merge strategy, so it does not cover merge-queue repos" ;;
esac
case "${constitution_flat}" in
  *'`--squash` is deliberately dropped because the queue chooses the strategy'*) ;;
  *) fail "the contract does not reconcile the mergeCommit rule with the merge-queue path" ;;
esac

echo "portfolio surveyor contract: post-arm confirmation assertions passed"

# A consumer requirement with no producer is not a requirement. Both assertions below pin the
# SURVEYOR side of a rule the maintenance skill and the constitution already state, because that is
# the half a prose edit silently drops: the consumer reads a field the digest never emits, or
# promises a blocker over a discovery pass that cannot see it.

# An EVICTED PR is the opposite of an owned one — nothing holds it and repairing it is the run's job —
# so the completed merge_group conclusion cannot ride on `active=`, which means "leave it alone".
# The queue's checks run on a synthetic ref, so no head-level rollup can substitute.
case "${surveyor_flat}" in
  *'merge_group_result=<conclusion>@<runId>@<runCreatedAt>'*) ;;
  *) fail "the surveyor emits no completed merge_group result, so an eviction is invisible to the consumer that requires it" ;;
esac
case "${surveyor_flat}" in
  *'emitted whether or not the PR is currently queued'*) ;;
  *) fail "the completed merge_group result is not required independently of the ownership signal" ;;
esac
grep -Fq 'merge_group_result=' "${surveyor}" ||
  fail "the digest row grammar carries no merge_group_result field for the consumer to read"

# The persistent maintainer-blocker promise covers every PR the orchestrator drives, so scoping the
# discovery pass to `devantler`-authored PRs leaves it unenforceable on bot and external PRs: after
# the generic ~2h activity signal lapses, a live `do not merge` disappears from the digest entirely.
case "${surveyor_flat}" in
  *'The open-PR half is author-agnostic'*) ;;
  *) fail "maintainer-comment discovery is still author-scoped, so a blocker on a bot or external PR is never surfaced" ;;
esac
case "${surveyor_flat}" in
  *'every actionable open PR already enumerated for the pentad'*) ;;
  *) fail "the widened maintainer-comment sweep does not reuse the enumerated pentad set" ;;
esac

echo "portfolio surveyor contract: producer-for-every-consumer assertions passed"

# One field, one spelling. The producer prose, the consumer skill and every digest row must name the
# completed merge_group result identically, or the surveyor cannot satisfy both and a consumer
# following the other spelling reads nothing where an eviction was reported.
grep -Fq 'merge-group-result' "${surveyor}" &&
  fail "the surveyor still carries a second spelling of the merge_group result field"
grep -Fq 'merge-group-result' "${maintenance_skill}" &&
  fail "the maintenance skill still carries a second spelling of the merge_group result field"

# The external/Copilot row is swept and merged like any other, so it needs the two signals that
# persist past the generic ~2h activity window: an eviction (invisible in the head pentad, since the
# queue runs on a synthetic ref) and a human CHANGES_REQUESTED (not a candidate-maintainer-comment
# surface). Omitting either lets the row read ready over a live block.
external_row="$(grep -F 'EXTERNAL/Copilot — NEVER-RUN-LOCALLY' "${surveyor}" || true)"
[ -n "${external_row}" ] || fail "the external/Copilot digest row is missing entirely"
case "${external_row}" in
  *'merge_group_result=<<conclusion>@<runId>@<runCreatedAt>|stale@<runId>|none>'*) ;;
  *) fail "the external/Copilot row omits merge_group_result, so an eviction there is invisible" ;;
esac
case "${external_row}" in
  *'rd=<APPROVED|CHANGES_REQUESTED:'*) ;;
  *) fail "the external/Copilot row omits rd=, so a human CHANGES_REQUESTED is lost once the activity window expires" ;;
esac

# A merge queue changes the strategy, never the closed three-author `--auto` list.
case "${constitution_flat}" in
  *'A merge queue does NOT widen who may use `--auto`'*) ;;
  *) fail "the merge-queue path can still push a non-App author through auto-merge" ;;
esac

# The surveyor must not re-promise the updater auto-merge eligibility the contract withdrew.
case "${surveyor_flat}" in
  *'`app/botantler-1` is never `--auto` eligible'*) ;;
  *) fail "the surveyor does not record that the exit-0 updater exemption excludes auto-merge" ;;
esac

echo "portfolio surveyor contract: round-8 field-consistency assertions passed"

# A merge_group run is correlated by `pr-<n>`, which survives every push — so without binding the
# result to WHEN it ran, the newest completed run keeps reporting an eviction the PR has already
# answered, and the consumer re-diagnoses or blocks a ready PR on every run.
case "${surveyor_flat}" in
  *'Bind the result to WHEN it ran'*) ;;
  *) fail "the merge_group result is not bound in time, so a repaired eviction blocks forever" ;;
esac

# ...and the reason it is bound in TIME rather than by head: a merge_group run's `headSha` is the
# synthetic queue commit, never the contributing PR's head (measured on platform#3035 — run
# head_sha 977218004e, queue branch pr-3035-56536122b2, PR headRefOid c8d669236f: three distinct
# objects). A `headSha == headRefOid` test therefore reports EVERY completed run as stale, hiding
# the queue failures this field exists to surface and re-permitting the blind re-queue.
case "${surveyor_flat}" in
  *'is NOT the contributing PR'*'head'*) ;;
  *) fail "the surveyor does not record that merge_group headSha is the synthetic queue commit, so the stale test can be rebuilt on it" ;;
esac

# A top-level COMMENTED review body is neither an issue comment nor an inline comment, so the two
# prescribed reads miss a maintainer `do not merge` entirely; it then carries only the expiring
# activity signal and no rd=CHANGES_REQUESTED, and the PR merges over a live instruction.
case "${surveyor_flat}" in
  *'THREE surfaces, not two'*) ;;
  *) fail "maintainer review BODIES are still unswept, so a persistent requirement there expires silently" ;;
esac

# behaviour_observed gates an external PR's merge, and the deepening read cannot tell whether a green
# check exercised the change — so a guess is either an unobserved merge or a parked contribution.
case "${surveyor_flat}" in
  *'Name the EVIDENCE, or emit `unknown`'*) ;;
  *) fail "behaviour_observed can still be guessed from data that cannot support the classification" ;;
esac

# A title edit changes no commit, so the head pin cannot catch it — and the squash subject is the title.
case "${constitution_flat}" in
  *'`title` is in that list because the head pin does NOT cover it'*) ;;
  *) fail "the merge preflight does not re-validate the title, so a late edit can corrupt the changelog" ;;
esac

echo "portfolio surveyor contract: round-9 evidence-and-staleness assertions passed"
