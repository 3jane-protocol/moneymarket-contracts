// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";

import {LCCExitLib} from "../../../src/lcc/libraries/LCCExitLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCTypesLib} from "../../../src/lcc/libraries/LCCTypesLib.sol";

contract LCCExitAssignmentHarness {
    mapping(uint256 => LCCTypesLib.Bucket) internal buckets;
    uint256[] internal maturities;
    mapping(uint256 => uint256) internal indexPlusOne;
    mapping(uint256 => mapping(uint256 => LCCTypesLib.ExitExposure)) internal exposureByCallAndMaturity;
    mapping(uint256 => uint256[]) internal maturitiesByCall;

    uint256 internal constant BPS = 10_000;

    function seed(uint256 maturity, uint128 commitment) external {
        require(indexPlusOne[maturity] == 0, "duplicate");
        buckets[maturity].commitment = commitment;
        maturities.push(maturity);
        indexPlusOne[maturity] = maturities.length;
    }

    function assign(uint256 accountCommitment, uint256 earliestMaturity, uint256 maxDeferralEpochs, uint256 capacity)
        external
        view
        returns (uint256)
    {
        return LCCExitLib.assignExitMaturity(
            buckets, accountCommitment, maxDeferralEpochs, capacity, earliestMaturity | (BPS << 64)
        );
    }

    function assignAndBook(
        uint256 accountCommitment,
        uint256 earliestMaturity,
        uint256 maxDeferralEpochs,
        uint256 capacity
    ) external returns (uint256 maturity) {
        maturity = LCCExitLib.assignExitMaturity(
            buckets, accountCommitment, maxDeferralEpochs, capacity, earliestMaturity | (BPS << 64)
        );
        buckets[maturity].commitment += uint128(accountCommitment);
    }

    function commitmentAt(uint256 maturity) external view returns (uint256) {
        return buckets[maturity].commitment;
    }
}

contract LCCExitLibExitTest is Test {
    uint256 internal constant MAX_EXIT_MATURITY_BUCKETS = 128;
    uint256 internal constant EARLIEST = 100;
    uint256 internal constant CAPACITY = 10;
    uint256 internal constant ACCOUNT_COMMITMENT = 10;

    LCCExitAssignmentHarness internal harness;

    function setUp() public {
        harness = new LCCExitAssignmentHarness();
        for (uint256 i = 0; i < MAX_EXIT_MATURITY_BUCKETS; ++i) {
            uint256 maturity = EARLIEST + i;
            uint128 commitment = maturity == 103 || maturity == 107 ? 2 : 9;
            harness.seed(maturity, commitment);
        }
    }

    function testFullListFallbackSelectsLeastLoadedEarliestTie() public view {
        assertEq(harness.assign(ACCOUNT_COMMITMENT, EARLIEST, 128, CAPACITY), 103);
    }

    function testFuzzFullListFallbackBoundsPostAssignmentAndBreaksMinimumLoadTieByEarliest(
        uint128 capacitySeed,
        uint128 accountCommitmentSeed,
        uint8 firstMinimumIndexSeed,
        uint8 secondMinimumIndexSeed,
        uint256 loadSeed
    ) public {
        uint256 capacity = bound(uint256(capacitySeed), 4, type(uint128).max / 2);
        uint256 accountCommitment = bound(uint256(accountCommitmentSeed), 3, capacity - 1);
        uint256 firstMinimumIndex = bound(uint256(firstMinimumIndexSeed), 1, MAX_EXIT_MATURITY_BUCKETS - 2);
        uint256 secondMinimumIndex =
            bound(uint256(secondMinimumIndexSeed), firstMinimumIndex + 1, MAX_EXIT_MATURITY_BUCKETS - 1);
        uint256 minimumLoad = capacity - accountCommitment + 1;
        uint256 higherLoadRange = capacity - minimumLoad - 1;

        LCCExitAssignmentHarness fuzzHarness = new LCCExitAssignmentHarness();
        uint256 eligibleLoad;
        // Seed in reverse maturity order so the later tied minimum is encountered first. Every nonminimum load is
        // strictly greater, and every load leaves less than A of individual room, forcing the full-list fallback.
        for (uint256 remaining = MAX_EXIT_MATURITY_BUCKETS; remaining != 0; --remaining) {
            uint256 index = remaining - 1;
            uint256 load = minimumLoad;
            if (index != firstMinimumIndex && index != secondMinimumIndex) {
                load += 1 + uint256(keccak256(abi.encode(loadSeed, index))) % higherLoadRange;
            }
            fuzzHarness.seed(EARLIEST + index, uint128(load));
            eligibleLoad += load;
        }

        uint256 eligibleCount = MAX_EXIT_MATURITY_BUCKETS;
        assertLe(eligibleLoad + accountCommitment, eligibleCount * capacity);

        uint256 selectedMaturity =
            fuzzHarness.assignAndBook(accountCommitment, EARLIEST, MAX_EXIT_MATURITY_BUCKETS, capacity);
        uint256 postAssignmentLoad = fuzzHarness.commitmentAt(selectedMaturity);

        assertEq(selectedMaturity, EARLIEST + firstMinimumIndex);
        assertEq(postAssignmentLoad, minimumLoad + accountCommitment);
        assertGt(postAssignmentLoad, capacity);
        assertLe(postAssignmentLoad, eligibleLoad / eligibleCount + accountCommitment);
        assertLt(postAssignmentLoad, capacity + accountCommitment);
    }

    function testFullListFallbackRejectsNarrowEligibleAggregateCapacity() public {
        // Only maturities 220..227 are eligible before first-fit reaches the untracked 228 key. Their scheduled
        // commitment is 8 * 9, so adding this account exceeds the real 8 * CAPACITY aggregate bound.
        vm.expectRevert(LCCErrorsLib.ExitCapacityReached.selector);
        harness.assign(ACCOUNT_COMMITMENT, EARLIEST + 120, 8, CAPACITY);
    }

    function testNarrowDeferralRejectsBeforeFullListAggregateCapacity() public {
        vm.expectRevert(LCCErrorsLib.ExitDeferralExceeded.selector);
        harness.assign(ACCOUNT_COMMITMENT, EARLIEST, 127, CAPACITY);
    }

    function testExitDeferralExceededPrecedesExitCapacityReached() public {
        vm.expectRevert(LCCErrorsLib.ExitDeferralExceeded.selector);
        harness.assign(ACCOUNT_COMMITMENT, EARLIEST, 127, CAPACITY);

        vm.expectRevert(LCCErrorsLib.ExitCapacityReached.selector);
        harness.assign(ACCOUNT_COMMITMENT, EARLIEST + 120, 8, CAPACITY);
    }

    function testZeroCapacityIsFlooredInsideLibrary() public {
        LCCExitAssignmentHarness emptyHarness = new LCCExitAssignmentHarness();
        assertEq(emptyHarness.assign(1, EARLIEST, type(uint256).max, 0), EARLIEST);
    }
}
