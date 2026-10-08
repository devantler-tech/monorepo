#!/usr/bin/env bash
# Exercise the source checkout used by the real affected-tests job on both OSes.
set -euo pipefail
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)
TMP=$(mktemp -d)
finished=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$finished" != 1 && "$rc" == 0 ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
workflow="$ROOT/.github/workflows/ci.yaml"
check() {
  yq -o=json '.' "$1" | jq -er '
    .jobs["test-run-affected-tests"] as $job |
    $job.strategy.matrix.os == ["ubuntu-latest","macos-latest"] and
    $job["runs-on"] == "${{ matrix.os }}" and
    ($job.steps | to_entries) as $steps |
    [$steps[] | select(.value.id == "site-pin")] as $pin |
    [$steps[] | select(.value.with.repository == "devantler-tech/business-site")] as $checkout |
    [$steps[] | select(.value.run == "bash .claude/scripts/run-affected-tests.sh --all --list")] as $select |
    ($pin | length == 1) and ($checkout | length == 1) and ($select | length == 1) and
    $pin[0].value.run == "revision=$(bash .claude/scripts/business-site-revision.sh)\nprintf '\''revision=%s\\n'\'' \"$revision\" >> \"$GITHUB_OUTPUT\"\n" and
    ($checkout[0].value.uses | test("^actions/checkout@[0-9a-f]{40}$")) and
    $checkout[0].value.with.ref == "${{ steps.site-pin.outputs.revision }}" and
    $checkout[0].value.with.path == "applications/business-site" and
    $checkout[0].value.with["persist-credentials"] == false and
    $pin[0].key < $checkout[0].key and $checkout[0].key < $select[0].key
  ' >/dev/null || return 1
  yq -r '.jobs.changes.steps[] | select((.uses // "") | contains("paths-filter")) | .with.filters' "$1" |
    yq -o=json '.' | jq -e '
      .["active-projects"] as $paths |
      ($paths | index("github/devantler-tech/.github-public") != null) and
      ($paths | index("github/devantler-tech/.github-public/actions/**") != null) and
      ($paths | index("github/devantler-tech/.github-public/.github/workflows/**") != null)
    ' >/dev/null || return 1
  yq -o=json '.jobs.drift-check-active-projects.steps' "$1" | jq -e '
    [.[] | select((.run // "") | contains("submodule-init.sh"))][0].run ==
      "bash .claude/scripts/submodule-init.sh applications/business-site github/devantler-tech/.github-public github/devantler-tech/github-actions/actions"
  ' >/dev/null || return 1
}
check "$workflow" || { echo 'FAIL: both-OS affected selection lacks its committed source checkout' >&2; exit 1; }
asserts=1
reject() {
  local name=$1 expression=$2
  cp "$workflow" "$TMP/workflow.yaml"
  yq -i "$expression" "$TMP/workflow.yaml"
  asserts=$((asserts + 1))
  if check "$TMP/workflow.yaml"; then
    printf 'FAIL: %s was accepted\n' "$name" >&2
    exit 1
  fi
}
reject 'missing source checkout' 'del(.jobs.test-run-affected-tests.steps[] | select(.with.repository == "devantler-tech/business-site"))'
reject 'mutable source' '(.jobs.test-run-affected-tests.steps[] | select(.with.repository == "devantler-tech/business-site") | .with.ref) = "main"'
reject 'wrong checkout directory' '(.jobs.test-run-affected-tests.steps[] | select(.with.repository == "devantler-tech/business-site") | .with.path) = "elsewhere"'
reject 'retained credentials' '(.jobs.test-run-affected-tests.steps[] | select(.with.repository == "devantler-tech/business-site") | .with.persist-credentials) = true'
reject 'uncovered macOS path' '.jobs.test-run-affected-tests.strategy.matrix.os = ["ubuntu-latest"]'
reject 'missing maintained automation checkout' '(.jobs.drift-check-active-projects.steps[] | select((.run // "") | contains("submodule-init.sh")) | .run) = "bash .claude/scripts/submodule-init.sh applications/business-site github/devantler-tech/github-actions/actions"'

# A local clone has the real root files but no populated submodules. Do not create
# stand-in test scripts: check out the real source at the resolver-selected commit.
git clone --shared --quiet "$ROOT" "$TMP/root"
cp "$workflow" "$TMP/root/.github/workflows/ci.yaml"
cp "$0" "$TMP/root/.claude/scripts/business-site-ci.test.sh"
rc=0
bash "$TMP/root/.claude/scripts/run-affected-tests.sh" --root "$TMP/root" --all --list > "$TMP/before" 2>&1 || rc=$?
if [[ "$rc" != 2 ]] || ! grep -q 'a selected script does not exist' "$TMP/before" || ! grep -q 'applications/business-site/' "$TMP/before"; then
  echo 'FAIL: root-only checkout did not reproduce the missing real source scripts' >&2
  cat "$TMP/before" >&2
  exit 1
fi
pin_run=$(yq -r '.jobs.test-run-affected-tests.steps[] | select(.id == "site-pin") | .run' "$workflow")
(cd "$TMP/root" && GITHUB_OUTPUT="$TMP/output" bash -e -c "$pin_run")
revision=$(sed -n 's/^revision=//p' "$TMP/output")
expected=$(git --no-replace-objects -C "$TMP/root" rev-parse HEAD:applications/business-site)
[[ "$revision" == "$expected" ]] || { echo 'FAIL: checkout resolver did not select committed source' >&2; exit 1; }
git clone --shared --quiet --no-checkout "$ROOT/applications/business-site" "$TMP/root/applications/business-site"
git -C "$TMP/root/applications/business-site" checkout --quiet --detach "$revision"
bash "$TMP/root/.claude/scripts/run-affected-tests.sh" --root "$TMP/root" --all --list > "$TMP/after"
grep -qx 'applications/business-site/docs/scripts/check-active-projects-drift.test.sh' "$TMP/after"
grep -qx 'applications/business-site/docs/scripts/check-cv-drift.test.sh' "$TMP/after"
asserts=$((asserts + 3))
finished=1
printf 'business-site-ci.test: all %s controls passed with real committed source\n' "$asserts"
