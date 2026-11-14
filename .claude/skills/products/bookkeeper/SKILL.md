---
name: maintain-bookkeeper
description: Product card for devantler-tech/bookkeeper, the small Go program that sends the suite's supplier invoices from a mailbox to Numina. Use when the Agentic Engineer selects bookkeeper.
---

# Maintain: Bookkeeper

- **Serves:** the business's bookkeeping · **Outcome:** supplier invoices reach the Numina books without anyone forwarding them by hand ([README](https://github.com/devantler-tech/bookkeeper#readme))
- **Constraints:** fixed rules only, no AI; the standard library only; it may read mail and set one of two keywords, and upload to Numina's inbox, and nothing more
- **Non-goals:** booking, reconciliation and VAT, which stay in Numina
- **Evidence:** UNKNOWN

`devantler-tech/bookkeeper` is one Go command, `collect-vouchers`, packaged with a Helm chart that
runs it as a daily CronJob on the platform. It was created from the Go template on 2026-11-13.

## Working on it

It is **not a submodule** of this monorepo, so never run `submodule-init.sh` for it.

- **API-only work** (triage, review, comments) needs no checkout.
- **A code change** gets its own clone: `.claude/scripts/safe-clone.sh devantler-tech/bookkeeper
  <scratch-dir>`. Acquire the issue claim against that clone
  (`.claude/scripts/agent-claim.sh acquire <issue> --repo-dir <clone>`), create the claimed work
  branch there with `.claude/scripts/worktree-claim.sh add <clone> ...`, and open an ordinary draft
  PR **in that repository**.

Its own `AGENTS.md` carries the validate commands and the task menu in `## Maintenance`; follow it.

## Privacy

The program handles the business's supplier mail. **No supplier names, amounts, mail subjects, file
names or credentials** may reach an issue, PR, log, test fixture or this card. Read visibility live
(`gh api repos/devantler-tech/bookkeeper --jq .private`) before publishing anything about it.

## Authority boundary

Never widen what the program may do to the mailbox or the books without the maintainer's decision:
that is a widened trust boundary, not ordinary feature work. Deploying it, and the credentials it
needs, belong to the platform (devantler-tech/platform#6160).
