# ADR 0015: Run the scheduled agent lanes in platform pods, with the host as the fallback

Status: Proposed. It becomes accepted only when the two proofs under *Conditions* hold.

Date: 2026-11-11

Builds on: [ADR 0014](0014-kagent-claude-api-credit-lane.md)

Issue: [#4942](https://github.com/devantler-tech/monorepo/issues/4942), under the epic
[#4853](https://github.com/devantler-tech/monorepo/issues/4853)

## Context

The Claude and Codex lanes run on the maintainer's own machine, beside his keychain, his signing
key and his personal sign-ins, and with a route to his local network. On 2026-11-04 he asked for the
agents to run in a container, a cloud runner or a runtime's own sandbox instead, with every tool and
permission they need to keep working without his help. His note on the epic adds one limit: the
platform is the preferred place, but not at the price of pay-per-token billing.

The spike [#4854](https://github.com/devantler-tech/monorepo/issues/4854) compared the options on
2026-11-11 from the vendors' public documentation and this repository. Its
[result](https://github.com/devantler-tech/monorepo/issues/4854#issuecomment-6803112763) holds the
evidence and the sources; this record keeps the decision and its reasons.

ADR 0014 already runs Claude Code on the platform in a sandboxed kagent harness, with an outbound
allow-list, short-lived GitHub App tokens added on the way out, signed commits and a pinned plugin.
That lane is paid from an API credit. The two host lanes are paid from flat-rate subscriptions and
must stay that way.

## Decision

1. **Claude lane.** It moves to a platform pod in the kagent Claude Code harness that ADR 0014
   builds, signed in with the Claude subscription instead of the API credit.
2. **Codex lane.** It moves to a platform pod of its own with an outbound allow-list, signed in with
   the ChatGPT plan. If kagent cannot host Codex, a plain scheduled pod does.
3. **The host stays the fallback.** Both host lanes keep running as they do today until the
   sandboxed runs have held up over an observation window. The maintainer sets the length of that
   window and what counts as holding up, and he decides when a host lane is retired. Until he does,
   nothing is retired.
4. **Nothing moves on this record alone.** It changes no runtime, permission, schedule, identity or
   billing route. Each lane moves through its own reviewed change after its proof.

## Conditions

The decision rests on two links nobody has tried yet. Each has its own issue:

- [#4940](https://github.com/devantler-tech/monorepo/issues/4940): a Claude run signed in with the
  subscription completes in the kagent harness, a probe shows it cannot reach the local network, and
  one run's use of cluster capacity is measured.
- [#4941](https://github.com/devantler-tech/monorepo/issues/4941): a Codex run signed in with the
  ChatGPT plan completes in a platform pod with the same probe.

If a proof fails, this record is amended before any lane moves. A failed proof never falls through
to pay-per-token billing.

## Options compared

| | Runtime's own sandbox on the host | Platform pod (chosen) | Vendor cloud sessions |
|---|---|---|---|
| Cut off from the local network | Partly. Claude's sandbox covers the shell only; MCP servers and file tools stay outside | Yes: pod network policy plus an allow-list | Yes |
| Same tools as today | Yes, except that Claude's network filter blocks SSH pushes | After the pinned tool image exists ([#4867](https://github.com/devantler-tech/monorepo/issues/4867)) | No local tools or MCP servers |
| Acts as the GitHub App ([#4601](https://github.com/devantler-tech/monorepo/issues/4601)) | No. Personal sign-ins stay within reach | Yes | No. It acts through the user's own GitHub account |
| Signed commits | With the host's signing key | Signed by the App | Not established |
| Memory, worktrees and caches | Unchanged | On a volume ([#4910](https://github.com/devantler-tech/monorepo/issues/4910)) | Lost with every run |
| Flat-rate billing kept | Yes | Yes, if the two proofs hold | Yes |
| Upkeep | Low | An image, a policy and secrets to maintain | Low |

## Reasons

- **It is the only option that ends the exposure.** A sandbox on the host still runs beside the
  maintainer's credentials and network. A pod has neither.
- **It reuses what exists.** The platform already supplies network policy, scoped secrets, volumes
  and scheduling, and ADR 0014 adds the harness and the App identity. No second mechanism is built.
- **It keeps flat-rate billing.** Both vendors document a sign-in for unattended runs that uses the
  subscription and not per-token pricing.
- **Vendor cloud sessions do not fit scheduled lanes.** Each run starts from a fresh clone, so
  private memory has no safe home, and the agent's own tools are missing.
- **Hosted CI runners** put the model credential in the job's environment, which ADR 0014 rejected.

## Risks

- **The subscription sign-in may have to sit inside the pod.** kagent adds credentials on the way
  out for an API credential. Whether it can do that for a subscription sign-in is unknown, and a
  sign-in stored in the pod is weaker than the kagent lane's design. #4940 answers it.
- **Cluster capacity is not measured.** Two lanes run about twice an hour each. If that needs more
  paid nodes, the cost is weighed against the protected-outcomes floor before any schedule moves.
- **One failure domain.** An engineer that runs only on the platform stops when the platform does,
  and it is the engineer that repairs the platform. That is why the host stays the fallback.
- **Usage limits do not change.** Moving a run does not change the subscription limits the lanes
  already reach ([#4718](https://github.com/devantler-tech/monorepo/issues/4718)).
- **A sandbox that refuses ordinary commands costs autonomy.** Any refusal the new environment
  causes is filed under [#4288](https://github.com/devantler-tech/monorepo/issues/4288).

## Consequences

- The work that has to exist before a lane can move is already tracked under
  [#4866](https://github.com/devantler-tech/monorepo/issues/4866): the tool image, loading the whole
  plugin, keeping overlapping runs from overwriting each other's memory, and letting the Agent
  Improver read transcripts produced in the cluster
  ([#4870](https://github.com/devantler-tech/monorepo/issues/4870)).
- Interactive sessions are not decided here. The epic covers them; this record covers the two
  scheduled lanes.
- Codex's own network allow-list on the host already refuses private destinations by default. It is
  a stopgap the Agent Improver may weigh, not the end state.
