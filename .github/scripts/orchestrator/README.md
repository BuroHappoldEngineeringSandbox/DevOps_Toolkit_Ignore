# Orchestrator shell scripts

Used by `ci-orchestrator.yml` **after** the `_central` checkout of DevOps_Toolkit (policy + these scripts).

## Files

| File | Purpose |
|------|---------|
| `policy-contract.sh` | Declares required **states** and **keys** for `policy.json`. Edit here first when extending the contract. |
| `validate-policy.sh` | Ensures `policy.json` exists and each state object has every required key (`has()`; safe for boolean `false`). |
| `read-policy.sh` | Reads flags for the current `STATE` (from repo topics) and writes `GITHUB_OUTPUT`. Applies optional `.github/bhom.json` compliance override. |
| `read-bhom-config.sh` | Dotnet / configuration / test solution defaults and `bhom.json` overrides. |

## Changing policy shape

1. Update `policy.json` at the DevOps_Toolkit repo root.
2. Update `policy-contract.sh` (and thus `validate-policy.sh` via sourcing).
3. Update `read-policy.sh` if you add/remove fields passed to downstream workflows.
4. Update `ci-orchestrator.yml` job `if:` / `with:` as needed.

Topic → `STATE` mapping lives in the workflow **Read GitHub Topic** step (beta wins over alpha over prototype).

## Environment overrides (testing)

- `POLICY_PATH` — default `_central/policy.json`
- `BHOM_PATH` — default `.github/bhom.json`
- `STATE` — required by `read-policy.sh` (passed from the workflow)
