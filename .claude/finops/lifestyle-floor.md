# The lifestyle floor — protected outcomes

**Owner: the maintainer. Not the agent.**

This file names the outcomes that are **never traded for money**. The
[`finops-engineer`](../agents/finops-engineer.md) reads it every run and vetoes any proposal that
would deliver *less* of anything below.

**How to read an entry:** each names an **outcome**, not an implementation. "Everything is reachable
at its own name over HTTPS" is protected; *how* that is delivered is fair game — a cheaper
implementation of the same outcome is exactly the work this agent exists to do.

**How to change it:** the maintainer edits it, or tells the agent to in a session or over Slack. The
agent may *propose* an addition and may *ask* whether something still belongs — it may never remove
or weaken an entry on its own, and never infer a change from a metric.

---

## Protected

| # | Outcome | Why it is here |
|---|---|---|
| 1 | **The platform stays up without babysitting.** Node loss, a bad deploy or a restart is a non-event, not a pager. | This is the entire point of the platform. Redundancy that looks "idle" is what buys it. |
| 2 | **Data is recoverable.** Backups run, are retained, and are restorable — including the personal apps. | Its value is realised exactly once, on the worst day. Never judge it by utilisation. |
| 3 | **Everything is reachable at its own name, over HTTPS, from anywhere.** | Domains, DNS, certificates, ingress and the load balancer are lifestyle, not overhead. |
| 4 | **The household finance app keeps working, privately, with bank sync intact.** | It is how the maintainer runs his actual life. Ironically the single thing this agent must never economise on. |
| 5 | **The deployed personal and client sites stay live and fast** — the wedding app, the coaching site, and anything else serving real people. | Other people depend on these. Their cost is negligible; their breakage is not. |
| 6 | **The maintainer can see what the platform is doing** — dashboards, logs, traces, alerts. | Observability is what makes the platform *owned* rather than *hoped at*. A rarely-opened dashboard is not waste. |
| 7 | **Security posture holds.** Policy enforcement, scanning, secret management and admission control stay on. | A saving bought by turning off a control is a loan against a bad day. |
| 8 | **The agent fleet keeps working** — enough model and review capacity that the engineers are not blocked. | Capacity here converts directly into shipped work. Starving it to save money is a false economy, and has already blocked a PR once. |
| 9 | **Experimentation stays possible.** Headroom to try a new tool or spin something up without a budget conversation. | A platform you cannot play on stops being interesting, and this one exists partly to be interesting. |

---

## Explicitly NOT protected

These may be proposed freely — they are the agent's natural hunting ground:

- **Idle and orphaned resources** — volumes with no claim, workloads nobody deploys to, capacity
  provisioned for a load that never arrived.
- **Over-provisioning** — requests and limits far above measured usage, *provided real headroom is
  kept* and the workload is watched afterwards.
- **Paying retail** — a worse tier, region, instance shape, commitment or provider for identical
  capability.
- **Duplication** — two tools doing one job, or a managed service duplicating something already
  self-hosted well.
- **Forgotten spend** — anything renewing that no longer serves outcome 1–9.
- **Unobserved spend** — cost accruing where nothing is watching, notably CI clusters in other clouds.
  *Measuring* it is always in scope, whatever it turns out to be.

---

## Standing notes

- **Low utilisation is evidence about capacity, never about value.** Outcomes 2, 6 and 9 exist largely
  to stop that inference being made. When you cannot tell "unused" from "unwanted", it is protected
  until the maintainer says otherwise.
- **Cheaper delivery of a protected outcome is always welcome** — that is the job. Less of one never
  is.
- **The floor erodes gradually or not at all.** No single proposal ends a lifestyle; twenty defensible
  ones do. That is why this is a written list with a veto step, not a factor in a ranking.

---

*Seeded 2026-07-21 from what is actually deployed, deliberately conservative: it is far cheaper to
remove an over-protection the maintainer disagrees with than to discover a protection that was
missing after the fact. Entries 1–9 are the agent's reading of intent and are **awaiting his
confirmation** — a wrong entry here is a bug, and correcting it is a one-line edit.*
