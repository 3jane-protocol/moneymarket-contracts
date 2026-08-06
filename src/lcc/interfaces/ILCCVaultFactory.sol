// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

/// @title ILCCVaultFactory
/// @notice Minimal family authority and admission interface consumed by LCC vault implementations.
interface ILCCVaultFactory {
    function authorizeDeposit(address user, bool hadOpenExposure) external;
    function isOwner(address account) external view returns (bool);
    function isGuardian(address account) external view returns (bool);
    function requireBouncer(address account) external view;
}
