// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IMorpho, Id, PaymentCycle} from "../../src/interfaces/IMorpho.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";

/// @title GetMarketFreezeTime Script
/// @notice Finds when the market froze by querying the last payment cycle and cycle duration
/// @dev Helps determine the correct endDate parameter for CloseCycleSafe
contract GetMarketFreezeTime is Script {
    /// @notice MorphoCredit contract address (mainnet)
    address private constant MORPHO_ADDRESS = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    IMorpho private constant morpho = IMorpho(MORPHO_ADDRESS);

    /// @notice ProtocolConfig contract address (mainnet)
    address private constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    IProtocolConfig private constant protocolConfig = IProtocolConfig(PROTOCOL_CONFIG);

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    function run() external {
        console2.log("=== Market Freeze Time Analysis ===");
        console2.log("");
        console2.log("MorphoCredit address:", MORPHO_ADDRESS);
        console2.log("ProtocolConfig address:", PROTOCOL_CONFIG);
        console2.log("Market ID:", vm.toString(Id.unwrap(MARKET_ID)));
        console2.log("");

        // Query last PaymentCycleCreated event
        bytes32 eventSig = keccak256("PaymentCycleCreated(bytes32,uint256,uint256,uint256)");

        // Set up topics array for the event filter
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = eventSig;
        topics[1] = bytes32(Id.unwrap(MARKET_ID));

        // Query logs from a reasonable starting block (adjust as needed)
        // Search last 3M blocks (~1 year on mainnet) or from genesis
        uint256 fromBlock = block.number > 3000000 ? block.number - 3000000 : 1;

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, block.number, MORPHO_ADDRESS, topics);

        if (logs.length == 0) {
            console2.log("ERROR: No PaymentCycleCreated events found");
            console2.log("The market may never have had a payment cycle created");
            return;
        }

        // Get the most recent cycle
        Vm.EthGetLogs memory lastLog = logs[logs.length - 1];

        // Decode event data: (cycleId, startDate, endDate)
        (uint256 cycleId, uint256 startDate, uint256 endDate) = abi.decode(lastLog.data, (uint256, uint256, uint256));

        // Get cycle duration from ProtocolConfig
        uint256 cycleDuration = protocolConfig.getCycleDuration();

        // Calculate freeze time
        uint256 freezeTime = endDate + cycleDuration;

        console2.log("=== Last Payment Cycle ===");
        console2.log("Cycle ID:", cycleId);
        console2.log("Start date:", startDate);
        console2.log("  ", _formatTimestamp(startDate));
        console2.log("End date:", endDate);
        console2.log("  ", _formatTimestamp(endDate));
        console2.log("");

        console2.log("=== Cycle Configuration ===");
        console2.log("Cycle duration:", cycleDuration, "seconds");
        console2.log("  ", cycleDuration / 1 days, "days");
        console2.log("");

        console2.log("=== Market Freeze Information ===");
        console2.log("Market froze at:", freezeTime);
        console2.log("  ", _formatTimestamp(freezeTime));
        console2.log("");

        console2.log("Current timestamp:", block.timestamp);
        console2.log("  ", _formatTimestamp(block.timestamp));
        console2.log("");

        if (block.timestamp >= freezeTime) {
            uint256 daysSinceFrozen = (block.timestamp - freezeTime) / 1 days;
            console2.log("Status: MARKET IS FROZEN");
            console2.log("Days since frozen:", daysSinceFrozen);
            console2.log("");

            // Calculate suggested new cycle end date (current time or custom)
            uint256 suggestedEndDate = block.timestamp;

            console2.log("=== Ready to Close Cycle ===");
            console2.log("You can now run CloseCycleSafe with an end date");
            console2.log("Suggested end date (now):", suggestedEndDate);
            console2.log("");
            console2.log("Example command:");
            console2.log("forge script script/operations/CloseCycleSafe.s.sol:CloseCycleSafe \\");
            console2.log("  --sig \"run(string,uint256,bool)\" \\");
            console2.log("  \"data/obligations.json\" \\");
            console2.log("  %d \\", suggestedEndDate);
            console2.log("  true");
        } else {
            uint256 timeUntilFreeze = freezeTime - block.timestamp;
            uint256 daysUntilFreeze = timeUntilFreeze / 1 days;
            console2.log("Status: Market is NOT frozen");
            console2.log("Time until freeze:", timeUntilFreeze, "seconds");
            console2.log("  ", daysUntilFreeze, "days");
            console2.log("");
            console2.log("The market will freeze at timestamp:", freezeTime);
            console2.log("You cannot close the cycle until after this time");
        }

        console2.log("");
        console2.log("=== Additional Information ===");
        console2.log("- The market freezes when: current time >= last cycle end + cycle duration");
        console2.log("- Once frozen, borrowing and repayment are disabled");
        console2.log("- A new cycle must be created to unfreeze the market");
        console2.log("- The new cycle end date should be in the future");
    }

    /**
     * @notice Format a Unix timestamp as a human-readable date
     * @param timestamp The Unix timestamp to format
     * @return A string representation of the date
     */
    function _formatTimestamp(uint256 timestamp) private pure returns (string memory) {
        // Basic date calculation (approximate, doesn't handle leap years perfectly)
        uint256 year = 1970;
        uint256 month = 1;
        uint256 day = 1;

        uint256 daysSinceEpoch = timestamp / 86400;

        // Approximate year calculation
        year += (daysSinceEpoch / 365);
        uint256 remainingDays = daysSinceEpoch % 365;

        // Approximate month calculation
        uint256[] memory daysInMonth = new uint256[](12);
        daysInMonth[0] = 31; // January
        daysInMonth[1] = 28; // February (not handling leap years)
        daysInMonth[2] = 31; // March
        daysInMonth[3] = 30; // April
        daysInMonth[4] = 31; // May
        daysInMonth[5] = 30; // June
        daysInMonth[6] = 31; // July
        daysInMonth[7] = 31; // August
        daysInMonth[8] = 30; // September
        daysInMonth[9] = 31; // October
        daysInMonth[10] = 30; // November
        daysInMonth[11] = 31; // December

        for (uint256 i = 0; i < 12; i++) {
            if (remainingDays >= daysInMonth[i]) {
                remainingDays -= daysInMonth[i];
                month++;
            } else {
                day = remainingDays + 1;
                break;
            }
        }

        // Get time components
        uint256 secondsInDay = timestamp % 86400;
        uint256 hourValue = secondsInDay / 3600;
        uint256 minuteValue = (secondsInDay % 3600) / 60;
        uint256 secondValue = secondsInDay % 60;

        // Format as string
        return string(
            abi.encodePacked(
                "~",
                vm.toString(year),
                "-",
                _padZero(month),
                "-",
                _padZero(day),
                " ",
                _padZero(hourValue),
                ":",
                _padZero(minuteValue),
                ":",
                _padZero(secondValue),
                " UTC"
            )
        );
    }

    /**
     * @notice Pad a number with leading zero if needed
     */
    function _padZero(uint256 num) private pure returns (string memory) {
        if (num < 10) {
            return string(abi.encodePacked("0", vm.toString(num)));
        }
        return vm.toString(num);
    }
}
