# DevOps_Toolkit

Shared **GitHub Actions workflows**, **composite actions**, and **CLI runners** for BHoM repositories. Consumer repos call the reusable workflows (for example `ci-orchestrator.yml`) from their own `.github/workflows/ci.yml` and inherit behaviour driven by **repo topics**, **`policy.json`** (in this repo), and optional **`.github/bhom.json`** in each caller.

## What lives here

| Area | Role |
|------|------|
| [`.github/workflows/`](.github/workflows/) | Reusable workflows: orchestrator, format, compliance, dataset, build, unit tests. |
| [`.github/actions/`](.github/actions/) | Composite actions (e.g. resolve dependencies, stage assemblies, prepare runners). |
| [`.github/scripts/`](.github/scripts/) | Shell helpers (orchestrator policy/bhom, PR format check). |
| [`config/.editorconfig`](config/.editorconfig) | Canonical formatting rules; CI can copy this into caller repos for `dotnet format` (see below). |
| [`policy.json`](policy.json) | Central **policy** (per lifecycle stage: prototype / alpha / beta) for which CI stages run. |
| [`src/`](src/) | `ComplianceRunner` and `DatasetComplianceRunner` (and related projects) used by compliance workflows. |

**Compliance vs dataset:** **Code compliance** (C#, projects) uses `ComplianceRunner` and `ci-compliance.yml`. **Dataset JSON** checks under `.../datasets/...` use `DatasetComplianceRunner` and `ci-dataset.yml` — different inputs, engines, and PR file filters.

## EditorConfig

The canonical file is under **`config/.editorconfig`**. Format CI may apply it to the caller workspace so checks align across repos.

> **Note:** EditorConfig integration is still being aligned with repo layout and props/distribution workflows; treat the copy in `config/` as the intended source of truth once that is settled. (You can expand this section when the process is final.)

## CI orchestrator & shell scripts

The orchestrator (`.github/workflows/ci-orchestrator.yml`) runs a **setup** job that checks out the **caller** repository, resolves **GitHub topics** → `STATE` (beta → alpha → prototype precedence), checks out this repo as `_central`, then runs the scripts under **`.github/scripts/orchestrator/`**.

| Script | Purpose |
|--------|---------|
| `policy-contract.sh` | Declares required **states** and **keys** for `policy.json`. Edit here first when extending the contract. |
| `validate-policy.sh` | Ensures `policy.json` exists and each state object has every required key (`jq` `has()`; safe for boolean `false`). |
| `read-policy.sh` | Reads policy flags for `STATE` and writes `GITHUB_OUTPUT`. Optional `.github/bhom.json` **compliance** override. |
| `read-bhom-config.sh` | Dotnet / configuration / test solution path from `bhom.json`, with a **default** test `.sln` if unset. |

### Caller `.github/bhom.json` (optional)

| Key | Purpose |
|-----|---------|
| `dotnet_version` | SDK hint (default `8.0`). |
| `configuration` | Build configuration (default `Release`). |
| `unit_tests.solution` | Relative path to the test solution. If omitted, **`.ci/tests/unitTests/UnitTests.sln`** is used. |
| `compliance.checks` | Optional override of compliance check list (see `read-policy.sh`). |

### Changing policy or orchestrator behaviour

1. Update **`policy.json`** at the root of this repository.
2. Update **`policy-contract.sh`** (and thus `validate-policy.sh` via sourcing).
3. Update **`read-policy.sh`** if you add or remove fields passed to downstream workflows.
4. Update **`ci-orchestrator.yml`** job `if:` / `with:` as needed.

**Topic → `STATE`:** Defined in the orchestrator **Read GitHub Topic** step (order: beta, then alpha, then prototype).

### Environment overrides (advanced / local testing)

| Variable | Meaning |
|----------|---------|
| `POLICY_PATH` | Default `_central/policy.json`. |
| `BHOM_PATH` | Alternate path instead of `.github/bhom.json`. |
| `STATE` | Required by `read-policy.sh` (normally supplied by the workflow). |

## Versioning

Consumer workflows typically reference **`@main`** or a **tag** / **SHA** on this repository. Pinning reduces surprise upgrades when reusable workflows change.
