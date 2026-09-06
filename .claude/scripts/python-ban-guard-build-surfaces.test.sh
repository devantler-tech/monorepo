#!/usr/bin/env bash
# Actual-entrypoint checks: fixtures are scanned as text and never executed.
# python-ban-guard: allow-file — inert Go directives and Make recipes exercise the scanner.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="${GUARD:-$here/python-ban-guard.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
count=0

# Scan one tracked fixture and require the expected status and source-located findings.
check() {
  local name="$1" path="$2" source="$3" expected_rc="$4" first="${5:-}" second="${6:-}"
  local dir="$tmp/$name" out rc=0
  mkdir -p "$dir/$(dirname "$path")"
  git -C "$dir" init -q
  printf '%s' "$source" >"$dir/$path"
  git -C "$dir" add -- "$path"
  out="$(bash "$guard" "$dir" 2>&1)" || rc=$?
  count=$((count + 1))
  if [[ "$rc" -eq "$expected_rc" && "$out" == *"$first"* && "$out" == *"$second"* ]]; then
    printf 'PASS: build surface %s\n' "$name"
  else
    printf 'FAIL: build surface %s — rc=%s expected=%s: %s\n' "$name" "$rc" "$expected_rc" "$out"
    fail=1
  fi
}

check generate-direct tools.go $'package tools\n//go:generate python3 --version\n' 1 \
  'tools.go:2: Python invocation `python3 --version`'
check generate-alias tools.go $'package tools\n//go:generate -command py python3\n//go:generate py --version\n' 1 \
  'tools.go:3: Python invocation `python3 --version`'
check generate-argument-data tools.go $'package tools\n//go:generate echo "python3 --version"\n' 0
check generate-comment-data tools.go $'package tools\n// go:generate python3 --version\n' 0
check generate-unused-alias tools.go $'package tools\n//go:generate -command py python3\n' 0

# Both lines must survive: the parser emits the directive before exit 3 and the
# production wrapper appends the legacy finding instead of replacing parser output.
check generate-and-compatibility tools.go $'package tools\n//go:generate python3 --version\nvar example = `\npip3 --version\n`\n' 1 \
  'tools.go:2: Python invocation `python3 --version`' \
  'tools.go:4: Python invocation `pip3 --version`'
check safe-directive-retains-compatibility tools.go $'package tools\n//go:generate echo safe\nvar example = `\npip3 --version\n`\n' 1 \
  'tools.go:4: Python invocation `pip3 --version`'

check make-silent Makefile $'check:\n\t@python3 --version\n' 1 \
  'Makefile:2: Python invocation `python3 --version`'
check make-ignore makefile $'check:\n\t-pip3 --version\n' 1 \
  'makefile:2: Python invocation `pip3 --version`'
check make-force GNUmakefile $'check:\n\t+pytest\n' 1 \
  'GNUmakefile:2: Python invocation `pytest`'
check make-combined checks.mk $'check:\n\t-@+ python3 --version\n' 1 \
  'checks.mk:2: Python invocation `python3 --version`'
check make-inline Makefile $'check: ; @python3 --version\n' 1 \
  'Makefile:1: Python invocation `python3 --version`'
check make-argument-data Makefile $'check:\n\t@echo python3 --version\n' 0
check make-declaration-data Makefile $'TOOL = python3\ncheck:\n\t@echo safe\n' 0
check make-define-data Makefile $'define EXAMPLE\n\t@python3 --version\nendef\ncheck:\n\t@echo safe\n' 0
check make-continuation Makefile $'check:\n\t@echo safe; \\\n\tpython3 --version\n' 1 \
  'Makefile:3: Python invocation `python3 --version`'
check make-continuation-data Makefile $'check:\n\t@echo \\\n\tpython3 --version\n' 0

printf 'Build surface entrypoint assertions: %s\n' "$count"
exit "$fail"
