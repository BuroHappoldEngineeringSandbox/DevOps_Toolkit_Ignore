# DevOps_Toolkit

A centralised GitHub Actions CI toolkit for .NET repositories. Provides a single
reusable orchestrator workflow that runs format checking, compliance analysis, dataset
validation, build, and unit tests — gated by a per-repository maturity level.

Designed to be consumed by multiple repositories across one or more GitHub organisations.

---

## How it works

Each consuming repository calls the CI orchestrator from its own workflow file. The
orchestrator reads the repository's `maturity` custom property and a central `policy.json`
to decide which checks to run, then dispatches those checks as parallel jobs.

```
Your repo  →  .github/workflows/ci.yml
                └── calls ci-orchestrator.yml@main
                      ├── setup        (reads maturity + policy, detects changed files)
                      ├── format       (dotnet format — PR diffs only)
                      ├── compliance   (BHoM compliance rules — PR diffs only)
                      ├── dataset      (dataset JSON validation — PR diffs only)
                      ├── build        (dotnet build)
                      ├── unit-tests   (dotnet test — if .ci/unit-tests/ exists)
                      └── emit-health  (CI health dashboard dispatch)
```

Checks not enabled for a repository's maturity level are skipped entirely — they never
appear as failed or pending required status checks.

---

## Prerequisites

### 1. Repository custom property: `maturity`

The orchestrator fails immediately if this property is absent. It controls which checks
run against your repository.

Set it under **GitHub → Organisation settings → Repository custom properties**, or
per-repository under **Settings → Custom properties**.

| Value | Checks enabled |
|-------|---------------|
| `prototype` | format |
| `alpha` | format · compliance (copyright + project rules) · build · unit-tests |
| `beta` | all of the above + documentation + code rules + dataset validation |

Start with `prototype` for new repositories and promote when ready.

### 2. GitHub App (optional, required for private dependencies)

Without a GitHub App the orchestrator falls back to `GITHUB_TOKEN`, which is scoped
to the current repository. This is sufficient when all dependency repositories are public.

If any repository in your dependency graph is private, configure a GitHub App and store
its credentials as **organisation-level** secrets (or per-repository if preferred):

| Secret name | Description |
|-------------|-------------|
| `BHOM_APP_ID` | Numeric App ID — visible on the App's settings page |
| `BHOM_APP_PRIVATE_KEY` | PEM-format private key — generated under the App settings |

**Required App permissions:**

| Scope | Permission | Required for |
|-------|-----------|--------------|
| Repository: Contents | Read | Cloning private dependency repos |
| Repository: Pull requests | Read | Compliance and format steps read PR metadata |

**App installation:** install the App on every GitHub organisation whose repositories
appear in any `dependencies.txt` file across your fleet.

> If you are adopting this toolkit outside the BHoM organisation, create your own GitHub
> App. The App name is not significant — only the numeric ID and PEM key are consumed.

### 3. DevOps_Toolkit must be readable

The orchestrator checks out a copy of this repository at runtime to read `policy.json`.
If this repository is private, the App (or a PAT stored as `GH_TOKEN`) must have
`Contents: read` access to it. If it is public, no extra configuration is required.

---

## Integrating the orchestrator

### Step 1 — Copy the caller workflow

Copy [`templates/caller-ci.yml`](templates/caller-ci.yml) to your repository at:

```
.github/workflows/ci.yml
```

Edit the single placeholder on the `uses:` line:

```yaml
uses: YOUR_ORG/DevOps_Toolkit/.github/workflows/ci-orchestrator.yml@main
```

Replace `YOUR_ORG` with the GitHub organisation (or user account) that hosts your
DevOps_Toolkit instance.

### Step 2 — Set the maturity property

Set `maturity` to `prototype`, `alpha`, or `beta` on the repository before the first
workflow run. The orchestrator hard-fails if the property is absent.

### Step 3 — Add secrets

Add `BHOM_APP_ID` and `BHOM_APP_PRIVATE_KEY` at organisation level if you have private
dependencies. The workflow treats both as optional — missing credentials cause a graceful
fallback to `GITHUB_TOKEN`, not a failure. Public-dependency repositories need no secrets.

### Step 4 — Open a pull request

The first run executes the `setup` job, reads policy, and runs only the checks appropriate
for your maturity level against the files changed in the PR.

---

## Configuration reference

### Caller workflow inputs

Passed via the `with:` block when calling the orchestrator. Both are optional.

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `dotnet_version` | string | `"8.0"` | .NET SDK version used by build, compliance, dataset, unit-test, and format jobs |
| `configuration` | string | `"Release"` | MSBuild configuration passed to all build steps |

Example:

```yaml
jobs:
  ci:
    uses: YOUR_ORG/DevOps_Toolkit/.github/workflows/ci-orchestrator.yml@main
    with:
      dotnet_version: "9.0"
      configuration: "Release"
    secrets:
      BHOM_APP_ID:          ${{ secrets.BHOM_APP_ID }}
      BHOM_APP_PRIVATE_KEY: ${{ secrets.BHOM_APP_PRIVATE_KEY }}
```

### `dependencies.txt`

