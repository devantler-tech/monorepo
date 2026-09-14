#!/usr/bin/env bash
#
# Self-test for board-archive.sh. Archiving the wrong item hides live work from
# the maintainer's board, so the cases that matter are the ones that must STAY:
# every keep reason in the rule has its own fixture item, and the candidate set
# is asserted exactly rather than by inclusion.
#
# All GitHub access is stubbed by a fake `gh` on PATH — no network, no live board.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/board-archive.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

check() { # check <name> <condition-exit> [detail]
  if [ "$2" = 0 ]; then
    printf 'ok   %s\n' "$1"
    pass=$((pass + 1))
  else
    printf 'FAIL %s%s\n' "$1" "${3:+: $3}" >&2
    fail=$((fail + 1))
  fi
}

# ── fixture: two pages covering every classification ──────────────────────
# With NOW=2026-09-14 and the default 30 days, the cutoff is 2026-08-15.
issue() { # issue <item> <number> <state> <closedAt|null> [parent-json] [total] [completed] [archived]
  jq -cn --arg item "$1" --argjson n "$2" --arg state "$3" --argjson closed "$4" \
    --argjson parent "${5:-null}" --argjson total "${6:-0}" --argjson completed "${7:-0}" \
    --argjson archived "${8:-false}" \
    '{id: $item, isArchived: $archived, content: {__typename: "Issue", id: ("I_" + ($n | tostring)),
      number: $n, state: $state, closedAt: $closed, repository: {nameWithOwner: "devantler-tech/monorepo"},
      subIssuesSummary: {total: $total, completed: $completed}, parent: $parent}}'
}
pr() { # pr <item> <number> <closedAt>
  jq -cn --arg item "$1" --argjson n "$2" --arg closed "$3" \
    '{id: $item, isArchived: false, content: {__typename: "PullRequest", id: ("PR_" + ($n | tostring)),
      number: $n, state: "MERGED", closedAt: $closed, repository: {nameWithOwner: "devantler-tech/ksail"}}}'
}
old='"2026-07-01T00:00:00Z"'
# Every mutating run must hold a claim; the fake helper accepts any well-formed sha.
claim_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
page() { # page <hasNext> <cursor> <node>...
  local has="$1" cur="$2"
  shift 2
  printf '%s\n' "$@" | jq -cs --argjson has "$has" --arg cur "$cur" \
    '{data: {organization: {projectV2: {id: "PVT_test", items: {pageInfo: {hasNextPage: $has, endCursor: $cur}, nodes: .}}}}}'
}

page 'true' cursor2 \
  "$(pr PVTI_1 1 2026-07-01T00:00:00Z)" \
  "$(pr PVTI_2 2 2026-09-01T00:00:00Z)" \
  "$(issue PVTI_3 3 CLOSED "$old")" \
  "$(issue PVTI_4 4 OPEN null)" \
  "$(issue PVTI_5 5 CLOSED "$old" '{"id":"I_P5","state":"OPEN","parent":null}')" \
  "$(issue PVTI_6 6 CLOSED "$old")" >"$tmp/page1.json"
page 'false' '' \
  "$(issue PVTI_7 7 OPEN null '{"id":"I_6","state":"CLOSED","parent":null}')" \
  "$(issue PVTI_8 8 CLOSED "$old" null 2 1)" \
  "$(issue PVTI_9 9 CLOSED "$old" '{"id":"I_P9","state":"CLOSED","parent":{"id":"I_G9","state":"OPEN","parent":null}}')" \
  '{"id":"PVTI_10","isArchived":false,"content":{"__typename":"DraftIssue"}}' \
  '{"id":"PVTI_11","isArchived":false,"content":null}' \
  "$(issue PVTI_12 12 CLOSED "$old" null 0 0 true)" \
  "$(issue PVTI_13 13 CLOSED "$old" '{"id":"I_P13","state":"CLOSED","parent":{"id":"I_X13"}}')" >"$tmp/page2.json"

