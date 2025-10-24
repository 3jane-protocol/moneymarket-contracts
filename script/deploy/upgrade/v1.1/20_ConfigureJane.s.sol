// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Jane} from "../../../../src/jane/Jane.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title ConfigureJane
 * @notice Configure Jane token for v1.1 upgrade
 * @dev Adds MarkdownController as burner and RewardsDistributor as minter
 */
contract ConfigureJane is Script {
    // Role identifiers from Jane.sol
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run() external {
        // Load addresses
        address jane = vm.envAddress("JANE_ADDRESS");
        address markdownController = vm.envAddress("MARKDOWN_CONTROLLER_ADDRESS");
        address rewardsDistributor = vm.envAddress("REWARDS_DISTRIBUTOR_ADDRESS");

        console.log("Configuring Jane token...");
        console.log("  Jane:", jane);
        console.log("  MarkdownController (burner):", markdownController);
        console.log("  RewardsDistributor (minter):", rewardsDistributor);

        Jane janeToken = Jane(jane);

        vm.startBroadcast();

        // Add MarkdownController as burner
        if (!janeToken.hasRole(BURNER_ROLE, markdownController)) {
            janeToken.grantRole(BURNER_ROLE, markdownController);
            console.log("  Granted BURNER_ROLE to MarkdownController");
        } else {
            console.log("  MarkdownController already has BURNER_ROLE");
        }

        // Add RewardsDistributor as minter
        if (!janeToken.hasRole(MINTER_ROLE, rewardsDistributor)) {
            janeToken.grantRole(MINTER_ROLE, rewardsDistributor);
            console.log("  Granted MINTER_ROLE to RewardsDistributor");
        } else {
            console.log("  RewardsDistributor already has MINTER_ROLE");
        }

        // Set MarkdownController reference
        janeToken.setMarkdownController(markdownController);
        console.log("  Set MarkdownController reference");

        console.log("Jane configuration complete");

        vm.stopBroadcast();
    }
}