List repositories that must be built before your repository. One entry per line.
Blank lines and `#` comments are ignored. Dependencies are resolved transitively.

```
# Syntax: org/repo   or   org/repo@ref
BHoM/BHoM
BHoM/BHoM_Engine
BHoM/BHoM_Adapter@feature/my-branch   # pin to a specific ref
```

### Unit tests

Place a `.sln` file under `.ci/unit-tests/` to enable the unit-test job. The job
discovers the solution automatically; no configuration is required.

### Alt build configurations

List additional MSBuild configurations in `altConfigs.txt` at the repo root, one per
line in `org/repo/ConfigName` format. The `build` job runs these after the primary build.

---

## What is opinionated (not configurable per repository)

- **Which checks run at each maturity level.** Controlled by `policy.json` in
  DevOps_Toolkit. This is a platform governance decision, not a per-team choice.
  To request a change, open a PR against this repository.
- **Runner OS.** Build, compliance, dataset, and unit-test jobs run on `windows-latest`.
  This is required by the BHoM assembly staging convention
  (`C:\ProgramData\BHoM\Assemblies`).
- **Dependency clone root.** Dependencies are cloned to `C:\bhom-deps\` on the runner.
- **Branch resolution order for dependencies.** PR head branch → PR base branch →
  `develop` → remote default. Explicit `@ref` pins in `dependencies.txt` always win.
- **Compliance rules.** The set of available compliance checks and their behaviour are
  defined in the ComplianceRunner tool in this repository.

---

## Fork PR behaviour

The `setup` job reads the `maturity` custom property via the GitHub API. On fork pull
requests, `GITHUB_TOKEN` is scoped to the fork and may not have access to the parent
repository's custom properties. This causes `setup` to fail with:

```
::error::Repository custom property 'maturity' is not set.
```

**Options for repositories that accept fork contributions:**

1. **Configure the GitHub App** (`BHOM_APP_ID` / `BHOM_APP_PRIVATE_KEY`) at organisation
   level. The App token is minted before the properties lookup and has org-wide read
   access, so the lookup succeeds for both fork and non-fork PRs.

2. **Set the `maturity` property on the fork itself.** The API call will resolve the
   fork's own property value. Only practical for known, trusted forks.

3. **Do not use this workflow as a required status check for fork PRs.** Accept that
   external forks will see a failing `setup` job, and gate merges on a maintainer review
   rather than CI.

---

## Required status checks

After CI passes on an initial PR, configure required status checks on your `develop` /
`main` branches under **Settings → Branches → Branch protection rules**:

```
ci / setup
ci / build        (maturity: alpha or beta)
ci / unit-tests   (maturity: alpha or beta)
```

`format` and `compliance` are PR-only checks (they are skipped on push events). Do not
list them as required checks on branch rules — they will show as `skipped`, not
`passing`, on push-triggered runs and would permanently block merges.

---

## Upgrading maturity

1. Update the `maturity` custom property on the repository.
2. Open a PR — the orchestrator will now run the additional checks enabled by the new
   maturity level.
3. Fix any new failures before merging.
4. Update your branch protection rules to require the newly enabled jobs.

There is no automated promotion step. Maturity upgrades are intentionally manual.

---

## Troubleshooting

### `Repository custom property 'maturity' is not set`

The `maturity` property was not set before enabling CI, or the token used to read it
lacks access (see [Fork PR behaviour](#fork-pr-behaviour)).  
**Fix:** Set `maturity` on the repository. For fork PRs, configure the GitHub App.

### `Invalid maturity value '...'`

The property is set to a value not listed in `policy.json`.  
**Fix:** Set it to exactly `prototype`, `alpha`, or `beta`.

### `No .sln file found in repository`

The `build` job expects a `.sln` file at the repo root named `<RepoName>.sln`, or at
minimum one `.sln` anywhere in the repo.  
**Fix:** Ensure a solution file exists. The build job will find the first `.sln`
alphabetically if `<RepoName>.sln` is absent (a notice is emitted).

### `packages.config detected — legacy NuGet/MSBuild is not supported`

The toolkit only supports SDK-style projects.  
**Fix:** Migrate all projects from `packages.config` to `<PackageReference>` before onboarding.

### Dependency clone fails / `assembly not found` at build time

A private repository in `dependencies.txt` could not be cloned because no credentials
with access to it are configured.  
**Fix:** Configure the GitHub App and ensure it is installed on the organisation that
owns the dependency repository. Check the `Resolve dependencies` step log for the
specific error.

### `Clone not found at C:\bhom-deps\<repo>` (hard error)

Dependency resolution recorded a repository in the build order but the clone was never
written to disk — typically an auth failure or network interruption.  
**Fix:** Check the `Resolve dependencies` step log for earlier errors.

### `policy.json is not valid` / `missing required key`

`policy.json` in this repository does not match the expected schema.  
**Fix:** This is a platform-level issue — open a PR against DevOps_Toolkit to correct
`policy.json`. Do not edit policy in consuming repositories.

### Format check fails on files I didn't change

A prior commit introduced a formatting issue that `dotnet format` now surfaces.  
**Fix:** Run `dotnet format` locally, commit the result, and push.
