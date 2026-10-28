// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";
import {
    ITransparentUpgradeableProxy,
    ProxyAdmin
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title ExecuteUSD3v113Upgrade
/// @notice Execute the previously scheduled USD3 v1.1.3 ProxyAdmin upgrade once the timelock delay has elapsed.
/// @dev Mirrors the operation built by ScheduleUSD3v113Upgrade and submits Timelock.executeBatch via Safe.
///      Also exposes view-only checkStatus() and verify() helpers.
contract ExecuteUSD3v113Upgrade is Script, SafeHelper, TimelockHelper {
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address constant PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _buildOperation(address newImpl)
        internal
        pure
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory datas,
            bytes32 salt,
            bytes32 predecessor
        )
    {
        targets = new address[](1);
        values = new uint256[](1);
        datas = new bytes[](1);

        targets[0] = PROXY_ADMIN;
        values[0] = 0;
        datas[0] = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(USD3_PROXY), newImpl, abi.encodeWithSignature("restartStrategy()"))
        );

        salt = generateSalt("USD3 v1.1.3 Restart Strategy Upgrade");
        predecessor = bytes32(0);
    }

    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        address newImpl = vm.envAddress("USD3_IMPL");
        require(newImpl != address(0), "USD3_IMPL not set");

        console2.log("=== Execute USD3 v1.1.3 Upgrade via Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("USD3 proxy:", USD3_PROXY);
        console2.log("New USD3 impl:", newImpl);
        console2.log("Send to Safe:", send);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newImpl);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(TIMELOCK, operationId);
        console2.log("");

        requireOperationReady(TIMELOCK, operationId);

        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, salt);

        console2.log("Adding executeBatch call to Safe transaction...");
        addToBatch(TIMELOCK, executeCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed, USD3 proxy will:");
            console2.log("  - point at impl: %s", newImpl);
            console2.log("  - have isShutdown() == false");
            console2.log("");
            console2.log("Run --sig \"verify()\" to confirm post-execution state.");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Check status of the upgrade operation
    function checkStatus() external view {
        address newImpl = vm.envAddress("USD3_IMPL");
        require(newImpl != address(0), "USD3_IMPL not set");

        console2.log("=== USD3 v1.1.3 Upgrade Operation Status ===");
        console2.log("New USD3 impl:", newImpl);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newImpl);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(TIMELOCK, operationId);
    }

    /// @notice Verify the upgrade was applied correctly
    function verify() external view {
        address expectedImpl = vm.envAddress("USD3_IMPL");
        require(expectedImpl != address(0), "USD3_IMPL not set");

        console2.log("=== Verifying USD3 v1.1.3 Upgrade ===");
        console2.log("Expected impl:", expectedImpl);
        console2.log("");

        address currentImpl = address(uint160(uint256(vm.load(USD3_PROXY, IMPLEMENTATION_SLOT))));
        console2.log("USD3 proxy implementation slot:", currentImpl);

        (bool ok, bytes memory data) = USD3_PROXY.staticcall(abi.encodeWithSignature("isShutdown()"));
        require(ok, "Failed to read USD3.isShutdown()");
        bool shutdown = abi.decode(data, (bool));
        console2.log("USD3 isShutdown():", shutdown);

        console2.log("");
        bool implOk = currentImpl == expectedImpl;
        bool restartOk = !shutdown;
        if (implOk && restartOk) {
            console2.log("PASS: implementation upgraded and strategy restarted");
        } else {
            if (!implOk) {
                console2.log("FAIL: implementation slot does not match expected impl");
            }
            if (!restartOk) {
                console2.log("FAIL: strategy is still shutdown");
            }
        }
    }

    function run() external {
        this.run(false);
    }
}