# ── the fake gh ────────────────────────────────────────────────────────────
# Knobs: STUB_LOG, STUB_PAGE_BAD, STUB_CURSOR_STUCK, STUB_ARCHIVE_BAD, STUB_RECHECK_STATE, STUB_PROJECT,
#        STUB_RECHECK_PARENT / STUB_RECHECK_SIS / STUB_RECHECK_SUBISSUES (JSON applied to the issue
#        candidate PVTI_3 at recheck), STUB_RECHECK_CLOSED_AT (every recheck), STUB_CLAIM_FAIL (claim helper)
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
item=""
for a in "$@"; do case "$a" in item=*) item="${a#item=}" ;; esac; done
case "$args" in
  *unarchiveProjectV2Item*)
    printf 'unarchive %s\n' "$item" >>"$STUB_LOG"
    jq -n --arg id "$item" '{data: {unarchiveProjectV2Item: {item: {id: $id, isArchived: false}}}}' ;;
  *archiveProjectV2Item*)
    printf 'archive %s\n' "$item" >>"$STUB_LOG"
    archived=true
    [ "${STUB_ARCHIVE_BAD:-0}" = 1 ] && archived=false
    jq -n --arg id "$item" --argjson a "$archived" '{data: {archiveProjectV2Item: {item: {id: $id, isArchived: $a}}}}' ;;
  *"node(id:"*)
    printf 'recheck %s\n' "$item" >>"$STUB_LOG"
    printf 'recheck-full-pages %s\n' "$(grep -o 'subIssues(first: 100)' <<<"$args" | wc -l | tr -d ' ')" >>"$STUB_LOG"
    state="${STUB_RECHECK_STATE:-CLOSED}"
    closed_at="${STUB_RECHECK_CLOSED_AT:-2026-07-01T00:00:00Z}"
    parent=null
    sis=null
    subs=null
    if [ "$item" = PVTI_3 ]; then
      parent="${STUB_RECHECK_PARENT:-null}"
      sis='{"total":0,"completed":0}'
      [ -z "${STUB_RECHECK_SIS:-}" ] || sis="$STUB_RECHECK_SIS"
      subs='{"totalCount":0,"nodes":[]}'
      [ -z "${STUB_RECHECK_SUBISSUES:-}" ] || subs="$STUB_RECHECK_SUBISSUES"
    fi
    jq -n --arg id "$item" --arg s "$state" --arg c "$closed_at" \
      --argjson p "$parent" --argjson sis "$sis" --argjson subs "$subs" \
      '{data: {node: {id: $id, isArchived: false,
        content: ({state: $s, closedAt: $c}
          + (if $sis == null then {} else {subIssuesSummary: $sis, parent: $p, subIssues: $subs} end))}}}' ;;
  *"items("*)
    if [ "${STUB_PAGE_BAD:-0}" = 1 ]; then
      printf '{"errors":[{"message":"boom"}]}\n'
    elif [[ "$args" == *after=cursor2* ]]; then
      if [ "${STUB_CURSOR_STUCK:-0}" = 1 ]; then
        jq -c '.data.organization.projectV2.items.pageInfo = {hasNextPage: true, endCursor: "cursor2"}' "$STUB_DIR/page2.json"
      else
        cat "$STUB_DIR/page2.json"
      fi
    else
      cat "$STUB_DIR/page1.json"
    fi ;;
  *"projectV2(number"*)
    jq -n --arg id "${STUB_PROJECT:-PVT_test}" '{data: {organization: {projectV2: {id: $id}}}}' ;;
  *) printf 'unexpected gh call: %s\n' "$args" >&2; exit 99 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# A fake agent-claim helper: logs each renewal and prints a fresh tip, or fails.
cat >"$tmp/bin/claim-helper" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
printf 'claim-renew %s %s\n' "$2" "$3" >>"$STUB_LOG"
if [ "${STUB_CLAIM_FAIL:-0}" = 1 ]; then
  echo "agent-claim: LOST" >&2
  exit 1
fi
echo "agent-claim: RENEWED" >&2
printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HELPER
chmod +x "$tmp/bin/claim-helper"

