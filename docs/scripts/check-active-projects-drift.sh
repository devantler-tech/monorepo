#!/usr/bin/env bash
#
# check-active-projects-drift.sh
#
# Guards the hand-maintained Actions / Reusable Workflows lists on the Active
# Projects page (docs/src/content/docs/projects/active.mdx) against silent
# drift from their source-of-truth repo. Both lists are sourced from the
# devantler-tech/actions submodule (the standalone reusable-workflows repo was
# merged into it and archived 2026-07-10 — monorepo#1964): composite actions
# live in its top-level directories, reusable workflows in its
# .github/workflows. The check is entirely network-free: it reads only the
# already-checked-out submodule, never the GitHub API.
#
#   - Actions list       — one bullet per composite action, so it maps 1:1 to
#                          the `*/action.yaml` directories. A bullet *count*
#                          alone cannot catch a rename (or a net-zero add+remove)
#                          — the count stays equal while a bullet silently goes
#                          stale — so we additionally pin the exact directory
#                          names via an inline `actions-dirs: a,b,c` marker in
#                          active.mdx and enforce SET equality between that
#                          marker and the live action directories (plus the
#                          original bullet-count tripwire, so the marker can't be
#                          updated without revisiting the prose bullets).
#   - Reusable Workflows — the site list is *categorical* (CI / CD / Automation
#                          buckets), not one bullet per workflow, so a bullet
#                          count cannot map 1:1. We tripwire on the number of
#                          reusable (`workflow_call`) workflows versus an expected
#                          count declared inline in active.mdx via a
#                          `reusable-workflows-count: N` marker — but a count
#                          alone, exactly like the Actions bullet count, cannot
#                          catch a rename or a net-zero add+remove (the count
#                          stays equal while a category bullet silently goes
#                          stale), so we additionally pin the exact workflow names
#                          via a `reusable-workflows-names: a,b,c` marker and
#                          enforce SET equality between it and the live
#                          `workflow_call` workflows (keeping the count tripwire so
#                          the names marker can't be updated without revisiting the
#                          category bullets). Adding, removing, OR renaming a
#                          workflow therefore forces a human to revisit the
#                          category bullets and update both markers.
#   - Submodules         — the page is a *curated* view of the monorepo's
#                          submodule set (the source-of-truth is .gitmodules):
#                          some submodules are their own H2 product section,
#                          some are grouped under "Self-Hosted Personal Apps",
#                          some are listed on the Templates page instead, and
#                          several are infra/config repos not surfaced as
#                          projects at all. A count or section scan can't model
#                          that curation, so we pin the FULL submodule set via a
#                          `projects-submodules: path=disposition,...` marker and
#                          enforce SET equality between the marker's paths and
#                          the live .gitmodules paths. Adding or removing a
#                          submodule therefore forces a human to record it and
#                          decide whether/how it appears — a brand-new product
#                          can no longer land in the monorepo while silently
#                          going unrepresented on the site. (This check reads
#                          only the tracked .gitmodules file, so it needs no
#                          submodule checkout and stays network-free.)
#   - Templates page     — the four template submodules are dispositioned
#                          `=templates-page` in the submodule marker above
#                          because they are surfaced on the Templates page
#                          (docs/src/content/docs/templates/), not here. That
#                          page's index CardGrid is auto-derived from the
#                          `templates/*` doc collection, so the *list* cannot
#                          drift — but the set of template doc PAGES is itself
#                          hand-maintained, and nothing tied it to the
#                          dispositioned submodule set. A new template repo could
#                          be recorded as `=templates-page` (the submodule check
#                          forces that) yet never get a doc page — silently
#                          vanishing from the site — and a renamed/removed
#                          template page could likewise linger. So we enforce SET
#                          equality between the basenames of the
#                          `=templates-page` submodules and the source repos that
#                          the template doc pages declare in their
#                          `**Repository**: [devantler-tech/<repo>]` line. Adding,
#                          removing, or renaming a template therefore forces both
#                          the doc page and the marker disposition to be updated
#                          in lockstep. (Reads only the marker and the in-repo doc
#                          pages, so it stays network-free.)
#
# Run from the repository root (CI sets the working directory there); falls back
# to a path relative to this script for local runs.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${GITHUB_WORKSPACE:-$(cd "$script_dir/../.." && pwd)}"

