#!/usr/bin/env bash
#
# Self-test for check-active-projects-drift.sh — proves the drift guard PASSES a
# fully-consistent fixture and FAILS each individual drift scenario (a missing
# marker, a count tripwire, and a set-equality mismatch for every one of the
# four checks: Actions, Reusable Workflows, Submodules, Templates page). Run in
# CI so the guard's correctness is continuously verified — a refactor that
# silently weakens any check is caught here, not in production drift.
#
# The guard reads its repo root from $GITHUB_WORKSPACE (falling back to the
# checkout when unset), so every case points it at a self-contained fixture tree
# under a tempdir — the test needs no submodule checkout and never touches the
# real repo.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/check-active-projects-drift.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0

pass_case() { # name root
  if GITHUB_WORKSPACE="$2" bash "$guard" >/dev/null 2>&1; then
    printf '  ✅ %s — passed as expected\n' "$1"
  else
    printf '  ❌ %s — expected PASS but the guard FAILED\n' "$1"; fail=1
  fi
}

fail_case() { # name root
  if GITHUB_WORKSPACE="$2" bash "$guard" >/dev/null 2>&1; then
    printf '  ❌ %s — expected FAIL but the guard PASSED\n' "$1"; fail=1
  else
    printf '  ✅ %s — failed as expected\n' "$1"
  fi
}

# Build a fully-consistent fixture repo root at $1: two composite actions, two
# reusable (workflow_call) workflows, four submodules (two infra-section, one
# grouped, one templates-page), and one matching template doc page — all four
# markers in active.mdx agreeing with the live sources.
build_fixture() {
  local root="$1"
  rm -rf "$root"
  local mdx_dir="$root/docs/src/content/docs/projects"
  local tpl_dir="$root/docs/src/content/docs/templates"
  local actions_dir="$root/github/devantler-tech/github-actions/actions"
  local rw_dir="$root/github/devantler-tech/github-actions/reusable-workflows/.github/workflows"
  mkdir -p "$mdx_dir" "$tpl_dir" "$actions_dir/alpha" "$actions_dir/beta" "$rw_dir"

  printf 'name: alpha\n' > "$actions_dir/alpha/action.yaml"
  printf 'name: beta\n'  > "$actions_dir/beta/action.yaml"

  printf 'on:\n  workflow_call:\n' > "$rw_dir/ci-one.yaml"
  printf 'on:\n  workflow_call:\n' > "$rw_dir/cd-two.yaml"

  cat > "$root/.gitmodules" <<'EOF'
[submodule "actions"]
	path = github/devantler-tech/github-actions/actions
	url = https://github.com/devantler-tech/actions.git
[submodule "reusable-workflows"]
	path = github/devantler-tech/github-actions/reusable-workflows
	url = https://github.com/devantler-tech/reusable-workflows.git
[submodule "bar"]
	path = applications/bar
	url = https://github.com/devantler-tech/bar.git
[submodule "foo-template"]
	path = templates/foo-template
	url = https://github.com/devantler-tech/foo-template.git
EOF

  cat > "$tpl_dir/foo.md" <<'EOF'
---
title: Foo Template
---
**Repository**: [devantler-tech/foo-template](https://github.com/devantler-tech/foo-template)
EOF

  cat > "$mdx_dir/active.mdx" <<'EOF'
---
title: Active Projects
---

{/* projects-submodules: applications/bar=grouped,github/devantler-tech/github-actions/actions=section,github/devantler-tech/github-actions/reusable-workflows=section,templates/foo-template=templates-page */}

## [⚡ Actions](https://github.com/devantler-tech/actions)

- alpha — first action
- beta — second action

{/* actions-dirs: alpha,beta */}

## 🔄 Reusable Workflows

- CI bucket
- CD bucket

{/* reusable-workflows-count: 2 */}
{/* reusable-workflows-names: cd-two,ci-one */}
EOF
}

# 0. fully-consistent fixture → pass (the happy path; guards against a guard
#    that fails-closed on a correct page).
good="$tmp/good"; build_fixture "$good"
pass_case "fully-consistent fixture" "$good"

# 1. Actions: marker absent → fail (missing-marker branch).
c="$tmp/actions-missing-marker"; build_fixture "$c"
sed -i.bak '/actions-dirs:/d' "$c/docs/src/content/docs/projects/active.mdx"
fail_case "Actions: missing actions-dirs marker" "$c"

# 2. Actions: a third action dir but the bullets/marker still list two →
#    bullet-count tripwire fires.
c="$tmp/actions-count"; build_fixture "$c"
mkdir -p "$c/github/devantler-tech/github-actions/actions/gamma"
printf 'name: gamma\n' > "$c/github/devantler-tech/github-actions/actions/gamma/action.yaml"
fail_case "Actions: count tripwire (3 dirs, 2 bullets)" "$c"

# 3. Actions: count matches but a marker name is renamed → set-equality fires.
c="$tmp/actions-set"; build_fixture "$c"
sed -i.bak 's/actions-dirs: alpha,beta/actions-dirs: alpha,gamma/' \
  "$c/docs/src/content/docs/projects/active.mdx"
fail_case "Actions: set mismatch (marker renames beta→gamma)" "$c"

# 4. Reusable Workflows: count marker disagrees with the live workflow count.
c="$tmp/rw-count"; build_fixture "$c"
sed -i.bak 's/reusable-workflows-count: 2/reusable-workflows-count: 3/' \
  "$c/docs/src/content/docs/projects/active.mdx"
fail_case "Reusable Workflows: count tripwire (marker 3, live 2)" "$c"

# 5. Reusable Workflows: count matches but a name is renamed → set-equality fires.
c="$tmp/rw-set"; build_fixture "$c"
sed -i.bak 's/reusable-workflows-names: cd-two,ci-one/reusable-workflows-names: cd-three,ci-one/' \
  "$c/docs/src/content/docs/projects/active.mdx"
fail_case "Reusable Workflows: set mismatch (marker renames cd-two→cd-three)" "$c"

# 6. Submodules: a new submodule in .gitmodules not recorded in the marker →
#    submodule set-equality fires.
c="$tmp/submodule-set"; build_fixture "$c"
cat >> "$c/.gitmodules" <<'EOF'
[submodule "newthing"]
	path = applications/newthing
	url = https://github.com/devantler-tech/newthing.git
EOF
fail_case "Submodules: unrecorded new submodule" "$c"

# 7. Templates page: a templates-page submodule (recorded in .gitmodules so the
#    submodule check still passes) has no matching template doc page → templates
#    set-equality fires in isolation.
c="$tmp/templates-set"; build_fixture "$c"
sed -i.bak 's#templates/foo-template=templates-page#templates/foo-template=templates-page,templates/baz-template=templates-page#' \
  "$c/docs/src/content/docs/projects/active.mdx"
cat >> "$c/.gitmodules" <<'EOF'
[submodule "baz-template"]
	path = templates/baz-template
	url = https://github.com/devantler-tech/baz-template.git
EOF
fail_case "Templates: templates-page submodule with no doc page" "$c"

if [ "$fail" -ne 0 ]; then
  printf '❌ active-projects drift-guard self-test FAILED\n' >&2
  exit 1
fi
printf '✅ active-projects drift-guard self-test passed (8 cases)\n'
