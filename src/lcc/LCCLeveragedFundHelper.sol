// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import {ORACLE_PRICE_SCALE} from "../libraries/ConstantsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {SharesMathLib} from "../libraries/SharesMathLib.sol";
import {ILCCLeveragedFundHelper} from "./interfaces/ILCCLeveragedFundHelper.sol";
import {ILCCVault} from "./interfaces/ILCCVault.sol";
import {ILCCVaultFactory} from "./interfaces/ILCCVaultFactory.sol";
import {LCCAuctionLib} from "./libraries/LCCAuctionLib.sol";
import {IMorphoBlue, IMorphoBlueFlashLoanCallback} from "./interfaces/IMorphoBlue.sol";
import {ILCCNotificationVault, ILCCRedeemableVault} from "./interfaces/ILCCNotificationVault.sol";

/// @title LCCLeveragedFundHelper
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Levered LCC funding, shortfall-auction takes, and unwinds on the pinned canonical Morpho Blue singleton.
/// `ILCCLeveragedFundHelper` is the behaviour specification; `src/lcc/README.md` is the auditor narrative.
/// @dev Layout: entrypoints size and validate a request with view reads (a take also syncs the vault), then
/// `_executeFund`, `takeAuction`, or `_executeUnwind` runs it directly or through `_bridge`, whose flash-loan
/// callback dispatches on the payload's `OperationKind` to `_runFund`, `_runTake`, or `_runUnwind`. Persistent state is
/// the cooldown book; the in-flight operation hash and the reentrancy lock are transient.
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
        uint256 contribution;
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
        uint256 contribution;
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

    /// @notice Grants Morpho standing maximal USD3l and USDC allowances, used for collateral supply, flash-loan
    /// repayment, and debt repayment. The standing USDC allowance means Morpho's pulls are not capped by an exact
    /// approval: the helper relies on canonical Morpho pulling exactly the repay and flash amounts, and an unwind's
    /// end-of-entry USDC balance check catches any excess.
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

        // Morpho pulls only from its msg.sender, and the helper holds no USD3l or USDC of its own between
        // transactions, so standing allowances expose nothing.
        IERC20(usd3l_).forceApprove(morpho_, type(uint256).max);
        IERC20(usdc_).forceApprove(morpho_, type(uint256).max);
    }

    /// @dev Requires the helper's USD3l balance to end the entrypoint where it started (`UnexpectedBalance`): the
    /// helper is a bypassed USD3l owner, so it must never keep USD3l it handled, and donated USD3l is never touched.
    modifier keepsUsd3lBalance() {
        uint256 usd3lBefore = _usd3lBalance();
        _;
        _requireUsd3lBalance(usd3lBefore);
    }

    /* FUND */

    /// @inheritdoc ILCCLeveragedFundHelper
    /// @dev The allowance checks follow sizing, which makes only view calls, and precede any token movement.
    function fund(FundParams calldata params)
        external
        nonReentrant
        keepsUsd3lBalance
        returns (uint256 obligation, uint256 fundingAmount, uint256 collateral)
    {
        if (_needsAuthorization(params.borrowAssets)) revert NotAuthorized();
        FundOperation memory op = _sizeFund(params);
        _requireContributionAllowance(op.contribution);
        _requireAllowance(usd3l, op.maxCollateral, "");
        if (op.marginAssets != 0) _requireAllowance(op.marginAsset, op.maxMarginShares, "");
        return (op.obligation, op.fundingAmount, _executeFund(op, _marketId(op.market), params.maxEntryLtv));
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
    ) external nonReentrant keepsUsd3lBalance returns (uint256 obligation, uint256 fundingAmount, uint256 collateral) {
        FundOperation memory op = _sizeFund(params);

        if (op.contribution != 0) _applyPermit(usdc, usdcPermit, op.contribution);
        _applyPermit(usd3l, usd3lPermit, op.maxCollateral);
        if (op.marginAssets != 0) _applyPermit(op.marginAsset, marginPermit, op.maxMarginShares);
        if (_needsAuthorization(op.borrowAssets)) _applyAuthorization(authorization, authorizationSignature);

        return (op.obligation, op.fundingAmount, _executeFund(op, _marketId(op.market), params.maxEntryLtv));
    }

    /* TAKE */

    /// @inheritdoc ILCCLeveragedFundHelper
    /// @dev The only allowance checked is the caller's USDC allowance against the scaled contribution: the USD3l and
    /// the margin award are delivered to this helper, and the award withdrawal burns the helper's own shares.
    function takeAuction(TakeParams calldata params)
        external
        nonReentrant
        keepsUsd3lBalance
        returns (uint256 filled, uint256 collateral)
    {
        if (_needsAuthorization(params.borrowAssets)) revert NotAuthorized();
        TakeOperation memory op = _sizeTake(params);
        _requireContributionAllowance(op.contribution);
        bytes32 id = _marketId(op.market);
        uint256 flashAssets = op.borrowAssets + op.marginAssets;
        if (flashAssets == 0) {
            _pullContribution(op.contribution);
            collateral = _runTake(op);
            _startCooldown(msg.sender, id, collateral);
        } else {
            collateral = _executeBridgedEntry(
                abi.encode(OperationKind.Take, op),
                flashAssets,
                op.contribution,
                op.market,
                id,
                op.borrowAssets != 0,
                params.maxEntryLtv
            );
        }
        emit AuctionTaken(op.user, op.vault, id, op.fill, collateral, op.borrowAssets, op.marginAssets);
        return (op.fill, collateral);
    }

    /* UNWIND */

    /// @inheritdoc ILCCLeveragedFundHelper
    function unwind(UnwindParams calldata params)
        external
        nonReentrant
        keepsUsd3lBalance
        returns (uint256 repaidAssets, uint256 amountOut)
    {
        if (!_isAuthorized()) revert NotAuthorized();
        return _executeUnwind(params);
    }

    /// @inheritdoc ILCCLeveragedFundHelper
    function unwindWithAuthorization(
        UnwindParams calldata params,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    ) external nonReentrant keepsUsd3lBalance returns (uint256 repaidAssets, uint256 amountOut) {
        if (!_isAuthorized()) {
            _applyAuthorization(authorization, authorizationSignature);
        }
        return _executeUnwind(params);
    }

    /* FLASH-LOAN CALLBACK */

    /// @inheritdoc IMorphoBlueFlashLoanCallback
    /// @dev Accepted only from Morpho while this helper's own `flashLoan` call is in flight, and only when the
    /// loaned `assets` and `data` hash to the operation recorded for it, so the amount is bound with the payload. The
    /// record is cleared before any external call. Morpho pulls the repayment under the standing USDC allowance.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external override {
        if (msg.sender != morpho) revert InvalidCallback();
        bytes32 expected = _operation;
        if (expected == bytes32(0)) revert InvalidCallback();
        if (keccak256(abi.encodePacked(assets, keccak256(data))) != expected) revert InvalidCallback();
        _operation = bytes32(0);

        OperationKind kind = abi.decode(data[:32], (OperationKind));
        if (kind == OperationKind.Fund) {
            (, FundOperation memory op) = abi.decode(data, (OperationKind, FundOperation));
            _runFund(op);
        } else if (kind == OperationKind.Unwind) {
            (, UnwindOperation memory op) = abi.decode(data, (OperationKind, UnwindOperation));
            uint256 received = _runUnwind(op);
            if (received < assets) revert RedemptionBelowRepayment(usdc, received, assets);
        } else {
            (, TakeOperation memory op) = abi.decode(data, (OperationKind, TakeOperation));
            _runTake(op);
        }
    }

    /* VIEWS */

    /// @inheritdoc ILCCLeveragedFundHelper
    function cooldowns(address user, bytes32 marketId) external view returns (Cooldown[] memory) {
        return _cooldowns[user][marketId];
    }

    /// @inheritdoc ILCCLeveragedFundHelper
    function maxUnwindable(address user, bytes32 marketId) external view returns (uint256) {
        uint256 collateral = _positionCollateral(marketId, user);
        uint256 liveDuration = ILCCNotificationVault(usd3l).cooldownDuration();
        if (_cooldownWaived(liveDuration)) return collateral;
        return Math.min(collateral, _maturedShares(user, marketId, liveDuration));
    }

    /// @dev The helper's own USD3l balance.
    function _usd3lBalance() private view returns (uint256) {
        return IERC20(usd3l).balanceOf(address(this));
    }

    /// @dev Reverts with `UnexpectedBalance` unless the helper's USD3l balance equals `expected`.
    function _requireUsd3lBalance(uint256 expected) private view {
        uint256 balance = _usd3lBalance();
        if (balance != expected) revert UnexpectedBalance(usd3l, balance, expected);
    }

    /* REQUEST VALIDATION */

    /// @dev Checks shared by every entry and unwind: the deadline, then the market's loan and collateral tokens.
    function _validateRequest(uint256 deadline, IMorphoBlue.MarketParams calldata market) private view {
        if (block.timestamp > deadline) revert DeadlineExpired(); // deliberate wall-clock read
        if (market.loanToken != usdc || market.collateralToken != usd3l) revert InvalidRequest();
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
            revert InvalidRequest();
        }
        address marginAsset = _validateVault(params.vault);
        if (params.marginAssets != 0) {
            if (params.maxMarginShares == 0) revert InvalidRequest();
            _requireUsdcVault(marginAsset);
            op.marginAsset = marginAsset;
            op.marginAssets = params.marginAssets;
            op.maxMarginShares = params.maxMarginShares;
        }

        ILCCVault vault = ILCCVault(params.vault);
        if (vault.currentPhase() != ILCCVault.Phase.Funding) revert NothingToFund();
        op.user = msg.sender;
        op.vault = params.vault;
        op.market = params.market;
        op.obligation = vault.obligationOf(vault.currentEpoch(), msg.sender);
        if (op.obligation == 0) revert NothingToFund();
        if (op.obligation > params.maxObligation) revert ObligationExceedsMax(op.obligation, params.maxObligation);

        op.fundingAmount = Math.max(op.obligation, IERC4626(usd3).previewMint(1));
        if (op.fundingAmount - op.obligation > MAX_FUNDING_TOP_UP) {
            revert FundingTopUpExceeded(op.fundingAmount, op.obligation);
        }
        _requireSplit(params.borrowAssets, params.marginAssets, op.fundingAmount);
        op.borrowAssets = params.borrowAssets;

        op.contribution = op.fundingAmount - op.borrowAssets - op.marginAssets;
        if (op.contribution > params.maxContribution) {
            revert ContributionExceedsMax(op.contribution, params.maxContribution);
        }

        op.minCollateral = params.minCollateral;
        op.maxCollateral = params.maxCollateral;
    }

    /// @dev Validates a take, syncs the vault (see `takeAuction`), sizes the fill, and scales it as `TakeParams` says.
    function _sizeTake(TakeParams calldata params) private returns (TakeOperation memory op) {
        _validateRequest(params.deadline, params.market);
        if (params.minCollateral == 0) revert InvalidRequest();
        uint256 maxFill = params.maxFill;
        if (maxFill == 0 || params.minFill > maxFill) revert InvalidRequest();
        _requireSplit(params.borrowAssets, params.marginAssets, maxFill);
        address marginAsset = _validateVault(params.vault);
        if (marginAsset == usdc || marginAsset == usd3) revert UnsupportedMarginAsset(marginAsset);
        if (params.marginAssets != 0) _requireUsdcVault(marginAsset);

        ILCCVault vault = ILCCVault(params.vault);
        uint256 slot = vault.syncState().pendingAuctionEpochPlusOne;
        if (slot != 0) vault.finalizeEpochSlash(slot - 1);
        else vault.materializeAccount(address(this));
        slot = vault.syncState().pendingAuctionEpochPlusOne;
        if (slot == 0) revert NothingToFund();
        LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(slot - 1);
        uint256 fill = Math.min(maxFill, uint256(auction.shortfallAmount) - auction.filledAmount);
        if (fill < params.minFill) revert FillBelowMinimum(fill, params.minFill);

        op.user = msg.sender;
        op.vault = params.vault;
        op.marginAsset = marginAsset;
        op.market = params.market;
        op.fill = fill;
        op.contribution = Math.mulDiv(maxFill - params.borrowAssets - params.marginAssets, fill, maxFill);
        op.marginAssets = Math.mulDiv(params.marginAssets, fill, maxFill);
        if (params.borrowAssets != 0) op.borrowAssets = fill - op.contribution - op.marginAssets;
        else if (params.marginAssets != 0) op.marginAssets = fill - op.contribution;
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

    /// @dev Runs a sized funding in market `id`, directly through `_runFund` when it bridges nothing and otherwise
    /// through `_executeBridgedEntry`, and returns the collateral supplied.
    function _executeFund(FundOperation memory op, bytes32 id, uint256 maxEntryLtv)
        private
        returns (uint256 collateral)
    {
        uint256 flashAssets = op.borrowAssets + op.marginAssets;
        if (flashAssets != 0) {
            return _executeBridgedEntry(
                abi.encode(OperationKind.Fund, op),
                flashAssets,
                op.contribution,
                op.market,
                id,
                op.borrowAssets != 0,
                maxEntryLtv
            );
        }
        _pullContribution(op.contribution);
        collateral = _runFund(op);
        _startCooldown(msg.sender, id, collateral);
    }

    /// @dev The bridged half of a funding or take entry, shared by both: pulls the caller's `contribution`, runs the
    /// entry's `payload` inside a flash loan of `flashAssets` (`_bridgeEntry`), and opens the cooldown for the
    /// collateral supplied in market `id`.
    function _executeBridgedEntry(
        bytes memory payload,
        uint256 flashAssets,
        uint256 contribution,
        IMorphoBlue.MarketParams memory market,
        bytes32 id,
        bool borrowed,
        uint256 maxEntryLtv
    ) private returns (uint256 collateral) {
        _pullContribution(contribution);
        collateral = _bridgeEntry(payload, flashAssets, market, id, borrowed, maxEntryLtv);
        _startCooldown(msg.sender, id, collateral);
    }

    /// @dev Pulls a nonzero USDC `contribution` from the caller to the helper.
    function _pullContribution(uint256 contribution) private {
        if (contribution != 0) IERC20(usdc).safeTransferFrom(msg.sender, address(this), contribution);
    }

    /// @dev Checks the request, consumes matured cooldowns before any state-changing external call, accrues the market,
    /// sizes the repayment, runs the unwind directly or through the flash bridge when the repayment is nonzero, and
    /// sends the caller the output token's measured balance change of the helper. Full mode leaves zero debt because it
    /// repays the exact share count read after accrual in this transaction.
    function _executeUnwind(UnwindParams calldata params) private returns (uint256 repaidAssets, uint256 amountOut) {
        _validateRequest(params.deadline, params.market);
        if (params.shares == 0) revert InvalidRequest();

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
        uint256 usdcAfter = IERC20(usdc).balanceOf(address(this));
        address outToken;
        if (params.usd3Out) {
            if (usdcAfter != usdcBefore) revert UnexpectedBalance(usdc, usdcAfter, usdcBefore);
            outToken = usd3;
            amountOut = IERC20(usd3).balanceOf(address(this)) - usd3Before;
        } else {
            outToken = usdc;
            amountOut = usdcAfter - usdcBefore;
        }
        if (amountOut < params.minOut) revert UnwindOutputBelowMinimum(amountOut, params.minOut);

        if (amountOut != 0) IERC20(outToken).safeTransfer(msg.sender, amountOut);
        emit Unwound(msg.sender, id, outToken, op.repayAssets, params.shares, amountOut);
        return (op.repayAssets, amountOut);
    }

    /// @dev Bridges an entry and returns the change in the caller's collateral in market `id` across the flash loan.
    /// The caller is read here, before bridging, because msg.sender is Morpho inside the callback. When the entry
    /// borrowed, the read-back is the whole-position LTV check against `maxEntryLtv`.
    function _bridgeEntry(
        bytes memory data,
        uint256 flashAssets,
        IMorphoBlue.MarketParams memory market,
        bytes32 id,
        bool borrowed,
        uint256 maxEntryLtv
    ) private returns (uint256) {
        address user = msg.sender;
        uint256 collateralBefore = _positionCollateral(id, user);
        _bridge(data, flashAssets);
        uint256 collateralAfter =
            borrowed ? _checkEntryLtv(market, id, user, maxEntryLtv) : _positionCollateral(id, user);
        return collateralAfter - collateralBefore;
    }

    /// @dev Records `keccak256(abi.encodePacked(assets, keccak256(data)))` as the in-flight operation, takes a Morpho
    /// flash loan of `assets` USDC with `data`, and requires the callback to have consumed the record.
    function _bridge(bytes memory data, uint256 assets) private {
        _operation = keccak256(abi.encodePacked(assets, keccak256(data)));
        IMorphoBlue(morpho).flashLoan(usdc, assets, data);
        if (_operation != bytes32(0)) revert InvalidCallback();
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
    /// forwards the rest of the award; and borrows `borrowAssets` for the caller to the helper. Returns the collateral
    /// supplied.
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

    /// @dev Repays `repayShares` of the caller's debt by shares from the helper's flash-loaned USDC under the standing
    /// allowance (Morpho pulls exactly the shares' value rounded up, which is `repayAssets`), withdraws
    /// `shares` of the caller's collateral to the helper, redeems exactly the USD3l that withdrawal delivered, and
    /// returns the USDC received from USD3. Any other USD3l, USD3, or USDC the helper holds is never touched.
    function _runUnwind(UnwindOperation memory op) private returns (uint256) {
        if (op.repayShares != 0) {
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
    /// the USD3 actually burned is held to the same bound, so donated USD3 is never spent (`RedemptionBelowRepayment`
    /// in USD3 for both). Returns the USDC received. Every amount is a measured balance change.
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
            if (required > usd3Received) revert RedemptionBelowRepayment(usd3, usd3Received, required);
            ILCCRedeemableVault(usd3).withdraw(repayAssets, address(this), address(this), 0);
            uint256 usd3Spent = usd3AfterRedeem - IERC20(usd3).balanceOf(address(this));
            if (usd3Spent > usd3Received) revert RedemptionBelowRepayment(usd3, usd3Received, usd3Spent);
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
        if (burned > released) revert MarginSharesUnavailable(burned, released);
    }

    /// @dev Withdraws exactly `marginAssets` of USDC to the helper from its own margin-asset shares, whose balance is
    /// `marginBefore + awardReceived` after the fill. The shares burned must not exceed `awardReceived`, so donated
    /// shares are never spent; the USDC received must equal `marginAssets`. Returns the award shares left to forward.
    function _withdrawAward(TakeOperation memory op, uint256 marginBefore, uint256 awardReceived)
        private
        returns (uint256)
    {
        uint256 burned = _withdrawUsdc(op.marginAsset, op.marginAssets, address(this), marginBefore + awardReceived);
        if (burned > awardReceived) revert MarginSharesUnavailable(burned, awardReceived);
        return awardReceived - burned;
    }

    /// @dev Withdraws exactly `assets` of USDC to the helper from `owner`'s shares of the ERC-4626 `marginAsset`,
    /// requires the helper's USDC balance to end exactly `assets` above where it started (`UnexpectedBalance`, with
    /// both balances absolute), and returns the shares burned, measured from `sharesBefore`, `owner`'s balance the
    /// caller already read, to its balance after the withdrawal.
    function _withdrawUsdc(address marginAsset, uint256 assets, address owner, uint256 sharesBefore)
        private
        returns (uint256 burned)
    {
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));

        IERC4626(marginAsset).withdraw(assets, address(this), owner);

        burned = sharesBefore - IERC20(marginAsset).balanceOf(owner);
        uint256 usdcAfter = IERC20(usdc).balanceOf(address(this));
        if (usdcAfter != usdcBefore + assets) revert UnexpectedBalance(usdc, usdcAfter, usdcBefore + assets);
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
    /// cooldowns in order and writing only cooldowns that changed or moved. Once nothing remains to consume and no
    /// cooldown has been removed, the rest of the book is left unread and its length unchanged. Skipped while the USD3l
    /// cooldown is waived.
    function _consumeCooldowns(address user, bytes32 marketId, uint256 shares) private {
        uint256 liveDuration = ILCCNotificationVault(usd3l).cooldownDuration();
        if (_cooldownWaived(liveDuration)) return;
        Cooldown[] storage book = _cooldowns[user][marketId];
        uint256 length = book.length;
        uint256 remaining = shares;
        uint256 kept;
        for (uint256 i; i < length; ++i) {
            if (remaining == 0 && kept == i) return;
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
        uint256 collateralValue = positionCollateral.mulDivDown(IOracle(market.oracle).price(), ORACLE_PRICE_SCALE);
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

    /// @dev Applies the caller's enabling Morpho authorization of this helper. A payload whose authorizer is not the
    /// caller, whose authorized address is not this helper, or that does not enable reverts `InvalidRequest`. A
    /// submission that reverts (for example because a third party already submitted it) is tolerated when the
    /// authorization is then in place, and reverts `NotAuthorized` otherwise.
    function _applyAuthorization(
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata signature
    ) private {
        if (
            authorization.authorizer != msg.sender || authorization.authorized != address(this)
                || !authorization.isAuthorized
        ) revert InvalidRequest();
        try IMorphoBlue(morpho).setAuthorizationWithSig(authorization, signature) {} catch {}
        if (!_isAuthorized()) revert NotAuthorized();
    }

    /// @dev Submits the permit (see `PermitSignature`), tolerating a revert such as a third party's prior submission,
    /// then requires the resulting allowance to cover `required` (`InsufficientAllowance`, carrying the permit's revert
    /// data, empty when the permit applied).
    function _applyPermit(address token, PermitSignature calldata permit, uint256 required) private {
        bytes memory permitRevert;
        try IERC20Permit(token)
            .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {}
        catch (bytes memory reason) {
            permitRevert = reason;
        }
        _requireAllowance(token, required, permitRevert);
    }

    /// @dev The standing-allowance check of a nonzero USDC contribution, shared by `fund` and `takeAuction`.
    function _requireContributionAllowance(uint256 contribution) private view {
        if (contribution != 0) _requireAllowance(usdc, contribution, "");
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
        if (!ILCCVaultFactory(factory).isVault(vault)) revert UnregisteredVault();
        ILCCVault.AssetConfig memory config = ILCCVault(vault).assetConfig();
        if (config.fundingAsset != usdc || config.usd3 != usd3 || config.notificationVault != usd3l) {
            revert InvalidConfiguration();
        }
        if (config.marginAsset == usd3l) revert UnsupportedMarginAsset(config.marginAsset);
        return config.marginAsset;
    }

    /// @dev Requires `marginAsset` to be an ERC-4626 vault over USDC; checked only on entries that source margin.
    function _requireUsdcVault(address marginAsset) private view {
        if (marginAsset.code.length == 0) revert UnsupportedMarginAsset(marginAsset);
        try IERC4626(marginAsset).asset() returns (address asset) {
            if (asset == usdc) return;
        } catch {}
        revert UnsupportedMarginAsset(marginAsset);
    }
}
