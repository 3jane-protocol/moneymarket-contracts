// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";

contract LCCAuctionTest is LCCBase {
    uint256 internal constant DEADLINE = START + NORMAL + PRE_CALL + FUNDING;
    uint256 internal constant WINDOW_END = START + EPOCH;

    function setUp() public override {
        super.setUp();
        _deployAuctionVault();
    }

    /// @dev alice honors, bob defaults: pool = 50e18 margin, shortfall = 50e18 USDC, kicked at the deadline.
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
        emit ILeveragedCallableCreditVault.AuctionKicked(0, 50e18, 50e18);
        vault.finalizeEpochSlash(0);

        assertEq(margin.balanceOf(treasury), 0);
        assertEq(vault.pendingAuctionEpochPlusOne(), 1);

        LCCAuctionLib.AuctionState memory state = vault.getAuctionState(0);
        assertEq(state.shortfallUsdc, 50e18);
        assertEq(state.marginPool, 50e18);
        assertEq(state.filledUsdc, 0);
        assertEq(state.marginAwarded, 0);
    }

    function testNoKickWhenFinalizedAfterWindow() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        vm.warp(WINDOW_END + 1);
        vault.finalizeEpochSlash(0);

        assertEq(margin.balanceOf(treasury), 50e18);
        assertEq(vault.pendingAuctionEpochPlusOne(), 0);
    }

    function testNoKickWhenAwardCapZero() public {
        vm.prank(owner);
        vault.setMaxAuctionAwardBps(0);

        _setupShortfallAuction();

        assertEq(margin.balanceOf(treasury), 50e18);
        assertEq(vault.pendingAuctionEpochPlusOne(), 0);
    }

    function testNoKickWhenNoShortfall() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(1);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        // Alice's ceil-rounded obligation covered the full 1-wei call; bob still defaulted and was slashed.
        assertEq(margin.balanceOf(treasury), 50e18);
        assertEq(vault.pendingAuctionEpochPlusOne(), 0);
    }

    function testZeroAwardFillBeforeFirstStep() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 4);

        vm.prank(carol);
        (uint256 filled, uint256 award) = vault.takeAuction(0, 10e18);

        assertEq(filled, 10e18);
        assertEq(award, 0);
        assertEq(usd3.balanceOf(carol), 10e18);
        assertEq(margin.balanceOf(carol), 1_000_000e18);
    }

    function testPartialFillsAcrossStepsAndLazySweep() public {
        _setupShortfallAuction();

        // Step 1 (50% offered = 25e18): fill half the shortfall.
        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (uint256 filled1, uint256 award1) = vault.takeAuction(0, 25e18);
        assertEq(filled1, 25e18);
        assertEq(award1, 12.5e18);

        // Step 2 (75% offered = 37.5e18): clamp a too-large fill to the 25e18 remaining.
        vm.warp(DEADLINE + 10);
        vm.prank(bob);
        (uint256 filled2, uint256 award2) = vault.takeAuction(0, 100e18);
        assertEq(filled2, 25e18);
        assertEq(award2, 18.75e18);

        // Full fill settles immediately: remainder to treasury.
        assertEq(vault.pendingAuctionEpochPlusOne(), 0);
        assertEq(margin.balanceOf(treasury), 50e18 - award1 - award2);
        assertEq(usd3.balanceOf(carol), 25e18);
        assertEq(usd3.balanceOf(bob), 25e18);
    }

    function testUnfilledAuctionSweepsLazilyAfterWindow() public {
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(0, 10e18);
        assertEq(award, 5e18);

        vm.warp(WINDOW_END);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ILeveragedCallableCreditVault.AuctionSettled(0, 10e18, 5e18, 45e18);
        vault.materializeAccount(carol);

        assertEq(vault.pendingAuctionEpochPlusOne(), 0);
        assertEq(margin.balanceOf(treasury), 45e18);

        vm.warp(WINDOW_END + 1);
        vm.expectRevert(LeveragedCallableCreditVault.AuctionNotLive.selector);
        vm.prank(carol);
        vault.takeAuction(0, 1e18);
    }

    function testFullFillEndsAuction() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        vm.prank(carol);
        vault.takeAuction(0, 50e18);

        assertEq(vault.pendingAuctionEpochPlusOne(), 0);

        vm.expectRevert(LeveragedCallableCreditVault.AuctionNotLive.selector);
        vm.prank(bob);
        vault.takeAuction(0, 1e18);
    }

    function testOracleCapBindsAtFillTimePrice() public {
        _setupShortfallAuction();

        // Margin appreciates 10x after the kick: the oracle cap (100% of fill value) binds below the ramp award.
        oracle.setPrice(10 * ORACLE_PRICE_SCALE);
        vm.warp(DEADLINE + 10);

        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(0, 25e18);

        // Ramp award would be 37.5e18 * 25/50 = 18.75e18; cap = 25e18 / 10 = 2.5e18.
        assertEq(award, 2.5e18);
    }

    function testZeroOraclePriceRevertsTake() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);
        oracle.setPrice(0);

        vm.expectRevert(LeveragedCallableCreditVault.OraclePriceInvalid.selector);
        vm.prank(carol);
        vault.takeAuction(0, 10e18);
    }

    function testTakeRevertsWhenUsd3CannotAccept() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        usd3.setDepositLimit(0);
        vm.expectRevert();
        vm.prank(carol);
        vault.takeAuction(0, 10e18);

        usd3.setDepositLimit(type(uint256).max);
        usd3.setDepositHookReverts(true);
        vm.expectRevert("!allowed");
        vm.prank(carol);
        vault.takeAuction(0, 10e18);

        // Nothing was filled or awarded; the pool is intact.
        LCCAuctionLib.AuctionState memory state = vault.getAuctionState(0);
        assertEq(state.filledUsdc, 0);
        assertEq(state.marginAwarded, 0);
        assertEq(margin.balanceOf(carol), 1_000_000e18);
    }

    function testShutdownForceSettlesAndBlocksTakes() public {
        _setupShortfallAuction();
        vm.warp(DEADLINE + 5);

        vm.prank(owner);
        vault.shutdown();

        assertEq(vault.pendingAuctionEpochPlusOne(), 0);
        assertEq(margin.balanceOf(treasury), 50e18);

        vm.expectRevert(LeveragedCallableCreditVault.ShutdownActive.selector);
        vm.prank(carol);
        vault.takeAuction(0, 10e18);

        // Honored funder's emergency claim is isolated from the swept inventory.
        vm.prank(alice);
        assertEq(vault.claimEmergencyMargin(alice), 50e18);
    }

    function testSequentialCallsSettlePriorAuctionBeforeNextKick() public {
        _setupShortfallAuction();

        // Nobody touches the vault during epoch 0's window; epoch 1 runs a fresh call.
        vm.warp(START + EPOCH + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(1, 100e18);

        assertEq(vault.pendingAuctionEpochPlusOne(), 0);
        assertEq(margin.balanceOf(treasury), 50e18);

        vm.warp(START + EPOCH + NORMAL + PRE_CALL);
        vm.prank(alice);
        vault.fundEpochCall(1);

        vm.warp(START + EPOCH + NORMAL + PRE_CALL + FUNDING);
        vault.finalizeEpochSlash(1);

        // Everyone honored epoch 1: no second auction.
        assertEq(vault.pendingAuctionEpochPlusOne(), 0);
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

        assertEq(vault.pendingAuctionEpochPlusOne(), 1);
        assertEq(vault.getAuctionState(0).marginPool, 50e18);
        assertEq(vault.exitRequestedMarginByMaturity(maturity), 0);
        assertEq(vault.exitRequestedCallableByMaturity(maturity), 0);
    }

    function testSetMaxAuctionAwardBpsMatrix() public {
        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        vm.prank(owner);
        vault.setMaxAuctionAwardBps(10_001);

        vm.prank(owner);
        vault.setMaxAuctionAwardBps(5_000);
        assertEq(vault.maxAuctionAwardBps(), 5_000);

        _setupShortfallAuction();
        vm.expectRevert(LeveragedCallableCreditVault.InvalidPhase.selector);
        vm.prank(owner);
        vault.setMaxAuctionAwardBps(1_000);
    }

    function testCannotEnableAwardCapWithoutMachinery() public {
        vault = new LeveragedCallableCreditVault(_params(CAP, CAP));

        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        vm.prank(owner);
        vault.setMaxAuctionAwardBps(1);
    }

    function testConstructorValidationMatrix() public {
        ILeveragedCallableCreditVault.VaultParams memory params = _params(CAP, CAP);

        params.auctionStepDecayRateBps = 1;
        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        new LeveragedCallableCreditVault(params);

        params.auctionStepDecayRateBps = 0;
        params.maxAuctionAwardBps = 1;
        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        new LeveragedCallableCreditVault(params);

        params = _auctionParams();
        params.auctionStepDecayRateBps = 0;
        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        new LeveragedCallableCreditVault(params);

        params = _auctionParams();
        params.auctionStepDecayRateBps = 10_001;
        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        new LeveragedCallableCreditVault(params);

        params = _auctionParams();
        params.maxAuctionAwardBps = 10_001;
        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        new LeveragedCallableCreditVault(params);

        // Auction-enabled vaults need a nonzero Closed window.
        params = _auctionParams();
        params.fundingDuration = EPOCH - NORMAL - PRE_CALL;
        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        new LeveragedCallableCreditVault(params);

        params = _params(CAP, CAP);
        params.protocolCallableCapUsdc = uint256(type(uint128).max) + 1;
        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        new LeveragedCallableCreditVault(params);
    }

    function testSetRiskCapsRejectsCapAboveUint128() public {
        vm.expectRevert(LeveragedCallableCreditVault.InvalidParams.selector);
        vm.prank(owner);
        vault.setRiskCaps(uint256(type(uint128).max) + 1, CAP, 2_000, 0);
    }
}
