# ADR 0017: Products sign their own releases

Status: Accepted.

Date: 2026-11-14

Issue: the epic [#5046](https://github.com/devantler-tech/monorepo/issues/5046)

## Context

A product publishes each release as two signed artifacts: its container image, and a manifests
artifact holding its `deploy/` folder. Today one shared reusable workflow in `devantler-tech/.github`,
`publish-app.yaml`, builds and signs both, and each product calls it at an exact commit. A keyless
signature names the workflow that made it, so every signature names a commit of the shared
workflow, not the product the release belongs to.

The platform checks those signatures in three places: Flux before it reconciles a manifests
artifact, Kyverno before it admits a pod, and Talos before a node pulls an image. All three can match
only a signature's issuer and subject. So the platform trusts each approved commit of the shared
workflow, and guards that trust with a list of approved commits, a limit of two at a time, checks on
how products pin the workflow, and a report of which commit signed what. About 5,000 lines of
platform scripts and tests serve this.

`.github` releases several times a day, and every commit a product wants to use needs its own
platform approval. In the four weeks to 2026-11-14 that took about a dozen approval-only pull
requests, while some products ran a publisher several weeks old. And because the subject names the
shared workflow, a signature cannot say which product it was made for
([platform#3749](https://github.com/devantler-tech/platform/issues/3749)).

On 2026-11-14 the maintainer asked for this to be rethought from the ground up, and simplified while
staying secure.

## Decision

1. **A product signs its own releases.** The shared publishing steps become a composite action in
   `devantler-tech/.github`, run by the product's own release workflow. A keyless signature then
   names that workflow at its release tag:
   `https://github.com/devantler-tech/<repo>/.github/workflows/<file>@refs/tags/vX.Y.Z`.

2. **The platform trusts each tenant's own repository on release tags.** A tenant's manifests source
   accepts only its own repository's release workflow on a `v<semver>` tag. The rule follows from the
   tenant's name and never changes between releases. Image admission and node pull rules accept a
   first-party repository's release workflow on a release tag, and a tenant runs the image digest its
   verified manifests pin.

3. **Only release tags cut from `main` are signed.** Release tags cannot be moved or deleted, and
   releases are immutable. Only the release process may create a release tag, and the action refuses
   to sign a tag whose commit is not on the default branch.

4. **The shared code is an ordinary dependency.** A product pins the action like any other action and
   takes new versions through its own reviewed dependency pull requests. Workflow lockfiles can pin
   it later ([.github#923](https://github.com/devantler-tech/.github/issues/923)); they cannot pin a
   reusable workflow.

5. **The approval machinery goes.** Once every consumer signs as itself, the platform deletes the
   approved-commit lists, the two-commit limit, the pin checks, the signing report and the publisher
   source bindings.

## Options compared

- **Keep approving each commit, from one source file.** Each approval gets cheaper, but every
  publisher commit still needs a platform change, and a signature still does not name the product.
- **Trust the shared workflow's immutable release tags within a major version.** Most approval pull
  requests go away, but a signature still names the shared workflow, so a tenant still cannot be tied
  to its own repository, and each new major still needs a platform change.
- **Write the publishing steps into each product's release workflow.** There is nothing shared to
  pin, and the tenant template already keeps its tenants' release workflow in sync. But products not
  made from the template would each carry their own copy of the steps.

## Consequences

- The platform no longer reviews each revision of the shared publishing code separately. A change to
  it is reviewed when it merges in `.github`, and again when each product takes the new version.
- A tenant's manifests can only come from its own repository, which resolves platform#3749.
- World at Ruin's zone server and KHoist's chart already sign as themselves, so they already follow
  this decision.
- The migration runs in order under #5046: hardening
  ([platform#6264](https://github.com/devantler-tech/platform/issues/6264),
  [.github#924](https://github.com/devantler-tech/.github/issues/924)), the action
  ([.github#925](https://github.com/devantler-tech/.github/issues/925)), the platform's trust
  ([platform#6265](https://github.com/devantler-tech/platform/issues/6265)), each consumer's
  switch, and last the deletion of the approval machinery
  ([platform#6266](https://github.com/devantler-tech/platform/issues/6266)). Until the last
  consumer moves, the platform trusts both identities.
- A product that splits `deploy/` into base, prod and dev
  ([ADR 0016](0016-dev-and-prod-deployments.md)) switches in the same change, and names its app
  manifest through the action's `app-manifest` input.
- A pre-release is signed only when its tag's commit is on `main`, so dev can no longer preview
  unmerged work by publishing a pre-release, as ADR 0016 decision 2 allowed. Dev previews what has
  merged.
