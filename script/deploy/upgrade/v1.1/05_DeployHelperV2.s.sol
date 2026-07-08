// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Helper} from "../../../../src/Helper.sol";

/**
 * @title DeployHelperV2
 * @notice Deploy new Helper contract for v1.1 upgrade
 * @dev New features:
 *      - Direct USDC support (no waUSDC wrapping required)
 *      - Referral tracking via deposit() and borrow() with bytes32 referralCode
 */
contract DeployHelperV2 is Script {
    function run() external returns (address) {
        // Check if already deployed
        address existing = _loadAddress("helperV2");
        if (existing != address(0)) {
            console.log("HelperV2 already deployed at:", existing);
            return existing;
        }

        // Load addresses from environment variables
        address morpho = vm.envAddress("MORPHO_ADDRESS");
        address usd3 = vm.envAddress("USD3_ADDRESS");
        address susd3 = vm.envAddress("SUSD3_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address wausdc = vm.envAddress("WAUSDC_ADDRESS");

        console.log("Deploying HelperV2 with direct USDC support...");
        console.log("  MORPHO:", morpho);
        console.log("  USD3:", usd3);
        console.log("  sUSD3:", susd3);
        console.log("  USDC:", usdc);
        console.log("  WAUSDC:", wausdc);

        vm.startBroadcast();

        Helper helperV2 = new Helper(morpho, usd3, susd3, usdc, wausdc);

        console.log("HelperV2 deployed at:", address(helperV2));
        console.log("Note: Update MorphoCredit.setHelper() in Phase 3");

        vm.stopBroadcast();

        return address(helperV2);
    }

    function _loadAddress(string memory key) internal view returns (address) {
        string memory chainId = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("deployments/", chainId, "/latest.json");
        try vm.readFile(deploymentsPath) returns (string memory json) {
            try vm.parseJsonAddress(json, string.concat(".", key)) returns (address addr) {
                return addr;
            } catch {
                return address(0);
            }
        } catch {
            return address(0);
        }
    }
}
