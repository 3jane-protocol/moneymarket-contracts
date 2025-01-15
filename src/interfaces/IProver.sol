// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IProver
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IProver {
    /// @notice Verifies backing of assets.
    function isSafeTVV(address borrower, uint256 credit) external view returns (bool);
}
