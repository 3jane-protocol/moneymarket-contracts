// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {TimelockController} from "../../../../lib/openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title DeploySevenDayTimelock
/// @notice Deploy the new self-administered 7-day timelock for slow ProxyAdmin authority.
contract DeploySevenDayTimelock is Script {
    address constant MAIN_MULTISIG = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address constant DEPLOYER_EOA = 0x1226858E04b9d077258F153275613734421cD06B;
    uint256 constant MIN_DELAY = 7 days;

    function run() external returns (address) {
        require(MAIN_MULTISIG.code.length > 0, "main multisig has no code");

        address[] memory proposers = new address[](1);
        proposers[0] = MAIN_MULTISIG;

        address[] memory executors = new address[](2);
        executors[0] = MAIN_MULTISIG;
        executors[1] = DEPLOYER_EOA;

        console2.log("=== Deploying Seven Day Timelock ===");
        console2.log("Min delay:", MIN_DELAY, "seconds");
        console2.log("Proposer:", MAIN_MULTISIG);
        console2.log("Canceller:", MAIN_MULTISIG);
        console2.log("Executor[0]:", MAIN_MULTISIG);
        console2.log("Executor[1]:", DEPLOYER_EOA);
        console2.log("External admin: address(0)");
        console2.log("");

        vm.startBroadcast();

        TimelockController timelock =
            new TimelockController{salt: "3jane-7d"}(MIN_DELAY, proposers, executors, address(0));

        vm.stopBroadcast();

        console2.log("=== Seven Day Timelock Deployed ===");
        console2.log("Address:", address(timelock));
        console2.log("Note: TimelockController grants DEFAULT_ADMIN_ROLE to itself.");
        console2.log("");
        console2.log("Next step:");
        console2.log("Run 01_ScheduleTwoTimelockMigration.s.sol with SEVEN_DAY_TIMELOCK=%s", address(timelock));

        return address(timelock);
    }
}
