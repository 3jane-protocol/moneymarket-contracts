# AGENTS.md

This file is the primary operational guide for AI coding agents working in this repository.

## Repository Purpose

This repository contains Morpho Blue plus 3Jane-specific credit extensions for unsecured lending, including:

- Core money market logic in `src/`.
- Credit-line and borrower-premium logic in `src/` and `src/libraries/`.
- JANE token and rewards distribution modules in `src/jane/`.
- USD3/sUSD3 strategy and lifecycle tests in `test/forge/usd3/`.
- Formal and symbolic test suites in `test/halmos/` and `certora/`.

## Golden Rules

- Always use `yarn` scripts for build/test/lint flows.
- Do not run ad-hoc direct commands when a script exists in `package.json`.
- Keep comments descriptive of current code behavior, not change-history narrative.
- Do not commit planning markdown files.

## USD3 Migration Status (Completed / Deprecated Runbook)

The USD3 waUSDC -> USDC migration has been completed. The sequence below is retained for historical and regression context and should not be treated as a pending operational task.

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
- Fork upgrade regression tests (historical migration safety): `yarn test:forge:fork:upgrade`
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

## Jane Module Guide (`src/jane/`)

- `src/jane/Jane.sol`: ERC20 + permit token with role-based minting/transfer gates and MarkdownController-driven redistribution from delinquent borrowers.
- `src/jane/RewardsDistributor.sol`: merkle-based cumulative rewards claims with epoch emission caps and transfer/mint distribution modes.
- Integration point: `src/MarkdownController.sol` freezes borrower transferability and can slash/redistribute JANE during delinquency/default transitions.

Primary Jane tests:

- `test/forge/jane/JaneTokenAccessControl.t.sol`
- `test/forge/jane/JaneTokenTransfer.t.sol`
- `test/forge/jane/JaneTokenMintFinalization.t.sol`
- `test/forge/jane/rewards/RewardsDistributorUnit.t.sol`
- `test/forge/jane/rewards/RewardsDistributorSecurity.t.sol`
- `test/forge/jane/rewards/RewardsDistributorIntegration.t.sol`
- `test/forge/integration/markdown/MarkdownControllerJaneTest.sol`

Targeted local command patterns for Jane changes:

- `yarn run test:forge --match-path 'test/forge/jane/**/*.t.sol' -vvv`
- `yarn run test:forge --match-contract MarkdownControllerJaneTest -vvv`

## Architecture Notes

- Primary contract: `src/Morpho.sol`.
- Credit extension: `src/MorphoCredit.sol`.
- Share-based accounting via `SharesMathLib` and market/position state.
- Hook points (`_before*`, `_after*`) are used to integrate borrower-premium accrual behavior.
- 3Jane model introduces unsecured credit-line behavior and borrower-specific pricing.
- JANE token behavior is enforced through role controls plus borrower freeze/redistribution interactions with `MarkdownController`.

## Markdown + JANE Redistribution Flow

JANE redistribution is driven by markdown/default logic rather than a separate burner-controller stack.

- `src/MarkdownController.sol`: tracks borrower markdown state, freeze status, and proportional/full JANE slashing.
- `src/jane/Jane.sol`: enforces transfer restrictions and only allows redistribution through the configured markdown controller.
- `src/jane/RewardsDistributor.sol`: handles protocol rewards independently of markdown redistribution.

Owner and authorization boundaries across `Jane`, `RewardsDistributor`, and `MarkdownController` should be validated whenever JANE flows are modified.

## Documentation Index

- Human onboarding: `README.md`
- Deep technical docs: `docs/index.md`
- Architecture details: `docs/architecture.md`
- Tooling/stack details: `docs/tech-stack.md`
- CI/deployment behavior: `docs/deployment.md`
- Doc maintenance process: `docs/doc-gardening.md`
