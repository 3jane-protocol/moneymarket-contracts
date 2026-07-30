// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase, LCCGasGriefingOracle, LCCRevertingOracle} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

contract LCCReturnPoolTest is LCCBase {
    function setUp() public override {
        super.setUp();
        _assertLayoutSlot("marginPriceAtCallOpen", MARGIN_PRICE_AT_CALL_OPEN_SLOT);
    }

    function testPendingDisposalUsesCallOpenSnapshotWhenOracleDies() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        oracle.setPrice(ORACLE_PRICE_SCALE);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.warp(START + EPOCH);
        oracle.setPrice(0);

        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 200e18);
    }

    function testRiskCapSetterOnlyBlocksProtocolCapReductionDuringLiveAuction() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 300e18;
        params.userCommitmentCap = 300e18;
        _deployVaultWithParams(params);

        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(owner);
        vault.setRiskCaps(299e18, 300e18, 2_000, 0);

        vm.prank(owner);
        vault.setRiskCaps(300e18, 250e18, 313, 7e18);
        ILCCVault.RiskConfig memory config = vault.riskConfig();
        assertEq(config.protocolCommitmentCap, 300e18);
        assertEq(config.userCommitmentCap, 250e18);
        assertEq(config.exitCapBps, 313);
        assertEq(config.minDepositAssets, 7e18);

        vm.prank(owner);
        vault.setRiskCaps(301e18, 251e18, 314, 8e18);
        config = vault.riskConfig();
        assertEq(config.protocolCommitmentCap, 301e18);
        assertEq(config.userCommitmentCap, 251e18);
        assertEq(config.exitCapBps, 314);
        assertEq(config.minDepositAssets, 8e18);
    }

    function testHeadroomZeroSendsWholeSurplusToTreasury() public {
        _setupCapBoundSlash(100e18);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);
        assertEq(vault.totals().activeMargin, 50e18);
        assertEq(vault.totals().activeCommitment, 100e18);
        assertEq(vault.totals().pendingMargin, 0);
    }

    function testCapAtOrAboveCallDenominatorClampsOnlyBySlashedCommitmentAndPreservesPool() public {
        _setupSingleDefaulterCapBoundSlash(250e18);
        oracle.setPrice(2 * ORACLE_PRICE_SCALE);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        uint256 fundedCallOpenCommitment = state.fundedAmount + state.fundedUsersRemainingCommitment;
        uint256 slashedCommitment = state.commitmentDenominator - fundedCallOpenCommitment;

        assertEq(state.commitmentDenominator, 200e18);
        assertEq(fundedCallOpenCommitment, 100e18);
        assertEq(slashedCommitment, 100e18);
        assertEq(state.returnPool, 50e18);
        assertEq(state.returnCommitment, slashedCommitment);
        assertEq(vault.getAccount(alice).activeMargin, 50e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testCapBetweenFundedBaseAndCallDenominatorReturnsExactlyCapMinusFundedBase() public {
        uint256 cap = 150e18;
        _setupSingleDefaulterCapBoundSlash(cap);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        uint256 fundedCallOpenCommitment = state.fundedAmount + state.fundedUsersRemainingCommitment;

        assertEq(fundedCallOpenCommitment, 100e18);
        assertEq(state.returnPool, 50e18);
        assertEq(state.returnCommitment, cap - fundedCallOpenCommitment);
        assertEq(vault.getAccount(alice).activeMargin, 50e18);
        assertEq(vault.totals().activeCommitment, cap);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testCapAtOrBelowFundedBaseReturnsZero() public {
        _setupSingleDefaulterCapBoundSlash(99e18);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        uint256 fundedCallOpenCommitment = state.fundedAmount + state.fundedUsersRemainingCommitment;

        assertEq(fundedCallOpenCommitment, 100e18);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(vault.getAccount(alice).activeMargin, 0);
        assertEq(vault.totals().activeCommitment, fundedCallOpenCommitment);
        assertEq(_accruedTreasuryMargin(), 50e18);
    }

    function testPairedShareGuardDoesNotCreditMarginWhenCommitmentShareFloorsToZero() public {
        _setupCapBoundSlash(100e18 + 1);
        vault.materializeAccount(alice);
        vault.materializeAccount(bob);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);

        ILCCVault.Account memory aliceAccount = vault.getAccount(alice);
        ILCCVault.Account memory bobAccount = vault.getAccount(bob);
        assertEq(aliceAccount.activeMargin, 0);
        assertEq(aliceAccount.activeCommitment, 0);
        assertEq(bobAccount.activeMargin, 0);
        assertEq(bobAccount.activeCommitment, 0);
        assertEq(vault.totals().activeMargin, 50e18);
        assertEq(vault.totals().activeCommitment, 100e18);
        _assertAccountTotalsWithinDust(0);
    }

    function testLowPriceReturnCommitmentBelowThresholdSweepsSurplus() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        oracle.setPrice(4_999e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), 100e18);
        assertEq(vault.totals().activeMargin, 0);
        assertEq(vault.totals().activeCommitment, 0);
    }

    function testReturnCommitmentAboveThresholdCreditsPairedShares() public {
        _deposit(alice, 99e18);
        _deposit(bob, 1e18);
        oracle.setPrice(5_556e18);
        _openCall(200e18);
        oracle.setPrice(4_999e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 1_111_200);

        vault.materializeAccount(alice);
        vault.materializeAccount(bob);

        ILCCVault.Account memory aliceAccount = vault.getAccount(alice);
        ILCCVault.Account memory bobAccount = vault.getAccount(bob);
        assertGt(aliceAccount.activeMargin, 0);
        assertGt(aliceAccount.activeCommitment, 0);
        assertGt(bobAccount.activeMargin, 0);
        assertGt(bobAccount.activeCommitment, 0);
        assertEq(aliceAccount.activeMargin + bobAccount.activeMargin, 100e18);
        assertLe(vault.totals().activeCommitment - aliceAccount.activeCommitment - bobAccount.activeCommitment, 1);
    }

    function testPostCallOraclePriceAloneCannotFlipDustBoundarySweep() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        oracle.setPrice(4_999e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        uint256 snapshot = vm.snapshotState();

        oracle.setPrice(5_556e18);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);
        _assertSweptReturnPool();

        assertTrue(vm.revertToState(snapshot), "first oracle branch restore failed");
        oracle.setPrice(ORACLE_PRICE_SCALE);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);
        _assertSweptReturnPool();

        assertTrue(vm.revertToStateAndDelete(snapshot), "second oracle branch restore failed");
    }

    function testGoingConcernDisposalIgnoresZeroRevertingAndGasGriefingOracleAfterCallOpen() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        oracle.setPrice(ORACLE_PRICE_SCALE);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        uint256 snapshot = vm.snapshotState();

        oracle.setPrice(0);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);
        _assertFullSnapshotReturnPool();

        assertTrue(vm.revertToState(snapshot), "zero-price branch restore failed");
        LCCRevertingOracle revertingOracle = new LCCRevertingOracle();
        vm.etch(address(oracle), address(revertingOracle).code);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);
        _assertFullSnapshotReturnPool();

        assertTrue(vm.revertToState(snapshot), "reverting branch restore failed");
        LCCGasGriefingOracle gasGriefingOracle = new LCCGasGriefingOracle();
        vm.etch(address(oracle), address(gasGriefingOracle).code);
        vm.warp(START + EPOCH);
        vault.materializeAccount{gas: 3_000_000}(alice);
        _assertFullSnapshotReturnPool();

        assertTrue(vm.revertToStateAndDelete(snapshot), "gas-griefing branch restore failed");
    }

    function testNoAuctionDisposalUsesCallOpenSnapshot() public {
        _deposit(alice, 100e18);
        oracle.setPrice(ORACLE_PRICE_SCALE);
        _openCall(100e18);
        oracle.setPrice(4_999e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        _assertFullSnapshotReturnPool();
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testWindDownRetainsComputableValuationAboveOldRawProductThreshold() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.maxEpochs = 1;
        _deployVaultWithParams(params);

        _deposit(alice, 100e18);
        uint256 price = type(uint256).max / 100e18 + 1;
        assertGt(price, type(uint256).max / 100e18);
        (uint256 valueProductHigh,) = Math.mul512(100e18, price);
        assertLt(valueProductHigh, ORACLE_PRICE_SCALE);
        uint256 marginValue = Math.mulDiv(100e18, price, ORACLE_PRICE_SCALE);
        (uint256 commitmentProductHigh,) = Math.mul512(marginValue, 10_000);
        assertLt(commitmentProductHigh, 5_000);

        oracle.setPrice(price);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        _assertFullSnapshotReturnPool();
    }

    function testWindDownSweepsWhenSecondValuationStageGenuinelyOverflows() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.maxEpochs = 1;
        params.marginRatioBps = 1;
        _deployVaultWithParams(params);

        uint256 marginAssets = 2 * ORACLE_PRICE_SCALE;
        _mintAndApprove(alice, marginAssets, 0);
        oracle.setPrice(100);
        assertEq(_deposit(alice, marginAssets), 2_000_000);

        uint256 price = type(uint256).max / 4;
        (uint256 valueProductHigh,) = Math.mul512(marginAssets, price);
        assertLt(valueProductHigh, ORACLE_PRICE_SCALE);
        uint256 marginValue = Math.mulDiv(marginAssets, price, ORACLE_PRICE_SCALE);
        (uint256 commitmentProductHigh,) = Math.mul512(marginValue, 10_000);
        assertGe(commitmentProductHigh, params.marginRatioBps);

        oracle.setPrice(price);
        _openCall(1_000_000);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), marginAssets);
    }

    function testMissingSnapshotFallbackIsOwnerGatedAndOwnerRecoversGoingConcern() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        vm.store(address(vault), _mappingSlot(0, MARGIN_PRICE_AT_CALL_OPEN_SLOT), bytes32(0));

        vm.warp(START + EPOCH);
        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vault.materializeAccount(alice);

        vm.prank(owner);
        vault.finalizeEpochSlash(0);

        _assertFullSnapshotReturnPool();
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
    }

    function testMissingSnapshotWindDownDoesNotConsultOracleForNonOwner() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.maxEpochs = 1;
        _deployVaultWithParams(params);

        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        vm.store(address(vault), _mappingSlot(0, MARGIN_PRICE_AT_CALL_OPEN_SLOT), bytes32(0));
        LCCRevertingOracle revertingOracle = new LCCRevertingOracle();
        vm.etch(address(oracle), address(revertingOracle).code);

        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        _assertSweptReturnPool();
    }

    function testNoAuctionDisposalCountsNextEpochExitAsHeadroom() public {
        uint256 maturity = _setupNextEpochExitHeadroom();
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(state.returnPool, 50e18);
        assertEq(state.returnCommitment, 100e18);
        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), 100e18);
    }

    function testLateNoAuctionFinalizationAtCurrentPlusThreePreservesReturnPool() public {
        _setupNextEpochExitHeadroom();
        vm.warp(START + 3 * EPOCH + NORMAL + PRE_CALL);
        assertEq(vault.currentEpoch(), 3);

        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(state.returnPool, 50e18);
        assertEq(state.returnCommitment, 100e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testCapBelowGrandfatheredUtilizationDoesNotAddDueCommitmentAsHeadroom() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 200e18;
        _deployVaultWithParams(params);

        _deposit(carol, 5e18);
        _deposit(bob, 45e18);
        _deposit(alice, 50e18);
        vm.prank(carol);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        _openCall(100e18);
        _fund(carol);
        _fundRolling(bob);

        vm.prank(owner);
        vault.setRiskCaps(80e18, 200e18, 2_000, 0);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.totals().activeCommitment, 95e18);

        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), 50e18);
        assertEq(vault.totals().activeCommitment, 90e18);
        assertGt(vault.totals().activeCommitment, vault.riskConfig().protocolCommitmentCap);
    }

    function testSlashedCommitmentBoundRemainsBelowPackedTotalsHeadroom() public {
        uint256 maxPacked = type(uint128).max;
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = maxPacked;
        params.userCommitmentCap = maxPacked;
        _deployVaultWithParams(params);

        uint256 bobCommitment = maxPacked - 40e18 - 1;
        uint256 bobMargin = bobCommitment / 2;
        _mintAndApprove(bob, bobMargin, bobCommitment);
        _deposit(bob, bobMargin);
        _deposit(carol, 10e18);
        _deposit(alice, 10e18);
        vm.prank(carol);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        _openCall((maxPacked - 1) / 2);
        _fundRolling(bob);
        _fund(carol);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        uint256 usedBeforeDisposal = vault.totals().activeCommitment;
        uint256 packingHeadroom = maxPacked - usedBeforeDisposal;
        assertEq(packingHeadroom, 30e18 + 1);
        oracle.setPrice(4 * ORACLE_PRICE_SCALE);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        uint256 slashedCommitment =
            state.commitmentDenominator - state.fundedAmount - state.fundedUsersRemainingCommitment;
        assertEq(slashedCommitment, 20e18);
        assertLt(slashedCommitment, packingHeadroom);
        assertEq(state.returnCommitment, slashedCommitment);
        assertLe(vault.totals().activeCommitment, maxPacked);
        assertEq(state.returnPool, 10e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testThirdPartyDepositDuringOpenedCallCannotReduceDefaultRecovery() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 300e18;
        params.userCommitmentCap = 300e18;
        _deployVaultWithParams(params);

        _deposit(alice, 50e18);
        _deposit(carol, 50e18);
        _openCall(200e18);
        _fund(carol);

        uint256 snapshot = vm.snapshotState();

        vm.prank(owner);
        vault.setRiskCaps(200e18, 300e18, 2_000, 0);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        uint256 recoveryWithoutDeposit = vault.getAccount(alice).activeMargin;
        uint256 poolWithoutDeposit = state.returnPool;
        uint256 commitmentWithoutDeposit = state.returnCommitment;
        uint256 treasuryWithoutDeposit = _accruedTreasuryMargin();

        assertEq(poolWithoutDeposit, 50e18);
        assertEq(commitmentWithoutDeposit, 100e18);
        assertEq(recoveryWithoutDeposit, 50e18);
        assertEq(treasuryWithoutDeposit, 0);

        assertTrue(vm.revertToState(snapshot), "baseline snapshot restore failed");

        _deposit(bob, 100e18);
        assertEq(vault.getAccount(bob).pendingCommitment, 200e18);
        vm.prank(owner);
        vault.setRiskCaps(200e18, 300e18, 2_000, 0);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        state = vault.getEpochState(0);
        assertEq(state.commitmentDenominator, 200e18);
        assertEq(state.fundedAmount + state.fundedUsersRemainingCommitment, 100e18);
        assertEq(state.returnPool, poolWithoutDeposit);
        assertEq(state.returnCommitment, commitmentWithoutDeposit);
        assertEq(vault.getAccount(alice).activeMargin, recoveryWithoutDeposit);
        assertEq(state.returnPool, 50e18);
        assertEq(state.returnCommitment, 100e18);
        assertEq(_accruedTreasuryMargin(), treasuryWithoutDeposit);
    }

    function _setupNextEpochExitHeadroom() internal returns (uint256 maturity) {
        _deployVaultWithParams(_params(300e18, 300e18));

        _deposit(carol, 100e18);
        _deposit(alice, 50e18);
        vm.prank(carol);
        maturity = vault.requestExit(type(uint256).max, type(uint256).max);
        assertEq(maturity, 1);

        _openCall(150e18);
        _fund(carol);
        oracle.setPrice(2 * ORACLE_PRICE_SCALE);
    }

    function _setupSingleDefaulterCapBoundSlash(uint256 cap) internal {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 200e18;
        _deployVaultWithParams(params);

        _deposit(alice, 50e18);
        _deposit(carol, 50e18);
        _openCall(200e18);
        _fundRolling(carol);

        vm.prank(owner);
        vault.setRiskCaps(cap, 200e18, 2_000, 0);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + EPOCH);
    }

    /// @dev The owner lowers the cap to already-active rolling utilization before settlement, independently
    /// exercising the commitment-side clamp without relying on a deposit during the live auction.
    function _setupCapBoundSlash(uint256 cap) internal {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 200e18;
        _deployVaultWithParams(params);

        _deposit(alice, 49e18);
        _deposit(bob, 1e18);
        _deposit(carol, 50e18);
        _openCall(200e18);
        _fundRolling(carol);

        vm.prank(owner);
        vault.setRiskCaps(cap, 200e18, 2_000, 0);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + EPOCH);
    }

    function _assertAccountTotalsWithinDust(uint256 dustBound) internal view {
        ILCCVault.Totals memory totals = vault.totals();
        address[3] memory users = [alice, bob, carol];
        uint256 activeMargin;
        uint256 activeCommitment;
        for (uint256 i = 0; i < users.length; ++i) {
            ILCCVault.Account memory account = vault.getAccount(users[i]);
            activeMargin += account.activeMargin;
            activeCommitment += account.activeCommitment;
        }
        assertLe(activeMargin, totals.activeMargin);
        assertLe(uint256(totals.activeMargin) - activeMargin, dustBound);
        assertLe(activeCommitment, totals.activeCommitment);
        assertLe(uint256(totals.activeCommitment) - activeCommitment, dustBound);
    }

    function _assertFullSnapshotReturnPool() internal view {
        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 200e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function _assertSweptReturnPool() internal view {
        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(_accruedTreasuryMargin(), 100e18);
    }
}
