// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Ownable} from "../../../lib/openzeppelin/contracts/access/Ownable.sol";
import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";
import {LCCEventsLib} from "../../../src/lcc/libraries/LCCEventsLib.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ORACLE_PRICE_SCALE} from "../../../src/libraries/ConstantsLib.sol";

contract LCCPauseTest is LCCBase {
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    function testGuardianOwnerAndUnauthorizedPause() public {
        vm.prank(owner);
        vault.setGuardian(guardian);

        vm.prank(guardian);
        vault.pause();
        (, bool paused,,) = vault.pauseState();
        assertTrue(paused);

        vm.prank(owner);
        vault.unpause();

        vm.prank(owner);
        vault.pause();

        _deployVaultWithParams(_params(CAP, CAP));
        vm.expectRevert(LCCErrorsLib.Unauthorized.selector);
        vm.prank(stranger);
        vault.pause();
    }

    function testDoublePauseAndUnpauseWhenNotPausedRevert() public {
        vm.expectRevert(LCCErrorsLib.NotPaused.selector);
        vm.prank(owner);
        vault.unpause();

        vm.prank(owner);
        vault.pause();

        vm.expectRevert(LCCErrorsLib.AlreadyPaused.selector);
        vm.prank(owner);
        vault.pause();
    }

    function testPausedEntryPointsRevertAndLiveFunctionsSucceed() public {
        _deposit(alice, 100e18);

        vm.prank(owner);
        vault.setGuardian(guardian);
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(alice);
        vault.deposit(1e18, 1, type(uint256).max, true, type(uint256).max);

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(owner);
        vault.openEpochCall(0, 1e18);

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(alice);
        vault.fundCall(false);

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(carol);
        vault.takeAuction(1e18);

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(alice);
        vault.requestExit(type(uint256).max, type(uint256).max);

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(alice);
        vault.claimExitedMargin(alice);

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(alice);
        vault.claimRemainingMargin(alice);

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(alice);
        vault.materializeAccount(alice);

        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vault.finalizeEpochSlash(0);

        vm.prank(owner);
        vault.setGuardian(address(0));
        (address storedGuardian, bool paused,,) = vault.pauseState();
        assertEq(storedGuardian, address(0));
        assertTrue(paused);

        OracleMock newOracle = new OracleMock();
        newOracle.setPrice(ORACLE_PRICE_SCALE);
        vm.prank(owner);
        vault.setMarginOracle(address(newOracle));
        assertEq(vault.assetConfig().marginOracle, address(newOracle));

        vm.prank(owner);
        vault.shutdown();
        assertTrue(vault.shutdownState().active);
    }

    function testUnpauseIsOwnerOnlyWithNoTimeBound() public {
        vm.prank(owner);
        vault.setGuardian(guardian);
        vm.prank(guardian);
        vault.pause();
        (,, uint64 pausedAt,) = vault.pauseState();

        vm.warp(uint256(pausedAt) + 365 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        vault.unpause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        vault.unpause();

        vm.prank(owner);
        vault.unpause();
        (, bool paused,, uint64 accumulated) = vault.pauseState();
        assertFalse(paused);
        assertEq(accumulated, 365 days);
    }

    function testClockExactnessShiftsFundingDeadline() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(200e18);

        uint256 pauseAt = START + NORMAL + PRE_CALL + 10;
        uint256 duration = 37;
        vm.warp(pauseAt);
        vm.prank(owner);
        vault.pause();
        assertEq(uint256(vault.currentPhase()), uint256(ILCCVault.Phase.Funding));
        assertEq(_effectiveTime(vault), pauseAt);

        vm.warp(pauseAt + duration);
        assertEq(uint256(vault.currentPhase()), uint256(ILCCVault.Phase.Funding));
        assertEq(_effectiveTime(vault), pauseAt);
        vm.prank(owner);
        vault.unpause();
        assertEq(uint256(vault.currentPhase()), uint256(ILCCVault.Phase.Funding));

        vm.warp(START + NORMAL + PRE_CALL + FUNDING + duration - 1);
        vm.prank(alice);
        vault.fundCall(false);

        vm.warp(START + NORMAL + PRE_CALL + FUNDING + duration + 1);
        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(bob);
        vault.fundCall(false);
    }

    function testShutdownWhilePausedDuringFundingDisablesSlash() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCall(200e18);

        vm.warp(START + NORMAL + PRE_CALL + 10);
        vm.prank(owner);
        vault.pause();
        vm.warp(START + NORMAL + PRE_CALL + 10 + 1 days);
        vm.prank(owner);
        vault.shutdown();

        ILCCVault.EpochState memory state = vault.getEpochState(0);
        ILCCVault.ShutdownState memory shutdownState = vault.shutdownState();
        (, bool paused,, uint64 accumulated) = vault.pauseState();
        assertFalse(paused);
        assertEq(accumulated, 1 days);
        assertEq(_effectiveTime(vault), START + NORMAL + PRE_CALL + 10);
        assertEq(shutdownState.timestamp, START + NORMAL + PRE_CALL + 10);
        assertEq(shutdownState.epoch, 0);
        assertTrue(state.slashFinalized);
        assertTrue(state.slashDisabledByShutdown);
        assertEq(state.slashedMargin, 0);
        assertEq(vault.totals().activeMargin, 200e18);
        assertEq(_accruedTreasuryMargin(), 0);
    }

    function testPausedAccumulatedAcrossTwoCyclesKeepsClockExact() public {
        vm.warp(START + 5);
        vm.prank(owner);
        vault.pause();
        vm.warp(START + 15);
        assertEq(_effectiveTime(vault), START + 5);
        vm.prank(owner);
        vault.unpause();
        assertEq(_effectiveTime(vault), START + 5);

        vm.warp(START + 25);
        vm.prank(owner);
        vault.pause();
        vm.warp(START + 45);
        assertEq(_effectiveTime(vault), START + 15);
        vm.prank(owner);
        vault.unpause();

        (,,, uint64 accumulated) = vault.pauseState();
        assertEq(accumulated, 30);
        assertEq(_effectiveTime(vault), START + 15);
    }

    function testShutdownWhilePausedEndsPauseAndAllowsImmediateWindDownClaims() public {
        _deposit(alice, 100e18);

        uint256 pauseAt = START + 5;
        uint256 duration = 37;
        vm.warp(pauseAt);
        vm.prank(owner);
        vault.pause();

        vm.warp(pauseAt + duration);
        vm.expectEmit(true, false, false, false, address(vault));
        emit LCCEventsLib.Unpaused(owner);
        vm.prank(owner);
        vault.shutdown();

        (, bool paused,, uint64 accumulated) = vault.pauseState();
        assertFalse(paused);
        assertEq(accumulated, duration);
        assertEq(_effectiveTime(vault), pauseAt);
        assertEq(vault.shutdownState().timestamp, pauseAt);

        vm.expectRevert(LCCErrorsLib.NotPaused.selector);
        vm.prank(owner);
        vault.unpause();

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimRemainingMargin(alice);
        assertEq(claimed, 100e18);
        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
    }

    function testPauseAfterShutdownBlocksClaimsUntilOwnerUnpauses() public {
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.setGuardian(guardian);
        vm.prank(owner);
        vault.shutdown();

        vm.prank(guardian);
        vault.pause();
        vm.expectRevert(LCCErrorsLib.Paused.selector);
        vm.prank(alice);
        vault.claimRemainingMargin(alice);

        vm.prank(owner);
        vault.unpause();
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
    }

    function testRenounceOwnershipAlwaysReverts() public {
        vm.expectRevert(LCCErrorsLib.Unauthorized.selector);
        vm.prank(owner);
        vault.renounceOwnership();
        assertEq(vault.owner(), owner);

        vm.prank(owner);
        vault.pause();
        vm.expectRevert(LCCErrorsLib.Unauthorized.selector);
        vm.prank(owner);
        vault.renounceOwnership();
        assertEq(vault.owner(), owner);
    }

    function testTransferOwnershipWhilePausedLetsNewOwnerRecover() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.transferOwnership(newOwner);

        assertEq(vault.owner(), newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        vault.unpause();

        vm.prank(newOwner);
        vault.unpause();
        (, bool paused,,) = vault.pauseState();
        assertFalse(paused);
    }
}
