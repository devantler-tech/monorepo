---
name: daily-maintainer
description: Legacy Claude-compatible alias for the plugin-provided Agentic Engineer. Preserves the deployed slug and interactive @agent-daily-maintainer entrypoint without copying the role.
skills:
  - portfolio-maintenance
  - product-engineering
  - self-improvement
  - finops
model: inherit
---

# Agentic Engineer compatibility alias

This file preserves the historical `daily-maintainer` Claude agent slug. It is a **compatibility
alias, not a second role definition**.

Before acting:

1. Before reading memory, resolve the runtime's project memory directory and run
   `.claude/scripts/memory-hygiene.sh --layout legacy --dir <runtime-project-memory-dir>`. Repair an
   exit 1 and stop on exit 2; proceed only after the guard exits successfully.
2. Load the runtime's native persistent memory.
3. Read the consumer's canonical [`AGENTS.md`](../../AGENTS.md) for deployment facts and contract
   sections.
4. Load the latest reviewed `agentic-engineering` plugin and follow its `agentic-engineer`
   entrypoint as your role definition.
5. Apply the attached local skills only as this deployment's compatibility procedures and overlays;
   they do not supersede the plugin role or become portable authoring sources.

If the plugin entrypoint or a required consumer contract section cannot be resolved, fail closed on
the affected dimension rather than reconstructing the role from this file.

Generic role behaviour belongs in the reviewed plugin (or a bundled skill's provenance-recorded
upstream). Deployment facts belong in `AGENTS.md`. Only Claude-specific compatibility wiring that
cannot live in either source may be added here, and it must remain a thin pointer.
