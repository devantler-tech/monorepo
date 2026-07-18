# 🗂️ Devantler's Monorepo

Every project I actively work on, gathered in one place.

Each project stays its own repository and is linked in here as a *submodule* — a pointer to another
repository, checked out inside this one. So one clone opens everything in VS Code, while each project
keeps its own releases, issues, and access.

<img width="1800" alt="image" src="https://github.com/devantler/monorepo/assets/26203420/615d3085-1c58-4718-9d40-ab511c5b1da9">

## Getting started

```bash
git clone git@github.com:devantler-tech/monorepo.git
cd monorepo
.claude/scripts/submodule-init.sh --all
```

Use that script rather than `git submodule update --init`. The plain Git command lets separate
working copies of a project resolve back to the same folder, so parallel sessions overwrite each
other; the script does the same job and repairs that. It also works after a
`git clone --recurse-submodules`, which has the same problem. Run
`.claude/scripts/submodule-init.sh --check` any time to confirm things are still separated — see
[worktree isolation](.claude/worktree-isolation.md) for the full story.

Check that each project landed on the right branch. One left on a detached commit can lose work.

> [!NOTE]
> Projects clone over SSH, so add your public SSH key to GitHub first — HTTPS won't work. SSH
> authenticates from your key; HTTPS would ask for credentials on every request.

## Working with projects

| Task | Command |
| --- | --- |
| Add one | `git submodule add -b <branch> <ssh-url> <path>` |
| Move or rename one | `git mv <old-path> <new-path>` |
| Point one at a new URL | `git submodule set-url -- <path> <new-url>` |
| Remove one | `./delete-submodule.sh <path>` |

Each project is pinned to a specific commit, and your checkout stays on that pin. Automated pull
requests here move the pins forward, but **your existing checkout does not follow — and re-running
the init script will not move it either.**

That is deliberate: the script only populates projects that are empty, and leaves already-populated
ones alone so it can never discard work you have sitting in one. Moving a populated project to a
newer pin is a manual, per-project decision — commit or push anything you care about there first.
