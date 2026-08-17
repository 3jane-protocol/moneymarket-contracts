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
    event CooldownStarted(address indexed user, uint256 shares, uint256 timestamp);
    event CooldownCancelled(address indexed user);
    event WithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);

    // Core functions
    function startCooldown(uint256 shares) external;
    function cancelCooldown() external;

    // View functions
    function getCooldownStatus(address user)
        external
        view
        returns (uint256 cooldownEnd, uint256 windowEnd, uint256 shares);
    function cooldowns(address user) external view returns (uint64 cooldownEnd, uint64 windowEnd, uint128 shares);
    function lockedUntil(address user) external view returns (uint256);

    // Parameters
    /// @dev Reads the sUSD3 lock duration from ProtocolConfig.
    function lockDuration() external view returns (uint256);
    /// @dev Reads the sUSD3 cooldown duration from ProtocolConfig.
    function cooldownDuration() external view returns (uint256);
    /// @dev Reads the sUSD3 withdrawal window from ProtocolConfig.
    function withdrawalWindow() external view returns (uint256);
    function morphoCredit() external view returns (address);
    /// @dev Reads the maximum subordination ratio from ProtocolConfig.
    function maxSubordinationRatio() external view returns (uint256);
    function symbol() external pure returns (string memory);
}
