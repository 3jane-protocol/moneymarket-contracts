// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IMorphoBlue} from "./IMorphoBlue.sol";

/// @title ILCCLeveragedFundHelper
/// @notice Self-service amortizing capital-call funding that borrows part of the obligation on canonical Morpho Blue
/// against the USD3l the funding delivers.
/// @dev The helper pins the Morpho singleton and USD3l, derives USD3 and USDC from USD3l's asset chain, and serves any
/// market on that singleton whose loan token is USDC and collateral token is USD3l. The market's oracle, IRM, and LLTV
/// are chosen by the caller among markets its curator created; the helper does not vet them. An entry that borrows or
/// uses released margin bridges `borrowAssets + marginAssets` with a Morpho flash loan, repaid by the borrow and by
/// USDC withdrawn from the caller's margin-asset shares, so the singleton must physically hold
/// `2 * borrowAssets + marginAssets` of USDC during the entry (the flash loan, then the borrow). An entry with neither
/// never touches the flash loan. Only an entry that borrows reads the market oracle or needs Morpho authorization.
interface ILCCLeveragedFundHelper {
    /// @param vault Factory-registered LCC vault whose current-epoch obligation the caller funds.
    /// @param market Morpho Blue market lending USDC against USD3l in which the caller's collateral is supplied and
    /// from which `borrowAssets` is borrowed.
    /// @param borrowAssets USDC borrowed from `market` on behalf of the caller; zero borrows nothing. An entry is fully
    /// levered when `borrowAssets` equals `fundingAmount = max(obligation, usd3.previewMint(1))`, which includes the
    /// one-share top-up; on a dust obligation `borrowAssets = obligation` with `maxContribution = 0` therefore reverts
    /// `ContributionExceedsMax`.
    /// @param marginAssets USDC the caller sources from margin-asset shares toward the funding, intended to come from
    /// the margin the vault releases to the caller inside `fundCall`; zero uses no margin and never calls the margin
    /// asset.
    /// When nonzero, the vault's margin asset must be an ERC-4626 vault whose `asset()` is USDC
    /// (`MarginAssetNotUsdcVault` otherwise). The helper withdraws exactly `marginAssets` after the margin is released;
    /// the shares burned, measured as the caller's balance change, may exceed neither `maxMarginShares`
    /// (`MarginSharesExceedMax`) nor the shares the vault released to the caller in this entry
    /// (`MarginExceedsReleased`), so a pre-existing margin-asset balance is never consumed.
    /// @param maxMarginShares Maximum margin-asset shares the withdrawal may burn; must be nonzero when `marginAssets`
    /// is. The caller's margin-asset allowance or permit must cover it.
    /// @param maxContribution Maximum USDC pulled from the caller (funding amount minus `borrowAssets` and
    /// `marginAssets`).
    /// @param minCollateral Minimum USD3l the vault must deliver to the caller for this funding; must be nonzero and at
    /// most `maxCollateral`. Integrators set it just under `usd3l.previewDeposit(usd3.previewDeposit(fundingAmount))`.
    /// @param maxCollateral Maximum USD3l supplied as collateral and pulled from the caller; any delivery above it
    /// stays in the caller's wallet. Integrators set it at or just above the preview and sign the USD3l permit for it.
    /// @param maxEntryLtv Maximum loan-to-value of the caller's whole position in `market` after a levered
    /// entry, WAD-scaled like Morpho's LLTV. Checked only when `borrowAssets` is nonzero; an unlevered entry only adds
    /// collateral and never reads the market oracle.
    /// @param maxObligation Maximum capital-call obligation the caller accepts to fund.
    /// @param deadline Last timestamp at which the call may execute.
    struct FundParams {
        address vault;
        IMorphoBlue.MarketParams market;
        uint256 borrowAssets;
        uint256 marginAssets;
        uint256 maxMarginShares;
        uint256 maxContribution;
        uint256 minCollateral;
        uint256 maxCollateral;
        uint256 maxEntryLtv;
        uint256 maxObligation;
        uint256 deadline;
    }

