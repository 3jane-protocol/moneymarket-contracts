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

- `src/lcc/LCCVault.sol`: per-facility LCC vault — margin deposits create USDC callable commitments, the owner opens one capital call per epoch, funding routes USDC through USD3 into wrapped USD3 Notification Vault (`USD3n`) shares for funders/fillers, and missed obligations slash margin. Funding may pull up to 1,000 extra USDC base units so dust obligations mint at least one USD3 share, while settlement stays obligation-denominated. Self-funders choose per call whether to amortize with `fundCall(false)` or roll with `fundCall(true)`; rolling pays the obligation while retaining full margin and callable commitment, so exposure re-arms every epoch. Push funding through `fundCall(address)` always amortizes. State progression is lazy (no keeper); `materializeAccount` and `finalizeEpochSlash` are permissionless.
- Heavy rolling keeps `protocolCommitmentCap` utilization pinned because rolled accounts do not decrement active commitment, reducing deposit headroom. Surplus disposal conservatively counts every funded account's call-open commitment as surviving in its call-local base; for an auction-eligible epoch outside wind-down, a current cap at or below that base zeroes the paired return and diverts the recoverable pool to treasury, while any positive commitment clamp preserves it in full. Auction-ineligible disposal, shutdown-truncated disposal, and disposal of the last callable epoch (or later) bypass this protocol-cap clamp and remain bounded by the commitment removed plus packing headroom. Auction eligibility describes the opportunity to fill, whereas the clamp protects future-call capacity. A kicked epoch can become ineligible when shutdown lands mid-window, but `shutdownTruncated` implies `windDown`, so the `!windDown && auctionEligible` clamp condition already excludes it. Deposits cannot influence either bound; owners manage the current cap with `setRiskCaps`, which freezes protocol-cap changes while the auction slot is live.
- `maxEpochs` can schedule a vault sunset: `0` means perpetual, otherwise epochs `0..maxEpochs-1` are callable and epoch `maxEpochs` starts a terminal withdraw-only phase. `claimRemainingMargin` is the wind-down claim for shutdown or terminal sunset, while `claimExitedMargin` remains the normal maturity-gated exit claim. `minCommitmentEpochs` (immutable, up to 64, 0 disables) gates `requestExit` from the later of the latest deposit activation and one epoch after the call that produced the latest nonzero return credit; the wind-down claim bypasses it.
- Slashed margin backs a step-decay shortfall auction during the epoch's `Closed` phase (pricing math in the externally linked `src/lcc/libraries/LCCAuctionLib.sol`); the award curve reserves the configured treasury take, fills use the live oracle to cap `marginAwarded`, and completed settlement charges `slashFeeBps` on the greater of cumulative awards and cumulative fills' pro-rata first-step offer. Every auction-eligible epoch receives completed treatment after its full window, even if nobody touched the vault to open a record: zero fills send the whole gross pool to treasury. A shutdown strictly before `closedEnd` genuinely truncates the opportunity and returns the unawarded pool without a take; zero shortfall and disabled config are likewise non-eligible. The remaining return pool is converted to commitment at the validated nonzero price snapshotted at call open, so the conversion price is frozen but the amount converted is not. A missing snapshot is corruption/future-writer recovery: the live fallback is owner-gated. Price-failure tolerance is separate from the epoch-anchored cap exemption, and neither predicate contains the other: actual shutdown or terminal state sets tolerance, while the protocol-cap exemption uses `shutdownTruncated || lastCallableEpoch`. In particular, the last callable epoch disposed during its own Closed phase before terminal is cap-exempt but still price-intolerant; on a corrupt zero snapshot it re-bricks for a non-owner until terminal begins one epoch later. To preserve rather than sweep a missing-snapshot pool when the live oracle is also dead, the owner must call `setMarginOracle` first and then send any `synced` call; `shutdown()` alone is non-bricking but is not recovery. The unconditional overflow guard is an oracle-corruption sweep, not a dead branch. Call opening only rejects a zero price and stores the price and `marginAtCallOpen`; it never multiplies them or proves that the snapshot can value the margin without overflow. Even a full-`uint128` pool needs a selected price around `3.4e70` at the minimum valid margin ratio — roughly 34 orders of magnitude above an honest `ORACLE_PRICE_SCALE`-scaled price — so the guard is unreachable under the trusted-oracle assumption. On corrupt state, un-gating it trades a permanent brick of every `synced` entrypoint for a confiscating sweep of the whole selected pool, with the same `SlashSurplusDisposed(epoch, all, 0, 0)` shape as a legitimate zero-return disposal. Future changes must keep the guard after price selection, keep the subsequent `price == 0` sweep, and must not treat either as dead code.
- LCC deployment topology: `LCCAuctionLib` and `LCCConfigLib` are externally linked into a shared `LCCVault` implementation, an `UpgradeableBeacon` owned by 3Jane's existing 7-day timelock points at that implementation, and `LCCVaultFactory` deploys per-facility `BeaconProxy` instances with atomic initializer calldata. The implementation constructor fixes protocol-wide `notificationVault`, `usd3`, `fundingAsset`, and `treasury`; per-facility params live in proxy storage.
- `src/lcc/LCCVaultFactory.sol`: owner-gated factory for LCC `BeaconProxy` vaults (`createVault` is restricted to the immutable factory owner); registry membership records owner-vetted provenance. The beacon is public, so non-factory proxies can point at it and remain unregistered.
- Vaults must be on USD3's `supplyCapExempt` list for funding/fill deposits to bypass supply-cap headroom and first-time minimum deposits.
- The LCC module is Cancun-only and pinned to solc `0.8.35`; `LCCVault.sol` uses scoped `optimizer_runs = 150` (24,116 runtime bytes; 160 bytes below the 24,276-byte release ceiling; 460 bytes of EIP-170 headroom) while the factory compiles at the repo default. The vault uses `ReentrancyGuardTransient`, so every deployment chain must support EIP-1153. Forge produces the sole canonical deployment artifact; Hardhat uses a pinned stable solc-js `0.8.35` for its compile/test-only Cancun output. USD3 remains Shanghai and compiles at the repo-default optimizer runs, while the frozen `USD3_old` upgrade-test artifact stays pinned at `optimizer_runs = 200`.
- Pending-activation and exit-maturity bucket pairs are stored as packed `LCCTypesLib.Bucket` words; the four original `uint256` view getters remain the stable external ABI. Per-call exit exposure packs six `uint128` amounts into three words and retains an explicit fourth-word `listed` guard for exact-once maturity-list membership.
- Auction state packs `shortfallAmount`, `filledAmount`, `marginPool`, and `marginAwarded` into two words. `getAuctionState` remains wire-compatible, and auction-fill accounting is performed by the externally linked `LCCAuctionLib`.
- LCC upgrade safety: the beacon owner can replace logic under every beacon-backed vault after the 7-day timelock. The initial layout starts with Ownable's `_owner`, uses no persistent reentrancy slot, and retains the full 50-slot `__gap`. LCC is pre-deployment, so new state is declared above the gap and the reserve stays at 50; only post-deployment upgrades consume gap slots. After deployment, never reorder storage variables or base contracts; append new state by consuming `__gap`; treat `LCCTypesLib` packed structs as upgrade-frozen layout; keep `_disableInitializers()` in implementation constructors; re-link both `LCCAuctionLib` and `LCCConfigLib` on implementation redeploys. Every future implementation must preserve the property that runtime exit capacity is at least one, or normalize existing configurations during the upgrade. Every implementation that sets `callOpened` to true must write a validated nonzero `marginPriceAtCallOpen` snapshot for that epoch in the same transaction; otherwise a missing price blocks non-owner going-concern disposal. Return-pool replay credits each defaulter its full paired share with no per-user cap bound (deliberately reopened M-01), keeping global totals equal to the sum of per-account commitments up to the pair-drop residual (flooring dust per epoch, except when the conversion pins at `MIN_RETURN_COMMITMENT`, where it scales with the dropped margin). A nonzero return credit anchors `commitmentStartEpoch` at the later of its existing value and the disposed call's epoch plus one, the deterministic first epoch in which that exposure can back a new call.
- **Settlement-input freezing (upgrade rule).** Every input to `_finalizeEpochSlash`, `_settleAuction`, `_disposeSlashSurplus`, `LCCAuctionLib.disposeValuation`, and `_settlementReturnPool` must be classified before merge. The normal permitted classes are frozen for the disposed epoch or read only from a `synced` + slot-guarded setter. The `synced` coupling is a general argument, not a per-setter coincidence: `_syncGlobal` finalizes every slash-eligible epoch, in ascending `calledEpochList` order with `_slashEligible` monotone in effective time, before the setter's storage write, so no config change can interleave between an epoch becoming disposable and its disposal. The sole deferral channel is the auction slot, which is why `setRiskCaps`, `setMaxAuctionAwardBps`, and `setSlashFeeBps` each carry a `pendingAuctionEpochPlusOne` guard; the `setRiskCaps` guard covers protocol-cap raises as well as reductions. `_shutdown` is the explicit owner-only exception: it is frozen against permissionless timing and against post-window shutdown by the strict `timestamp < closedEnd(epoch)` comparison, but remains a live owner-side discriminator between the funding deadline and the Closed end. If epoch E is untouched, shutdown anywhere in `[fundingDeadline(E), closedEnd(E))` makes `_finalizeEpochSlash` skip the kick and dispose it as ineligible; if E has already kicked and is partially filled, shutdown in the same interval settles it immediately as ineligible. Normal window-end settlement instead charges the take and sends the unfilled gross share to treasury under the cap clamp. The delta is the whole unfilled gross share plus reserved fee, moved from treasury to defaulters. `shutdown()` deliberately has no pending-auction guard; owner-only authority prevents a permissionless front-run. Live price-failure tolerance (valuation bit 17) is inert on legitimately reachable disposal: `openEpochCall` stores a nonzero snapshot for every epoch it marks `callOpened`, both remaining bit-17 effects are gated by `price == 0`, and the overflow guard no longer reads bit 17. The bit is also monotone because `_shutdown.active` and `_terminal()` are one-way and `_now()` never rewinds across pause/unpause. The residual on a zero snapshot must be recorded, not generalized away: before terminal a non-owner reverts and preserves the pool for owner recovery; after terminal flips by clock alone, the first non-owner touch has bit 16 clear, skips fallback, and irreversibly sweeps the pool, while an owner touch at the same timestamp has bit 16 set, may read a healthy live oracle, and may credit defaulters. This first-toucher allocation difference is unreachable through shipped writers but is real under storage corruption or an upgrade that violates the snapshot rule. `msg.sender == owner()` (valuation bit 16) is therefore a live, owner-transferable settlement input and a genuine allocation discriminator on corrupt zero-snapshot state, though inert on every legitimate nonzero snapshot for the same `price == 0` reason. `_pause` is also live and guardian-controlled because it feeds `_now()`, hence `_terminal()` and `shutdownTruncated`; it is safe because `_sync()` reverts while paused, so no disposal runs, and `_endPause()` preserves effective time so `_now()` never rewinds. Price-failure tolerance and cap exemption are separate, non-nesting predicates: the last callable epoch in its own Closed phase before terminal has `windDown && !toleratePriceFailure`. `_clockConfig`, `_assetConfig.marginRatioBps`, and `_auctionConfig.auctionStepDecayRateBps` are frozen because they have no setter. Adding a setter for one requires the same treatment, and for `auctionStepDecayRateBps` would also break the `offered1` reconstruction at settlement, which must reprice the curve the fills paid against. `setMarginOracle` is deliberately un-`synced`; that is safe only while `marginPriceAtCallOpen` is guaranteed nonzero for every opened call. Two live `_totals` reads are retained and provably inert by conservation — the slash decrements the same amounts before disposal, so the packing clamp can never bind — and are not precedent for reading live aggregates.
- **Settlement determinism (design rule).** LCC settlement prefers determinism over case-by-case optimality. The return-credit anchor derives from the disposed call's epoch rather than settlement time, accepting that settlement after `PreCall` in a dormant vault can let one defaulter exit with re-credited commitment that backed no call. That exception is bounded to one epoch of one defaulter's credit, and dormancy is forced because `_requireNoPriorUnsettledCall` blocks every later call while the prior call remains unsettled. The protocol-cap clamp likewise remains applicable after a post-window shutdown even though no future call can use the reserved capacity, accepting that a saturated cap can send recoverable defaulter margin to treasury in exchange for an outcome independent of who settles first. Determinism and post-credit freshness are mutually exclusive under permissionless lazy settlement; the tempting local fix to read current state because it looks more accurate is exactly what this rule forbids.
- Caller-side auction bounds make fills more likely to revert, so auctions stay live longer in expectation. That is safe only because commit `1e4a2761` first removed the live-auction replay barrier and the earlier price-snapshot work froze return-pool valuation at call open, so shifting settlement from mid-window to window-end cannot change the disposal price. Any future implementation that reintroduces a global replay barrier on live auctions, or unfreezes disposal valuation, must revisit these bounds. `yarn build:forge:size` resolves the canonical full-settings build artifact, recursively compares its embedded storage layout with the versioned, reviewer-controlled `docs/lcc-vault-storage-layout.json`, and checks the external ABI; the checker never regenerates either baseline.
- The EpochState/RiskConfig storage repack is policy-deferred — see `docs/lcc-deferred-epochstate-repack.md` for the measured record. Re-measure variant sizes against the current artifact before re-opening; the underlying analysis does not need redoing.
- Design notes: `docs/architecture.md` (LCC Domain section).

