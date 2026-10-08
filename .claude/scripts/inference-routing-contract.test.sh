#!/usr/bin/env bash
# Evaluate the deployed policy with synthetic observations; never launch inference.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_ROOT="${INFERENCE_ROUTING_PLUGIN_ROOT:-$ROOT/libraries/agent-plugins/plugins/agentic-engineering}"
EVALUATOR="$PLUGIN_ROOT/scripts/evaluate-inference-routing.sh"
POLICY="$ROOT/.claude/plugin-consumption/inference-routing.policy.json"
TMP="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$TMP"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then
    echo "inference-routing-contract.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    exit 1
  fi
}
trap on_exit EXIT
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
# An input that cannot be read or parsed is UNKNOWN (2), never a finding (1): nothing was examined.
# A readable input that says the wrong thing is a finding.
[[ -r "$GUIDE" && -r "$RUNTIME_DOC" ]] ||
  { echo 'UNKNOWN accepted parent routes: contract files unreadable' >&2; exit 2; }

# Check that a registry file holds an instances map. Argument: the registry file.
check_registry() {
  local status=0
  [[ -r "$1" ]] || { echo 'UNKNOWN accepted parent routes: the instance registry is unreadable'; return 2; }
  jq -e '.instances | type == "object"' "$1" > /dev/null 2>&1 || status=$?
  case "$status" in
    0) ;;
    1) echo 'FAIL accepted parent routes: the instance registry has no instances map'; return 1 ;;
    *) echo 'UNKNOWN accepted parent routes: the instance registry could not be parsed'; return 2 ;;
  esac
}

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
  [[ -r "$1" ]] || { echo 'UNKNOWN accepted parent routes: guide unreadable'; return 2; }
  section="$(awk '
    /^## Inference routing$/ { on = 1; next }
    on && /^## / { exit }
    on { print }' "$1")" || { echo 'UNKNOWN accepted parent routes: guide unreadable'; return 2; }
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


# The accepted rows, exactly as the maintainer decided them: one "instance|route|decision" per
# line. The table must hold exactly these rows. Listing a row lets a scheduled run work without
# the enforcement proof, so a row is authorised by a reviewed change to this list in the same
# pull request, never by table text that merely looks like a decision.
accepted_rows='codex-local|Engineer and improver schedules, on the model fixed in each scheduler entry and the ChatGPT subscription sign-in|Maintainer, 2026-10-07, monorepo#3314'

# Print one trimmed cell of a table row. Arguments: the row, the awk field number.
cell() {
  printf '%s\n' "$1" | awk -F'|' -v n="$2" '{ gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n }'
}

