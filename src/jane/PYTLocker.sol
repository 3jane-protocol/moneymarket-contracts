// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "../../lib/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../../lib/openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "../../lib/openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title IPYieldToken
/// @notice Interface for Pendle Yield Tokens
interface IPYieldToken is IERC20Metadata {
    /// @notice Returns the expiry timestamp of the yield token
    function expiry() external view returns (uint256);
}

/// @title PYTLocker
/// @notice Manages locking of multiple Pendle Yield Tokens (PYT) until their expiry
/// @dev Single contract that can handle multiple PYT tokens with owner whitelisting
contract PYTLocker is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Errors
    error TokenNotSupported();
    error TokenAlreadySupported();
    error InvalidToken();
    error TokenExpired();
    error TokenNotExpired();
    error InsufficientBalance();
    error ZeroAmount();

    // Events
    event TokenAdded(address indexed pytToken, uint256 expiry);
    event Deposited(address indexed user, address indexed pytToken, uint256 amount);
    event Withdrawn(address indexed user, address indexed pytToken, uint256 amount);

    // State variables
    /// @notice Tracks user balances for each PYT token
    /// @dev token -> user -> amount
    mapping(address => mapping(address => uint256)) public balances;

    /// @notice Total supply locked for each PYT token
    /// @dev token -> total amount
    mapping(address => uint256) public totalSupply;

    /// @notice Set of supported PYT tokens (add-only)
    /// @dev Uses EnumerableSet for efficient operations and enumeration
    EnumerableSet.AddressSet private supportedTokens;

    /**
     * @notice Creates a new multi-token PYT locker
     * @param _initialOwner The address that will be the owner of the contract
     */
    constructor(address _initialOwner) Ownable(_initialOwner) {}

    // Modifiers
    modifier onlySupported(address pytToken) {
        if (!supportedTokens.contains(pytToken)) revert TokenNotSupported();
        _;
    }

    // Owner functions

    /**
     * @notice Adds a new PYT token to the whitelist
     * @param pytToken The address of the PYT token to add
     * @dev Can only be called by owner, tokens cannot be removed once added
     */
    function addSupportedToken(address pytToken) external onlyOwner {
        if (supportedTokens.contains(pytToken)) revert TokenAlreadySupported();
        if (pytToken == address(0)) revert InvalidToken();

        // Verify it's a valid PYT token by calling expiry()
        uint256 tokenExpiry = IPYieldToken(pytToken).expiry();
        if (tokenExpiry <= block.timestamp) revert TokenExpired();

        supportedTokens.add(pytToken);

        emit TokenAdded(pytToken, tokenExpiry);
    }

    // User functions

    /**
     * @notice Deposits PYT tokens and locks them until expiry
     * @param pytToken The PYT token to deposit
     * @param amount The amount to deposit
     * @dev Tokens must be whitelisted and not expired
     */
    function deposit(address pytToken, uint256 amount) external nonReentrant onlySupported(pytToken) {
        if (amount == 0) revert ZeroAmount();
        if (isExpired(pytToken)) revert TokenExpired();

        // Transfer tokens from user
        IERC20(pytToken).safeTransferFrom(msg.sender, address(this), amount);

        // Update balances
        balances[pytToken][msg.sender] += amount;
        totalSupply[pytToken] += amount;

        emit Deposited(msg.sender, pytToken, amount);
    }

    /**
     * @notice Withdraws PYT tokens after they have expired
     * @param pytToken The PYT token to withdraw
     * @param amount The amount to withdraw
     * @dev Can only withdraw after token expiry
     */
    function withdraw(address pytToken, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!isExpired(pytToken)) revert TokenNotExpired();

        uint256 balance = balances[pytToken][msg.sender];
        if (balance < amount) revert InsufficientBalance();

        // Update balances
        balances[pytToken][msg.sender] = balance - amount;
        totalSupply[pytToken] -= amount;

        // Transfer tokens to user
        IERC20(pytToken).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, pytToken, amount);
    }

    // View functions

    /**
     * @notice Checks if a PYT token has expired
     * @param pytToken The PYT token to check
     * @return True if the token has expired, false otherwise
     */
    function isExpired(address pytToken) public view returns (bool) {
        if (!supportedTokens.contains(pytToken)) return false;
        return IPYieldToken(pytToken).expiry() <= block.timestamp;
    }

    /**
     * @notice Returns the time remaining until a PYT expires
     * @param pytToken The PYT token to check
     * @return Seconds until expiry, or 0 if already expired or not supported
     */
    function timeUntilExpiry(address pytToken) public view returns (uint256) {
        if (!supportedTokens.contains(pytToken)) return 0;
        uint256 expiryTime = IPYieldToken(pytToken).expiry();
        if (expiryTime <= block.timestamp) return 0;
        return expiryTime - block.timestamp;
    }

    /**
     * @notice Returns the expiry timestamp of a PYT token
     * @param pytToken The PYT token to check
     * @return The expiry timestamp, or 0 if not supported
     */
    function expiry(address pytToken) public view returns (uint256) {
        if (!supportedTokens.contains(pytToken)) return 0;
        return IPYieldToken(pytToken).expiry();
    }

    /**
     * @notice Returns the balance of a user for a specific PYT token
     * @param user The user address
     * @param pytToken The PYT token
     * @return The user's balance
     */
    function balanceOf(address user, address pytToken) public view returns (uint256) {
        return balances[pytToken][user];
    }

    /**
     * @notice Returns the total number of supported tokens
     * @return The length of the token list
     */
    function supportedTokenCount() public view returns (uint256) {
        return supportedTokens.length();
    }

    /**
     * @notice Returns a supported token at a given index
     * @param index The index in the token list
     * @return The token address
     */
    function supportedTokenAt(uint256 index) public view returns (address) {
        return supportedTokens.at(index);
    }

    /**
     * @notice Returns all supported tokens
     * @return An array of all supported token addresses
     */
    function getSupportedTokens() public view returns (address[] memory) {
        return supportedTokens.values();
    }

    /**
     * @notice Checks if a token is supported
     * @param pytToken The token to check
     * @return True if supported, false otherwise
     */
    function isSupported(address pytToken) public view returns (bool) {
        return supportedTokens.contains(pytToken);
    }
}
