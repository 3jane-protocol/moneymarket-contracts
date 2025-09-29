// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    ERC20,
    ERC20Wrapper,
    IERC20,
    IERC20Metadata
} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";

error InvalidAddress();
error PYTNotExpired();
error PYTAlreadyExpired();
error LockerAlreadyExists();

/// @title IPYieldToken
/// @notice Interface for Pendle Yield Tokens
interface IPYieldToken is IERC20Metadata {
    /// @notice Returns the expiry timestamp of the yield token
    function expiry() external view returns (uint256);
}

/// @title PYTLocker
/// @notice Wraps Pendle Yield Tokens (PYT) and locks them until expiry
/// @dev Once the PYT expires, wrapped tokens can be unwrapped to redeem the underlying
contract PYTLocker is ERC20Wrapper {
    /**
     * @notice Creates a new PYT locker
     * @param pytoken The Pendle Yield Token to wrap
     * @dev Reverts if the token is already expired or invalid
     */
    constructor(IERC20Metadata pytoken)
        ERC20Wrapper(pytoken)
        ERC20(string.concat("l", pytoken.symbol()), string.concat("l", pytoken.symbol()))
    {
        if (address(pytoken) == address(0)) revert InvalidAddress();
        if (isExpired()) revert PYTAlreadyExpired();
    }

    /**
     * @notice Deposits PYT tokens and mints wrapped tokens
     * @param account The account to mint wrapped tokens to
     * @param value The amount of PYT tokens to deposit
     * @return True if successful
     * @dev Prevents deposits after the PYT has expired
     */
    function depositFor(address account, uint256 value) public override returns (bool) {
        if (isExpired()) revert PYTAlreadyExpired();
        return super.depositFor(account, value);
    }

    /**
     * @notice Burns wrapped tokens and withdraws PYT tokens
     * @param account The account to send PYT tokens to
     * @param value The amount of wrapped tokens to burn
     * @return True if successful
     * @dev Only allows withdrawals after the PYT has expired
     */
    function withdrawTo(address account, uint256 value) public override returns (bool) {
        if (!isExpired()) revert PYTNotExpired();
        return super.withdrawTo(account, value);
    }

    /**
     * @notice Checks if the underlying PYT has expired
     * @return True if the PYT has expired, false otherwise
     */
    function isExpired() public view returns (bool) {
        return expiry() <= block.timestamp;
    }

    /**
     * @notice Returns the time remaining until the PYT expires
     * @return Seconds until expiry, or 0 if already expired
     */
    function timeUntilExpiry() public view returns (uint256) {
        uint256 expiryTime = expiry();
        if (expiryTime <= block.timestamp) return 0;
        return expiryTime - block.timestamp;
    }

    /**
     * @notice Returns the expiry timestamp of the underlying PYT
     * @return The expiry timestamp
     */
    function expiry() public view returns (uint256) {
        return IPYieldToken(address(underlying())).expiry();
    }
}

/// @title PYTLockerFactory
/// @notice Factory for deploying PYT locker contracts
/// @dev Tracks deployed lockers and prevents duplicates
contract PYTLockerFactory {
    /// @notice Emitted when a new locker is created
    event LockerCreated(address indexed pytoken, address indexed locker);

    /// @notice Maps PYT token addresses to their locker contracts
    mapping(address => address) public pytLockers;

    /**
     * @notice Creates a new PYT locker or returns existing one
     * @param pytoken The Pendle Yield Token to create a locker for
     * @return locker The address of the locker contract
     * @dev Reverts if trying to create a locker for an already expired token
     */
    function newPYTLocker(address pytoken) external returns (address locker) {
        if (pytoken == address(0)) revert InvalidAddress();

        // Check if locker already exists
        locker = pytLockers[pytoken];
        if (locker != address(0)) revert LockerAlreadyExists();

        // Create new locker
        locker = address(new PYTLocker(IERC20Metadata(pytoken)));
        pytLockers[pytoken] = locker;

        emit LockerCreated(pytoken, locker);
    }

    /**
     * @notice Gets the locker address for a given PYT
     * @param pytoken The PYT token address
     * @return The locker contract address, or zero address if not deployed
     */
    function getLocker(address pytoken) external view returns (address) {
        return pytLockers[pytoken];
    }

    /**
     * @notice Checks if a locker exists for a given PYT
     * @param pytoken The PYT token address
     * @return True if a locker has been deployed for this PYT
     */
    function hasLocker(address pytoken) external view returns (bool) {
        return pytLockers[pytoken] != address(0);
    }
}
