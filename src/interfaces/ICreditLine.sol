// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id, MarketParams} from "./IMorpho.sol";

/// @title ICreditLine
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Interface that credit line used by Morpho must implement.
/// @dev It is the user's responsibility to select markets with safe credit line.
interface ICreditLine {
    /// @notice The defender
    function ozd() external view returns (address);

    /// @notice The zktls prover
    function prover() external view returns (address);

    /// @notice The morpho contract.
    function MORPHO() external view returns (address);

    /// @notice The markdown manager
    function mm() external view returns (address);

    /// @notice Sets `newOzd` as `ozd` of the contract.
    /// @dev Warning: No two-step transfer ownership.
    /// @dev Warning: The ozd can be set to the zero address.
    function setOzd(address newOzd) external;

    /// @notice Sets `newProver` as `prover` of the contract.
    /// @dev Warning: No two-step transfer ownership.
    /// @dev Warning: The prover can be set to the zero address.
    function setProver(address newProver) external;

    /// @notice Sets `newMm` as `mm` of the contract.
    /// @dev Warning: No two-step transfer ownership.
    /// @dev Warning: The mm can be set to the zero address.
    function setMm(address newMm) external;

    /// @notice Sets credit line
    function setCreditLines(
        Id[] calldata ids,
        address[] calldata borrowers,
        uint256[] calldata vv,
        uint256[] calldata credit,
        uint128[] calldata drp
    ) external;

    /// @notice Close a payment cycle and create repayment obligations.
    function closeCycleAndPostObligations(
        Id id,
        uint256 endDate,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external;

    /// @notice Add obligations to the most recently closed cycle.
    function addObligationsToLatestCycle(
        Id id,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external;

    /// @notice Settle a borrower position.
    function settle(MarketParams memory marketParams, address borrower, uint256 assets, uint256 cover)
        external
        returns (uint256 writtenOffAssets, uint256 writtenOffShares);
}
