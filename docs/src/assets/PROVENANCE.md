# Asset provenance — `docs/src/assets`

## `matrix.png`

Committed splash-hero background for `docs/src/content/docs/index.mdx`.

- **Origin:** generated once by `docs/scripts/generate-hero.py` (Pillow / `PIL`), a manual
  offline generator that was never wired into CI.
- **Removed generator:** `d847f3b` / [#2232](https://github.com/devantler-tech/monorepo/pull/2232)
  (`chore: remove generate-hero.py, the last Python file in the repo`) — portfolio scripting is
  bash or Go only.
- **Status:** the PNG is the durable asset. Do not reintroduce a Python generator; if the hero
  must be regenerated, rewrite the tool in Go (or replace the image by hand) and update this note.

Closes the acceptance criteria of [#2176](https://github.com/devantler-tech/monorepo/issues/2176).

## `agentic-engineering-process.png`

Cover and inline diagram for the Agentic Engineering documentation and blog post.

- **Origin:** rendered from the Mermaid `block-beta` definition embedded in
  `docs/src/content/docs/agentic-engineering.mdx`.
- **Rendering:** light background, three category boxes, and a numbered serpentine activity flow;
  exported at 3808×2142 (16:9).
- **Status:** the MDX Mermaid definition is the editable source. Regenerate the PNG from that source
  whenever the process or diagram changes, and update both in the same change.
