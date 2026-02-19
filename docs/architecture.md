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
- Settlement paths include write-off handling and JANE burn integration.

## USD3 / sUSD3 Domain

- USD3 and sUSD3 behavior is exercised in `test/forge/usd3/`.
- Upgrade behavior (waUSDC -> USDC) requires an atomic multisig batch for safety.
- See `test/forge/usd3/integration/USD3UpgradeMultisigBatch.t.sol` for expected flow validation.

## Test Architecture

- Forge unit/integration/fuzz tests: `test/forge/`
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
