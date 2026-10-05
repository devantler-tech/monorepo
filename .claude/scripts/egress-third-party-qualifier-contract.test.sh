#!/usr/bin/env bash
# shellcheck disable=SC2016
# Contract prose uses literal backticks, never shell substitutions.
#
# Guards the Egress allow-list and artifact conventions for bounded third-party contributions.
#
# Why this needs a guard. AGENTS.md uses "upstream" in two unrelated senses. *Definition routing*
# calls `agent-plugins` "the file's canonical upstream" — a repository that is ALSO in the Portfolio
# map. *Egress* used to gate "an upstream issue/PR only once both its gates are cleared". An agent
# routing a definition fix upstream therefore met one allow-list entry permitting it (`devantler-tech`
# GitHub artifacts) and one appearing to forbid it, inside a section whose own rule resolves ambiguity
# in the closed direction ("until it is listed it is not an egress destination and you do not send to
# it"). Standing down was the literally compliant reading, and an Improver lane did exactly that on two
# consecutive dispatches, dropping a prepared SECURITY fix each time. The canonical section then said
# "Third-party upstream repos" and "`devantler-tech` repos are exempt"; the Egress entry had dropped
# both qualifiers.
#
# The maintainer loosened the former per-artifact approval gate on 2026-10-05. The replacement is
# narrower than general external-write authority: a contribution needs a recorded portfolio need,
# no sufficient in-portfolio alternative, a cleared professional boundary, and compliance with the
# target project's AI policy. Projects that prohibit AI-assisted contributions receive no agent
# contribution, and omission of an unsolicited disclosure may never become a false denial.
#
# The assertions pin the two sections' vocabulary together, because drifting apart is the defect
# class itself.
#
# Three hardenings came from review (Codex, 2026-08-25) and each closed a real hole:
#   * the destination condition is matched as one contiguous affirmative clause, so a negation or an
#     unrelated earlier phrase cannot satisfy it;
#   * the owner assertion exists because the first draft exempted "the skills repositories" —
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
constitution="${repo_root}/.claude/guides/egress-and-privacy.md"
conventions_guide="${repo_root}/.claude/guides/github-artifacts.md"
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
# rather than inferred from how much text got captured. An empty END anchor means the section runs to
# the next `## ` heading, or to the end of the file for a guide's last section.
extract() {
  local start="$1" end="$2" file="${3:-${constitution}}" sentinel='@@END-ANCHOR-SEEN@@' out
  out="$(
    awk -v s="${sentinel}" -v a="${start}" -v b="${end}" '
      index($0, a) { ins = 1 }
      ins && b != "" && index($0, b) && !index($0, a) { ins = 0; print s }
      ins && b == "" && /^## / && !index($0, a) { ins = 0; print s }
      ins { print }
      END { if (ins && b == "") print s }
    ' "${file}"
  )"
  case "${out}" in
    *'@@END-ANCHOR-SEEN@@'*) ;;
    *) fail "section anchors not both found: '${start}' .. '${end}'" ;;
  esac
  printf '%s' "${out}" | tr '\n' ' ' | tr -s ' '
}

egress="$(extract '## Egress' '## Sensitive information stays private')"
# Anchored on STRUCTURAL SECTION HEADINGS at both ends, never on a neighbouring bullet's prose. The CI
# filter runs this test on every AGENTS.md edit, so an anchor on any bullet's wording turns an
# unrelated reword into a required-check failure — measured for both the start and the end anchor.
conventions="$(extract '## GitHub artifact conventions' '' "${conventions_guide}")"
research="$(extract '## Professional-work repository boundary' '## Egress')"
advance_research="$(extract '## Enhancement work' '## Security hardening' "${repo_root}/.claude/guides/advance-work.md")"
trust="$(extract '## Trust gate' '## Untrusted input' "${repo_root}/.claude/guides/trust-and-input.md")"
readiness="$(extract '## Autonomy' '' "${repo_root}/.claude/guides/pr-readiness.md")"
merge_delivery="$(extract '**Cross-repo delivery' '## Dependency-automation' "${repo_root}/.claude/guides/merge-policy.md")"
channels="$(extract '## Maintainer channels' '' "${repo_root}/.claude/guides/maintainer-channels.md")"
root_channels="$(extract '### Maintainer channels' '### Spend contract' "${repo_root}/AGENTS.md")"

