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
/// pro-rata obligation all-or-nothing (the funding is delivered as wrapped USD3n) and get the backing margin
/// released proportionally. Unfunded obligations are slashed after the funding deadline, and the resulting
/// shortfall is offered through an epoch-shortfall Dutch auction.
/// @dev Unit convention: amount-like accounting values outside the margin family are denominated in `fundingAsset`
/// unless documented otherwise; margin amounts are in `marginAsset`; `marginValue` is margin valued in
/// `fundingAsset`; epoch fields are epoch indices; `*Bps` fields are basis points (out of 10_000). Events and
/// errors are exposed through `LCCEventsLib` and `LCCErrorsLib`. Settlement consumers read `AuctionSettled` for
/// fill totals and `SlashSurplusDisposed` for the disposal split.
interface ILCCVault {
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

    /// @notice Immutable (and initial-mutable) facility configuration consumed by the constructor.
    /// @param owner Vault owner: opens calls, tunes risk caps, and can trigger emergency shutdown.
    /// @param marginAsset ERC20 posted as the performance bond. Must be standard (no fee-on-transfer / rebasing).
    /// @param fundingAsset ERC20 used to fund calls and auction fills (the spec's "callable asset"); must equal
    /// USD3's underlying asset.
    /// @param notificationVault ERC-4626 wrapper over USD3 that receives funded amounts for the funder.
    /// @param marginOracle Trusted oracle returning the margin-to-fundingAsset price scaled by ORACLE_PRICE_SCALE.
    /// @param treasury Recipient of slashed margin (and unsold auction collateral).
    /// @param startTimestamp Epoch-zero start; the epoch clock is derived from this.
    /// @param epochLength Total epoch duration in seconds (Normal + PreCall + Funding + Closed).
    /// @param normalDuration Seconds of the Normal phase.
    /// @param preCallDuration Seconds of the PreCall phase.
    /// @param fundingDuration Seconds of the Funding phase.
    /// @param marginRatioBps Leverage ratio in bps: commitment = marginValue * BPS / marginRatioBps.
    /// @param protocolCommitmentCap Vault-wide cap on active+pending commitment (fundingAsset); also the base for
    /// per-epoch exit capacity. Bounded by type(uint128).max.
    /// @param userCommitmentCap Per-account cap on active+pending commitment (fundingAsset).
    /// @param exitCapBps Per-epoch exit capacity as a fraction of `protocolCommitmentCap`, in bps.
    /// @param exitDelayEpochs Minimum epochs between an exit request and its earliest maturity.
    /// @param minDepositAssets Minimum margin deposit, in marginAsset units.
    /// @param auctionStepCount Number of price steps spanning the Closed window; 0 disables the auction entirely,
    /// otherwise must be at least 2 (the final step boundary coincides with settlement and is never live).
    /// @param auctionStepDecayRateBps Per-step decay of the protocol's retained pool share, in bps.
    /// @param maxAuctionAwardBps Oracle-valued collateral award cap per fundingAsset filled, in bps; 0 disables.
    /// @param slashFeeBps Fee on unawarded slashed margin surplus, in bps.
    struct VaultParams {
        address owner;
        address marginAsset;
        address fundingAsset;
        address notificationVault;
        address marginOracle;
        address treasury;
        uint256 startTimestamp;
        uint256 epochLength;
        uint256 normalDuration;
        uint256 preCallDuration;
        uint256 fundingDuration;
        uint256 marginRatioBps;
        uint256 protocolCommitmentCap;
        uint256 userCommitmentCap;
        uint256 exitCapBps;
        uint256 exitDelayEpochs;
        uint256 minDepositAssets;
        uint256 auctionStepCount;
        uint256 auctionStepDecayRateBps;
        uint256 maxAuctionAwardBps;
        uint256 slashFeeBps;
    }

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
    /// @param epochLength Total epoch duration in seconds.
    /// @param normalDuration Seconds of the Normal phase.
    /// @param preCallDuration Seconds of the PreCall phase.
    /// @param fundingDuration Seconds of the Funding phase.
    /// @param marginRatioBps Leverage ratio in bps.
    /// @param exitDelayEpochs Minimum epochs between exit request and earliest maturity.
    struct EpochConfig {
        uint256 startTimestamp;
        uint256 epochLength;
        uint256 normalDuration;
        uint256 preCallDuration;
        uint256 fundingDuration;
        uint256 marginRatioBps;
        uint256 exitDelayEpochs;
    }

