// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IMorpho, IMorphoCredit, Id, Market, MarketParams} from "../../src/interfaces/IMorpho.sol";
import {IAdaptiveCurveIrm} from "../../src/irm/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol";
import {MathLib as MorphoMathLib} from "../../src/libraries/MathLib.sol";
import {ExpLib} from "../../src/irm/adaptive-curve-irm/libraries/ExpLib.sol";

contract GetIrmDetails is Script {
    using MorphoMathLib for uint128;

    uint256 constant WAD = 1e18;
    int256 constant WAD_INT = int256(WAD);
    uint256 constant SECONDS_PER_YEAR = 365.25 days;

    // Mainnet addresses
    address constant MORPHO_CREDIT = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address constant ADAPTIVE_CURVE_IRM = 0x1d434D2899f81F3C3fdf52C814A6E23318f9C7Df;

    // Market ID for USDC market
    Id constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    function run() public {
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

        // Calculate utilization
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
        console2.log("  Utilization: %d bps", (utilization * 10000) / WAD);
        console2.log("");
        console2.log("Interest Rates:");
        console2.log("  Current Borrow Rate (WAD): %d", currentBorrowRate);
        console2.log("  Current Borrow APR: %d bps", (currentAPR * 10000) / WAD);
        console2.log("");
        console2.log("  Rate at Target (WAD): %d", rateAtTarget);
        console2.log("  Rate at Target APR: %d bps", (targetAPR * 10000) / WAD);
        console2.log("");
        console2.log("  Last Update: %d", market.lastUpdate);
        console2.log("  Fee: %d bps", market.fee / 1e14);
    }

    function _toAPR(uint256 ratePerSecond) internal pure returns (uint256) {
        // Convert from per-second rate to annual rate using continuous compounding
        // APR = e^(rate * secondsPerYear) - 1
        int256 annualRate = int256(ratePerSecond * SECONDS_PER_YEAR);
        int256 expResult = ExpLib.wExp(annualRate);
        // expResult is e^(annualRate) in WAD, so subtract WAD to get the APR
        return uint256(expResult - WAD_INT);
    }
}