mdx="$repo_root/docs/src/content/docs/projects/active.mdx"
actions_dir="$repo_root/github/devantler-tech/github-actions/actions"
rw_workflows_dir="$repo_root/github/devantler-tech/github-actions/actions/.github/workflows"
gitmodules="$repo_root/.gitmodules"
templates_dir="$repo_root/docs/src/content/docs/templates"

# Anchor each H2 section on the source repo URL it links to — unique and stable.
actions_anchor="](https://github.com/devantler-tech/actions)"

fail=0

die_missing() {
  echo "::error::$1 not found at '$2' — is the submodule checked out?" >&2
  exit 1
}

[ -f "$mdx" ] || die_missing "active.mdx" "$mdx"
[ -d "$actions_dir" ] || die_missing "actions submodule" "$actions_dir"
[ -d "$rw_workflows_dir" ] || die_missing "actions submodule workflows directory" "$rw_workflows_dir"
[ -f "$gitmodules" ] || die_missing ".gitmodules" "$gitmodules"
[ -d "$templates_dir" ] || die_missing "templates docs directory" "$templates_dir"

# Count "- " bullets in the H2 section whose header line contains $1.
count_section_bullets() {
  awk -v anchor="$1" '
    /^## / { insec = (index($0, anchor) > 0) ? 1 : 0; next }
    insec && /^[[:space:]]*- / { n++ }
    END { print n + 0 }
  ' "$mdx"
}

# --- Actions: bullet-count tripwire + directory-name set equality --------------
# Live action directory names (each dir holding an action.yaml), sorted & unique.
actions_live=$(
  find "$actions_dir" -mindepth 2 -maxdepth 2 -name action.yaml -type f \
    | awk -F/ '{ print $(NF - 1) }' | sort -u
)
actions_count=$(printf '%s\n' "$actions_live" | grep -c . || true)
actions_bullets=$(count_section_bullets "$actions_anchor")

# Declared directory names from the inline `actions-dirs: a,b,c` marker.
actions_marker=$(
  grep -oE 'actions-dirs:[[:space:]]*[a-z0-9,_-]+' "$mdx" \
    | sed -E 's/^actions-dirs:[[:space:]]*//' | head -n1 || true
)
actions_declared=$(printf '%s' "$actions_marker" | tr ',' '\n' | sed '/^$/d' | sort -u)

if [ -z "$actions_marker" ]; then
  echo "::error file=docs/src/content/docs/projects/active.mdx::Missing 'actions-dirs: a,b,c' marker \
in the '## ⚡ Actions' section of docs/src/content/docs/projects/active.mdx." >&2
  fail=1
elif [ "$actions_count" -ne "$actions_bullets" ]; then
  echo "::error file=docs/src/content/docs/projects/active.mdx::Actions list drift: \
${actions_count} composite action(s) in the actions submodule but ${actions_bullets} bullet(s) under \
'## ⚡ Actions'. An action was added or removed in devantler-tech/actions but the list was not updated — \
update the '## ⚡ Actions' section of docs/src/content/docs/projects/active.mdx." >&2
  fail=1
elif [ "$actions_declared" != "$actions_live" ]; then
  only_live=$(comm -23 <(printf '%s\n' "$actions_live") <(printf '%s\n' "$actions_declared") | paste -sd, -)
  only_marker=$(comm -13 <(printf '%s\n' "$actions_live") <(printf '%s\n' "$actions_declared") | paste -sd, -)
  echo "::error file=docs/src/content/docs/projects/active.mdx::Actions list drift: the 'actions-dirs' \
marker does not match the action directories in devantler-tech/actions. \
Missing from marker: [${only_live:-none}]. Stale in marker (no longer a real action): [${only_marker:-none}]. \
An action was added, removed, or renamed — update the matching bullet AND the 'actions-dirs' marker in the \
'## ⚡ Actions' section of docs/src/content/docs/projects/active.mdx." >&2
  fail=1
