#!/usr/bin/env bash
#
# Guards the Egress allow-list against re-acquiring the term collision that made it gate portfolio
# repositories as if they were third-party.
#
# Why this needs a guard. AGENTS.md uses "upstream" in two unrelated senses. *Definition routing*
# calls `agent-plugins` "the file's canonical upstream" — a repository that is ALSO in the Portfolio
# map. *Egress* used to gate "an upstream issue/PR only once both its gates are cleared". An agent
# routing a definition fix upstream therefore met one allow-list entry permitting it (`devantler-tech`
# GitHub artifacts) and one appearing to forbid it, inside a section whose own rule resolves ambiguity
# in the closed direction ("until it is listed it is not an egress destination and you do not send to
# it"). Standing down was the literally compliant reading, and an Improver lane did exactly that on two
# consecutive dispatches, dropping a prepared SECURITY fix each time. The canonical section this entry
# points at never agreed: *GitHub artifact conventions* says "Third-party upstream repos" and
# "`devantler-tech` repos are exempt". The Egress entry had dropped both qualifiers.
#
# This is a DISAMBIGUATION, never a loosening. The third-party gate is unchanged and assertion 3
# proves it: a non-`devantler-tech` artifact still needs the professional-work boundary AND the
# per-artifact approval. What changes is only that the gate stops firing on repositories the very
# same allow-list already permits one entry earlier.
#
# Assertion 4 pins the two sections' vocabulary together, because drifting apart is the defect class
# itself — the canonical section was always right and the pointer-site copy silently was not.
#
# Three hardenings came from review (Codex, 2026-08-25) and each closed a real hole:
#   * assertions 3 searched the section for the two gate phrases INDEPENDENTLY, so an edit reading
#     "per-artifact approval is no longer required" left both substrings present and the guard green
#     while the invariant was gone. It now matches the affirmative clause that GRANTS the destination.
#     Proven differentially: with that clause negated, the previous revision of this test PASSES and
#     this one fails.
#   * assertion 4 exists because the first draft of the prose exempted "the skills repositories" —
#     but a synced skill's upstream is frequently third party (`find-skills` is `vercel-labs/skills`),
#     so that phrasing would have exempted a third-party owner from the very gate this entry imposes.
#   * the conventions extraction anchored on prose owned by the PRECEDING bullet, so rewording an
#     unrelated PR-body sentence would have reddened a required check on every AGENTS.md edit.
#
# Assertions are scoped to their section, not the whole file: asserting against the whole
# constitution is a scope hole, because an unrelated passage carrying the phrase would satisfy the
# check while the real passage stayed wrong.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
constitution="${repo_root}/AGENTS.md"
passed=0

fail() {
  echo "egress-third-party-qualifier contract: FAIL — $*" >&2
  exit 1
}
ok() { passed=$((passed + 1)); }

[ -r "${constitution}" ] || fail "cannot read ${constitution}"

# Extract ONLY the named section, then flatten it: sentences wrap across source lines, so a fragment
# spanning a line break would never match and the test would be always-red regardless of content.
# A sentinel proves the END anchor was actually seen, so a missing anchor is detected DIRECTLY
# rather than inferred from how much text got captured.
extract() {
  local start="$1" end="$2" sentinel='@@END-ANCHOR-SEEN@@' out
  out="$(
    awk -v s="${sentinel}" -v a="${start}" -v b="${end}" '
      index($0, a) { ins = 1 }
      ins && index($0, b) && !index($0, a) { ins = 0; print s }
      ins { print }
    ' "${constitution}"
  )"
  case "${out}" in
    *'@@END-ANCHOR-SEEN@@'*) ;;
    *) fail "section anchors not both found: '${start}' .. '${end}'" ;;
  esac
  printf '%s' "${out}" | tr '\n' ' ' | tr -s ' '
}

egress="$(extract '### Egress' '### Sensitive information stays private')"
# Anchored on STRUCTURAL SECTION HEADINGS at both ends, never on a neighbouring bullet's prose. The CI
# filter runs this test on every AGENTS.md edit, so an anchor on any bullet's wording turns an
# unrelated reword into a required-check failure — measured for both the start and the end anchor.
conventions="$(extract '### GitHub artifact conventions' '### Cadence & focus')"

