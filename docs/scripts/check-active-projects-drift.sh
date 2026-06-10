#!/usr/bin/env bash
#
# check-active-projects-drift.sh
#
# Guards the hand-maintained Actions / Reusable Workflows lists on the Active
# Projects page (docs/src/content/docs/projects/active.mdx) against silent
# drift from their source-of-truth sibling repos. Both repos are submodules of
# this monorepo, so the check is entirely network-free: it reads only the
# already-checked-out submodules, never the GitHub API.
#
#   - Actions list       — one bullet per composite action, so it maps 1:1 to
#                          the `*/action.yaml` directories. Enforced as a strict
#                          count equality.
#   - Reusable Workflows — the site list is *categorical* (CI / CD / Automation
#                          buckets), not one bullet per workflow, so a bullet
#                          count cannot map 1:1. Instead we tripwire on the
#                          number of reusable (`workflow_call`) workflows versus
#                          an expected count declared inline in active.mdx via a
#                          `reusable-workflows-count: N` marker. Adding or
#                          removing a workflow therefore forces a human to
#                          revisit the category bullets and bump the marker.
#
# Run from the repository root (CI sets the working directory there); falls back
# to a path relative to this script for local runs.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${GITHUB_WORKSPACE:-$(cd "$script_dir/../.." && pwd)}"

mdx="$repo_root/docs/src/content/docs/projects/active.mdx"
actions_dir="$repo_root/github/devantler-tech/github-actions/actions"
rw_workflows_dir="$repo_root/github/devantler-tech/github-actions/reusable-workflows/.github/workflows"

# Anchor each H2 section on the source repo URL it links to — unique and stable.
actions_anchor="](https://github.com/devantler-tech/actions)"

fail=0

die_missing() {
  echo "::error::$1 not found at '$2' — is the submodule checked out?" >&2
  exit 1
}

[ -f "$mdx" ] || die_missing "active.mdx" "$mdx"
[ -d "$actions_dir" ] || die_missing "actions submodule" "$actions_dir"
[ -d "$rw_workflows_dir" ] || die_missing "reusable-workflows submodule" "$rw_workflows_dir"

# Count "- " bullets in the H2 section whose header line contains $1.
count_section_bullets() {
  awk -v anchor="$1" '
    /^## / { insec = (index($0, anchor) > 0) ? 1 : 0; next }
    insec && /^[[:space:]]*- / { n++ }
    END { print n + 0 }
  ' "$mdx"
}

# --- Actions: strict 1:1 count -------------------------------------------------
actions_count=$(find "$actions_dir" -mindepth 2 -maxdepth 2 -name action.yaml -type f | wc -l | tr -d ' ')
actions_bullets=$(count_section_bullets "$actions_anchor")

if [ "$actions_count" -ne "$actions_bullets" ]; then
  echo "::error file=docs/src/content/docs/projects/active.mdx::Actions list drift: \
${actions_count} composite action(s) in the actions submodule but ${actions_bullets} bullet(s) under \
'## ⚡ Actions'. An action was added or removed in devantler-tech/actions but the list was not updated — \
update the '## ⚡ Actions' section of docs/src/content/docs/projects/active.mdx." >&2
  fail=1
else
  echo "OK: Actions list in sync (${actions_count} actions == ${actions_bullets} bullets)."
fi

# --- Reusable Workflows: count tripwire vs. inline marker ----------------------
rw_count=$(grep -lE '^[[:space:]]*workflow_call:' "$rw_workflows_dir"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
rw_expected=$(grep -oE 'reusable-workflows-count:[[:space:]]*[0-9]+' "$mdx" | grep -oE '[0-9]+' | head -n1 || true)

if [ -z "$rw_expected" ]; then
  echo "::error file=docs/src/content/docs/projects/active.mdx::Missing 'reusable-workflows-count: N' \
marker in the '## 🔄 Reusable Workflows' section of docs/src/content/docs/projects/active.mdx." >&2
  fail=1
elif [ "$rw_count" -ne "$rw_expected" ]; then
  echo "::error file=docs/src/content/docs/projects/active.mdx::Reusable Workflows drift: \
${rw_count} reusable (workflow_call) workflow(s) in the reusable-workflows submodule but the marker \
declares ${rw_expected}. A workflow was added or removed in devantler-tech/reusable-workflows — review \
the category bullets under '## 🔄 Reusable Workflows' in docs/src/content/docs/projects/active.mdx and \
update the 'reusable-workflows-count' marker to ${rw_count}." >&2
  fail=1
else
  echo "OK: Reusable Workflows in sync (${rw_count} workflow_call workflows == marker ${rw_expected})."
fi

exit "$fail"
