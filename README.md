# Devantler's Monorepo

This repository is a monorepo that contains all my active projects as submodules. This allows me to keep all my projects in one place and easily manage them in VSCode.

<img width="1800" alt="image" src="https://github.com/devantler/monorepo/assets/26203420/74b92fbe-0449-4712-b918-115332133471">


<details>
  <summary>Show/Hide folder structure</summary>

<!-- readme-tree start -->
```
.
├── .github
│   └── workflows
├── .vscode
├── github
│   ├── config
│   └── profile
├── libraries
│   ├── dotnet-age-cli
│   ├── dotnet-flux-cli
│   ├── dotnet-k3d-cli
│   ├── dotnet-k9s-cli
│   ├── dotnet-kind-cli
│   ├── dotnet-kubeconform-cli
│   ├── dotnet-kubernetes-generator
│   ├── dotnet-kustomize-cli
│   ├── dotnet-sops-cli
│   └── dotnet-template-engine
├── projects
│   ├── data-product
│   ├── dotnet-commons
│   ├── homelab
│   ├── ksail
│   ├── oci-artifacts
│   └── pandoc-plus
└── templates
    └── dotnet-template

26 directories
```
<!-- readme-tree end -->

</details>

### Initializing the Monorepo

When you clone the monorepo for the first time, you need to initialize the submodules:

```bash
git submodule update --init --recursive
```

Alternatively, you can clone the monorepo with the `--recurse-submodules` flag:

```bash
git clone --recurse-submodules git@github.com:energinet-digitalisering/[department-name].git
```

Make sure that all submodules are checked out on the correct branch the first time you clone the monorepo. Otherwise, you might risk loosing changes as the submodule will be in a detached head state.

> [!NOTE]
> Submodules are configured to clone with SSH, so it requires adding your public SSH key to DevOps and GitHub, respectively. You will not be able to clone the submodules with HTTPS. This decision was made, as HTTPS will require authentication on every request, where as SSH can do this automatically when the public key is shared.

### Adding a submodule

```sh
git submodule add -b <branch> <ssh-url> <path>
```

### Updating a submodule

All submodules are configured to automatically update to the latest commit on the branch they are tracking.

### Removing a submodule

```sh
# Remove the submodule entry from .git/config
git submodule deinit -f <path>

# Remove the submodule directory from the superproject's .git/modules directory
rm -rf .git/modules/<path>

# Remove the entry in .gitmodules and remove the submodule directory located at path/to/submodule
git rm -f <path>
```
