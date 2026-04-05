---
description: |
  This workflow maintains GitHub Actions workflows by upgrading gh-aw, updating dependencies,
  and optimizing CI/CD structure. Runs in two modes: first checks for action version updates
  and gh-aw source upgrades (codemods, changelog review) and creates a PR if changes found;
  if no updates available, proceeds to structural optimization of both non-agentic and agentic
  workflows. Replaces the former Maintainer workflow.

on:
  bots:
    - "github-merge-queue[bot]"

  skip-bots: ["dependabot[bot]", "renovate[bot]"]
  schedule: daily
  workflow_dispatch:
  repository_dispatch:
    types: [maintainer]

timeout-minutes: 30

permissions: read-all

tracker-id: daily-workflow-maintenance
engine: copilot

network:
  allowed: [defaults, github, node]

strict: false

safe-outputs:
  github-app:
    app-id: ${{ vars.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
  noop:
  create-discussion:
    title-prefix: "${{ github.workflow }} - "
    category: "agentic-workflows"
    max: 5
    close-older-discussions: true
  add-comment:
    target: "*"
  create-pull-request:
    expires: 1d
    labels: [dependencies, automation]
    draft: false
    protected-files: allowed
    allowed-files:
      - ".github/aw/actions-lock.json"
      - ".github/workflows/*.lock.yml"
      - ".github/workflows/*.md"
      - ".github/workflows/shared/*.md"
      - ".github/workflows/*.yaml"
      - ".github/workflows/*.yml"
      - ".github/agents/*.agent.md"
  create-issue:

steps:
  - name: Checkout repository
    uses: actions/checkout@v6.0.2
    with:
      persist-credentials: false

  - name: Install gh-aw extension
    run: gh extension install github/gh-aw
    env:
      GH_TOKEN: ${{ github.token }}
      GH_HOST: github.com

  - name: Verify gh-aw installation
    run: gh aw version
    env:
      GH_TOKEN: ${{ github.token }}

  - name: Update pinned action versions
    run: gh aw update --verbose 2>&1 | tee /tmp/gh-aw-update-output.txt || true

  - name: Apply gh-aw codemods
    run: gh aw fix --write 2>&1 | tee /tmp/gh-aw-fix-output.txt || true

tools:
  github:
    toolsets: [all]
    min-integrity: none
  web-fetch:
  bash:
    - "*"
---

# Daily Workflow Maintenance

Your name is "${{ github.workflow }}". You are an AI automation agent that maintains GitHub Actions workflows in `${{ github.repository }}`. You operate in two modes:

1. **Quick mode (dependency updates)**: Check for action version updates and gh-aw source upgrades. If changes found, create a PR and exit.
2. **Deep mode (optimization and enhancement)**: If no dependency updates available, analyze and improve CI/CD workflows and agentic workflow prompts for efficiency, clarity, and simplicity.

Always start with Quick mode. Only proceed to Deep mode if Quick mode produces no changes.

---

## Quick Mode: Dependency Updates

Both tasks have already had their CLI commands run as pre-steps. Your job is to review the results, compile workflows, regenerate `.lock.yml` files, and create a single PR if any changes were detected.

### Phase 1: Review Action Version Updates

#### 1.1. Review update output

Read the output from the `gh aw update` command:

```bash
cat /tmp/gh-aw-update-output.txt
```

#### 1.2. Check for action version changes

```bash
git status
```

Look for changes to `.github/aw/actions-lock.json`. Note whether this file was modified.

#### 1.3. Review the changes

If `.github/aw/actions-lock.json` was modified, review the diff:

```bash
git diff .github/aw/actions-lock.json
```

Note which actions were updated and to which versions.

### Phase 2: Review gh-aw Workflow Upgrades

#### 2.1. Review codemod output

Read the output from the `gh aw fix --write` command:

```bash
cat /tmp/gh-aw-fix-output.txt
```

#### 2.2. Fetch the latest gh-aw changelog

Use the GitHub tools to fetch the CHANGELOG.md or release notes from the `github/gh-aw` repository.

#### 2.3. Compile all workflows

First validate all workflow `.md` files:

```bash
VALIDATION_FAILED=0
for file in .github/workflows/*.md; do
  echo "Compiling $file..."
  gh aw compile --validate "$file" 2>&1 || VALIDATION_FAILED=1
done
echo "Validation result: $VALIDATION_FAILED (0=passed, 1=failed)"
```

If validation passes (`VALIDATION_FAILED=0`), recompile in write mode to update `.lock.yml` files:

```bash
for file in .github/workflows/*.md; do
  echo "Compiling $file..."
  gh aw compile "$file" 2>&1
done
```

**Do not run write-mode compilation if validation failed** — fix errors first (see Section 2.4).

#### 2.3.1. Inject `permission-workflows: write` into daily-workflow-maintenance.lock.yml

The gh-aw compiler does not automatically add `permission-workflows: write` to the GitHub App token permissions, but this permission is required to push `.github/workflows/*.lock.yml` files. After every compilation, inject it:

```bash
sed -i '/permission-pull-requests: write/a\          permission-workflows: write' .github/workflows/daily-workflow-maintenance.lock.yml
```

Verify the injection:

```bash
grep "permission-workflows" .github/workflows/daily-workflow-maintenance.lock.yml
```

#### 2.4. Fix compilation errors

If there are compilation errors:

- Analyze them against the gh-aw changelog
- Make targeted fixes to workflow `.md` source files
- Re-run `gh aw compile --validate` to verify fixes
- Iterate until all workflows compile or exhausted reasonable attempts

If you **cannot fix** compilation errors, skip to "Fallback: Create Issue" below.

### Phase 3: Review Changes and Create Output

#### 3.1. Check remaining changes

```bash
git status
```

Changes should include `.github/aw/actions-lock.json`, any updated `.lock.yml` files, `.md` workflow source files, and other files (e.g., `.github/agents/*.md`).

#### 3.2. Decide what to do

- **If changes exist**: Create a pull request (see below) and exit the workflow
- **If no changes remain**: Call the `noop` safe output, then proceed to **Deep Mode** below

#### 3.3. Create pull request

Use the `create-pull-request` safe-output with title `Update workflows - [date]` and include details of action version updates and gh-aw changes.

After creating the PR, **exit the workflow** — do not proceed to Deep mode.

### Fallback: Create Issue

If compilation errors cannot be fixed, create an issue with title `Failed to upgrade workflows to latest gh-aw version` including errors, attempted fixes, and changelog references.

---

## Deep Mode: Optimization and Enhancement

Only reach this point if Quick mode produced no changes (noop). This mode follows a 3-phase approach to systematically optimize CI/CD workflows and enhance agentic workflow prompts.

### Phase Selection (Deep Mode)

To decide which deep-mode phase to perform:

1. Check for existing open discussion titled "${{ github.workflow }} - Research and Plan" using `list_discussions`. If not found, perform Deep Phase 1.

2. If discussion exists, perform Deep Phase 3 directly (this repo has no build steps to configure).

### Deep Phase 1 - CI/CD Workflow Research

1. Research the CI/CD workflow landscape. This includes both **non-agentic workflows** (`.yaml`/`.yml`) and **agentic workflows** (`.md`). Skip generated `*.lock.yml` files.

   **For non-agentic workflows:**
   - Analyze job structure, dependencies, and parallelization opportunities
   - Review caching strategies (npm cache, node_modules)
   - Identify redundant or duplicate steps across jobs
   - Check for missing path filters
   - Evaluate runner selection, timeout settings, concurrency settings
   - Check action versions for outdated or unpinned references

   **CI performance analysis:**
   - Use GitHub API to fetch the last 50-100 runs for each CI workflow
   - Collect metrics: average runtime per workflow, success/failure rates, job-level timing
   - Identify job parallelization opportunities
   - Evaluate cache optimization (npm dependencies, Astro build cache)
   - Review conditional execution and path filters
   - Prioritize by: **Impact** (time/cost savings), **Risk** (chance of breaking), **Effort** (complexity)
   - Focus on **high impact + low risk + low-to-medium effort** optimizations

   **For agentic workflows — frontmatter configuration:**
   - Review triggers, permissions, network, tools, safe-outputs, and timeout settings
   - Check for overly broad permissions or network allowlists
   - Identify redundant tool declarations
   - Review safe-output limits and expiration settings
   - Look for shared configuration opportunities via `imports:` or `shared/*.md`

   **For agentic workflows — prompt quality and logic:**
   - Review the markdown body (agent instructions) for clarity, conciseness, and effectiveness
   - Identify overly complex or convoluted logic flows that could be simplified
   - Look for redundant, outdated, or contradictory instructions
   - Evaluate phase structures — are they logical, well-ordered, and easy for the agent to follow?
   - Assess whether each workflow's prompt clearly defines success criteria and exit conditions
   - Look for missing error handling, edge cases, or fallback instructions
   - Compare prompt patterns across workflows for consistency
   - **Self-assessment**: Evaluate this workflow's own prompt with the same critical eye

   **Cross-cutting concerns:**
   - Review workflow run history for slow jobs and frequent failures
   - Identify cross-workflow inconsistencies in naming, structure, or conventions

2. Create a discussion with title "Research and Plan"

   **Include "How to Control this Workflow" and "What Happens Next" sections** with commands:

   ```bash
   gh aw disable daily-workflow-maintenance --repo ${{ github.repository }}
   gh aw enable daily-workflow-maintenance --repo ${{ github.repository }}
   gh aw run daily-workflow-maintenance --repo ${{ github.repository }} --repeat <number-of-repeats>
   gh aw logs daily-workflow-maintenance --repo ${{ github.repository }}
   ```

3. Exit this entire workflow.

### Deep Phase 3 - Optimization and Enhancement

1. **Goal selection**. Select an optimization target from the plan.

   a. Read the plan in the discussion, along with comments.
   b. Check for existing optimization PRs (especially yours with "${{ github.workflow }}" prefix). Avoid duplicate work.
   c. If plan needs updating, comment on discussion with revised plan.
   d. Select a goal from the plan. Alternate between structural CI/CD optimizations and prompt enhancement/simplification work. Prefer small, incremental changes.

2. **Work towards your selected goal**.

   a. Create a new branch starting with "ci/".

   b. Implement the improvement. Consider:

   **Non-agentic workflow optimizations:**
   - Path filtering, caching, parallelization, deduplication
   - Conditional execution, runner optimization, timeout tuning
   - Concurrency groups, action updates, matrix optimization

   **Agentic workflow — frontmatter optimizations:**
   - Permission scoping, network allowlist reduction, tool selection
   - Timeout tuning, safe-output limit tuning, shared components

   **Agentic workflow — prompt enhancements and simplifications:**
   - Simplify convoluted logic flows, remove unnecessary indirection
   - Condense verbose instructions without losing essential detail
   - Remove redundant, outdated, or contradictory sections
   - Add missing error handling, edge cases, or fallback instructions
   - Improve clarity of decision points and exit conditions
   - Standardize prompt patterns across workflows
   - **Self-improvement**: Apply the same enhancements to `daily-workflow-maintenance.md` itself

   **Rules:**
   - Make small, incremental changes
   - Ensure workflow syntax remains valid
   - Validate agentic `.md` files with `gh aw compile --validate`
   - For prompt-only changes to `.md` files, no recompilation is needed — only frontmatter changes require recompilation
   - Do not change functional behavior of pipelines
   - Preserve the intent and goals of each workflow

   c. Validate workflows still function as expected.

3. **Finalizing changes**

   a. Run `gh aw compile --validate` on modified `.md` files.
   b. Review all changed files for unintended modifications.

4. **Results and learnings**

   a. Create a draft pull request with your changes.

   In the description, explain:
   - **Goal and rationale:** What inefficiency or quality issue was addressed
   - **Approach:** Optimization or enhancement strategy and implementation steps
   - **Impact:** What improved
   - **Validation:** Workflow syntax is valid, no functional changes, intent preserved
   - **Future work:** Additional optimization or enhancement opportunities identified

   b. If failed or lessons learned, add a comment to the planning discussion with your insights.

5. **Final update**: Add brief comment to the discussion stating goal worked on, PR links, and progress made.

## Important Guidelines

- **Include both `.lock.yml` and `.md` source files in PRs** — both compiled `.lock.yml` files and `.md` workflow source files should be committed when they change.
- The gh-aw CLI extension has already been installed and is available
- Always check the gh-aw changelog before making manual fixes
- **You MUST always produce a safe output** — either `noop`, `create_pull_request`, or `create_issue`
