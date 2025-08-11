// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface ISUSD3 is IStrategy {
    // Structs
    struct UserCooldown {
        uint64 cooldownEnd;
        uint64 windowEnd;
        uint128 shares;
    }

    // Events
    event CooldownStarted(
        address indexed user,
        uint256 shares,
        uint256 timestamp
    );
    event CooldownCancelled(address indexed user);
    event WithdrawalCompleted(
        address indexed user,
        uint256 shares,
        uint256 assets
    );
    event USD3StrategyUpdated(address newStrategy);
    event WithdrawalWindowUpdated(uint256 newWindow);

    // Core functions
    function startCooldown(uint256 shares) external;
    function cancelCooldown() external;
    function withdraw() external returns (uint256 assets);

    // View functions
    function getCooldownStatus(
        address user
    )
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares);
    function cooldowns(
        address user
    ) external view returns (UserCooldown memory);
    function lockedUntil(address user) external view returns (uint256);

    // Parameters
    function lockDuration() external view returns (uint256);
    function cooldownDuration() external view returns (uint256);
    function withdrawalWindow() external view returns (uint256);
    function usd3Strategy() external view returns (address);
    function morphoCredit() external view returns (address);
    function maxSubordinationRatio() external view returns (uint256);
    function symbol() external pure returns (string memory);

    // Management functions
    function setUsd3Strategy(address _usd3Strategy) external;
    function setWithdrawalWindow(uint256 _withdrawalWindow) external;
}
