// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";

contract LCCSlashFeeTest is LCCBase {
    uint256 internal constant DEADLINE = START + NORMAL + PRE_CALL + FUNDING;
    uint256 internal constant WINDOW_END = START + EPOCH;

    function testFeeOnAwardedPartialFillSplit() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(10e18);
        assertEq(award, 5e18);

        vm.warp(WINDOW_END);
        vault.materializeAccount(carol);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(margin.balanceOf(treasury), 0.5e18);
        assertEq(state.returnPool, 44.5e18);
        assertEq(state.returnCommitment, 89e18);
    }

    function testFullFillFeeClampedToSurplus() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.slashFeeBps = 10_000;
        _deployVaultWithParams(params);
        _setupShortfallAuction();

        vm.warp(DEADLINE + 10);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(50e18);
        assertEq(award, 37.5e18);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(margin.balanceOf(treasury), 12.5e18);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
    }

    function testNoKickLateFinalizationHasNoFeeBasis() public {
        _deployAuctionVault();
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);

        vm.warp(WINDOW_END + 1);
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(margin.balanceOf(treasury), 0);
        assertEq(state.returnPool, 50e18);
        assertEq(state.returnCommitment, 100e18);
    }

    function testDisabledAuctionHasNoFeeBasis() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(margin.balanceOf(treasury), 0);
        assertEq(state.returnPool, 100e18);
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
        assertEq(margin.balanceOf(treasury), 0);
        assertEq(state.returnPool, 1e18);
        assertEq(state.returnCommitment, 2e18);
        assertEq(vault.getAuctionState(0).shortfallAmount, 0);
    }

    function testShutdownSettledPartialFillChargesFeeOnAward() public {
        _deployAuctionVault();
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(10e18);
        assertEq(award, 5e18);

        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(margin.balanceOf(treasury), 0.5e18);
        assertEq(state.returnPool, 44.5e18);
        assertEq(state.returnCommitment, 89e18);
    }

    function testFullFeeNeverAuctionedGoingConcernRetriesUntilOracleRecovery() public {
        // Full fee on an auction-enabled vault, but the call finalizes only after the auction window, so no
        // auction is kicked: the fee basis is zero, the whole surplus is a return pool, and going-concern
        // disposal needs the oracle.
        ILCCVault.VaultParams memory params = _auctionParams();
        params.slashFeeBps = 10_000;
        _deployVaultWithParams(params);

        _deposit(alice, 100e18);
        _openCall(100e18);
        vm.warp(WINDOW_END);

        oracle.setPrice(0);
        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vault.materializeAccount(alice);

        oracle.setPrice(ORACLE_PRICE_SCALE);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(margin.balanceOf(treasury), 0);
        assertEq(state.returnPool, 100e18);
        assertEq(state.returnCommitment, 200e18);
    }

    function testFullFeePartialFillDeadOracleRetriesButWindDownSettles() public {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.slashFeeBps = 10_000;
        _deployVaultWithParams(params);
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(10e18);
        assertEq(award, 5e18);

        oracle.setPrice(0);
        vm.warp(WINDOW_END);
        vm.expectRevert(LCCErrorsLib.OraclePriceInvalid.selector);
        vault.materializeAccount(alice);

        oracle.setPrice(ORACLE_PRICE_SCALE);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(margin.balanceOf(treasury), 5e18);
        assertEq(state.returnPool, 40e18);
        assertEq(state.returnCommitment, 80e18);

        uint256 treasuryBefore = margin.balanceOf(treasury);

        params = _auctionParams();
        params.maxEpochs = 1;
        params.slashFeeBps = 10_000;
        vm.warp(START);
        _deployVaultWithParams(params);
        _setupShortfallAuction();

        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (, award) = vault.takeAuction(10e18);
        assertEq(award, 5e18);

        oracle.setPrice(0);
        vm.warp(WINDOW_END);
        vault.materializeAccount(alice);

        state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(margin.balanceOf(treasury) - treasuryBefore, 45e18);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
    }

    function testFeeConsumedSurplusSettlesWithoutOracle() public {
        // At full fee, an award large enough that the fee consumes the whole surplus leaves returnPool == 0, so
        // lazy settlement never values the pool and cannot depend on the oracle.
        ILCCVault.VaultParams memory params = _auctionParams();
        params.slashFeeBps = 10_000;
        _deployVaultWithParams(params);
        _setupShortfallAuction();

        vm.warp(DEADLINE + 10);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(40e18);
        assertEq(award, 30e18);

        oracle.setPrice(0);
        vm.warp(WINDOW_END);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 0);
        assertEq(margin.balanceOf(treasury), 20e18);
        assertEq(state.returnPool, 0);
        assertEq(state.returnCommitment, 0);
    }

    function testTightCapClampPinsNeverAwardedRecovery() public {
        _setupAllDefaultAuctionWithCap(250e18);

        vm.warp(DEADLINE + 1);
        _deposit(carol, 100e18);

        vm.warp(WINDOW_END);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 25e18);
        assertEq(state.returnCommitment, 50e18);
        assertEq(margin.balanceOf(treasury), 75e18);
    }

    function testTightCapClampPinsPartialFillRecovery() public {
        _setupAllDefaultAuctionWithCap(250e18);

        vm.warp(DEADLINE + 5);
        vm.prank(carol);
        (, uint256 award) = vault.takeAuction(20e18);
        assertEq(award, 5e18);

        _deposit(carol, 100e18);

        vm.warp(WINDOW_END);
        vault.materializeAccount(alice);

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        assertEq(state.returnPool, 25e18);
        assertEq(state.returnCommitment, 50e18);
        assertEq(margin.balanceOf(treasury), 70e18);
    }

    function _setupShortfallAuction() internal {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(150e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);
    }

    function _setupAllDefaultAuctionWithCap(uint256 cap) internal {
        ILCCVault.VaultParams memory params = _auctionParams();
        params.protocolCommitmentCap = cap;
        _deployVaultWithParams(params);

        _deposit(alice, 99e18);
        _deposit(bob, 1e18);
        _openCall(200e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);
        assertEq(vault.syncState().pendingAuctionEpochPlusOne, 1);
    }
}
