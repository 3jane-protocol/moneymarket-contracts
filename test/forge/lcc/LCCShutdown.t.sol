// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase, LCCBlacklistMockToken, LCCRevertingOracle} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

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

    function testPostWindowShutdownMatchesPermissionlessSettlementAtSaturatedCap() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 300e18;
        params.userCommitmentCap = 300e18;
        _deployVaultWithParams(params);

        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        vm.prank(owner);
        vault.setRiskCaps(200e18, 300e18, 2_000, 0);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 5);
        uint256 expectedAward = _referenceAward(50e18, 0, 10e18, 50e18, 5, 5, 5_000, 1_000, 10_000, 1e36);
        vm.prank(carol);
        vault.takeAuction(10e18, expectedAward, type(uint256).max);

        ILCCVault.EpochState memory openState = vault.getEpochState(0);
        assertEq(openState.fundedAmount + openState.fundedUsersRemainingCommitment, 200e18);
        assertEq(vault.riskConfig().protocolCommitmentCap, 200e18);
        uint256 snapshot = vm.snapshotState();

        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);
        ILCCVault.EpochState memory permissionlessState = vault.getEpochState(0);
        uint256 permissionlessTreasury = _accruedTreasuryMargin();

        assertTrue(vm.revertToStateAndDelete(snapshot), "permissionless branch restore failed");
        vm.warp(START + EPOCH);
        vm.prank(owner);
        vault.shutdown();
        ILCCVault.EpochState memory shutdownState = vault.getEpochState(0);

        assertEq(shutdownState.returnPool, permissionlessState.returnPool);
        assertEq(shutdownState.returnCommitment, permissionlessState.returnCommitment);
        assertEq(_accruedTreasuryMargin(), permissionlessTreasury);
    }

    function testPostWindowShutdownMissingSnapshotAndDeadOracleStillSucceeds() public {
        _setupPostWindowMissingSnapshot();
        LCCRevertingOracle deadOracle = new LCCRevertingOracle();
        vm.etch(address(oracle), address(deadOracle).code);

        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(vault.shutdownState().active);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), 100e18);
        vault.materializeAccount(alice);
    }

    function testPostWindowShutdownMissingSnapshotAndLiveOracleRecoversPool() public {
        SettlementReference memory settlement = _setupPostWindowMissingSnapshot();

        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(vault.shutdownState().active);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(state.returnPool, settlement.baseReturn);
        assertEq(state.returnCommitment, 2 * settlement.baseReturn);
        assertEq(_accruedTreasuryMargin(), 100e18 - settlement.baseReturn);
        vault.materializeAccount(alice);
    }

    function testPostWindowShutdownOverflowSnapshotStillSucceeds() public {
        uint256 maxPacked = type(uint128).max;
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = maxPacked;
        params.userCommitmentCap = maxPacked;
        _deployVaultWithParams(params);

        uint256 marginAssets = maxPacked / 2;
        _mintAndApprove(alice, marginAssets, 0);
        uint256 commitment = _deposit(alice, marginAssets);
        _openCall(commitment);
        _mintAndApprove(carol, 0, commitment);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.store(address(vault), _mappingSlot(0, MARGIN_PRICE_AT_CALL_OPEN_SLOT), bytes32(type(uint256).max));
        uint256 fill = commitment / 2;
        vm.prank(carol);
        vault.takeAuction(fill, 0, type(uint256).max);

        SettlementReference memory settlement =
            _referenceSettlement(marginAssets, 0, fill, commitment, 5_000, 1_000, true);
        (uint256 valueProductHigh,) = Math.mul512(settlement.baseReturn, type(uint256).max);
        assertGe(valueProductHigh, ORACLE_PRICE_SCALE, "fixture must trigger the exact mulDiv overflow predicate");

        vm.warp(START + EPOCH);
        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(vault.shutdownState().active);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), marginAssets);
        vault.materializeAccount(alice);
    }

    function _setupPostWindowMissingSnapshot() internal returns (SettlementReference memory settlement) {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        vm.prank(carol);
        vault.takeAuction(50e18, 0, type(uint256).max);

        vm.store(address(vault), _mappingSlot(0, MARGIN_PRICE_AT_CALL_OPEN_SLOT), bytes32(0));
        vm.warp(START + EPOCH);
        settlement = _referenceSettlement(100e18, 0, 50e18, 100e18, 5_000, 1_000, true);
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

        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, auctionMargin);
        assertEq(vault.totals().activeMargin, auctionMargin);
        assertEq(vault.totals().pendingMargin, maxPacked - auctionMargin);
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
