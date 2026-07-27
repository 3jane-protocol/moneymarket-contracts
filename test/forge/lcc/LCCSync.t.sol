// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";

contract LCCSyncTest is LCCBase {
    uint256 internal constant HUGE_EPOCH_GAP = 20_000;

    function testSyncActivatesPendingBeforeCapSensitiveDeposit() public {
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);

        assertEq(vault.totals().pendingMargin, 0);
        assertEq(vault.totals().activeMargin, 150e18);
    }

    function testSyncFoldsMaturedExitsBeforeNextAction() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);

        assertEq(vault.totals().activeMargin, 50e18);
    }

    function testExplicitFinalizeAndAutoSyncReachSameState() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();

        vm.prank(bob);
        vault.materializeAccount(bob);

        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(vault.totals().activeMargin, 100e18);
    }

    function testSparseSyncSkipsLargeEmptyEpochGapWithBoundedGas() public {
        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);

        uint256 gasBefore = gasleft();
        _deposit(alice, 100e18);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 700_000);
        assertEq(vault.totals().activeMargin, 100e18);
        ILCCVault.SyncState memory state = vault.syncState();
        assertEq(state.lastActivationFolded, HUGE_EPOCH_GAP);
        // Both view fields reconstruct from the single stored lastFolded; asserted as a pair once here.
        assertEq(state.lastMaturityFolded, HUGE_EPOCH_GAP);
    }

    function testSparseSyncFoldsPendingAfterLargeDormantGapOnce() public {
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);
        _syncAs(alice);

        assertEq(vault.pendingMarginByActivationEpoch(1), 0);
        assertEq(vault.pendingCommitmentByActivationEpoch(1), 0);
        assertEq(vault.totals().pendingMargin, 0);
        assertEq(vault.totals().activeMargin, 100e18);
        ILCCVault.SyncState memory state = vault.syncState();
        assertEq(state.lastActivationFolded, HUGE_EPOCH_GAP);
    }

    function testSparseSyncFoldsMaturityAfterLargeDormantGapOnce() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        uint256 maturity = vault.requestExit();

        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);
        _syncAs(alice);

        assertEq(vault.exitBucketMarginByMaturity(maturity), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), 0);
        assertEq(vault.totals().activeMargin, 0);
        assertEq(vault.claimableExitedMargin(alice), 100e18);
        ILCCVault.SyncState memory state = vault.syncState();
        assertEq(state.lastActivationFolded, HUGE_EPOCH_GAP);
    }

    function testSparseSyncFoldsPendingAndMaturityInSameSync() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        uint256 maturity = vault.requestExit();

        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(bob, 50e18);

        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);
        _syncAs(bob);

        assertEq(vault.pendingMarginByActivationEpoch(1), 0);
        assertEq(vault.exitBucketMarginByMaturity(maturity), 0);
        assertEq(vault.totals().pendingMargin, 0);
        assertEq(vault.totals().activeMargin, 50e18);
        assertEq(vault.claimableExitedMargin(alice), 100e18);
        ILCCVault.SyncState memory state = vault.syncState();
        assertEq(state.lastActivationFolded, HUGE_EPOCH_GAP);
    }

    function testEligibleUnfinalizedReplayBarrierDoesNotAdvanceStoredFoldWatermarks() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();
        _openCall(100e18);

        vm.warp(START + EPOCH);

        assertEq(vault.claimableExitedMargin(alice), 0);
        ILCCVault.SyncState memory state = vault.syncState();
        assertEq(state.lastActivationFolded, 0);

        // A mutating synced touch finalizes the eligible epoch, and only then may the stored watermark advance.
        vault.materializeAccount(alice);
        state = vault.syncState();
        assertEq(state.lastActivationFolded, 1);
        assertTrue(vault.getEpochState(0).slashFinalized);
    }

    function testSparseSyncMaturityPruningDoesNotSkipSwapRemovedDueBucket() public {
        LCCVault tightExitVault = _newVault(_params(address(oracle), 1_000e18, CAP, 2_000));
        vault = tightExitVault;
        _mintAndApprove(alice, 1_000_000e18, 1_000_000e18);
        _mintAndApprove(bob, 1_000_000e18, 1_000_000e18);
        _mintAndApprove(carol, 1_000_000e18, 1_000_000e18);

        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _deposit(carol, 100e18);

        vm.prank(alice);
        uint256 aliceMaturity = vault.requestExit();
        vm.prank(bob);
        uint256 bobMaturity = vault.requestExit();
        vm.prank(carol);
        uint256 carolMaturity = vault.requestExit();

        assertTrue(aliceMaturity < bobMaturity && bobMaturity < carolMaturity);

        vm.warp(START + EPOCH * (carolMaturity + 1));
        _syncAs(alice);

        assertEq(vault.exitBucketMarginByMaturity(aliceMaturity), 0);
        assertEq(vault.exitBucketMarginByMaturity(bobMaturity), 0);
        assertEq(vault.exitBucketMarginByMaturity(carolMaturity), 0);
        assertEq(vault.totals().activeMargin, 0);
        assertEq(vault.claimableExitedMargin(alice), 100e18);
        assertEq(vault.claimableExitedMargin(bob), 100e18);
        assertEq(vault.claimableExitedMargin(carol), 100e18);
    }

    function testSparseSyncRemainingClaimAfterLargeDormantGap() public {
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);
        vm.prank(owner);
        vault.shutdown();

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimRemainingMargin(alice);

        assertEq(claimed, 100e18);
        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
        assertEq(vault.totals().activeMargin, 0);
    }
}
