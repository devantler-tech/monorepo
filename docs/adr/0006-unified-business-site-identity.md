# Unified business-site identity

## Status

Accepted for the business preview, 2026-10-06. Extends [ADR 0005](0005-business-homepage-and-localization.md).

## Context

Devantler Tech is a one-person software business. A business homepage connected to a separate
personal résumé and documentation site leaves visitors unsure who provides the services. The
founder's public work is useful evidence, but it should support the business rather than imply
a larger team or a roster of paying clients.

## Decision

The flagged business experience uses shared header, footer, typography, colors and appearance
controls throughout. Its About page introduces Nikolai Emil Damm as founder and developer, with
a real public photograph, clear working boundaries and a link to his CV. Its Projects page
introduces actual developer tools and accurately labelled family examples. Both pages have English
and Danish versions, and language switching preserves the page.

The journal and detailed technical pages retain Starlight's search, reading navigation and RSS
inside the same business identity. Historical articles and academic work retain their truthful
authorship and dates. There is no fictional employee directory, inflated agency language,
testimonial or claim that personal work was commissioned by a customer.

The default-off experience remains available while the release flag exists. The CV's data and
drift contract remain authoritative; the business biography does not duplicate its role roster.

## Consequences

Visitors can move from services to the founder, public work and journal without losing the inquiry
route or appearance preference. Shared components prevent page-specific branding drift. The
documentation still has its own reading tools, but only one synchronized appearance picker.

New commercial content must distinguish demonstrated capability from customer promises. A small
business identity does not imply emergency support, unlimited hosting or a larger staff.
