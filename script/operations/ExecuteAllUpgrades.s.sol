// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import "../../src/usd3/interfaces/IUSD3.sol";

/**
 * @title ExecuteAllUpgrades
 * @notice Execute all v1.1 upgrades as atomic batch via Safe multisig
 * @dev ⚠️ CRITICAL: Wraps Timelock.executeBatch() in Safe batch with USD3 operations
 *
 *      Safe Multisig Batch (7 operations):
 *      1. USD3.setPerformanceFee(0)
 *      2. USD3.setProfitMaxUnlockTime(0)
 *      3. USD3.report() [BEFORE upgrade]
 *      4. Timelock.executeBatch() -> Upgrades all 4 implementations + USD3.reinitialize()
 *      5. USD3.report() [AFTER reinitialize]
 *      6. USD3.syncTrancheShare() [Sets performanceFee to TRANCHE_SHARE_VARIANT]
 *      7. USD3.setProfitMaxUnlockTime(prevUnlockTime)
 *
 *      Prerequisites:
 *      - Safe multisig MUST have management role on USD3
 *      - Safe multisig MUST have keeper role on USD3 (or roles allow any caller)
 *      - Timelock operation MUST be Ready (2 day delay passed)
 *
 *      Execution Flow:
 *      1. Fetch Timelock operation data from events
 *      2. Verify operation is Ready
 *      3. Build Safe batch with USD3 operations + Timelock execution
 *      4. Send to Safe API for multisig approval
 *      5. Once approved, all 8 operations execute atomically
 *
 *      Why This Works:
 *      - Timelock only owns ProxyAdmins, not USD3
 *      - Safe has management/keeper roles on USD3
 *      - Safe batch ensures atomicity of all operations
 *      - First report() finalizes waUSDC state before upgrade
 *      - Timelock upgrades all 4 implementations and calls USD3.reinitialize() atomically
 *      - Second report() updates totalAssets with new USDC values
 *      - Prevents user losses during waUSDC -> USDC migration
 */
