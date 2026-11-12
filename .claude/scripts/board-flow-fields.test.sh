#!/usr/bin/env bash
#
# Self-test for board-flow-fields.sh (monorepo#4992). The checks that matter are the fail-closed
# ones: a board read that fails, returns the wrong shape, uses a status name the board does not
# have, or comes back empty must exit 2 (UNKNOWN), never 0. A clean pass on a read that examined
# nothing is the exact failure this check exists to prevent.
#
# Board access goes through the BOARD_FLOW_FIXTURE seam or a fake `gh` on PATH; no network.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/board-flow-fields.sh"
tmp="$(mktemp -d)"
completed=0
# bash 3.2 can report a set -u abort as exit 0 once an EXIT trap runs, so require completion.
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
on_exit() {
  local status=$?
  rm -rf "$tmp"
  if [ "${completed}" != 1 ] && [ "${status}" = 0 ]; then
    echo "board-flow-fields.test.sh: aborted before finishing; reporting failure rather than a clean pass" >&2
    exit 1
  fi
}
trap on_exit EXIT

pass=0
fail=0
STATUS='🏃🏻‍♂️ In Progress'

check() { # check <name> <expected-exit> <actual-exit> <output> [needle] [absent-needle]
  local name="$1" want="$2" got="$3" hay="$4" needle="${5:-}" absent="${6:-}"
  if [ "$want" != "$got" ]; then
    printf 'FAIL %s: expected exit %s, got %s\n  output: %s\n' "$name" "$want" "$got" "$hay" >&2
    fail=$((fail + 1)); return
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$hay"; then
    printf 'FAIL %s: output missing %q\n  got: %s\n' "$name" "$needle" "$hay" >&2
    fail=$((fail + 1)); return
  fi
  if [ -n "$absent" ] && grep -qF -- "$absent" <<<"$hay"; then
    printf 'FAIL %s: output unexpectedly has %q\n  got: %s\n' "$name" "$absent" "$hay" >&2
    fail=$((fail + 1)); return
  fi
  printf 'ok   %s\n' "$name"
  pass=$((pass + 1))
}

# item <repo> <number> <first-started|""> <blocked-since|""> <open-blockers>
item() {
  jq -nc --arg r "$1" --argjson n "$2" --arg fs "$3" --arg bs "$4" --argjson o "$5" '
    {fs: (if $fs == "" then null else {date: $fs} end),
     bs: (if $bs == "" then null else {date: $bs} end),
     content: {number: $n, repository: {name: $r}, issueDependenciesSummary: {blockedBy: $o}}}'
}

fixture() { # fixture <file> <total> <options-json> <item>...
  local file="$1" total="$2" options="$3"; shift 3
  printf '%s\n' "$@" | jq -s --argjson t "$total" --argjson o "$options" \
    '{total: $t, options: $o, items: map(select(. != null))}' > "$file"
}

run() { # run <fixture> [args...] → sets out, rc
  local f="$1"; shift
  set +e
  out=$(BOARD_FLOW_FIXTURE="$f" bash "$script" "$@" 2>&1)
  rc=$?
  set -e
}

opts=$(jq -nc --arg s "$STATUS" '["📥 Backlog", $s, "✅ Done"]')

# 1. Every card complete, a blocked card with Blocked since, an unblocked card without it: clean.
fixture "$tmp/clean.json" 10 "$opts" \
  "$(item ksail 1 2026-11-01 "" 0)" "$(item platform 2 2026-11-02 2026-11-03 1)"
run "$tmp/clean.json"
check "complete cards pass" 0 "$rc" "$out" "in_progress=2 missing-first-started=0 missing-blocked-since=0 stale-blocked-since=0"

# 2. Each finding kind is reported against the right card, and only that card.
fixture "$tmp/findings.json" 10 "$opts" \
  "$(item ksail 1 "" "" 0)" "$(item platform 2 2026-11-02 "" 2)" \
  "$(item monorepo 3 2026-11-02 2026-11-04 0)" "$(item world-at-ruin 4 2026-11-01 2026-11-02 1)"
run "$tmp/findings.json"
check "missing First started is a finding" 1 "$rc" "$out" "missing-first-started ksail#1" "missing-first-started platform#2"
check "open blocker without Blocked since is a finding" 1 "$rc" "$out" "missing-blocked-since platform#2" "missing-blocked-since ksail#1"
check "Blocked since with every blocker closed is stale" 1 "$rc" "$out" "stale-blocked-since monorepo#3" "world-at-ruin#4"
check "counts match the findings" 1 "$rc" "$out" "in_progress=4 missing-first-started=1 missing-blocked-since=1 stale-blocked-since=1"

