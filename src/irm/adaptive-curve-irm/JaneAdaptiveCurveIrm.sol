// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IAaveMarket, ReserveDataLegacy} from "./interfaces/IAaveMarket.sol";

import {AdaptiveCurveIrm} from "./AdaptiveCurveIrm.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ConstantsLib} from "./libraries/ConstantsLib.sol";
import {MarketParamsLib} from "../../libraries/MarketParamsLib.sol";
import {Id, Market, MarketParams, IMorpho} from "../../interfaces/IMorpho.sol";

/// @title JaneAdaptiveCurveIrm
/// @author Morpho Labs
/// @custom:contact security@morpho.org
contract JaneAdaptiveCurveIrm is AdaptiveCurveIrm {
    using MarketParamsLib for MarketParams;

    address public immutable AAVE_MARKET;

    mapping(Id => int256) public baseAtTarget;

    constructor(address morpho, address aaveMarket) AdaptiveCurveIrm(morpho) {
        require(aaveMarket != address(0), ErrorsLib.ZERO_ADDRESS);
        AAVE_MARKET = aaveMarket;
    }

    function borrowRate(MarketParams memory marketParams, Market memory market) public override returns (uint256) {
        Id id = marketParams.id();

        address underlying = IMorpho(MORPHO).idToMarketParams(id).collateralToken;

        ReserveDataLegacy memory reserveData = IAaveMarket(AAVE_MARKET).getReserveData(underlying);

        int256 aaveBorrowRateBase = int128((reserveData.currentVariableBorrowRate / 1e9)) / int128(365 days);
        int256 aaveBorrowRateAtTarget = aaveBorrowRateBase * (ConstantsLib.CURVE_STEEPNESS / 1e18);

        rateAtTarget[id] = rateAtTarget[id] + aaveBorrowRateAtTarget - baseAtTarget[id];
        baseAtTarget[id] = aaveBorrowRateAtTarget;

        return super.borrowRate(marketParams, market);
    }
}
