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

# Accepted scheduled parent routes (monorepo#3314). A maintainer decision lets a listed instance's
# scheduled parent run without the native enforcement proof. Pin both halves: the rule that lets
# the run work, and the limits the acceptance must not move. Each checker prints one FAIL line and
# returns 1 at the first thing it cannot find, so the fixtures below can prove that every check
# fires, and fires for its own reason.
GUIDE="${INFERENCE_ROUTING_GUIDE:-$ROOT/.claude/guides/spend-and-inference.md}"
RUNTIME_DOC="${INFERENCE_ROUTING_RUNTIME_DOC:-$ROOT/.claude/plugin-consumption/inference-routing-runtime.md}"
REGISTRY="$ROOT/.claude/plugin-consumption/agent-instances.json"
[[ -r "$GUIDE" && -r "$RUNTIME_DOC" && -r "$REGISTRY" ]] ||
  { echo 'FAIL accepted parent routes: contract files unreadable' >&2; exit 1; }

# Print a file as one line of whitespace-normalised text with the backticks (octal 140) removed:
# both files are hard-wrapped and mark code with backticks.
flatten() {
  tr -s '[:space:]' ' ' | tr -d '\140'
}

# Check the rule in the guide. Argument: the guide file.
# Agents resolve the rule at the Inference routing section, so read that section alone: the same
# words under another heading would not be the rule, and a missing heading extracts nothing.
check_guide() {
  local section text phrase
  section="$(awk '
    /^## Inference routing$/ { on = 1; next }
    on && /^## / { exit }
    on { print }' "$1")" || { echo 'FAIL accepted parent routes: guide unreadable'; return 1; }
  [[ -n "$section" ]] ||
    { echo 'FAIL accepted parent routes: the guide has no Inference routing section'; return 1; }
  text="$(printf '%s\n' "$section" | flatten)"
  for phrase in \
    'Outside an accepted route, missing pre-inference controls hold the affected startup, resume or fallback' \
    'An accepted route is never held for them' \
    'native pre-inference enforcement is **not a required control** for it' \
    'never a reason to stop a scheduled run or to skip portfolio work' \
    'a visible model ID containing fable, an inference API key, or a sign-in or billing route other than the included subscription' \
    'it cannot prevent the first one' \
    'Children, advisors, model switches, fallback and automatic routing stay disabled and gated' \
    'No-Fable and subscription-only inference still bind the accepted route' \
    'only the maintainer adds one'; do
    case "$text" in
      *"$phrase"*) ;;
      *) printf 'FAIL accepted parent routes: guide lost: %s\n' "$phrase"; return 1 ;;
    esac
  done
}

# Each table cell is matched whole, so a row cannot be widened by adding words to it: the route
# cell admits only the scheduled parent on the scheduler-fixed model and one named subscription
# sign-in.
route_re='^(Engineer|Improver|Engineer and improver) schedules?, on the model fixed in (its|each) scheduler entry and the [A-Za-z][A-Za-z0-9.-]* subscription sign-in$'
decision_re='^Maintainer, 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9], monorepo#[0-9]+$'
# Print one trimmed cell of a table row. Arguments: the row, the awk field number.
cell() {
  printf '%s\n' "$1" | awk -F'|' -v n="$2" '{ gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n }'
}

