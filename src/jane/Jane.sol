// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20, ERC20Permit} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControlEnumerable} from "../../lib/openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/**
 * @title Jane
 * @notice 3Jane protocol governance and rewards token with controlled transfer capabilities
 */
contract Jane is ERC20, ERC20Permit, AccessControlEnumerable {
    error TransferNotAllowed();
    error InvalidAddress();

    event TransferEnabled();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Role identifier for the owner (can manage all roles and contract parameters)
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @notice Role identifier for minters (can mint new tokens before minting is finalized)
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role identifier for transfer-enabled accounts (can transfer when transfers are disabled)
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    /// @notice Whether transfers are globally enabled for all users
    /// @dev When true, anyone can transfer. When false, only addresses with transfer role can participate in transfers
    bool public transferable;

    /**
     * @notice Initializes the JANE token with its owner
     * @param _initialOwner Address that will be the contract owner
     */
    constructor(address _initialOwner) ERC20("JANE", "JANE") ERC20Permit("JANE") {
        if (_initialOwner == address(0)) revert InvalidAddress();
        _grantRole(OWNER_ROLE, _initialOwner);
        _setRoleAdmin(MINTER_ROLE, OWNER_ROLE);
        _setRoleAdmin(TRANSFER_ROLE, OWNER_ROLE);
    }

    /**
     * @notice Enables transfers globally (one-way switch)
     * @dev Once enabled, transfers cannot be disabled again
     */
    function setTransferable() external onlyRole(OWNER_ROLE) {
        transferable = true;
        emit TransferEnabled();
    }

    /**
     * @notice Renounces the ability to grant MINTER_ROLE (one-way operation)
     * @dev Sets MINTER_ROLE admin to 0 (which no one has)
     * Existing minters can still mint until they individually renounce
     * After this, no new minters can ever be granted
     */
    function renounceMintAdmin() external onlyRole(OWNER_ROLE) {
        _setRoleAdmin(MINTER_ROLE, bytes32(0));
    }

    /**
     * @notice Transfers ownership to a new address atomically
     * @dev Only callable by current owner. Ensures exactly one owner at all times.
     * @param newOwner Address that will become the new owner
     */
    function transferOwnership(address newOwner) external onlyRole(OWNER_ROLE) {
        if (newOwner == address(0)) revert InvalidAddress();
        address previousOwner = _msgSender();
        _revokeRole(OWNER_ROLE, previousOwner);
        _grantRole(OWNER_ROLE, newOwner);
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /**
     * @inheritdoc ERC20
     * @dev Adds transfer restrictions based on transferable status and transfer roles
     */
    function transfer(address to, uint256 value) public override returns (bool) {
        if (!_canTransfer(_msgSender(), to)) revert TransferNotAllowed();
        return super.transfer(to, value);
    }

    /**
     * @inheritdoc ERC20
     * @dev Adds transfer restrictions based on transferable status and transfer roles
     */
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (!_canTransfer(from, to)) revert TransferNotAllowed();
        return super.transferFrom(from, to, value);
    }

    /**
     * @notice Mints new tokens to the specified account
     * @dev Only callable by accounts with minter role and before minting is finalized
     * @param account Address to receive the minted tokens
     * @param value Amount of tokens to mint
     */
    function mint(address account, uint256 value) external onlyRole(MINTER_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        _mint(account, value);
    }

    /// @notice Burns `value` tokens from the caller's balance
    /// @dev Not gated by `transferable` or `TRANSFER_ROLE`; a holder may always burn their own tokens
    function burn(uint256 value) external {
        _burn(_msgSender(), value);
    }

    /**
     * @notice Checks if a transfer is allowed based on current restrictions
     * @dev Internal helper function for transfer validation
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @return bool True if transfers are globally enabled or either party holds the transfer role
     */
    function _canTransfer(address from, address to) internal view returns (bool) {
        return transferable || hasRole(TRANSFER_ROLE, from) || hasRole(TRANSFER_ROLE, to);
    }

    /**
     * @notice Returns the current owner address
     * @return The owner address, or address(0) if no owner exists
     */
    function owner() public view returns (address) {
        uint256 count = getRoleMemberCount(OWNER_ROLE);
        return count > 0 ? getRoleMember(OWNER_ROLE, 0) : address(0);
    }
}
