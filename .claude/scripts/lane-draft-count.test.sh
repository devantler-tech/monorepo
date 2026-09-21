#!/usr/bin/env bash
# lane-draft-count.test.sh — RED/GREEN coverage for lane-draft-count.sh (monorepo#2562).
#
# The cases that matter most are the fail-closed ones: an unproven read must never print a number,
# because a count below the cap reads exactly like permission to open another draft.
#
# Fixtures are synthetic and hermetic: every case uses the LANE_* seams and a registry file written
# here, so gh is never invoked.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/lane-draft-count.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0

cat > "$FIX/registry.json" <<'EOF'
{"version":1,"instances":{"claude-local":{"namespace":"claude","authors":{"rest":"devantler"}},"codex-local":{"namespace":"codex","authors":{"rest":"devantler"}}}}
EOF

# drafts <file> <headRefName[:x|:a]>... — writes a fixture array; ":x" marks a fork branch and
# ":a" an author other than the registered identity
drafts() {
  local out=$1; shift
  printf '%s\n' "$@" | jq -R 'split(":") | {headRefName: .[0], isCrossRepository: (.[1] == "x"),
      author: {login: (if .[1] == "a" then "someone-else" else "devantler" end)}}' \
    | jq -s 'to_entries | map(.value + {id: ("PR_" + (.key | tostring))})' > "$out"
}

# run <fixture> [args...] — every seam defaults to a complete, stable read; a case overrides one
# seam at a time via the environment.
run() {
  local fixture=$1; shift
  LANE_DRAFTS_JSON="$fixture" \
  LANE_DRAFTS_JSON_2="${T_SECOND:-$fixture}" \
  LANE_REPOS_EXPECTED="${T_EXPECTED:-26}" \
  LANE_REPOS_VISIBLE="${T_VISIBLE:-26}" \
  LANE_REPOS_VISIBLE_2="${T_VISIBLE_2:-${T_VISIBLE:-26}}" \
  LANE_REPOS_VISIBLE_3="${T_VISIBLE_3:-${T_VISIBLE_2:-${T_VISIBLE:-26}}}" \
    bash "$SCRIPT" --instances "${T_REGISTRY:-$FIX/registry.json}" "$@" 2>/dev/null
}

