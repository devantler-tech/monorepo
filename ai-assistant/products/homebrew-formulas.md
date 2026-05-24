# Product card: Homebrew Formulas

**Repo:** `devantler-tech/homebrew-formulas` — the Homebrew tap for devantler-tech tools (Ruby
formulas, e.g. `ksail`). README is a table of formula → description.
**Subdir:** `homebrew-formulas`. **Issues:** enabled → Monthly Activity issue.
**Workflows:** `ci.yaml`, `sync-labels.yaml`, `todos.yaml`. **New coverage** — light touch.

## Before working here
- Read `README.md` and look at the formulas (`Formula/*.rb` or root `*.rb`) and `ci.yaml` to see how
  formulas are validated (typically `brew style` / `brew audit` / install-test).
- **Releases usually bump formulas automatically.** A tool release (e.g. ksail) commonly opens a PR
  here to update the formula's `url`/`version`/`sha256`. **Do NOT hand-edit a formula's version/sha
  to chase a release** — that's the release automation's job; you'd race it and risk a wrong sha.
  Your job is the formula's *correctness and hygiene*, not version bumps.

## Conventions specific to this repo
- **Branch:** `claude/daily-ai-assistant-<short-desc>` off `main`. **Labels:** `automation` + an
  existing area label. **PR title = Conventional Commit.**
- **Validate before any PR:** `brew style ./<formula>.rb` and `brew audit --strict --online <formula>`
  if `brew` is available; otherwise a Ruby syntax check (`ruby -c <formula>.rb`) and a careful read.
  Match whatever `ci.yaml` runs. Never open a PR that would fail the tap's CI.
- **AI-disclosure line** on every artifact. Never run an external contributor's branch.

## Task menu — minimal; usually nothing to do
1. **Triage & label** new unlabelled issues/PRs; one insightful comment on the oldest un-commented
   issue/PR (e.g. an install failure report → investigate the formula).
2. **Formula hygiene** (only clear, low-risk): fix deprecated Homebrew DSL, broken `homepage`/`url`,
   bad `desc`/license, lint/style failures, dead formulas, README table drift vs the actual formulas
   → a draft PR. **Not** speculative version bumps (see above).
3. **CI/workflow health:** keep the tap's own CI green and tidy (pin/align actions, fix broken steps).
4. **Maintain your own open PRs:** fix CI you caused, resolve conflicts.

## Monthly Activity issue
Maintain ONE open issue `[AI Assistant] Monthly Activity {YYYY}-{MM}` (label `automation`), updated
only when you acted. **Suggested maintainer actions** first (+ links), then **Run history**
reverse-chronological. Fresh issue each month.
