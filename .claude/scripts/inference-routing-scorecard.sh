#!/usr/bin/env bash
# Pure aggregation of normalized caller reports; never authenticates evidence,
# reads transcripts, launches inference, contacts a service, or writes a store.
set -euo pipefail
# Return a generic error without echoing invalid or potentially sensitive evidence.
invalid() {
  printf '%s\n' '{"status":"INVALID","optimizationVerdict":"NO_VERDICT"}'
  exit 2
}
[[ $# == 0 ]] || invalid
command -v jq > /dev/null || invalid
result=$(jq -sce '
  def exact($fields): type == "object" and (keys | sort) == ($fields | sort);
  def identifier: type == "string" and length > 0 and length <= 128
    and test("^[A-Za-z0-9][A-Za-z0-9._/-]*$");
  def nullable_id: . == null or identifier;
  def amount: type == "number" and . >= 0 and . <= 1000000000000;
  def integer: amount and floor == .;
  def nullable_integer: . == null or integer;
  def metric_keys: ["inputTokens","cachedInputTokens","outputTokens","reasoningTokens","activeSeconds"];
  def cohort_key: [.cohort,.taskClass,.policyRevision];
  def attempt:
    exact(["id","parentId","runtime","requestedModel","effectiveModel","effort","status",
      "failureKind","inputTokens","cachedInputTokens","outputTokens","reasoningTokens","activeSeconds"])
    and (.id | identifier) and all(.parentId,.runtime,.requestedModel,.effectiveModel; nullable_id)
    and (.effort | . == null or IN("none","minimal","low","medium","high","xhigh","max","ultra"))
    and (.status | IN("succeeded","failed","abandoned","pending"))
    and (.failureKind | . == null or IN("reasoning","environment","quota","authority","unknown"))
    and (if .status == "failed" then true else .failureKind == null end)
    and all(.inputTokens,.cachedInputTokens,.outputTokens,.reasoningTokens; nullable_integer)
    and (.activeSeconds | . == null or amount);
  def work_item($window):
    exact(["id","cohort","taskClass","policyRevision","status","terminalAt","pr","attempts"])
    and all(.id,.cohort,.taskClass,.policyRevision; identifier)
    and (.status | IN("accepted","failed","abandoned","pending"))
    and (if .status == "pending" then .terminalAt == null
      else (.terminalAt | integer and . >= $window.start and . < $window.end) end)
    and (.pr | . == null or (type == "string" and length <= 256
      and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$")))
    and (.attempts | type == "array" and length <= 1024 and all(.[]; attempt));
  def valid:
    exact(["version","window","coverage","workItems"])
    and .version == 1
    and (.window | exact(["start","end"]) and all(.[]; integer) and .start < .end)
    and (.coverage | exact(["inventoryKnown","expectedAttempts"])
      and (.inventoryKnown | type == "boolean")
      and (.expectedAttempts | type == "array" and length <= 10000
        and all(.[]; exact(["id","workItemId"]) and all(.id,.workItemId; identifier))
        and length == (unique_by(.id) | length)))
    and (.window as $window | .workItems | type == "array" and length <= 512
      and all(.[]; work_item($window)))
    and ([.workItems[].attempts[]] | length <= 10000);
  def root_reached($attempts; $id; $seen):
    if ($seen | index($id)) != null or ($seen | length) >= 32 then false
    else $attempts[$id] as $a
      | if $a == null then false elif $a.parentId == null then true
        else root_reached($attempts; $a.parentId; $seen + [$id]) end
    end;
  def complete_chain:
    . as $item | .attempts as $a
      | (reduce $a[] as $attempt ({}; .[$attempt.id] = $attempt)) as $by_id
      | ([$a[] | select(.parentId == null)] | length) == 1
      and ([$a[] | select(.parentId != null)] | group_by(.parentId) | all(.[]; length == 1))
      and ($item.status == "pending" or all($a[]; .status != "pending"))
      and all($a[]; root_reached($by_id; .id; []));
  def metrics:
    . as $attempts | reduce metric_keys[] as $key ({};
      .[$key] = {observedTotal: ([$attempts[][$key] | select(. != null)] | add // 0),
        unknownAttempts: ([$attempts[] | select(.[$key] == null)] | length)});
  if length != 1 or (.[0] | valid | not) then error("invalid") else .[0] end
  | . as $input
  | if any(.workItems[]; .attempts | group_by(.id) | any(.[]; (unique | length) != 1))
      then error("conflicting attempt") else . end
  | [.workItems[] | .attempts |= unique_by(.id)] as $normalized
  | if any($normalized | group_by(.id)[]; (unique | length) != 1)
      then error("conflicting work item") else . end
  | ($normalized | unique_by(.id)) as $items
  | [$items[] as $w | $w.attempts[] | . + {workItemId:$w.id,cohort:$w.cohort,
      taskClass:$w.taskClass,policyRevision:$w.policyRevision}] as $attempts
  | if ([$attempts[].id] | length != (unique | length))
      or any($items | map(select(.pr != null)) | group_by(.pr)[];
        (map(cohort_key) | unique | length) != 1)
    then error("conflicting attribution") else . end
  | (reduce $input.coverage.expectedAttempts[] as $entry ({};
      .[$entry.id] = $entry.workItemId)) as $inventory
  | ($inventory | keys) as $expected_ids
  | ($expected_ids - [$attempts[].id] | length) as $missing
  | ([$attempts[].id] - $expected_ids | length) as $unexpected
  | ([$attempts[] | . as $a | select(($inventory | has($a.id))
      and $inventory[$a.id] != $a.workItemId)] | length) as $misassigned
  | ([$items[] | select(complete_chain | not)] | length) as $incomplete
  | ([$attempts[] | select(.runtime == null or .requestedModel == null or .effectiveModel == null
      or .effort == null or (.status == "failed" and (.failureKind == null or .failureKind == "unknown")))] | length) as $unattributed
  | ([$attempts[] | . as $a | select(any(metric_keys[]; $a[.] == null))] | length) as $unknown_metrics
  | ($input.coverage.inventoryKnown and $missing == 0 and $unexpected == 0 and $misassigned == 0
      and $incomplete == 0 and $unattributed == 0 and $unknown_metrics == 0) as $complete
  | ($input.window.end - $input.window.start) as $duration
  | {
      version:1,status:"OK",window:$input.window,evidenceTrust:"NORMALIZED_CALLER_REPORTS",
      optimizationVerdict:"NO_VERDICT",quotaAttribution:"UNKNOWN",
      coverage:{status:(if $complete then "COMPLETE" else "UNKNOWN" end),
        inventoryKnown:$input.coverage.inventoryKnown,expectedAttempts:($expected_ids | length),
        observedAttempts:($attempts | length),missingAttempts:$missing,unexpectedAttempts:$unexpected,
        misassignedAttempts:$misassigned,
        incompleteChains:$incomplete,unattributedAttempts:$unattributed,unknownMetricAttempts:$unknown_metrics,
        duplicateWorkItemRows:(($input.workItems | length) - ($items | length)),
        duplicateAttemptRows:(([$input.workItems[].attempts[]] | length) - ($attempts | length))},
      totals:{workItems:($items | length),attempts:($attempts | length),
        acceptedWorkItems:([$items[] | select(.status == "accepted")] | length),
        acceptedPRs:([$items[] | select(.status == "accepted" and .pr != null) | .pr] | unique | length)},
      cohorts:[$items | group_by(cohort_key)[] | . as $group
        | [$group[] | select(.status == "accepted")] as $accepted
        | ($accepted | length) as $n
        | ([$accepted[].pr | select(. != null)] | unique | length) as $prs
        | {cohort:.[0].cohort,taskClass:.[0].taskClass,policyRevision:.[0].policyRevision,
          workItems:length,acceptedWorkItems:$n,acceptedPRs:$prs,
          failedWorkItems:([.[] | select(.status == "failed")] | length),
          abandonedWorkItems:([.[] | select(.status == "abandoned")] | length),
          pendingWorkItems:([.[] | select(.status == "pending")] | length),
          acceptedWorkItemsPerDay:($n * 86400 / $duration),acceptedPRsPerDay:($prs * 86400 / $duration),
          metrics:([.[] | .attempts[]] | metrics)}],
      modelParticipation:[$attempts | group_by([.cohort,.taskClass,.policyRevision,.runtime,.effectiveModel,.effort])[]
        | ([.[] | select(.status != "pending")] | length) as $terminal
        | ([.[] | select(.status == "failed")] | length) as $failed
        | {cohort:.[0].cohort,taskClass:.[0].taskClass,policyRevision:.[0].policyRevision,
          runtime:.[0].runtime,effectiveModel:.[0].effectiveModel,effort:.[0].effort,
          participatingWorkItems:([.[].workItemId] | unique | length),attempts:length,
          terminalAttempts:$terminal,failedAttempts:$failed,
          failedByKind:([.[] | select(.status == "failed")] | group_by(.failureKind // "unknown")
            | map({key:(.[0].failureKind // "unknown"),value:length}) | from_entries),
          abandonedAttempts:([.[] | select(.status == "abandoned")] | length),
          pendingAttempts:([.[] | select(.status == "pending")] | length),
          requestedModelMismatches:([.[] | select(.requestedModel != null and .effectiveModel != null and .requestedModel != .effectiveModel)] | length),
          failedAttemptRate:(if $terminal == 0 then null else $failed / $terminal end),metrics:metrics}]
    }
' 2>/dev/null) || invalid
printf '%s\n' "$result"