Targeted local command for LCC changes:

- `yarn run test:forge --match-path 'test/forge/lcc/**/*.t.sol' -vvv`

## USD3 Upgrade Rules (`src/usd3/`)

- `USD3._deployFunds(uint256) internal override {}` is deliberately empty; deposit-path deployment lives in `_postDepositHook` (`_deployDepositedFunds`). The empty override is safe **only** against the pinned `tokenizedStrategyAddress` constant (`src/usd3/base/BaseStrategyUpgradeable.sol:82`). Any implementation that changes that constant must re-verify that `deployFunds` is still called only from `_deposit`; otherwise the empty override silently no-ops a new deployment path.
- Deployment now runs in `_postDepositHook`, **after** `TokenizedStrategy.deposit`'s `nonReentrant` lock has released — where `_deployFunds` ran inside it. That is safe only while no callee in the deploy path (`WAUSDC.mint`, `morphoCredit.supply` with empty data, the IRM) has a caller-controlled callback. If one ever does, `_postDepositHook` is unprotected.
- The pending-loss gate (`_pendingLoss`) is exact on the deposit path only because `Δnav == ΔtotalAssets == assets` at hook entry, which requires a non-fee-on-transfer asset.
- The bare `catch` in `_supplyToMorpho` (`src/usd3/USD3.sol:409`) swallows callee out-of-gas as well as reverts, via the 63/64 rule. On the permissionless deposit path a depositor can size transaction gas so the Morpho supply OOGs, the catch fires, and the deposit completes undeployed with a misleading `RebalanceDeferred`. The gas cost falls entirely on that depositor and a later tend deploys the funds; the other callers reach it through `onlyKeepers` entrypoints. Informational, no action needed.
- `_pendingLoss()` (`src/usd3/USD3.sol:181-183`) can be switched off by donating USDC or waUSDC, since `nav()` (`USD3.sol:699-701`) rises while stored `totalAssets` does not. Masking a loss `L` requires donating `L` and unlocks at most `L·j/b` of extra deployment (`j` = junior share of supply, `b` = backing ratio). Where the subordination cap actually binds, `j/b ≤ 1`, so the donation costs at least what it unlocks and is unrecoverable — not an economic attack. Informational, no action needed.

