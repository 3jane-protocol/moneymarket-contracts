# Deployment and CI Execution

## Scope

This repository is a contracts codebase. "Deployment" here primarily means CI execution and release publishing behavior.

## GitHub Actions Workflows

- `foundry.yml`
  - Baseline tests: `forge-baseline-fast`, `forge-baseline-deep`
  - IRM tests: `irm-tests`
  - Core invariants: `core-invariant-fast`, `core-invariant-deep`
  - USD3 invariants: `usd3-invariant-fast`, `usd3-invariant-deep`
  - Fork tests: `fork-tests`
- `formatting.yml`: formatter/lint checks
- `hardhat.yml`: hardhat test execution
- `halmos.yml`: halmos symbolic checks
- `certora.yml`: certora workflow definition (triggered section currently commented out)
- `npm-release.yml`: manual publish workflow
- `update-docs.yml`: scheduled and manual doc-gardening automation

## Trigger Model

### Foundry

- PR/push: fast baseline + IRM + fast invariants
- Schedule/manual dispatch: deep baseline + deep invariants
- Fork tests run on schedule/manual or PR label `ci/run-fork-tests`

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
