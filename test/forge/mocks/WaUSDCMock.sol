// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";

/// @title WaUSDCMock
/// @notice ERC4626 mock for testing CallableCredit with configurable maxRedeem
/// @dev Simulates waUSDC (Aave wrapped USDC) with controllable liquidity constraints
contract WaUSDCMock is ERC20Mock {
    ERC20Mock public immutable underlying;

    /// @notice Exchange rate: assets per share (scaled by 1e18)
    /// @dev Default 1:1, can be modified to simulate appreciation
    uint256 public exchangeRate = 1e18;

    /// @notice Maximum amount that can be redeemed (simulates Aave liquidity)
    uint256 public maxRedeemAmount = type(uint256).max;

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    constructor(address _underlying) {
        underlying = ERC20Mock(_underlying);
    }

    // ============ ERC4626 View Functions ============

    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() external view returns (uint256) {
        return _convertToAssets(totalSupply);
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares);
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 ownerShares = balanceOf[owner];
        uint256 ownerAssets = _convertToAssets(ownerShares);
        uint256 maxRedeemableAssets = _convertToAssets(maxRedeemAmount);
        return ownerAssets < maxRedeemableAssets ? ownerAssets : maxRedeemableAssets;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        uint256 ownerShares = balanceOf[owner];
        return ownerShares < maxRedeemAmount ? ownerShares : maxRedeemAmount;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return _convertToSharesRoundUp(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares);
    }

    // ============ ERC4626 Mutative Functions ============

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = _convertToShares(assets);
        underlying.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = _convertToAssets(shares);
        underlying.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = _convertToSharesRoundUp(assets);
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner][msg.sender] = allowed - shares;
            }
        }
        _burn(owner, shares);
        underlying.transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner][msg.sender] = allowed - shares;
            }
        }
        assets = _convertToAssets(shares);
        _burn(owner, shares);
        underlying.transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // ============ Test Helper Functions ============

    /// @notice Set the maximum redeemable amount (simulates Aave liquidity constraints)
    function setMaxRedeem(uint256 _maxRedeemAmount) external {
        maxRedeemAmount = _maxRedeemAmount;
    }

    /// @notice Set the exchange rate (simulates waUSDC appreciation)
    /// @param _exchangeRate Assets per share, scaled by 1e18 (e.g., 1.1e18 = 1.1 USDC per waUSDC)
    function setExchangeRate(uint256 _exchangeRate) external {
        exchangeRate = _exchangeRate;
    }

    /// @notice Mint shares directly (for test setup)
    function mintShares(address to, uint256 shares) external {
        _mint(to, shares);
    }

    // ============ Internal Functions ============

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        return (assets * 1e18) / exchangeRate;
    }

    function _convertToSharesRoundUp(uint256 assets) internal view returns (uint256) {
        return (assets * 1e18 + exchangeRate - 1) / exchangeRate;
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return (shares * exchangeRate) / 1e18;
    }

    function _mint(address to, uint256 shares) internal {
        balanceOf[to] += shares;
        totalSupply += shares;
        emit Transfer(address(0), to, shares);
    }

    function _burn(address from, uint256 shares) internal {
        balanceOf[from] -= shares;
        totalSupply -= shares;
        emit Transfer(from, address(0), shares);
    }

    // ============ ERC20 Metadata ============

    function name() external pure returns (string memory) {
        return "Wrapped Aave USDC Mock";
    }

    function symbol() external pure returns (string memory) {
        return "waUSDC";
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}