## Operational Preconditions Committed to Auditors

These are commitments made on the record in the Guardian Audits review, where a finding was accepted as residual risk *because* the precondition holds. They are enforced by owner discipline, not by code. Breaking one makes the corresponding code fix a prerequisite, not an option.

**M-02 — LCC return-pool allocation under leverage dispersion.** The return pool is allocated to defaulters by slashed margin while the shortfall consuming it is commitment-driven, so an over-committed defaulter under-pays and the discrepancy lands on a lower-leverage co-defaulter. Accepted without a code fix, conditional on all of:

- Registered facilities use approved non-rebasing USD-denominated yield-bearing stables only. Admitting volatile margin assets requires the code fix first. This is a listing checklist item — `LCCConfigLib` validation accepts any nonzero asset, so nothing in code enforces it.
- Facilities carry a bounded tenor, or justify their dispersion budget without one. A perpetual facility (`maxEpochs = 0`) permits multi-year leverage divergence.
- A per-stake loss budget is evaluated at listing against the pair (max leverage dispersion `r`, max slash-loss fraction `λ`), using the general form `λx(r−1)/(1 + x(r−1))` where `x` is the high-leverage cohort's margin fraction. Do not use the symmetric `λ(r−1)/(r+1)`; it is the `x = ½` case and understates the worst case. Any auction-eligible epoch with zero fills realizes the maximum loss fraction `λ = 1` by construction, because the whole gross pool goes to treasury even if no auction record was opened.
- Revalidation is **change-triggered, not one-time**: any use of `setRiskCaps`, `setMaxAuctionAwardBps`, or `setSlashFeeBps`, and any margin-oracle change, requires re-running the budget before execution. `setMaxAuctionAwardBps` moves the realizable award loss, `setSlashFeeBps` moves the reserved treasury take and return pool, and margin-oracle changes affect both fill caps and re-armed commitment valuation. `setRiskCaps` shifts cohort composition asymmetrically: a lowered `userCommitmentCap` binds only new admissions, while incumbent over-cap exposure persists through rolls and the reopened-M-01 full-share return credit (re-valued at each call-open price), so the high-leverage cohort's margin fraction `x` can drift upward after a cap cut that never touches it, and a lowered `protocolCommitmentCap` changes disposal headroom and can zero auction-eligible return pools. The 24h params timelock makes this enforceable in practice.
- A named owner signs the budget off at listing and at each revalidation.

