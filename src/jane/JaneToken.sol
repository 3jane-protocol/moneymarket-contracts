// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {ERC20, ERC20Permit} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title JaneToken
 * @notice 3Jane protocol governance and rewards token with controlled transfer capabilities
 * @dev Implements ownership-based access control for minting, burning, and transfer restrictions.
 * Transfer logic:
 * - When transferable = true: Anyone can transfer tokens
 * - When transferable = false: Only addresses with transfer role can be one of the sender or receiver
 */
contract JaneToken is ERC20, ERC20Permit, ERC20Burnable, Ownable {
    error TransferNotAllowed();
    error MintFinalized();
    error NotMinter();
    error NotBurner();
    error InvalidAddress();

    event TransferEnabled();
    event MintingFinalized();
    event TransferRoleUpdated(address indexed account, bool indexed hasRole);

    /// @notice Global transfer toggle - when true, anyone can transfer
    bool public transferable;
    bool public mintFinalized;
    address public immutable minter;
    address public immutable burner;
    mapping(address => bool) public hasTransferRole;

    /**
     * @notice Initializes the JANE token with owner, minter, and burner
     * @param _initialOwner Address that will be the contract owner
     * @param _minter Address that will have minting privileges
     * @param _burner Address that will have burning privileges
     */
    constructor(address _initialOwner, address _minter, address _burner)
        ERC20("JANE", "JANE")
        ERC20Permit("JANE")
        Ownable(_initialOwner)
    {
        minter = _minter;
        burner = _burner;
    }

    /**
     * @notice Enables transfers globally (one-way switch)
     * @dev Once enabled, transfers cannot be disabled again
     */
    function setTransferable() external onlyOwner {
        transferable = true;
        emit TransferEnabled();
    }

    /**
     * @notice Permanently disables minting (one-way switch)
     * @dev Once finalized, no new tokens can ever be minted
     */
    function finalizeMinting() external onlyOwner {
        mintFinalized = true;
        emit MintingFinalized();
    }

    /**
     * @notice Updates transfer role for an account
     * @param account Address to update transfer role for
     * @param hasRole Whether the account should have transfer role
     */
    function setTransferRole(address account, bool hasRole) external onlyOwner {
        hasTransferRole[account] = hasRole;
        emit TransferRoleUpdated(account, hasRole);
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
     * @dev Only callable by the designated minter address and before minting is finalized
     * @param account Address to receive the minted tokens
     * @param value Amount of tokens to mint
     */
    function mint(address account, uint256 value) external {
        if (_msgSender() != minter) revert NotMinter();
        if (mintFinalized) revert MintFinalized();
        if (account == address(0)) revert InvalidAddress();
        _mint(account, value);
    }

    /**
     * @notice Burns tokens from the specified account
     * @dev Only callable by the designated burner address
     * @param account Address from which to burn tokens
     * @param value Amount of tokens to burn
     */
    function burn(address account, uint256 value) external {
        if (_msgSender() != burner) revert NotBurner();
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
        return transferable || hasTransferRole[from] || hasTransferRole[to];
    }
}
