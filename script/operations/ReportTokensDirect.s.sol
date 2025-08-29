// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {ITokenizedStrategy} from "../../src/interfaces/ITokenizedStrategy.sol";

/// @title ReportTokensDirect Script
/// @notice Calls report() on USD3 and sUSD3 tokens via direct execution
/// @dev For testing or emergency use - production should use ReportTokensSafe
contract ReportTokensDirect is Script {
    /// @notice USD3 token address (mainnet)
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    /// @notice sUSD3 token address (mainnet)
    address private constant sUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    /// @notice Dry run function for validation without execution
    function dryRun() external view {
        console2.log("=== DRY RUN: Reporting USD3 and sUSD3 ===");
        console2.log("USD3 address:", USD3);
        console2.log("sUSD3 address:", sUSD3);
        console2.log("");

        // Check that contracts exist and have code
        uint256 usd3CodeSize;
        uint256 susd3CodeSize;

        assembly {
            usd3CodeSize := extcodesize(USD3)
            susd3CodeSize := extcodesize(sUSD3)
        }

        if (usd3CodeSize == 0) {
            console2.log("[ERROR] USD3 contract not found at address");
        } else {
            console2.log("[SUCCESS] USD3 contract found (code size: %d bytes)", usd3CodeSize);
        }

        if (susd3CodeSize == 0) {
            console2.log("[ERROR] sUSD3 contract not found at address");
        } else {
            console2.log("[SUCCESS] sUSD3 contract found (code size: %d bytes)", susd3CodeSize);
        }

        console2.log("");
        console2.log("Dry run completed!");
        console2.log("Note: Actual profit/loss values can only be determined during execution");
    }

    /// @notice Main execution function
    function run() external {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Reporting USD3 and sUSD3 (Direct) ===");
        console2.log("USD3 address:", USD3);
        console2.log("sUSD3 address:", sUSD3);
        console2.log("");

        // Get the deployer account
        string memory walletType = vm.envString("WALLET_TYPE");
        require(keccak256(bytes(walletType)) == keccak256("account"), "Direct execution requires WALLET_TYPE=account");

        string memory accountName = vm.envString("SAFE_PROPOSER_ACCOUNT");
        console2.log("Using account:", accountName);

        vm.startBroadcast();

        // Call report on USD3 (senior tranche first)
        console2.log("Calling report on USD3...");
        (uint256 usd3Profit, uint256 usd3Loss) = ITokenizedStrategy(USD3).report();
        console2.log("USD3 Report Results:");
        console2.log("  Profit:", usd3Profit);
        console2.log("  Loss:", usd3Loss);
        console2.log("");

        // Call report on sUSD3 (subordinate tranche)
        console2.log("Calling report on sUSD3...");
        (uint256 susd3Profit, uint256 susd3Loss) = ITokenizedStrategy(sUSD3).report();
        console2.log("sUSD3 Report Results:");
        console2.log("  Profit:", susd3Profit);
        console2.log("  Loss:", susd3Loss);

        vm.stopBroadcast();

        console2.log("");
        console2.log("Reports completed successfully!");

        // Summary
        console2.log("");
        console2.log("=== Summary ===");
        console2.log("USD3:");
        console2.log("  Profit:", usd3Profit);
        console2.log("  Loss:", usd3Loss);
        console2.log("sUSD3:");
        console2.log("  Profit:", susd3Profit);
        console2.log("  Loss:", susd3Loss);

        uint256 totalProfit = usd3Profit + susd3Profit;
        uint256 totalLoss = usd3Loss + susd3Loss;
        console2.log("Total:");
        console2.log("  Profit:", totalProfit);
        console2.log("  Loss:", totalLoss);

        if (totalLoss > 0) {
            console2.log("");
            console2.log("[WARNING] Losses detected - sUSD3 shares may be burned for loss absorption");
        }
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
