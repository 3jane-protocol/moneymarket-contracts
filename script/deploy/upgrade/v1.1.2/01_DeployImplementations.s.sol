// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";

/**
 * @title DeployImplementations v1.1.2
 * @notice Deploy new implementations for MorphoCredit, USD3, and sUSD3
 * @dev Changes in v1.1.2:
 *      - PR 98: DEBT_CAP = 0 blocks borrowing, USD3_SUPPLY_CAP = 0 blocks deposits
 *      - PR 99: cooldownDuration = 0 skips cooldown requirement
 *
 *      Usage:
 *      PROTOCOL_CONFIG=0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E \
 *      forge script script/deploy/upgrade/v1.1.2/01_DeployImplementations.s.sol \
 *        --rpc-url mainnet --broadcast --verify
 */
contract DeployImplementations is Script {
    function run() external returns (address morphoCreditImpl, address usd3Impl, address susd3Impl) {
        address protocolConfig = vm.envAddress("PROTOCOL_CONFIG");
        require(protocolConfig != address(0), "PROTOCOL_CONFIG not set");

        console2.log("=== Deploying v1.1.2 Implementations ===");
        console2.log("ProtocolConfig:", protocolConfig);
        console2.log("");

        vm.startBroadcast();

        // Deploy MorphoCredit implementation
        console2.log("Deploying MorphoCredit implementation...");
        MorphoCredit morphoCredit = new MorphoCredit(protocolConfig);
        morphoCreditImpl = address(morphoCredit);
        console2.log("  MorphoCredit:", morphoCreditImpl);

        // Deploy USD3 implementation
        console2.log("Deploying USD3 implementation...");
        USD3 usd3 = new USD3();
        usd3Impl = address(usd3);
        console2.log("  USD3:", usd3Impl);

        // Deploy sUSD3 implementation
        console2.log("Deploying sUSD3 implementation...");
        sUSD3 susd3 = new sUSD3();
        susd3Impl = address(susd3);
        console2.log("  sUSD3:", susd3Impl);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify contracts on Etherscan");
        console2.log("  2. Run 02_ScheduleUpgrades.s.sol with:");
        console2.log("     MORPHO_CREDIT_IMPL=%s \\", morphoCreditImpl);
        console2.log("     USD3_IMPL=%s \\", usd3Impl);
        console2.log("     SUSD3_IMPL=%s", susd3Impl);

        return (morphoCreditImpl, usd3Impl, susd3Impl);
    }
}
