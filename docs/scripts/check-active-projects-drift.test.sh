#!/usr/bin/env bash
#
# Self-test for check-active-projects-drift.sh — proves the drift guard PASSES a
# fully-consistent fixture and FAILS each individual drift scenario, asserting on
# the guard's actual error so every case pins its OWN branch (a refactor that
# made one check's failure get mis-attributed to another's message would be
# caught here). Covered failure branches: a missing marker for each of the three
# markers that have one (actions-dirs, reusable-workflows-count,
# reusable-workflows-names, projects-submodules), the count tripwire for Actions
# and Reusable Workflows, the set-equality mismatch for all four checks (Actions,
# Reusable Workflows, Submodules, Templates page — both directions for Templates),
# and the hard die_missing guard fired when a required submodule/file is absent
# (distinct from drift: it exits with a "is the submodule checked out?" error
# rather than a drift message). Run in CI so the guard's correctness is
# continuously verified — a refactor that silently weakens any check is caught
# here, not in production drift.
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

# Assert the guard FAILS *and* its combined stdout+stderr contains the expected
# literal marker substring — so the case proves it tripped its own branch, not
# merely that something somewhere failed.
fail_match() { # name root expected-substring
  local out
  if out="$(GITHUB_WORKSPACE="$2" bash "$guard" 2>&1)"; then
    printf '  ❌ %s — expected FAIL but the guard PASSED\n' "$1"; fail=1
  elif printf '%s\n' "$out" | grep -qF -- "$3"; then
    printf '  ✅ %s — failed on the expected branch\n' "$1"
  else
    printf '  ❌ %s — FAILED but not on the expected branch (wanted: %s)\n' "$1" "$3"; fail=1
  fi
}

