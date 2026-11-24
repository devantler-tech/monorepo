# ADR 0020: One GitHub token broker for every caller

Status: Accepted. The maintainer delegated the design on 2026-11-24.

Date: 2026-11-24

Issue: the epic [#5166](https://github.com/devantler-tech/monorepo/issues/5166)

## Context

Automation reaches GitHub through the organization's GitHub Apps, botantler-1 and botantler-2. Today
each caller, whether a workflow or a platform workload, mints its own tokens from App credentials it
holds itself. So the credentials are spread across many callers, each one can mint more than its
job needs, and no single place shows who may obtain which access. Most workflow callers are
`devantler-tech/.github`'s shared workflows.

On 2026-11-24 the maintainer asked for one hosted service to handle all programmatic GitHub access:
workflows and platform workloads prove who they are with workload identity instead of stored
credentials, only the service's own App credentials live in OpenBao, and the service spreads load
over both Apps, because GitHub rate-limits each App installation separately. He asked whether
hosting it on the platform creates a chicken-and-egg problem.

## Decision

1. **[octo-sts](https://github.com/octo-sts/app) is the broker.** A caller presents an OIDC token. The
   broker checks it against a trust policy and returns an installation token scoped to that policy's
   repositories and permissions. It lasts at most an hour, and the caller revokes it when done.
   - GitHub Actions callers use `octo-sts/action` with `id-token: write`. The issuer is
     `https://token.actions.githubusercontent.com`.
   - Platform workloads present a projected service-account token, whose issuer is the cluster's
     service-account issuer.
   - The broker accepts those two issuers only (`OCTOSTS_ALLOWED_ISSUERS`).
2. **Every grant is a file reviewed in a pull request.**
   - A policy lives at `.github/chainguard/<identity>.sts.yaml` in the repository the token is for,
     or in `devantler-tech/.github` for an identity that spans repositories.
   - It matches exact claims (repository, ref, workflow file, service account), never broad
     patterns.
3. **Both botantler Apps sit behind the broker,** which sends each exchange to the installation with
   the most rate limit left. A policy that must create release tags pins botantler-1 until
   botantler-2 joins the release-tag creation bypass list. The agents' devantler-tech-engineering App
   can join the same way, pinned by its own policies.
4. **The broker runs on the platform.** It runs in prod only, because it is a third-party app
   ([ADR 0016](0016-dev-and-prod-deployments.md)), behind the public Gateway. The App credentials
   live only in OpenBao and reach the broker through External Secrets.
5. **The platform's own recovery never depends on the broker.**
   - Flux pulls every source anonymously from public registries.
   - The platform deploys with each workflow's own built-in token.
   - A check keeps the platform's deploy and recovery workflows off the broker.
   - Break-glass needs no service: an organization admin can cut a release by hand (the release-tag
     ruleset's admin bypass), and the App private keys are also kept offline by the maintainer.
6. **The organization App secrets are deleted** once nothing reads them.

## Options compared

| Option | Actions callers | Platform callers | Keys | Outcome |
|---|---|---|---|---|
| octo-sts on the platform | Yes, OIDC | Yes, service-account tokens | OpenBao only | Chosen |
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
- A platform outage pauses automation that needs an App token, such as release tags, auto-merge
  arming, template sync and skill updates. It never blocks the platform's own repair.
- botantler-2 joins the release-tag creation bypass list before any release policy routes to it.
- octo-sts is pre-1.0 and releases often. Its image is pinned by digest and updated by reviewed
  pull requests. A policy that writes checks pins one App, because octo-sts needs Firestore or
  DynamoDB to keep checks on one App across several.
- The cluster's service-account discovery endpoints become readable without authentication. They
  hold public keys only. The broker trusts the API server's CA.
- The migration runs in order under #5166:
  1. The platform runs the broker with both Apps.
  2. `devantler-tech/.github`'s shared workflows move to it, with organization policies.
  3. The remaining repository workflows move.
  4. Platform callers move: the agents and Crossplane's GitHub provider.
  5. The organization App secrets are deleted.
