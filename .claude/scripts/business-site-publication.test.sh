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
  if [[ "$finished" != 1 && "$rc" == 0 ]]; then rc=2; fi
  exit "$rc"
}
trap cleanup EXIT
# Only an immutable product gitlink belongs to this repository's website boundary.
entry=$(git --no-replace-objects -C "$ROOT" ls-files --stage -- applications/business-site) || {
  echo 'UNKNOWN: cannot read the candidate business-site gitlink' >&2; exit 2;
}
[[ "$entry" =~ ^160000[[:space:]]([0-9a-f]{40})[[:space:]]0[[:space:]]applications/business-site$ ]] || {
  echo 'FAIL: candidate business-site gitlink is missing or conflicted' >&2
  exit 1
}
# Inspect parsed authority and calls, not a workflow filename that could be renamed.
check() {
  local json out rc
  json=$(yq -o=json '.' "$1") || {
    printf 'UNKNOWN: cannot parse workflow %s\n' "$1" >&2; return 2;
  }
  if ! jq -e 'type == "object" and (.jobs | type == "object") and
    (.jobs | all(.[]; type == "object"))' <<< "$json" >/dev/null; then
    printf 'UNKNOWN: cannot read workflow structure in %s\n' "$1" >&2; return 2;
  fi
  if out=$(jq -e '
    ([.permissions, .jobs[]?.permissions] | all(.[];
      (.pages // "none") != "write")) and
    (
    . as $workflow | [.jobs[]?] | all(.[];
      ((.uses // "") | test("business-site/.*publish|actions/deploy-pages@") | not) and
      ((.environment // "") | if type == "object" then .name else . end) != "github-pages" and
      (. as $job | [.steps[]? |
        ((.["working-directory"] // $job.defaults.run["working-directory"] // $workflow.defaults.run["working-directory"] // "") | ltrimstr("./")) as $cwd |
        select(($cwd | contains("applications/business-site")) or $cwd == "docs") | (.run // "")] |
        all(.[]; test("(npm|pnpm|yarn).*build|astro.*build") | not)) and
      ([.steps[]? | (.uses // ""), (.run // "")] | all(.[];
        test("actions/deploy-pages@|business-site-revision\\.sh|business-site/.*publish-pages|gh workflow run.*publish-site") | not))))' <<< "$json" 2>&1); then
    return 0
  else
    rc=$?
  fi
  if [[ "$rc" == 1 ]]; then
    printf 'FAIL: competing website publication in %s\n' "$1" >&2; return 1;
  fi
  printf 'UNKNOWN: cannot evaluate workflow %s\n%s\n' "$1" "$out" >&2; return 2
}
for retired in .github/workflows/publish-pages.yaml .claude/scripts/business-site-revision.sh .claude/scripts/business-site-revision.test.sh; do
  if [ -e "$ROOT/$retired" ] || [ -L "$ROOT/$retired" ]; then
    printf 'FAIL: retired monorepo publication implementation remains: %s\n' "$retired" >&2
    exit 1
  fi
done
workflow_files=$(find "$ROOT/.github/workflows" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort) || {
  echo 'UNKNOWN: root workflows could not be read' >&2; exit 2;
}
[ -n "$workflow_files" ] || { echo 'UNKNOWN: no root workflows were examined' >&2; exit 2; }
while IFS= read -r workflow; do
  if check "$workflow"; then :; else exit $?; fi
done <<< "$workflow_files"
printf 'permissions: {}\njobs:\n  aggregate:\n    permissions:\n      contents: read\n    steps:\n      - run: echo aggregate\n' > "$TMP/base.yaml"
if check "$TMP/base.yaml"; then :; else exit $?; fi
asserts=1
# Failed reads are not policy rejections and must never satisfy a negative control.
expect_unknown() {
  local name=$1 out rc
  shift
  if out="$("$@" 2>&1)"; then rc=0; else rc=$?; fi
  if [[ "$rc" != 2 ]] || ! grep -Fq 'UNKNOWN:' <<< "$out"; then
    printf 'FAIL: %s returned %s instead of UNKNOWN\n%s\n' "$name" "$rc" "$out" >&2
    exit 1
  fi
  asserts=$((asserts + 1))
}
printf 'jobs: [\n' > "$TMP/invalid.yaml"
expect_unknown 'malformed workflow' check "$TMP/invalid.yaml"
expect_unknown 'unreadable workflow' check "$TMP/missing.yaml"
printf '' > "$TMP/empty.yaml"
expect_unknown 'empty workflow' check "$TMP/empty.yaml"
printf 'null\n' > "$TMP/null.yaml"
expect_unknown 'null workflow' check "$TMP/null.yaml"
printf 'jobs: []\n' > "$TMP/jobs-array.yaml"
expect_unknown 'non-object jobs' check "$TMP/jobs-array.yaml"
mkdir -p "$TMP/probe/.claude/scripts" "$TMP/probe/.github/workflows"
cp "$0" "$TMP/probe/.claude/scripts/business-site-publication.test.sh"
git -C "$TMP/probe" init -q
git -C "$TMP/probe" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,applications/business-site
for invalid in invalid empty null jobs-array; do
  cp "$TMP/$invalid.yaml" "$TMP/probe/.github/workflows/ci.yaml"
  expect_unknown "actual guard $invalid input" bash "$TMP/probe/.claude/scripts/business-site-publication.test.sh"
done
cp "$TMP/base.yaml" "$TMP/probe/.github/workflows/ci.yaml"
mkdir "$TMP/tools"
for tool in yq jq; do
  printf '#!/usr/bin/env bash\nexit 17\n' > "$TMP/tools/$tool"
  chmod +x "$TMP/tools/$tool"
  PATH="$TMP/tools:$PATH" expect_unknown "$tool failed read" check "$TMP/base.yaml"
  PATH="$TMP/tools:$PATH" expect_unknown "actual guard $tool failure" bash "$TMP/probe/.claude/scripts/business-site-publication.test.sh"
  rm "$TMP/tools/$tool"
done
# Mutation controls exercise the same validator used for every real root workflow.
reject() {
  local name=$1 expression=$2 out rc
  cp "$TMP/base.yaml" "$TMP/fixture.yaml"
  yq -i "$expression" "$TMP/fixture.yaml" || {
    printf 'UNKNOWN: cannot create %s control\n' "$name" >&2; exit 2;
  }
  asserts=$((asserts + 1))
  if out=$(check "$TMP/fixture.yaml" 2>&1); then
    printf 'FAIL: %s accepted\n' "$name" >&2; exit 1;
  else
    rc=$?
  fi
  if [[ "$rc" != 1 ]] || ! grep -Fq 'FAIL: competing website publication in ' <<< "$out"; then
    printf 'UNKNOWN: %s did not prove a policy rejection\n%s\n' "$name" "$out" >&2; exit 2;
  fi
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
