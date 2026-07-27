// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {Vm} from "../../../lib/forge-std/src/Vm.sol";

contract LCCMaterializeTest is LCCBase {
    function testFreshAccountCanDepositAfterManyFinalizedCalls() public {
        _createFundedCallHistory(alice, MAX_MATERIALIZE_STEPS_PLUS_ONE());

        vm.warp(START + EPOCH * (MAX_MATERIALIZE_STEPS_PLUS_ONE() + 1));
        _deposit(bob, 10e18);

        ILCCVault.Account memory account = vault.getAccount(bob);
        assertEq(account.activeMargin, 10e18);
        assertEq(account.calledEpochCursor, vault.syncState().finalizedCallPrefix);
    }

    function testClearedAccountCanDepositAfterManyMoreFinalizedCalls() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        oracle.setPrice(4_999e18);
        _syncAs(alice);
        oracle.setPrice(1e36);

        vm.warp(START + EPOCH);
        _createFundedCallHistoryFromEpoch(bob, 1, MAX_MATERIALIZE_STEPS_PLUS_ONE());

        vm.warp(START + EPOCH * (MAX_MATERIALIZE_STEPS_PLUS_ONE() + 2));
        _deposit(alice, 10e18);

        ILCCVault.Account memory account = vault.getAccount(alice);
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
        ILCCVault.Account memory derived = vault.getAccount(alice);
        assertEq(derived.claimableExitMargin, 0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.UserDefaulted(alice, 0, 100e18, 200e18);
        _syncAs(alice);

        assertEq(vault.claimableExitedMargin(alice), 0);
    }

    function testDerivedViewMatchesMutatingMaterializationForPending() public {
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        _syncAs(bob);

        ILCCVault.Account memory derived = vault.getAccount(alice);
        _syncAs(alice);
        ILCCVault.Account memory storedDerived = vault.getAccount(alice);

        assertEq(derived.activeMargin, storedDerived.activeMargin);
        assertEq(derived.pendingMargin, storedDerived.pendingMargin);
        assertEq(derived.calledEpochCursor, storedDerived.calledEpochCursor);
    }

    function testDerivedViewMatchesMutatingMaterializationForDefault() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.Account memory derived = vault.getAccount(alice);
        _syncAs(alice);
        ILCCVault.Account memory storedDerived = vault.getAccount(alice);

        assertEq(derived.activeMargin, 100e18);
        assertEq(storedDerived.activeMargin, 100e18);
        assertEq(derived.calledEpochCursor, storedDerived.calledEpochCursor);
    }

    function testPendingDepositAfterSettledCallIsNotDefaultedForPriorEpoch() public {
        vm.recordLogs();
        _deposit(alice, 100e18);
        _openCall(100e18);

        _finishFunding();
        _deposit(bob, 100e18);

        vm.warp(START + EPOCH);
        _syncAs(bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        ILCCVault.Account memory account = vault.getAccount(bob);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCommitment, 200e18);
        _assertNoUserDefaulted(logs, address(vault), bob, 0);
    }

    function testOldActiveExposureDefaultsBeforePostSettlementPendingDeposit() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        _finishFunding();
        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.UserDefaulted(alice, 0, 100e18, 200e18);
        _deposit(alice, 50e18);

        vm.warp(START + EPOCH);
        _syncAs(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 150e18);
        assertEq(account.activeCommitment, 300e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testMaturedExiterIsNotDefaultedByLaterCall() public {
        vm.recordLogs();
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
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNoUserDefaulted(logs, address(vault), alice, 1);
    }

    function testRepeatMaterializeIsIdempotent() public {
        _deposit(alice, 100e18);
        vault.materializeAccount(alice);

        bytes32 beforeHash = keccak256(abi.encode(vault.getAccount(alice)));
        vault.materializeAccount(alice);
        bytes32 afterHash = keccak256(abi.encode(vault.getAccount(alice)));

        assertEq(afterHash, beforeHash);
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
            vault.fundCall(false);

            vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL + FUNDING);
            vault.finalizeEpochSlash(epoch);
        }
    }

    function MAX_MATERIALIZE_STEPS_PLUS_ONE() internal pure returns (uint256) {
        return 65;
    }
}
