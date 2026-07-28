#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
contract="${repo_root}/AGENTS.md"
agent="${repo_root}/.claude/agents/daily-maintainer.md"
run_loop="${repo_root}/.claude/skills/portfolio-maintenance/SKILL.md"
engineering="${repo_root}/.claude/skills/product-engineering/SKILL.md"
site_card="${repo_root}/.claude/skills/products/monorepo/SKILL.md"
site_readme="${repo_root}/docs/README.md"
workflow="${repo_root}/.github/workflows/ci.yaml"

fail() {
  echo "product value contract: FAIL — $*" >&2
  exit 1
}

grep -Fq 'Build the right thing — value before output' "${contract}" ||
  fail "canonical contract does not put user value before output"
grep -Fq 'evidence → audience/problem → hypothesis → success signal' "${contract}" ||
  fail "canonical contract is missing the evidence-to-outcome issue shape"
grep -Fq 'Marketing is a product problem' "${contract}" ||
  fail "canonical contract does not treat marketing as product work"
grep -Fq 'Blog posts are a maintained public product' "${contract}" ||
  fail "canonical contract does not treat the blog as a product"
grep -Fq 'professional, high-level, and outsider-first' "${contract}" ||
  fail "canonical blog quality bar is missing"
grep -Fq 'Stewardship includes **new posts and' "${contract}" ||
  fail "canonical blog stewardship omits new posts"
grep -Fq 'material refreshes** of useful older posts' "${contract}" ||
  fail "canonical blog stewardship omits old-post maintenance"
grep -Fq 'after operate work and one oldest-substantive slice' "${contract}" ||
  fail "canonical cadence can starve low-priority blog stewardship"
grep -Fq "Use \`Fixes #delivery\`; when later measurement" "${contract}" ||
  fail "canonical queue rules can close an experiment before measurement"
if grep -Fq 'problem → proposed direction → rough size' "${contract}"; then
  fail "canonical contract still permits evidence-free enhancement issues"
fi

for documentation_contract in "${contract}" "${engineering}"; do
  # Literal Markdown; backticks must not execute shell command substitution.
  # shellcheck disable=SC2016
  grep -Fq 'every ADR lives under **`docs/adr/`**' "${documentation_contract}" ||
    fail "${documentation_contract} does not make docs/adr the exclusive ADR location"
  grep -Fq 'DESCRIBE THE AS-IS, NEVER THE JOURNEY' "${documentation_contract}" ||
    fail "${documentation_contract} does not require present-state documentation"
  grep -Fq 'Historical records are exempt' "${documentation_contract}" ||
    fail "${documentation_contract} does not protect historical records from as-is rewrites"
  grep -Fq 'Operational migration and upgrade instructions are exempt' "${documentation_contract}" ||
    fail "${documentation_contract} can suppress required migration procedures"
done
case_variant_fixture="$(
  printf '%s\n' 'DOCS/ADR/0002-case-variant.md' |
    grep -Ei '(^|/)(adr|adrs)(/|$)' |
    grep -Ev '^docs/adr/' || true
)"
if [ "${case_variant_fixture}" != 'DOCS/ADR/0002-case-variant.md' ]; then
  fail "case-variant ADR paths are treated as canonical"
fi
if git -C "${repo_root}" ls-files |
  grep -Ei '(^|/)(adr|adrs)(/|$)' |
  grep -Ev '^docs/adr/'; then
  fail "tracked ADRs remain outside docs/adr"
fi

grep -Fq 'evidence-led' "${agent}" ||
  fail "daily maintainer summary does not route evidence-led selection"
grep -Fq 'Value & evidence loop' "${engineering}" ||
  fail "product engineering lacks the value-measurement procedure"
grep -Fq 'measure → learn → iterate, stop, or reverse' "${engineering}" ||
  fail "product engineering lacks an outcome feedback loop"
grep -Fq 'issue is the experiment record' "${engineering}" ||
  fail "blog outcomes have no durable per-post experiment record"
grep -Fq "delivery child closes with \`Fixes #N\`" "${engineering}" ||
  fail "delivery can close the experiment record before measurement"
grep -Fq 'named measurement date is a valid time gate' "${engineering}" ||
  fail "experiment issues can block the oldest queue before measurement is due"
