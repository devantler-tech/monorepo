# Portable Agentic Engineer loader

Use this bootstrap in a native harness that can read the consuming checkout. It supplies no
provider identity, schedule, credentials, model selection, or mutation authority.

1. Read the checkout's [AGENTS.md](../../AGENTS.md). It is authoritative for deployment facts,
   including the instance registry, authority, trust, cadence, inference routing, and delivery gates.
   If that contract is unavailable, report the missing contract before acting.
2. Resolve this instance and its capabilities from the consumer contract and the native harness's
   verified state. Use the deployment's authenticated identity and ownership rules; do not infer
   permissions, branch namespaces, or billing from a provider name or an installed application.
   Keep unknown or unsupported authority closed for the affected action and report the concrete
   missing capability. Preserve the reviewed work that remains authorized.
3. Native dispatch must follow the effective desired state's
   [`spec.source`](../plugin-consumption/agentic-engineering.desired-state.json):
   `latest-reviewed-default-branch` / `before-starting-each-run`, through the registered instance's
   supported native refresh control plane and the consumer's rollout gates. Preserve
   `hotSwapDuringRun: false`: a refresh can prepare a later dispatch only, never replace this
   session's booted definition. The consumer gitlink is rollout-verification evidence, not a runtime version lock.
4. Check definition currency with the adapter supported by this deployment, comparing its loaded
   or declared source evidence against the consumer pin. On `DRIFT` or `UNKNOWN`, report the result
   and follow the contract's recovery and reviewed fallback at the **consumer's pinned gitlink**.
   Use the *Agentic engineering plugin contract* procedure to materialize and read that revision
   without replacement objects. The `git-ref` backend accepts an explicit full commit ID or fully
   qualified source ref through `--loaded-ref`; it attests **source parity only** and does not attest the loaded session.
   Missing loaded-state evidence remains unknown. Never edit runtime caches or describe a successful
   refresh as proof that this session loaded the refreshed definition.
5. Read `plugins/agentic-engineering/agents/agentic-engineer.agent.md` from the reviewed source
   resolved above, then its required skills and only the deployment overlays declared by the consumer.
   A cached version label or legacy role alias does not substitute for that source.
6. Follow the reviewed engineer's run loop within those resolved bounds. Apply the consumer's
   inference-routing prerequisites before any new delegation. If enforced delegation is unavailable,
   use the contract's ordinary reviewed inline fallback where authorized; never create a renamed
   subagent to bypass a capability restriction.

The native dispatch configuration should point here and to the consuming checkout. Its effective
configuration still needs verification through that harness's supported control plane; this file
does not install, schedule, or activate an agent.