# Check the accepted-routes table and the rules beside it. Arguments: the runtime document, and
# optionally the decided rows (default: the list above). Each rule is read where agents resolve
# it: the startup rule in the document's introduction, the row rule and the table in the
# Accepted scheduled parent routes section.
check_routes() {
  local doc="$1" allowed="${2-$accepted_rows}"
  local intro section text phrase rows row fields key id registered seen=''
  [[ -r "$doc" ]] || { echo 'UNKNOWN accepted parent routes: runtime document unreadable'; return 2; }
  intro="$(awk '/^## / { exit } { print }' "$doc")" ||
    { echo 'UNKNOWN accepted parent routes: runtime document unreadable'; return 2; }
  text="$(printf '%s\n' "$intro" | flatten)"
  for phrase in \
    'Outside a listed route, missing pre-inference controls hold the affected startup, resume or fallback' \
    'A listed route is never held for them'; do
    case "$text" in
      *"$phrase"*) ;;
      *) printf 'FAIL accepted parent routes: runtime document lost: %s\n' "$phrase"; return 1 ;;
    esac
  done
  section="$(awk '
    /^## Accepted scheduled parent routes$/ { on = 1; next }
    on && /^## / { exit }
    on { print }' "$doc")" ||
    { echo 'UNKNOWN accepted parent routes: runtime document unreadable'; return 2; }
  [[ -n "$section" ]] ||
    { echo 'FAIL accepted parent routes: the runtime document has no Accepted scheduled parent routes section'; return 1; }
  text="$(printf '%s\n' "$section" | flatten)"
  phrase='a row accepts the parent run alone and enables no route, child, switch or fallback'
  case "$text" in
    *"$phrase"*) ;;
    *) printf 'FAIL accepted parent routes: runtime document lost: %s\n' "$phrase"; return 1 ;;
  esac
  # The table's data rows (neither the header nor the separator row), backticks removed.
  rows="$(printf '%s\n' "$section" |
    awk '/^\|/ && !/^\| *Instance *\|/ && !/^\|[-| ]+$/ { print }' | tr -d '\140')"
  [[ -n "$rows" ]] || { echo 'FAIL accepted parent routes: no accepted row found'; return 1; }
  # Every row in the table is a decided row, once.
  while IFS= read -r row; do
    # "| a | b | c |" splits into five fields; any other count is a row this check cannot read.
    fields="$(printf '%s\n' "$row" | awk -F'|' '{ print NF }')"
    [[ "$fields" == 5 ]] ||
      { printf 'FAIL accepted parent routes: row is not three cells: %s\n' "$row"; return 1; }
    key="$(cell "$row" 2)|$(cell "$row" 3)|$(cell "$row" 4)"
    grep -Fxq -- "$key" <<<"$allowed" ||
      { printf 'FAIL accepted parent routes: not a decided row: %s\n' "$key"; return 1; }
    if grep -Fxq -- "$key" <<<"$seen"; then
      printf 'FAIL accepted parent routes: row listed twice: %s\n' "$key"
      return 1
    fi
    seen="$seen$key"$'\n'
  done <<ROWS
$rows
ROWS
  # Every decided row is in the table, and names a registered instance.
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    id="${key%%|*}"
    grep -Fxq -- "$key" <<<"$seen" ||
      { printf 'FAIL accepted parent routes: decided row missing: %s\n' "$id"; return 1; }
    # jq exits 1 for "not registered" and above 1 when it could not read or parse the registry.
    registered=0
    jq -e --arg id "$id" '.instances | has($id)' "$REGISTRY" > /dev/null 2>&1 || registered=$?
    case "$registered" in
      0) ;;
      1) printf 'FAIL accepted parent routes: %s is not a registered instance\n' "$id"; return 1 ;;
      *) echo 'UNKNOWN accepted parent routes: the instance registry could not be read'; return 2 ;;
    esac
  done <<ALLOWED
$allowed
ALLOWED
}

# The live contract must pass. A checker's own status is kept: 1 is a finding, 2 is UNKNOWN.
status=0
out="$(check_registry "$REGISTRY")" || status=$?
[[ "$status" == 0 ]] || { printf '%s\n' "$out" >&2; exit "$status"; }
out="$(check_guide "$GUIDE")" || status=$?
[[ "$status" == 0 ]] || { printf '%s\n' "$out" >&2; exit "$status"; }
printf 'PASS accepted parent route rule and its limits\n'
out="$(check_routes "$RUNTIME_DOC")" || status=$?
[[ "$status" == 0 ]] || { printf '%s\n' "$out" >&2; exit "$status"; }
printf 'PASS accepted parent routes are exactly the decided rows\n'

# Run a checker and require one outcome: the given status and a diagnostic naming its own reason.
# Arguments: case name, expected status, expected diagnostic text, then the checker and its
# arguments.
expects() {
  local name="$1" want_status="$2" want="$3" got got_status=0
  shift 3
  got="$("$@")" || got_status=$?
  if [[ "$got_status" != "$want_status" ]]; then
    printf 'FAIL accepted parent routes control %s: status %s, want %s: %s\n' \
      "$name" "$got_status" "$want_status" "$got" >&2
    exit 1
  fi
  case "$got" in
    *"$want"*) printf 'PASS control %s\n' "$name" ;;
    *) printf 'FAIL accepted parent routes control %s: wrong reason: %s\n' "$name" "$got" >&2
       exit 1 ;;
  esac
}
# A fixture that must be refused as a finding. Arguments: case name, expected diagnostic text,
# then the checker and its arguments.
refuses() {
  local name="$1" want="$2"
  shift 2
  expects "$name" 1 "$want" "$@"
}

