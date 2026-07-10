// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

/// @title LCCEventsLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Library exposing LCC vault events.
library LCCEventsLib {
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
    /// @param payer Account supplying the funding asset.
    /// @param user Account whose obligation was funded.
    /// @param epoch Epoch funded.
    /// @param obligationAmount Obligation paid (fundingAsset).
    /// @param fundingAmount Actual funding asset pulled and delivered, including any bounded dust top-up.
    event CallFunded(
        address indexed payer,
        address indexed user,
        uint256 indexed epoch,
        uint256 obligationAmount,
        uint256 fundingAmount
    );

    /// @notice Emitted when backing margin is released to a funder.
    /// @param user Account receiving the released margin.
    /// @param epoch Epoch the funding settled for.
    /// @param marginAssets Margin released (marginAsset).
    event MarginReleased(address indexed user, uint256 indexed epoch, uint256 marginAssets);

    /// @notice Emitted when an account's unfunded obligation is materialized as a default.
    /// @param user Defaulted account.
    /// @param epoch Epoch defaulted on.
    /// @param slashedMargin Margin forfeited by this account (marginAsset).
    /// @param slashedCommitment Commitment removed by this default (fundingAsset).
    event UserDefaulted(address indexed user, uint256 indexed epoch, uint256 slashedMargin, uint256 slashedCommitment);

    /// @notice Emitted when a defaulted account receives returned slash surplus during materialization.
    /// @param user Defaulted account.
    /// @param epoch Epoch whose return pool was attributed.
    /// @param marginAssets Returned margin credited (marginAsset).
    /// @param commitment Returned commitment credited (fundingAsset).
    event ReturnPoolCredited(address indexed user, uint256 indexed epoch, uint256 marginAssets, uint256 commitment);

    /// @notice Emitted when unawarded slashed margin is disposed after any auction-award-based fee.
    /// @param epoch Epoch whose slash surplus was disposed.
    /// @param treasuryAmount Margin swept to treasury, including fee and unbacked remainder (marginAsset).
    /// @param returnPool Margin returned to defaulters for lazy attribution (marginAsset).
    /// @param returnCommitment Callable commitment created by `returnPool` (fundingAsset).
    event SlashSurplusDisposed(
        uint256 indexed epoch, uint256 treasuryAmount, uint256 returnPool, uint256 returnCommitment
    );

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

    /// @notice Emitted when remaining margin is withdrawn after shutdown or terminal sunset.
    /// @param user Withdrawing account.
    /// @param receiver Recipient of the margin.
    /// @param marginAssets Margin transferred (marginAsset).
    event RemainingMarginClaimed(address indexed user, address indexed receiver, uint256 marginAssets);

    /// @notice Emitted when the owner updates mutable risk caps.
    /// @param protocolCommitmentCap New vault-wide commitment cap (fundingAsset).
    /// @param userCommitmentCap New per-account commitment cap (fundingAsset).
    /// @param exitCapBps New per-epoch exit capacity, in bps.
    /// @param minDepositAssets New minimum margin deposit (marginAsset).
    event RiskCapUpdated(
        uint256 protocolCommitmentCap, uint256 userCommitmentCap, uint256 exitCapBps, uint256 minDepositAssets
    );

    /// @notice Emitted when emergency shutdown is triggered.
    /// @param epoch Epoch in which shutdown occurred.
    /// @param timestamp Pause-adjusted effective timestamp of shutdown.
    event EmergencyShutdown(uint256 indexed epoch, uint256 timestamp);

    /// @notice Emitted when the pause guardian or owner pauses the vault.
    /// @param by Account that paused the vault.
    event Paused(address indexed by);

    /// @notice Emitted when the owner unpauses the vault.
    /// @param by Account that unpaused the vault.
    event Unpaused(address indexed by);

    /// @notice Emitted when the owner updates the pause guardian.
    /// @param oldGuardian Previous guardian.
    /// @param newGuardian New guardian.
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

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
    event AuctionSettled(uint256 indexed epoch, uint256 filledAmount, uint256 marginAwarded);

    /// @notice Emitted when the owner updates the oracle-valued auction award cap.
    /// @param maxAuctionAwardBps New award cap per fundingAsset filled, in bps.
    event AuctionAwardCapUpdated(uint256 maxAuctionAwardBps);

    /// @notice Emitted when the owner updates the auction-award-based slash surplus fee.
    /// @param slashFeeBps New fee on auction-awarded slashed margin, clamped to unawarded surplus, in bps.
    event SlashFeeUpdated(uint256 slashFeeBps);

    /// @notice Emitted when the owner updates the trusted margin oracle.
    /// @param oldOracle Previous margin oracle.
    /// @param newOracle New margin oracle.
    event MarginOracleUpdated(address indexed oldOracle, address indexed newOracle);
}
