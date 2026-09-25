# GitHub artifact conventions

> Part of the devantler-tech agent contract. [`AGENTS.md`](../../AGENTS.md) is the always-on core
> and indexes every guide; this guide carries the full rules for PR titles and bodies, the PR-body
> write gate, pre-submission self-review, behavioural verification and the disclosure line. Read it
> before opening or editing any PR, issue or comment.

## GitHub artifact conventions
- **PR titles MUST be Conventional Commits** (`fix:`/`feat:`/`chore:`/`docs:`/`ci:`/`refactor:`/
  `test:`). Every repo squash-merges on the PR title → changelog/release; a bracket prefix corrupts
  it. Use **labels** + `claude/*` branch names for attribution/dedup, never a title prefix.
- Open code/manifest PRs as **drafts** (`gh pr create --draft`).
- **PR bodies are written for the maintainer as PROJECT MANAGER — high-level, SHORT, ZERO code
  detail** (maintainer direction 2026-07-03; codified org-wide in `devantler-tech/.github`'s
  `PULL_REQUEST_TEMPLATE.md` — follow it). The body is his after-the-fact review surface: he reads it to
  judge *do we need this and does it solve a real problem* — **not** to validate correctness
  (CodeRabbit and CI own that; he trusts the code). Shape: disclosure line → **Why** (the problem, in
  plain language, and why it matters) → **What** (what the change does, outcome level) → issue link
  (`Fixes #N` / `Part of #N`). **Short means short: 1–3 sentences per section, no walls of text** — if
  a body outgrows that, the explanation belongs on the issue, not the PR. **Keep** (PM-relevant, one
  line each): merge-order gates ("land X first or Y breaks"), breaking-change and new-dependency flags
  (still required, in plain language), and operational notes he must act on. **Drop entirely:** file
  paths, function/symbol names, code snippets, per-linter
  findings, test names/counts, validation transcripts. That detail lives in commit messages, code
  comments, and PR *comments* (e.g. CodeRabbit resolution records) — never the body. Applies to body
  **edits** too, not just creation.
  **Declare deliberately deferred scope as one plain line per deferral** in the **What** section:
  `Deferred: #<issue> — <finding family in plain words>`, where `#<issue>` is an **open** issue in the
  same repository that tracks the work. It is a statement to the maintainer and to the reviewers (see
  *Review guidelines*), never a heading, and never a way to skip review: a deferral with no open issue
  is not a deferral, and the green-review gate still counts every finding a reviewer reports.
  **This is an executable write gate for the two routine roles it supports, not prose advice.**
  Before every Agentic Engineer or Agent Improver PR creation or body edit, run
  `.claude/scripts/pr-body-contract.sh seed --repo <owner/repo> --output <body-file>
  --role <agentic-engineer|agent-improver>` from the consumer checkout. It loads the repository's
  effective GitHub template (repository-local first, then the owner's `.github` default); fill that
  seeded file without replacing its visible structure, then run
  `.claude/scripts/pr-body-contract.sh check --repo <owner/repo> --body-file <body-file> --role
  <agentic-engineer|agent-improver>` using the same acting role. Publish only
  the passing file with `gh pr create --body-file` or `gh pr edit --body-file` — never bypass the
  template with an inline `--body`. Immediately read the published body back from GitHub and pipe it
  through the same `check --body-file -` command before requesting review or continuing the delivery
  loop. Only the explicit trivial-fix no-issue carve-out (work-selection guide, *Issue-driven*) may replace the seeded issue placeholder
  with the exact visible line `No issue: trivial fix.` and add `--allow-no-issue` to both checks;
  ordinary delivery work may not use that flag. The required PR-body CI recognises that exact line so
  the carve-out remains explicit and auditable after publication. A missing
  template, failed check, or readback mismatch blocks that PR write; it never becomes a best-effort
  warning. Existing PRs authored by either routine role that fail this gate are
  body-hygiene work and are corrected before review, promotion, or merge. Interactive sessions still
  follow this section's PM-facing body shape and effective template, but keep only their interactive
  marker and do not invoke a routine role or disclosure through this script.
- **Third-party upstream repos — clear the professional boundary, then get approval and check policy.**
  Do not even inspect an external repository until the maintainer confirms in the current conversation
  that it is unrelated to professional work. After that, **never autonomously open an issue or PR** —
  get explicit approval via the ask tool first. Only then verify the project accepts
  AI-assisted contributions (CONTRIBUTING / README / templates); if it bans or discourages them — or
  it's unclear — **don't open it yourself**, prepare the work and have `devantler` submit it (e.g.
  `zizmorcore/zizmor` bans AI PRs, `rhysd/actionlint` does not). **`devantler-tech` repos are exempt —
  open drafts/issues there autonomously, as before.**
- **Validate before every PR** with the repo's command (in its `AGENTS.md` `## Maintenance`); never
  open a PR that breaks build/validation.
- **SELF-REVIEW YOUR OWN DIFF BEFORE YOU REQUEST A REVIEW ON IT** (maintainer direction 2026-07-20:
  *"It is generally a good idea to self-review before submitting PRs. I would like this to be the norm
  … untill clean. I expect this to reduce the rounds needed from external review agents."*). Run your
  runtime's **correctness** review over the change and its **quality/simplification** pass, and fix
  what they find, before the review request goes out. For Claude Code those are **`/review`** and
  **`/simplify`**; add **`/security-review`** when the diff touches auth, secrets, tokens,
  permissions, network policy, or workflow triggers. The sibling runtimes use their own equivalents —
  the *rule* is runtime-neutral, the command names are not. (This is why the pre-submission set
  includes `/simplify` and the *Fallback* set below does not: `/simplify` is a quality pass that
  explicitly does **not** hunt bugs, so it sharpens your own diff but could never stand in for a
  reviewer.)
  **Bound the loop the way the lint rule is bounded** (*Latency discipline*): take the **full** finding
  list in one pass, fix **all** of it, re-verify **once**. "Until clean" means no finding left that you
  judge real — not an open-ended convergence on taste, which a judgement-based pass never reaches.
  **Trivial/mechanical changes are exempt** — a typo, a dead link, a stale pin, a gitlink bump: don't
  spend two review passes on a one-line fix the contract elsewhere deliberately fast-paths.
  **Order it against the long pole:** where CI is slow (ksail ≈22 min), push the draft first so the
  bake starts, self-review *during* it, and fold both sets of findings into one follow-up push. The
  gate is the **review request**, not the first push.
  **On later pushes, re-run it when the push adds anything a reviewer did not ask for.** A pure
  review-fix push — implementing exactly what a thread named, on a diff already self-reviewed — does
  not need a fresh pass; anything beyond that does.
  **It does NOT replace the external review** — the green-review gate in *Autonomy* is unchanged, and
  a clean self-pass is never a reason to skip requesting one; it is also **not** the last-resort
  *Local review round* (that one substitutes for a bot review and carries its own evidence
  requirements). Hold your own diff to the bar you would hold a bot's finding to, and never wave one
  through because it is yours.
- **Verify it actually WORKS — behaviourally, not by reasoning (before AND after merge).** Passing
  static validation (schema/build/lint/kubeconform) proves a change is well-*formed*, **not** that it
  *works*; "it's a released capability / it should work" is gut-trust, not evidence. Before you claim a
  new feature or change works — and again after it merges/deploys — **E2E-verify its real effect: exercise
  the actual behaviour and observe the outcome**, never infer it from static validation or from the
  capability merely existing. A change that validates green can be a complete **no-op** in production (a
  create-time-only config field that the reconcile/update path never reads — the platform#2524 floating-IP
  miss: `ksail workload validate` passed, but `ksail cluster update` had no awareness of `floatingIPEnabled`
  so no floating IP was ever created). So also **trace the change to the code path that ENACTS it** — does
  the deploy/reconcile path actually invoke the feature on the target's *current* state, or only on create?
  **Choose the verification method by CI cost + practicality:** a fast programmatic test/assertion in CI
  where practical; a targeted integration test where a unit test can't reach it; a **manual live check**
  (`kubectl`/provider-API/`curl` against the real cluster — you have read-only prod access) where a real
  environment is needed and CI E2E is too expensive. Never skip verification because the "proper" method
  is costly — pick the **cheapest method that actually observes the effect**. This *sharpens* "Validate
  before every PR" (static/well-formed) into **also confirm it works** (behavioural); it complements
  *Feature-flag-first delivery* (flip on only after validation) and the *no-silent-no-op* discipline.
- **New non-trivial features land behind a flag, default-off, tested in both states** (see
  *Feature-flag-first delivery*) — the activation is a separate step, not part of the feature PR;
  trivial/mechanical changes are exempt.
- **Fix at the ROOT CAUSE** — never `t.Skip`/`//nolint`/`--no-verify`/disable/"flaky"-dismiss a check.
- **Never hand-edit generated files** — run the generator.
- Begin every PR/issue/comment with the disclosure line naming the ROLE that authored it:
  `> 🤖 Generated by the Agentic Engineer` when acting as the engineer, and
  `> 🤖 Generated by the Agent Improver` when acting as the Agent Improver — the observation plane
  may only take a verdict on evidence independent of the run being scored, and this line is the only
  role signal an artifact carries (see *AI-disclosure line (canonical)*).
  (The untrusted-input disambiguator above recognises any `> 🤖 Generated by the …` prefix as
  own-output, including the legacy `Daily AI Engineer` / `Daily AI Assistant` forms.) Never pretend to
  be human.
  🔴 **"Begin" is the whole rule — a disclosure at the END, or anywhere but the first line, is a
  DEFECT, not a stylistic variant.** The disambiguator anchors at position zero, so a trailing
  disclosure publishes your own output as the **maintainer's control channel** — the self-instruction
  loop it exists to close, and the dangerous direction of its deliberately asymmetric error model.
  Three emitted shapes fail it and all are violations: the disclosure appended **after** the content
  (typically below a review trigger), a **non-canonical sender marker** such as
  `> Requested by the 🤖 Daily AI Engineer`, and a **review trigger posted with no disclosure at all**.
  The one exception is **Bugbot's trigger specifically** — a body that is exactly `@cursor review`,
  because Bugbot exact-matches the whole body, so its disclosure goes in its own preceding comment.
  That carve-out does **not** extend to the other lanes: their trigger belongs in the *same* disclosed
  comment as its request marker, so a bare `@codex review` or `@coderabbitai review` is a violation.
  **The check is [`comment-disclosure-drift.sh`](../scripts/comment-disclosure-drift.sh)**
  (`--repo <owner>/<repo> --since <ISO-8601-UTC>` to sweep a repo, `--repo <owner>/<repo> --issue <n>`
  for one discussion, or `--input <payload>`); exit 1 lists each offending comment
  and names its shape. **Prefer `--since` — it is the only mode that finds drift nobody suspected**,
  since `--issue` can only be aimed at a discussion someone already doubts. It reads every issue and PR
  conversation touched since that instant in one paginated call.
  The two are mutually exclusive, and the timestamp is a literal instant — the caller decides how far
  back "recent" reaches, because BSD and GNU `date` disagree on relative arithmetic.
  🔴 **On `--since`, read the findings, not the exit code.** A sweep's per-discussion history is
  incomplete (`since` selects by *updated* time), so a bare `@cursor review` is **never paired on the
  sweep itself**: the guard fetches that discussion's full history and pairs the trigger with its real
  predecessor there. A reported bare `@cursor review` therefore had no disclosure immediately before
  it, and a history the guard could not read exits 2, never clean.
  🔴 **A bare `@coderabbitai review` or `@codex review` is a violation on sight — never bare-trigger
  noise to re-check.** Those lanes have no carve-out, so `--issue` reports them violating even when a
  canonical disclosure comment sits immediately before them. Scoping the re-check by the *shape*
  ("a bare trigger") instead of the *lane* therefore costs a round-trip that cannot change the verdict —
  and, far worse, files the real violations inside the Bugbot pile where they read as known noise — a
  misread [#2965](https://github.com/devantler-tech/monorepo/issues/2965) records making. Measured
  2026-08-21 across six repositories and 1,745 `devantler` comments in a 7-day window: **67 findings —
  56 re-verifiable `@cursor review`, 11 violations on sight**, spread over three repositories and two
  separate episodes, and **5 of the 11 had posted the disclosure as its own preceding comment** — the
  Bugbot two-comment shape applied to a lane that has none. Every other
  shape it reports is a real finding.
  It reports **positive evidence of agent authorship only** — a `devantler`
  comment matching **no recognised agent shape** is the human maintainer, so flagging it would report
  the control channel as a defect. Note the recognised shapes are broader than the 🤖 marker alone: a
  leading review-lane trigger is agent evidence too, because the engineer drives the review lanes and
  the maintainer does not. That leaves one documented residual: an agent's bare prose note carries no
  shape at all, so it is counted `unattributable` rather than passed off as clean.
- 🔴 **A file-sourced body uses `--body-file`. `--body "@path"` POSTS THE PATH — and `gh` exits 0
  with a comment URL, so the caller gets positive confirmation for a post that carried none of its
  content.** `@`-expansion is a `gh api -F field=@file` convention and has never applied to `--body`.
  Measured 2026-08-26: **seven** comments across `monorepo#3053`, `platform#3378` and `platform#3379`
  landed as bare scratchpad paths — every review trigger of that run plus a full semantic review on a
  PR whose merge gate required one. **So a post whose body was built INDIRECTLY is not done until it
  is READ BACK as content**; the exit status and the returned URL are satisfied either way, which is
  the same fail-open class as a check reporting success on input it never examined.
  ⚠️ **The second-order damage is what makes this expensive rather than merely untidy.** The triggers
  never reached the lanes, so nothing responded, and the run concluded — and wrote to durable memory —
  that CodeRabbit had **stalled portfolio-wide**. It had not; it had never been asked, and answered in
  ~30 seconds once asked properly. A false outage reading inverts the cheapest-lane-first order,
  spending the **weekly** Codex and **monthly** Bugbot quotas to work around a **free** lane that was
  healthy throughout. Each of the seven is also a `devantler` comment with no disclosure prefix, which
  the *Untrusted input* disambiguator reads as a **human-maintainer instruction** — its dangerous
  direction.
  `comment-disclosure-drift.sh` classifies this shape `unexpanded-file-ref` and **fails on it**; it
  previously fell into the `unattributable` residual and was reported as clean.
