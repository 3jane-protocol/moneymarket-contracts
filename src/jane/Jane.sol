// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20, ERC20Permit} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControlEnumerable} from "../../lib/openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IMarkdownController} from "../interfaces/IMarkdownController.sol";

/**
 * @title Jane
 * @notice 3Jane protocol governance and rewards token with controlled transfer capabilities
 */
contract Jane is ERC20, ERC20Permit, ERC20Burnable, AccessControlEnumerable {
    error TransferNotAllowed();
    error MintFinalized();
    error InvalidAddress();

    event TransferEnabled();
    event MintingFinalized();
    event MarkdownControllerSet(address indexed controller);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    /// @notice Whether transfers are globally enabled for all users
    /// @dev When true, anyone can transfer. When false, only addresses with transfer role can participate in transfers
    bool public transferable;

    /// @notice Whether minting has been permanently disabled
    /// @dev Once set to true, no new tokens can ever be minted
    bool public mintFinalized;

    /// @notice MarkdownController that manages transfer freezes for delinquent borrowers
    address public markdownController;

    /**
     * @notice Initializes the JANE token with owner, minter, and burner
     * @param _initialAdmin Address that will be the contract admin
     * @param _minter Address that will have minting privileges
     * @param _burner Address that will have burning privileges
     */
    constructor(address _initialAdmin, address _minter, address _burner) ERC20("JANE", "JANE") ERC20Permit("JANE") {
        if (_initialAdmin == address(0)) revert InvalidAddress();
        _grantRole(ADMIN_ROLE, _initialAdmin);
        _setRoleAdmin(MINTER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(BURNER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(TRANSFER_ROLE, ADMIN_ROLE);
        if (_minter != address(0)) {
            _grantRole(MINTER_ROLE, _minter);
        }
        if (_burner != address(0)) {
            _grantRole(BURNER_ROLE, _burner);
        }
    }

    /**
     * @notice Enables transfers globally (one-way switch)
     * @dev Once enabled, transfers cannot be disabled again
     */
    function setTransferable() external onlyRole(ADMIN_ROLE) {
        transferable = true;
        emit TransferEnabled();
    }

    /**
     * @notice Permanently disables minting (one-way switch)
     * @dev Once finalized, no new tokens can ever be minted
     */
    function finalizeMinting() external onlyRole(ADMIN_ROLE) {
        mintFinalized = true;
        emit MintingFinalized();
    }

    /**
     * @notice Sets the MarkdownController address
     * @param _controller Address of the MarkdownController contract
     */
    function setMarkdownController(address _controller) external onlyRole(ADMIN_ROLE) {
        markdownController = _controller;
        emit MarkdownControllerSet(_controller);
    }

    /**
     * @notice Transfers admin role to a new address atomically
     * @dev Only callable by current admin. Ensures exactly one admin at all times.
     * @param newAdmin Address that will become the new admin
     */
    function transferAdmin(address newAdmin) external onlyRole(ADMIN_ROLE) {
        if (newAdmin == address(0)) revert InvalidAddress();
        address previousAdmin = _msgSender();
        _revokeRole(ADMIN_ROLE, previousAdmin);
        _grantRole(ADMIN_ROLE, newAdmin);
        emit AdminTransferred(previousAdmin, newAdmin);
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
        if (mintFinalized) revert MintFinalized();
        if (account == address(0)) revert InvalidAddress();
        _mint(account, value);
    }

    /**
     * @notice Burns tokens from the specified account
     * @dev Only callable by accounts with burner role
     * @param account Address from which to burn tokens
     * @param value Amount of tokens to burn
     */
    function burn(address account, uint256 value) external onlyRole(BURNER_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        _burn(account, value);
    }

    /**
     * @notice Checks if a transfer is allowed based on current restrictions
     * @dev Internal helper function for transfer validation
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @return bool True if the transfer is allowed
     */
    function _canTransfer(address from, address to) internal view returns (bool) {
        // First check if transfers are even allowed (cheap checks)
        if (!transferable && !hasRole(TRANSFER_ROLE, from) && !hasRole(TRANSFER_ROLE, to)) {
            return false;
        }

        // Only if transfers would be allowed, check the expensive freeze status
        address _markdownController = markdownController;
        if (_markdownController != address(0)) {
            return !IMarkdownController(_markdownController).isFrozen(from);
        }

        return true;
    }

    /**
     * @notice Returns the current admin address
     * @return The admin address, or address(0) if no admin exists
     */
    function admin() public view returns (address) {
        uint256 count = getRoleMemberCount(ADMIN_ROLE);
        return count > 0 ? getRoleMember(ADMIN_ROLE, 0) : address(0);
    }
}
