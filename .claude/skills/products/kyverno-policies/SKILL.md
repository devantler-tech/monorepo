---
name: maintain-kyverno-policies
description: Maintenance + advance task menu for devantler-tech/kyverno-policies — the shared, tested Kyverno policy catalog the platform and platform-template consume instead of vendoring per-repo copies. Use when the daily maintainer selects kyverno-policies.
---

# Maintain: Kyverno policy library (shared library)

The reusable **Kyverno policy catalog** for the devantler-tech platforms. Generic admission and
generation policy behaviour lives here **once**, so consumer copies in
[`platform`](../platform/SKILL.md) and `platform-template` cannot drift apart. Consumer wiring and
rollout stay separate changes in those repositories.

The canonical task menu lives **in the repo itself** — read the **`## Maintenance`** section of
`libraries/kyverno-policies/AGENTS.md` (on the submodule's latest `main`):
<https://github.com/devantler-tech/kyverno-policies/blob/main/AGENTS.md>. This card is a pointer by
design — the menu is maintained once, in the product's own `AGENTS.md`.

**A policy is inert until a consumer pins and references it.** Adding one to the catalog changes
nothing on any cluster; adoption is its own draft PR, validated in every affected overlay. Keep
policies generic — environment-specific exclusions, patches, and rollout choices belong to the
consumer repo, never here.

**Behaviour is test-first, and the gate has teeth.** Every policy carries a `kyverno test` contract
under `tests/<policy>/`; for a generate rule, assert the complete generated resource **and** at least
one nonmatching resource. `kyverno test .` discovers fixtures recursively, so a new policy is covered
as soon as its fixture exists — never hand-list fixture paths in a runner. Note that a bare
`kyverno apply` is **fail-open** (it exits 0 on failures unless `--warn-exit-code` is set), so trust
the repo's own validation block rather than a naive invocation.

**Validation** (run every gate before opening or updating a PR — the repo's `AGENTS.md` is
authoritative if this drifts):

```sh
yamllint .
kubectl kustomize . > /dev/null
kyverno test . --require-tests --detailed-results --remove-color
bash scripts/test-policy-catalog.sh
shellcheck scripts/test-policy-catalog.sh
actionlint .github/workflows/ci.yaml
zizmor .github/workflows/ci.yaml
git diff --check
```

Tests are **static and local** — never connect to or mutate a live cluster to validate a
policy-library diff.

Shared cross-repo rules are in the monorepo [`AGENTS.md`](../../../../AGENTS.md).

## Roadmap & enhancement

Roadmap lives in **GitHub Issues** on `devantler-tech/kyverno-policies` (`roadmap`-labelled epics +
milestones). To **advance** (catalog coverage, the GeneratingPolicy API migration, test depth, CI
hardening, docs) follow [`product-engineering`](../../product-engineering/SKILL.md).
