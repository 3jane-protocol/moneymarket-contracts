// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC4626, ERC20, IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "../../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title MockATokenVault
 * @notice Mock implementation of an Aave ATokenVault that wraps aUSDC
 * @dev Simulates yield accrual over time for testing purposes
 */
contract MockATokenVault is ERC4626 {
    using Math for uint256;

    uint256 public lastUpdate;
    uint256 public constant YIELD_RATE = 3e16; // 3% APY (simplified)

    constructor(
        IERC20 _asset
    ) ERC4626(_asset) ERC20("Mock Aave USDC Vault", "maUSDC") {
        lastUpdate = block.timestamp;
    }

    /**
     * @dev Simulates yield accrual over time
     * @return assets The total amount of underlying assets held by the vault
     */
    function totalAssets() public view virtual override returns (uint256) {
        // For testing simplicity, don't automatically accrue yield
        // Tests can explicitly add yield by airdropping tokens
        return super.totalAssets();
    }

    /**
     * @dev Override to update lastUpdate on deposits
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        _updateYield();
        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Override to update lastUpdate on withdrawals
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        _updateYield();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Updates the last update timestamp
     */
    function _updateYield() internal {
        lastUpdate = block.timestamp;
    }

    /**
     * @dev Allows manual yield simulation for testing
     * @param yieldAmount Amount of yield to add to the vault
     */
    function simulateYield(uint256 yieldAmount) external {
        // For testing, we expect the test to airdrop tokens to simulate yield
        lastUpdate = block.timestamp;
    }
}
