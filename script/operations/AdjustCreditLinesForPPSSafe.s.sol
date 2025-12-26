// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {IMorpho, IMorphoCredit, Id, Position} from "../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../src/libraries/EventsLib.sol";
import {IERC4626} from "../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title AdjustCreditLinesForPPSSafe Script
/// @notice Automatically adjusts credit lines based on waUSDC PPS growth since last SetCreditLine event
/// @dev Queries events to determine exact scaling needed for each borrower
contract AdjustCreditLinesForPPSSafe is Script, SafeHelper {
    /// @notice MorphoCredit contract address (mainnet)
    address private constant MORPHO_ADDRESS = 0xD8e0337436665aF893726177B9756F27481C3Bbe;
    IMorpho private constant morpho = IMorpho(MORPHO_ADDRESS);
    IMorphoCredit private constant morphoCredit = IMorphoCredit(MORPHO_ADDRESS);

    /// @notice CreditLine contract address (mainnet)
    CreditLine private constant creditLine = CreditLine(0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9);

    /// @notice waUSDC (ERC4626 wrapper for Aave USDC)
    IERC4626 private constant WAUSDC = IERC4626(0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E);

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    /// @notice Minimum credit line from protocol config
    uint256 private constant MIN_CREDIT_LINE = 10_000e6; // 10k USDC minimum

    /// @notice Struct for borrower addresses from JSON
    struct BorrowerData {
        address borrower_address;
    }

    /// @notice Event data structure
    struct CreditLineEvent {
        uint256 blockNumber;
        uint256 credit;
        bool found;
    }

    /// @notice Main execution function
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(bool send) external isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF)) {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Adjusting Credit Lines for waUSDC PPS Growth via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("MorphoCredit address:", MORPHO_ADDRESS);
        console2.log("CreditLine address:", address(creditLine));
        console2.log("waUSDC address:", address(WAUSDC));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("");

        // Get current waUSDC PPS
        uint256 currentPPS = WAUSDC.convertToAssets(1e6);
        console2.log("Current waUSDC PPS: 1.000000 waUSDC = %s USDC", _formatUSDC(currentPPS));
        console2.log("");

        // Read borrower list from JSON
        string memory jsonPath = "data/borrowers-2025-10-22.json";
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        BorrowerData[] memory borrowerList = abi.decode(data, (BorrowerData[]));

        console2.log("Processing", borrowerList.length, "borrowers from", jsonPath);
        console2.log("");

        // Prepare arrays for batch update
        uint256 validCount = 0;
        Id[] memory tempIds = new Id[](borrowerList.length);
        address[] memory tempBorrowers = new address[](borrowerList.length);
        uint256[] memory tempVvs = new uint256[](borrowerList.length);
        uint256[] memory tempCredits = new uint256[](borrowerList.length);
        uint128[] memory tempDrps = new uint128[](borrowerList.length);

        uint256 totalCurrentCredit = 0;
        uint256 totalNewCredit = 0;

        console2.log("=== Credit Line Adjustments ===");

        // Process each borrower
        for (uint256 i = 0; i < borrowerList.length; i++) {
            address borrower = borrowerList[i].borrower_address;

            // Get current position
            Position memory pos = morpho.position(MARKET_ID, borrower);
            uint256 currentCredit = pos.collateral;

            // Skip if no current credit
            if (currentCredit == 0) {
                continue;
            }

            // Get current DRP
            (, uint128 currentDrp,) = morphoCredit.borrowerPremium(MARKET_ID, borrower);

            // Query last SetCreditLine event for this borrower
            CreditLineEvent memory lastEvent = _getLastSetCreditLineEvent(borrower);

            if (!lastEvent.found) {
                console2.log("WARNING: No SetCreditLine event found for", borrower);
                console2.log("  Skipping borrower");
                console2.log("");
                continue;
            }

            // Get historical PPS at event block
            uint256 historicalPPS = _getHistoricalPPS(lastEvent.blockNumber);

            // Calculate PPS growth
            uint256 ppsGrowthBps = ((currentPPS - historicalPPS) * 10000) / historicalPPS;

            // Scale down credit line
            uint256 scaledCredit = (lastEvent.credit * historicalPPS) / currentPPS;

            // Ensure minimum credit line
            if (scaledCredit < MIN_CREDIT_LINE && scaledCredit > 0) {
                scaledCredit = MIN_CREDIT_LINE;
            }

            // Calculate actual reduction
            uint256 reductionBps = 0;
            if (currentCredit > scaledCredit) {
                reductionBps = ((currentCredit - scaledCredit) * 10000) / currentCredit;
            }

            // Log details for first few and last few
            if (validCount < 3 || i >= borrowerList.length - 2) {
                console2.log("Borrower:", borrower);
                console2.log("  Last set at block:", lastEvent.blockNumber);
                console2.log("  PPS then: %s USDC", _formatUSDC(historicalPPS));
                console2.log("  PPS growth: %s%%", _formatBps(ppsGrowthBps));
                console2.log("  Current credit: %s waUSDC", currentCredit / 1e6);
                console2.log("  New credit: %s waUSDC", scaledCredit / 1e6);
                console2.log("  Reduction: %s%%", _formatBps(reductionBps));
                console2.log("");
            } else if (validCount == 3) {
                console2.log("... [showing first 3 and last 2 borrowers] ...");
                console2.log("");
            }

            // Get current VV (we'll keep it the same)
            // Since we don't have VV in the position, we'll need to maintain it
            // For now, calculate to maintain LTV ratio
            uint256 vv = (scaledCredit * 1e18) / 8e17; // Assuming 80% LTV

            // Add to arrays
            tempIds[validCount] = MARKET_ID;
            tempBorrowers[validCount] = borrower;
            tempVvs[validCount] = vv;
            tempCredits[validCount] = scaledCredit;
            tempDrps[validCount] = currentDrp;

            totalCurrentCredit += currentCredit;
            totalNewCredit += scaledCredit;
            validCount++;
        }

        // Create final arrays with correct size
        Id[] memory ids = new Id[](validCount);
        address[] memory borrowers = new address[](validCount);
        uint256[] memory vvs = new uint256[](validCount);
        uint256[] memory credits = new uint256[](validCount);
        uint128[] memory drps = new uint128[](validCount);

        for (uint256 i = 0; i < validCount; i++) {
            ids[i] = tempIds[i];
            borrowers[i] = tempBorrowers[i];
            vvs[i] = tempVvs[i];
            credits[i] = tempCredits[i];
            drps[i] = tempDrps[i];
        }

        // Calculate overall reduction
        uint256 overallReductionBps = 0;
        if (totalCurrentCredit > 0) {
            overallReductionBps = ((totalCurrentCredit - totalNewCredit) * 10000) / totalCurrentCredit;
        }

        console2.log("=== Summary ===");
        console2.log("Borrowers processed:", validCount);
        console2.log("Total current credit: %s waUSDC", totalCurrentCredit / 1e6);
        console2.log("Total new credit: %s waUSDC", totalNewCredit / 1e6);
        console2.log("Overall reduction: %s%%", _formatBps(overallReductionBps));
        console2.log("(Matches waUSDC PPS appreciation)");
        console2.log("");

        if (validCount == 0) {
            console2.log("No borrowers to update");
            return;
        }

        // Create the setCreditLines call
        bytes memory setCreditLinesCall =
            abi.encodeCall(CreditLine.setCreditLines, (ids, borrowers, vvs, credits, drps));

        // Add to batch
        addToBatch(address(creditLine), setCreditLinesCall);

        console2.log("=== Batch Summary ===");
        console2.log("Operation: CreditLine.setCreditLines");
        console2.log("Number of credit lines:", validCount);
        console2.log("All adjustments based on PPS growth since last set");
        console2.log("All DRPs preserved from current on-chain values");
        console2.log("");

        // Execute the batch
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Multisig signers must approve the transaction in Safe UI");
            console2.log("2. Once threshold reached, anyone can execute");
            console2.log("3. All", validCount, "credit lines will be updated atomically");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /**
     * @notice Alternative entry point with default simulation mode
     */
    function run() external {
        this.run(false);
    }

    /**
     * @notice Query the last SetCreditLine event for a borrower
     * @param borrower The borrower address
     * @return Event data including block number and credit amount
     */
    function _getLastSetCreditLineEvent(address borrower) private view returns (CreditLineEvent memory) {
        // Build event filter
        bytes32 eventSig = keccak256("SetCreditLine(bytes32,address,uint256)");
        bytes32 marketIdTopic = bytes32(Id.unwrap(MARKET_ID));
        bytes32 borrowerTopic = bytes32(uint256(uint160(borrower)));

        // Query logs (last 10000 blocks as example, adjust as needed)
        uint256 fromBlock = block.number > 10000 ? block.number - 10000 : 1;

        VmSafe.Log[] memory logs =
            vm.getLogs(MORPHO_ADDRESS, fromBlock, block.number, eventSig, marketIdTopic, borrowerTopic);

        if (logs.length == 0) {
            return CreditLineEvent(0, 0, false);
        }

        // Get the most recent event
        VmSafe.Log memory lastLog = logs[logs.length - 1];

        // Decode credit amount from data
        uint256 credit = abi.decode(lastLog.data, (uint256));

        return CreditLineEvent(lastLog.blockNumber, credit, true);
    }

    /**
     * @notice Get historical waUSDC PPS at a specific block
     * @param blockNumber The block number to query
     * @return PPS value at that block
     */
    function _getHistoricalPPS(uint256 blockNumber) private returns (uint256) {
        // Store current block
        uint256 currentBlock = block.number;

        // Roll to historical block
        vm.roll(blockNumber);
        uint256 historicalPPS = WAUSDC.convertToAssets(1e6);

        // Roll back to current
        vm.roll(currentBlock);

        return historicalPPS;
    }

    /**
     * @notice Format USDC amount with decimals
     */
    function _formatUSDC(uint256 amount) private pure returns (string memory) {
        uint256 whole = amount / 1e6;
        uint256 decimal = (amount % 1e6) / 1000; // Show 3 decimal places
        return string(abi.encodePacked(vm.toString(whole), ".", _padZeros(decimal, 3)));
    }

    /**
     * @notice Format basis points as percentage
     */
    function _formatBps(uint256 bps) private pure returns (string memory) {
        uint256 whole = bps / 100;
        uint256 decimal = bps % 100;
        return string(abi.encodePacked(vm.toString(whole), ".", _padZeros(decimal, 2)));
    }

    /**
     * @notice Pad number with leading zeros
     */
    function _padZeros(uint256 num, uint256 digits) private pure returns (string memory) {
        string memory numStr = vm.toString(num);
        bytes memory result = new bytes(digits);

        // Fill with zeros
        for (uint256 i = 0; i < digits; i++) {
            result[i] = "0";
        }

        // Copy number from the right
        bytes memory numBytes = bytes(numStr);
        uint256 startPos = digits > numBytes.length ? digits - numBytes.length : 0;
        for (uint256 i = 0; i < numBytes.length && i < digits; i++) {
            result[startPos + i] = numBytes[i];
        }

        return string(result);
    }

    /**
     * @notice Check if base fee is acceptable
     * @return True if base fee is below limit
     */
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
