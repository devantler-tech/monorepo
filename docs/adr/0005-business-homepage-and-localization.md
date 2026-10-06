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

Starlight owns the supporting documentation and journal. A small integration injects the business
routes in every production and development build. Separate route entrypoints avoid leaking
Starlight's global CSS into marketing pages, and component-scoped business styles do not restyle
the documentation.

The business pages preserve the original green identity and decorative Matrix image. A native
appearance selector supports System, Light and Dark, with English/Danish labels. An inline head
script applies the preference before painting and shares Starlight's storage key and System
representation so visits to supporting pages retain the choice. System changes update the current
page unless the visitor explicitly selects a theme; blocked storage does not prevent switching.
The no-JavaScript layout follows the system theme and omits the inactive control.

The opening section names the developer, shows the existing public profile photograph and links
to his biography and public code. First-person copy and explicitly labelled family projects provide
personal context without implying an agency team, paid client history or manufactured social proof.
The same photograph is used for social sharing rather than the illustrated technical avatar.

The production build checks the published experience against emitted HTML. Checks cover language routes,
starting prices, navigation, the developer's portrait and profile links, inquiry links and supporting
pages. Controller tests cover saved choices, system changes and blocked storage. No application
backend or new dependency is needed for the inquiry journey.

## Consequences

The marketing copy is translated as a unit, while supporting technical content remains English.
LinkedIn supplies a real contact destination until company contact details are confirmed. Paid
subscriptions, checkout and contractual service guarantees are not implied by the product list.
The business experience requires no release flag. Recovery uses a reviewed revert and redeploy.
