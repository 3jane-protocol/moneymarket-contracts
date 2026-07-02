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
        assertEq(
            state.marginReleased + state.fundedUsersRemainingMargin + margin.balanceOf(treasury) + state.returnPool,
            200e18
        );
        assertEq(margin.balanceOf(treasury), 10e18);
        assertEq(state.returnPool, 90e18);
        assertEq(vault.totals().activeMargin, 90e18);
        assertEq(vault.totals().activeCommitment, 180e18);

        vault.finalizeEpochSlash(0);
        assertEq(margin.balanceOf(treasury), 10e18);
    }

    function testSlashFeeZeroReturnsAllSurplus() public {
        vm.prank(owner);
        vault.setSlashFeeBps(0);

        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(0);
        assertEq(margin.balanceOf(treasury), 0);
        assertEq(state.returnPool, 100e18);
        assertEq(vault.totals().activeMargin, 100e18);
        assertEq(vault.totals().activeCommitment, 200e18);
    }

    function testSlashFeeFullSendsAllSurplusToTreasury() public {
        vm.prank(owner);
        vault.setSlashFeeBps(10_000);

        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(0);
        assertEq(margin.balanceOf(treasury), 100e18);
        assertEq(state.returnPool, 0);
        assertEq(vault.totals().activeMargin, 0);
        assertEq(vault.totals().activeCommitment, 0);
    }

    function testSlashFeeFullDisposesWithoutOracle() public {
        vm.prank(owner);
        vault.setSlashFeeBps(10_000);

        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();

        oracle.setPrice(0);
        vault.finalizeEpochSlash(0);

        assertEq(margin.balanceOf(treasury), 100e18);
        assertEq(vault.getEpochState(0).returnPool, 0);
    }

    function testAutoSyncFinalizesEligibleSlashAndMaterializationDoesNotDoubleDecrement() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();

        _syncAs(alice);

        assertEq(margin.balanceOf(treasury), 10e18);
        assertTrue(vault.defaultedEpoch(0, alice));
        assertEq(vault.totals().activeMargin, 90e18);

        _syncAs(alice);
        assertEq(margin.balanceOf(treasury), 10e18);
        assertEq(vault.totals().activeMargin, 90e18);
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
        assertEq(margin.balanceOf(treasury), 24e18);
    }

    function testExitingDefaulterDoesNotBrickMaturityFoldWithoutUserMaterialization() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        _openCall(100e18);

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);

        assertEq(margin.balanceOf(treasury), 10e18);
        assertEq(vault.exitBucketMarginByMaturity(1), 0);
        assertEq(vault.totals().activeMargin, 140e18);

        _deposit(carol, 25e18);
        assertEq(vault.totals().activeMargin, 165e18);
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
        assertEq(vault.totals().activeMargin, 140e18);
        assertEq(vault.claimableExitedMargin(alice), 0);
    }
}
