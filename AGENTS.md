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

- `src/lcc/LCCVault.sol`: per-facility LCC vault — margin deposits create USDC callable commitments, the owner opens one capital call per epoch, funding routes USDC through USD3 into wrapped USD3 Notification Vault (`USD3l`) shares for funders/fillers, and missed obligations slash margin. Funding may pull up to 1,000 extra USDC base units so dust obligations mint at least one USD3 share, while settlement stays obligation-denominated. Self-funders choose per call whether to amortize with `fundCall(false)` or roll with `fundCall(true)`; rolling pays the obligation while retaining full margin and callable commitment, so exposure re-arms every epoch. Push funding through `fundCall(address)` always amortizes. State progression is lazy (no keeper); `materializeAccount` and `finalizeEpochSlash` are permissionless.
- Heavy rolling keeps `protocolCommitmentCap` utilization pinned because rolled accounts do not decrement active commitment, reducing deposit headroom. Surplus disposal conservatively counts every funded account's call-open commitment as surviving in its call-local base; for an auction-eligible epoch outside wind-down, a current cap at or below that base zeroes the paired return and diverts the recoverable pool to treasury, while any positive commitment clamp preserves it in full. Auction-ineligible disposal, shutdown-truncated disposal, and disposal of the last callable epoch (or later) bypass this protocol-cap clamp and remain bounded by the commitment removed plus packing headroom. Auction eligibility describes the opportunity to fill, whereas the clamp protects future-call capacity. A kicked epoch can become ineligible when shutdown lands mid-window, but `shutdownTruncated` implies `windDown`, so the `!windDown && auctionEligible` clamp condition already excludes it. Deposits cannot influence either bound; owners manage the current cap with `setRiskCaps`, which freezes protocol-cap changes while the auction slot is live.
- `maxEpochs` can schedule a vault sunset: `0` means perpetual, otherwise epochs `0..maxEpochs-1` are callable and epoch `maxEpochs` starts a terminal withdraw-only phase. `claimRemainingMargin` is the wind-down claim for shutdown or terminal sunset, while `claimExitedMargin` remains the normal maturity-gated exit claim. `minCommitmentEpochs` (immutable, up to 64, 0 disables) gates `requestExit` from the later of the latest deposit activation and one epoch after the call that produced the latest nonzero return credit; the wind-down claim bypasses it.
- Slashed margin backs a step-decay shortfall auction during the epoch's `Closed` phase (pricing math in the externally linked `src/lcc/libraries/LCCAuctionLib.sol`); the award curve reserves the configured treasury take, fills use the live oracle to cap `marginAwarded`, and completed settlement charges `slashFeeBps` on the greater of cumulative awards and cumulative fills' pro-rata first-step offer. Every auction-eligible epoch receives completed treatment after its full window, even if nobody touched the vault to open a record: zero fills send the whole gross pool to treasury. A shutdown strictly before `closedEnd` genuinely truncates the opportunity and returns the unawarded pool without a take; zero shortfall and disabled config are likewise non-eligible. The remaining return pool is converted to commitment at the validated nonzero price snapshotted at call open, so the conversion price is frozen but the amount converted is not. A missing snapshot is corruption/future-writer recovery: the live fallback is owner-gated. Price-failure tolerance is separate from the epoch-anchored cap exemption, and neither predicate contains the other: actual shutdown or terminal state sets tolerance, while the protocol-cap exemption uses `shutdownTruncated || lastCallableEpoch`. In particular, the last callable epoch disposed during its own Closed phase before terminal is cap-exempt but still price-intolerant; on a corrupt zero snapshot it re-bricks for a non-owner until terminal begins one epoch later. To preserve rather than sweep a missing-snapshot pool when the live oracle is also dead, the owner must call `setMarginOracle` first and then send any `synced` call; `shutdown()` alone is non-bricking but is not recovery. The unconditional overflow guard is an oracle-corruption sweep, not a dead branch. Call opening only rejects a zero price and stores the price and `marginAtCallOpen`; it never multiplies them or proves that the snapshot can value the margin without overflow. Even a full-`uint128` pool needs a selected price around `3.4e70` at the minimum valid margin ratio — roughly 34 orders of magnitude above an honest `ORACLE_PRICE_SCALE`-scaled price — so the guard is unreachable under the trusted-oracle assumption. On corrupt state, un-gating it trades a permanent brick of every `synced` entrypoint for a confiscating sweep of the whole selected pool, with the same `SlashSurplusDisposed(epoch, all, 0, 0)` shape as a legitimate zero-return disposal. Future changes must keep the guard after price selection, keep the subsequent `price == 0` sweep, and must not treat either as dead code.
- LCC deployment topology: `LCCAuctionLib`, `LCCConfigLib`, and `LCCExitLib` are externally linked into a shared `LCCVault` implementation, an `UpgradeableBeacon` owned by 3Jane's existing 7-day timelock points at that implementation, and `LCCVaultFactory` deploys per-facility `BeaconProxy` instances with atomic initializer calldata. The implementation constructor fixes protocol-wide `notificationVault`, `usd3`, `fundingAsset`, and `treasury`; per-facility params live in proxy storage.
- `src/lcc/LCCVaultFactory.sol`: non-upgradeable family authority, admission registry, and `BeaconProxy` deployer. Its deliberately unheld `DEFAULT_ADMIN_ROLE` makes two-step `transferOwnership`/`acceptOwnership` the sole `OWNER_ROLE` mutation path, and owner-role renunciation is blocked. `OWNER_ROLE` administers `LISTER_ROLE`, `BOUNCER_ROLE`, and `GUARDIAN_ROLE`. Whitelist and prospective one-open-vault enforcement are independently owner-disableable; disabling the latter preserves warm `vaultOf` recording but makes no exclusivity claim. The optional admissions module is a narrow static decision hook; registry writes remain in the factory. The beacon is public, but non-factory proxies are unsupported and cannot pass the factory deposit gate.
- **Factory authority-view rule.** `isOwner`, `isGuardian`, and `requireBouncer` must remain `external view` functions that read only the non-upgradeable factory's local AccessControl role storage. They must never call the admissions module or another external contract and must never loop. These STATICCALL-safe reads are the sole vault authority source and are live on emergency and settlement paths.
- **LCC registry invariants.** `finalizedCallPrefix` must advance in the same transaction that writes `slashFinalized`; `isAccountClosed` is upgrade-frozen as `bounded replay complete && zero exposure`; and the vault's captured `factory` is written exactly once in `initialize` and must never acquire a setter. `initialize` must not call an `isVault`-gated factory function because factory registration happens only after proxy construction returns. Matured exit exposure remains open until `claimExitedMargin` clears it; an incomplete bounded replay conservatively reports open. Admission checks only the vault currently named by `vaultOf` and never scans the unbounded family list. Deliberate owner-accepted residual: a user who opened A then B while `oneVaultPolicyEnabled` was off can retain an open position in A while `vaultOf` names B; after re-enabling, closing and reopening B passes the named-vault check and restores two open positions. This is bounded to users grandfathered by a policy-off window, is unreachable for a user whose entire history is under an enabled policy, and is accepted as the same prospective-only carve-out rather than placing an unbounded loop of external bounded-replay calls on every deposit. Operators must reconcile multi-vault users offchain before re-enabling the policy.
- Vaults must be on USD3's `supplyCapExempt` list for funding/fill deposits to bypass supply-cap headroom and first-time minimum deposits.
- The LCC module is Cancun-only and pinned to solc `0.8.35`; `LCCVault.sol` uses scoped `optimizer_runs = 150` (24,144 runtime bytes after exit-accounting extraction; 132 bytes below the 24,276-byte release ceiling; 432 bytes of EIP-170 headroom) while the factory compiles at the repo default. The active-only monolith measured 24,703 bytes, 127 bytes over EIP-170, so `LCCExitLib` remains required. The vault uses `ReentrancyGuardTransient`, so every deployment chain must support EIP-1153. Forge produces the sole canonical deployment artifact with a constructor-time code check on the linked `LCCExitLib`; Hardhat uses a pinned stable solc-js `0.8.35` for its compile/test-only Cancun output. USD3 remains Shanghai and compiles at the repo-default optimizer runs, while the frozen `USD3_old` upgrade-test artifact stays pinned at `optimizer_runs = 200`.
- Pending-activation and exit-maturity bucket pairs are stored as packed `LCCTypesLib.Bucket` words; the four original `uint256` view getters remain the stable external ABI. Per-call exit exposure packs six `uint128` amounts into three words and retains an explicit fourth-word `listed` guard for exact-once maturity-list membership.
- Auction state packs `shortfallAmount`, `filledAmount`, `marginPool`, and `marginAwarded` into two words. `getAuctionState` remains wire-compatible, and auction-fill accounting is performed by the externally linked `LCCAuctionLib`.
- LCC upgrade safety: the beacon owner can replace logic under every beacon-backed vault after the 7-day timelock. The v2 fresh-family layout starts with `_clockConfig` at slot 0, stores the captured `factory` at slot 29, uses no persistent reentrancy slot, and retains a 49-slot `__gap` beginning at slot 30. After deployment, never reorder storage variables or base contracts; append new state by consuming `__gap`; treat `LCCTypesLib` packed structs and `isAccountClosed` semantics as upgrade-frozen; keep `_disableInitializers()` in implementation constructors; re-link `LCCAuctionLib`, `LCCConfigLib`, and `LCCExitLib` on implementation redeploys. `LCCExitLib` anchors at `exitBucketByMaturity` and derives the following four exit-storage roots, so that five-root adjacency is upgrade-frozen even though extraction adds no library storage and leaves the layout baseline unchanged. Its packed-`uint256` call ABI silently narrows amount halves to `uint128` at the boundary where the prior in-contract `SafeCast` would have reverted. The `uint128`-representability bound is upgrade-frozen: every packed amount must continue to originate in `uint128` storage and only decrease before the call, or a future writer must restore explicit checked casts. Every future implementation must preserve the property that runtime exit capacity is at least one, or normalize existing configurations during the upgrade. Every implementation that sets `callOpened` to true must write a validated nonzero `marginPriceAtCallOpen` snapshot for that epoch in the same transaction; otherwise a missing price blocks non-owner going-concern disposal. Return-pool replay credits each defaulter its full paired share with no per-user cap bound (deliberately reopened M-01), keeping global totals equal to the sum of per-account commitments up to the pair-drop residual (flooring dust per epoch, except when the conversion pins at `MIN_RETURN_COMMITMENT`, where it scales with the dropped margin). A nonzero return credit anchors `commitmentStartEpoch` at the later of its existing value and the disposed call's epoch plus one, the deterministic first epoch in which that exposure can back a new call.
- **Settlement-input freezing (upgrade rule).** Every input to `_finalizeEpochSlash`, `_settleAuction`, `_disposeSlashSurplus`, `LCCAuctionLib.disposeValuation`, and `_settlementReturnPool` must be classified before merge. The normal permitted classes are frozen for the disposed epoch or read only from a `synced` + slot-guarded setter. The `synced` coupling is a general argument, not a per-setter coincidence: `_syncGlobal` finalizes every slash-eligible epoch, in ascending `calledEpochList` order with `_slashEligible` monotone in effective time, before the setter's storage write, so no config change can interleave between an epoch becoming disposable and its disposal. The sole deferral channel is the auction slot, which is why `setRiskCaps`, `setMaxAuctionAwardBps`, and `setSlashFeeBps` each carry a `pendingAuctionEpochPlusOne` guard; the `setRiskCaps` guard covers protocol-cap raises as well as reductions. `_shutdown` is the explicit owner-only exception: it is frozen against permissionless timing and against post-window shutdown by the strict `timestamp < closedEnd(epoch)` comparison, but remains a live owner-side discriminator between the funding deadline and the Closed end. If epoch E is untouched, shutdown anywhere in `[fundingDeadline(E), closedEnd(E))` makes `_finalizeEpochSlash` skip the kick and dispose it as ineligible; if E has already kicked and is partially filled, shutdown in the same interval settles it immediately as ineligible. Normal window-end settlement instead charges the take and sends the unfilled gross share to treasury under the cap clamp. The delta is the whole unfilled gross share plus reserved fee, moved from treasury to defaulters. `shutdown()` deliberately has no pending-auction guard; owner-only authority prevents a permissionless front-run. Live price-failure tolerance (valuation bit 17) is inert on legitimately reachable disposal: `openEpochCall` stores a nonzero snapshot for every epoch it marks `callOpened`, both remaining bit-17 effects are gated by `price == 0`, and the overflow guard no longer reads bit 17. The bit is also monotone because `_shutdown.active` and `_terminal()` are one-way and `_now()` never rewinds across pause/unpause. The residual on a zero snapshot must be recorded, not generalized away: before terminal a non-owner reverts and preserves the pool for owner recovery; after terminal flips by clock alone, the first non-owner touch has bit 16 clear, skips fallback, and irreversibly sweeps the pool, while an owner touch at the same timestamp has bit 16 set, may read a healthy live oracle, and may credit defaulters. This first-toucher allocation difference is unreachable through shipped writers but is real under storage corruption or an upgrade that violates the snapshot rule. Valuation bit 16 now reads `factory.isOwner(msg.sender)`: the predicate code is frozen at non-upgradeable factory deployment, while role membership remains a live, family-wide settlement input. Because this is membership rather than address equality, the factory's single-owner invariant is a settlement-correctness dependency. Do not rotate factory ownership while any family vault has a pending auction slot with a missing price snapshot; both oracle recovery and the owner-triggered synced disposal must remain under one owner through recovery. `_pause` is also live and controlled family-wide by factory `GUARDIAN_ROLE` or `OWNER_ROLE` because it feeds `_now()`, hence `_terminal()` and `shutdownTruncated`; it is safe because `_sync()` reverts while paused, so no disposal runs, and `_endPause()` preserves effective time so `_now()` never rewinds. Price-failure tolerance and cap exemption are separate, non-nesting predicates: the last callable epoch in its own Closed phase before terminal has `windDown && !toleratePriceFailure`. `_clockConfig`, `_assetConfig.marginRatioBps`, and `_auctionConfig.auctionStepDecayRateBps` are frozen because they have no setter. Adding a setter for one requires the same treatment, and for `auctionStepDecayRateBps` would also break the `offered1` reconstruction at settlement, which must reprice the curve the fills paid against. `setMarginOracle` is deliberately un-`synced`; that is safe only while `marginPriceAtCallOpen` is guaranteed nonzero for every opened call. The captured `factory` is another frozen input and sole authority source; it must never gain a setter. Two live `_totals` reads are retained and provably inert by conservation — the slash decrements the same amounts before disposal, so the packing clamp can never bind — and are not precedent for reading live aggregates.
- **Settlement determinism (design rule).** LCC settlement prefers determinism over case-by-case optimality. The return-credit anchor derives from the disposed call's epoch rather than settlement time, accepting that settlement after `PreCall` in a dormant vault can let one defaulter exit with re-credited commitment that backed no call. That exception is bounded to one epoch of one defaulter's credit, and dormancy is forced because `_requireNoPriorUnsettledCall` blocks every later call while the prior call remains unsettled. The protocol-cap clamp likewise remains applicable after a post-window shutdown even though no future call can use the reserved capacity, accepting that a saturated cap can send recoverable defaulter margin to treasury in exchange for an outcome independent of who settles first. Determinism and post-credit freshness are mutually exclusive under permissionless lazy settlement; the tempting local fix to read current state because it looks more accurate is exactly what this rule forbids.
- Caller-side auction bounds make fills more likely to revert, so auctions stay live longer in expectation. That is safe only because commit `1e4a2761` first removed the live-auction replay barrier and the earlier price-snapshot work froze return-pool valuation at call open, so shifting settlement from mid-window to window-end cannot change the disposal price. Any future implementation that reintroduces a global replay barrier on live auctions, or unfreezes disposal valuation, must revisit these bounds. `yarn build:forge:size` resolves the canonical full-settings build artifact, recursively compares its embedded storage layout with the versioned, reviewer-controlled `docs/lcc-vault-storage-layout.json`, and checks the external ABI; the checker never regenerates either baseline.
- The EpochState/RiskConfig storage repack is policy-deferred — see `docs/lcc-deferred-epochstate-repack.md` for the measured record. Re-measure variant sizes against the current artifact before re-opening; the underlying analysis does not need redoing.
- Design notes: `docs/architecture.md` (LCC Domain section).

