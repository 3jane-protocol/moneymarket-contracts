// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {TimelockHelper} from "../../../utils/TimelockHelper.sol";

interface IProxyAdmin {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external payable;
}

/**
 * @title ExecuteUpgrades v1.1.2
 * @notice Execute scheduled MorphoCredit, USD3, and sUSD3 upgrades after timelock delay
 * @dev This script:
 *      1. Reconstructs the batched operation from implementation addresses
 *      2. Verifies operation is ready
 *      3. Executes via Safe multisig
 *
 *      Usage:
 *      MORPHO_CREDIT_IMPL=<addr> USD3_IMPL=<addr> SUSD3_IMPL=<addr> \
 *      forge script script/deploy/upgrade/v1.1.2/03_ExecuteUpgrades.s.sol \
 *        --rpc-url mainnet -s "run(bool)" true
 */
contract ExecuteUpgrades is Script, SafeHelper, TimelockHelper {
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

        console2.log("=== Execute v1.1.2 Upgrades via Timelock ===");
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

        // Rebuild the batched upgrade operation
        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt) =
            _buildUpgradeOperation(morphoCreditImpl, usd3Impl, susd3Impl);

        bytes32 predecessor = bytes32(0);

        // Calculate operation ID
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        // Check operation state
        logOperationState(TIMELOCK, operationId);
        console2.log("");

        // Verify operation is ready
        requireOperationReady(TIMELOCK, operationId);

        // Encode the execute call
        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, salt);

        // Add to Safe batch
        console2.log("Adding executeBatch call to Safe transaction...");
        addToBatch(TIMELOCK, executeCalldata);

        // Execute via Safe
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Once executed, the following will be upgraded:");
            console2.log("  - MorphoCredit: DEBT_CAP = 0 now blocks borrowing");
            console2.log("  - USD3: USD3_SUPPLY_CAP = 0 now blocks deposits");
            console2.log("  - sUSD3: cooldownDuration = 0 skips cooldown");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    function checkStatus() external view {
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

        // Generate deterministic salt from implementation addresses (must match schedule script)
        salt = keccak256(abi.encodePacked("v1.1.2 Upgrade: ", morphoCreditImpl, usd3Impl, susd3Impl));
    }

    function run() external {
        this.run(false);
    }
}
