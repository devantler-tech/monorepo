# 🗂️ Devantler's Monorepo

This repository is a monorepo that contains all my active projects as submodules, effectively bridging a manyrepo and monorepo. This allows me to keep all my projects in one place and easily manage them in VSCode, while avoiding common pitfalls introduced with monorepos (e.g. no repo-per-product, complex release-strategy, overpriviliged access)

<img width="1800" alt="image" src="https://github.com/devantler/monorepo/assets/26203420/615d3085-1c58-4718-9d40-ab511c5b1da9">

## Initializing the Monorepo

When you clone the monorepo for the first time, you need to initialize the submodules:

```bash
.claude/scripts/submodule-init.sh --all
```

This initializes every submodule at its pinned commit and keeps per-worktree isolation intact. A bare
`git submodule update --init` writes a `core.worktree` key into each submodule's shared config, which
every later `git worktree add` inherits — so worktrees silently resolve back into the main checkout and
parallel sessions collide. The wrapper repairs that and verifies isolation before returning; run
`.claude/scripts/submodule-init.sh --check` at any time to re-verify (a non-destructive probe: it
never touches submodule content or other sessions' worktrees, but does add and remove its own
throwaway probe worktree).

You can also clone the monorepo with the `--recurse-submodules` flag. That initializes the submodules
the same way, so it breaks isolation the same way — run the wrapper afterwards to repair it (`--check`
is a non-destructive probe and would only report the problem, not fix it):

```bash
git clone --recurse-submodules git@github.com:devantler-tech/monorepo.git
cd monorepo && .claude/scripts/submodule-init.sh --all
```

Make sure that all submodules are checked out on the correct branch the first time you clone the monorepo. Otherwise, you might risk loosing changes as the submodule will be in a detached head state.

> [!NOTE]
> Submodules are configured to clone with SSH, so it requires adding your public SSH key to GitHub. You will not be able to clone the submodules with HTTPS. This decision was made, as HTTPS will require authentication on every request, where as SSH can do this automatically when the public key is shared.

## Adding a submodule

```sh
git submodule add -b <branch> <ssh-url> <path>
```

## Updating a submodule

There are three scenarios for updating a submodule:

1. You want to update the submodule to the latest commit on the branch it is tracking.
2. You want to update a submodule's upstream url.
3. You want to rename/move a submodule.

### Updating to the latest commit on the branch

All submodules are configured to automatically update to the latest commit on the branch they are tracking.

### Updating a submodule's upstream url

To update a submodule's upstream url, you need to run the following command:

```sh
git submodule set-url -- <path> <newurl>
```

### Renaming or moving a submodule

To rename or move a submodule, you need to run the following command:

```sh
git mv old/path/to/submodule new/path/to/submodule
```

## Removing a submodule

```sh
./delete-submodule.sh <path>
```
