#!/usr/bin/env bash
# Idempotent Cursor cloud `install` / update hook for the monorepo environment.
#
# Boot leaves Git submodules uninitialised (`--recurse-submodules=no`). Product work is still in
# scope for the Cursor Agentic Engineer lane — it inits the submodule it needs on demand via
# `.claude/scripts/submodule-init.sh`. This hook only refreshes the always-needed docs deps so
# cold starts stay fast; it does NOT init every submodule (that would dominate every tick).
#
# Wired from `.cursor/environment.json` → `install`.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

if [[ -f docs/package.json ]]; then
  npm ci --prefix docs
fi
