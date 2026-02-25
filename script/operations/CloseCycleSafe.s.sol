// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {TimelockHelper} from "../utils/TimelockHelper.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {Id} from "../../src/interfaces/IMorpho.sol";
import {CycleObligationDataLib} from "../utils/CycleObligationDataLib.sol";

/// @title CloseCycleSafe Script
/// @notice Closes payment cycles and posts obligations via Safe multisig transaction
/// @dev Parses JSON file with obligation data and batches transactions for Safe.
///      Since CreditLine is owned by the Timelock, use schedule/execute for timelock flow.
///
///      Usage (timelock flow):
///      1. Schedule: forge script ... -s "schedule(string,uint256,bool)" repayments.json <endDate> true
///      2. Wait for timelock delay (24 hours)
///      3. Execute: forge script ... -s "execute(string,uint256,bool)" repayments.json <endDate> true
contract CloseCycleSafe is Script, SafeHelper, TimelockHelper {
    using CycleObligationDataLib for *;

    /// @notice CreditLine contract address (mainnet)
    CreditLine private constant creditLine = CreditLine(0x26389b03298BA5DA0664FfD6bF78cF3A7820c6A9);

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    /// @notice Maximum number of obligations to process in a single call
    uint256 private constant BATCH_SIZE = 50;

    address private constant TIMELOCK = 0x1dCcD4628d48a50C1A7adEA3848bcC869f08f8C2;
    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;

    /// @notice Struct for JSON parsing - fields ordered to match alphabetized JSON
    /// @dev JSON fields alphabetically: borrower, endingBalance, repaymentBps
    struct ObligationData {
        address borrower; // maps to "borrower" (1st alphabetically)
        uint256 endingBalance; // maps to "endingBalance" (2nd alphabetically)
        uint256 repaymentBps; // maps to "repaymentBps" (3rd alphabetically)
    }

    /// @notice Main execution function
    /// @param jsonPath Path to JSON file containing obligation data
    /// @param endDate Unix timestamp for cycle end date
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function run(string memory jsonPath, uint256 endDate, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF))
    {
        // Check base fee
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Closing Cycle and Posting Obligations via Safe ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF));
        console2.log("CreditLine address:", address(creditLine));
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("End date:", endDate);
        console2.log("JSON file:", jsonPath);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Validate end date
        require(CycleObligationDataLib.validateEndDate(endDate), "End date must be in the past or very near future");

        // Read and parse JSON
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        ObligationData[] memory obligations = abi.decode(data, (ObligationData[]));

        console2.log("Loaded", obligations.length, "obligations from JSON");

        // Validate all obligations
        for (uint256 i = 0; i < obligations.length; i++) {
            require(
                CycleObligationDataLib.validateObligation(
                    obligations[i].borrower, obligations[i].repaymentBps, obligations[i].endingBalance
                ),
                string.concat("Invalid obligation for borrower ", vm.toString(obligations[i].borrower))
            );
        }

        if (obligations.length > 0) {
            console2.log("All obligations validated successfully");
        }
        console2.log("");

        // Process in batches
        uint256 totalBatches = obligations.length == 0 ? 1 : (obligations.length + BATCH_SIZE - 1) / BATCH_SIZE;
        console2.log("Processing in %d batches of up to %d obligations each", totalBatches, BATCH_SIZE);

        // Handle empty obligations array - still need to close the cycle
        if (obligations.length == 0) {
            console2.log("No obligations to post - closing cycle with end date only");

            // Create empty arrays
            address[] memory emptyBorrowers = new address[](0);
            uint256[] memory emptyRepaymentBps = new uint256[](0);
            uint256[] memory emptyEndingBalances = new uint256[](0);

            // Close cycle with empty obligations
            bytes memory callData = abi.encodeCall(
                creditLine.closeCycleAndPostObligations,
                (MARKET_ID, endDate, emptyBorrowers, emptyRepaymentBps, emptyEndingBalances)
            );

            addToBatch(address(creditLine), callData);
        }

        for (uint256 i = 0; i < obligations.length; i += BATCH_SIZE) {
            uint256 end = i + BATCH_SIZE > obligations.length ? obligations.length : i + BATCH_SIZE;
            uint256 size = end - i;

            console2.log("Batch %d - Processing obligations %d to %d", (i / BATCH_SIZE) + 1, i, end - 1);

            // Prepare arrays for this batch
            address[] memory borrowers = new address[](size);
            uint256[] memory repaymentBps = new uint256[](size);
            uint256[] memory endingBalances = new uint256[](size);

            for (uint256 j = 0; j < size; j++) {
                ObligationData memory ob = obligations[i + j];
                borrowers[j] = ob.borrower;
                repaymentBps[j] = ob.repaymentBps;
                endingBalances[j] = ob.endingBalance;

                console2.log("  -", vm.toString(ob.borrower));
                console2.log("    Repayment:", ob.repaymentBps, "bps");
                console2.log("    Ending balance:", ob.endingBalance);
            }

            // Encode the appropriate call based on batch number
            bytes memory callData;
            if (i == 0) {
                // First batch: close cycle with end date
                console2.log("    [FIRST BATCH: Using closeCycleAndPostObligations]");
                callData = abi.encodeCall(
                    creditLine.closeCycleAndPostObligations,
                    (MARKET_ID, endDate, borrowers, repaymentBps, endingBalances)
                );
            } else {
                // Subsequent batches: add to latest cycle
                console2.log("    [SUBSEQUENT BATCH: Using addObligationsToLatestCycle]");
                callData = abi.encodeCall(
                    creditLine.addObligationsToLatestCycle, (MARKET_ID, borrowers, repaymentBps, endingBalances)
                );
            }

            // Add to Safe batch
            addToBatch(address(creditLine), callData);
        }

        console2.log("");
        console2.log("All batches prepared");

        // Execute the batch
        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully!");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully");
        }
    }

    /// @notice Alternative entry point with default simulation mode
    /// @param jsonPath Path to JSON file containing obligation data
    /// @param endDate Unix timestamp for cycle end date
    function run(string memory jsonPath, uint256 endDate) external {
        this.run(jsonPath, endDate, false);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TIMELOCK FLOW
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Schedule cycle close through Timelock (Step 1)
    /// @param jsonPath Path to JSON file containing obligation data
    /// @param endDate Unix timestamp for cycle end date
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function schedule(string memory jsonPath, uint256 endDate, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(TIMELOCK)
    {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Schedule Close Cycle via Timelock ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("CreditLine address:", address(creditLine));
        console2.log("End date:", endDate);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Build timelock operation arrays from obligations
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) =
            _buildTimelockArrays(jsonPath, endDate);

        // Generate deterministic salt from endDate
        bytes32 salt = keccak256(abi.encodePacked("closeCycle", endDate));
        bytes32 predecessor = bytes32(0);

        // Calculate operation ID
        bytes32 operationId = calculateBatchOperationId(targets, values, datas, predecessor, salt);

        console2.log("Operation details:");
        console2.log("  Salt:", vm.toString(salt));
        console2.log("  Operation ID:", vm.toString(operationId));
        console2.log("  Calls:", targets.length);
        console2.log("");

        // Check if operation already exists
        if (isOperation(TIMELOCK, operationId)) {
            logOperationState(TIMELOCK, operationId);
            console2.log("");
            console2.log("Operation already exists. Use execute() to execute when ready.");
            return;
        }

        // Simulate execution at future timestamp (after timelock delay)
        uint256 minDelay = getMinDelay(TIMELOCK);
        uint256 savedTimestamp = block.timestamp;
        vm.warp(block.timestamp + minDelay);
        simulateExecution(TIMELOCK, targets, values, datas);
        vm.warp(savedTimestamp);
        console2.log("");

        console2.log("Timelock delay:", minDelay, "seconds (%d hours)", minDelay / 3600);
        console2.log("");

        // Encode the schedule call
        bytes memory scheduleCalldata = encodeScheduleBatch(targets, values, datas, predecessor, salt, minDelay);

        // Add to Safe batch
        console2.log("Adding scheduleBatch call to Safe transaction...");
        addToBatch(TIMELOCK, scheduleCalldata);

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("");
            console2.log("=== IMPORTANT ===");
            console2.log("Operation ID: %s", vm.toString(operationId));
            console2.log("");
            console2.log("Next steps:");
            console2.log("1. Multisig signers must approve and execute the schedule transaction");
            console2.log("2. Wait %d seconds (%d hours) after scheduling", minDelay, minDelay / 3600);
            console2.log("3. Run execute() with the SAME parameters");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
            console2.log("Operation ID would be: %s", vm.toString(operationId));
        }
    }

    /// @notice Execute scheduled cycle close through Timelock (Step 2 - after delay)
    /// @param jsonPath Path to JSON file containing obligation data (must match schedule)
    /// @param endDate Unix timestamp for cycle end date (must match schedule)
    /// @param send Whether to send transaction to Safe API (true) or just simulate (false)
    function execute(string memory jsonPath, uint256 endDate, bool send)
        external
        isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE))
        isTimelock(TIMELOCK)
    {
        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        console2.log("=== Execute Close Cycle via Timelock ===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("Timelock address:", TIMELOCK);
        console2.log("CreditLine address:", address(creditLine));
        console2.log("End date:", endDate);
        console2.log("Send to Safe:", send);
        console2.log("");

        // Rebuild timelock operation arrays (must match schedule)
        (address[] memory targets, uint256[] memory values, bytes[] memory datas) =
            _buildTimelockArrays(jsonPath, endDate);

        // Regenerate the same salt
        bytes32 salt = keccak256(abi.encodePacked("closeCycle", endDate));
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

        if (send) {
            console2.log("Sending transaction to Safe API...");
            executeBatch(true);
            console2.log("");
            console2.log("Transaction sent successfully!");
            console2.log("Cycle closed with end date: %d", endDate);
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("");
            console2.log("Simulation completed successfully");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Build timelock operation arrays from obligation data
    function _buildTimelockArrays(string memory jsonPath, uint256 endDate)
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory datas)
    {
        // Read and parse JSON
        string memory json = vm.readFile(jsonPath);
        bytes memory data = vm.parseJson(json);
        ObligationData[] memory obligations = abi.decode(data, (ObligationData[]));

        console2.log("Loaded", obligations.length, "obligations from JSON");

        // Validate all obligations
        for (uint256 i = 0; i < obligations.length; i++) {
            require(
                CycleObligationDataLib.validateObligation(
                    obligations[i].borrower, obligations[i].repaymentBps, obligations[i].endingBalance
                ),
                string.concat("Invalid obligation for borrower ", vm.toString(obligations[i].borrower))
            );
        }

        // Calculate number of batches
        uint256 totalBatches = obligations.length == 0 ? 1 : (obligations.length + BATCH_SIZE - 1) / BATCH_SIZE;
        targets = new address[](totalBatches);
        values = new uint256[](totalBatches);
        datas = new bytes[](totalBatches);

        // Handle empty obligations
        if (obligations.length == 0) {
            targets[0] = address(creditLine);
            values[0] = 0;
            datas[0] = abi.encodeCall(
                creditLine.closeCycleAndPostObligations,
                (MARKET_ID, endDate, new address[](0), new uint256[](0), new uint256[](0))
            );
            console2.log("No obligations - closing cycle with end date only");
            return (targets, values, datas);
        }

        // Build batched calls
        for (uint256 i = 0; i < obligations.length; i += BATCH_SIZE) {
            uint256 batchIdx = i / BATCH_SIZE;
            uint256 end = i + BATCH_SIZE > obligations.length ? obligations.length : i + BATCH_SIZE;
            uint256 size = end - i;

            address[] memory borrowers = new address[](size);
            uint256[] memory repaymentBps = new uint256[](size);
            uint256[] memory endingBalances = new uint256[](size);

            for (uint256 j = 0; j < size; j++) {
                borrowers[j] = obligations[i + j].borrower;
                repaymentBps[j] = obligations[i + j].repaymentBps;
                endingBalances[j] = obligations[i + j].endingBalance;
            }

            targets[batchIdx] = address(creditLine);
            values[batchIdx] = 0;

            if (i == 0) {
                datas[batchIdx] = abi.encodeCall(
                    creditLine.closeCycleAndPostObligations,
                    (MARKET_ID, endDate, borrowers, repaymentBps, endingBalances)
                );
            } else {
                datas[batchIdx] = abi.encodeCall(
                    creditLine.addObligationsToLatestCycle, (MARKET_ID, borrowers, repaymentBps, endingBalances)
                );
            }
        }

        return (targets, values, datas);
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
