// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {IMorpho, IMorphoCredit, Id} from "../../src/interfaces/IMorpho.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {MorphoCreditLib} from "../../src/libraries/periphery/MorphoCreditLib.sol";

/// @title GetMarketFreezeTime Script
/// @notice Finds when the market froze by querying the last payment cycle and cycle duration
/// @dev Helps determine the correct endDate parameter for CloseCycleSafe
contract GetMarketFreezeTime is Script {
    using MorphoCreditLib for IMorphoCredit;

    /// @notice MorphoCredit contract address (mainnet)
    address private constant MORPHO_ADDRESS = 0xDe6e08ac208088cc62812Ba30608D852c6B0EcBc;
    IMorphoCredit private constant morpho = IMorphoCredit(MORPHO_ADDRESS);

    /// @notice ProtocolConfig contract address (mainnet)
    address private constant PROTOCOL_CONFIG = 0x6b276A2A7dd8b629adBA8A06AD6573d01C84f34E;
    IProtocolConfig private constant protocolConfig = IProtocolConfig(PROTOCOL_CONFIG);

    /// @notice Market ID for credit lines (mainnet)
    Id private constant MARKET_ID = Id.wrap(0xc2c3e4b656f4b82649c8adbe82b3284c85cc7dc57c6dc8df6ca3dad7d2740d75);

    function run() external {
        console2.log("=== Market Freeze Time Analysis ===");
        console2.log("");

        // Get cycle count directly from storage
        uint256 cycleCount = morpho.getPaymentCycleLength(MARKET_ID);

        if (cycleCount == 0) {
            console2.log("ERROR: No payment cycles exist");
            return;
        }

        uint256 lastCycleId = cycleCount - 1;
        (, uint256 endDate) = morpho.getCycleDates(MARKET_ID, lastCycleId);
        uint256 cycleDuration = protocolConfig.getCycleDuration();
        uint256 freezeTime = endDate + cycleDuration;

        console2.log("Last cycle ID:", lastCycleId);
        console2.log("Last cycle end:", endDate);
        console2.log("  ", _formatTimestamp(endDate));
        console2.log("Cycle duration:", cycleDuration / 1 days, "days");
        console2.log("");

        console2.log("Freeze time:", freezeTime);
        console2.log("  ", _formatTimestamp(freezeTime));
        console2.log("Current time:", block.timestamp);
        console2.log("  ", _formatTimestamp(block.timestamp));
        console2.log("");

        if (block.timestamp >= freezeTime) {
            console2.log("Status: FROZEN");
            console2.log("Days since frozen:", (block.timestamp - freezeTime) / 1 days);
        } else {
            console2.log("Status: NOT FROZEN");
            console2.log("Days until freeze:", (freezeTime - block.timestamp) / 1 days);
        }
    }

    function _formatTimestamp(uint256 timestamp) private returns (string memory) {
        string[] memory cmd = new string[](4);
        cmd[0] = "date";
        cmd[1] = "-u";
        cmd[2] = string(abi.encodePacked("-r", vm.toString(timestamp)));
        cmd[3] = "+%Y-%m-%d %H:%M:%SZ";

        bytes memory result = vm.ffi(cmd);
        return string(result);
    }
}
