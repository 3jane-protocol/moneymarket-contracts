// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {ITimelockController} from "../../../../src/interfaces/ITimelockController.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {USD3v12UpgradeBase} from "./USD3v12UpgradeBase.s.sol";

/**
 * @title ScheduleUSD3v12Upgrade
 * @notice Schedule the USD3 v1.2 ProxyAdmin upgrade through the 7-day timelock via Safe multisig.
 * @dev The operation calls ProxyAdmin.upgradeAndCall with empty data. v1.2 appends state into the storage gap and
 *      requires no reinitializer.
 *
 *      Usage:
 *      FOUNDRY_PROFILE=script USD3_IMPL=<address> SEVEN_DAY_TIMELOCK=<address> WALLET_TYPE=local \
 *        SAFE_PROPOSER_PRIVATE_KEY=<private-key> forge script \
 *        script/deploy/upgrade/v1.2/05_ScheduleUSD3v12Upgrade.s.sol \
 *        --sig "run(bool)" false --rpc-url mainnet
 *      Use WALLET_TYPE=account with SAFE_PROPOSER_ACCOUNT, or WALLET_TYPE=ledger with MNEMONIC_INDEX, instead.
 */
contract ScheduleUSD3v12Upgrade is Script, SafeHelper, USD3v12UpgradeBase {
    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(_sevenDayTimelock()) {
        address sevenDayTimelock = timelock;
        address newImpl = _usd3Impl();

        address actualAdmin = address(uint160(uint256(vm.load(USD3_PROXY, ADMIN_SLOT))));
        require(actualAdmin == PROXY_ADMIN, "ProxyAdmin mismatch");

        bytes32 proposerRole = ITimelockController(sevenDayTimelock).PROPOSER_ROLE();
        (bool roleReadOk, bytes memory roleData) =
            sevenDayTimelock.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", proposerRole, SAFE_ADDRESS));
        require(
            roleReadOk && roleData.length == 32 && abi.decode(roleData, (bool)), "Safe is not a 7-day timelock proposer"
        );

        console2.log("=== Schedule USD3 v1.2 Upgrade via 7-Day Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("7-day timelock:", sevenDayTimelock);
        console2.log("USD3 proxy:", USD3_PROXY);
        console2.log("ProxyAdmin:", PROXY_ADMIN);
        console2.log("New USD3 impl:", newImpl);
        console2.log("Send to Safe:", send);
        console2.log("");

        uint256 minDelay = getMinDelay(sevenDayTimelock);
        console2.log("Timelock minimum delay (seconds):", minDelay);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newImpl);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation details:");
        console2.log("  Target[0] (ProxyAdmin.upgradeAndCall):", targets[0]);
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Operation ID:", vm.toString(operationId));
        console2.log("");

        if (isOperation(sevenDayTimelock, operationId)) {
            logOperationState(sevenDayTimelock, operationId);
            console2.log("");
            console2.log("Operation already exists. Use 06_ExecuteUSD3v12Upgrade.s.sol to execute.");
            return;
        }

        simulateExecution(sevenDayTimelock, targets, values, datas);
        console2.log("");

        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(sevenDayTimelock, scheduleCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("=== Save These Values for Execution ===");
            console2.log("Operation ID: %s", vm.toString(operationId));
            console2.log("Salt: %s", vm.toString(salt));
            console2.log("Ready at (unix):", block.timestamp + minDelay);
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Safe signers approve and execute the schedule transaction");
            console2.log("2. Wait 7 days after scheduling");
            console2.log("3. Run 06_ExecuteUSD3v12Upgrade.s.sol with:");
            console2.log("   USD3_IMPL=%s", newImpl);
            console2.log("   SEVEN_DAY_TIMELOCK=%s", sevenDayTimelock);
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
            console2.log("Operation ID would be: %s", vm.toString(operationId));
        }
    }

    function run() external {
        this.run(false);
    }
}
