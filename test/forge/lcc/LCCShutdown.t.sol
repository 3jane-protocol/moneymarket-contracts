// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase, LCCRevertingOracle} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";

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
        assertEq(margin.balanceOf(treasury), 0);
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
        assertEq(margin.balanceOf(treasury), 10e18);
        assertEq(state.returnPool, 90e18);
        assertEq(state.returnCommitment, 180e18);
    }

    function testShutdownDisposalSkipsCapClampAndKeepsFullReturnPool() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 200e18;
        _deployVaultWithParams(params);

        _deposit(alice, 99e18);
        _deposit(bob, 1e18);
        _openCall(200e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 1);
        _deposit(carol, 100e18);

        vm.warp(START + EPOCH);
        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 90e18);
        assertEq(state.returnCommitment, 180e18);
        assertEq(margin.balanceOf(treasury), 10e18);
    }

    function testShutdownWithDeadOracleAndPendingAuctionSweepsSurplus() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
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
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(margin.balanceOf(treasury), 100e18);
    }

    function testEmergencyClaimWithdrawsSafeMarginAndBlocksDeposits() public {
        _deposit(alice, 100e18);

        vm.prank(owner);
        vault.shutdown();

        vm.expectRevert();
        _deposit(alice, 1e18);

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimEmergencyMargin(alice);

        assertEq(claimed, 100e18);
        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
        assertEq(vault.totals().activeMargin, 0);
    }

    function testEmergencyClaimClearsPendingExitBucket() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        uint256 maturity = vault.requestExit();

        vm.prank(owner);
        vault.shutdown();

        vm.prank(alice);
        vault.claimEmergencyMargin(alice);

        assertEq(vault.exitBucketMarginByMaturity(maturity), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), 0);

        vm.warp(START + EPOCH * (maturity + 1));
        _syncAs(bob);

        assertEq(vault.totals().activeMargin, 0);
        assertEq(vault.totals().activeCommitment, 0);
    }
}
