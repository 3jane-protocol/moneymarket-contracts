// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {IERC20Errors} from "../../../lib/openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";

contract LCCFundingTest is LCCBase {
    function _assertFundingUntouched(address user, uint256 expectedCommitment) internal view {
        assertFalse(vault.fundedEpoch(0, user));
        assertEq(vault.getEpochState(0).fundedAmount, 0);
        assertEq(vault.getAccount(user).activeCommitment, expectedCommitment);
    }

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

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 75e18);
        assertEq(account.activeCommitment, 150e18);
    }

    function testObligationRoundsUpAndMarginReleaseRoundsDown() public {
        _deposit(alice, 1e18);
        _openCall(1);

        uint256 obligation = _fund(alice);

        assertEq(obligation, 1);
        assertEq(notificationVault.balanceOf(alice), 1);

        ILCCVault.Account memory account = vault.getAccount(alice);
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
        vault.fundCall(false);
    }

    function testFundingRevertsWhenNotificationVaultRejectsAndRetrySucceeds() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        notificationVault.setDepositHookReverts(true);
        vm.warp(START + NORMAL + PRE_CALL);
        vm.expectRevert(bytes("!notification"));
        vm.prank(alice);
        vault.fundCall(false);

        _assertFundingUntouched(alice, 200e18);
        assertEq(usd3.balanceOf(address(vault)), 0);

        notificationVault.setDepositHookReverts(false);
        uint256 obligation = _fund(alice);

        assertEq(obligation, 100e18);
        assertEq(notificationVault.balanceOf(alice), 100e18);
        assertTrue(vault.fundedEpoch(0, alice));
    }

    function testDustSelfFundingAtPpsAboveOneUsesTopUpOnlyForDeliveryAndRingFence() public {
        _seedUsd3(2, 1);
        _deposit(alice, 1e18);
        _openCall(1);

        uint256 ringFencedLiquidityBefore = usd3.ringFencedLiquidity();
        uint256 payerBalanceBefore = usdc.balanceOf(alice);
        vm.warp(START + NORMAL + PRE_CALL);
        vm.expectEmit(true, true, true, true, address(vault));
        emit LCCEventsLib.CallFunded(alice, alice, 0, 1, 2);
        vm.prank(alice);
        uint256 obligation = vault.fundCall(false);

        assertEq(obligation, 1);
        assertEq(usdc.balanceOf(alice), payerBalanceBefore - 2);
        assertEq(notificationVault.balanceOf(alice), 1);
        assertEq(usd3.ringFencedLiquidity() - ringFencedLiquidityBefore, 2);
        assertEq(vault.getEpochState(0).fundedAmount, 1);
        assertEq(vault.getAccount(alice).activeCommitment, 2e18 - 1);
    }

    function testDustRollingFundingAtPpsAboveOneRetainsObligationAccounting() public {
        _seedUsd3(2, 1);
        _deposit(alice, 1e18);
        _openCall(1);

        uint256 obligation = _fundRolling(alice);

        assertEq(obligation, 1);
        assertEq(notificationVault.balanceOf(alice), 1);
        assertEq(vault.getEpochState(0).fundedAmount, 1);
        assertEq(vault.getAccount(alice).activeMargin, 1e18);
        assertEq(vault.getAccount(alice).activeCommitment, 2e18);
    }

    function testPushFundingAtPpsAboveOneBoundaryNeedsNoTopUp() public {
        _seedUsd3(2, 1);
        _deposit(alice, 1e18);
        _openCall(2);

        uint256 payerBalanceBefore = usdc.balanceOf(carol);
        uint256 obligation = _fundFor(carol, alice);

        assertEq(obligation, 2);
        assertEq(usdc.balanceOf(carol), payerBalanceBefore - 2);
        assertEq(notificationVault.balanceOf(alice), 1);
        assertEq(vault.getEpochState(0).fundedAmount, 2);
        assertEq(vault.getAccount(alice).activeCommitment, 2e18 - 2);
    }

    function testDustTopUpDoesNotReduceAnotherAccountsShortfall() public {
        _deployAuctionVault();
        _seedUsd3(2, 1);
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);
        _openCall(2);

        assertEq(_fund(alice), 1);
        assertEq(vault.obligationOf(0, bob), 1);
        assertEq(vault.getEpochState(0).fundedAmount, 1);

        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.getAuctionState(0).shortfallAmount, 1);
    }

    function testFundingAtOneToOnePpsPullsAndAccountsExactObligation() public {
        _deposit(alice, 1e18);
        _openCall(1);

        uint256 payerBalanceBefore = usdc.balanceOf(alice);
        assertEq(usd3.previewMint(1), 1);
        assertEq(_fund(alice), 1);

        assertEq(usdc.balanceOf(alice), payerBalanceBefore - 1);
        assertEq(notificationVault.balanceOf(alice), 1);
        assertEq(vault.getEpochState(0).fundedAmount, 1);
    }

    function testSameBlockPpsJumpBindsFundingTopUpBeforeStateWrites() public {
        _seedUsd3(2, 0);
        _deposit(alice, 1e18);
        _openCall(1);

        uint256 quotedFundingAmount = usd3.previewMint(1);
        usd3.reportProfit(2_002);
        assertEq(quotedFundingAmount, 1);
        assertEq(usd3.previewMint(1), 1_002);

        vm.warp(START + NORMAL + PRE_CALL);
        vm.expectRevert(LCCErrorsLib.FundingTopUpExcessive.selector);
        vm.prank(alice);
        vault.fundCall(false);

        _assertFundingUntouched(alice, 2e18);
    }

    function testMaximumFundingTopUpBoundarySucceeds() public {
        _seedUsd3(1, 1_000);
        assertEq(usd3.previewMint(1), 1_001);

        _deposit(alice, 1e18);
        _openCall(1);
        uint256 payerBalanceBefore = usdc.balanceOf(alice);
        assertEq(_fund(alice), 1);

        assertEq(usdc.balanceOf(alice), payerBalanceBefore - 1_001);
        assertEq(vault.getEpochState(0).fundedAmount, 1);
        assertEq(notificationVault.balanceOf(alice), 1);
    }

    function testExactObligationAllowanceRevertsForTopUpThenRetrySucceeds() public {
        _seedUsd3(2, 1);
        _deposit(alice, 1e18);
        _openCall(1);
        vm.warp(START + NORMAL + PRE_CALL);

        vm.prank(alice);
        usdc.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 1, 2));
        vm.prank(alice);
        vault.fundCall(false);

        _assertFundingUntouched(alice, 2e18);

        vm.prank(alice);
        usdc.approve(address(vault), 2);
        vm.prank(alice);
        assertEq(vault.fundCall(false), 1);
    }

    function testUsd3DeliveryFailureRollsBackDustFundingAtomically() public {
        _seedUsd3(2, 1);
        _deposit(alice, 1e18);
        _openCall(1);
        usd3.setDepositHookReverts(true);
        vm.warp(START + NORMAL + PRE_CALL);

        uint256 payerBalanceBefore = usdc.balanceOf(alice);
        vm.expectRevert(bytes("!allowed"));
        vm.prank(alice);
        vault.fundCall(false);

        assertEq(usdc.balanceOf(alice), payerBalanceBefore);
        _assertFundingUntouched(alice, 2e18);
    }

    function testDegenerateUsd3PauseShutdownAvoidsSlashAndAllowsWindDownClaim() public {
        _seedUsd3(1, 0);
        usdc.burn(address(usd3), 1);
        assertEq(usd3.totalSupply(), 1);
        assertEq(usd3.totalAssets(), 0);
        assertEq(usd3.previewMint(1), 0);

        _deposit(alice, 100e18);
        _openCall(100e18);
        vm.warp(START + NORMAL + PRE_CALL);
        vm.expectRevert(LCCErrorsLib.FundingDeliveryImpossible.selector);
        vm.prank(alice);
        vault.fundCall(false);

        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(state.slashFinalized);
        assertTrue(state.slashDisabledByShutdown);
        assertEq(state.slashedMargin, 0);
        uint256 marginBefore = margin.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
        assertEq(margin.balanceOf(alice), marginBefore + 100e18);
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

        ILCCVault.EpochState memory state = vault.getEpochState(0);
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

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.fundedAmount, state.callAmount);

        _finishFunding();
        uint256 treasuryBefore = margin.balanceOf(treasury);
        vault.finalizeEpochSlash(0);

        // Bob forfeits his full margin; fundedAmount >= callAmount leaves no shortfall, so no auction award creates a
        // fee basis and the return pool is reactivated for lazy attribution.
        assertEq(margin.balanceOf(treasury) - treasuryBefore, 0);
        assertEq(vault.getAuctionState(0).shortfallAmount, 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testFundingRequiresFundingPhaseAndCannotRepeat() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(alice);
        vault.fundCall(false);

        _fund(alice);

        vm.expectRevert(LCCErrorsLib.AlreadyFunded.selector);
        vm.prank(alice);
        vault.fundCall(false);
    }
}
