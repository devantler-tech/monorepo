# Inference routing runtime verification

The canonical policy is [inference-routing.policy.json](inference-routing.policy.json), resolved
through `AGENTS.md` **Inference routing**. Shared behavior is provider agnostic; the
[instance registry](agent-instances.json) and routing policy contain the current deployment bindings.
Adding a compatible native adapter does not require another role definition or infer authority.
Its opt-in controls the new automatic routing and
delegation mechanism; it does not stop or reconfigure existing native parent schedules. Existing
parent execution also requires an independently confirmed permitted model and included billing
route. Disabled routing does not establish that compliance. Missing pre-inference controls hold the
affected startup, resume or fallback; unresolved parent enforcement remains an explicit rollout gap.
All registrations initially expire on **2026-09-26 00:00 UTC**. Renewal requires fresh capability
evidence and a reviewed policy revision, not extending a date automatically.

## Recorded capabilities — 2026-09-12

| Surface | Observed capability | Unverified control; automatic routing remains disabled |
|---|---|---|
| Codex local, CLI 0.154.0 and desktop task tools | CLI reports ChatGPT login; explicit parent/subagent model selection; native Pro usage reports; weekly bucket exposed | Five-hour bucket absent; no verified pre-inference account admission or no-substitution boundary; parent permission overrides can affect children |
| Claude local, bundled CLI 2.1.266 | Bundled binary found outside PATH; enabled engineer/improver schedule records expose no model field; user settings have no model allowlist and no managed settings file was present | CLI status reports no login in the inspecting process; desktop authentication, included billing, effective model and native enforcement remain unresolved |

These are separate surfaces, not a fleet-wide verification result. Presence in a policy is neither
entitlement nor activation. The primary model strings
are candidates to resolve against the deployed harness; benchmark availability cannot resolve them.
The inspecting process exposed no OpenAI or Anthropic inference API-key environment
variables. This is a scoped process observation, not proof about other applications or devices.

A local evaluator probe on 2026-09-12 used a fresh native Codex weekly observation while retaining
the absent short window and unknown chain reservations. It returned `HOLD` with `QUOTA_UNKNOWN`,
`CONTROLS_UNVERIFIED`, `POLICY_DISABLED` and `RUNTIME_DISABLED`, and `executionAdmitted: false`.
No model was launched by that probe and no quota reservation was made.

Claude's native exact-model allowlist with `enforceAvailableModels` covers startup, resume and
fallback, but an empty list or an entirely unavailable list permits the account default. The
`PreModelSwitch` hook omits automatic fallback and restored resume models; `SessionStart` and
`SubagentStart` cannot block. These documented controls do not close that escape. This is a missing
guarantee, not evidence that an existing run selected Fable.

`forceLoginMethod: claudeai` and absence of API keys also do not establish included billing:
Console OAuth can incur API charges without an API key. Disabling usage credits in the actual
Claude.ai account supplies the included-usage ceiling only when the scheduler's subscription route
is independently verified. Neither the account setting nor that scheduler identity was verified.
Keep the Claude route disabled; do not substitute a prompt or a non-blocking hook for enforcement.

## Native verification procedure

1. Bind runtime, surface/version, policy revision, loaded role/skill blob identities, and account
   bucket identity in the private verification record. Keep credentials and account IDs out of Git.
   Also verify the loaded `resources/inference-routing.md` against the reviewed plugin revision.
   The existing currency helper covers agents, skills and declared executable assets; its `CURRENT`
   result alone does not attest this ancillary Markdown resource. Read the verified pinned copy
   whenever the installed resource cannot be verified.
2. Confirm the subscription-authenticated native path. Disable paid fallback, on-demand usage,
   credit overages and purchases using the native setting. Record its authoritative read-back.
   A local dollar estimate or `--max-budget` is not subscription billing enforcement.
3. Pin the intended exact model. Verify effective resolution before inference on startup, resume,
   child overrides, advisors, default selection, and fallback. Intercept prohibited requests before
   generation in negative tests; do not launch Fable to test the prohibition. A documented fallback
   or an opaque alias with no enforceable resolution leaves the affected route disabled.
4. Probe ordinary reads and denied writes through every exposed tool, including MCP. Claude plugin
   frontmatter cannot supply ignored hooks/permission settings. Codex keeps its existing inline
   survey override. Verify inherited connectors at their actual execution boundary; a model or
   role name does not establish a read-only sandbox.
