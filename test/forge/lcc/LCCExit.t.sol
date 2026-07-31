// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {BPS} from "../../../src/libraries/ConstantsLib.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";

contract LCCExitTest is LCCBase {
    uint256 internal constant MAX_EXIT_MATURITY_BUCKETS = 128;
    uint256 internal constant MAX_EXIT_DELAY_EPOCHS = 64;
    // Smallest exitCapBps accepted by the floor: exitCapBps * MAX_EXIT_DELAY_EPOCHS >= 2 * BPS.
    uint256 internal constant FLOOR_EXIT_CAP_BPS = 313;
    uint256 internal constant LADDER_INITIAL_CAP = 32e18;
    uint256 internal constant EXIT_MATURITY_LIST_SLOT = 22;
    // Gas assertions target the mainnet block gas limit, not this environment's block.gaslimit.
    uint256 internal constant BLOCK_GAS_LIMIT = 30_000_000;
    uint256 internal constant GAS_HEADROOM = 5_000_000;

    function testExitMaturesAndClaimsFullMargin() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        uint256 maturity = vault.requestExit(type(uint256).max, type(uint256).max);
        assertEq(maturity, 1);

        vm.warp(START + EPOCH);
        assertEq(vault.claimableExitedMargin(alice), 100e18);

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimExitedMargin(alice);

        assertEq(claimed, 100e18);
        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
        assertEq(vault.totals().activeMargin, 0);
    }

    function testFullyFundedExiterClearsExitWithZeroClaimable() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        uint256 maturity = vault.requestExit(type(uint256).max, type(uint256).max);
        assertEq(maturity, 1);

        // Call consumes the exiter's entire commitment; funding releases all margin, leaving nothing to claim.
        _openCall(200e18);
        uint256 obligation = _fund(alice);
        assertEq(obligation, 200e18);

        vm.warp(START + EPOCH);
        assertEq(vault.claimableExitedMargin(alice), 0);

        // The exit still clears, so the account is reusable rather than bricked in exitRequested.
        vm.prank(alice);
        uint256 claimed = vault.claimExitedMargin(alice);
        assertEq(claimed, 0);

        ILCCVault.Account memory account = vault.getAccount(alice);
        assertFalse(account.exitRequested);

        _deposit(alice, 100e18);
        assertEq(vault.getAccount(alice).activeMargin, 100e18);
    }

    function testExitBlocksNewDepositsAndRemainsCallableUntilMaturity() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.expectRevert(LCCErrorsLib.ExitInProgress.selector);
        _deposit(alice, 1e18);

        _openCall(100e18);
        assertEq(vault.obligationOf(0, alice), 100e18);
    }

    function testFifoExitAssignmentAndOversizedExit() public {
        vault = _newVault(_params(address(oracle), 1_000e18, 2_000e18, 1_000));
        vm.startPrank(alice);
        margin.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        margin.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        _deposit(alice, 400e18);
        _deposit(bob, 60e18);

        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        vm.prank(bob);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 2);
    }

    function testZeroDeferralAcceptsEarliestMaturityWithRoom() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        assertEq(vault.requestExit(0, type(uint256).max), 1);
    }

    function testZeroDeferralRejectsDisplacementFromEarliestMaturity() public {
        ILCCVault.VaultParams memory params = _params(address(oracle), 100e18, 100e18, 2_000);
        params.marginRatioBps = BPS;
        _deployVaultWithParams(params);

        assertEq(_deposit(alice, 20e18), 20e18);
        assertEq(_deposit(bob, 1e18), 1e18);

        vm.prank(alice);
        assertEq(vault.requestExit(0, type(uint256).max), 1);

        vm.expectRevert(LCCErrorsLib.ExitDeferralExceeded.selector);
        vm.prank(bob);
        vault.requestExit(0, type(uint256).max);
    }

    function testPositiveDeferralAcceptsAtBoundAndRejectsOnePastIt() public {
        ILCCVault.VaultParams memory params = _params(address(oracle), 100e18, 100e18, 2_000);
        params.marginRatioBps = BPS;
        _deployVaultWithParams(params);

        assertEq(_deposit(alice, 20e18), 20e18);
        assertEq(_deposit(bob, 20e18), 20e18);
        assertEq(_deposit(carol, 1e18), 1e18);

        vm.prank(alice);
        assertEq(vault.requestExit(0, type(uint256).max), 1);

        vm.prank(bob);
        assertEq(vault.requestExit(1, type(uint256).max), 2);

        vm.expectRevert(LCCErrorsLib.ExitDeferralExceeded.selector);
        vm.prank(carol);
        vault.requestExit(1, type(uint256).max);
    }

    function testOversizedCommitmentWithZeroDeferralUsesEscapeClause() public {
        ILCCVault.VaultParams memory params = _params(address(oracle), 100e18, 100e18, 2_000);
        params.marginRatioBps = BPS;
        _deployVaultWithParams(params);

        assertEq(_deposit(alice, 21e18), 21e18);

        vm.prank(alice);
        assertEq(vault.requestExit(0, type(uint256).max), 1);
    }

    function testExitWallClockDeadlineRejectsExpiredAndAcceptsInclusiveDeadline() public {
        vm.expectRevert(LCCErrorsLib.DeadlineExpired.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, block.timestamp - 1);

        _deposit(alice, 100e18);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, block.timestamp), 1);
    }

    function testExitDeadlineUsesWallClockAfterPause() public {
        _deposit(alice, 100e18);

        vm.prank(owner);
        vault.pause();
        vm.warp(block.timestamp + 100);
        vm.prank(owner);
        vault.unpause();

        uint256 effectiveNow = _effectiveTime(vault);
        uint256 deadline = effectiveNow + 50;
        assertGt(deadline, effectiveNow);
        assertLt(deadline, block.timestamp);

        vm.expectRevert(LCCErrorsLib.DeadlineExpired.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, deadline);
    }

    function testCannotClaimBeforeMaturity() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.expectRevert(LCCErrorsLib.ExitNotMature.selector);
        vm.prank(alice);
        vault.claimExitedMargin(alice);
    }

    function testCannotRequestExitWithPendingOnlyDeposit() public {
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.PendingDepositExists.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);
    }

    function testCannotRequestExitWithActiveAndPendingDeposit() public {
        _deposit(alice, 100e18);

        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 50e18);

        vm.expectRevert(LCCErrorsLib.PendingDepositExists.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);
    }

    function testCanRequestExitAfterPendingDepositActivates() public {
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 2);
    }

    function testExitingFunderReducesMaturityBucketAndClaimsRemainder() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        _openCall(100e18);
        _fund(alice);

        assertEq(vault.exitBucketMarginByMaturity(1), 50e18);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 100e18);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimExitedMargin(alice), 50e18);
        assertEq(vault.totals().activeMargin, 0);
    }

    function testPrunedMaturityBucketCanBeReusedInSameEpoch() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);

        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        _openCall(400e18);
        _fund(alice);

        assertEq(vault.exitBucketMarginByMaturity(1), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 0);

        vm.prank(bob);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        assertEq(vault.exitBucketMarginByMaturity(1), 100e18);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 200e18);
    }

    function testExitRequestedAfterCallOpenRemainsLiableForOpenCall() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        vm.warp(START + EPOCH);
        vm.expectEmit(true, true, false, true, address(vault));
        emit LCCEventsLib.UserDefaulted(alice, 0, 100e18, 200e18);
        _syncAs(alice);

        assertEq(_accruedTreasuryMargin(), 0);
        assertEq(vault.claimableExitedMargin(alice), 0);
    }

    function testMaxExitDelayHonestOneExitPerEpochDoesNotHitCapacity() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.exitDelayEpochs = MAX_EXIT_DELAY_EPOCHS;
        _deployVaultWithParams(params);

        for (uint256 epoch = 0; epoch < MAX_EXIT_DELAY_EPOCHS * 3; ++epoch) {
            address user = _actor(epoch);
            vm.warp(START + EPOCH * epoch);
            _mintAndApprove(user, 1e18, 0);
            _deposit(user, 1e18);

            vm.prank(user);
            assertEq(vault.requestExit(type(uint256).max, type(uint256).max), epoch + MAX_EXIT_DELAY_EPOCHS);
        }
    }

    function testOverflowFillToCapRejectsNextNewExitBucket() public {
        _deployOverflowBucketVault();
        uint256 activeCommitment = _buildExitBucketLadder();
        _assertExitBucketCount(MAX_EXIT_MATURITY_BUCKETS);

        (address overflow,) = _depositNextExactFitLadderAccount(MAX_EXIT_MATURITY_BUCKETS, activeCommitment);

        // The unbounded assignment would open a 129th bucket, but the caller's narrower consent takes precedence.
        vm.expectRevert(LCCErrorsLib.ExitDeferralExceeded.selector);
        vm.prank(overflow);
        vault.requestExit(MAX_EXIT_MATURITY_BUCKETS - 1, type(uint256).max);

        vm.expectRevert(LCCErrorsLib.ExitCapacityReached.selector);
        vm.prank(overflow);
        vault.requestExit(type(uint256).max, type(uint256).max);
    }

    function testExitIntoExistingBucketSucceedsAtCap() public {
        _deployOverflowBucketVault();
        uint256 activeCommitment = _buildExitBucketLadder();
        _assertExitBucketCount(MAX_EXIT_MATURITY_BUCKETS);

        // Restore deposit headroom with the smallest possible cap raise. The live capacity is now much larger than
        // the first ladder rung, so this one-unit joiner fits the earliest existing bucket while the list stays full.
        vm.prank(owner);
        vault.setRiskCaps(activeCommitment + 1, CAP, FLOOR_EXIT_CAP_BPS, 0);
        address joiner = _actor(MAX_EXIT_MATURITY_BUCKETS);
        _mintAndApprove(joiner, 1, 0);
        assertEq(_deposit(joiner, 1), 1);

        vm.prank(joiner);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), MAX_EXIT_DELAY_EPOCHS);
        assertTrue(vault.getAccount(joiner).exitRequested);
    }

    function testMaxExitBucketOpenCallGasStaysBelowBlockLimit() public {
        _deployOverflowBucketVault();
        uint256 totalCommitment = _buildExitBucketLadder();

        address defaulter = _actor(MAX_EXIT_MATURITY_BUCKETS);
        uint256 defaulterCommitment = LADDER_INITIAL_CAP;
        vm.prank(owner);
        vault.setRiskCaps(totalCommitment + defaulterCommitment, CAP, FLOOR_EXIT_CAP_BPS, 0);
        _mintAndApprove(defaulter, defaulterCommitment, 0);
        totalCommitment += _deposit(defaulter, defaulterCommitment);

        vm.warp(START + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(0, totalCommitment / 2);

        vm.warp(START + NORMAL + PRE_CALL);
        for (uint256 i = 0; i < MAX_EXIT_MATURITY_BUCKETS; ++i) {
            vm.prank(_actor(i));
            vault.fundCall(false);
        }

        vm.warp(START + EPOCH + NORMAL);
        _assertExitBucketCount(MAX_EXIT_MATURITY_BUCKETS);
        uint256 gasBefore = gasleft();
        vm.prank(owner);
        vault.openEpochCall(1, 1);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("max bucket openEpochCall gas", gasUsed);
        assertLt(gasUsed, BLOCK_GAS_LIMIT);
        assertGt(BLOCK_GAS_LIMIT - gasUsed, GAS_HEADROOM);
    }

    function testMaxExitBucketShutdownGasStaysBelowBlockLimit() public {
        _deployOverflowBucketVault();
        _buildExitBucketLadder();
        _assertExitBucketCount(MAX_EXIT_MATURITY_BUCKETS);

        uint256 gasBefore = gasleft();
        vm.prank(owner);
        vault.shutdown();
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("max bucket shutdown gas", gasUsed);
        assertLt(gasUsed, BLOCK_GAS_LIMIT);
        assertGt(BLOCK_GAS_LIMIT - gasUsed, GAS_HEADROOM);
    }

    function testCapCutBelowLiveUtilizationPreservesDenseExitPacking() public {
        uint256 accountCount = 64;
        uint256 accountCommitment = 1e18;
        ILCCVault.VaultParams memory params = _params(accountCount * accountCommitment, CAP);
        params.marginRatioBps = BPS;
        params.exitCapBps = FLOOR_EXIT_CAP_BPS;
        _deployVaultWithParams(params);

        for (uint256 i = 0; i < accountCount; ++i) {
            address user = _actor(i);
            _mintAndApprove(user, accountCommitment, 0);
            assertEq(_deposit(user, accountCommitment), accountCommitment);
        }

        uint256 activeCommitment = vault.totals().activeCommitment;
        assertEq(activeCommitment, accountCount * accountCommitment);
        _lowerProtocolCapBelowLiveUtilization();

        uint256 configuredCapCapacity = vault.riskConfig().protocolCommitmentCap * FLOOR_EXIT_CAP_BPS / BPS;
        uint256 liveCapacity = activeCommitment * FLOOR_EXIT_CAP_BPS / BPS;
        assertGt(liveCapacity, configuredCapCapacity);

        for (uint256 i = 0; i < accountCount; ++i) {
            vm.prank(_actor(i));
            assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1 + i / 2);
        }

        uint256 firstBucketCommitment = vault.exitBucketCommitmentByMaturity(1);
        assertEq(firstBucketCommitment, 2 * accountCommitment);
        assertLe(firstBucketCommitment, liveCapacity);
        assertGt(firstBucketCommitment, configuredCapCapacity);
    }

    function testMinimumNonzeroConfiguredCapacityAssignsFirstBucket() public {
        ILCCVault.VaultParams memory params = _params(address(oracle), 32, 32, FLOOR_EXIT_CAP_BPS);
        params.marginRatioBps = BPS;
        _deployVaultWithParams(params);

        _mintAndApprove(alice, 1, 0);
        assertEq(_deposit(alice, 1), 1);

        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 1);
    }

    function testSupportedFloorZeroCapacityPairAssignsUnderRuntimeClamp() public {
        ILCCVault.VaultParams memory params = _params(address(oracle), 31, 31, FLOOR_EXIT_CAP_BPS);
        params.marginRatioBps = BPS;
        _deployVaultWithParams(params);

        _mintAndApprove(alice, 1, 0);
        assertEq(_deposit(alice, 1), 1);

        assertEq(vault.riskConfig().protocolCommitmentCap, 31);
        assertEq(vault.riskConfig().exitCapBps, FLOOR_EXIT_CAP_BPS);

        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 1);
    }

    function testMinimumCapacityScansPriorNonemptyBucketsAndTerminates() public {
        uint256 protocolCap = 31;
        uint256 accountCount = 8;
        uint256 initialExitCapBps = Math.ceilDiv(BPS, protocolCap);
        ILCCVault.VaultParams memory params = _params(address(oracle), protocolCap, protocolCap, initialExitCapBps);
        params.marginRatioBps = BPS;
        _deployVaultWithParams(params);

        for (uint256 i = 0; i < accountCount; ++i) {
            address user = _actor(i);
            _mintAndApprove(user, 1, 0);
            assertEq(_deposit(user, 1), 1);
        }

        assertEq(Math.mulDiv(protocolCap, initialExitCapBps, BPS), 1);
        for (uint256 i = 0; i < accountCount - 1; ++i) {
            address user = _actor(i);
            vm.prank(user);
            assertEq(vault.requestExit(type(uint256).max, type(uint256).max), i + 1);
            assertEq(vault.exitBucketCommitmentByMaturity(i + 1), 1);
        }
        _assertExitBucketCount(accountCount - 1);

        vm.prank(owner);
        vault.setRiskCaps(protocolCap, protocolCap, FLOOR_EXIT_CAP_BPS, 0);
        assertEq(Math.mulDiv(protocolCap, FLOOR_EXIT_CAP_BPS, BPS), 0);

        vm.prank(_actor(accountCount - 1));
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), accountCount);
        assertEq(vault.exitBucketCommitmentByMaturity(accountCount), 1);
        _assertExitBucketCount(accountCount);
    }

    /// @dev Characterizes ordering sensitivity: unrelated amortizing funding can reduce live capacity and move a
    /// later unbounded exit from maturity 1 to 2.
    function testCharacterizationAmortizationCanChangeSubsequentExitMaturity() public {
        ILCCVault.VaultParams memory params = _params(address(oracle), 100e18, 100e18, 5_000);
        params.marginRatioBps = BPS;
        _deployVaultWithParams(params);

        assertEq(_deposit(alice, 30e18), 30e18);
        assertEq(_deposit(bob, 15e18), 15e18);
        assertEq(_deposit(carol, 55e18), 55e18);

        vm.prank(owner);
        vault.setRiskCaps(10e18, 100e18, 5_000, 0);

        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        uint256 snapshot = vm.snapshotState();
        vm.prank(bob);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);
        assertTrue(vm.revertToStateAndDelete(snapshot), "snapshot restore failed");

        _openCall(20e18);
        assertEq(_fund(carol), 11e18);
        assertEq(vault.totals().activeCommitment, 89e18);

        vm.prank(bob);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 2);
    }

    /// @dev Pins accepted L-07 behavior: first-fit maturity is fixed, so reopened earlier capacity can let a later
    /// requester overtake an earlier requester whose still-outstanding exit remains assigned to a later epoch.
    function testCharacterizationLaterRequesterCanOvertakeFixedEarlierExit() public {
        ILCCVault.VaultParams memory params = _params(address(oracle), 100e18, 100e18, 5_000);
        params.marginRatioBps = BPS;
        _deployVaultWithParams(params);

        assertEq(_deposit(alice, 40e18), 40e18);
        assertEq(_deposit(bob, 20e18), 20e18);
        assertEq(_deposit(carol, 20e18), 20e18);

        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);
        vm.prank(bob);
        uint256 earlierRequesterMaturity = vault.requestExit(type(uint256).max, type(uint256).max);
        assertEq(earlierRequesterMaturity, 2);

        _openCall(40e18);
        assertEq(_fund(alice), 20e18);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 20e18);
        assertEq(vault.getAccount(bob).exitMaturityEpoch, earlierRequesterMaturity);

        vm.prank(carol);
        uint256 laterRequesterMaturity = vault.requestExit(type(uint256).max, type(uint256).max);
        assertEq(laterRequesterMaturity, 1);
        assertEq(vault.getAccount(bob).exitMaturityEpoch, 2);
        assertEq(vault.getAccount(carol).exitMaturityEpoch, 1);
        assertLt(laterRequesterMaturity, earlierRequesterMaturity);
    }

    function testBoundedExitRejectsAmortizationDrivenMaturityChange() public {
        ILCCVault.VaultParams memory params = _params(address(oracle), 100e18, 100e18, 5_000);
        params.marginRatioBps = BPS;
        _deployVaultWithParams(params);

        assertEq(_deposit(alice, 30e18), 30e18);
        assertEq(_deposit(bob, 15e18), 15e18);
        assertEq(_deposit(carol, 55e18), 55e18);

        vm.prank(owner);
        vault.setRiskCaps(10e18, 100e18, 5_000, 0);

        vm.prank(alice);
        assertEq(vault.requestExit(type(uint256).max, type(uint256).max), 1);

        uint256 snapshot = vm.snapshotState();
        vm.prank(bob);
        assertEq(vault.requestExit(0, type(uint256).max), 1);
        assertTrue(vm.revertToStateAndDelete(snapshot), "snapshot restore failed");

        _openCall(20e18);
        assertEq(_fund(carol), 11e18);
        assertEq(vault.totals().activeCommitment, 89e18);

        vm.expectRevert(LCCErrorsLib.ExitDeferralExceeded.selector);
        vm.prank(bob);
        vault.requestExit(0, type(uint256).max);
    }

    function _deployOverflowBucketVault() internal {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.marginRatioBps = BPS;
        params.exitCapBps = FLOOR_EXIT_CAP_BPS;
        params.exitDelayEpochs = MAX_EXIT_DELAY_EPOCHS;
        _deployVaultWithParams(params);
    }

    /// @dev Lowers the configured protocol cap below aggregate active utilization. Runtime exit capacity uses live
    /// utilization at each request, so it cannot fall below the configured-cap value but can decline with utilization.
    function _lowerProtocolCapBelowLiveUtilization() internal {
        vm.prank(owner);
        vault.setRiskCaps(32, CAP, FLOOR_EXIT_CAP_BPS, 0);
    }

    /// @dev Builds 128 genuinely live buckets through public calls. Each rung deposits exactly the current capacity:
    /// it cannot fit a prior nonempty bucket and is not oversized, so first-fit must open the next maturity.
    function _buildExitBucketLadder() internal returns (uint256 activeCommitment) {
        for (uint256 i = 0; i < MAX_EXIT_MATURITY_BUCKETS; ++i) {
            (address user, uint256 capacity) = _depositNextExactFitLadderAccount(i, activeCommitment);
            activeCommitment += capacity;
            vm.prank(user);
            assertEq(vault.requestExit(type(uint256).max, type(uint256).max), MAX_EXIT_DELAY_EPOCHS + i);
        }
        assertEq(vault.totals().activeCommitment, activeCommitment);
    }

    function _depositNextExactFitLadderAccount(uint256 index, uint256 activeBefore)
        internal
        returns (address user, uint256 capacity)
    {
        uint256 protocolCap = Math.max(LADDER_INITIAL_CAP, Math.ceilDiv(activeBefore * BPS, BPS - FLOOR_EXIT_CAP_BPS));
        capacity = Math.mulDiv(protocolCap, FLOOR_EXIT_CAP_BPS, BPS);
        assertGe(protocolCap, activeBefore + capacity);

        vm.prank(owner);
        vault.setRiskCaps(protocolCap, CAP, FLOOR_EXIT_CAP_BPS, 0);
        user = _actor(index);
        _mintAndApprove(user, capacity, capacity);
        assertEq(_deposit(user, capacity), capacity);
    }

    function _assertExitBucketCount(uint256 expected) internal view {
        _assertLayoutSlot("exitMaturityList", EXIT_MATURITY_LIST_SLOT);
        assertEq(uint256(vm.load(address(vault), bytes32(EXIT_MATURITY_LIST_SLOT))), expected);
    }

    function _actor(uint256 index) internal view returns (address) {
        return vm.addr(index + 10_000);
    }
}
