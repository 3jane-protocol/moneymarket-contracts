// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../../../utils/SafeHelper.sol";
import {USD3v12UpgradeBase} from "./USD3v12UpgradeBase.s.sol";

/**
 * @title ExecuteUSD3v12Upgrade
 * @notice Execute the scheduled USD3 v1.2 upgrade after the 7-day timelock delay.
 * @dev Rebuilds the operation shared with ScheduleUSD3v12Upgrade and exposes view-only status and verification
 *      helpers.
 *
 *      Usage:
 *      FOUNDRY_PROFILE=script USD3_IMPL=<address> SEVEN_DAY_TIMELOCK=<address> WALLET_TYPE=local \
 *        SAFE_PROPOSER_PRIVATE_KEY=<private-key> forge script \
 *        script/deploy/upgrade/v1.2/06_ExecuteUSD3v12Upgrade.s.sol \
 *        --sig "run(bool)" false --rpc-url mainnet
 *      Use WALLET_TYPE=account with SAFE_PROPOSER_ACCOUNT, or WALLET_TYPE=ledger with MNEMONIC_INDEX, instead.
 */
contract ExecuteUSD3v12Upgrade is Script, SafeHelper, USD3v12UpgradeBase {
    function run(bool send) external isBatch(SAFE_ADDRESS) isTimelock(_sevenDayTimelock()) {
        address sevenDayTimelock = timelock;
        address newImpl = _usd3Impl();

        console2.log("=== Execute USD3 v1.2 Upgrade via 7-Day Timelock ===");
        console2.log("Safe address:", SAFE_ADDRESS);
        console2.log("7-day timelock:", sevenDayTimelock);
        console2.log("USD3 proxy:", USD3_PROXY);
        console2.log("New USD3 impl:", newImpl);
        console2.log("Send to Safe:", send);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newImpl);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");

        logOperationState(sevenDayTimelock, operationId);
        console2.log("");

        requireOperationReady(sevenDayTimelock, operationId);

        bytes memory executeCalldata = encodeExecuteBatch(targets, values, datas, predecessor, salt);

        console2.log("Adding executeBatch call to Safe transaction...");
        addToBatch(sevenDayTimelock, executeCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Next steps:");
            console2.log("  1. Safe signers approve and execute the transaction");
            console2.log("  2. Run --sig \"verify()\" to confirm impl %s and the v1.2 registry getters", newImpl);
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Check the status of the shared USD3 v1.2 timelock operation.
    function checkStatus() external view {
        address sevenDayTimelock = _sevenDayTimelock();
        address newImpl = _usd3Impl();

        console2.log("=== USD3 v1.2 Upgrade Operation Status ===");
        console2.log("7-day timelock:", sevenDayTimelock);
        console2.log("New USD3 impl:", newImpl);
        console2.log("");

        (address[] memory targets, uint256[] memory values, bytes[] memory datas, bytes32 salt, bytes32 predecessor) =
            _buildOperation(newImpl);

        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation ID:", vm.toString(operationId));
        console2.log("");
        logOperationState(sevenDayTimelock, operationId);
    }

    /// @notice Verify the implementation slot and the two v1.2 registry getters.
    function verify() external view {
        address expectedImpl = _usd3Impl();

        console2.log("=== Verifying USD3 v1.2 Upgrade ===");
        console2.log("Expected impl:", expectedImpl);
        console2.log("");

        address currentImpl = address(uint160(uint256(vm.load(USD3_PROXY, IMPLEMENTATION_SLOT))));
        bool implementationOk = currentImpl == expectedImpl;
        console2.log("USD3 proxy implementation slot:", currentImpl);
        console2.log(implementationOk ? "PASS: implementation slot matches" : "FAIL: implementation slot mismatch");

        (bool ringFenceCallOk, bytes memory ringFenceData) =
            USD3_PROXY.staticcall(abi.encodeWithSignature("ringFencedLiquidity()"));
        bool ringFenceGetterOk = ringFenceCallOk && ringFenceData.length == 32;
        if (ringFenceGetterOk) {
            console2.log("USD3 ringFencedLiquidity():", abi.decode(ringFenceData, (uint256)));
            console2.log("PASS: ringFencedLiquidity() exists and returned uint256");
        } else {
            console2.log("FAIL: ringFencedLiquidity() call failed or returned malformed data");
        }

        (bool exemptCallOk, bytes memory exemptData) =
            USD3_PROXY.staticcall(abi.encodeWithSignature("supplyCapExempt(address)", address(0)));
        bool exemptGetterOk = exemptCallOk && exemptData.length == 32;
        bool zeroAddressExempt = exemptGetterOk && abi.decode(exemptData, (bool));
        bool supplyCapOk = exemptGetterOk && !zeroAddressExempt;
        if (exemptGetterOk) console2.log("USD3 supplyCapExempt(address(0)):", zeroAddressExempt);
        console2.log(
            supplyCapOk
                ? "PASS: supplyCapExempt(address(0)) exists and is false"
                : "FAIL: supplyCapExempt(address(0)) missing/true"
        );
    }

    function run() external {
        this.run(false);
    }
}