    /// @notice Immutable auction timing and decay configuration.
    /// @param auctionStepCount Number of price steps spanning the Closed-window auction.
    /// @param auctionStepDecayRateBps Per-step retained-pool decay, in bps.
    /// @param auctionStepDuration Derived duration of each auction price step, in seconds.
    struct AuctionConfig {
        uint256 auctionStepCount;
        uint256 auctionStepDecayRateBps;
        uint256 auctionStepDuration;
    }

    /// @notice Mutable risk limits used by deposits, exits, and auction awards.
    /// @param protocolCommitmentCap Vault-wide cap on active+pending commitment.
    /// @param userCommitmentCap Per-account cap on active+pending commitment.
    /// @param exitCapBps Per-epoch exit capacity fraction, in bps.
    /// @param minDepositAssets Minimum margin deposit.
    /// @param maxAuctionAwardBps Oracle-valued auction award cap per fundingAsset filled, in bps.
    /// @param slashFeeBps Fee on unawarded slashed margin surplus, in bps.
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

    /// @notice Packed terminal emergency shutdown state.
    /// @param active Whether shutdown has been triggered.
    /// @param timestamp Block timestamp at which shutdown was triggered (0 if not shut down).
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
    /// @param exitClaimed True once the matured exit margin has been claimed.
    /// @param exitMatured True once the exit has matured (margin moved to `claimableExitMargin`).
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
    /// @param fundedUsersRemainingMargin Margin of fully-funded users that stays callable past this call
    /// (marginAsset).
    /// @param fundedUsersRemainingCommitment Commitment of fully-funded users that stays active past this call
    /// (fundingAsset).
    /// @param slashFinalized True once slashing for this epoch has been finalized.
    /// @param slashDisabledByShutdown True if shutdown landed before/within this epoch's funding window, so no
    /// slash is taken.
    /// @param slashedMargin Aggregate margin slashed for this epoch (marginAsset).
    /// @param returnPool Slashed surplus returned to defaulters after treasury fee, when backed by nonzero
    /// settlement commitment (marginAsset).
    /// @param returnCommitment Callable commitment created by `returnPool` at settlement (fundingAsset).
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