contract ExecuteAllUpgrades is Script, SafeHelper, TimelockHelper {
    /// @notice TimelockController address (mainnet)
    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;

    /// @notice USD3 proxy address (mainnet)
    address private constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    /// @notice Main execution function
    /// @param operationId Timelock operation ID from scheduling step
    /// @param previousProfitUnlockTime Previous profit unlock time to restore (seconds)
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(bytes32 operationId, uint256 previousProfitUnlockTime, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
        isTimelock(TIMELOCK)
    {
        console2.log("=== Executing All v1.1 Upgrades via Safe ===");
        console2.log("WARNING: CRITICAL - 7 operations will execute atomically");
        console2.log("WARNING: CRITICAL - All 4 implementations upgrade + USD3.reinitialize() in step 4");
        console2.log("");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("USD3 Proxy:", USD3_PROXY);
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Previous profit unlock time:", previousProfitUnlockTime);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Check Timelock operation state
        console2.log("Checking Timelock operation status...");
        logOperationState(TIMELOCK, operationId);
        console2.log("");

        // Ensure operation is Ready
        requireOperationReady(TIMELOCK, operationId);

        // Fetch Timelock operation data
        console2.log("Fetching Timelock operation data from events...");
        (
            address[] memory timelockTargets,
            uint256[] memory timelockValues,
            bytes[] memory timelockDatas,
            bytes32 predecessor,
            bytes32 salt
        ) = _fetchOperationData(operationId);

        console2.log("Timelock operation fetched:");
        console2.log("  Targets:", timelockTargets.length);
        for (uint256 i = 0; i < timelockTargets.length; i++) {
            console2.log("    Target", i, ":", timelockTargets[i]);
        }
        console2.log("");

        // Verify operation ID
        bytes32 calculatedId =
            calculateBatchOperationId(timelockTargets, timelockValues, timelockDatas, predecessor, salt);
        require(calculatedId == operationId, "Operation ID mismatch");

        // Build Safe batch with 7 operations
        console2.log("=== Building Safe Atomic Batch ===");

        // 1. USD3.setPerformanceFee(0)
        console2.log("1. USD3.setPerformanceFee(0)");
        bytes memory setFeeZeroCall = abi.encodeWithSignature("setPerformanceFee(uint16)", uint16(0));
        addToBatch(USD3_PROXY, setFeeZeroCall);

        // 2. USD3.setProfitMaxUnlockTime(0)
        console2.log("2. USD3.setProfitMaxUnlockTime(0)");
        bytes memory setUnlockZeroCall = abi.encodeWithSignature("setProfitMaxUnlockTime(uint256)", uint256(0));
        addToBatch(USD3_PROXY, setUnlockZeroCall);

        // 3. USD3.report() [BEFORE upgrade]
        console2.log("3. USD3.report() [BEFORE upgrade]");
        bytes memory reportBeforeCall = abi.encodeWithSignature("report()");
        addToBatch(USD3_PROXY, reportBeforeCall);

        // 4. Timelock.executeBatch() -> Upgrades all 4 implementations + USD3.reinitialize()
        console2.log("4. Timelock.executeBatch() -> Upgrades MorphoCredit, IRM, USD3 + reinitialize(), sUSD3");
        bytes memory timelockExecuteCall =
            encodeExecuteBatch(timelockTargets, timelockValues, timelockDatas, predecessor, salt);
        addToBatch(TIMELOCK, timelockExecuteCall);

        // 5. USD3.report() [AFTER reinitialize]
        console2.log("5. USD3.report() [AFTER reinitialize]");
        bytes memory reportAfterCall = abi.encodeWithSignature("report()");
        addToBatch(USD3_PROXY, reportAfterCall);

        // 6. USD3.syncTrancheShare()
        console2.log("6. USD3.syncTrancheShare()");
        bytes memory syncCall = abi.encodeWithSignature("syncTrancheShare()");
        addToBatch(USD3_PROXY, syncCall);

        // 7. USD3.setProfitMaxUnlockTime(previousUnlockTime)
        console2.log("7. USD3.setProfitMaxUnlockTime(", previousProfitUnlockTime, ")");
        bytes memory restoreUnlockCall =
            abi.encodeWithSignature("setProfitMaxUnlockTime(uint256)", previousProfitUnlockTime);
        addToBatch(USD3_PROXY, restoreUnlockCall);

        console2.log("");

        // Execute via Safe
        if (send) {
            console2.log("Sending atomic batch to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Multisig signers must approve the transaction in Safe UI");
            console2.log("2. Once threshold reached, anyone can execute");
            console2.log("3. All 7 operations will execute atomically (all-or-nothing)");
            console2.log("");
            console2.log("CRITICAL: This prevents user losses during waUSDC -> USDC migration");
            console2.log("CRITICAL: All 4 implementations upgrade + USD3.reinitialize() at step 4");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Fetch Timelock operation data from events
    /// @dev Same implementation as ExecuteTimelockViaSafe.s.sol
    function _fetchOperationData(bytes32 operationId)
        private
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory datas,
            bytes32 predecessor,
            bytes32 salt
        )
    {
        // Event signatures
        bytes32 CALL_SCHEDULED_TOPIC = keccak256("CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)");
        bytes32 CALL_SALT_TOPIC = keccak256("CallSalt(bytes32,bytes32)");

        // Search for CallScheduled events
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = CALL_SCHEDULED_TOPIC;
        topics[1] = operationId;

        // Get logs from the last 30 days (approximately)
        uint256 fromBlock = block.number > 216000 ? block.number - 216000 : 0;
        Vm.EthGetLogs[] memory scheduledLogs = vm.eth_getLogs(fromBlock, block.number, TIMELOCK, topics);

        require(scheduledLogs.length > 0, "No CallScheduled events found for this operation ID");

        // Count unique indices
        uint256 maxIndex = 0;
        for (uint256 i = 0; i < scheduledLogs.length; i++) {
            uint256 index = uint256(scheduledLogs[i].topics[2]);
            if (index > maxIndex) {
                maxIndex = index;
            }
        }

        // Initialize arrays
        uint256 arraySize = maxIndex + 1;
        targets = new address[](arraySize);
        values = new uint256[](arraySize);
        datas = new bytes[](arraySize);

        // Parse CallScheduled events
        for (uint256 i = 0; i < scheduledLogs.length; i++) {
            uint256 index = uint256(scheduledLogs[i].topics[2]);

            // Decode non-indexed parameters
            (address target, uint256 value, bytes memory data, bytes32 pred, uint256 delay) =
                abi.decode(scheduledLogs[i].data, (address, uint256, bytes, bytes32, uint256));

            targets[index] = target;
            values[index] = value;
            datas[index] = data;

            if (i == 0) {
                predecessor = pred;
            } else {
                require(predecessor == pred, "Inconsistent predecessor in batch");
            }
        }

        // Search for CallSalt event
        bytes32[] memory saltTopics = new bytes32[](2);
        saltTopics[0] = CALL_SALT_TOPIC;
        saltTopics[1] = operationId;

        Vm.EthGetLogs[] memory saltLogs = vm.eth_getLogs(fromBlock, block.number, TIMELOCK, saltTopics);

        if (saltLogs.length > 0) {
            salt = abi.decode(saltLogs[0].data, (bytes32));
        } else {
            salt = bytes32(0);
        }

        return (targets, values, datas, predecessor, salt);
    }
}
