// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {IMorpho, IMorphoCredit} from "../../src/interfaces/IMorpho.sol";
import {IIrm} from "../../src/interfaces/IIrm.sol";
import {IProtocolConfig, IRMConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {MarketParams, Market, Id} from "../../src/interfaces/IMorpho.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";
import {IAaveMarket, ReserveDataLegacy} from "../../src/irm/adaptive-curve-irm/interfaces/IAaveMarket.sol";

/**
 * @title GetCurrentRate
 * @notice Query current interest rate, utilization, and IRM parameters for a MorphoCredit market
 * @dev Displays both APR (nominal) and APY (effective with continuous compounding)
 */
contract GetCurrentRate is Script {
    using MathLib for uint256;

    uint256 constant WAD = 1e18;

    function run() external view {
        console2.log("block number: %d", block.number);

        address morphoAddress = vm.envAddress("MORPHO_ADDRESS");
        bytes32 marketIdBytes = vm.envBytes32("MARKET_ID");

        IMorpho morpho = IMorpho(morphoAddress);
        IMorphoCredit morphoCredit = IMorphoCredit(morphoAddress);
        Id marketId = Id.wrap(marketIdBytes);

        // Get market params and state
        MarketParams memory params = morpho.idToMarketParams(marketId);
        Market memory marketState = morpho.market(marketId);

        // Calculate utilization
        uint256 utilization = marketState.totalSupplyAssets > 0
            ? (uint256(marketState.totalBorrowAssets) * WAD) / uint256(marketState.totalSupplyAssets)
            : 0;

        // Get IRM config from ProtocolConfig
        address protocolConfig = morphoCredit.protocolConfig();
        IRMConfig memory irmConfig = IProtocolConfig(protocolConfig).getIRMConfig();

        // Get borrow rate
        uint256 ratePerSecond = IIrm(params.irm).borrowRateView(params, marketState);

        // Calculate APR (nominal rate) and APY (effective rate with continuous compounding)
        uint256 apr = ratePerSecond * 365 days;
        uint256 apy = ratePerSecond.wTaylorCompounded(365 days);

        // Get Aave USDC supply rate
        // AAVE_POOL and USDC are public immutables but not in IAdaptiveCurveIrm interface
        // So we read them from environment or use mainnet defaults
        address aavePool = vm.envOr("AAVE_POOL", address(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2)); // Aave V3 Pool
            // mainnet
        address usdc = vm.envOr("USDC_ADDRESS", address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)); // USDC mainnet
        ReserveDataLegacy memory reserveData = IAaveMarket(aavePool).getReserveData(usdc);

        // Aave's rates are already APRs in RAY (1e27)
        // Convert from RAY to WAD for APR
        uint256 aaveSupplyAPR = uint256(reserveData.currentLiquidityRate) / 1e9;
        uint256 aaveBorrowAPR = uint256(reserveData.currentVariableBorrowRate) / 1e9;

        // Convert APR to per-second rate, then calculate APY
        uint256 aaveSupplyRatePerSecond = aaveSupplyAPR / 365 days;
        uint256 aaveSupplyAPY = aaveSupplyRatePerSecond.wTaylorCompounded(365 days);

        uint256 aaveBorrowRatePerSecond = aaveBorrowAPR / 365 days;
        uint256 aaveBorrowAPY = aaveBorrowRatePerSecond.wTaylorCompounded(365 days);

        // Calculate full USDC cost (MorphoCredit rate + Aave supply rate)
        uint256 fullUsdcAPR = apr + aaveSupplyAPR;
        uint256 fullUsdcAPY = apy + aaveSupplyAPY;

        // Display results
        console2.log("=== MorphoCredit Market Interest Rate Info ===");
        console2.log("");
        console2.log("Market ID:", vm.toString(marketIdBytes));
        console2.log("IRM Address:", params.irm);
        console2.log("ProtocolConfig:", protocolConfig);
        console2.log("");

        console2.log("=== Market State ===");
        console2.log("Total Supply Assets:", marketState.totalSupplyAssets);
        console2.log("Total Borrow Assets:", marketState.totalBorrowAssets);
        console2.log("Last Update:", marketState.lastUpdate);
        console2.log("");

        console2.log("=== Utilization ===");
        console2.log("Current Utilization: %e %%", (utilization * 100) / WAD);
        console2.log("Target Utilization (Kink): %e %%", (irmConfig.targetUtilization * 100) / WAD);
        if (utilization > irmConfig.targetUtilization) {
            console2.log("Status: ABOVE TARGET (paying higher rates)");
        } else if (utilization < irmConfig.targetUtilization) {
            console2.log("Status: BELOW TARGET (paying lower rates)");
        } else {
            console2.log("Status: AT TARGET");
        }
        console2.log("");

        console2.log("=== MorphoCredit waUSDC Borrow Rate ===");
        console2.log("Borrow Rate (per second): %d", ratePerSecond);
        console2.log("Borrow APR (nominal): %d bps", (apr * 10000) / WAD);
        console2.log("Borrow APY (actual with continuous compounding): %d bps", (apy * 10000) / WAD);
        console2.log("");

        console2.log("=== Aave USDC Rates ===");
        console2.log("Aave Supply APR (waUSDC appreciation): %d bps", (aaveSupplyAPR * 10000) / WAD);
        console2.log("Aave Supply APY: %d bps", (aaveSupplyAPY * 10000) / WAD);
        console2.log("");
        console2.log("Aave Borrow APR: %d bps", (aaveBorrowAPR * 10000) / WAD);
        console2.log("Aave Borrow APY: %d bps", (aaveBorrowAPY * 10000) / WAD);
        console2.log("");
        uint256 aaveSpreadAPR = aaveBorrowAPR > aaveSupplyAPR ? aaveBorrowAPR - aaveSupplyAPR : 0;
        console2.log("Aave Spread (borrow - supply): %d bps", (aaveSpreadAPR * 10000) / WAD);
        console2.log("");

        console2.log("=== Full USDC Cost (MorphoCredit + Aave) ===");
        console2.log("Full USDC APR: %d bps", (fullUsdcAPR * 10000) / WAD);
        console2.log("Full USDC APY: %d bps", (fullUsdcAPY * 10000) / WAD);
        console2.log("(This is what borrowing waUSDC costs in raw USDC terms)");
        console2.log("");

        console2.log("=== IRM Configuration (Adaptive Curve) ===");
        console2.log("Curve Steepness: %e", irmConfig.curveSteepness);
        console2.log("Adjustment Speed: %e", irmConfig.adjustmentSpeed);
        console2.log("Target Utilization: %e %%", (irmConfig.targetUtilization * 100) / WAD);
        console2.log("Initial Rate at Target: %e", irmConfig.initialRateAtTarget);
        console2.log("Min Rate at Target: %e", irmConfig.minRateAtTarget);
        console2.log("Max Rate at Target: %e", irmConfig.maxRateAtTarget);
    }
}
