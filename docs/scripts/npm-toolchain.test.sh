#!/usr/bin/env bash
#
# npm-toolchain.test.sh — every workflow job that installs, audits or builds the site uses
# the npm major that writes docs/package-lock.json (monorepo#3749).
#
# WHY: Dependabot writes the lockfile with npm 11, its default for a version-3 lockfile.
# npm 10 and npm 11 disagree about which optional peer entries a lockfile must hold, so a
# lockfile one major writes fails the other major's `npm ci` sync check, and every
# dependency update of the site went red. docs/package.json declares the npm major in
# devEngines.packageManager, and npm refuses to install, audit or run with another major.
# This test keeps the workflows on a Node line that bundles that major, so no workflow can
# drift back unnoticed — including the publish workflow, which runs only on main.
#
# CHECKS
#   1. docs/package.json declares devEngines.packageManager as npm "^<major>.0.0" with
#      onFail "error".
#   2. Every job in .github/workflows that works in docs/ (a step or job default with
#      working-directory docs, `--prefix docs` or `cd docs`) has exactly one actions/setup-node step
#      with an explicit node-version, on a Node line whose bundled npm is that major. The
#      known jobs must all be found, so an empty discovery cannot pass.
#   3. CI runs this test from a job that its own inputs gate.
#
# Fixture cases first prove each check rejects the drift it exists for.
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(CDPATH='' cd -- "${script_dir}/../.." && pwd -P)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
  printf 'docs npm toolchain: FAIL - %s\n' "$*" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq is required to read the workflows"
command -v jq >/dev/null 2>&1 || fail "jq is required to read docs/package.json"

# The npm major each Node release line bundles, from the Node.js release notes. An unlisted
# line fails closed: confirm the npm major it bundles before adding it here.
bundled_npm_major() {
  case "$1" in
    22) printf '10\n' ;;
    24) printf '11\n' ;;
    *) return 1 ;;
  esac
}

# Jobs that must be discovered, as <workflow file>:<job id>.
required_jobs=(
  ci.yaml:build-docs
  ci.yaml:audit-docs
  ci.yaml:drift-check-active-projects
  audit-docs.yaml:audit-docs
  publish-pages.yaml:build
)

# Paths the CI filter gating this test must list, so a change to any input reruns it.
required_filter_paths=(
  docs/package.json
  docs/scripts/npm-toolchain.test.sh
  .github/workflows/audit-docs.yaml
  .github/workflows/ci.yaml
  .github/workflows/publish-pages.yaml
)

