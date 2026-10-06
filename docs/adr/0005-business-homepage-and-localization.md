# Business homepage and localization

Date: 2026-10-06
Status: Accepted

## Context

Small-business customers need a clear account of purchasable services, starting prices, hosting
boundaries and a way to inquire. The engineering documentation, profile and blog serve a different
audience and remain useful supporting material.

## Decision

The business experience uses dedicated static Astro homepage routes at `/` and `/da/`. Both share
one component, stable section identifiers and typed English/Danish copy. Explicit language links,
canonical URLs and alternate-language metadata make localization independent of browser language
or client-side rendering. Switching languages preserves the current section.

Starlight continues to own the supporting documentation, blog and profile. Its existing homepage
content remains the default-off route during the short release-flag lifecycle. A small integration
injects business routes only for enabled builds. Configuration bootstraps inclusion from the
process environment because `astro:env` cannot be imported in Astro configuration; the injected
entrypoint also checks the native, schema-validated flag. Separate route entrypoints avoid leaking
Starlight's global CSS into marketing pages, and component-scoped business styles do not restyle
the documentation.

The build exercises both release states against emitted HTML. Checks cover language routes,
starting prices, navigation, inquiry links, preserved supporting pages and absent unreleased
markup. No application backend or new dependency is needed for the inquiry journey.

## Consequences

The marketing copy is translated as a unit, while supporting technical content remains English.
LinkedIn supplies a real contact destination until company contact details are confirmed. Paid
subscriptions, checkout and contractual service guarantees are not implied by the product list.
The separate publication issue owns removal of the temporary release flag after evaluation.