else
  echo "OK: Actions list in sync (${actions_count} actions == ${actions_bullets} bullets, marker set matches)."
fi

# --- Reusable Workflows: count tripwire + workflow-name set equality -----------
# Live reusable (workflow_call) workflow names (basename minus .yaml), sorted & unique.
rw_live=$(
  grep -lE '^[[:space:]]*workflow_call:' "$rw_workflows_dir"/*.yaml 2>/dev/null \
    | awk -F/ '{ name = $NF; sub(/\.yaml$/, "", name); print name }' | sort -u
)
rw_count=$(printf '%s\n' "$rw_live" | grep -c . || true)
rw_expected=$(grep -oE 'reusable-workflows-count:[[:space:]]*[0-9]+' "$mdx" | grep -oE '[0-9]+' | head -n1 || true)

# Declared workflow names from the inline `reusable-workflows-names: a,b,c` marker.
rw_marker=$(
  grep -oE 'reusable-workflows-names:[[:space:]]*[a-z0-9,_-]+' "$mdx" \
    | sed -E 's/^reusable-workflows-names:[[:space:]]*//' | head -n1 || true
)
rw_declared=$(printf '%s' "$rw_marker" | tr ',' '\n' | sed '/^$/d' | sort -u)

if [ -z "$rw_expected" ]; then
  echo "::error file=docs/src/content/docs/projects/active.mdx::Missing 'reusable-workflows-count: N' \
marker in the '## 🔄 Reusable Workflows' section of docs/src/content/docs/projects/active.mdx." >&2
  fail=1
elif [ -z "$rw_marker" ]; then
  echo "::error file=docs/src/content/docs/projects/active.mdx::Missing 'reusable-workflows-names: a,b,c' \
marker in the '## 🔄 Reusable Workflows' section of docs/src/content/docs/projects/active.mdx." >&2
  fail=1
elif [ "$rw_count" -ne "$rw_expected" ]; then
  echo "::error file=docs/src/content/docs/projects/active.mdx::Reusable Workflows drift: \
${rw_count} reusable (workflow_call) workflow(s) in the actions submodule but the marker \
declares ${rw_expected}. A workflow was added or removed in devantler-tech/actions — review \
the category bullets under '## 🔄 Reusable Workflows' in docs/src/content/docs/projects/active.mdx and \
update the 'reusable-workflows-count' marker to ${rw_count}." >&2
  fail=1
elif [ "$rw_declared" != "$rw_live" ]; then
  only_live=$(comm -23 <(printf '%s\n' "$rw_live") <(printf '%s\n' "$rw_declared") | paste -sd, -)
  only_marker=$(comm -13 <(printf '%s\n' "$rw_live") <(printf '%s\n' "$rw_declared") | paste -sd, -)
  echo "::error file=docs/src/content/docs/projects/active.mdx::Reusable Workflows drift: the \
'reusable-workflows-names' marker does not match the workflow_call workflows in \
devantler-tech/actions. Missing from marker: [${only_live:-none}]. \
Stale in marker (no longer a workflow_call workflow): [${only_marker:-none}]. A workflow was added, \
removed, or renamed — review the category bullets under '## 🔄 Reusable Workflows' AND update the \
'reusable-workflows-names' marker in docs/src/content/docs/projects/active.mdx." >&2
  fail=1
else
  echo "OK: Reusable Workflows in sync (${rw_count} workflow_call workflows == marker ${rw_expected}, name set matches)."
fi

# --- Submodules: every submodule is consciously represented (or excluded) ------
# Live submodule paths from .gitmodules (a tracked file at the repo root, so no
# submodule contents are needed here), sorted & unique.
submodules_live=$(
  grep -E '^[[:space:]]*path[[:space:]]*=' "$gitmodules" \
    | awk -F'=' '{ gsub(/[[:space:]]/, "", $2); print $2 }' | sort -u
)

