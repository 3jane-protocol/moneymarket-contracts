// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "../../../../lib/openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockWaUSDC
 * @notice Mock implementation of waUSDC (wrapped aave USDC)
 * @dev Simple ERC4626-like vault that wraps USDC for testing USD3 strategy
 */
contract MockWaUSDC is ERC20 {
    using Math for uint256;

    // Storage slot 0 for underlying asset (avoiding immutables for etching)
    address private _asset;

    constructor(address _usdc) ERC20("Wrapped Aave USDC", "waUSDC") {
        _asset = _usdc;
    }

    /**
     * @dev Returns the underlying asset (USDC)
     */
    function asset() public view returns (address) {
        return _asset;
    }

    /**
     * @dev Deposit USDC to receive waUSDC shares
     */
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = assets; // 1:1 for simplicity
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        return shares;
    }

    /**
     * @dev Withdraw USDC by burning waUSDC shares
     */
    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
        shares = assets; // 1:1 for simplicity
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }
        _burn(owner, shares);
        IERC20(_asset).transfer(receiver, assets);
        return shares;
    }

    /**
     * @dev Redeem waUSDC shares for USDC
     */
    function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets) {
        assets = shares; // 1:1 for simplicity
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }
        _burn(owner, shares);
        IERC20(_asset).transfer(receiver, assets);
        return assets;
    }

    /**
     * @dev Preview functions for ERC4626 compatibility
     */
    function convertToShares(uint256 assets) public pure returns (uint256) {
        return assets; // 1:1 conversion
    }

    function convertToAssets(uint256 shares) public pure returns (uint256) {
        return shares; // 1:1 conversion
    }

    function previewDeposit(uint256 assets) public pure returns (uint256) {
        return assets;
    }

    function previewWithdraw(uint256 assets) public pure returns (uint256) {
        return assets;
    }

    function previewRedeem(uint256 shares) public pure returns (uint256) {
        return shares;
    }

    /**
     * @dev Returns the total amount of underlying USDC held by the vault
     */
    function totalAssets() public view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }

    /**
     * @dev Max deposit/mint/withdraw/redeem functions
     */
    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    /**
     * @dev Mint function for ERC4626 compatibility
     */
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = shares; // 1:1 for simplicity
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        return assets;
    }
}
