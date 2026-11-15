# ADR 0018: One application template, with stacks and optional tenancy

Status: Proposed. It becomes accepted when the maintainer approves the template pull request.

Date: 2026-11-14

## Context

The portfolio had three starter templates:

| Template | Gave | Synced into |
|---|---|---|
| `go-template` | A Go module, golangci-lint, GoReleaser binaries, the shared Go validator | KHoist, Bookkeeper |
| `dotnet-template` | A .NET library with tests, NuGet publishing | nothing |
| `platform-tenant-template` | `deploy/` manifests, a signed image and manifests release, delivery CI gates | the wedding app, AS Coaching |

Template-sync follows one source per repository, and all three own the same paths:
`ci.yaml`, `cd.yaml`, `release.yaml`, `template-sync.yaml`, `.releaserc`, `CLAUDE.md` and
`AGENTS.md`. So an application that is both a Go program and a platform tenant can only follow
one of them. KHoist shows the cost: it syncs from `go-template` but lists 44 paths in its
`.templatesyncignore`, including its CI, CD and release workflows, so it receives almost nothing,
and it carries its tenant publishing by hand. The two tenants, in turn, got no stack at all.

On 2026-11-14 the maintainer asked for the templates to be merged, with tenancy included or a
scaffolder for Go and .NET projects, and then for the result to be called `application-template`,
with tenancy something you scaffold, since not every application needs it.

## Decision

1. **One template.** `platform-tenant-template` becomes `application-template`. Its root keeps
   the language-neutral plumbing every application shares: Conventional-Commit releases,
   template-sync, Dependabot, the agent instructions and the CI aggregate.
2. **Stacks are scaffolded once.** `stacks/go` and `stacks/dotnet` hold a small HTTP service each:
   the source and tests, lint and analyzer configuration, a Dockerfile and the stack's CI job. Both
   serve `GET /` on port 3000. `scripts/scaffold.sh <go|dotnet|none> [--tenancy] [name]` copies one
   stack over the template and renames it. After that the stack files belong to the application
   and are never synced. `none` keeps a placeholder for a stack the application brings, such as
   the two SvelteKit tenants.
3. **Tenancy is a scaffold option.** With `--tenancy`, the application keeps `deploy/`, the signed
   publish in `cd.yaml` and the CI jobs that build the image and render `deploy/` before merge.
   Without it the scaffold removes them, and adds the tenant files to `.templatesyncignore` so
   template-sync never brings them back. The template's root stays shaped as a tenant, so the
   existing tenants keep syncing the same paths, and its platform admissibility checks keep
   running against the same `deploy/`.
4. **The scaffold edits by markers.** `ci.yaml`, `dependabot.yml` and `AGENTS.md` mark their
   stack, tenancy and template-only parts. The CI aggregate consumes `needs.*.result` rather than
   naming each job, so removing a job and its `needs` entry leaves nothing else to edit. The tenant
   CI contract now pins that `needs` lists every other job exactly once.
5. **Guards use the repository ID.** The template's "skip in the template itself" guards match its
   immutable repository ID instead of its name, so they hold before, during and after the rename.
6. **`go-template` and `dotnet-template` retire.** KHoist and Bookkeeper move their template-sync
   source to the application template, then both repositories are archived through their
   Crossplane manifests in `devantler-tech/.github`.
7. **Not carried over:** GoReleaser binary releases, NuGet package publishing, the three-OS .NET
   test matrix, MegaLinter and pre-commit, and the Copilot setup workflow, which the no-Copilot
   direction of 2026-11-13 rules out. No current consumer needs them from a template. A product
   that does adds it as its own file.

## Options compared

- **Add tenancy to `go-template` and `dotnet-template`, retire the tenant template.** Two copies
  of the tenancy plumbing and its platform checks would drift apart, and the two SvelteKit tenants
  would have no template.
- **Keep three templates, and let an application follow two.** Template-sync takes one source,
  and the templates collide on the same workflow paths, which is the problem itself.
- **One template whose stack files stay synced.** Stack workflows would sit at stack-specific paths
  so updates reach applications, but each application would then ignore the other stacks' files,
  and the stack's own code still cannot sync. The stack's only shared, update-worthy part is its
  pin on the shared Go validator or .NET test action, which Dependabot already keeps current.

## Consequences

- An application starts in one command with its stack, and a tenant passes its probes before any
  code is written. The template's own CI scaffolds every combination, checks what each leaves, and
  builds, tests, lints and runs each stack's image.