# Declared paths from the inline `projects-submodules: path=disposition,...`
# marker — take the path (left of '=') from each comma-separated entry.
submodules_marker=$(
  grep -oE 'projects-submodules:[[:space:]]*[a-z0-9/=,._-]+' "$mdx" \
    | sed -E 's/^projects-submodules:[[:space:]]*//' | head -n1 || true
)
submodules_declared=$(
  printf '%s' "$submodules_marker" | tr ',' '\n' | sed -E 's/=.*$//; /^[[:space:]]*$/d' | sort -u
)

if [ -z "$submodules_marker" ]; then
  echo "::error file=docs/src/content/docs/projects/active.mdx::Missing \
'projects-submodules: path=disposition,...' marker in \
docs/src/content/docs/projects/active.mdx." >&2
  fail=1
elif [ "$submodules_declared" != "$submodules_live" ]; then
  only_live=$(comm -23 <(printf '%s\n' "$submodules_live") <(printf '%s\n' "$submodules_declared") | paste -sd, -)
  only_marker=$(comm -13 <(printf '%s\n' "$submodules_live") <(printf '%s\n' "$submodules_declared") | paste -sd, -)
  echo "::error file=docs/src/content/docs/projects/active.mdx::Submodule drift: the \
'projects-submodules' marker does not match the submodules in .gitmodules. \
Missing from marker: [${only_live:-none}]. Stale in marker (no longer a submodule): [${only_marker:-none}]. \
A submodule was added or removed — record it in the 'projects-submodules' marker with its disposition \
(section / grouped / templates-page / infra / omitted) and, if it should appear as a project, update the page." >&2
  fail=1
else
  sub_n=$(printf '%s\n' "$submodules_live" | grep -c .)
  echo "OK: Submodule representation in sync (${sub_n} submodules all accounted for in the marker)."
fi

# --- Templates page: every templates-page submodule has a doc page (& vice versa) ---
# Basenames of the submodules dispositioned `=templates-page` in the marker above
# (the path is always `templates/<repo>`, so the basename is the repo name).
templates_declared=$(
  printf '%s' "$submodules_marker" | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -E '=templates-page$' \
    | sed -E 's/=templates-page$//; s#^.*/##' | sort -u
)

# Source repos the live template doc pages declare in their `**Repository**:`
# line — one per page under docs/src/content/docs/templates/*.md (the index is
# an .mdx file, so the *.md glob excludes it), sorted & unique.
templates_live=$(
  grep -hoE '^\*\*Repository\*\*:[[:space:]]*\[devantler-tech/[a-z0-9._-]+\]' "$templates_dir"/*.md 2>/dev/null \
    | sed -E 's#.*\[devantler-tech/##; s/\]$//' | sort -u
)

if [ "$templates_declared" != "$templates_live" ]; then
  only_decl=$(comm -23 <(printf '%s\n' "$templates_declared") <(printf '%s\n' "$templates_live") | paste -sd, -)
  only_page=$(comm -13 <(printf '%s\n' "$templates_declared") <(printf '%s\n' "$templates_live") | paste -sd, -)
  echo "::error file=docs/src/content/docs/projects/active.mdx::Templates page drift: the submodules \
dispositioned '=templates-page' in the 'projects-submodules' marker do not match the template doc pages \
under docs/src/content/docs/templates/. Dispositioned templates-page but missing a doc page (or its \
'**Repository**: [devantler-tech/<repo>]' link is wrong): [${only_decl:-none}]. Has a doc page but not \
dispositioned templates-page in the marker: [${only_page:-none}]. Add/remove the template doc page and \
keep the 'projects-submodules' marker disposition in lockstep." >&2
  fail=1
else
  tpl_n=$(printf '%s\n' "$templates_declared" | grep -c .)
  echo "OK: Templates page in sync (${tpl_n} templates-page submodules == ${tpl_n} template doc pages, repo set matches)."
fi

exit "$fail"
