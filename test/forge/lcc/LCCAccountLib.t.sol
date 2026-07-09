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

        assertTrue(account.isZeroExposure());
    }

    function testFuzzIsZeroExposureMatchesAccountExposurePredicate(
        uint128 activeMargin,
        uint128 activeCommitment,
        uint128 pendingMargin,
        uint128 pendingCommitment,
        uint128 claimableExitMargin,
        bool exitRequested,
        bool exitClaimed
    ) public {
        ILCCVault.Account memory account;
        account.activeMargin = activeMargin;
        account.activeCommitment = activeCommitment;
        account.pendingMargin = pendingMargin;
        account.pendingCommitment = pendingCommitment;
        account.claimableExitMargin = claimableExitMargin;
        account.exitRequested = exitRequested;
        account.exitClaimed = exitClaimed;

        bool expected = activeMargin == 0 && activeCommitment == 0 && pendingMargin == 0 && pendingCommitment == 0
            && claimableExitMargin == 0 && (!exitRequested || exitClaimed);

        assertEq(account.isZeroExposure(), expected);
    }
}
