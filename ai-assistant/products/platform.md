# Product card: Platform

**Repo:** `devantler-tech/platform` — a **GitOps-based Kubernetes platform** (not a code repo): all
"code" is Kubernetes YAML managed with Kustomize overlays and deployed via Flux CD. Stack: Cilium,
Talos Linux, KSail, SOPS+Age.
**Subdir:** `platform` (a submodule; checked out in-place on the primary checkout).
**Issues:** enabled → durable memory = a Monthly Activity issue (below).

**Before working here:** read `AGENTS.md` (esp. "What's Useful for the AI Assistant" / "What's Less
Applicable") and skim `.github/instructions/` (kustomize-manifests, talos-patches, sops-secrets)
before editing any manifests.

## Conventions specific to this repo
- **Branch:** `claude/repo-assist-<short-desc>` off `main`. **Labels:** `automation,repo-assist`
  (stable dedup/attribution keys). **PR title = Conventional Commit** (repo runs semantic-release
  off PR titles). Issue titles MAY use a prefix.
- **Validate before any manifest PR** — both overlays MUST build:
  `kubectl kustomize k8s/clusters/local/` and `kubectl kustomize k8s/clusters/prod/` (standalone
  `kustomize` isn't installed; `kubectl` has it built in). Per-file sanity:
  `kubectl apply --dry-run=client -f <file>`. If a change breaks an overlay build, do **not** open
  the PR. The full Talos+Docker cluster system test runs in CI on the PR (needs Docker+KSail, 3–5 min)
  — don't run it locally.
- **Never run a cluster.** Static validation only — no `ksail up`/create/switch/delete, no mutating
  `~/.kube/config`.
- **Protected files — never modify:** `*.enc.yaml` (SOPS secrets), `ksail.prod.yaml` (live prod
  config), `.sops.yaml` (encryption rules). Never commit plaintext secrets. **Base files are
  immutable** — change behaviour via Kustomize `patches:` in overlays, never edit `k8s/bases/`
  directly from a provider/cluster overlay. Respect Flux dependency order
  (`variables` → `infrastructure-controllers` → `infrastructure` → `apps`).
- **AI-disclosure line** on every artifact.

## Task menu — each run pick the 2–3 highest-value (favour the "platform-useful" tasks in AGENTS.md)
1. **Triage & label** unlabelled issues/PRs (`bug`, `enhancement`, `documentation`, `question`,
   `needs triage`, `security`, `help wanted`, `good first issue`, …); remove misapplied labels;
   close obvious spam/off-topic.
2. **Investigate & comment** on open issues lacking a Daily-AI-Assistant comment (oldest first;
   1–3/run) — manifest misconfigs, Helm chart issues, Flux sync/dependency-order problems. Answer
   by type (bug → root cause/workaround; feature → feasibility; question → concise answer with
   manifest refs; onboarding → point to README/AGENTS.md). Never post vague acknowledgements.
3. **Fix confident, low-risk issues** → branch `claude/repo-assist-fix-issue-<N>-<desc>`, minimal
   surgical fix, overlays build, draft PR with `Closes #N`, root cause, rationale, trade-offs, and
   the build-check result; one brief comment on the issue linking the PR.
4. **Engineering investments:** Helm chart version bumps via HelmRelease `spec.chart.spec.version`
   (prefer minor/patch; majors only with clear benefit); GitHub Actions / workflow health
   (upgrade/pin actions, caching, fix flaky steps, remove dead workflows); bundle compatible open
   Renovate/Dependabot PRs into one referencing the originals. Branch `claude/repo-assist-eng-<desc>`,
   one concern per PR, draft PR with build-check result.
5. **Manifest improvements:** Kustomize structure cleanup, dead-resource removal, documentation gaps,
   reducing duplication — only obviously-beneficial, low-risk changes. Be highly selective.
6. **Maintain your own open PRs** (`repo-assist`): fix CI you caused (push updates), resolve
   conflicts. Don't push for infra-only failures — comment instead. Stuck after a couple of retries
   → comment and leave for humans.
7. **Stale-PR nudges:** ≤3 polite nudges to other contributors' PRs untouched 14+ days waiting on
   the author (not when waiting on a maintainer; skip if already nudged).

> **Skip** performance, test-suite, and code-refactoring tasks — per AGENTS.md they're "Less
> Applicable" to a declarative manifest repo (no app code, no test suite; CI is a full cluster
> system test).

## Monthly Activity issue
Maintain ONE open issue `[AI Assistant] Monthly Activity {YYYY}-{MM}` (label `automation,repo-assist`).
Format (rewrite the body to this if it differs): AI-disclosure line; `## Activity for <Month Year>`;
**`## Suggested Actions for Maintainer`** first — a complete, deduplicated checklist of *pending*
items only, one `* [ ]` line each with a direct link (remove a line when actioned — don't tick it);
then `## Future Work for Platform AI Assistant` (brief, optional); then **`## Run History`**
reverse-chronological (`### YYYY-MM-DD HH:MM` + emoji bullets: 💬 commented / 🔧 PR / 🏷️ labelled /
📝 issue, with links). If the open issue is for a previous month, close it and open a fresh one.
Don't update if nothing was done this run.
