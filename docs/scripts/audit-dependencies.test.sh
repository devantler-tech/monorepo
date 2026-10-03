#!/usr/bin/env bash

set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(CDPATH='' cd -- "${script_dir}/../.." && pwd -P)"
audit_script="${script_dir}/audit-dependencies.sh"
ci_workflow="${repo_root}/.github/workflows/ci.yaml"
scheduled_workflow="${repo_root}/.github/workflows/audit-docs.yaml"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
  printf 'docs audit: FAIL - %s\n' "$*" >&2
  exit 1
}

[ -x "${audit_script}" ] || fail "audit-dependencies.sh is missing or not executable"
command -v yq >/dev/null 2>&1 || fail "yq is required to validate workflow wiring"

mkdir -p "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 2 ] && [ "$1" = "audit" ] && [ "$2" = "--omit=dev" ] || {
  printf 'unexpected npm arguments: %s\n' "$*" >&2
  exit 64
}

count_file="${FAKE_NPM_COUNT_FILE:?}"
count=0
[ ! -f "${count_file}" ] || count="$(<"${count_file}")"
count=$((count + 1))
printf '%s\n' "${count}" >"${count_file}"

case "${FAKE_NPM_MODE:?}" in
  success)
    printf 'found 0 vulnerabilities\n'
    ;;
  vulnerable)
    printf '1 high severity vulnerability\n' >&2
    exit 1
    ;;
  endpoint-then-success)
    if [ "${count}" -eq 1 ]; then
      printf 'npm error audit endpoint returned an error\n' >&2
      exit 1
    fi
    printf 'found 0 vulnerabilities\n'
    ;;
  endpoint-always)
    printf 'npm error audit endpoint returned an error\n' >&2
    exit 1
    ;;
  *)
    printf 'unknown fake mode\n' >&2
    exit 64
    ;;
esac
EOF
chmod +x "${tmp_dir}/bin/npm"

run_case() {
  local mode="$1" expected_status="$2" expected_attempts="$3"
  local count_file="${tmp_dir}/${mode}.count"
  local status=0

  PATH="${tmp_dir}/bin:${PATH}" \
    FAKE_NPM_MODE="${mode}" \
    FAKE_NPM_COUNT_FILE="${count_file}" \
    "${audit_script}" >/dev/null 2>&1 || status=$?

  [ "${status}" -eq "${expected_status}" ] ||
    fail "${mode} exited ${status}; expected ${expected_status}"
  [ "$(<"${count_file}")" -eq "${expected_attempts}" ] ||
    fail "${mode} used $(<"${count_file}") attempts; expected ${expected_attempts}"
}

run_case success 0 1
run_case vulnerable 1 1
run_case endpoint-then-success 0 2
run_case endpoint-always 1 2

# Print the path list of one change filter in the CI workflow.
filter_paths() { # ci-workflow filter-name
  awk -v name="$2" '
    $0 == "            " name ":" { inside = 1; next }
    inside && /^            [a-z0-9-]+:/ { exit }
    inside { print }
  ' "$1"
}

