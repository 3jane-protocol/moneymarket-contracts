// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

import {ORACLE_PRICE_SCALE} from "../../libraries/ConstantsLib.sol";

/// @title LCCAuctionLib
/// @notice Stateless pricing math for the LCC epoch-shortfall auction.
/// @dev The auction sells the right to fill an epoch's USDC shortfall (wrapped into USD3 for the buyer) together
/// with a collateral kicker from the slashed margin pool. The protocol's retained share of the pool decays by
/// `stepDecayRateBps` every `stepDuration` seconds, so the offered kicker ramps from zero toward the full pool.
/// Functions take only value types and memory structs so the library can be switched to external linkage if the
/// vault approaches the bytecode size limit.
library LCCAuctionLib {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;

    struct AuctionState {
        uint128 shortfallUsdc;
        uint128 filledUsdc;
        uint256 marginPool;
        uint256 marginAwarded;
    }

    /// @dev Overflow-checked fixed-point exponentiation by squaring (the well-known MakerDAO/Ajna implementation).
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

    /// @notice Collateral award for filling `fillUsdc` of the shortfall while `offered` is on the table.
    /// @dev Pro-rata of the current offer against the ORIGINAL shortfall, capped by the fill-time oracle value and
    /// the unawarded pool. Conservation: each award <= marginPool * fill / shortfall, so total awards never exceed
    /// the pool because total fills never exceed the shortfall; the pool clamp is belt-and-suspenders.
    function fillAward(AuctionState memory state, uint256 fillUsdc, uint256 offered, uint256 oracleCapMargin)
        public
        pure
        returns (uint256 award)
    {
        if (state.shortfallUsdc == 0) return 0;

        award = Math.mulDiv(offered, fillUsdc, state.shortfallUsdc);
        if (award > oracleCapMargin) award = oracleCapMargin;

        uint256 remainingPool = state.marginPool - state.marginAwarded;
        if (award > remainingPool) award = remainingPool;
    }

    /// @notice Full award computation for a fill: the ramped pro-rata kicker, capped by `maxAwardBps` of the fill
    /// valued at `price` (the trusted margin-to-USDC oracle price), clamped to the unawarded pool.
    function computeAward(
        AuctionState memory state,
        uint256 fillUsdc,
        uint256 elapsed,
        uint256 stepDuration,
        uint256 stepDecayRateBps,
        uint256 maxAwardBps,
        uint256 price
    ) public pure returns (uint256) {
        uint256 oracleCapMargin = Math.mulDiv(Math.mulDiv(fillUsdc, maxAwardBps, BPS), ORACLE_PRICE_SCALE, price);
        uint256 offered = offeredPool(state.marginPool, elapsed, stepDuration, stepDecayRateBps);
        return fillAward(state, fillUsdc, offered, oracleCapMargin);
    }
}
