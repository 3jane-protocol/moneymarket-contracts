// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCAuctionLib} from "../libraries/LCCAuctionLib.sol";

/// @title ILeveragedCallableCreditVault
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Interface for the Leveraged Callable Credit vault: a per-facility callable-credit primitive (not
/// ERC-4626, no transferable shares). Depositors post one ERC20 `marginAsset` as a performance bond; the vault
/// values it through a trusted Morpho-style oracle and leverages it by `marginRatioBps` into a commitment
/// denominated in `fundingAsset`. The owner opens at most one capital call per epoch; called users fund their
/// pro-rata obligation all-or-nothing (the funding is deposited into USD3 for them) and get the backing margin
/// released proportionally. Unfunded obligations are slashed after the funding deadline, and the resulting
/// shortfall is offered through an epoch-shortfall Dutch auction.
/// @dev Unit convention: amount-like accounting values outside the margin family are denominated in `fundingAsset`
/// unless documented otherwise; margin amounts are in `marginAsset`; `marginValue` is margin valued in
/// `fundingAsset`; epoch fields are epoch indices; `*Bps` fields are basis points (out of 10_000).
interface ILeveragedCallableCreditVault {
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
    /// @param usd3 ERC-4626 vault that funded amounts are deposited into for the funder.
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
    /// @param auctionStepCount Number of price steps spanning the Closed window; 0 disables the auction entirely.
    /// @param auctionStepDecayRateBps Per-step decay of the protocol's retained pool share, in bps.
    /// @param maxAuctionAwardBps Oracle-valued collateral award cap per fundingAsset filled, in bps; 0 disables.
    struct VaultParams {
        address owner;
        address marginAsset;
        address fundingAsset;
        address usd3;
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
    /// @param callAmount Total amount called this epoch (fundingAsset).
    /// @param marginAtCallOpen Total active margin snapshotted at call open (marginAsset).
    /// @param fundedAmount Cumulative funded obligations this epoch (fundingAsset).
    /// @param marginReleased Cumulative margin released to funders this epoch (marginAsset).
    /// @param fundedUsersRemainingMargin Margin of fully-funded users that stays callable past this call
    /// (marginAsset).
    /// @param fundedUsersRemainingCommitment Commitment of fully-funded users that stays active past this call
    /// (fundingAsset).
    /// @param slashFinalized True once slashing for this epoch has been finalized.
    /// @param slashDisabledByShutdown True if shutdown landed before/within this epoch's funding window, so no
    /// slash is taken.
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
    }

    /// @notice Emitted when a deposit is checkpointed (immediately active or staged as pending).
    /// @param user Account credited with the deposit.
    /// @param marginAssets Margin deposited (marginAsset).
    /// @param marginValue Oracle value of the deposited margin (fundingAsset).
    /// @param commitment Commitment created by the deposit (fundingAsset).
    /// @param activationEpoch Epoch at which the commitment becomes callable.
    /// @param immediate True if activated in the current epoch, false if staged as pending.
    event DepositCheckpointed(
        address indexed user,
        uint256 marginAssets,
        uint256 marginValue,
        uint256 commitment,
        uint256 activationEpoch,
        bool immediate
    );
    /// @notice Emitted when a pending-activation bucket folds into the active totals.
    /// @param epoch Activation epoch whose bucket folded.
    /// @param marginAssets Margin activated (marginAsset).
    /// @param commitment Commitment activated (fundingAsset).
    event PendingActivated(uint256 indexed epoch, uint256 marginAssets, uint256 commitment);
    /// @notice Emitted when the owner opens an epoch's capital call.
    /// @param epoch Epoch the call was opened for.
    /// @param callAmount Total amount called (fundingAsset).
    /// @param commitmentDenominator Active-commitment base snapshotted as the pro-rata denominator (fundingAsset).
    event EpochCallOpened(uint256 indexed epoch, uint256 callAmount, uint256 commitmentDenominator);
    /// @notice Emitted when a user's epoch obligation is funded.
    /// @param user Account whose obligation was funded.
    /// @param epoch Epoch funded.
    /// @param obligationAmount Obligation paid (fundingAsset).
    event CallFunded(address indexed user, uint256 indexed epoch, uint256 obligationAmount);
    /// @notice Emitted when backing margin is released to a funder.
    /// @param user Account receiving the released margin.
    /// @param epoch Epoch the funding settled for.
    /// @param marginAssets Margin released (marginAsset).
    event MarginReleased(address indexed user, uint256 indexed epoch, uint256 marginAssets);
    /// @notice Emitted when funding USDC is escrowed because USD3 could not accept the deposit.
    /// @param user Beneficiary the escrow is held for.
    /// @param epoch Epoch the funding settled for.
    /// @param fundingAmount Amount escrowed (fundingAsset).
    event EscrowedFundingCreated(address indexed user, uint256 indexed epoch, uint256 fundingAmount);
    /// @notice Emitted when previously escrowed funding is later deposited into USD3.
    /// @param user Beneficiary of the USD3 deposit.
    /// @param fundingAmount Amount moved from escrow into USD3 (fundingAsset).
    event EscrowedFundingPlaced(address indexed user, uint256 fundingAmount);
    /// @notice Emitted when escrowed funding is returned to its owner after shutdown.
    /// @param user Owner of the escrow.
    /// @param receiver Recipient of the returned funds.
    /// @param fundingAmount Amount returned (fundingAsset).
    event EscrowedFundingClaimed(address indexed user, address indexed receiver, uint256 fundingAmount);
    /// @notice Emitted when an account's unfunded obligation is materialized as a default.
    /// @param user Defaulted account.
    /// @param epoch Epoch defaulted on.
    /// @param slashedMargin Margin forfeited by this account (marginAsset).
    /// @param slashedCommitment Commitment removed by this default (fundingAsset).
    event UserDefaulted(address indexed user, uint256 indexed epoch, uint256 slashedMargin, uint256 slashedCommitment);
    /// @notice Emitted once an epoch's slash is finalized.
    /// @param epoch Epoch finalized.
    /// @param slashedMargin Aggregate margin slashed (marginAsset); 0 if disabled by shutdown.
    /// @param slashedCommitment Aggregate commitment removed (fundingAsset); 0 if disabled by shutdown.
    /// @param disabledByShutdown True if no slash was taken because shutdown interrupted the funding window.
    event EpochSlashFinalized(
        uint256 indexed epoch, uint256 slashedMargin, uint256 slashedCommitment, bool disabledByShutdown
    );
    /// @notice Emitted when an account requests a full-account exit.
    /// @param user Exiting account.
    /// @param maturityEpoch Epoch the exit was assigned to mature.
    /// @param marginAssets Margin scheduled to exit (marginAsset).
    /// @param commitment Commitment scheduled to exit (fundingAsset).
    event ExitRequested(address indexed user, uint256 indexed maturityEpoch, uint256 marginAssets, uint256 commitment);
    /// @notice Emitted when a maturity bucket folds out of the active totals.
    /// @param maturityEpoch Maturity epoch whose bucket folded.
    /// @param marginAssets Margin matured out (marginAsset).
    /// @param commitment Commitment matured out (fundingAsset).
    event ExitMatured(uint256 indexed maturityEpoch, uint256 marginAssets, uint256 commitment);
    /// @notice Emitted when matured exit margin is claimed.
    /// @param user Exiting account.
    /// @param receiver Recipient of the margin.
    /// @param marginAssets Margin transferred (marginAsset).
    event ExitedMarginClaimed(address indexed user, address indexed receiver, uint256 marginAssets);
    /// @notice Emitted when safe margin is withdrawn through the emergency path after shutdown.
    /// @param user Withdrawing account.
    /// @param receiver Recipient of the margin.
    /// @param marginAssets Margin transferred (marginAsset).
    event EmergencyMarginClaimed(address indexed user, address indexed receiver, uint256 marginAssets);
    /// @notice Emitted when the owner updates mutable risk caps.
    /// @param protocolCommitmentCap New vault-wide commitment cap (fundingAsset).
    /// @param userCommitmentCap New per-account commitment cap (fundingAsset).
    /// @param exitCapBps New per-epoch exit capacity, in bps.
    /// @param minDepositAssets New minimum margin deposit (marginAsset).
    event RiskCapUpdated(
        uint256 protocolCommitmentCap, uint256 userCommitmentCap, uint256 exitCapBps, uint256 minDepositAssets
    );
    /// @notice Emitted when emergency shutdown is triggered (terminal).
    /// @param epoch Epoch in which shutdown occurred.
    /// @param timestamp Block timestamp of shutdown.
    event EmergencyShutdown(uint256 indexed epoch, uint256 timestamp);
    /// @notice Emitted when an epoch's funding shortfall opens a Dutch auction.
    /// @param epoch Epoch whose shortfall is auctioned.
    /// @param shortfallAmount Unfunded amount to be filled (fundingAsset).
    /// @param marginPool Slashed margin backing the collateral kicker (marginAsset).
    event AuctionKicked(uint256 indexed epoch, uint256 shortfallAmount, uint256 marginPool);
    /// @notice Emitted on each auction fill.
    /// @param filler Account filling the shortfall.
    /// @param epoch Auctioned epoch.
    /// @param fillAmount Shortfall filled by this take (fundingAsset).
    /// @param marginAward Collateral kicker awarded (marginAsset).
    event AuctionFill(address indexed filler, uint256 indexed epoch, uint256 fillAmount, uint256 marginAward);
    /// @notice Emitted when an auction settles (fully filled or window elapsed).
    /// @param epoch Settled epoch.
    /// @param filledAmount Total shortfall filled (fundingAsset).
    /// @param marginAwarded Total collateral awarded to fillers (marginAsset).
    /// @param marginToTreasury Unsold collateral swept to treasury (marginAsset).
    event AuctionSettled(uint256 indexed epoch, uint256 filledAmount, uint256 marginAwarded, uint256 marginToTreasury);
    /// @notice Emitted when the owner updates the oracle-valued auction award cap.
    /// @param maxAuctionAwardBps New award cap per fundingAsset filled, in bps.
    event AuctionAwardCapUpdated(uint256 maxAuctionAwardBps);

    /// @notice Thrown when requesting an exit while the account still holds a pending (not-yet-active) deposit.
    error PendingDepositExists();
    /// @notice Thrown when an account cannot be fully materialized within the per-call step bound; call
    /// `materializeAccount` repeatedly to catch up before retrying.
    error AccountMaterializationIncomplete();

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
    /// @notice Deposits margin for `receiver`, creating a leveraged commitment.
    /// @dev Pulls `assets` of marginAsset from the caller. Activates immediately during Normal (before a call
    /// opens), otherwise stages as pending for the next epoch. Reverts under shutdown, on a pending-blocking exit,
    /// on a zero/sub-minimum amount, on a zero oracle price, or if a cap would be exceeded.
    /// @param assets Margin to deposit (marginAsset).
    /// @param receiver Account credited with the deposit.
    /// @return commitment Commitment created (fundingAsset).
    function deposit(uint256 assets, address receiver) external returns (uint256 commitment);
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
    /// `callAmount` exceeds the active-commitment base.
    /// @param epoch Epoch to open the call for (must be current).
    /// @param callAmount Total amount to call (fundingAsset).
    function openEpochCall(uint256 epoch, uint256 callAmount) external;
    /// @notice Funds the caller's own current-epoch obligation, all-or-nothing.
    /// @param epoch Epoch to fund (must be current).
    /// @return obligationAmount Obligation paid (fundingAsset).
    function fundEpochCall(uint256 epoch) external returns (uint256 obligationAmount);
    /// @notice Funds `user`'s current-epoch obligation with funding supplied by the caller (push-based).
    /// @dev The caller pays; released margin, the USD3 position (or escrow credit), and funded status accrue to
    /// `user`. Escrow credit is never refundable to the payer.
    /// @param epoch Epoch to fund (must be current).
    /// @param user Account whose obligation is funded.
    /// @return obligationAmount Obligation paid (fundingAsset).
    function fundEpochCallFor(uint256 epoch, address user) external returns (uint256 obligationAmount);
    /// @notice Fills up to `maxFillAmount` of the live auction's shortfall in exchange for a USD3 position and a
    /// collateral kicker.
    /// @dev No escrow fallback for fillers: reverts if USD3 cannot accept the deposit. The award is the current
    /// ramped pro-rata kicker, capped by `maxAuctionAwardBps` of the fill at the fill-time oracle price.
    /// @param epoch Auctioned epoch (must be the live auction).
    /// @param maxFillAmount Maximum shortfall to fill (fundingAsset).
    /// @return filledAmount Shortfall actually filled (fundingAsset).
    /// @return marginAward Collateral kicker awarded (marginAsset).
    function takeAuction(uint256 epoch, uint256 maxFillAmount)
        external
        returns (uint256 filledAmount, uint256 marginAward);
    /// @notice Owner update of the oracle-valued auction award cap.
    /// @dev Reverts above BPS, when set nonzero while auctions are disabled, or while an auction is live.
    /// @param newMaxAuctionAwardBps New award cap per fundingAsset filled, in bps.
    function setMaxAuctionAwardBps(uint256 newMaxAuctionAwardBps) external;
    /// @notice Auction state for an epoch.
    /// @param epoch Epoch to query.
    /// @return The auction state.
    function getAuctionState(uint256 epoch) external view returns (LCCAuctionLib.AuctionState memory);
    /// @notice Live-auction slot, encoded as epoch + 1 (0 means no live auction).
    /// @return The encoded live-auction epoch.
    function pendingAuctionEpochPlusOne() external view returns (uint256);
    /// @notice Oracle-valued auction award cap per fundingAsset filled, in bps (0 disables the kicker).
    /// @return The award cap in bps.
    function maxAuctionAwardBps() external view returns (uint256);
    /// @notice Number of price steps spanning the Closed-window auction (0 disables auctions).
    /// @return The step count.
    function auctionStepCount() external view returns (uint256);
    /// @notice Duration of each auction price step, in seconds.
    /// @return The step duration.
    function auctionStepDuration() external view returns (uint256);
    /// @notice Per-step decay of the protocol's retained pool share, in bps.
    /// @return The per-step decay in bps.
    function auctionStepDecayRateBps() external view returns (uint256);
    /// @notice Deposits a user's escrowed funding into USD3, up to USD3's current capacity.
    /// @param user Beneficiary whose escrow is placed.
    /// @return placedAmount Amount deposited into USD3 (fundingAsset).
    function depositEscrowedFunding(address user) external returns (uint256 placedAmount);
    /// @notice Returns the caller's escrowed funding after shutdown, when USD3 placement can no longer be forced.
    /// @param receiver Recipient of the returned funds.
    /// @return assets Amount returned (fundingAsset).
    function claimEscrowedFunding(address receiver) external returns (uint256 assets);
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
    /// @notice Total active margin across all accounts (marginAsset).
    /// @return The total active margin.
    function totalActiveMargin() external view returns (uint256);
    /// @notice Total active commitment across all accounts (fundingAsset).
    /// @return The total active commitment.
    function totalActiveCommitment() external view returns (uint256);
    /// @notice Total pending (not-yet-active) margin across all accounts (marginAsset).
    /// @return The total pending margin.
    function totalPendingMargin() external view returns (uint256);
    /// @notice Total pending commitment across all accounts (fundingAsset).
    /// @return The total pending commitment.
    function totalPendingCommitment() external view returns (uint256);
    /// @notice Total funding held in escrow across all accounts (fundingAsset).
    /// @return The total escrowed funding.
    function totalEscrowedFundingAmount() external view returns (uint256);
    /// @notice Funding held in escrow for a specific user (fundingAsset).
    /// @param user Account to query.
    /// @return The escrowed funding for `user`.
    function escrowedFundingAmount(address user) external view returns (uint256);
    /// @notice Vault-wide cap on active+pending commitment (fundingAsset).
    /// @return The protocol commitment cap.
    function protocolCommitmentCap() external view returns (uint256);
    /// @notice Per-account cap on active+pending commitment (fundingAsset).
    /// @return The user commitment cap.
    function userCommitmentCap() external view returns (uint256);
    /// @notice Per-epoch exit capacity as a fraction of the protocol cap, in bps.
    /// @return The exit cap in bps.
    function exitCapBps() external view returns (uint256);
    /// @notice Minimum margin deposit (marginAsset).
    /// @return The minimum deposit.
    function minDepositAssets() external view returns (uint256);
    /// @notice Whether emergency shutdown has been triggered.
    /// @return True if shut down.
    function shutdownActive() external view returns (bool);
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