# Print a runtime document: the startup rule in the introduction, then the section with its row
# rule and one table row per "instance|route|decision" argument. A row argument is written as
# given, so a fixture can carry a fourth cell.
routes_doc() {
  printf '%s\n\n' 'Outside a listed route, missing pre-inference controls hold the affected startup,' \
    'resume or fallback. A listed route is never held for them.'
  printf '%s\n\n%s\n\n%s\n%s\n' '## Accepted scheduled parent routes' \
    'Only the maintainer adds a row; a row accepts the parent run alone and enables no route, child, switch or fallback.' \
    '| Instance | Accepted route | Decision |' '|---|---|---|'
  local row
  for row; do
    printf '| %s |\n' "$(printf '%s' "$row" | sed 's/|/ | /g')"
  done
  printf '\n%s\n' '## Native verification procedure'
}
codex_row="$accepted_rows"
codex_route="$(cell "|$codex_row|" 3)"
codex_decision="$(cell "|$codex_row|" 4)"
# A second row, for fixtures only: it is not a decided row unless a fixture's own list says so.
other_route='Engineer schedule, on the model fixed in its scheduler entry and the Example subscription sign-in'
other_row="claude-local|$other_route|Maintainer, 2026-11-01, monorepo#1"
two_rows="$codex_row"$'\n'"$other_row"

# The fixture builder itself must produce a document the checker accepts, or every refusal below
# would prove nothing. Two decided rows prove the list is not limited to one.
routes_doc "$codex_row" > "$TMP/routes-good.md"
expects 'valid fixture' 0 '' check_routes "$TMP/routes-good.md"
routes_doc "$codex_row" "$other_row" > "$TMP/routes-two.md"
expects 'valid fixture with two decided rows' 0 '' check_routes "$TMP/routes-two.md" "$two_rows"

# A row is accepted only when it is a decided row, whatever it looks like.
refuses 'well-formed row that was never decided' 'not a decided row: claude-local|' \
  check_routes "$TMP/routes-two.md"
routes_doc "codex-local|$codex_route or API billing|$codex_decision" > "$TMP/r.md"
refuses 'route with API billing' 'not a decided row: codex-local|' check_routes "$TMP/r.md"
routes_doc "codex-local|$codex_route, and its children and fallback|$codex_decision" > "$TMP/r.md"
refuses 'route with children and fallback' 'not a decided row: codex-local|' check_routes "$TMP/r.md"
routes_doc "codex-local|Engineer and improver schedules, on any model and the ChatGPT subscription sign-in|$codex_decision" > "$TMP/r.md"
refuses 'route on any model' 'not a decided row: codex-local|' check_routes "$TMP/r.md"
routes_doc "codex-local|Improver schedule, on the model fixed in its scheduler entry and the ChatGPT subscription sign-in|$codex_decision" > "$TMP/r.md"
refuses 'codex row narrowed to the improver' 'not a decided row: codex-local|' check_routes "$TMP/r.md"
routes_doc "codex-local|$codex_route|Maintainer, 2026-11-01, monorepo#1" > "$TMP/r.md"
refuses 'codex row under another decision' 'not a decided row: codex-local|' check_routes "$TMP/r.md"
routes_doc "codex-local|$codex_route|also its children|$codex_decision" > "$TMP/r.md"
refuses 'fourth cell' 'row is not three cells' check_routes "$TMP/r.md"
routes_doc "$codex_row" "$codex_row" > "$TMP/r.md"
refuses 'row listed twice' 'row listed twice' check_routes "$TMP/r.md"

