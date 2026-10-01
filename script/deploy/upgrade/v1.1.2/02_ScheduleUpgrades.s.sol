// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";

interface IProxyAdmin {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external payable;
}

/**
 * @title ScheduleUpgrades v1.1.2
 * @notice Schedule MorphoCredit, USD3, and sUSD3 upgrades via Timelock in a single batch
 * @dev This script:
 *      1. Encodes 3 ProxyAdmin.upgradeAndCall() calls
 *      2. Wraps in single Timelock.scheduleBatch()
 *      3. Submits to Safe for proposer signatures
 *
 *      Usage:
 *      MORPHO_CREDIT_IMPL=<addr> USD3_IMPL=<addr> SUSD3_IMPL=<addr> \
 *      forge script script/deploy/upgrade/v1.1.2/02_ScheduleUpgrades.s.sol \
 *        --rpc-url mainnet -s "run(bool)" true
 */
contract ScheduleUpgrades is Script, SafeHelper, TimelockHelper {
    // Mainnet addresses (from Notion deployment doc)
    address constant MORPHO_CREDIT_PROXY = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    address constant MORPHO_CREDIT_PROXY_ADMIN = 0x0b0dA0C2D0e21C43C399c09f830e46E3341fe1D4;

    address constant USD3_PROXY = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address constant USD3_PROXY_ADMIN = 0x41C838664a9C64905537fF410333B9f5964cC596;

    address constant SUSD3_PROXY = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;
    address constant SUSD3_PROXY_ADMIN = 0xecda55c32966B00592Ed3922E386063e1Bc752c2;

    address constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address constant SAFE_ADDRESS = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(TIMELOCK) {
        // Get implementation addresses from environment
        address morphoCreditImpl = vm.envAddress("MORPHO_CREDIT_IMPL");
        address usd3Impl = vm.envAddress("USD3_IMPL");
        address susd3Impl = vm.envAddress("SUSD3_IMPL");

        require(morphoCreditImpl != address(0), "MORPHO_CREDIT_IMPL not set");
        require(usd3Impl != address(0), "USD3_IMPL not set");
        require(susd3Impl != address(0), "SUSD3_IMPL not set");

        console2.log("=== Schedule v1.1.2 Upgrades via Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("Timelock address:", TIMELOCK);
        console2.log("");
        console2.log("Implementations:");
        console2.log("  MorphoCredit:", morphoCreditImpl);
        console2.log("  USD3:", usd3Impl);
        console2.log("  sUSD3:", susd3Impl);
        console2.log("");
        console2.log("Send to Safe:", send);
        console2.log("");

        // Get minimum delay from timelock
        uint256 minDelay = getMinDelay(TIMELOCK);
        console2.log("Timelock minimum delay:", minDelay, "seconds (%d hours)", minDelay / 3600);
        console2.log("");

        // Build batched upgrade operation (3 calls)
        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _buildUpgradeOperation(morphoCreditImpl, usd3Impl, susd3Impl);

        bytes32 predecessor = bytes32(0);

        // Calculate operation ID for reference
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation details:");
        console2.log("  Targets: %d", targets.length);
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Operation ID:", vm.toString(operationId));
        console2.log("");

        // Check if operation already exists
        if (isOperation(TIMELOCK, operationId)) {
            logOperationState(TIMELOCK, operationId);
            console2.log("");
            console2.log("Operation already exists. Use 03_ExecuteUpgrades.s.sol to execute.");
            return;
        }

        // Simulate execution to verify calls will succeed
        simulateExecution(TIMELOCK, targets, values, datas);
        console2.log("");

        // Encode the schedule call
        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

        // Add to Safe batch
        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(TIMELOCK, scheduleCalldata);

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("=== IMPORTANT: Save these values for execution ===");
            console2.log("Operation ID: %s", vm.toString(operationId));
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Wait for Safe signers to approve and execute the schedule transaction");
            console2.log("2. Wait %d seconds (%d hours) after scheduling", minDelay, minDelay / 3600);
            console2.log("3. Run 03_ExecuteUpgrades.s.sol with same implementation addresses");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
            console2.log("Operation ID would be: %s", vm.toString(operationId));
        }
    }

    function checkStatus() external {
        address morphoCreditImpl = vm.envAddress("MORPHO_CREDIT_IMPL");
        address usd3Impl = vm.envAddress("USD3_IMPL");
        address susd3Impl = vm.envAddress("SUSD3_IMPL");

        require(morphoCreditImpl != address(0), "MORPHO_CREDIT_IMPL not set");
        require(usd3Impl != address(0), "USD3_IMPL not set");
        require(susd3Impl != address(0), "SUSD3_IMPL not set");

        console2.log("=== Checking v1.1.2 Upgrade Status ===");
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _buildUpgradeOperation(morphoCreditImpl, usd3Impl, susd3Impl);

        bytes32 predecessor = bytes32(0);
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(TIMELOCK, operationId);

        uint256 minDelay = getMinDelay(TIMELOCK);
        console2.log("");
        console2.log("Current timelock delay:", minDelay, "seconds (%d hours)", minDelay / 3600);
    }

    function _buildUpgradeOperation(address morphoCreditImpl, address usd3Impl, address susd3Impl)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt)
    {
        targets = new address[](3);
        values = new uint256[](3);
        datas = new bytes[](3);

        // MorphoCredit upgrade
        targets[0] = MORPHO_CREDIT_PROXY_ADMIN;
        values[0] = 0;
        datas[0] = abi.encodeCall(IProxyAdmin.upgradeAndCall, (MORPHO_CREDIT_PROXY, morphoCreditImpl, ""));

        // USD3 upgrade
        targets[1] = USD3_PROXY_ADMIN;
        values[1] = 0;
        datas[1] = abi.encodeCall(IProxyAdmin.upgradeAndCall, (USD3_PROXY, usd3Impl, ""));

        // sUSD3 upgrade
        targets[2] = SUSD3_PROXY_ADMIN;
        values[2] = 0;
        datas[2] = abi.encodeCall(IProxyAdmin.upgradeAndCall, (SUSD3_PROXY, susd3Impl, ""));

        // Generate deterministic salt from implementation addresses
        salt = keccak256(abi.encodePacked("v1.1.2 Upgrade: ", morphoCreditImpl, usd3Impl, susd3Impl));
    }

    function run() external {
        this.run(false);
    }
}