# monorepo#3836: public inspection is permitted, but it cannot authorize execution,
# publication, private reads or employment access. Pin these at the permission site.
check_research() {
  local text="$1" phrase
  for phrase in \
    'Read-only investigation of public open-source repositories needed to operate or advance a portfolio product is permitted without per-repository read approval' \
    'The project must be known to be unrelated to the maintainer' \
    'Research does not authorize executing untrusted branch code, external writes or publication, or expanding the portfolio' \
    'Private or ambiguous external repositories require current, explicit confirmation before any inspection' \
    'Never discover, enumerate, search, inspect metadata/content/CI, clone, fetch, build, run, comment, review, push, open an issue/PR, merge, or otherwise interact with such repositories'; do
    has "${phrase}" "${text}" || fail "public research boundary missing: ${phrase}"
  done
}

# Policy assertions match CONTIGUOUS literals with grep -qF, never a `case` glob. A glob permits
# arbitrary text between fragments, so a negation or unrelated earlier phrase can leave the guard
# green while the invariant is gone.
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

# 1. The qualifier and replacement decision gate must be bound to the destination itself.
has '**third-party upstream contributions only when their necessity and the lack of a sufficient in-portfolio alternative are recorded' "${egress}" || \
  fail "the third-party destination is not bound to recorded necessity and the lack of a sufficient in-portfolio alternative"
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
  fail 'the Egress allow-list no longer names `devantler-tech` GitHub artifacts as a permitted destination — a fail-closed list without it forbids all suite-owned output'
ok

# 4. The replacement must remain affirmative and must not silently reintroduce the retired ask.
has 'No separate per-artifact approval is required once those conditions hold' "${egress}" || \
  fail "the Egress destination does not affirm that the bounded path works without a separate per-artifact approval"
ok

# 4. The exemption must follow the devantler-tech OWNER, never the word "upstream". *Definition
#    routing* calls a synced skill's repository an upstream too, and those are frequently third party
#    (`find-skills` is owned by `vercel-labs/skills`) — so an exemption phrased as "the skills
#    repositories" would exempt a third-party owner from the gate this very entry imposes.
has 'The exemption follows the `devantler-tech` owner, never the word *upstream*' "${egress}" || \
  fail "the Egress entry no longer ties the exemption to the devantler-tech OWNER, so a third-party skill upstream could read as exempt"
ok


# 5. Ownership must be AUTHORIZED by a reviewed mapping the upstream cannot write, never by the
#    skill's own `metadata.github-repo`. That field is self-attesting — a third-party release
#    declaring a `devantler-tech` URL would read back as proof of our ownership and exempt itself
#    from the very gate this entry imposes. The mapping is `.claude/bundled-skill-ownership.tsv`,
#    checked against the pinned bundle by `skill-owner.sh --check-reviewed` (monorepo#3054); an
#    earlier revision routed this to a dated prose census, and before that to the field itself.
# ONE line, deliberately: `has` is a fixed-string grep, and grep -F reads a multi-line pattern as
# one alternative per line — so a pattern spanning the wrapped sentence would be satisfied by any
# single line of it, including lines the previous wording shares.
has 'reviewed mapping [`.claude/bundled-skill-ownership.tsv`](../bundled-skill-ownership.tsv),' "${egress}" || \
  fail "the Egress entry no longer routes skill ownership to the reviewed mapping and away from the self-attesting metadata.github-repo — a third-party skill declaring a devantler-tech URL could exempt itself from this very gate"
ok
has '`.claude/scripts/skill-owner.sh --check-reviewed` proves the two still agree' "${egress}" || \
  fail "the Egress entry no longer names the check that proves the reviewed mapping matches the pinned bundle — a mapping nothing compares is a census by another name"
ok
has 'A bundled skill with no reviewed row has no reviewed owner: route its fix as third-party' "${egress}" || \
  fail "the Egress entry no longer fails closed for a bundled skill the reviewed mapping does not name — an unnamed skill could be exempted on no reviewed basis at all"
ok
has 'a `MISMATCH` against the reviewed row revokes it — never grant one' "${egress}" || \
  fail "the Egress entry no longer states that the skill's own claim can only withdraw an exemption, never grant one"
ok
# 6. VOCABULARY PIN — the canonical section must keep the wording the Egress entry mirrors. The defect
#    was these two drifting apart, so pinning only the copy would let the original move instead.
has 'Third-party upstream contributions' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer says 'Third-party upstream contributions' — the two sections have drifted apart again"
ok
has '`devantler-tech` repositories remain portfolio destinations rather than third-party ones' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer contiguously states the devantler-tech exemption"
ok


# 8. The canonical section must impose the bounded autonomous-write conditions and disclosure rules.
has 'Public read-only source research needs no separate read approval when it meets the research exception in the privacy guide' "${conventions}" || \
  fail "*GitHub artifact conventions* does not permit bounded public source research"
