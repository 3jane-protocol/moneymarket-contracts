// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20, ERC20Permit} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControlEnumerable} from "../../lib/openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IMarkdownController} from "../interfaces/IMarkdownController.sol";

/**
 * @title Jane
 * @notice 3Jane protocol governance and rewards token with controlled transfer capabilities
 */
contract Jane is ERC20, ERC20Permit, AccessControlEnumerable {
    error TransferNotAllowed();
    error InvalidAddress();
    error Unauthorized();

    event TransferEnabled();
    event MarkdownControllerSet(address indexed controller);
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

    /// @notice MarkdownController that manages transfer freezes for delinquent borrowers
    address public markdownController;

    /// @notice Address that will receive redistributed tokens
    address public distributor;

    /**
     * @notice Initializes the JANE token with owner and distributor
     * @param _initialOwner Address that will be the contract owner
     * @param _distributor Address that will receive redistributed tokens from defaulted borrowers
     */
    constructor(address _initialOwner, address _distributor) ERC20("Jane", "JANE") ERC20Permit("JANE") {
        if (_initialOwner == address(0)) revert InvalidAddress();
        _grantRole(OWNER_ROLE, _initialOwner);
        _setRoleAdmin(MINTER_ROLE, OWNER_ROLE);
        _setRoleAdmin(TRANSFER_ROLE, OWNER_ROLE);
        distributor = _distributor;
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
     * @notice Sets the MarkdownController address
     * @param _controller Address of the MarkdownController contract
     */
    function setMarkdownController(address _controller) external onlyRole(OWNER_ROLE) {
        markdownController = _controller;
        emit MarkdownControllerSet(_controller);
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

    /**
     * @notice Redistributes JANE from defaulted borrower to distributor
     * @dev Only callable by MarkdownController during default/settlement
     * @param borrower Address of the defaulted borrower
     * @param amount Amount of tokens to redistribute
     */
    function redistributeFromBorrower(address borrower, uint256 amount) external {
        if (msg.sender != markdownController) revert Unauthorized();
        if (borrower == address(0) || distributor == address(0)) revert InvalidAddress();
        _transfer(borrower, distributor, amount);
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
     * @notice Returns the current owner address
     * @return The owner address, or address(0) if no owner exists
     */
    function owner() public view returns (address) {
        uint256 count = getRoleMemberCount(OWNER_ROLE);
        return count > 0 ? getRoleMember(OWNER_ROLE, 0) : address(0);
    }
}
