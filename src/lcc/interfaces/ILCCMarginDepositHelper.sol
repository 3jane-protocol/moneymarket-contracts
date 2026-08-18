// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

/// @title ILCCMarginDepositHelper
/// @notice Self-service wrapper for depositing USDC, USDT, or their Aave aTokens into matching LCC vaults.
interface ILCCMarginDepositHelper {
    struct DepositParams {
        address vault;
        uint256 amountIn;
        uint256 minMarginShares;
        uint256 minCommitment;
        uint256 maxCommitment;
        bool allowPendingActivation;
        uint256 deadline;
    }

    error ZeroAddress();
    error InvalidStataToken();
    error UnregisteredVault();
    error WrongMarginAsset();
    error MaxDepositExceeded(uint256 amount, uint256 maximum);
    error InsufficientMarginShares(uint256 shares, uint256 minimum);

    function factory() external view returns (address);
    function usdc() external view returns (address);
    function aEthUSDC() external view returns (address);
    function waEthUSDC() external view returns (address);
    function usdt() external view returns (address);
    function aEthUSDT() external view returns (address);
    function waEthUSDT() external view returns (address);

    function depositUSDC(DepositParams calldata params) external returns (uint256 commitment);
    function depositAethUSDC(DepositParams calldata params) external returns (uint256 commitment);
    function depositUSDT(DepositParams calldata params) external returns (uint256 commitment);
    function depositAethUSDT(DepositParams calldata params) external returns (uint256 commitment);
}