**M-04 — MorphoCredit fee recipient versus the USD3 ring fence.** USD3 subtracts the ring fence from withdrawal capacity while MorphoCredit grants the fee recipient an independent exception. Accepted without a code fix solely because the MorphoCredit fee is zero and **will not be enabled**. `setFee` is owner-gated; enabling it makes this finding live and it must then be remediated on its merits. Verify the fee is still zero before treating this finding as closed.

**M-04 (round 2) — pending-loss deposit admission and borrow gating: deliberate deviations.** The round-2 M-04 remediation recommended zeroing `availableDepositLimit()` while a loss is pending, and additionally that Morpho prevent new borrowing that would leave deployed exposure above what live junior backing supports. We implemented the `_supplyToMorpho` pending-loss gate but neither of those two:

- **Deposit-limit zeroing: constraint plus choice.** The hard constraint rules out only one placement: `supplyCapExempt` receivers return `type(uint256).max` at `src/usd3/USD3.sol:530` before any later check, so a guard placed *above* that early return would brick `LCCVault.fundCall`'s USD3 deposit (`src/lcc/LCCVault.sol:814`) during a pending loss, converting an accounting delay into missed capital-call obligations and margin slashing. A guard placed *below* the exempt early return (before the cap math at `USD3.sol:534`) would preserve the exemption path and still zero deposits for everyone else. Leaving the non-exempt path open as well was a deliberate decision, not forced by the exemption.
- **Zero-cap LCC funding precondition.** Never set `USD3_SUPPLY_CAP` to zero while an LCC facility has an open call. `availableDepositLimit()` returns zero for a zero cap before its `supplyCapExempt` early return, so exempt receivers are not exempt from the halt; `LCCVault.fundCall` would fail and compelled funders would be slashed.
- **Morpho-side borrow prevention: not implemented.** The residual is that pre-existing over-cap deployment stays borrowable through the pending-loss window, and through the post-unpause window described in the runbook's junior-exit entry.
- **Residual for admitted deposits.** They stay in local waUSDC and cannot reach MorphoCredit until `report()` recognizes the loss. When the junior tranche fully covers the loss, such a depositor is exactly neutral: `totalBurnNeeded = loss·preSupply/preAssets` (`USD3.sol:599`) is independent of the deposit, so post-report PPS is unchanged. When the loss exceeds sUSD3's balance, the burn is capped (`USD3.sol:609-611`) and the remainder socializes across all seniors — including a depositor admitted after the loss materialized, who cannot exit meanwhile because `availableWithdrawLimit` returns zero on the same predicate (`USD3.sol:469`). That excess-loss exposure is what the un-implemented recommendations targeted; it is pre-existing at base `81fff3b8`, not a regression. Note that LCC funders meeting a capital call are **compelled** depositors — declining costs them their margin — so for the exempt path this residual falls on obligated parties rather than on someone who chose to enter at a stale price, and it is structurally unavoidable there: gating the exempt path is the one placement the constraint above rules out.

