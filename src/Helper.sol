// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMorpho, IMorphoCredit, Id, Market, Position} from "./interfaces/IMorpho.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {IHelper} from "./interfaces/IHelper.sol";
import {IUSD3} from "./interfaces/IUSD3.sol";
import {IERC20} from "./interfaces/IERC20.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";

import {IERC4626} from "../lib/forge-std/src/interfaces/IERC4626.sol";

/// @title Helper
/// @author 3Jane
/// @custom:contact support@3jane.xyz
contract Helper is IHelper {
    using SafeTransferLib for IERC20;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    /// @inheritdoc IHelper
    address public immutable MORPHO;
    /// @inheritdoc IHelper
    address public immutable USD3;
    /// @inheritdoc IHelper
    address public immutable sUSD3;
    /// @inheritdoc IHelper
    address public immutable USDC;
    /// @inheritdoc IHelper
    address public immutable WAUSDC;

    /* CONSTRUCTOR */

    constructor(address morpho, address usd3, address susd3, address usdc, address wausdc) {
        if (morpho == address(0)) revert ErrorsLib.ZeroAddress();
        if (usd3 == address(0)) revert ErrorsLib.ZeroAddress();
        if (susd3 == address(0)) revert ErrorsLib.ZeroAddress();
        if (usdc == address(0)) revert ErrorsLib.ZeroAddress();
        if (wausdc == address(0)) revert ErrorsLib.ZeroAddress();

        MORPHO = morpho;
        USD3 = usd3;
        sUSD3 = susd3;
        USDC = usdc;
        WAUSDC = wausdc;

        // Set max approvals
        IERC20(USDC).approve(WAUSDC, type(uint256).max);
        IERC20(WAUSDC).approve(USD3, type(uint256).max);
        IERC20(WAUSDC).approve(MORPHO, type(uint256).max);
        IERC20(USD3).approve(sUSD3, type(uint256).max);
    }

    /// @inheritdoc IHelper
    function deposit(uint256 assets, address receiver, bool hop) external returns (uint256) {
        uint256 waUsdcAmount = _wrap(msg.sender, assets);

        if (hop) {
            require(IUSD3(USD3).whitelist(receiver), "!whitelist");
            assets = IUSD3(USD3).deposit(waUsdcAmount, address(this));
            assets = IERC4626(sUSD3).deposit(assets, receiver);
        } else {
            assets = IUSD3(USD3).deposit(waUsdcAmount, receiver);
        }

        return assets;
    }

    /// @inheritdoc IHelper
    function redeem(uint256 shares, address receiver) external returns (uint256) {
        uint256 waUsdcAssets = IUSD3(USD3).redeem(shares, address(this), msg.sender);
        return IERC4626(WAUSDC).redeem(waUsdcAssets, receiver, address(this));
    }

    /// @inheritdoc IHelper
    function borrow(MarketParams memory marketParams, uint256 assets) external returns (uint256, uint256) {
        uint256 waUsdcShares = IERC4626(WAUSDC).convertToShares(assets);
        (uint256 waUSDCAmount, uint256 shares) =
            IMorpho(MORPHO).borrow(marketParams, waUsdcShares, 0, msg.sender, address(this));
        uint256 usdcAmount = IERC4626(WAUSDC).redeem(waUSDCAmount, msg.sender, address(this));
        return (usdcAmount, shares);
    }

    /// @inheritdoc IHelper
    function repay(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
        returns (uint256, uint256)
    {
        // Check if this is a full repayment request
        if (assets == type(uint256).max) {
            return _repayFull(marketParams, onBehalf, data);
        } else {
            // Normal partial repayment flow
            uint256 waUSDCAmount = _wrap(msg.sender, assets);
            (, uint256 shares) = IMorpho(MORPHO).repay(marketParams, waUSDCAmount, 0, onBehalf, data);
            return (assets, shares);
        }
    }

    function _repayFull(MarketParams memory marketParams, address onBehalf, bytes calldata data)
        internal
        returns (uint256, uint256)
    {
        Id id = marketParams.id();

        // Accrue premium first to get accurate borrow shares
        IMorphoCredit(MORPHO).accrueBorrowerPremium(id, onBehalf);

        // Get current borrow shares after premium accrual
        Position memory pos = IMorpho(MORPHO).position(id, onBehalf);

        // If no debt, return early
        if (pos.borrowShares == 0) {
            return (0, 0);
        }

        // Get market state to calculate assets needed
        Market memory market = IMorpho(MORPHO).market(id);

        // Calculate waUSDC assets needed (rounds up like Morpho does)
        uint256 waUsdcNeeded = uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        // Convert to USDC amount needed (preview how much USDC needed to mint waUsdcNeeded)
        uint256 usdcNeeded = IERC4626(WAUSDC).previewMint(waUsdcNeeded);

        // Pull USDC from user and wrap to waUSDC
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcNeeded);
        IERC4626(WAUSDC).deposit(usdcNeeded, address(this));

        // Repay with shares to ensure complete repayment
        (, uint256 sharesRepaid) = IMorpho(MORPHO).repay(marketParams, 0, pos.borrowShares, onBehalf, data);

        return (usdcNeeded, sharesRepaid);
    }

    function _wrap(address from, uint256 assets) internal returns (uint256) {
        IERC20(USDC).safeTransferFrom(from, address(this), assets);
        return IERC4626(WAUSDC).deposit(assets, address(this));
    }
}
