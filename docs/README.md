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