# Check the accepted-routes table and the startup rule beside it. Argument: the runtime document.
# Every row names a registered instance, a route no wider than the scheduled parent and a
# maintainer decision. The Codex row is required by name: it is the decision this contract
# records, and without it the scheduled Codex runs stop at the pre-flight again.
check_routes() {
  local text phrase rows row fields id route decision codex_listed=0
  text="$(flatten < "$1")" || { echo 'FAIL accepted parent routes: runtime document unreadable'; return 1; }
  for phrase in \
    'Outside a listed route, missing pre-inference controls hold the affected startup, resume or fallback' \
    'A listed route is never held for them'; do
    case "$text" in
      *"$phrase"*) ;;
      *) printf 'FAIL accepted parent routes: runtime document lost: %s\n' "$phrase"; return 1 ;;
    esac
  done
  # The table's data rows (neither the header nor the separator row), backticks removed.
  rows="$(awk '
    /^## Accepted scheduled parent routes$/ { on = 1; next }
    on && /^## / { exit }
    on && /^\|/ && !/^\| *Instance *\|/ && !/^\|[-| ]+$/ { print }' "$1" | tr -d '\140')" ||
    { echo 'FAIL accepted parent routes: runtime document unreadable'; return 1; }
  [[ -n "$rows" ]] || { echo 'FAIL accepted parent routes: no accepted row found'; return 1; }
  while IFS= read -r row; do
    # "| a | b | c |" splits into five fields; any other count is a row this check cannot read.
    fields="$(printf '%s\n' "$row" | awk -F'|' '{ print NF }')"
    [[ "$fields" == 5 ]] ||
      { printf 'FAIL accepted parent routes: row is not three cells: %s\n' "$row"; return 1; }
    id="$(cell "$row" 2)"
    route="$(cell "$row" 3)"
    decision="$(cell "$row" 4)"
    [[ -n "$id" ]] || { printf 'FAIL accepted parent routes: unreadable row: %s\n' "$row"; return 1; }
    jq -e --arg id "$id" '.instances | has($id)' "$REGISTRY" > /dev/null ||
      { printf 'FAIL accepted parent routes: %s is not a registered instance\n' "$id"; return 1; }
    [[ "$route" =~ $route_re ]] ||
      { printf 'FAIL accepted parent routes: %s accepts more than a scheduled parent route: %s\n' "$id" "$route"; return 1; }
    [[ "$decision" =~ $decision_re ]] ||
      { printf 'FAIL accepted parent routes: %s carries no maintainer decision\n' "$id"; return 1; }
    [[ "$id" != codex-local ]] || codex_listed=1
  done <<ROWS
$rows
ROWS
  [[ "$codex_listed" == 1 ]] ||
    { echo 'FAIL accepted parent routes: codex-local is not listed'; return 1; }
}

# The live contract must pass.
out="$(check_guide "$GUIDE")" || { printf '%s\n' "$out" >&2; exit 1; }
printf 'PASS accepted parent route rule and its limits\n'
out="$(check_routes "$RUNTIME_DOC")" || { printf '%s\n' "$out" >&2; exit 1; }
printf 'PASS accepted parent routes are registered, parent-only and maintainer-decided\n'

# Run a checker against a fixture that must be refused, and require the refusal to name its own
# reason. Arguments: case name, checker, fixture file, expected diagnostic text.
refuses() {
  local name="$1" checker="$2" fixture="$3" want="$4" got
  if got="$("$checker" "$fixture")"; then
    printf 'FAIL accepted parent routes control %s: the fixture was accepted\n' "$name" >&2
    exit 1
  fi
  case "$got" in
    *"$want"*) printf 'PASS control %s\n' "$name" ;;
    *) printf 'FAIL accepted parent routes control %s: refused for another reason: %s\n' "$name" "$got" >&2
       exit 1 ;;
  esac
}

# Print a runtime document holding the startup rule and one table row per "id|route|decision"
# argument. A row argument is written as given, so a fixture can carry a fourth cell.
routes_doc() {
  printf '%s\n\n' 'Outside a listed route, missing pre-inference controls hold the affected startup,' \
    'resume or fallback. A listed route is never held for them.'
  printf '%s\n\n%s\n%s\n' '## Accepted scheduled parent routes' \
    '| Instance | Accepted route | Decision |' '|---|---|---|'
  local row
  for row; do
    printf '| %s |\n' "$(printf '%s' "$row" | sed 's/|/ | /g')"
  done
  printf '\n%s\n' '## Native verification procedure'
}
good_route='Engineer and improver schedules, on the model fixed in each scheduler entry and the Example subscription sign-in'
good_decision='Maintainer, 2026-10-07, monorepo#3314'

# The fixture builder itself must produce a document the checker accepts, or every refusal below
# would prove nothing.
routes_doc "codex-local|$good_route|$good_decision" > "$TMP/routes-good.md"
out="$(check_routes "$TMP/routes-good.md")" ||
  { printf 'FAIL accepted parent routes control: the valid fixture was refused: %s\n' "$out" >&2; exit 1; }