run() { # run <case> <args...>  → sets rc, out, err; fresh log per case
  local name="$1"
  shift
  : >"$tmp/$name.log"
  set +e
  out=$(PATH="$tmp/bin:$PATH" STUB_DIR="$tmp" STUB_LOG="$tmp/$name.log" \
    BOARD_ARCHIVE_NOW=2026-09-14T00:00:00Z BOARD_ARCHIVE_PACE_SECONDS="${TEST_PACE:-0}" \
    BOARD_ARCHIVE_CLAIM_HELPER="$tmp/bin/claim-helper" \
    bash "$script" "$@" 2>"$tmp/$name.err")
  rc=$?
  set -e
  err=$(cat "$tmp/$name.err")
  log=$(cat "$tmp/$name.log")
}

# 1. dry run selects exactly the two eligible items and writes nothing
run dry
refs=$(printf '%s\n' "$out" | cut -f2 | sort | tr '\n' ' ')
check "dry run exits 0" "$([ "$rc" = 0 ] && echo 0 || echo 1)" "rc=$rc err=$err"
check "dry run selects exactly the eligible set" \
  "$([ "$refs" = "devantler-tech/ksail#1 devantler-tech/monorepo#3 " ] && echo 0 || echo 1)" "got: $refs"
check "dry run never mutates" "$(grep -q archive <<<"$log" && echo 1 || echo 0)" "$log"
check "dry run summary counts kept items" \
  "$(grep -qF '13 active item(s), 7 closed over 30 day(s), 5 kept for open hierarchy, 2 candidate(s)' <<<"$err" && echo 0 || echo 1)" "$err"
check "dry run never prints board titles" "$(grep -q '"title"' <<<"$out$err" && echo 1 || echo 0)"

# 2. a wider window changes the age gate only
run young --min-closed-days 20
refs=$(printf '%s\n' "$out" | cut -f2 | sort | tr '\n' ' ')
check "closing age is measured against --min-closed-days" \
  "$([ "$refs" = "devantler-tech/ksail#1 devantler-tech/monorepo#3 " ] && echo 0 || echo 1)" "got: $refs"
run recent --min-closed-days 1
refs=$(printf '%s\n' "$out" | cut -f2 | sort | tr '\n' ' ')
check "a recently merged PR becomes eligible with a shorter window" \
  "$([ "$refs" = "devantler-tech/ksail#1 devantler-tech/ksail#2 devantler-tech/monorepo#3 " ] && echo 0 || echo 1)" "got: $refs"

# 3. apply requires a manifest
run nomanifest --apply --claim "2238:$claim_sha"
check "--apply without --manifest is a usage error" "$([ "$rc" = 1 ] && ! grep -q archive <<<"$log" && echo 0 || echo 1)" "rc=$rc"

# 4. apply archives each candidate, recording it first
run apply --apply --manifest "$tmp/apply.tsv" --claim "2238:$claim_sha"
check "apply exits 0" "$([ "$rc" = 0 ] && echo 0 || echo 1)" "rc=$rc err=$err"
check "apply archives exactly the candidates" \
  "$([ "$(grep '^archive' <<<"$log" | sort | tr '\n' ' ')" = "archive PVTI_1 archive PVTI_3 " ] && echo 0 || echo 1)" "$log"
check "apply rechecks each item before archiving it" \
  "$([ "$(grep -c '^recheck ' <<<"$log")" = 2 ] && echo 0 || echo 1)" "$log"
check "manifest records project and item for each archive" \
  "$([ "$(cut -f1,2 "$tmp/apply.tsv" | tr '\t' ':' | sort | tr '\n' ' ')" = "PVT_test:PVTI_1 PVT_test:PVTI_3 " ] && echo 0 || echo 1)" "$(cat "$tmp/apply.tsv")"

# 5. --max caps one run
run cap --apply --manifest "$tmp/cap.tsv" --max 1 --claim "2238:$claim_sha"
check "--max caps archives per run" "$([ "$(grep -c '^archive' <<<"$log")" = 1 ] && echo 0 || echo 1)" "$log"

