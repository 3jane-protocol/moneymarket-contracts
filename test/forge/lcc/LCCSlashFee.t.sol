// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCAuctionLib} from "../../../src/lcc/libraries/LCCAuctionLib.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {ORACLE_PRICE_SCALE, BPS} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

contract LCCSlashFeeTest is LCCBase {
    uint256 internal constant DEADLINE = START + NORMAL + PRE_CALL + FUNDING;
    uint256 internal constant WINDOW_END = START + EPOCH;

    function testNaturalEndZeroTakesSendsGrossPoolToTreasury() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        vm.warp(WINDOW_END);
        vault.materializeAccount(bob);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), 50e18);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(vault.getAccount(bob).activeMargin, 0);
    }

    function testOpeningWindowZeroAwardFillChargesStepOneFeeFloor() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        uint256 fill = 10e18;
        vm.warp(DEADLINE + 4);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(fill, 0, type(uint256).max);
        assertEq(award, 0);

        SettlementReference memory expected = _referenceSettlement(50e18, award, fill, 50e18, 5_000, 1_000, true);
        uint256 stepOneAward = _referenceAward(50e18, 0, fill, 50e18, 5, 5, 5_000, 1_000, BPS, ORACLE_PRICE_SCALE);
        assertEq(expected.fee, Math.mulDiv(stepOneAward, 1_000, BPS));
        assertGt(expected.fee, 0);

        vm.warp(WINDOW_END);
        vault.materializeAccount(carol);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), expected.unfilledPool + expected.fee);
        assertEq(state.returnPool, expected.baseReturn);
    }

    function testDustFillSplitAcrossOpeningBoundaryCannotReduceFeeFloor() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        uint256 totalFill = 10e18;
        uint256 openingDust = 11;
        vm.warp(DEADLINE + 4);
        vm.prank(carol);
        (, uint256 openingAward) = vault.takeAuction(openingDust, 0, type(uint256).max);
        assertEq(openingAward, 0);

        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (, uint256 stepOneAward) = vault.takeAuction(totalFill - openingDust, 0, type(uint256).max);

        SettlementReference memory expected =
            _referenceSettlement(50e18, stepOneAward, totalFill, 50e18, 5_000, 1_000, true);
        assertGt(expected.feeBasis, stepOneAward);
        assertGt(expected.fee, Math.mulDiv(stepOneAward, 1_000, BPS));

        vm.warp(WINDOW_END);
        vault.materializeAccount(carol);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), expected.unfilledPool + expected.fee);
        assertEq(state.returnPool, expected.baseReturn);
    }

    function testPartialFillUsesGrossPoolFirstConservation() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        uint256 fill = 17e18;
        vm.warp(DEADLINE + 10);
        uint256 expectedAward = _referenceAward(50e18, 0, fill, 50e18, 10, 5, 5_000, 1_000, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(fill, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(50e18, award, fill, 50e18, 5_000, 1_000, true);
        vm.warp(WINDOW_END);
        vault.materializeAccount(carol);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), expected.unfilledPool + expected.fee);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(50e18, award + expected.fee + state.returnPool + expected.unfilledPool);
    }

    function testHighDecayFullFeeTakeIsNeverClipped() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.auctionStepDecayRateBps = 9_999;
        params.slashFeeBps = BPS;
        _deployVaultWithParams(params);
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        uint256 expectedAward = _referenceAward(50e18, 0, 50e18, 50e18, 5, 5, 9_999, BPS, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(50e18, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(50e18, award, 50e18, 50e18, 9_999, BPS, true);
        assertEq(expected.fee, Math.mulDiv(expected.feeBasis, BPS, BPS));
        assertLe(expected.fee, 50e18 - award);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), expected.fee);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(50e18, award + expected.fee + state.returnPool);
    }

    function testLateFinalizationWithoutKickConfiscatesPool() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        vm.warp(WINDOW_END + 1);
        vault.finalizeEpochSlash(0);
        vault.materializeAccount(bob);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.getAuctionState(0).shortfallAmount, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(vault.getAccount(bob).activeMargin, 0);
    }

    function testShutdownTruncatedAuctionDoesNotDivertUnfilledPool() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        uint256 fill = 10e18;
        vm.warp(DEADLINE + 5);
        uint256 expectedAward = _referenceAward(50e18, 0, fill, 50e18, 5, 5, 5_000, 1_000, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(fill, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(50e18, award, fill, 50e18, 5_000, 1_000, false);
        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(expected.unfilledPool, 0);
        assertEq(expected.fee, 0);
        assertEq(expected.baseReturn, 45_454_545_454_545_454_546);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(50e18, award + state.returnPool);
    }

    function testLateNoKickConfiscatesDespiteSaturatedProtocolCap() public {
        _setupPartiallyFundedSaturatedCap(true);

        vm.warp(WINDOW_END + 1);
        vault.finalizeEpochSlash(0);

        _assertLateEligiblePoolConfiscated();
    }

    function testAuctionDisabledBypassesSaturatedProtocolCap() public {
        _setupPartiallyFundedSaturatedCap(false);

        _finishFunding();
        vault.finalizeEpochSlash(0);

        _assertNoKickPoolReturned();
    }

    function testFeeOnAwardedPartialFillSplit() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        uint256 expectedAward = _referenceAward(50e18, 0, 10e18, 50e18, 5, 5, 5_000, 1_000, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(10e18, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(50e18, award, 10e18, 50e18, 5_000, 1_000, true);
        assertEq(expected.baseReturn, 5_000_000_000_000_000_001);
        assertEq(expected.unfilledPool + expected.fee, 40_454_545_454_545_454_545);

        vm.warp(WINDOW_END);
        vault.materializeAccount(carol);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), expected.unfilledPool + expected.fee);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(state.returnCommitment, expected.baseReturn * 2);
    }

    function testFullFillFeeReservedInFull() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.slashFeeBps = 10_000;
        _deployVaultWithParams(params);
        _setupShortfallAuction();

        vm.warp(DEADLINE + 10);
        uint256 expectedAward = _referenceAward(50e18, 0, 50e18, 50e18, 10, 5, 5_000, BPS, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(50e18, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(50e18, award, 50e18, 50e18, 5_000, BPS, true);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), expected.fee);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(state.returnCommitment, expected.baseReturn * 2);
    }

    function testNoKickLateFinalizationConfiscatesAsUnfilledEligibleEpoch() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        vm.warp(WINDOW_END + 1);
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), 50e18);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
    }

    function testDisabledAuctionHasNoFeeBasis() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        SettlementReference memory expected = _referenceSettlement(100e18, 0, 0, 1, 0, 0, false);
        assertEq(expected.baseReturn, 100e18);
        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(state.returnCommitment, 200e18);
    }

    function testZeroShortfallSlashHasNoFeeBasis() public {
        _deployAuctionVault();
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);
        _openCall(1);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(state.returnPool, 1e18);
        assertEq(state.returnCommitment, 2e18);
        assertEq(vault.getAuctionState(0).shortfallAmount, 0);
    }

    function testShutdownSettledPartialFillReturnsUnawardedPoolWithoutTake() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        uint256 expectedAward = _referenceAward(50e18, 0, 10e18, 50e18, 5, 5, 5_000, 1_000, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(10e18, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(50e18, award, 10e18, 50e18, 5_000, 1_000, false);

        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(expected.fee, 0);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(state.returnCommitment, expected.baseReturn * 2);
    }

    function testFullFeeNeverAuctionedEligibleEpochConfiscatesWithoutOracle() public {
        // A late eligible epoch receives completed zero-fill treatment even though no auction record was opened.
        ILCCVault.VaultParams memory params = _auctionParams();
        params.slashFeeBps = 10_000;
        _deployVaultWithParams(params);

        _deposit(alice, 100e18);
        oracle.setPrice(ORACLE_PRICE_SCALE);
        _openCall(100e18);
        vm.warp(WINDOW_END);

        oracle.setPrice(0);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), 100e18);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
    }

    function testFullFeePartialFillUsesCallOpenSnapshot() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.slashFeeBps = 10_000;
        _deployVaultWithParams(params);
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        uint256 expectedAward = _referenceAward(50e18, 0, 10e18, 50e18, 5, 5, 5_000, BPS, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(10e18, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(50e18, award, 10e18, 50e18, 5_000, BPS, true);

        oracle.setPrice(0);
        vm.warp(WINDOW_END);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(_accruedTreasuryMargin(), expected.unfilledPool + expected.fee);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(state.returnCommitment, expected.baseReturn * 2);
    }

    function testReservedFeeAndReturnSettleFromSnapshotWithoutLiveOracle() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.slashFeeBps = 10_000;
        _deployVaultWithParams(params);
        _setupShortfallAuction();

        vm.warp(DEADLINE + 10);
        uint256 expectedAward = _referenceAward(50e18, 0, 40e18, 50e18, 10, 5, 5_000, BPS, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(40e18, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(50e18, award, 40e18, 50e18, 5_000, BPS, true);

        oracle.setPrice(0);
        vm.warp(WINDOW_END);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(_accruedTreasuryMargin(), expected.unfilledPool + expected.fee);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(state.returnCommitment, expected.baseReturn * 2);
    }

    function testUnfilledAuctionDivertsGrossPoolDespiteTightCap() public {
        _setupTightCapAuction();

        vm.warp(WINDOW_END);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), 100e18);
    }

    function testTightCapClampPinsPartialFillRecovery() public {
        _setupTightCapAuction();

        vm.warp(DEADLINE + 5);
        uint256 expectedAward = _referenceAward(100e18, 0, 20e18, 200e18, 5, 5, 5_000, 1_000, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(20e18, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);

        SettlementReference memory expected = _referenceSettlement(100e18, award, 20e18, 200e18, 5_000, 1_000, true);

        vm.warp(WINDOW_END);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, expected.baseReturn);
        assertEq(state.returnCommitment, expected.baseReturn * 2);
        assertEq(_accruedTreasuryMargin(), expected.unfilledPool + expected.fee);
    }

    function testProtocolCapRaiseCannotChangePendingAuctionSettlement() public {
        _setupPartiallyFundedSaturatedCap(true);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        uint256 fill = 10e18;
        vm.warp(DEADLINE + 5);
        uint256 expectedAward = _referenceAward(50e18, 0, fill, 50e18, 5, 5, 5_000, 1_000, BPS, ORACLE_PRICE_SCALE);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(fill, expectedAward, type(uint256).max);
        assertEq(award, expectedAward);
        assertGt(award, 0);
        assertEq(vault.riskConfig().protocolCommitmentCap, 200e18);

        uint256 snapshot = vm.snapshotState();

        vm.warp(WINDOW_END);
        vault.materializeAccount(bob);
        ILCCVault.EpochState memory settledBeforeRaise = vault.getEpochState(0);
        uint256 treasuryBeforeRaise = _accruedTreasuryMargin();
        vm.prank(owner);
        vault.setRiskCaps(300e18, 300e18, 2_000, 0);

        assertTrue(vm.revertToStateAndDelete(snapshot), "settlement-before-raise branch restore failed");

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(owner);
        vault.setRiskCaps(300e18, 300e18, 2_000, 0);
        vm.warp(WINDOW_END);
        vault.materializeAccount(bob);
        ILCCVault.EpochState memory settledAfterRejectedRaise = vault.getEpochState(0);
        uint256 treasuryAfterRejectedRaise = _accruedTreasuryMargin();
        vm.prank(owner);
        vault.setRiskCaps(300e18, 300e18, 2_000, 0);

        assertEq(settledAfterRejectedRaise.returnPool, settledBeforeRaise.returnPool);
        assertEq(settledAfterRejectedRaise.returnCommitment, settledBeforeRaise.returnCommitment);
        assertEq(treasuryAfterRejectedRaise, treasuryBeforeRaise);
    }

    function _setupShortfallAuction() internal {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);
    }

    /// @dev Carol rolls rather than defaulting, so her pre-existing 100 commitment remains live through the
    /// auction. Lowering the cap to 150 leaves 50 commitment headroom and independently exercises the
    /// commitment-side clamp without relying on a deposit during the live auction.
    function _setupTightCapAuction() internal {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 300e18;
        _deployVaultWithParams(params);

        _deposit(alice, 99e18);
        _deposit(bob, 1e18);
        _deposit(carol, 50e18);
        _openCall(300e18);
        _fundRolling(carol);

        vm.prank(owner);
        vault.setRiskCaps(150e18, 300e18, 2_000, 0);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);
    }

    function _setupPartiallyFundedSaturatedCap(bool auctionEnabled) internal {
        ILCCVault.VaultParams memory params = auctionEnabled ? _auctionParams() : _params(300e18, 300e18);
        params.protocolCommitmentCap = 300e18;
        params.userCommitmentCap = 300e18;
        _deployVaultWithParams(params);

        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        vm.prank(owner);
        vault.setRiskCaps(200e18, 300e18, 2_000, 0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.fundedAmount + state.fundedUsersRemainingCommitment, 200e18);
        assertLe(vault.riskConfig().protocolCommitmentCap, state.fundedAmount + state.fundedUsersRemainingCommitment);
    }

    function _assertNoKickPoolReturned() internal view {
        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.getAuctionState(0).shortfallAmount, 0);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(state.returnPool, 50e18);
        assertEq(state.returnCommitment, 100e18);
    }

    function _assertLateEligiblePoolConfiscated() internal view {
        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.getAuctionState(0).shortfallAmount, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
    }
}
