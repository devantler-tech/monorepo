---
description: |
  Automated CI failure investigator that triggers when monitored workflows fail.
  Performs deep analysis of GitHub Actions workflow failures to identify root causes,
  patterns, and provide actionable remediation steps. Analyzes logs, error messages,
  and workflow configuration to help diagnose and resolve CI issues efficiently.
  Domain-specific context for Astro Starlight, Node.js, and npm-based builds.

on:
  bots:
    - "github-merge-queue[bot]"
    - "github-actions[bot]"

  skip-bots: ["dependabot[bot]", "renovate[bot]"]

  workflow_run:
    workflows: [CI, "Publish - Pages", "Site Maintainer", "Daily Workflow Maintenance"]
    types: [completed]
    branches: [main, "**"]

if: ${{ github.event.workflow_run.conclusion == 'failure' }}

permissions: read-all

network:
  allowed: [defaults, node]

strict: false

safe-outputs:
  noop:
    report-as-issue: false
  create-issue:
    title-prefix: "${{ github.workflow }} - "
    close-older-issues: true
    labels: [automation, ci]
  add-comment:

tools:
  github:
    toolsets: [all]
  cache-memory: true
  web-fetch:
  bash: true

timeout-minutes: 30
source: githubnext/agentics/workflows/ci-doctor.md@1ef9dbe65e8265b57fe2ffa76098457cf3ae2b32
---

## Domain-Specific Context

This repository is a **monorepo** containing an [Astro Starlight](https://starlight.astro.build/) documentation site (`docs/`) along with Git submodules for various projects.

### Common Failure Patterns

**Astro/Starlight build failures:**
- Missing or invalid frontmatter in `.md`/`.mdx` files
- Broken import paths for Astro components or assets
- Invalid MDX syntax (JSX expressions, unclosed tags)
- Starlight plugin configuration errors in `astro.config.mjs`
- Missing dependencies after `package.json` changes

**Node.js/npm failures:**
- `npm ci` failures from lockfile desync (`package-lock.json` vs `package.json`)
- Node.js version incompatibilities
- npm audit failures (dependency vulnerabilities)
- Sharp image processing errors (platform-specific native binaries)

**Submodule failures:**
- Submodule reference pointing to deleted or force-pushed commit
- Authentication failures fetching private submodules
- Submodule path conflicts after renames

**Agentic workflow failures:**
- gh-aw compilation errors after version upgrades
- Missing tools or permissions in workflow frontmatter
- Safe-output not invoked (workflow exits without calling noop, create-issue, etc.)
- Timeout exceeded on complex multi-mode workflows

### Investigation Priorities

When analyzing failures in this repository:

1. Check if the failure is in `docs/` build steps — most CI runs are docs-related
2. Check `npm ci` and `npm run build` output for Astro-specific errors
3. Check for recent `package.json` or `astro.config.mjs` changes that may have introduced the issue
4. For `Publish - Pages` failures, check the deploy step separately from the build step
5. For agentic workflow failures (`Site Maintainer`, `Daily Workflow Maintenance`), check if the agent produced a safe output before the failure
