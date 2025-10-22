// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC4626} from "../../lib/forge-std/src/interfaces/IERC4626.sol";

/// @title IUSD3
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Interface for USD3 token, which is an ERC4626 vault
interface IUSD3 is IERC4626 {
    // USD3 inherits all ERC4626 functions including:
    // - deposit(uint256 assets, address receiver) returns (uint256 shares)
    // - redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)
    // - And all other ERC4626 standard functions
    function whitelist(address user) external view returns (bool);
    function availableDepositLimit(address owner) external view returns (uint256);
}
