# Maintenance dashboard

> 🤖 Maintained by the Daily AI Assistant. Single portfolio-wide status board (replaces per-repo
> "Monthly Activity" issues). Updated via draft PR when it materially changes; fast-churning state
> lives machine-local in `~/.claude/scheduled-tasks/daily-ai-assistant/state.json`.

## Pending maintainer actions
_Promote a draft PR to "ready for review" (or merge) to give the assistant the go-signal. This list
holds only open items; the assistant removes a line once actioned._

- [ ] **Decide**: should the private `applications/*` (wedding-app, ascoachingogvaner) get a non-linked mention on the public devantler.tech site? (repos can't be linked; maintainer preference.)

## Known issues (assistant to investigate)
- **`TODOs` workflow fails with `startup_failure`** on every push to `main` across **platform, go-template, dotnet-template, monorepo, homebrew-tap** (but **succeeds on ksail**). Each is a thin caller of `reusable-workflows/.github/workflows/scan-for-todo-comments.yaml@v3.1.4`; GitHub reports a "workflow file issue". ksail's caller is near-identical, so the cause is likely a repo/org-level Actions, secret, or permissions difference rather than the caller YAML. No functional impact beyond a red TODO-scanner check. Root cause not yet pinned — flagged for a follow-up run.

## Product status
| Product | Repo | Last worked | Notes |
|---|---|---|---|
| KSail | `devantler-tech/ksail` | — | Maintainer actively iterating CI: #4864 (fix Calico v3.32 + require-all-checks gate) is red on its own required check; #4879 (Talos ISO diff) has green required checks but is review-blocked. Both have auto-merge on — left to the maintainer. |
| Platform | `devantler-tech/platform` | — | Release on `main` recovered earlier today (APP_PRIVATE_KEY fix) and is now green. `TODOs` startup_failure (see Known issues). |
| Monorepo + site | `devantler-tech/monorepo` | 2026-05-24 | Issues disabled; CI clean; links healthy. #1694 (KSail unbloat) & #1695 (assistant restructure) both merged. |
| Templates | `go-template`, `dotnet-template` | 2026-05-24 | **go-template Release fixed** — added `.releaserc` ([#59](https://github.com/devantler-tech/go-template/pull/59), merged); Release workflow now green on `main`. dotnet-template healthy. |
| GitHub Actions | `actions`, `reusable-workflows` | — | actions #163 (dependabot zizmor 0.5.3→0.5.5) blocked by failing `test-setup-copilot-skills-inline` on macOS + Ubuntu — needs investigation. |
| Homebrew tap | `homebrew-tap` | — | No open PRs; no release workflow. `TODOs` startup_failure (see Known issues). |
| Applications | `wedding-app`, `ascoachingogvaner` | — | Private; no open PRs. Not yet surveyed in depth. |

## Run log
_Reverse-chronological; one line per run. Detailed cross-run state is in `state.json`._

- **2026-05-24 19:00 (Sun)** — First unified run. Surveyed all 10 repos. Fixed go-template Release breakage: added `.releaserc` ([#59](https://github.com/devantler-tech/go-template/pull/59)); maintainer promoted → squash-merged → Release now green on `main`. Found portfolio-wide `TODOs` `startup_failure` (5 repos) and a failing `test-setup-copilot-skills-inline` test in `actions` — logged for follow-up. Confirmed #1694 & #1695 merged; left ksail to the maintainer (active CI work).
