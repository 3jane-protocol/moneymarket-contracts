// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {DelayedRepaymentRebateLib} from "../../../src/libraries/DelayedRepaymentRebateLib.sol";

contract DelayedRepaymentRebateLibTest is Test {
    function test_delayedInterest_zeroWhenStartDebtIsZero() public pure {
        uint256 rebate = DelayedRepaymentRebateLib.delayedInterest(100e6, 0, 110e6);

        assertEq(rebate, 0);
    }

    function test_delayedInterest_zeroWhenEndDebtDoesNotIncrease() public pure {
        uint256 rebate = DelayedRepaymentRebateLib.delayedInterest(100e6, 1_000e6, 1_000e6);

        assertEq(rebate, 0);
    }

    function test_delayedInterest_partialPrincipalReceivesProportionalGrowth() public pure {
        uint256 rebate = DelayedRepaymentRebateLib.delayedInterest(250e6, 1_000e6, 1_100e6);

        assertEq(rebate, 25e6);
    }

    function test_cappedPrincipal_capsAtStartDebt() public pure {
        uint256 capped = DelayedRepaymentRebateLib.cappedPrincipal(2_000e6, 1_500e6);

        assertEq(capped, 1_500e6);
    }

    function test_cappedPrincipal_usesReceivedWhenBelowDebt() public pure {
        uint256 capped = DelayedRepaymentRebateLib.cappedPrincipal(500e6, 1_500e6);

        assertEq(capped, 500e6);
    }

    function test_residualCleanup_addsDebtBelowThreshold() public pure {
        uint256 cleanup = DelayedRepaymentRebateLib.residualCleanup(24_999_999, 25e6);

        assertEq(cleanup, 24_999_999);
    }

    function test_residualCleanup_zeroWhenDebtIsZero() public pure {
        uint256 cleanup = DelayedRepaymentRebateLib.residualCleanup(0, 25e6);

        assertEq(cleanup, 0);
    }

    function test_residualCleanup_zeroWhenDebtEqualsThreshold() public pure {
        uint256 cleanup = DelayedRepaymentRebateLib.residualCleanup(25e6, 25e6);

        assertEq(cleanup, 0);
    }

    function test_residualCleanup_honorsConfigurableThreshold() public pure {
        uint256 cleanup = DelayedRepaymentRebateLib.residualCleanup(40e6, 50e6);

        assertEq(cleanup, 40e6);
    }

    function test_topicAddress_roundTripsAddressTopic() public pure {
        address account = address(0x1234567890123456789012345678901234567890);
        bytes32 topic = DelayedRepaymentRebateLib.addressTopic(account);

        assertEq(DelayedRepaymentRebateLib.topicAddress(topic), account);
    }
}
