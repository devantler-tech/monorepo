#!/usr/bin/env bash
# Fixtures for contract-test-invocation.sh (monorepo#2586): a wired test passes, and every way of
# leaving a test unexecuted — deleting its run step, mentioning it only as another command's
# argument, adding it unwired, or orphaning the parent that runs it — fails with a named reason.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sut="$here/contract-test-invocation.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
fail=0

# case <name> <want-exit> <want-output-substring> <workflow body> [test files...]
case_() {
  local name="$1" want="$2" needle="$3" body="$4"; shift 4
  local dir="$root/$name" out rc=0
  mkdir -p "$dir/.claude/scripts" "$dir/.github/workflows"
  printf '%s\n' "$body" >"$dir/.github/workflows/ci.yaml"
  local f
  for f in "$@"; do printf '%s\n' "${f#*=}" >"$dir/.claude/scripts/${f%%=*}"; done
  out="$(cd "$dir" && bash "$sut" 2>&1)" || rc=$?
  if [[ "$rc" != "$want" ]] || [[ "$out" != *"$needle"* ]]; then
    echo "  FAIL $name: want exit $want and '$needle'; got exit $rc: $out"
    fail=1
  else
    echo "  ok   $name"
  fi
}

self_step='      - run: bash .claude/scripts/contract-test-invocation.sh'

case_ wired 0 "all 1 contract tests" "jobs:
  test-a:
    steps:
      - run: |
          shellcheck .claude/scripts/a.test.sh
          bash .claude/scripts/a.test.sh
$self_step" 'a.test.sh=true'

case_ run-step-deleted 1 "NOT-INVOKED a.test.sh: job(s) test-a are wired to it" "jobs:
  test-a:
    steps:
      - run: shellcheck .claude/scripts/a.test.sh
$self_step" 'a.test.sh=true'

# The real shape of the defect: the job's ONLY reference was its run step, so after deleting it the
# job is found through the paths-filter key it is gated on.
case_ filter-gated-run-step-deleted 1 "NOT-INVOKED a.test.sh: job(s) test-a are wired to it" "jobs:
  changes:
    steps:
      - id: filter
        with:
          filters: |
            a:
              - '.claude/scripts/a.test.sh'
  test-a:
    if: needs.changes.outputs.a == 'true'
    steps:
      - uses: actions/checkout@v4
$self_step" 'a.test.sh=true'

case_ continuation-is-an-argument 1 "NOT-INVOKED b.test.sh" "jobs:
  lint:
    steps:
      - run: |
          shellcheck .claude/scripts/a.test.sh \\
            .claude/scripts/b.test.sh
          bash .claude/scripts/a.test.sh
$self_step" 'a.test.sh=true' 'b.test.sh=true'

case_ unwired-new-test 1 "NOT-INVOKED new.test.sh: no workflow job" "jobs:
  test-a:
    steps:
      - run: bash .claude/scripts/a.test.sh
$self_step" 'a.test.sh=true' 'new.test.sh=true'

# shellcheck disable=SC2016 # $here is expanded by the fixture test, not here
case_ invoked-through-parent 0 "all 2 contract tests" "jobs:
  test-parent:
    steps:
      - run: bash ./.claude/scripts/parent.test.sh
$self_step" 'parent.test.sh=if ! bash "$here/child.test.sh"; then exit 1; fi' 'child.test.sh=true'

# shellcheck disable=SC2016 # $here is expanded by the fixture test, not here
case_ orphaned-parent 1 "NOT-INVOKED child.test.sh" "jobs:
  other:
    steps:
      - run: echo nothing
$self_step" 'parent.test.sh=bash "$here/child.test.sh"' 'child.test.sh=true'

case_ commented-invocation 1 "NOT-INVOKED a.test.sh" "jobs:
  test-a:
    steps:
      - run: |
          # bash .claude/scripts/a.test.sh
          true
$self_step" 'a.test.sh=true'

