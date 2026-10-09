// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IMorphoBlue} from "./IMorphoBlue.sol";

/// @title ILCCLeveragedFundHelper
/// @notice Levered LCC positions on canonical Morpho Blue, in three lifecycles: amortizing capital-call funding
/// (`fund`), shortfall-auction fills (`takeAuction`), and unwinds of the resulting position (`unwind`). Both entries
/// supply the USD3l the vault delivers as the caller's collateral and can borrow part of the USDC paid against it.
/// This interface is the helper's behaviour specification.
/// @dev Common shape. The helper pins the Morpho singleton, the LCC vault factory, and USD3l, and derives USD3 as
/// `usd3l.asset()` and USDC as `usd3.asset()`. Served markets: every request names a `market` (in `FundParams`,
/// `TakeParams`, and `UnwindParams` alike), which must be a market on the pinned singleton whose loan token is USDC and
/// collateral token is USD3l (`InvalidRequest` otherwise). Its oracle, IRM, and LLTV are chosen by the caller
/// among markets its curator created; the helper does not vet them. The LCC beneficiary, the Morpho `onBehalf`, and
/// the cooldown owner are always the caller. Only an entry that borrows reads the market oracle or needs Morpho
/// authorization, and after such an entry the loan-to-value of the caller's whole position in the market, valued at
/// the market oracle price with debt rounded up, must be within the caller's `maxEntryLtv`.
///
/// Flash bridge. An operation takes a Morpho flash loan only when the USDC it bridges is nonzero: `borrowAssets +
/// marginAssets` for an entry (repaid by the borrow and by USDC withdrawn from margin-asset shares), the repayment for
/// an unwind. During a bridged entry the singleton must physically hold `2 * borrowAssets + marginAssets` of USDC (the
/// flash loan, then the borrow). At most one operation is in flight: the helper records the hash of the loaned amount
/// and the payload in transient storage, the callback runs only from Morpho and only for that hash, and the record is
/// consumed before any external call. Every amount is a measured balance change, never a preview.
///
/// Allowances and balances. Morpho holds standing maximal USD3l and USDC allowances from the helper, granted at
/// construction for collateral supply, flash-loan repayment, and debt repayment; Morpho pulls only from its
/// `msg.sender`, and the helper holds no USD3l or USDC of its own between transactions. The standing USDC allowance
/// means Morpho's pulls are not capped by an exact approval: the helper relies on canonical Morpho pulling exactly the
/// repay and flash amounts, and an unwind's end-of-entry USDC balance check catches any excess. Each vault receives an
/// exact USDC approval that must be spent in full (`VaultAmountMismatch`). Every entrypoint requires the helper's USD3l
/// balance to end where it started (`UnexpectedBalance`), so donated USD3l is never touched.
///
/// Cooldown book. Every entry opens a `Cooldown` for the collateral it supplied, at most `MAX_COOLDOWNS` per user and
/// market; a full book first merges its two oldest cooldowns (`CooldownsMerged`), so no entry reverts for book reasons.
/// Unwinds consume matured cooldowns oldest first and emit no per-cooldown record: a user's matured shares are read
/// from `cooldowns()` together with the live USD3l `cooldownDuration`, and `maxUnwindable` combines them with live
/// collateral. Entries are the only way a cooldown starts, unwind consumption the only way one is removed, and the
/// full-book merge the only other change.
///
/// Unwind. USD3l management grants the helper the USD3l cooldown bypass, which it uses only for collateral it
/// withdraws from the caller's own position and only up to the caller's matured cooldowns, so bypass redemptions for a
/// user never exceed the USD3l the helper supplied for that user, each at least the cooldown after it was supplied. The
/// gate is waived while USD3l is shut down or its cooldown is zero, mirroring the vault's own waivers. Accepted
/// residual: a cooldown is not reduced when the collateral it covered leaves the position directly or by liquidation,
/// which is weaker than the USD3l vault's own transfer lock on cooled shares.
///
/// Surface. Entrypoints are `nonReentrant`. The helper holds no factory role, never deposits into USD3 itself (the
/// vault is the USD3 depositor and holds the supply-cap exemption), and has no owner, rescue, receiver-choice,
/// delegated-beneficiary, arbitrary-call, or upgrade surface. Accepted properties: the Morpho authorization is global
/// across the caller's Morpho positions and stays enabled until the caller revokes it; there is no entry-LTV buffer
/// below LLTV beyond the caller's own bound; entries are allowed while a USD3 loss is pending; the market's oracle,
/// LLTV, and liquidation strategy belong to its curator.
interface ILCCLeveragedFundHelper {
    /// @param vault Factory-registered LCC vault whose current-epoch obligation the caller funds.
    /// @param market Served market (see the interface's served-market rule) in which the caller's collateral is
    /// supplied and from which `borrowAssets` is borrowed.
    /// @param borrowAssets USDC borrowed from `market` on behalf of the caller; zero borrows nothing. An entry is fully
    /// levered when `borrowAssets` equals `fundingAmount = max(obligation, usd3.previewMint(1))`, which includes the
    /// one-share top-up; on a dust obligation `borrowAssets = obligation` with `maxContribution = 0` therefore reverts
    /// `ContributionExceedsMax`.
    /// @param marginAssets USDC the caller sources from the margin the vault releases to it inside `fundCall`; zero
    /// uses no margin and never calls the margin asset. When nonzero, the vault's margin asset must be an ERC-4626
    /// vault
    /// whose `asset()` is USDC (`UnsupportedMarginAsset` otherwise). After the release the helper withdraws exactly
    /// `marginAssets` of USDC from the caller's margin-asset shares (`UnexpectedBalance` unless exactly that
    /// arrives); the shares burned, measured as the caller's balance change, may exceed neither `maxMarginShares`
    /// (`MarginSharesExceedMax`) nor the shares the vault released to the caller in this entry
    /// (`MarginSharesUnavailable`), so a pre-existing margin-asset balance is never consumed. Integrators set it to the
    /// `previewRedeem` of the released shares `activeMargin * obligation / activeCommitment` (rounded down, as the
    /// vault does) or just under.
    /// @param maxMarginShares Maximum margin-asset shares the withdrawal may burn; must be nonzero when `marginAssets`
    /// is (`InvalidRequest`). The caller's margin-asset allowance or permit must cover it.
    /// @param maxContribution Maximum USDC pulled from the caller (funding amount minus `borrowAssets` and
    /// `marginAssets`).
    /// @param minCollateral Minimum USD3l the vault must deliver to the caller for this funding
    /// (`CollateralBelowMinimum`); must be nonzero and at most `maxCollateral` (`InvalidRequest`). Integrators
    /// set it just under `usd3l.previewDeposit(usd3.previewDeposit(fundingAmount))`.
    /// @param maxCollateral Maximum USD3l supplied as collateral and pulled from the caller; any delivery above it
    /// stays in the caller's wallet. Integrators set it at or just above the preview.
    /// @param maxEntryLtv Maximum loan-to-value of the caller's whole position in `market` after a levered entry,
    /// WAD-scaled like Morpho's LLTV (`EntryLtvExceeded`). Checked only when `borrowAssets` is nonzero.
    /// @param maxObligation Maximum capital-call obligation the caller accepts to fund (`ObligationExceedsMax`).
    /// @param deadline Last timestamp at which the call may execute (`DeadlineExpired`).
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

