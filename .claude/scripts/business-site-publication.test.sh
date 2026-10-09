#!/usr/bin/env bash
# Keep the aggregator from becoming a second website publisher after live cutover.
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
# Only an immutable product gitlink belongs to this repository's website boundary.
entry=$(git --no-replace-objects -C "$ROOT" ls-files --stage -- applications/business-site)
[[ "$entry" =~ ^160000[[:space:]]([0-9a-f]{40})[[:space:]]0[[:space:]]applications/business-site$ ]] || {
  echo 'FAIL: candidate business-site gitlink is missing or conflicted' >&2
  exit 1
}
# Inspect parsed authority and calls, not a workflow filename that could be renamed.
check() {
  yq -o=json '.' "$1" | jq -e '
    [.permissions, .jobs[]?.permissions] | all(.[];
      (.pages // "none") != "write")' >/dev/null &&
  yq -o=json '.' "$1" | jq -e '
    . as $workflow | [.jobs[]?] | all(.[];
      ((.uses // "") | test("business-site/.*publish|actions/deploy-pages@") | not) and
      ((.environment // "") | if type == "object" then .name else . end) != "github-pages" and
      (. as $job | [.steps[]? |
        ((.["working-directory"] // $job.defaults.run["working-directory"] // $workflow.defaults.run["working-directory"] // "") | ltrimstr("./")) as $cwd |
        select(($cwd | contains("applications/business-site")) or $cwd == "docs") | (.run // "")] |
        all(.[]; test("(npm|pnpm|yarn).*build|astro.*build") | not)) and
      ([.steps[]? | (.uses // ""), (.run // "")] | all(.[];
        test("actions/deploy-pages@|business-site-revision\\.sh|business-site/.*publish-pages|gh workflow run.*publish-site") | not)))' >/dev/null
}
for retired in .github/workflows/publish-pages.yaml .claude/scripts/business-site-revision.sh .claude/scripts/business-site-revision.test.sh; do
  [ ! -e "$ROOT/$retired" ] && [ ! -L "$ROOT/$retired" ] || {
    printf 'FAIL: retired monorepo publication implementation remains: %s\n' "$retired" >&2
    exit 1
  }
done
workflow_files=$(find "$ROOT/.github/workflows" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort) || {
  echo 'FAIL: root workflows could not be read' >&2; exit 1;
}
[ -n "$workflow_files" ] || { echo 'FAIL: no root workflows were examined' >&2; exit 1; }
while IFS= read -r workflow; do
  check "$workflow" || { printf 'FAIL: competing website publication in %s\n' "$workflow" >&2; exit 1; }
done <<< "$workflow_files"
printf 'permissions: {}\njobs:\n  aggregate:\n    permissions:\n      contents: read\n    steps:\n      - run: echo aggregate\n' > "$TMP/base.yaml"
check "$TMP/base.yaml" || { echo 'FAIL: aggregation-only workflow rejected' >&2; exit 1; }
asserts=1
# Mutation controls exercise the same validator used for every real root workflow.
reject() {
  local name=$1 expression=$2
  cp "$TMP/base.yaml" "$TMP/fixture.yaml"
  yq -i "$expression" "$TMP/fixture.yaml"
  asserts=$((asserts + 1))
  if check "$TMP/fixture.yaml"; then printf 'FAIL: %s accepted\n' "$name" >&2; exit 1; fi
}
reject 'top-level Pages authority' '.permissions.pages = "write"'
reject 'job Pages authority' '.jobs.aggregate.permissions.pages = "write"'
reject 'renamed deployment action' '.jobs.aggregate.steps[0].uses = "actions/deploy-pages@0123456789abcdef0123456789abcdef01234567"'
reject 'renamed environment' '.jobs.aggregate.environment = "github-pages"'
reject 'structured environment' '.jobs.aggregate.environment = {"name":"github-pages"}'
reject 'external publication caller' '.jobs.aggregate.uses = "devantler-tech/business-site/.github/workflows/publish-pages.yaml@0123456789abcdef0123456789abcdef01234567"'
reject 'restored resolver' '.jobs.aggregate.steps[0].run = "bash .claude/scripts/business-site-revision.sh"'
reject 'source-owned dispatch from aggregator' '.jobs.aggregate.steps[0].run = "gh workflow run publish-site.yaml --repo devantler-tech/business-site"'
reject 'restored website build' '.jobs.aggregate.steps[0] = {"working-directory":"applications/business-site","run":"npm run build"}'
reject 'restored legacy application build' '.jobs.aggregate.steps[0] = {"working-directory":"docs","run":"npm run build"}'
reject 'job-default application build' '.jobs.aggregate.defaults.run."working-directory" = "applications/business-site" | .jobs.aggregate.steps[0].run = "npm run build"'
reject 'workflow-default application build' '.defaults.run."working-directory" = "applications/business-site" | .jobs.aggregate.steps[0].run = "npm run build"'
finished=1
printf 'business-site-publication.test: PASS — aggregation only; %s controls\n' "$asserts"
