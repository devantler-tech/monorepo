# Run-loop read boundaries

Inventory for [monorepo#3430](https://github.com/devantler-tech/monorepo/issues/3430),
reviewed against consumer `90dbd9e8e433e3c981ef002b3d5b0afeef99549f` and its adopted
plugin `c759182ac59d550f8d1f3d5b03d86f2fa0e79b06` on 2026-10-25. This records the
decision-making read families in preflight, the survey, work selection and PR delivery;
it does not inventory reads inside every product's build or tests.

A successful transport is not necessarily a complete observation. An empty list,
zero count, skipped check or absent marker is evidence only after the reader has
established scope, shape, completeness and the identity being judged. A helper's
exit code and its documented output must be interpreted together: exit `0` from a
classifier can mean “classified,” rather than “safe to merge.” Rebind mutable facts
before the dependent write.

**Mechanical** means the named implementation rejects the relevant bad observation.
**Caller-bound** means that implementation checks only part of the boundary; the
remaining checks belong to the caller. **Procedural** means the contract requires
the check but there is no universal collector enforcing it. **Gap** names a known
missing observation. None of these labels is a new merge exemption.

## Gate reads first

| Read and tempting all-clear | What distinguishes missing evidence | Enacting source and regression coverage |
|---|---|---|
| Unresolved review threads: `0` | **Mechanical:** failed, empty or malformed input is UNKNOWN; paginated nodes must equal the reported total. A resolved first page cannot hide an unresolved second page. | [`pr-unresolved-threads.sh`](../scripts/pr-unresolved-threads.sh), [refused/empty/truncated-read tests and guard ablations](../scripts/pr-unresolved-threads.test.sh). |
| Required checks: the visible rollup is all green | **Mechanical, with caller identity binding:** compare against the base branch's required set, including required workflows and app-bound results. Missing, pending, failed and unverifiable gates stay distinct. An unreadable code-quality surface is UNVERIFIED. | [`required-gate-completeness.sh`](../scripts/required-gate-completeness.sh) and [tests](../scripts/required-gate-completeness.test.sh); [merge policy](merge-policy.md). |
| Default-branch CI: empty failures | **Mechanical:** the adopted plugin classifier requires validated repository/source/run/attempt evidence and complete reads. Refusal or malformed output is not an empty red set; the consumer requires its native exit status and complete output shape. | Adopted plugin `scripts/classify-default-branch-ci-runs.sh`; [`portfolio-surveyor.test.sh`](../scripts/portfolio-surveyor.test.sh) and [overlay step 4](../agents/portfolio-surveyor.md). |
| CodeRabbit summary: green status, refreshed timestamp or named head | **Caller-bound:** only a substantive review verdict for the exact full head counts. A quota shell, skipped review, unrelated walkthrough or findings cannot be GREEN. Caller still binds author, request freshness and complete discussion retrieval. | [`coderabbit-summary-verdict.sh`](../scripts/coderabbit-summary-verdict.sh) and [tests](../scripts/coderabbit-summary-verdict.test.sh). |
| CodeRabbit review object: no inline comments | **Caller-bound:** empty reply containers, other heads, skipped reviews, hidden/collapsed findings and malformed sections are not clean reviews. Caller still checks freshness and the other pentad surfaces. | [`coderabbit-review-verdict.sh`](../scripts/coderabbit-review-verdict.sh) and [tests](../scripts/coderabbit-review-verdict.test.sh). |
| Local review: marker appears somewhere | **Caller-bound:** complete review pages must reconcile to their total and one exact head before the marker and findings can be judged. An old round cannot approve a new commit. | [`local-review-verdict.sh`](../scripts/local-review-verdict.sh) and [tests](../scripts/local-review-verdict.test.sh). |
| Codex/Bugbot: ACK, reaction or ancillary green check | **Procedural:** require substantive current-head completion, inspect its findings and retain the other gates. A queued request or acknowledgment is not a review. There is no universal normalizer for every provider artifact. | [Review-lane contract](review-lanes.md), [`review-lane-health.sh`](../scripts/review-lane-health.sh) and [tests](../scripts/review-lane-health.test.sh). |
| Review-lane health: no recent result or no refusal found | **Mechanical:** failed collection is UNKNOWN; newest completed review, quota refusal and stale service are distinct. A cached verdict carries its observation time and does not establish another PR's review. | [`review-lane-health.sh`](../scripts/review-lane-health.sh), [tests](../scripts/review-lane-health.test.sh). |
| PR ownership: no disclosure marker | **Mechanical, with attribution limits:** an unreadable/empty body exits UNKNOWN, not `none`. A classified body attributes work; it does not waive ownership or merge checks. | [`pr-ownership-disclosure.sh`](../scripts/pr-ownership-disclosure.sh), [tests](../scripts/pr-ownership-disclosure.test.sh). |
| Active work: old push time or no forge claim | **Caller-bound:** include ref creation/recreation when reading activity; inspect current local holders. `unknown:` is not no holder. A stale review request expires only under its documented envelope, not by dropping a maintainer requirement. | [`pr-worktree-holder.sh`](../scripts/pr-worktree-holder.sh), [163-case suite](../scripts/pr-worktree-holder.test.sh); [activity and vocabulary guards](../scripts/portfolio-surveyor.test.sh). |
| Issue claim or review-request lock: no competing ref returned | **Mechanical ref operation, caller-bound continuation:** use the normal helper's verified acquisition/CAS result. A list/read failure is UNKNOWN and authorizes no dependent write. The helper cannot prevent an orchestrator from ignoring its exit status. | [`agent-claim.sh`](../scripts/agent-claim.sh), [tests](../scripts/agent-claim.test.sh); [`review-request-lock.sh`](../scripts/review-request-lock.sh), [tests](../scripts/review-request-lock.test.sh). |
| Programmed updater: bot author or expected title | **Mechanical, caller-bound scope:** exact identity, commit sequence, signatures, message and complete changed paths determine classification. Exit `3` still requires semantic review; exit `0` never makes this author eligible for deferred auto-merge. Reclassify the exact current head. | [`programmed-bot-review-exemption.sh`](../scripts/programmed-bot-review-exemption.sh), [surveyor/classifier regressions](../scripts/portfolio-surveyor.test.sh), [merge policy](merge-policy.md). |
| Parked work: `blocked` label or one prose blocker | **Mechanical:** complete scoped issue/PR and dependency observations, one valid blocker record, current verification and label readback are required. Failed reads cannot remove work from the actionable set. | [`blocked-label-blocker-line.sh`](../scripts/blocked-label-blocker-line.sh), [tests](../scripts/blocked-label-blocker-line.test.sh). |
| Merge completion: request accepted or matching head while still OPEN | **Caller-bound:** only MERGED permits comparing the merged PR's source head with the evaluated head. Keep deferred arming outstanding; `mergeCommit` is not that source-head field. | [Merge confirmation contract](merge-policy.md), [`merge-confirmation-read.test.sh`](../scripts/merge-confirmation-read.test.sh). |

## Discovery, readiness and preflight

| Read and tempting all-clear | What distinguishes missing evidence | Enacting source and regression coverage |
|---|---|---|
| Portfolio: no repository rows | **Procedural, with mechanical bounded consumers:** enumerate the declared map, confirm live visibility/archived state and authenticate before breadth. A missing `.github` file in a shell glob is not an empty repository. There is no universal portfolio snapshot transaction. | [Scope and visibility](work-selection.md), [fan-out rule](tool-call-discipline.md); [`lane-draft-count.sh`](../scripts/lane-draft-count.sh) reconciles its own repository inventory. |
| PR/issue enumeration: an empty search | **Procedural:** bind the repository at retrieval, paginate and reconcile the surface's count; a refused/short read remains QUERY-UNKNOWN. Search identity fields first, then deepen each PR. Raw ad-hoc CLI reads have no universal completeness wrapper. | [PR sweep](pr-readiness.md), [surveyor](../agents/portfolio-surveyor.md); [`pr-sweep-enumeration-contract.test.sh`](../scripts/pr-sweep-enumeration-contract.test.sh). |
| Native types: no untyped issues or no matching work | **Caller-bound:** derive the residual from complete primary and typed operands; reject malformed/missing type data. `no:type` is not a reliable operand. Truncation withholds only the affected repository's residual. | [Native-type contract](issues-and-board.md), [surveyor selection](../agents/portfolio-surveyor.md), [`portfolio-surveyor.test.sh`](../scripts/portfolio-surveyor.test.sh); adopted plugin's native issue classifier. |
| Dependencies/sub-issues: zero blockers or all children closed | **Caller-bound:** validate numeric summaries and read current issue labels in the same deepening response. Unreadable metadata is not zero. Completed children trigger a parent acceptance check; they do not prove the parent outcome. | [Work selection](work-selection.md), [surveyor dependency query](../agents/portfolio-surveyor.md), [`portfolio-surveyor.test.sh`](../scripts/portfolio-surveyor.test.sh). |
| Project join: absent priority, status, effort or WIP rows | **Procedural:** establish complete native project/issue joins before ranking. Missing joins are UNKNOWN, not lowest priority, Ready capacity or permission to start. A declared WIP exception is separate evidence. | [Kanban pull](work-selection.md), [board contract](issues-and-board.md), [`project-planning-fields.test.sh`](../scripts/project-planning-fields.test.sh). |
| Lane draft limit: count `0` | **Mechanical:** complete repository inventories and repeated normalized draft snapshots must agree before a count is printed. Failed or racing observations exit UNKNOWN. | [`lane-draft-count.sh`](../scripts/lane-draft-count.sh), [tests](../scripts/lane-draft-count.test.sh). |
| Kata measurement: date absent or issue old enough | **Mechanical parsed date, caller-bound delivery state:** use the structured measurement date; unreadable or malformed dates are not due-now. Verify delivery and measurement acceptance separately. | [`kata-measure-date.sh`](../scripts/kata-measure-date.sh), [tests](../scripts/kata-measure-date.test.sh); [kata guide](improvement-katas.md). |
| Scheduled workflow silence: no recent failed runs | **Mechanical:** read complete workflow inventory, parsed schedule, pinned file/history, continuity window and run observations, then rebind the default head. UNKNOWN differs from SILENT and from healthy. | [`silent-scheduled-workflows.sh`](../scripts/silent-scheduled-workflows.sh), [tests](../scripts/silent-scheduled-workflows.test.sh). |
| Dependency automation silence: no update PRs | **Gap:** scheduled-workflow silence and self-progressing-PR classification do not prove a configured updater has ever run. The independent updater liveness signal is still tracked by [#3138](https://github.com/devantler-tech/monorepo/issues/3138), with access gaps under [#4098](https://github.com/devantler-tech/monorepo/issues/4098). | [Current parent refinement](https://github.com/devantler-tech/monorepo/issues/3138#issuecomment-6392893146). Do not report quiet as healthy without positive evidence. |
| Default branch/submodule pin: equal cached OIDs | **Caller-bound:** require successful fresh full-ref fetch/read and compare the intended revision. A stale local remote-tracking ref cannot witness freshness. | [`submodule-pin-currency.sh`](../scripts/submodule-pin-currency.sh), [tests](../scripts/submodule-pin-currency.test.sh); [Git safety](git-and-worktrees.md). |
| Plugin currency: same version string or source pin | **Mechanical source comparison, separate runtime boundary:** compare complete blob/mode inventories at the adopted default-branch gitlink and declared assets. DRIFT/UNKNOWN is not CURRENT; source parity is not proof of native session loading. | [`plugin-definition-currency.sh`](../scripts/plugin-definition-currency.sh), [tests](../scripts/plugin-definition-currency.test.sh), [definition guide](definition-and-plugin.md). |
| Skill ownership: no metadata matches | **Mechanical:** structural provenance lookup at the pinned source distinguishes LOCAL from synchronized ownership. Empty glob/unreadable source is UNKNOWN, not “all local.” | [`skill-owner.sh`](../scripts/skill-owner.sh), [tests](../scripts/skill-owner.test.sh). |
| Native memory, disk and platform health: empty diagnostics | **Caller-bound:** require each preflight helper's documented native successful exit. Repair/stop codes retain their meaning; cached silence cannot establish current live health. | [Durable memory](durable-memory.md), [`disk-preflight.sh`](../scripts/disk-preflight.sh), [`platform-live-health.sh`](../scripts/platform-live-health.sh). |
| CLI field vocabulary: one unsupported field voids a request | **Mechanical syntax coverage, procedural transport:** the vocabulary guards cover prescribed calls and reject invented fields; they do not make a refused request complete. Read the command's actual exit before parsing output. | [`gh-json-vocabulary-contract.test.sh`](../scripts/gh-json-vocabulary-contract.test.sh), [`surveyor-forge-vocabulary.test.sh`](../scripts/surveyor-forge-vocabulary.test.sh), [`surveyor-vocabulary-coverage.test.sh`](../scripts/surveyor-vocabulary-coverage.test.sh). |
| Credentials/quota: public fetch works or a rate bucket has room | **Procedural:** authenticate the intended viewer and test the actual operation. REST and GraphQL availability are separate observations; neither a public fetch nor one bucket proves the other API is usable. A failed required lock/read still blocks its dependent write. | [Trust and input](trust-and-input.md), [privacy](egress-and-privacy.md), [review/ownership gates](review-lanes.md). |
| Publication/deployment: source merged, tag exists or CI is green | **Caller-bound:** bind exact source, signed digest, publisher/run/attempt and actual consumer readback. Missing or stale application evidence remains pending; synthetic tests and a created release do not establish deployment. | [Behavioral verification](github-artifacts.md), the owning product's publication/reconciliation contracts. |

## Demonstrated failure controls and remaining limits

The existing required thread-counter suite exercises a refused read, empty input,
missing PR, a first-page-only response and a real 103-thread/two-page fixture. It
requires UNKNOWN for incomplete observations, and its ablations demonstrate the
dangerous false zero when pagination/completeness checks are removed. The merge
preflight contract separately prevents replacing that read with unsupported CLI
thread fields. These are mechanical controls, not instructions to remember a
negative case manually.

The nine linked children of #3430 are closed. #2834 retains its other parent, as
the issue's existing record explains; neither REST `.parent` absence nor a closed
child total is used to rewrite that history. The inventory supplies the remaining
parent deliverable, while the explicit procedural/caller-bound rows prevent it
from claiming that every possible reader is mechanically safe.

Known updater silence remains #3138's separate outcome. For any newly discovered
unguarded read, record its producer, consuming decision, identities, incomplete
input and unsafe all-clear twin on the owning issue before proposing a guard.
Keep failed observations visible; this inventory is not a measurement of zero
future incidents or a sustained reliability improvement.