    /// @param market Served market (see the interface's served-market rule) that holds the caller's position.
    /// @param shares USD3l collateral shares to withdraw and redeem; nonzero (`InvalidRequest`), at most the
    /// caller's live collateral in `market` (`SharesExceedCollateral`) and, unless the USD3l cooldown is waived, at
    /// most the caller's matured cooldown shares there (`InsufficientMaturedShares`).
    /// @param full Repay the caller's whole debt in `market`, priced on-chain after accruing interest and repaid by
    /// shares, leaving zero debt; `repayAssets` is then ignored.
    /// @param repayAssets USDC of debt to repay when `full` is false; at most the current debt (`RepayExceedsDebt`). It
    /// is converted to borrow shares rounding down (a nonzero amount buying no share reverts `RepayRoundsToZero`) and
    /// repaid by shares, so the amount actually repaid is those shares' value rounded up, at most `repayAssets`. Zero
    /// repays nothing.
    /// @param maxRepayAssets Maximum USDC the repayment may cost (`RepayExceedsMax`).
    /// @param usd3Out Deliver the remainder as USD3 instead of USDC. Only the repayment is converted to USDC (through
    /// USD3's `withdraw`); with nothing to repay no USD3 is converted and USD3's withdraw limit is never read, so such
    /// an unwind works during a USD3 pending loss or waUSDC pause. USD3 carries no cooldown, which lives on USD3l.
    /// @param minOut Minimum amount of the output token sent to the caller, USD3 when `usd3Out` and USDC otherwise
    /// (`UnwindOutputBelowMinimum`).
    /// @param deadline Last timestamp at which the call may execute (`DeadlineExpired`).
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
    /// shortfall)` after the vault's sync, and every quoted amount is scaled by `fill / maxFill`, so a partial or
    /// front-run fill keeps the caller's per-unit protections. Dust rule: the quoted contribution (`maxFill -
    /// borrowAssets - marginAssets`) and `marginAssets` scale rounding down and the rounding dust goes to the borrow,
    /// else the margin, else the contribution, so the scaled borrow, margin, and contribution sum to the fill, a quote
    /// without a contribution pulls none, and the scaled borrow (or margin) may exceed its pro-rata share by up to two
    /// base units. `minMarginAward` scales rounding down, and `minCollateral` scales rounding down with a floor of one
    /// share. The contribution never exceeds the quoted one, so it carries no separate bound.
    /// @param vault Factory-registered LCC vault whose live shortfall auction the caller fills.
    /// @param market Served market (see the interface's served-market rule) in which the delivered USD3l is supplied as
    /// the caller's collateral and from which the scaled borrow is borrowed.
    /// @param maxFill USDC the caller offers and the denominator of every scaled field; must be nonzero
    /// (`InvalidRequest`). Quote it near the expected remaining shortfall rather than `type(uint256).max`, or the
    /// scaled amounts lose their precision.
    /// @param minFill Smallest acceptable fill, at most `maxFill` (`InvalidRequest`, `FillBelowMinimum`); zero
    /// accepts any nonzero fill.
    /// @param borrowAssets USDC borrowed at `maxFill`; scaled to the fill, taking the rounding dust, so a nonzero quote
    /// always borrows. A take with zero `borrowAssets` needs no Morpho authorization and never reads the market oracle.
    /// @param marginAssets USDC sourced from the margin award at `maxFill`; scaled to the fill rounding down, or taking
    /// the rounding dust when `borrowAssets` is zero. Zero forwards the whole award to the caller. When nonzero, the
    /// vault's margin asset must be an ERC-4626 vault whose `asset()` is USDC (`UnsupportedMarginAsset` otherwise);
    /// the helper withdraws exactly the scaled amount of USDC from the award it received (`UnexpectedBalance`),
    /// burning no more shares than the award (`MarginSharesUnavailable`), and forwards the rest.
    /// @param minMarginAward Minimum margin award at `maxFill`, scaled to the fill rounding down (it is a floor, and
    /// the vault floors its award) and passed to the vault. The award is pro-rata in the fill, so the scaled bound
    /// keeps its per-unit meaning.
    /// @param minCollateral Minimum USD3l the vault must deliver at `maxFill`; must be nonzero
    /// (`InvalidRequest`). It scales rounding down with a floor of one share, because the delivery itself
    /// floors twice (USD3, then USD3l). Integrators quote it at `maxFill` from
    /// `usd3l.previewDeposit(usd3.previewDeposit(maxFill))` with slack, because the scaled quote and a live double
    /// preview at the fill differ by rounding. All delivered USD3l is supplied as collateral; a caller who wants part
    /// of it liquid withdraws unlevered collateral from Morpho afterwards.
    /// @param maxEntryLtv Maximum loan-to-value of the caller's whole position in `market` after the take, WAD-scaled
    /// like Morpho's LLTV (`EntryLtvExceeded`); checked only when the scaled borrow is nonzero.
    /// @param deadline Last timestamp at which the call may execute (`DeadlineExpired`).
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
    /// @notice An unwind repaid `repaidAssets` of debt, redeemed `shares` of collateral (consuming that many matured
    /// cooldown shares unless the gate was waived), and sent `amountOut` of `outToken` (USDC or USD3) to the caller.
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
    /// @dev Permit replacement: `fundWithSignatures` always submits the USD3l permit, the USDC permit whenever the USDC
    /// contribution is nonzero, and the margin-asset permit whenever `marginAssets` is nonzero, so a permit that
    /// applies replaces the caller's standing allowance to this helper with `value`. A caller whose standing allowance
    /// already
    /// suffices should use `fund`, or sign for the allowance it wants to stand after the call. A submitted permit
    /// cannot outlive the call to be submitted later and reset the allowance. `value` must cover the amount pulled at
    /// execution. The USDC contribution is `fundingAmount - borrowAssets - marginAssets`; a fully levered entry (see
    /// `FundParams.borrowAssets`) pulls no USDC, ignores its USDC permit, and leaves the standing USDC allowance
    /// untouched. The contribution depends on the obligation and the `usd3.previewMint(1)` top-up at inclusion time,
    /// which can move between signing and inclusion (for example after a USD3 report), so signers should over-approve.
    /// The USD3l pulled is at most `FundParams.maxCollateral` and the USD3l permit is checked against that value before
    /// any funding, so signers sign it for `maxCollateral`. The margin-asset permit is checked against
    /// `FundParams.maxMarginShares`, so signers sign it for that value; an entry without margin ignores it and leaves
    /// the standing margin-asset allowance untouched.
    struct PermitSignature {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // Caller bounds: a bound the caller set, or a precondition the caller controls, does not hold.

