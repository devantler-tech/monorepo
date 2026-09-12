# Inference routing scorecard

Run `bash .claude/scripts/inference-routing-scorecard.sh < normalized-evidence.json` for a
descriptive scorecard. It uses Bash and jq, reads only standard input, and makes no network calls,
model requests, credential reads, reservations, or store writes. Exit 0 means aggregation succeeded;
exit 2 returns only a generic invalid result. Neither status authorises execution or policy promotion.

## Evidence boundary

Produce normalized evidence from native runtime metadata, an independent dispatch/child inventory,
and verified terminal outcomes joined to immutable revisions. Preserve source locators and extraction
versions in private native memory alongside the input. Never derive the expected inventory from the
same transcript walk being checked. Agent assertions, a successful routing preflight, and a PR's last
model are insufficient attribution. This component validates structure and joins, not authenticity.

Do not put raw transcripts, prompts, command output, credentials, private topology, or freeform text
in the input. Use non-sensitive identifiers; retain input and scorecard privately. The output exposes
only selected cohort/model labels and aggregate observations. An absent measurement is null, never
zero. A runtime adapter must supply disjoint per-attempt counters, not parent totals that already
include children. Missing native attribution remains UNKNOWN; do not invent it to complete the schema.

## Exact version 1 input

All fields are required; extra fields are rejected at every level. Identifiers are 1–128 ASCII
letters/digits plus `.`, `_`, `/`, `-`, starting with a letter/digit. Numbers are nonnegative and at
most 10^12; timestamps and token counts are integers. The top-level object contains:

| Field | Meaning |
| --- | --- |
| `version` | Literal `1` |
| `window` | `{start,end}` UTC epoch seconds; nonempty half-open interval `[start,end)` |
| `coverage` | `{inventoryKnown,expectedAttempts}`; `inventoryKnown` is a boolean and `expectedAttempts` is an array of independent inventory entries, each exactly `{id,workItemId}` with a unique attempt `id` and its expected work-item identity |
| `workItems` | Array of the work-item records below |

Each work item contains exactly `id`, `cohort`, `taskClass`, `policyRevision`, `status`, `terminalAt`,
`pr`, and `attempts`. Its cohort label binds repository, difficulty/acceptance stratum, runtime version,
and any experiment arm declared before observation. Grouping also preserves task class and policy
revision. A label is an assertion of comparability to verify, not proof of a causal experiment.

`status` is `accepted`, `failed`, `abandoned`, or `pending`. Terminal work items must have `terminalAt`
inside the window; pending items have null and are unresolved as of its end. Enumerate every terminal
work item in the window plus pending work, including failures and abandonment. Include their complete
attempt chains even when an attempt began before the window. Thus attempt metrics describe the full
delivery cohorts, not token usage incurred strictly inside the window.

`pr` is null or the canonical `owner/repo#number` identity, never a URL. An accepted non-PR deliverable
may have null. Multiple work items can share a PR within one cohort; cross-cohort PR attribution is
rejected. `accepted` requires independently verified acceptance, not merely a merged or opened PR.

Every attempt contains exactly:

| Fields | Values |
| --- | --- |
| `id`, `parentId` | Unique attempt ID and parent/predecessor ID, or null for the root; joins come from dispatch or verified handoff evidence |
| `runtime`, `requestedModel`, `effectiveModel` | Identifiers, or null when unavailable |
| `effort` | null or `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra` |
| `status` | `succeeded`, `failed`, `abandoned`, `pending` |
| `failureKind` | For failed attempts: `reasoning`, `environment`, `quota`, `authority`, `unknown`, or null; otherwise null |
| `inputTokens`, `cachedInputTokens`, `outputTokens`, `reasoningTokens` | Native counters or null; separate series, never summed together because counters can overlap |
| `activeSeconds` | Processing time excluding waits and child processing, or null when not measurable |

The independent inventory must bind each attempt to its work item, not merely enumerate attempt IDs.
A structurally valid chain assigned to another work item yields `misassignedAttempts` and UNKNOWN
coverage; flat ID-only inventories and duplicate inventory IDs are invalid. Verify cohort assignment
against the experiment register separately; this join does not authenticate caller-supplied labels.

There must be one root per complete work item and at most one child or successor per attempt.
Sibling branches retain all observed usage but make the chain incomplete; serial handoffs use the
preceding attempt as their `parentId`. Missing parents, cycles, chains deeper than 32,
unattributed attempts, missing measurements, or pending descendants of terminal work yield UNKNOWN
coverage. Exact duplicate rows are deduplicated and counted; conflicting work-item/attempt identities
and attempts assigned to multiple work items are invalid. Input is bounded to 512 item rows,
1024 attempts per row, and 10000 total attempt rows/inventory IDs.

## Reading the result

`totals` and `cohorts` count unique observed accepted work items and PRs. Cohort daily rates divide by
the supplied window duration; compare equal observation definitions, not raw values from unlike
cohorts. Failed, abandoned, and pending items remain visible. `modelParticipation` reports models'
participating work items, attempt outcomes, and requested/effective mismatches; it never allocates a
terminal delivery to one model. `failedAttemptRate` is failed attempts divided by all terminal
attempts, including abandonment. Pending attempts are excluded from that denominator; no terminal
attempts produces null. `failedByKind` separates reasoning failures from environment, quota, and
authority failures. Abandonment remains a separate count, never hidden as success.

Every metric reports `observedTotal` and `unknownAttempts`; an observed zero with missing values is
not a complete zero. Output `coverage.expectedAttempts` is a numeric count, unlike the input inventory
array with the same name. Coverage reports expected/observed/missing/unexpected/misassigned attempts, incomplete
chains, unknown attribution/metrics, and duplicate rows. Counts under UNKNOWN coverage are partial
observations, never a successful optimization verdict.

`optimizationVerdict` is always `NO_VERDICT`: this descriptive component does not evaluate baselines,
quality floors, canary eligibility, or causal improvement. Agent Improver applies its reviewed
experiment procedure afterward. `quotaAttribution` is always `UNKNOWN`; token counters and overlapping
account snapshots cannot establish per-model subscription consumption. Never combine quota
percentages across providers or infer pay-as-you-go prices from these counters.
