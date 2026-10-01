// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";
import {ITokenizedStrategy} from "../../src/interfaces/ITokenizedStrategy.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";

interface IUSD3Operations {
    function morphoCredit() external view returns (address);
    function syncTrancheShare() external;
}

interface IMorphoCreditConfig {
    function protocolConfig() external view returns (address);
}

interface IAprOracle {
    function getCurrentApr(address vault) external view returns (uint256 apr);
}

/// @title ReportTokensSafe Script
/// @notice Calls report() on USD3 and sUSD3 tokens via Safe multisig transaction
/// @dev Batches both report calls into a single Safe transaction
contract ReportTokensSafe is Script, SafeHelper {
    /// @notice USD3 token address (mainnet)
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    /// @notice sUSD3 token address (mainnet)
    address private constant sUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    /// @notice Yearn APR oracle address (mainnet)
    address private constant APR_ORACLE = 0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92;

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
        uint256 maxUnlockTime = vm.envOr("MAX_UNLOCK_TIME", uint256(7 days));
        require(maxUnlockTime <= 365 days, "MAX_UNLOCK_TIME too long");
        uint256 susd3MaxUnlockTime = vm.envOr("SUSD3_MAX_UNLOCK_TIME", maxUnlockTime);
        require(susd3MaxUnlockTime <= 365 days, "SUSD3_MAX_UNLOCK_TIME too long");
        console2.log("Max unlock time:", _formatDuration(maxUnlockTime));
        console2.log("Susd3 max unlock time:", _formatDuration(susd3MaxUnlockTime));
        console2.log("");

        uint256 dealAmount = vm.envOr("DEAL_AMOUNT", uint256(0));
        if (dealAmount != 0) {
            deal(USDC, USD3, dealAmount);
            console2.log("Deal usdc:", dealAmount);
            console2.log("");
        }

        uint256 warpTo = vm.envOr("WARP_TO", uint256(0));
        if (warpTo != 0) {
            vm.warp(warpTo);
            console2.log("Warp to:", warpTo);
            console2.log("");
        }

        // Encode the report calls
        console2.log("Preparing report calls...");
        uint256 trancheShareVariant = _trancheShareVariant();
        console2.log("Protocol tranche share variant:", trancheShareVariant);
        console2.log("");

        // USD3 report (senior tranche first)
        console2.log("1. USD3 report");
        _addSyncTrancheShareIfNeeded(trancheShareVariant);
        _addSetProfitMaxUnlockTimeIfNeeded("USD3", USD3, maxUnlockTime);
        _addReportAndLogResults("USD3", USD3);

        // sUSD3 report (subordinate tranche)
        console2.log("2. sUSD3 report");
        _addSetProfitMaxUnlockTimeIfNeeded("sUSD3", sUSD3, susd3MaxUnlockTime);
        _addReportAndLogResults("sUSD3", sUSD3);

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
            _logFullProfitUnlockDates();
            console2.log("");
            _logCurrentAprs();
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

    function _trancheShareVariant() private view returns (uint256) {
        address morphoCredit = IUSD3Operations(USD3).morphoCredit();
        address protocolConfig = IMorphoCreditConfig(morphoCredit).protocolConfig();
        return IProtocolConfig(protocolConfig).getTrancheShareVariant();
    }

    function _addSyncTrancheShareIfNeeded(uint256 trancheShareVariant) private {
        uint256 currentPerformanceFee = ITokenizedStrategy(USD3).performanceFee();
        console2.log("  performanceFee:", currentPerformanceFee);

        if (currentPerformanceFee == trancheShareVariant) {
            console2.log("  syncTrancheShare skipped");
            return;
        }

        console2.log("  adding syncTrancheShare()");
        addToBatch(USD3, abi.encodeCall(IUSD3Operations.syncTrancheShare, ()));
    }

    function _addSetProfitMaxUnlockTimeIfNeeded(string memory label, address strategy, uint256 maxUnlockTime) private {
        uint256 currentUnlockTime = ITokenizedStrategy(strategy).profitMaxUnlockTime();
        console2.log("  %s profitMaxUnlockTime: %s", label, _formatDuration(currentUnlockTime));

        if (currentUnlockTime == maxUnlockTime) {
            console2.log("  %s setProfitMaxUnlockTime skipped", label);
            return;
        }

        console2.log("  %s adding setProfitMaxUnlockTime(%d)", label, maxUnlockTime);
        addToBatch(strategy, abi.encodeWithSignature("setProfitMaxUnlockTime(uint256)", maxUnlockTime));
    }

    function _addReportAndLogResults(string memory label, address strategy) private {
        bytes memory returnData = addToBatch(strategy, abi.encodeCall(ITokenizedStrategy.report, ()));
        (uint256 profit, uint256 loss) = abi.decode(returnData, (uint256, uint256));

        console2.log("  %s report profit:", label, profit);
        console2.log("  %s report loss:", label, loss);
    }

    function _logFullProfitUnlockDates() private {
        console2.log("=== Simulated fullProfitUnlockDate() ===");
        _logFullProfitUnlockDate("USD3", ITokenizedStrategy(USD3).fullProfitUnlockDate());
        _logFullProfitUnlockDate("sUSD3", ITokenizedStrategy(sUSD3).fullProfitUnlockDate());
    }

    function _logFullProfitUnlockDate(string memory label, uint256 unlockDate) private {
        console2.log("%s:", label);
        console2.log("  unix: %d", unlockDate);
        console2.log("  utc:  %s", _formatTimestamp(unlockDate));
        console2.log("  in:   %s", _formatDuration(unlockDate > block.timestamp ? unlockDate - block.timestamp : 0));
    }

    function _logCurrentAprs() private view {
        console2.log("=== Simulated current APR ===");
        IAprOracle oracle = IAprOracle(APR_ORACLE);
        uint256 usd3Apr = oracle.getCurrentApr(USD3);
        uint256 susd3Apr = oracle.getCurrentApr(sUSD3);
        console2.log("USD3:  %s", _formatApr(usd3Apr));
        console2.log("sUSD3: %s", _formatApr(usd3Apr + susd3Apr));
    }

    function _formatApr(uint256 apr) private pure returns (string memory) {
        uint256 percentage = (apr * 10_000) / 1e18;
        uint256 whole = percentage / 100;
        uint256 decimal = percentage % 100;

        return string(abi.encodePacked(vm.toString(whole), ".", decimal < 10 ? "0" : "", vm.toString(decimal), "%"));
    }

    function _formatTimestamp(uint256 timestamp) private returns (string memory) {
        string[] memory cmd = new string[](4);
        cmd[0] = "date";
        cmd[1] = "-u";
        cmd[2] = string(abi.encodePacked("-r", vm.toString(timestamp)));
        cmd[3] = "+%Y-%m-%d %H:%M:%S UTC";

        return _trimTrailingNewline(string(vm.ffi(cmd)));
    }

    function _formatDuration(uint256 secondsRemaining) private pure returns (string memory) {
        uint256 daysRemaining = secondsRemaining / 1 days;
        uint256 hoursRemaining = (secondsRemaining % 1 days) / 1 hours;
        uint256 minutesRemaining = (secondsRemaining % 1 hours) / 1 minutes;

        return string(
            abi.encodePacked(
                vm.toString(daysRemaining), "d ", vm.toString(hoursRemaining), "h ", vm.toString(minutesRemaining), "m"
            )
        );
    }

    function _trimTrailingNewline(string memory input) private pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        uint256 length = inputBytes.length;

        while (length > 0 && (inputBytes[length - 1] == 0x0a || inputBytes[length - 1] == 0x0d)) {
            length--;
        }

        bytes memory outputBytes = new bytes(length);
        for (uint256 i; i < length; ++i) {
            outputBytes[i] = inputBytes[i];
        }

        return string(outputBytes);
    }
}