**M-05 (round 2) — the USD3 ring fence is a cash reservation, not funder attribution.** `ringFencedLiquidity` reserves *pool cash* for the off-chain asset purchases an LCC capital call funds. It deliberately does **not** track the funder: the funder is paid in USD3n at delivery and is an ordinary claimant thereafter, shares are fungible, and the pool owes the origination its cash regardless of which holder's shares back it at any moment. A funder redeeming while the reservation persists is therefore correct behaviour, not a stuck counter. Release is `onlyManagement` (`releaseRingFence`, `src/usd3/USD3.sol:772-775`, which ratchets the counter down) because the triggering event — the purchase settling — is off-chain and not derivable on-chain, including from LCC's own books.

This makes the release an **owner-discipline duty**: management must release once a purchase settles, computing the amount from `RingFencedLiquidityIncreased` events, and must revalidate on any conduit change (`setRingFenceConduit`). Forgetting is silent, and because the accumulator is global rather than per-conduit, a stale reservation haircuts every unrelated depositor's withdrawal capacity. Known imprecision: the funding top-up over-credits the fence by up to `MAX_FUNDING_TOP_UP` (1,000 base units) per funding.

**M-02 / M-03 / M-11 (round 2) — markdown-driven junior misattribution and stale-markdown exit.** Accepted without code fixes:

