# ADR 0013: Keep frontend decisions with their products

Status: Accepted

Date: 2026-11-02

Supersedes: [ADR 0008](0008-portfolio-frontend-foundation.md)

## Context

The broad comparison in [#4019](https://github.com/devantler-tech/monorepo/issues/4019)
was meant to inform a shared frontend direction before the business-site migration.
Subsequent product work answered its immediate decisions separately:

- The public Svelte migration and Astro retirement have recorded delivery under
  [business-site #130](https://github.com/devantler-tech/business-site/issues/130#issuecomment-6256281084)
  and [#125](https://github.com/devantler-tech/business-site/issues/125).
  [Publication 40865680403](https://github.com/devantler-tech/business-site/actions/runs/40865680403)
  succeeded for `b88bf219f256a3b3b63f3399552c9b5041643b5a`. This is a historical
  publication receipt, not a fresh observation of every live route.
- The private Svelte candidate failed its mandatory maintenance objective. The
  product's [ADR 0017](https://github.com/devantler-tech/business-site/blob/cf7f0f3a3b8d68a5b5c45d93161239344b5f5907/docs/adr/0017-retain-go-private-presentation.md)
  retains Go private presentation and ends further collection for that candidate.
  Its remaining comparison [#142](https://github.com/devantler-tech/business-site/issues/142)
  was concluded as not planned and the candidate was removed.
- Existing Svelte sites, KSail's embedded interface and KHoist's API-only direction
  have different product needs. A common package name does not prove their quality.

The original spike's integrated framework comparison, constrained-device measurements,
hosting/resource comparison and final weighted matrix are incomplete. Restarting them
without an imminent consumer decision would add work without informing the delivered
public/private split. The negative private-candidate result remains a result, not a
reason to change its frozen success criteria or infer a timing/rollback pass.

## Decision

End the broad portfolio framework experiment as **not planned**. Retain Svelte /
SvelteKit / TypeScript as the direction for compatible new or materially changed
general-purpose web interfaces, based on demonstrated consumers and product fit.
Retain the business portal's reviewed Go presentation and server authority.

No universal performance winner or completed portfolio standardization is declared.
Keep existing healthy interfaces unless a named product outcome justifies a change.
KSail's embedded interface and documentation, World at Ruin's native game and vendor
applications retain their own appropriate technology. Do not benchmark a KHoist UI
that the API-only programme is retiring merely to complete the abandoned comparison.

Keep shared quality requirements: accessible native navigation/forms, measured browser
work appropriate to the actual route, private server-side authority and cache/origin
boundaries, supported dependencies and licenses, source-owned publication and tested
recovery. Invitation-only access, federated identity, customer isolation and financial
authority are not frontend choices and receive no exception from this decision.

An actual new framework decision must name the consumer and unmet need, compare
equivalent workloads against the existing product baseline, preserve these floors and
record uncertainty. It does not need to reopen every alternative for every product.
Do not extract a shared component library until two real consumers demonstrate need.

## Ownership and consequences

The [adoption programme #4222](https://github.com/devantler-tech/monorepo/issues/4222)
continues through independently useful product work. Retiring research does not
complete it or any unchecked product acceptance criterion:

- [#4224](https://github.com/devantler-tech/monorepo/issues/4224) owns supported starter
  placement and guidance, using demonstrated consumers rather than a speculative service.
- [#4223](https://github.com/devantler-tech/monorepo/issues/4223) owns existing-site
  quality; [KSail #7796](https://github.com/devantler-tech/ksail/issues/7796) owns its
  embedded-interface assessment.
- [Business-site #131](https://github.com/devantler-tech/business-site/issues/131)
  retains Go portal integration, identity, authorization and real-user-path acceptance.
- [KHoist #426](https://github.com/devantler-tech/khoist/issues/426) must follow the
  API-only product decision under [#390](https://github.com/devantler-tech/khoist/issues/390)
  and [#392](https://github.com/devantler-tech/khoist/issues/392), preserving any
  independent compatibility and retirement obligations.

The portfolio stack map continues to route changes to their existing product owners;
this decision creates no new buildable product or hosting permission. Deployment,
rollback, security, accessibility and customer activation remain independently gated.
Revise this ADR if a concrete consumer exposes a material disadvantage in the retained
direction, rather than reinstating a universal benchmark as a prerequisite.
