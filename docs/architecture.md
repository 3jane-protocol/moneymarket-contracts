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

## LCC Domain (Leveraged Callable Credit)

- `src/lcc/LeveragedCallableCreditVault.sol`: per-facility callable-credit vault (not ERC-4626, no transferable shares). One ERC20 `marginAsset` is posted as a performance bond, valued in USDC through a trusted Morpho-style `IOracle`, and leveraged by `marginRatioBps` into a USDC callable commitment.
- `src/lcc/LeveragedCallableCreditVaultFactory.sol`: permissionless vault deployment; registry membership confers no trust.
- Lifecycle: epochs and phases (`Normal`, `PreCall`, `Funding`, `Closed`) are time-derived. The owner opens at most one USDC call per epoch during `PreCall`; users fund all-or-nothing pro-rata obligations during `Funding`; unfunded accounts are slashed after the deadline.
- Slashed margin backs an epoch-shortfall auction during the `Closed` phase (or goes straight to treasury when the auction is disabled, there is no shortfall, or finalization happens after the window): fillers' USDC fills the remaining call shortfall and is deposited into USD3 for them, plus a collateral kicker that steps up over the window — the protocol's retained share of the pool decays by `auctionStepDecayRateBps` every step, with the window divided into `auctionStepCount` steps and per-fill awards capped by `maxAuctionAwardBps` at fill-time oracle price (`src/lcc/libraries/LCCAuctionLib.sol`, externally linked). Fillers get no escrow fallback — takes revert if USD3 cannot accept. Unclaimed collateral sweeps to treasury lazily at settlement; residual shortfall does not roll over.
- No keeper: all state progression is lazy. A `synced` modifier folds due pending activations, exit maturities, and eligible slash finalizations on every touch; per-user state is materialized by replaying finalized calls through a bounded cursor (`materializeAccount` is permissionless).
- Funding routes USDC into USD3 for the funder, or into an internal escrow when USD3 lacks deposit capacity (`placeEscrowedFunding` pushes escrow into USD3 permissionlessly; escrow is refundable to the funder only under terminal shutdown). Third parties may fund a user's obligation push-style via `fundEpochCallFor` (the caller pays; all proceeds accrue to the user).
- Exits are full-account, irrevocable, assigned first-fit to per-epoch maturity buckets capped at a percentage of the protocol callable cap; exiting accounts remain callable until maturity.
- Trust model: the vault owner and margin oracle are fully trusted; the margin asset must be a standard ERC20 (no fee-on-transfer/rebasing).
- Operational requirement: each LCC vault must be added to USD3's `depositorWhitelist` so funding and auction-fill deposits succeed while USD3 commitment enforcement is active (funding falls back to escrow if not; auction takes revert).

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