ok
has 'Private or ambiguous external repositories still require current, explicit confirmation before inspection' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer requires confirmation for private or ambiguous repositories"
ok
has 'record both the necessity and why no change inside `devantler-tech` can deliver the needed outcome' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer requires a recorded need and unavailable in-portfolio alternative"
ok
has 'No separate per-artifact approval is required once every condition above is proven' "${conventions}" || \
  fail "*GitHub artifact conventions* does not make the bounded contribution path autonomous"
ok
has 'If the project prohibits AI-assisted contributions, do not contribute there at all' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer refuses contributions to projects that prohibit AI assistance"
ok
has 'Do not add AI attribution unless the target project requires it' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer follows the target project's disclosure policy"
ok
has 'Never deny or falsely represent AI assistance when directly asked' "${conventions}" || \
  fail "*GitHub artifact conventions* no longer requires truthful answers about AI assistance"
ok
has 'Outside it, only bounded public research and third-party contributions authorised by the privacy and GitHub-artifact guides are permitted' "${trust}" || \
  fail "the trust gate does not recognise the bounded third-party contribution path"
ok
has 'A bounded public third-party contribution may proceed without a separate ask only after' "${readiness}" || \
  fail "the autonomy section still lacks the bounded no-separate-ask contribution path"
ok
has 'A bounded external contribution is eligible without a separate ask only when' "${merge_delivery}" || \
  fail "the merge policy still lacks the bounded no-separate-ask contribution path"
ok
has 'Never merge outside `devantler-tech`' "${merge_delivery}" || \
  fail "the bounded contribution path no longer preserves the external merge prohibition"
ok
has '**AI-disclosure line (canonical):** every `devantler-tech` PR body, issue and comment this deployment authors begins' "${channels}" || \
  fail "the canonical disclosure rule is not scoped to portfolio artifacts"
ok
has '**AI-disclosure line:** every `devantler-tech` artifact this deployment authors begins' "${root_channels}" || \
  fail "the root disclosure summary is not scoped to portfolio artifacts"
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
# Discarding stderr turns a malformed expression into a silent strict-mode abort — no FAIL line and no
# diagnostic, which is indistinguishable from a real contract violation. Surface it as a failure.
wf_q() {
  local out err rc
  err="$(mktemp)"
  out="$(yq -r "$1" "${workflow}" 2>"${err}")"; rc=$?
  if [ "${rc}" -ne 0 ]; then
    local msg; msg="$(tr '\n' ' ' < "${err}")"; rm -f "${err}"
    fail "yq failed evaluating '$1' — ${msg}"
  fi
  rm -f "${err}"
  printf '%s' "${out}"
}
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
# The aggregate job needs the same treatment: a `container:` on `status` supplies the image its
# composite action runs in, and the job-key allowlist above covers only this contract's own job.
status_extra="$(wf_q '.jobs.status | keys | .[] | select(. != "name" and . != "runs-on" and . != "if" and . != "needs" and . != "permissions" and . != "steps")')"
[ -z "${status_extra}" ] || \
  fail "the status job sets $(printf '%s' "${status_extra}" | tr '\n' ' ')— only name, runs-on, if, needs, permissions and steps are permitted, because keys such as container:, env: and continue-on-error: change what the aggregate runs in or whether its failure counts"
# The same key-says-nothing-about-value rule the contract job gets. `status` runs the aggregate action
# that carries this contract's result, so a bespoke runner can make that action report success, and a
# wider permissions grant is available to whatever runs there.
srunner="$(wf_q '.jobs.status."runs-on"')"
[ "${srunner}" = "ubuntu-latest" ] || \
  fail "the status job runs on '${srunner}', not the hosted ubuntu-latest — a bespoke runner can make the aggregate action report success regardless of this contract's result"
sperms="$(wf_q '.jobs.status.permissions | to_entries | map(.key + "=" + (.value|tostring)) | sort | join(",")')"
[ -z "${sperms}" ] || \
  fail "the status job grants permissions '${sperms}' — the aggregate needs none, and any grant is available to whatever runs in that job"

# A `run:` step before the aggregate can write BASH_ENV (or PATH) into $GITHUB_ENV, which the
# composite action's own bash then sources — invisible to the declarative env checks, because nothing
# declarative changed. The aggregate must be the job's only step.
[ "$(wf_q '.jobs.status.steps | length')" = "1" ] || \
  fail "the status job has more than one step — a step before the aggregate can export BASH_ENV or PATH via \$GITHUB_ENV, which the aggregate's own shell then inherits"
