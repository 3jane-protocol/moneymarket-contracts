// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {ITimelockController} from "../../src/interfaces/ITimelockController.sol";
import {
    ITransparentUpgradeableProxy,
    ProxyAdmin
} from "../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title ScheduleUSD3AtomicBatch
 * @notice Schedule USD3 upgrade as atomic batch through TimelockController via Safe multisig
 * @dev ⚠️ CRITICAL: All 8 operations MUST execute atomically to prevent user losses
 *
 *      Batch Order:
 *      1. setPerformanceFee(0)
 *      2. setProfitMaxUnlockTime(0)
 *      3. report() - before upgrade
 *      4. ProxyAdmin.upgrade()
 *      5. reinitialize()
 *      6. report() - after reinitialize
 *      7. syncTrancheShare()
 *      8. Restore fee settings
 *
 *      Usage:
 *      1. Deploy new USD3 implementation (script 12)
 *      2. Save current performanceFee and profitMaxUnlockTime values
 *      3. Run this script to schedule atomic batch
 *      4. Wait 2 days for timelock delay
 *      5. Execute batch via ExecuteTimelockViaSafe.s.sol
 */
contract ScheduleUSD3AtomicBatch is Script, SafeHelper, TimelockHelper {
    /// @notice TimelockController address (mainnet)
    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;

    /// @notice USD3 proxy address (mainnet)
    address private constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    /// @notice USD3 ProxyAdmin address (mainnet)
    address private constant PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;

    /// @notice EIP-1967 admin slot
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @notice Main execution function
    /// @param newImplementation Address of the new USD3 implementation
    /// @param previousPerformanceFee Previous performance fee to restore (step 8)
    /// @param previousProfitUnlockTime Previous profit unlock time to restore (step 8)
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(address newImplementation, uint16 previousPerformanceFee, uint256 previousProfitUnlockTime, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
        isTimelock(TIMELOCK)
    {
        // Verify ProxyAdmin is correct
        address actualAdmin = getProxyAdmin(USD3_PROXY);
        require(actualAdmin == PROXY_ADMIN, "ProxyAdmin mismatch");

        console2.log("=== Scheduling USD3 Atomic Batch via Safe + Timelock ===");
        console2.log("WARNING: CRITICAL - 8 operations will execute atomically");
        console2.log("");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("USD3 Proxy:", USD3_PROXY);
        console2.log("ProxyAdmin:", PROXY_ADMIN);
        console2.log("New implementation:", newImplementation);
        console2.log("Previous performance fee:", previousPerformanceFee);
        console2.log("Previous profit unlock time:", previousProfitUnlockTime);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Validate inputs
        require(newImplementation != address(0), "New implementation cannot be zero address");
        uint256 delay = getMinDelay(TIMELOCK);
        console2.log("Timelock delay:", delay / 1 days, "days");
        console2.log("");

        // Prepare all 8 operations
        address[] memory targets = new address[](8);
        uint256[] memory values = new uint256[](8);
        bytes[] memory datas = new bytes[](8);

        // Operation 1: setPerformanceFee(0)
        targets[0] = USD3_PROXY;
        values[0] = 0;
        datas[0] = abi.encodeWithSignature("setPerformanceFee(uint16)", uint16(0));

        // Operation 2: setProfitMaxUnlockTime(0)
        targets[1] = USD3_PROXY;
        values[1] = 0;
        datas[1] = abi.encodeWithSignature("setProfitMaxUnlockTime(uint256)", uint256(0));

        // Operation 3: report() - BEFORE upgrade
        targets[2] = USD3_PROXY;
        values[2] = 0;
        datas[2] = abi.encodeWithSignature("report()");

        // Operation 4: ProxyAdmin.upgrade()
        targets[3] = PROXY_ADMIN;
        values[3] = 0;
        datas[3] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(USD3_PROXY), newImplementation, "")
        );

        // Operation 5: reinitialize()
        targets[4] = USD3_PROXY;
        values[4] = 0;
        datas[4] = abi.encodeWithSignature("reinitialize()");

        // Operation 6: report() - AFTER reinitialize
        targets[5] = USD3_PROXY;
        values[5] = 0;
        datas[5] = abi.encodeWithSignature("report()");

        // Operation 7: syncTrancheShare()
        targets[6] = USD3_PROXY;
        values[6] = 0;
        datas[6] = abi.encodeWithSignature("syncTrancheShare()");

        // Operation 8a: Restore setPerformanceFee
        targets[7] = USD3_PROXY;
        values[7] = 0;
        datas[7] = abi.encodeWithSignature("setPerformanceFee(uint16)", previousPerformanceFee);

        // Note: We can only include 8 operations, so profitMaxUnlockTime restore
        // will need to be a separate transaction after this batch executes

        // Generate salt and predecessor
        bytes32 salt = generateSalt("USD3 v1.1 Atomic Batch Upgrade");
        bytes32 predecessor = bytes32(0);

        // Calculate operation ID
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Salt:", vm.toString(salt));
        console2.log("");

        // Log all operations
        console2.log("=== Atomic Batch Operations ===");
        console2.log("1. setPerformanceFee(0)");
        console2.log("2. setProfitMaxUnlockTime(0)");
        console2.log("3. report() [BEFORE upgrade]");
        console2.log("4. ProxyAdmin.upgrade()");
        console2.log("5. reinitialize()");
        console2.log("6. report() [AFTER reinitialize]");
        console2.log("7. syncTrancheShare()");
        console2.log("8. setPerformanceFee(", previousPerformanceFee, ")");
        console2.log("");
        console2.log("NOTE: setProfitMaxUnlockTime restore must be done separately");
        console2.log("    Run after batch executes:");
        console2.log("    cast send", USD3_PROXY);
        console2.log("      \"setProfitMaxUnlockTime(uint256)\"", previousProfitUnlockTime);
        console2.log("");

        // Check if operation already exists
        if (isOperation(TIMELOCK, operationId)) {
            console2.log("[WARNING] Operation already exists!");
            logOperationState(TIMELOCK, operationId);
            revert("Operation already scheduled");
        }

        // Encode the scheduleBatch call
        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, delay);

        // Add to Safe batch
        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(TIMELOCK, scheduleCalldata);

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }

        console2.log("");
        console2.log("=== IMPORTANT: Save this information ===");
        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Ready for execution at:", block.timestamp + delay);
        console2.log("Execution timestamp (unix):", block.timestamp + delay);
        console2.log("");
        console2.log("To execute after delay:");
        console2.log("  yarn script:forge script/operations/ExecuteTimelockViaSafe.s.sol \\");
        console2.log("    --sig \"run(bytes32,bool)\" \\");
        console2.log("    ", vm.toString(operationId), "false");
        console2.log("");
        console2.log("WARNING: CRITICAL - All 8 operations execute atomically");
        console2.log("WARNING: CRITICAL - Prevents user losses during waUSDC -> USDC migration");
    }

    /// @notice Retrieve the ProxyAdmin address from a proxy contract
    function getProxyAdmin(address proxyContract) internal view returns (address) {
        bytes32 adminSlot = vm.load(proxyContract, ADMIN_SLOT);
        return address(uint160(uint256(adminSlot)));
    }

    /// @notice Dry run example
    function dryRun() external {
        address newImpl = vm.envAddress("USD3_NEW_IMPL");
        uint16 prevFee = uint16(vm.envUint("USD3_PREV_PERFORMANCE_FEE"));
        uint256 prevUnlock = vm.envUint("USD3_PREV_PROFIT_UNLOCK_TIME");
        this.run(newImpl, prevFee, prevUnlock, false);
    }
}
