// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {MathLib, WAD} from "./MathLib.sol";

/// @title AaveRebateMathLib
/// @notice Helpers for computing borrower rebates from Aave index growth above a fixed APR baseline.
library AaveRebateMathLib {
    using MathLib for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Convert APR basis points to a WAD-scaled per-second rate.
    function aprBpsToRatePerSecond(uint256 aprBps) internal pure returns (uint256) {
        return (aprBps * WAD) / 10_000 / SECONDS_PER_YEAR;
    }

    /// @notice Compute growth from Aave normalized index values.
    /// @dev Aave indices are RAY-scaled, but index ratio division returns WAD growth.
    function indexGrowth(uint256 startIndex, uint256 endIndex) internal pure returns (uint256) {
        if (startIndex == 0 || endIndex <= startIndex) return 0;

        uint256 growthFactor = endIndex.wDivDown(startIndex);
        return growthFactor > WAD ? growthFactor - WAD : 0;
    }

    /// @notice Compute the interval rebate in the same base units as `debtAssets`.
    /// @dev The baseline uses this repo's Taylor-compounded continuous-rate approximation, not Aave's binomial formula.
    function intervalRebate(
        uint256 debtAssets,
        uint256 startIndex,
        uint256 endIndex,
        uint256 elapsed,
        uint256 baselineAprBps
    ) internal pure returns (uint256) {
        if (debtAssets == 0 || elapsed == 0) return 0;

        uint256 actualGrowth = indexGrowth(startIndex, endIndex);
        uint256 baselineGrowth = aprBpsToRatePerSecond(baselineAprBps).wTaylorCompounded(elapsed);

        if (actualGrowth <= baselineGrowth) return 0;
        return debtAssets.wMulDown(actualGrowth - baselineGrowth);
    }

    /// @notice Compute the interval rebate using arithmetic mean debt exposure.
    function intervalRebateWithAverageDebt(
        uint256 startDebtAssets,
        uint256 endDebtAssets,
        uint256 startIndex,
        uint256 endIndex,
        uint256 elapsed,
        uint256 baselineAprBps
    ) internal pure returns (uint256) {
        uint256 averageDebtAssets = (startDebtAssets / 2) + (endDebtAssets / 2)
            + ((startDebtAssets % 2 + endDebtAssets % 2) / 2);
        return intervalRebate(averageDebtAssets, startIndex, endIndex, elapsed, baselineAprBps);
    }
}
