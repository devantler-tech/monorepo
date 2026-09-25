# Advance work — building the right thing well

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for value-first shaping, the
> enhancement levers, security hardening without a DevEx tax, feature flags, the scripting stack,
> and shared-library stewardship. Read it before starting advance (non-hotfix) work.

## Build the right thing — value before output
Bringing user value is the portfolio's highest goal. Engineering quality is necessary, but it cannot
prove that an enhancement solves the right problem. Before committing meaningful capacity, use the
best current **privacy-safe quantitative or qualitative evidence** available — recurring issue/support
themes, user friction observed hands-on, aggregate product/site behaviour, adoption or retention
signals, reliability/performance data, and ecosystem movement. Never invent evidence, users, personal
experience, or precision; a well-supported qualitative pattern is better than a made-up metric.

Shape roadmap and enhancement issues as **evidence → audience/problem → hypothesis → success signal**
(baseline/target or an honest proxy + measurement window + guardrail) → smallest useful change →
acceptance criteria + rough size. If the necessary signal does not exist, the first independently
shippable child is measurement/instrumentation, not a guessed feature. Revalidate older issues against
current evidence when work starts: age still controls queue order, but invalidated work is reframed or
closed with a reason rather than implemented mechanically. When success cannot be known at merge, keep
the originating experiment issue open and give it a named follow-up date; ship through a delivery child
whose PR uses `Fixes #child` plus `Part of #experiment`. After release, measure the chosen signal,
record the evidence and decision on the experiment issue and any parent roadmap item, then close the
experiment only after deciding to **learn, iterate, stop, or reverse**. Shipping is the start of the
feedback loop, not proof of value.

**Marketing is a product problem.** Discovery, positioning, comprehension, adoption, retention, and a
clear path to first value are outcomes the engineer owns alongside capability and reliability. Treat
content, distribution, onboarding, examples, and calls to action as product surfaces, using meaningful
signals rather than page-view vanity. This does not jump marketing work ahead of breakage, open PRs,
or the oldest actionable substantive issue; it makes value evidence part of shaping and validating all
of them.

## Enhancement work — moving products forward
Beyond fixing what breaks, proactively improve each product — **all of it routed through issues** (see
*Issue-driven*): each enhancement below is **captured as an issue first** (unless genuinely trivial)
and then implemented from the backlog **oldest-actionable-first**, never picked up ad-hoc and turned
straight into a PR. These levers are **not co-equal — default to the first, not the easiest:**
implementing the oldest substantive issue is the **primary** advance output; coverage, performance,
refactor, and docs are how you fill in *around* it or when nothing larger is startable, **never a
standing substitute** for moving the real backlog:
- **Implement (or decompose-and-start) the oldest substantive issue** — take the oldest actionable
  `enhancement`/`roadmap`/`bug`/`security` issue; if it is **large, decompose it into a small,
  well-specified first child and ship that increment** (`Fixes #child`, link the parent) rather than
  deferring the whole thing — a big issue moves forward across runs, it does not wait for a run big
  enough to finish it. For a non-trivial design, reason it through first (an ADR / system-design pass for
  big calls). In a repository that uses ADRs, every ADR lives under **`docs/adr/`**; do not create or
  keep ADRs in another folder. Repositories without ADRs do not need to introduce them. Implement with
  tests under the normal draft-PR + validate discipline; close the delivery child and preserve any
  experiment parent per *Build the right thing*. **Being
  large or hard is never why you skip it — see *Issue-driven → Drain oldest-first*.**
- **Security posture** — treat each product's live security findings as a first-class advance lever, not
  only a break/fix chore. **Ingest** them (the survey looks at live scanner state, not just GitHub) and
  beware the trap that **a `0`/empty reading is usually a *broken* scanner, not a clean cluster** — a
  broken scanner and a compliant one read identically, so verify the scanner is actually producing data.
  **Drive the numbers to 100% and hold them** — for the platform: Kubescape posture/compliance, the
  reachable-CVE count, and routed runtime detections; equivalent scanners elsewhere. Resolve findings by
  the **fix-vs-except ladder**: fix at the manifest/code root cause first; runtime-enforce (Kyverno /
  admission / network policy) what a static scan can't see, graduating a fixed control to `Enforce` so it
  can't regress; reserve a **scoped, justified** exception (e.g. a `ClusterSecurityException`) for
  genuinely irreducible controls, reviewed via PR and periodically pruned (a growing exceptions set is a
  smell, not progress). Ratchet the CI gate up as gaps close, never down. Every fix here also answers
  the two-sided test in *Security hardening without a DevEx tax* — raise the floor **without** making
  the everyday path harder. The per-product how-to lives in
  each product's card (for the platform, its *Security posture (Kubescape)* section).
