// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMorpho} from "./interfaces/IMorpho.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {IHelper} from "./interfaces/IHelper.sol";
import {IUSD3} from "./interfaces/IUSD3.sol";
import {IERC20} from "./interfaces/IERC20.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

import {IERC4626} from "../lib/forge-std/src/interfaces/IERC4626.sol";

/// @title Helper
/// @author 3Jane
/// @custom:contact support@3jane.xyz
contract Helper is IHelper {
    using SafeTransferLib for IERC20;

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
        IERC20(USDC).approve(USD3, type(uint256).max);
        IERC20(WAUSDC).approve(MORPHO, type(uint256).max);
        IERC20(USD3).approve(sUSD3, type(uint256).max);
    }

    /// @inheritdoc IHelper
    function deposit(uint256 assets, address receiver, bool hop) external returns (uint256) {
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), assets);

        if (hop) {
            // Check if receiver is allowed to deposit this amount to USD3
            // This is needed for hop because USD3.deposit checks address(this), not receiver
            require(IUSD3(USD3).availableDepositLimit(receiver) >= assets, "Deposit exceeds limit");

            assets = IUSD3(USD3).deposit(assets, address(this));
            assets = IERC4626(sUSD3).deposit(assets, receiver);
        } else {
            assets = IUSD3(USD3).deposit(assets, receiver);
        }

        return assets;
    }

    /// @inheritdoc IHelper
    function redeem(uint256 shares, address receiver) external returns (uint256) {
        // USD3 now returns USDC directly after reinitialize()
        uint256 usdcAssets = IUSD3(USD3).redeem(shares, receiver, msg.sender);
        return usdcAssets;
    }

    /// @inheritdoc IHelper
    function borrow(MarketParams memory marketParams, uint256 assets) external returns (uint256, uint256) {
        (uint256 waUSDCAmount, uint256 shares) =
            IMorpho(MORPHO).borrow(marketParams, assets, 0, msg.sender, address(this));
        uint256 usdcAmount = IERC4626(WAUSDC).redeem(waUSDCAmount, msg.sender, address(this));
        return (usdcAmount, shares);
    }

    /// @inheritdoc IHelper
    function repay(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
        returns (uint256, uint256)
    {
        uint256 waUSDCAmount = _wrap(msg.sender, assets);
        (, uint256 shares) = IMorpho(MORPHO).repay(marketParams, waUSDCAmount, 0, onBehalf, data);
        return (assets, shares);
    }

    function _wrap(address from, uint256 assets) internal returns (uint256) {
        IERC20(USDC).safeTransferFrom(from, address(this), assets);
        return IERC4626(WAUSDC).deposit(assets, address(this));
    }
}
