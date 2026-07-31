// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.22 <0.9.0;

import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "../../../lib/openzeppelin/contracts/utils/math/SafeCast.sol";

import {ORACLE_PRICE_SCALE, BPS} from "../../libraries/ConstantsLib.sol";
import {IOracle} from "../../interfaces/IOracle.sol";
import {LCCErrorsLib} from "./LCCErrorsLib.sol";

/// @title LCCAuctionLib
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Pricing math and packed fill accounting for the LCC epoch-shortfall auction.
/// @dev The auction sells the right to fill an epoch's funding-asset shortfall (wrapped into USD3 for the buyer)
/// together with a collateral kicker from the slashed margin pool. The protocol's retained share of the pool decays by
/// `stepDecayRateBps` every `stepDuration` seconds, so the offered kicker ramps from zero toward the full pool.
/// The externally linked fill path accepts the caller's auction storage slot and records checked packed counters in
/// the same delegatecall that computes the award.
library LCCAuctionLib {
    using SafeCast for uint256;

    uint256 internal constant RAY = 1e27;

    /// @notice State of an epoch's shortfall auction.
    /// @param shortfallAmount Total shortfall to be filled (fundingAsset).
    /// @param filledAmount Cumulative amount filled so far (fundingAsset).
    /// @param marginPool Slashed margin backing the collateral kicker (marginAsset).
    /// @param marginAwarded Cumulative collateral awarded to fillers (marginAsset).
    struct AuctionState {
        uint128 shortfallAmount;
        uint128 filledAmount;
        uint128 marginPool;
        uint128 marginAwarded;
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

    /// @notice Computes an auction award and records the fill against packed auction storage.
    /// @dev `fillAward` clamps only the award to the unawarded pool; the caller must clamp `fillAmount` to the
    /// remaining shortfall (`shortfallAmount - filledAmount`) or `filledAmount` can exceed `shortfallAmount`,
    /// breaking full-fill settlement. SafeCast keeps both packed counters checked at the storage boundary.
    /// @param state The auction storage updated by the fill.
    /// @param fillAmount Amount of the shortfall being filled (fundingAsset).
    /// @param elapsed Seconds since the auction window opened.
    /// @param stepDuration Seconds per price step.
    /// @param stepDecayRateBps Per-step decay of the protocol's retained share, in bps.
    /// @param maxAwardBps Award cap per fundingAsset filled, in bps.
    /// @param price Margin-to-fundingAsset oracle price, scaled by ORACLE_PRICE_SCALE.
    /// @return award Collateral awarded for this fill (marginAsset).
    function applyFill(
        AuctionState storage state,
        uint256 fillAmount,
        uint256 elapsed,
        uint256 stepDuration,
        uint256 stepDecayRateBps,
        uint256 maxAwardBps,
        uint256 price
    ) public returns (uint256 award) {
        award = computeAward(state, fillAmount, elapsed, stepDuration, stepDecayRateBps, maxAwardBps, price);
        state.filledAmount = (uint256(state.filledAmount) + fillAmount).toUint128();
        state.marginAwarded = (uint256(state.marginAwarded) + award).toUint128();
    }

    /// @notice Resolves the lifecycle phase at an effective timestamp.
    /// @param timestamp Effective timestamp after excluding paused wall-clock time.
    /// @param packedClock The vault's packed `LCCTypesLib.ClockConfig` word, passed by value.
    /// @return The numeric value of the active `ILCCVault.Phase`.
    function phaseAt(uint256 timestamp, uint256 packedClock) public pure returns (uint8) {
        uint256 startTimestamp = uint64(packedClock);
        uint256 epochLength = uint32(packedClock >> 128);
        uint256 normalDuration = uint32(packedClock >> 160);
        uint256 preCallDuration = uint32(packedClock >> 192);
        uint256 fundingDuration = uint32(packedClock >> 224);
        uint256 elapsed = timestamp >= startTimestamp ? (timestamp - startTimestamp) % epochLength : 0;
        if (elapsed < normalDuration) return 0;
        if (elapsed < normalDuration + preCallDuration) return 1;
        if (elapsed < normalDuration + preCallDuration + fundingDuration) return 2;
        return 3;
    }

    /// @notice Resolves an epoch phase's effective-time end boundary.
    /// @param epoch Epoch whose boundary is requested.
    /// @param phase Numeric value of the requested `ILCCVault.Phase`.
    /// @param packedClock The vault's packed `LCCTypesLib.ClockConfig` word, passed by value.
    /// @return effectiveEnd The phase end in effective time, before any live pause offset is restored.
    function phaseEndsAt(uint256 epoch, uint8 phase, uint256 packedClock) public pure returns (uint256 effectiveEnd) {
        uint256 startTimestamp = uint64(packedClock);
        uint256 epochLength = uint32(packedClock >> 128);
        uint256 normalDuration = uint32(packedClock >> 160);
        uint256 preCallDuration = uint32(packedClock >> 192);
        uint256 fundingDuration = uint32(packedClock >> 224);
        uint256 start = startTimestamp + epoch * epochLength;
        if (phase == 0) return start + normalDuration;
        if (phase == 1) return start + normalDuration + preCallDuration;
        if (phase == 2) return start + normalDuration + preCallDuration + fundingDuration;
        return start + epochLength;
    }

    /// @notice Values margin assets in funding-asset units and derives their callable commitment.
    /// @param assets Margin assets to value.
    /// @param price Margin-to-fundingAsset oracle price, scaled by ORACLE_PRICE_SCALE.
    /// @param marginRatioBps Margin ratio used to leverage margin value into commitment, in bps.
    /// @return marginValue Value of the margin assets in fundingAsset units.
    /// @return commitment Callable commitment derived from the margin value.
    function valueAndCommitment(uint256 assets, uint256 price, uint256 marginRatioBps)
        public
        pure
        returns (uint256 marginValue, uint256 commitment)
    {
        marginValue = Math.mulDiv(assets, price, ORACLE_PRICE_SCALE);
        commitment = Math.mulDiv(marginValue, BPS, marginRatioBps);
    }

    /// @dev Matches the exact overflow predicate used by `Math.mulDiv` for both valuation stages.
    function _valuationOverflows(uint256 assets, uint256 price, uint256 marginRatioBps) private pure returns (bool) {
        (uint256 valueProductHigh,) = Math.mul512(assets, price);
        if (ORACLE_PRICE_SCALE <= valueProductHigh) return true;

        uint256 marginValue = Math.mulDiv(assets, price, ORACLE_PRICE_SCALE);
        (uint256 commitmentProductHigh,) = Math.mul512(marginValue, BPS);
        return marginRatioBps <= commitmentProductHigh;
    }

    /// @notice Values a disposed slash surplus into a return pool and returned commitment.
    /// @dev Charges the slash fee on auction-awarded collateral (capped by the surplus), then values the remainder
    /// at the call-open price snapshot. A missing snapshot may consult the live oracle only for an owner-triggered
    /// recovery. Without that permission, going-concern disposal reverts and wind-down disposal drops the pool to
    /// treasury. Wind-down also treats an unreadable, zero, or valuation-overflowing selected price as zero so
    /// recovery can never brick. The returned commitment is clamped by `headroom` and zeroed below
    /// `minReturnCommitment`; a zero commitment also zeroes the pool so the returned pair is always attributable.
    /// A nonzero commitment clamp does not reduce the pool. The saturating headroom above `usedMargin`
    /// independently caps the pool before valuation and keeps packed aggregate margin in range.
    /// @param surplus Unawarded slashed margin being disposed (marginAsset).
    /// @param auctionedMargin Collateral awarded to auction fillers, the fee basis (marginAsset).
    /// @param slashFeeBps Fee on auction-awarded collateral, in bps.
    /// @param marginPriceSnapshot Margin-oracle price frozen when the call opened.
    /// @param marginOracle Live margin oracle used only for an authorized missing-snapshot recovery.
    /// @param allowOracleFallback Whether the caller is authorized to recover a missing snapshot from the live oracle.
    /// @param windDown True once no future call can use returned commitment (shutdown or closed call window).
    /// @param marginRatioBps Margin ratio leveraging margin value into commitment, in bps.
    /// @param usedMargin Active plus pending margin already occupying packed totals.
    /// @param commitmentHeadroom Maximum commitment that may be returned.
    /// @param minReturnCommitment Minimum commitment worth attributing; smaller results are zeroed.
    /// @return returnPool Margin re-attributed to defaulters (marginAsset).
    /// @return returnCommitment Commitment re-attributed to defaulters (fundingAsset).
    function disposeValuation(
        uint256 surplus,
        uint256 auctionedMargin,
        uint256 slashFeeBps,
        uint256 marginPriceSnapshot,
        address marginOracle,
        bool allowOracleFallback,
        bool windDown,
        uint256 marginRatioBps,
        uint256 usedMargin,
        uint256 commitmentHeadroom,
        uint256 minReturnCommitment
    ) public view returns (uint256 returnPool, uint256 returnCommitment) {
        uint256 fee = Math.min(Math.mulDiv(auctionedMargin, slashFeeBps, BPS), surplus);
        returnPool = Math.min(surplus - fee, Math.saturatingSub(type(uint128).max, usedMargin));

        // The oracle is consulted only when there is a return pool to value.
        if (returnPool != 0) {
            uint256 price = marginPriceSnapshot;
            if (price == 0 && allowOracleFallback) {
                if (windDown) {
                    try IOracle(marginOracle).price() returns (uint256 p) {
                        price = p;
                    } catch {}
                } else {
                    price = IOracle(marginOracle).price();
                }
            }

            if (!windDown && price == 0) revert LCCErrorsLib.OraclePriceInvalid();
            // Apply the overflow guard after selecting either the snapshot or fallback price so a pathological
            // stored snapshot cannot break wind-down disposal.
            if (windDown && _valuationOverflows(returnPool, price, marginRatioBps)) price = 0;

            if (price == 0) {
                returnPool = 0;
            } else {
                (, uint256 rawCommitment) = valueAndCommitment(returnPool, price, marginRatioBps);
                returnCommitment = Math.min(rawCommitment, commitmentHeadroom);
                if (returnCommitment < minReturnCommitment) returnCommitment = 0;
                if (returnCommitment == 0) returnPool = 0;
            }
        }

        if (returnPool == 0) returnCommitment = 0;
    }
}
