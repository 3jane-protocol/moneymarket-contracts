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
 * @title ScheduleUSD3Upgrade
 * @notice Schedule USD3 ProxyAdmin upgrade through TimelockController via Safe multisig
 * @dev ⚠️ CRITICAL: This schedules ONLY the ProxyAdmin.upgradeAndCall() operation
 *
 *      Scheduled Operation:
 *      - ProxyAdmin.upgradeAndCall(USD3_PROXY, newImplementation, "")
 *
 *      Note: Timelock only owns ProxyAdmin, not USD3 itself. USD3 management functions
 *      (setPerformanceFee, report, etc.) are called by Safe multisig at execution time.
 *
 *      Usage:
 *      1. Deploy new USD3 implementation (script 12)
 *      2. Run this script to schedule ProxyAdmin upgrade
 *      3. Wait 2 days for timelock delay
 *      4. Execute full atomic batch via ExecuteUSD3AtomicBatch.s.sol
 *
 *      The execution script will wrap Timelock.executeBatch() in a Safe batch with:
 *      1. setPerformanceFee(0)
 *      2. setProfitMaxUnlockTime(0)
 *      3. report() [BEFORE upgrade]
 *      4. Timelock.executeBatch() -> ProxyAdmin.upgradeAndCall()
 *      5. reinitialize()
 *      6. report() [AFTER upgrade]
 *      7. syncTrancheShare()
 *      8. Restore fee settings
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
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(address newImplementation, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
        isTimelock(TIMELOCK)
    {
        // Verify ProxyAdmin is correct
        address actualAdmin = getProxyAdmin(USD3_PROXY);
        require(actualAdmin == PROXY_ADMIN, "ProxyAdmin mismatch");

        console2.log("=== Scheduling USD3 ProxyAdmin Upgrade via Safe + Timelock ===");
        console2.log("");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("USD3 Proxy:", USD3_PROXY);
        console2.log("ProxyAdmin:", PROXY_ADMIN);
        console2.log("New implementation:", newImplementation);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Validate inputs
        require(newImplementation != address(0), "New implementation cannot be zero address");
        uint256 delay = getMinDelay(TIMELOCK);
        console2.log("Timelock delay:", delay / 1 days, "days");
        console2.log("");

        // Prepare single operation: ProxyAdmin.upgradeAndCall()
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        // Schedule ProxyAdmin upgrade with reinitialize
        // Note: USD3 management functions will be called by Safe at execution time
        targets[0] = PROXY_ADMIN;
        values[0] = 0;
        datas[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(USD3_PROXY), newImplementation, abi.encodeWithSignature("reinitialize()"))
        );

        // Generate salt and predecessor
        bytes32 salt = generateSalt("USD3 v1.1 ProxyAdmin Upgrade");
        bytes32 predecessor = bytes32(0);

        // Calculate operation ID
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Salt:", vm.toString(salt));
        console2.log("");

        // Log scheduled operation
        console2.log("=== Scheduled Operation ===");
        console2.log("ProxyAdmin.upgradeAndCall(USD3_PROXY, newImplementation, \"\")");
        console2.log("");
        console2.log("IMPORTANT: Timelock only schedules the ProxyAdmin upgrade.");
        console2.log("USD3 management functions will be executed by Safe at execution time.");
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
        console2.log("NEXT STEP: Execute atomic batch after delay");
        console2.log("  Use ExecuteUSD3AtomicBatch.s.sol to execute the full atomic upgrade");
        console2.log("  This will wrap the Timelock execution in a Safe batch with USD3 operations");
        console2.log("");
        console2.log("  yarn script:forge script/operations/ExecuteUSD3AtomicBatch.s.sol \\");
        console2.log("    --sig \"run(bytes32,uint256,bool)\" \\");
        console2.log("    ", vm.toString(operationId), "<prevUnlockTime> false");
        console2.log("");
        console2.log("WARNING: CRITICAL - All 7 operations execute atomically via Safe");
        console2.log("WARNING: CRITICAL - Prevents user losses during waUSDC -> USDC migration");
    }

    /// @notice Retrieve the ProxyAdmin address from a proxy contract
    function getProxyAdmin(address proxyContract) internal view returns (address) {
        bytes32 adminSlot = vm.load(proxyContract, ADMIN_SLOT);
        return address(uint160(uint256(adminSlot)));
    }

    /// @notice Dry run example
    function dryRun() external {
        address newImpl = vm.envAddress("USD3_IMPL");
        this.run(newImpl, false);
    }
}
