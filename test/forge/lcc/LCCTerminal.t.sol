// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase, LCCRevertingOracle} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";

contract LCCTerminalTest is LCCBase {
    function testTerminalBlocksNewCallsDepositsAndExitRequests() public {
        _deployVaultWithParams(_termParams(1));
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH + NORMAL);

        vm.expectRevert(LCCErrorsLib.VaultTerminal.selector);
        vm.prank(owner);
        vault.openEpochCall(1, 100e18);

        vm.expectRevert(LCCErrorsLib.VaultTerminal.selector);
        _deposit(bob, 1e18);

        vm.expectRevert(LCCErrorsLib.VaultTerminal.selector);
        vm.prank(alice);
        vault.requestExit();
    }

    function testClaimRemainingReturnsRemainingMarginAndClearsAccount() public {
        _deployVaultWithParams(_termParams(1));
        _deposit(alice, 100e18);

        vm.warp(START + NORMAL);
        _deposit(alice, 25e18);

        vm.warp(START + EPOCH);
        uint256 beforeBalance = margin.balanceOf(alice);

        vm.prank(alice);
        uint256 claimed = vault.claimRemainingMargin(alice);

        assertEq(claimed, 125e18);
        assertEq(margin.balanceOf(alice), beforeBalance + 125e18);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 0);
        assertEq(account.activeCommitment, 0);
        assertEq(account.pendingMargin, 0);
        assertEq(account.pendingCommitment, 0);
        assertEq(account.claimableExitMargin, 0);
        assertFalse(account.exitRequested);
        assertEq(vault.totals().activeMargin, 0);
        assertEq(vault.totals().pendingMargin, 0);
    }

    function testLastCallSettlesInTerminalAndBothSidesWithdraw() public {
        _deployTermAuctionVault(1);
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.warp(START + EPOCH);
        uint256 bobBefore = margin.balanceOf(bob);
        vm.prank(bob);
        assertEq(vault.claimRemainingMargin(bob), 50e18);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(state.returnPool, 50e18);
        assertEq(state.returnCommitment, 100e18);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(margin.balanceOf(bob), bobBefore + 50e18);

        uint256 aliceBefore = margin.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 50e18);
        assertEq(margin.balanceOf(alice), aliceBefore + 50e18);
    }

    function testDeadOracleAtTerminalSweepsSurplusAndDoesNotBrickClaim() public {
        _deployTermAuctionVault(1);
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        LCCRevertingOracle badOracle = new LCCRevertingOracle();
        vm.etch(address(oracle), address(badOracle).code);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 50e18);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);
    }

    function testHigherTerminalOraclePriceKeepsReturnPoolDespiteCapHeadroom() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.maxEpochs = 1;
        params.protocolCommitmentCap = 200e18;
        _deployVaultWithParams(params);

        _deposit(alice, 99e18);
        _deposit(bob, 1e18);
        _openCall(200e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.prank(owner);
        vault.setRiskCaps(1, 200e18, 2_000, 0);
        oracle.setPrice(2 * ORACLE_PRICE_SCALE);

        vm.warp(START + EPOCH);
        vm.prank(bob);
        assertEq(vault.claimRemainingMargin(bob), 1e18);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 400e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testLastEpochEarlyFullFillDoesNotDivertReturnPool() public {
        // The last callable epoch's auction fully fills DURING its own Closed window, so disposal runs while
        // _currentEpoch() is still maxEpochs-1 (not yet terminal). The wind-down relaxation must still apply
        // (the returned commitment can never back a future call), or the tight cap would divert returnPool to
        // treasury. maxEpochs = 1 → epoch 0 is the last callable epoch.
        ILCCVault.VaultParams memory params = _auctionParams();
        params.maxEpochs = 1;
        params.protocolCommitmentCap = 200e18;
        _deployVaultWithParams(params);

        _deposit(alice, 99e18);
        _deposit(bob, 1e18);
        _openCall(200e18);
        _finishFunding();
        vault.finalizeEpochSlash(0); // both default; kicks the auction (shortfall 200e18, pool 100e18), pre-terminal
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.prank(owner);
        vault.setRiskCaps(1, 200e18, 2_000, 0);
        oracle.setPrice(2 * ORACLE_PRICE_SCALE);

        uint256 fillTime = START + NORMAL + PRE_CALL + FUNDING + 4; // Closed window, step 0 (award 0)
        assertLt(fillTime, START + EPOCH); // pre-terminal
        vm.warp(fillTime);

        address filler = makeAddr("filler");
        _mintAndApprove(filler, 0, 500e18);
        vm.prank(filler);
        vault.takeAuction(200e18); // full fill settles + disposes pre-terminal

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        ILCCVault.EpochState memory state = vault.getEpochState(0);
        // Wind-down applies (disposed epoch == maxEpochs-1): the full 100e18 returnPool is preserved for
        // defaulters rather than clamped to 0 and swept to treasury. With a zero award, there is no fee basis.
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 400e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testOlderEpochSettledInLastEpochClosedIsWindDown() public {
        // maxEpochs = 2 (epochs 0 and 1 callable; epoch 1 is the last). Epoch 0's auction is left pending and first
        // settles during epoch 1's Closed phase — after the last call-opening (PreCall) window has passed but before
        // terminal. No call can ever open again, so disposal must be wind-down: a dead oracle sweeps to treasury
        // instead of bricking the settlement, even though _currentEpoch() (1) has not reached maxEpochs (2).
        _deployTermAuctionVault(2);
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0); // kicks epoch 0's auction; no further sync leaves it pending
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        LCCRevertingOracle badOracle = new LCCRevertingOracle();
        vm.etch(address(oracle), address(badOracle).code);

        uint256 lastEpochClosed = START + EPOCH + NORMAL + PRE_CALL + FUNDING + 5;
        assertLt(lastEpochClosed, START + 2 * EPOCH); // epoch 1 Closed, pre-terminal
        vm.warp(lastEpochClosed);

        // A permissionless touch settles epoch 0's now-due auction at this late point; disposal is wind-down.
        vault.materializeAccount(alice);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);
    }

    function testMaturedExitersCanUseRemainingClaimAtAndAfterMaxEpochs() public {
        ILCCVault.VaultParams memory params = _params(400e18, 400e18);
        params.maxEpochs = 1;
        params.exitCapBps = 5_000;
        _deployVaultWithParams(params);

        _deposit(alice, 100e18);
        _deposit(bob, 100e18);

        vm.prank(alice);
        assertEq(vault.requestExit(), 1);

        vm.prank(bob);
        assertEq(vault.requestExit(), 2);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);

        vm.warp(START + 2 * EPOCH);
        vm.prank(bob);
        assertEq(vault.claimRemainingMargin(bob), 100e18);

        assertEq(vault.totals().activeMargin, 0);
    }

    function testClaimExitedMarginStillWorksAfterTerminal() public {
        _deployVaultWithParams(_termParams(1));
        _deposit(alice, 100e18);

        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 100e18);
    }

    function testClaimRemainingRequiresShutdownOrTerminalAndCoversMaturedShutdownExit() public {
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.NotWithdrawable.selector);
        vm.prank(alice);
        vault.claimRemainingMargin(alice);

        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + EPOCH);
        vm.prank(owner);
        vault.shutdown();

        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
    }

    function testMaxEpochsZeroNeverTerminal() public {
        _deposit(alice, 100e18);

        vm.warp(START + 100 * EPOCH + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(100, 100e18);

        assertTrue(vault.getEpochState(100).callOpened);
    }

    function testLaggingAccountNeedsMaterializeBatchesBeforeTerminalClaim() public {
        _deployVaultWithParams(_termParams(130));
        _deposit(alice, 10_000e18);
        _openDefaultingCallHistory(130);

        vm.warp(START + 130 * EPOCH);
        vm.expectRevert(LCCErrorsLib.AccountMaterializationIncomplete.selector);
        vm.prank(alice);
        vault.claimRemainingMargin(alice);

        vault.materializeAccount(alice);

        vm.expectRevert(LCCErrorsLib.AccountMaterializationIncomplete.selector);
        vm.prank(alice);
        vault.claimRemainingMargin(alice);

        vault.materializeAccount(alice);

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimRemainingMargin(alice);

        assertGt(claimed, 0);
        assertEq(margin.balanceOf(alice), beforeBalance + claimed);
    }

    function _deployTermAuctionVault(uint256 maxEpochs) internal {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.maxEpochs = maxEpochs;
        _deployVaultWithParams(params);
    }

    function _openDefaultingCallHistory(uint256 count) internal {
        for (uint256 epoch = 0; epoch < count; ++epoch) {
            vm.warp(START + epoch * EPOCH + NORMAL);
            vm.prank(owner);
            vault.openEpochCall(epoch, 1);
        }
    }
}
