#!/usr/bin/env bash
# Deployment-level PreToolUse dispatch for the portfolio surveyor's read-only guard.
#
# WHY THIS EXISTS (monorepo#3057)
# The forge read-only guard is attached to the surveyor through the `hooks:` frontmatter
# of the local overlay, `.claude/agents/portfolio-surveyor.md`. That is the only place it
# is attached, and it covers ONE of the two surveyor agent types this deployment exposes:
# the runtime ignores frontmatter hooks on an agent loaded from a plugin, so a run that
# dispatches `agentic-engineering:portfolio-surveyor` — the entry point the consumer
# contract names — runs every forge read with no guard at all. Measured 2026-09-04: a
# read under the plugin type ran with no hook, while the same read under the overlay
# type was intercepted.
#
# A project-wide Bash hook is the only surface the runtime offers that reaches a plugin
# agent, and a project-wide hook fires for EVERY Bash call in the session — the engineer's
# own write lane included. Routing every call through the guard would deny the merges and
# pushes the engineer exists to make. So this script is the narrow seam: the runtime
# includes `agent_type` in the hook's stdin when the call is made inside a subagent, and
# only the two surveyor types are forwarded to the real hook. Everything else exits 0
# without reading further, so the engineer's calls are untouched.
#
# FAIL DIRECTIONS, STATED
# - A surveyor type is forwarded verbatim to portfolio-surveyor-forge-hook.sh, which
#   fails CLOSED on its own (asset digests, classifier presence) — nothing here relaxes it.
# - Missing, empty or unparseable stdin, or no `agent_type` field, reads as "not a
#   surveyor" and exits 0. That is the top-level session and every other agent; failing
#   closed there would stop the whole engineer on the first malformed event. The surveyor
#   is never in that branch, because the runtime always supplies its type.
# - The forwarded target is a fixed sibling path, never an environment variable: an
#   overridable target would let anything able to set the surveyor's environment point
#   the guard at a program of its choosing.
#
# The overlay keeps its frontmatter hook as well; on that type the guard therefore runs
# twice per call, which is idempotent (two denials or two admissions of the same input).

set -euo pipefail

HERE=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly HERE
readonly TARGET="${HERE}/portfolio-surveyor-forge-hook.sh"

input=$(cat 2>/dev/null || true)
[ -n "${input}" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
agent_type=$(printf '%s' "${input}" | jq -r '.agent_type // ""' 2>/dev/null || true)

case "${agent_type}" in
  portfolio-surveyor|agentic-engineering:portfolio-surveyor) ;;
  *) exit 0 ;;
esac

if [ ! -f "${TARGET}" ] || [ ! -x "${TARGET}" ] || [ -L "${TARGET}" ]; then
  printf 'surveyor hook dispatch: forge hook is not a regular executable: %s\n' "${TARGET}" >&2
  exit 2
fi
printf '%s' "${input}" | exec "${TARGET}"
