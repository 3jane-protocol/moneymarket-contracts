// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";
import {
    ITransparentUpgradeableProxy,
    ProxyAdmin
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title ScheduleUSD3SUSD3v114Upgrades
/// @notice Schedule the USD3 and sUSD3 v1.1.4 ProxyAdmin upgrades through TimelockController via Safe.
/// @dev The scheduled batch contains two calls:
///      ProxyAdmin.upgradeAndCall(USD3_PROXY, USD3_IMPL, "")
///      ProxyAdmin.upgradeAndCall(SUSD3_PROXY, SUSD3_IMPL, "")
contract ScheduleUSD3SUSD3v114Upgrades is Script, SafeHelper, TimelockHelper {
    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address constant SUSD3_PROXY = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;
    address constant USD3_PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;
    address constant SUSD3_PROXY_ADMIN = 0xecda55c32966B00592Ed3922E386063e1Bc752c2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    uint256 constant EXPECTED_TIMELOCK_DELAY = 24 hours;

    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _buildOperation(address usd3Impl, address susd3Impl)
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
        targets = new address[](2);
        values = new uint256[](2);
        datas = new bytes[](2);

        targets[0] = USD3_PROXY_ADMIN;
        values[0] = 0;
        datas[0] = abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(USD3_PROXY), usd3Impl, ""));

        targets[1] = SUSD3_PROXY_ADMIN;
        values[1] = 0;
        datas[1] = abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(SUSD3_PROXY), susd3Impl, ""));

        salt = keccak256(abi.encodePacked("USD3+sUSD3 v1.1.4 Upgrade: ", usd3Impl, susd3Impl));
        predecessor = bytes32(0);
    }

    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        address usd3Impl = vm.envAddress("USD3_IMPL");
        address susd3Impl = vm.envAddress("SUSD3_IMPL");
        require(usd3Impl != address(0), "USD3_IMPL not set");
        require(susd3Impl != address(0), "SUSD3_IMPL not set");
        require(usd3Impl.code.length > 0, "USD3_IMPL has no code");
        require(susd3Impl.code.length > 0, "SUSD3_IMPL has no code");

        address actualUsd3Admin = address(uint160(uint256(vm.load(USD3_PROXY, ADMIN_SLOT))));
        address actualSusd3Admin = address(uint160(uint256(vm.load(SUSD3_PROXY, ADMIN_SLOT))));
        require(actualUsd3Admin == USD3_PROXY_ADMIN, "USD3 ProxyAdmin mismatch");
        require(actualSusd3Admin == SUSD3_PROXY_ADMIN, "sUSD3 ProxyAdmin mismatch");

        console2.log("=== Schedule USD3 + sUSD3 v1.1.4 Upgrade via Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("USD3 proxy:", USD3_PROXY);
        console2.log("sUSD3 proxy:", SUSD3_PROXY);
        console2.log("USD3 ProxyAdmin:", USD3_PROXY_ADMIN);
        console2.log("sUSD3 ProxyAdmin:", SUSD3_PROXY_ADMIN);
        console2.log("New USD3 impl:", usd3Impl);
        console2.log("New sUSD3 impl:", susd3Impl);
        console2.log("Send to Safe:", send);
        console2.log("");

        uint256 minDelay = getMinDelay(TIMELOCK);
        console2.log("Timelock minimum delay (seconds):", minDelay);
        require(minDelay == EXPECTED_TIMELOCK_DELAY, "Timelock delay is not 24 hours");
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(usd3Impl, susd3Impl);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation details:");
        console2.log("  Target[0] (USD3 ProxyAdmin.upgradeAndCall):", targets[0]);
        console2.log("  Target[1] (sUSD3 ProxyAdmin.upgradeAndCall):", targets[1]);
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Operation ID:", vm.toString(operationId));
        console2.log("");

        if (isOperation(TIMELOCK, operationId)) {
            logOperationState(TIMELOCK, operationId);
            console2.log("");
            console2.log("Operation already exists. Use ExecuteTimelockViaSafe.s.sol to execute when ready.");
            return;
        }

        simulateExecution(TIMELOCK, targets, values, datas);
        console2.log("");

        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(TIMELOCK, scheduleCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("=== Save these values for execution ===");
            console2.log("Operation ID: %s", vm.toString(operationId));
            console2.log("Salt: %s", vm.toString(salt));
            console2.log("Ready at (unix):", block.timestamp + minDelay);
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Safe signers approve and execute the schedule transaction");
            console2.log("2. Wait %d seconds after scheduling", minDelay);
            console2.log("3. Execute with script/operations/ExecuteTimelockViaSafe.s.sol");
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