    /// @notice EIP-2612 permit signed by the caller for this helper as spender.
    /// @dev `fundWithSignatures` always submits the USD3l permit, the USDC permit whenever the USDC contribution is
    /// nonzero, and the margin-asset permit whenever `marginAssets` is nonzero, so when one applies it replaces the
    /// caller's standing allowance to this helper with `value`. A caller whose standing allowance already suffices
    /// should use `fund`, or sign for the allowance it wants to stand after
    /// the call.
    /// @dev `value` must cover the amount pulled at execution. The USDC contribution is `fundingAmount - borrowAssets -
    /// marginAssets`; a fully levered entry (see `FundParams.borrowAssets`) pulls no USDC, and its USDC permit is
    /// ignored. The contribution depends on the obligation and the `usd3.previewMint(1)` top-up at inclusion time,
    /// which can move between signing and inclusion (for example after a USD3 report), so signers should over-approve.
    /// The USD3l pulled is at most `FundParams.maxCollateral`, and the USD3l permit is checked against that value
    /// before any funding, so signers sign it for `maxCollateral`. The margin-asset permit is checked against
    /// `FundParams.maxMarginShares`, so signers sign it for that value.
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
    error BorrowAndMarginExceedFunding(uint256 borrowAssets, uint256 marginAssets, uint256 fundingAmount);
    error InvalidMarginShares();
    error MarginAssetNotUsdcVault(address marginAsset);
    error MarginSharesExceedMax(uint256 shares, uint256 maximum);
    error MarginExceedsReleased(uint256 burned, uint256 released);
    error MarginReceiptMismatch(uint256 received, uint256 expected);
    error ContributionExceedsMax(uint256 contribution, uint256 maximum);
    error EntryLtvExceeded(uint256 ltv, uint256 maximum);
    error CollateralBelowMinimum(uint256 collateral, uint256 minimum);
    error InvalidCollateralBounds(uint256 minCollateral, uint256 maxCollateral);
    error FundingMismatch();
    error NotMorpho();
    error NoOperationInFlight();
    error OperationMismatch();
    error CallbackNotExecuted();
    error InvalidAuthorization();
    error AuthorizationFailed();
    error InsufficientAllowance(address token, uint256 allowance, uint256 required, bytes permitRevert);

    /// @notice Canonical Morpho Blue singleton.
    function morpho() external view returns (address);
    /// @notice LCC vault factory whose registered vaults may be funded.
    function factory() external view returns (address);
    /// @notice USDC, derived as `usd3().asset()`: the funding asset and every served market's loan token.
    function usdc() external view returns (address);
    /// @notice USD3, derived as `usd3l().asset()`.
    function usd3() external view returns (address);
    /// @notice USD3l, the notification vault wrapping USD3 and every served market's collateral token.
    function usd3l() external view returns (address);

    /// @notice Funds the caller's current-epoch obligation in `params.vault`, borrowing `params.borrowAssets` against
    /// the USD3l the funding delivers. Requires a prior USD3l allowance to this helper covering
    /// `params.maxCollateral`; a USDC allowance covering the contribution only when the contribution is nonzero (a
    /// fully levered entry pulls no USDC); a margin-asset share allowance covering `params.maxMarginShares` only when
    /// `params.marginAssets` is nonzero; and, when `params.borrowAssets` is nonzero, a Morpho authorization of this
    /// helper by the caller (`NotAuthorized` otherwise). A short USDC, USD3l, or margin-asset allowance reverts with
    /// `InsufficientAllowance` before any funding. Reverts before moving tokens unless the vault is in its
    /// Funding phase and the USD3 one-share top-up stays within the vault's limit.
    /// @dev The vault replays the caller's account under its bounded step limit inside `fundCall`, while the helper
    /// reads the obligation through the vault's unbounded view replay, so an account stale by more than
    /// `MAX_MATERIALIZE_STEPS` called epochs should call the vault's `materializeAccount` first; otherwise the entry
    /// reverts `AccountMaterializationIncomplete` after the replay cost is paid.
    /// @return obligation The obligation funded.
    /// @return fundingAmount USDC delivered to the vault: the obligation, or USD3's one-share minimum if larger.
    /// @return collateral USD3l supplied as Morpho collateral on behalf of the caller, at most `params.maxCollateral`.
    function fund(FundParams calldata params)
        external
        returns (uint256 obligation, uint256 fundingAmount, uint256 collateral);

    /// @notice Applies the caller's USDC permit, USD3l permit, margin-asset permit when `params.marginAssets` is
    /// nonzero, and, when `params.borrowAssets` is nonzero and the caller has not yet authorized this helper on Morpho,
    /// enabling Morpho authorization, then runs `fund`. Otherwise the margin permit and the authorization arguments
    /// are ignored and may be zeroed.
    /// @dev The USD3l permit, the USDC permit when the USDC contribution is nonzero, and the margin-asset permit when
    /// `params.marginAssets` is nonzero are always submitted; one that applies replaces the standing allowance with
    /// its `value`, which must cover the amount pulled at execution. A fully levered entry ignores its USDC permit and
    /// leaves the standing USDC allowance untouched; an entry without margin leaves the margin-asset allowance
    /// untouched. The amount pulled
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
        PermitSignature calldata marginPermit,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    ) external returns (uint256 obligation, uint256 fundingAmount, uint256 collateral);
}
