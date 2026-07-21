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
grep -Fq '`app/botantler-1` is narrowly trusted only for programmed agent-skills updater PRs' "${constitution}" ||
  fail "constitution either misses botantler updater PRs or trusts the App globally"
grep -Fq 'green_review=exempt-programmed-bot' "${surveyor}" ||
  fail "surveyor cannot report a programmed bot review exemption"
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '`botantler-1[bot]` is a candidate only for the programmed agent-skills updater classifier' "${surveyor}" ||
  fail "surveyor either misses botantler updater PRs or trusts the App outside the programmed path"
grep -Fq 'ksail-bot[bot]' "${surveyor}" ||
  fail "surveyor does not recognize the exact KSail App identity returned by search"
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
grep -Fq "The machine-local agents' **own** PRs" "${constitution}" ||
  fail "self-promotion rule still ambiguously includes the permission-limited Cursor cloud lane"
grep -Fq '`cursor[bot]` — **exact' "${surveyor}" ||
  fail "reference surveyor does not deepen PRs authored by the trusted Cursor Automation App"
grep -Fq 'siblings may build, run, review,' "${cursor_loader}" ||
  fail "Cursor loader still prevents trusted sibling instances from driving Cursor-authored PRs"
grep -Fq 'and drive your PRs' "${cursor_loader}" ||
  fail "Cursor loader does not authorize the sibling handoff through merge"
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
# Board coverage (#2326): a single unpaginated page counted 237 while totalCount was 4487.
# The digest must carry an explicit measured|unknown grammar, forbid emitting a count from one
# page, and prefer unknown under budget pressure — otherwise every survey re-improvises the metric
# and a truncated census looks complete.
# Literal Markdown code spans; command substitution is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq 'board_coverage=<measured:' "${surveyor}" ||
  fail "surveyor digest has no board_coverage measured|unknown grammar"
grep -Fq 'never emit a count from a single page' "${surveyor}" ||
  fail "surveyor may still emit a board-coverage count from a single-page read"
grep -Fq 'board_coverage=unknown' "${surveyor}" ||
  fail "surveyor has no unknown token for a truncated or budget-limited board census"
grep -Fq 'prefer `unknown` over a partial number' "${surveyor}" ||
  fail "surveyor does not prefer unknown over a partial board-coverage number under budget pressure"
grep -Fq 'automation-owned dependency PRs' "${maintenance_skill}" ||
  fail "portfolio-maintenance skill does not defer dependency PRs to automation"
grep -Fq 'agent-skills updater PRs' "${maintenance_skill}" ||
  fail "portfolio-maintenance skill still review-gates programmed agent-skills updater PRs"
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
grep -Fq 'never spend a review lane on them' "${agent_skills_card}" ||
  fail "agent-skills product card still requires review for programmed updater PRs"
grep -Fq 'classification succeeds' "${agent_skills_card}" ||
  fail "agent-skills product card can skip review without a successful classifier result"
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

expect_exempt \
  "agent-plugins programmed agent-skills update" \
  "agent-plugins" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${agent_plugins_skills_head}" \
  "${agent_plugins_skills_files}" \
  "${agent_plugins_skills_commits}"

expect_exempt \
  "Platform programmed agent-skills update" \
  "platform" \
  "app/botantler-1" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${platform_skills_head}" \
  "${platform_skills_files}" \
  "${platform_skills_commits}"

expect_exempt \
  "KSail programmed agent-skills update" \
  "ksail" \
  "app/ksail-bot" \
  "deps/agent-skills-update" \
  "chore(deps): update agent skills" \
  "${ksail_skills_head}" \
  "${ksail_skills_files}" \
  "${ksail_skills_commits}"

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

grep -Fq 'a GITHUB-MANAGED-SCAN (NO-ACTION) line never makes this false' "${surveyor}" ||
  fail "surveyor must state that a one-off GitHub-managed scan never sets nothing_on_fire: false (#2536)"

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
grep -Fq 'Red means `failure` OR `timed_out`' "${surveyor}" ||
  fail "surveyor's streak walk must treat timed_out as red, matching the red set (#2536)"

grep -Fq 'runs?branch=main&per_page=100' "${surveyor}" ||
  fail "surveyor's streak walk must filter to main, or a PR-triggered managed run pollutes it (#2536)"

# The exemption must key on the run PATH, not on `event: dynamic`, or it would exempt every future
# GitHub-managed run type — including actionable ones. `dynamic` stays a main-branch event.
grep -Fq 'never on `event: dynamic` alone' "${surveyor}" ||
  fail "surveyor must key the GitHub-managed exemption on the run path, not the dynamic event (#2536)"

grep -Fq '`workflow_dispatch`, `dynamic`' "${surveyor}" ||
  fail "surveyor must keep 'dynamic' in the main-branch event list — the exemption is by path (#2536)"

echo "portfolio surveyor contract: all assertions passed"
