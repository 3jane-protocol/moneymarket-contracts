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
- Topology: `LCCAuctionLib` and `LCCConfigLib` are the two externally linked libraries in the shared `LCCVault` implementation. An `UpgradeableBeacon` owned by 3Jane's existing 7-day timelock points at that implementation, and `src/lcc/LCCVaultFactory.sol` deploys per-facility `BeaconProxy` instances with atomic initializer calldata. The implementation constructor fixes protocol-wide `notificationVault`, `usd3`, `fundingAsset`, and `treasury`; per-facility params live in proxy storage.
- Build constraint: the canonical Forge `LCCVault` artifact is compiled for Cancun with official solc `0.8.35`, via IR, and 150 optimizer runs. The measured runtime is 23,948 bytes, 328 bytes below the internal ceiling and 628 bytes below EIP-170; `yarn build:forge:size` enforces the compiler settings, 24,276-byte internal ceiling, and two-linked-library topology. `ReentrancyGuardTransient` makes EIP-1153 support mandatory. Hardhat uses pinned stable solc-js `0.8.35` for compile/test-only Cancun output, while non-LCC production artifacts remain Shanghai.
- `src/lcc/LCCVaultFactory.sol`: owner-gated `BeaconProxy` deployment (`createVault` restricted to the immutable factory owner); registry membership records owner-vetted provenance. The beacon is public, so non-factory proxies can point at it and remain unregistered. Empty-init proxies are invalid shells until initialized by their first caller and are not registry-vetted vaults.
- Lifecycle: epochs and phases (`Normal`, `PreCall`, `Funding`, `Closed`) are derived from a pause-adjusted effective clock. The owner opens at most one call per epoch during `PreCall`; users fund all-or-nothing pro-rata obligations during `Funding`; unfunded accounts are slashed after the deadline. `maxEpochs` optionally schedules a terminal withdraw-only phase after a finite number of callable cycles (`0` means perpetual). An owner-appointed guardian or the owner can pause synced entrypoints and freeze the derived clock; unpause is owner-only with no time bound and resumes every window exactly where it froze. Shutdown ends an active pause without advancing effective time so wind-down claims become immediately available while funding-window slash semantics remain frozen at the pause instant. Pausing remains available after shutdown as a circuit breaker for the claim path.
- Amount-like accounting values outside the margin family are denominated in `fundingAsset` unless explicitly documented otherwise. Margin values are denominated in `marginAsset`; `marginValue` is margin valued in the funding asset before leverage.
- Slashed margin backs an epoch-shortfall auction during the `Closed` phase (or follows the same surplus-disposal path when the auction is disabled, there is no shortfall, or finalization happens after the window): fillers' funding asset fills the remaining call shortfall and is delivered as wrapped USD3n, plus a collateral kicker that steps up over the window — the protocol's retained share of the pool decays by `auctionStepDecayRateBps` every step, with the window divided into `auctionStepCount` steps and per-fill awards capped by `maxAuctionAwardBps` at fill-time oracle price (`src/lcc/libraries/LCCAuctionLib.sol`, externally linked). The treasury fee is charged on auction-awarded collateral and capped by the unawarded surplus, with the remainder forming a return pool that is lazily re-attributed to defaulters as active margin/commitment; residual shortfall does not roll over.
- No keeper: all state progression is lazy. A `synced` modifier folds due pending activations, exit maturities, and eligible slash finalizations on every touch; per-user state is materialized by replaying finalized calls through a bounded cursor (`materializeAccount` is permissionless).
- Funding routes the funding asset through USD3 into the USD3 Notification Vault (`USD3n`) for the funder. Self-funders choose per call whether to amortize (`fundCall(false)`, releasing proportional margin and reducing commitment) or roll (`fundCall(true)`, paying the obligation while retaining full margin and callable commitment). Rolled exposure re-arms every epoch, so repeated rolling keeps the account's full commitment callable and can make later pro-rata obligations larger as amortizers decay. Third parties may fund a user's obligation push-style via `fundCall(address)` (the caller pays; all proceeds accrue to the user), and push funding always amortizes so the payer cannot keep the user's margin locked. Funding pulls `max(obligationAmount, usd3.previewMint(1))` so every successful delivery mints at least one USD3 share, with at most 1,000 extra funding-asset base units; settlement remains obligation-denominated. `previewMint(1) == 0` reports an undeliverable zero-asset/nonzero-supply USD3 state: pause to freeze the deadline, then owner-shutdown before the frozen deadline. Other USD3 or notification-vault failures revert atomically and can be retried while the window remains open.
- Heavy rolling keeps `protocolCommitmentCap` utilization pinned because rolled accounts do not decrement active commitment, reducing deposit headroom. Going-concern surplus disposal uses a call-local funded base that conservatively treats every funded account's call-open commitment as surviving; a current cap at or below that base zeroes the paired return pool, while a positive commitment clamp preserves the full recovered margin. Deposits cannot influence the bound; owners manage the current cap with `setRiskCaps`.
- Exits are full-account, irrevocable, and assigned first-fit to per-epoch maturity buckets with capacity `max(1, max(protocolCommitmentCap, activeCommitment) * exitCapBps / BPS)`; exiting accounts remain liable until maturity. `requestExit(maxDeferralEpochs, deadline)` lets the caller bound both assignment and wall-clock freshness: `exitDelayEpochs` is the delay from now to the earliest available maturity (`currentEpoch + exitDelayEpochs`), while deferral starts there; 0 accepts only that maturity, `N` accepts up to `N` later epochs, and `type(uint256).max` accepts any. This deferral is unrelated to the `maxEpochs` sunset schedule. Capacity is recomputed per request from aggregate `activeCommitment`, deliberately introducing path dependence: it can decline as active commitment declines through amortization or slashing, but never below the configured-cap value at that request. Any unattributed return commitment conservatively included in the aggregate only widens capacity. Pending-activation and exit-maturity margin/commitment pairs each occupy one packed `LCCTypesLib.Bucket` word, while the four original `uint256` field getters preserve the external ABI. Per-call exit exposure packs six `uint128` amounts into three words and retains an explicit `listed` word so maturity-list membership remains exact-once. Auction state similarly packs its four `uint128` counters into two words; `getAuctionState` keeps the same wire encoding, and the linked `LCCAuctionLib` records packed fills. A vault may set `minCommitmentEpochs` (immutable, up to 64, 0 disables): `requestExit` reverts `CommitmentNotMature` until that many epochs have passed since `commitmentStartEpoch`, the later of the account's latest deposit activation epoch and the epoch in which its latest nonzero paired return-pool re-credit was created — every deposit and such re-credit advances the clock monotonically, zero credits and funding of any kind never touch it, and the wind-down claim bypasses the gate. Live maturity buckets are hard-capped at 128 (`requestExit` reverts `ExitCapacityReached` when a new bucket would exceed it). The configuration bounds `exitDelayEpochs <= 64` and `exitCapBps >= 313` keep worst-case honest exit demand, including first-fit fragmentation, within that cap. Scan termination relies separately on the runtime clamp: capacity is at least one, so any empty bucket terminates the scan and only nonzero-commitment buckets are skipped; `_trackExitMaturity` and `_pruneExitMaturityIfEmpty` keep those buckets in the maturity list, which is capped at 128, so the scan takes at most 129 iterations. The limit remains reachable through cap-raise sequences whose exact-capacity deposits each open a new maturity. `claimExitedMargin` handles normal matured exits, while `claimRemainingMargin` withdraws remaining active, pending, or matured-exit margin after shutdown or terminal sunset. A lagging account more than 64 finalized calls behind may need permissionless `materializeAccount` batches before the wind-down claim succeeds.
- Trust model: the vault owner and margin oracle are fully trusted. Vault ownership is transferable for governance rotation and incident recovery but cannot be renounced, preserving an account that can unpause, shut down, and open calls. Transfer is one-step, so a mistyped recipient while a pause is active would strand pause recovery behind the beacon timelock; operationally, ownership should not be transferred while paused. The margin oracle is owner-rotatable through `setMarginOracle`, and rotation reprices all unsettled calls. During a pause the owner may replace even a responsive oracle because fills cannot execute; while unpaused, a responsive oracle still blocks mid-auction rotation and the existing zero-price/reverting-oracle recovery carve-out remains. The pause guardian can only pause, while shutdown and oracle rotation remain live during a pause for incident response. The margin asset must be a standard ERC20 (no fee-on-transfer/rebasing). The beacon owner can replace logic under every beacon-backed LCC vault; this fleet-upgrade authority is mitigated by the 7-day timelock delay.
- Operational requirement: each LCC vault must be added to USD3's `supplyCapExempt` list so funding and auction-fill deposits bypass supply-cap headroom and first-time minimum deposits. A zero USD3 supply cap remains an emergency pause and blocks even exempt vaults.
- Upgrade safety checklist: the initial production layout has no persistent reentrancy slot and retains the full 50-slot `__gap` after the treasury accrual slot. While LCC remains pre-deployment, new state is declared above the gap so the post-deployment reserve stays at 50; only upgrades after deployment consume gap slots. After deployment, never reorder storage variables or base contracts; append new state by consuming `__gap`; treat the packed structs in `LCCTypesLib` as upgrade-frozen layout; keep `_disableInitializers()` in implementation constructors; re-link both `LCCAuctionLib` and `LCCConfigLib` whenever a new implementation is deployed. Every future implementation must preserve the property that runtime exit capacity is at least one, or normalize existing configurations during the upgrade. Surplus disposal may be deferred past slash finalization only through the auction slot, and returned commitment never exceeds the commitment the slash removed; the `setRiskCaps` cap-reduction guard relies on both, so any future implementation introducing another deferral path, or loosening that bound, must extend the guard to cover it. `yarn build:forge:size` reads the storage layout embedded in the canonical build-profile artifact and recursively canonicalizes encoding, widths, mappings, arrays, and packed struct members before comparing it with the versioned, reviewer-controlled `docs/lcc-vault-storage-layout.json`; the gate never regenerates its baseline.
- Deferred (policy, not physics): the EpochState/RiskConfig storage repack — measured record in `docs/lcc-deferred-epochstate-repack.md`.
- Audit-oriented walkthrough with diagrams: `src/lcc/README.md` (phase machine, funding/slash/auction flows, worked examples).

## USD3 / sUSD3 Domain

- USD3 and sUSD3 behavior is exercised in `test/forge/usd3/`.
- The waUSDC -> USDC migration is complete; upgrade tests now cover the current implementation upgrade path.
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
