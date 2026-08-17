// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Test} from "../../../lib/forge-std/src/Test.sol";

import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAccountLib} from "../../../src/lcc/libraries/LCCAccountLib.sol";

contract LCCAccountLibTest is Test {
    using LCCAccountLib for ILCCVault.Account;

    function testFuzzMatureExitMovesActiveMarginToClaimable(uint128 activeMargin, uint128 claimableExitMargin) public {
        ILCCVault.Account memory account;
        account.activeMargin = activeMargin;
        account.activeCommitment = 1;
        account.claimableExitMargin = claimableExitMargin;
        account.exitBucketMargin = activeMargin;
        account.exitBucketCommitment = 1;

        uint256 totalMargin = account.activeMargin + account.claimableExitMargin;

        account.matureExit();

        assertEq(account.activeMargin, 0);
        assertEq(account.activeCommitment, 0);
        assertEq(account.claimableExitMargin, totalMargin);
        assertEq(account.exitBucketMargin, 0);
        assertEq(account.exitBucketCommitment, 0);
        assertTrue(account.exitMatured);
    }

    function testFuzzActivatePendingPreservesMarginAndCommitmentSums(
        uint128 activeMargin,
        uint128 activeCommitment,
        uint128 pendingMargin,
        uint128 pendingCommitment,
        uint64 pendingActivationEpoch
    ) public {
        ILCCVault.Account memory account;
        account.activeMargin = activeMargin;
        account.activeCommitment = activeCommitment;
        account.pendingMargin = pendingMargin;
        account.pendingCommitment = pendingCommitment;
        account.pendingActivationEpoch = pendingActivationEpoch;

        uint256 totalMargin = account.activeMargin + account.pendingMargin;
        uint256 totalCommitment = account.activeCommitment + account.pendingCommitment;

        account.activatePending();

        assertEq(account.activeMargin, totalMargin);
        assertEq(account.activeCommitment, totalCommitment);
        assertEq(account.pendingMargin, 0);
        assertEq(account.pendingCommitment, 0);
        assertEq(account.pendingActivationEpoch, 0);
    }

    function testFuzzDefaultAccountClearsCalledExposureAndPendingExit(
        uint128 activeMargin,
        uint128 activeCommitment,
        uint128 pendingMargin,
        uint128 pendingCommitment,
        uint128 claimableExitMargin,
        uint64 exitMaturityEpoch
    ) public {
        ILCCVault.Account memory account;
        account.activeMargin = activeMargin;
        account.activeCommitment = activeCommitment;
        account.pendingMargin = pendingMargin;
        account.pendingCommitment = pendingCommitment;
        account.claimableExitMargin = claimableExitMargin;
        account.exitBucketMargin = activeMargin;
        account.exitBucketCommitment = activeCommitment;
        account.exitRequested = true;
        account.exitMaturityEpoch = exitMaturityEpoch;

        account.defaultAccount();

        assertEq(account.activeMargin, 0);
        assertEq(account.activeCommitment, 0);
        assertEq(account.exitBucketMargin, 0);
        assertEq(account.exitBucketCommitment, 0);
        assertEq(account.claimableExitMargin, 0);
        assertEq(account.pendingMargin, pendingMargin);
        assertEq(account.pendingCommitment, pendingCommitment);
        assertFalse(account.exitRequested);
        assertEq(account.exitMaturityEpoch, 0);
        assertTrue(account.exitClaimed);
        assertFalse(account.exitMatured);
    }

    function testFuzzDefaultAccountLeavesZeroExposureWhenNoPending(
        uint128 activeMargin,
        uint128 activeCommitment,
        uint128 claimableExitMargin
    ) public {
        ILCCVault.Account memory account;
        account.activeMargin = activeMargin;
        account.activeCommitment = activeCommitment;
        account.claimableExitMargin = claimableExitMargin;
        account.exitRequested = true;

        account.defaultAccount();

        assertTrue(account.isReplayInert());
    }

    function testFuzzIsReplayInertMatchesReplayFixedPointPredicate(
        uint128 activeMargin,
        uint128 activeCommitment,
        uint128 pendingMargin,
        uint128 pendingCommitment,
        uint128 claimableExitMargin,
        bool exitRequested,
        bool exitClaimed,
        bool exitMatured
    ) public {
        ILCCVault.Account memory account;
        account.activeMargin = activeMargin;
        account.activeCommitment = activeCommitment;
        account.pendingMargin = pendingMargin;
        account.pendingCommitment = pendingCommitment;
        account.claimableExitMargin = claimableExitMargin;
        account.exitRequested = exitRequested;
        account.exitClaimed = exitClaimed;
        account.exitMatured = exitMatured;

        bool expected = activeMargin == 0 && activeCommitment == 0 && pendingMargin == 0 && pendingCommitment == 0
            && (exitMatured || (claimableExitMargin == 0 && (!exitRequested || exitClaimed)));

        assertEq(account.isReplayInert(), expected);
    }

    function testMaturedClaimableExitIsReplayFixedPoint() public {
        ILCCVault.Account memory account;
        account.claimableExitMargin = 123e18;
        account.exitMaturityEpoch = 7;
        account.exitRequested = true;
        account.exitMatured = true;
        account.commitmentStartEpoch = 3;

        assertTrue(account.isReplayInert());

        account.activatePendingForEpoch(100);
        account.matureExitForEpoch(100);

        assertEq(account.activeMargin, 0);
        assertEq(account.activeCommitment, 0);
        assertEq(account.pendingMargin, 0);
        assertEq(account.pendingCommitment, 0);
        assertEq(account.claimableExitMargin, 123e18);
        assertEq(account.exitMaturityEpoch, 7);
        assertTrue(account.exitRequested);
        assertTrue(account.exitMatured);
        assertEq(account.commitmentStartEpoch, 3);
    }

    function testFullyFundedPreMaturityExitIsNotReplayInert() public {
        ILCCVault.Account memory account;
        account.exitMaturityEpoch = 7;
        account.exitRequested = true;

        assertFalse(account.isReplayInert());

        account.matureExitForEpoch(6);
        assertFalse(account.isReplayInert());
        assertFalse(account.exitMatured);

        account.matureExitForEpoch(7);
        assertTrue(account.isReplayInert());
        assertTrue(account.exitMatured);
    }
}