Targeted local command for LCC changes:

- `yarn run test:forge --match-path 'test/forge/lcc/**/*.t.sol' -vvv`

## Operational Preconditions Committed to Auditors

These are commitments made on the record in the Guardian Audits review, where a finding was accepted as residual risk *because* the precondition holds. They are enforced by owner discipline, not by code. Breaking one makes the corresponding code fix a prerequisite, not an option.

**M-02 — LCC return-pool allocation under leverage dispersion.** The return pool is allocated to defaulters by slashed margin while the shortfall consuming it is commitment-driven, so an over-committed defaulter under-pays and the discrepancy lands on a lower-leverage co-defaulter. Accepted without a code fix, conditional on all of:

- Registered facilities use approved non-rebasing USD-denominated yield-bearing stables only. Admitting volatile margin assets requires the code fix first. This is a listing checklist item — `LCCConfigLib` validation accepts any nonzero asset, so nothing in code enforces it.
- Facilities carry a bounded tenor, or justify their dispersion budget without one. A perpetual facility (`maxEpochs = 0`) permits multi-year leverage divergence.
- A per-stake loss budget is evaluated at listing against the pair (max leverage dispersion `r`, max slash-loss fraction `λ`), using the general form `λx(r−1)/(1 + x(r−1))` where `x` is the high-leverage cohort's margin fraction. Do not use the symmetric `λ(r−1)/(r+1)`; it is the `x = ½` case and understates the worst case. Any auction-eligible epoch with zero fills realizes the maximum loss fraction `λ = 1` by construction, because the whole gross pool goes to treasury even if no auction record was opened.
- Revalidation is **change-triggered, not one-time**: any use of `setRiskCaps`, `setMaxAuctionAwardBps`, or `setSlashFeeBps`, and any margin-oracle change, requires re-running the budget before execution. `setMaxAuctionAwardBps` moves the realizable award loss, `setSlashFeeBps` moves the reserved treasury take and return pool, and margin-oracle changes affect both fill caps and re-armed commitment valuation. `setRiskCaps` shifts cohort composition asymmetrically: a lowered `userCommitmentCap` binds only new admissions, while incumbent over-cap exposure persists through rolls and the reopened-M-01 full-share return credit (re-valued at each call-open price), so the high-leverage cohort's margin fraction `x` can drift upward after a cap cut that never touches it, and a lowered `protocolCommitmentCap` changes disposal headroom and can zero auction-eligible return pools. The 24h params timelock makes this enforceable in practice.
- A named owner signs the budget off at listing and at each revalidation.

**M-04 — MorphoCredit fee recipient versus the USD3 ring fence.** USD3 subtracts the ring fence from withdrawal capacity while MorphoCredit grants the fee recipient an independent exception. Accepted without a code fix solely because the MorphoCredit fee is zero and **will not be enabled**. `setFee` is owner-gated; enabling it makes this finding live and it must then be remediated on its merits. Verify the fee is still zero before treating this finding as closed.

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