- The rename runs in `devantler-tech/.github` in the same staged order as KHoist's rename:
  stop the settings sync from creating, rename in place, move labels, grants and permissions, then
  restore creation. GitHub redirects the old name, so existing callers keep working until their
  references move. The new `Validate Stacks` check joins the template's required checks then.
- KHoist and Bookkeeper each migrate in their own pull request: switch the sync source, then
  replace their ignore list with the template's ownership model.
- The portfolio map keeps `go-template` and `dotnet-template` until they are archived; the stack
  map already points new template work at the application template.

## Amendments

- **2026-11-15: every application syncs from the template, which carries the cross-cutting
  concerns.** The maintainer asked that every application use the template with template sync,
  so that cross-cutting concerns live in one place while each application can still diverge,
  and that the template grow to cover applications' needs generically: new stacks such as
  SvelteKit, generic workflows, and correct CodeQL, Dependabot, Renovate, CodeRabbit and
  MegaLinter configuration.

  1. **Scope.** Every application and infrastructure-configuration repository, from a review of the
     live organization rather than the monorepo's folders (#5063 corrects those): the applications
     KSail, KHoist, the business site, World at Ruin, the wedding app, AS Coaching and Bookkeeper,
     and the infrastructure configuration aws, unifi, Cloudflare and fleet-gitops. Infrastructure
     repositories scaffold with no stack. KSail and World at Ruin start with large ignore lists and
     shed them over time. Libraries, actions, the platform, the templates and the organization's
     shared repositories are not applications and keep their own configuration.
  2. **A shared file, and the application's own overlay.** The template owns one copy of each
     concern, and template-sync keeps it current. Where the tool can layer configuration, the
     application owns an overlay that sync never touches. Where it cannot, the application lists
     the shared file in `.templatesyncignore` and owns its copy. Logic that serves repositories
     beyond the template's applications stays in `devantler-tech/.github`, pinned like any
     dependency.

     | Concern | Shared | The application's own |
     |---|---|---|
     | Linting | `lint.yaml` and `.github/mega-linter.base.yml` (MegaLinter cupcake, read-only) | `.mega-linter.yml`, which extends the base |
     | Markdown and YAML style | `.markdownlint.json`, `.yamllint.yml` | ignored copies |
     | Code scanning | `codeql.yaml`, advanced, with languages detected from the files | `.github/codeql/codeql-config.yml` |
     | Code review | `.coderabbit.yaml`, layered over the organization's settings | an ignored copy |
     | Dependencies | `renovate.json` for `deploy/` image tags and Helm charts (tenants) | `.github/dependabot.yml`, composed per stack by the scaffold |

  3. **SvelteKit is a stack.** `stacks/svelte` is a SvelteKit 3 and Svelte 5 app on Node 26 with
     `adapter-node`, OpenFeature, Vitest, svelte-check and ESLint, serving `GET /` on port 3000
     like the other stacks.
  4. **Renovate fills Dependabot's gaps only.** Dependabot keeps packages, GitHub Actions and the
     Dockerfile current. Renovate, extending the organization preset, updates only the image tags
     and Helm charts in `deploy/`, so no update arrives twice. A repository must be enrolled in
     Renovate before the file does anything.
  5. **CodeQL moves to advanced setup per repository.** GitHub refuses advanced results while
     default setup is on, so the shared workflow stays off until a repository's default setup is
     turned off, which is a repository security setting the maintainer changes, and its
     `CODEQL_SETUP` variable is set to `advanced`. Alerts are fixed in ordinary reviewed pull
     requests, never with Copilot Autofix (maintainer direction, 2026-11-15).
  6. **Go applications keep linting through the shared Go validator**, which already runs
     MegaLinter with signed fixes; every other stack calls the template's `lint.yaml`. Extracting a
     stack-neutral lint workflow with signed fixes into `devantler-tech/.github` is a follow-up.
  7. **Onboarding order.** The two tenants that already sync from the template adopt the new
     files first, then the two `go-template` consumers switch their source, then the rest add a
     sync caller. Each runs in its own pull request in its own repository:

     | Application | Stack | Tenancy | Syncs from today |
     |---|---|---|---|
     | Wedding app, AS Coaching | SvelteKit | yes | this template |
     | KHoist, Bookkeeper | Go | own Helm chart and release | `go-template` |
     | Business site | Go and Node | yes | nothing |
     | World at Ruin | Godot and Go | own server release | nothing |
     | KSail | Go CLI | no | nothing |
     | aws | none | configuration tenant | nothing |
     | unifi, Cloudflare, fleet-gitops | none | no | nothing |
