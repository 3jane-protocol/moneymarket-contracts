// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "../../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPYieldToken} from "../../../../../src/jane/PYTLocker.sol";

/// @title MockPYT
/// @notice Mock Pendle Yield Token for testing PYTLocker
/// @dev Implements IPYieldToken interface with configurable expiry
contract MockPYT is ERC20, IPYieldToken {
    uint256 private _expiry;

    /// @notice Creates a new mock PYT token
    /// @param name Token name
    /// @param symbol Token symbol
    /// @param expiryTime Expiry timestamp
    constructor(string memory name, string memory symbol, uint256 expiryTime) ERC20(name, symbol) {
        _expiry = expiryTime;
    }

    /// @notice Returns the expiry timestamp
    /// @return The expiry timestamp
    function expiry() external view override returns (uint256) {
        return _expiry;
    }

    /// @notice Sets a new expiry timestamp (for testing)
    /// @param newExpiry The new expiry timestamp
    function setExpiry(uint256 newExpiry) external {
        _expiry = newExpiry;
    }

    /// @notice Mints tokens to an address (for testing)
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burns tokens from an address (for testing)
    /// @param from Address to burn from
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
