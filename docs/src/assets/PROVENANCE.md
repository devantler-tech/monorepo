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