# One row per job that works in docs/: job id, setup-node step count, node-version and
# node-version-file of the first setup-node step. "-" stands for an absent value, because
# `read` collapses empty tab-separated fields.
# shellcheck disable=SC2016 # $setup is a yq variable, not a shell expansion.
jobs_query='
  .jobs // {} | to_entries | map(select(
    ((.value.defaults.run."working-directory" // "") | test("^(\\./)?docs(/|$)")) or
    ([.value.steps[]? | select(
      ((."working-directory" // "") | test("^(\\./)?docs(/|$)")) or
      ((.run // "") | test("--prefix[ =](\\./)?docs(/|\\s|$)")) or
      ((.run // "") | test("(^|[\\s;&|(])cd\\s+(\\./)?docs(/|\\s|;|&|\\)|$)"))
    )] | length > 0)
  )) | map(
    [.value.steps[]? | select((.uses // "") | test("^actions/setup-node@"))] as $setup |
    [.key, ($setup | length), ($setup[0].with."node-version" // "-"),
     ($setup[0].with."node-version-file" // "-")]
  ) | .[]
'

violation() {
  printf '%s\n' "$*"
  return 1
}

# check <package.json> <workflows dir>: prints the first violation and returns 1.
check() {
  local package_json="$1" workflows_dir="$2"
  local pm_type name version on_fail declared_major

  pm_type="$(jq -r '.devEngines.packageManager | type' "${package_json}")" ||
    violation "cannot parse ${package_json}" || return 1
  [ "${pm_type}" = "object" ] ||
    violation "docs/package.json declares no devEngines.packageManager entry for npm" || return 1
  name="$(jq -r '.devEngines.packageManager.name // ""' "${package_json}")"
  version="$(jq -r '.devEngines.packageManager.version // ""' "${package_json}")"
  on_fail="$(jq -r '.devEngines.packageManager.onFail // ""' "${package_json}")"
  [ "${name}" = "npm" ] ||
    violation "devEngines.packageManager names '${name}', not npm" || return 1
  [ "${on_fail}" = "error" ] ||
    violation "devEngines.packageManager onFail is '${on_fail}'; it must be 'error' so another npm major stops before it reads the lockfile" ||
    return 1
  [[ "${version}" =~ ^\^([1-9][0-9]*)\.0\.0$ ]] ||
    violation "devEngines.packageManager version '${version}' is not one npm major written as ^<major>.0.0" ||
    return 1
  declared_major="${BASH_REMATCH[1]}"

  local workflow base rows job count node_version node_version_file line npm_major
  local found=" "
  for workflow in "${workflows_dir}"/*.yaml "${workflows_dir}"/*.yml; do
    [ -f "${workflow}" ] || continue
    base="$(basename "${workflow}")"
    rows="$(yq -o=tsv "${jobs_query}" "${workflow}")" ||
      violation "cannot parse ${base}" || return 1
    while IFS=$'\t' read -r job count node_version node_version_file; do
      [ -n "${job}" ] || continue
      found="${found}${base}:${job} "
      [ "${count}" = "1" ] ||
        violation "${base}:${job} works in docs/ but has ${count} actions/setup-node steps; it needs exactly one" ||
        return 1
      [ "${node_version_file}" = "-" ] && [ "${node_version}" != "-" ] ||
        violation "${base}:${job} must pin node-version explicitly, so the npm major it installs with is reviewable" ||
        return 1
      [[ "${node_version}" =~ ^v?([0-9]+)(\.|$) ]] ||
        violation "${base}:${job} node-version '${node_version}' does not name a Node release line" || return 1
      line="${BASH_REMATCH[1]}"
      npm_major="$(bundled_npm_major "${line}")" ||
        violation "${base}:${job} uses Node ${line}, whose bundled npm major this test does not know yet" ||
        return 1
      [ "${npm_major}" = "${declared_major}" ] ||
        violation "${base}:${job} sets up Node ${node_version}, which bundles npm ${npm_major}; docs/package.json declares npm ${declared_major}" ||
        return 1
    done <<<"${rows}"
  done

  local required
  for required in "${required_jobs[@]}"; do
    [[ "${found}" == *" ${required} "* ]] ||
      violation "${required} was not found as a job that works in docs/" || return 1
  done

  local ci="${workflows_dir}/ci.yaml" gate filter
  gate="$(yq -r '
    [.jobs | to_entries[] | select([.value.steps[]? | select(
      .run == "./scripts/npm-toolchain.test.sh" and ."working-directory" == "docs"
    )] | length > 0) | .value.if // ""] | .[0] // ""
  ' "${ci}")" || violation "cannot parse ci.yaml" || return 1
  [[ "${gate}" =~ needs\.changes\.outputs\.([a-z0-9-]+) ]] ||
    violation "ci.yaml has no job that runs ./scripts/npm-toolchain.test.sh in docs/ behind a change filter" ||
    return 1
  filter="${BASH_REMATCH[1]}"
  local path
  for path in "${required_filter_paths[@]}"; do
    FILTER="${filter}" REQUIRED="${path}" yq -e '
      .jobs.changes.steps[] | select(.id == "filter") | .with.filters | from_yaml
      | .[strenv(FILTER)] | any_c(. == strenv(REQUIRED))
    ' "${ci}" >/dev/null 2>&1 ||
      violation "ci.yaml filter '${filter}' does not list ${path}, so a change to it skips this test" ||
      return 1
  done
}

# expect_failure <case> <expected message fragment>: runs check on the fixture copy.
expect_failure() {
  local name="$1" fragment="$2" output status=0
  output="$(check "${fixture}/docs/package.json" "${fixture}/.github/workflows")" || status=$?
  [ "${status}" -ne 0 ] || fail "fixture '${name}' passed; the check must reject it"
  [[ "${output}" == *"${fragment}"* ]] ||
    fail "fixture '${name}' failed for another reason: ${output}"
}

# reset_fixture: a fresh copy of the real package.json and workflows.
reset_fixture() {
  fixture="${tmp_dir}/fixture"
  rm -rf "${fixture}"
  mkdir -p "${fixture}/docs" "${fixture}/.github"
  cp "${repo_root}/docs/package.json" "${fixture}/docs/package.json"
  cp -R "${repo_root}/.github/workflows" "${fixture}/.github/workflows"
}

output="$(check "${repo_root}/docs/package.json" "${repo_root}/.github/workflows")" || fail "${output}"

reset_fixture
yq -i '(.jobs.build.steps[] | select((.uses // "") | test("^actions/setup-node@")) | .with."node-version") = "22"' \
  "${fixture}/.github/workflows/publish-pages.yaml"
expect_failure "publish on Node 22" "publish-pages.yaml:build sets up Node 22, which bundles npm 10"

reset_fixture
yq -i '.jobs.extra = {"runs-on": "ubuntu-latest", "steps": [
  {"uses": "actions/setup-node@v7", "with": {"node-version": "22"}},
  {"run": "cd docs && npm ci"}]}' "${fixture}/.github/workflows/publish-pages.yaml"
expect_failure "new job entering docs/ with cd" "publish-pages.yaml:extra sets up Node 22"

reset_fixture
yq -i '(.jobs.audit-docs.steps[] | select((.uses // "") | test("^actions/setup-node@")) | .with."node-version") = "23"' \
  "${fixture}/.github/workflows/audit-docs.yaml"
expect_failure "unknown Node line" "audit-docs.yaml:audit-docs uses Node 23"

reset_fixture
yq -i 'del(.jobs.drift-check-active-projects.steps[] | select((.uses // "") | test("^actions/setup-node@")))' \
  "${fixture}/.github/workflows/ci.yaml"
expect_failure "job without setup-node" "ci.yaml:drift-check-active-projects works in docs/ but has 0"

reset_fixture
yq -i 'del(.jobs.build-docs)' "${fixture}/.github/workflows/ci.yaml"
expect_failure "job not discovered" "ci.yaml:build-docs was not found"

reset_fixture
jq 'del(.devEngines)' "${repo_root}/docs/package.json" >"${fixture}/docs/package.json"
expect_failure "no devEngines" "declares no devEngines.packageManager"

reset_fixture
jq '.devEngines.packageManager.onFail = "warn"' "${repo_root}/docs/package.json" >"${fixture}/docs/package.json"
expect_failure "onFail warn" "onFail is 'warn'"

reset_fixture
yq -i '(.jobs.changes.steps[] | select(.id == "filter") | .with.filters) |= (from_yaml | .docs-deps -= [".github/workflows/publish-pages.yaml"] | to_yaml)' \
  "${fixture}/.github/workflows/ci.yaml"
expect_failure "filter misses publish workflow" "does not list .github/workflows/publish-pages.yaml"

printf 'docs npm toolchain: PASS\n'