# 6. an item reopened since the read is skipped, not archived
STUB_RECHECK_STATE=OPEN run reopened --apply --manifest "$tmp/reopened.tsv" --claim "2238:$claim_sha"
check "a reopened item is skipped" \
  "$([ "$rc" = 0 ] && ! grep -q '^archive' <<<"$log" && [ ! -s "$tmp/reopened.tsv" ] && echo 0 || echo 1)" "rc=$rc $log"

# 7. a mutation that does not read back as archived stops the run
STUB_ARCHIVE_BAD=1 run badreadback --apply --manifest "$tmp/bad.tsv" --claim "2238:$claim_sha"
check "unverified archive exits 2 after one attempt" \
  "$([ "$rc" = 2 ] && [ "$(grep -c '^archive' <<<"$log")" = 1 ] && echo 0 || echo 1)" "rc=$rc $log"
check "the attempted item is already in the manifest" "$([ "$(wc -l <"$tmp/bad.tsv" | tr -d ' ')" = 1 ] && echo 0 || echo 1)"

# 8. read failures never lead to a mutation
STUB_PAGE_BAD=1 run badpage --apply --manifest "$tmp/badpage.tsv" --claim "2238:$claim_sha"
check "an error page exits 2 without archiving" "$([ "$rc" = 2 ] && ! grep -q archive <<<"$log" && echo 0 || echo 1)" "rc=$rc"
STUB_CURSOR_STUCK=1 run stuck --apply --manifest "$tmp/stuck.tsv" --claim "2238:$claim_sha"
check "a cursor that does not advance exits 2 without archiving" \
  "$([ "$rc" = 2 ] && ! grep -q archive <<<"$log" && echo 0 || echo 1)" "rc=$rc"

# 9. restore unarchives a manifest, and refuses one from another project
run restore --restore "$tmp/apply.tsv" --claim "2238:$claim_sha"
check "restore unarchives every manifest item" \
  "$([ "$rc" = 0 ] && [ "$(grep '^unarchive' <<<"$log" | sort | tr '\n' ' ')" = "unarchive PVTI_1 unarchive PVTI_3 " ] && echo 0 || echo 1)" "rc=$rc $log"
STUB_PROJECT=PVT_other run foreign --restore "$tmp/apply.tsv" --claim "2238:$claim_sha"
check "restore refuses another project's manifest before any mutation" \
  "$([ "$rc" = 2 ] && ! grep -q unarchive <<<"$log" && echo 0 || echo 1)" "rc=$rc $log"

# 10. no run may plan more writes than the hourly budget allows
run overmax --apply --manifest "$tmp/overmax.tsv" --max 451 --claim "2238:$claim_sha"
check "--max above the hourly cap is a usage error" "$([ "$rc" = 1 ] && ! grep -q archive <<<"$log" && echo 0 || echo 1)" "rc=$rc"
TEST_PACE=. run badpace --apply --manifest "$tmp/badpace.tsv" --claim "2238:$claim_sha"
check "a malformed pace is refused before any read or write" \
  "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"
: >"$tmp/big.tsv"
for ((i = 0; i < 451; i++)); do printf 'PVT_test\tPVTI_big%s\tdevantler-tech/monorepo#%s\t2026-07-01T00:00:00Z\n' "$i" "$i" >>"$tmp/big.tsv"; done
run bigrestore --restore "$tmp/big.tsv" --claim "2238:$claim_sha"
check "restore refuses a manifest over the hourly cap before any mutation" \
  "$([ "$rc" = 2 ] && ! grep -q unarchive <<<"$log" && echo 0 || echo 1)" "rc=$rc $log"

# 11. the recheck repeats the hierarchy rule, not only the state
STUB_RECHECK_PARENT='{"id":"I_P3","state":"OPEN","parent":null}' run ancestorreopened --apply --manifest "$tmp/anc.tsv" --claim "2238:$claim_sha"
check "an ancestor reopened since the read keeps the item" \
  "$([ "$rc" = 0 ] && [ "$(grep '^archive' <<<"$log" | tr '\n' ' ')" = "archive PVTI_1 " ] && echo 0 || echo 1)" "rc=$rc $log"
