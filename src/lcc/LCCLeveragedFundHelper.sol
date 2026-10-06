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
import {IMorphoBlue, IMorphoBlueOracle, IMorphoBlueSupplyCollateralCallback} from "./interfaces/IMorphoBlue.sol";

/// @title LCCLeveragedFundHelper
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Funds the caller's LCC capital-call obligation with amortizing push funding while borrowing part of it on a
/// caller-chosen market of the pinned canonical Morpho Blue singleton that lends USDC against USD3l, using the USD3l
/// the funding delivers as collateral.
/// @dev The LCC beneficiary and the Morpho `onBehalf` are always msg.sender. The helper supplies the previewed USD3l
/// as collateral first; inside Morpho's collateral callback it borrows, pays the vault through `fundCall(address)`,
/// requires the caller's USD3l balance to grow by exactly the previewed collateral, and hands that USD3l to Morpho.
/// After a levered entry the caller's whole position in that market must be within the caller's LTV bound. The helper
/// holds no factory role, never deposits into USD3 itself, and has no owner, rescue, receiver-choice,
/// delegated-beneficiary, arbitrary-call, or upgrade surface. Its only state is the transient in-flight operation and
/// reentrancy lock.
contract LCCLeveragedFundHelper is
    ILCCLeveragedFundHelper,
    IMorphoBlueSupplyCollateralCallback,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    /// @dev Mirrors the vault's bound on the extra funding asset pulled so a dust obligation mints one USD3 share.
    uint256 internal constant MAX_FUNDING_TOP_UP = 1_000;

    /// @dev Inputs one funding binds; its hash is the in-flight operation the Morpho callback must match.
    struct Operation {
        address user;
        address vault;
        IMorphoBlue.MarketParams market;
        uint256 obligation;
        uint256 fundingAmount;
        uint256 borrowAssets;
        uint256 collateral;
    }

    address public immutable override morpho;
    address public immutable override factory;
    address public immutable override usdc;
    address public immutable override usd3;
    address public immutable override usd3l;

    bytes32 private transient _operation;

    /// @param morpho_ Canonical Morpho Blue singleton.
    /// @param factory_ LCC vault factory whose registered vaults may be funded.
    /// @param usdc_ USDC, the asset of USD3 and the loan token of every market the helper serves.
    /// @param usd3l_ USD3l, the notification vault wrapping USD3 and the collateral token of every market served.
    constructor(address morpho_, address factory_, address usdc_, address usd3l_) {
        if (morpho_.code.length == 0 || factory_.code.length == 0 || usdc_.code.length == 0 || usd3l_.code.length == 0)
        {
            revert InvalidConfiguration();
        }

        address usd3_ = IERC4626(usd3l_).asset();
        if (IERC4626(usd3_).asset() != usdc_) revert InvalidConfiguration();

        morpho = morpho_;
        factory = factory_;
        usdc = usdc_;
        usd3 = usd3_;
        usd3l = usd3l_;
    }

    /// @inheritdoc ILCCLeveragedFundHelper
    function fund(FundParams calldata params)
        external
        nonReentrant
        returns (uint256 obligation, uint256 fundingAmount, uint256 collateral)
    {
        if (_needsAuthorization(params.borrowAssets)) revert NotAuthorized();
        return _execute(_prepare(params), params.maxEntryLtv);
    }

    /// @inheritdoc ILCCLeveragedFundHelper
    /// @dev Both permits are always submitted with msg.sender as owner and this helper as spender, so a permit that
    /// applies replaces the caller's standing allowance to this helper with its `value`. A permit that reverts is
    /// tolerated; the call then reverts with `InsufficientAllowance` unless the resulting allowance covers the need.
    /// The authorization is ignored when
    /// `params.borrowAssets` is zero or the caller has already authorized this helper on Morpho. Otherwise it must name
    /// msg.sender as authorizer, this helper as authorized, and enable it; a submission that reverts is tolerated if
    /// the authorization is then in place. There is no revoking counterpart, so the authorization stays enabled until
    /// the caller revokes it on Morpho.
    function fundWithSignatures(
        FundParams calldata params,
        PermitSignature calldata usdcPermit,
        PermitSignature calldata usd3lPermit,
        IMorphoBlue.Authorization calldata authorization,
        IMorphoBlue.Signature calldata authorizationSignature
    ) external nonReentrant returns (uint256 obligation, uint256 fundingAmount, uint256 collateral) {
        Operation memory op = _prepare(params);

        _applyPermit(usdc, usdcPermit, op.fundingAmount - op.borrowAssets);
        _applyPermit(usd3l, usd3lPermit, op.collateral);
        if (_needsAuthorization(op.borrowAssets)) _applyAuthorization(authorization, authorizationSignature);

        return _execute(op, params.maxEntryLtv);
    }

    /// @inheritdoc IMorphoBlueSupplyCollateralCallback
    /// @dev Accepted only from Morpho while this helper's own `supplyCollateral` call is in flight, and only for the
    /// exact operation recorded for it; the hash binding fixes the collateral amount. The record is cleared before any
    /// external call.
    function onMorphoSupplyCollateral(uint256, bytes calldata data) external override {
        if (msg.sender != morpho) revert NotMorpho();
        bytes32 expected = _operation;
        if (expected == bytes32(0)) revert NoOperationInFlight();
        if (keccak256(data) != expected) revert OperationMismatch();
        _operation = bytes32(0);

        Operation memory op = abi.decode(data, (Operation));

        if (op.borrowAssets != 0) {
            IMorphoBlue(morpho).borrow(op.market, op.borrowAssets, 0, op.user, address(this));
        }

        IERC20 collateralToken = IERC20(usd3l);
        uint256 balanceBefore = collateralToken.balanceOf(op.user);

        IERC20(usdc).forceApprove(op.vault, op.fundingAmount);
        if (ILCCVault(op.vault).fundCall(op.user) != op.obligation) revert FundingMismatch();
        if (IERC20(usdc).allowance(address(this), op.vault) != 0) revert FundingMismatch();

        uint256 minted = collateralToken.balanceOf(op.user) - balanceBefore;
        if (minted != op.collateral) revert CollateralPreviewMismatch(op.collateral, minted);

        collateralToken.safeTransferFrom(op.user, address(this), op.collateral);
        collateralToken.forceApprove(morpho, op.collateral);
    }

    function _prepare(FundParams calldata params) private view returns (Operation memory op) {
        if (block.timestamp > params.deadline) revert DeadlineExpired(); // deliberate wall-clock read
        if (params.market.loanToken != usdc || params.market.collateralToken != usd3l) revert MarketTokenMismatch();
        _validateVault(params.vault);

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
        if (params.borrowAssets > op.fundingAmount) revert BorrowExceedsFunding(params.borrowAssets, op.fundingAmount);
        op.borrowAssets = params.borrowAssets;

        uint256 contribution = op.fundingAmount - op.borrowAssets;
        if (contribution > params.maxContribution) revert ContributionExceedsMax(contribution, params.maxContribution);

        op.collateral = IERC4626(usd3l).previewDeposit(IERC4626(usd3).previewDeposit(op.fundingAmount));
    }

    function _execute(Operation memory op, uint256 maxEntryLtv)
        private
        returns (uint256 obligation, uint256 fundingAmount, uint256 collateral)
    {
        uint256 contribution = op.fundingAmount - op.borrowAssets;
        if (contribution != 0) IERC20(usdc).safeTransferFrom(msg.sender, address(this), contribution);

        bytes memory data = abi.encode(op);
        _operation = keccak256(data);
        IMorphoBlue(morpho).supplyCollateral(op.market, op.collateral, msg.sender, data);
        if (_operation != bytes32(0)) revert CallbackNotExecuted();

        if (op.borrowAssets != 0) _checkEntryLtv(op.market, msg.sender, maxEntryLtv);
        return (op.obligation, op.fundingAmount, op.collateral);
    }

    /// @dev Values the user's whole position in `market` at that market's oracle price, rounding debt up. Runs only
    /// after a nonzero borrow in this transaction: Morpho's `borrow` accrued interest, so the market totals are current
    /// and the borrow shares are nonzero. A zero collateral value (an oracle reading zero) is treated as unbounded LTV.
    function _checkEntryLtv(IMorphoBlue.MarketParams memory market, address user, uint256 maxEntryLtv) private view {
        bytes32 id = keccak256(abi.encode(market));
        (, uint128 borrowShares, uint128 collateral) = IMorphoBlue(morpho).position(id, user);
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
        uint256 allowance = IERC20(token).allowance(msg.sender, address(this));
        if (allowance < required) revert InsufficientAllowance(token, allowance, required, permitRevert);
    }

    function _validateVault(address vault) private view {
        if (!LCCVaultFactory(factory).isVault(vault)) revert UnregisteredVault();
        ILCCVault.AssetConfig memory config = ILCCVault(vault).assetConfig();
        if (config.fundingAsset != usdc || config.usd3 != usd3 || config.notificationVault != usd3l) {
            revert VaultAssetMismatch();
        }
        if (config.marginAsset == usd3l) revert MarginAssetIsCollateral();
    }
}
