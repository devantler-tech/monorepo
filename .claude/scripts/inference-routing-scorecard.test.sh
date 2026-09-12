#!/usr/bin/env bash
# Exercise the real offline aggregator; no runtime or model is contacted.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/evidence.json" <<'JSON'
{
  "version": 1,
  "window": {"start": 1000, "end": 2000},
  "coverage": {"inventoryKnown": true, "expectedAttempts": [{"id":"a","workItemId":"one"},{"id":"b","workItemId":"one"},{"id":"c","workItemId":"two"}]},
  "workItems": [
    {"id":"one","cohort":"bounded-repair","taskClass":"workhorse","policyRevision":"p1","status":"accepted","terminalAt":1500,"pr":"owner/repo#1","attempts":[
      {"id":"a","parentId":null,"runtime":"local","requestedModel":"small","effectiveModel":"small","effort":"medium","status":"failed","failureKind":"reasoning","inputTokens":100,"cachedInputTokens":10,"outputTokens":20,"reasoningTokens":5,"activeSeconds":30},
      {"id":"b","parentId":"a","runtime":"local","requestedModel":"large","effectiveModel":"large","effort":"high","status":"succeeded","failureKind":null,"inputTokens":200,"cachedInputTokens":20,"outputTokens":40,"reasoningTokens":10,"activeSeconds":60}
    ]},
    {"id":"two","cohort":"bounded-repair","taskClass":"workhorse","policyRevision":"p1","status":"failed","terminalAt":1600,"pr":null,"attempts":[
      {"id":"c","parentId":null,"runtime":"local","requestedModel":"small","effectiveModel":"small","effort":"medium","status":"failed","failureKind":"environment","inputTokens":50,"cachedInputTokens":0,"outputTokens":10,"reasoningTokens":0,"activeSeconds":15}
    ]}
  ]
}
JSON
# Transform a synthetic evidence fixture and check the real scorecard status and JSON output.
run_case() {
  local name="$1" change="$2" expected_exit="$3" assertion="$4" status=0
  jq "$change" "$TMP/evidence.json" > "$TMP/input.json"
  bash "$HERE/inference-routing-scorecard.sh" < "$TMP/input.json" > "$TMP/output.json" || status=$?
  if [[ "$status" != "$expected_exit" ]] || ! jq -e "$assertion" "$TMP/output.json" > /dev/null; then
    printf 'FAIL %s: exit=%s expected=%s\n' "$name" "$status" "$expected_exit" >&2
    cat "$TMP/output.json" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$name"
}
run_case complete-chain '.' 0 '.coverage.status == "COMPLETE" and .totals.acceptedWorkItems == 1 and .totals.acceptedPRs == 1 and .totals.attempts == 3 and .optimizationVerdict == "NO_VERDICT" and .quotaAttribution == "UNKNOWN"'
# Preserve the jq variable; shell expansion would corrupt the chain swap.
# shellcheck disable=SC2016
run_case swapped-work-item-chains '.workItems[0].attempts as $first | .workItems[0].attempts=.workItems[1].attempts | .workItems[1].attempts=$first | .workItems[1].cohort="canary"' 0 '.coverage.status == "UNKNOWN" and .coverage.misassignedAttempts == 3 and .optimizationVerdict == "NO_VERDICT"'
run_case reordered-inventory '.coverage.expectedAttempts |= reverse' 0 '.coverage.status == "COMPLETE" and .coverage.misassignedAttempts == 0'
run_case wrong-inventory-owner '.coverage.expectedAttempts[1].workItemId="absent"' 0 '.coverage.status == "UNKNOWN" and .coverage.misassignedAttempts == 1'
run_case duplicate-inventory-id '.coverage.expectedAttempts += [{"id":"a","workItemId":"two"}]' 2 '.status == "INVALID"'
run_case missing-inventory-owner 'del(.coverage.expectedAttempts[0].workItemId)' 2 '.status == "INVALID"'
run_case flat-inventory '.coverage.expectedAttemptIds=["a","b","c"] | del(.coverage.expectedAttempts)' 2 '.status == "INVALID"'
run_case mixed-models '.' 0 '(.modelParticipation | length) == 2 and (.modelParticipation[] | select(.effectiveModel == "small") | .participatingWorkItems == 2 and .failedAttempts == 2 and .terminalAttempts == 2 and .failedAttemptRate == 1 and (has("acceptedWorkItems") | not)) and (.cohorts[0] | .metrics.inputTokens.observedTotal == 350 and .metrics.activeSeconds.observedTotal == 105)'
run_case failure-causes '.' 0 '(.modelParticipation[] | select(.effectiveModel == "small") | .failedByKind == {"environment":1,"reasoning":1})'
run_case duplicate-item '.workItems += [.workItems[0]]' 0 '.totals.workItems == 2 and .totals.attempts == 3 and .totals.acceptedWorkItems == 1 and .coverage.duplicateWorkItemRows == 1'
run_case duplicate-attempt '.workItems[0].attempts += [.workItems[0].attempts[0]]' 0 '.totals.attempts == 3 and .coverage.duplicateAttemptRows == 1'
run_case conflicting-item '.workItems += [(.workItems[0] | .status="failed")]' 2 '.status == "INVALID"'
run_case conflicting-attempt '.workItems[0].attempts += [(.workItems[0].attempts[0] | .status="succeeded" | .failureKind=null)]' 2 '.status == "INVALID"'
run_case reused-attempt '.workItems[1].attempts=[.workItems[0].attempts[0]]' 2 '.status == "INVALID"'
run_case missing-inventory '.coverage.inventoryKnown=false' 0 '.coverage.status == "UNKNOWN" and .optimizationVerdict == "NO_VERDICT"'
run_case missing-child '.workItems[0].attempts |= map(select(.id != "b"))' 0 '.coverage.missingAttempts == 1 and .coverage.status == "UNKNOWN"'
run_case unrecorded-child '.coverage.expectedAttempts |= map(select(.id != "b"))' 0 '.coverage.unexpectedAttempts == 1 and .coverage.status == "UNKNOWN"'
run_case missing-parent '.workItems[0].attempts[1].parentId="absent"' 0 '.coverage.incompleteChains == 1 and .coverage.status == "UNKNOWN"'
run_case sibling-branch '.workItems[0].attempts += [(.workItems[0].attempts[1] | .id="d")] | .coverage.expectedAttempts += [{"id":"d","workItemId":"one"}]' 0 '.coverage.incompleteChains == 1 and .coverage.status == "UNKNOWN" and .totals.attempts == 4'
# Keep jq variables literal while constructing chains at the traversal boundary.
# shellcheck disable=SC2016
run_case chain-depth-32 '.workItems[0].attempts[1] as $template | .workItems=[(.workItems[0] | .attempts=[range(32) as $i | $template + {id:("node-"+($i|tostring)),parentId:(if $i == 0 then null else "node-"+(($i-1)|tostring) end)}])] | .coverage.expectedAttempts=[.workItems[0].attempts[] | {id,workItemId:"one"}]' 0 '.coverage.status == "COMPLETE" and .totals.attempts == 32'
# shellcheck disable=SC2016
run_case chain-depth-33 '.workItems[0].attempts[1] as $template | .workItems=[(.workItems[0] | .attempts=[range(33) as $i | $template + {id:("node-"+($i|tostring)),parentId:(if $i == 0 then null else "node-"+(($i-1)|tostring) end)}])] | .coverage.expectedAttempts=[.workItems[0].attempts[] | {id,workItemId:"one"}]' 0 '.coverage.status == "UNKNOWN" and .coverage.incompleteChains == 1 and .totals.attempts == 33'
# Exercise the maximum per-item input with long shared ancestry; retain every
# attempt in accounting even when the graph violates the one-child limit.
# shellcheck disable=SC2016
run_case maximum-branched-chain '.workItems[0].attempts[1] as $template | .workItems=[(.workItems[0] | .attempts=[range(1024) as $i | $template + {id:("node-"+($i|tostring)),parentId:(if $i == 0 then null else "node-"+(([($i-1),30]|min)|tostring) end)}])] | .coverage.expectedAttempts=[.workItems[0].attempts[] | {id,workItemId:"one"}]' 0 '.coverage.status == "UNKNOWN" and .coverage.incompleteChains == 1 and .totals.attempts == 1024 and .cohorts[0].metrics.inputTokens.observedTotal == 204800'
run_case cyclic-chain '.workItems[0].attempts[0].parentId="b"' 0 '.coverage.incompleteChains == 1 and .coverage.status == "UNKNOWN"'
run_case unknown-model '.workItems[0].attempts[1].effectiveModel=null' 0 '.coverage.unattributedAttempts == 1 and .coverage.status == "UNKNOWN" and .totals.attempts == 3'
run_case unknown-metric '.workItems[0].attempts[1].inputTokens=null' 0 '.cohorts[0].metrics.inputTokens.observedTotal == 150 and .cohorts[0].metrics.inputTokens.unknownAttempts == 1 and .coverage.status == "UNKNOWN"'
run_case different-policy '.workItems[1].policyRevision="p2"' 0 '(.cohorts | length) == 2 and .cohorts[0].acceptedWorkItems == 1 and .cohorts[1].acceptedWorkItems == 0'
run_case shared-pr '.workItems[1].status="accepted" | .workItems[1].pr="owner/repo#1"' 0 '.totals.acceptedWorkItems == 2 and .totals.acceptedPRs == 1 and .cohorts[0].acceptedPRs == 1'
run_case cross-cohort-pr '.workItems[1].status="accepted" | .workItems[1].pr="owner/repo#1" | .workItems[1].policyRevision="p2"' 2 '.status == "INVALID"'
run_case abandoned '.workItems[1].status="abandoned" | .workItems[1].attempts[0].status="abandoned" | .workItems[1].attempts[0].failureKind=null' 0 '.cohorts[0].abandonedWorkItems == 1 and (.modelParticipation[] | select(.effectiveModel == "small") | .abandonedAttempts == 1 and .terminalAttempts == 2 and .failedAttemptRate == 0.5)'
run_case pending '.workItems[1].status="pending" | .workItems[1].terminalAt=null | .workItems[1].attempts[0].status="pending" | .workItems[1].attempts[0].failureKind=null' 0 '(.modelParticipation[] | select(.effectiveModel == "small") | .pendingAttempts == 1 and .terminalAttempts == 1 and .failedAttemptRate == 1)'
run_case unfinished-terminal-chain '.workItems[0].attempts[1].status="pending"' 0 '.coverage.incompleteChains == 1 and .coverage.status == "UNKNOWN"'
run_case normalized-throughput '.' 0 '.cohorts[0].acceptedWorkItemsPerDay == 86.4 and .cohorts[0].acceptedPRsPerDay == 86.4'
run_case all-pending '.workItems |= map(.status="pending" | .terminalAt=null | .attempts |= map(.status="pending" | .failureKind=null))' 0 '.totals.acceptedWorkItems == 0 and all(.modelParticipation[]; .failedAttemptRate == null)'
run_case outside-window '.workItems[0].terminalAt=2000' 2 '.status == "INVALID"'
run_case missing-field 'del(.workItems[0].attempts[0].inputTokens)' 2 '.status == "INVALID"'
run_case extra-field '.rawTranscript="sensitive-value"' 2 '.status == "INVALID" and (tostring | contains("sensitive-value") | not)'
run_case invalid-metric '.workItems[0].attempts[0].activeSeconds=-1' 2 '.status == "INVALID"'
run_case empty-observation '.coverage.expectedAttempts=[] | .workItems=[]' 0 '.totals.attempts == 0 and .totals.acceptedWorkItems == 0 and .optimizationVerdict == "NO_VERDICT" and (.modelParticipation | length) == 0'
printf '{invalid' > "$TMP/input.json"
status=0
bash "$HERE/inference-routing-scorecard.sh" < "$TMP/input.json" > "$TMP/output.json" 2> "$TMP/error" || status=$?
[[ "$status" == 2 && ! -s "$TMP/error" ]]
jq -e '.status == "INVALID" and .optimizationVerdict == "NO_VERDICT"' "$TMP/output.json" > /dev/null
printf 'PASS malformed JSON\n'
