# devantler.tech

The [devantler.tech](https://devantler.tech) site — an [Astro](https://astro.build) +
[Starlight](https://starlight.astro.build) static site. It lives in this monorepo (`docs/` + repo
root) and deploys to GitHub Pages via `.github/workflows/publish-pages.yaml`.

## Develop

```sh
cd docs
npm install
npm run dev      # local dev server
npm run build    # production build (this is what CI validates)
```

## Blog editorial standard

The blog is a maintained product for people outside the repository, not a release-note feed or an
internal engineering diary. A worthwhile post starts from a real audience and problem, helps readers
understand why the work matters, and gives them a useful next step.

Use this high-level story shape: **Problem → Why it matters → What Devantler Tech built → Verified
outcome and trade-offs → Next step**. Define unavoidable jargon and explain where the product fits in
the wider portfolio. Link to deep implementation detail instead of making it the opening premise.
Never invent first-person experience, users, testimonials, adoption numbers, or precision that the
available evidence cannot support.

For an honest update on work still under way, use **Problem → Why now → Current status → Shipped
versus planned → Known unknowns and trade-offs → Next step**. Label shipped and planned work plainly;
do not turn intent into an implied outcome.

New posts and material updates to existing posts follow the same quality bar:

- Start from current, privacy-safe quantitative or qualitative evidence: recurring questions,
  adoption/onboarding friction, a meaningful shipped outcome, stale positioning, or an important
  lesson whose claims can be verified. Page views alone are not proof of value.
- Use complete frontmatter: intentional title, date, authors, useful tags, distinct description and
  excerpt, and a relevant cover image with descriptive alt text.
- Verify every command, product/version/license statement, screenshot, example, and link against the
  current portfolio. Refresh useful old posts when those facts or their positioning change.
- Keep the presentation skimmable and professional: a clear opening, descriptive headings, short
  paragraphs, purposeful visuals, and a relevant call to action.
- Verify follower-facing distribution: RSS inclusion, social/OG presentation, and a measurable CTA.
  Preview the result across mobile, tablet, and desktop, then run `npm run build` from `docs/` before
  opening the draft PR.

Publication cadence is a prompt to review opportunities, never a reason to create filler. Record the
intended reader outcome before publishing and revisit privacy-safe aggregate signals after the chosen
measurement window to improve, redistribute, update, or retire the content.

For a substantive publication or refresh, keep one experiment issue open with the audience, evidence,
hypothesis, success proxy, measurement window, and follow-up date. Close its delivery child when the
post merges; close the experiment only after recording the measured outcome and resulting decision.
Keep this lane single-flight—maintain or measure the current post before starting another.

## Feature flags (build-time)

Part of the portfolio-wide **feature-flag-first delivery** program
([monorepo#2059](https://github.com/devantler-tech/monorepo/issues/2059)): unreleased content or UI
lands **behind a default-off flag** so it can ship latent and be previewed before it goes live.

The site is a **pure static build**, so flags are **baked at build time** — there is no runtime,
per-user, or percentage evaluation. Flipping a flag means a **rebuild + redeploy**. (Live/per-user
rollout would require an SSR/hybrid adapter or a client-side [OpenFeature](https://openfeature.dev/)
web island — explicitly out of scope for the static site today.)

### The convention — `astro:env`

Flags are declared in the Zod-validated [`astro:env`](https://docs.astro.build/en/guides/environment-variables/)
`env.schema` in [`astro.config.mjs`](astro.config.mjs) — type-safe over raw `import.meta.env`:

```js
env: {
  schema: {
    FEATURE_PREVIEW_BANNER: envField.boolean({
      context: "server",   // read at build time in .astro components (SSG)
      access: "public",
      default: false,      // OFF by default — production omits the gated output
    }),
  },
},
```

Gate rendering on the flag by importing it from `astro:env/server` (or `astro:env/client` for a
`PUBLIC_`-prefixed client flag) — see [`src/components/PreviewBanner.astro`](src/components/PreviewBanner.astro),
the worked example wired into the home page. When the flag is off, the component emits nothing.

Flags can also gate **content-collection inclusion** (filter entries out of `getCollection(...)`
when a flag is off) to hold back whole docs sections.

### Preview builds

To review flagged content before production enables it, run a **preview build** with the flag on:

```sh
FEATURE_PREVIEW_BANNER=true npm run build
```

The production build (CI / `publish-pages.yaml`) leaves the flag unset, so it stays off.

### Lifecycle — remove the gate once shipped

A *release* flag is **short-lived**. Once the content/UI is live for good:

1. Delete the flag from the `env.schema` in `astro.config.mjs`.
2. Inline the gated markup (drop the `{ FLAG && (...) }` wrapper) or delete the example component.
3. Remove the flag from any preview-build invocations.

A growing set of stale flags is debt, not progress — retire each one as soon as its content ships.
Only a genuine kill-switch or a permanent setting is long-lived (and a permanent setting belongs in
plain config, not a flag).