STUB_RECHECK_SIS='{"total":2,"completed":1}' run subissueadded --apply --manifest "$tmp/sis.tsv" --claim "2238:$claim_sha"
check "an unfinished sub-issue added since the read keeps the item" \
  "$([ "$rc" = 0 ] && [ "$(grep '^archive' <<<"$log" | tr '\n' ' ')" = "archive PVTI_1 " ] && echo 0 || echo 1)" "rc=$rc $log"

# 12. apply and restore are opposite mutations and cannot be combined
run bothmodes --restore "$tmp/apply.tsv" --apply --manifest "$tmp/both.tsv" --claim "2238:$claim_sha"
check "combining --restore then --apply is a usage error" \
  "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"
run bothmodes2 --apply --manifest "$tmp/both2.tsv" --restore "$tmp/apply.tsv" --claim "2238:$claim_sha"
check "combining --apply then --restore is a usage error" \
  "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"

# 13. the recheck repeats the closing-age gate and walks the descendants
STUB_RECHECK_CLOSED_AT=2026-09-10T00:00:00Z run reclosed --apply --manifest "$tmp/reclosed.tsv" --claim "2238:$claim_sha"
check "an item re-closed since the read is too recent to archive" \
  "$([ "$rc" = 0 ] && ! grep -q '^archive' <<<"$log" && echo 0 || echo 1)" "rc=$rc $log"
STUB_RECHECK_SUBISSUES='{"totalCount":1,"nodes":[{"state":"CLOSED","subIssuesSummary":{"total":1,"completed":1},"subIssues":{"totalCount":1,"nodes":[{"state":"OPEN","subIssuesSummary":{"total":0,"completed":0}}]}}]}' \
  run grandchild --apply --manifest "$tmp/grandchild.tsv" --claim "2238:$claim_sha"
check "an open grandchild under a closed child keeps the item" \
  "$([ "$rc" = 0 ] && [ "$(grep '^archive' <<<"$log" | tr '\n' ' ')" = "archive PVTI_1 " ] && echo 0 || echo 1)" "rc=$rc $log"

# 14. a supplied claim is renewed before the first mutation, and a lost claim stops the run
claim_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
run claimed --apply --manifest "$tmp/claimed.tsv" --claim "2238:$claim_sha"
check "the claim is renewed once, before the first archive" \
  "$([ "$rc" = 0 ] && [ "$(grep -c '^claim-renew' <<<"$log")" = 1 ] &&
    awk '/^claim-renew/ {c = NR} /^archive/ && !a {a = NR} END {exit !(c && a && c < a)}' <<<"$log" &&
    echo 0 || echo 1)" "rc=$rc $log"
check "the renewed claim tip is reported" \
  "$(grep -qF 'tip=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' <<<"$err" && echo 0 || echo 1)" "$err"
STUB_CLAIM_FAIL=1 run claimlost --apply --manifest "$tmp/claimlost.tsv" --claim "2238:$claim_sha"
check "a lost claim stops an apply before any archive" \
  "$([ "$rc" = 2 ] && ! grep -q '^archive' <<<"$log" && [ ! -s "$tmp/claimlost.tsv" ] && echo 0 || echo 1)" "rc=$rc $log"
STUB_CLAIM_FAIL=1 run restoreclaimlost --restore "$tmp/apply.tsv" --claim "2238:$claim_sha"
check "a lost claim stops a restore before any unarchive" \
  "$([ "$rc" = 2 ] && ! grep -q '^unarchive' <<<"$log" && echo 0 || echo 1)" "rc=$rc $log"
run badclaim --apply --manifest "$tmp/badclaim.tsv" --claim 2238:nothex
check "a malformed claim is a usage error" "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"

