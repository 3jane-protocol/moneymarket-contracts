// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";

interface ITokenizedStrategyStatus {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function fullProfitUnlockDate() external view returns (uint256);
}

interface IAprOracleStatus {
    function getCurrentApr(address vault) external view returns (uint256 apr);
}

/// @title Token Profit Unlock Status
/// @notice Prints profit unlock and APR status for USD3 and sUSD3.
contract GetTokenProfitUnlockStatus is Script {
    /// @notice USD3 token address (mainnet)
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;

    /// @notice sUSD3 token address (mainnet)
    address private constant sUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    /// @notice Yearn APR oracle address (mainnet)
    address private constant APR_ORACLE = 0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92;

    function run() external {
        IAprOracleStatus oracle = IAprOracleStatus(APR_ORACLE);
        uint256 usd3Apr = oracle.getCurrentApr(USD3);
        uint256 susd3WrapperApr = oracle.getCurrentApr(sUSD3);

        console2.log("=== USD3 / sUSD3 Profit Unlock Status ===");
        console2.log("Block timestamp:", block.timestamp);
        console2.log("UTC:", _formatTimestamp(block.timestamp));
        console2.log("");

        _logStrategyStatus("USD3", USD3, usd3Apr);
        console2.log("");
        _logStrategyStatus("sUSD3", sUSD3, usd3Apr + susd3WrapperApr);
    }

    function _logStrategyStatus(string memory label, address strategy, uint256 apr) private {
        uint256 unlockDate = ITokenizedStrategyStatus(strategy).fullProfitUnlockDate();
        uint256 lockedShares = ITokenizedStrategyStatus(strategy).balanceOf(strategy);
        uint256 lockedProfit = ITokenizedStrategyStatus(strategy).convertToAssets(lockedShares);

        console2.log("%s:", label);
        console2.log("  fullProfitUnlockDate unix: %d", unlockDate);
        console2.log("  fullProfitUnlockDate utc:  %s", _formatTimestamp(unlockDate));
        console2.log(
            "  unlocks in:               %s",
            _formatDuration(unlockDate > block.timestamp ? unlockDate - block.timestamp : 0)
        );
        console2.log("  remaining locked profit:  %s", _formatTokenAmount(lockedProfit));
        console2.log("  oracle APR:               %s", _formatApr(apr));
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

    function _formatApr(uint256 apr) private pure returns (string memory) {
        uint256 percentage = (apr * 10_000) / 1e18;
        uint256 whole = percentage / 100;
        uint256 decimal = percentage % 100;

        return string(abi.encodePacked(vm.toString(whole), ".", decimal < 10 ? "0" : "", vm.toString(decimal), "%"));
    }

    function _formatTokenAmount(uint256 amount) private pure returns (string memory) {
        uint256 whole = amount / 1e6;
        uint256 decimal = amount % 1e6;

        return string(abi.encodePacked(vm.toString(whole), ".", _padLeft(vm.toString(decimal), 6)));
    }

    function _padLeft(string memory input, uint256 length) private pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        if (inputBytes.length >= length) return input;

        bytes memory outputBytes = new bytes(length);
        uint256 padding = length - inputBytes.length;

        for (uint256 i; i < padding; ++i) {
            outputBytes[i] = "0";
        }

        for (uint256 i; i < inputBytes.length; ++i) {
            outputBytes[padding + i] = inputBytes[i];
        }

        return string(outputBytes);
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
