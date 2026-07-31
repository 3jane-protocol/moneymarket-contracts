// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase, LCCGasGriefingOracle, LCCRevertingOracle} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

contract LCCReturnPoolTest is LCCBase {
    uint256 internal constant RISK_CONFIG_SLOT = 4;

    function setUp() public override {
        super.setUp();
        _assertLayoutSlot("_riskConfig", RISK_CONFIG_SLOT);
        _assertLayoutSlot("marginPriceAtCallOpen", MARGIN_PRICE_AT_CALL_OPEN_SLOT);
        _assertLayoutSlot("userCommitmentCapAtCallOpen", USER_COMMITMENT_CAP_AT_CALL_OPEN_SLOT);
    }

    function testOpenCallRejectsZeroUserCapAtSnapshotWrite() public {
        _deposit(alice, 100e18);
        vm.store(address(vault), bytes32(RISK_CONFIG_SLOT + 1), bytes32(0));

        vm.warp(START + NORMAL);
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        vm.prank(owner);
        vault.openEpochCall(0, 100e18);

        assertFalse(vault.getEpochState(0).callOpened);
        assertEq(uint256(vm.load(address(vault), _mappingSlot(0, USER_COMMITMENT_CAP_AT_CALL_OPEN_SLOT))), 0);
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

    function testReturnCreditUsesPartialFrozenUserCapHeadroomAndMarginRemainsClaimable() public {
        _setupHeterogeneousReturnPool(150e18);
        oracle.setPrice(ORACLE_PRICE_SCALE / 2);
        assertEq(_deposit(alice, 70e18), 70e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.UserDefaulted(alice, 0, 50e18, 50e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.ReturnPoolCredited(alice, 0, 50e18, 80e18);
        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 50e18);
        assertEq(account.activeCommitment, 80e18);
        assertEq(account.pendingMargin, 70e18);
        assertEq(account.pendingCommitment, 70e18);
        assertEq(account.activeCommitment + account.pendingCommitment, 150e18);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 2);

        uint256 balanceBefore = margin.balanceOf(alice);
        vm.warp(START + 2 * EPOCH);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 120e18);
        assertEq(margin.balanceOf(alice) - balanceBefore, 120e18);
    }

    function testPendingCommitmentConsumesFrozenCapAndWithholdsOnlyCommitmentCredit() public {
        _setupHeterogeneousReturnPool(150e18);
        vm.prank(owner);
        vault.setRiskCaps(400e18, 250e18, 2_000, 0);
        oracle.setPrice(ORACLE_PRICE_SCALE / 2);
        assertEq(_deposit(alice, 150e18), 150e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.UserDefaulted(alice, 0, 50e18, 50e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.ReturnPoolCredited(alice, 0, 50e18, 0);
        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 50e18);
        assertEq(account.activeCommitment, 0);
        assertEq(account.pendingMargin, 150e18);
        assertEq(account.pendingCommitment, 150e18, "pending exposure consumes the frozen cap");
    }

    function testFrozenUserCapMakesReturnCreditIndependentOfReplayTiming() public {
        // This isolates the frozen-snapshot/live-config timing property; deleting the clamp leaves both branches
        // equal, so clamp removal is instead killed by the partial-headroom, pending-consumes-cap, and
        // two-consecutive-epochs tests.
        _setupHeterogeneousReturnPool(150e18);
        uint256 snapshot = vm.snapshotState();

        _finishFunding();
        vault.finalizeEpochSlash(0);
        vault.materializeAccount(alice);
        uint256 unchangedCapCredit = vault.getAccount(alice).activeCommitment;
        assertEq(unchangedCapCredit, 100e18);

        assertTrue(vm.revertToStateAndDelete(snapshot), "snapshot restore failed");

        vm.prank(owner);
        vault.setRiskCaps(400e18, 1, 2_000, 0);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.Account memory derived = vault.getAccount(alice);
        assertEq(derived.activeCommitment, unchangedCapCredit);
        vault.materializeAccount(alice);
        ILCCVault.Account memory materialized = vault.getAccount(alice);
        assertEq(keccak256(abi.encode(materialized)), keccak256(abi.encode(derived)));
    }

    function testReplayCompletesAfterTwoConsecutiveCappedDefaultEpochs() public {
        _deployVaultWithParams(_params(300e18, 300e18));
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.setRiskCaps(300e18, 100e18, 2_000, 0);

        _openCall(200e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        _openCallAtEpoch(1, 200e18);
        _finishFundingAtEpoch(1);
        vault.finalizeEpochSlash(1);

        vault.materializeAccount(alice);

        ILCCVault.Account memory account = vault.getAccount(alice);
        ILCCVault.Totals memory totals = vault.totals();
        assertEq(account.calledEpochCursor, 2);
        assertEq(account.calledEpochCursor, vault.syncState().finalizedCallPrefix);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCommitment, 100e18);
        assertEq(totals.activeMargin, 100e18);
        assertEq(totals.activeCommitment, 200e18);
        assertEq(margin.balanceOf(address(vault)), totals.activeMargin + vault.pendingTreasuryMargin());
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
        ILCCVault.Account memory account = vault.getAccount(alice);
        assertEq(account.calledEpochCursor, vault.syncState().finalizedCallPrefix);
        assertTrue(account.calledEpochCursor != 0, "zero-credit disposal was replayed");
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

    /// @dev Pins accepted L-06 behavior: conservative returned commitment can temporarily deny deposits above the
    /// protocol cap, and the next slash removes the unattributed overage through its commitment denominator.
    function testCharacterizationReturnedCommitmentCreatesBoundedDepositDenialWindow() public {
        ILCCVault.VaultParams memory params = _params(300e18, 100e18);
        _deployVaultWithParams(params);

        _deposit(alice, 50e18);
        _deposit(carol, 50e18);
        _openCall(200e18);
        assertEq(_fund(carol), 100e18);

        vm.prank(owner);
        vault.setRiskCaps(300e18, 300e18, 2_000, 0);
        assertEq(_deposit(alice, 100e18), 200e18);
        vm.prank(owner);
        vault.setRiskCaps(200e18, 300e18, 2_000, 0);

        _finishFunding();
        vault.finalizeEpochSlash(0);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory firstState = vault.getEpochState(0);
        ILCCVault.Totals memory totals = vault.totals();
        assertEq(firstState.returnCommitment, 100e18);
        assertEq(totals.activeCommitment, 100e18);
        assertEq(totals.pendingCommitment, 200e18);
        assertEq(totals.activeCommitment + totals.pendingCommitment, 300e18);
        assertGt(totals.activeCommitment + totals.pendingCommitment, vault.riskConfig().protocolCommitmentCap);

        vm.expectRevert(LCCErrorsLib.CapExceeded.selector);
        _deposit(bob, 1e18);

        _openCallAtEpoch(1, 150e18);
        assertEq(_fundAtEpoch(alice, 1), 100e18);
        _finishFundingAtEpoch(1);
        vault.finalizeEpochSlash(1);

        ILCCVault.EpochState memory secondState = vault.getEpochState(1);
        uint256 secondSlashedCommitment =
            secondState.commitmentDenominator - secondState.fundedAmount - secondState.fundedUsersRemainingCommitment;
        totals = vault.totals();
        assertEq(secondState.commitmentDenominator, 300e18);
        assertEq(secondState.slashedMargin, 0);
        assertEq(secondSlashedCommitment, 100e18);
        assertEq(totals.activeCommitment, 100e18);
        assertEq(totals.pendingCommitment, 0);
        assertLt(totals.activeCommitment, vault.riskConfig().protocolCommitmentCap);

        assertEq(_deposit(bob, 1e18), 2e18);
        assertEq(vault.getAccount(bob).pendingCommitment, 2e18);
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

    function _setupHeterogeneousReturnPool(uint256 userCap) internal {
        _deployVaultWithParams(_params(400e18, userCap));

        oracle.setPrice(ORACLE_PRICE_SCALE / 2);
        assertEq(_deposit(alice, 50e18), 50e18);
        oracle.setPrice(3 * ORACLE_PRICE_SCALE / 2);
        assertEq(_deposit(bob, 50e18), 150e18);
        oracle.setPrice(ORACLE_PRICE_SCALE);
        _openCall(200e18);
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
