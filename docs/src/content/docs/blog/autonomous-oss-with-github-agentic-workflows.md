---
title: "How I Run KSail Autonomously with GitHub Agentic Workflows"
date: 2026-04-17
authors:
  - devantler
tags:
  - ai
  - github
  - copilot
  - agentic-workflows
  - automation
  - ksail
  - developer-experience
excerpt: A Mac Mini runs 24/7 at home, firing scheduled prompts that open PRs against KSail while I sleep. Here's how autonomy is obtained — and, more importantly, how it's managed so the output is actually good.
cover:
  alt: Autonomous OSS development with GitHub Agentic Workflows
  image: ../../../assets/agentic-workflows.png
---

A Mac Mini runs 24/7 in my house on Funen. It doesn't serve media, it doesn't compile code, it doesn't host a website. Its only job is to fire scheduled prompts at GitHub agents so they can work on [KSail](https://github.com/devantler-tech/ksail) while I sleep.

That sounds like a recipe for chaos. Left to their own devices, autonomous agents tend to produce a lot of *output* and not a lot of *outcomes* — PRs that don't compile, issues that duplicate each other, roadmaps that drift from reality. I've been running this setup long enough to have seen all of those failure modes first-hand.

What saves it is that autonomy isn't the goal. **Structured autonomy** is the goal. The agents are given narrow lanes, scheduled windows, and deterministic guardrails. I stay in the loop at exactly one place: the Draft → In Review transition. Everything else runs on rails.

This post is about how those rails are built.

## The Core Problem with Autonomy

Every "AI does your work for you" demo glosses over the same uncomfortable truth: an agent that's free to do anything will eventually do something you don't want. The interesting question isn't "how much can the agent do?" — it's "how do I make sure the things it does are the things I'd have done myself?"

My answer has three parts:

1. **Narrow the scope of each workflow** so there's a clear definition of "done" and very little room to improvise.
2. **Stack deterministic guardrails** — the kind that don't negotiate — between the agent's output and the main branch.
3. **Keep exactly one human decision in the loop**, at the point where it adds the most signal.

Everything else in this setup is in service of those three rules.

## The Pipeline: Six Agentic Workflows