# Assertions 1 and 3 match CONTIGUOUS literals with grep -qF, never a `case` glob. A glob written as
# *'third-party'*'upstream issue/PR'* permits arbitrary text between the fragments, which is fail-open
# twice over — both mutations below were demonstrated to PASS an earlier revision of this test:
#   * moving `third-party` into an unrelated earlier entry ("read-only third-party public web
#     research") while reverting the gated entry to a bare `upstream issue/PR` — the exact collision
#     this guard exists to prevent, reintroduced with the guard still green;
#   * rewriting the clause to `professional-work boundary; per-artifact approval is no longer
#     required` — both phrases still present, gate removed, guard still green.
# `case` is also the wrong primitive here regardless: these literals contain `*`, which a case pattern
# would interpret as a wildcard rather than matching.
# A step can satisfy every connectivity assertion and still not be able to fail. Three constructs do
# it, each found separately by review: `continue-on-error` (step reports success), a step-level `if:`
# (command never runs), and a `shell:` override such as `bash {0} || true` (command runs, failure
# swallowed). Any step this guard depends on must be free of all three, so the check is factored here
# rather than repeated — the previous rounds fixed one step at a time and the next step stayed open.
step_can_fail() { # step_can_fail <step-text> <description>
  local step="$1" what="$2"
  grep -qE '^        continue-on-error:' <<< "${step}" && \
    fail "the ${what} declares continue-on-error — it would report success whatever its command returns, so the guard would not gate"
  grep -qE '^        if:' <<< "${step}" && \
    fail "the ${what} carries a step-level 'if:' — it could be skipped while the job and the required aggregate stay green"
  grep -qE '^        shell:' <<< "${step}" && \
    fail "the ${what} overrides 'shell:' — a wrapper such as 'bash {0} || true' converts its failure to success, so the guard would not gate"
  return 0
}
has() { grep -qF -- "$1" <<< "${2}"; }

# 1. The qualifier must be bound to the gated entry ITSELF, contiguously.
has '**third-party upstream issue/PR only once' "${egress}" || \
  fail "the gated entry is not contiguously qualified as third-party (a 'third-party' elsewhere in the section does not count)"
ok

# 2. The section must resolve the overlap explicitly, or a later reader re-derives the same doubt from
#    *Definition routing* and stands down again.
has '**A `devantler-tech` repository is never that case**' "${egress}" || \
  fail "the Egress allow-list does not contiguously state that a devantler-tech repository is never the gated case"
ok

# 3. The POSITIVE destination must exist. Everything else here pins that a `devantler-tech` repo is
#    not the GATED case — but "not third-party" adds no destination of its own, and this section fails
#    closed. Delete the affirmative entry and every suite-owned issue, PR, comment, review and push
#    becomes un-sendable: the exact operational failure this guard exists to prevent, arrived at from
#    the opposite direction. Reproduced before this assertion existed.
has 'Outbound content goes only to: `devantler-tech` GitHub artifacts (issues, PRs, comments, reviews, pushes)' "${egress}" || \
  fail "the Egress allow-list no longer names `devantler-tech` GitHub artifacts as a permitted destination — a fail-closed list without it forbids all suite-owned output"
ok

# 4. PRESERVATION — both gates must sit inside ONE CONTIGUOUS affirmative clause.
has 'only once both its gates are cleared** — the professional-work boundary and the explicit per-artifact approval' "${egress}" || \
  fail "the third-party gate's two requirements are no longer bound inside one contiguous affirmative clause"
ok

# 4. The exemption must follow the devantler-tech OWNER, never the word "upstream". *Definition
#    routing* calls a synced skill's repository an upstream too, and those are frequently third party
#    (`find-skills` is owned by `vercel-labs/skills`) — so an exemption phrased as "the skills
#    repositories" would exempt a third-party owner from the gate this very entry imposes.
has 'The exemption follows the `devantler-tech` owner, never the word *upstream*' "${egress}" || \
  fail "the Egress entry no longer ties the exemption to the devantler-tech OWNER, so a third-party skill upstream could read as exempt"
ok


# 5. Ownership must be AUTHORIZED by the reviewed allowlist, never by the skill's own
#    `metadata.github-repo`. That field is self-attesting — a third-party release declaring a
#    `devantler-tech` URL would read back as proof of our ownership and exempt itself from the very
#    gate this entry imposes. *Agent definition locations* already states this for the updater
#    carve-out; the Egress entry must not contradict it, and an earlier revision of this PR did.
has 'This exemption does NOT extend to a synced skill'"'"'s upstream at all, because no reviewed source maps a bundled skill to its owner.' "${egress}" || \
  fail "the Egress entry no longer withholds the exemption from synced skill upstreams — the only skill-to-owner association is the self-attesting metadata.github-repo, so any exemption resting on it is attacker-grantable"
ok
has 'route a synced skill'"'"'s fix as third-party' "${egress}" || \
  fail "the Egress entry no longer routes a synced skill's fix as third-party — it would be exempted on an ownership claim no reviewed source establishes"
