// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";

contract LCCMaterializeTest is LCCBase {
    function testFreshAccountCanDepositAfterManyFinalizedCalls() public {
        _createFundedCallHistory(alice, MAX_MATERIALIZE_STEPS_PLUS_ONE());

        vm.warp(START + EPOCH * (MAX_MATERIALIZE_STEPS_PLUS_ONE() + 1));
        _deposit(bob, 10e18);

        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(bob);
        assertEq(account.activeMargin, 10e18);
        assertEq(account.calledEpochCursor, vault.syncState().finalizedCallPrefix);
    }

    function testClearedAccountCanDepositAfterManyMoreFinalizedCalls() public {
        vm.prank(owner);
        vault.setSlashFeeBps(10_000);

        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        _syncAs(alice);

        vm.warp(START + EPOCH);
        _createFundedCallHistoryFromEpoch(bob, 1, MAX_MATERIALIZE_STEPS_PLUS_ONE());

        vm.warp(START + EPOCH * (MAX_MATERIALIZE_STEPS_PLUS_ONE() + 2));
        _deposit(alice, 10e18);

        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 10e18);
        assertEq(account.calledEpochCursor, vault.syncState().finalizedCallPrefix);
    }

    function testViewDoesNotReportClaimableExitPastUnfinalizedEligibleCall() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();
        _openCall(100e18);

        vm.warp(START + EPOCH);

        assertEq(vault.claimableExitedMargin(alice), 0);
        ILeveragedCallableCreditVault.Account memory derived = vault.getAccount(alice);
        assertEq(derived.claimableExitMargin, 0);

        _syncAs(alice);

        assertTrue(vault.defaultedEpoch(0, alice));
        assertEq(vault.claimableExitedMargin(alice), 0);
    }

    function testDerivedViewMatchesMutatingMaterializationForPending() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        _syncAs(bob);

        ILeveragedCallableCreditVault.Account memory derived = vault.getAccount(alice);
        _syncAs(alice);
        ILeveragedCallableCreditVault.Account memory storedDerived = vault.getAccount(alice);

        assertEq(derived.activeMargin, storedDerived.activeMargin);
        assertEq(derived.pendingMargin, storedDerived.pendingMargin);
        assertEq(derived.calledEpochCursor, storedDerived.calledEpochCursor);
    }

    function testDerivedViewMatchesMutatingMaterializationForDefault() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILeveragedCallableCreditVault.Account memory derived = vault.getAccount(alice);
        _syncAs(alice);
        ILeveragedCallableCreditVault.Account memory storedDerived = vault.getAccount(alice);

        assertEq(derived.activeMargin, 90e18);
        assertEq(storedDerived.activeMargin, 90e18);
        assertEq(derived.calledEpochCursor, storedDerived.calledEpochCursor);
    }

    function testPendingDepositDuringCallIsNotDefaultedForPriorEpoch() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(bob, 100e18);

        vm.warp(START + EPOCH);
        _syncAs(bob);

        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(bob);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCommitment, 200e18);
        assertFalse(vault.defaultedEpoch(0, bob));
    }

    function testOnlyOldActiveExposureDefaultsWhenUserAlsoHasPendingDeposit() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 50e18);

        vm.warp(START + EPOCH);
        _syncAs(alice);

        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(alice);
        assertTrue(vault.defaultedEpoch(0, alice));
        assertEq(account.activeMargin, 140e18);
        assertEq(account.activeCommitment, 280e18);
        assertEq(margin.balanceOf(treasury), 10e18);
    }

    function testMaturedExiterIsNotDefaultedByLaterCall() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + EPOCH);
        _deposit(bob, 100e18);

        vm.warp(START + EPOCH + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(1, 100e18);

        vm.warp(START + EPOCH + NORMAL + PRE_CALL + FUNDING);
        vault.finalizeEpochSlash(1);

        assertEq(vault.claimableExitedMargin(alice), 100e18);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 100e18);
        assertFalse(vault.defaultedEpoch(1, alice));
    }

    function testRepeatMaterializeSkipsAccountStorageWrite() public {
        _deposit(alice, 100e18);
        vault.materializeAccount(alice);

        vm.record();
        vault.materializeAccount(alice);
        (, bytes32[] memory writes) = vm.accesses(address(vault));

        // Only the reentrancy guard (2 writes) and the two fold trackers should be written; the unchanged account
        // must not be re-stored.
        assertLe(writes.length, 4);
    }

    function _createFundedCallHistory(address funder, uint256 count) internal {
        _createFundedCallHistoryFromEpoch(funder, 0, count);
    }

    function _createFundedCallHistoryFromEpoch(address funder, uint256 startEpoch, uint256 count) internal {
        if (vault.getAccount(funder).activeMargin == 0) _deposit(funder, 10_000e18);

        for (uint256 i = 0; i < count; ++i) {
            uint256 epoch = startEpoch + i;
            vm.warp(START + EPOCH * epoch + NORMAL);
            vm.prank(owner);
            vault.openEpochCall(epoch, 1e18);

            vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL);
            vm.prank(funder);
            vault.fundCall();

            vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL + FUNDING);
            vault.finalizeEpochSlash(epoch);
        }
    }

    function MAX_MATERIALIZE_STEPS_PLUS_ONE() internal pure returns (uint256) {
        return 65;
    }
}