# Separators inside quotes are text, not command boundaries: printing a line that mentions a test
# must not count as running it.
case_ quoted-separator-is-text 1 "NOT-INVOKED a.test.sh" "jobs:
  test-a:
    steps:
      - run: |
          printf '%s\n' \"audit; bash .claude/scripts/a.test.sh\"
          echo 'x && bash .claude/scripts/a.test.sh | tee y'
$self_step" 'a.test.sh=true'

# A quoted '#' is not a comment, so a real invocation after it on the same line still counts.
case_ quoted-hash-then-invocation 0 "all 1 contract tests" "jobs:
  test-a:
    steps:
      - run: |
          echo 'step #1' && bash .claude/scripts/a.test.sh
$self_step" 'a.test.sh=true'

# Real separators outside quotes still split commands.
case_ unquoted-separators-split 0 "all 2 contract tests" "jobs:
  test-a:
    steps:
      - run: echo \"a; b\" || true; bash .claude/scripts/a.test.sh | cat && sh .claude/scripts/b.test.sh
$self_step" 'a.test.sh=true' 'b.test.sh=true'

# A heredoc body is data fed to a command, not a command: its lines never run.
case_ heredoc-body-is-data 1 "NOT-INVOKED a.test.sh" "jobs:
  test-a:
    steps:
      - run: |
          cat <<EOF > notes.txt
          bash .claude/scripts/a.test.sh
          EOF
$self_step" 'a.test.sh=true'

case_ quoted-dash-heredoc-body-is-data 1 "NOT-INVOKED a.test.sh" "jobs:
  test-a:
    steps:
      - run: |
          cat <<-'END'
          bash .claude/scripts/a.test.sh
          END
$self_step" 'a.test.sh=true'

# The heredoc ends at its delimiter: a real invocation after it still counts, and <<< is not a heredoc.
case_ invocation-after-heredoc 0 "all 1 contract tests" "jobs:
  test-a:
    steps:
      - run: |
          grep -q x <<< \"x\"
          cat <<EOF
          text
          EOF
          bash .claude/scripts/a.test.sh
$self_step" 'a.test.sh=true'

# bash -n only parses the script, alone or in an option cluster; other options still run it.
case_ syntax-only-n 1 "NOT-INVOKED a.test.sh" "jobs:
  test-a:
    steps:
      - run: bash -n .claude/scripts/a.test.sh
$self_step" 'a.test.sh=true'

case_ syntax-only-cluster 1 "NOT-INVOKED a.test.sh" "jobs:
  test-a:
    steps:
      - run: sh -nv .claude/scripts/a.test.sh
$self_step" 'a.test.sh=true'

case_ traced-run-counts 0 "all 1 contract tests" "jobs:
  test-a:
    steps:
      - run: bash -x .claude/scripts/a.test.sh
$self_step" 'a.test.sh=true'

# A parent that runs a same-named test from ANOTHER directory does not cover the top-level one.
# shellcheck disable=SC2016 # $here is expanded by the fixture test, not here
case_ same-basename-other-dir 1 "NOT-INVOKED child.test.sh" "jobs:
  test-parent:
    steps:
      - run: bash .claude/scripts/parent.test.sh
$self_step" 'parent.test.sh=bash "$here/fixtures/child.test.sh"' 'child.test.sh=true'

case_ self-not-run 1 "NOT-INVOKED contract-test-invocation.sh" "jobs:
  test-a:
    steps:
      - run: bash .claude/scripts/a.test.sh" 'a.test.sh=true'

case_ no-tests 2 "refusing an empty pass" "jobs:
  x:
    steps:
$self_step"

# The real repository: every contract test here is executed by ci.yaml.
repo_root="$(cd "$here/../.." && pwd)"
if out="$(cd "$repo_root" && bash "$sut" 2>&1)"; then
  echo "  ok   live repository"
else
  echo "  FAIL live repository: $out"
  fail=1
fi

if [[ "$fail" != 0 ]]; then exit 1; fi
echo "contract-test-invocation.test: ok"
