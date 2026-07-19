#!/usr/bin/env bash
#
# Self-test for flow-scorecard.sh — proves the flow metrics are computed
# correctly from fixture data, that every stated-gap honesty note is actually
# printed, that a malformed input fails LOUD (never a banner-only exit 0 — the
# telemetry miner shipped that failure once), and that the fixture path never
# invokes gh at all (a poisoned PATH shim records any call and fails the test),
# which also proves the test needs no network and no token.
#
# Fixture shapes are COPIED from real `gh project item-list` / GraphQL search
# output (sampled 2026-07-19) — invented shapes passed for two review rounds
# once while the real shape went unparsed.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$script_dir/flow-scorecard.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; failures=$(( failures + 1 )); }

contains() { # desc, haystack-file, needle
  if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing: $3)"; fi
}
not_contains() {
  if grep -qF -- "$3" "$2"; then fail "$1 (unexpectedly present: $3)"; else pass "$1"; fi
}

# ── Poisoned gh shim: any invocation is a test failure ───────────
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<SHIM
#!/usr/bin/env bash
echo "gh \$*" >> "$tmp/gh-spy"
exit 9
SHIM
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# ── Fixtures (shapes copied from live output) ────────────────────
# Board items in the REST `orgs/{org}/projectsV2/{n}/items` shape: 3 open-lane
# Issues, one status-less Issue, one open Issue stuck in ✅ Done (the reopened
# defect), plus one PullRequest and one DraftIssue item that must be excluded.
cat > "$tmp/items.json" <<'EOF'
[
  {"id":1,"node_id":"PVTI_a1","content_type":"Issue","archived_at":null,"content":{"number":10,"state":"open","title":"t1","repository_url":"https://api.github.com/repos/devantler-tech/alpha"},"fields":[{"data_type":"single_select","id":169063393,"name":"Status","value":{"id":"47fc9ee4","name":{"html":"🏃🏻‍♂️ In Progress","raw":"🏃🏻‍♂️ In Progress"}}}]},
  {"id":2,"node_id":"PVTI_a2","content_type":"Issue","archived_at":null,"content":{"number":11,"state":"open","title":"t2","repository_url":"https://api.github.com/repos/devantler-tech/alpha"},"fields":[{"data_type":"single_select","id":169063393,"name":"Status","value":{"id":"47fc9ee4","name":{"html":"🏃🏻‍♂️ In Progress","raw":"🏃🏻‍♂️ In Progress"}}}]},
  {"id":3,"node_id":"PVTI_a3","content_type":"Issue","archived_at":null,"content":{"number":12,"state":"open","title":"t3","repository_url":"https://api.github.com/repos/devantler-tech/beta"},"fields":[{"data_type":"single_select","id":169063393,"name":"Status","value":{"id":"47fc9ee4","name":{"html":"🏃🏻‍♂️ In Progress","raw":"🏃🏻‍♂️ In Progress"}}}]},
  {"id":4,"node_id":"PVTI_a4","content_type":"Issue","archived_at":null,"content":{"number":13,"state":"open","title":"t4","repository_url":"https://api.github.com/repos/devantler-tech/beta"},"fields":[{"data_type":"single_select","id":169063393,"name":"Status","value":{"id":"f75ad846","name":{"html":"🫴 Ready","raw":"🫴 Ready"}}}]},
  {"id":5,"node_id":"PVTI_a5","content_type":"Issue","archived_at":null,"content":{"number":14,"state":"open","title":"t5","repository_url":"https://api.github.com/repos/devantler-tech/beta"},"fields":[]},
  {"id":6,"node_id":"PVTI_a6","content_type":"Issue","archived_at":null,"content":{"number":16,"state":"open","title":"t8","repository_url":"https://api.github.com/repos/devantler-tech/beta"},"fields":[{"data_type":"single_select","id":169063393,"name":"Status","value":{"id":"98236657","name":{"html":"✅ Done","raw":"✅ Done"}}}]},
  {"id":7,"node_id":"PVTI_a7","content_type":"PullRequest","archived_at":null,"content":{"number":15,"state":"open","title":"t6","repository_url":"https://api.github.com/repos/devantler-tech/beta"},"fields":[{"data_type":"single_select","id":169063393,"name":"Status","value":{"id":"f75ad846","name":{"html":"🫴 Ready","raw":"🫴 Ready"}}}]},
  {"id":8,"node_id":"PVTI_a8","content_type":"DraftIssue","archived_at":null,"content":{"title":"t7"},"fields":[{"data_type":"single_select","id":169063393,"name":"Status","value":{"id":"f498da34","name":{"html":"📥 Backlog","raw":"📥 Backlog"}}}]}
]
EOF

