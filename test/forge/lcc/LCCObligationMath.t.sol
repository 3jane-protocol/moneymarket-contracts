// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

contract LCCObligationMathTest is Test {
    function testFuzzCeilObligationsBoundAggregateOvercollection(uint96[16] memory commitments, uint256 callSeed)
        public
        pure
    {
        uint256 denominator;
        uint256 nonzeroCount;
        for (uint256 i = 0; i < commitments.length; ++i) {
            denominator += commitments[i];
            if (commitments[i] != 0) ++nonzeroCount;
        }
        if (denominator == 0) return;

        uint256 callAmount = callSeed % (denominator + 1);
        uint256 obligationSum;
        for (uint256 i = 0; i < commitments.length; ++i) {
            obligationSum += _obligation(callAmount, denominator, commitments[i]);
        }

        assertGe(obligationSum, callAmount);
        if (callAmount == 0) {
            assertEq(obligationSum, 0);
        } else {
            assertLe(obligationSum, callAmount + nonzeroCount - 1);
        }
    }

    function testFuzzReleasedMarginFloorsAndNeverExceedsMargin(
        uint128 margin,
        uint128 commitmentSeed,
        uint128 obligationSeed
    ) public pure {
        uint256 commitment = uint256(commitmentSeed) + 1;
        uint256 obligation = bound(uint256(obligationSeed), 0, commitment);

        uint256 releasedMargin = Math.mulDiv(margin, obligation, commitment);

        assertLe(releasedMargin, margin);
        if (obligation == commitment) assertEq(releasedMargin, margin);
    }

    function _obligation(uint256 callAmount, uint256 commitmentDenominator, uint256 activeCommitment)
        internal
        pure
        returns (uint256)
    {
        if (activeCommitment == 0 || commitmentDenominator == 0) return 0;
        return Math.mulDiv(activeCommitment, callAmount, commitmentDenominator, Math.Rounding.Ceil);
    }
}
