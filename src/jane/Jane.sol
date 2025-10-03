// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {ERC20, ERC20Permit} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "../../lib/openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {EnumerableSet} from "../../lib/openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IMarkdownController} from "../interfaces/IMarkdownController.sol";

/**
 * @title Jane
 * @notice 3Jane protocol governance and rewards token with controlled transfer capabilities
 */
contract Jane is ERC20, ERC20Permit, ERC20Burnable, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    error TransferNotAllowed();
    error MintFinalized();
    error NotMinter();
    error NotBurner();
    error InvalidAddress();

    event TransferEnabled();
    event MintingFinalized();
    event TransferAuthorized(address indexed account, bool indexed authorized);
    event MinterAuthorized(address indexed account, bool indexed authorized);
    event BurnerAuthorized(address indexed account, bool indexed authorized);
    event MarkdownControllerSet(address indexed controller);

    /// @notice Set of addresses authorized to mint new tokens
    EnumerableSet.AddressSet private _minters;

    /// @notice Set of addresses authorized to burn tokens from any account
    EnumerableSet.AddressSet private _burners;

    /// @notice Set of addresses authorized to transfer when transfers are restricted
    EnumerableSet.AddressSet private _transferAuthorized;

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
     * @param _initialOwner Address that will be the contract owner
     * @param _minter Address that will have minting privileges
     * @param _burner Address that will have burning privileges
     */
    constructor(address _initialOwner, address _minter, address _burner)
        ERC20("JANE", "JANE")
        ERC20Permit("JANE")
        Ownable(_initialOwner)
    {
        if (_minter != address(0)) {
            _minters.add(_minter);
        }
        if (_burner != address(0)) {
            _burners.add(_burner);
        }
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
     * @notice Sets the MarkdownController address
     * @param _controller Address of the MarkdownController contract
     */
    function setMarkdownController(address _controller) external onlyOwner {
        markdownController = _controller;
        emit MarkdownControllerSet(_controller);
    }

    /**
     * @notice Grants transfer role to an account
     * @param account Address to grant transfer role
     */
    function addTransferRole(address account) external onlyOwner {
        if (_transferAuthorized.add(account)) {
            emit TransferAuthorized(account, true);
        }
    }

    /**
     * @notice Revokes transfer role from an account
     * @param account Address to revoke transfer role
     */
    function removeTransferRole(address account) external onlyOwner {
        if (_transferAuthorized.remove(account)) {
            emit TransferAuthorized(account, false);
        }
    }

    /**
     * @notice Grants minter role to an account
     * @param account Address to grant minter role
     */
    function addMinter(address account) external onlyOwner {
        if (_minters.add(account)) {
            emit MinterAuthorized(account, true);
        }
    }

    /**
     * @notice Revokes minter role from an account
     * @param account Address to revoke minter role
     */
    function removeMinter(address account) external onlyOwner {
        if (_minters.remove(account)) {
            emit MinterAuthorized(account, false);
        }
    }

    /**
     * @notice Grants burner role to an account
     * @param account Address to grant burner role
     */
    function addBurner(address account) external onlyOwner {
        if (_burners.add(account)) {
            emit BurnerAuthorized(account, true);
        }
    }

    /**
     * @notice Revokes burner role from an account
     * @param account Address to revoke burner role
     */
    function removeBurner(address account) external onlyOwner {
        if (_burners.remove(account)) {
            emit BurnerAuthorized(account, false);
        }
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
    function mint(address account, uint256 value) external {
        if (!isMinter(_msgSender())) revert NotMinter();
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
    function burn(address account, uint256 value) external {
        if (!isBurner(_msgSender())) revert NotBurner();
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
        if (!transferable && !hasTransferRole(from) && !hasTransferRole(to)) {
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
     * @notice Checks if an account has transfer role
     * @param account Address to check
     * @return True if account has transfer role
     */
    function hasTransferRole(address account) public view returns (bool) {
        return _transferAuthorized.contains(account);
    }

    /**
     * @notice Returns all accounts with transfer role
     * @return Array of addresses with transfer role
     */
    function transferAuthorized() public view returns (address[] memory) {
        return _transferAuthorized.values();
    }

    /**
     * @notice Checks if an account has minter role
     * @param account Address to check
     * @return True if account has minter role
     */
    function isMinter(address account) public view returns (bool) {
        return _minters.contains(account);
    }

    /**
     * @notice Returns all accounts with minter role
     * @return Array of minter addresses
     */
    function minters() public view returns (address[] memory) {
        return _minters.values();
    }

    /**
     * @notice Checks if an account has burner role
     * @param account Address to check
     * @return True if account has burner role
     */
    function isBurner(address account) public view returns (bool) {
        return _burners.contains(account);
    }

    /**
     * @notice Returns all accounts with burner role
     * @return Array of burner addresses
     */
    function burners() public view returns (address[] memory) {
        return _burners.values();
    }
}
