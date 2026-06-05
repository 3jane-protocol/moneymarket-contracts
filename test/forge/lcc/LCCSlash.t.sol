// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";

contract LCCSlashTest is LCCBase {
    function testSlashConservationAndTreasuryReceivesOnce() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(400e18);
        _fund(alice);
        _finishFunding();

        vault.finalizeEpochSlash(0);

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.rawMarginReleased + state.honoredRawMarginRemaining + margin.balanceOf(treasury), 200e18);
        assertEq(margin.balanceOf(treasury), 100e18);
        assertEq(vault.totalActiveMargin(), 0);
        assertEq(vault.totalActiveCallableUsdc(), 0);

        vault.finalizeEpochSlash(0);
        assertEq(margin.balanceOf(treasury), 100e18);
    }

    function testAutoSyncFinalizesEligibleSlashAndMaterializationDoesNotDoubleDecrement() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();

        _syncAs(alice);

        assertEq(margin.balanceOf(treasury), 100e18);
        assertTrue(vault.defaultedEpoch(0, alice));
        assertEq(vault.totalActiveMargin(), 0);

        _syncAs(alice);
        assertEq(margin.balanceOf(treasury), 100e18);
        assertEq(vault.totalActiveMargin(), 0);
    }

    function testDefaultedUserCanDepositAgainAndDefaultInLaterEpoch() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        _syncAs(alice);

        vm.warp(START + EPOCH);
        _deposit(alice, 50e18);

        vm.warp(START + EPOCH + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(1, 50e18);
        vm.warp(START + EPOCH + NORMAL + PRE_CALL + FUNDING);
        _syncAs(alice);

        assertTrue(vault.defaultedEpoch(0, alice));
        assertTrue(vault.defaultedEpoch(1, alice));
        assertEq(margin.balanceOf(treasury), 150e18);
    }

    function testExitingDefaulterDoesNotBrickMaturityFoldWithoutUserMaterialization() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        _openCall(100e18);

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);

        assertEq(margin.balanceOf(treasury), 100e18);
        assertEq(vault.exitRequestedMarginByMaturity(1), 0);
        assertEq(vault.totalActiveMargin(), 50e18);

        _deposit(carol, 25e18);
        assertEq(vault.totalActiveMargin(), 75e18);
    }

    function testExitingDefaulterMaterializedAfterMaturityCannotDoubleDecrement() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        _openCall(100e18);

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);

        _syncAs(alice);

        assertTrue(vault.defaultedEpoch(0, alice));
        assertEq(vault.totalActiveMargin(), 50e18);
        assertEq(vault.claimableExitedMargin(alice), 0);
    }
}
