// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {ILCCVault} from "../interfaces/ILCCVault.sol";

/// @title LCCTypesLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Library exposing implementation-only LCC vault types.
library LCCTypesLib {
    /// @notice Packed pause circuit-breaker state; effective time excludes accumulated paused seconds.
    /// @param guardian Address allowed to pause alongside the owner (zero disables the guardian).
    /// @param paused True while the vault clock and all synced entrypoints are frozen.
    /// @param pausedAt Wall timestamp of the active or most recently completed pause.
    /// @param pausedAccumulated Total wall seconds spent paused over the vault's lifetime.
    struct PauseState {
        address guardian;
        bool paused;
        uint48 pausedAt;
        uint40 pausedAccumulated;
    }

    /// @notice Packed epoch clock and phase durations.
    struct ClockConfig {
        uint64 startTimestamp;
        uint64 maxEpochs;
        uint32 epochLength;
        uint32 normalDuration;
        uint32 preCallDuration;
        uint32 fundingDuration;
    }

    /// @notice Packed facility asset parameters.
    struct AssetConfigStorage {
        address marginAsset;
        uint16 marginRatioBps;
        uint16 exitDelayEpochs;
        uint16 minCommitmentEpochs;
    }

    /// @notice Packed facility oracle and auction parameters.
    struct AuctionConfigStorage {
        address marginOracle;
        uint32 auctionStepCount;
        uint16 auctionStepDecayRateBps;
        uint32 auctionStepDuration;
    }

    /// @notice Packed implementation form of the global sync cursors and live-auction slot.
    /// @dev Activation and maturity folds advance together, so one watermark backs both fields in the external view.
    struct SyncStateStorage {
        uint64 lastFolded;
        uint64 finalizedCallPrefix;
        uint64 pendingAuctionEpochPlusOne;
    }

    /// @notice Packed margin and commitment amounts for an activation or exit-maturity epoch.
    struct Bucket {
        uint128 margin;
        uint128 commitment;
    }

    /// @notice Packed on-chain form of {ILCCVault.Account}.
    /// @dev Fields carry the same meaning as `Account`; amounts pack into uint128 and epochs/cursor into uint64.
    /// Deposits revert on the cast if an amount exceeds its width.
    struct AccountStorage {
        uint128 activeMargin;
        uint128 activeCommitment;
        uint128 pendingMargin;
        uint128 pendingCommitment;
        uint128 claimableExitMargin;
        uint128 exitBucketMargin;
        uint128 exitBucketCommitment;
        uint64 pendingActivationEpoch;
        uint64 calledEpochCursor;
        uint64 exitMaturityEpoch;
        bool exitRequested;
        bool exitClaimed;
        bool exitMatured;
        // Later of the latest deposit activation and one epoch after the call that produced the latest nonzero
        // return-pool re-credit; funding never touches it.
        uint64 commitmentStartEpoch;
    }

    /// @notice Per-(call epoch, maturity epoch) snapshot of exiting users' exposure, used to carve defaulted
    /// exiters out of their maturity buckets at slash time so each user's exposure leaves global totals once.
    /// @param margin Exiting margin exposed to the call at snapshot (marginAsset).
    /// @param commitment Exiting commitment exposed to the call at snapshot (fundingAsset).
    /// @param fundedAmount Of that exposure, the portion funded before maturity (fundingAsset).
    /// @param marginReleased Margin released to those funders (marginAsset).
    /// @param fundedUsersRemainingMargin Remaining margin of those funders after their proportional release
    /// (marginAsset).
    /// @param fundedUsersRemainingCommitment Remaining commitment of those funders after funding (fundingAsset).
    /// Rolled funding never appears in this struct — a live exiter cannot roll — so unlike the epoch-level
    /// counter these are exact live-position values, which the slash carve-out relies on.
    /// @param listed Whether this maturity has been recorded for the call (avoids duplicate tracking).
    struct ExitExposure {
        uint128 margin;
        uint128 commitment;
        uint128 fundedAmount;
        uint128 marginReleased;
        uint128 fundedUsersRemainingMargin;
        uint128 fundedUsersRemainingCommitment;
        bool listed;
    }

    /// @notice A default discovered during account replay, to be persisted/emitted by the mutating caller.
    /// @param epoch Epoch the account defaulted on.
    /// @param slashedMargin Margin forfeited (marginAsset).
    /// @param slashedCommitment Commitment removed (fundingAsset).
    /// @param returnMarginShare Return-pool margin credited back for this default (marginAsset).
    /// @param returnCommitmentShare Return-pool commitment credited back for this default (fundingAsset).
    struct DefaultRecord {
        uint256 epoch;
        uint256 slashedMargin;
        uint256 slashedCommitment;
        uint256 returnMarginShare;
        uint256 returnCommitmentShare;
    }

    /// @notice Result of replaying an account forward over the called-epoch list.
    /// @param account The materialized account after replay.
    /// @param defaults Defaults discovered during this replay (only populated in the bounded/recording mode).
    /// @param defaultCount Number of valid entries in `defaults`.
    /// @param complete True if replay caught the account up to the finalized prefix within the step bound.
    struct AccountReplay {
        ILCCVault.Account account;
        DefaultRecord[] defaults;
        uint256 defaultCount;
        bool complete;
    }
}
