// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCFundingTest is LCCBase {
    function testFundingPullsExactObligationDeliversNotificationVaultAndReleasesMargin() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(75e18);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 obligation = _fund(alice);

        assertEq(obligation, 50e18);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - 50e18);
        assertEq(notificationVault.balanceOf(alice), 50e18);
        assertEq(margin.balanceOf(alice), 1_000_000e18 - 75e18);
        assertTrue(vault.fundedEpoch(0, alice));

        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 75e18);
        assertEq(account.activeCommitment, 150e18);
    }

    function testObligationRoundsUpAndMarginReleaseRoundsDown() public {
        _deposit(alice, 1e18);
        _openCall(1);

        uint256 obligation = _fund(alice);

        assertEq(obligation, 1);
        assertEq(notificationVault.balanceOf(alice), 1);

        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 1e18);
        assertEq(account.activeCommitment, 2e18 - 1);
    }

    function testSmallObligationBelowUsd3MinDepositSucceedsWhenVaultExempt() public {
        usd3.setMinDeposit(100e18);
        usd3.setSupplyCapExempt(address(vault), true);

        _deposit(alice, 1e18);
        _openCall(1);

        uint256 obligation = _fund(alice);

        assertEq(obligation, 1);
        assertEq(notificationVault.balanceOf(alice), 1);
        assertTrue(vault.fundedEpoch(0, alice));
    }

    function testSmallObligationBelowUsd3MinDepositRevertsWhenVaultNotExempt() public {
        usd3.setMinDeposit(100e18);

        _deposit(alice, 1e18);
        _openCall(1);

        vm.warp(START + NORMAL + PRE_CALL);
        vm.expectRevert(bytes("<min"));
        vm.prank(alice);
        vault.fundCall();
    }

    function testFundingRevertsWhenNotificationVaultRejectsAndRetrySucceeds() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        notificationVault.setDepositHookReverts(true);
        vm.warp(START + NORMAL + PRE_CALL);
        vm.expectRevert(bytes("!notification"));
        vm.prank(alice);
        vault.fundCall();

        notificationVault.setDepositHookReverts(false);
        uint256 obligation = _fund(alice);

        assertEq(obligation, 100e18);
        assertEq(notificationVault.balanceOf(alice), 100e18);
        assertTrue(vault.fundedEpoch(0, alice));
    }

    function testAggregateFundingExceedsCallAmountFromCeilDust() public {
        _deposit(alice, 1e18); // commitment 2e18
        _deposit(bob, 1e18); // commitment 2e18

        // Call 3 against a 4e18 denominator: each pro-rata share is 1.5, ceil-rounded to 2.
        _openCall(3);

        uint256 aliceObligation = _fund(alice);
        uint256 bobObligation = _fund(bob);

        assertEq(aliceObligation, 2);
        assertEq(bobObligation, 2);

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.callAmount, 3);
        assertEq(state.fundedAmount, 4);
        assertGt(state.fundedAmount, state.callAmount);

        assertEq(notificationVault.balanceOf(alice), 2);
        assertEq(notificationVault.balanceOf(bob), 2);
    }

    function testFundingDoesNotExtinguishOtherObligationAndSlashesNonFunder() public {
        _deployAuctionVault();
        _deposit(alice, 1e18); // commitment 2e18
        _deposit(bob, 1e18); // commitment 2e18

        // Call 1 against a 4e18 denominator: each ceil-rounded obligation is the minimum 1 unit.
        _openCall(1);

        uint256 aliceObligation = _fund(alice);
        assertEq(aliceObligation, 1);

        // Alice fully covering the call does not release Bob from his own all-or-nothing obligation.
        assertEq(vault.obligationOf(0, bob), 1);

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.fundedAmount, state.callAmount);

        _finishFunding();
        uint256 treasuryBefore = margin.balanceOf(treasury);
        vault.finalizeEpochSlash(0);

        // Bob forfeits his full margin; fundedAmount >= callAmount leaves no shortfall, so only the slash fee is
        // swept and the return pool is reactivated for lazy attribution.
        assertEq(margin.balanceOf(treasury) - treasuryBefore, 0.1e18);
        assertEq(vault.getAuctionState(0).shortfallAmount, 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testFundingRequiresFundingPhaseAndCannotRepeat() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(alice);
        vault.fundCall();

        _fund(alice);

        vm.expectRevert(LCCErrorsLib.AlreadyFunded.selector);
        vm.prank(alice);
        vault.fundCall();
    }
}
