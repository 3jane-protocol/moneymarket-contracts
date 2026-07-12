// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";

contract LCCRollTest is LCCBase {
    function testRolledSelfFundKeepsAccountTotalsAndRecordsNetSettlementCommitment() public {
        uint256 commitment = _deposit(alice, 100e18);
        _openCall(50e18);

        ILCCVault.Account memory beforeAccount = vault.getAccount(alice);
        ILCCVault.Totals memory beforeTotals = vault.totals();
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceMarginBefore = margin.balanceOf(alice);

        uint256 obligation = _fundRolling(alice);

        assertEq(obligation, 50e18);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - obligation);
        assertEq(notificationVault.balanceOf(alice), obligation);
        assertEq(margin.balanceOf(alice), aliceMarginBefore);
        assertTrue(vault.fundedEpoch(0, alice));

        ILCCVault.Account memory afterAccount = vault.getAccount(alice);
        assertEq(afterAccount.activeMargin, beforeAccount.activeMargin);
        assertEq(afterAccount.activeCommitment, beforeAccount.activeCommitment);

        ILCCVault.Totals memory afterTotals = vault.totals();
        assertEq(afterTotals.activeMargin, beforeTotals.activeMargin);
        assertEq(afterTotals.activeCommitment, beforeTotals.activeCommitment);
        assertEq(afterTotals.pendingMargin, beforeTotals.pendingMargin);
        assertEq(afterTotals.pendingCommitment, beforeTotals.pendingCommitment);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.fundedAmount, obligation);
        assertEq(state.marginReleased, 0);
        assertEq(state.fundedUsersRemainingMargin, 100e18);
        assertEq(state.fundedUsersRemainingCommitment, commitment - obligation);
    }

    function testRollerOnlyEpochFinalizesWithoutSlash() public {
        _deposit(alice, 100e18);
        _openCall(50e18);
        _fundRolling(alice);

        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(state.slashFinalized);
        assertEq(state.slashedMargin, 0);
        assertEq(state.commitmentDenominator - state.fundedAmount - state.fundedUsersRemainingCommitment, 0);
    }

    function testMixedRollAmortizeDefaultAuctionConservesAndReattributesReturnPool() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _deposit(carol, 100e18);

        _openCall(300e18);
        assertEq(_fundRolling(alice), 100e18);
        assertEq(_fund(bob), 100e18);

        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.fundedAmount, 200e18);
        assertEq(state.marginReleased, 50e18);
        assertEq(state.fundedUsersRemainingMargin, 150e18);
        assertEq(state.fundedUsersRemainingCommitment, 200e18);
        assertEq(state.slashedMargin, 100e18);
        assertEq(state.commitmentDenominator - state.fundedAmount - state.fundedUsersRemainingCommitment, 200e18);
        assertEq(state.marginReleased + state.fundedUsersRemainingMargin + state.slashedMargin, state.marginAtCallOpen);
        assertEq(
            state.fundedAmount + state.fundedUsersRemainingCommitment
                + (state.commitmentDenominator - state.fundedAmount - state.fundedUsersRemainingCommitment),
            state.commitmentDenominator
        );

        LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(0);
        assertEq(auction.shortfallAmount, state.callAmount - state.fundedAmount);
        assertEq(auction.marginPool, 100e18);

        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 5);
        vm.prank(alice);
        (uint256 filled, uint256 award) = vault.takeAuction(100e18);
        assertEq(filled, 100e18);
        assertEq(award, 50e18);

        state = vault.getEpochState(0);
        // fee = min(awarded 50e18 x 10%, surplus 50e18) = 5e18.
        assertEq(state.returnPool, 45e18);
        assertEq(state.returnCommitment, 90e18);
        assertEq(margin.balanceOf(treasury), 5e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.UserDefaulted(carol, 0, 100e18, 200e18);
        vault.materializeAccount(carol);
        ILCCVault.Account memory carolAccount = vault.getAccount(carol);
        assertEq(carolAccount.activeMargin, 45e18);
        assertEq(carolAccount.activeCommitment, 90e18);
    }

    function testLiveExiterCannotRollButCanAmortizeAndClaimedExiterCanRollAfterRedeposit() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        _openCall(50e18);
        vm.warp(START + NORMAL + PRE_CALL);
        vm.expectRevert(LCCErrorsLib.ExitInProgress.selector);
        vm.prank(alice);
        vault.fundCall(true);

        vm.prank(alice);
        assertEq(vault.fundCall(false), 50e18);

        vm.warp(START);
        _deployVaultWithParams(_params(CAP, CAP));
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 100e18);

        _deposit(alice, 100e18);
        _openCallAtEpoch(1, 50e18);
        assertEq(_fundRollingAtEpoch(alice, 1), 50e18);
    }

    function testPushFundingAlwaysAmortizesAndFrontRunDeniesRollRecoverableByDeposit() public {
        _deposit(alice, 100e18);
        _openCall(50e18);

        uint256 aliceMarginBefore = margin.balanceOf(alice);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        uint256 obligation = _fundFor(bob, alice);

        assertEq(obligation, 50e18);
        assertEq(usdc.balanceOf(bob), bobUsdcBefore - obligation);
        assertEq(notificationVault.balanceOf(alice), obligation);
        assertEq(margin.balanceOf(alice), aliceMarginBefore + 25e18);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 75e18);
        assertEq(account.activeCommitment, 150e18);

        vm.expectRevert(LCCErrorsLib.AlreadyFunded.selector);
        vm.prank(alice);
        vault.fundCall(true);

        _deposit(alice, 25e18);
        account = vault.getAccount(alice);
        assertEq(account.activeMargin + account.pendingMargin, 100e18);
        assertEq(account.activeCommitment + account.pendingCommitment, 200e18);
    }

    function testMultiEpochRollRearmsAndLaterAmortizesNormally() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);

        _openCall(100e18);
        uint256 epoch0AliceObligation = _fundRolling(alice);
        _fund(bob);
        assertEq(epoch0AliceObligation, 50e18);

        _finishFunding();
        vault.finalizeEpochSlash(0);

        _openCallAtEpoch(1, 100e18);
        uint256 epoch1AliceObligation = _fundRollingAtEpoch(alice, 1);
        _fundAtEpoch(bob, 1);
        assertGt(epoch1AliceObligation, epoch0AliceObligation);

        _finishFundingAtEpoch(1);
        vault.finalizeEpochSlash(1);

        _openCallAtEpoch(2, 100e18);
        ILCCVault.Account memory beforeAmortize = vault.getAccount(alice);
        uint256 aliceBalanceBefore = margin.balanceOf(alice);
        uint256 epoch2AliceObligation = _fundAtEpoch(alice, 2);

        // The rolled epochs left the margin:commitment ratio untouched, so the post-roll amortize releases the
        // exact proportional amount.
        uint256 expectedRelease = beforeAmortize.activeMargin * epoch2AliceObligation / beforeAmortize.activeCommitment;
        ILCCVault.Account memory afterAmortize = vault.getAccount(alice);
        assertGt(epoch2AliceObligation, epoch1AliceObligation);
        assertEq(afterAmortize.activeCommitment, beforeAmortize.activeCommitment - epoch2AliceObligation);
        assertEq(afterAmortize.activeMargin, beforeAmortize.activeMargin - expectedRelease);
        assertEq(margin.balanceOf(alice), aliceBalanceBefore + expectedRelease);
    }

    function testRollThenRequestExitClaimsFullNeverAmortizedMargin() public {
        _deposit(alice, 100e18);
        _openCall(50e18);
        _fundRolling(alice);

        vm.prank(alice);
        uint256 maturity = vault.requestExit();

        assertEq(vault.exitBucketMarginByMaturity(maturity), 100e18);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), 200e18);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 100e18);
    }

    function testRolledPositionClaimsFullMarginAtTerminalAndAfterMidWindowShutdown() public {
        _deployVaultWithParams(_termParams(1));
        _deposit(alice, 100e18);
        _openCall(50e18);
        _fundRolling(alice);

        vm.warp(START + EPOCH);
        uint256 aliceBefore = margin.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
        assertEq(margin.balanceOf(alice), aliceBefore + 100e18);

        _deployVaultWithParams(_params(CAP, CAP));
        _deposit(alice, 100e18);
        _openCall(50e18);
        _fundRolling(alice);

        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.slashedMargin, 0);

        aliceBefore = margin.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
        assertEq(margin.balanceOf(alice), aliceBefore + 100e18);
    }
}
