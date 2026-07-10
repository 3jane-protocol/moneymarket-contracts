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

    function setUp() public override {
        super.setUp();
        _deployAuctionVault();
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

        assertEq(margin.balanceOf(treasury), 0);
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
        // deadline, not the kick, so the ramp is already at 75%.
        vm.warp(DEADLINE + 10);
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(25e18);
        assertEq(award, 18.75e18);
    }

    function testNoKickWhenFinalizedAfterWindow() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        vm.warp(WINDOW_END + 1);
        vault.finalizeEpochSlash(0);

        assertEq(margin.balanceOf(treasury), 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testNoKickWhenAwardCapZero() public {
        vm.prank(owner);
        vault.setMaxAuctionAwardBps(0);

        _setupShortfallAuction();

        assertEq(margin.balanceOf(treasury), 0);
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
        assertEq(margin.balanceOf(treasury), 0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testZeroAwardFillBeforeFirstStep() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 4);

        vm.prank(carol);
        (uint256 filled, uint256 award) = vault.takeAuction(10e18);

        assertEq(filled, 10e18);
        assertEq(award, 0);
        assertEq(notificationVault.balanceOf(carol), 10e18);
        assertEq(margin.balanceOf(carol), 1_000_000e18);
    }

    function testPartialFillsAcrossStepsAndLazySweep() public {
        _setupShortfallAuction();

        // Step 1 (50% offered = 25e18): fill half the shortfall.
        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (uint256 filled1, uint256 award1) = vault.takeAuction(25e18);
        assertEq(filled1, 25e18);
        assertEq(award1, 12.5e18);

        // Step 2 (75% offered = 37.5e18): clamp a too-large fill to the 25e18 remaining.
        vm.warp(DEADLINE + 10);
        vm.prank(bob);
        (uint256 filled2, uint256 award2) = vault.takeAuction(100e18);
        assertEq(filled2, 25e18);
        assertEq(award2, 18.75e18);

        // Full fill settles immediately: the slash fee is charged on awarded margin and capped by the remainder.
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        uint256 feeOnAward = (award1 + award2) / 10;
        uint256 remainder = 50e18 - award1 - award2;
        assertEq(margin.balanceOf(treasury), feeOnAward < remainder ? feeOnAward : remainder);
        assertEq(notificationVault.balanceOf(carol), 25e18);
        assertEq(notificationVault.balanceOf(bob), 25e18);
    }

    function testUnfilledAuctionSweepsLazilyAfterWindow() public {
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(10e18);
        assertEq(award, 5e18);

        vm.warp(WINDOW_END);
        vm.expectEmit(true, false, false, true, address(vault));
        emit LCCEventsLib.SlashSurplusDisposed(0, 0.5e18, 44.5e18, 89e18);
        vm.expectEmit(true, false, false, true, address(vault));
        emit LCCEventsLib.AuctionSettled(0, 10e18, 5e18);
        vault.materializeAccount(carol);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(margin.balanceOf(treasury), 0.5e18);

        vm.warp(WINDOW_END + 1);
        vm.expectRevert(LCCErrorsLib.AuctionNotLive.selector);
        vm.prank(carol);
        vault.takeAuction(1e18);
    }

    function testFullFillEndsAuction() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        vm.prank(carol);
        vault.takeAuction(50e18);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);

        vm.expectRevert(LCCErrorsLib.AuctionNotLive.selector);
        vm.prank(bob);
        vault.takeAuction(1e18);
    }

    function testOracleCapBindsAtFillTimePrice() public {
        _setupShortfallAuction();

        // Margin appreciates 10x after the kick: the oracle cap (100% of fill value) binds below the ramp award.
        oracle.setPrice(10 * ORACLE_PRICE_SCALE);
        vm.warp(DEADLINE + 10);

        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(25e18);

        // Ramp award would be 37.5e18 * 25/50 = 18.75e18; cap = 25e18 / 10 = 2.5e18.
        assertEq(award, 2.5e18);
    }

    function testZeroOraclePriceRevertsTake() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);
        oracle.setPrice(0);

        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vm.prank(carol);
        vault.takeAuction(10e18);
    }

    function testTakeRevertsWhenUsd3CannotAccept() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        usd3.setDepositLimit(0);
        vm.expectRevert();
        vm.prank(carol);
        vault.takeAuction(10e18);

        usd3.setDepositLimit(type(uint256).max);
        usd3.setDepositHookReverts(true);
        vm.expectRevert("!allowed");
        vm.prank(carol);
        vault.takeAuction(10e18);

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
        (uint256 filled,) = vault.takeAuction(1);

        assertEq(filled, 1);
        assertEq(notificationVault.balanceOf(carol), 1);
    }

    function testOneUnitResidualAtPpsAboveOneSettlesAtWindowEnd() public {
        _seedUsd3(2, 1);
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        vm.prank(carol);
        (uint256 filled,) = vault.takeAuction(50e18 - 1);
        assertEq(filled, 50e18 - 1);

        vm.expectRevert(bytes("ZERO_SHARES"));
        vm.prank(bob);
        vault.takeAuction(type(uint256).max);

        LCCAuctionLib.AuctionState memory auction = vault.getAuctionState(0);
        assertEq(auction.shortfallAmount - auction.filledAmount, 1);
        vm.warp(WINDOW_END);
        vault.materializeAccount(carol);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        auction = vault.getAuctionState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(auction.filledAmount, auction.shortfallAmount - 1);
        assertLe(auction.marginAwarded, auction.marginPool);
        assertEq(auction.marginAwarded + state.returnPool + margin.balanceOf(treasury), state.slashedMargin);
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

        uint256 expectedAward = LCCAuctionLib.offeredPool(
            50e18, liveTimestamp - deadline, config.auctionStepDuration, config.auctionStepDecayRateBps
        );
        vm.prank(carol);
        (uint256 filled, uint256 award) = vault.takeAuction(50e18);

        assertEq(filled, 50e18);
        assertEq(award, expectedAward);
        assertLe(award, 50e18);
        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(award + state.returnPool + margin.balanceOf(treasury), state.slashedMargin);
    }

    function testShutdownForceSettlesAndBlocksTakes() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        vm.prank(owner);
        vault.shutdown();

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(margin.balanceOf(treasury), 0);
        ILCCVault.EpochState memory epochState = vault.getEpochState(0);
        assertEq(epochState.returnPool, 50e18);
        assertEq(epochState.returnCommitment, 100e18);

        vm.expectRevert(LCCErrorsLib.ShutdownActive.selector);
        vm.prank(carol);
        vault.takeAuction(10e18);

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
        assertEq(margin.balanceOf(treasury), 0);

        vm.warp(START + EPOCH + NORMAL + PRE_CALL);
        vm.prank(alice);
        vault.fundCall(false);

        vm.warp(START + EPOCH + NORMAL + PRE_CALL + FUNDING);
        vault.finalizeEpochSlash(1);

        // The epoch-0 defaulter's returned surplus is live commitment again for epoch 1, so Alice's funding
        // does not cover the entire second call.
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 2);
    }

    function testExitingDefaulterFeedsPoolAndExitBucketCarved() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        vm.prank(bob);
        uint256 maturity = vault.requestExit();

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
}