# Every decided row must be there, for a registered instance.
routes_doc "$other_row" > "$TMP/r.md"
refuses 'decided row missing' 'decided row missing: codex-local' check_routes "$TMP/r.md" "$two_rows"
unregistered_row="unregistered-example|$other_route|Maintainer, 2026-11-01, monorepo#1"
routes_doc "$codex_row" "$unregistered_row" > "$TMP/r.md"
refuses 'decided row for an unregistered instance' 'unregistered-example is not a registered instance' \
  check_routes "$TMP/r.md" "$codex_row"$'\n'"$unregistered_row"

# The table and the rules beside it, each in its own place.
routes_doc > "$TMP/r.md"
refuses 'empty table' 'no accepted row found' check_routes "$TMP/r.md"
sed 's/^## Accepted scheduled parent routes$/## Something else/' "$TMP/routes-good.md" > "$TMP/r.md"
refuses 'table under another heading' 'has no Accepted scheduled parent routes section' \
  check_routes "$TMP/r.md"
sed 's/^Outside a listed route, missing/Missing/' "$TMP/routes-good.md" > "$TMP/r.md"
refuses 'startup hold not scoped' 'runtime document lost: Outside a listed route' check_routes "$TMP/r.md"
{ printf '%s\n\n' 'An introduction without the rule.'; sed 's/^## Native verification procedure$//' "$TMP/routes-good.md" |
  awk '/^Outside a listed route/ { held = 1 } held && /^## Accepted/ { held = 0 } !held { print }'
  printf '%s\n\n%s\n%s\n' '## Native verification procedure' \
    'Outside a listed route, missing pre-inference controls hold the affected startup,' \
    'resume or fallback. A listed route is never held for them.'; } > "$TMP/r.md"
refuses 'startup rule outside the introduction' 'runtime document lost: Outside a listed route' \
  check_routes "$TMP/r.md"
sed 's/a row accepts the parent run alone and enables no route/a row accepts the run and its children and enables no route/' "$TMP/routes-good.md" > "$TMP/r.md"
refuses 'row scope widened' 'runtime document lost: a row accepts the parent run alone' check_routes "$TMP/r.md"

# An input that cannot be read or parsed is UNKNOWN; a readable one that is wrong is a finding.
expects 'unreadable runtime document' 2 'runtime document unreadable' check_routes "$TMP/absent.md"
expects 'unreadable guide' 2 'guide unreadable' check_guide "$TMP/absent.md"
expects 'unreadable registry' 2 'the instance registry is unreadable' check_registry "$TMP/absent.json"
printf '%s' '{not json' > "$TMP/registry.json"
expects 'registry that does not parse' 2 'the instance registry could not be parsed' \
  check_registry "$TMP/registry.json"
printf '%s\n' '{"instances": []}' > "$TMP/registry.json"
refuses 'registry without an instances map' 'the instance registry has no instances map' \
  check_registry "$TMP/registry.json"
printf '%s\n' '{"version": 1}' > "$TMP/registry.json"
refuses 'registry with no instances at all' 'the instance registry has no instances map' \
  check_registry "$TMP/registry.json"

# Guide controls are cut from the live guide, so each first proves that it changed its input.
# Arguments: case name, sed expression, expected diagnostic text.
guide_refuses() {
  sed "$2" "$GUIDE" > "$TMP/g.md"
  if cmp -s "$GUIDE" "$TMP/g.md"; then
    printf 'FAIL accepted parent routes control %s: the fixture equals the live guide\n' "$1" >&2
    exit 1
  fi
  refuses "$1" "$3" check_guide "$TMP/g.md"
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
refuses 'guide rule moved out of its section' 'guide lost: Outside an accepted route' \
  check_guide "$TMP/g.md"
completed=1