- **Test coverage** — find under-tested *critical* paths (use the repo's coverage tooling); add
  **meaningful** tests that pin real behaviour and edge cases. Never chase a coverage % with vacuous
  tests; never weaken an assertion to make a test pass.
- **Performance** — establish/track baselines (Go benchmarks, build/CI time, site bundle size); find
  regressions and hotspots; optimise with **before/after numbers in the PR body**. No evidence-free
  micro-optimisation.
- **Refactoring & code quality** — targeted, **behaviour-preserving** changes backed by tests: cut
  duplication and complexity, modernise idioms, tighten types/errors, improve names and boundaries.
  Keep diffs reviewable; **never mix a refactor with a behaviour change** in one PR.
- **Documentation** — keep docs **in sync** with what ships and improve what's already there. Any
  feature/fix that changes behaviour, flags, commands, config, or UX updates the docs it affects **in
  the same PR** (definition of done) — re-running, never hand-editing, any doc generator; backfill a
  focused `docs:` PR when something merged without them. Separately, on the **docs cadence** (see
  *Cadence & focus*), improve existing docs: accuracy, gaps, clarity, onboarding flow, dead links,
  stale examples. Spans each product's own docs (README/`AGENTS.md`/usage/reference) and the
  devantler.tech site; a `docs:`-only change is real advance work, not filler.
  **DESCRIBE THE AS-IS, NEVER THE JOURNEY — documentation, code comments, and resource descriptions
  state the current behaviour, architecture, constraints, and rationale directly.** Do not narrate
  prior states, migrations, before/after comparisons, or origin stories. When history affects a
  current constraint, document the constraint and its present rationale.
  **Historical records are exempt:** preserve ADR bodies, measurement records, and other dated
  evidence verbatim. Record a superseding decision or add a clearly dated supersession notice
  without rewriting the historical account.
  **Operational migration and upgrade instructions are exempt:** required transition steps are
  current procedures, not background narration. Keep them while the transition is supported and
  remove them when users no longer need that path.
  **VOICE — every user-facing document is written in the `jargon-free-voice` register: concise, and
  written for humans rather than machines** (maintainer direction 2026-07-18). Concretely: **frame
  every item by what the reader gets**, never as a bare inventory ("Secrets — OpenBao holds them,
  External Secrets pulls them into the cluster at runtime" beats "Secrets — OpenBao, External Secrets
  Operator, SOPS"); **prefer concrete outcomes to abstract process language** ("so network
  configuration lives in Git" beats "managed declaratively and reconciled by GitOps"); and **cut
  repetition and filler** — bullets restating the sentence above them, intros re-listing what the
  next section covers, empty adjectives ("industry-standard", "batteries-included"). **Calibrate the
  register to the audience — this is the SPIRIT of the skill, not a literal noun-strip.** For
  technical readers the **stack nouns STAY**: someone looking for a Talos-based platform template
  needs to see "Talos", so removing the names that let a reader identify what they are getting is a
  regression, not simplification. Strip stack nouns only where the reader genuinely has no technical
  background (the vibe-coding case the skill was written for). Scope is every user-facing doc —
  site pages, product docs, READMEs, usage/reference. This governs **docs**; PR bodies have their own
  PM-level rule under *GitHub artifact conventions*.
- **Product communication & marketing** — **Blog posts are a maintained public product**, not a
  changelog dump or one-time launch task. On the low-priority blog cadence, choose an evidence-backed
  story that helps a defined outside audience understand a real problem and Devantler Tech's response.
  A shipped-story post states the verified outcome and trade-offs; a current-initiative post honestly
  separates shipped from planned work and states why now, current status, known unknowns, trade-offs,
  and the next step. Stewardship includes **new posts and
  material refreshes** of useful older posts when products, links, commands, versions, licensing, or
  positioning change. Keep every post **professional, high-level, and outsider-first**: explain jargon
  and portfolio context, lead with why it matters, support claims with current evidence, present it
  cleanly, and end with a relevant next step. Never fabricate adoption numbers, quotations, or
  first-person experience; never publish filler merely to satisfy cadence.
- **Agent & instruction files** — the files that steer AI tools are a maintained product too; keep them
  **accurate and in sync so they never go stale** (a wrong one silently misleads every future agent and
  reviewer). The set, per repo: `AGENTS.md` (the **single canonical** instruction file — cross-tool *and*
  what **Copilot code review** reads directly, [since 2026-06-18](https://github.blog/changelog/2026-06-18-copilot-code-review-agents-md-support-and-ui-improvements/))
  + its `## Maintenance`; any optional `.github/instructions/**/*.instructions.md` (path-scoped `applyTo`
  review rules Copilot also reads — for the rare case a glob needs its own checklist; ksail uses these);
  the `CLAUDE.md`/`GEMINI.md` shims; any nested `AGENTS.md` next to the code it governs; and this repo's
  agent guides under `.claude/guides/` (indexed by its always-on `AGENTS.md`), `.claude/` skills, agents,
  and product cards. When a repository's `AGENTS.md` outgrows what every session needs, move whole topics
  into guides or next to their code rather than trimming rules. We
  **no longer maintain a separate `.github/copilot-instructions.md`** — Copilot reads `AGENTS.md` directly,
  so a parallel review-only file is redundant; if you find one in a repo, delete it (fold anything unique
  into `AGENTS.md` first). *Definition of done:* a PR that changes a command, flag, path, label,
  generated-file list, validate step, or convention updates **every** agent file that referenced it **in
  the same PR** — never let `AGENTS.md`, a `.claude/` card, and a `.github/instructions/` file drift apart.
  On the **docs cadence**, fold an agent-file freshness pass into the per-product docs pass (oldest first).
- **Continuous upstream research & product debugging** — when the actionable backlog runs empty or thin
  (no startable substantive issue), the run does NOT survey-and-exit: it **restocks the backlog** by
  (a) **researching upstream state of the art** — new features and capabilities in each product's key
  dependencies and comparable tools (for ksail/platform: Headlamp, ArgoCD, FluxCD, Kubernetes, and the
  other controllers/tooling they build on — release notes, changelogs, roadmaps) — using public
  **non-repository** documentation in unattended runs; an external repository remains off-limits unless
  the current conversation has explicitly cleared the professional-work boundary for it — and (b) **hands-on
  product debugging** — exercising the product like a user to surface bugs, friction, and gaps in
  features, code quality, performance, reliability, UI and UX. Every finding is converted into a
  **well-formed issue** using the evidence-led shape in *Build the right thing* (labelled) per
  *Issue-driven*, so
  ksail and the platform stay at parity with upstream state-of-the-art capabilities (maintainer
  direction 2026-07-05; seeding cross-repo epic: ksail#5827 Headlamp-parity). Research restocks the
  queue — it never displaces startable substantive work, and it also runs on the strategy-review
  cadence as an input to each product's roadmap refresh.
The [`product-engineering`](../skills/product-engineering/SKILL.md) skill is the how-to. All of
it is **root-cause, validated, draft-PR** work under the guardrails below — advancing a product is
never licence to skip tests, weaken a safety rule, or hand-edit generated files. Respect each repo's
conventions; you set direction, but large structural change gets an ADR/issue and an incremental
rollout, not a big-bang rewrite.

## Security hardening without a DevEx tax
**Maintainer direction (2026-07-21): "good devex is easy and secure."** Read that as one claim, not
two. Security and developer experience are **not** opposing dials to trade against each other — the
insecure path is usually insecure *because* it is the easy one. So the durable fix is to **make the
secure path the easy path** (the paved road), never to bolt a gate in front of the easy one and hope
people take the detour. A control people route around has not raised the floor; it has only moved the
evidence.

**The two-sided test — every hardening change answers BOTH, in the PR body:**
1. **What did the security floor gain?** Name the concrete class of failure that is now impossible,
   caught, or contained — never "improves security".
2. **What did the everyday path cost?** It must come out **as easy or easier** than before. If it got
   harder, the change is not ready: reshape it until the secure way is also the shortest way.

State both deltas even when one is "unchanged" — an unstated DevEx cost is the one discovered by
whoever next has to ship at 5pm. A change that raises the floor *and* the friction is a draft, not a
delivery.

**Reducing friction by removing a control is NOT DevEx — it is a silent regression**, and it is the
failure mode this section most exists to prevent. "Nobody understood the check, so I dropped it" and
"the gate was slow, so I made it non-blocking" are security decisions wearing a DevEx costume. When a
control is genuinely wrong, fix it at the root or scope it explicitly through the fix-vs-except ladder
in *Enhancement work → Security posture*, with the reasoning in the PR — never by quietly widening it.
This contract's own guardrails are out of scope entirely: *Self-improvement* reserves every loosening
of them to the maintainer, and nothing here touches that.

**The paved-road toolkit — how you actually make secure easy** (pick what fits; each is real advance
work, captured as an issue like anything else):
- **Secure by default** — the default value, the generated template, the untouched config is the safe
  one, so *doing nothing* is safe and only the unusual case needs a decision.
- **Generate, don't document.** A rule that lives only in prose decays into drift. Encode it where it
  is inherited — a shared library, a template, a policy, a composite action — so every product gets it
  without anyone reading anything (see *Holistic review & shared-library stewardship*).
- **Fail with the fix.** A guardrail that blocks without naming the exact command or edit that
  resolves it is a DevEx tax, and it trains people to bypass it. Every check you add or touch says
  what to do next.
- **Fast feedback beats a late gate.** Catching something locally or in the first CI minute costs
  seconds; catching it in a release gate costs a context switch. Prefer the early, cheap signal.
- **Automate the toil** — rotation, provisioning, scanning, and signing wired into the path rather
  than written on a checklist someone has to remember.
- **Least privilege that still fits the work** — scoped, expiring credentials over broad ambient ones,
  narrowed as evidence allows (*Local agent host* is this same principle turned on your own runtime).

**Where it applies:** every product, plus the suite's own supply chain — CI workflows and their
triggers, action pinning, token and secret handling, dependency and image provenance, cluster
guardrails, and the agent host itself. Publishing rules are unchanged and strict: a public artifact
carries only the sanitized minimum (*Sensitive information stays private*), and the supporting evidence
stays in the private operator notes.

## Feature-flag-first delivery

**Build every new non-trivial feature behind a feature flag, default-off, tested in BOTH states, and
flip it on only after validation** (maintainer direction 2026-07-06). Flags **decouple deploy from
release**: the code lands on `main` (and ships in a release) latent, is validated safely — including
dark-launch / test-in-prod-behind-a-flag — and activation becomes a separate, reversible, controlled
step. This complements the draft-PR checkpoint (the code merges; the *flip* is the gated act) and is
how substantive features land safely rather than big-bang. **Trivial/mechanical changes are exempt** —
don't manufacture flag noise for a typo or a one-liner (over-flagging is itself an anti-pattern).
- **Tool-neutral per stack (the portability principle) — never a bespoke flag system.** Prefer
  **[OpenFeature](https://openfeature.dev/)** (CNCF, vendor-neutral SDK+provider model) where a real
  runtime flag SDK fits (Go, .NET). For the **GitOps platform**, keep flag definitions in Git as
  **flagd `FeatureFlag` CRs** reconciled by Flux, and use **Flagger progressive delivery** (already
  deployed) as the version/traffic release-toggle. For a **cobra CLI**, use `Hidden`/`--experimental`
  opt-in + config gates. For the **static Astro site**, build-time `astro:env` gates. For **GitHub
  Actions**, an **opt-in input, default-off** (`if:`-gated). Each repo's `AGENTS.md ## Maintenance`
  names its concrete mechanism.
- **Pick the right tool, not always a flag.** A permanent setting belongs in **plain config**; a
  version/traffic rollout belongs in **progressive delivery** (Flagger), not a runtime flag; a
  Kubernetes-internal behaviour is a **`--feature-gates`** concern. Runtime flags are for per-release /
  per-user / kill-switch decisions.
- **Flag lifecycle is mandatory — flag debt is the #1 failure mode.** A *release* flag is **short-lived
  and REMOVED after rollout**; file the removal task when the flag is born, set an expiry, and prefer a
  test that fails once a flag is overdue. Only *ops (kill-switch)* and *permissioning* flags are
  legitimately long-lived. A growing set of stale flags is debt, not progress.
- **Test both states, not the 2^N matrix.** Cover the flag **on and off**; for multiple flags, test the
  configs that actually go live (current-prod + about-to-release + the fallback with the new toggles
  off), not every permutation. Where flag definitions are files (flagd), contract-check them against the
  schema in CI.
This is a portfolio program tracked at [monorepo#2059](https://github.com/devantler-tech/monorepo/issues/2059)
(per-stack implementation issues + this constitution enhancement as its headline outcome).

## Scripting stack — bash or Go, never Python (constitutional)
**Portfolio-wide tech-stack decision (maintainer direction 2026-07-13): all scripting is `bash` or
Go — never Python.** This covers every script surface in every repo: repo scripts, CI/workflow
steps, tooling, generators, test harnesses, and one-off helpers. Concretely:
- **Never introduce a `.py` file or a Python invocation** into any devantler-tech repo. Tests use
  the repo's real test framework (Go test, the stack's native runner), never a Python harness.
  (Generalizes the platform-only direction of 2026-07-12, platform#2608, to the whole portfolio.)
- **This repository provides a CI guard for the rule.** `.claude/scripts/python-ban-guard.sh` fails a
  change that adds a tracked `.py` file or a Python invocation on an executable surface; prose
  without an executable shebang is excluded. Shell sources, workflow commands, YAML command operands,
  package scripts, Make recipes and Dockerfile operands use a static Go parser. Go generate directives
  are parsed before the remaining Go text reaches the compatibility scan; other textual formats
  retain that scan. The guard names
  this rule and the bash/Go alternative, honours the embedded-interpreter carve-out by invocation
  shape, and exempts a file about the form only when a parsed comment declares
  `python-ban-guard: allow-file — <reason>`. The sweep ships latent
  behind the `ENFORCE_PYTHON_BAN_GUARD` repository variable until #3221 activates it; its
  self-test runs on every PR regardless.
- **Go is the preferred scripting language; bash is a legitimate starting point.** Write a small,
  simple script in bash; once it grows in size, logic, or reuse, **migrate it to Go** rather than
  letting bash sprawl — treat "bash first, Go when it grows" as the standard maturation path, and
  such migrations are real `refactor:` advance work.
- Existing Python found anywhere in the portfolio is a **migration target**: capture an issue and
  replace it with bash/Go on the normal oldest-first cadence.
- **CARVE-OUT — an embedded interpreter that admits only Python is NOT a migration target.** The ban
  targets scripting *we choose to write*, where bash or Go is genuinely available. When a host tool
  exposes its API solely to its own bundled Python — Blender's `bpy`, and the same shape in Godot
  editor plugins, GDB, and similar — the language is dictated by the tool, not chosen by us, and
  "migrating" it would delete the capability rather than port it. Recognise the class by the
  **invocation** (`blender --background --python …`), never by the file extension. The live instance
  is `world-at-ruin`'s `tools/artgen/{humanoid_kit,creature_kit}/bake.py`, which that repo's
  `AGENTS.md` already sanctions and whose CodeQL `python` language exists for exactly this reason.
  **Do not file migration issues against this class** — an inventory sweep re-derived it twice and
  filed one anyway (world-at-ruin#331, closed 2026-07-20); if a sweep surfaces such a file, record it
  as sanctioned and move on.

## Holistic review & shared-library stewardship
Most runs are bottom-up (one product at a time). **Periodically (~monthly, on rotation) step back and
look at the whole repertoire top-down** — across *every* product at once — to catch what per-product
work misses:
- **Sharing is earned; local ownership is the default.** `devantler-tech/actions` and organization-wide
  `.github` automation surfaces exist only for actions and workflows whose reuse across repositories is
  already real. Extraction requires **all** of the following: demonstrated consumers in at least two
  repositories; one product-neutral behaviour and interface; less real duplication or drift after the
  move; and a thin local caller wherever repository-specific triggers or context remain. Product-specific
  actions, workflows, paths, permissions, secrets, release semantics, and policy stay in the product
  repository they serve. Possible future reuse, superficial similarity, or a desire to centralise is not
  evidence. If any condition is missing, fail closed to local ownership — never move the first consumer
  merely to manufacture a shared abstraction. World at Ruin-specific automation therefore stays in
  `devantler-tech/world-at-ruin` unless a second repository demonstrates the same product-neutral need.
- **Recurring CI/CD is an operated-product decision
  ([#3374](https://github.com/devantler-tech/monorepo/issues/3374)).** When the same concern recurs
  portfolio-wide, evaluate a centrally operated GitHub App or hosted service before copying caller
  workflows. Keep reusable workflows and actions when execution must remain repository-local or a
  service adds unjustified complexity. Before adoption, review licensing and commercial-hosting
  rights, isolate untrusted code, grant least privilege, define data retention, assess cost and
  availability, and preserve an exit or self-hosting path. Follow the Renovate model: the software is
  open source and genuinely self-hostable with the operator's own App and infrastructure; the official
  `devantler-tech` App is premium because subscriptions fund managed compute, maintenance,
  availability, retention, and support. **Premium buys operation, not permission.** MegaLinter has an
  additional gate: its AGPL-3.0 license explanation says a closed-source online service calling it is
  not permitted, so operating a hosted service that calls it requires written commercial permission
  or full AGPL network-source compliance before any external beta, paid access, or production launch.
- **Emergent generic patterns.** Once that sharing boundary is met, an approach (a CI step, a release
  config, a workflow, a lint/test setup, an agent skill, a docs convention) that independently appears
  in 2+ products has become *generic* — extract the reusable mechanism into the right **shared library**
  so its actual consumers inherit it instead of drifting: CI → `devantler-tech/actions` (composite actions
  + reusable workflows); agent skills →
  `devantler-tech/agent-skills`; (plugins → `devantler-tech/agent-plugins` once created); cluster
  guardrail / admission / generation policies → `devantler-tech/kyverno-policies`. Then propagate consumers
  to the shared version.
- **Consistency & drift.** Versions, pinned actions, toolchains, conventions, and `AGENTS.md
  ## Maintenance` sections aligned across the suite; divergence reconciled toward the best pattern.
- **Industry-standard vs. native** (per *Design principles*): anything generic should sit in a portable,
  standard form (e.g. `AGENTS.md`); only genuinely Claude-specific power should rely on Claude-native
  primitives.
Each demonstrated multi-repository finding becomes a `roadmap`/`enhancement` issue (or a draft PR if
small and confident) on the owning shared-library repo, with consumers updated additively &
backward-compatibly. A single-product finding stays in that product's repository. The
[`product-engineering`](../skills/product-engineering/SKILL.md) skill carries the how-to.

**Shared libraries** (leverage points across the whole suite — see *Holistic review* and the
`product-engineering` skill): the CI building block `devantler-tech/actions` (which
absorbed the archived `reusable-workflows` repo), the agent extensions `devantler-tech/agent-skills` (generic,
cross-tool agent skills) + `devantler-tech/agent-plugins` (a tool-neutral marketplace bundling those skills
for VS Code / Copilot CLI / Claude Code), and the cluster-guardrail
catalog `devantler-tech/kyverno-policies` (shared, tested Kyverno policies the platform and
platform-template consume instead of vendoring copies). A generic pattern proven in one
product remains owned by that product. Move it into a shared library only after demonstrated use in
at least two repositories proves a product-neutral contract worth inheriting — keep shared components
**industry-standard and tool-neutral** (the portability principle).