- Junior principal is **not** restored when a markdown reverses. The mitigation is operational: airdrop USD3 to sUSD3 when an impairment reverses. M-03 (fee-share sizing) is coupled — fixing it alone deepens the misattribution the airdrop must then cover — so both are accepted together.
- M-11's recommended market-wide freshness checkpoint is not achievable as specified; we accept that markdowns must be materialized regularly.
- The **markdown module will not be activated**. This covers M-11 and round-2 M-02 **only**. It does *not* cover round-2 M-04, M-07 or L-13: `CreditLine.settle` (`src/CreditLine.sol:204`) is `onlyOwnerOrOzd` with **no repayment-status gate** and reaches `settleAccount` (`src/MorphoCredit.sol:858`), which writes down `totalSupplyAssets` directly. Settlement therefore keeps the stale-accounting window reachable with the markdown module off, and any claim to the contrary is wrong.

**Runbook footgun — the wiped and non-wiped states need opposite remedies.** `docs/operations-runbook.md`'s first entry directs setting `TRANCHE_SHARE_VARIANT` to `0` so a recovery accrues to seniors. That is correct only when the junior tranche is **wiped**. In round-2 M-02's partial-loss case — sUSD3 absorbed a loss but still holds shares — routing 100% of a cure to seniors is the wrong direction and compounds the misattribution the airdrop exists to correct. The operator must establish which state they are in before applying that remedy.

**Round 3 — A/M-15: retroactive tranche-share repricing is accepted policy, not a defect to fix.** `syncTrancheShare` writes the new share directly into the performance-fee bits and deliberately does **not** report first. `TokenizedStrategy.report()` applies whichever fee is live at execution time to the whole profit interval since the previous report, so the new share is charged against profit earned under the old one — raising it moves already-earned senior yield to sUSD3, lowering it moves already-earned junior yield to seniors.

