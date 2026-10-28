// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface INotificationVault is IStrategy {
    struct UserCooldown {
        uint64 cooldownEnd;
        uint64 windowEnd;
        uint128 shares;
    }

    event CooldownStarted(address indexed user, uint256 shares, uint256 timestamp);
    event CooldownCancelled(address indexed user);
    event WithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);
    event CooldownBypassUpdated(address indexed account, bool allowed);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidCooldownConfig();
    error NoActiveCooldown();
    error InsufficientShares();
    error ReportsDisabled();
    error CooldownBypassed();

    function startCooldown(uint256 shares) external;
    function cancelCooldown() external;
    function getCooldownStatus(address user)
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares);
    function setCooldownBypass(address account, bool allowed) external;

    function cooldowns(address user) external view returns (uint64 cooldownEnd, uint64 windowEnd, uint128 shares);
    function cooldownBypass(address account) external view returns (bool);
    function cooldownDuration() external view returns (uint64);
    function withdrawalWindow() external view returns (uint64);
    function symbol() external pure returns (string memory);
}
