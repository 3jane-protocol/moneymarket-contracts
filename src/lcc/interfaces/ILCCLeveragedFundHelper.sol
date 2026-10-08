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

    /// @param market Morpho Blue market lending USDC against USD3l that holds the caller's position.
    /// @param shares USD3l collateral shares to withdraw and redeem; at most the caller's live collateral in `market`
    /// and, unless the USD3l cooldown is waived, at most the caller's matured ticket shares there.
    /// @param full Repay the caller's whole debt in `market`, priced on-chain after accruing interest and repaid by
    /// shares; `repayAssets` is then ignored.
    /// @param repayAssets USDC of debt to repay when `full` is false; at most the current debt. It is converted to
    /// borrow shares rounding down (a nonzero amount buying no share reverts `RepayRoundsToZero`) and repaid by shares,
    /// so the
    /// amount actually repaid is those shares' value rounded up, at most `repayAssets`. Zero repays nothing.
    /// @param maxRepayAssets Maximum USDC the repayment may cost.
    /// @param minUsdcOut Minimum USDC sent to the caller: the redemption proceeds less the repayment.
    /// @param deadline Last timestamp at which the call may execute.
    struct UnwindParams {
        IMorphoBlue.MarketParams market;
        uint256 shares;
        bool full;
        uint256 repayAssets;
        uint256 maxRepayAssets;
        uint256 minUsdcOut;
        uint256 deadline;
    }

    /// @notice A cooldown ticket for USD3l collateral one funding entry supplied. It matures at
    /// `start + max(duration, live USD3l cooldownDuration)` and never expires.
    struct Ticket {
        uint128 shares;
        uint64 start;
        uint64 duration;
    }

    /// @notice A funding entry opened a ticket for the collateral it supplied.
    event TicketOpened(address indexed user, bytes32 indexed marketId, uint256 shares, uint256 start, uint256 duration);
    /// @notice A funding entry found the book full and merged the two oldest tickets into the ticket at `index` (0);
    /// the values are the merged ticket's totals, carrying the later of the two maturities. The entry's own ticket is
    /// then opened in the freed last slot (`TicketOpened`).
    event TicketMerged(
        address indexed user, bytes32 indexed marketId, uint256 index, uint256 shares, uint256 start, uint256 duration
    );
    event TicketCancelled(address indexed user, bytes32 indexed marketId, uint256 index, uint256 shares);
    event TicketsConsumed(address indexed user, bytes32 indexed marketId, uint256 shares);
    event Unwound(
        address indexed user, bytes32 indexed marketId, uint256 repaidAssets, uint256 shares, uint256 usdcOut
    );

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
    error InvalidUnwindShares();
    error SharesExceedCollateral(uint256 shares, uint256 collateral);
    error InsufficientMaturedShares(uint256 requested, uint256 matured);
    error RepayExceedsDebt(uint256 repayAssets, uint256 debt);
    error RepayExceedsMax(uint256 repayAssets, uint256 maximum);
    error UnwindOutputBelowMinimum(uint256 usdcOut, uint256 minimum);
    error UnwindProceedsBelowRepayment(uint256 received, uint256 repayment);
    error RepayRoundsToZero(uint256 repayAssets);
    error UnknownTicket(uint256 index);

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

    /// @notice Withdraws `params.shares` of the caller's USD3l collateral from `params.market`, repays the requested
    /// debt with a Morpho flash loan of that amount, redeems the withdrawn USD3l to USDC through USD3 under this
    /// helper's USD3l cooldown bypass, repays the flash loan, and sends the rest to the caller. Requires the caller's
    /// Morpho authorization of this helper (`NotAuthorized` otherwise) and, unless the USD3l cooldown is waived (shut
    /// down or zero), matured tickets covering `params.shares`, consumed oldest first. With nothing to repay no flash
    /// loan is taken. A partial unwind leaves debt, so Morpho's health check (and the market oracle) applies to the
    /// withdrawal. USD3's own withdraw limit (pending loss, waUSDC liquidity, ring fence, floors) and the bypass grant
    /// can make the redemption revert; the whole call then reverts and the tickets are restored. Debt is always repaid
    /// by shares; redemption proceeds below the flash-loaned repayment revert `UnwindProceedsBelowRepayment`.
    /// @return repaidAssets USDC of debt repaid: the repaid shares' value rounded up, which the flash loan covers.
    /// @return sharesRedeemed USD3l collateral shares withdrawn and redeemed.
    /// @return usdcOut USDC sent to the caller.
    function unwind(UnwindParams calldata params)
        external
        returns (uint256 repaidAssets, uint256 sharesRedeemed, uint256 usdcOut);

    /// @notice `unwind` that first applies the caller's enabling Morpho authorization of this helper when it is not
    /// already in place, with the same tolerance as `fundWithSignatures`; otherwise the authorization is ignored.
    function unwindWithAuthorization(
        UnwindParams calldata params,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    ) external returns (uint256 repaidAssets, uint256 sharesRedeemed, uint256 usdcOut);

    /// @notice Removes the caller's ticket at `index` in market `marketId`, keeping the rest in order.
    function cancelTicket(bytes32 marketId, uint256 index) external;

    /// @notice `user`'s open tickets in market `marketId`, oldest first.
    function tickets(address user, bytes32 marketId) external view returns (Ticket[] memory);

    /// @notice Shares of `user`'s tickets in market `marketId` matured at the live USD3l cooldown.
    function maturedShares(address user, bytes32 marketId) external view returns (uint256);

    /// @notice The most shares `user` can unwind in market `marketId` by the ticket gate and live collateral; USD3's
    /// withdraw limit and Morpho's health check are not included.
    function maxUnwindable(address user, bytes32 marketId) external view returns (uint256);
}