# Validate how both workflows invoke the wrapper. Prints the first violation and
# returns 1; returns 0 when the wiring holds.
validate_wiring() { # ci-workflow scheduled-workflow
  local ci="$1" scheduled="$2" workflow required_path
  local live_filter contract_filter extra_path

  for workflow in "${ci}" "${scheduled}"; do
    yq -e '
      [.jobs.audit-docs.steps[]
        | select(.name == "Test audit wrapper")
        | select(."working-directory" == "docs")
        | select(.run == "./scripts/audit-dependencies.test.sh")]
      | length == 1
    ' "${workflow}" >/dev/null 2>&1 || {
      printf '%s does not run the audit contract test\n' "${workflow##*/}"
      return 1
    }

    yq -e '
      [.jobs.audit-docs.steps[]
        | select(.name == "Audit")
        | select(."working-directory" == "docs")
        | select(.run == "./scripts/audit-dependencies.sh")]
      | length == 1
    ' "${workflow}" >/dev/null 2>&1 || {
      printf '%s does not run the shared audit wrapper\n' "${workflow##*/}"
      return 1
    }

    yq -e '
      [.jobs.audit-docs.steps[] | select(.run == "npm ci")]
      | length == 0
    ' "${workflow}" >/dev/null 2>&1 || {
      printf '%s rebuilds node_modules before a lockfile audit\n' "${workflow##*/}"
      return 1
    }
  done

  # The live audit answers for the dependency tree, so it runs when the tree or the
  # wrapper that reads it changes.
  live_filter="$(filter_paths "${ci}" docs-deps)"
  for required_path in \
    "              - 'docs/package.json'" \
    "              - 'docs/package-lock.json'" \
    "              - 'docs/scripts/audit-dependencies.sh'"; do
    grep -Fqx -- "${required_path}" <<<"${live_filter}" || {
      printf 'docs-deps filter does not run the live audit for %s\n' "${required_path#*\'}"
      return 1
    }
  done

  # A workflow-only change cannot alter what the site depends on. A workflow path
  # here makes an advisory with no released fix fail every pull request that edits
  # CI, and a glob can match one as easily as a literal path, so the filter may hold
  # those three inputs and nothing else.
  extra_path="$(grep -E '^[[:space:]]*-' <<<"${live_filter}" | grep -Fvx \
    -e "              - 'docs/package.json'" \
    -e "              - 'docs/package-lock.json'" \
    -e "              - 'docs/scripts/audit-dependencies.sh'" | head -n 1 || true)"
  if [ -n "${extra_path}" ]; then
    printf 'docs-deps filter runs the live audit for more than the dependency tree and its wrapper\n'
    return 1
  fi

  yq -e '.jobs.audit-docs.if == "needs.changes.outputs.docs-deps == '"'"'true'"'"'"' \
    "${ci}" >/dev/null 2>&1 || {
    printf 'audit-docs is not gated on the docs-deps filter\n'
    return 1
  }

  # The contract test reads both workflows and the wrapper, so it self-gates on them.
  contract_filter="$(filter_paths "${ci}" docs-audit-contract)"
  for required_path in \
    "              - 'docs/scripts/audit-dependencies.sh'" \
    "              - 'docs/scripts/audit-dependencies.test.sh'" \
    "              - '.github/workflows/audit-docs.yaml'" \
    "              - '.github/workflows/ci.yaml'"; do
    grep -Fqx -- "${required_path}" <<<"${contract_filter}" || {
      printf 'docs-audit-contract filter does not self-gate %s\n' "${required_path#*\'}"
      return 1
    }
  done

  # shellcheck disable=SC2016 # ${{ … }} is workflow syntax, not a shell expansion.
  yq -e '
    .jobs.changes.outputs."docs-audit-contract"
      == "${{ steps.filter.outputs.docs-audit-contract }}"
  ' "${ci}" >/dev/null 2>&1 || {
    printf 'the changes job does not export the docs-audit-contract filter\n'
    return 1
  }

  yq -e '
    .jobs.test-docs-audit-wrapper.if
      == "needs.changes.outputs.docs-audit-contract == '"'"'true'"'"'"
  ' "${ci}" >/dev/null 2>&1 || {
    printf 'test-docs-audit-wrapper is not gated on the docs-audit-contract filter\n'
    return 1
  }

  yq -e '
    [.jobs.test-docs-audit-wrapper.steps[]
      | select(."working-directory" == "docs")
      | select(.run == "./scripts/audit-dependencies.test.sh")
      | select(has("if") | not)
      | select(has("continue-on-error") | not)]
    | length == 1
  ' "${ci}" >/dev/null 2>&1 || {
    printf 'test-docs-audit-wrapper does not run the audit contract test unconditionally\n'
    return 1
  }

  yq -e '
    [.jobs.test-docs-audit-wrapper.steps[] | select((.run // "") | test("audit-dependencies\.sh"))]
    | length == 0
  ' "${ci}" >/dev/null 2>&1 || {
    printf 'test-docs-audit-wrapper runs the live audit\n'
    return 1
  }

  # Neither job may fail without failing the required check.
  for workflow in audit-docs test-docs-audit-wrapper; do
    JOB="${workflow}" yq -e '.jobs.status.needs | any_c(. == strenv(JOB))' \
      "${ci}" >/dev/null 2>&1 || {
      printf 'CI - Required Checks does not wait for %s\n' "${workflow}"
      return 1
    }
    JOB="${workflow}" yq -e '
      [.jobs.status.steps[]
        | (.with."job-results" // "")
        | select(contains("needs." + strenv(JOB) + ".result"))]
      | length == 1
    ' "${ci}" >/dev/null 2>&1 || {
      printf 'CI - Required Checks does not report the result of %s\n' "${workflow}"
      return 1
    }
  done
}

violation="$(validate_wiring "${ci_workflow}" "${scheduled_workflow}")" || fail "${violation}"

# Each rule above must reject the drift it exists for. Every case edits a fresh copy
# of the real workflows and names the violation it expects, so a case cannot pass
# for an unrelated reason.
fixture_ci="${tmp_dir}/ci.yaml"
fixture_scheduled="${tmp_dir}/audit-docs.yaml"
mutations_run=0

reset_fixture() {
  cp "${ci_workflow}" "${fixture_ci}"
  cp "${scheduled_workflow}" "${fixture_scheduled}"
}

expect_violation() { # description expected-violation
  local description="$1" expected="$2" actual
  if actual="$(validate_wiring "${fixture_ci}" "${fixture_scheduled}")"; then
    fail "mutation passed: ${description}"
  fi
  [ "${actual}" = "${expected}" ] ||
    fail "${description}: got '${actual}', expected '${expected}'"
  mutations_run=$((mutations_run + 1))
}

# Add or remove one path in a change filter of the fixture CI workflow, as text, so
# the file keeps the layout filter_paths reads.
add_filter_path() { # filter-name path
  awk -v name="$1" -v path="$2" '
    { print }
    $0 == "            " name ":" { print "              - \047" path "\047" }
  ' "${fixture_ci}" >"${fixture_ci}.new"
  mv "${fixture_ci}.new" "${fixture_ci}"
}

remove_filter_path() { # filter-name path
  awk -v name="$1" -v path="$2" '
    $0 == "            " name ":" { inside = 1; print; next }
    inside && /^            [a-z0-9-]+:/ { inside = 0 }
    inside && $0 == "              - \047" path "\047" { next }
    { print }
  ' "${fixture_ci}" >"${fixture_ci}.new"
  mv "${fixture_ci}.new" "${fixture_ci}"
}

reset_fixture
violation="$(validate_wiring "${fixture_ci}" "${fixture_scheduled}")" ||
  fail "an unedited copy of the workflows is rejected: ${violation}"

reset_fixture
add_filter_path docs-deps .github/workflows/ci.yaml
expect_violation "the CI workflow re-enters the live audit filter" \
  "docs-deps filter runs the live audit for more than the dependency tree and its wrapper"

reset_fixture
add_filter_path docs-deps .github/workflows/audit-docs.yaml
expect_violation "the scheduled workflow re-enters the live audit filter" \
  "docs-deps filter runs the live audit for more than the dependency tree and its wrapper"

reset_fixture
add_filter_path docs-deps '**'
expect_violation "a catch-all glob enters the live audit filter" \
  "docs-deps filter runs the live audit for more than the dependency tree and its wrapper"

reset_fixture
add_filter_path docs-deps 'docs/**'
expect_violation "every docs change runs the live audit" \
  "docs-deps filter runs the live audit for more than the dependency tree and its wrapper"

reset_fixture
remove_filter_path docs-deps docs/package-lock.json
expect_violation "a lockfile change no longer runs the live audit" \
  "docs-deps filter does not run the live audit for docs/package-lock.json'"

reset_fixture
remove_filter_path docs-deps docs/scripts/audit-dependencies.sh
expect_violation "a wrapper change no longer runs the live audit" \
  "docs-deps filter does not run the live audit for docs/scripts/audit-dependencies.sh'"

reset_fixture
remove_filter_path docs-audit-contract .github/workflows/ci.yaml
expect_violation "a CI workflow change no longer runs the contract test" \
  "docs-audit-contract filter does not self-gate .github/workflows/ci.yaml'"

reset_fixture
yq -i '.jobs.audit-docs.if = "needs.changes.outputs.docs-audit-contract == '"'"'true'"'"'"' \
  "${fixture_ci}"
expect_violation "the live audit is gated on the contract filter" \
  "audit-docs is not gated on the docs-deps filter"

reset_fixture
yq -i 'del(.jobs.changes.outputs."docs-audit-contract")' "${fixture_ci}"
expect_violation "the contract filter is not exported" \
  "the changes job does not export the docs-audit-contract filter"

reset_fixture
yq -i '.jobs.test-docs-audit-wrapper.if = "false"' "${fixture_ci}"
expect_violation "the contract job never runs" \
  "test-docs-audit-wrapper is not gated on the docs-audit-contract filter"

reset_fixture
yq -i '.jobs.test-docs-audit-wrapper.steps[-1].continue-on-error = true' "${fixture_ci}"
expect_violation "the contract test may fail without failing its job" \
  "test-docs-audit-wrapper does not run the audit contract test unconditionally"

reset_fixture
yq -i '.jobs.test-docs-audit-wrapper.steps += [{"name": "Audit", "working-directory": "docs", "run": "./scripts/audit-dependencies.sh"}]' \
  "${fixture_ci}"
expect_violation "the contract job runs the live audit" \
  "test-docs-audit-wrapper runs the live audit"

reset_fixture
yq -i '.jobs.status.needs -= ["test-docs-audit-wrapper"]' "${fixture_ci}"
expect_violation "the required check does not wait for the contract job" \
  "CI - Required Checks does not wait for test-docs-audit-wrapper"

reset_fixture
yq -i '(.jobs.status.steps[] | select(.with."job-results") | .with."job-results") |= sub("\$\{\{ needs\.audit-docs\.result \}\}\s*"; "")' \
  "${fixture_ci}"
expect_violation "the required check does not report the live audit" \
  "CI - Required Checks does not report the result of audit-docs"

reset_fixture
yq -i 'del(.jobs.audit-docs.steps[] | select(.name == "Audit"))' "${fixture_scheduled}"
expect_violation "the scheduled workflow stops auditing" \
  "audit-docs.yaml does not run the shared audit wrapper"

[ "${mutations_run}" -eq 15 ] || fail "ran ${mutations_run} wiring mutations; expected 15"

printf 'docs audit: PASS\n'
