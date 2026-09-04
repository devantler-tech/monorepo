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

for workflow in "${ci_workflow}" "${scheduled_workflow}"; do
  yq -e '
    [.jobs.audit-docs.steps[]
      | select(.name == "Test audit wrapper")
      | select(."working-directory" == "docs")
      | select(.run == "./scripts/audit-dependencies.test.sh")]
    | length == 1
  ' "${workflow}" >/dev/null || fail "${workflow} does not run the audit contract test"

  yq -e '
    [.jobs.audit-docs.steps[]
      | select(.name == "Audit")
      | select(."working-directory" == "docs")
      | select(.run == "./scripts/audit-dependencies.sh")]
    | length == 1
  ' "${workflow}" >/dev/null || fail "${workflow} does not run the shared audit wrapper"

  yq -e '
    [.jobs.audit-docs.steps[] | select(.run == "npm ci")]
    | length == 0
  ' "${workflow}" >/dev/null || fail "${workflow} rebuilds node_modules before a lockfile audit"
done

docs_deps_filter="$(awk '
  /^            docs-deps:/ { inside = 1; print; next }
  inside && /^            [a-z0-9-]+:/ { exit }
  inside { print }
' "${ci_workflow}")"

for required_path in \
  "              - 'docs/scripts/audit-dependencies.sh'" \
  "              - 'docs/scripts/audit-dependencies.test.sh'" \
  "              - '.github/workflows/audit-docs.yaml'" \
  "              - '.github/workflows/ci.yaml'"; do
  printf '%s\n' "${docs_deps_filter}" | grep -Fqx -- "${required_path}" ||
    fail "docs-deps filter does not self-gate ${required_path#*\'}"
done

printf 'docs audit: PASS\n'
