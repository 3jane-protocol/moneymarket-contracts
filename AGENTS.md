# AGENTS.md

This file is the primary operational guide for AI coding agents working in this repository.

## Repository Purpose

This repository contains Morpho Blue plus 3Jane-specific credit extensions for unsecured lending, including:

- Core money market logic in `src/`.
- Credit-line and borrower-premium logic in `src/` and `src/libraries/`.
- JANE token and rewards distribution modules in `src/jane/`.
- USD3/sUSD3 strategy and lifecycle tests in `test/forge/usd3/`.
- LCC vault module in `src/lcc/` with tests in `test/forge/lcc/`.
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

- The migration executed on mainnet and its `reinitialize()` hook has since been removed from the
  implementation, so no live test replays the historical batch; the sequence above is the record.
- `test/forge/usd3/integration/USD3UpgradeMultisigBatch.t.sol` and `test/forge/usd3/fork/USD3UpgradeForkTest.t.sol`
  cover the implementation upgrade from the frozen v2 logic to the cleaned implementation.

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
  - `forge-test`: non-invariant suite (matrix: slow + fast fuzz budgets) on PR/push/dispatch
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
- LCC vault module: `src/lcc/` (vault, factory, interface)
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

## LCC Module Guide (`src/lcc/`)

- `src/lcc/LCCVault.sol`: per-facility LCC vault — margin deposits create USDC callable commitments, the owner opens one capital call per epoch, funding routes USDC through USD3 into wrapped USD3 Notification Vault (`USD3n`) shares for funders/fillers, and missed obligations slash margin. Self-funders choose per call whether to amortize with `fundCall(false)` or roll with `fundCall(true)`; rolling pays the obligation while retaining full margin and callable commitment, so exposure re-arms every epoch. Push funding through `fundCall(address)` always amortizes. State progression is lazy (no keeper); `materializeAccount` and `finalizeEpochSlash` are permissionless.
- Heavy rolling keeps `protocolCommitmentCap` utilization pinned because rolled accounts do not decrement active commitment. This reduces deposit headroom and can divert more defaulter surplus to treasury through the going-concern headroom clamp in tight-cap vaults; owners manage this with `setRiskCaps`.
- `maxEpochs` can schedule a vault sunset: `0` means perpetual, otherwise epochs `0..maxEpochs-1` are callable and epoch `maxEpochs` starts a terminal withdraw-only phase. `claimRemainingMargin` is the wind-down claim for shutdown or terminal sunset, while `claimExitedMargin` remains the normal maturity-gated exit claim. `minCommitmentEpochs` (immutable, up to 64, 0 disables) gates `requestExit` until that many epochs have passed since the latest deposit activation; the wind-down claim bypasses it.
- Slashed margin backs a step-decay shortfall auction during the epoch's `Closed` phase (pricing math in the externally linked `src/lcc/libraries/LCCAuctionLib.sol`); the treasury fee is charged on auction-awarded collateral and capped by the unawarded surplus, with the remainder forming a return pool that is lazily re-attributed to defaulters as active commitment. Disabled config (`auctionStepCount == 0`) uses the same surplus-disposal path without an auction but has no auction-award fee basis.
- LCC deployment topology: `LCCAuctionLib` is externally linked into a shared `LCCVault` implementation, an `UpgradeableBeacon` owned by 3Jane's existing 7-day timelock points at that implementation, and `LCCVaultFactory` deploys per-facility `BeaconProxy` instances with atomic initializer calldata. The implementation constructor fixes protocol-wide `notificationVault`, `usd3`, `fundingAsset`, and `treasury`; per-facility params live in proxy storage.
- `src/lcc/LCCVaultFactory.sol`: owner-gated factory for LCC `BeaconProxy` vaults (`createVault` is restricted to the immutable factory owner); registry membership records owner-vetted provenance. The beacon is public, so non-factory proxies can point at it and remain unregistered.
- Vaults must be on USD3's `supplyCapExempt` list for funding/fill deposits to bypass supply-cap headroom and first-time minimum deposits.
- The LCC module is pinned to solc `0.8.35`; `LCCVault.sol` alone uses scoped `optimizer_runs = 400` to preserve bytecode headroom while the factory compiles at the repo default. USD3 compiles at the repo-default optimizer runs with a thin (~0.9 KB) EIP-170 margin; the frozen `USD3_old` upgrade-test artifact is pinned at `optimizer_runs = 200`. The LCC sources use a version-range pragma so Hardhat compiles them via per-file `overrides` in `hardhat.config.ts`.
- LCC upgrade safety: the beacon owner can replace logic under every beacon-backed vault after the 7-day timelock. Never reorder storage variables or base contracts; append new state into `__gap`; treat `LCCTypesLib` packed structs as upgrade-frozen layout; keep `_disableInitializers()` in implementation constructors; re-link `LCCAuctionLib` on implementation redeploys. A `forge inspect LCCVault storageLayout` snapshot is the manual review gate for implementation changes.
- Design notes: `docs/architecture.md` (LCC Domain section).

Targeted local command for LCC changes:

- `yarn run test:forge --match-path 'test/forge/lcc/**/*.t.sol' -vvv`

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
