// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IIrm} from "../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {Id} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";

/// @title IAdaptiveCurveIrm
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IFixedRateIrm is IIrm {
    /// @notice Sets the borrow rate for a market.
    /// @dev A rate can be set by anybody, but only once.
    /// @dev The creator of a market with this IRM would typically batch the creation with the setting of the rate.
    function setBorrowRate(Id id, uint256 newBorrowRate) external;
}
