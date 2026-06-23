// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";

contract LCCSyncTest is LCCBase {
    uint256 internal constant HUGE_EPOCH_GAP = 20_000;

    function testSyncActivatesPendingBeforeCapSensitiveDeposit() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);

        assertEq(vault.totalPendingMargin(), 0);
        assertEq(vault.totalActiveMargin(), 150e18);
    }

    function testSyncFoldsMaturedExitsBeforeNextAction() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);

        assertEq(vault.totalActiveMargin(), 50e18);
    }

    function testExplicitFinalizeAndAutoSyncReachSameState() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();

        vm.prank(bob);
        vault.materializeAccount(bob);

        assertEq(margin.balanceOf(treasury), 100e18);
        assertEq(vault.totalActiveMargin(), 0);
    }

    function testSparseSyncSkipsLargeEmptyEpochGapWithBoundedGas() public {
        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);

        uint256 gasBefore = gasleft();
        _deposit(alice, 100e18);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 700_000);
        assertEq(vault.totalActiveMargin(), 100e18);
    }

    function testSparseSyncFoldsPendingAfterLargeDormantGapOnce() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);
        _syncAs(alice);

        assertEq(vault.pendingMarginByActivationEpoch(1), 0);
        assertEq(vault.pendingCommitmentByActivationEpoch(1), 0);
        assertEq(vault.totalPendingMargin(), 0);
        assertEq(vault.totalActiveMargin(), 100e18);
    }

    function testSparseSyncFoldsMaturityAfterLargeDormantGapOnce() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        uint256 maturity = vault.requestExit();

        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);
        _syncAs(alice);

        assertEq(vault.exitBucketMarginByMaturity(maturity), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), 0);
        assertEq(vault.totalActiveMargin(), 0);
        assertEq(vault.claimableExitedMargin(alice), 100e18);
    }

    function testSparseSyncFoldsPendingAndMaturityInSameSync() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        uint256 maturity = vault.requestExit();

        vm.warp(START + NORMAL);
        _deposit(bob, 50e18);

        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);
        _syncAs(bob);

        assertEq(vault.pendingMarginByActivationEpoch(1), 0);
        assertEq(vault.exitBucketMarginByMaturity(maturity), 0);
        assertEq(vault.totalPendingMargin(), 0);
        assertEq(vault.totalActiveMargin(), 50e18);
        assertEq(vault.claimableExitedMargin(alice), 100e18);
    }

    function testSparseSyncMaturityPruningDoesNotSkipSwapRemovedDueBucket() public {
        LeveragedCallableCreditVault tightExitVault =
            new LeveragedCallableCreditVault(_params(address(oracle), 1_000e18, CAP, 2_000));
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
        assertEq(vault.totalActiveMargin(), 0);
        assertEq(vault.claimableExitedMargin(alice), 100e18);
        assertEq(vault.claimableExitedMargin(bob), 100e18);
        assertEq(vault.claimableExitedMargin(carol), 100e18);
    }

    function testSparseSyncEmergencyClaimAfterLargeDormantGap() public {
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH * HUGE_EPOCH_GAP);
        vm.prank(owner);
        vault.shutdown();

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimEmergencyMargin(alice);

        assertEq(claimed, 100e18);
        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
        assertEq(vault.totalActiveMargin(), 0);
    }
}
