# Daily AI Assistant

One local Claude Code routine that maintains **every devantler-tech product** from this monorepo.
It replaces four separate scheduled routines — `ksail-ai-assistant`, `platform-ai-assistant`,
`monorepo-ai-assistant`, and `monthly-strategy` — with a single daily orchestrator that surveys the
whole portfolio each run and spends its budget on the highest-value work, wherever it is.

## How it's wired

```
ai-assistant/                         ← version-controlled here, in the monorepo
├── brain.md                          ← the daily routine: pre-flight → survey → select → act → report
├── conventions.md                    ← shared rules for every product (git safety, PR/commit, autonomy, untrusted input)
├── products/                         ← one card per product (loaded on demand when that product is selected)
│   ├── ksail.md                      ← + the monthly KSail "Monthly Strategy" task
│   ├── platform.md
│   ├── monorepo.md                   ← the monorepo repo + the devantler.tech docs site (Issues disabled here)
│   ├── templates.md                  ← go-template + dotnet-template
│   ├── github-actions.md             ← actions + reusable-workflows
│   ├── homebrew-formulas.md
│   └── applications.md               ← wedding-app + ascoachingogvaner (private tenants)
└── README.md                         ← this file

~/.claude/scheduled-tasks/daily-ai-assistant/
├── SKILL.md                          ← thin loader: "read <monorepo>/ai-assistant/brain.md and follow it"
└── state.json                        ← cross-run orchestration memory (machine-local, NOT version-controlled)
```

- The **scheduled task** (`daily-ai-assistant`) runs on a recurring schedule (twice daily — 07:00 &
  19:00 local — by default). Its `SKILL.md` is a thin loader that
  points at `brain.md` here, so the definition is reviewable, survives a machine reinstall, and the
  assistant can improve its own definition via ordinary draft PRs against the monorepo.
- The assistant runs from the **primary monorepo checkout** `~/git-personal/monorepo` (stays on
  `main`, all submodules present in-place). It is **not** the interactive parallel-session clone at
  `~/monorepo`, and it never runs from a `.claude/worktrees/...` worktree.
- **Memory:** durable per-product activity lives in each repo's **Monthly Activity issue** (where
  Issues are enabled); the monorepo has Issues disabled so its log + caches live in `state.json`.
  Cross-product orchestration memory (rotation cursor, per-product last-worked, CI/link caches) also
  lives in `state.json` — kept out of git so it doesn't create PR noise or cross-clone conflicts.

## Operating principles (full detail in `conventions.md`)

- **Never merge** (humans decide) — except driving *trusted-author* PRs to merge where a card says
  so (KSail). Never merge external-contributor PRs.
- **Draft PR is the checkpoint:** act on judgement, ship changes as draft PRs; the maintainer's
  promotion to "ready for review" is the go-signal.
- **Validate before every PR** with the product's command; **fix at the root cause** — never bypass
  a check. **Never run untrusted (external) PR code.**
- **Quality over quantity:** a quiet, do-nothing-but-report run is a good run.

## Editing this

Change `brain.md` / `conventions.md` / a product card like any other file and open a draft PR. To add
a new product, add a `products/<name>.md` card and a row to the table in `brain.md` §1. The
`~/.claude/.../SKILL.md` loader rarely needs changing (it just points here).