# check <name> <want-rc> <want-stdout-substring> <fixture> [args...]
check() {
  local name=$1 want_rc=$2 want=$3 fixture=$4; shift 4
  local out rc=0
  out=$(run "$fixture" "$@") || rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want"; then
    if [ "$want_rc" -eq 2 ] && printf '%s' "$out" | grep -q "drafts="; then
      fail=$((fail + 1)); echo "FAIL: $name (UNKNOWN leaked a count)"; return
    fi
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: $name (rc=$rc want=$want_rc)"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

drafts "$FIX/three.json" claude/a-1 claude/b-2 claude/c-3 codex/d-4 renovate/e
check "within cap exits 0 with the lane count" 0 "lane=claude drafts=3 cap=20 verdict=WITHIN" "$FIX/three.json" --lane claude
check "every registered lane and the remainder are counted" 0 "open_drafts: claude=3 codex=1 other=1 total=5" "$FIX/three.json" --lane codex
check "exactly at the cap is still WITHIN" 0 "verdict=WITHIN" "$FIX/three.json" --lane claude --cap 3
check "one over the cap is OVER and exits 1" 1 "lane=claude drafts=3 cap=2 verdict=OVER" "$FIX/three.json" --lane claude --cap 2
echo '[]' > "$FIX/none.json"
check "no open drafts at all is WITHIN with zero" 0 "lane=claude drafts=0 cap=20 verdict=WITHIN" "$FIX/none.json" --lane claude

# Coverage: a repository the credential cannot list contributes nothing.
T_VISIBLE=24 check "a credential blind to some repositories is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane claude
T_EXPECTED=x check "an unreadable private-repository total is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane claude
T_VISIBLE_2=27 check "a repository appearing between the two passes is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane claude
T_VISIBLE_3=27 check "a repository appearing after the last scan is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane claude

# The default cap and the contract's number are two copies of one decision: if the row is
# remeasured and this default is not, the script keeps allowing drafts against the old limit.
contract_cap=$(grep -oE 'more than \*{0,2}[0-9]+\*{0,2} open drafts' "$SCRIPT_DIR/../../AGENTS.md" | grep -oE '[0-9]+' | head -1 || true)
script_cap=$(grep -oE '^CAP=[0-9]+' "$SCRIPT" | grep -oE '[0-9]+' || true)
if [ -n "$contract_cap" ] && [ "$contract_cap" = "$script_cap" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: default cap $script_cap does not match the AGENTS.md row ($contract_cap)"
fi
# …and the default must actually be the value the boundary uses, not just a variable that matches.
out=$(run "$FIX/three.json" --lane claude --cap "$script_cap")
at_cap=$(printf '%s' "$out" | grep -oE 'cap=[0-9]+')
if [ "$at_cap" = "cap=$script_cap" ] && printf '%s' "$(run "$FIX/three.json" --lane claude)" | grep -qF "$at_cap"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: the default cap is not the one the verdict uses ($at_cap)"
fi

# Stability: the two full reads must agree on every draft's attribution.
jq '.[4].id = "PR_new"' "$FIX/three.json" > "$FIX/churn.json"
T_SECOND="$FIX/churn.json" check "one draft closing while another opens is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane claude
jq '.[4].headRefName = "claude/renamed-5"' "$FIX/three.json" > "$FIX/renamed.json"
T_SECOND="$FIX/renamed.json" check "a branch renamed between reads is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane claude
jq '.[4].id = .[0].id' "$FIX/three.json" > "$FIX/dup.json"
check "a draft appearing twice in one read is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/dup.json" --lane claude

# Attribution: same-repository branch in the lane's namespace, by the lane's registered author.
drafts "$FIX/lookalike.json" claude/a-1 claudex/b-2 claude-x/c-3 claude/fork-4:x
check "lookalike prefixes and fork branches are not the lane" 0 "open_drafts: claude=1 codex=0 other=3 total=4" "$FIX/lookalike.json" --lane claude
drafts "$FIX/impostor.json" claude/a-1 claude/b-2:a claude/c-3:a
check "a lane-prefixed branch by another author is not the lane" 0 "open_drafts: claude=1 codex=0 other=2 total=3" "$FIX/impostor.json" --lane claude

# Usage and registry errors are UNKNOWN, never a verdict.
check "an unregistered lane is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane cursor
check "a missing lane is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json"
check "a non-numeric cap is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane claude --cap many
echo '{"version":1,"instances":{}}' > "$FIX/empty.json"
T_REGISTRY="$FIX/empty.json" check "an empty registry is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane claude
echo '{"version":1,"instances":{"claude-local":{"namespace":"claude"}}}' > "$FIX/noauthor.json"
T_REGISTRY="$FIX/noauthor.json" check "a registry lane without an author is UNKNOWN" 2 "verdict=UNKNOWN" "$FIX/three.json" --lane claude

# The run loop must consult this helper before opening a draft, and fail closed on it. The count is
# the orchestrator's to read: the survey subagent's read-only guard declares no route to this
# script, so a digest line produced there would always be UNKNOWN and block every lane's intake.
SKILL="$SCRIPT_DIR/../skills/portfolio-maintenance/SKILL.md"
# Read each section on its own: the same phrases under `## 1. Survey` would be the delegated
# surveyor's job, which cannot run the helper, so only `## 2. Select` may satisfy the pin.
section() { awk -v h="$1" '/^## /{on=(index($0,h)==1)} on' "$SKILL"; }
select_text=$(section "## 2. Select")
survey_text=$(section "## 1. Survey")
if [ -n "$select_text" ] && [ -n "$survey_text" ] &&
  printf '%s\n' "$select_text" | grep -Fq '.claude/scripts/lane-draft-count.sh --lane <your namespace>' &&
  printf '%s\n' "$select_text" | grep -Fq 'open **no** non-hotfix draft when' &&
  printf '%s\n' "$select_text" | grep -Fq 'own lane is `UNKNOWN` or `OVER`' &&
  ! printf '%s\n' "$survey_text" | grep -Fq 'lane-draft-count.sh'; then
  pass=$((pass + 1))
else
  echo 'FAIL: `## 2. Select` must require a fail-closed lane-draft-count check before a new draft, and `## 1. Survey` must not delegate it' >&2
  fail=$((fail + 1))
fi

echo "lane-draft-count: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
