// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCExitTest is LCCBase {
    function testExitMaturesAndClaimsFullMargin() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        uint256 maturity = vault.requestExit();
        assertEq(maturity, 1);

        vm.warp(START + EPOCH);
        assertEq(vault.claimableExitedMargin(alice), 100e18);

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimExitedMargin(alice);

        assertEq(claimed, 100e18);
        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
        assertEq(vault.totals().activeMargin, 0);
    }

    function testExitBlocksNewDepositsAndRemainsCallableUntilMaturity() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        vault.requestExit();

        vm.expectRevert(LCCErrorsLib.ExitInProgress.selector);
        _deposit(alice, 1e18);

        _openCall(100e18);
        assertEq(vault.obligationOf(0, alice), 100e18);
    }

    function testFifoExitAssignmentAndOversizedExit() public {
        vault = new LeveragedCallableCreditVault(_params(address(oracle), 1_000e18, 2_000e18, 1_000));
        vm.startPrank(alice);
        margin.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        margin.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        _deposit(alice, 400e18);
        _deposit(bob, 60e18);

        vm.prank(alice);
        assertEq(vault.requestExit(), 1);

        vm.prank(bob);
        assertEq(vault.requestExit(), 2);
    }

    function testCannotClaimBeforeMaturity() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        vm.expectRevert(LCCErrorsLib.ExitNotMature.selector);
        vm.prank(alice);
        vault.claimExitedMargin(alice);
    }

    function testCannotRequestExitWithPendingOnlyDeposit() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.PendingDepositExists.selector);
        vm.prank(alice);
        vault.requestExit();
    }

    function testCannotRequestExitWithActiveAndPendingDeposit() public {
        _deposit(alice, 100e18);

        vm.warp(START + NORMAL);
        _deposit(alice, 50e18);

        vm.expectRevert(LCCErrorsLib.PendingDepositExists.selector);
        vm.prank(alice);
        vault.requestExit();
    }

    function testCanRequestExitAfterPendingDepositActivates() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(), 2);
    }

    function testExitingFunderReducesMaturityBucketAndClaimsRemainder() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        _openCall(100e18);
        _fund(alice);

        assertEq(vault.exitBucketMarginByMaturity(1), 50e18);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 100e18);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 50e18);
        assertEq(vault.totals().activeMargin, 0);
    }

    function testPrunedMaturityBucketCanBeReusedInSameEpoch() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);

        vm.prank(alice);
        assertEq(vault.requestExit(), 1);

        _openCall(400e18);
        _fund(alice);

        assertEq(vault.exitBucketMarginByMaturity(1), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 0);

        vm.prank(bob);
        assertEq(vault.requestExit(), 1);

        assertEq(vault.exitBucketMarginByMaturity(1), 100e18);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 200e18);
    }

    function testExitRequestedAfterCallOpenRemainsLiableForOpenCall() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.prank(alice);
        assertEq(vault.requestExit(), 1);

        vm.warp(START + EPOCH);
        _syncAs(alice);

        assertTrue(vault.defaultedEpoch(0, alice));
        assertEq(margin.balanceOf(treasury), 10e18);
        assertEq(vault.claimableExitedMargin(alice), 0);
    }
}
