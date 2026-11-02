# Frontend direction and adoption

[ADR 0013](adr/0013-product-owned-frontend-decisions.md) retains Svelte / SvelteKit /
TypeScript for compatible new or materially changed general-purpose web interfaces,
and the business portal's reviewed Go private presentation. It ends the broad
[framework experiment #4019](https://github.com/devantler-tech/monorepo/issues/4019)
as not planned; its missing comparisons remain unmeasured. The dated
[ADR 0008](adr/0008-portfolio-frontend-foundation.md) preserves that earlier proposal.

Use product needs and common quality floors to choose a rendering pattern. No universal
fastest framework or completed portfolio standardization is claimed. Keep healthy
specialized interfaces unless a product-owned comparison justifies their replacement.
The executable stack map retains the existing product owners and creates no new service.

## Dated baseline, not a live package census

These public-source revisions were inspected on 2026-10-15. Rebind the affected product's
actual default branch, repository instructions and dependency lock before implementation.
The monorepo's gitlink can lag a product's source; this table is not permission to branch
from a stale pin.

| Product and source baseline | Observed frontend | Adoption or exception work |
| --- | --- | --- |
| business-site `85b8c8ad4d9dd8ec5f6e97ea7e494a875b32c569` | Astro 7.3.6 / Starlight 0.42.5, Go private portal | [Foundation #124](https://github.com/devantler-tech/business-site/issues/124), [public parity #130](https://github.com/devantler-tech/business-site/issues/130), [Go-authoritative portal #131](https://github.com/devantler-tech/business-site/issues/131) |
| ascoachingogvaner `b121f61ef5787f20a10b97e96c2a9d3e495631e2` | SvelteKit 3 / Svelte 5, static adapter | [Existing-site conformance #4223](https://github.com/devantler-tech/monorepo/issues/4223) |
| wedding-app `c2865745259ed16a498e30331f6a33be05434779` | SvelteKit 3 / Svelte 5, Node adapter, PostgreSQL | [Existing-site conformance #4223](https://github.com/devantler-tech/monorepo/issues/4223) |
| ksail `3f499bb220cc5b9b0c0039de43d6264a65c977f8` | React 19 / MUI / xterm embedded UI; Astro 7 documentation | [Embedded UI assessment #7796](https://github.com/devantler-tech/ksail/issues/7796); keep documentation content-first unless its own evidence supports a change |
| khoist (then data-product-controller) `1f4723b55ac365ec048e0cbbabfbb719f1ff0ce4` | Go server-rendered `/ui`; no application package.json | [Server-rendered UI assessment #426](https://github.com/devantler-tech/khoist/issues/426) |
| world-at-ruin `3014d84db4bff8de4a602c6c7e5ad5cf93633a99` | Native Godot 4.7.1 game; tool-only npm package | Specialized native/game surface, outside the DOM frontend adoption; no Svelte rewrite implied |

Vendor applications deployed by the platform are not portfolio-authored frontend source.
Since this baseline, the public business-site Svelte migration and Astro retirement
have delivery records under [#130](https://github.com/devantler-tech/business-site/issues/130#issuecomment-6256281084)
and [#125](https://github.com/devantler-tech/business-site/issues/125). Its
[private-presentation decision](https://github.com/devantler-tech/business-site/blob/cf7f0f3a3b8d68a5b5c45d93161239344b5f5907/docs/adr/0017-retain-go-private-presentation.md)
retains Go after rejecting the Svelte candidate. KHoist's API-only direction under
[#390](https://github.com/devantler-tech/khoist/issues/390) /
[#392](https://github.com/devantler-tech/khoist/issues/392) takes precedence over
benchmarking its retiring product UI. These are product decisions, not evidence that
every current deployment or remaining acceptance criterion has been verified.

The [owned starter/template follow-up #4224](https://github.com/devantler-tech/monorepo/issues/4224)
must select an existing owner and validate a clean-start path; this record does not invent
a new repository or claim all templates already conform. The portfolio
[adoption epic #4222](https://github.com/devantler-tech/monorepo/issues/4222) owns the linked
investigation and independently deliverable slices.

## Before choosing an implementation pattern

1. Name the actual visitor or authenticated workflow and its baseline. Distinguish static
   reading, dynamic forms and genuinely interactive UI. Select prerender/SSR/optional
   client rendering by need, not a single hydration setting for the entire application.
2. Keep sensitive state on its authoritative server. Prove server-only code cannot enter
   the production browser bundle; unit-test behavior alone does not prove that boundary.
   Private pages must enforce current customer/operator authority and private cache rules.
3. Preserve keyboard semantics, semantic landmarks, language switching, current public
   URLs, images, SEO and failure behavior. Add real user-path evidence, not only selectors
   asserting that component names exist.
4. Audit the exact dependency graph and licenses, supported runtime and deployment
   constraints. Keep secret values out of client builds and repository artifacts. New
   hosting or services require the existing spend/approval process.
5. Compare equivalent workloads. Record source/locks/toolchain, repeated build results,
   browser-transferred assets, no-JS behavior, interaction/load measurements, accessibility
   and hosting needs. A narrow viewport is not a constrained CPU/network measurement;
   an emitted bundle is not necessarily transferred on the visited route.

The historical [comparison source and results](https://github.com/devantler-tech/business-site/tree/18029834054e8951b134570463a6c13116b45f22/research/frontend-4019)
make the bounded sample reproducible. Its native forms and fictional data are not a real
identity-provider, customer-isolation or payment acceptance result. Keep those gaps
visible in product-owned acceptance. Do not restart rejected-candidate collectors to
complete the retired broad comparison or report missing results as passing.

## Business-site ownership and remaining acceptance

The historical default-off [foundation PR #133](https://github.com/devantler-tech/business-site/pull/133)
introduced `web/` in the source repository, not the aggregator. Current product source
uses the public Svelte frontend and retained Go portal; publication and business facts
remain owned by that repository. A new frontend must not create a second sign-in,
payment or work authority.

The delivered public migration #130 covered existing public routes and redirects, the bilingual
home/offer/contact/company copy, ranked six-tool portfolio, Journal and its unique artwork,
CV and technical pages. An About-only build is not that parity. Preserve the existing
price/maintenance/legal/contact decisions rather than inventing new claims during a
framework change. Its delivery record is historical evidence; rebind the current source
and actual visitor path when changing it.

Portal integration #131 retains its reviewed Go presentation/API boundary and must
prove authenticated and cross-client refusal, current roles,
expiry/logout/revocation, native forms, server errors and a11y. Keep one federated OIDC
broker, invitation-only access, verified server-side payment authority and the portal-owned
API/MCP work queue. Do not introduce a client-orders repository. The migration does not
enable real customer intake or payments, and private consumer access is not excluded by
the invitation-only policy.

Before a live route changes: reviewed parity/security evidence, settled exact-head CI,
source-owned deployment and live receipt, EN/DA visitor checks and a tested rollback path
are separate requirements. Do not retire working production code before replacement
publication is verified. The original public
[gate retirement #125](https://github.com/devantler-tech/business-site/issues/125)
is delivered; it is not a future prerequisite to repeat. Any new release gate needs its
own bounded adoption and retirement evidence.