# 3. --summary keeps the counts and the exit code but drops the per-card lines.
run "$tmp/findings.json" --summary
check "--summary prints counts only" 1 "$rc" "$out" "missing-first-started=1" "ksail#1"

# 3b. An archived card is off the board: neither counted nor reported.
archived=$(item platform 9 "" "" 1 | jq -c '. + {isArchived: true}')
fixture "$tmp/archived.json" 10 "$opts" "$(item ksail 1 2026-11-01 "" 0)" "$archived"
run "$tmp/archived.json"
check "an archived card is ignored" 0 "$rc" "$out" "in_progress=1 missing-first-started=0" "platform#9"

# 4. An empty In Progress column on a readable board is a real, clean answer.
fixture "$tmp/empty-column.json" 10 "$opts"
run "$tmp/empty-column.json"
check "an empty column on a readable board passes" 0 "$rc" "$out" "in_progress=0"

# 5. Fail-closed controls: each must be UNKNOWN for its own reason.
fixture "$tmp/empty-board.json" 0 "$opts"
run "$tmp/empty-board.json"
check "an empty unfiltered board is UNKNOWN" 2 "$rc" "$out" "unfiltered board returned no items"

fixture "$tmp/no-option.json" 10 '["📥 Backlog","In Progress"]' "$(item ksail 1 "" "" 0)"
run "$tmp/no-option.json"
check "a missing Status option is UNKNOWN, not clean" 2 "$rc" "$out" "does not exist, so the filter cannot be trusted"

jq -n --argjson o "$opts" '{total: 10, options: $o, items: [{fs: null, bs: null, content: {}}]}' > "$tmp/no-content.json"
run "$tmp/no-content.json"
check "a card that is not an issue read is UNKNOWN" 2 "$rc" "$out" "lacks its issue number"

printf '{"total": 10, "options": [], "items": "x"}' > "$tmp/shape.json"
run "$tmp/shape.json"
check "a malformed read is UNKNOWN" 2 "$rc" "$out" "not the expected shape"

run "$tmp/absent.json"
check "an unreadable fixture is UNKNOWN" 2 "$rc" "$out" "fixture unreadable"

set +e; out=$(bash "$script" --bogus 2>&1); rc=$?; set -e
check "an unknown argument is a usage error" 2 "$rc" "$out" "unknown argument"

# 6. The live path, through a fake gh: two item pages are combined, and a failed read is UNKNOWN.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Fake gh: answers the control query and the paginated item query from env-selected files.
args="$*"
case "$args" in
  *--paginate*)
    printf '%s\n' "$args" > "$FAKE_ARGS_LOG"
    [ "${FAKE_ITEMS_FAIL:-0}" = 1 ] && exit 1
    cat "$FAKE_PAGES" ;;
  *)
    [ "${FAKE_META_FAIL:-0}" = 1 ] && exit 1
    cat "$FAKE_META" ;;
esac
STUB
chmod +x "$tmp/bin/gh"
jq -nc --argjson o "$opts" '{total: 10, options: $o}' > "$tmp/meta.json"
{ jq -nc --argjson a "$(item ksail 1 "" "" 0)" '[$a]'
  jq -nc --argjson b "$(item platform 2 2026-11-01 "" 1)" '[$b]'; } > "$tmp/pages.json"

live() {
  set +e
  out=$(PATH="$tmp/bin:$PATH" FAKE_META="$tmp/meta.json" FAKE_PAGES="$tmp/pages.json" \
    FAKE_ARGS_LOG="$tmp/args.log" "$@" bash "$script" 2>&1)
  rc=$?
  set -e
}
live env
check "live pages are combined" 1 "$rc" "$out" "in_progress=2 missing-first-started=1 missing-blocked-since=1"

# The stub answers any query, so pin the parts of the live query a silent edit would break:
# the exact status filter, pagination through `$endCursor`, and the fields the checks read.
query_args=$(cat "$tmp/args.log" 2>/dev/null || true)
# shellcheck disable=SC2016 # The needles are literal GraphQL text, not shell expansions.
for needle in "q=status:\"${STATUS}\" is:open is:issue" 'after:$endCursor' \
  'pageInfo{hasNextPage endCursor}' 'name:"First started"' 'name:"Blocked since"' \
  'isArchived' 'issueDependenciesSummary{blockedBy}'; do
  check "the live item query carries ${needle}" 0 0 "$query_args" "$needle"
done
live env FAKE_META_FAIL=1
check "a failed control read is UNKNOWN" 2 "$rc" "$out" "board control read failed"
live env FAKE_ITEMS_FAIL=1
check "a failed item read is UNKNOWN" 2 "$rc" "$out" "In Progress item read failed"

echo "board-flow-fields.test.sh: ${pass} passed, ${fail} failed"
completed=1
[ "$fail" -eq 0 ]
