// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";

/// @title DeployImplementations v1.1.4
/// @notice Deploy the updated USD3 and sUSD3 implementations for the v1.1.4 upgrade.
/// @dev Changes in v1.1.4:
///      - Updates USD3 deployment-cap behavior for sUSD3 backing constraints.
///      - Adds a nominal sUSD3 backing floor in addition to the ratio-based debt floor.
contract DeployImplementations is Script {
    function run() external returns (address usd3Impl, address susd3Impl) {
        console2.log("=== Deploying v1.1.4 Implementations ===");
        console2.log("");

        vm.startBroadcast();

        console2.log("Deploying USD3 implementation...");
        USD3 usd3 = new USD3{salt: "3jane"}();
        usd3Impl = address(usd3);
        console2.log("  USD3:", usd3Impl);

        console2.log("Deploying sUSD3 implementation...");
        sUSD3 susd3 = new sUSD3{salt: "3jane"}();
        susd3Impl = address(susd3);
        console2.log("  sUSD3:", susd3Impl);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify the contracts on Etherscan");
        console2.log("  2. Run 02_ScheduleUSD3SUSD3v114Upgrades.s.sol with:");
        console2.log("     USD3_IMPL=%s \\", usd3Impl);
        console2.log("     SUSD3_IMPL=%s", susd3Impl);

        return (usd3Impl, susd3Impl);
    }
}
