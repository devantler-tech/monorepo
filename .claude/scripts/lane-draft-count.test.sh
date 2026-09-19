#!/usr/bin/env bash
# lane-draft-count.test.sh — RED/GREEN coverage for lane-draft-count.sh (monorepo#2562).
#
# The cases that matter most are the fail-closed ones: a partial read must never print a number,
# because a floor below the cap reads exactly like permission to open another draft.
#
# Fixtures are synthetic and hermetic: every case uses the LANE_DRAFTS_* seams and a registry file
# written here, so gh is never invoked.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/lane-draft-count.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0

cat > "$FIX/registry.json" <<'EOF'
{"version":1,"instances":{"claude-local":{"namespace":"claude"},"codex-local":{"namespace":"codex"}}}
EOF

# drafts <file> <headRefName:cross>... — writes a fixture array
drafts() {
  local out=$1; shift
  printf '%s\n' "$@" | jq -R 'split(":") | {headRefName: .[0], isCrossRepository: (.[1] == "x")}' | jq -s . > "$out"
}

# check <name> <want-rc> <want-stdout-substring> <total> <fixture> [args...]
check() {
  local name=$1 want_rc=$2 want=$3 total=$4 fixture=$5; shift 5
  local out rc=0
  out=$(LANE_DRAFTS_JSON="$fixture" LANE_DRAFTS_TOTAL="$total" \
    bash "$SCRIPT" --instances "$FIX/registry.json" "$@" 2>/dev/null) || rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: $name (rc=$rc want=$want_rc)"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

drafts "$FIX/three.json" claude/a-1 claude/b-2 claude/c-3 codex/d-4 renovate/e
check "within cap exits 0 with the lane count" 0 "lane=claude drafts=3 cap=20 verdict=WITHIN" 5 "$FIX/three.json" --lane claude
check "every registered lane and the remainder are counted" 0 "open_drafts: claude=3 codex=1 other=1 total=5" 5 "$FIX/three.json" --lane codex
check "exactly at the cap is still WITHIN" 0 "verdict=WITHIN" 5 "$FIX/three.json" --lane claude --cap 3
check "one over the cap is OVER and exits 1" 1 "lane=claude drafts=3 cap=2 verdict=OVER" 5 "$FIX/three.json" --lane claude --cap 2

# Fail-closed: a read that saw fewer drafts than the search reported is a floor, not a count.
check "a truncated read is UNKNOWN" 2 "verdict=UNKNOWN" 6 "$FIX/three.json" --lane claude
check "a truncated read prints no count" 2 "verdict=UNKNOWN" 900 "$FIX/three.json" --lane claude --cap 100
out=$(LANE_DRAFTS_JSON="$FIX/three.json" LANE_DRAFTS_TOTAL=6 bash "$SCRIPT" --instances "$FIX/registry.json" --lane claude 2>/dev/null || true)
if printf '%s' "$out" | grep -q "drafts="; then fail=$((fail + 1)); echo "FAIL: UNKNOWN leaked a number"; else pass=$((pass + 1)); fi
check "a non-numeric total is UNKNOWN" 2 "verdict=UNKNOWN" "abc" "$FIX/three.json" --lane claude

# Attribution: the lane is the branch namespace of a same-repository branch, matched exactly.
drafts "$FIX/lookalike.json" claude/a-1 claudex/b-2 claude-x/c-3 claude/fork-4:x
check "lookalike prefixes and fork branches are not the lane" 0 "open_drafts: claude=1 codex=0 other=3 total=4" 4 "$FIX/lookalike.json" --lane claude

# Usage and registry errors are UNKNOWN, never a verdict.
check "an unregistered lane is UNKNOWN" 2 "verdict=UNKNOWN" 5 "$FIX/three.json" --lane cursor
check "a missing lane is UNKNOWN" 2 "verdict=UNKNOWN" 5 "$FIX/three.json"
check "a non-numeric cap is UNKNOWN" 2 "verdict=UNKNOWN" 5 "$FIX/three.json" --lane claude --cap many
echo '{"version":1,"instances":{}}' > "$FIX/empty.json"
out=$(LANE_DRAFTS_JSON="$FIX/three.json" LANE_DRAFTS_TOTAL=5 bash "$SCRIPT" --instances "$FIX/empty.json" --lane claude 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: empty registry rc=$rc"; fi
echo '[]' > "$FIX/none.json"
check "no open drafts at all is WITHIN with zero" 0 "lane=claude drafts=0 cap=20 verdict=WITHIN" 0 "$FIX/none.json" --lane claude

echo "lane-draft-count: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
