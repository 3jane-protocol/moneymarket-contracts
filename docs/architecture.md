# Architecture

## Overview

This repository extends Morpho Blue with 3Jane credit primitives and USD3/sUSD3 strategy logic.

## Contract Structure

- `src/Morpho.sol`: base market operations and accounting.
- `src/MorphoCredit.sol`: credit-line and borrower-premium extensions using hook overrides.
- `src/libraries/`: core libraries (`MathLib`, `SharesMathLib`, `UtilsLib`, and related helpers).
- `src/libraries/periphery/`: helper libraries for integrators.
- `src/mocks/`: test-only mock contracts.

## Core Data and Accounting Model

- Market identity is derived from `MarketParams` hashed into `Id`.
- Position and market state are share-based, not balance-based.
- Interest accrual updates borrow/supply state before operations.
- Premium accrual is borrower-specific and integrated through hook entry points.

## 3Jane Credit Extensions

- Unsecured lending path via credit-line controls.
- Per-borrower premium model layered on top of base IRM rate.
- Settlement paths include write-off handling and JANE markdown/redistribution integration.

## Jane Domain (Token + Rewards)

- `src/jane/Jane.sol` implements the JANE token with role-based mint/transfer controls and `MarkdownController` integration for borrower freezes and redistribution.
- `src/jane/RewardsDistributor.sol` implements cumulative merkle-based rewards claims, optional mint-vs-transfer payout mode, and global emissions caps.
- `src/MarkdownController.sol` orchestrates markdown-driven borrower freezing and proportional/full redistribution calls into `Jane`.
- Security boundaries center on:
  - role ownership and minter finalization in `Jane`
  - owner-only root/emission updates in `RewardsDistributor`
  - `onlyMorphoCredit` and markdown enablement gates in `MarkdownController`

## LCC Domain

- `src/lcc/LCCVault.sol`: per-facility callable-credit vault (not ERC-4626, no transferable shares). One ERC20 `marginAsset` is posted as a performance bond, valued through a trusted Morpho-style `IOracle`, and leveraged by `marginRatioBps` into a callable commitment denominated in the vault's `fundingAsset`. The spec term "callable asset" maps to `fundingAsset` in code because that token funds calls and auction fills.
- `src/lcc/LCCVaultFactory.sol`: permissionless `LCCVault` deployment; registry membership confers no trust.
- Lifecycle: epochs and phases (`Normal`, `PreCall`, `Funding`, `Closed`) are time-derived. The owner opens at most one call per epoch during `PreCall`; users fund all-or-nothing pro-rata obligations during `Funding`; unfunded accounts are slashed after the deadline. `maxEpochs` optionally schedules a terminal withdraw-only phase after a finite number of callable cycles (`0` means perpetual).
- Amount-like accounting values outside the margin family are denominated in `fundingAsset` unless explicitly documented otherwise. Margin values are denominated in `marginAsset`; `marginValue` is margin valued in the funding asset before leverage.
- Slashed margin backs an epoch-shortfall auction during the `Closed` phase (or follows the same surplus-disposal path when the auction is disabled, there is no shortfall, or finalization happens after the window): fillers' funding asset fills the remaining call shortfall and is delivered as wrapped USD3n, plus a collateral kicker that steps up over the window — the protocol's retained share of the pool decays by `auctionStepDecayRateBps` every step, with the window divided into `auctionStepCount` steps and per-fill awards capped by `maxAuctionAwardBps` at fill-time oracle price (`src/lcc/libraries/LCCAuctionLib.sol`, externally linked). Unawarded collateral is split into a configurable treasury fee and a return pool that is lazily re-attributed to defaulters as active margin/commitment; residual shortfall does not roll over.
- No keeper: all state progression is lazy. A `synced` modifier folds due pending activations, exit maturities, and eligible slash finalizations on every touch; per-user state is materialized by replaying finalized calls through a bounded cursor (`materializeAccount` is permissionless).
- Funding routes the funding asset through USD3 into the USD3 Notification Vault (`USD3n`) for the funder. Third parties may fund a user's obligation push-style via `fundCall(address)` (the caller pays; all proceeds accrue to the user). If USD3 or the notification vault cannot deliver, the funding transaction reverts and can be retried while the funding window remains open.
- Exits are full-account, irrevocable, assigned first-fit to per-epoch maturity buckets capped at a percentage of the protocol commitment cap; exiting accounts remain liable until maturity. `claimExitedMargin` handles normal matured exits, while `claimRemainingMargin` withdraws remaining active, pending, or matured-exit margin after shutdown or terminal sunset. A lagging account more than 64 finalized calls behind may need permissionless `materializeAccount` batches before the wind-down claim succeeds.
- Trust model: the vault owner and margin oracle are fully trusted; the margin asset must be a standard ERC20 (no fee-on-transfer/rebasing).
- Operational requirement: each LCC vault must be added to USD3's `supplyCapExempt` list so funding and auction-fill deposits bypass supply-cap headroom and first-time minimum deposits. If USD3's regular whitelist is enabled, the vault must also be whitelisted there. A zero USD3 supply cap remains an emergency pause and blocks even exempt vaults. The legacy general whitelist machinery is expected to stay disabled in production and is a deferred bytecode-size simplification candidate.

## USD3 / sUSD3 Domain

- USD3 and sUSD3 behavior is exercised in `test/forge/usd3/`.
- The waUSDC -> USDC migration is complete; upgrade docs/tests are retained as historical regression context.
- See `test/forge/usd3/integration/USD3UpgradeMultisigBatch.t.sol` and `test/forge/usd3/fork/USD3UpgradeForkTest.t.sol`.

## Test Architecture

- Forge unit/integration/fuzz tests: `test/forge/`
- Jane token/rewards suites: `test/forge/jane/` and `test/forge/integration/markdown/MarkdownControllerJaneTest.sol`
- LCC suites: `test/forge/lcc/` (focused regressions plus the `LCCStatefulInvariantTest` harness, which runs in the standard `test` profile)
- Forge invariants:
  - Core harness: `CoreInvariantHarness`
  - USD3 harnesses: `InvariantsTest`, `DebtFloorInvariantsTest`
- Fork tests: `test/forge/usd3/fork/`
- Hardhat tests: `test/hardhat/`
- Halmos symbolic tests: `test/halmos/`
- Certora specs: `certora/`

## Current Invariant Execution Model

- Core invariants run fast/deep profiles in CI.
- USD3 invariants are currently expected to expose one known failing invariant and are gate-checked for exactly that failure signature.
- This expected-failure gate must be removed once underlying protocol behavior is fixed.