ok
# 6. VOCABULARY PIN — the canonical section must keep the wording the Egress entry mirrors. The defect
#    was these two drifting apart, so pinning only the copy would let the original move instead.
has 'Third-party upstream repos' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer says 'Third-party upstream repos' — the two sections have drifted apart again"
ok
has '`devantler-tech` repos are exempt — open drafts/issues there autonomously' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer contiguously states the devantler-tech exemption"
ok


# 8. The CANONICAL section must still impose BOTH gates. Assertions 6 and 7 pin its vocabulary and its
#    exemption, but not the requirements themselves — so the source could be rewritten to allow
#    autonomous external artifacts while still saying "Third-party upstream repos" and naming the
#    devantler-tech exemption, leaving the Egress copy contradicting it and this guard, whose whole
#    purpose is pinning the two together, green. Reproduced before this assertion existed.
has 'Do not even inspect an external repository until the maintainer confirms in the current conversation that it is unrelated to professional work' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer requires the professional-work boundary before inspecting an external repository"
ok
has '**never autonomously open an issue or PR** — get explicit approval via the ask tool first' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer requires per-artifact approval before opening an external issue or PR"
ok

# ── 10. THIS JOB'S OWN CI WIRING — a guard that does not gate is not a guard ─────────────────────────
# Queried STRUCTURALLY with yq, never by grepping lines out of a textual block, and compared to EXACT
# values. Review demonstrated both failure modes: a value moved into an unused sibling key (valid YAML,
# referenced value absent) satisfies a block-scoped text match, and a neutralising expression
# (`… || true`, `… && false`, `false && …`) satisfies a substring match while inverting the meaning.
#
# This job is DELIBERATELY UNCONDITIONAL — no `needs:`, no `if:`, no paths-filter entry. A wiring
# validator gated on the very chain it validates cannot report its own disconnection: removing the
# filter or its exported output skips the job, and the aggregate accepts a skipped path-filtered job,
# so the required check stays green precisely when the wiring broke. Running always costs one fast
# bash job per PR and removes that whole class.
workflow="${repo_root}/.github/workflows/ci.yaml"
# FAIL, never skip: a renamed or unreadable workflow would otherwise bypass every assertion below and
# still print OK — the vacuous-success mode this guard exists to prevent, one level up.
[ -r "${workflow}" ] || \
  fail "ci.yaml is missing or unreadable at ${workflow} — this job's own wiring cannot be verified, so an OK here would be vacuous"
command -v yq >/dev/null 2>&1 || \
  fail "yq is unavailable, so this job's wiring cannot be verified structurally and an OK here would be vacuous"
yq '.' "${workflow}" >/dev/null 2>&1 || \
  fail "ci.yaml does not parse as YAML — its wiring cannot be verified"

JOB='test-egress-third-party-qualifier-contract'
# Named wf_q, not q: a real `q` binary exists on PATH here, so a helper named q that is called before
# its definition silently runs an unrelated CLI — and the failures surface as "command not found" for
# `fail`, which does not abort, so the test still prints PASS. Encountered exactly that while editing.
wf_q() { yq -r "$1" "${workflow}" 2>/dev/null; }
present() { [ -n "$1" ] && [ "$1" != "null" ]; }

# (a) the job must exist and be UNCONDITIONAL — any `if:` or `needs:` reintroduces a skip path, and a
#     skipped path-filtered job is accepted by the aggregate.
present "$(wf_q ".jobs.\"${JOB}\"")" || \
  fail "ci.yaml has no ${JOB} job — the contract is not checked at all"
# `present` cannot distinguish an absent key from the literal strings "null" or "" — and GitHub
# evaluates `if: "null"` and `if: ""` as FALSY, skipping the job. Test key EXISTENCE structurally.
# The job must carry ONLY the keys it needs. A blocklist kept losing here too: `if`/`needs` (a skip
# path), `continue-on-error` (the run passes though the job failed), `defaults.run.shell` and `env`
# (redirect what executes), and `container:` — whose image can supply a `bash` that simply returns
# success while every step and the exact `run:` text stay unchanged. `services`, `strategy` and
# `uses` would have followed. Enumerate what is permitted.
job_extra="$(wf_q ".jobs.\"${JOB}\" | keys | .[] | select(. != \"name\" and . != \"runs-on\" and . != \"permissions\" and . != \"steps\")")"
[ -z "${job_extra}" ] || \
  fail "the ${JOB} job sets $(printf '%s' "${job_extra}" | tr '\n' ' ')— only name, runs-on, permissions and steps are permitted, because keys such as if:, needs:, container:, env: and continue-on-error: change whether the guard runs, what it runs in, or whether its failure counts"

