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
/// together with a collateral kicker from the slashed margin pool. The protocol's retained share of the award reserve
/// decays by `stepDecayRateBps` every `stepDuration` seconds, so the offered kicker ramps from zero toward the maximum
/// award that leaves the configured treasury take reserved.
/// The externally linked fill path accepts the caller's auction storage slot and records checked packed counters in
/// the same delegatecall that computes the award.
library LCCAuctionLib {
    using SafeCast for uint256;

    uint256 internal constant RAY = 1e27;
    /// @dev One whole USDC in 6-decimal funding base units. Settlement treats smaller returned commitments as
    /// unattributable dust; using a non-6-decimal funding asset requires revalidating this threshold.
    uint256 internal constant MIN_RETURN_COMMITMENT = 1e6;

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
    /// @dev offered = target * (1 - (1 - stepDecayRateBps/BPS)^(elapsed/stepDuration)): zero before the first step
    /// completes, monotonically nondecreasing in elapsed, never exceeds `rampTarget`.
    /// @param rampTarget Maximum collateral approached by the decay ramp (marginAsset).
    /// @param elapsed Seconds since the auction window opened.
    /// @param stepDuration Seconds per price step.
    /// @param stepDecayRateBps Per-step decay of the protocol's retained share, in bps.
    /// @return The collateral currently offered (marginAsset).
    function offeredPool(uint256 rampTarget, uint256 elapsed, uint256 stepDuration, uint256 stepDecayRateBps)
        public
        pure
        returns (uint256)
    {
        if (rampTarget == 0) return 0;

        uint256 steps = elapsed / stepDuration;
        if (steps == 0) return 0;

        uint256 rayMultiplier = RAY - stepDecayRateBps * 1e23;
        uint256 retained = rpow(rayMultiplier, steps, RAY);
        return rampTarget - Math.mulDiv(rampTarget, retained, RAY);
    }

    /// @notice Collateral award for filling `fillAmount` of the shortfall while `offered` is on the table.
    /// @dev Pro-rata of the current offer against the ORIGINAL shortfall, capped by the fill-time oracle value and
    /// the unawarded reserve. Conservation: each award <= maxCumulativeAward * fill / shortfall, so total awards never
    /// exceed the reserve because total fills never exceed the shortfall; the reserve clamp is belt-and-suspenders.
    /// @param state The auction state.
    /// @param fillAmount Amount of the shortfall being filled (fundingAsset).
    /// @param offered Collateral currently offered (marginAsset), from `offeredPool`.
    /// @param oracleCapMargin Oracle-valued award cap for this fill (marginAsset).
    /// @param maxCumulativeAward Reserved upper bound on all auction awards (marginAsset).
    /// @return award Collateral awarded for this fill (marginAsset).
    function fillAward(
        AuctionState memory state,
        uint256 fillAmount,
        uint256 offered,
        uint256 oracleCapMargin,
        uint256 maxCumulativeAward
    ) public pure returns (uint256 award) {
        if (state.shortfallAmount == 0) return 0;

        award = Math.mulDiv(offered, fillAmount, state.shortfallAmount);
        if (award > oracleCapMargin) award = oracleCapMargin;

        uint256 remainingPool = maxCumulativeAward - state.marginAwarded;
        if (award > remainingPool) award = remainingPool;
    }

    /// @notice Full award computation for a fill: the ramped pro-rata kicker, capped by `maxAwardBps` of the fill
    /// valued at `price` (the trusted margin-to-fundingAsset oracle price), clamped to the unawarded pool.
    /// @param state The auction state.
    /// @param fillAmount Amount of the shortfall being filled (fundingAsset).
    /// @param elapsed Seconds since the auction window opened.
    /// @param stepDuration Seconds per price step.
    /// @param stepDecayRateBps Per-step decay of the protocol's retained share, in bps.
    /// @param slashFeeBps Fee charged on the settlement take basis, in bps.
    /// @param maxAwardBps Award cap per fundingAsset filled, in bps.
    /// @param price Margin-to-fundingAsset oracle price, scaled by ORACLE_PRICE_SCALE.
    /// @return Collateral awarded for this fill (marginAsset).
    function computeAward(
        AuctionState memory state,
        uint256 fillAmount,
        uint256 elapsed,
        uint256 stepDuration,
        uint256 stepDecayRateBps,
        uint256 slashFeeBps,
        uint256 maxAwardBps,
        uint256 price
    ) public pure returns (uint256) {
        if (state.shortfallAmount == 0) return 0;

        uint256 oracleCapMargin = Math.mulDiv(Math.mulDiv(fillAmount, maxAwardBps, BPS), ORACLE_PRICE_SCALE, price);
        uint256 maxCumulativeAward = Math.mulDiv(state.marginPool, BPS, BPS + slashFeeBps);
        uint256 offered = offeredPool(maxCumulativeAward, elapsed, stepDuration, stepDecayRateBps);
        uint256 award = fillAward(state, fillAmount, offered, oracleCapMargin, maxCumulativeAward);
        return Math.min(award, _remainingEligibleAward(state, fillAmount, slashFeeBps));
    }

    /// @dev Completed settlement floors the gross pool's filled share before reserving its fee. Mirror that ordering
    /// cumulatively so awards cannot exceed the filled share's post-reserve capacity, including at base-unit dust.
    function _remainingEligibleAward(AuctionState memory state, uint256 fillAmount, uint256 slashFeeBps)
        private
        pure
        returns (uint256)
    {
        uint256 eligiblePool =
            Math.mulDiv(state.marginPool, uint256(state.filledAmount) + fillAmount, state.shortfallAmount);
        uint256 eligibleAward = Math.mulDiv(eligiblePool, BPS, BPS + slashFeeBps);
        return Math.saturatingSub(eligibleAward, state.marginAwarded);
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
    /// @param slashFeeBps Fee charged on the settlement take basis, in bps.
    /// @param maxAwardBps Award cap per fundingAsset filled, in bps.
    /// @param price Margin-to-fundingAsset oracle price, scaled by ORACLE_PRICE_SCALE.
    /// @return award Collateral awarded for this fill (marginAsset).
    function applyFill(
        AuctionState storage state,
        uint256 fillAmount,
        uint256 elapsed,
        uint256 stepDuration,
        uint256 stepDecayRateBps,
        uint256 slashFeeBps,
        uint256 maxAwardBps,
        uint256 price
    ) public returns (uint256 award) {
        award = computeAward(
            state, fillAmount, elapsed, stepDuration, stepDecayRateBps, slashFeeBps, maxAwardBps, price
        );
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

    /// @dev Return pool for a disposed epoch's unawarded surplus. Non-eligible and shutdown-truncated epochs
    /// return every unawarded unit without a take. Eligible epochs receive completed-auction treatment: the
    /// unfilled share of the gross pool (surplus plus awards) goes to treasury and the slash fee comes out of the
    /// filled remainder.
    function _settlementReturnPool(AuctionState storage auction, uint256 surplus, uint256 settlementConfig)
        private
        view
        returns (uint256 disposalPool)
    {
        // Eligibility is an explicit flag, not inferred from the record: an untouched but eligible epoch has a
        // zero auction record (zero fills) and must dispose as zero, not as a full no-take return.
        if (settlementConfig & (1 << 32) == 0) return surplus;
        if (auction.shortfallAmount == 0) return 0;

        uint256 stepDecayRateBps = settlementConfig & type(uint16).max;
        uint256 slashFeeBps = (settlementConfig >> 16) & type(uint16).max;
        uint256 auctionedMargin = auction.marginAwarded;
        uint256 feeBasis = auctionedMargin;
        uint256 grossPool = surplus + auctionedMargin;
        uint256 maxCumulativeAward = Math.mulDiv(grossPool, BPS, BPS + slashFeeBps);
        // The fee basis is the greater of cumulative awards and the fills' pro-rata share of the first-step offer.
        // `offered1` reconstructs that offer from `stepDecayRateBps`, repricing the curve the fills actually paid
        // against; the reconstruction is sound only because `auctionStepDecayRateBps` has no setter.
        uint256 offered1 = maxCumulativeAward - Math.mulDiv(maxCumulativeAward, BPS - stepDecayRateBps, BPS);
        feeBasis = Math.max(feeBasis, Math.mulDiv(offered1, auction.filledAmount, auction.shortfallAmount));
        disposalPool = Math.mulDiv(grossPool, auction.filledAmount, auction.shortfallAmount) - auctionedMargin;

        // The surplus clamp is unreachable on valid fill state (the reserved ramp keeps awards within post-fee
        // capacity); it bounds the fee independently of the ramp so a future award-ramp change cannot take more
        // than the surplus being disposed.
        uint256 fee = Math.min(Math.mulDiv(feeBasis, slashFeeBps, BPS), surplus);
        disposalPool -= fee;
    }

    /// @notice Values a disposed slash surplus into a return pool and returned commitment.
    /// @dev Pool: derived by `_settlementReturnPool` (eligibility and fee treatment documented there), then capped
    /// by the uint128 headroom over the low half of `packedHeadroom` so packed aggregate margin stays in range.
    /// Price: the call-open snapshot. A missing snapshot consults the live oracle only when the fallback permission
    /// bit is set; with the price-failure tolerance bit set (shutdown/terminal), an unreadable or zero price drops
    /// the pool to treasury instead of reverting, so recovery can never brick. Valuation overflow at the selected
    /// price is treated as oracle corruption and likewise drops the pool (guard rationale in the body).
    /// Commitment: derived from the pool at the selected price, clamped to the headroom high half, and zeroed below
    /// `MIN_RETURN_COMMITMENT`. A zero commitment also zeroes the pool, so the returned pair is always attributable
    /// to an account; a nonzero clamp never reduces the pool.
    /// @param auction Recorded auction state; a zero shortfall means no auction record was opened.
    /// @param surplus Unawarded slashed margin being disposed (marginAsset).
    /// @param settlementConfig Packed step decay (bits 0..15), slash fee (bits 16..31), and auction-eligibility flag
    /// (bit 32). An eligible disposal always receives completed-auction treatment.
    /// @param marginPriceSnapshot Margin-oracle price frozen when the call opened.
    /// @param marginOracle Live margin oracle used only for an authorized missing-snapshot recovery.
    /// @param valuationConfig Packed margin ratio (bits 0..15), oracle-fallback permission (bit 16), and live
    /// price-failure tolerance flag (bit 17).
    /// @param packedHeadroom Active-plus-pending margin in bits 0..127 and return-commitment headroom in bits 128..255.
    /// @return returnPool Margin re-attributed to defaulters (marginAsset).
    /// @return returnCommitment Commitment re-attributed to defaulters (fundingAsset).
    function disposeValuation(
        AuctionState storage auction,
        uint256 surplus,
        uint256 settlementConfig,
        uint256 marginPriceSnapshot,
        address marginOracle,
        uint256 valuationConfig,
        uint256 packedHeadroom
    ) public view returns (uint256 returnPool, uint256 returnCommitment) {
        returnPool = Math.min(
            _settlementReturnPool(auction, surplus, settlementConfig),
            Math.saturatingSub(type(uint128).max, packedHeadroom & type(uint128).max)
        );

        // The oracle is consulted only when there is a return pool to value.
        if (returnPool != 0) {
            uint256 price = marginPriceSnapshot;
            bool toleratePriceFailure = valuationConfig & (1 << 17) != 0;
            if (price == 0 && valuationConfig & (1 << 16) != 0) {
                if (toleratePriceFailure) {
                    try IOracle(marginOracle).price() returns (uint256 p) {
                        price = p;
                    } catch {}
                } else {
                    price = IOracle(marginOracle).price();
                }
            }

            if (!toleratePriceFailure && price == 0) revert LCCErrorsLib.OraclePriceInvalid();
            // Oracle-corruption guard. It must run after snapshot/fallback selection and before valuation: call
            // opening validated only `price != 0` and never proved the price could value `marginAtCallOpen`, so
            // this is the only check that the selected price can value this pool. For an honest oracle it is
            // unreachable — a full-uint128 pool overflows only near price 3.4e70 at the minimum margin ratio,
            // ~34 orders of magnitude above an ORACLE_PRICE_SCALE-scaled price — which is why it reads as dead
            // code but is not. On corrupt state, zeroing the price trades a permanent settlement brick for
            // confiscation of the pool via the `price == 0` sweep below.
            uint256 marginRatioBps = valuationConfig & type(uint16).max;
            if (_valuationOverflows(returnPool, price, marginRatioBps)) price = 0;

            if (price == 0) {
                returnPool = 0;
            } else {
                (, uint256 rawCommitment) = valueAndCommitment(returnPool, price, marginRatioBps);
                returnCommitment = Math.min(rawCommitment, packedHeadroom >> 128);
                if (returnCommitment < MIN_RETURN_COMMITMENT) returnCommitment = 0;
                if (returnCommitment == 0) returnPool = 0;
            }
        }

        if (returnPool == 0) returnCommitment = 0;
    }
}
