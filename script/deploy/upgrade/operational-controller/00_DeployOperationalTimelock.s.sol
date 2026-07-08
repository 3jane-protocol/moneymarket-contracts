// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {TimelockController} from "../../../../lib/openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeployOperationalTimelock
/// @notice Deploy the fast operational timelock that will hold OPERATOR_ROLE on OperationalController.
contract DeployOperationalTimelock is Script {
    address constant SLOW_TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant FAST_SAFE = 0x4444444444Da32a2D5eEc7f56d4889ce79B2bb96;
    address constant DEPLOYER_EOA = 0x1226858E04b9d077258F153275613734421cD06B;
    uint256 constant MIN_DELAY = 24 hours;

    function run() external returns (address) {
        require(SLOW_TIMELOCK.code.length > 0, "slow timelock has no code");
        require(FAST_SAFE.code.length > 0, "fast safe has no code");

        address[] memory proposers = new address[](1);
        proposers[0] = FAST_SAFE;

        address[] memory executors = new address[](2);
        executors[0] = FAST_SAFE;
        executors[1] = DEPLOYER_EOA;

        console2.log("=== Deploying Operational Timelock ===");
        console2.log("Min delay:", MIN_DELAY, "seconds");
        console2.log("Proposer:", FAST_SAFE);
        console2.log("Executor[0]:", FAST_SAFE);
        console2.log("Executor[1]:", DEPLOYER_EOA);
        console2.log("Admin (slow timelock):", SLOW_TIMELOCK);
        console2.log("");

        vm.startBroadcast();

        TimelockController timelock =
            new TimelockController{salt: "3jane"}(MIN_DELAY, proposers, executors, SLOW_TIMELOCK);

        vm.stopBroadcast();

        console2.log("=== Operational Timelock Deployed ===");
        console2.log("Address:", address(timelock));
        console2.log("Note: TimelockController also grants DEFAULT_ADMIN_ROLE to itself.");
        console2.log("      Self-admin revocation is intentionally deferred to a later slow-timelock operation.");
        console2.log("");
        console2.log("Next step:");
        console2.log("Run 01_DeployOperationalController.s.sol with OPERATIONAL_TIMELOCK=%s", address(timelock));

        return address(timelock);
    }
}
