// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface ISUSD3 is IERC20 {
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
}
