#!/usr/bin/env bash
# Evaluate the deployed policy with synthetic observations; never launch inference.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_ROOT="${INFERENCE_ROUTING_PLUGIN_ROOT:-$ROOT/libraries/agent-plugins/plugins/agentic-engineering}"
EVALUATOR="$PLUGIN_ROOT/scripts/evaluate-inference-routing.sh"
POLICY="$ROOT/.claude/plugin-consumption/inference-routing.policy.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[[ -x "$EVALUATOR" ]] || { echo 'reviewed routing evaluator unavailable' >&2; exit 1; }
jq -n --slurpfile policy "$POLICY" '{policy:$policy[0],
  task:{class:"workhorse",depth:0,children:0,distinctFailedHypotheses:0,activeMinutes:0,
    failureKind:"none",contractClear:true,checksDefined:true,reversible:true,
    sensitiveInvariants:false,writeRequired:true},
  snapshot:{observedAt:1789171200,runtime:"codex-local",runtimeVersion:"fixture",
    model:"gpt-5.6-sol",billing:"unknown",controls:"unverified",evidenceRef:null,
    buckets:{short:null,weekly:null}}}' > "$TMP/request.json"
# Run a modified synthetic request and verify both the process status and policy decision.
# Arguments: case name, jq fixture transformation, expected status, jq assertion.
check() {
  local name="$1" change="$2" expected="$3" assertion="$4" status=0
  jq "$change" "$TMP/request.json" > "$TMP/input.json"
  "$EVALUATOR" --now 1789171200 < "$TMP/input.json" > "$TMP/output.json" || status=$?
  if [[ "$status" != "$expected" ]] || ! jq -e "$assertion" "$TMP/output.json" > /dev/null; then
    printf 'FAIL %s\n' "$name" >&2
    cat "$TMP/output.json" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$name"
}
check default-off '.' 1 '.executionAdmitted == false and .decision == "HOLD" and
  (.reasons | index("POLICY_DISABLED") != null and index("RUNTIME_DISABLED") != null and index("QUOTA_UNKNOWN") != null)'
check no-fable '.policy.routes.workhorse.model="Claude-Fable-5.1"' 2 '.decision == "INVALID"'
check no-fable-support '.policy.routes.support.model="claude-fable-next"' 2 '.decision == "INVALID"'
check no-paid-fallback '.policy.paidFallback=true' 2 '.decision == "INVALID"'
check no-api-mode '.policy.billingMode="api"' 2 '.decision == "INVALID"'
check no-default-substitution '.policy.routes.workhorse.model="default"' 2 '.decision == "INVALID"'
check no-missing-window '.policy.enabled=true | .policy.runtimes["codex-local"].enabled=true' 1 '.reasons | index("QUOTA_UNKNOWN") != null'
check unverified-controls '.snapshot.billing="included"' 1 '.reasons | index("CONTROLS_UNVERIFIED") != null'
check deep-reasoning '.task.distinctFailedHypotheses=2' 1 '.taskClass == "diagnosis" and .route.model == "gpt-6-astra" and .executionAdmitted == false'
check environment-hold '.task.failureKind="environment"' 1 '.reasons | index("NON_REASONING_FAILURE") != null'
check provider-neutral-binding '.policy.runtimes["test-instance"]={enabled:false,role:"owner",expiresAt:1790380800} | .policy.routes.workhorse={model:"test-workhorse-v1",runtime:"test-instance",effort:"medium"} | .snapshot.runtime="test-instance" | .snapshot.model="test-workhorse-v1"' 1 '.route.runtime == "test-instance" and .route.model == "test-workhorse-v1" and .executionAdmitted == false'
# Current deployment bindings are intentionally inert; provider names are not a schema constraint.
# Activation is a later reviewed change with native evidence and its own positive/negative probes.
jq -e --slurpfile registry "$ROOT/.claude/plugin-consumption/agent-instances.json" '
  .enabled == false and all(.runtimes[]; .enabled == false)
  and all(.runtimes | keys[]; . as $id | $registry[0].instances | has($id))
  and .limits.maxDepth == 1 and .limits.maxChildren == 1' "$POLICY" > /dev/null
printf 'PASS inert runtime registrations\n'