    /// @notice The caller submitted the request after its `deadline`.
    error DeadlineExpired();
    /// @notice The caller has not authorized this helper on Morpho, or the caller's authorization signature failed to
    /// leave it authorized.
    error NotAuthorized();
    /// @notice The caller's allowance of `token` to this helper, after any permit the caller supplied (whose revert
    /// data is `permitRevert`, empty when it applied or none was submitted), is below `required`.
    error InsufficientAllowance(address token, uint256 allowance, uint256 required, bytes permitRevert);
    /// @notice The caller's current-epoch obligation exceeds the caller's `maxObligation`.
    error ObligationExceedsMax(uint256 obligation, uint256 maximum);
    /// @notice The USDC the caller would contribute exceeds the caller's `maxContribution`.
    error ContributionExceedsMax(uint256 contribution, uint256 maximum);
    /// @notice The caller's `borrowAssets` and `marginAssets` together exceed the funding amount or `maxFill`.
    error BorrowAndMarginExceedTotal(uint256 borrowAssets, uint256 marginAssets, uint256 total);
    /// @notice The vault delivered less USD3l than the caller's (scaled) `minCollateral`.
    error CollateralBelowMinimum(uint256 collateral, uint256 minimum);
    /// @notice Withdrawing the caller's `marginAssets` burned more margin-asset shares than the caller's
    /// `maxMarginShares`.
    error MarginSharesExceedMax(uint256 shares, uint256 maximum);
    /// @notice Withdrawing the caller's `marginAssets` burned more margin-asset shares than this entry made available:
    /// the shares the vault released to the caller in a funding, or the margin award the helper received in a take.
    error MarginSharesUnavailable(uint256 burned, uint256 available);
    /// @notice After a levered entry, the loan-to-value of the caller's whole position exceeds the caller's
    /// `maxEntryLtv`.
    error EntryLtvExceeded(uint256 ltv, uint256 maximum);
    /// @notice The auction's remaining shortfall makes the fill smaller than the caller's `minFill`.
    error FillBelowMinimum(uint256 fill, uint256 minFill);
    /// @notice The caller asked to unwind more shares than the caller's live collateral in the market.
    error SharesExceedCollateral(uint256 shares, uint256 collateral);
    /// @notice The caller's matured cooldown shares in the market do not cover the shares the caller asked to unwind.
    error InsufficientMaturedShares(uint256 requested, uint256 matured);
    /// @notice The caller's `repayAssets` exceeds the caller's current debt in the market.
    error RepayExceedsDebt(uint256 repayAssets, uint256 debt);
    /// @notice The caller's nonzero `repayAssets` buys no borrow share.
    error RepayRoundsToZero(uint256 repayAssets);
    /// @notice The repayment would cost more than the caller's `maxRepayAssets`.
    error RepayExceedsMax(uint256 repayAssets, uint256 maximum);
    /// @notice The unwind's redemption leaves less than the repayment needs; `token` names the unit: USDC on the USDC
    /// path (redemption proceeds against the flash-loaned repayment), USD3 on the `usd3Out` path (the USD3 the
    /// redemption produced against the USD3 previewed for, or actually burned by, the repayment's withdraw).
    error RedemptionBelowRepayment(address token, uint256 available, uint256 required);
    /// @notice The unwind would send the caller less of the output token than the caller's `minOut`.
    error UnwindOutputBelowMinimum(uint256 amountOut, uint256 minimum);

