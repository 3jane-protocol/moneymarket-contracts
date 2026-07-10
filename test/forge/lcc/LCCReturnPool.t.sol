// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";

contract LCCReturnPoolTest is LCCBase {
    function testPendingDisposalRevertsOnZeroOracleAndRetriesAfterRecovery() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);

        vm.warp(START + EPOCH);
        oracle.setPrice(0);

        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vault.materializeAccount(alice);

        oracle.setPrice(ORACLE_PRICE_SCALE);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(margin.balanceOf(treasury), 0);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 200e18);
    }

    function testHeadroomZeroSendsWholeSurplusToTreasury() public {
        _setupCapBoundSlash(200e18);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(margin.balanceOf(treasury), 100e18);
        assertEq(vault.totals().activeMargin, 100e18);
        assertEq(vault.totals().activeCommitment, 200e18);
        assertEq(vault.totals().pendingMargin, 0);
    }

    function testPairedShareGuardDoesNotCreditMarginWhenCommitmentShareFloorsToZero() public {
        _setupCapBoundSlash(200e18 + 1);
        vault.materializeAccount(alice);
        vault.materializeAccount(bob);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(margin.balanceOf(treasury), 100e18);

        ILCCVault.Account memory aliceAccount = vault.getAccount(alice);
        ILCCVault.Account memory bobAccount = vault.getAccount(bob);
        assertEq(aliceAccount.activeMargin, 0);
        assertEq(aliceAccount.activeCommitment, 0);
        assertEq(bobAccount.activeMargin, 0);
        assertEq(bobAccount.activeCommitment, 0);
        assertEq(vault.totals().activeMargin, 100e18);
        assertEq(vault.totals().activeCommitment, 200e18);
        _assertAccountTotalsWithinDust(0);
    }

    function testLowPriceReturnCommitmentBelowThresholdSweepsSurplus() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        oracle.setPrice(4_999e18);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(margin.balanceOf(treasury), 100e18);
        assertEq(vault.totals().activeMargin, 0);
        assertEq(vault.totals().activeCommitment, 0);
    }

    function testReturnCommitmentAboveThresholdCreditsPairedShares() public {
        _deposit(alice, 99e18);
        _deposit(bob, 1e18);
        _openCall(200e18);
        _finishFunding();
        oracle.setPrice(5_556e18);
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

    function testDueExitMaturityCountsAsDisposalHeadroom() public {
        _deployVaultWithParams(_params(200e18 + 500_000, 200e18 + 500_000));

        _deposit(carol, 100e18);
        _deposit(alice, 250_000);

        vm.prank(carol);
        uint256 maturity = vault.requestExit();
        assertEq(maturity, 1);

        _openCall(1);
        _fund(carol);

        oracle.setPrice(4 * ORACLE_PRICE_SCALE);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 250_000);
        assertEq(state.returnCommitment, 2_000_000);
        assertEq(margin.balanceOf(treasury), 0);
        assertEq(vault.exitBucketCommitmentByMaturity(maturity), 0);
    }

    function testCapBelowGrandfatheredUtilizationDoesNotAddDueCommitmentAsHeadroom() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = 200e18;
        _deployVaultWithParams(params);

        _deposit(carol, 5e18);
        _deposit(bob, 45e18);
        _deposit(alice, 50e18);
        vm.prank(carol);
        assertEq(vault.requestExit(), 1);

        _openCall(100e18);
        _fund(carol);
        _fundRolling(bob);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.totals().activeCommitment, 95e18);

        vm.prank(owner);
        vault.setRiskCaps(80e18, 200e18, 2_000, 0);
        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
        assertEq(margin.balanceOf(treasury), 50e18);
        assertEq(vault.totals().activeCommitment, 90e18);
        assertGt(vault.totals().activeCommitment, vault.riskConfig().protocolCommitmentCap);
    }

    function testDisposalHeadroomClampsToPackedTotalsWidthBeforeDueExitFold() public {
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
        assertEq(vault.requestExit(), 1);

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
        assertEq(state.returnCommitment, packingHeadroom);
        assertEq(vault.totals().activeCommitment, maxPacked - 10e18);
        assertGt(state.returnPool, 0);
        assertEq(state.returnPool + margin.balanceOf(treasury), 10e18);
    }

    /// @dev Slashed epoch whose freed cap headroom is re-consumed by a fresh deposit before disposal:
    /// alice and bob default on a 200e18 call, carol's deposit fills the cap back to `cap`, and time is
    /// warped past the epoch so the next touch settles and disposes.
    function _setupCapBoundSlash(uint256 cap) internal {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = cap;
        _deployVaultWithParams(params);

        _deposit(alice, 99e18);
        _deposit(bob, 1e18);
        _openCall(200e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + NORMAL + PRE_CALL + FUNDING + 1);
        _deposit(carol, 100e18);

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
}
