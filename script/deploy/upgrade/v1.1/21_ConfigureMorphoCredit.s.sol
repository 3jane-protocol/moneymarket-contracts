// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IMorphoCredit} from "../../../../src/interfaces/IMorpho.sol";

/**
 * @title ConfigureMorphoCredit
 * @notice Configure MorphoCredit for v1.1 upgrade
 * @dev Updates Helper reference to new HelperV2 with direct USDC support
 */
contract ConfigureMorphoCredit is Script {
    function run() external {
        // Load addresses
        address morphoCredit = vm.envAddress("MORPHO_ADDRESS");
        address helperV2 = vm.envAddress("HELPER_V2_ADDRESS");

        console.log("Configuring MorphoCredit...");
        console.log("  MorphoCredit:", morphoCredit);
        console.log("  New Helper (V2):", helperV2);

        IMorphoCredit morpho = IMorphoCredit(morphoCredit);

        vm.startBroadcast();

        // Update helper reference
        morpho.setHelper(helperV2);
        console.log("  Updated Helper to V2");
        console.log("  V2 features: direct USDC support, referral tracking");

        console.log("MorphoCredit configuration complete");

        vm.stopBroadcast();
    }
}
