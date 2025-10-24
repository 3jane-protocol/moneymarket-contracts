// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract DeployTimelock is Script {
    function run() external returns (address) {
        // Configuration
        uint256 minDelay = vm.envOr("TIMELOCK_DELAY", uint256(300)); // 5 minutes for testnet
        address multisig = vm.envAddress("MULTISIG_ADDRESS");

        // Setup roles
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;

        address[] memory executors = new address[](1);
        executors[0] = multisig;

        vm.startBroadcast();

        TimelockController timelock = new TimelockController(
            minDelay,
            proposers,
            executors,
            multisig // admin (can cancel)
        );

        console.log("TimelockController deployed at:", address(timelock));
        console.log("Min delay:", minDelay / 60, "minutes");
        console.log("Proposer:", multisig);
        console.log("Executor: Anyone (0x0)");
        console.log("Admin:", multisig);

        vm.stopBroadcast();

        return address(timelock);
    }
}
