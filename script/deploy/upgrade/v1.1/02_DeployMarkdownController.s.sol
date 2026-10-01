// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MarkdownController} from "../../../../src/MarkdownController.sol";
import {Id} from "../../../../src/interfaces/IMorpho.sol";

/**
 * @title DeployMarkdownController
 * @notice Deploy MarkdownController for v1.1 upgrade
 * @dev Replaces MarkdownManager with new burn mechanics integrated with Jane token
 */
contract DeployMarkdownController is Script {
    function run() external returns (address) {
        // Check if already deployed
        address existing = _loadAddress("markdownController");
        if (existing != address(0)) {
            console.log("MarkdownController already deployed at:", existing);
            return existing;
        }

        // Load addresses from environment
        address protocolConfig = vm.envAddress("PROTOCOL_CONFIG");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address jane = vm.envAddress("JANE_ADDRESS");
        address morphoCredit = vm.envAddress("MORPHO_ADDRESS");
        bytes32 marketIdBytes = vm.envBytes32("MARKET_ID");
        Id marketId = Id.wrap(marketIdBytes);

        console.log("Deploying MarkdownController...");
        console.log("  ProtocolConfig:", protocolConfig);
        console.log("  Owner:", owner);
        console.log("  Jane:", jane);
        console.log("  MorphoCredit:", morphoCredit);
        console.log("  Market ID:", vm.toString(marketIdBytes));

        vm.startBroadcast();

        MarkdownController markdownController =
            new MarkdownController(protocolConfig, owner, jane, morphoCredit, marketId);

        console.log("MarkdownController deployed at:", address(markdownController));
        console.log("Note: Will be added as burner to Jane in Phase 3");

        vm.stopBroadcast();

        return address(markdownController);
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
