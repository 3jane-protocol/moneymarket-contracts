// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MarkdownManager} from "../../src/MarkdownManager.sol";

contract DeployMarkdownManager is Script {
    function run() external returns (address) {
        vm.startBroadcast();

        MarkdownManager markdownManager = new MarkdownManager();

        console.log("MarkdownManager deployed at:", address(markdownManager));

        vm.stopBroadcast();

        return address(markdownManager);
    }
}
