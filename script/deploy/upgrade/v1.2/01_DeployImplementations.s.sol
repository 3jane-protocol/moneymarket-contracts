// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";

/**
 * @title DeployImplementations v1.2
 * @notice Deploy the new USD3 implementation for the v1.2 release.
 * @dev Usage:
 *      forge script script/deploy/upgrade/v1.2/01_DeployImplementations.s.sol \
 *        --rpc-url mainnet --broadcast --verify
 */
contract DeployImplementations is Script {
    function run() external returns (address usd3Impl) {
        console2.log("=== Deploying v1.2 Implementations ===");
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
        console2.log("  1. Verify the contract on Etherscan");
        console2.log("  2. Run 05_ScheduleUSD3v12Upgrade.s.sol with:");
        console2.log("     USD3_IMPL=%s", usd3Impl);

        return usd3Impl;
    }
}