5. Verify every builder's allowed paths, tools and remote actions at the runtime boundary; an isolated
   directory and prompt do not constrain shell or authenticated forge access. Bind child execution to
   the owner's renewable claim token/generation and expiry. Prove claim loss/expiry denies further
   mutations and cancels the stale child, and reject stale-owner output at integration. If that
   enforcement is unavailable, retain inline work. Bind one physical worktree to each builder and
   the immutable base/claim owner. Check the actual
   top-level path and common gitdir/config; a submodule worktree that resolves into a shared
  directory fails isolation. Verify a read-only mount/capability boundary for an observer.
6. Establish serialized admission before inference for each account, including engineer and improver
   schedules. Start with one execution chain and no speculative fan-out. Native schedule offsets
   do not serialize long-running tasks. An in-session prompt cannot protect its initial inference.
   Keep unsettled consumption until the account snapshots reconcile; do not release it on lease
   expiry alone. Include all applicable provider/model buckets and uninstrumented-device coverage.
7. Record positive and intercepted-negative probe evidence, reviewer, time, expiry and rollback
   revision. Only then propose enabling that registration and the policy. Configuration tests alone
   cannot satisfy these runtime probes.

Use native subscription controls only. Do not add a paid inference broker or API adapter to overcome
an unavailable native feature. An unsupported route is a measured capability gap, not a reason to
weaken the contract or silently substitute a model.

## Writer coordination

Scope each delegated edit to an explicit file/interface set, one issue claim and one isolated
worktree. Coupled API/schema/lockfile/generated-output changes serialize even when file paths differ.
The owner checks the returned commit and rebinds it to current main before integration and review.

Only one owner integrates a work item. Before cross-runtime handoff, stop the prior writer and
transfer the actual claim/worktree/result evidence; do not hand both runtimes the same writable
checkout. No automatic cross-provider handoff is enabled. A verified future route may hand off once;
failed attempts and model evidence travel with it. Never bounce work between models indefinitely.

## Governance and cadence

The registry's `policyPublisher` is the single routing-policy publisher. It uses the existing issue
claim, owned worktree and current-head PR review protocol, including collisions with its own runs.
Other registered instances contribute evidence/review and do not mutate this policy concurrently. Model
evidence is reviewed weekly during an existing improvement run; no additional recurring model
session is needed. Candidate discovery also runs after a documented model release or regression.

The first effort experiment compares Sol medium with the existing Sol xhigh baseline in matched
workhorse tasks. Retain a verified permitted baseline until the experiment is admitted; do not
grandfather an unverified native default or replace the baseline before collecting it. Use at most 10% of eligible tasks in the
canary, one changed variable, and a predeclared baseline/holdout. Admission requires verified native
controls, complete coverage and both quota reserves. The 20-minute/two-hypothesis rules and 20%/15%
reserves are conservative pilot parameters, not measured optima.

Two weeks and 30 completed tasks per compared arm/class are minimum observation floors, not a
statistical guarantee. Predeclare uncertainty intervals and practical benefit thresholds; extend
the window when precision or coverage is insufficient. Failures and abandonments stay in the
denominator. Promote only if accepted outcomes per measured same-provider quota unit improve and
safety, review/rework, CI, revert, and ownership floors do not regress. A violation of billing,
model prohibition or writer boundaries stops the affected experiment immediately; restore the
last reviewed policy and investigate. Quality or throughput regressions revert the candidate route.
No automatic promotion from a benchmark rank or raw PR count.

The [telemetry procedure](inference-routing-telemetry.md) supplies the normalized evidence and
scorecard. Native private records contain the full attempt chain and hydration costs; public reports
contain only sanitized engineering conclusions. Missing short-window data or exact model attribution
is **NO-VERDICT**, not a zero-cost task or a successful optimization.

## Documentation evidence

Verified against primary documentation on 2026-09-12; these sources inform probes and do not replace
local runtime evidence:

- [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents): model overrides,
  inherited context and permission behavior.
- [Claude subagents](https://code.claude.com/docs/en/sub-agents) and
  [model configuration](https://code.claude.com/docs/en/model-config): plugin restrictions and
  model allowlist resolution, including the unavailable-list fallback edge case.
- [Claude hooks](https://code.claude.com/docs/en/hooks),
  [authentication](https://code.claude.com/docs/en/authentication#restrict-login-to-your-organization)
  and [usage credits](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans):
  hook coverage, Console OAuth and the account's included-usage ceiling.
