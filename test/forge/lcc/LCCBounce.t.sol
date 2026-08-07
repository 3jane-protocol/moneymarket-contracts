// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase, LCCBlacklistMockToken} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";

contract LCCBounceTest is LCCBase {
    uint256 internal constant MATURITY_LIST_SLOT = 21;

    function testNonBouncerReverts() public {
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.Unauthorized.selector);
        vm.prank(stranger);
        vault.bounceCommitment(alice, 1);
    }

    function testPendingAuctionReverts() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, 1);
    }

    function testOpenUnfinalizedCurrentCallReverts() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, 1);
    }

    function testIncompleteReplayStillPrecedesExitInProgressGuard() public {
        _createLaggingMaturedExitHistory(65);
        vm.warp(START + 65 * EPOCH);

        vm.expectRevert(LCCErrorsLib.AccountMaterializationIncomplete.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, 1);

        vault.materializeAccount(alice);
        vm.expectRevert(LCCErrorsLib.ExitInProgress.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, 1);
    }

    function testEntireActiveBounceClosesPlainAccount() public {
        uint256 commitment = _deposit(alice, 100e18);
        uint256 balanceBefore = margin.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.CommitmentBounced(bouncer, alice, 100e18, commitment);
        vm.prank(bouncer);
        uint256 returned = vault.bounceCommitment(alice, commitment);

        assertEq(returned, 100e18);
        assertEq(margin.balanceOf(alice), balanceBefore + returned);
        _assertClosedActiveAccount(alice);
        ILCCVault.Totals memory totals = vault.totals();
        assertEq(totals.activeMargin, 0);
        assertEq(totals.activeCommitment, 0);
    }

    function testExitingAccountRevertsAndLeavesExitBucketUntouched() public {
        uint256 commitment = _deposit(alice, 100e18);
        vm.prank(alice);
        uint256 maturity = vault.requestExit(type(uint256).max, type(uint256).max);

        vm.expectRevert(LCCErrorsLib.ExitInProgress.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, commitment);

        assertEq(vault.exitBucketMarginByMaturity(maturity), 100e18);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), commitment);
    }

    function testMaturedUnclaimedExitReverts() public {
        uint256 commitment = _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);
        vm.warp(START + EPOCH);
        assertEq(vault.claimableExitedMargin(alice), 100e18);

        vm.expectRevert(LCCErrorsLib.ExitInProgress.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, commitment);
    }

    function testPendingDepositReverts() public {
        uint256 activeCommitment = _deposit(alice, 100e18);
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 50e18);

        vm.expectRevert(LCCErrorsLib.PendingDepositExists.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, activeCommitment);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCommitment, activeCommitment);
        assertEq(account.pendingMargin, 50e18);
        assertGt(account.pendingCommitment, 0);
    }

    function testPartialBounceUsesProRataFloorAndLeavesRoundingDust() public {
        assertEq(_deposit(alice, 10), 20);
        uint256 balanceBefore = margin.balanceOf(alice);

        vm.prank(bouncer);
        uint256 returned = vault.bounceCommitment(alice, 3);

        assertEq(returned, 1);
        assertEq(margin.balanceOf(alice), balanceBefore + 1);
        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 9);
        assertEq(account.activeCommitment, 17);
        assertEq(vault.totals().activeMargin, 9);
        assertEq(vault.totals().activeCommitment, 17);
    }

    function testPartialBounceDustFloorReverts() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.minDepositAssets = 10;
        _deployVaultWithParams(params);
        assertEq(_deposit(alice, 11), 22);

        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, 4);

        assertEq(vault.getAccount(alice).activeMargin, 11);
        assertEq(vault.getAccount(alice).activeCommitment, 22);
    }

    function testBounceRejectsZeroAndAmountAboveActiveCommitment() public {
        uint256 activeCommitment = _deposit(alice, 10e18);

        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, 0);

        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, activeCommitment + 1);
    }

    function testEntireActiveBounceWorksUnderShutdown() public {
        uint256 commitment = _deposit(alice, 100e18);
        vm.prank(owner);
        vault.shutdown();

        vm.prank(bouncer);
        assertEq(vault.bounceCommitment(alice, commitment), 100e18);
        _assertClosedActiveAccount(alice);
    }

    function testEntireActiveBounceWorksUnderTerminalSunset() public {
        _deployVaultWithParams(_termParams(1));
        uint256 commitment = _deposit(alice, 100e18);
        vm.warp(START + EPOCH);

        vm.prank(bouncer);
        assertEq(vault.bounceCommitment(alice, commitment), 100e18);
        _assertClosedActiveAccount(alice);
    }

    function testRepeatEntireActiveBounceRevertsInvalidAmount() public {
        uint256 commitment = _deposit(alice, 100e18);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, commitment);

        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(bouncer);
        vault.bounceCommitment(alice, commitment);
    }

    function testClaimRemainingMarginUnchangedStillUnwindsExitBucket() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        uint256 maturity = vault.requestExit(type(uint256).max, type(uint256).max);
        vm.prank(owner);
        vault.shutdown();

        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);

        assertEq(vault.exitBucketMarginByMaturity(maturity), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), 0);
        assertEq(uint256(vm.load(address(vault), bytes32(MATURITY_LIST_SLOT))), 0);
        assertTrue(vault.isAccountClosed(alice));
    }

    function testEntireActiveBounceAllowsRegistryRepointToSecondFamilyVault() public {
        LCCVault otherVault = _newVault(_params(CAP, CAP));
        _mintAndApprove(otherVault, alice, 0, 0);
        uint256 commitment = _deposit(alice, 100e18);

        vm.prank(bouncer);
        vault.bounceCommitment(alice, commitment);

        vm.prank(alice);
        otherVault.deposit(10e18, alice, 1, type(uint256).max, true, type(uint256).max);
        assertEq(factory.vaultOf(alice), address(otherVault));
        assertEq(otherVault.getAccount(alice).activeMargin, 10e18);
    }

    function testBlacklistedMarginRecipientCannotBeBounced() public {
        LCCBlacklistMockToken blacklistMargin = new LCCBlacklistMockToken("Blacklist Margin", "BLM");
        margin = blacklistMargin;
        _deployVaultWithParams(_params(CAP, CAP));
        _mintAndApprove(alice, 100e18, 0);
        uint256 commitment = _deposit(alice, 100e18);
        blacklistMargin.setBlockedRecipient(alice);

        vm.expectRevert(bytes("BLOCKED_RECIPIENT"));
        vm.prank(bouncer);
        vault.bounceCommitment(alice, commitment);

        assertEq(vault.getAccount(alice).activeMargin, 100e18);
    }

    function _assertClosedActiveAccount(address user) internal view {
        ILCCVault.Account memory account = vault.getAccount(user);
        assertEq(account.activeMargin, 0);
        assertEq(account.activeCommitment, 0);
        assertEq(account.pendingMargin, 0);
        assertEq(account.pendingCommitment, 0);
        assertEq(account.claimableExitMargin, 0);
        assertFalse(account.exitRequested);
        assertTrue(vault.isAccountClosed(user));
    }

    function _createLaggingMaturedExitHistory(uint256 count) internal {
        _deposit(alice, 10_000e18);
        _deposit(bob, 10_000e18);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        for (uint256 epoch = 0; epoch < count; ++epoch) {
            vm.warp(START + EPOCH * epoch + NORMAL);
            vm.prank(owner);
            vault.openEpochCall(epoch, 1e18);

            vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL);
            vm.prank(epoch == 0 ? alice : bob);
            vault.fundCall(false);

            vm.warp(START + EPOCH * epoch + NORMAL + PRE_CALL + FUNDING);
            vault.finalizeEpochSlash(epoch);
        }
    }
}