# 15. board writes are never unowned, and a manifest is never reused across runs
run noclaimapply --apply --manifest "$tmp/noclaim.tsv"
check "--apply without --claim is a usage error before any call" \
  "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"
run noclaimrestore --restore "$tmp/apply.tsv"
check "--restore without --claim is a usage error before any call" \
  "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"
printf 'PVT_test\tPVTI_old\tdevantler-tech/monorepo#99\t2026-07-01T00:00:00Z\n' >"$tmp/reused.tsv"
run reused --apply --manifest "$tmp/reused.tsv" --claim "2238:$claim_sha"
check "--apply refuses a manifest that already has entries" \
  "$([ "$rc" = 1 ] && [ -z "$log" ] && [ "$(wc -l <"$tmp/reused.tsv" | tr -d ' ')" = 1 ] && echo 0 || echo 1)" "rc=$rc $log"

# 16. a deeper branch the recheck could not read keeps the item
STUB_RECHECK_SUBISSUES='{"totalCount":1,"nodes":[{"state":"CLOSED","subIssuesSummary":{"total":1,"completed":1},"subIssues":{"totalCount":1,"nodes":[{"state":"CLOSED","subIssuesSummary":{"total":1,"completed":1}}]}}]}' \
  run unreadbranch --apply --manifest "$tmp/unread.tsv" --claim "2238:$claim_sha"
check "a closed sub-issue whose own children were not read keeps the item" \
  "$([ "$rc" = 0 ] && [ "$(grep '^archive' <<<"$log" | tr '\n' ' ')" = "archive PVTI_1 " ] && echo 0 || echo 1)" "rc=$rc $log"

# 18. the recheck reads a full sub-issue level (GitHub allows 100 per parent)
wide=$(jq -cn '{totalCount: 60, nodes: [range(60) | {state: "CLOSED", subIssuesSummary: {total: 0, completed: 0},
  subIssues: {totalCount: 0, nodes: []}}]}')
STUB_RECHECK_SIS='{"total":60,"completed":60}' STUB_RECHECK_SUBISSUES="$wide" \
  run widetree --apply --manifest "$tmp/wide.tsv" --claim "2238:$claim_sha"
check "the recheck asks for a full 100-item page at both sub-issue levels" \
  "$([ "$(grep '^recheck-full-pages' <<<"$log" | sort -u | tr '\n' ' ')" = "recheck-full-pages 2 " ] && echo 0 || echo 1)" "$log"
check "a finished issue with 60 closed sub-issues is still archived" \
  "$([ "$rc" = 0 ] && [ "$(grep '^archive' <<<"$log" | sort | tr '\n' ' ')" = "archive PVTI_1 archive PVTI_3 " ] && echo 0 || echo 1)" "rc=$rc $log"

# 19. options are accepted only by the modes they apply to, and the manifest must persist
run restoremanifest --restore "$tmp/apply.tsv" --manifest "$tmp/other.tsv" --claim "2238:$claim_sha"
check "--restore rejects --manifest before any call" \
  "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"
run drymanifest --manifest "$tmp/dry.tsv"
check "a dry run rejects --manifest" "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"
run devnull --apply --manifest /dev/null --claim "2238:$claim_sha"
check "--apply rejects a non-regular manifest such as /dev/null" \
  "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"
: >"$tmp/real.tsv"
ln -s "$tmp/real.tsv" "$tmp/link.tsv"
run symlink --apply --manifest "$tmp/link.tsv" --claim "2238:$claim_sha"
check "--apply rejects a symlinked manifest" "$([ "$rc" = 1 ] && [ -z "$log" ] && echo 0 || echo 1)" "rc=$rc $log"

# 17. the printed usage matches what the parser requires
run usagetext --not-a-flag
check "usage shows --claim for both mutating forms" \
  "$([ "$rc" = 1 ] && grep -qF -- '--apply --manifest NEW-FILE --claim ISSUE:SHA' <<<"$err" &&
    grep -qF -- '--restore FILE --claim ISSUE:SHA' <<<"$err" && echo 0 || echo 1)" "rc=$rc $err"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