    // Request, vault and timing: the caller named a malformed request, an unusable vault or market, or a vault state
    // with nothing to act on.

    /// @notice The caller's request is malformed: its market's loan token is not USDC or collateral token not USD3l;
    /// its collateral bounds are zero or inverted; it sources margin with zero `maxMarginShares`; its `maxFill` is zero
    /// or below `minFill`; it unwinds zero shares; or an authorization it submits names another authorizer, another
    /// authorized address than this helper, or does not enable.
    error InvalidRequest();
    /// @notice The caller named a vault the factory has not registered.
    error UnregisteredVault();
    /// @notice The vault's margin asset is unusable for the caller's request: USD3l for any entry; USDC or USD3 for a
    /// take; or, when the request sources margin, not an ERC-4626 vault whose `asset()` is USDC.
    error UnsupportedMarginAsset(address marginAsset);
    /// @notice After the reads (and, for a take, the vault's sync) there is nothing to fund: the vault is not in its
    /// Funding phase, the caller's obligation is zero, or the vault has no live shortfall auction.
    error NothingToFund();
    /// @notice The vault's one-share top-up over the caller's obligation exceeds the vault's `MAX_FUNDING_TOP_UP`.
    error FundingTopUpExceeded(uint256 fundingAmount, uint256 obligation);
    /// @notice Raised both at construction, when the deployer passed a codeless Morpho, factory, USD3l, USD3, or USDC,
    /// and on a request, when the caller named a vault whose USDC, USD3, or USD3l wiring differs from this helper's.
    error InvalidConfiguration();

