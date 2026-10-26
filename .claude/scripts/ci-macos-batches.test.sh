#!/usr/bin/env bash
# Keep the measured short macOS cases covered without 22 runner allocations (#4394).
# Check the actual workflow before executing its exact, allow-listed batch programs
# against fixtures: a printed PASS never overrides a failing or missing child.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
finished=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [[ "$finished" != 1 && $rc -eq 0 ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT

fail() {
  echo "ci-macos-batches: FAIL — $*" >&2
  exit 1
}
unknown() {
  echo "ci-macos-batches: UNKNOWN — $*" >&2
  exit 2
}

# This inventory is deliberately independent of the workflow's batch commands.
cat >"$tmp/cases.tsv" <<'CASES'
1	worktree-lane-sweep
1	unsigned-commit-report
1	shared-checkout-freshness
1	security-advisory-sweep
1	gh-json-read
2	sibling-lane-watch
2	platform-live-health
2	squash-closing-keywords
2	board-add
2	prod-kube-context
2	flow-scorecard
3	review-lane-health
3	plugin-definition-currency
3	board-archive
3	disk-preflight
3	claude-task-live-runs
3	graphql-availability
4	claude-dispatch-rate
4	claude-lane-liveness
4	lane-draft-count
4	submodule-pin-currency
4	hypothesis-id-reserve
CASES
jq -Rn '[inputs | split("\t") | {group:.[0], name:.[1]}]' <"$tmp/cases.tsv" >"$tmp/cases.json"

# Every producer status is checked; an empty, partial or multi-document read is UNKNOWN.
yq -o=json '.' "$repo_root/.github/workflows/ci.yaml" >"$tmp/raw.json" || unknown 'cannot parse CI workflow'
jq -se 'length == 1 and (.[0] | type == "object" and (.jobs | type == "object"))' "$tmp/raw.json" >/dev/null || unknown 'incomplete workflow object'
jq '.' "$tmp/raw.json" >"$tmp/workflow.json"
jq -er '.jobs.changes.steps[] | select(.id == "filter") | .with.filters' "$tmp/workflow.json" >"$tmp/filters.yaml" || unknown 'cannot read path filters'
yq -o=json '.' "$tmp/filters.yaml" >"$tmp/filters.json" || unknown 'cannot parse path filters'
jq -se 'length == 1 and (.[0] | type == "object" and length > 0)' "$tmp/filters.json" >/dev/null || unknown 'incomplete filter object'

cat >"$tmp/check.jq" <<'CHECK'
def trim_names: del(.name) | .steps |= map(del(.name));
def program($cases): "batch_status=0\n" + ($cases | map("bash .claude/scripts/" + .name + ".test.sh || batch_status=1\n") | join("")) + "exit \"$batch_status\"\n";
. as $w | $cases[0] as $all | $filters[0] as $f |
($w.jobs["test-board-add"].steps[0] | del(.name)) as $checkout |
($checkout.uses | type == "string" and test("^actions/checkout@[0-9a-f]{40}$")) and
($checkout | keys == ["uses","with"] and .with == {"persist-credentials":false}) and
([ $w.jobs | keys[] | select(startswith("test-macos-batch-")) ] == [range(1;5) | "test-macos-batch-\(.)"]) and
all($all[];
  .name as $name | $w.jobs["test-"+$name] as $linux |
  ($linux | trim_names) == {
    needs:"changes", if:("needs.changes.outputs."+$name+" == 'true'"),
    strategy:{"fail-fast":false,matrix:{os:["ubuntu-latest"]}},
    "runs-on":"${{ matrix.os }}",permissions:{contents:"read"},
    steps:[$checkout,{run:("bash .claude/scripts/"+$name+".test.sh")}]
  } and ($f[$name] | type == "array" and length > 0 and index(".claude/scripts/"+$name+".test.sh") != null)
) and
all(range(1;5);
  tostring as $group | ("test-macos-batch-"+$group) as $id | ("macos-batch-"+$group) as $filter |
  [$all[] | select(.group == $group)] as $members |
  ($w.jobs[$id] | trim_names) == {
    needs:"changes", if:("needs.changes.outputs."+$filter+" == 'true'"),
    "runs-on":"macos-latest","timeout-minutes":10,permissions:{contents:"read"},
    steps:[$checkout,{shell:"bash",run:program($members)}]
  } and
  $f[$filter] == ([$members[] | $f[.name][]] | unique) and
  $w.jobs.changes.outputs[$filter] == ("${{ steps.filter.outputs."+$filter+" }}") and
  ($w.jobs.status.needs | index($id) != null) and
  ([ $w.jobs.status.steps[] | select((.uses // "") | startswith("devantler-tech/.github/actions/aggregate-job-checks@")) | .with["job-results"] | gsub("\\$\\{\\{ ";"${{") | gsub(" \\}\\}";"}}") | split(" ")[] | select(. != "") ] | index("${{needs."+$id+".result}}") != null)
)
CHECK
check_workflow() {
  jq -e --slurpfile cases "$tmp/cases.json" --slurpfile filters "${2:-$tmp/filters.json}" -f "$tmp/check.jq" "$1" >"$tmp/check.out" 2>"$tmp/check.err"
}
check_workflow "$tmp/workflow.json" || fail 'batch inventory, Linux coverage, filtering, permissions, failure propagation or aggregate wiring drifted'

# Ablations prove omissions and unsafe control flow cannot look like coverage.
reject_mutation() {
  local label="$1" expression="$2"
  jq "$expression" "$tmp/workflow.json" >"$tmp/mutated.json"
  if check_workflow "$tmp/mutated.json"; then fail "$label was accepted"; fi
}
reject_mutation 'missing batch' 'del(.jobs["test-macos-batch-1"])'
reject_mutation 'dropped Linux coverage' 'del(.jobs["test-board-add"])'
reject_mutation 'dropped aggregate need' '.jobs.status.needs -= ["test-macos-batch-1"]'
reject_mutation 'dropped aggregate results' '.jobs.status.steps[0].with["job-results"] = ""'
reject_mutation 'missing output' 'del(.jobs.changes.outputs["macos-batch-1"])'
reject_mutation 'wrong OS' '.jobs["test-macos-batch-1"]["runs-on"] = "ubuntu-latest"'
reject_mutation 'write permission' '.jobs["test-macos-batch-1"].permissions.contents = "write"'
reject_mutation 'swallowed failure' '.jobs["test-macos-batch-1"].steps[1].run |= sub("batch_status=1";"true")'
reject_mutation 'omitted child' '.jobs["test-macos-batch-1"].steps[1].run |= (split("\n") | map(select(contains("worktree-lane-sweep.test.sh") | not)) | join("\n"))'
reject_mutation 'duplicated test' '.jobs["test-macos-batch-1"].steps[1].run += "bash .claude/scripts/board-add.test.sh\n"'
jq '.["macos-batch-1"] |= .[1:]' "$tmp/filters.json" >"$tmp/mutated-filters.json"
if check_workflow "$tmp/workflow.json" "$tmp/mutated-filters.json"; then fail 'incomplete union filter was accepted'; fi

# Only the exact programs validated above are executed, in a private fixture tree.
mkdir -p "$tmp/fixture/.claude/scripts"
while IFS=$'\t' read -r group name; do
  cat >"$tmp/fixture/.claude/scripts/$name.test.sh" <<'CASE'
#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf '%s\n' "$name" >>"$BATCH_TEST_LOG"
echo 'PASS (deliberately untrusted output)'
if [[ "$name" == "$BATCH_TEST_FAIL" ]]; then exit "$BATCH_TEST_RC"; fi
CASE
done <"$tmp/cases.tsv"
for group in 1 2 3 4; do
  job="test-macos-batch-$group"
  JOB="$job" jq -er '.jobs[env.JOB].steps[1].run' "$tmp/workflow.json" >"$tmp/program.sh"
  awk -F '\t' -v g="$group" '$1 == g { print $2 ".test.sh" }' "$tmp/cases.tsv" >"$tmp/expected"
  target="$(sed -n '2p' "$tmp/expected")"
  for mode in pass failure unknown missing; do
    : >"$tmp/observed"
    fail_case='' child_rc=0
    if [[ "$mode" == failure ]]; then
      fail_case="$target"
      child_rc=42
    fi
    if [[ "$mode" == unknown ]]; then
      fail_case="$target"
      child_rc=2
    fi
    if [[ "$mode" == missing ]]; then mv "$tmp/fixture/.claude/scripts/$target" "$tmp/missing-case"; fi
    rc=0
    (cd "$tmp/fixture" && BATCH_TEST_LOG="$tmp/observed" BATCH_TEST_FAIL="$fail_case" BATCH_TEST_RC="$child_rc" "$BASH" -e -o pipefail "$tmp/program.sh") >"$tmp/run.log" 2>&1 || rc=$?
    if [[ "$mode" == pass ]]; then
      [[ $rc -eq 0 ]] || fail "$job positive control failed"
    else [[ $rc -ne 0 ]] || fail "$job accepted $mode despite printed PASS"; fi
    if [[ "$mode" == missing ]]; then
      grep -Fxv "$target" "$tmp/expected" >"$tmp/expected-missing"
      diff -u "$tmp/expected-missing" "$tmp/observed" || fail "$job did not continue after a missing child"
      mv "$tmp/missing-case" "$tmp/fixture/.claude/scripts/$target"
    else diff -u "$tmp/expected" "$tmp/observed" || fail "$job omitted later cases after $mode"; fi
  done
done
echo 'ci-macos-batches: OK — 22 cases retain both OSes; four batches run every child and propagate all failures'
finished=1