# (b) it must run EXACTLY the contract script: a wrapper such as `… || true` converts every failure to
#     success while still containing the filename.
# Materialise before matching: `q … | grep -q` under pipefail reports failure when grep exits
# on a match and SIGPIPEs yq, so a present value reads as absent.
run_cmds="$(wf_q ".jobs.\"${JOB}\".steps[] | select(.run != null) | .run")"
grep -Fqx -- 'bash .claude/scripts/egress-third-party-qualifier-contract.test.sh' <<< "${run_cmds}" || \
  fail "no step in the ${JOB} job runs exactly 'bash .claude/scripts/egress-third-party-qualifier-contract.test.sh' — a wrapper such as '… || true' converts every contract failure to success"

# (b2) the job must check out THIS PR's head, not a fixed ref. With `ref: main` on the checkout, a PR
# weakening AGENTS.md, this script, or the workflow would validate the unchanged default branch and
# the required aggregate would stay green. The default (no ref) is the PR merge ref, which is correct.
[ "$(wf_q "[.jobs.\"${JOB}\".steps[] | select(.uses != null and (.uses | test(\"^actions/checkout@\")))] | length")" = "1" ] || \
  fail "the ${JOB} job does not have exactly one actions/checkout step — what the contract script reads cannot be established"
[ "$(wf_q "[.jobs.\"${JOB}\".steps[] | select(.uses != null and (.uses | test(\"^actions/checkout@\"))) | select(.with != null and (.with | has(\"ref\")))] | length")" = "0" ] || \
  fail "the ${JOB} job's checkout pins a ref — it would validate that ref instead of this pull request's head, so a PR weakening the contract would pass against the unchanged default branch"
# `ref:` is not the only redirect: `repository:` replaces the workspace with another repo's default
# branch, so the exact command would run an attacker-supplied no-op. Allow ONLY the key this step
# legitimately needs, rather than blocklisting the redirects we happened to think of.
bad_with="$(wf_q ".jobs.\"${JOB}\".steps[] | select(.uses != null and (.uses | test(\"^actions/checkout@\"))) | .with | keys | .[] | select(. != \"persist-credentials\")")"
[ -z "${bad_with}" ] || \
  fail "the ${JOB} job's checkout sets $(printf '%s' "${bad_with}" | tr '\n' ' ')— only persist-credentials is permitted, because keys such as repository: or ref: redirect what the contract script reads"
# Both validated actions must be pinned to an immutable full commit SHA. `actions/checkout@main`
# satisfies a repository-prefix test while the action's contents can change after review — which
# could alter what is checked out or whether a failure gates the merge. This mirrors the repository's
# own action-pinning requirement.
for spec in \
  "checkout|.jobs.\"${JOB}\".steps[] | select(.uses != null and (.uses | test(\"^actions/checkout@\"))) | .uses" \
  "aggregate action|.jobs.status.steps[] | select(.uses != null and (.uses | test(\"^devantler-tech/actions/aggregate-job-checks@\"))) | .uses"; do
  what="${spec%%|*}"; path="${spec#*|}"
  ref="$(wf_q "${path}")"
  case "${ref##*@}" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "the ${what} is pinned to '${ref##*@}', not a full commit SHA — a mutable ref can change after review, altering what is checked out or whether a failure gates the merge" ;;
  esac
done


# NO environment may be injected into this job's execution path, at any scope. Individual variables
# were arriving one review round at a time — `BASH_ENV` (bash sources it before the `run:` command, so
# a checked-in `exit 0` passes having checked nothing) and then `PATH` (prepend a directory holding a
# checked-in `bash` and the exact command invokes that no-op instead) — and `SHELLOPTS`, `IFS` and
# `GIT_*` would have followed. None is visible to the shell:/if:/continue-on-error checks, because the
# command still matches exactly. All three scopes carry no `env` today, so require exactly that rather
# than blocklisting the variables we happen to have thought of.
for scope in '.env' ".jobs.\"${JOB}\".env" ".jobs.\"${JOB}\".steps[].env"; do
  [ "$(wf_q "[${scope} | select(. != null)] | length")" = "0" ] || \
    fail "an env is set at ${scope} — variables such as BASH_ENV or PATH redirect what the verification command actually executes while the command itself still matches, so the guard would not gate"
done


# (b3) no INHERITED shell override, and no injected step. A workflow- or job-level
# `defaults.run.shell` of `bash {0} || true` applies to the verification step without any step-level
# `shell:`, and a step inserted after Checkout can overwrite the script so the exact command runs a
# replacement that checks nothing. Both leave every other assertion satisfied.
for path in ".defaults.run.shell" ".jobs.\"${JOB}\".defaults.run.shell"; do
  [ "$(wf_q "[${path}] | map(select(. != null)) | length")" = "0" ] || \
    fail "a defaults.run.shell is set at ${path} — it is inherited by the verification step and a template such as 'bash {0} || true' converts every contract failure to success"
done
[ "$(wf_q ".jobs.\"${JOB}\".steps | length")" = "2" ] || \
  fail "the ${JOB} job does not have exactly two steps (checkout, verify) — an injected step can overwrite the script so the exact command runs a replacement that checks nothing"

# (c) the aggregate must depend on this job, actually evaluate its dependencies, and receive this
#     job's result UNTRANSFORMED. `needs.<job>.result == 'failure' && 'success' || needs.<job>.result`
#     contains the reference while handing the action `success` whenever the contract fails.
status_needs="$(wf_q '.jobs.status.needs[]?')"
grep -Fqx -- "${JOB}" <<< "${status_needs}" || \
  fail "the status job does not list ${JOB} in needs: — its failures would not gate the merge"
status_if="$(wf_q '.jobs.status.if')"
[ "${status_if}" = "always()" ] || \
  fail "the status job is not 'if: always()' (got '${status_if}') — a skipped aggregate evaluates no failing dependency, so this job's entry in it would gate nothing"
agg_results="$(wf_q '.jobs.status.steps[] | select(.uses != null and (.uses | test("^devantler-tech/actions/aggregate-job-checks@"))) | .with."job-results"')"
present "${agg_results}" || \
  fail "the status job has no devantler-tech/actions/aggregate-job-checks step with a job-results input — nothing evaluates the dependency results"
# job-results is a FOLDED scalar — one line, space-separated — so match the exact token as a
# substring. The masking form `${{ needs.<job>.result == 'failure' && 'success' || … }}` does not
# contain it, because `result` is followed by ` ==` rather than ` }}`.
grep -qF -- "\${{ needs.${JOB}.result }}" <<< "${agg_results}" || \
  fail "the aggregate action's job-results does not receive exactly '\${{ needs.${JOB}.result }}' — a transformed entry can hand it 'success' while this contract fails"

# (d) neither this job nor the aggregate may be unable to fail — at JOB level or STEP level. Each of
#     these was found separately by review, and each satisfies every assertion above.
for j in "${JOB}" status; do
  [ "$(wf_q ".jobs.\"${j}\" | has(\"continue-on-error\")")" = "false" ] || \
    fail "the ${j} job sets continue-on-error at job level — the run passes even when the job fails, so the guard would not gate"
done
# The steps this guard depends on must carry ONLY the keys they legitimately need. A blocklist kept
# losing: `continue-on-error`, then a step-level `if:`, then `shell:`, then `working-directory:`
# (which makes the exact `run:` text execute a different file entirely). Each satisfies every other
# assertion, because the command still matches. Enumerate what is permitted instead.
check_step_keys() { # check_step_keys <yq-path> <description> <allowed-csv>
  local path="$1" what="$2" allowed="$3" extra
  [ "$(wf_q "[${path}] | length")" = "1" ] || \
    fail "expected exactly one ${what} in ci.yaml — its settings cannot be checked, so an OK here would be vacuous"
  extra="$(wf_q "${path} | keys | .[]" | grep -vxF -e "${allowed//,/$'\n'}" || true)"
  [ -z "${extra}" ] || \
    fail "the ${what} sets $(printf '%s' "${extra}" | tr '\n' ' ')— only ${allowed} are permitted, because keys such as working-directory:, shell:, env:, if: and continue-on-error: change what runs or whether its failure counts"
}
check_step_keys ".jobs.\"${JOB}\".steps[] | select(.run != null and (.run | test(\"egress-third-party-qualifier-contract.test.sh\")))" \
  "verification step" "name,run"
check_step_keys ".jobs.changes.steps[] | select(.id == \"filter\")" \
  "paths-filter producer step" "name,id,uses,with"
check_step_keys ".jobs.status.steps[] | select(.uses != null and (.uses | test(\"^devantler-tech/actions/aggregate-job-checks@\")))" \
  "status job's aggregate step" "name,uses,with"
ok
[ "${passed}" -eq 12 ] || fail "expected 12 assertions, ran ${passed}"
echo "egress-third-party-qualifier contract: PASS (${passed} assertions)"
