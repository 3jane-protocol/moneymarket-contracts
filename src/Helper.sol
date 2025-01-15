// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMorpho, IMorphoCredit} from "./interfaces/IMorpho.sol";
import {IAaveMarket} from "./interfaces/IAaveMarket.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {IHelper} from "./interfaces/IHelper.sol";

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
        require(newMorpho != address(0), ErrorsLib.ZERO_ADDRESS);
        require(newAaveMarket != address(0), ErrorsLib.ZERO_ADDRESS);
        morpho = newMorpho;
        aaveMarket = newAaveMarket;
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

        require(msg.sender == onBehalf || _morpho.isAuthorized(onBehalf, msg.sender), ErrorsLib.UNAUTHORIZED);

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
        IERC20 collateralToken = IERC20(marketParams.collateralToken);
        collateralToken.safeTransferFrom(msg.sender, address(this), assets);

        IAaveMarket(aaveMarket).supply(marketParams.collateralToken, assets, address(this), 0);

        collateralToken.approve(morpho, assets);

        (assets, shares) = IMorpho(morpho).repay(marketParams, assets, shares, onBehalf, data);

        return (assets, shares);
    }
}
