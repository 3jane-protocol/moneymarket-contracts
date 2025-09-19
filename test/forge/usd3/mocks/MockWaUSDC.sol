// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "../../../../lib/openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockWaUSDC
 * @notice Mock implementation of waUSDC (wrapped aave USDC)
 * @dev ERC4626-like vault with dynamic share pricing for testing USD3 upgrade scenarios
 */
contract MockWaUSDC is ERC20 {
    using Math for uint256;

    // Storage slot 0 for underlying asset (avoiding immutables for etching)
    address private _asset;

    // Share price in 6 decimals (1e6 = 1:1 ratio, 1.1e6 = 1.1:1 ratio)
    uint256 public sharePrice = 1e6;

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
     * @dev Returns the decimals (6, matching USDC)
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @dev Deposit USDC to receive waUSDC shares
     */
    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        shares = previewDeposit(assets);
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        return shares;
    }

    /**
     * @dev Withdraw USDC by burning waUSDC shares
     */
    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
        shares = previewWithdraw(assets);
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
        assets = previewRedeem(shares);
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
    function convertToShares(uint256 assets) public view returns (uint256) {
        // For first deposit, avoid rounding issues while still respecting share price
        if (totalSupply() == 0 && sharePrice == 1e6) {
            return assets; // 1:1 when price is exactly 1.0
        }
        return assets.mulDiv(1e6, sharePrice, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares.mulDiv(sharePrice, 1e6, Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(1e6, sharePrice, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return shares.mulDiv(sharePrice, 1e6, Math.Rounding.Ceil);
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
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    /**
     * @dev Mint function for ERC4626 compatibility
     */
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = previewMint(shares);
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        return assets;
    }

    /**
     * @dev Simulate yield accumulation by increasing share price
     * @param percentIncrease Percentage increase in basis points (100 = 1%)
     */
    function simulateYield(uint256 percentIncrease) external {
        sharePrice = sharePrice.mulDiv(10000 + percentIncrease, 10000, Math.Rounding.Floor);
    }

    /**
     * @dev Set share price directly for testing
     * @param newPrice New share price in 6 decimals
     */
    function setSharePrice(uint256 newPrice) external {
        require(newPrice > 0, "Invalid price");
        sharePrice = newPrice;
    }
}
