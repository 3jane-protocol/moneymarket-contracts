// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IMorphoBlue} from "./IMorphoBlue.sol";

/// @title ILCCLeveragedFundHelper
/// @notice Levered LCC positions on canonical Morpho Blue, in three lifecycles: amortizing capital-call funding
/// (`fund`), shortfall-auction fills (`takeAuction`), and unwinds of the resulting position (`unwind`). Both entries
/// supply the USD3l the vault delivers as the caller's collateral and can borrow part of the USDC paid against it.
/// @dev Common shape. The helper pins the Morpho singleton and USD3l, derives USD3 and USDC from USD3l's asset chain,
/// and serves any market on that singleton whose loan token is USDC and collateral token is USD3l. The market's
/// oracle, IRM, and LLTV are chosen by the caller among markets its curator created; the helper does not vet them. The
/// LCC beneficiary and the Morpho `onBehalf` are always the caller. Only an entry that borrows reads the market oracle
/// or needs Morpho authorization.
///
/// Fund. An entry that borrows or sources USDC from margin bridges `borrowAssets + marginAssets` with a Morpho flash
/// loan, repaid by the borrow and by USDC withdrawn from margin-asset shares, so the singleton must physically hold
/// `2 * borrowAssets + marginAssets` of USDC during the entry (the flash loan, then the borrow). An entry with neither
/// never touches the flash loan.
///
/// Take. The same holds for the scaled borrow and margin. The helper is the vault's filler, supplies all the USD3l
/// delivered to it, and its USD3l balance must end unchanged.
///
/// Cooldown book. Every entry opens a `Cooldown` for the collateral it supplied, at most `MAX_COOLDOWNS` per user and
/// market.
///
/// Unwind. A position closes from its collateral alone under the helper's USD3l cooldown bypass, up to the caller's
/// matured cooldowns; see `unwind`.
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
    /// and, unless the USD3l cooldown is waived, at most the caller's matured cooldown shares there.
    /// @param full Repay the caller's whole debt in `market`, priced on-chain after accruing interest and repaid by
    /// shares; `repayAssets` is then ignored.
    /// @param repayAssets USDC of debt to repay when `full` is false; at most the current debt. It is converted to
    /// borrow shares rounding down (a nonzero amount buying no share reverts `RepayRoundsToZero`) and repaid by shares,
    /// so the amount actually repaid is those shares' value rounded up, at most `repayAssets`. Zero repays nothing.
    /// @param maxRepayAssets Maximum USDC the repayment may cost.
    /// @param usd3Out Deliver the remainder as USD3 instead of USDC. Only the repayment is converted to USDC (through
    /// USD3's `withdraw`); with nothing to repay no USD3 is converted and USD3's withdraw limit is never read, so such
    /// an unwind works during a USD3 pending loss or waUSDC pause. USD3 carries no cooldown, which lives on USD3l.
    /// @param minOut Minimum amount of the output token sent to the caller: USD3 when `usd3Out`, USDC otherwise.
    /// @param deadline Last timestamp at which the call may execute.
    struct UnwindParams {
        IMorphoBlue.MarketParams market;
        uint256 shares;
        bool full;
        uint256 repayAssets;
        uint256 maxRepayAssets;
        bool usd3Out;
        uint256 minOut;
        uint256 deadline;
    }

    /// @dev Every quoted amount is quoted at `maxFill`. The fill is sized on-chain as `min(maxFill, remaining
    /// shortfall)` after the vault's sync, and every quoted amount is scaled by `fill / maxFill`, so a partial fill
    /// keeps the caller's per-unit protections. Dust rule: the quoted contribution (`maxFill - borrowAssets -
    /// marginAssets`) and `marginAssets` scale rounding down and the rounding dust goes to the borrow, else the margin,
    /// else the contribution, so the scaled borrow, margin, and contribution sum to the fill, a quote without a
    /// contribution pulls none, and the scaled borrow (or margin) may exceed its pro-rata share by up to two base
    /// units. `minMarginAward` scales rounding down, and `minCollateral` scales rounding down with a floor of one
    /// share. The contribution never exceeds the quoted one, so it carries no separate bound.
    /// @param vault Factory-registered LCC vault whose live shortfall auction the caller fills.
    /// @param market Morpho Blue market lending USDC against USD3l in which the delivered USD3l is supplied as the
    /// caller's collateral and from which the scaled borrow is borrowed.
    /// @param maxFill USDC the caller offers and the denominator of every scaled field; must be nonzero. Quote it near
    /// the expected remaining shortfall rather than `type(uint256).max`, or the scaled amounts lose their precision.
    /// @param minFill Smallest acceptable fill, at most `maxFill`; zero accepts any nonzero fill.
    /// @param borrowAssets USDC borrowed at `maxFill`; scaled to the fill, taking the rounding dust, so a nonzero quote
    /// always borrows. A take with zero `borrowAssets` needs no Morpho authorization and never reads the market oracle.
    /// @param marginAssets USDC sourced from the margin award at `maxFill`; scaled to the fill rounding down, or taking
    /// the rounding dust when `borrowAssets` is zero. Zero forwards the whole award to the caller. When nonzero, the
    /// vault's margin asset must be an ERC-4626 vault whose `asset()` is USDC (`MarginAssetNotUsdcVault` otherwise);
    /// the helper withdraws exactly the scaled amount from the award it received, burning no more shares than the
    /// award (`MarginExceedsAward`), and forwards the rest.
    /// @param minMarginAward Minimum margin award at `maxFill`, scaled to the fill rounding down (it is a floor, and
    /// the vault floors its award) and passed to the vault. The award is pro-rata in the fill, so the scaled bound
    /// keeps its per-unit meaning.
    /// @param minCollateral Minimum USD3l the vault must deliver at `maxFill`; must be nonzero. It scales rounding down
    /// with a floor of one share, because the delivery itself floors twice (USD3, then USD3l). Integrators quote it at
    /// `maxFill` from `usd3l.previewDeposit(usd3.previewDeposit(maxFill))` with slack, because the scaled quote and a
    /// live double preview at the fill differ by rounding. All delivered USD3l is supplied as collateral; a caller who
    /// wants part of it liquid withdraws unlevered collateral from Morpho afterwards.
    /// @param maxEntryLtv Maximum loan-to-value of the caller's whole position in `market` after the take, WAD-scaled
    /// like Morpho's LLTV; checked only when the scaled borrow is nonzero.
    /// @param deadline Last timestamp at which the call may execute.
    struct TakeParams {
        address vault;
        IMorphoBlue.MarketParams market;
        uint256 maxFill;
        uint256 minFill;
        uint256 borrowAssets;
        uint256 marginAssets;
        uint256 minMarginAward;
        uint256 minCollateral;
        uint256 maxEntryLtv;
        uint256 deadline;
    }

    /// @notice A cooldown for USD3l collateral one funding or take entry supplied. It matures at
    /// `start + max(duration, live USD3l cooldownDuration)` and never expires.
    struct Cooldown {
        uint128 shares;
        uint64 start;
        uint64 duration;
    }

    /// @notice A funding or take entry started a cooldown for the collateral it supplied.
    event CooldownStarted(
        address indexed user, bytes32 indexed marketId, uint256 shares, uint256 start, uint256 duration
    );
    /// @notice A funding or take entry found the book full and merged the two oldest cooldowns into the oldest slot;
    /// `shares` is their sum, `start` the later of their starts, and `duration` runs from that start to the later of
    /// their recorded maturities (`start + duration`), so the merged cooldown matures no earlier than either input
    /// under any live duration. The entry's own cooldown is then started in the freed last slot (`CooldownStarted`).
    event CooldownsMerged(
        address indexed user, bytes32 indexed marketId, uint256 shares, uint256 start, uint256 duration
    );
    /// @notice An unwind consumed `shares` from the user's matured cooldowns in `marketId`, oldest first.
    event CooldownsConsumed(address indexed user, bytes32 indexed marketId, uint256 shares);
    /// @notice An unwind repaid `repaidAssets` of debt, redeemed `shares` of collateral, and sent `amountOut` of
    /// `outToken` (USDC or USD3) to the caller.
    event Unwound(
        address indexed user,
        bytes32 indexed marketId,
        address outToken,
        uint256 repaidAssets,
        uint256 shares,
        uint256 amountOut
    );
    /// @notice A take filled `filled` USDC of `vault`'s live shortfall auction for `user`: `collateral` USD3l was
    /// supplied as the user's collateral in market `marketId`, `borrowed` USDC was borrowed for the user, and
    /// `marginAssets` USDC was withdrawn from the margin award. The vault's `AuctionFill` in the same transaction
    /// records the epoch and the gross award, and the margin-asset transfer to the user records the forwarded award.
    event AuctionTaken(
        address indexed user,
        address indexed vault,
        bytes32 indexed marketId,
        uint256 filled,
        uint256 collateral,
        uint256 borrowed,
        uint256 marginAssets
    );

    /// @notice EIP-2612 permit signed by the caller for this helper as spender.
    /// @dev `fundWithSignatures` always submits the USD3l permit, the USDC permit whenever the USDC contribution is
    /// nonzero, and the margin-asset permit whenever `marginAssets` is nonzero, so when one applies it replaces the
    /// caller's standing allowance to this helper with `value`. A caller whose standing allowance already suffices
    /// should use `fund`, or sign for the allowance it wants to stand after the call. `value` must cover the amount
    /// pulled at execution. The USDC contribution is `fundingAmount - borrowAssets -
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

    // Configuration and request validation
    error InvalidConfiguration();
    error UnregisteredVault();
    error VaultAssetMismatch();
    error MarginAssetIsCollateral();
    error MarginAssetNotUsdcVault(address marginAsset);
    error MarketTokenMismatch();
    error DeadlineExpired();
    error InvalidCollateralBounds(uint256 minCollateral, uint256 maxCollateral);
    error BorrowAndMarginExceedTotal(uint256 borrowAssets, uint256 marginAssets, uint256 total);
    error InvalidMarginShares();

    // Fund, and the entry checks takes share
    error NotFundingPhase();
    error FundingTopUpExceeded(uint256 fundingAmount, uint256 obligation);
    error NoObligation();
    error ObligationExceedsMax(uint256 obligation, uint256 maximum);
    error ContributionExceedsMax(uint256 contribution, uint256 maximum);
    /// @notice The vault funded or filled a different amount than requested, or left part of the helper's USDC
    /// allowance unused.
    error VaultAmountMismatch();
    error CollateralBelowMinimum(uint256 collateral, uint256 minimum);
    error MarginSharesExceedMax(uint256 shares, uint256 maximum);
    error MarginExceedsReleased(uint256 burned, uint256 released);
    error MarginReceiptMismatch(uint256 received, uint256 expected);
    error EntryLtvExceeded(uint256 ltv, uint256 maximum);

    // Take
    /// @notice `maxFill` is zero or `minFill` exceeds it.
    error InvalidFillBounds(uint256 minFill, uint256 maxFill);
    /// @notice A take was requested on a vault whose margin asset is USDC or USD3, which the take's balance
    /// measurements cannot tell apart from the fill, the flash loan, or the redemption chain.
    error TakeMarginAssetUnsupported(address marginAsset);
    /// @notice The vault has no live shortfall auction after its sync.
    error NoLiveAuction();
    error FillBelowMinimum(uint256 fill, uint256 minFill);
    /// @notice Withdrawing the award-sourced USDC burned more margin-asset shares than the award delivered.
    error MarginExceedsAward(uint256 burned, uint256 awardReceived);
    /// @notice A take left the helper holding USD3l it did not hold before.
    error Usd3lRetained(uint256 balance, uint256 expected);

    // Unwind
    error InvalidUnwindShares();
    error SharesExceedCollateral(uint256 shares, uint256 collateral);
    error InsufficientMaturedShares(uint256 requested, uint256 matured);
    error RepayExceedsDebt(uint256 repayAssets, uint256 debt);
    error RepayRoundsToZero(uint256 repayAssets);
    error RepayExceedsMax(uint256 repayAssets, uint256 maximum);
    error UnwindProceedsBelowRepayment(uint256 received, uint256 repayment);
    /// @notice With `usd3Out`, the USD3 needed to withdraw the repayment (previewed before the withdraw, or actually
    /// burned by it) exceeds the USD3 this unwind's redemption produced.
    error Usd3BelowRepayment(uint256 usd3Redeemed, uint256 usd3Required);
    /// @notice A `usd3Out` unwind changed the helper's USDC balance, which the exact flash and repayment pulls keep at
    /// zero.
    error UnexpectedUsdcChange(uint256 amount);
    error UnwindOutputBelowMinimum(uint256 amountOut, uint256 minimum);

    // Flash-loan callback
    error NotMorpho();
    error NoOperationInFlight();
    error OperationMismatch();
    error CallbackNotExecuted();

    // Authorization and permits
    error NotAuthorized();
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
    /// @notice Maximum open cooldowns per user and market; a further entry first merges the two oldest cooldowns.
    function MAX_COOLDOWNS() external view returns (uint256);

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

    /// @notice Fills the live shortfall auction of `params.vault` for the caller, supplying the USD3l the vault
    /// delivers as the caller's collateral in `params.market` and borrowing the scaled `params.borrowAssets` against
    /// it. The helper first syncs the vault through a permissionless `synced` entrypoint: when an auction slot is
    /// already live it pokes `finalizeEpochSlash` of that auction's epoch, whose body is a no-op because the epoch is
    /// already slash-finalized; otherwise it pokes `materializeAccount(helper)`, which kicks an untouched auction whose
    /// slash became eligible and leaves an inert helper account in the vault. Either sync settles an expired auction or
    /// one under shutdown. The helper then reverts `NoLiveAuction` when no auction is live, sizes the fill as
    /// `min(maxFill, remaining shortfall)` (`FillBelowMinimum` below `minFill`), and scales every quoted amount (see
    /// `TakeParams`). Requires a USDC allowance covering the scaled contribution only when it is nonzero and, when
    /// `params.borrowAssets` is nonzero, the caller's Morpho authorization of this helper (`NotAuthorized`, checked
    /// first); no other allowance is needed. There is no signature variant. Emits `AuctionTaken`.
    /// @dev The vault's filler is this helper: the vault delivers the USD3l and the margin award to it, and it supplies
    /// all of the USD3l for the caller, withdraws the scaled `marginAssets` of USDC from the award when nonzero, and
    /// forwards the rest of the award. Morpho `onBehalf` and the cooldown owner are always msg.sender, and the
    /// collateral supplied opens a cooldown as a funding entry does. The vault's own checks (liveness after its sync,
    /// `InsufficientMarginAward`, the margin oracle) apply to the fill, and a fill that completes the shortfall settles
    /// the auction inside the vault. A paused vault reverts at the sync.
    /// @return filled USDC paid to the vault for the fill.
    /// @return collateral USD3l supplied as Morpho collateral on behalf of the caller.
    function takeAuction(TakeParams calldata params) external returns (uint256 filled, uint256 collateral);

    /// @notice Withdraws `params.shares` of the caller's USD3l collateral from `params.market`, repays the requested
    /// debt with a Morpho flash loan of that amount, redeems the withdrawn USD3l to USD3 under this helper's USD3l
    /// cooldown bypass, converts to USDC either all of that USD3 or, with `params.usd3Out`, only the repayment, repays
    /// the flash loan, and sends the rest to the caller in USDC or USD3. Requires the caller's
    /// Morpho authorization of this helper (`NotAuthorized` otherwise) and, unless the USD3l cooldown is waived (shut
    /// down or zero), matured cooldowns covering `params.shares`, consumed oldest first. With nothing to repay no flash
    /// loan is taken. A partial unwind leaves debt, so Morpho's health check (and the market oracle) applies to the
    /// withdrawal. USD3's own withdraw limit (pending loss, waUSDC liquidity, ring fence, floors) and the bypass grant
    /// can make the redemption revert; the whole call then reverts and the cooldowns are restored. Debt is always
    /// repaid by shares. On the USDC path, redemption proceeds below the flash-loaned repayment revert
    /// `UnwindProceedsBelowRepayment`; on the `usd3Out` path, a repayment needing more USD3 than the redemption
    /// produced reverts `Usd3BelowRepayment`, and the helper's USDC balance must end unchanged
    /// (`UnexpectedUsdcChange`).
    /// @return repaidAssets USDC of debt repaid: the repaid shares' value rounded up, which the flash loan covers.
    /// @return sharesRedeemed USD3l collateral shares withdrawn and redeemed.
    /// @return outToken Token sent to the caller: USD3 with `params.usd3Out`, USDC otherwise.
    /// @return amountOut Amount of `outToken` sent to the caller.
    function unwind(UnwindParams calldata params)
        external
        returns (uint256 repaidAssets, uint256 sharesRedeemed, address outToken, uint256 amountOut);

    /// @notice `unwind` that first applies the caller's enabling Morpho authorization of this helper when it is not
    /// already in place, with the same tolerance as `fundWithSignatures`; otherwise the authorization is ignored.
    function unwindWithAuthorization(
        UnwindParams calldata params,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    ) external returns (uint256 repaidAssets, uint256 sharesRedeemed, address outToken, uint256 amountOut);

    /// @notice `user`'s open cooldowns in market `marketId`, oldest first.
    function cooldowns(address user, bytes32 marketId) external view returns (Cooldown[] memory);

    /// @notice Shares of `user`'s cooldowns in market `marketId` matured at the live USD3l cooldown.
    function maturedShares(address user, bytes32 marketId) external view returns (uint256);

    /// @notice The most shares `user` can unwind in market `marketId` by the cooldown gate and live collateral; USD3's
    /// withdraw limit and Morpho's health check are not included.
    function maxUnwindable(address user, bytes32 marketId) external view returns (uint256);
}
