# Deployment and CI Execution

## Scope

This repository is a contracts codebase. "Deployment" here primarily means CI execution and release publishing behavior.

## LCC Implementation Deployment

`LCCVault` is compiled for Shanghai with solc `0.8.35`, via IR, and 500 optimizer runs in both Foundry and Hardhat.
Its measured runtime is 24,014 bytes, leaving 562 bytes below EIP-170; run `yarn build:forge:size` before approving an
implementation release.

`LCCAuctionLib` is the implementation's only externally linked library. Deploy and link it before deploying each new
`LCCVault` implementation, then schedule the beacon upgrade through the 7-day timelock. The config, account, bucket,
type, error, and event libraries are compiled internally and require no deployment or link addresses. Compare
`forge inspect LCCVault storageLayout` with `docs/lcc-vault-storage-layout.json` before scheduling the upgrade.

## GitHub Actions Workflows

- `foundry.yml`
  - Non-invariant tests: `forge-test` (matrix: slow + fast fuzz budgets)
    - Includes Jane token/rewards suites under `test/forge/jane/**`
  - IRM tests: `irm-tests`
  - Core invariants: `core-invariant-fast`, `core-invariant-deep`
  - USD3 invariants: `usd3-invariant-fast`, `usd3-invariant-deep`
  - Fork tests (including legacy USD3 migration regression tests): `fork-tests`
- `formatting.yml`: formatter/lint checks
- `hardhat.yml`: hardhat test execution
- `halmos.yml`: halmos symbolic checks
- `certora.yml`: certora workflow definition (triggered section currently commented out)
- `npm-release.yml`: manual publish workflow
- `update-docs.yml`: scheduled and manual doc-gardening automation

## Trigger Model

### Foundry

- PR/push: `forge-test` (both slow + fast matrix) + IRM + fast invariants (core + usd3)
- Schedule: deep invariants (core + usd3) + fork tests
- Manual dispatch: all jobs (non-invariant + IRM + fast/deep invariants + fork tests)
- Fork tests also triggered by PR label `ci/run-fork-tests`
- The `fork-tests` job still runs `test:forge:fork:upgrade` to exercise the current USD3 upgrade path.

### Doc Gardening

- Weekly schedule and manual dispatch
- Opens a PR only when documentation drift is detected

## Secrets and Variables

- `ETH_RPC_URL` (secret): required for fork tests
- `NPM_TOKEN` (secret): required for npm publish
- `ANTHROPIC_API_KEY` (secret): required for doc-gardening automation via Claude Code Action

## Release Notes

When workflow names or test script names change, update:

1. `.github/workflows/*.yml`
2. `package.json` scripts
3. `AGENTS.md` CI map
4. `docs/deployment.md`
