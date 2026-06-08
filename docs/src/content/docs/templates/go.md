---
title: 🐹 Go Template
description: A Go starter template with CI/CD, testing, and code quality tooling.
---

A minimal, batteries-included template for new Go projects. Skip the boilerplate — start shipping.

**Repository**: [devantler-tech/go-template](https://github.com/devantler-tech/go-template)

## What's Inside

- **CI/CD** — GitHub Actions workflows for build, test, lint, and release
- **Testing** — `go test` with coverage reporting via [GitHub Code Quality](https://docs.github.com/code-security/code-quality)
- **Quality** — [Go Report Card](https://goreportcard.com/) integration for continuous code-quality feedback
- **Dependency management** — [Dependabot](https://docs.github.com/code-security/dependabot) keeps Go modules and Actions up to date
- **Release automation** — Semantic versioning and automated GitHub Releases

## Getting Started

```bash
# Create a new repo from the template
gh repo create my-project --template devantler-tech/go-template --public --clone

# Install dependencies
cd my-project && go mod tidy

# Run tests
go test ./...
```

## Links

- 📦 [Template on GitHub](https://github.com/devantler-tech/go-template)
- 🔄 [Reusable workflows used by this template](https://github.com/devantler-tech/reusable-workflows)
