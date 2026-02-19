# AGENTS.md

This file is the primary operational guide for AI coding agents working in this repository.

## Repository Purpose

This repository contains Morpho Blue plus 3Jane-specific credit extensions for unsecured lending, including:

- Core money market logic in `src/`.
- Credit-line and borrower-premium logic in `src/` and `src/libraries/`.
- USD3/sUSD3 strategy and lifecycle tests in `test/forge/usd3/`.
- Formal and symbolic test suites in `test/halmos/` and `certora/`.

## Golden Rules

- Always use `yarn` scripts for build/test/lint flows.
- Do not run ad-hoc direct commands when a script exists in `package.json`.
- Keep comments descriptive of current code behavior, not change-history narrative.
- Do not commit planning markdown files.

## Critical Runbook: USD3 waUSDC -> USDC Upgrade

When upgrading USD3 from waUSDC to USDC, execute the upgrade as one atomic multisig batch.

### Required Atomic Sequence

1. `strategy.setPerformanceFee(0)`
2. `strategy.setProfitMaxUnlockTime(0)`
3. `strategy.report()`
4. `proxyAdmin.upgrade(proxy, newImpl)`
5. `strategy.reinitialize()`
6. `strategy.report()`
7. `strategy.syncTrancheShare()`
8. `strategy.setProfitMaxUnlockTime(previous)`

### Why it matters

Without atomic batching, `totalAssets()` can be stale during the transition window. If waUSDC PPS is above 1.0, users can be underpaid on withdrawal.

### Reference test

- `test/forge/usd3/integration/USD3UpgradeMultisigBatch.t.sol`

## Canonical Commands

Use these scripts exactly as defined in `package.json`:

- Install: `yarn`
- Build (forge): `yarn build:forge`
- Build (hardhat): `yarn build:hardhat`
- Lint: `yarn lint`
- Lint fix: `yarn lint:fix`
- Forge tests (all in `test` profile): `yarn test:forge`
- Forge non-invariant tests: `yarn test:forge:noninvariant`
- Forge IRM tests: `yarn test:forge:irm`
- Core invariants: `yarn test:forge:invariant:core`
- USD3 invariants: `yarn test:forge:invariant:usd3`
- Fork tests: `yarn test:forge:fork`
- Fork upgrade tests: `yarn test:forge:fork:upgrade`
- Hardhat tests: `yarn test:hardhat`
- Halmos checks: `yarn test:halmos`

## Test and CI Map

GitHub Actions in `.github/workflows/`:

- `foundry.yml`
  - `forge-baseline-fast`: non-invariant suite on PR/push
  - `forge-baseline-deep`: non-invariant deep run on schedule/manual
  - `irm-tests`: IRM-only profile
  - `core-invariant-fast` / `core-invariant-deep`
  - `usd3-invariant-fast` / `usd3-invariant-deep` (currently expected-failure gated)
  - `fork-tests` (schedule/manual or PR label `ci/run-fork-tests`)
- `formatting.yml`: lint/format checks
- `hardhat.yml`: hardhat test job
- `halmos.yml`: symbolic checks
- `certora.yml`: currently disabled by trigger comments

### Seeds and reproducibility

Foundry CI jobs seed fuzz/invariant runs from base SHA or commit SHA for deterministic reruns.

## Codebase Map

- Core contracts: `src/`
- Core interfaces/libraries: `src/interfaces/`, `src/libraries/`
- Mocks: `src/mocks/`
- Forge tests: `test/forge/`
- Hardhat tests: `test/hardhat/`
- Halmos: `test/halmos/`
- Certora specs/config: `certora/`

## Architecture Notes

- Primary contract: `src/Morpho.sol`.
- Credit extension: `src/MorphoCredit.sol`.
- Share-based accounting via `SharesMathLib` and market/position state.
- Hook points (`_before*`, `_after*`) are used to integrate borrower-premium accrual behavior.
- 3Jane model introduces unsecured credit-line behavior and borrower-specific pricing.

## Settlement + JANE Burn Flow

Settlement uses helper-controller architecture so bad-debt settlement and JANE burn execute atomically.

- `CreditLine.sol`: credit operations and settlement orchestration.
- `SettlementController.sol`: wraps settlement and burn call sequence.
- `JaneBurner.sol`: authorization-gated burn helper.
- `JaneToken.sol`: token with burner role control.

Owner and authorization boundaries should be validated whenever settlement logic changes.

## Documentation Index

- Human onboarding: `README.md`
- Deep technical docs: `docs/index.md`
- Architecture details: `docs/architecture.md`
- Tooling/stack details: `docs/tech-stack.md`
- CI/deployment behavior: `docs/deployment.md`
- Doc maintenance process: `docs/doc-gardening.md`
