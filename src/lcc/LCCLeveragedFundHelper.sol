// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ORACLE_PRICE_SCALE} from "../libraries/ConstantsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {LCCVaultFactory} from "./LCCVaultFactory.sol";
import {ILCCLeveragedFundHelper} from "./interfaces/ILCCLeveragedFundHelper.sol";
import {ILCCVault} from "./interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "./libraries/LCCAuctionLib.sol";
import {IMorphoBlue, IMorphoBlueOracle, IMorphoBlueFlashLoanCallback} from "./interfaces/IMorphoBlue.sol";
import {ILCCNotificationVault, ILCCRedeemableVault} from "./interfaces/ILCCNotificationVault.sol";

/// @title LCCLeveragedFundHelper
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Levered LCC positions on the pinned canonical Morpho Blue singleton, in three lifecycles: `fund` pays the
/// caller's capital-call obligation with amortizing push funding, `takeAuction` fills an LCC vault's live shortfall
/// auction for the caller, and `unwind` closes all or part of the resulting position. Both entries supply the USD3l
/// the vault delivers as the caller's collateral in a caller-chosen market lending USDC against USD3l, and can borrow
/// part of the USDC paid there.
/// @dev Common shape. The LCC beneficiary, the Morpho `onBehalf`, and the cooldown owner are always msg.sender. An
/// operation takes a Morpho flash loan only when the USDC it bridges is nonzero. At most one operation is in flight:
/// its hash is held in transient storage, and the flash-loan callback runs only for that hash. Collateral is measured
/// as balance changes, never previewed. Only an entry that borrows reads the market oracle, and the caller's whole
/// position in that market must then be within the caller's LTV bound.
///
/// Fund. The helper pulls the caller's USDC contribution, bridges `borrowAssets + marginAssets`, pays the vault
/// through `fundCall(address)` (which releases margin to the caller), measures the USD3l the caller received, requires
/// it to reach `minCollateral`, supplies up to `maxCollateral` of it (any excess stays in the caller's wallet),
/// withdraws `marginAssets` of USDC from the caller's released ERC-4626-over-USDC margin-asset shares, and borrows
/// `borrowAssets`; those two repay the flash loan.
///
/// Take. The helper syncs the vault, sizes the fill as `min(maxFill, remaining shortfall)`, scales every quoted amount
/// to the fill, pulls the scaled contribution, bridges the scaled borrow and award-sourced USDC, and fills through the
/// vault's `takeAuction` as the filler itself. It supplies all the USD3l delivered to it as the caller's collateral,
/// withdraws the scaled `marginAssets` of USDC from the margin award (ERC-4626-over-USDC margin assets only), forwards
/// the rest of the award, and borrows the scaled borrow. Its USD3l balance must end unchanged. Vaults whose margin
/// asset is USDC or USD3 are not served by takes.
///
/// Cooldown book. Every fund or take entry opens a cooldown for the collateral it supplied, at most `MAX_COOLDOWNS`
/// per user and market; a full book first merges its two oldest cooldowns (`CooldownsMerged`).
///
/// Unwind. USD3l management grants this helper the USD3l cooldown bypass; the helper uses it only for collateral it
/// withdraws from the caller's own position, and only up to the caller's matured cooldowns, so a bypass redemption for
/// a user never exceeds the USD3l the helper supplied for that user, each at least the cooldown after it was supplied.
/// Accepted residual: a cooldown is not reduced when the collateral it covered leaves the position directly or by
/// liquidation, so this is weaker than the USD3l vault's own transfer lock. The gate is waived while USD3l is shut down
/// or its cooldown is zero, mirroring the vault's own waivers.
///
/// Surface and state. The helper holds no factory role, never deposits into USD3 itself, and has no owner, rescue,
/// receiver-choice, delegated-beneficiary, arbitrary-call, or upgrade surface. Its state is the per-user cooldown book,
/// the transient in-flight operation, and the reentrancy lock.
contract LCCLeveragedFundHelper is ILCCLeveragedFundHelper, IMorphoBlueFlashLoanCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    /* CONSTANTS & TYPES */

    /// @dev Mirrors the vault's bound on the extra funding asset pulled so a dust obligation mints one USD3 share.
    uint256 internal constant MAX_FUNDING_TOP_UP = 1_000;

    /// @notice Maximum open cooldowns per user and market; a further entry first merges the two oldest cooldowns.
    uint256 public constant MAX_COOLDOWNS = 32;

    /// @dev First field of every flash-loan payload, so the callback dispatches on the operation it was armed for.
    enum OperationKind {
        Fund,
        Unwind,
        Take
    }

    /// @dev Inputs one funding binds; hashed with its kind as the in-flight operation.
    struct FundOperation {
        address user;
        address vault;
        address marginAsset;
        IMorphoBlue.MarketParams market;
        uint256 obligation;
        uint256 fundingAmount;
        uint256 borrowAssets;
        uint256 marginAssets;
        uint256 maxMarginShares;
        uint256 minCollateral;
        uint256 maxCollateral;
    }

    /// @dev Final values of one take, scaled to the fill; hashed with its kind as the in-flight operation.
    struct TakeOperation {
        address user;
        address vault;
        address marginAsset;
        IMorphoBlue.MarketParams market;
        uint256 fill;
        uint256 borrowAssets;
        uint256 marginAssets;
        uint256 minMarginAward;
        uint256 minCollateral;
    }

    /// @dev Inputs one unwind binds; hashed with its kind as the in-flight operation.
    struct UnwindOperation {
        address user;
        IMorphoBlue.MarketParams market;
        uint256 shares;
        uint256 repayAssets;
        uint256 repayShares;
        bool usd3Out;
    }

    /// @dev A position's debt as read by `_debtOf`.
    struct DebtState {
        uint256 borrowShares;
        uint256 collateral;
        uint256 assets;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
    }

    /* IMMUTABLES & STATE */

    address public immutable override morpho;
    address public immutable override factory;
    address public immutable override usdc;
    address public immutable override usd3;
    address public immutable override usd3l;

    bytes32 private transient _operation;

    mapping(address user => mapping(bytes32 marketId => Cooldown[])) private _cooldowns;

    /* CONSTRUCTOR */

    /// @param morpho_ Canonical Morpho Blue singleton.
    /// @param factory_ LCC vault factory whose registered vaults may be funded.
    /// @param usd3l_ USD3l, the notification vault wrapping USD3 and the collateral token of every market served. USD3
    /// is derived as `usd3l_.asset()` and USDC as `usd3.asset()`.
    constructor(address morpho_, address factory_, address usd3l_) {
        if (morpho_.code.length == 0 || factory_.code.length == 0 || usd3l_.code.length == 0) {
            revert InvalidConfiguration();
        }

        address usd3_ = IERC4626(usd3l_).asset();
        if (usd3_.code.length == 0) revert InvalidConfiguration();
        address usdc_ = IERC4626(usd3_).asset();
        if (usdc_.code.length == 0) revert InvalidConfiguration();

        morpho = morpho_;
        factory = factory_;
        usdc = usdc_;
        usd3 = usd3_;
        usd3l = usd3l_;

        // Morpho pulls collateral only from its msg.sender, and the helper holds no USD3l between transactions, so a
        // standing allowance exposes nothing.
        IERC20(usd3l_).forceApprove(morpho_, type(uint256).max);
    }

    /* FUND */

    /// @inheritdoc ILCCLeveragedFundHelper
    /// @dev Checks the caller's standing USDC allowance (when the contribution is nonzero), USD3l allowance (against
    /// `maxCollateral`), and margin-asset allowance (against `maxMarginShares`, when `marginAssets` is nonzero) after
    /// the fail-fast checks and before any token moves, reverting with `InsufficientAllowance`.
    function fund(FundParams calldata params)
        external
        nonReentrant
        returns (uint256 obligation, uint256 fundingAmount, uint256 collateral)
    {
        if (_needsAuthorization(params.borrowAssets)) revert NotAuthorized();
        FundOperation memory op = _sizeFund(params);
        uint256 contribution = _fundContribution(op);
        if (contribution != 0) _requireAllowance(usdc, contribution, "");
        _requireAllowance(usd3l, op.maxCollateral, "");
        if (op.marginAssets != 0) _requireAllowance(op.marginAsset, op.maxMarginShares, "");
        return _executeFund(op, params.maxEntryLtv);
    }

    /// @inheritdoc ILCCLeveragedFundHelper
    /// @dev Each permit is submitted with msg.sender as owner and this helper as spender, after sizing and before any
    /// token moves: the USDC permit only when the contribution is nonzero, checked against it; the USD3l permit always,
    /// checked against `maxCollateral`; the margin-asset permit only when `marginAssets` is nonzero, checked against
    /// `maxMarginShares`. The authorization is applied only when the entry borrows and the caller has not yet
    /// authorized this helper.
    function fundWithSignatures(
        FundParams calldata params,
        PermitSignature calldata usdcPermit,
        PermitSignature calldata usd3lPermit,
        PermitSignature calldata marginPermit,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    ) external nonReentrant returns (uint256 obligation, uint256 fundingAmount, uint256 collateral) {
        FundOperation memory op = _sizeFund(params);

        uint256 contribution = _fundContribution(op);
        if (contribution != 0) _applyPermit(usdc, usdcPermit, contribution);
        _applyPermit(usd3l, usd3lPermit, op.maxCollateral);
        if (op.marginAssets != 0) _applyPermit(op.marginAsset, marginPermit, op.maxMarginShares);
        if (_needsAuthorization(op.borrowAssets)) _applyAuthorization(authorization, authorizationSignature);

        return _executeFund(op, params.maxEntryLtv);
    }

    /* TAKE */

    /// @inheritdoc ILCCLeveragedFundHelper
    /// @dev The only allowance checked is the caller's USDC allowance against the scaled contribution: the USD3l and
    /// the margin award are delivered to this helper, and the award withdrawal burns the helper's own shares.
    function takeAuction(TakeParams calldata params)
        external
        nonReentrant
        returns (uint256 filled, uint256 collateral)
    {
        if (_needsAuthorization(params.borrowAssets)) {
            revert NotAuthorized();
        }
        TakeOperation memory op = _sizeTake(params);
        bytes32 marketId = _marketId(params.market);
        collateral = _executeTake(op, marketId, params.maxEntryLtv);
        emit AuctionTaken(op.user, op.vault, marketId, op.fill, collateral, op.borrowAssets, op.marginAssets);
        return (op.fill, collateral);
    }

    /* UNWIND */

    /// @inheritdoc ILCCLeveragedFundHelper
    function unwind(UnwindParams calldata params)
        external
        nonReentrant
        returns (uint256 repaidAssets, uint256 sharesRedeemed, address outToken, uint256 amountOut)
    {
        if (!_isAuthorized()) revert NotAuthorized();
        return _executeUnwind(params);
    }

    /// @inheritdoc ILCCLeveragedFundHelper
    function unwindWithAuthorization(
        UnwindParams calldata params,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    )
        external
        nonReentrant
        returns (uint256 repaidAssets, uint256 sharesRedeemed, address outToken, uint256 amountOut)
    {
        if (!_isAuthorized()) {
            _applyAuthorization(authorization, authorizationSignature);
        }
        return _executeUnwind(params);
    }

    /* FLASH-LOAN CALLBACK */

    /// @inheritdoc IMorphoBlueFlashLoanCallback
    /// @dev Accepted only from Morpho while this helper's own `flashLoan` call is in flight, and only for the exact
    /// operation recorded for it and the amount it bridges (`borrowAssets + marginAssets` for funding and takes, the
    /// repayment for an unwind). The record is cleared before any external call.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external override {
        if (msg.sender != morpho) revert NotMorpho();
        bytes32 expected = _operation;
        if (expected == bytes32(0)) revert NoOperationInFlight();
        if (keccak256(data) != expected) revert OperationMismatch();
        _operation = bytes32(0);

        OperationKind kind = abi.decode(data[:32], (OperationKind));
        if (kind == OperationKind.Fund) {
            (, FundOperation memory op) = abi.decode(data, (OperationKind, FundOperation));
            if (assets != op.borrowAssets + op.marginAssets) revert OperationMismatch();
            _runFund(op);
        } else if (kind == OperationKind.Unwind) {
            (, UnwindOperation memory op) = abi.decode(data, (OperationKind, UnwindOperation));
            if (assets != op.repayAssets) revert OperationMismatch();
            uint256 received = _runUnwind(op);
            if (received < assets) revert UnwindProceedsBelowRepayment(received, assets);
        } else {
            (, TakeOperation memory op) = abi.decode(data, (OperationKind, TakeOperation));
            if (assets != op.borrowAssets + op.marginAssets) revert OperationMismatch();
            _runTake(op);
        }
        IERC20(usdc).forceApprove(morpho, assets);
    }

    /* VIEWS */

    /// @inheritdoc ILCCLeveragedFundHelper
    function cooldowns(address user, bytes32 marketId) external view returns (Cooldown[] memory) {
        return _cooldowns[user][marketId];
    }

    /// @inheritdoc ILCCLeveragedFundHelper
    function maturedShares(address user, bytes32 marketId) external view returns (uint256) {
        return _maturedShares(user, marketId, ILCCNotificationVault(usd3l).cooldownDuration());
    }

    /// @inheritdoc ILCCLeveragedFundHelper
    function maxUnwindable(address user, bytes32 marketId) external view returns (uint256) {
        uint256 collateral = _positionCollateral(marketId, user);
        uint256 liveDuration = ILCCNotificationVault(usd3l).cooldownDuration();
        if (_cooldownWaived(liveDuration)) return collateral;
        return Math.min(collateral, _maturedShares(user, marketId, liveDuration));
    }

    /* REQUEST VALIDATION */

    /// @dev Checks shared by every entry and unwind: the deadline, then the market's loan and collateral tokens.
    function _validateRequest(uint256 deadline, IMorphoBlue.MarketParams calldata market) private view {
        if (block.timestamp > deadline) revert DeadlineExpired(); // deliberate wall-clock read
        if (market.loanToken != usdc || market.collateralToken != usd3l) revert MarketTokenMismatch();
    }

    /// @dev Requires `borrowAssets + marginAssets <= total` without overflowing (`BorrowAndMarginExceedTotal`).
    function _requireSplit(uint256 borrowAssets, uint256 marginAssets, uint256 total) private pure {
        if (borrowAssets > total || marginAssets > total - borrowAssets) {
            revert BorrowAndMarginExceedTotal(borrowAssets, marginAssets, total);
        }
    }

    /// @dev Morpho's id of `market`.
    function _marketId(IMorphoBlue.MarketParams memory market) private pure returns (bytes32) {
        return keccak256(abi.encode(market));
    }

    /* SIZING */

    /// @dev Validates a funding request with view reads only and sizes it from the caller's current obligation.
    function _sizeFund(FundParams calldata params) private view returns (FundOperation memory op) {
        _validateRequest(params.deadline, params.market);
        if (params.minCollateral == 0 || params.minCollateral > params.maxCollateral) {
            revert InvalidCollateralBounds(params.minCollateral, params.maxCollateral);
        }
        address marginAsset = _validateVault(params.vault);
        if (params.marginAssets != 0) {
            if (params.maxMarginShares == 0) revert InvalidMarginShares();
            _requireUsdcVault(marginAsset);
            op.marginAsset = marginAsset;
            op.marginAssets = params.marginAssets;
            op.maxMarginShares = params.maxMarginShares;
        }

        ILCCVault vault = ILCCVault(params.vault);
        if (vault.currentPhase() != ILCCVault.Phase.Funding) revert NotFundingPhase();
        op.user = msg.sender;
        op.vault = params.vault;
        op.market = params.market;
        op.obligation = vault.obligationOf(vault.currentEpoch(), msg.sender);
        if (op.obligation == 0) revert NoObligation();
        if (op.obligation > params.maxObligation) revert ObligationExceedsMax(op.obligation, params.maxObligation);

        op.fundingAmount = Math.max(op.obligation, IERC4626(usd3).previewMint(1));
        if (op.fundingAmount - op.obligation > MAX_FUNDING_TOP_UP) {
            revert FundingTopUpExceeded(op.fundingAmount, op.obligation);
        }
        _requireSplit(params.borrowAssets, params.marginAssets, op.fundingAmount);
        op.borrowAssets = params.borrowAssets;

        uint256 contribution = _fundContribution(op);
        if (contribution > params.maxContribution) revert ContributionExceedsMax(contribution, params.maxContribution);

        op.minCollateral = params.minCollateral;
        op.maxCollateral = params.maxCollateral;
    }

    /// @dev USDC pulled from the caller: the funding amount less the borrowed and margin-sourced parts.
    function _fundContribution(FundOperation memory op) private pure returns (uint256) {
        return op.fundingAmount - op.borrowAssets - op.marginAssets;
    }

    /// @dev Validates a take, syncs the vault (see `takeAuction`), sizes the fill, and scales it as `TakeParams` says.
    function _sizeTake(TakeParams calldata params) private returns (TakeOperation memory op) {
        _validateRequest(params.deadline, params.market);
        if (params.minCollateral == 0) revert InvalidCollateralBounds(0, type(uint256).max);
        uint256 maxFill = params.maxFill;
        if (maxFill == 0 || params.minFill > maxFill) revert InvalidFillBounds(params.minFill, maxFill);
        _requireSplit(params.borrowAssets, params.marginAssets, maxFill);
        address marginAsset = _validateVault(params.vault);
        if (marginAsset == usdc || marginAsset == usd3) revert TakeMarginAssetUnsupported(marginAsset);
        if (params.marginAssets != 0) _requireUsdcVault(marginAsset);

        ILCCVault vault = ILCCVault(params.vault);
        uint256 slot = vault.syncState().pendingAuctionEpochPlusOne;
        if (slot != 0) vault.finalizeEpochSlash(slot - 1);
        else vault.materializeAccount(address(this));
        slot = vault.syncState().pendingAuctionEpochPlusOne;
        if (slot == 0) revert NoLiveAuction();
        LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(slot - 1);
        uint256 fill = Math.min(maxFill, uint256(auction.shortfallAmount) - auction.filledAmount);
        if (fill < params.minFill) revert FillBelowMinimum(fill, params.minFill);

        op.user = msg.sender;
        op.vault = params.vault;
        op.marginAsset = marginAsset;
        op.market = params.market;
        op.fill = fill;
        uint256 contribution = Math.mulDiv(maxFill - params.borrowAssets - params.marginAssets, fill, maxFill);
        op.marginAssets = Math.mulDiv(params.marginAssets, fill, maxFill);
        if (params.borrowAssets != 0) op.borrowAssets = fill - contribution - op.marginAssets;
        else if (params.marginAssets != 0) op.marginAssets = fill - contribution;
        op.minMarginAward = Math.mulDiv(params.minMarginAward, fill, maxFill);
        op.minCollateral = Math.max(1, Math.mulDiv(params.minCollateral, fill, maxFill));
    }

    /// @dev Prices the repayment against the just-accrued market, always as borrow shares: in full mode all of the
    /// caller's shares; in partial mode the shares `repayAssets` buys, rounded down and at most the caller's shares,
    /// with `repayAssets` at most the current debt (`RepayExceedsDebt`) and a nonzero amount that buys no share
    /// rejected (`RepayRoundsToZero`). The repayment is the shares' value rounded up, exactly what Morpho pulls, and is
    /// bounded by `maxRepayAssets`.
    function _sizeUnwind(UnwindParams calldata params, bytes32 id) private view returns (UnwindOperation memory op) {
        DebtState memory debt = _debtOf(id, msg.sender);

        op.user = msg.sender;
        op.market = params.market;
        op.shares = params.shares;
        op.usd3Out = params.usd3Out;
        if (params.full) {
            op.repayShares = debt.borrowShares;
        } else if (params.repayAssets != 0) {
            if (params.repayAssets > debt.assets) revert RepayExceedsDebt(params.repayAssets, debt.assets);
            op.repayShares = Math.min(
                params.repayAssets.toSharesDown(debt.totalBorrowAssets, debt.totalBorrowShares), debt.borrowShares
            );
            if (op.repayShares == 0) revert RepayRoundsToZero(params.repayAssets);
        }
        op.repayAssets = op.repayShares.toAssetsUp(debt.totalBorrowAssets, debt.totalBorrowShares);
        if (op.repayAssets > params.maxRepayAssets) revert RepayExceedsMax(op.repayAssets, params.maxRepayAssets);
    }

    /* EXECUTION & FLASH BRIDGE */

    /// @dev Pulls the contribution, runs the funding directly or through the flash bridge, and opens its cooldown.
    function _executeFund(FundOperation memory op, uint256 maxEntryLtv)
        private
        returns (uint256 obligation, uint256 fundingAmount, uint256 collateral)
    {
        uint256 contribution = _fundContribution(op);
        if (contribution != 0) IERC20(usdc).safeTransferFrom(msg.sender, address(this), contribution);

        uint256 flashAssets = op.borrowAssets + op.marginAssets;
        bytes32 id = _marketId(op.market);
        if (flashAssets == 0) {
            collateral = _runFund(op);
        } else {
            collateral = _bridgeEntry(
                abi.encode(OperationKind.Fund, op),
                flashAssets,
                op.market,
                id,
                op.user,
                op.borrowAssets != 0,
                maxEntryLtv
            );
        }
        _startCooldown(op.user, id, collateral);
        return (op.obligation, op.fundingAmount, collateral);
    }

    /// @dev Checks the caller's USDC allowance against the scaled contribution and pulls it, runs the take directly or
    /// through the flash bridge, and opens its cooldown. Returns the collateral supplied.
    function _executeTake(TakeOperation memory op, bytes32 marketId, uint256 maxEntryLtv)
        private
        returns (uint256 collateral)
    {
        uint256 contribution = op.fill - op.borrowAssets - op.marginAssets;
        if (contribution != 0) {
            _requireAllowance(usdc, contribution, "");
            IERC20(usdc).safeTransferFrom(msg.sender, address(this), contribution);
        }

        uint256 flashAssets = op.borrowAssets + op.marginAssets;
        if (flashAssets == 0) {
            collateral = _runTake(op);
        } else {
            collateral = _bridgeEntry(
                abi.encode(OperationKind.Take, op),
                flashAssets,
                op.market,
                marketId,
                op.user,
                op.borrowAssets != 0,
                maxEntryLtv
            );
        }
        _startCooldown(op.user, marketId, collateral);
    }

    /// @dev Checks the request, consumes matured cooldowns before any state-changing external call, accrues the market,
    /// sizes the repayment, runs the unwind directly or through the flash bridge when the repayment is nonzero, and
    /// sends the caller the output token's measured balance change of the helper. Full mode leaves zero debt because it
    /// repays the exact share count read after accrual in this transaction.
    function _executeUnwind(UnwindParams calldata params)
        private
        returns (uint256 repaidAssets, uint256 sharesRedeemed, address outToken, uint256 amountOut)
    {
        _validateRequest(params.deadline, params.market);
        if (params.shares == 0) revert InvalidUnwindShares();

        bytes32 id = _marketId(params.market);
        uint256 collateral = _positionCollateral(id, msg.sender);
        if (params.shares > collateral) revert SharesExceedCollateral(params.shares, collateral);
        _consumeCooldowns(msg.sender, id, params.shares);

        IMorphoBlue(morpho).accrueInterest(params.market);
        UnwindOperation memory op = _sizeUnwind(params, id);

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        uint256 usd3Before = params.usd3Out ? IERC20(usd3).balanceOf(address(this)) : 0;
        if (op.repayAssets == 0) _runUnwind(op);
        else _bridge(abi.encode(OperationKind.Unwind, op), op.repayAssets);
        uint256 usdcChange = IERC20(usdc).balanceOf(address(this)) - usdcBefore;
        if (params.usd3Out) {
            if (usdcChange != 0) revert UnexpectedUsdcChange(usdcChange);
            outToken = usd3;
            amountOut = IERC20(usd3).balanceOf(address(this)) - usd3Before;
        } else {
            outToken = usdc;
            amountOut = usdcChange;
        }
        if (amountOut < params.minOut) revert UnwindOutputBelowMinimum(amountOut, params.minOut);

        if (amountOut != 0) IERC20(outToken).safeTransfer(msg.sender, amountOut);
        emit Unwound(msg.sender, id, outToken, op.repayAssets, params.shares, amountOut);
        return (op.repayAssets, params.shares, outToken, amountOut);
    }

    /// @dev Bridges an entry and returns the change in `user`'s collateral in market `id` across the flash loan. When
    /// the entry borrowed, the read-back is the whole-position LTV check against `maxEntryLtv`.
    function _bridgeEntry(
        bytes memory data,
        uint256 flashAssets,
        IMorphoBlue.MarketParams memory market,
        bytes32 id,
        address user,
        bool borrowed,
        uint256 maxEntryLtv
    ) private returns (uint256) {
        uint256 collateralBefore = _positionCollateral(id, user);
        _bridge(data, flashAssets);
        uint256 collateralAfter =
            borrowed ? _checkEntryLtv(market, id, user, maxEntryLtv) : _positionCollateral(id, user);
        return collateralAfter - collateralBefore;
    }

    /// @dev Records `data` as the in-flight operation, takes a Morpho flash loan of `assets` USDC for it, and requires
    /// the callback to have consumed the record.
    function _bridge(bytes memory data, uint256 assets) private {
        _operation = keccak256(data);
        IMorphoBlue(morpho).flashLoan(usdc, assets, data);
        if (_operation != bytes32(0)) revert CallbackNotExecuted();
    }

    /* RUN PATHS */

    /// @dev Pays the vault from the helper's USDC (the caller's contribution plus any flash-loaned `borrowAssets` and
    /// `marginAssets`), which also releases margin to the caller; measures the USD3l delivered to the caller, requires
    /// at least `minCollateral`, and supplies up to `maxCollateral` of it as the caller's collateral (any excess stays
    /// in the caller's wallet); then withdraws `marginAssets` of USDC from the caller's margin-asset shares to the
    /// helper, burning no more than `maxMarginShares` and no more than the shares released in this entry; then borrows
    /// `borrowAssets` for the caller to the helper. Returns the collateral supplied.
    function _runFund(FundOperation memory op) private returns (uint256 supplied) {
        IERC20 collateralToken = IERC20(usd3l);
        uint256 balanceBefore = collateralToken.balanceOf(op.user);
        uint256 marginBefore = op.marginAssets != 0 ? IERC20(op.marginAsset).balanceOf(op.user) : 0;

        IERC20(usdc).forceApprove(op.vault, op.fundingAmount);
        if (ILCCVault(op.vault).fundCall(op.user) != op.obligation) revert VaultAmountMismatch();
        if (IERC20(usdc).allowance(address(this), op.vault) != 0) revert VaultAmountMismatch();

        uint256 delivered = collateralToken.balanceOf(op.user) - balanceBefore;
        if (delivered < op.minCollateral) revert CollateralBelowMinimum(delivered, op.minCollateral);
        supplied = Math.min(delivered, op.maxCollateral);

        collateralToken.safeTransferFrom(op.user, address(this), supplied);
        IMorphoBlue(morpho).supplyCollateral(op.market, supplied, op.user, "");
        if (op.marginAssets != 0) _withdrawReleasedMargin(op, marginBefore);
        if (op.borrowAssets != 0) {
            IMorphoBlue(morpho).borrow(op.market, op.borrowAssets, 0, op.user, address(this));
        }
    }

    /// @dev Fills the vault's auction from the helper's USDC (the caller's contribution plus any flash-loaned
    /// `borrowAssets` and `marginAssets`), receiving the USD3l delivery and the margin award; supplies the whole
    /// measured delivery as the caller's collateral; withdraws `marginAssets` of USDC from the award when nonzero and
    /// forwards the rest of the award; borrows `borrowAssets` for the caller to the helper; and requires the helper's
    /// USD3l balance to end where it started. Returns the collateral supplied.
    function _runTake(TakeOperation memory op) private returns (uint256 supplied) {
        uint256 usd3lBefore = IERC20(usd3l).balanceOf(address(this));
        uint256 marginBefore = IERC20(op.marginAsset).balanceOf(address(this));
        uint256 awardReceived;
        (supplied, awardReceived) = _fillAndSupply(op, usd3lBefore, marginBefore);

        uint256 awardForwarded = op.marginAssets != 0 ? _withdrawAward(op, marginBefore, awardReceived) : awardReceived;
        if (awardForwarded != 0) IERC20(op.marginAsset).safeTransfer(op.user, awardForwarded);
        if (op.borrowAssets != 0) {
            IMorphoBlue(morpho).borrow(op.market, op.borrowAssets, 0, op.user, address(this));
        }

        uint256 usd3lAfter = IERC20(usd3l).balanceOf(address(this));
        if (usd3lAfter != usd3lBefore) revert Usd3lRetained(usd3lAfter, usd3lBefore);
    }

    /// @dev Pays the vault exactly `fill` through its `takeAuction`, measures the USD3l and margin-asset shares the
    /// helper received across it from `usd3lBefore` and `marginBefore`, requires at least `minCollateral` of USD3l, and
    /// supplies all of it as the caller's collateral from the helper's own balance.
    function _fillAndSupply(TakeOperation memory op, uint256 usd3lBefore, uint256 marginBefore)
        private
        returns (uint256 supplied, uint256 awardReceived)
    {
        IERC20(usdc).forceApprove(op.vault, op.fill);
        uint256 deadline = block.timestamp; // deliberate wall-clock read
        (uint256 filled,) = ILCCVault(op.vault).takeAuction(op.fill, op.minMarginAward, deadline);
        if (filled != op.fill || IERC20(usdc).allowance(address(this), op.vault) != 0) revert VaultAmountMismatch();

        supplied = IERC20(usd3l).balanceOf(address(this)) - usd3lBefore;
        if (supplied < op.minCollateral) revert CollateralBelowMinimum(supplied, op.minCollateral);
        awardReceived = IERC20(op.marginAsset).balanceOf(address(this)) - marginBefore;

        IMorphoBlue(morpho).supplyCollateral(op.market, supplied, op.user, "");
    }

    /// @dev Repays `repayShares` of the caller's debt by shares from the helper's flash-loaned USDC, withdraws
    /// `shares` of the caller's collateral to the helper, redeems exactly the USD3l that withdrawal delivered, and
    /// returns the USDC received from USD3. Any other USD3l, USD3, or USDC the helper holds is never touched.
    function _runUnwind(UnwindOperation memory op) private returns (uint256) {
        if (op.repayShares != 0) {
            IERC20(usdc).forceApprove(morpho, op.repayAssets);
            IMorphoBlue(morpho).repay(op.market, 0, op.repayShares, op.user, "");
        }
        uint256 usd3lBefore = IERC20(usd3l).balanceOf(address(this));
        IMorphoBlue(morpho).withdrawCollateral(op.market, op.shares, op.user, address(this));
        return _redeemCollateral(IERC20(usd3l).balanceOf(address(this)) - usd3lBefore, op.usd3Out, op.repayAssets);
    }

    /// @dev Redeems `shares` of USD3l to USD3 under the helper's cooldown bypass, then converts USD3 to USDC with zero
    /// loss tolerance: all of it when `usd3Out` is false; with `usd3Out`, only `repayAssets` of USDC through USD3's
    /// `withdraw`, and nothing at all when `repayAssets` is zero, so USD3's withdraw limit is then never read. Before
    /// the withdraw the USD3 it needs (`previewWithdraw`) must not exceed what this redemption produced, and after it
    /// the USD3 actually burned is held to the same bound, so donated USD3 is never spent (`Usd3BelowRepayment` for
    /// both). Returns the USDC received. Every amount is a measured balance change.
    function _redeemCollateral(uint256 shares, bool usd3Out, uint256 repayAssets)
        private
        returns (uint256 usdcReceived)
    {
        uint256 usd3Before = IERC20(usd3).balanceOf(address(this));
        ILCCRedeemableVault(usd3l).redeem(shares, address(this), address(this), 0);
        uint256 usd3AfterRedeem = IERC20(usd3).balanceOf(address(this));
        uint256 usd3Received = usd3AfterRedeem - usd3Before;

        if (usd3Out && repayAssets == 0) return 0;
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        if (usd3Out) {
            uint256 required = IERC4626(usd3).previewWithdraw(repayAssets);
            if (required > usd3Received) revert Usd3BelowRepayment(usd3Received, required);
            ILCCRedeemableVault(usd3).withdraw(repayAssets, address(this), address(this), 0);
            uint256 usd3Spent = usd3AfterRedeem - IERC20(usd3).balanceOf(address(this));
            if (usd3Spent > usd3Received) revert Usd3BelowRepayment(usd3Received, usd3Spent);
        } else {
            ILCCRedeemableVault(usd3).redeem(usd3Received, address(this), address(this), 0);
        }
        usdcReceived = IERC20(usdc).balanceOf(address(this)) - usdcBefore;
    }

    /* RECEIPTS & WITHDRAWALS */

    /// @dev Withdraws exactly `marginAssets` of USDC to the helper from the caller's margin-asset shares. The shares
    /// burned are measured as the caller's balance change across the withdrawal and must not exceed `maxMarginShares`
    /// or the shares the vault released to the caller in this entry (the balance change across `fundCall`), so a
    /// pre-existing margin-asset balance is never consumed. `marginBefore` is the caller's balance before `fundCall`;
    /// the one balance read here, after `fundCall` and before the withdrawal, is both the released end point and the
    /// burn start point.
    function _withdrawReleasedMargin(FundOperation memory op, uint256 marginBefore) private {
        uint256 marginAfterFund = IERC20(op.marginAsset).balanceOf(op.user);
        uint256 released = marginAfterFund - marginBefore;
        uint256 burned = _withdrawUsdc(op.marginAsset, op.marginAssets, op.user, marginAfterFund);
        if (burned > op.maxMarginShares) revert MarginSharesExceedMax(burned, op.maxMarginShares);
        if (burned > released) revert MarginExceedsReleased(burned, released);
    }

    /// @dev Withdraws exactly `marginAssets` of USDC to the helper from its own margin-asset shares, whose balance is
    /// `marginBefore + awardReceived` after the fill. The shares burned must not exceed `awardReceived`, so donated
    /// shares are never spent; the USDC received must equal `marginAssets`. Returns the award shares left to forward.
    function _withdrawAward(TakeOperation memory op, uint256 marginBefore, uint256 awardReceived)
        private
        returns (uint256)
    {
        uint256 burned = _withdrawUsdc(op.marginAsset, op.marginAssets, address(this), marginBefore + awardReceived);
        if (burned > awardReceived) revert MarginExceedsAward(burned, awardReceived);
        return awardReceived - burned;
    }

    /// @dev Withdraws exactly `assets` of USDC to the helper from `owner`'s shares of the ERC-4626 `marginAsset`,
    /// requires the helper's USDC balance to rise by exactly `assets` (`MarginReceiptMismatch`), and returns the shares
    /// burned, measured from `sharesBefore`, `owner`'s balance the caller already read, to its balance after the
    /// withdrawal.
    function _withdrawUsdc(address marginAsset, uint256 assets, address owner, uint256 sharesBefore)
        private
        returns (uint256 burned)
    {
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));

        IERC4626(marginAsset).withdraw(assets, address(this), owner);

        burned = sharesBefore - IERC20(marginAsset).balanceOf(owner);
        uint256 received = IERC20(usdc).balanceOf(address(this)) - usdcBefore;
        if (received != assets) revert MarginReceiptMismatch(received, assets);
    }

    /* COOLDOWN BOOK */

    /// @dev Opens a cooldown for `shares` supplied in this entry, first merging the two oldest cooldowns when the book
    /// is full (see `CooldownsMerged`). Never reverts for book reasons.
    function _startCooldown(address user, bytes32 marketId, uint256 shares) private {
        uint64 duration = ILCCNotificationVault(usd3l).cooldownDuration();
        uint64 start = uint64(block.timestamp); // deliberate wall-clock read
        Cooldown memory cooldown = Cooldown({shares: uint128(shares), start: start, duration: duration});
        Cooldown[] storage book = _cooldowns[user][marketId];
        uint256 length = book.length;
        if (length < MAX_COOLDOWNS) {
            book.push(cooldown);
        } else {
            Cooldown memory merged = book[0];
            Cooldown memory second = book[1];
            uint256 maturity =
                Math.max(uint256(merged.start) + merged.duration, uint256(second.start) + second.duration);
            if (second.start > merged.start) merged.start = second.start;
            merged.duration = uint64(maturity - merged.start);
            merged.shares += second.shares;
            book[0] = merged;
            for (uint256 i = 2; i < length; ++i) {
                book[i - 1] = book[i];
            }
            book[length - 1] = cooldown;
            emit CooldownsMerged(user, marketId, merged.shares, merged.start, merged.duration);
        }
        emit CooldownStarted(user, marketId, cooldown.shares, cooldown.start, cooldown.duration);
    }

    /// @dev Consumes `shares` from the caller's matured cooldowns in `marketId`, oldest first, keeping the remaining
    /// cooldowns in order and writing only cooldowns that changed or moved. Skipped while the USD3l cooldown is waived.
    function _consumeCooldowns(address user, bytes32 marketId, uint256 shares) private {
        uint256 liveDuration = ILCCNotificationVault(usd3l).cooldownDuration();
        if (_cooldownWaived(liveDuration)) return;
        Cooldown[] storage book = _cooldowns[user][marketId];
        uint256 length = book.length;
        uint256 remaining = shares;
        uint256 kept;
        for (uint256 i; i < length; ++i) {
            Cooldown memory cooldown = book[i];
            bool changed;
            if (remaining != 0 && _isMatured(cooldown, liveDuration)) {
                uint256 taken = Math.min(remaining, cooldown.shares);
                cooldown.shares -= uint128(taken);
                remaining -= taken;
                changed = true;
            }
            if (cooldown.shares != 0) {
                if (changed || kept != i) book[kept] = cooldown;
                ++kept;
            }
        }
        if (remaining != 0) revert InsufficientMaturedShares(shares, shares - remaining);
        for (uint256 i = kept; i < length; ++i) {
            book.pop();
        }
        emit CooldownsConsumed(user, marketId, shares);
    }

    /// @dev Sum of `user`'s cooldown shares in `marketId` matured at `liveDuration`.
    function _maturedShares(address user, bytes32 marketId, uint256 liveDuration)
        private
        view
        returns (uint256 shares)
    {
        Cooldown[] storage book = _cooldowns[user][marketId];
        for (uint256 i; i < book.length; ++i) {
            Cooldown memory cooldown = book[i];
            if (_isMatured(cooldown, liveDuration)) shares += cooldown.shares;
        }
    }

    /// @dev A cooldown matures at its start plus the longer of its recorded and the live USD3l cooldown.
    function _isMatured(Cooldown memory cooldown, uint256 liveDuration) private view returns (bool) {
        uint256 currentTime = block.timestamp; // deliberate wall-clock read
        return currentTime >= uint256(cooldown.start) + Math.max(cooldown.duration, liveDuration);
    }

    /// @dev Mirrors the USD3l vault's own waivers: no cooldown applies while its already-read `liveDuration` is zero
    /// or the vault is shut down (read only when the duration is nonzero).
    function _cooldownWaived(uint256 liveDuration) private view returns (bool) {
        return liveDuration == 0 || ILCCNotificationVault(usd3l).isShutdown();
    }

    /* DEBT & LTV */

    /// @dev `user`'s borrow shares, collateral, and debt in market `id` (shares valued rounding up), with the market's
    /// borrow totals, from one position read and one market read.
    function _debtOf(bytes32 id, address user) private view returns (DebtState memory debt) {
        (, uint128 borrowShares, uint128 collateral) = IMorphoBlue(morpho).position(id, user);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorphoBlue(morpho).market(id);
        debt.borrowShares = borrowShares;
        debt.collateral = collateral;
        debt.totalBorrowAssets = totalBorrowAssets;
        debt.totalBorrowShares = totalBorrowShares;
        debt.assets = uint256(borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    /// @dev `user`'s collateral in market `id` as Morpho records it.
    function _positionCollateral(bytes32 id, address user) private view returns (uint256 collateral) {
        (,, collateral) = IMorphoBlue(morpho).position(id, user);
    }

    /// @dev Values the user's whole position in `market` at that market's oracle price, rounding debt up. Runs only
    /// after a nonzero borrow in this transaction: Morpho's `borrow` accrued interest, so the market totals are current
    /// and the borrow shares are nonzero. A zero collateral value (an oracle reading zero) is treated as unbounded LTV.
    /// Returns the position's collateral it valued.
    function _checkEntryLtv(IMorphoBlue.MarketParams memory market, bytes32 id, address user, uint256 maxEntryLtv)
        private
        view
        returns (uint256 positionCollateral)
    {
        DebtState memory debt = _debtOf(id, user);
        positionCollateral = debt.collateral;
        uint256 collateralValue =
            positionCollateral.mulDivDown(IMorphoBlueOracle(market.oracle).price(), ORACLE_PRICE_SCALE);
        uint256 ltv = collateralValue == 0 ? type(uint256).max : debt.assets.wDivUp(collateralValue);
        if (ltv > maxEntryLtv) revert EntryLtvExceeded(ltv, maxEntryLtv);
    }

    /* PERMITS & AUTHORIZATION */

    /// @dev True when a levered entry still needs the caller's Morpho authorization of this helper.
    function _needsAuthorization(uint256 borrowAssets) private view returns (bool) {
        return borrowAssets != 0 && !_isAuthorized();
    }

    /// @dev True when the caller has authorized this helper on Morpho.
    function _isAuthorized() private view returns (bool) {
        return IMorphoBlue(morpho).isAuthorized(msg.sender, address(this));
    }

    /// @dev Applies the caller's enabling Morpho authorization of this helper. A submission that reverts (for example
    /// because a third party already submitted it) is tolerated when the authorization is then in place.
    function _applyAuthorization(
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata signature
    ) private {
        if (
            authorization.authorizer != msg.sender || authorization.authorized != address(this)
                || !authorization.isAuthorized
        ) revert InvalidAuthorization();
        try IMorphoBlue(morpho).setAuthorizationWithSig(authorization, signature) {} catch {}
        if (!_isAuthorized()) revert AuthorizationFailed();
    }

    /// @dev Always submits the permit, so a signed permit cannot outlive this call to be submitted later and reset the
    /// allowance. A permit that applies sets the allowance to its `value`; a revert (for example because a third party
    /// already submitted it) is tolerated. The resulting allowance must then cover `required`, or the call reverts
    /// with `InsufficientAllowance`, carrying the permit's revert data (empty when the permit applied).
    function _applyPermit(address token, PermitSignature calldata permit, uint256 required) private {
        bytes memory permitRevert;
        try IERC20Permit(token)
            .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {}
        catch (bytes memory reason) {
            permitRevert = reason;
        }
        _requireAllowance(token, required, permitRevert);
    }

    /// @dev Reverts with `InsufficientAllowance`, carrying `permitRevert`, unless the caller's allowance of `token` to
    /// this helper covers `required`.
    function _requireAllowance(address token, uint256 required, bytes memory permitRevert) private view {
        uint256 allowance = IERC20(token).allowance(msg.sender, address(this));
        if (allowance < required) revert InsufficientAllowance(token, allowance, required, permitRevert);
    }

    /* VAULT WIRING */

    /// @dev Returns the vault's margin asset without calling the margin asset.
    function _validateVault(address vault) private view returns (address marginAsset) {
        if (!LCCVaultFactory(factory).isVault(vault)) revert UnregisteredVault();
        ILCCVault.AssetConfig memory config = ILCCVault(vault).assetConfig();
        if (config.fundingAsset != usdc || config.usd3 != usd3 || config.notificationVault != usd3l) {
            revert VaultAssetMismatch();
        }
        if (config.marginAsset == usd3l) revert MarginAssetIsCollateral();
        return config.marginAsset;
    }

    /// @dev Requires `marginAsset` to be an ERC-4626 vault over USDC; checked only on entries that source margin.
    function _requireUsdcVault(address marginAsset) private view {
        if (marginAsset.code.length == 0) revert MarginAssetNotUsdcVault(marginAsset);
        try IERC4626(marginAsset).asset() returns (address asset) {
            if (asset == usdc) return;
        } catch {}
        revert MarginAssetNotUsdcVault(marginAsset);
    }
}
