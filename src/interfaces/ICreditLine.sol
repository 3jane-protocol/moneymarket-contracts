// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id} from "./IMorpho.sol";

/// @title ICreditLine
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Interface that credit line used by Morpho must implement.
/// @dev It is the user's responsibility to select markets with safe credit line.
interface ICreditLine {
    /// @notice The owner of the contract.
    /// @dev It has the power to change the owner.
    function owner() external view returns (address);

    /// @notice The defender
    function ozd() external view returns (address);

    /// @notice The zktls prover
    function prover() external view returns (address);

    /// @notice The morpho contract.
    function morpho() external view returns (address);

    /// @notice Sets `newOwner` as `owner` of the contract.
    /// @dev Warning: No two-step transfer ownership.
    /// @dev Warning: The owner can be set to the zero address.
    function setOwner(address newOwner) external;

    /// @notice Sets `newOzd` as `ozd` of the contract.
    /// @dev Warning: No two-step transfer ownership.
    /// @dev Warning: The ozd can be set to the zero address.
    function setOzd(address newOzd) external;

    /// @notice Sets `newProver` as `prover` of the contract.
    /// @dev Warning: No two-step transfer ownership.
    /// @dev Warning: The prover can be set to the zero address.
    function setProver(address newProver) external;

    /// @notice Sets credit line
    function setCreditLine(Id id, address borrower, uint256 credit, uint128 premiumRate) external;
}
