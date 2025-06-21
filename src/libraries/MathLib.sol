// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

uint256 constant WAD = 1e18;

/// @title MathLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Library to manage fixed-point arithmetic.
library MathLib {
    /// @dev Returns (`x` * `y`) / `WAD` rounded down.
    function wMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    /// @dev Returns (`x` * `WAD`) / `y` rounded down.
    function wDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y);
    }

    /// @dev Returns (`x` * `WAD`) / `y` rounded up.
    function wDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }

    /// @dev Returns (`x` * `y`) / `d` rounded down.
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    /// @dev Returns (`x` * `y`) / `d` rounded up.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }

    /// @dev Returns the sum of the first three non-zero terms of a Taylor expansion of e^(nx) - 1, to approximate a
    /// continuous compound interest rate.
    function wTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        uint256 firstTerm = x * n;
        uint256 secondTerm = mulDivDown(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = mulDivDown(secondTerm, firstTerm, 3 * WAD);

        return firstTerm + secondTerm + thirdTerm;
    }

    /// @dev Computes the inverse of wTaylorCompounded, finding the rate that produces the given growth factor.
    /// Uses a 3-term Taylor series approximation of ln(x) to solve for rate in the compound interest formula.
    /// Formula: rate = ln(x) / n ≈ [(x-1) - (x-1)²/2 + (x-1)³/3] / n
    ///
    /// Accuracy notes:
    /// - The Taylor approximation of ln(x) is most accurate for x close to 1
    /// - At growth factor x = 1.69*WAD (69% growth), approximation error < 2%
    /// - At growth factor x = 2*WAD (100% growth, where ln(2) ≈ 0.69), approximation error < 5%
    /// - Accuracy decreases for larger growth factors; not recommended for x > 2.5*WAD (150% growth)
    ///
    /// Example: If debt grew from 1000 to 1105 over 1 year (10.5% growth):
    /// - x = 1.105*WAD (growth factor)
    /// - n = 365 days (time period)
    /// - Returns ~10% APR as rate per second
    ///
    /// @param x The growth factor scaled by WAD (e.g., 1.1*WAD for 10% growth). Must be >= WAD.
    /// @param n The time period over which the growth occurred (in seconds)
    /// @return The continuously compounded rate per second that would produce this growth (scaled by WAD)
    function wInverseTaylorCompounded(uint256 x, uint256 n) internal pure returns (uint256) {
        require(x >= WAD, "ln undefined");

        uint256 firstTerm = x - WAD;
        uint256 secondTerm = wMulDown(firstTerm, firstTerm);
        uint256 thirdTerm = wMulDown(secondTerm, firstTerm);

        uint256 series = firstTerm - secondTerm / 2 + thirdTerm / 3;

        return series / n;
    }
}