    // Internal invariants: a dependency behaved outside what the helper relies on.

    /// @notice The vault funded or filled a different amount than requested, or left part of the helper's USDC
    /// allowance unused.
    error VaultAmountMismatch();
    /// @notice The helper's balance of `token` is `balance` where `expected` was required; both fields are absolute
    /// balances of `token`. The helper's USD3l balance must end every entrypoint where it started, a `usd3Out` unwind
    /// must leave the helper's USDC balance unchanged, and a margin withdrawal must leave the helper's USDC balance
    /// exactly the withdrawn amount above where it started.
    error UnexpectedBalance(address token, uint256 balance, uint256 expected);
    /// @notice The flash-loan callback came from someone other than Morpho, with no operation in flight, or with an
    /// amount and payload that do not hash to the operation in flight; or Morpho's flash loan returned without running
    /// the callback.
    error InvalidCallback();

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

    /// @notice Funds the caller's current-epoch obligation in `params.vault` with amortizing push funding, borrowing
    /// `params.borrowAssets` against the USD3l the funding delivers. For obligation `O` the vault pulls the funding
    /// amount `F = max(O, usd3.previewMint(1))` and the caller contributes `F - borrowAssets - marginAssets` USDC
    /// (`BorrowAndMarginExceedTotal` when the parts exceed `F`). The helper pays the vault through `fundCall(address)`,
    /// which releases margin to the caller, measures the USD3l the caller received, supplies up to `maxCollateral` of
    /// it as the caller's collateral, withdraws `marginAssets` of USDC from the released margin, and borrows
    /// `borrowAssets`.
    /// Requires, before any token moves: a Morpho authorization of this helper by the caller when
    /// `params.borrowAssets` is nonzero (`NotAuthorized`, checked first); a registered vault (`UnregisteredVault`)
    /// wired to this helper's USDC, USD3, and USD3l (`InvalidConfiguration`) whose margin asset is not USD3l
    /// (`UnsupportedMarginAsset`); the vault's Funding phase and a nonzero obligation (`NothingToFund`); the one-share
    /// top-up within the vault's `MAX_FUNDING_TOP_UP` (`FundingTopUpExceeded`); and the caller's allowances to this
    /// helper: USDC covering the contribution only when it is nonzero, USD3l covering `params.maxCollateral`, and
    /// margin-asset shares covering `params.maxMarginShares` only when `params.marginAssets` is nonzero
    /// (`InsufficientAllowance`, in that order).
    /// @dev The vault replays the caller's account under its bounded step limit inside `fundCall`, while the helper
    /// reads the obligation through the vault's unbounded view replay, so an account stale by more than
    /// `MAX_MATERIALIZE_STEPS` called epochs should call the vault's `materializeAccount` first; otherwise the entry
    /// reverts `AccountMaterializationIncomplete` after the replay cost is paid. This applies to `fundWithSignatures`
    /// as well.
    /// @return obligation The obligation funded.
    /// @return fundingAmount USDC delivered to the vault: the obligation, or USD3's one-share minimum if larger.
    /// @return collateral USD3l supplied as Morpho collateral on behalf of the caller, at most `params.maxCollateral`.
    function fund(FundParams calldata params)
        external
        returns (uint256 obligation, uint256 fundingAmount, uint256 collateral);

