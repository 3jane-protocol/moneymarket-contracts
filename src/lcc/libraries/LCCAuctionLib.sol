// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

import {ORACLE_PRICE_SCALE, BPS} from "../../libraries/ConstantsLib.sol";

/// @title LCCAuctionLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Stateless pricing math for the LCC epoch-shortfall auction.
/// @dev The auction sells the right to fill an epoch's funding-asset shortfall (wrapped into USD3 for the buyer)
/// together with a collateral kicker from the slashed margin pool. The protocol's retained share of the pool decays by
/// `stepDecayRateBps` every `stepDuration` seconds, so the offered kicker ramps from zero toward the full pool.
/// Functions take only value types and memory structs so the library can be switched to external linkage if the
/// vault approaches the bytecode size limit.
library LCCAuctionLib {
    uint256 internal constant RAY = 1e27;

    /// @notice State of an epoch's shortfall auction.
    /// @param shortfallAmount Total shortfall to be filled (fundingAsset).
    /// @param filledAmount Cumulative amount filled so far (fundingAsset).
    /// @param marginPool Slashed margin backing the collateral kicker (marginAsset).
    /// @param marginAwarded Cumulative collateral awarded to fillers (marginAsset).
    struct AuctionState {
        uint128 shortfallAmount;
        uint128 filledAmount;
        uint256 marginPool;
        uint256 marginAwarded;
    }

    /// @notice Computes `x**n` in fixed-point with `base` scaling.
    /// @dev Overflow-checked fixed-point exponentiation by squaring (the well-known MakerDAO/Ajna implementation).
    /// @param x The base, scaled by `base`.
    /// @param n The integer exponent.
    /// @param base The fixed-point scaling factor (e.g. RAY).
    /// @return z `x**n`, scaled by `base`.
    function rpow(uint256 x, uint256 n, uint256 base) public pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := base }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := base }
                default { z := x }
                let half := div(base, 2)
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, base)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    /// @notice Collateral offered to fillers at `elapsed` seconds into the auction window.
    /// @dev offered = pool * (1 - (1 - stepDecayRateBps/BPS)^(elapsed/stepDuration)): zero before the first step
    /// completes, monotonically nondecreasing in elapsed, never exceeds `marginPool`.
    /// @param marginPool Total slashed margin backing the auction (marginAsset).
    /// @param elapsed Seconds since the auction window opened.
    /// @param stepDuration Seconds per price step.
    /// @param stepDecayRateBps Per-step decay of the protocol's retained share, in bps.
    /// @return The collateral currently offered (marginAsset).
    function offeredPool(uint256 marginPool, uint256 elapsed, uint256 stepDuration, uint256 stepDecayRateBps)
        public
        pure
        returns (uint256)
    {
        if (marginPool == 0) return 0;

        uint256 steps = elapsed / stepDuration;
        if (steps == 0) return 0;

        uint256 rayMultiplier = RAY - stepDecayRateBps * 1e23;
        uint256 retained = rpow(rayMultiplier, steps, RAY);
        return marginPool - Math.mulDiv(marginPool, retained, RAY);
    }

    /// @notice Collateral award for filling `fillAmount` of the shortfall while `offered` is on the table.
    /// @dev Pro-rata of the current offer against the ORIGINAL shortfall, capped by the fill-time oracle value and
    /// the unawarded pool. Conservation: each award <= marginPool * fill / shortfall, so total awards never exceed
    /// the pool because total fills never exceed the shortfall; the pool clamp is belt-and-suspenders.
    /// @param state The auction state.
    /// @param fillAmount Amount of the shortfall being filled (fundingAsset).
    /// @param offered Collateral currently offered (marginAsset), from `offeredPool`.
    /// @param oracleCapMargin Oracle-valued award cap for this fill (marginAsset).
    /// @return award Collateral awarded for this fill (marginAsset).
    function fillAward(AuctionState memory state, uint256 fillAmount, uint256 offered, uint256 oracleCapMargin)
        public
        pure
        returns (uint256 award)
    {
        if (state.shortfallAmount == 0) return 0;

        award = Math.mulDiv(offered, fillAmount, state.shortfallAmount);
        if (award > oracleCapMargin) award = oracleCapMargin;

        uint256 remainingPool = state.marginPool - state.marginAwarded;
        if (award > remainingPool) award = remainingPool;
    }

    /// @notice Full award computation for a fill: the ramped pro-rata kicker, capped by `maxAwardBps` of the fill
    /// valued at `price` (the trusted margin-to-fundingAsset oracle price), clamped to the unawarded pool.
    /// @param state The auction state.
    /// @param fillAmount Amount of the shortfall being filled (fundingAsset).
    /// @param elapsed Seconds since the auction window opened.
    /// @param stepDuration Seconds per price step.
    /// @param stepDecayRateBps Per-step decay of the protocol's retained share, in bps.
    /// @param maxAwardBps Award cap per fundingAsset filled, in bps.
    /// @param price Margin-to-fundingAsset oracle price, scaled by ORACLE_PRICE_SCALE.
    /// @return Collateral awarded for this fill (marginAsset).
    function computeAward(
        AuctionState memory state,
        uint256 fillAmount,
        uint256 elapsed,
        uint256 stepDuration,
        uint256 stepDecayRateBps,
        uint256 maxAwardBps,
        uint256 price
    ) public pure returns (uint256) {
        uint256 oracleCapMargin = Math.mulDiv(Math.mulDiv(fillAmount, maxAwardBps, BPS), ORACLE_PRICE_SCALE, price);
        uint256 offered = offeredPool(state.marginPool, elapsed, stepDuration, stepDecayRateBps);
        return fillAward(state, fillAmount, offered, oracleCapMargin);
    }
}
