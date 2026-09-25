#!/usr/bin/env bash
#
# Self-test for run-affected-tests.sh, against a throwaway git repository whose workflow
# gates three test scripts behind three paths-filter filters.
#
# What it pins:
#   - selection follows the workflow: a change hits only the filters whose globs match it
#   - a change no filter matches selects nothing (the negative control), and still exits 0
#   - `**/` also matches at the repository root, as dorny/paths-filter does
#   - a step's working-directory resolves the script path
#   - a failing script makes the run exit 1 and prints its log tail
#   - a script past --timeout is killed and reported TIMEOUT, not left running
#   - an unreadable workflow or a missing merge base is exit 2, never a clean pass
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
runner="${here}/run-affected-tests.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fails=0
ok() { printf 'ok: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

repo="${tmp}/repo"
mkdir -p "${repo}/.github/workflows" "${repo}/scripts" "${repo}/docs/scripts" "${repo}/other"
cd "${repo}" || exit 2
git init -q -b main
git config user.email t@example.invalid
git config user.name test
git config commit.gpgsign false

cat > .github/workflows/ci.yaml <<'EOF'
on: pull_request
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - uses: dorny/paths-filter@0000000000000000000000000000000000000000
        id: filter
        with:
          filters: |
            alpha:
              - 'scripts/alpha*'
            beta:
              - 'scripts/beta*'
              - '**/*.beta'
            gamma:
              - 'docs/**'
  test-alpha:
    needs: changes
    if: needs.changes.outputs.alpha == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/alpha.test.sh
  test-beta:
    needs: changes
    if: needs.changes.outputs.beta == 'true' && github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo setup
          bash scripts/beta.test.sh
  test-gamma:
    needs: changes
    if: needs.changes.outputs.gamma == 'true'
    runs-on: ubuntu-latest
    steps:
      - working-directory: docs
        run: ./scripts/gamma.test.sh
  ungated:
    runs-on: ubuntu-latest
    steps:
      - run: bash scripts/always.test.sh
EOF
printf 'exit 0\n' > scripts/alpha.test.sh
printf 'echo beta-broke-here; exit 3\n' > scripts/beta.test.sh
printf 'sleep 30\n' > docs/scripts/gamma.test.sh
printf 'exit 0\n' > scripts/always.test.sh
: > other/readme.txt
sed '/^  ungated:/,$d' .github/workflows/ci.yaml > .github/workflows/gated-only.yaml
# A second workflow for the two hostile cases: a job naming a script that does not exist,
# and a script that ignores TERM.
cat > .github/workflows/extra.yaml <<'EOF'
jobs:
  changes:
    steps:
      - uses: dorny/paths-filter@0000000000000000000000000000000000000000
        with:
          filters: |
            ghost:
              - 'missing/**'
            stubborn:
              - 'stubborn/**'
  test-ghost:
    if: needs.changes.outputs.ghost == 'true'
    steps:
      - run: bash scripts/ghost.test.sh
  test-stubborn:
    if: needs.changes.outputs.stubborn == 'true'
    steps:
      - run: bash scripts/stubborn.test.sh
EOF
printf "trap '' TERM\nsleep 60\n" > scripts/stubborn.test.sh
mkdir -p missing stubborn
git add -A && git commit -q -m base

run() { "${runner}" --root "${repo}" --base main "$@"; }

# --- selection -----------------------------------------------------------------------------
git switch -q -c work
: > other/notes.txt
out="$(run --list)"; rc=$?
if [ "${rc}" -eq 0 ] && [ "$(printf '%s\n' "${out}" | grep '\.test\.sh')" = "scripts/always.test.sh" ]; then
  ok "an unrelated change selects only the job CI runs on every change"
else bad "an unrelated change selected: ${out} (rc=${rc})"; fi
out="$(run --ci-file .github/workflows/gated-only.yaml)"; rc=$?
if [ "${rc}" -eq 0 ] && grep -q 'no affected test scripts' <<<"${out}"; then
  ok "an empty selection exits 0 and says so"
else bad "empty selection: ${out} (rc=${rc})"; fi

printf 'x\n' >> scripts/alpha.test.sh
out="$(run --list)"
if [ "$(printf '%s\n' "${out}" | grep '\.test\.sh')" = "scripts/alpha.test.sh
scripts/always.test.sh" ]; then
  ok "a change to alpha selects alpha and the always-run job only"
else bad "alpha selection: ${out}"; fi
git checkout -q -- scripts/alpha.test.sh

: > root.beta
out="$(run --list)"
if grep -qx 'scripts/beta.test.sh' <<<"${out}"; then
  ok "a leading **/ matches a file at the repository root"
else bad "root **/ match: ${out}"; fi
rm -f root.beta

: > docs/page.md
out="$(run --list)"
if grep -qx 'docs/scripts/gamma.test.sh' <<<"${out}"; then
  ok "a step working-directory resolves the script path"
else bad "working-directory resolution: ${out}"; fi
rm -f docs/page.md

out="$(run --list --all)"
if [ "$(printf '%s\n' "${out}" | grep -c '\.test\.sh')" -eq 4 ]; then
  ok "--all selects every script a CI job runs"
else bad "--all selection: ${out}"; fi

# --- execution -----------------------------------------------------------------------------
printf 'x\n' >> scripts/beta.test.sh
out="$(run)"; rc=$?
if [ "${rc}" -eq 1 ] && grep -q '^FAIL .*scripts/beta.test.sh' <<<"${out}" \
   && grep -q 'beta-broke-here' <<<"${out}"; then
  ok "a failing script exits 1 and shows its log tail"
else bad "failing script: ${out} (rc=${rc})"; fi
git checkout -q -- scripts/beta.test.sh

: > docs/page.md
start="$(date +%s)"
out="$(run --timeout 2)"; rc=$?
took=$(( $(date +%s) - start ))
if [ "${rc}" -eq 1 ] && grep -q '^TIMEOUT' <<<"${out}" && [ "${took}" -lt 20 ]; then
  ok "a script past --timeout is killed and reported TIMEOUT (${took}s)"
else bad "timeout: ${out} (rc=${rc}, took=${took}s)"; fi
rm -f docs/page.md

printf 'x\n' >> scripts/alpha.test.sh
out="$(run)"; rc=$?
if [ "${rc}" -eq 0 ] && grep -q '^PASS .*scripts/alpha.test.sh' <<<"${out}"; then
  ok "a passing selection exits 0"
else bad "passing run: ${out} (rc=${rc})"; fi
git checkout -q -- scripts/alpha.test.sh

: > stubborn/x
start="$(date +%s)"
out="$(run --ci-file .github/workflows/extra.yaml --timeout 2 2>&1)"; rc=$?
took=$(( $(date +%s) - start ))
if [ "${rc}" -eq 1 ] && grep -q '^TIMEOUT' <<<"${out}" && [ "${took}" -lt 20 ]; then
  ok "a script that ignores TERM is killed after the grace period (${took}s)"
else bad "TERM-ignoring script: ${out} (rc=${rc}, took=${took}s)"; fi
rm -f stubborn/x

# --- cannot tell ---------------------------------------------------------------------------
: > missing/x
out="$(run --ci-file .github/workflows/extra.yaml --list 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ] && grep -q 'scripts/ghost.test.sh' <<<"${out}"; then
  ok "a selected script that does not exist is exit 2 and named"
else bad "missing script: ${out} (rc=${rc})"; fi
rm -f missing/x
"${runner}" --root "${repo}" --base main --ci-file missing.yaml --list >/dev/null 2>&1
if [ $? -eq 2 ]; then ok "an unreadable workflow is exit 2"; else bad "unreadable workflow was not exit 2"; fi
"${runner}" --root "${repo}" --base no-such-ref --list >/dev/null 2>&1
if [ $? -eq 2 ]; then ok "a missing merge base is exit 2"; else bad "missing merge base was not exit 2"; fi
"${runner}" --root "${repo}" --timeout 0 --list >/dev/null 2>&1
if [ $? -eq 2 ]; then ok "a zero timeout is rejected"; else bad "a zero timeout was accepted"; fi

if [ "${fails}" -eq 0 ]; then
  echo "PASS: run-affected-tests selects what CI selects, and fails closed"
  exit 0
fi
echo "FAIL: ${fails} case(s)"
exit 1