A checkpointing fix was implemented and then **deliberately reverted**. Do not reintroduce it without an explicit owner decision. The reason is that forcing a report inside a parameter setter couples the tranche-share change to loss recognition and junior-share burning — `_postReportHook` burns sUSD3 shares on any pending loss — so every relayer sync would crystallize P&L on the relayer's schedule rather than the operator's. That coupling was judged a worse footgun than the reprice it prevents.

**This is accepted residual risk with an operational precondition, and must be described that way — never as a complete mitigation.** Two independent reviews were explicit that "report before syncing" is not a full boundary, and the finding itself documents the ordering already reallocating profit twice on mainnet in June 2026 ($7,863 and $31,307 reports, the latter allocating $3,131 at the new rate). The precondition, with the procedure in `docs/operations-runbook.md`:

- The production keeper relayer holds a keeper role and auto-syncs the tranche fee. It must be **halted before a timelocked `TRANCHE_SHARE_VARIANT` change executes**, or it can land the first sync itself with no preceding report. Without this the mitigation is fiction — the operator does not control ordering once the config value is live.
- `report()` and `syncTrancheShare()` must land in **one transaction or multisig batch**, in that order. Same-block is exact for profit visible to USD3 accounting; split across blocks, the interval between them is repriced.
- Two residuals are **not** closed by any ordering discipline and must not be claimed as closed: borrower-local premium materialized after the change (`accruePremiumsForBorrowers`, `src/MorphoCredit.sol:146`, is permissionless and list-driven, so old-period income is reported at the new share), and entry into the favoured tranche during the publicly observable 24h timelock window.

**Consequence for `setPerformanceFee`.** With `syncTrancheShare` uncheckpointed again, the inherited `setPerformanceFee` is no longer a distinct escape hatch — both paths are uncheckpointed. It remains the only route for values it can express (`MAX_FEE = 5000`, i.e. 50%), while `syncTrancheShare` accepts up to 10,000, so shares above 50% are settable only through the sync path.

**Round 3 — A/L-05: `maxAuctionAwardBps` is a pre-deadline control.** The setter is `synced`, and `_syncGlobal` runs before the setter body, so after the funding deadline the setter's own call can finalize the slash, open the auction slot, and then revert `InvalidPhase` against the slot it just created. This was previously documented as a runtime off-switch, which overstated it; the claim has been withdrawn rather than fixed, because the fix costs +142 bytes and LCC has 160 bytes of release margin. Land any change while the epoch is in `Funding` or earlier. Corrected in `src/lcc/LCCVault.sol` and `src/lcc/README.md`.

**Round 3 — the M-02 airdrop mitigation is imprecise, and structurally so.** The operational remedy for a reversed impairment is an airdrop of USD3 to sUSD3. Measured at block 25741635, sUSD3's `performanceFee` is `0` (nothing is skimmed) but `profitMaxUnlockTime` is `259200` (3 days). Three consequences, which bound what the mitigation can claim: the donation is recognized at the next `sUSD3.report()` and unlocks linearly, so a depositor entering during the window captures part of a restoration they never lost; it credits **current** sUSD3 holders pro-rata rather than the holders actually burned, who may have exited; and it raises `asset.balanceOf(sUSD3)`, which clears sUSD3's own withdraw guard, so it should be bundled with the report rather than run alone. It does **not** mask a USD3 pending loss — that needs a USDC/waUSDC donation to USD3 itself. Because the airdrop is untargeted, no sizing formula makes it net the fee-share over-allocation in round-3 `B/H-04`; do not commit to one.

**Round 3 — CCL retirement as a dormancy precondition.** Fourteen round-3 findings are classified dormant because they require a third-party CCL borrower with a drawn line. Chain state at mainnet block 25741635 confirms this: of 76 borrowers ever issued a line on the live market, 75 are at zero, and the sole nonzero line (60,000,000 USDC) belongs to the protocol-owned origination account `0x3ff3ff33d20a086834a095ed6ed562c9e189291b`. The supporting reads are recorded in `audit-round3/onchain-evidence.md` with their pinned block.

**Issuing any third-party credit line re-arms every one of those findings simultaneously.** This is a listing-gate commitment, not a property of the code — nothing prevents `setCreditLine` from being called. Re-read the evidence file before treating any of them as closed.

