// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IMorphoBlue} from "./IMorphoBlue.sol";

/// @title ILCCLeveragedFundHelper
/// @notice Self-service amortizing capital-call funding that borrows part of the obligation on canonical Morpho Blue
/// against the USD3l the funding delivers.
/// @dev The helper pins the Morpho singleton, USDC, USD3, and USD3l, and serves any market on that singleton whose
/// loan token is USDC and collateral token is USD3l. The market's oracle, IRM, and LLTV are chosen by the caller among
/// markets its curator created; the helper does not vet them.
interface ILCCLeveragedFundHelper {
    /// @param vault Factory-registered LCC vault whose current-epoch obligation the caller funds.
    /// @param market Morpho Blue market lending USDC against USD3l in which the caller's collateral is supplied and
    /// from which `borrowAssets` is borrowed.
    /// @param borrowAssets USDC borrowed from `market` on behalf of the caller; zero borrows nothing. An entry is fully
    /// levered when `borrowAssets` equals `fundingAmount = max(obligation, usd3.previewMint(1))`, which includes the
    /// one-share top-up; on a dust obligation `borrowAssets = obligation` with `maxContribution = 0` therefore reverts
    /// `ContributionExceedsMax`.
    /// @param maxContribution Maximum USDC pulled from the caller (funding amount minus `borrowAssets`).
    /// @param maxEntryLtv Maximum loan-to-value of the caller's whole position in `market` after a levered
    /// entry, WAD-scaled like Morpho's LLTV. Checked only when `borrowAssets` is nonzero; an unlevered entry only adds
    /// collateral and never reads the market oracle.
    /// @param maxObligation Maximum capital-call obligation the caller accepts to fund.
    /// @param deadline Last timestamp at which the call may execute.
    struct FundParams {
        address vault;
        IMorphoBlue.MarketParams market;
        uint256 borrowAssets;
        uint256 maxContribution;
        uint256 maxEntryLtv;
        uint256 maxObligation;
        uint256 deadline;
    }

    /// @notice EIP-2612 permit signed by the caller for this helper as spender.
    /// @dev `fundWithSignatures` always submits the USD3l permit, and the USDC permit whenever the USDC contribution is
    /// nonzero, so when one applies it replaces the caller's standing allowance to this helper with `value`. A caller
    /// whose standing allowance already suffices should use `fund`, or sign for the allowance it wants to stand after
    /// the call.
    /// @dev `value` must cover the amount pulled at execution: the USDC contribution or the USD3l collateral. The USDC
    /// contribution is `fundingAmount - borrowAssets`; a fully levered entry (see `FundParams.borrowAssets`) pulls no
    /// USDC, and its USDC permit is ignored.
    /// Both are computed from the obligation, the `usd3.previewMint(1)` top-up, and USD3 previews at inclusion time,
    /// which can move between signing and inclusion (for example after a USD3 report), so signers should over-approve
    /// or sign the maximum they accept.
    struct PermitSignature {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    error InvalidConfiguration();
    error UnregisteredVault();
    error VaultAssetMismatch();
    error MarginAssetIsCollateral();
    error MarketTokenMismatch();
    error NotFundingPhase();
    error FundingTopUpExceeded(uint256 fundingAmount, uint256 obligation);
    error NotAuthorized();
    error DeadlineExpired();
    error NoObligation();
    error ObligationExceedsMax(uint256 obligation, uint256 maximum);
    error BorrowExceedsFunding(uint256 borrowAssets, uint256 fundingAmount);
    error ContributionExceedsMax(uint256 contribution, uint256 maximum);
    error EntryLtvExceeded(uint256 ltv, uint256 maximum);
    error CollateralPreviewMismatch(uint256 previewed, uint256 minted);
    error FundingMismatch();
    error NotMorpho();
    error NoOperationInFlight();
    error OperationMismatch();
    error CallbackNotExecuted();
    error InvalidAuthorization();
    error AuthorizationFailed();
    error InsufficientAllowance(address token, uint256 allowance, uint256 required, bytes permitRevert);

    function morpho() external view returns (address);
    function factory() external view returns (address);
    function usdc() external view returns (address);
    function usd3() external view returns (address);
    function usd3l() external view returns (address);

    /// @notice Funds the caller's current-epoch obligation in `params.vault`, borrowing `params.borrowAssets` against
    /// the USD3l the funding delivers. Requires a prior USD3l allowance to this helper; a USDC allowance only when
    /// `fundingAmount` exceeds `params.borrowAssets` (a fully levered entry pulls no USDC); and, when
    /// `params.borrowAssets` is nonzero, a Morpho authorization of this helper by the caller (`NotAuthorized`
    /// otherwise). Reverts before moving tokens unless the vault is in its Funding phase and the USD3 one-share top-up
    /// stays within the vault's limit.
    /// @dev The vault replays the caller's account under its bounded step limit inside `fundCall`, while the helper
    /// reads the obligation through the vault's unbounded view replay, so an account stale by more than
    /// `MAX_MATERIALIZE_STEPS` called epochs should call the vault's `materializeAccount` first; otherwise the entry
    /// reverts `AccountMaterializationIncomplete` after the replay cost is paid.
    /// @return obligation The obligation funded.
    /// @return fundingAmount USDC delivered to the vault: the obligation, or USD3's one-share minimum if larger.
    /// @return collateral USD3l supplied as Morpho collateral on behalf of the caller.
    function fund(FundParams calldata params)
        external
        returns (uint256 obligation, uint256 fundingAmount, uint256 collateral);

    /// @notice Applies the caller's USDC permit, USD3l permit, and, when `params.borrowAssets` is nonzero and the
    /// caller has not yet authorized this helper on Morpho, enabling Morpho authorization, then runs `fund`. Otherwise
    /// the authorization arguments are ignored and may be zeroed.
    /// @dev The USD3l permit, and the USDC permit when the USDC contribution is nonzero, are always submitted; one that
    /// applies replaces the standing allowance with its `value`, which must cover the amount pulled at execution. A
    /// fully levered entry ignores its USDC permit and leaves the standing USDC allowance untouched. The amount pulled
    /// can differ from the amount at signing (see `PermitSignature`). A signature that fails to apply is tolerated
    /// when the allowance or authorization it grants is already in place, so a third party submitting the same
    /// signature first cannot make this call revert. The vault replays the caller's account under its bounded step
    /// limit inside `fundCall`, while the helper reads the obligation through the vault's unbounded view replay, so an
    /// account stale by more than `MAX_MATERIALIZE_STEPS` called epochs should call the vault's `materializeAccount`
    /// first; otherwise the entry reverts `AccountMaterializationIncomplete` after the replay cost is paid.
    function fundWithSignatures(
        FundParams calldata params,
        PermitSignature calldata usdcPermit,
        PermitSignature calldata usd3lPermit,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    ) external returns (uint256 obligation, uint256 fundingAmount, uint256 collateral);
}