    /// @notice Current epoch index derived from the block timestamp.
    /// @return The current epoch.
    function currentEpoch() external view returns (uint256);
    /// @notice Current lifecycle phase derived from the block timestamp.
    /// @return The current phase.
    function currentPhase() external view returns (Phase);
    /// @notice Timestamp at which a given phase ends within a given epoch.
    /// @param epoch Epoch to query.
    /// @param phase Phase whose end is requested.
    /// @return The phase-end timestamp.
    function phaseEndsAt(uint256 epoch, Phase phase) external view returns (uint256);
    /// @notice Deposits margin for the caller, creating a leveraged commitment.
    /// @dev Pulls `assets` of marginAsset from the caller and credits the caller's own account (self-deposit only,
    /// since a deposit creates a callable obligation). Activates immediately during Normal (before a call opens),
    /// otherwise stages as pending for the next epoch. Reverts under shutdown, on a pending-blocking exit, on a
    /// zero/sub-minimum amount, on a zero oracle price, or if a cap would be exceeded.
    /// @param assets Margin to deposit (marginAsset).
    /// @return commitment Commitment created (fundingAsset).
    function deposit(uint256 assets) external returns (uint256 commitment);
    /// @notice Requests a full-account exit, assigning the earliest maturity epoch with available exit capacity.
    /// @dev The account stays callable until maturity. Reverts if an exit is already pending, if the account holds
    /// pending margin, or if it has no active position.
    /// @return maturityEpoch The assigned maturity epoch.
    function requestExit() external returns (uint256 maturityEpoch);
    /// @notice Claims matured exit margin to `receiver`.
    /// @param receiver Recipient of the margin.
    /// @return assets Margin transferred (marginAsset).
    function claimExitedMargin(address receiver) external returns (uint256 assets);
    /// @notice Withdraws safe (uncalled) margin through the emergency path after shutdown.
    /// @param receiver Recipient of the margin.
    /// @return assets Margin transferred (marginAsset).
    function claimEmergencyMargin(address receiver) external returns (uint256 assets);
    /// @notice Owner update of mutable risk caps; applies to future deposits and exit assignments only.
    /// @param newProtocolCommitmentCap New vault-wide commitment cap (fundingAsset); must be in (0, uint128.max].
    /// @param newUserCommitmentCap New per-account commitment cap (fundingAsset).
    /// @param newExitCapBps New per-epoch exit capacity, in bps (0 < value <= BPS).
    /// @param newMinDeposit New minimum margin deposit (marginAsset).
    function setRiskCaps(
        uint256 newProtocolCommitmentCap,
        uint256 newUserCommitmentCap,
        uint256 newExitCapBps,
        uint256 newMinDeposit
    ) external;
    /// @notice Triggers terminal emergency shutdown: blocks new deposits/calls and enables emergency withdrawal.
    function shutdown() external;
    /// @notice Owner opens the current epoch's capital call during PreCall.
    /// @dev Reverts unless in PreCall of `epoch`, if a prior call is unsettled, if already opened, or if
    /// `callAmount` exceeds the active-commitment base. Owner guidance: `callAmount` should be meaningful relative to
    /// the active-commitment base and the account distribution. Because obligations are ceil-rounded per account
    /// (see `obligationOf`), a dust-sized call can force every account to owe a single funding unit, and any account
    /// that does not fund then forfeits its full margin under the all-or-nothing slash.
    /// @param epoch Epoch to open the call for (must be current).
    /// @param callAmount Total amount to call (fundingAsset).
    function openEpochCall(uint256 epoch, uint256 callAmount) external;
    /// @notice Funds the caller's own current-epoch obligation, all-or-nothing.
    /// @dev The Funding phase is the timing guard. A delayed transaction landing in another epoch's Funding phase
    /// would need to cross epoch end, Normal, and PreCall first.
    /// @return obligationAmount Per-account obligation paid (fundingAsset), the ceil-rounded pro-rata share.
    function fundCall() external returns (uint256 obligationAmount);
    /// @notice Funds `user`'s current-epoch obligation with funding supplied by the caller (push-based).
    /// @dev The caller pays; released margin, wrapped USD3n delivery, and funded status accrue to `user`. The
    /// Funding phase is the timing guard, as on {fundCall}.
    /// @param user Account whose obligation is funded.
    /// @return obligationAmount Per-account obligation paid (fundingAsset), the ceil-rounded pro-rata share.
    function fundCall(address user) external returns (uint256 obligationAmount);
    /// @notice Fills up to `maxFillAmount` of the live auction's shortfall in exchange for wrapped USD3n and a
    /// collateral kicker.
    /// @dev Targets whichever auction is live, following Yearn-take semantics. `maxFillAmount` is the caller's only
    /// bound; the award is the current ramped pro-rata kicker, capped by `maxAuctionAwardBps` of the fill at the
    /// fill-time oracle price. Reverts if USD3 or the notification vault cannot accept delivery.
    /// @param maxFillAmount Maximum shortfall to fill (fundingAsset).
    /// @return filledAmount Shortfall actually filled (fundingAsset).
    /// @return marginAward Collateral kicker awarded (marginAsset).
    function takeAuction(uint256 maxFillAmount) external returns (uint256 filledAmount, uint256 marginAward);
    /// @notice Owner update of the oracle-valued auction award cap.
    /// @dev Reverts above BPS, when set nonzero while auctions are disabled, or while an auction is live.
    /// @param newMaxAuctionAwardBps New award cap per fundingAsset filled, in bps.
    function setMaxAuctionAwardBps(uint256 newMaxAuctionAwardBps) external;
    /// @notice Owner update of the fee charged on unawarded slashed margin surplus.
    /// @param newSlashFeeBps New fee in bps.
    function setSlashFeeBps(uint256 newSlashFeeBps) external;
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
    /// @notice Terminal emergency shutdown state.
    /// @return The shutdown state.
    function shutdownState() external view returns (ShutdownState memory);
    /// @notice Whether `user` fully funded their obligation for `epoch`.
    /// @param epoch Epoch to query.
    /// @param user Account to query.
    /// @return True if funded.
    function fundedEpoch(uint256 epoch, address user) external view returns (bool);
    /// @notice Whether `user` was materialized as defaulted for `epoch`.
    /// @param epoch Epoch to query.
    /// @param user Account to query.
    /// @return True if defaulted.
    function defaultedEpoch(uint256 epoch, address user) external view returns (bool);
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
