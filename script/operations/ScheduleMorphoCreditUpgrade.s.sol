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
 * @title ScheduleMorphoCreditUpgrade
 * @notice Schedule MorphoCredit upgrade through TimelockController via Safe multisig
 * @dev Part of v1.1 upgrade process
 *
 *      Usage:
 *      1. Deploy new MorphoCredit implementation (script 10)
 *      2. Run this script to schedule upgrade
 *      3. Wait 2 days for timelock delay
 *      4. Execute upgrade via ExecuteTimelockViaSafe.s.sol
 */
contract ScheduleMorphoCreditUpgrade is Script, SafeHelper, TimelockHelper {
    /// @notice TimelockController address (mainnet)
    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;

    /// @notice MorphoCredit proxy address (mainnet)
    address private constant MORPHO_CREDIT_PROXY = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;

    /// @notice MorphoCredit ProxyAdmin address (mainnet)
    address private constant PROXY_ADMIN = 0x0b0dA0C2D0e21C43C399c09f830e46E3341fe1D4;

    /// @notice EIP-1967 admin slot
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @notice Main execution function
    /// @param newImplementation Address of the new MorphoCredit implementation
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(address newImplementation, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
        isTimelock(TIMELOCK)
    {
        // Verify ProxyAdmin is correct
        address actualAdmin = getProxyAdmin(MORPHO_CREDIT_PROXY);
        require(actualAdmin == PROXY_ADMIN, "ProxyAdmin mismatch");

        console2.log("=== Scheduling MorphoCredit Upgrade via Safe + Timelock ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("MorphoCredit Proxy:", MORPHO_CREDIT_PROXY);
        console2.log("ProxyAdmin:", PROXY_ADMIN);
        console2.log("New implementation:", newImplementation);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Validate inputs
        require(newImplementation != address(0), "New implementation cannot be zero address");
        uint256 delay = getMinDelay(TIMELOCK);
        console2.log("Timelock delay:", delay / 1 days, "days");

        // Prepare the upgrade operation
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory datas = new bytes[](1);

        targets[0] = PROXY_ADMIN;
        values[0] = 0;
        datas[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(MORPHO_CREDIT_PROXY), newImplementation, "")
        );

        // Generate salt and predecessor
        bytes32 salt = generateSalt("MorphoCredit v1.1 Upgrade");
        bytes32 predecessor = bytes32(0);

        // Calculate operation ID
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("Salt:", vm.toString(salt));
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
    }

    /// @notice Retrieve the ProxyAdmin address from a proxy contract
    function getProxyAdmin(address proxyContract) internal view returns (address) {
        bytes32 adminSlot = vm.load(proxyContract, ADMIN_SLOT);
        return address(uint160(uint256(adminSlot)));
    }

    /// @notice Dry run example
    function dryRun() external {
        address newImpl = vm.envAddress("MORPHO_CREDIT_NEW_IMPL");
        this.run(newImpl, false);
    }
}