KSail runs six [GitHub Agentic Workflows](https://github.com/githubnext/agentics), each with a narrow scope and its own schedule. They're implemented as Markdown prompt files that the `gh-aw` extension compiles into GitHub Actions workflows.

- **Weekly Strategy** — Runs Monday and Wednesday. On Monday it analyzes recent issues, discussions, and competitor tools (Tilt, Skaffold, DevSpace, and the rest) and publishes a Now / Next / Later roadmap. On Wednesday it turns the roadmap into promotional content — a Reddit post, a LinkedIn snippet, or a blog draft.
- **Repo Assist** — Runs every 12 hours. This is the busiest workflow. It picks a task via weighted random selection from 12 categories (labelling issues, investigating bugs, cleaning up stale PRs, translating roadmap items into backlog issues, writing small code improvements). Weights adjust based on repo state — if there are a lot of unlabelled issues, labelling gets heavier.
- **Daily Docs** — Runs daily and on every push to `main`. Syncs documentation with code changes, and on a separate schedule scans for bloat and simplifies redundant pages. Knows which files are auto-generated and refuses to edit them.
- **Daily Workflow Maintenance** — Runs daily. Updates action versions, applies [`gh-aw`](https://github.com/githubnext/agentics) codemods, recompiles workflow lock files. If there's nothing to update, it switches into a deeper mode that analyzes CI metrics and proposes optimizations.
- **CI Doctor** — Runs on failure. When any monitored workflow fails, CI Doctor pulls the logs, runs pattern matching against previous investigations, categorizes the root cause, and files an issue with a recommended fix.
- **Agentics Maintenance** — Runs every two hours. Closes expired discussions, issues, and PRs; keeps labels in sync. Mostly janitorial.

Each workflow has a single sentence that describes what it's allowed to do. None of them can merge. None of them can close another workflow's PR. Most of them can only open drafts.

## How Autonomy Is Obtained

The workflows run on GitHub-hosted runners, but the *prompts* that kick them off are scheduled on my Mac Mini via a simple cron-like setup. Why a physical machine and not just GitHub's built-in schedule triggers? Two reasons:

1. **I can dispatch prompts on demand.** When I'm drafting an idea and want Repo Assist to pick it up immediately, I trigger it from the Mac Mini rather than waiting for the next 12-hour window.
2. **The prompts are themselves versioned locally**, so I can iterate on them the same way I iterate on code — edit, test, commit, push. Keeping them on a machine I can see keeps the feedback loop tight.

The flow from idea to merged PR looks like this:

```mermaid
flowchart LR
    A["🗺️ Weekly Strategy<br/>Roadmap + content"] --> B["📋 Repo Assist<br/>Issues + draft PRs"]
    B --> C["👨‍💻 Me<br/>Promote Draft → In Review"]
    C --> D["⚙️ CI Pipeline<br/>Lint, build, test, bench"]
    D --> E["🤖 Agent Merge<br/>Rebase, fix, merge"]

    classDef agent fill:#1f6feb,stroke:#58a6ff,color:#fff;
    classDef human fill:#f0883e,stroke:#f0883e,color:#000;
    classDef ci fill:#238636,stroke:#3fb950,color:#fff;
    class A,B,E agent;
    class C human;
    class D ci;
```

Weekly Strategy produces the "what to work on." Repo Assist turns that into issues and, where appropriate, draft PRs. Everything sits in Draft until I promote it. CI runs on every change. Agent Merge (implemented as a [Skill](https://github.com/features/copilot-skills)) rebases and addresses final review feedback. The whole thing is a conveyor belt with exactly one human hand on it.

## How Autonomy Is *Managed*: The Guardrails

This is the part that actually matters. Scheduled prompts are cheap; guardrails are what make the output trustworthy. Every PR opened by an agent — or by me, for that matter — has to pass through a stack of deterministic checks before it can merge.

```mermaid
flowchart LR
    A["🚨 Agent opens PR"] --> B["🛡️ GHAS<br/>CodeQL + secret scanning"]
    B --> C["🔒 StepSecurity<br/>Runner egress auditing"]
    C --> D["🧹 Linting<br/>MegaLinter + golangci-lint"]
    D --> E["🧪 Unit tests<br/>go test ./..."]
    E --> F["🚀 E2E matrix<br/>Kind × K3d × Talos × VCluster"]
    F --> G["✅ Agent Merge<br/>via Skills"]

    classDef sec fill:#da3633,stroke:#f85149,color:#fff;
    classDef quality fill:#1f6feb,stroke:#58a6ff,color:#fff;
    classDef gate fill:#238636,stroke:#3fb950,color:#fff;
    class B,C sec;
    class D,E,F quality;
    class A,G gate;
```

Each layer earns its place:

- **GHAS + CodeQL** catches the class of bugs where an agent confidently introduces an injection or an unvalidated input. It's the cheapest guardrail with the highest return.
- **StepSecurity** hardens the runners themselves. `egress-policy: audit` on every job means I can see exactly which hosts a workflow is talking to — essential when agents occasionally try to fetch from somewhere unexpected.
- **MegaLinter and golangci-lint** enforce the stylistic and correctness conventions that agents are particularly bad at holding to consistently across a long session. Agents will write idiomatic Go for 20 files and then suddenly forget `errcheck`.
- **Unit tests** run on every PR via `go test ./...`. They're the first line of behavioral defense.
- **E2E / system tests** run on the merge queue across a matrix of distributions (Kind, K3d, Talos, VCluster) and providers (Docker, Hetzner, Omni). This is the slow, expensive, and most valuable layer — most agent-introduced regressions get caught here.
- **Agent Merge via Skills** handles the final rebase-and-address-review dance. It's explicitly *not* allowed to bypass any of the above.

The important property is that none of these layers trust the agent. They don't ask "did the agent say the code is good?" — they check independently.

## My Role: One Button

If you stripped everything else away, my job on KSail comes down to a single action: **promote draft PRs to In Review**.

That's the moment where I read the diff, read the linked issue, decide whether the change actually fits the roadmap, and either promote it or close it. Everything upstream is optional; everything downstream is automatic.

I do a few other things:

- 👀 **Occasional check-ins** to sanity-check agent decisions — am I comfortable with the direction of the current roadmap? Are there issues getting closed that shouldn't be?
- 🛠️ **Jumping in to build something myself** when I feel like coding. I use the same workflow — draft PR, CI, agent merge — so nothing is bypassed.

The workflow is explicitly designed so **nothing merges without my approval**. Agent Merge waits for `In Review` status; `In Review` only happens when I click the button. This is the one invariant I'm not willing to relax.

## Lessons Learned

A year into running this, a few things stand out — most of them are about what *changes* when AI becomes autonomous rather than assistive.

**The model matters more than the prompt.** A weaker model produces worse initial output and falls apart on anything with a large scope. When I run the same workflow against a mid-tier model and a frontier model, the frontier model is the one that actually ships usable code. The prompt matters, but it's the multiplier — not the base.

**Before Agentic Workflows, working with AI was tedious.** I'd open a chat, paste context, iterate, copy results back, paste into a PR. The per-task overhead was high enough that I used AI sparingly. Scheduled agentic workflows flipped that — the AI runs whether I'm paying attention or not, and I review in batch rather than drive in loops.

**I cannot trust AI to do a good job.** That sounds harsh, but it's the frame that makes the whole system work. I don't ask "is this PR correct?" — I assume it isn't, and I lean on the guardrails to prove me wrong. When CI, lint, and the E2E matrix all go green, I've got something like evidence. Without that stack, every agent PR would be a coin flip.

**The grunt of the work shifts from coding to validation.** My days look different now. I spend less time writing code and more time reading diffs, promoting drafts, and deciding whether a change fits the roadmap. The work didn't disappear — it moved from producer to editor.

**Autonomous AI requires good tooling, full stop.** Without GHAS and StepSecurity I'd be anxious every time an agent opened a PR. CodeQL catches the confidently-wrong security mistakes; StepSecurity tells me exactly which hosts a runner is talking to. These aren't optional for me anymore. Anyone running autonomous workflows without equivalent hardening is taking a risk they probably don't fully appreciate.

**Working code beats sexy code — a mentality I had to buy into the hard way.** My instinct is to factor, generalize, make it elegant. Newer models tend to satisfy that same itch, and when they do it well, it feels great. But when they duplicate code that shouldn't be duplicated, it feels *really* bad — worse than if I'd written the duplication myself. The compromise I've landed on: let the agent ship working code first, and treat refactoring as a separate, deliberate task rather than something to sneak into every PR.

**Adding things to the feedback loop pays off immediately.** CI Doctor is the clearest example. The moment I wired up failure analysis into the pipeline, recurring failures started getting diagnosed in minutes instead of hours. Every new signal I've added to the loop — test coverage reports, benchmark regressions, lint summaries — has had a similar effect. The feedback loop is where most of the leverage is.

**Scheduling from a physical machine isn't strictly necessary, but I like the Master Control mentality.** Most of these schedules could move to GitHub's built-in cron. The reason I keep the Mac Mini is that it's a single place where I can see what's running, what's queued, and what I'm iterating on. It's a dashboard I can glance at, not just a trigger. That feeling of having a central is worth more to me than the pure technical utility of the machine.

## Closing

Autonomy is a spectrum, not a binary. The goal of this setup isn't to remove myself from the project — it's to move the tedious parts up the spectrum (triage, labelling, dependency updates, stale-PR nudges, docs drift) while keeping the parts that benefit from human judgment (scope decisions, design trade-offs, what actually gets merged) firmly with me.

The Mac Mini in my house isn't replacing me. It's freeing up the time I used to spend on janitorial work so I can spend it on the parts of the project that are actually interesting.

If you want to see the workflow files themselves, they live in [`.github/workflows/`](https://github.com/devantler-tech/ksail/tree/main/.github/workflows) in the KSail repo — every `*.md` file in that folder is one of the agentic workflows described here. The compiled `*.lock.yml` files are the GitHub Actions that actually run. The whole system is built on top of [githubnext/agentics](https://github.com/githubnext/agentics), which provides the `gh-aw` CLI and the workflow prompt framework. Clone, adapt, and let me know what you build.
