// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IAaveMarket, ReserveDataLegacy} from "./interfaces/IAaveMarket.sol";

import {AdaptiveCurveIrm} from "./AdaptiveCurveIrm.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ConstantsLib} from "./libraries/ConstantsLib.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {Id, Market, IMorpho} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title 3JaneAdaptiveCurveIrm
/// @author Morpho Labs
/// @custom:contact security@morpho.org
contract JaneAdaptiveCurveIrm is AdaptiveCurveIrm {
    address public immutable AAVE_MARKET;

    constructor(address morpho, address aaveMarket) AdaptiveCurveIrm(morpho) {
        require(aaveMarket != address(0), ErrorsLib.ZERO_ADDRESS);
        AAVE_MARKET = aaveMarket;
    }

    function _borrowRate(Id id, Market memory market) internal view override returns (uint256, int256) {
        (uint256 avgRate, int256 endRateAtTarget) = super._borrowRate(id, market);

        address underlying = IMorpho(MORPHO).idToMarketParams(id).collateralToken;

        ReserveDataLegacy memory reserveData = IAaveMarket(AAVE_MARKET).getReserveData(underlying);

        int256 aaveBorrowRateBase = int128((reserveData.currentVariableBorrowRate / 1e9)) / int256(365 days);
        int256 aaveBorrowRateAtTarget = aaveBorrowRateBase * ConstantsLib.CURVE_STEEPNESS / 1e18;

        return (avgRate, endRateAtTarget + aaveBorrowRateAtTarget);
    }
}
