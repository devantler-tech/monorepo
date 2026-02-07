---
title: 📁 .NET Template
description: A simple .NET template for new projects with CI/CD, testing, and code quality tooling.
---

A simple .NET template for new projects with CI/CD, testing, and code quality tooling.

**Repository**: [devantler-tech/dotnet-template](https://github.com/devantler-tech/dotnet-template)

## Features

- **CI/CD pipelines with GitHub Actions**
- **Publish libraries to GHCR and NuGet**
- **Test projects and collect coverage with Codecov**
- **EditorConfig with preferred .NET code style**
- **Dependency management with Renovate**

## Getting Started

```bash
# Clone the template
gh repo create my-project --template devantler-tech/dotnet-template --public --clone

# Restore packages
cd my-project && dotnet restore
```
