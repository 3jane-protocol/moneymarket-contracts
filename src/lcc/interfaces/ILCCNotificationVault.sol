// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

/// @title ILCCRedeemableVault
/// @notice TokenizedStrategy redemption and withdrawal with an explicit loss bound, as exposed by USD3 and USD3l.
interface ILCCRedeemableVault {
    function redeem(uint256 shares, address receiver, address owner, uint256 maxLoss) external returns (uint256 assets);

    function withdraw(uint256 assets, address receiver, address owner, uint256 maxLoss)
        external
        returns (uint256 shares);
}

/// @title ILCCNotificationVault
/// @notice The USD3 Notification Vault (USD3l) views the leveraged funding helper reads for its cooldown gate.
interface ILCCNotificationVault is ILCCRedeemableVault {
    function cooldownDuration() external view returns (uint64);
    function isShutdown() external view returns (bool);
}
