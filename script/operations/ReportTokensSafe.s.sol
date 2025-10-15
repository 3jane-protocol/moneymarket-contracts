// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {ITokenizedStrategy} from "../../src/interfaces/ITokenizedStrategy.sol";

/// @title ReportTokensSafe Script
/// @notice Calls report() on USD3 and sUSD3 tokens via Safe multisig transaction
/// @dev Batches both report calls into a single Safe transaction
contract ReportTokensSafe is Script, SafeHelper {
    /// @notice USD3 token address (mainnet)
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    /// @notice sUSD3 token address (mainnet)
    address private constant sUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    /// @notice Main execution function
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF)) {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Reporting USD3 and sUSD3 via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("USD3 address:", USD3);
        console2.log("sUSD3 address:", sUSD3);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Encode the report calls
        console2.log("Preparing report calls...");

        // USD3 report (senior tranche first)
        console2.log("1. USD3 report");
        bytes memory usd3CallData = abi.encodeCall(ITokenizedStrategy.report, ());
        addToBatch(USD3, usd3CallData);

        // sUSD3 report (subordinate tranche)
        console2.log("2. sUSD3 report");
        bytes memory susd3CallData = abi.encodeCall(ITokenizedStrategy.report, ());
        addToBatch(sUSD3, susd3CallData);

        console2.log("");
        console2.log("Both report calls prepared");

        // Execute the batch
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Note: Actual profit/loss values will be available after execution");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
            console2.log("");
            console2.log("Note: Simulation may not show actual profit/loss values");
        }
    }

    /// @notice Alternative entry point with default simulation mode
    function run() external {
        this.run(false);
    }

    /// @notice Check if base fee is acceptable
    /// @return True if base fee is below limit
    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
    }
}