Two independent grounds happen to coincide for the Cluster A subset (round-3 `A/H-01`, `B/H-05`, `A/M-14`, `B/M-05`): they also need the subordination cap to bind, and `MIN_SUSD3_BACKING_RATIO` is `0`, so `_subordinationDeployCapWaUSDC` (`src/usd3/USD3.sol:196`) returns `type(uint256).max`. Setting that ratio nonzero revives them even with CCL retired. Do not collapse the two grounds into one argument — they fail independently.

**Round 3 — what "markdown is never activated" does and does not cover.** The precondition covers round-3 `B/H-02`, `B/M-04`, `B/M-06`, `B/M-07` and the markdown leg of `B/H-04`. It does **not** cover the settlement-reachable or base-interest paths, because both are live and markdown-independent:

- Settlement is a live NAV-*down* event, reachable with the markdown module off (see the round-2 entry above, which already records why).
- Ordinary base interest is a live NAV-*up* event that mints tranche fee shares with no cash behind them.

Findings reaching through either stay live regardless of markdown or borrower status. Specifically, **`B/M-01`, `A/M-13` and `B/H-03` are not covered by the markdown precondition** and were triaged on their own merits. Do not extend the markdown argument to them.

**`B/M-08` is the case that splits, and it was initially mis-grouped — do not repeat the error.** It is a *withdraw-side* escape in `sUSD3.availableWithdrawLimit`, and its filed route depends on markdown that is due but unmaterialized. `USD3.nav()` cannot see that even in principle: its expected-market preview carries only aggregate base interest, while `totalMarkdownAmount` moves solely on a borrower-specific touch. Two consequences follow. The markdown precondition **does** cover the filed route, alongside `B/M-04` and `B/H-02`. And the deposit-side guard added for `A/M-13` does **not** fix `B/M-08` — claiming so would be a false remediation claim, because the two sit on opposite sides of the vault. What the guard shares with it is only the residual: the settlement analogue is already caught by the existing withdraw-side guard, since settlement decrements `totalSupplyAssets` immediately and therefore does move `nav()`, leaving front-running of the settle transaction as the sole gap — closed operationally by submitting settle + `USD3.report()` + `sUSD3.report()` as one private bundle.

**Round 3 — B/L-01, the settlement-bricking underflow, is dormant on measurement rather than by construction.** `MathLib.wInverseTaylorCompounded` (`src/libraries/MathLib.sol:64-73`) evaluates `firstTerm - secondTerm/2 + thirdTerm/3` left-to-right and panics on underflow once `x > 3·WAD`. Settlement is load-bearing for the whole round-3 disposition strategy, so this was checked rather than assumed. Both call paths are dormant with a wide margin at block 25741635:

- **Premium leg** (`src/MorphoCredit.sol:184`): the protocol account has `premium.rate == 0` and an empty `repaymentObligation`, so `_accrueBorrowerPremium` early-returns at `:318` before reaching the call. Measured ratio `x = 1.000035` against the 3.0 threshold.
- **IRM leg** (`AdaptiveCurveIrm.sol:242,244`): not covered by that early return and on settlement's own `_accrueInterest` path, but `_updateAaveIndices` refreshes the snapshot on every market touch, holding the ratio at ~1.0000.

Two properties of the premium leg must not be forgotten. The measured ratio is a **moving quantity**, not a fixed one — but not for the reason the early return suggests. `_snapshotBorrowerPosition` (`:356-376`) rewrites `borrowAssetsAtLastAccrual` **unconditionally** at `:372` regardless of premium rate, so the snapshot is stale only because nothing has touched the account since 2026-05-13; the doc comment at `:354` claiming otherwise is doc rot. This cuts in our favour: `accruePremiumsForBorrowers` (`:146`) is permissionless and reaches that snapshot via `:159`, so at rate 0 anyone can re-base the ratio to 1.0 without traversing the vulnerable math. Second, the dormancy is **governance-dependent**: setting a premium rate on the protocol account, or posting a repayment obligation, re-arms the leg. Re-verify before any retirement settlement of that account.

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