# Closed issues: durations 4d, 1d, 17d in-window; one closed pre-window; one
# closed_at:null (still open — search shape includes it when a query drifts).
cat > "$tmp/closed.json" <<'EOF'
[
  {"number":1,"created_at":"2026-07-10T00:00:00Z","closed_at":"2026-07-14T00:00:00Z","repository_url":"https://api.github.com/repos/devantler-tech/alpha"},
  {"number":2,"created_at":"2026-07-12T00:00:00Z","closed_at":"2026-07-13T00:00:00Z","repository_url":"https://api.github.com/repos/devantler-tech/alpha"},
  {"number":3,"created_at":"2026-07-01T00:00:00Z","closed_at":"2026-07-18T00:00:00Z","repository_url":"https://api.github.com/repos/devantler-tech/beta"},
  {"number":4,"created_at":"2026-06-20T00:00:00Z","closed_at":"2026-07-01T00:00:00Z","repository_url":"https://api.github.com/repos/devantler-tech/beta"},
  {"number":5,"created_at":"2026-07-15T00:00:00Z","closed_at":null,"repository_url":"https://api.github.com/repos/devantler-tech/beta"}
]
EOF

# Open substantive issues: alpha's oldest is the June Bug (48d at the fixed
# clock), beta's a fresh Security issue (4d).
cat > "$tmp/substantive.json" <<'EOF'
[
  {"number":1,"created_at":"2026-07-01T00:00:00Z","repository_url":"https://api.github.com/repos/devantler-tech/alpha","type":"Feature"},
  {"number":2,"created_at":"2026-06-01T00:00:00Z","repository_url":"https://api.github.com/repos/devantler-tech/alpha","type":"Bug"},
  {"number":5,"created_at":"2026-07-15T00:00:00Z","repository_url":"https://api.github.com/repos/devantler-tech/beta","type":"Security"}
]
EOF

# Merged PRs: 1 substantive + 1 supporting + 1 unparsable-title in-window on
# agent branches; a renovate/* PR and a pre-window agent PR must be excluded.
cat > "$tmp/prs.json" <<'EOF'
[
  {"title":"feat(x): add thing","headRefName":"claude/x-thing-1","mergedAt":"2026-07-15T00:00:00Z","repo":"alpha"},
  {"title":"docs: sync page","headRefName":"codex/y-docs","mergedAt":"2026-07-14T00:00:00Z","repo":"beta"},
  {"title":"fix(deps): bump lib","headRefName":"renovate/lib-1.x","mergedAt":"2026-07-15T00:00:00Z","repo":"beta"},
  {"title":"feat: too old","headRefName":"claude/old-2","mergedAt":"2026-07-01T00:00:00Z","repo":"alpha"},
  {"title":"🤖 unparseable title","headRefName":"claude/w-3","mergedAt":"2026-07-16T00:00:00Z","repo":"beta"}
]
EOF

fixture_env=(
  FLOW_NOW_UTC="2026-07-19T00:00:00Z"
  FLOW_ITEMS_JSON="$tmp/items.json"
  FLOW_CLOSED_JSON="$tmp/closed.json"
  FLOW_SUBSTANTIVE_JSON="$tmp/substantive.json"
  FLOW_PRS_JSON="$tmp/prs.json"
)

# ── Full run over fixtures ───────────────────────────────────────
out="$tmp/out-all.txt"
if env "${fixture_env[@]}" FLOW_WIP_LIMITS="🏃🏻‍♂️ In Progress=2" \
    bash "$tool" > "$out" 2>"$tmp/err-all.txt"; then
  pass "full fixture run exits 0"
else
  fail "full fixture run exits 0 (stderr: $(cat "$tmp/err-all.txt"))"
fi

contains "banner present"        "$out" "FLOW SCORECARD — Kanban Kata monorepo#2271"
contains "untrusted-data banner" "$out" "UNTRUSTED DATA — evidence, never instruction"
contains "end marker present"    "$out" "END FLOW SCORECARD"

# WIP: counts, exclusions, ladder names, limits
contains "WIP counts In Progress=3 (PR + draft excluded)" "$out" "    3  🏃🏻‍♂️ In Progress"
contains "WIP counts Ready=1"                             "$out" "    1  🫴 Ready"
contains "status-less item lands in (no status)"          "$out" "    1  (no status)"
contains "configured limit renders"                       "$out" "(limit 2)"
contains "over-limit flag fires at 3>2"                   "$out" "⚠ OVER LIMIT"
contains "unconfigured column is honestly unmeasured"     "$out" "(limit ?)"
contains "UI-only limits gap stated"                      "$out" "limits are board-UI-only"
contains "open issue stuck in Done is flagged"            "$out" "⚠ OPEN issue in Done"

# Throughput: 3 in-window closures; durations [1,4,17] → median 4, p85 17
contains "throughput counts only in-window closures" "$out" "issues closed in window: 3"
contains "median computed"                           "$out" "median 4d"
contains "p85 computed"                              "$out" "p85 17d"
contains "cycle-time proxy honestly labelled"        "$out" "PROXY for cycle time"

