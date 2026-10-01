// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IMorpho, IMorphoCredit, Id, Market, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {IAdaptiveCurveIrm} from "../../src/irm/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol";
import {MathLib as MorphoMathLib} from "../../src/libraries/MathLib.sol";
import {ExpLib} from "../../src/irm/adaptive-curve-irm/libraries/ExpLib.sol";
import {MathLib, WAD_INT as WAD} from "../../src/irm/adaptive-curve-irm/libraries/MathLib.sol";

contract GetIrmDetailsComparison is Script {
    using MorphoMathLib for uint128;
    using MathLib for int256;

    uint256 constant WAD_UINT = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365.25 days;

    // Mainnet addresses
    address constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address constant ADAPTIVE_CURVE_IRM = 0x1d434D2899f81F3C3fdf52C814A6E23318f9C7Df;

    // Market ID for USDC market
    Id constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    function run() public view {
        IMorpho morpho = IMorpho(MORPHO_CREDIT);
        IAdaptiveCurveIrm irm = IAdaptiveCurveIrm(ADAPTIVE_CURVE_IRM);

        // Get market params
        MarketParams memory marketParams = morpho.idToMarketParams(MARKET_ID);

        // Get market state
        Market memory market = morpho.market(MARKET_ID);

        // Get current borrow rate
        uint256 currentBorrowRate = irm.borrowRateView(marketParams, market);

        // Get rate at target utilization
        int256 rateAtTargetInt = irm.rateAtTarget(MARKET_ID);
        uint256 rateAtTarget = uint256(rateAtTargetInt);

        // Calculate current utilization
        uint256 utilization =
            market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0;

        // Convert rates to APR using exact exponential calculation
        uint256 currentAPR = _toAPR(currentBorrowRate);
        uint256 targetAPR = _toAPR(rateAtTarget);

        console2.log("=== IRM Details for USDC Market ===");
        console2.log("");
        console2.log("Market ID: %s", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("");
        console2.log("Current State:");
        console2.log("  Total Supply Assets: %d", market.totalSupplyAssets);
        console2.log("  Total Borrow Assets: %d", market.totalBorrowAssets);
        console2.log("  Utilization: %d bps", (utilization * 10000) / WAD_UINT);
        console2.log("");
        console2.log("Current Parameters:");
        console2.log("  Rate at Target (WAD): %d", rateAtTarget);
        console2.log("  Rate at Target APR: %d bps", (targetAPR * 10000) / WAD_UINT);
        console2.log("  Target Utilization: 90%%");
        console2.log("  Current Curve Steepness: 1");
        console2.log("");
        console2.log("Current Rates:");
        console2.log("  Borrow Rate (WAD): %d", currentBorrowRate);
        console2.log("  Borrow APR: %d bps", (currentAPR * 10000) / WAD_UINT);
        console2.log("");

        // Show rate curve comparison at different steepness values
        console2.log("=== Rate Curve Comparison (APR in bps) ===");
        console2.log("");

        uint256[7] memory utilizationPoints = [
            uint256(0), // 0%
            25 * WAD_UINT / 100, // 25%
            50 * WAD_UINT / 100, // 50%
            75 * WAD_UINT / 100, // 75%
            90 * WAD_UINT / 100, // 90% (target)
            95 * WAD_UINT / 100, // 95%
            99 * WAD_UINT / 100 // 99%
        ];

        string[7] memory utilLabels = ["  0%", " 25%", " 50%", " 75%", " 90%", " 95%", " 99%"];

        for (uint256 i = 0; i < utilizationPoints.length; i++) {
            uint256 util = utilizationPoints[i];

            // Calculate rates for different steepness values
            uint256 rate1 = _calculateRate(rateAtTargetInt, int256(util), 1e18, 90 * int256(WAD_UINT) / 100);
            uint256 rate2 = _calculateRate(rateAtTargetInt, int256(util), 1.25e18, 90 * int256(WAD_UINT) / 100);
            uint256 rate3 = _calculateRate(rateAtTargetInt, int256(util), 1.5e18, 90 * int256(WAD_UINT) / 100);
            uint256 rate4 = _calculateRate(rateAtTargetInt, int256(util), 2e18, 90 * int256(WAD_UINT) / 100);

            // Convert to APR
            uint256 apr1 = _toAPR(rate1);
            uint256 apr2 = _toAPR(rate2);
            uint256 apr3 = _toAPR(rate3);
            uint256 apr4 = _toAPR(rate4);

            // Log each row
            console2.log("Utilization: %s", utilLabels[i]);
            console2.log("  Steepness=1: %d bps", (apr1 * 10000) / WAD_UINT);
            console2.log("  Steepness=1.25: %d bps", (apr2 * 10000) / WAD_UINT);
            console2.log("  Steepness=1.50: %d bps", (apr3 * 10000) / WAD_UINT);
            console2.log("  Steepness=2: %d bps", (apr4 * 10000) / WAD_UINT);
            console2.log("");
        }
    }

    function _calculateRate(int256 _rateAtTarget, int256 utilization, int256 curveSteepness, int256 targetUtilization)
        internal
        pure
        returns (uint256)
    {
        int256 errNormFactor = utilization > targetUtilization ? WAD - targetUtilization : targetUtilization;
        int256 err = (utilization - targetUtilization).wDivToZero(errNormFactor);

        // Apply curve formula
        int256 coeff = err < 0 ? WAD - WAD.wDivToZero(curveSteepness) : curveSteepness - WAD;
        int256 rate = (coeff.wMulToZero(err) + WAD).wMulToZero(_rateAtTarget);

        return uint256(rate);
    }

    function _toAPR(uint256 ratePerSecond) internal pure returns (uint256) {
        // Convert from per-second rate to annual rate using continuous compounding
        // APR = e^(rate * secondsPerYear) - 1
        int256 annualRate = int256(ratePerSecond * SECONDS_PER_YEAR);
        int256 expResult = ExpLib.wExp(annualRate);
        // expResult is e^(annualRate) in WAD, so subtract WAD to get the APR
        return uint256(expResult - WAD);
    }
}
