// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20, ERC20Permit} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {
    AccessControl,
    AccessControlEnumerable
} from "../../lib/openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "../../lib/openzeppelin/contracts/access/IAccessControl.sol";
import {ITransferController} from "../interfaces/ITransferController.sol";

/**
 * @title Jane
 * @notice 3Jane protocol governance and rewards token with controlled transfer capabilities
 * @dev An optional owner-set transfer controller is consulted on `transfer` and `transferFrom` only: `canTransfer`
 * before balances change and `didTransfer` after. It is additive to the `transferable` / `TRANSFER_ROLE` gate, so
 * both must allow a transfer and `TRANSFER_ROLE` does not bypass the controller. `mint` and `burn` bypass the
 * controller, and `permit` does not consult it. The controller is trusted; a revert in either hook reverts the
 * transfer. The controller hooks live in `transfer` and `transferFrom` only, so any function that moves balances
 * through `_transfer` or `_update` must call the same hooks explicitly to stay under the controller.
 */
contract Jane is ERC20, ERC20Permit, AccessControlEnumerable {
    error TransferNotAllowed();
    error InvalidAddress();
    error ControllerStillSet();

    event TransferEnabled();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TransferControllerSet(address indexed controller);

    /// @notice Role identifier for the owner (can manage all roles and contract parameters)
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @notice Role identifier for minters (can mint new tokens before minting is finalized)
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role identifier for transfer-enabled accounts (can transfer when transfers are disabled)
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    /// @notice Whether transfers are globally enabled for all users
    /// @dev When true, anyone can transfer. When false, only addresses with transfer role can participate in transfers
    bool public transferable;

    /// @notice External transfer policy consulted on `transfer` and `transferFrom`; address(0) when disabled
    address public transferController;

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
     * @notice Sets the transfer controller consulted on `transfer` and `transferFrom`
     * @param controller Controller address, or address(0) to disable
     */
    function setTransferController(address controller) external onlyRole(OWNER_ROLE) {
        transferController = controller;
        emit TransferControllerSet(controller);
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
     * @inheritdoc AccessControl
     * @dev Reverts with `ControllerStillSet` when an OWNER_ROLE holder renounces OWNER_ROLE while a transfer
     * controller is set, which guarantees that an OWNER_ROLE holder continues to exist while a controller is set.
     * Other calls fall through to the inherited checks. Transferring ownership to an address that cannot operate the
     * token is the owner's responsibility, as with every other owner-gated function.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public override(AccessControl, IAccessControl) {
        if (
            role == OWNER_ROLE && transferController != address(0) && callerConfirmation == _msgSender()
                && hasRole(OWNER_ROLE, callerConfirmation)
        ) revert ControllerStillSet();
        super.renounceRole(role, callerConfirmation);
    }

    /**
     * @inheritdoc ERC20
     * @dev Adds transfer restrictions based on transferable status, transfer roles and the transfer controller
     */
    function transfer(address to, uint256 value) public override returns (bool) {
        address controller = transferController;
        address from = _msgSender();
        if (!_canTransfer(controller, from, to, value)) revert TransferNotAllowed();
        bool success = super.transfer(to, value);
        _afterTransfer(controller, from, to, value);
        return success;
    }

    /**
     * @inheritdoc ERC20
     * @dev Adds transfer restrictions based on transferable status, transfer roles and the transfer controller.
     * The controller receives the token owner `from`, not the spender.
     */
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        address controller = transferController;
        if (!_canTransfer(controller, from, to, value)) revert TransferNotAllowed();
        bool success = super.transferFrom(from, to, value);
        _afterTransfer(controller, from, to, value);
        return success;
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
    /// @dev Not gated by `transferable`, `TRANSFER_ROLE` or the transfer controller; a holder may always burn their
    /// own tokens
    function burn(uint256 value) external {
        _burn(_msgSender(), value);
    }

    /**
     * @notice Checks if a transfer is allowed based on current restrictions
     * @dev The role gate is evaluated first; the controller is consulted only when the role gate passes
     * @param controller Transfer controller, or address(0) when disabled
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @param amount Amount being transferred
     * @return bool True if transfers are globally enabled or either party holds the transfer role, and the
     * controller is unset or allows the transfer
     */
    function _canTransfer(address controller, address from, address to, uint256 amount) internal view returns (bool) {
        if (!transferable && !hasRole(TRANSFER_ROLE, from) && !hasRole(TRANSFER_ROLE, to)) return false;
        return controller == address(0) || ITransferController(controller).canTransfer(from, to, amount);
    }

    /**
     * @notice Notifies the transfer controller after balances have changed
     * @param controller Transfer controller, or address(0) when disabled
     * @param from Address that sent tokens
     * @param to Address that received tokens
     * @param amount Amount transferred
     */
    function _afterTransfer(address controller, address from, address to, uint256 amount) internal {
        if (controller != address(0)) ITransferController(controller).didTransfer(from, to, amount);
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
