// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMorpho, IMorphoCredit} from "./interfaces/IMorpho.sol";
import {IAaveMarket, IAaveToken} from "./interfaces/IAaveMarket.sol";
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
    address public aaveMarket;

    /// @inheritdoc IHelper
    address public morpho;

    /* CONSTRUCTOR */

    constructor(address newMorpho, address newAaveMarket) {
        if (newMorpho == address(0)) revert ErrorsLib.ZeroAddress();
        if (newAaveMarket == address(0)) revert ErrorsLib.ZeroAddress();
        morpho = newMorpho;
        aaveMarket = newAaveMarket;
    }

    /// @inheritdoc IHelper
    function deposit(IERC4626 vault, uint256 assets, address receiver) external returns (uint256) {
        address vaultAsset = vault.asset();
        address underlying = IAaveToken(vaultAsset).UNDERLYING_ASSET_ADDRESS();

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), assets);

        IERC20(underlying).approve(aaveMarket, assets);

        IAaveMarket(aaveMarket).supply(underlying, assets, address(this), 0);

        IERC20(vaultAsset).approve(address(vault), assets);

        uint256 shares = vault.deposit(assets, receiver);

        return shares;
    }

    /// @inheritdoc IHelper
    function redeem(IERC4626 vault, uint256 shares, address receiver, address owner) external returns (uint256) {
        address vaultAsset = vault.asset();

        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), shares);

        uint256 assets = vault.redeem(shares, address(this), owner);

        IAaveMarket(aaveMarket).withdraw(IAaveToken(vaultAsset).UNDERLYING_ASSET_ADDRESS(), assets, receiver);

        return assets;
    }

    /// @inheritdoc IHelper
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        IMorpho _morpho = IMorpho(morpho);

        if (msg.sender != onBehalf && !_morpho.isAuthorized(onBehalf, msg.sender)) revert ErrorsLib.Unauthorized();

        if (!_morpho.isAuthorized(onBehalf, address(this))) IMorphoCredit(morpho).setAuthorizationV2(onBehalf, true);

        (assets, shares) = _morpho.borrow(marketParams, assets, shares, onBehalf, address(this));

        IAaveMarket(aaveMarket).withdraw(marketParams.collateralToken, assets, receiver);

        return (assets, shares);
    }

    /// @inheritdoc IHelper
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        address collateralToken = marketParams.collateralToken;

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), assets);

        IERC20(collateralToken).approve(aaveMarket, assets);

        IAaveMarket(aaveMarket).supply(collateralToken, assets, address(this), 0);

        IERC20(marketParams.loanToken).approve(morpho, assets);

        (assets, shares) = IMorpho(morpho).repay(marketParams, assets, shares, onBehalf, data);

        return (assets, shares);
    }
}
