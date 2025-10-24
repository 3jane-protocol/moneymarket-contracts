// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IProtocolConfig} from "../../../../src/interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";

/**
 * @title ConfigureProtocolConfig
 * @notice Configure ProtocolConfig for v1.1 upgrade
 * @dev Updates parameters for MarkdownController, sUSD3 subordination logic, and debt cap
 */
contract ConfigureProtocolConfig is Script {
    function run() external {
        // Load addresses
        address protocolConfig = vm.envAddress("PROTOCOL_CONFIG");

        // Load configuration values (with defaults if not provided)
        uint256 fullMarkdownDuration;
        try vm.envUint("FULL_MARKDOWN_DURATION") returns (uint256 duration) {
            fullMarkdownDuration = duration;
        } catch {
            fullMarkdownDuration = 180 days; // Default: 6 months
        }

        uint256 subordinatedDebtCapBps;
        try vm.envUint("SUBORDINATED_DEBT_CAP_BPS") returns (uint256 cap) {
            subordinatedDebtCapBps = cap;
        } catch {
            subordinatedDebtCapBps = 10000; // Default: 100%
        }

        uint256 subordinatedDebtFloorBps;
        try vm.envUint("SUBORDINATED_DEBT_FLOOR_BPS") returns (uint256 floor) {
            subordinatedDebtFloorBps = floor;
        } catch {
            subordinatedDebtFloorBps = 10000; // Default: 100%
        }

        uint256 debtCap;
        try vm.envUint("DEBT_CAP") returns (uint256 cap) {
            debtCap = cap;
        } catch {
            debtCap = 50_000_000e6; // Default: 50M waUSDC
        }

        console.log("Configuring ProtocolConfig...");
        console.log("  ProtocolConfig:", protocolConfig);
        console.log("  Full markdown duration:", fullMarkdownDuration / 1 days, "days");
        console.log("  Subordinated debt cap:", subordinatedDebtCapBps / 100, "%");
        console.log("  Subordinated debt floor:", subordinatedDebtFloorBps / 100, "%");
        console.log("  Debt cap:", debtCap / 1e6, "M waUSDC");

        IProtocolConfig config = IProtocolConfig(protocolConfig);

        vm.startBroadcast();

        // Set full markdown duration for MarkdownController
        config.setConfig(ProtocolConfigLib.FULL_MARKDOWN_DURATION, fullMarkdownDuration);
        console.log("  Set FULL_MARKDOWN_DURATION");

        // Set subordinated debt parameters for sUSD3
        config.setConfig(ProtocolConfigLib.SUBORDINATED_DEBT_CAP_BPS, subordinatedDebtCapBps);
        console.log("  Set SUBORDINATED_DEBT_CAP_BPS");

        config.setConfig(ProtocolConfigLib.SUBORDINATED_DEBT_FLOOR_BPS, subordinatedDebtFloorBps);
        console.log("  Set SUBORDINATED_DEBT_FLOOR_BPS");

        config.setConfig(ProtocolConfigLib.DEBT_CAP, debtCap);
        console.log("  Set DEBT_CAP");

        console.log("ProtocolConfig configuration complete");

        vm.stopBroadcast();
    }
}