    /// @notice `fund` that first applies the caller's signatures: the USDC permit when the contribution is nonzero, the
    /// USD3l permit, the margin-asset permit when `params.marginAssets` is nonzero, and, when `params.borrowAssets` is
    /// nonzero and the caller has not yet authorized this helper on Morpho, an enabling Morpho authorization. The
    /// margin permit and the authorization arguments are otherwise ignored and may be zeroed. Permits replace the
    /// standing allowance as `PermitSignature` describes, and the resulting allowance must cover the requirement
    /// (`InsufficientAllowance`, carrying the permit's revert data).
    /// @dev A signature that fails to apply is tolerated when the allowance or authorization it grants is already in
    /// place, so a third party submitting the same signature first cannot make this call revert. An applied
    /// authorization payload must name the caller as authorizer and this helper as authorized and must enable
    /// (`InvalidRequest`); an authorization that is still missing after submission reverts `NotAuthorized`. The enable
    /// signature is separable: a third party can submit it on its own, and the authorization then stands even if this
    /// call reverts.
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
    /// it. Requires the caller's Morpho authorization of this helper when `params.borrowAssets` is nonzero
    /// (`NotAuthorized`, checked first), then fail-fast checks with view reads only, and a margin asset other than USDC
    /// or USD3 (`UnsupportedMarginAsset`). The helper then syncs the vault through a permissionless `synced`
    /// entrypoint: when an auction slot is already live it pokes `finalizeEpochSlash` of that auction's epoch, whose
    /// body is a no-op because the epoch is already slash-finalized; otherwise it pokes `materializeAccount(helper)`,
    /// which kicks an untouched auction whose slash became eligible and leaves an inert helper account in the vault.
    /// Either sync settles an expired auction or one under shutdown, and a paused vault reverts there. The helper then
    /// reverts `NothingToFund` when no auction is live, sizes the fill as `min(maxFill, remaining shortfall)`
    /// (`FillBelowMinimum` below `minFill`), and scales every quoted amount (see `TakeParams`). Only the caller's USDC
    /// allowance covering the scaled contribution is required, and only when it is nonzero. There is no signature
    /// variant. Emits `AuctionTaken`.
    /// @dev The vault's filler is this helper: it pays exactly the fill through the vault's `takeAuction` with the
    /// scaled `minMarginAward`, receives the USD3l delivery and the margin award, supplies all of the measured USD3l
    /// (at least the scaled `minCollateral`) for the caller, withdraws the scaled `marginAssets` of USDC from the award
    /// when nonzero, forwards the rest of the award, and borrows the scaled borrow. The collateral supplied opens a
    /// cooldown as a funding entry does. The vault's own checks (liveness after its sync, `InsufficientMarginAward`,
    /// the margin oracle) apply to the fill, a fill that completes the shortfall settles the auction inside the vault,
    /// and a residual below one USD3 share is unfillable because fills get no top-up. The sync is part of this
    /// transaction, so a later revert rolls it back.
    /// @return filled USDC paid to the vault for the fill.
    /// @return collateral USD3l supplied as Morpho collateral on behalf of the caller.
    function takeAuction(TakeParams calldata params) external returns (uint256 filled, uint256 collateral);

