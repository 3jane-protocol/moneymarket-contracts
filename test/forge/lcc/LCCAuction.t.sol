// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";

contract LCCAuctionTest is LCCBase {
    uint256 internal constant DEADLINE = START + NORMAL + PRE_CALL + FUNDING;
    uint256 internal constant WINDOW_END = START + EPOCH;
    uint256 internal constant CLOCK_CONFIG_SLOT = 1;
    uint256 internal constant ACCOUNTS_SLOT = 15;
    uint256 internal constant UINT64_MASK = type(uint64).max;

    function setUp() public override {
        super.setUp();
        _deployAuctionVault();
        _assertLayoutSlot("_clockConfig", CLOCK_CONFIG_SLOT);
        _assertLayoutSlot("accounts", ACCOUNTS_SLOT);
    }

    /// @dev alice honors, bob defaults: pool = 50e18 margin, shortfall = 50e18 funding asset, kicked at the deadline.
    function _setupShortfallAuction() internal {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);
    }

    function testKickRecordsAuctionInsteadOfTreasury() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();

        vm.expectEmit(true, false, false, true, address(vault));
        emit LCCEventsLib.AuctionKicked(0, 50e18, 50e18);
        vault.finalizeEpochSlash(0);

        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        LCCAuctionLib.AuctionState memory state = vault.getAuctionState(0);
        assertEq(state.shortfallAmount, 50e18);
        assertEq(state.marginPool, 50e18);
        assertEq(state.filledAmount, 0);
        assertEq(state.marginAwarded, 0);
    }

    function testStepDurationDerivedFromClosedWindow() public view {
        assertEq(vault.auctionConfig().auctionStepCount, 4);
        assertEq(vault.auctionConfig().auctionStepDuration, (EPOCH - NORMAL - PRE_CALL - FUNDING) / 4);
    }

    function testLateKickStartsMidRamp() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        // Nobody touches the vault until two steps into the window: elapsed is measured from the funding
        // deadline, not the kick, so the reserved award ramp is already at 75%.
        vm.warp(DEADLINE + 10);
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        uint256 expectedAward = _referenceAward(50e18, 0, 25e18, 50e18, 10, 5, 5_000, 1_000, 10_000, oracle.price());
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(25e18, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);
    }

    function testNoKickWhenFinalizedAfterWindowUsesCompletedZeroFillTreatment() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        vm.warp(WINDOW_END + 1);
        vault.finalizeEpochSlash(0);

        assertEq(vault.getAuctionState(0).shortfallAmount, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testNoKickWhenAwardCapZero() public {
        vm.prank(owner);
        vault.setMaxAuctionAwardBps(0);

        _setupShortfallAuction();

        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testNoKickWhenNoShortfall() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(1);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        // Alice's ceil-rounded obligation covered the full 1-wei call; bob still defaulted and was slashed.
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testZeroAwardFillBeforeFirstStep() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 4);

        vm.prank(carol);
        (uint256 filled, uint256 award) = vault.takeAuction(10e18, 0, type(uint256).max);

        assertEq(filled, 10e18);
        assertEq(award, 0);
        assertEq(notificationVault.balanceOf(carol), 10e18);
        assertEq(margin.balanceOf(carol), 1_000_000e18);
    }

    function testPartialFillsAcrossStepsAndLazySweep() public {
        _setupShortfallAuction();

        // Step 1: fill half the shortfall from the fee-reserved ramp.
        vm.warp(DEADLINE + 5);
        uint256 expectedAward1 = _referenceAward(50e18, 0, 25e18, 50e18, 5, 5, 5_000, 1_000, 10_000, oracle.price());
        vm.prank(carol);
        (uint256 filled1, uint256 award1) = vault.takeAuction(25e18, expectedAward1, type(uint256).max);
        assertEq(filled1, 25e18);
        assertEq(award1, expectedAward1);

        // Step 2: clamp a too-large fill to the 25e18 remaining.
        vm.warp(DEADLINE + 10);
        uint256 expectedAward2 =
            _referenceAward(50e18, award1, 25e18, 50e18, 10, 5, 5_000, 1_000, 10_000, oracle.price());
        vm.prank(bob);
        (uint256 filled2, uint256 award2) = vault.takeAuction(100e18, expectedAward2, type(uint256).max);
        assertEq(filled2, 25e18);
        assertEq(award2, expectedAward2);

        // Full fill settles immediately with the full take reserved by the award ceiling.
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        SettlementReference memory expected =
            _referenceSettlement(50e18, award1 + award2, 50e18, 50e18, 5_000, 1_000, true);
        assertEq(_accruedTreasuryMargin(), expected.fee);
        assertEq(notificationVault.balanceOf(carol), 25e18);
        assertEq(notificationVault.balanceOf(bob), 25e18);
    }

    function testUnfilledAuctionSweepsLazilyAfterWindow() public {
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        uint256 expectedAward = _referenceAward(50e18, 0, 10e18, 50e18, 5, 5, 5_000, 1_000, 10_000, oracle.price());
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(10e18, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(50e18, award, 10e18, 50e18, 5_000, 1_000, true);

        vm.warp(WINDOW_END);
        vm.expectEmit(true, false, false, true, address(vault));
        emit LCCEventsLib.SlashSurplusDisposed(
            0, expected.unfilledPool + expected.fee, expected.baseReturn, expected.baseReturn * 2
        );
        vm.expectEmit(true, false, false, true, address(vault));
        emit LCCEventsLib.AuctionSettled(0, 10e18, expectedAward);
        vault.materializeAccount(carol);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(_accruedTreasuryMargin(), expected.unfilledPool + expected.fee);

        vm.warp(WINDOW_END + 1);
        vm.expectRevert(LCCErrorsLib.AuctionNotLive.selector);
        vm.prank(carol);
        vault.takeAuction(1e18, 0, type(uint256).max);
    }

    function testFullFillEndsAuction() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        uint256 expectedAward = _referenceAward(50e18, 0, 50e18, 50e18, 5, 5, 5_000, 1_000, 10_000, oracle.price());
        vm.prank(carol);
        vault.takeAuction(50e18, expectedAward, type(uint256).max);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);

        vm.expectRevert(LCCErrorsLib.AuctionNotLive.selector);
        vm.prank(bob);
        vault.takeAuction(1e18, 0, type(uint256).max);
    }

    function testMidWindowFullFillAndBoundarySettlementUseDifferentFilledEligibility() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 300e18;
        _deployVaultWithParams(params);

        _deposit(carol, 100e18);
        _deposit(alice, 50e18);
        vm.prank(carol);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        _openCall(150e18);
        _fund(carol);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        oracle.setPrice(2 * ORACLE_PRICE_SCALE);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);
        uint256 snapshot = vm.snapshotState();

        vm.warp(DEADLINE + 1);
        vm.prank(bob);
        (, uint256 award) = vault.takeAuction(type(uint256).max, 0, type(uint256).max);
        assertEq(award, 0);

        ILCCVault.EpochState memory midWindow = vault.getEpochState(0);
        uint256 midWindowTreasury = _accruedTreasuryMargin();
        SettlementReference memory eagerExpected = _referenceSettlement(50e18, 0, 50e18, 50e18, 5_000, 1_000, true);
        assertEq(midWindow.returnPool, eagerExpected.baseReturn);
        assertEq(midWindow.returnCommitment, eagerExpected.baseReturn * 2);
        assertEq(midWindowTreasury, eagerExpected.fee);

        assertTrue(vm.revertToState(snapshot));
        vm.warp(WINDOW_END);
        vault.materializeAccount(bob);

        ILCCVault.EpochState memory boundary = vault.getEpochState(0);
        assertEq(boundary.returnPool, 0);
        assertEq(boundary.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);
        assertGt(midWindow.returnPool, boundary.returnPool);
    }

    function testDepositRevertsWhileAuctionIsLive() public {
        _setupShortfallAuction();

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        _deposit(carol, 1e18);
    }

    function testLiveAuctionDoesNotBlockEarlierMaturedExiterClaim() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);
        vault.materializeAccount(alice);
        assertEq(vault.claimableExitedMargin(alice), 100e18);

        _openCallAtEpoch(2, 100e18);
        _finishFundingAtEpoch(2);
        vault.finalizeEpochSlash(2);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 3);
        // Descriptive only: this preview discards replay.complete; the successful claim below pins the behavior.
        assertEq(vault.claimableExitedMargin(alice), 100e18);

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 100e18);

        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 3);
    }

    function testLiveAuctionBlocksDefaultingAccountClaims() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);
        vault.materializeAccount(alice);

        _openCallAtEpoch(2, 100e18);
        _finishFundingAtEpoch(2);
        vault.finalizeEpochSlash(2);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 3);

        vm.expectRevert(LCCErrorsLib.AccountMaterializationIncomplete.selector);
        vm.prank(bob);
        vault.claimExitedMargin(bob);

        // Public shutdown/terminal transitions settle a live auction first. Force only the terminal flag here to
        // prove claimRemainingMargin independently preserves the same replay barrier while the slot is unsettled.
        _setMaxEpochsForTest(2);
        vm.expectRevert(LCCErrorsLib.AccountMaterializationIncomplete.selector);
        vm.prank(bob);
        vault.claimRemainingMargin(bob);
        _setMaxEpochsForTest(0);

        ILCCVault.EpochState memory state = vault.getEpochState(2);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);

        ILCCVault.Account memory account = vault.getAccount(bob);
        assertEq(account.activeMargin, 50e18);
        assertEq(account.activeCommitment, 100e18);
        assertEq(account.claimableExitMargin, 0);
        assertEq(account.calledEpochCursor, 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 3);
    }

    function testLiveAuctionPersistsPendingActivationBeforeDefaultBarrier() public {
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH + NORMAL + PRE_CALL);
        _deposit(bob, 50e18);

        ILCCVault.Account memory pending = _loadStoredAccount(bob);
        assertEq(pending.activeMargin, 0);
        assertEq(pending.activeCommitment, 0);
        assertEq(pending.pendingMargin, 50e18);
        assertEq(pending.pendingCommitment, 100e18);
        assertEq(pending.pendingActivationEpoch, 2);

        _openCallAtEpoch(2, 150e18);
        _fundAtEpoch(alice, 2);
        _finishFundingAtEpoch(2);
        vault.finalizeEpochSlash(2);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 3);

        ILCCVault.Account memory expected = vault.getAccount(bob);
        assertEq(expected.activeMargin, 50e18);
        assertEq(expected.activeCommitment, 100e18);
        assertEq(expected.pendingMargin, 0);
        assertEq(expected.pendingCommitment, 0);
        assertEq(expected.pendingActivationEpoch, 0);
        assertEq(expected.calledEpochCursor, 0);

        vault.materializeAccount(bob);
        ILCCVault.Account memory stored = _loadStoredAccount(bob);
        assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(expected)));

        bytes32 firstMaterialization = _storedAccountHash(bob);
        vault.materializeAccount(bob);
        assertEq(_storedAccountHash(bob), firstMaterialization);

        vm.expectRevert(LCCErrorsLib.AccountMaterializationIncomplete.selector);
        vm.prank(bob);
        vault.claimExitedMargin(bob);

        _setMaxEpochsForTest(2);
        vm.expectRevert(LCCErrorsLib.AccountMaterializationIncomplete.selector);
        vm.prank(bob);
        vault.claimRemainingMargin(bob);
        _setMaxEpochsForTest(0);

        vm.warp(START + 3 * EPOCH);
        vault.materializeAccount(carol);

        _setMaxEpochsForTest(3);
        assertEq(vault.getAccount(bob).activeMargin, 0);
        vm.expectRevert(LCCErrorsLib.NothingToClaim.selector);
        vm.prank(bob);
        vault.claimRemainingMargin(bob);
    }

    function testOracleCapBindsAtFillTimePrice() public {
        _setupShortfallAuction();

        // Margin appreciates 10x after the kick: the oracle cap (100% of fill value) binds below the ramp award.
        oracle.setPrice(10 * ORACLE_PRICE_SCALE);
        vm.warp(DEADLINE + 10);

        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(25e18, 2.5e18, type(uint256).max);

        // Ramp award would be 37.5e18 * 25/50 = 18.75e18; cap = 25e18 / 10 = 2.5e18.
        assertEq(award, 2.5e18);
    }

    function testTakeRevertsWhenOracleMoveErasesQuotedAward() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        uint256 fill = 50e18;
        LCCAuctionLib.AuctionState memory beforeState = vault.getAuctionState(0);
        uint256 quotedAward = LCCAuctionLib.computeAward(
            beforeState,
            fill,
            5,
            vault.auctionConfig().auctionStepDuration,
            vault.auctionConfig().auctionStepDecayRateBps,
            vault.riskConfig().slashFeeBps,
            vault.riskConfig().maxAuctionAwardBps,
            oracle.price()
        );
        assertEq(quotedAward, _referenceAward(50e18, 0, fill, 50e18, 5, 5, 5_000, 1_000, 10_000, oracle.price()));

        oracle.setPrice(ORACLE_PRICE_SCALE * 1e18);

        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 marginBefore = margin.balanceOf(carol);
        vm.expectRevert(LCCErrorsLib.InsufficientMarginAward.selector);
        vm.prank(carol);
        vault.takeAuction(fill, quotedAward, type(uint256).max);

        LCCAuctionLib.AuctionState memory afterState = vault.getAuctionState(0);
        assertEq(afterState.filledAmount, 0);
        assertEq(afterState.marginAwarded, 0);
        assertEq(usdc.balanceOf(carol), usdcBefore);
        assertEq(margin.balanceOf(carol), marginBefore);
        assertEq(notificationVault.balanceOf(carol), 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);
    }

    function testTakeDeadlineUsesWallClockAfterPause() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        vm.prank(owner);
        vault.pause();
        vm.warp(DEADLINE + 15);
        vm.prank(owner);
        vault.unpause();

        // The effective auction clock is still DEADLINE + 5, but the transaction's wall-clock deadline has expired.
        vm.expectRevert(LCCErrorsLib.DeadlineExpired.selector);
        vm.prank(carol);
        vault.takeAuction(10e18, 0, DEADLINE + 5);

        LCCAuctionLib.AuctionState memory state = vault.getAuctionState(0);
        assertEq(state.filledAmount, 0);
        assertEq(state.marginAwarded, 0);
    }

    function testExpiredTakeDeadlinePrecedesShutdownGuard() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        vm.prank(owner);
        vault.shutdown();

        vm.expectRevert(LCCErrorsLib.DeadlineExpired.selector);
        vm.prank(carol);
        vault.takeAuction(10e18, 0, block.timestamp - 1);
    }

    function testExpiredTakeDeadlinePrecedesAuctionNotLiveGuard() public {
        vm.warp(START + 1);

        vm.expectRevert(LCCErrorsLib.DeadlineExpired.selector);
        vm.prank(carol);
        vault.takeAuction(10e18, 0, START);
    }

    function testTakeRevertsWhenAwardIsBelowMinimum() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 expectedAward = _referenceAward(50e18, 0, 10e18, 50e18, 5, 5, 5_000, 1_000, 10_000, oracle.price());
        vm.expectRevert(LCCErrorsLib.InsufficientMarginAward.selector);
        vm.prank(carol);
        vault.takeAuction(10e18, expectedAward + 1, block.timestamp);

        LCCAuctionLib.AuctionState memory state = vault.getAuctionState(0);
        assertEq(state.filledAmount, 0);
        assertEq(state.marginAwarded, 0);
        assertEq(usdc.balanceOf(carol), usdcBefore);
        assertEq(notificationVault.balanceOf(carol), 0);
    }

    function testTakeSucceedsAtMinimumAwardBoundary() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        uint256 expectedAward = _referenceAward(50e18, 0, 10e18, 50e18, 5, 5, 5_000, 1_000, 10_000, oracle.price());
        vm.prank(carol);
        (uint256 filled, uint256 award) = vault.takeAuction(10e18, expectedAward, block.timestamp);

        assertEq(filled, 10e18);
        assertEq(award, expectedAward);
    }

    function testTakeAcceptsFavorableOracleMoveAboveQuotedAward() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        uint256 fill = 50e18;
        oracle.setPrice(4 * ORACLE_PRICE_SCALE);
        LCCAuctionLib.AuctionState memory beforeState = vault.getAuctionState(0);
        uint256 quotedAward = LCCAuctionLib.computeAward(
            beforeState,
            fill,
            5,
            vault.auctionConfig().auctionStepDuration,
            vault.auctionConfig().auctionStepDecayRateBps,
            vault.riskConfig().slashFeeBps,
            vault.riskConfig().maxAuctionAwardBps,
            oracle.price()
        );
        assertEq(quotedAward, _referenceAward(50e18, 0, fill, 50e18, 5, 5, 5_000, 1_000, 10_000, oracle.price()));

        oracle.setPrice(ORACLE_PRICE_SCALE);

        vm.prank(carol);
        (uint256 filled, uint256 award) = vault.takeAuction(fill, quotedAward, type(uint256).max);

        assertEq(filled, fill);
        assertEq(award, _referenceAward(50e18, 0, fill, 50e18, 5, 5, 5_000, 1_000, 10_000, oracle.price()));
        assertGt(award, quotedAward);
    }

    function testPriorPartialFillReducesLaterFillAndAwardAtomically() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 15);

        uint256 expectedPriorAward =
            _referenceAward(50e18, 0, 40e18, 50e18, 15, 5, 5_000, 1_000, 10_000, oracle.price());
        vm.prank(carol);
        (uint256 priorFill, uint256 priorAward) = vault.takeAuction(40e18, expectedPriorAward, type(uint256).max);
        assertEq(priorFill, 40e18);
        assertEq(priorAward, expectedPriorAward);

        LCCAuctionLib.AuctionState memory priorState = vault.getAuctionState(0);
        assertEq(priorState.shortfallAmount - priorState.filledAmount, 10e18);
        assertEq(priorState.marginPool - priorState.marginAwarded, 50e18 - expectedPriorAward);

        uint256 expectedRemainingAward =
            _referenceAward(50e18, priorAward, 10e18, 50e18, 15, 5, 5_000, 1_000, 10_000, oracle.price());
        vm.expectRevert(LCCErrorsLib.InsufficientMarginAward.selector);
        vm.prank(bob);
        vault.takeAuction(20e18, expectedRemainingAward + 1, type(uint256).max);

        LCCAuctionLib.AuctionState memory revertedState = vault.getAuctionState(0);
        assertEq(revertedState.filledAmount, priorState.filledAmount);
        assertEq(revertedState.marginAwarded, priorState.marginAwarded);

        vm.prank(bob);
        (uint256 filled, uint256 award) = vault.takeAuction(20e18, expectedRemainingAward, type(uint256).max);
        assertEq(filled, 10e18);
        assertEq(award, expectedRemainingAward);
    }

    function testZeroOraclePriceRevertsTake() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);
        oracle.setPrice(0);

        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vm.prank(carol);
        vault.takeAuction(10e18, 0, type(uint256).max);
    }

    function testTakeRevertsWhenUsd3CannotAccept() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        usd3.setDepositLimit(0);
        vm.expectRevert();
        vm.prank(carol);
        vault.takeAuction(10e18, 0, type(uint256).max);

        usd3.setDepositLimit(type(uint256).max);
        usd3.setDepositHookReverts(true);
        vm.expectRevert("!allowed");
        vm.prank(carol);
        vault.takeAuction(10e18, 0, type(uint256).max);

        // Nothing was filled or awarded; the pool is intact.
        LCCAuctionLib.AuctionState memory state = vault.getAuctionState(0);
        assertEq(state.filledAmount, 0);
        assertEq(state.marginAwarded, 0);
        assertEq(margin.balanceOf(carol), 1_000_000e18);
    }

    function testSmallFillBelowUsd3MinDepositSucceedsWhenVaultExempt() public {
        _setupShortfallAuction();
        usd3.setMinDeposit(100e18);
        usd3.setSupplyCapExempt(address(vault), true);
        vm.warp(DEADLINE + 5);

        vm.prank(carol);
        (uint256 filled,) = vault.takeAuction(1, 0, type(uint256).max);

        assertEq(filled, 1);
        assertEq(notificationVault.balanceOf(carol), 1);
    }

    function testOneUnitResidualAtPpsAboveOneSettlesAtWindowEnd() public {
        _seedUsd3(2, 1);
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        vm.prank(carol);
        (uint256 filled,) = vault.takeAuction(50e18 - 1, 0, type(uint256).max);
        assertEq(filled, 50e18 - 1);

        vm.expectRevert(bytes("ZERO_SHARES"));
        vm.prank(bob);
        vault.takeAuction(type(uint256).max, 0, type(uint256).max);

        LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(0);
        assertEq(auction.shortfallAmount - auction.filledAmount, 1);
        vm.warp(WINDOW_END);
        vault.materializeAccount(carol);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        auction = vault.getAuctionState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(auction.filledAmount, auction.shortfallAmount - 1);
        assertLe(auction.marginAwarded, auction.marginPool);
        assertEq(auction.marginAwarded + state.returnPool + _accruedTreasuryMargin(), state.slashedMargin);
    }

    function testMaximumLiveStepCanExceedConfiguredStepCount() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.fundingDuration = 30;
        params.auctionStepCount = 6;
        _deployVaultWithParams(params);

        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        uint256 deadline = START + NORMAL + PRE_CALL + params.fundingDuration;
        vm.warp(deadline);
        vault.finalizeEpochSlash(0);

        uint256 liveTimestamp = START + EPOCH - 1;
        vm.warp(liveTimestamp);
        ILCCVault.AuctionConfig memory config = vault.auctionConfig();
        uint256 maximumLiveStep = (liveTimestamp - deadline) / config.auctionStepDuration;
        assertEq(config.auctionStepCount, 6);
        assertEq(config.auctionStepDuration, 1);
        assertEq(maximumLiveStep, 9);

        uint256 expectedAward = _referenceAward(
            50e18,
            0,
            50e18,
            50e18,
            liveTimestamp - deadline,
            config.auctionStepDuration,
            config.auctionStepDecayRateBps,
            vault.riskConfig().slashFeeBps,
            vault.riskConfig().maxAuctionAwardBps,
            oracle.price()
        );
        vm.prank(carol);
        (uint256 filled, uint256 award) = vault.takeAuction(50e18, expectedAward, type(uint256).max);

        assertEq(filled, 50e18);
        assertEq(award, expectedAward);
        assertLe(award, 50e18);
        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(award + state.returnPool + _accruedTreasuryMargin(), state.slashedMargin);
    }

    function testShutdownForceSettlesAndBlocksTakes() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        vm.prank(owner);
        vault.shutdown();

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(_accruedTreasuryMargin(), 0);
        ILCCVault.EpochState memory epochState = vault.getEpochState(0);
        assertEq(epochState.returnPool, 50e18);
        assertEq(epochState.returnCommitment, 100e18);

        vm.expectRevert(LCCErrorsLib.ShutdownActive.selector);
        vm.prank(carol);
        vault.takeAuction(10e18, 0, type(uint256).max);

        // Honored funder's remaining-margin claim is isolated from the swept inventory.
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 50e18);
    }

    function testSequentialCallsSettlePriorAuctionBeforeNextKick() public {
        _setupShortfallAuction();

        // Nobody touches the vault during epoch 0's window; epoch 1 runs a fresh call.
        vm.warp(START + EPOCH + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(1, 100e18);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);

        vm.warp(START + EPOCH + NORMAL + PRE_CALL);
        vm.prank(alice);
        vault.fundCall(false);

        vm.warp(START + EPOCH + NORMAL + PRE_CALL + FUNDING);
        vault.finalizeEpochSlash(1);

        // Epoch 0 completed unfilled, so its pool went to treasury and Alice alone fully covers epoch 1.
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testExitingDefaulterFeedsPoolAndExitBucketCarved() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        vm.prank(bob);
        uint256 maturity = vault.requestExit(type(uint256).max, type(uint256).max);

        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);
        assertEq(vault.getAuctionState(0).marginPool, 50e18);
        assertEq(vault.exitBucketMarginByMaturity(maturity), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), 0);
    }

    function testSetMaxAuctionAwardBpsMatrix() public {
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        vm.prank(owner);
        vault.setMaxAuctionAwardBps(10_001);

        vm.prank(owner);
        vault.setMaxAuctionAwardBps(5_000);
        assertEq(vault.riskConfig().maxAuctionAwardBps, 5_000);

        _setupShortfallAuction();
        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(owner);
        vault.setMaxAuctionAwardBps(1_000);
    }

    function testSetSlashFeeBpsRevertsWhileAuctionLive() public {
        _setupShortfallAuction();

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(owner);
        vault.setSlashFeeBps(500);
    }

    function testCannotEnableAwardCapWithoutMachinery() public {
        vault = _newVault(_params(CAP, CAP));

        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        vm.prank(owner);
        vault.setMaxAuctionAwardBps(1);
    }

    function testInitializerValidationMatrix() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);

        params.auctionStepDecayRateBps = 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        // Disabled auction (stepCount 0) still rejects a nonzero award cap.
        params.auctionStepDecayRateBps = 0;
        params.maxAuctionAwardBps = 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        // A one-step auction would offer zero collateral for its entire window.
        params = _auctionParams();
        params.auctionStepCount = 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _auctionParams();
        params.auctionStepDecayRateBps = 0;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _auctionParams();
        params.auctionStepDecayRateBps = 10_001;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _auctionParams();
        params.maxAuctionAwardBps = 10_001;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        // Auction-enabled vaults need a nonzero Closed window.
        params = _auctionParams();
        params.fundingDuration = EPOCH - NORMAL - PRE_CALL;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        // At least one second per step: stepCount cannot exceed the Closed window.
        params = _auctionParams();
        params.auctionStepCount = EPOCH - NORMAL - PRE_CALL - FUNDING + 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params = _params(CAP, CAP);
        params.protocolCommitmentCap = uint256(type(uint128).max) + 1;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);
    }

    function testSetRiskCapsRejectsCapAboveUint128() public {
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        vm.prank(owner);
        vault.setRiskCaps(uint256(type(uint128).max) + 1, CAP, 2_000, 0);
    }

    function _setMaxEpochsForTest(uint256 maxEpochs) internal {
        uint256 word = uint256(vm.load(address(vault), bytes32(CLOCK_CONFIG_SLOT)));
        word = (word & ~(UINT64_MASK << 64)) | (maxEpochs << 64);
        vm.store(address(vault), bytes32(CLOCK_CONFIG_SLOT), bytes32(word));
    }

    function _loadStoredAccount(address user) internal view returns (ILCCVault.Account memory account) {
        uint256 accountSlot = uint256(keccak256(abi.encode(user, ACCOUNTS_SLOT)));
        uint256 word0 = uint256(vm.load(address(vault), bytes32(accountSlot)));
        uint256 word1 = uint256(vm.load(address(vault), bytes32(accountSlot + 1)));
        uint256 word2 = uint256(vm.load(address(vault), bytes32(accountSlot + 2)));
        uint256 word3 = uint256(vm.load(address(vault), bytes32(accountSlot + 3)));
        uint256 word4 = uint256(vm.load(address(vault), bytes32(accountSlot + 4)));

        account.activeMargin = uint128(word0);
        account.activeCommitment = uint128(word0 >> 128);
        account.pendingMargin = uint128(word1);
        account.pendingCommitment = uint128(word1 >> 128);
        account.claimableExitMargin = uint128(word2);
        account.exitBucketMargin = uint128(word2 >> 128);
        account.exitBucketCommitment = uint128(word3);
        account.pendingActivationEpoch = (word3 >> 128) & UINT64_MASK;
        account.calledEpochCursor = word3 >> 192;
        account.exitMaturityEpoch = word4 & UINT64_MASK;
        account.exitRequested = ((word4 >> 64) & 0xff) != 0;
        account.exitClaimed = ((word4 >> 72) & 0xff) != 0;
        account.exitMatured = ((word4 >> 80) & 0xff) != 0;
        account.commitmentStartEpoch = (word4 >> 88) & UINT64_MASK;
    }

    function _storedAccountHash(address user) internal view returns (bytes32) {
        uint256 accountSlot = uint256(keccak256(abi.encode(user, ACCOUNTS_SLOT)));
        return keccak256(
            abi.encode(
                vm.load(address(vault), bytes32(accountSlot)),
                vm.load(address(vault), bytes32(accountSlot + 1)),
                vm.load(address(vault), bytes32(accountSlot + 2)),
                vm.load(address(vault), bytes32(accountSlot + 3)),
                vm.load(address(vault), bytes32(accountSlot + 4))
            )
        );
    }
}
