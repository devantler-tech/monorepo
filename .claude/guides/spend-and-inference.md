# Spend stewardship and inference routing

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for the Spend contract with its facts
> table and activation gate, and the inference-routing rules. Read it before a cost pass, and before
> any model selection, delegation, escalation or schedule-default change.

## Spend contract — the money side of the same portfolio
**Spend is the Agentic Engineer's own mandate, not a separate agent's** (maintainer direction
2026-07-25, superseding the standalone FinOps Engineer that used to live at
`.claude/agents/finops-engineer.md`). Running cost is incurred by the code this engineer already owns,
so a second scheduled writer over the same repositories only produced overlapping claim lanes and a
duplicate copy of the delivery discipline — which is why the *Writer namespaces* table already had to
record both roles sharing one provider instance. The generic mandate and its money boundaries now live
in the plugin entrypoint's **Spend stewardship** section (upstream
[ADR 0005](https://github.com/devantler-tech/agent-plugins/blob/main/docs/adr/0005-merge-spend-stewardship-into-the-engineer.md));
this section supplies the deployment facts it resolves. **Absent or malformed, the engineer fails
closed on the cost dimension only** — operate and advance work continue, spend analysis does not.

| What the plugin resolves here | This deployment's fact |
|---|---|
| **Effective desired state** | [`.claude/plugin-consumption/agentic-engineering.desired-state.json`](../plugin-consumption/agentic-engineering.desired-state.json) — the single effective desired-state document for this deployment, including `spec.roles["agentic-engineer"].spendStewardshipEnabled: false`. The reviewed entrypoint's opt-in contract governs its resolution. |
| **Protected-outcomes floor** | [`.claude/finops/lifestyle-floor.md`](../finops/lifestyle-floor.md) — the declared, versioned list of outcomes never traded for money. **Changing it is the maintainer's call**, in a session or over the private channel; never the engineer's, and never inferred from a metric. |
| **Run procedure for a cost pass** | [`.claude/skills/finops/`](../skills/finops/SKILL.md) — measure → attribute → diagnose → floor-veto → act → verify → record. |
| **Cost evidence source** | the read-only [`.claude/scripts/finops-snapshot.sh`](../scripts/finops-snapshot.sh) (OpenCost attribution), plus Coroot's Prometheus for actual usage. The **provider billing API is NOT wired**, so every saving figure is *modelled*, never *realised*, and must say so. The run loop carries the full source-by-source state and its four known measurement defects. |
| **Private decision channel** | the devantler-tech Slack, per *Maintainer channels* — 🔴 **and its destination is still UNRESOLVED**: the only channel in the workspace is the **public** `#announcements`, where financial detail must never go. Until the maintainer designates a private destination, send **nothing** — and route only **non-financial** blockers through the run report, never a financial decision, which is not produced at all while this reads UNRESOLVED (see *Activation gate*). |
| **Cost-pass cadence** | per *Cadence & focus* — a heavy task, so roughly weekly, never every run, and always behind hotfixes and actionable PRs. |
| **Which lanes may run it** | Only registered instances with verified access to both the live-cluster evidence source and private ledger. A missing capability skips the cost pass; provider or host labels never establish access. |
| **Private evidence store** | the out-of-repository ledger named under *Durable memory* — proposals, open asks, and projected-vs-realised. Absolute figures never enter a repo file. |

**Activation gate — the decision-producing half is DEFAULT-OFF until the private channel resolves.**
Spend stewardship is disabled in the effective desired state; ordinary operate and advance work
continue. The **Private decision channel** row supplies an additional restriction after the reviewed
entrypoint's explicit opt-in and deployment prerequisites resolve:

| Half of the mandate | State while the channel reads UNRESOLVED | Why |
|---|---|---|
| **Measurement & engineering** — wiring an evidence source, fixing the stale price table, an orphaned-volume cleanup | **ON** | ordinary engineering work with no financial output; blocking it would stall the very measurement the rest depends on |
| **Decision-producing** — a financial ask, a spend proposal, a savings figure put to the maintainer | **OFF** | there is nowhere to send it, and parking it in a report is the passive self-blocking this contract forbids elsewhere |

Only after the reviewed entrypoint resolves explicit spend enablement and the required deployment
facts may the cost pass run steps 1–4 of its run loop and **stop before step 5's ask** while the channel
is unresolved. Ordinary engineering repairs to measurement remain available while spend stewardship
is disabled; spend analysis and financial decisions do not. Resolving the channel is a further
prerequisite for financial decisions, never spend opt-in; both are maintainer acts, never agent ones.
The delivery-contract test checks the disabled configuration and the separate channel restriction.

Three properties are **not negotiable by the engineer**, and merging the role changed none of them: it
**never moves money** (it prepares the decision; the maintainer executes it), it **gives no
personalised investment advice** (engineering economics only — rent vs own, tier, provider, payback),
and **private financial data never reaches a public artifact**. They are also stated in the plugin
entrypoint; restating them here is deliberate, so retiring the standalone agent cannot read as
retiring its limits. The **Agent Improver improves the spend dimension too**, on its
own parameters — calibration, floor integrity, signal discipline, honesty, confidentiality, coverage —
deliberately *not* on how much it saves.

## Inference routing

The reviewed [inference routing policy](../plugin-consumption/inference-routing.policy.json)
is this deployment's source for task-class aliases, effort, escalation thresholds, quota reserves,
and runtime registrations. The [instance registry](../plugin-consumption/agent-instances.json)
is the source for instance IDs, writer namespaces, exact per-surface identities, native definition
adapters, allowed roles and the designated policy publisher. The plugin owns the portable
evaluator/procedure; this consumer owns the current bindings. Provider names never confer capability.
[Runtime verification and governance](../plugin-consumption/inference-routing-runtime.md)
records the concrete surface/version, expiry, capability gaps and promotion criteria. A registry row
does not establish entitlement or enforcement.

**Inference spend stewardship is mandatory and separate from infrastructure FinOps opt-in.** Use
only already-included native subscription inference. No inference API keys, pay-as-you-go endpoints,
purchased/reset credits, paid fallback, overage activation, automatic subscription upgrades, or
inference brokers. The existing infrastructure `spendStewardshipEnabled: false` and private-channel
gate remain unchanged. A quota or capability failure queues the dependent work; it never widens billing.

**No-Fable is a protected limit:** the entire Fable model family is prohibited in recurring parent
runs, children, advisors, fallback, retries and experiments, even if a provider describes it as
included. No automatic alias or default may resolve to it. The policy rejects visible model IDs
containing `fable`, case-insensitively; native controls must prove opaque resolution and fallback
before a route is enabled. Prompt wording and a successful evaluator result are not proof of that
boundary. A forbidden request must be intercepted before inference, never executed as a probe.

| Task class | Scope and escalation |
|---|---|
| `support` | Bounded analysis with an independently verifiable result and measured net context savings |
| `workhorse` | One repository/behavior, clear acceptance checks and ownership, reversible implementation; routine lint/Git steps stay in the owning task |
| `diagnosis` | Direct admission for difficult reasoning or sensitive invariants; otherwise two distinct failed repair hypotheses or 20 active minutes without resolution |
| `deepRefactor` | Verified native workflow advantage or measured class-specific benefit; not an automatic next rung after diagnosis |

The exact runtime/model IDs are in the policy, not inferred from this table. Unknown scope, missing
checks or irreversible writes hold implementation; a diagnostic step may investigate read-only.
Authentication, environment, ownership, quota and authority failures use their existing recovery
paths, never model escalation. A handoff carries failed hypotheses and evidence and happens at most
once across providers; stop the previous writer first. One delivery owner retains the issue and PR.

**Activation:** automatic routing is initially disabled in the policy and every runtime registration.
Existing native parent execution may continue only on an independently confirmed permitted model
and included billing route. Disabled routing does not grandfather an unknown parent route, reconfigure
its scheduler, or prove its initial inference is quota-protected. Missing pre-inference controls hold
the affected startup, resume or fallback; report unresolved parent enforcement explicitly. Resolve
this contract before any new delegated/model-switched execution. Do not enable a route until native billing, exact model,
tool, isolation, and serialized account-admission probes pass. Retain **UNKNOWN** for unexposed quota
buckets and **NO-VERDICT** for incomplete attribution. The Codex **inline survey override** remains
in force; an explore alias or model change cannot evade it.

Initial automatic limits, when verified and enabled, are one child at depth one and one admitted
scheduled execution chain per account across engineer and improver. Admission is before inference;
schedule offsets and in-session preflight do not enforce it. Reserve 20% of short-window and 15% of
weekly allowance, accounting for all attempts and unsettled consumption. These are pilot parameters,
not measured optima. A missing estimate or bucket never becomes zero.

Each delegated writer requires an isolated worktree, explicit file/interface scope, enforced tool
permissions and claim fencing. The delivery owner integrates the result after checking its revision
and evidence. Registrations expire after 14 days and require fresh reviewed evidence to renew.

The instance named by `policyPublisher` in the registry is the single policy publisher, fenced by
the existing issue claim and current-head PR workflow even against overlapping runs of itself.
Other registered instances supply independent evidence and review. Weekly candidate research uses an existing improvement run, with at most a 10% canary
only after runtime admission is verified. Keep the Sol xhigh baseline until that experiment is
admitted. Use the [routing telemetry procedure](../plugin-consumption/inference-routing-telemetry.md)
and its scorecard to count complete attempt chains and accepted outcomes; never attribute a mixed
model PR to its final model. Two weeks and 30 completed tasks per arm/class are minimum floors,
not proof of statistical significance. Billing, No-Fable, ownership and quality floors are vetoes.
Changes to protected spend/model/runtime limits require explicit maintainer direction; benchmarks
may nominate aliases but cannot authorize activation or automatically select `latest`.
