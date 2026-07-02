// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILeveragedCallableCreditVault} from "../interfaces/ILeveragedCallableCreditVault.sol";

/// @title LCCTypesLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Library exposing implementation-only Leveraged Callable Credit vault types.
library LCCTypesLib {
    /// @notice Packed on-chain form of {ILeveragedCallableCreditVault.Account}.
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
    }

    /// @notice Per-(call epoch, maturity epoch) snapshot of exiting users' exposure, used to carve defaulted
    /// exiters out of their maturity buckets at slash time so each user's exposure leaves global totals once.
    /// @param margin Exiting margin exposed to the call at snapshot (marginAsset).
    /// @param commitment Exiting commitment exposed to the call at snapshot (fundingAsset).
    /// @param fundedAmount Of that exposure, the portion funded before maturity (fundingAsset).
    /// @param marginReleased Margin released to those funders (marginAsset).
    /// @param fundedUsersRemainingMargin Remaining callable margin of those funders (marginAsset).
    /// @param fundedUsersRemainingCommitment Remaining active commitment of those funders (fundingAsset).
    /// @param listed Whether this maturity has been recorded for the call (avoids duplicate tracking).
    struct ExitExposure {
        uint256 margin;
        uint256 commitment;
        uint256 fundedAmount;
        uint256 marginReleased;
        uint256 fundedUsersRemainingMargin;
        uint256 fundedUsersRemainingCommitment;
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
        ILeveragedCallableCreditVault.Account account;
        DefaultRecord[] defaults;
        uint256 defaultCount;
        bool complete;
    }
}