routes_doc "codex-local|$good_route|$good_decision" "claude-local|Engineer schedule, on the model fixed in its scheduler entry and the Example subscription sign-in|$good_decision" > "$TMP/routes-two.md"
out="$(check_routes "$TMP/routes-two.md")" ||
  { printf 'FAIL accepted parent routes control: a second valid row was refused: %s\n' "$out" >&2; exit 1; }
printf 'PASS control valid fixtures are accepted\n'

routes_doc "codex-local|Engineer and improver schedules, on any model and the Example subscription sign-in|$good_decision" > "$TMP/r.md"
refuses 'route on any model' check_routes "$TMP/r.md" 'codex-local accepts more than a scheduled parent route'
routes_doc "codex-local|$good_route or API billing|$good_decision" > "$TMP/r.md"
refuses 'route with API billing' check_routes "$TMP/r.md" 'codex-local accepts more than a scheduled parent route'
routes_doc "codex-local|$good_route, and its children and fallback|$good_decision" > "$TMP/r.md"
refuses 'route with children and fallback' check_routes "$TMP/r.md" 'codex-local accepts more than a scheduled parent route'
routes_doc "codex-local|$good_route|also its children|$good_decision" > "$TMP/r.md"
refuses 'fourth cell' check_routes "$TMP/r.md" 'row is not three cells'
routes_doc "codex-local|$good_route|Engineer, 2026-10-07" > "$TMP/r.md"
refuses 'decision not the maintainer' check_routes "$TMP/r.md" 'codex-local carries no maintainer decision'
routes_doc "codex-local|$good_route|$good_decision and the engineer" > "$TMP/r.md"
refuses 'decision with a suffix' check_routes "$TMP/r.md" 'codex-local carries no maintainer decision'
routes_doc "codex-local|$good_route|$good_decision" "unregistered-example|$good_route|$good_decision" > "$TMP/r.md"
refuses 'unregistered instance' check_routes "$TMP/r.md" 'unregistered-example is not a registered instance'
routes_doc "claude-local|$good_route|$good_decision" > "$TMP/r.md"
refuses 'codex row replaced' check_routes "$TMP/r.md" 'codex-local is not listed'
routes_doc > "$TMP/r.md"
refuses 'empty table' check_routes "$TMP/r.md" 'no accepted row found'
sed 's/^## Accepted scheduled parent routes$/## Something else/' "$TMP/routes-good.md" > "$TMP/r.md"
refuses 'table under another heading' check_routes "$TMP/r.md" 'no accepted row found'
sed 's/^Outside a listed route, missing/Missing/' "$TMP/routes-good.md" > "$TMP/r.md"
refuses 'startup hold not scoped' check_routes "$TMP/r.md" 'runtime document lost: Outside a listed route'

# Guide controls are cut from the live guide, so each first proves that it changed its input.
# Arguments: case name, sed expression, expected diagnostic text.
guide_refuses() {
  sed "$2" "$GUIDE" > "$TMP/g.md"
  if cmp -s "$GUIDE" "$TMP/g.md"; then
    printf 'FAIL accepted parent routes control %s: the fixture equals the live guide\n' "$1" >&2
    exit 1
  fi
  refuses "$1" check_guide "$TMP/g.md" "$3"
}
guide_refuses 'guide heading renamed' 's/^## Inference routing$/## Routing/' \
  'the guide has no Inference routing section'
guide_refuses 'guide startup hold not scoped' 's/Outside an accepted route, missing$/Missing/' \
  'guide lost: Outside an accepted route'
guide_refuses 'guide backstop overclaims' 's/it cannot prevent the first one/it prevents every prohibited turn/' \
  'guide lost: it cannot prevent the first one'
# The rule under another heading is not the rule: move the section's text under the previous
# heading and leave an Inference routing section that no longer holds it.
awk '
  /^## Inference routing$/ { hold = 1 }
  hold { held = held $0 "\n"; next }
  { body = body $0 "\n" }
  END { sub(/## Inference routing\n/, "", held); printf "%s%s## Inference routing\n\nSee above.\n", body, held }' \
  "$GUIDE" > "$TMP/g.md"
cmp -s "$GUIDE" "$TMP/g.md" &&
  { echo 'FAIL accepted parent routes control guide rule moved: the fixture equals the live guide' >&2; exit 1; }
refuses 'guide rule moved out of its section' check_guide "$TMP/g.md" \
  'guide lost: Outside an accepted route'
