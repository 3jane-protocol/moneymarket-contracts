// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title ErrorsLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Library exposing custom errors.
library ErrorsLib {
    /// @notice Thrown when the caller is not the owner.
    error NotOwner();

    /// @notice Thrown when the caller is not the market's credit line.
    error NotCreditLine();

    /// @notice Thrown when the caller is not the market's helper.
    error NotHelper();

    /// @notice Thrown when the caller is not the market's usd3.
    error NotUsd3();

    /// @notice Thrown when the caller is not the owner or ozd.
    error NotOwnerOrOzd();

    /// @notice Thrown when the user is unverified.
    error Unverified();

    /// @notice Thrown when the LLTV to enable exceeds the maximum LLTV.
    error MaxLltvExceeded();

    /// @notice Thrown when the LTV to enable exceeds the maximum LTV.
    error MaxLtvExceeded();

    /// @notice Thrown when the VV to enable exceeds the maximum VV.
    error MaxVvExceeded();

    /// @notice Thrown when the credit to enable exceeds the maximum credit.
    error MaxCreditLineExceeded();

    /// @notice Thrown when the credit to enable is below the minimum credit.
    error MinCreditLineExceeded();

    /// @notice Thrown when the fee to set exceeds the maximum fee.
    error MaxFeeExceeded();

    /// @notice Thrown when the value is already set.
    error AlreadySet();

    /// @notice Thrown when the IRM is not enabled at market creation.
    error IrmNotEnabled();

    /// @notice Thrown when the LLTV is not enabled at market creation.
    error LltvNotEnabled();

    /// @notice Thrown when the market is already created.
    error MarketAlreadyCreated();

    /// @notice Thrown when a token to transfer doesn't have code.
    error NoCode();

    /// @notice Thrown when the market is not created.
    error MarketNotCreated();

    /// @notice Thrown when not exactly one of the input amount is zero.
    error InconsistentInput();

    /// @notice Thrown when zero assets is passed as input.
    error ZeroAssets();

    /// @notice Thrown when a zero address is passed as input.
    error ZeroAddress();

    /// @notice Thrown when the caller is not authorized to conduct an action.
    error Unauthorized();

    /// @notice Thrown when the collateral is insufficient to `borrow` or `withdrawCollateral`.
    error InsufficientCollateral();

    /// @notice Thrown when the liquidity is insufficient to `withdraw` or `borrow`.
    error InsufficientLiquidity();

    /// @notice Thrown when the position to liquidate is healthy.
    error HealthyPosition();

    /// @notice Thrown when the authorization signature is invalid.
    error InvalidSignature();

    /// @notice Thrown when the authorization signature is expired.
    error SignatureExpired();

    /// @notice Thrown when the nonce is invalid.
    error InvalidNonce();

    /// @notice Thrown when a token transfer reverted.
    error TransferReverted();

    /// @notice Thrown when a token transfer returned false.
    error TransferReturnedFalse();

    /// @notice Thrown when a token transferFrom reverted.
    error TransferFromReverted();

    /// @notice Thrown when a token transferFrom returned false
    error TransferFromReturnedFalse();

    /// @notice Thrown when the maximum uint128 is exceeded.
    error MaxUint128Exceeded();

    /// @notice Thrown when the premium rate exceeds the maximum allowed.
    error MaxDrpExceeded();

    /// @notice Thrown when the borrower has outstanding repayment obligations.
    error OutstandingRepayment();

    /// @notice Thrown when the protocol is paused.
    error Paused();

    /// @notice Thrown when trying to close a future cycle.
    error CannotCloseFutureCycle();

    /// @notice Thrown when cycle duration is invalid.
    error InvalidCycleDuration();

    /// @notice Thrown when no payment cycles exist.
    error NoCyclesExist();

    /// @notice Thrown when cycle ID is invalid.
    error InvalidCycleId();

    /// @notice Thrown when partial payment is attempted but full obligation payment is required.
    error MustPayFullObligation();

    /// @notice Thrown when repayment basis points exceed 100%.
    error RepaymentExceedsHundredPercent();

    /// @notice Thrown when an invalid markdown manager is set.
    error InvalidMarkdownManager();

    /// @notice Thrown when trying to settle non-existent debt.
    error NoAccountToSettle();
}
