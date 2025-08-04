// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMorpho} from "./interfaces/IMorpho.sol";
import {IUSD3} from "./interfaces/IUSD3.sol";
import {IWrap} from "./interfaces/IWrap.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {IHelper} from "./interfaces/IHelper.sol";

import {IERC4626} from "../lib/forge-std/src/interfaces/IERC4626.sol";

import {IERC20} from "./interfaces/IERC20.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

/// @title Helper
/// @author Morpho Labs
/// @custom:contact security@morpho.org
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
        IERC20(WAUSDC).approve(USD3, type(uint256).max);
        IERC20(WAUSDC).approve(MORPHO, type(uint256).max);
        IERC20(USD3).approve(sUSD3, type(uint256).max);
    }

    /// @inheritdoc IHelper
    function deposit(uint256 assets, address receiver, bool hop) external returns (uint256) {
        assets = IUSD3(USD3).deposit(_wrap(msg.sender, assets), receiver);
        if (hop) {
            assets = IUSD3(sUSD3).deposit(assets, receiver);
        }
        return assets;
    }

    /// @inheritdoc IHelper
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        IERC20(USD3).safeTransferFrom(msg.sender, address(this), shares);

        uint256 assets = IUSD3(USD3).redeem(shares, address(this), owner);
        return _unwrap(receiver, assets);
    }

    /// @inheritdoc IHelper
    function borrow(MarketParams memory marketParams, uint256 assets) external returns (uint256, uint256) {
        (uint256 waUSDCAmount, uint256 shares) =
            IMorpho(MORPHO).borrow(marketParams, assets, 0, msg.sender, address(this));
        _unwrap(msg.sender, waUSDCAmount);
        return (waUSDCAmount, shares);
    }

    /// @inheritdoc IHelper
    function repay(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
        returns (uint256, uint256)
    {
        (uint256 waUSDCAmount, uint256 shares) =
            IMorpho(MORPHO).repay(marketParams, _wrap(msg.sender, assets), 0, onBehalf, data);
        return (waUSDCAmount, shares);
    }

    function _wrap(address from, uint256 assets) internal returns (uint256) {
        IERC20(USDC).safeTransferFrom(from, address(this), assets);
        return IWrap(WAUSDC).deposit(assets, address(this));
    }

    function _unwrap(address receiver, uint256 assets) internal returns (uint256) {
        uint256 shares = IWrap(WAUSDC).withdraw(assets, address(this), address(this));
        IERC20(USDC).safeTransfer(receiver, shares);
        return shares;
    }
}
