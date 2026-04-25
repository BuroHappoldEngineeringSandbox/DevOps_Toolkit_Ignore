# DevOps_Toolkit

Centralised CI and governance toolkit for .NET repositories. Provides a reusable
orchestrator workflow that runs format, compliance, dataset, build, and unit-test checks,
gated by a per-repository maturity level (`prototype` | `alpha` | `beta`).

---

## Two usage paths

### Path A — Org-wide ruleset (hosting org)

The orchestrator is enforced automatically across all covered repositories via a GitHub
**Required workflows** ruleset. No per-repository workflow file is needed.

Each repository only needs:

1. The `maturity` custom property set (see [Maturity levels](#maturity-levels)).
2. App secrets configured at org level if any dependencies are private (see [Secrets](#secrets)).

### Path B — Per-repository caller workflow (other orgs, or repos outside ruleset coverage)

Use this path when integrating DevOps_Toolkit into an org that does not enforce it via
a ruleset, or for individual repositories that are explicitly opted in.

1. Set the `maturity` custom property (see [Maturity levels](#maturity-levels)).
2. Copy [`templates/caller-ci.yml`](templates/caller-ci.yml) to `.github/workflows/ci.yml`
   and replace the `YOUR_ORG` placeholder:
   ```yaml
   uses: YOUR_ORG/DevOps_Toolkit/.github/workflows/ci-orchestrator.yml@main
   ```
   If the toolkit is hosted in a different org, use that org's name.
3. Add App secrets at org level if any dependencies are private (see [Secrets](#secrets)).
4. Open a pull request — the orchestrator runs `setup`, reads policy, and runs only the
   checks appropriate for the repository's maturity level.

---

## Maturity levels

Set under **GitHub → Org settings → Custom properties**, or per-repository under
**Settings → Custom properties**.

| Value | Checks enabled |
|---|---|
| `prototype` | format |
| `alpha` | format · compliance · build · unit-tests |
| `beta` | all of the above + documentation, code rules, dataset validation |

The orchestrator hard-fails immediately if `maturity` is not set.

---

## Secrets

Required only when repositories in the dependency graph are private.

| Secret | Description |
|---|---|
| `BHOM_APP_ID` | GitHub App numeric ID |
| `BHOM_APP_PRIVATE_KEY` | GitHub App PEM private key |

Add these at org level. Without them the orchestrator falls back to `GITHUB_TOKEN`,
which is sufficient for fully-public dependency graphs.

The App must be installed in every org whose private repositories appear in any
`dependencies.txt` file across your fleet.

---

## Configuration

### Caller workflow inputs (optional)

| Input | Default | Description |
|---|---|---|
| `dotnet_version` | `"8.0"` | .NET SDK version for all jobs |
| `configuration` | `"Release"` | MSBuild configuration |

### `dependencies.txt`

List upstream repositories to build before your own, one per line:

```
# org/repo  or  org/repo@ref
BHoM/BHoM
BHoM/BHoM_Engine
BHoM/BHoM_Adapter@feature/my-branch
```

### Unit tests

Place a `.sln` file under `.ci/unit-tests/` to enable the unit-test job. No further
configuration needed.

---

## What is not configurable per repository

The following are platform decisions owned by DevOps_Toolkit, not individual teams:

- **Which checks run at each maturity level** — defined in `policy.json`
- **Runner OS** — `windows-latest` (required by the BHoM assembly staging convention)
- **Dependency clone root** — `C:\bhom-deps\`
- **Compliance rules** — defined in the ComplianceRunner tool in this repository

To change any of these, open a PR against DevOps_Toolkit.

---

## Required status checks

Configure these on `develop` / `main` under **Settings → Branches**:

```
ci / setup
ci / build        (alpha or beta only)
ci / unit-tests   (alpha or beta only)
```

Do not add `format` or `compliance` as required checks — they are PR-only and show as
`skipped` on push events, which would permanently block merges.

---

## Fork PRs

`GITHUB_TOKEN` on a fork PR cannot read custom properties from the upstream repository.
`setup` will fail with a clear error indicating the cause. Options:

- **Configure the GitHub App** at org level — the App token can read upstream properties.
- **Set `maturity` on the fork itself** — only practical for known, trusted forks.

---

## Upgrading maturity

1. Update the `maturity` property on the repository.
2. Open a PR — new checks enabled by the higher tier will now run.
3. Fix any failures, then update branch protection rules to require the new jobs.

---

## Troubleshooting

| Error | Fix |
|---|---|
| `maturity is not set` | Set the custom property. For fork PRs, configure the GitHub App. |
| `Invalid maturity value` | Use exactly `prototype`, `alpha`, or `beta`. |
| `No .sln file found` | Ensure a `.sln` exists at the repo root or anywhere in the repo. |
| `packages.config detected` | Migrate to `<PackageReference>` — legacy NuGet is not supported. |
| Dependency clone fails | Configure the GitHub App and install it in the dependency's org. |
| `policy.json is not valid` | Open a PR against DevOps_Toolkit — do not edit policy in consuming repos. |
| Format fails on unchanged files | Run `dotnet format` locally, commit, and push. |
