// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {SafeHelper} from "../utils/SafeHelper.sol";

interface ITokenizedStrategyProfitUnlock {
    function management() external view returns (address);
    function profitMaxUnlockTime() external view returns (uint256);
    function setProfitMaxUnlockTime(uint256 profitMaxUnlockTime) external;
}

/// @title SetProfitMaxUnlockTimeSafe
/// @notice Sets profitMaxUnlockTime on USD3 and sUSD3 through the protocol Safe.
contract SetProfitMaxUnlockTimeSafe is Script, SafeHelper {
    address private constant DEFAULT_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address private constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    struct VaultStatus {
        string label;
        address vault;
        address management;
        uint256 currentProfitMaxUnlockTime;
        uint256 targetProfitMaxUnlockTime;
        bool needsUpdate;
    }

    function run() external {
        this.run(vm.envUint("PROFIT_MAX_UNLOCK_TIME"), false);
    }

    function run(uint256 profitMaxUnlockTime) external {
        this.run(profitMaxUnlockTime, false);
    }

    function run(uint256 profitMaxUnlockTime, bool send) external isBatch(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE)) {
        require(profitMaxUnlockTime <= 365 days, "PROFIT_MAX_UNLOCK_TIME too long");

        if (!_baseFeeOkay()) {
            console2.log("Aborting: Base fee too high");
            return;
        }

        address safe = vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE);
        VaultStatus[2] memory statuses = _loadStatuses(safe, profitMaxUnlockTime);
        uint256 updates = _countUpdates(statuses);
        require(updates > 0, "profitMaxUnlockTime already set");

        _logStatuses("Set USD3/sUSD3 Profit Max Unlock Time", statuses);
        console2.log("Send to Safe:", send);
        console2.log("");

        _addSetProfitMaxUnlockTimeIfNeeded(statuses[0]);
        _addSetProfitMaxUnlockTimeIfNeeded(statuses[1]);

        console2.log("");
        console2.log("=== Batch Summary ===");
        console2.log("Operations:", updates);
        console2.log("Target profitMaxUnlockTime:", _formatDuration(profitMaxUnlockTime));
        console2.log("");

        if (send) {
            console2.log("Sending profit unlock update transaction to Safe API...");
            executeBatch(true);
            console2.log("Transaction sent successfully.");
        } else {
            console2.log("Simulation mode - not sending to Safe");
            executeBatch(false);
            console2.log("Simulation completed successfully.");
        }
    }

    function preview(uint256 profitMaxUnlockTime) external view {
        require(profitMaxUnlockTime <= 365 days, "PROFIT_MAX_UNLOCK_TIME too long");
        _logStatuses(
            "Preview USD3/sUSD3 Profit Max Unlock Time Updates",
            _loadStatuses(vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE), profitMaxUnlockTime)
        );
    }

    function verify(uint256 profitMaxUnlockTime) external view {
        require(
            ITokenizedStrategyProfitUnlock(USD3).profitMaxUnlockTime() == profitMaxUnlockTime,
            "USD3 profitMaxUnlockTime mismatch"
        );
        require(
            ITokenizedStrategyProfitUnlock(SUSD3).profitMaxUnlockTime() == profitMaxUnlockTime,
            "sUSD3 profitMaxUnlockTime mismatch"
        );

        console2.log("=== Verify USD3/sUSD3 Profit Max Unlock Time ===");
        console2.log("USD3 profitMaxUnlockTime:", _formatDuration(profitMaxUnlockTime));
        console2.log("sUSD3 profitMaxUnlockTime:", _formatDuration(profitMaxUnlockTime));
    }

    function _loadStatuses(address safe, uint256 targetProfitMaxUnlockTime)
        private
        view
        returns (VaultStatus[2] memory statuses)
    {
        statuses[0] = _loadStatus("USD3", USD3, safe, targetProfitMaxUnlockTime);
        statuses[1] = _loadStatus("sUSD3", SUSD3, safe, targetProfitMaxUnlockTime);
    }

    function _loadStatus(string memory label, address vault, address safe, uint256 targetProfitMaxUnlockTime)
        private
        view
        returns (VaultStatus memory status)
    {
        ITokenizedStrategyProfitUnlock strategy = ITokenizedStrategyProfitUnlock(vault);
        address management = strategy.management();
        require(management == safe, string.concat(label, " management is not protocol Safe"));

        uint256 currentProfitMaxUnlockTime = strategy.profitMaxUnlockTime();
        status = VaultStatus({
            label: label,
            vault: vault,
            management: management,
            currentProfitMaxUnlockTime: currentProfitMaxUnlockTime,
            targetProfitMaxUnlockTime: targetProfitMaxUnlockTime,
            needsUpdate: currentProfitMaxUnlockTime != targetProfitMaxUnlockTime
        });
    }

    function _addSetProfitMaxUnlockTimeIfNeeded(VaultStatus memory status) private {
        if (!status.needsUpdate) {
            console2.log("%s profitMaxUnlockTime already set; skipping", status.label);
            return;
        }

        addToBatch(
            status.vault,
            abi.encodeCall(ITokenizedStrategyProfitUnlock.setProfitMaxUnlockTime, (status.targetProfitMaxUnlockTime))
        );
        console2.log("Added %s setProfitMaxUnlockTime call", status.label);
    }

    function _countUpdates(VaultStatus[2] memory statuses) private pure returns (uint256 updates) {
        for (uint256 i = 0; i < statuses.length; i++) {
            if (statuses[i].needsUpdate) updates++;
        }
    }

    function _logStatuses(string memory label, VaultStatus[2] memory statuses) private view {
        console2.log("===", label, "===");
        console2.log("Safe address:", vm.envOr("SAFE_ADDRESS", DEFAULT_SAFE));
        console2.log("");

        for (uint256 i = 0; i < statuses.length; i++) {
            console2.log(statuses[i].label);
            console2.log("  vault:", statuses[i].vault);
            console2.log("  management:", statuses[i].management);
            console2.log("  current profitMaxUnlockTime:", _formatDuration(statuses[i].currentProfitMaxUnlockTime));
            console2.log("  target profitMaxUnlockTime:", _formatDuration(statuses[i].targetProfitMaxUnlockTime));
            console2.log("  needs update:", statuses[i].needsUpdate);
        }
    }

    function _baseFeeOkay() private view returns (bool) {
        uint256 basefeeLimit = vm.envOr("BASE_FEE_LIMIT", uint256(50)) * 1e9;
        if (block.basefee >= basefeeLimit) {
            console2.log("Base fee too high: %d gwei > %d gwei limit", block.basefee / 1e9, basefeeLimit / 1e9);
            return false;
        }
        console2.log("Base fee OK: %d gwei", block.basefee / 1e9);
        return true;
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
}
