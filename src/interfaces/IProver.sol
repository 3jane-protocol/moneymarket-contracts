// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id} from "./IMorpho.sol";

/// @title IProver
/// @author Morpho Labs
/// @custom:contact security@morpho.org
interface IProver {
    /// @notice Verifies user connected offchain services + backing of assets.
    function verify(Id id, address borrower, uint256 vv, uint256 credit, uint128 drp) external view returns (bool);
}
