// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.18;

import {IAaveMarket, ReserveDataLegacy} from "../../../src/irm/adaptive-curve-irm/interfaces/IAaveMarket.sol";

/// @notice Mock Aave pool for testing AdaptiveCurveIrm
contract AavePoolMock is IAaveMarket {
    mapping(address => ReserveDataLegacy) public reserveData;

    function setReserveData(
        address asset,
        uint128 liquidityIndex,
        uint128 currentLiquidityRate,
        uint128 variableBorrowIndex,
        uint128 currentVariableBorrowRate
    ) external {
        ReserveDataLegacy storage data = reserveData[asset];
        data.liquidityIndex = liquidityIndex;
        data.currentLiquidityRate = currentLiquidityRate;
        data.variableBorrowIndex = variableBorrowIndex;
        data.currentVariableBorrowRate = currentVariableBorrowRate;
        data.lastUpdateTimestamp = uint40(block.timestamp);
    }

    function getReserveData(address asset) external view override returns (ReserveDataLegacy memory) {
        ReserveDataLegacy memory data = reserveData[asset];
        // If not initialized, return default values that won't cause issues
        if (data.liquidityIndex == 0) {
            data.liquidityIndex = 1e27; // RAY
            data.variableBorrowIndex = 1e27; // RAY
            data.currentLiquidityRate = 0;
            data.currentVariableBorrowRate = 0;
        }
        return data;
    }

    function getReserveNormalizedIncome(address asset) external view override returns (uint256) {
        ReserveDataLegacy memory data = reserveData[asset];
        // Return the liquidity index as the normalized income
        return data.liquidityIndex == 0 ? 1e27 : uint256(data.liquidityIndex);
    }

    function getReserveNormalizedVariableDebt(address asset) external view override returns (uint256) {
        ReserveDataLegacy memory data = reserveData[asset];
        // Return the variable borrow index as the normalized debt
        return data.variableBorrowIndex == 0 ? 1e27 : uint256(data.variableBorrowIndex);
    }
}
