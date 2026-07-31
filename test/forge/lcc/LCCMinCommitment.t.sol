// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCMinCommitmentTest is LCCBase {
    // These slots mirror the reviewer-controlled storage-layout baseline. The raw-state fixtures below isolate
    // account replay states that public admission deliberately cannot construct.
    uint256 internal constant SYNC_STATE_SLOT = 12;
    uint256 internal constant ACCOUNTS_SLOT = 15;
    uint256 internal constant EPOCHS_SLOT = 16;
    uint256 internal constant CALLED_EPOCH_LIST_SLOT = 17;
    uint256 internal constant RETURN_CREDIT_EPOCH_SLOT = 29;
    uint256 internal constant UINT64_MASK = type(uint64).max;

    function setUp() public override {
        super.setUp();
        _assertLayoutSlot("_syncState", SYNC_STATE_SLOT);
        _assertLayoutSlot("accounts", ACCOUNTS_SLOT);
        _assertLayoutSlot("epochs", EPOCHS_SLOT);
        _assertLayoutSlot("calledEpochList", CALLED_EPOCH_LIST_SLOT);
        _assertLayoutSlot("returnCreditEpochByCall", RETURN_CREDIT_EPOCH_SLOT);
        _assertLayoutSlot("marginPriceAtCallOpen", MARGIN_PRICE_AT_CALL_OPEN_SLOT);
    }

    function testMinZeroExitsSameEpoch() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);
    }

    function testGateBlocksUntilMinEpochsElapse() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 2 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 3);
    }

    function testPendingDepositAnchorsAtActivationEpoch() public {
        _deployMinCommitmentVault(2, 0);

        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);

        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);

        vm.warp(START + 2 * EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 4);
    }

    function testTopUpResetsTheClock() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);

        vm.warp(START + 3 * EPOCH);
        _deposit(alice, 50e18);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 3);

        vm.warp(START + 4 * EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 5 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 6);
    }

    function testFundingNeverTouchesTheClock() public {
        _deployMinCommitmentVault(2, 0);

        vm.warp(START + EPOCH);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _deposit(carol, 100e18);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);

        // Fund a later epoch's call so a regression that re-anchors the clock on funding would move it to 2.
        _openCallAtEpoch(2, 100e18);
        _fundRollingAtEpoch(alice, 2);
        _fundAtEpoch(bob, 2);
        vm.prank(alice);
        vault.fundCall(carol);

        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);
        assertEq(vault.getAccount(bob).commitmentStartEpoch, 1);
        assertEq(vault.getAccount(carol).commitmentStartEpoch, 1);
    }

    function testDefaultWipeThenRedepositResets() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);
        _openCall(200e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);
        _deposit(alice, 50e18);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);

        vm.warp(START + 2 * EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);
    }

    function testDefaultReturnPoolCreditReanchorsMinimumCommitmentClock() public {
        _deployMinCommitmentVault(2, 0);

        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCallAtEpoch(1, 100e18);
        _fundAtEpoch(alice, 1);
        _finishFundingAtEpoch(1);
        vault.finalizeEpochSlash(1);

        vm.warp(START + 2 * EPOCH);
        ILCCVault.Account memory preview = vault.getAccount(bob);
        assertGt(preview.activeMargin, 0);
        assertEq(preview.commitmentStartEpoch, 1);

        vault.materializeAccount(bob);

        ILCCVault.Account memory bobAccount = vault.getAccount(bob);
        assertEq(bobAccount.activeMargin, preview.activeMargin);
        assertEq(bobAccount.activeCommitment, preview.activeCommitment);
        assertEq(_storedCommitmentStartEpoch(bob), preview.commitmentStartEpoch);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 3 * EPOCH);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);
    }

    function testDelayedReturnPoolCreditAnchorsAtCreationEpoch() public {
        _deployMinCommitmentVault(1, 0);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(100e18);
        _fund(alice);
        _finishFunding();

        // Persist epoch 0's late disposal before checking the gate: a reverting requestExit would roll sync back.
        vm.warp(START + EPOCH);
        vault.finalizeEpochSlash(0);
        vault.materializeAccount(bob);

        ILCCVault.Account memory account = vault.getAccount(bob);
        assertGt(account.activeMargin, 0);
        assertEq(account.commitmentStartEpoch, 1);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 2 * EPOCH);
        vm.prank(bob);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 3);
    }

    function testLateNoAuctionFinalizationRestartsFullMinimumPeriod() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(100e18);
        _fund(alice);
        _finishFunding();

        vm.warp(START + 3 * EPOCH);
        vault.finalizeEpochSlash(0);
        vault.materializeAccount(bob);
        assertEq(vault.getAccount(bob).commitmentStartEpoch, 3);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 4 * EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 5 * EPOCH);
        vm.prank(bob);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 6);
    }

    function testAuctionWindowEndSettlementRestartsFullMinimumPeriod() public {
        _deployMinCommitmentAuctionVault(1);
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.warp(START + EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);

        // The reverting request rolled settlement back; persist it separately before checking the gate again.
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);
        vault.materializeAccount(bob);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(vault.getAccount(bob).commitmentStartEpoch, 1);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 2 * EPOCH);
        vm.prank(bob);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 3);
    }

    function testFullyFilledAuctionUsesCallEpochAsCreditAnchor() public {
        _deployMinCommitmentAuctionVault(1);
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 5);
        vm.prank(carol);
        vault.takeAuction(50e18, 0, type(uint256).max);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);

        vault.materializeAccount(bob);
        ILCCVault.Account memory account = vault.getAccount(bob);
        assertGt(account.activeMargin, 0);
        assertEq(account.commitmentStartEpoch, 0);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(bob);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + EPOCH);
        vm.prank(bob);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 2);
    }

    function testTerminalDisposalRecordsCreditCreationEpoch() public {
        _deployMinCommitmentVault(1, 1);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(100e18);
        _fund(alice);
        _finishFunding();

        vm.warp(START + EPOCH);
        vault.finalizeEpochSlash(0);
        vault.materializeAccount(bob);

        assertEq(_storedReturnCreditEpoch(0), 1);
        assertEq(vault.getAccount(bob).commitmentStartEpoch, 1);
    }

    function testShutdownDisposalRecordsCreditCreationEpoch() public {
        _deployMinCommitmentVault(1, 0);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(100e18);
        _fund(alice);
        _finishFunding();

        vm.warp(START + 2 * EPOCH);
        vm.prank(owner);
        vault.shutdown();
        vault.materializeAccount(bob);

        assertEq(_storedReturnCreditEpoch(0), 2);
        assertEq(vault.getAccount(bob).commitmentStartEpoch, 2);
    }

    function testPendingActivatingOnDefaultEpochIsSlashedAndReanchored() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(bob, 100e18);

        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);
        ILCCVault.Account memory pending = vault.getAccount(alice);
        assertEq(pending.pendingMargin, 100e18);
        assertEq(pending.pendingActivationEpoch, 1);

        _openCallAtEpoch(1, 100e18);
        _fundAtEpoch(bob, 1);
        _finishFundingAtEpoch(1);
        vault.finalizeEpochSlash(1);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(1);
        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(state.slashedMargin, 100e18);
        assertEq(account.pendingMargin, 0);
        assertEq(account.pendingCommitment, 0);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCommitment, 200e18);
        assertEq(account.commitmentStartEpoch, 1);
    }

    function testFuturePendingSurvivesEarlierDefaultAndKeepsLaterAnchorAtReplayLevel() public {
        _deposit(alice, 100e18);
        _seedPendingAccountState(alice, 50e18, 100e18, 3, 3);
        _appendFinalizedReplayEpoch(1, 100e18, 100e18, 200e18);

        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCommitment, 200e18);
        assertEq(account.pendingMargin, 50e18);
        assertEq(account.pendingCommitment, 100e18);
        assertEq(account.pendingActivationEpoch, 3);
        assertEq(account.commitmentStartEpoch, 3);
    }

    function testPublicFlowCreatesFuturePendingBehindUnsettledCall() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 50e18);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCommitment, 200e18);
        assertEq(account.pendingMargin, 50e18);
        assertEq(account.pendingCommitment, 100e18);
        assertEq(account.pendingActivationEpoch, 1);
        assertEq(account.commitmentStartEpoch, 1);
    }

    function testAggregateZeroReturnDoesNotReanchor() public {
        _deposit(alice, 1);
        _appendFinalizedReplayEpoch(1, 1, 0, 0);

        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 0);
        assertEq(account.activeCommitment, 0);
        assertEq(account.commitmentStartEpoch, 0);
    }

    function testCommitmentShareRoundingToZeroDoesNotReanchor() public {
        _deposit(alice, 1);
        _appendFinalizedReplayEpoch(1, 100, 100, 99);

        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 0);
        assertEq(account.activeCommitment, 0);
        assertEq(account.commitmentStartEpoch, 0);
    }

    function testMarginShareRoundingToZeroDoesNotReanchor() public {
        _deposit(alice, 1);
        // The commitment share first rounds to 2, but the tuple-literal zero return pairs it back to zero when the
        // margin share rounds to zero. A commitment-only replay guard input is therefore not constructible.
        _appendFinalizedReplayEpoch(1, 100, 99, 200);

        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 0);
        assertEq(account.activeCommitment, 0);
        assertEq(account.commitmentStartEpoch, 0);
    }

    function testDustPairedReturnCreditReanchors() public {
        _deposit(alice, 1);
        _appendFinalizedReplayEpoch(1, 100, 100, 200);

        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 1);
        assertEq(account.activeCommitment, 2);
        assertEq(account.commitmentStartEpoch, 1);
    }

    function testAbsentCreditCreationEpochFallsBackToCallEpoch() public {
        _deposit(alice, 100);
        _appendFinalizedReplayEpoch(2, 100, 25, 50);
        assertEq(_storedReturnCreditEpoch(2), 0);

        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 25);
        assertEq(account.activeCommitment, 50);
        assertEq(account.commitmentStartEpoch, 2);
    }

    function testPartialPairedReturnCreditReanchors() public {
        _deposit(alice, 100);
        _appendFinalizedReplayEpoch(1, 100, 25, 50);

        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 25);
        assertEq(account.activeCommitment, 50);
        assertEq(account.commitmentStartEpoch, 1);
    }

    function testRepeatedDefaultsAdvanceAnchorOnlyOnNonzeroCredit() public {
        _deposit(alice, 100e18);
        // The future pending exposure keeps the account replayable after epoch 3's zero-credit default. Its
        // deliberately old synthetic anchor lets this account-level fixture observe every monotonic transition.
        _seedPendingAccountState(alice, 50e18, 100e18, 4, 0);

        _appendFinalizedReplayEpoch(1, 100e18, 100e18, 200e18);
        vault.materializeAccount(alice);
        assertEq(_storedCommitmentStartEpoch(alice), 1);

        _appendFinalizedReplayEpoch(2, 100e18, 100e18, 200e18);
        vault.materializeAccount(alice);
        assertEq(_storedCommitmentStartEpoch(alice), 2);

        _appendFinalizedReplayEpoch(3, 100e18, 0, 0);
        vault.materializeAccount(alice);
        assertEq(_storedCommitmentStartEpoch(alice), 2);

        _appendFinalizedReplayEpoch(4, 50e18, 50e18, 100e18);
        vault.materializeAccount(alice);
        assertEq(_storedCommitmentStartEpoch(alice), 4);
    }

    function testDefaultClearsExitAndReturnCreditRestartsCommitmentPeriod() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);

        vm.warp(START + 2 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 3);

        _openCallAtEpoch(2, 100e18);
        _fundAtEpoch(bob, 2);
        _finishFundingAtEpoch(2);
        vault.finalizeEpochSlash(2);
        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertFalse(account.exitRequested);
        assertTrue(account.exitClaimed);
        assertGt(account.activeMargin, 0);
        assertEq(account.commitmentStartEpoch, 2);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 4 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 5);
    }

    function testEpochZeroReturnCreditLeavesZeroAnchor() public {
        _deposit(alice, 100e18);
        _appendFinalizedReplayEpoch(0, 100e18, 100e18, 200e18);

        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCommitment, 200e18);
        assertEq(account.commitmentStartEpoch, 0);
    }

    function testChunkedMaterializationConvergesToUnboundedPreviewAnchor() public {
        _deposit(alice, 100e18);
        for (uint256 epoch = 1; epoch <= 130; ++epoch) {
            _appendFinalizedReplayEpoch(epoch, 100e18, 100e18, 200e18);
        }

        // getAccount is an unbounded preview over the same stored input; materialization intentionally advances
        // only 64 calls per update, so intermediate storage tracks the bounded prefix before reaching the fixpoint.
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 130);

        vault.materializeAccount(alice);
        assertEq(_storedCalledEpochCursor(alice), 64);
        assertEq(_storedCommitmentStartEpoch(alice), 64);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 130);

        vault.materializeAccount(alice);
        assertEq(_storedCalledEpochCursor(alice), 128);
        assertEq(_storedCommitmentStartEpoch(alice), 128);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 130);

        vault.materializeAccount(alice);
        assertEq(_storedCalledEpochCursor(alice), 130);
        assertEq(_storedCommitmentStartEpoch(alice), 130);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, _storedCommitmentStartEpoch(alice));
    }

    function testExitClaimThenRedepositResets() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);

        vm.warp(START + 2 * EPOCH);
        vm.prank(alice);
        uint256 maturity = vault.requestExit(type(uint256).max, type(uint256).max);
        assertEq(maturity, 3);

        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        vault.claimExitedMargin(alice);

        vm.warp(START + 5 * EPOCH);
        _deposit(alice, 100e18);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 5);

        vm.warp(START + 6 * EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + 7 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 8);
    }

    function testImmediateDepositPreservesFuturePendingActivationAnchor() public {
        _deposit(alice, 100e18);
        _seedPendingAccountState(alice, 50e18, 100e18, 3, 3);

        vm.warp(START + 2 * EPOCH);
        _deposit(alice, 25e18);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.pendingActivationEpoch, 3);
        assertEq(account.commitmentStartEpoch, 3);
    }

    function testTerminalClaimRemainingBypassesGate() public {
        _deployMinCommitmentVault(2, 1);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
    }

    function testShutdownClaimRemainingBypassesGate() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);

        vm.prank(owner);
        vault.shutdown();

        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
    }

    function testHoldToMaturityVaultDrainsAtTerminal() public {
        // minCommitmentEpochs >= maxEpochs: the exit gate can never pass before terminal, so the facility is
        // hold-to-maturity; the terminal claim still drains in full.
        _deployMinCommitmentVault(64, 1);
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
    }

    function testValidationCeiling() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);

        params.minCommitmentEpochs = 65;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params.minCommitmentEpochs = 64;
        assertEq(_newVault(params).epochConfig().minCommitmentEpochs, 64);

        params.minCommitmentEpochs = 0;
        assertEq(_newVault(params).epochConfig().minCommitmentEpochs, 0);
    }

    function _deployMinCommitmentVault(uint256 minCommitmentEpochs, uint256 maxEpochs) internal {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.minCommitmentEpochs = minCommitmentEpochs;
        params.maxEpochs = maxEpochs;
        _deployVaultWithParams(params);
    }

    function _deployMinCommitmentAuctionVault(uint256 minCommitmentEpochs) internal {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.minCommitmentEpochs = minCommitmentEpochs;
        _deployVaultWithParams(params);
    }

    function _appendFinalizedReplayEpoch(
        uint256 epoch,
        uint256 aggregateSlashedMargin,
        uint256 returnPool,
        uint256 returnCommitment
    ) internal {
        uint256 length = uint256(vm.load(address(vault), bytes32(CALLED_EPOCH_LIST_SLOT)));
        uint256 listDataSlot = uint256(keccak256(abi.encode(CALLED_EPOCH_LIST_SLOT)));
        vm.store(address(vault), bytes32(listDataSlot + length), bytes32(epoch));
        vm.store(address(vault), bytes32(CALLED_EPOCH_LIST_SLOT), bytes32(length + 1));

        uint256 stateSlot = uint256(_mappingSlot(epoch, EPOCHS_SLOT));
        vm.store(address(vault), bytes32(stateSlot + 8), bytes32(uint256(1)));
        vm.store(address(vault), bytes32(stateSlot + 9), bytes32(aggregateSlashedMargin));
        vm.store(address(vault), bytes32(stateSlot + 10), bytes32(returnPool));
        vm.store(address(vault), bytes32(stateSlot + 11), bytes32(returnCommitment));

        uint256 syncState = uint256(vm.load(address(vault), bytes32(SYNC_STATE_SLOT)));
        syncState = (syncState & ~(UINT64_MASK << 64)) | ((length + 1) << 64);
        vm.store(address(vault), bytes32(SYNC_STATE_SLOT), bytes32(syncState));
    }

    function _seedPendingAccountState(
        address user,
        uint256 pendingMargin,
        uint256 pendingCommitment,
        uint256 activationEpoch,
        uint256 commitmentStartEpoch
    ) internal {
        uint256 accountSlot = uint256(keccak256(abi.encode(user, ACCOUNTS_SLOT)));
        vm.store(address(vault), bytes32(accountSlot + 1), bytes32(pendingMargin | (pendingCommitment << 128)));

        uint256 cursorWord = uint256(vm.load(address(vault), bytes32(accountSlot + 3)));
        cursorWord = (cursorWord & ~(UINT64_MASK << 128)) | (activationEpoch << 128);
        vm.store(address(vault), bytes32(accountSlot + 3), bytes32(cursorWord));

        uint256 exitWord = uint256(vm.load(address(vault), bytes32(accountSlot + 4)));
        exitWord = (exitWord & ~(UINT64_MASK << 88)) | (commitmentStartEpoch << 88);
        vm.store(address(vault), bytes32(accountSlot + 4), bytes32(exitWord));
    }

    function _storedCalledEpochCursor(address user) internal view returns (uint256) {
        uint256 accountSlot = uint256(keccak256(abi.encode(user, ACCOUNTS_SLOT)));
        return (uint256(vm.load(address(vault), bytes32(accountSlot + 3))) >> 192) & UINT64_MASK;
    }

    function _storedCommitmentStartEpoch(address user) internal view returns (uint256) {
        uint256 accountSlot = uint256(keccak256(abi.encode(user, ACCOUNTS_SLOT)));
        return (uint256(vm.load(address(vault), bytes32(accountSlot + 4))) >> 88) & UINT64_MASK;
    }

    function _storedReturnCreditEpoch(uint256 epoch) internal view returns (uint256) {
        return uint256(vm.load(address(vault), _mappingSlot(epoch, RETURN_CREDIT_EPOCH_SLOT)));
    }
}