grep -Fq 'last_value_review' "${run_loop}" ||
  fail "run loop does not persist the value-review cursor"
grep -Fq '**Value check before build.**' "${run_loop}" ||
  fail "run loop does not revalidate value before implementation"
grep -Fq 'last_blog_stewardship' "${run_loop}" ||
  fail "run loop does not persist the blog-stewardship cursor"
grep -Fq "use \`Fixes #delivery\`" "${run_loop}" ||
  fail "run loop can close an experiment before measurement"
# Spike floor (#2267): the primary run loop must not invent a delivery PR for a Spike.
# shellcheck disable=SC2016 # literal backticks in prose we pin
grep -Fq '`type:"Spike"` is not a delivery-PR path' "${run_loop}" ||
  fail "run loop still treats Spikes as delivery-PR work (#2267)"
grep -Fq 'do **not** invent a draft PR for it' "${run_loop}" ||
  fail "run loop lacks the Spike no-delivery-PR floor rule (#2267)"

grep -Fq 'Blog Stewardship' "${site_card}" ||
  fail "site card has no recurring blog task"
grep -Fq 'Blog Stewardship (low priority; monthly evidence review' "${site_card}" ||
  fail "site card does not preserve the low-priority monthly blog review"
grep -Fq 'publish/refresh every 4–8 weeks' "${site_card}" ||
  fail "site card does not preserve the worthwhile blog cadence"
grep -Fq "Do not advance \`last_metrics_review\`" "${site_card}" ||
  fail "missing metrics access can falsely satisfy the review cursor"
grep -Fq "\`last_blog_stewardship\` is the later of" "${site_card}" ||
  fail "review-only work can postpone the publication cadence"
grep -Fq 'publish/refresh dates** and never advances' "${site_card}" ||
  fail "review-only work can postpone the publication cadence"
grep -Fq 'start no new post while either is open' "${site_card}" ||
  fail "blog cadence has no single-flight guard"
for cursor in last_blog_review last_blog_publish last_blog_refresh last_metrics_review; do
  grep -Fq "${cursor}" "${site_card}" ||
    fail "site card is missing ${cursor}"
done
if grep -Fq '**Never modify blog posts.**' "${site_card}"; then
  fail "site card still bans blog maintenance globally"
fi

grep -Fq '## Blog editorial standard' "${site_readme}" ||
  fail "site contributor guide lacks the blog editorial standard"
grep -Fq 'Problem → Why it matters → What Devantler Tech built' "${site_readme}" ||
  fail "site contributor guide lacks the outsider-first story shape"
grep -Fq 'Problem → Why now → Current status' "${site_readme}" ||
  fail "site contributor guide omits honest current-initiative updates"
grep -Fq 'RSS inclusion, social/OG presentation' "${site_readme}" ||
  fail "site contributor guide omits distribution verification"

grep -Fq -- "- '.github/workflows/ci.yaml'" "${workflow}" ||
  fail "product value filter does not self-test workflow-only changes"
for adr_filter in "'**/[Aa][Dd][Rr]/**'" "'**/[Aa][Dd][Rr][Ss]/**'"; do
  grep -Fq -- "- ${adr_filter}" "${workflow}" ||
    fail "product value filter does not run for ${adr_filter} path changes"
done
grep -Fq '      - changes' "${workflow}" ||
  fail "required aggregate does not depend on path detection"
# Literal GitHub expression; shell expansion would make this assertion unsafe.
# shellcheck disable=SC2016
grep -Fq '${{ needs.changes.result }}' "${workflow}" ||
  fail "required aggregate does not evaluate path-detection failures"

# Egress mention neutralisation (#2312) — bots parse raw text; backticks do not inert a mention.
grep -Fq 'No Markdown construct hides a mention from a bot' "${contract}" ||
  fail "Egress does not state that Markdown cannot hide mentions from bots (#2312)"
grep -Fq 'break the token' "${contract}" ||
  fail "Egress does not require token-breaking to neutralise mentions (#2312)"
grep -Fq 'zero-width space after' "${contract}" ||
  fail "Egress lost the zero-width-space token-break example (#2312)"
if grep -Fq 'wrap the span in backticks' "${contract}"; then
  fail "Egress still offers backticks as mention neutralisation (#2312)"
fi

echo "product value contract: all assertions passed"
