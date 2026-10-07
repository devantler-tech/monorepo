#!/usr/bin/env bash
# Pin both the reusable publisher and the website source without moving Pages.
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
check() {
  yq -o=json '.' "$1" | jq -er '
    .on.push.branches == ["main"] and
    (.on.push.paths | index("applications/business-site") != null) and
    (.on.push.paths | index(".github/workflows/publish-pages.yaml") != null) and
    (.on.push.paths | index(".claude/scripts/business-site-revision.sh") != null) and
    (.on | has("workflow_dispatch")) and
    .concurrency.group == "pages" and
    .jobs.revision.permissions == {"contents":"read"} and
    .jobs.revision.outputs.revision == "${{ steps.pin.outputs.revision }}" and
    ([.jobs.revision.steps[] | select((.uses // "") | startswith("actions/checkout@"))] | length == 1) and
    ([.jobs.revision.steps[] | select((.uses // "") | startswith("actions/checkout@"))][0].with["persist-credentials"] == false) and
    ([.jobs.revision.steps[] | select(.id == "pin")][0].run ==
      "revision=$(bash .claude/scripts/business-site-revision.sh)\nprintf '\''revision=%s\\n'\'' \"$revision\" >> \"$GITHUB_OUTPUT\"\n") and
    .jobs.publish.needs == "revision" and
    (.jobs.publish.uses | test("^devantler-tech/business-site/\\.github/workflows/publish-pages\\.yaml@[0-9a-f]{40}$")) and
    .jobs.publish.with["source-revision"] == "${{ needs.revision.outputs.revision }}" and
    .jobs.publish.permissions == {"contents":"read","pages":"write","id-token":"write"} and
    (.jobs.publish | has("secrets") | not) and
    (.jobs | keys == ["publish","revision"])
  ' >/dev/null
}
workflow="$ROOT/.github/workflows/publish-pages.yaml"
check "$workflow" || { echo 'FAIL: committed-source publication bridge is not wired' >&2; exit 1; }
asserts=1
reject() {
  local name=$1 expression=$2
  cp "$workflow" "$TMP/fixture.yaml"
  yq -i "$expression" "$TMP/fixture.yaml"
  asserts=$((asserts + 1))
  if check "$TMP/fixture.yaml"; then
    printf 'FAIL: %s was accepted\n' "$name" >&2
    exit 1
  fi
}
reject 'mutable reusable workflow' '.jobs.publish.uses = "devantler-tech/business-site/.github/workflows/publish-pages.yaml@main"'
reject 'mutable source input' '.jobs.publish.with."source-revision" = "main"'
reject 'ignored pin output' '.jobs.revision.outputs.revision = "fixed"'
reject 'missing source trigger' '.on.push.paths -= ["applications/business-site"]'
reject 'missing resolver trigger' '.on.push.paths -= [".claude/scripts/business-site-revision.sh"]'
reject 'wrong branch' '.on.push.branches = ["preview"]'
reject 'retained checkout credentials' '(.jobs.revision.steps[] | select((.uses // "") | test("^actions/checkout@")) | .with."persist-credentials") = true'
reject 'inherited caller secrets' '.jobs.publish.secrets = "inherit"'
reject 'competing deployment job' '.jobs.deploy = {"runs-on":"ubuntu-latest","steps":[{"run":"echo competing"}]}'
reject 'unsequenced publisher' '.jobs.publish.needs = "nothing"'
reject 'resolver failure masking' "(.jobs.revision.steps[] | select(.id == \"pin\") | .run) = \"echo revision=\$(bash .claude/scripts/business-site-revision.sh) >> \$GITHUB_OUTPUT\""
finished=1
printf 'business-site-publication.test: all %s assertions passed\n' "$asserts"
