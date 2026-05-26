---
title: 📁 .NET Template
description: A .NET starter template with CI/CD, testing, publishing, and code quality tooling.
---

A minimal, batteries-included template for new .NET projects and libraries. Skip the boilerplate — start shipping.

**Repository**: [devantler-tech/dotnet-template](https://github.com/devantler-tech/dotnet-template)

## What's Inside

- **CI/CD** — GitHub Actions workflows for build, test, lint, and release
- **Publishing** — Release libraries to [GitHub Container Registry](https://docs.github.com/en/packages) and [NuGet](https://www.nuget.org/) automatically
- **Testing** — Test projects with coverage reporting via [GitHub Code Quality](https://docs.github.com/code-security/code-quality)
- **Code style** — `.editorconfig` with opinionated .NET code style
- **Dependency management** — [Renovate](https://docs.renovatebot.com/) keeps NuGet packages and Actions up to date
- **Release automation** — Semantic versioning and automated GitHub Releases

## Getting Started

```bash
# Create a new repo from the template
gh repo create my-project --template devantler-tech/dotnet-template --public --clone

# Restore packages
cd my-project && dotnet restore

# Run tests
dotnet test
```

## Links

- 📦 [Template on GitHub](https://github.com/devantler-tech/dotnet-template)
- 🔄 [Reusable workflows used by this template](https://github.com/devantler-tech/reusable-workflows)
