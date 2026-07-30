// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase, LCCBlacklistMockToken, LCCRevertingOracle} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";

contract LCCShutdownTest is LCCBase {
    function testShutdownDuringFundingDisablesSlash() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.warp(START + NORMAL + PRE_CALL);
        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(state.slashFinalized);
        assertTrue(state.slashDisabledByShutdown);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(vault.totals().activeMargin, 100e18);
    }

    function testShutdownAtFundingDeadlineWithLiveOracleDisposesNormally() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();

        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(state.slashFinalized);
        assertFalse(state.slashDisabledByShutdown);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 200e18);
    }

    function testShutdownDisposalSkipsCapClampAndKeepsFullReturnPool() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 200e18;
        _deployVaultWithParams(params);

        _deposit(alice, 99e18);
        _deposit(bob, 1e18);
        _openCall(200e18);
        vm.prank(owner);
        vault.setRiskCaps(1, 200e18, 2_000, 0);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + EPOCH);
        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 200e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testShutdownWithDeadOracleAndPendingAuctionReturnsSnapshotValuedPool() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        oracle.setPrice(1e36);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        LCCRevertingOracle badOracle = new LCCRevertingOracle();
        vm.etch(address(oracle), address(badOracle).code);

        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 200e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testRemainingClaimWithdrawsSafeMarginAndBlocksDeposits() public {
        _deposit(alice, 100e18);

        vm.prank(owner);
        vault.shutdown();

        vm.expectRevert();
        _deposit(alice, 1e18);

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimRemainingMargin(alice);

        assertEq(claimed, 100e18);
        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
        assertEq(vault.totals().activeMargin, 0);
    }

    function testRemainingClaimClearsPendingExitBucket() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        uint256 maturity = vault.requestExit(type(uint256).max, type(uint256).max);

        vm.prank(owner);
        vault.shutdown();

        vm.prank(alice);
        vault.claimRemainingMargin(alice);

        assertEq(vault.exitBucketMarginByMaturity(maturity), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), 0);

        vm.warp(START + EPOCH * (maturity + 1));
        _syncAs(bob);

        assertEq(vault.totals().activeMargin, 0);
        assertEq(vault.totals().activeCommitment, 0);
    }

    function testShutdownSettlesAuctionAfterMaxWidthPendingDepositDuringCall() public {
        uint256 maxPacked = type(uint128).max;
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = maxPacked;
        params.userCommitmentCap = maxPacked;
        _deployVaultWithParams(params);
        oracle.setPrice(1e18);
        margin.mint(alice, maxPacked);
        margin.mint(bob, maxPacked);

        uint256 auctionMargin = maxPacked / 2;
        uint256 commitment = _deposit(alice, auctionMargin);
        _openCall(commitment);
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(bob, maxPacked - auctionMargin);
        assertEq(vault.totals().activeMargin + vault.totals().pendingMargin, maxPacked);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.warp(START + EPOCH);
        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, auctionMargin);
        assertEq(vault.totals().activeMargin, maxPacked);
        assertEq(vault.totals().pendingMargin, 0);
        assertEq(vault.pendingTreasuryMargin(), 0);
    }

    function testRejectedTreasuryTransferDoesNotBrickShutdownOrRemainingClaim() public {
        LCCBlacklistMockToken blacklistMargin = new LCCBlacklistMockToken("Blacklist Margin", "bMRG");
        margin = blacklistMargin;
        _deployAuctionVault();
        _mintAndApprove(alice, 100e18, 0);
        _mintAndApprove(bob, 50e18, 0);
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        oracle.setPrice(4_999e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        blacklistMargin.setBlockedRecipient(treasury);

        vm.prank(owner);
        vault.shutdown();
        assertEq(vault.pendingTreasuryMargin(), 50e18);
        assertEq(margin.balanceOf(treasury), 0);

        uint256 aliceBefore = margin.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 50e18);
        assertEq(margin.balanceOf(alice), aliceBefore + 50e18);

        vm.prank(owner);
        vault.pause();
        vm.expectRevert("BLOCKED_RECIPIENT");
        vault.sweepTreasury();
        assertEq(vault.pendingTreasuryMargin(), 50e18);

        blacklistMargin.setBlockedRecipient(address(0));
        vm.expectEmit(false, false, false, true, address(vault));
        emit LCCEventsLib.TreasurySwept(50e18);
        vault.sweepTreasury();

        assertEq(vault.pendingTreasuryMargin(), 0);
        assertEq(margin.balanceOf(treasury), 50e18);
    }
}