    /// @notice Withdraws `params.shares` of the caller's USD3l collateral from `params.market`, repays the requested
    /// debt with a Morpho flash loan of that amount, redeems the withdrawn USD3l to USD3 under this helper's USD3l
    /// cooldown bypass, converts to USDC either all of that USD3 or, with `params.usd3Out`, only the repayment, repays
    /// the flash loan, and sends the rest to the caller in USDC or USD3. Requires the caller's Morpho authorization of
    /// this helper (`NotAuthorized`; unlevered and margin-only funders never granted it) and, unless the USD3l cooldown
    /// is waived, matured cooldowns covering `params.shares`, consumed oldest first before any state-changing external
    /// call. With nothing to repay no flash loan is taken. A partial unwind leaves debt, so Morpho's health check (and
    /// the market oracle) applies to the withdrawal. Every conversion has zero loss tolerance. USD3's own withdraw
    /// limit (pending loss, waUSDC liquidity, ring fence, floors) and the bypass grant can make the redemption revert;
    /// the whole call then reverts and the cooldowns are restored. On the USDC path, redemption proceeds below the
    /// flash-loaned repayment revert `RedemptionBelowRepayment` in USDC; on the `usd3Out` path, a repayment needing
    /// more USD3 than the redemption produced reverts `RedemptionBelowRepayment` in USD3, and the helper's USDC
    /// balance must end unchanged (`UnexpectedBalance`). Donated USD3l, USD3, and USDC are never touched. Emits
    /// `Unwound`.
    /// @return repaidAssets USDC of debt repaid: the repaid shares' value rounded up, which the flash loan covers.
    /// @return amountOut Amount of the output token sent to the caller: USD3 with `params.usd3Out`, USDC otherwise.
    function unwind(UnwindParams calldata params) external returns (uint256 repaidAssets, uint256 amountOut);

    /// @notice `unwind` that first applies the caller's enabling Morpho authorization of this helper when it is not
    /// already in place, with the same tolerance as `fundWithSignatures`; otherwise the authorization is ignored.
    function unwindWithAuthorization(
        UnwindParams calldata params,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    ) external returns (uint256 repaidAssets, uint256 amountOut);

    /// @notice `user`'s open cooldowns in market `marketId`, oldest first. With the live USD3l `cooldownDuration`
    /// this is the matured-share bookkeeping: a cooldown is matured from `start + max(duration, cooldownDuration)` on.
    function cooldowns(address user, bytes32 marketId) external view returns (Cooldown[] memory);

    /// @notice The most shares `user` can unwind in market `marketId` by the cooldown gate and live collateral; USD3's
    /// withdraw limit and Morpho's health check are not included.
    function maxUnwindable(address user, bytes32 marketId) external view returns (uint256);
}
