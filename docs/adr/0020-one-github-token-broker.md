# ADR 0020: One GitHub token broker for every caller

Status: Accepted. The maintainer delegated the design on 2026-11-24, and on 2026-11-25 chose one
broker and the botantler Apps for every caller, behind a caller gate.

Date: 2026-11-24. Amended 2026-11-25.

Issue: the epic [#5166](https://github.com/devantler-tech/monorepo/issues/5166)

## Context

Automation reaches GitHub through GitHub Apps. Today each caller mints its own tokens from App
credentials it holds itself:
- the organization's workflows use botantler-1 and botantler-2;
- the platform's agents use the devantler-tech-engineering App;
- Crossplane's GitHub provider uses an App of its own.

So the credentials are spread across many callers, each one can mint more than its job needs, and no
single place shows who may obtain which access. Most workflow callers are `devantler-tech/.github`'s
shared workflows.

On 2026-11-24 the maintainer asked for one hosted service to handle all programmatic GitHub access:
workflows and platform workloads prove who they are with workload identity instead of stored
credentials, only the service's own App credentials live in OpenBao, and the service spreads load
over both botantler Apps, because GitHub rate-limits each App installation separately. He asked
whether hosting it on the platform creates a chicken-and-egg problem.

On 2026-11-25 he set the boundary: only devantler-tech repositories, devantler-tech workloads and
named customer repositories may ever get a token from his Apps. He chose one broker, with
botantler-1 and botantler-2 as the Apps for every caller, and asked for protection against floods.

## Decision

1. **[octo-sts](https://github.com/octo-sts/app) is the broker.** A caller presents an OIDC token. The
   broker checks it against a trust policy and returns an installation token scoped to that policy's
   repositories and permissions. It lasts at most an hour, and the caller revokes it when done.
   - GitHub Actions callers use `octo-sts/action` with `id-token: write`. The issuer is
     `https://token.actions.githubusercontent.com`.
   - Platform workloads present a projected service-account token, whose issuer is the cluster's
     service-account issuer.
   - The broker accepts those two issuers only (`OCTOSTS_ALLOWED_ISSUERS`).
2. **A caller gate admits only allowed callers, before octo-sts sees the request.** Any GitHub
   repository in the world can get an Actions token for the broker's audience. octo-sts reads a
   trust policy from GitHub before it checks the caller, so without a gate anyone could spend the
   Apps' shared hourly quota on made-up identities. A loose policy in any devantler-tech repository
   would also admit them. octo-sts has no caller allowlist, so an Envoy in the broker's pod takes every
   request:
   - It verifies the token against the issuer's published keys and requires the broker's audience
     and an expiry.
   - It admits only these callers:
     - a GitHub Actions token from the devantler-tech organization, matched by its numeric ID
       (`repository_owner_id`), which survives renames and cannot be re-registered;
     - a named customer repository, by `repository_id`;
     - a named platform workload, by its exact service-account subject.
   - It gives admitted callers a per-pod request budget.
   - It forwards only the exchange endpoint, with the token, so octo-sts still verifies it and
     applies the trust policy.

   The allowlist lives in the platform repository, and a test pins it, so it changes only on purpose.
   The gate goes if octo-sts gains an equivalent.
3. **Every grant is a file reviewed in a pull request.**
   - A policy lives at `.github/chainguard/<identity>.sts.yaml` in the repository the token is for,
     or in `devantler-tech/.github` for an identity that spans repositories.
   - It matches exact claims (repository, ref, workflow file, service account), never broad
     patterns. It pins its callers by the same IDs the gate uses. A required check from
     `devantler-tech/.github` enforces that on every repository.
   - When octo-sts can refuse repository-level policies
     ([octo-sts/app#1919](https://github.com/octo-sts/app/pull/1919)), every grant moves to
     `devantler-tech/.github`.
4. **botantler-1 and botantler-2 serve every caller,** and the broker routes each exchange by
   rate limit left. The agents' App and Crossplane's App retire once their callers move. One pair of
   Apps stays safe because each policy pins the App that its access needs:
   - **Release tags:** only botantler-1 may create them (the release-tag ruleset's bypass), and only
     release workflows' policies pin it.
   - **Other write access:** any other policy that grants write access pins botantler-2, so an agent
     or customer token can never cut a release.
   - **Read-only:** a read-only policy may use either App.
   - **Administration:** the permission Crossplane needs is allowed in Crossplane's policy only.
5. **Customer repositories only call in.** The broker serves the devantler-tech organization only,
   so every token is for a devantler-tech repository. A customer's organization is never a target,
   because octo-sts would then read that organization's own policies.
6. **The broker runs on the platform.** It runs in prod only, because it is a third-party app
   ([ADR 0016](0016-dev-and-prod-deployments.md)), behind the public Gateway and Cloudflare. The
   App credentials live only in OpenBao and reach the broker through External Secrets.
7. **The platform's own recovery never depends on the broker.**
   - Flux pulls every source anonymously from public registries.
   - The platform deploys with each workflow's own built-in token.
   - A check keeps the platform's deploy and recovery workflows off the broker.
   - Break-glass needs no service: an organization admin can cut a release by hand (the release-tag
     ruleset's admin bypass), and the App private keys are also kept offline by the maintainer.
8. **The organization App secrets are deleted** once nothing reads them.

## Options compared

| Option | Actions callers | Platform callers | Keys | Outcome |
|---|---|---|---|---|
| octo-sts on the platform, behind a caller gate | Yes, OIDC | Yes, service-account tokens | OpenBao only | Chosen |
| The same without a gate | Yes | Yes | OpenBao only | Rejected: anyone can spend the Apps' quota, and one loose policy admits outsiders |
| Two brokers: a public one, and an internal one for the agents' and Crossplane's Apps | Yes | Yes | OpenBao only | Rejected by the maintainer for one broker and one pair of Apps. The gate and the App pins give the same boundary |
| octo-sts on Cloud Run or AWS Lambda | Yes | Only with the cluster issuer published | A cloud secret store | Rejected: adds a vendor, moves the keys out of OpenBao, and removes no dependency that recovery needs |
| OpenBao with a GitHub secrets plugin | Only if GitHub's runners can reach OpenBao | Yes | OpenBao | Rejected: exposes the secret store to the internet, and the plugin's OpenBao compatibility is unverified |
| External Secrets `GithubAccessToken` generator | No | Yes | Copied into every consumer namespace | Rejected: serves platform callers only |
| GitHub's own OIDC exchange (`create-github-app-token` v3.4.0-beta) | Yes | No | None for callers | Watched: beta, Actions only, controls not yet documented. If it becomes generally available, Actions callers may use it directly |
| Organization secrets (today) | Yes | No | Every workflow | Replaced |

Hosting elsewhere would make the broker survive a platform outage, but the outage would still stop
nothing that recovery needs, and the keys would have to leave OpenBao or the broker would still
depend on the platform's OpenBao. Google's *Building Secure and Reliable Systems* (chapter 9) asks
that emergency access not depend on the normal credential service. Here the emergency path is an
organization admin, so it does not.

## Consequences

- No caller stores a GitHub credential. Each token is short-lived, narrowly scoped and revoked after
  use, and each grant is a reviewed file.
- Only allowed callers reach octo-sts. Everyone else is refused by a signature check, without a
  GitHub call. Cloudflare absorbs floods in front of the cluster, and the per-pod budget stops an
  allowed caller in a loop.
- A platform outage pauses automation that needs an App token, such as release tags, auto-merge
  arming, template sync, skill updates and the agents. It never blocks the platform's own repair.
- The agents' pull requests come from botantler-2 instead of devantler-tech-engineering. The merge
  and review rules that trust the botantler Apps must tell agent work apart from programmed
  automation by its branch namespace, not by its author.
- octo-sts is pre-1.0 and releases often. Its image is pinned by digest and updated by reviewed
  pull requests. A policy that writes checks pins one App, because octo-sts needs Firestore or
  DynamoDB to keep checks on one App across several.
- The cluster's service-account discovery endpoints become readable without authentication. They
  hold public keys only. The broker trusts the API server's CA.
- The migration runs in order under #5166:
  1. The platform runs the broker with both Apps, behind the caller gate.
  2. Every repository gets the required policy check. Then `devantler-tech/.github`'s shared workflows
     move to the broker, with organization policies.
  3. The remaining repository workflows move.
  4. Platform callers move: the agents and Crossplane's GitHub provider. Then their Apps retire.
  5. Named customer repositories join, one allowlist entry and one policy each.
  6. The organization App secrets are deleted.
