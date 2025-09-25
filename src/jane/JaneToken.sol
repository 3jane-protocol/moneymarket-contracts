// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "../../lib/openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title JaneToken
 * @notice 3Jane protocol governance and rewards token with controlled transfer capabilities
 * @dev Implements role-based access control for minting, burning, and transfer restrictions.
 * Transfer logic:
 * - When transferable = true: Anyone can transfer tokens
 * - When transferable = false: Only addresses with TRANSFER_ROLE can send, or addresses with TRANSFER_TO_ROLE can
 * receive
 */
contract JaneToken is ERC20, AccessControl {
    error TransferNotAllowed();
    error InvalidAddress();

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    event TransferableStatusChanged(bool indexed newStatus);

    /// @notice Global transfer toggle - when true, anyone can transfer
    bool public transferable;

    /**
     * @notice Initializes the JANE token with an initial admin
     * @param _initialAdmin Address that will receive the DEFAULT_ADMIN_ROLE
     */
    constructor(address _initialAdmin) ERC20("3Jane", "JANE") {
        if (_initialAdmin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
    }

    /**
     * @notice Updates the global transferable status
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE
     * @param _transferable New transferable status
     */
    function setTransferable(bool _transferable) external onlyRole(DEFAULT_ADMIN_ROLE) {
        transferable = _transferable;
        emit TransferableStatusChanged(_transferable);
    }

    /**
     * @inheritdoc ERC20
     * @dev Adds transfer restrictions based on transferable status and roles
     */
    function transfer(address to, uint256 value) public override returns (bool) {
        if (!_canTransfer(_msgSender(), to)) revert TransferNotAllowed();
        return super.transfer(to, value);
    }

    /**
     * @inheritdoc ERC20
     * @dev Adds transfer restrictions based on transferable status and roles
     */
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (!_canTransfer(from, to)) revert TransferNotAllowed();
        return super.transferFrom(from, to, value);
    }

    /**
     * @notice Mints new tokens to the specified account
     * @dev Only callable by addresses with MINTER_ROLE
     * @param account Address to receive the minted tokens
     * @param value Amount of tokens to mint
     */
    function mint(address account, uint256 value) external onlyRole(MINTER_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        _mint(account, value);
    }

    /**
     * @notice Burns tokens from the specified account
     * @dev Only callable by addresses with BURNER_ROLE
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
        return transferable || hasRole(TRANSFER_ROLE, from) || hasRole(TRANSFER_ROLE, to);
    }
}
