// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

/// @title LCCErrorsLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Library exposing LCC vault errors.
library LCCErrorsLib {
    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();
    /// @notice Thrown when an action is restricted to the owner.
    error NotOwner();
    /// @notice Thrown when an input parameter is outside its valid range.
    error InvalidParams();
    /// @notice Thrown when a wall-clock transaction deadline has expired.
    error DeadlineExpired();
    /// @notice Thrown when an action is attempted that is blocked by emergency shutdown.
    error ShutdownActive();
    /// @notice Thrown when a state-transitioning action is attempted while the vault is paused.
    error Paused();
    /// @notice Thrown when pausing a vault that is already paused.
    error AlreadyPaused();
    /// @notice Thrown when unpausing a vault that is not paused.
    error NotPaused();
    /// @notice Thrown when a caller is not authorized for the action.
    error Unauthorized();
    /// @notice Thrown when a new call, deposit, or exit request is attempted after scheduled sunset.
    error VaultTerminal();
    /// @notice Thrown when an exit request would create more tracked maturity buckets than the vault supports.
    error ExitCapacityReached();
    /// @notice Thrown when an exit cannot be assigned within the caller's maximum accepted deferral.
    error ExitDeferralExceeded();
    /// @notice Thrown when depositing while the account has a pending or unclaimed exit.
    error ExitInProgress();
    /// @notice Thrown when a deposit would exceed the protocol-wide or per-account commitment cap.
    error CapExceeded();
    /// @notice Thrown when an action is attempted in the wrong lifecycle phase.
    error InvalidPhase();
    /// @notice Thrown when the supplied epoch is not the current epoch, or the call is closed/finalized.
    error InvalidEpoch();
    /// @notice Thrown when opening a call for an epoch that already has one.
    error CallAlreadyOpened();
    /// @notice Thrown when opening a call or depositing while an earlier call remains unsettled.
    error PriorCallUnsettled();
    /// @notice Thrown when an amount argument is zero or otherwise invalid for the operation.
    error InvalidAmount();
    /// @notice Thrown when the margin oracle returns a zero (unusable) price.
    error OraclePriceInvalid();
    /// @notice Thrown when funding an obligation that the user has already funded this epoch.
    error AlreadyFunded();
    /// @notice Thrown when minting one USD3 share would require more than the permitted funding top-up.
    error FundingTopUpExcessive();
    /// @notice Thrown when USD3 cannot mint any shares because it reports zero assets with supply outstanding.
    error FundingDeliveryImpossible();
    /// @notice Thrown when there is nothing to claim for the caller.
    error NothingToClaim();
    /// @notice Thrown when claiming an exit that was never requested (or already claimed).
    error NoExitRequested();
    /// @notice Thrown when claiming an exit before its maturity epoch.
    error ExitNotMature();
    /// @notice Thrown when requesting an exit before the minimum commitment period has elapsed.
    error CommitmentNotMature();
    /// @notice Thrown when finalizing a slash for an epoch that is not yet slash-eligible.
    error SlashNotEligible();
    /// @notice Thrown when a wind-down withdrawal is attempted before shutdown or terminal sunset.
    error NotWithdrawable();
    /// @notice Thrown when taking an auction that is not currently live.
    error AuctionNotLive();
    /// @notice Thrown when requesting an exit while the account still holds a pending (not-yet-active) deposit.
    error PendingDepositExists();
    /// @notice Thrown when an account cannot be fully materialized within the per-call step bound.
    error AccountMaterializationIncomplete();
}
