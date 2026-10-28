// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {AaveRebateEventsLib} from "../../../src/libraries/AaveRebateEventsLib.sol";
import {AaveRebateMathLib} from "../../../src/libraries/AaveRebateMathLib.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";

contract AaveRebateMathLibTest is Test {
    using MathLib for uint256;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant BASELINE_BPS = 500;

    function test_intervalRebate_zeroWhenActualGrowthBelowBaseline() public pure {
        uint256 debt = 1_000e6;
        uint256 elapsed = 365 days;
        uint256 startIndex = RAY;
        uint256 endIndex = RAY + (RAY * 4) / 100;

        uint256 rebate = AaveRebateMathLib.intervalRebate(debt, startIndex, endIndex, elapsed, BASELINE_BPS);

        assertEq(rebate, 0);
    }

    function test_intervalRebate_zeroWhenActualGrowthEqualsBaseline() public pure {
        uint256 debt = 1_000e6;
        uint256 elapsed = 365 days;
        uint256 baselineGrowth = AaveRebateMathLib.aprBpsToRatePerSecond(BASELINE_BPS).wTaylorCompounded(elapsed);
        uint256 startIndex = RAY;
        uint256 endIndex = RAY + (RAY * baselineGrowth) / WAD;

        uint256 rebate = AaveRebateMathLib.intervalRebate(debt, startIndex, endIndex, elapsed, BASELINE_BPS);

        assertEq(rebate, 0);
    }

    function test_intervalRebate_positiveExcessGrowth() public pure {
        uint256 debt = 1_000e6;
        uint256 elapsed = 365 days;
        uint256 startIndex = RAY;
        uint256 endIndex = RAY + (RAY * 10) / 100;

        uint256 actualGrowth = AaveRebateMathLib.indexGrowth(startIndex, endIndex);
        uint256 baselineGrowth = AaveRebateMathLib.aprBpsToRatePerSecond(BASELINE_BPS).wTaylorCompounded(elapsed);
        uint256 expected = debt.wMulDown(actualGrowth - baselineGrowth);

        uint256 rebate = AaveRebateMathLib.intervalRebate(debt, startIndex, endIndex, elapsed, BASELINE_BPS);

        assertEq(rebate, expected);
        assertGt(rebate, 0);
    }

    function test_intervalRebate_ignoresZeroDebt() public pure {
        uint256 rebate = AaveRebateMathLib.intervalRebate(0, RAY, RAY + (RAY * 10) / 100, 365 days, BASELINE_BPS);

        assertEq(rebate, 0);
    }

    function test_intervalRebate_floorsToUsdcBaseUnits() public pure {
        uint256 debt = 1;
        uint256 elapsed = 365 days;
        uint256 startIndex = RAY;
        uint256 endIndex = RAY + RAY / 10;

        uint256 rebate = AaveRebateMathLib.intervalRebate(debt, startIndex, endIndex, elapsed, BASELINE_BPS);

        assertEq(rebate, 0);
    }

    function test_intervalRebate_zeroWhenEndIndexBelowStartIndex() public pure {
        uint256 rebate = AaveRebateMathLib.intervalRebate(1_000e6, RAY, RAY - 1, 365 days, BASELINE_BPS);

        assertEq(rebate, 0);
    }

    function test_intervalRebateWithAverageDebt_matchesConstantDebt() public pure {
        uint256 debt = 1_000e6;
        uint256 elapsed = 365 days;
        uint256 startIndex = RAY;
        uint256 endIndex = RAY + RAY / 10;

        uint256 expected = AaveRebateMathLib.intervalRebate(debt, startIndex, endIndex, elapsed, BASELINE_BPS);
        uint256 rebate =
            AaveRebateMathLib.intervalRebateWithAverageDebt(debt, debt, startIndex, endIndex, elapsed, BASELINE_BPS);

        assertEq(rebate, expected);
    }

    function test_intervalRebateWithAverageDebt_increasingDebtExceedsStartOnly() public pure {
        uint256 startDebt = 1_000e6;
        uint256 endDebt = 2_000e6;
        uint256 elapsed = 365 days;
        uint256 startIndex = RAY;
        uint256 endIndex = RAY + RAY / 10;

        uint256 startOnly = AaveRebateMathLib.intervalRebate(startDebt, startIndex, endIndex, elapsed, BASELINE_BPS);
        uint256 averageDebt = AaveRebateMathLib.intervalRebateWithAverageDebt(
            startDebt, endDebt, startIndex, endIndex, elapsed, BASELINE_BPS
        );

        assertGt(averageDebt, startOnly);
    }

    function test_intervalRebateWithAverageDebt_countsZeroStartPositiveEnd() public pure {
        uint256 rebate =
            AaveRebateMathLib.intervalRebateWithAverageDebt(0, 2_000e6, RAY, RAY + RAY / 10, 365 days, BASELINE_BPS);

        assertGt(rebate, 0);
    }
}

contract AaveRebateEventsLibTest is Test {
    function test_borrowerTopicIndex_matchesEventIndexedFields() public pure {
        assertEq(AaveRebateEventsLib.borrowerTopicIndex(AaveRebateEventsLib.BORROW_EVENT_SIG), 2);
        assertEq(AaveRebateEventsLib.borrowerTopicIndex(AaveRebateEventsLib.REPAY_EVENT_SIG), 3);
        assertEq(AaveRebateEventsLib.borrowerTopicIndex(AaveRebateEventsLib.PREMIUM_ACCRUED_EVENT_SIG), 2);
        assertEq(AaveRebateEventsLib.borrowerTopicIndex(AaveRebateEventsLib.ACCOUNT_SETTLED_EVENT_SIG), 3);
    }

    function test_borrowerTopicIndex_revertsForUnknownEvent() public {
        vm.expectRevert(bytes("unknown event"));
        this.borrowerTopicIndex(keccak256("Unknown()"));
    }

    function borrowerTopicIndex(bytes32 eventSig) external pure returns (uint256) {
        return AaveRebateEventsLib.borrowerTopicIndex(eventSig);
    }
}
