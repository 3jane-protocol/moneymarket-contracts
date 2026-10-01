// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

contract LCCAuctionLibTest is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    LCCAuctionLib.AuctionState internal disposalAuction;

    function _rpowReference(uint256 x, uint256 n, uint256 base) internal pure returns (uint256 z) {
        z = base;
        for (uint256 i = 0; i < n; ++i) {
            z = z * x / base;
        }
    }

    function testRpowKnownValues() public pure {
        assertEq(LCCAuctionLib.rpow(RAY, 100, RAY), RAY);
        assertEq(LCCAuctionLib.rpow(0, 0, RAY), RAY);
        assertEq(LCCAuctionLib.rpow(0, 5, RAY), 0);
        assertEq(LCCAuctionLib.rpow(RAY / 2, 1, RAY), RAY / 2);
        assertEq(LCCAuctionLib.rpow(RAY / 2, 2, RAY), RAY / 4);
    }

    function testFuzzRpowMatchesReference(uint256 multiplierBps, uint8 steps) public pure {
        multiplierBps = bound(multiplierBps, 0, BPS);
        uint256 x = RAY - multiplierBps * 1e23;

        uint256 fast = LCCAuctionLib.rpow(x, steps, RAY);
        uint256 slow = _rpowReference(x, steps, RAY);

        // rpow rounds each step half-up while the reference floors each step, so fast >= slow with a drift bounded
        // by the per-step rounding compounded over n multiplications.
        assertGe(fast, slow, "rpow below reference");
        assertLe(fast - slow, slow / 1e6 + uint256(steps) + 1, "rpow drift");
        assertLe(fast, RAY);
    }

    function testOfferedPoolBoundariesAndMonotonicity() public pure {
        uint256 pool = 1_000e18;

        assertEq(LCCAuctionLib.offeredPool(0, 100, 10, 5_000), 0);
        assertEq(LCCAuctionLib.offeredPool(pool, 0, 10, 5_000), 0);
        assertEq(LCCAuctionLib.offeredPool(pool, 9, 10, 5_000), 0);
        assertEq(LCCAuctionLib.offeredPool(pool, 10, 10, 5_000), pool / 2);
        assertEq(LCCAuctionLib.offeredPool(pool, 20, 10, 5_000), pool * 3 / 4);
        assertEq(LCCAuctionLib.offeredPool(pool, 10, 10, BPS), pool);

        uint256 previous;
        for (uint256 elapsed = 0; elapsed <= 200; elapsed += 10) {
            uint256 offered = LCCAuctionLib.offeredPool(pool, elapsed, 10, 1_000);
            assertGe(offered, previous);
            assertLe(offered, pool);
            previous = offered;
        }
    }

    function testFuzzOfferedPoolNeverExceedsPool(uint128 pool, uint32 elapsed, uint32 stepDuration, uint256 decayBps)
        public
        pure
    {
        stepDuration = uint32(bound(stepDuration, 1, type(uint32).max));
        decayBps = bound(decayBps, 1, BPS);

        uint256 offered = LCCAuctionLib.offeredPool(pool, elapsed, stepDuration, decayBps);
        assertLe(offered, pool);
    }

    function testFuzzOfferedPoolMonotonicInElapsed(
        uint128 pool,
        uint32 elapsed1,
        uint32 elapsed2,
        uint32 stepDuration,
        uint256 decayBps
    ) public pure {
        stepDuration = uint32(bound(stepDuration, 1, type(uint32).max));
        decayBps = bound(decayBps, 1, BPS);
        if (elapsed1 > elapsed2) (elapsed1, elapsed2) = (elapsed2, elapsed1);

        uint256 offered1 = LCCAuctionLib.offeredPool(pool, elapsed1, stepDuration, decayBps);
        uint256 offered2 = LCCAuctionLib.offeredPool(pool, elapsed2, stepDuration, decayBps);

        assertLe(offered1, offered2);
    }

    function testFuzzFillSequenceConservesPool(uint128 shortfall, uint128 pool, uint256 seed) public pure {
        shortfall = uint128(bound(shortfall, 1, type(uint128).max));

        LCCAuctionLib.AuctionState memory state = LCCAuctionLib.AuctionState({
            shortfallAmount: shortfall, filledAmount: 0, marginPool: pool, marginAwarded: 0
        });

        uint256 totalAward;
        for (uint256 i = 0; i < 8; ++i) {
            uint256 remaining = shortfall - state.filledAmount;
            if (remaining == 0) break;

            uint256 fill = bound(uint256(keccak256(abi.encode(seed, i, "fill"))), 1, remaining);
            uint256 elapsed = bound(uint256(keccak256(abi.encode(seed, i, "time"))), 0, 5_000);
            uint256 offered = LCCAuctionLib.offeredPool(pool, elapsed, 60, 500);

            uint256 award = LCCAuctionLib.fillAward(state, fill, offered, type(uint256).max, pool);

            state.filledAmount += uint128(fill);
            state.marginAwarded += uint128(award);
            totalAward += award;
        }

        assertLe(totalAward, pool);
        assertEq(state.marginAwarded, totalAward);
    }

    function testFuzzApplyFillSequenceKeepsSettlementNonnegative(
        uint128 shortfallSeed,
        uint128 pool,
        uint16 slashFeeSeed,
        uint16 decaySeed,
        uint16 maxAwardSeed,
        uint32 stepDurationSeed,
        uint128 priceSeed,
        uint256 sequenceSeed
    ) public {
        uint128 shortfall = uint128(bound(uint256(shortfallSeed), 1, type(uint128).max));
        uint256 slashFeeBps = bound(uint256(slashFeeSeed), 0, BPS);
        uint256 stepDecayRateBps = bound(uint256(decaySeed), 1, BPS);
        uint256 maxAwardBps = bound(uint256(maxAwardSeed), 0, BPS);
        uint256 stepDuration = bound(uint256(stepDurationSeed), 1, type(uint32).max);
        uint256 price = bound(uint256(priceSeed), 1, type(uint128).max);

        disposalAuction = LCCAuctionLib.AuctionState({
            shortfallAmount: shortfall, filledAmount: 0, marginPool: pool, marginAwarded: 0
        });

        for (uint256 i = 0; i < 8; ++i) {
            uint256 remaining = uint256(shortfall) - disposalAuction.filledAmount;
            if (remaining == 0) break;

            uint256 fill = bound(uint256(keccak256(abi.encode(sequenceSeed, i, "fill"))), 1, remaining);
            uint256 elapsed = bound(uint256(keccak256(abi.encode(sequenceSeed, i, "time"))), 0, 8 * stepDuration);
            LCCAuctionLib.applyFill(
                disposalAuction, fill, elapsed, stepDuration, stepDecayRateBps, slashFeeBps, maxAwardBps, price
            );
            _assertSettlementNonnegative(disposalAuction, stepDecayRateBps, slashFeeBps);
        }
    }

    function _assertSettlementNonnegative(
        LCCAuctionLib.AuctionState memory state,
        uint256 stepDecayRateBps,
        uint256 slashFeeBps
    ) internal pure {
        uint256 eligiblePool = Math.mulDiv(state.marginPool, state.filledAmount, state.shortfallAmount);
        uint256 maxCumulativeAward = Math.mulDiv(state.marginPool, BPS, BPS + slashFeeBps);
        uint256 offered1 = maxCumulativeAward - Math.mulDiv(maxCumulativeAward, BPS - stepDecayRateBps, BPS);
        uint256 feeBasis =
            Math.max(state.marginAwarded, Math.mulDiv(offered1, state.filledAmount, state.shortfallAmount));
        uint256 surplus = uint256(state.marginPool) - state.marginAwarded;
        uint256 fee = Math.min(Math.mulDiv(feeBasis, slashFeeBps, BPS), surplus);

        assertGe(eligiblePool, uint256(state.marginAwarded) + fee);
    }

    function testFillAwardCaps() public pure {
        LCCAuctionLib.AuctionState memory state =
            LCCAuctionLib.AuctionState({shortfallAmount: 100e18, filledAmount: 0, marginPool: 50e18, marginAwarded: 0});

        // Pro-rata: half the shortfall at full offer takes half the pool.
        assertEq(LCCAuctionLib.fillAward(state, 50e18, 50e18, type(uint256).max, 50e18), 25e18);
        // Oracle cap binds.
        assertEq(LCCAuctionLib.fillAward(state, 50e18, 50e18, 1e18, 50e18), 1e18);
        // Remaining-pool clamp binds.
        state.marginAwarded = 49e18;
        assertEq(LCCAuctionLib.fillAward(state, 100e18, 50e18, type(uint256).max, 50e18), 1e18);
        // Zero shortfall short-circuits.
        state.shortfallAmount = 0;
        assertEq(LCCAuctionLib.fillAward(state, 1e18, 50e18, type(uint256).max, 50e18), 0);
    }

    function testFuzzComputeAwardRespectsOracleCap(
        uint128 shortfall,
        uint128 pool,
        uint128 awardedSeed,
        uint128 fillSeed,
        uint32 elapsed,
        uint32 stepDuration,
        uint256 decayBps,
        uint256 maxAwardBps,
        uint256 price
    ) public pure {
        shortfall = uint128(bound(shortfall, 1, type(uint128).max));
        uint128 marginAwarded = uint128(bound(uint256(awardedSeed), 0, pool));
        uint256 fillAmount = bound(uint256(fillSeed), 0, shortfall);
        stepDuration = uint32(bound(stepDuration, 1, type(uint32).max));
        decayBps = bound(decayBps, 1, BPS);
        maxAwardBps = bound(maxAwardBps, 0, BPS);
        price = bound(price, 1, type(uint128).max);

        LCCAuctionLib.AuctionState memory state = LCCAuctionLib.AuctionState({
            shortfallAmount: shortfall, filledAmount: 0, marginPool: pool, marginAwarded: marginAwarded
        });

        uint256 award =
            LCCAuctionLib.computeAward(state, fillAmount, elapsed, stepDuration, decayBps, 0, maxAwardBps, price);
        uint256 oracleCap = Math.mulDiv(Math.mulDiv(fillAmount, maxAwardBps, BPS), ORACLE_PRICE_SCALE, price);

        assertLe(award, oracleCap);
    }

    function testComputeAwardReservesFeeAfterEligiblePoolFloor() public pure {
        LCCAuctionLib.AuctionState memory state =
            LCCAuctionLib.AuctionState({shortfallAmount: 2, filledAmount: 0, marginPool: 3, marginAwarded: 0});

        // The global reserve is 2, but the first fill's gross eligible pool is only 1. Reserving the fee after that
        // floor leaves no award capacity, preventing completed settlement from underflowing E - A - fee.
        assertEq(LCCAuctionLib.computeAward(state, 1, 1, 1, BPS, 1, BPS, ORACLE_PRICE_SCALE), 0);
    }

    function testComputeAwardZeroShortfallReturnsZero() public pure {
        LCCAuctionLib.AuctionState memory state =
            LCCAuctionLib.AuctionState({shortfallAmount: 0, filledAmount: 0, marginPool: 3, marginAwarded: 0});

        assertEq(LCCAuctionLib.computeAward(state, 1, 1, 0, BPS, BPS, BPS, 0), 0);
    }

    function testFuzzValueAndCommitmentMatchesFormula(uint128 assets, uint128 price, uint16 marginRatioSeed)
        public
        pure
    {
        uint256 marginRatioBps = bound(uint256(marginRatioSeed), 1, BPS);
        (uint256 marginValue, uint256 commitment) = LCCAuctionLib.valueAndCommitment(assets, price, marginRatioBps);

        uint256 expectedValue = Math.mulDiv(assets, price, ORACLE_PRICE_SCALE);
        assertEq(marginValue, expectedValue);
        assertEq(commitment, Math.mulDiv(expectedValue, BPS, marginRatioBps));
    }

    function testDisposeValuationClampsMarginBeforeValuingCommitment() public {
        OracleMock oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        (uint256 returnPool, uint256 returnCommitment) = LCCAuctionLib.disposeValuation(
            disposalAuction,
            100e18,
            0,
            ORACLE_PRICE_SCALE,
            address(oracle),
            5_000,
            uint256(type(uint128).max) - 25e18 | (uint256(type(uint128).max) << 128)
        );

        assertEq(returnPool, 25e18);
        assertEq(returnCommitment, 50e18);
    }

    function testDisposeValuationCommitmentClampPreservesNonzeroPool() public {
        OracleMock oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        (uint256 returnPool, uint256 returnCommitment) = LCCAuctionLib.disposeValuation(
            disposalAuction, 100e18, 0, ORACLE_PRICE_SCALE, address(oracle), 5_000, 50e18 << 128
        );

        assertEq(returnPool, 100e18);
        assertEq(returnCommitment, 50e18);
    }

    function testDisposeValuationOverflowGuardIsIndependentOfPriceFailureTolerance() public {
        OracleMock oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);
        uint256 returnAssets = uint256(type(uint128).max) / 2;

        (uint256 returnPool, uint256 returnCommitment) = LCCAuctionLib.disposeValuation(
            disposalAuction,
            returnAssets,
            0,
            type(uint256).max,
            address(oracle),
            5_000,
            uint256(type(uint128).max) << 128
        );

        assertEq(returnPool, 0);
        assertEq(returnCommitment, 0);
    }

    function testDisposeValuationIgnoresExtensionBitsWhenAuctionEligibilityIsUnset() public {
        OracleMock oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE_SCALE);

        (uint256 returnPool, uint256 returnCommitment) = LCCAuctionLib.disposeValuation(
            disposalAuction,
            100e18,
            1 << 33,
            ORACLE_PRICE_SCALE,
            address(oracle),
            5_000,
            uint256(type(uint128).max) << 128
        );

        assertEq(returnPool, 100e18);
        assertEq(returnCommitment, 200e18);
    }
}