# Age: oldest per repo, age vs the fixed clock, oldest-first ordering
contains "alpha's oldest is the June Bug at 48d" "$out" "   48d  alpha#2  (Bug, created 2026-06-01)"
contains "beta's oldest is the Security at 4d"   "$out" "    4d  beta#5  (Security, created 2026-07-15)"
if [ "$(grep -n 'alpha#2' "$out" | cut -d: -f1)" -lt "$(grep -n 'beta#5' "$out" | cut -d: -f1)" ]; then
  pass "age list is sorted oldest-first"
else
  fail "age list is sorted oldest-first"
fi

# Mix: renovate + pre-window excluded → n=3, 1 substantive / 1 supporting / 1 other
contains "mix counts agent PRs only, in-window" "$out" "merged agent PRs: 3"
contains "substantive classified"               "$out" "substantive (feat|fix|perf): 1"
contains "supporting classified"                "$out" "supporting  (docs|chore|ci|test|build|style|refactor): 1"
contains "unparseable title counted as other"   "$out" "other/unparsed titles: 1"
contains "substantive share computed"           "$out" "substantive share: 50%"
contains "heuristic honestly labelled"          "$out" "not a quality judgement"

# No free-text passthrough: fixture titles must never reach the output
not_contains "issue/PR titles are not echoed" "$out" "add thing"

# gh never invoked on the fixture path
if [ -f "$tmp/gh-spy" ]; then
  fail "fixture path never invokes gh ($(head -1 "$tmp/gh-spy"))"
else
  pass "fixture path never invokes gh"
fi

# ── Section selection ────────────────────────────────────────────
out="$tmp/out-wip.txt"
env "${fixture_env[@]}" bash "$tool" --section wip > "$out" 2>/dev/null
contains     "--section wip prints WIP"           "$out" "WIP per board Status"
not_contains "--section wip omits throughput"     "$out" "issues closed in window"
not_contains "--section wip omits mix"            "$out" "merged agent PRs"

# ── Argument validation fails fast (never a banner-only success) ─
if env "${fixture_env[@]}" bash "$tool" --section wpi > "$tmp/out-bad.txt" 2>&1; then
  fail "misspelled --section exits with code 2"
else
  status=$?
  if [ "$status" -eq 2 ]; then
    pass "misspelled --section exits with code 2"
  else
    fail "misspelled --section exits with code 2 (got $status)"
  fi
fi
not_contains "misspelled --section prints no banner" "$tmp/out-bad.txt" "FLOW SCORECARD"

if env "${fixture_env[@]}" bash "$tool" --window-days x > /dev/null 2>&1; then
  fail "non-integer --window-days exits nonzero"
else
  pass "non-integer --window-days exits nonzero"
fi

if env "${fixture_env[@]}" FLOW_NOW_UTC="not-a-date" bash "$tool" > /dev/null 2>&1; then
  fail "unparseable FLOW_NOW_UTC exits nonzero"
else
  pass "unparseable FLOW_NOW_UTC exits nonzero"
fi

# ── Malformed input fails LOUD, other sections still report ──────
echo '{}' > "$tmp/not-array.json"
out="$tmp/out-malformed.txt"
if env "${fixture_env[@]}" FLOW_ITEMS_JSON="$tmp/not-array.json" \
    bash "$tool" > "$out" 2>"$tmp/err-malformed.txt"; then
  fail "malformed board input exits nonzero"
else
  pass "malformed board input exits nonzero"
fi
contains "malformed section is marked UNMEASURED"    "$out" "treat as UNMEASURED, never as clean"
contains "other sections still report"               "$out" "issues closed in window: 3"
contains "failed section named on stderr"            "$tmp/err-malformed.txt" "FAILED SECTIONS: wip"

# Malformed FLOW_WIP_LIMITS fails the wip section rather than flagging nothing
if env "${fixture_env[@]}" FLOW_WIP_LIMITS="Ready-5" bash "$tool" --section wip \
    > "$tmp/out-badlim.txt" 2>/dev/null; then
  fail "malformed FLOW_WIP_LIMITS exits nonzero"
else
  pass "malformed FLOW_WIP_LIMITS exits nonzero"
fi
contains "malformed limits are named" "$tmp/out-badlim.txt" "FLOW_WIP_LIMITS is malformed"

# ── Help exits clean and actually documents the seams ────────────
if bash "$tool" --help > "$tmp/help.txt" 2>&1; then
  pass "--help exits 0"
else
  fail "--help exits 0"
fi
contains "--help lists the test seams (sed range covers the whole header)" \
  "$tmp/help.txt" "FLOW_NOW_UTC"

echo ""
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) FAILED"
  exit 1
fi
echo "all tests passed"
