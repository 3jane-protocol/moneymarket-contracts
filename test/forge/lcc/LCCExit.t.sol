// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";

contract LCCExitTest is LCCBase {
    uint256 internal constant MAX_EXIT_MATURITY_BUCKETS = 128;
    uint256 internal constant MAX_EXIT_DELAY_EPOCHS = 64;
    // Smallest exitCapBps accepted by the floor: exitCapBps * MAX_EXIT_DELAY_EPOCHS >= 2 * BPS.
    uint256 internal constant FLOOR_EXIT_CAP_BPS = 313;
    uint256 internal constant OVERFLOW_EXIT_MARGIN = 600e18;
    // Gas assertions target the mainnet block gas limit, not this environment's block.gaslimit.
    uint256 internal constant BLOCK_GAS_LIMIT = 30_000_000;
    uint256 internal constant GAS_HEADROOM = 5_000_000;

    function testExitMaturesAndClaimsFullMargin() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        uint256 maturity = vault.requestExit();
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
        uint256 maturity = vault.requestExit();
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
        vault.requestExit();

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
        assertEq(vault.requestExit(), 1);

        vm.prank(bob);
        assertEq(vault.requestExit(), 2);
    }

    function testCannotClaimBeforeMaturity() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        vm.expectRevert(LCCErrorsLib.ExitNotMature.selector);
        vm.prank(alice);
        vault.claimExitedMargin(alice);
    }

    function testCannotRequestExitWithPendingOnlyDeposit() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.PendingDepositExists.selector);
        vm.prank(alice);
        vault.requestExit();
    }

    function testCannotRequestExitWithActiveAndPendingDeposit() public {
        _deposit(alice, 100e18);

        vm.warp(START + NORMAL);
        _deposit(alice, 50e18);

        vm.expectRevert(LCCErrorsLib.PendingDepositExists.selector);
        vm.prank(alice);
        vault.requestExit();
    }

    function testCanRequestExitAfterPendingDepositActivates() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(), 2);
    }

    function testExitingFunderReducesMaturityBucketAndClaimsRemainder() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

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
        assertEq(vault.requestExit(), 1);

        _openCall(400e18);
        _fund(alice);

        assertEq(vault.exitBucketMarginByMaturity(1), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 0);

        vm.prank(bob);
        assertEq(vault.requestExit(), 1);

        assertEq(vault.exitBucketMarginByMaturity(1), 100e18);
        assertEq(vault.exitBucketCommitmentByMaturity(1), 200e18);
    }

    function testExitRequestedAfterCallOpenRemainsLiableForOpenCall() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.prank(alice);
        assertEq(vault.requestExit(), 1);

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
            assertEq(vault.requestExit(), epoch + MAX_EXIT_DELAY_EPOCHS);
        }
    }

    function testOverflowFillToCapRejectsNextNewExitBucket() public {
        _deployOverflowBucketVault();

        address overflow = _actor(MAX_EXIT_MATURITY_BUCKETS + 1);
        _mintAndApprove(overflow, OVERFLOW_EXIT_MARGIN, 0);
        _deposit(overflow, OVERFLOW_EXIT_MARGIN);

        _fillExitBucketsToCap();

        vm.expectRevert(LCCErrorsLib.ExitCapacityReached.selector);
        vm.prank(overflow);
        vault.requestExit();
    }

    function testExitIntoExistingBucketSucceedsAtCap() public {
        _deployOverflowBucketVault();

        address joiner = _actor(MAX_EXIT_MATURITY_BUCKETS + 2);
        _mintAndApprove(joiner, OVERFLOW_EXIT_MARGIN, 0);
        _deposit(joiner, OVERFLOW_EXIT_MARGIN);

        _fillExitBucketsToCap();

        // Restore per-bucket capacity so the first tracked maturity has room again; with the list still at cap, an
        // exit assigned to an existing maturity must not revert ExitCapacityReached.
        vm.prank(owner);
        vault.setRiskCaps(CAP, CAP, FLOOR_EXIT_CAP_BPS, 0);

        vm.prank(joiner);
        assertEq(vault.requestExit(), MAX_EXIT_DELAY_EPOCHS);
        assertTrue(vault.getAccount(joiner).exitRequested);
    }

    function testMaxExitBucketOpenCallGasStaysBelowBlockLimit() public {
        _deployOverflowBucketVault();
        uint256 totalCommitment = _depositGasRegressionAccounts();

        vm.warp(START + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(0, totalCommitment / 2);

        _shrinkExitBucketCapacity();

        for (uint256 i = 0; i < MAX_EXIT_MATURITY_BUCKETS; ++i) {
            address user = _actor(i);
            vm.prank(user);
            vault.requestExit();
        }

        vm.warp(START + NORMAL + PRE_CALL);
        for (uint256 i = 0; i < MAX_EXIT_MATURITY_BUCKETS; ++i) {
            vm.prank(_actor(i));
            vault.fundCall(false);
        }

        vm.warp(START + EPOCH + NORMAL);
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
        _fillExitBucketsToCap();

        uint256 gasBefore = gasleft();
        vm.prank(owner);
        vault.shutdown();
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("max bucket shutdown gas", gasUsed);
        assertLt(gasUsed, BLOCK_GAS_LIMIT);
        assertGt(BLOCK_GAS_LIMIT - gasUsed, GAS_HEADROOM);
    }

    function _deployOverflowBucketVault() internal {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.exitCapBps = FLOOR_EXIT_CAP_BPS;
        params.exitDelayEpochs = MAX_EXIT_DELAY_EPOCHS;
        _deployVaultWithParams(params);
    }

    /// @dev Shrinks per-bucket exit capacity below a single account's commitment by lowering the protocol cap, so
    /// each subsequent exit spills into its own maturity bucket (the owner-driven path to the bucket cap; a static
    /// floor-valid config cannot reach it with honest demand).
    function _shrinkExitBucketCapacity() internal {
        vm.prank(owner);
        vault.setRiskCaps(1e18, CAP, FLOOR_EXIT_CAP_BPS, 0);
    }

    function _fillExitBucketsToCap() internal {
        for (uint256 i = 0; i < MAX_EXIT_MATURITY_BUCKETS; ++i) {
            address user = _actor(i);
            _mintAndApprove(user, OVERFLOW_EXIT_MARGIN, 0);
            _deposit(user, OVERFLOW_EXIT_MARGIN);
        }

        _shrinkExitBucketCapacity();

        for (uint256 i = 0; i < MAX_EXIT_MATURITY_BUCKETS; ++i) {
            address user = _actor(i);
            vm.prank(user);
            assertEq(vault.requestExit(), MAX_EXIT_DELAY_EPOCHS + i);
        }
    }

    function _depositGasRegressionAccounts() internal returns (uint256 totalCommitment) {
        for (uint256 i = 0; i < MAX_EXIT_MATURITY_BUCKETS; ++i) {
            address user = _actor(i);
            _mintAndApprove(user, OVERFLOW_EXIT_MARGIN, OVERFLOW_EXIT_MARGIN * 2);
            totalCommitment += _deposit(user, OVERFLOW_EXIT_MARGIN);
        }

        address defaulter = _actor(MAX_EXIT_MATURITY_BUCKETS);
        _mintAndApprove(defaulter, OVERFLOW_EXIT_MARGIN, 0);
        totalCommitment += _deposit(defaulter, OVERFLOW_EXIT_MARGIN);
    }

    function _actor(uint256 index) internal view returns (address) {
        return vm.addr(index + 10_000);
    }
}
