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
import {IMorphoBlue, IMorphoBlueOracle, IMorphoBlueFlashLoanCallback} from "./interfaces/IMorphoBlue.sol";

/// @title LCCLeveragedFundHelper
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Funds the caller's LCC capital-call obligation with amortizing push funding while borrowing part of it on a
/// caller-chosen market of the pinned canonical Morpho Blue singleton that lends USDC against USD3l, using the USD3l
/// the funding delivers as collateral.
/// @dev The LCC beneficiary and the Morpho `onBehalf` are always msg.sender. The helper pulls the caller's USDC
/// contribution, bridges `borrowAssets + marginAssets` with a Morpho flash loan when that sum is nonzero, pays the
/// vault through `fundCall(address)` (which releases margin to the caller), measures the USD3l the caller received,
/// requires it to reach the caller's `minCollateral`, supplies up to `maxCollateral` of it as collateral on behalf of
/// the caller (any excess stays in the caller's wallet), withdraws `marginAssets` of USDC from the caller's
/// ERC-4626-over-USDC margin-asset shares, and borrows `borrowAssets`; those two repay the flash loan. An entry with
/// neither runs the same sequence directly, without a flash loan. After a flash-loan entry the collateral supplied is
/// read back from the caller's Morpho position; only an entry that borrows reads the oracle, and the caller's whole
/// position in that market must then be within the caller's LTV bound.
/// The helper holds no factory role, never deposits into USD3 itself, and has no owner, rescue, receiver-choice,
/// delegated-beneficiary, arbitrary-call, or upgrade surface. Its only state is the transient in-flight operation and
/// the reentrancy lock.
contract LCCLeveragedFundHelper is ILCCLeveragedFundHelper, IMorphoBlueFlashLoanCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    /// @dev Mirrors the vault's bound on the extra funding asset pulled so a dust obligation mints one USD3 share.
    uint256 internal constant MAX_FUNDING_TOP_UP = 1_000;

    /// @dev Inputs one funding binds; its hash is the in-flight operation the Morpho flash-loan callback must match.
    struct Operation {
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

    address public immutable override morpho;
    address public immutable override factory;
    address public immutable override usdc;
    address public immutable override usd3;
    address public immutable override usd3l;

    bytes32 private transient _operation;

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
        Operation memory op = _prepare(params);
        uint256 contribution = _contribution(op);
        if (contribution != 0) _requireAllowance(usdc, contribution, "");
        _requireAllowance(usd3l, op.maxCollateral, "");
        if (op.marginAssets != 0) _requireAllowance(op.marginAsset, op.maxMarginShares, "");
        return _execute(op, params.maxEntryLtv);
    }

    /// @inheritdoc ILCCLeveragedFundHelper
    /// @dev The USD3l permit, the USDC permit whenever the USDC contribution is nonzero, and the margin-asset permit
    /// whenever `params.marginAssets` is nonzero are always submitted with msg.sender as owner and this helper as
    /// spender, so a permit that applies replaces the caller's standing allowance to this helper with its `value`. A
    /// fully levered entry pulls no USDC, so its USDC permit is ignored and the standing USDC allowance is left
    /// untouched; an entry without margin ignores the margin permit. A permit that reverts is tolerated; the call then
    /// reverts with `InsufficientAllowance` unless the resulting allowance covers the need, which for USD3l is
    /// `maxCollateral` and for the margin asset `maxMarginShares`, the most the entry can pull or burn. The
    /// authorization is ignored when `params.borrowAssets` is zero or the caller has already authorized this helper on
    /// Morpho. Otherwise it must name msg.sender as authorizer, this helper as
    /// authorized, and enable it; a submission that reverts is tolerated if the authorization is then in place. There
    /// is no revoking counterpart, so the authorization stays enabled until the caller revokes it on Morpho.
    function fundWithSignatures(
        FundParams calldata params,
        PermitSignature calldata usdcPermit,
        PermitSignature calldata usd3lPermit,
        PermitSignature calldata marginPermit,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    ) external nonReentrant returns (uint256 obligation, uint256 fundingAmount, uint256 collateral) {
        Operation memory op = _prepare(params);

        uint256 contribution = _contribution(op);
        if (contribution != 0) _applyPermit(usdc, usdcPermit, contribution);
        _applyPermit(usd3l, usd3lPermit, op.maxCollateral);
        if (op.marginAssets != 0) _applyPermit(op.marginAsset, marginPermit, op.maxMarginShares);
        if (_needsAuthorization(op.borrowAssets)) _applyAuthorization(authorization, authorizationSignature);

        return _execute(op, params.maxEntryLtv);
    }

    /// @inheritdoc IMorphoBlueFlashLoanCallback
    /// @dev Accepted only from Morpho while this helper's own `flashLoan` call is in flight, and only for the exact
    /// operation recorded for it and the amount it bridges (`borrowAssets + marginAssets`). The record is cleared
    /// before any external call.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external override {
        if (msg.sender != morpho) revert NotMorpho();
        bytes32 expected = _operation;
        if (expected == bytes32(0)) revert NoOperationInFlight();
        if (keccak256(data) != expected) revert OperationMismatch();
        _operation = bytes32(0);

        Operation memory op = abi.decode(data, (Operation));
        if (assets != op.borrowAssets + op.marginAssets) revert OperationMismatch();

        _run(op);
        IERC20(usdc).forceApprove(morpho, assets);
    }

    function _prepare(FundParams calldata params) private view returns (Operation memory op) {
        if (block.timestamp > params.deadline) revert DeadlineExpired(); // deliberate wall-clock read
        if (params.market.loanToken != usdc || params.market.collateralToken != usd3l) revert MarketTokenMismatch();
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
        if (params.borrowAssets > op.fundingAmount || params.marginAssets > op.fundingAmount - params.borrowAssets) {
            revert BorrowAndMarginExceedFunding(params.borrowAssets, params.marginAssets, op.fundingAmount);
        }
        op.borrowAssets = params.borrowAssets;

        uint256 contribution = _contribution(op);
        if (contribution > params.maxContribution) revert ContributionExceedsMax(contribution, params.maxContribution);

        op.minCollateral = params.minCollateral;
        op.maxCollateral = params.maxCollateral;
    }

    function _execute(Operation memory op, uint256 maxEntryLtv)
        private
        returns (uint256 obligation, uint256 fundingAmount, uint256 collateral)
    {
        uint256 contribution = _contribution(op);
        if (contribution != 0) IERC20(usdc).safeTransferFrom(msg.sender, address(this), contribution);

        uint256 flashAssets = op.borrowAssets + op.marginAssets;
        if (flashAssets == 0) {
            collateral = _run(op);
        } else {
            bytes32 id = keccak256(abi.encode(op.market));
            uint256 collateralBefore = _positionCollateral(id, op.user);

            bytes memory data = abi.encode(op);
            _operation = keccak256(data);
            IMorphoBlue(morpho).flashLoan(usdc, flashAssets, data);
            if (_operation != bytes32(0)) revert CallbackNotExecuted();

            uint256 collateralAfter = op.borrowAssets != 0
                ? _checkEntryLtv(op.market, id, op.user, maxEntryLtv)
                : _positionCollateral(id, op.user);
            collateral = collateralAfter - collateralBefore;
        }
        return (op.obligation, op.fundingAmount, collateral);
    }

    /// @dev USDC pulled from the caller: the funding amount less the borrowed and margin-sourced parts.
    function _contribution(Operation memory op) private pure returns (uint256) {
        return op.fundingAmount - op.borrowAssets - op.marginAssets;
    }

    /// @dev `user`'s collateral in market `id` as Morpho records it.
    function _positionCollateral(bytes32 id, address user) private view returns (uint256 collateral) {
        (,, collateral) = IMorphoBlue(morpho).position(id, user);
    }

    /// @dev Pays the vault from the helper's USDC (the caller's contribution plus any flash-loaned `borrowAssets` and
    /// `marginAssets`), which also releases margin to the caller; measures the USD3l delivered to the caller, requires
    /// at least `minCollateral`, and supplies up to `maxCollateral` of it as the caller's collateral (any excess stays
    /// in the caller's wallet); then withdraws `marginAssets` of USDC from the caller's margin-asset shares to the
    /// helper, burning no more than `maxMarginShares` and no more than the shares released in this entry; then borrows
    /// `borrowAssets` for the caller to the helper. Returns the collateral supplied.
    function _run(Operation memory op) private returns (uint256 supplied) {
        IERC20 collateralToken = IERC20(usd3l);
        uint256 balanceBefore = collateralToken.balanceOf(op.user);
        uint256 marginBefore = op.marginAssets != 0 ? IERC20(op.marginAsset).balanceOf(op.user) : 0;

        IERC20(usdc).forceApprove(op.vault, op.fundingAmount);
        if (ILCCVault(op.vault).fundCall(op.user) != op.obligation) revert FundingMismatch();
        if (IERC20(usdc).allowance(address(this), op.vault) != 0) revert FundingMismatch();

        uint256 delivered = collateralToken.balanceOf(op.user) - balanceBefore;
        if (delivered < op.minCollateral) revert CollateralBelowMinimum(delivered, op.minCollateral);
        supplied = Math.min(delivered, op.maxCollateral);

        collateralToken.safeTransferFrom(op.user, address(this), supplied);
        IMorphoBlue(morpho).supplyCollateral(op.market, supplied, op.user, "");
        if (op.marginAssets != 0) _withdrawMargin(op, marginBefore);
        if (op.borrowAssets != 0) {
            IMorphoBlue(morpho).borrow(op.market, op.borrowAssets, 0, op.user, address(this));
        }
    }

    /// @dev Withdraws exactly `marginAssets` of USDC to the helper from the caller's margin-asset shares. The shares
    /// burned are measured as the caller's balance change across the withdrawal and must not exceed `maxMarginShares`
    /// or the shares the vault released to the caller in this entry (the balance change across `fundCall`), so a
    /// pre-existing margin-asset balance is never consumed. `marginBefore` is the caller's balance before `fundCall`;
    /// the balance read here, after `fundCall` and before the withdrawal, is both the released end point and the
    /// burn start point.
    function _withdrawMargin(Operation memory op, uint256 marginBefore) private {
        IERC20 marginToken = IERC20(op.marginAsset);
        uint256 marginAfterFunding = marginToken.balanceOf(op.user);
        uint256 released = marginAfterFunding - marginBefore;
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));

        IERC4626(op.marginAsset).withdraw(op.marginAssets, address(this), op.user);

        uint256 burned = marginAfterFunding - marginToken.balanceOf(op.user);
        if (burned > op.maxMarginShares) revert MarginSharesExceedMax(burned, op.maxMarginShares);
        if (burned > released) revert MarginExceedsReleased(burned, released);
        uint256 received = IERC20(usdc).balanceOf(address(this)) - usdcBefore;
        if (received != op.marginAssets) revert MarginReceiptMismatch(received, op.marginAssets);
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
        (, uint128 borrowShares, uint128 collateral) = IMorphoBlue(morpho).position(id, user);
        positionCollateral = collateral;
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorphoBlue(morpho).market(id);
        uint256 borrowed = uint256(borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
        uint256 collateralValue =
            uint256(collateral).mulDivDown(IMorphoBlueOracle(market.oracle).price(), ORACLE_PRICE_SCALE);
        uint256 ltv = collateralValue == 0 ? type(uint256).max : borrowed.wDivUp(collateralValue);
        if (ltv > maxEntryLtv) revert EntryLtvExceeded(ltv, maxEntryLtv);
    }

    /// @dev True when a levered entry still needs the caller's Morpho authorization of this helper.
    function _needsAuthorization(uint256 borrowAssets) private view returns (bool) {
        return borrowAssets != 0 && !IMorphoBlue(morpho).isAuthorized(msg.sender, address(this));
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
        if (!IMorphoBlue(morpho).isAuthorized(msg.sender, address(this))) revert AuthorizationFailed();
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

    /// @dev Returns the vault's margin asset without calling it.
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