# Build a fully-consistent fixture repo root at $1: two composite actions, two
# reusable (workflow_call) workflows living in the actions submodule's
# .github/workflows (the standalone reusable-workflows repo is archived —
# monorepo#1964) alongside a non-workflow_call workflow the guard must ignore,
# four submodules (two infra-section, one grouped, one templates-page), and one
# matching template doc page — all four markers in active.mdx agreeing with the
# live sources.
build_fixture() {
  local root="$1"
  rm -rf "$root"
  local mdx_dir="$root/docs/src/content/docs/projects"
  local tpl_dir="$root/docs/src/content/docs/templates"
  local actions_dir="$root/github/devantler-tech/github-actions/actions"
  local rw_dir="$actions_dir/.github/workflows"
  mkdir -p "$mdx_dir" "$tpl_dir" "$actions_dir/alpha" "$actions_dir/beta" "$rw_dir"

  printf 'name: alpha\n' > "$actions_dir/alpha/action.yaml"
  printf 'name: beta\n'  > "$actions_dir/beta/action.yaml"

  printf 'on:\n  workflow_call:\n' > "$rw_dir/ci-one.yaml"
  printf 'on:\n  workflow_call:\n' > "$rw_dir/cd-two.yaml"
  # The actions repo's own CI lives in the same directory; the guard must only
  # count workflow_call workflows, so this file must NOT enter the set.
  printf 'on:\n  push:\n' > "$rw_dir/repo-ci.yaml"

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

{/* projects-submodules: applications/bar=grouped,github/devantler-tech/github-actions/actions=section,github/devantler-tech/github-actions/reusable-workflows=omitted,templates/foo-template=templates-page */}

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

# Path to the fixture's active.mdx — every drift case mutates this file.
mdx_path() { printf '%s/docs/src/content/docs/projects/active.mdx' "$1"; }

# 0. fully-consistent fixture → pass (the happy path; guards against a guard
#    that fails-closed on a correct page).
good="$tmp/good"; build_fixture "$good"
pass_case "fully-consistent fixture" "$good"

# 1. Actions: marker absent → missing-marker branch.
c="$tmp/actions-missing-marker"; build_fixture "$c"
sed -i.bak '/actions-dirs:/d' "$(mdx_path "$c")"
fail_match "Actions: missing actions-dirs marker" "$c" \
  "Missing 'actions-dirs: a,b,c' marker"

# 2. Actions: a third action dir but the bullets/marker still list two →
#    bullet-count tripwire fires.
c="$tmp/actions-count"; build_fixture "$c"
mkdir -p "$c/github/devantler-tech/github-actions/actions/gamma"
printf 'name: gamma\n' > "$c/github/devantler-tech/github-actions/actions/gamma/action.yaml"
fail_match "Actions: count tripwire (3 dirs, 2 bullets)" "$c" \
  "composite action(s) in the actions submodule but"

# 3. Actions: count matches but a marker name is renamed → set-equality fires.
c="$tmp/actions-set"; build_fixture "$c"
sed -i.bak 's/actions-dirs: alpha,beta/actions-dirs: alpha,gamma/' "$(mdx_path "$c")"
fail_match "Actions: set mismatch (marker renames beta→gamma)" "$c" \
  "the 'actions-dirs' marker does not match"

# 4. Reusable Workflows: count marker absent → missing-marker branch.
c="$tmp/rw-missing-count"; build_fixture "$c"
sed -i.bak '/reusable-workflows-count:/d' "$(mdx_path "$c")"
fail_match "Reusable Workflows: missing reusable-workflows-count marker" "$c" \
  "Missing 'reusable-workflows-count: N'"

# 5. Reusable Workflows: names marker absent (count present) → missing-names branch.
c="$tmp/rw-missing-names"; build_fixture "$c"
sed -i.bak '/reusable-workflows-names:/d' "$(mdx_path "$c")"
fail_match "Reusable Workflows: missing reusable-workflows-names marker" "$c" \
  "Missing 'reusable-workflows-names: a,b,c'"

# 6. Reusable Workflows: count marker disagrees with the live workflow count.
c="$tmp/rw-count"; build_fixture "$c"
sed -i.bak 's/reusable-workflows-count: 2/reusable-workflows-count: 3/' "$(mdx_path "$c")"
fail_match "Reusable Workflows: count tripwire (marker 3, live 2)" "$c" \
  "but the marker declares"

# 7. Reusable Workflows: count matches but a name is renamed → set-equality fires.
c="$tmp/rw-set"; build_fixture "$c"
sed -i.bak 's/reusable-workflows-names: cd-two,ci-one/reusable-workflows-names: cd-three,ci-one/' \
  "$(mdx_path "$c")"
fail_match "Reusable Workflows: set mismatch (marker renames cd-two→cd-three)" "$c" \
  "'reusable-workflows-names' marker does not match"

# 8. Submodules: marker absent → missing-marker branch.
c="$tmp/submodule-missing-marker"; build_fixture "$c"
sed -i.bak '/projects-submodules:/d' "$(mdx_path "$c")"
fail_match "Submodules: missing projects-submodules marker" "$c" \
  "Missing 'projects-submodules: path=disposition,...'"

# 9. Submodules: a new submodule in .gitmodules not recorded in the marker →
#    submodule set-equality fires.
c="$tmp/submodule-set"; build_fixture "$c"
cat >> "$c/.gitmodules" <<'EOF'
[submodule "newthing"]
	path = applications/newthing
	url = https://github.com/devantler-tech/newthing.git
EOF
fail_match "Submodules: unrecorded new submodule" "$c" \
  "Submodule drift: the 'projects-submodules' marker does not match"

# 10. Templates page (forward): a templates-page submodule (recorded in
#     .gitmodules so the submodule check still passes) has no matching template
#     doc page → templates set-equality fires on the "missing a doc page" side.
c="$tmp/templates-missing-page"; build_fixture "$c"
sed -i.bak 's#templates/foo-template=templates-page#templates/foo-template=templates-page,templates/baz-template=templates-page#' \
  "$(mdx_path "$c")"
cat >> "$c/.gitmodules" <<'EOF'
[submodule "baz-template"]
	path = templates/baz-template
	url = https://github.com/devantler-tech/baz-template.git
EOF
fail_match "Templates: templates-page submodule with no doc page" "$c" \
  "link is wrong): [baz-template]"

# 11. Templates page (reverse): a template doc page whose repo is NOT
#     dispositioned =templates-page in the marker (and not a submodule, so the
#     submodule check still passes) → templates set-equality fires on the
#     "has a doc page but not dispositioned" side.
c="$tmp/templates-extra-page"; build_fixture "$c"
cat > "$c/docs/src/content/docs/templates/qux.md" <<'EOF'
---
title: Qux Template
---
**Repository**: [devantler-tech/qux-template](https://github.com/devantler-tech/qux-template)
EOF
fail_match "Templates: doc page not dispositioned templates-page" "$c" \
  "not dispositioned templates-page in the marker: [qux-template]"

# 12. die_missing: a required submodule is absent → hard error (exit 1 with the
#     "is the submodule checked out?" message), distinct from a drift failure.
c="$tmp/missing-submodule"; build_fixture "$c"
rm -rf "$c/github/devantler-tech/github-actions/actions"
fail_match "die_missing: actions submodule not checked out" "$c" \
  "actions submodule not found"

# 13. Retired-repo link: ANY page under docs/src/content linking to an archived
#     repo trips the guard — not just the guarded lists. Uses the homepage,
#     because that is exactly where this drifted in production: active.mdx was
#     updated when reusable-workflows was archived and the homepage LinkCard was
#     not (monorepo#1813, theme 2).
c="$tmp/retired-link"; build_fixture "$c"
cat >"$c/docs/src/content/docs/index.mdx" <<'FIXTURE'
---
title: Home
---

<LinkCard href="https://github.com/devantler-tech/reusable-workflows" />
FIXTURE
fail_match "retired-repo link on an unguarded page" "$c" \
  "Retired-repo link"

if [ "$fail" -ne 0 ]; then
  printf '❌ active-projects drift-guard self-test FAILED\n' >&2
  exit 1
fi
printf '✅ active-projects drift-guard self-test passed (14 cases)\n'
