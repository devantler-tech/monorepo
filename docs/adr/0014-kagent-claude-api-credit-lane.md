# ADR 0014: Run a budget-capped Agentic Engineer lane on kagent

Status: Accepted

Date: 2026-11-07

Reopens, under new economics: [ADR 0001](0001-kagent-agent-fleet-substrate.md)

Issue: [#4866](https://github.com/devantler-tech/monorepo/issues/4866)

## Context

ADR 0001 proposed kagent as a hosted substrate for the Agentic Engineer. It was rejected on
2026-09-10 because pay-per-token inference at the measured run shape cost about 73 times its cap:
spend grew with every scheduled run, and flat-rate subscriptions were far cheaper.

On 2026-11-05 the maintainer reported a new input: a **$200 monthly Claude API credit**. The credit
refills each month and is not a meter he pays per token. He asked for a kagent lane that runs the
`agentic-engineering` plugin as another scheduled engineer.

At the measured median run (about 43 million input tokens, 98% of them cache reads, and 310 thousand
output tokens), one full run costs about $19 on Claude Opus 5.5, $14 on Claude Sonnet 5.5 and $4 on
Claude Haiku 5.5. The credit therefore buys about ten full Opus runs a month, so the lane must be
budgeted rather than run on the host lanes' hourly cadence.

kagent itself has changed since July. Release 1.0 (release candidate 3, 2026-11-06) runs Claude Code
as a native **harness**: the gateway injects the model key at egress so the key never enters the
agent's sandbox, `EgressPolicy` allow-lists destinations and injects other Secret-backed headers,
and plugins and skills are pinned to an immutable git commit. On 2026-11-07 it was compared with
`kubernetes-sigs/agent-sandbox` (sandbox pods only, with no agent runtime or credential injection),
McKinsey's ARK (v0.1.x), Dapr Agents (a Python framework that cannot host Claude Code) and rossoctl
(small and young). kagent remains the best fit.

## Decision

The maintainer decided on 2026-11-07:

1. **A third Agentic Engineer lane runs on kagent** in the platform cluster: instance
   `kagent-cluster`, writer namespace `kagent/*`, the Agentic Engineer role only. The Agent
   Improver stays on the host lanes.
2. **Model and budget.** The lane uses `claude-opus-5-5` only, with no fallback model, and never a
   Fable-family model. It runs once a day, each run capped at about $6, so at most about $190 a
   month. An API workspace spend limit equal to the credit is the hard stop. When the credit runs
   out the lane stops; it never buys more.
3. **Identity.** The lane acts as the **Devantler Tech Engineering** GitHub App
   (`devantler-tech-engineering[bot]`, registered 2026-11-07), never as a personal account. Short
   installation tokens are injected at egress, so neither the App's private key nor a long-lived
   token enters the sandbox. Commits it pushes are signed.
4. **Federated model credential.** No long-lived Anthropic API key exists. Outside the agent's
   sandbox, a Kubernetes service-account token is exchanged through Anthropic workload identity
   federation for a short-lived access token, which kagent's gateway injects at egress. The
   federation rule pins one service account and one audience, and its workspace carries the spend
   limit. The cluster's issuer is registered with inline keys, which must be re-registered if the
   cluster's service-account signing key changes.
5. **One brain.** The harness loads the `agentic-engineering` plugin from the reviewed
   `libraries/agent-plugins` gitlink. The lane never runs a hand-copied or partial role.
6. **Suspended until ready.** The schedule stays suspended until every sub-issue of #4866 is done:
   the runtime, the identities, the image, whole-plugin loading and the canary run.

## Consequences

- The contract registers the lane now: the instance registry, the cadence table, the trust gate and
  an accepted billing route. Registration enables no route, child or fallback, and the schedule
  stays suspended.
- Each run does about a third of a full survey-and-ladder pass. The lane suits finishing and
  focused rung 1 to 3 work more than wide surveys, and it shares claims with the host lanes through
  the existing `agent-claim/<issue>` refs.
- The lane is the first workload of the sandboxed-runner epic
  ([#4853](https://github.com/devantler-tech/monorepo/issues/4853)) and the first user of the App
  identity ([#4601](https://github.com/devantler-tech/monorepo/issues/4601)). What it proves there
  informs the move of the host lanes.
- kagent's API is `v1alpha3` and 1.0 is not yet generally available, so versions are pinned exactly
  and upgrades are reviewed.
- Known gaps, each a sub-issue of #4866: kagent has no native schedule, so a `CronJob` invokes the
  agent over A2A; kagent's gateway injects Anthropic credentials as an `x-api-key` header while
  federated access tokens are bearer tokens, so the injection path must be proven; the Claude
  harness drops a dual-manifest plugin's agents, hooks and MCP servers
  ([kagent-dev/kagent#3388](https://github.com/kagent-dev/kagent/issues/3388)); and the Agent
  Improver cannot yet see transcripts produced inside the cluster.

## Alternatives considered

- **Keep the credit unused.** Wastes a recurring, already-granted budget.
- **Spend the credit on the host lanes' Claude runs.** The host lanes use the subscription, so the
  credit would add little there and would not advance sandboxing or the App identity.
- **Claude Managed Agents with scheduled deployments.** Anthropic would host the loop and the
  sandbox, but the lane would leave the platform the portfolio already operates. The maintainer
  chose kagent in 2026-07 and asked for it again on 2026-11-05.
- **A GitHub Actions workflow running Claude Code.** Simple to schedule, but it has no gateway
  credential injection, puts the model key in the job environment and does not exercise the
  platform-hosted sandbox the agents are moving to.

## Amendments

- **2026-11-09: no per-run time limit.** Decision 2 capped each run at about $6, enforced as a
  20-minute cancel by the trigger. The maintainer replaced that cap: a run that is cancelled
  mid-task wastes what it has already spent, and a real engineering run needs longer. A run now goes
  until the agent ends it, and the Anthropic workspace spend limit equal to the credit is the lane's
  only spend cap. The lane still runs at most once a day and stops when the credit runs out
  ([platform#5964](https://github.com/devantler-tech/platform/pull/5964)).
