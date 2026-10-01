// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";

/**
 * @title DeployImplementations v1.1.3
 * @notice Deploy new USD3 implementation for the v1.1.3 upgrade.
 * @dev Changes in v1.1.3:
 *      - Adds USD3.restartStrategy() (reinitializer(3)) to atomically clear the strategy
 *        shutdown flag during ProxyAdmin.upgradeAndCall.
 *
 *      Usage:
 *      forge script script/deploy/upgrade/v1.1.3/01_DeployImplementations.s.sol \
 *        --rpc-url mainnet --broadcast --verify
 */
contract DeployImplementations is Script {
    function run() external returns (address usd3Impl) {
        console2.log("=== Deploying v1.1.3 Implementations ===");
        console2.log("");

        vm.startBroadcast();

        console2.log("Deploying USD3 implementation...");
        USD3 usd3 = new USD3{salt: "3jane"}();
        usd3Impl = address(usd3);
        console2.log("  USD3:", usd3Impl);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify contract on Etherscan");
        console2.log("  2. Run 02_ScheduleUSD3v113Upgrade.s.sol with:");
        console2.log("     USD3_IMPL=%s", usd3Impl);

        return usd3Impl;
    }
}
