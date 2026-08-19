// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {LCCAuctionLib} from "../libraries/LCCAuctionLib.sol";

/// @title ILCCVault
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Interface for the LCC vault: a per-facility callable-credit primitive (not
/// ERC-4626, no transferable shares). Depositors post one ERC20 `marginAsset` as a performance bond; the vault
/// values it through a trusted Morpho-style oracle and leverages it by `marginRatioBps` into a commitment
/// denominated in `fundingAsset`. The owner opens at most one capital call per epoch; called users fund their
/// pro-rata obligation all-or-nothing (the funding is delivered as wrapped USD3l) and get the backing margin
/// released proportionally. Unfunded obligations are slashed after the funding deadline, and the resulting
/// shortfall is offered through an epoch-shortfall Dutch auction.
/// @dev Unit convention: amount-like accounting values outside the margin family are denominated in `fundingAsset`
/// unless documented otherwise; margin amounts are in `marginAsset`; `marginValue` is margin valued in
/// `fundingAsset`; epoch fields are epoch indices; `*Bps` fields are basis points (out of 10_000). Events and
/// errors are exposed through `LCCEventsLib` and `LCCErrorsLib`. Settlement consumers read `AuctionSettled` for
/// fill totals and `SlashSurplusDisposed` for the disposal split. Scheduled sunset is modeled by `maxEpochs`: when
/// nonzero, epochs `0..maxEpochs-1` are callable and epoch `maxEpochs` starts a terminal withdraw-only phase.
/// Oracle-tolerant wind-down surplus disposal applies to shutdown-truncated epochs and the last callable epoch (or
/// later); older epochs retain going-concern terms even when first disposed during shutdown or terminal. Accounts
/// lagging more than 64 finalized calls may need permissionless `materializeAccount` batches before
/// `claimRemainingMargin` can complete. LCC vaults are deployed as BeaconProxy instances behind an UpgradeableBeacon
/// controlled by 3Jane's 7-day timelock; the beacon owner can replace logic for every beacon-backed vault after the
/// timelock delay.
/// Factory registry membership records owner-vetted provenance, not exclusive deployability: non-factory proxies can
/// point at the public beacon and remain unregistered.
interface ILCCVault {
    /// @notice Thrown when whitelist enforcement rejects a depositor.
    error NotWhitelistedDepositor();
    /// @notice Thrown when a depositor still has exposure in another family vault.
    error RegisteredElsewhere(address vault);
    /// @notice Thrown when an exit request would create more tracked maturity buckets than the vault supports.
    error ExitCapacityReached();
    /// @notice Thrown when an exit cannot be assigned within the caller's maximum accepted deferral.
    error ExitDeferralExceeded();

    /// @notice Timestamp-derived lifecycle phase within an epoch.
    /// @dev `Normal`: deposits activate immediately (until a call opens). `PreCall`: the owner may open the epoch
    /// call. `Funding`: called users fund their obligations. `Closed`: funding deadline passed; slashing and the
    /// shortfall auction occur.
    enum Phase {
        Normal,
        PreCall,
        Funding,
        Closed
    }

    /// @notice Facility configuration consumed by the initializer.
    /// @param marginAsset ERC20 posted as the performance bond. Must be standard (no fee-on-transfer / rebasing).
    /// @param marginOracle Trusted oracle returning the margin-to-fundingAsset price scaled by ORACLE_PRICE_SCALE.
    /// @param startTimestamp Epoch-zero start; the epoch clock is derived from this. Bounded to uint64.
    /// @param maxEpochs Maximum callable epochs; 0 means perpetual. Bounded to uint64.
    /// @param epochLength Total epoch duration in seconds (Normal + PreCall + Funding + Closed). Bounded to uint32.
    /// @param normalDuration Seconds of the Normal phase. Bounded to uint32.
    /// @param preCallDuration Seconds of the PreCall phase. Bounded to uint32.
    /// @param fundingDuration Seconds of the Funding phase. Bounded to uint32.
    /// @param marginRatioBps Leverage ratio in bps: commitment = marginValue * BPS / marginRatioBps.
    /// @param protocolCommitmentCap Vault-wide cap on active+pending commitment (fundingAsset). The exit-capacity
    /// denominator is the greater of this cap and aggregate live `activeCommitment`. Bounded by type(uint128).max.
    /// @param userCommitmentCap Per-account cap on active+pending commitment (fundingAsset).
    /// @param exitCapBps Per-epoch exit capacity as a fraction of the exit-capacity denominator, in bps; must satisfy
    /// `exitCapBps * 64 >= 2 * BPS` (>= 313) and `<= BPS`.
    /// @param exitDelayEpochs Minimum epochs between a Normal-phase exit request and its earliest maturity; requests
    /// after Normal add one epoch to preserve prospective call exposure while another call can still open. At most 64.
    /// @param minCommitmentEpochs Minimum epochs an account must be committed (counted from commitmentStartEpoch,
    /// the later of its latest deposit activation and one epoch after the call that produced its latest nonzero
    /// return-pool re-credit) before it can request an exit; at most 64, 0 disables the gate. Composed lockup: the
    /// earliest exit request is commitmentStartEpoch + minCommitmentEpochs and the earliest maturity adds
    /// exitDelayEpochs. Wind-down claims (shutdown or terminal) bypass the gate.
    /// @param minDepositAssets Minimum margin deposit, in marginAsset units.
    /// @param auctionStepCount Divisor used to derive the Closed-window step duration; 0 disables the auction
    /// entirely, otherwise must be at least 2. Because the duration is floor-rounded and the live step index is
    /// uncapped, a remainder can make live steps reach or exceed this configured count. Bounded to uint32, and its
    /// derived step duration is also bounded to uint32.
    /// @param auctionStepDecayRateBps Per-step decay of the protocol's retained pool share, in bps.
    /// @param maxAuctionAwardBps Oracle-valued collateral award cap per fundingAsset filled, in bps; 0 disables.
    /// @param slashFeeBps Fee on auction-awarded slashed margin, clamped to the unawarded surplus, in bps.
    struct VaultParams {
        address marginAsset;
        address marginOracle;
        uint256 startTimestamp;
        uint256 maxEpochs;
        uint256 epochLength;
        uint256 normalDuration;
        uint256 preCallDuration;
        uint256 fundingDuration;
        uint256 marginRatioBps;
        uint256 protocolCommitmentCap;
        uint256 userCommitmentCap;
        uint256 exitCapBps;
        uint256 exitDelayEpochs;
        uint256 minCommitmentEpochs;
        uint256 minDepositAssets;
        uint256 auctionStepCount;
        uint256 auctionStepDecayRateBps;
        uint256 maxAuctionAwardBps;
        uint256 slashFeeBps;
    }

    /// @notice Initializes a beacon proxy vault with per-facility configuration.
    /// @param params The facility configuration.
    function initialize(VaultParams calldata params) external;

    /// @notice Immutable asset and integration addresses for this vault.
    /// @param marginAsset ERC20 posted as the performance bond.
    /// @param fundingAsset ERC20 used to fund calls and auction fills.
    /// @param usd3 ERC-4626 USD3 vault.
    /// @param notificationVault ERC-4626 wrapper that receives funded amounts.
    /// @param marginOracle Trusted oracle for margin-to-fundingAsset pricing.
    /// @param treasury Recipient of slashed margin and unsold auction collateral.
    struct AssetConfig {
        address marginAsset;
        address fundingAsset;
        address usd3;
        address notificationVault;
        address marginOracle;
        address treasury;
    }

    /// @notice Immutable epoch timing and commitment derivation configuration.
    /// @param startTimestamp Epoch-zero start timestamp.
    /// @param maxEpochs Maximum callable epochs; 0 means perpetual.
    /// @param epochLength Total epoch duration in seconds.
    /// @param normalDuration Seconds of the Normal phase.
    /// @param preCallDuration Seconds of the PreCall phase.
    /// @param fundingDuration Seconds of the Funding phase.
    /// @param marginRatioBps Leverage ratio in bps.
    /// @param exitDelayEpochs Minimum epochs between exit request and earliest maturity.
    /// @param minCommitmentEpochs Minimum epochs since commitmentStartEpoch (the later of the latest deposit
    /// activation and one epoch after the call that produced the latest nonzero return-pool re-credit) before an
    /// exit request; 0 disables the gate.
    struct EpochConfig {
        uint256 startTimestamp;
        uint256 maxEpochs;
        uint256 epochLength;
        uint256 normalDuration;
        uint256 preCallDuration;
        uint256 fundingDuration;
        uint256 marginRatioBps;
        uint256 exitDelayEpochs;
        uint256 minCommitmentEpochs;
    }

    /// @notice Immutable auction timing and decay configuration.
    /// @param auctionStepCount Configured divisor used to derive the Closed-window step duration; the live index is
    /// uncapped and can exceed this value when the division has a remainder.
    /// @param auctionStepDecayRateBps Per-step retained-pool decay, in bps.
    /// @param auctionStepDuration Derived duration of each auction price step, in seconds.
    struct AuctionConfig {
        uint256 auctionStepCount;
        uint256 auctionStepDecayRateBps;
        uint256 auctionStepDuration;
    }

    /// @notice Mutable risk limits used by deposits, exits, and auction awards.
    /// @param protocolCommitmentCap Vault-wide cap on active+pending commitment; exit capacity uses the greater of
    /// this configured cap and aggregate live `activeCommitment`.
    /// @param userCommitmentCap Per-account cap on active+pending commitment.
    /// @param exitCapBps Per-epoch exit capacity fraction of the configured-cap/live-utilization denominator, in bps.
    /// @param minDepositAssets Minimum margin deposit.
    /// @param maxAuctionAwardBps Oracle-valued auction award cap per fundingAsset filled, in bps.
    /// @param slashFeeBps Fee on auction-awarded slashed margin, clamped to the unawarded surplus, in bps.
    struct RiskConfig {
        uint256 protocolCommitmentCap;
        uint256 userCommitmentCap;
        uint256 exitCapBps;
        uint256 minDepositAssets;
        uint256 maxAuctionAwardBps;
        uint256 slashFeeBps;
    }

    /// @notice Packed aggregate margin/commitment totals.
    /// @dev Commitment totals are cap-bounded by `protocolCommitmentCap <= type(uint128).max`; margin totals rely on
    /// the aggregate deployment invariant documented on the vault and fail safely via SafeCast if exceeded.
    /// @param activeMargin Total active margin across all accounts (marginAsset).
    /// @param activeCommitment Total active commitment across all accounts (fundingAsset).
    /// @param pendingMargin Total pending margin across all accounts (marginAsset).
    /// @param pendingCommitment Total pending commitment across all accounts (fundingAsset).
    struct Totals {
        uint128 activeMargin;
        uint128 activeCommitment;
        uint128 pendingMargin;
        uint128 pendingCommitment;
    }

    /// @notice Packed global sync cursors and live-auction slot.
    /// @param lastActivationFolded Highest epoch whose pending activations have been folded.
    /// @param lastMaturityFolded Highest epoch whose maturity buckets have been folded.
    /// @param finalizedCallPrefix Count of leading called epochs whose slash is finalized.
    /// @param pendingAuctionEpochPlusOne Live-auction slot encoded as epoch + 1 (0 means none).
    struct SyncState {
        uint64 lastActivationFolded;
        uint64 lastMaturityFolded;
        uint64 finalizedCallPrefix;
        uint64 pendingAuctionEpochPlusOne;
    }

    /// @notice Packed emergency shutdown state.
    /// @param active Whether shutdown has been triggered.
    /// @param timestamp Pause-adjusted effective timestamp at which shutdown was triggered (0 if not shut down).
    /// @param epoch Epoch in which shutdown was triggered (0 if not shut down).
    struct ShutdownState {
        bool active;
        uint64 timestamp;
        uint64 epoch;
    }

    /// @notice Materialized per-account position (the in-memory shape returned by views; storage is packed).
    /// @param activeMargin Margin currently callable (marginAsset).
    /// @param activeCommitment Commitment backed by `activeMargin` (fundingAsset).
    /// @param pendingMargin Margin deposited but not yet activated (marginAsset).
    /// @param pendingCommitment Commitment of the pending margin (fundingAsset).
    /// @param pendingActivationEpoch Epoch at which the pending balance activates (0 if none).
    /// @param calledEpochCursor Replay cursor: index into `calledEpochs` up to which this account is materialized.
    /// @param claimableExitMargin Matured exit margin awaiting claim (marginAsset).
    /// @param exitBucketMargin This account's margin contribution to its maturity bucket (marginAsset).
    /// @param exitBucketCommitment This account's commitment contribution to its maturity bucket (fundingAsset).
    /// @param exitRequested True once a full-account exit has been requested.
    /// @param exitMaturityEpoch Epoch at which the requested exit matures (callable until then).
    /// @param exitClaimed True once the exit has completed or been cleared.
    /// @param exitMatured True once the exit has matured (margin moved to `claimableExitMargin`).
    /// @param commitmentStartEpoch Later of the account's latest deposit activation epoch and one epoch after the
    /// call that produced its latest nonzero return-pool re-credit. The latter is the first epoch in which the
    /// re-credited exposure can back a new call, so settlement delay cannot extend the minCommitmentEpochs gate.
    /// Funding never changes it.
    struct Account {
        uint256 activeMargin;
        uint256 activeCommitment;
        uint256 pendingMargin;
        uint256 pendingCommitment;
        uint256 pendingActivationEpoch;
        uint256 calledEpochCursor;
        uint256 claimableExitMargin;
        uint256 exitBucketMargin;
        uint256 exitBucketCommitment;
        bool exitRequested;
        uint256 exitMaturityEpoch;
        bool exitClaimed;
        bool exitMatured;
        uint256 commitmentStartEpoch;
    }

    /// @notice Per-epoch capital-call accounting, finalized lazily after the funding deadline.
    /// @param callOpened True once the owner has opened this epoch's call.
    /// @param commitmentDenominator Total active commitment snapshotted at call open; the pro-rata base for
    /// obligations (fundingAsset).
    /// @param callAmount Total amount called this epoch (fundingAsset). This is the nominal base for independently
    /// computed pro-rata obligations, not a strict aggregate funding cap: because each obligation is ceil-rounded,
    /// `fundedAmount` can settle slightly above `callAmount`.
    /// @param marginAtCallOpen Total active margin snapshotted at call open (marginAsset).
    /// @param fundedAmount Cumulative funded obligations this epoch (fundingAsset). May exceed `callAmount` by up to
    /// ~(number of funding accounts - 1) units of rounding dust from per-account ceil obligations.
    /// @param marginReleased Cumulative margin released to funders this epoch (marginAsset).
    /// @param fundedUsersRemainingMargin Margin of fully-funded users retained for settlement after this call
    /// (marginAsset).
    /// @param fundedUsersRemainingCommitment Settlement counter for fully-funded users' commitment net of funded
    /// obligations, not a live-position aggregate (fundingAsset).
    /// @param slashFinalized True once slashing for this epoch has been finalized.
    /// @param slashDisabledByShutdown True if shutdown landed before/within this epoch's funding window, so no
    /// slash is taken.
    /// @param slashedMargin Aggregate margin slashed for this epoch (marginAsset).
    /// @param returnPool Slashed surplus returned to defaulters after the treasury fee and aggregate-margin packing
    /// clamp. Retained in full when backed by nonzero settlement commitment (marginAsset).
    /// @param returnCommitment Callable commitment paired with `returnPool`, bounded by the call-local slashed
    /// commitment and, during going concern, current protocol-cap headroom over funded call-open exposure
    /// (fundingAsset).
    struct EpochState {
        bool callOpened;
        uint256 commitmentDenominator;
        uint256 callAmount;
        uint256 marginAtCallOpen;
        uint256 fundedAmount;
        uint256 marginReleased;
        uint256 fundedUsersRemainingMargin;
        uint256 fundedUsersRemainingCommitment;
        bool slashFinalized;
        bool slashDisabledByShutdown;
        uint256 slashedMargin;
        uint256 returnPool;
        uint256 returnCommitment;
    }

    /// @notice Current epoch index derived from the pause-adjusted effective timestamp.
    /// @return The current epoch.
    function currentEpoch() external view returns (uint256);
    /// @notice Current lifecycle phase derived from the pause-adjusted effective timestamp.
    /// @return The current phase.
    function currentPhase() external view returns (Phase);
    /// @notice Wall-clock timestamp at which a given phase ends within a given epoch.
    /// @dev Projects the effective-time boundary using the pause offset accumulated when queried. It is exact for
    /// current and future boundaries while unpaused, but a boundary already in the past shifts if a later pause adds
    /// to the offset. While paused, it assumes the vault is unpaused at the current wall-clock timestamp.
    /// @param epoch Epoch to query.
    /// @param phase Phase whose end is requested.
    /// @return The wall-clock phase-end timestamp.
    function phaseEndsAt(uint256 epoch, Phase phase) external view returns (uint256);
    /// @notice Current pause circuit-breaker state.
    /// @return paused Whether synced state-transitioning entrypoints are paused.
    /// @return pausedAt Wall-clock timestamp at which the current pause began, or the previous pause began if unpaused.
    /// @return pausedAccumulated Total wall-clock seconds subtracted from lifecycle time by completed pauses.
    function pauseState() external view returns (bool paused, uint64 pausedAt, uint64 pausedAccumulated);
    /// @notice Reports whether an account is permanently clear of exposure for family-registry migration.
    /// @dev Replay is intentionally bounded. An incomplete replay conservatively reports not closed so a mandatory
    /// deposit authorization path cannot become unbounded; anyone may materialize the account in batches first.
    /// @param user Account whose stored and replayable exposure is inspected.
    /// @return True only when bounded replay completes and leaves no active, pending, exiting, or claimable exposure.
    function isAccountClosed(address user) external view returns (bool);
    /// @notice Deposits caller-funded margin for a beneficiary, creating a bounded leveraged commitment.
    /// @dev Pulls `assets` of marginAsset from the caller and irrevocably credits `onBehalfOf`. Self-deposits require
    /// no deposit-operator role; a distinct payer must hold the factory's DEPOSIT_OPERATOR_ROLE. The final factory
    /// authorization is deliberately fail-late and atomic, so a rejection unwinds the token pull and all state. A
    /// successful deposit can extend the beneficiary's commitment lockup and consume their cap. It activates
    /// immediately during Normal (before a call opens), otherwise stages as pending for the next epoch when permitted.
    /// Deposits remain available during PreCall and while an opened call is unsettled, but are unavailable while an
    /// auction is live. Reverts under shutdown, when activation would reach scheduled sunset, on a pending-blocking
    /// exit, on an expired wall-clock deadline, on invalid commitment bounds, on a zero/sub-minimum amount, on a zero
    /// beneficiary, on a zero oracle price, or if a cap would be exceeded.
    /// @param assets Margin to deposit (marginAsset).
    /// @param onBehalfOf Beneficiary whose margin and commitment account is credited.
    /// @param minCommitment Minimum acceptable commitment, inclusive and nonzero.
    /// @param maxCommitment Maximum acceptable commitment, inclusive.
    /// @param allowPendingActivation Whether the deposit may be staged for the next epoch.
    /// @param deadline Wall-clock timestamp after which the deposit reverts.
    /// @return commitment Commitment created (fundingAsset).
    function deposit(
        uint256 assets,
        address onBehalfOf,
        uint256 minCommitment,
        uint256 maxCommitment,
        bool allowPendingActivation,
        uint256 deadline
    ) external returns (uint256 commitment);
    /// @notice Requests a full-account exit within caller-supplied maturity-deferral and wall-clock bounds.
    /// @dev Capacity is at least one funding-asset unit and otherwise `exitCapBps` of the greater of the configured
    /// protocol cap and aggregate live `activeCommitment`. The live-utilization floor is deliberately path-dependent
    /// and ensures capacity is never below the configured-cap value at request time, but capacity can decline as
    /// active commitment declines through amortization or slashing. Aggregate active commitment may conservatively
    /// include unattributed return commitment, which only widens capacity. The account stays callable until maturity.
    /// At execution, the earliest available maturity is re-evaluated from the executing `currentEpoch` plus
    /// `exitDelayEpochs` during Normal, when that epoch's call outcome is still unknown. A request during PreCall,
    /// Funding, or Closed adds one epoch. While another call can still open — outside shutdown and before the last
    /// callable epoch's call window has passed — this makes the request span an epoch whose call outcome was unknown
    /// when it was made; at the shutdown or sunset edge, `claimRemainingMargin` supplies the withdrawal path without
    /// manufacturing call exposure. The phase boundary is deliberately conservative during PreCall before a call
    /// opens: the holder is already bound to that epoch's unknown outcome, but still receives the bounded one-epoch
    /// shift needed to cover call-free Funding uniformly. `maxDeferralEpochs` bounds displacement from that
    /// phase-aware earliest maturity: 0 accepts only that maturity and `type(uint256).max` accepts any maturity. It
    /// therefore bounds displacement within the executing epoch rather than pinning an absolute maturity on its own.
    /// The two bounds compose: because execution cannot occur after `deadline`, the assigned maturity never exceeds
    /// the epoch containing `deadline` plus `exitDelayEpochs`, the possible one-epoch phase adjustment, and
    /// `maxDeferralEpochs`. Shortening `deadline` therefore tightens the absolute guarantee as well as limiting
    /// mempool staleness. A bounded vault rejects an assigned maturity at or after `maxEpochs`; therefore its last
    /// request boundary is the end of Normal in epoch `maxEpochs - 1 - exitDelayEpochs`. Configurations where
    /// `minCommitmentEpochs + exitDelayEpochs >= maxEpochs` deliberately provide only terminal wind-down, not an
    /// in-tenor exit request.
    ///
    /// An account whose commitment exceeds the entire per-epoch capacity uses the oversized-account escape clause
    /// only inside the `assigned < capacity` guard. It takes the first bucket with any remaining room and therefore
    /// cannot be guaranteed the earliest bucket. Consequently `maxDeferralEpochs == 0` is systematically most likely
    /// to revert for the largest positions, contrary to the natural intuition that they receive priority. Reverts if
    /// the wall-clock deadline has expired, an exit is already pending, the account holds pending margin, or it has
    /// no active position. Cap-raise sequences can still fill the 128-live-bucket list. If first-fit would then need
    /// a new key, the request stays within the caller's deferral window and reuses the least-loaded eligible tracked
    /// maturity (earliest on ties), but only when eligible scheduled commitment plus the account fits
    /// `eligibleCount * capacity`. This is the only operative aggregate bound and constrains only narrow deferral
    /// windows: admission is unconditional at `ceil(BPS / exitCapBps)` eligible keys (32 at the minimum cap ratio),
    /// apart from base-unit flooring. The full-list fallback deliberately softens an individual bucket's capacity
    /// without splitting the account. For eligible load `S`, eligible bucket count `N`, capacity `C`, and the
    /// admitted account's actual commitment `A`, the aggregate gate is `S + A <= N * C`. Least-loaded selection
    /// bounds the selected bucket's post-assignment load by `S / N + A <= C + A * (1 - 1 / N)`, so its overshoot is
    /// strictly less than `A`; replay can make `A` exceed the live `userCommitmentCap`. The rejected
    /// earliest-eligible alternative would retain only the aggregate bound and could concentrate an overshoot
    /// approaching `(N - 1) * C` in one bucket. The fallback never tracks a 129th key and otherwise reverts
    /// `ExitCapacityReached`.
    /// @param maxDeferralEpochs Maximum accepted epochs past the earliest available maturity.
    /// @param deadline Wall-clock timestamp after which the exit request reverts.
    /// @return maturityEpoch The assigned maturity epoch.
    function requestExit(uint256 maxDeferralEpochs, uint256 deadline) external returns (uint256 maturityEpoch);
    /// @notice Claims matured exit margin to `receiver`.
    /// @param receiver Recipient of the margin.
    /// @return assets Margin transferred (marginAsset).
    function claimExitedMargin(address receiver) external returns (uint256 assets);
    /// @notice Withdraws remaining margin after emergency shutdown or scheduled terminal sunset.
    /// @dev Pays active margin, pending margin, and already-matured claimable exit margin. Like other
    /// state-touching calls, this may revert with `AccountMaterializationIncomplete` until a lagging account is
    /// brought within the bounded replay window by `materializeAccount`.
    /// @param receiver Recipient of the margin.
    /// @return assets Margin transferred (marginAsset).
    function claimRemainingMargin(address receiver) external returns (uint256 assets);
    /// @notice Removes part or all of a user's callable commitment and returns the paired margin to that user.
    /// @dev Callable only by a factory bouncer and unavailable while slash settlement is outstanding. Removes exactly
    /// the requested nominal active commitment pro rata, rounded down in the user's favor. A bouncer waits one epoch
    /// for a pending deposit to fold into active state; users whose exit is in progress are left to that exit. Partial
    /// removal cannot leave active margin below `minDepositAssets`. Removing the entire active commitment from an
    /// account with no pending, claimable, or exit state leaves zero exposure, and its family registry entry clears
    /// lazily when the user next deposits elsewhere. Margin is always pushed directly to `user`; a blacklisted holder
    /// of a blacklistable margin asset therefore cannot be bounced because the transfer reverts, and the operational
    /// fallback is to pause or shut down the facility. The function remains available after shutdown and scheduled
    /// terminal sunset. A lagging account may first need permissionless `materializeAccount` calls to complete bounded
    /// replay.
    /// @param user Account whose commitment is removed and that receives returned margin.
    /// @param commitment Nominal active commitment to remove.
    /// @return marginReturned Margin transferred to `user` (marginAsset).
    function bounceCommitment(address user, uint256 commitment) external returns (uint256 marginReturned);
    /// @notice Transfers all accrued treasury margin to the treasury.
    /// @dev Permissionless, unsynced, and available while paused or shut down. The accrued ledger is zeroed before the
    /// transfer and restored by transaction rollback if the margin token rejects the treasury recipient.
    function sweepTreasury() external;
    /// @notice Margin accrued for treasury but still held by the vault (marginAsset).
    function pendingTreasuryMargin() external view returns (uint256);
    /// @notice Owner update of mutable risk caps; configured caps apply to future deposits, while exit capacity is
    /// recomputed per request from the greater of the configured cap and live active utilization. It can decline with
    /// live utilization but never below the configured-cap value at that request.
    /// @dev Any protocol-cap change is blocked while finalized slash surplus awaits auction settlement. Updates to
    /// the other three parameters remain available when the protocol cap is unchanged.
    /// @param newProtocolCommitmentCap New vault-wide commitment cap (fundingAsset); must be in (0, uint128.max].
    /// @param newUserCommitmentCap New per-account commitment cap (fundingAsset).
    /// @param newExitCapBps New per-epoch exit capacity, in bps (313 <= value <= BPS).
    /// @param newMinDeposit New minimum margin deposit (marginAsset).
    function setRiskCaps(
        uint256 newProtocolCommitmentCap,
        uint256 newUserCommitmentCap,
        uint256 newExitCapBps,
        uint256 newMinDeposit
    ) external;
    /// @notice Triggers emergency shutdown: blocks new deposits/calls and enables remaining-margin withdrawal.
    /// @dev Callable while paused. Shutdown ends the active pause, emits `Unpaused`, and records the same frozen
    /// pause-adjusted timestamp so in-flight funding windows keep their slash-disable semantics. A later pause
    /// remains available as a circuit breaker for the wind-down claim path.
    function shutdown() external;
    /// @notice Pauses synced state-transitioning entrypoints and freezes the derived lifecycle clock.
    /// @dev Callable by the owner or guardian. Pause does not run global sync, so it remains available even if a
    /// sync path is blocked. While paused, every `synced` entrypoint reverts before state progression: deposits,
    /// exits, funding, auctions, slash finalization, account materialization, and owner risk/auction setters. The
    /// live functions are shutdown, setMarginOracle, pause/unpause, factory role management, and views. Pause
    /// remains callable after shutdown so a faulty wind-down claim path can be stopped.
    function pause() external;
    /// @notice Owner unpauses the vault and resumes every epoch window exactly where it froze.
    /// @dev The pause has no time bound: margin stays frozen until the owner unpauses or shuts the vault down;
    /// shutdown ends the active pause automatically.
    function unpause() external;
    /// @notice Owner opens the current epoch's capital call during PreCall.
    /// @dev Reverts unless in PreCall of `epoch`, if a prior call is unsettled, if already opened, or if
    /// `callAmount` exceeds the active-commitment base. Reads and snapshots the current margin-oracle price, reverting
    /// on zero and propagating an oracle revert. Owner guidance: `callAmount` should be meaningful relative to the
    /// active-commitment base and the account distribution. Because obligations are ceil-rounded per account (see
    /// `obligationOf`), a dust-sized call can force every account to owe a single funding unit, and any account that
    /// does not fund then forfeits its full margin under the all-or-nothing slash.
    /// @param epoch Epoch to open the call for (must be current).
    /// @param callAmount Total amount to call (fundingAsset).
    function openEpochCall(uint256 epoch, uint256 callAmount) external;
    /// @notice Funds the caller's own current-epoch obligation, all-or-nothing.
    /// @dev The Funding phase is the timing guard. A delayed transaction landing in another epoch's Funding phase
    /// would need to cross epoch end, Normal, and PreCall first. With `roll = false`, funding amortizes the position
    /// by releasing proportional margin and reducing callable commitment. With `roll = true`, funding pays the
    /// obligation and delivers wrapped USD3l while retaining the caller's full margin and full callable commitment;
    /// that exposure re-arms each epoch, the caller's pro-rata share of successive calls grows as amortizers decay,
    /// and lifetime funding obligations are unbounded while rolling. A live exiter cannot roll and reverts with
    /// `ExitInProgress`; a live exiter may still fund with `roll = false`. Delivery always mints at least one USD3
    /// share: when the obligation itself would round to zero shares, the payer supplies at most 1,000 extra
    /// funding-asset base units and the beneficiary receives the full resulting USD3l amount. Settlement accounting
    /// remains based on `obligationAmount`. Payers should approve `obligationOf(epoch, user) + 1_000` base units, or
    /// compute `max(obligationOf(epoch, user), usd3.previewMint(1))` client-side. Reverts `FundingTopUpExcessive`
    /// above that bound and `FundingDeliveryImpossible` when USD3 reports zero assets with nonzero supply. Either
    /// error signals an incident state: pause to freeze the deadline and have the owner shut down before the frozen
    /// deadline to disable slashing.
    /// @param roll Whether to retain full margin and commitment after paying this call.
    /// @return obligationAmount Per-account obligation paid (fundingAsset), the ceil-rounded pro-rata share.
    function fundCall(bool roll) external returns (uint256 obligationAmount);
    /// @notice Funds `user`'s current-epoch obligation with funding supplied by the caller (push-based).
    /// @dev The caller pays; released margin, wrapped USD3l delivery, and funded status accrue to `user`. The
    /// Funding phase is the timing guard, as on {fundCall}. Push funding always amortizes because the payer must not
    /// control whether the user's margin remains locked and callable. A push fund can front-run and deny the user's
    /// intended roll for that epoch: the payer donates the obligation plus any bounded delivery top-up, the user
    /// receives wrapped USD3l and released margin, and the user can restore commitment by re-depositing the released
    /// margin. The delivery guarantees and degenerate-USD3 incident procedure are the same as {fundCall(bool)}.
    /// @param user Account whose obligation is funded.
    /// @return obligationAmount Per-account obligation paid (fundingAsset), the ceil-rounded pro-rata share.
    function fundCall(address user) external returns (uint256 obligationAmount);
    /// @notice Fills up to `maxFillAmount` of the live auction's shortfall in exchange for wrapped USD3l and a
    /// collateral kicker.
    /// @dev Targets whichever auction is live, following Yearn-take semantics. The award is the current ramped
    /// pro-rata kicker, capped by `maxAuctionAwardBps` of the fill at the fill-time oracle price. `minMarginAward` is
    /// an absolute minimum applied to the award for the actual fill after `maxFillAmount` is clamped to the remaining
    /// shortfall, not to `maxFillAmount`. A concurrent partial fill can therefore reduce both the caller's fill and
    /// award enough to revert even when the per-unit award rate is unchanged. Callers seeking execution at a rate
    /// rather than an absolute total should either size `maxFillAmount` below the observed remaining shortfall to
    /// leave a contention buffer, or take through an atomic contract that reads the remaining shortfall and computes
    /// the floor in the same transaction. An off-chain read or simulation, even in the same block, is not atomic with
    /// inclusion. The floor is deliberately not prorated by `filledAmount / maxFillAmount`: its absolute form lets a
    /// taker require a minimum notional that covers fixed gas costs, which a prorated floor cannot express. The
    /// wall-clock `deadline` is checked as the first statement in the function body, after the `synced` modifier
    /// runs; an expired deadline reverts the modifier's sync work along with the fill. Reverts if USD3 or the
    /// notification vault cannot accept delivery. If a fill leaves a residual smaller than the assets required to
    /// mint one USD3 share, the remaining shortfall cannot be filled because `maxFillAmount` is a caller ceiling and
    /// no top-up is taken; it settles through normal window-end disposal without rolling over.
    /// @param maxFillAmount Maximum shortfall to fill (fundingAsset).
    /// @param minMarginAward Minimum acceptable collateral kicker (marginAsset).
    /// @param deadline Wall-clock timestamp after which the transaction reverts.
    /// @return filledAmount Shortfall actually filled (fundingAsset).
    /// @return marginAward Collateral kicker awarded (marginAsset).
    function takeAuction(uint256 maxFillAmount, uint256 minMarginAward, uint256 deadline)
        external
        returns (uint256 filledAmount, uint256 marginAward);
    /// @notice Owner update of the oracle-valued auction award cap.
    /// @dev Reverts above BPS, when set nonzero while auctions are disabled, or while an auction is live.
    /// @param newMaxAuctionAwardBps New award cap per fundingAsset filled, in bps.
    function setMaxAuctionAwardBps(uint256 newMaxAuctionAwardBps) external;
    /// @notice Owner update of the fee charged on auction-awarded slashed margin, clamped to unawarded surplus.
    /// @param newSlashFeeBps New fee in bps.
    function setSlashFeeBps(uint256 newSlashFeeBps) external;
    /// @notice Owner update of the trusted margin oracle.
    /// @dev Rotation is owner-trusted and reprices subsequent deposits and auction fills, but not an opened call's
    /// return-pool commitment. While paused, no fills can execute and the owner may rotate even a responsive current
    /// oracle before resuming the frozen auction. While unpaused, the live-auction guard blocks rotation only while
    /// the current oracle still returns a nonzero price for fills; a zero-price, reverting, or otherwise unreadable
    /// current oracle never blocks rotation. The new oracle must return marginAsset-to-fundingAsset (USDC) prices at
    /// ORACLE_PRICE_SCALE with matching decimals; the vault can only check that the price is nonzero.
    /// @param newOracle New margin oracle.
    function setMarginOracle(address newOracle) external;
    /// @notice Auction state for an epoch.
    /// @param epoch Epoch to query.
    /// @return The auction state.
    function getAuctionState(uint256 epoch) external view returns (LCCAuctionLib.AuctionState memory);
    /// @notice Permissionlessly finalizes an epoch's slash once eligible (also runs lazily on any state touch).
    /// @param epoch Epoch to finalize.
    function finalizeEpochSlash(uint256 epoch) external;
    /// @notice Advances a user's lazy materialization (folds pending/matured state, records defaults).
    /// @param user Account to materialize.
    function materializeAccount(address user) external;
    /// @notice Materialized view of an account (read-only replay; not persisted).
    /// @param user Account to query.
    /// @return The materialized account.
    function getAccount(address user) external view returns (Account memory);
    /// @notice Stored epoch-call accounting for an epoch.
    /// @param epoch Epoch to query.
    /// @return The epoch state.
    function getEpochState(uint256 epoch) external view returns (EpochState memory);
    /// @notice Current obligation a user owes for an epoch's open call (0 if none, funded, or finalized).
    /// @dev Ceil-rounded and computed independently per account from the call-open commitment snapshot; another
    /// account funding does not reduce or extinguish this account's obligation, so the sum of obligations across
    /// accounts can exceed `callAmount`.
    /// @param epoch Epoch to query.
    /// @param user Account to query.
    /// @return The obligation (fundingAsset).
    function obligationOf(uint256 epoch, address user) external view returns (uint256);
    /// @notice Margin currently claimable from a matured exit (0 if not yet claimable).
    /// @param user Account to query.
    /// @return The claimable margin (marginAsset).
    function claimableExitedMargin(address user) external view returns (uint256);
    /// @notice The epochs in which a call has been opened, in order.
    /// @return The list of called epochs.
    function calledEpochs() external view returns (uint256[] memory);
    /// @notice Immutable asset and integration address configuration.
    /// @return The asset configuration.
    function assetConfig() external view returns (AssetConfig memory);
    /// @notice Immutable epoch timing and leverage configuration.
    /// @return The epoch configuration.
    function epochConfig() external view returns (EpochConfig memory);
    /// @notice Immutable auction timing and decay configuration.
    /// @return The auction configuration.
    function auctionConfig() external view returns (AuctionConfig memory);
    /// @notice Mutable risk limits.
    /// @return The risk configuration.
    function riskConfig() external view returns (RiskConfig memory);
    /// @notice Aggregate margin and commitment totals.
    /// @return The aggregate totals.
    function totals() external view returns (Totals memory);
    /// @notice Global sync cursors and live-auction slot.
    /// @return The sync state.
    function syncState() external view returns (SyncState memory);
    /// @notice Emergency shutdown state.
    /// @return The shutdown state.
    function shutdownState() external view returns (ShutdownState memory);
    /// @notice Whether `user` fully funded their obligation for `epoch`.
    /// @param epoch Epoch to query.
    /// @param user Account to query.
    /// @return True if funded.
    function fundedEpoch(uint256 epoch, address user) external view returns (bool);
    /// @notice Pending margin scheduled to activate at an epoch (marginAsset).
    /// @param epoch Activation epoch to query.
    /// @return The pending margin for that epoch.
    function pendingMarginByActivationEpoch(uint256 epoch) external view returns (uint256);
    /// @notice Pending commitment scheduled to activate at an epoch (fundingAsset).
    /// @param epoch Activation epoch to query.
    /// @return The pending commitment for that epoch.
    function pendingCommitmentByActivationEpoch(uint256 epoch) external view returns (uint256);
    /// @notice Margin scheduled to exit at a maturity epoch (marginAsset).
    /// @param epoch Maturity epoch to query.
    /// @return The exit-bucket margin for that epoch.
    function exitBucketMarginByMaturity(uint256 epoch) external view returns (uint256);
    /// @notice Commitment scheduled to exit at a maturity epoch (fundingAsset).
    /// @param epoch Maturity epoch to query.
    /// @return The exit-bucket commitment for that epoch.
    function exitBucketCommitmentByMaturity(uint256 epoch) external view returns (uint256);
}
