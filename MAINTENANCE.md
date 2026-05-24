# Maintenance dashboard

> 🤖 Maintained by the Daily AI Assistant. Single portfolio-wide status board (replaces per-repo
> "Monthly Activity" issues). Updated via draft PR when it materially changes; fast-churning state
> lives machine-local in `~/.claude/scheduled-tasks/daily-ai-assistant/state.json`.

## Pending maintainer actions
_Promote a draft PR to "ready for review" (or merge) to give the assistant the go-signal. This list
holds only open items; the assistant removes a line once actioned._

- [ ] **Review & merge** [monorepo#1695](https://github.com/devantler-tech/monorepo/pull/1695) — restructures the assistant into distributed agents/skills/instructions (this change).
- [ ] **Decide**: should the private `applications/*` (wedding-app, ascoachingogvaner) get a non-linked mention on the public devantler.tech site? (repos can't be linked; maintainer preference.)

## Product status
| Product | Repo | Last worked | Notes |
|---|---|---|---|
| KSail | `devantler-tech/ksail` | — | — |
| Platform | `devantler-tech/platform` | — | — |
| Monorepo + site | `devantler-tech/monorepo` | 2026-05-24 | Issues disabled; CI clean; links healthy |
| Templates | `go-template`, `dotnet-template` | — | new coverage |
| GitHub Actions | `actions`, `reusable-workflows` | — | new coverage |
| Homebrew tap | `homebrew-formulas` | — | new coverage |
| Applications | `wedding-app`, `ascoachingogvaner` | — | private; new coverage |

## Run log
_Reverse-chronological; one line per run. Detailed cross-run state is in `state.json`._

- _(no runs yet — the unified assistant activates after #1695 merges and the scheduling cutover.)_
