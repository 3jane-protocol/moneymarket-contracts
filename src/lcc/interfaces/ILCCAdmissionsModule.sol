// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

/// @title ILCCAdmissionsModule
/// @notice Narrow, read-only extension point for LCC family deposit decisions.
interface ILCCAdmissionsModule {
    function canDeposit(address user, address vault) external view returns (bool);
}