# An allowlisted KEY still says nothing about its VALUE — the same gap review found in the wiring
# queries. `runs-on` may name a self-hosted runner that supplies a no-op `bash` or `yq`, and
# `persist-credentials: true` leaves the checkout token in git config for the PR-head script that runs
# next. Pin both values, not just their presence.
runner="$(wf_q ".jobs.\"${JOB}\".\"runs-on\"")"
[ "${runner}" = "ubuntu-latest" ] || \
  fail "the ${JOB} job runs on '${runner}', not the hosted ubuntu-latest — a self-hosted or bespoke runner can supply a no-op bash or yq, so the verification command would succeed without checking anything"
persist="$(wf_q ".jobs.\"${JOB}\".steps[] | select(.uses != null and (.uses | test(\"^actions/checkout@\"))) | .with.\"persist-credentials\"")"
[ "${persist}" = "false" ] || \
  fail "the ${JOB} job's checkout sets persist-credentials: ${persist} — the token would remain in git config for the PR-head script that runs next, exposing a credential to checked-out code"
# `permissions` was allowlisted as a key while its CONTENTS were unchecked, so `id-token: write` would
# let this PR-head bash step mint an OIDC token it has no need for. Pin the mapping, not the key.
perms="$(wf_q ".jobs.\"${JOB}\".permissions | to_entries | map(.key + \"=\" + (.value|tostring)) | sort | join(\",\")")"
[ "${perms}" = "contents=read" ] || \
  fail "the ${JOB} job's permissions are '${perms}', not exactly contents=read — a wider grant such as id-token: write would be available to a step running this pull request's code"

# The event decides what Checkout's default ref IS. Under `pull_request_target` it defaults to the
# BASE branch, so the no-ref assertion above would hold while the job validated unchanged
# default-branch files — and that event also runs with a privileged token.
events="$(wf_q '.on | keys | .[]' | sort | tr '\n' ',')"
case ",${events}" in
  *",pull_request_target,"*) fail "the workflow triggers on pull_request_target — Checkout then defaults to the BASE branch, so this guard would validate unchanged default-branch files while a pull request weakens the contract" ;;
esac
case ",${events}" in
  *",pull_request,"*) ;;
  *) fail "the workflow does not trigger on pull_request (events: ${events%,}) — this guard would not run against pull requests at all" ;;
esac



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


# NO `defaults` may be inherited by the verification step, at either scope. These arrived one key at a
# time — `defaults.run.shell` (a `bash {0} || true` template converts every failure to success) and
# then `defaults.run.working-directory` (the exact `run:` text executes a different file entirely) —
# and `defaults.run` has no key that is safe to inherit here. Neither scope declares any today, so
# require exactly that rather than blocklisting the keys we happen to have thought of.
for scope in '.defaults' ".jobs.\"${JOB}\".defaults"; do
  [ "$(wf_q "[${scope} | select(. != null)] | length")" = "0" ] || \
    fail "a defaults block is set at ${scope} — it is inherited by the verification step, where run.shell converts a failure to success and run.working-directory makes the exact command execute a different file"
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
check_step_keys ".jobs.status.steps[] | select(.uses != null and (.uses | test(\"^devantler-tech/actions/aggregate-job-checks@\")))" \
  "status job's aggregate step" "name,uses,with"
ok
check_research "${research}"
# Each dropped boundary must fail for that specific omission, not a setup error.
for phrase in \
  'Read-only investigation of public open-source repositories needed to operate or advance a portfolio product is permitted without per-repository read approval' \
  'The project must be known to be unrelated to the maintainer' \
  'Research does not authorize executing untrusted branch code, external writes or publication, or expanding the portfolio' \
  'Private or ambiguous external repositories require current, explicit confirmation before any inspection' \
  'Never discover, enumerate, search, inspect metadata/content/CI, clone, fetch, build, run, comment, review, push, open an issue/PR, merge, or otherwise interact with such repositories'; do
  output=""
  if output="$(check_research "${research//"${phrase}"/REMOVED}" 2>&1)"; then
    fail "negative control accepted missing research boundary: ${phrase}"
  fi
  has "public research boundary missing: ${phrase}" "${output}" ||
    fail "negative control failed for an unrelated reason"
done
ok
has 'public documentation and bounded public read-only source research under the privacy guide' "${advance_research}" || \
  fail 'the advance guide still prohibits permitted public source research'
if has '**non-repository** documentation in unattended runs; an external repository remains off-limits unless' "${advance_research}"; then
  fail 'the advance guide retains the former blanket repository-read ban'
fi
ok
[ "${passed}" -eq 27 ] || fail "expected 27 assertions, ran ${passed}"
echo "egress-third-party-qualifier contract: PASS (${passed} assertions)"
