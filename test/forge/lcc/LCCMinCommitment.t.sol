// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCMinCommitmentTest is LCCBase {
    function testMinZeroExitsSameEpoch() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        assertEq(vault.requestExit(), 1);
    }

    function testGateBlocksUntilMinEpochsElapse() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + 2 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(), 3);
    }

    function testPendingDepositAnchorsAtActivationEpoch() public {
        _deployMinCommitmentVault(2, 0);

        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);

        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);

        vm.warp(START + 2 * EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(), 4);
    }

    function testTopUpResetsTheClock() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);

        vm.warp(START + 3 * EPOCH);
        _deposit(alice, 50e18);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 3);

        vm.warp(START + 4 * EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + 5 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(), 6);
    }

    function testFundingNeverTouchesTheClock() public {
        _deployMinCommitmentVault(2, 0);

        vm.warp(START + EPOCH);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _deposit(carol, 100e18);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);

        // Fund a later epoch's call so a regression that re-anchors the clock on funding would move it to 2.
        _openCallAtEpoch(2, 100e18);
        _fundRollingAtEpoch(alice, 2);
        _fundAtEpoch(bob, 2);
        vm.prank(alice);
        vault.fundCall(carol);

        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);
        assertEq(vault.getAccount(bob).commitmentStartEpoch, 1);
        assertEq(vault.getAccount(carol).commitmentStartEpoch, 1);
    }

    function testDefaultWipeThenRedepositResets() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);
        _openCall(200e18);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.warp(START + EPOCH);
        vault.materializeAccount(alice);
        _deposit(alice, 50e18);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 1);

        vm.warp(START + 2 * EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        vault.requestExit();
    }

    function testReturnPoolCreditKeepsOriginalAnchor() public {
        _deployMinCommitmentVault(2, 0);

        // Anchor at a nonzero epoch so a wipe that zeroed the clock would be visible.
        vm.warp(START + EPOCH);
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _openCallAtEpoch(1, 100e18);
        _fundAtEpoch(alice, 1);
        _finishFundingAtEpoch(1);
        vault.finalizeEpochSlash(1);

        vm.warp(START + 2 * EPOCH);
        vault.materializeAccount(bob);

        ILCCVault.Account memory bobAccount = vault.getAccount(bob);
        assertGt(bobAccount.activeMargin, 0);
        assertEq(bobAccount.commitmentStartEpoch, 1);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(bob);
        vault.requestExit();

        vm.warp(START + 3 * EPOCH);
        vm.prank(bob);
        vault.requestExit();
    }

    function testExitClaimThenRedepositResets() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);

        vm.warp(START + 2 * EPOCH);
        vm.prank(alice);
        uint256 maturity = vault.requestExit();
        assertEq(maturity, 3);

        vm.warp(START + 3 * EPOCH);
        vm.prank(alice);
        vault.claimExitedMargin(alice);

        vm.warp(START + 5 * EPOCH);
        _deposit(alice, 100e18);
        assertEq(vault.getAccount(alice).commitmentStartEpoch, 5);

        vm.warp(START + 6 * EPOCH);
        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + 7 * EPOCH);
        vm.prank(alice);
        assertEq(vault.requestExit(), 8);
    }

    function testTerminalClaimRemainingBypassesGate() public {
        _deployMinCommitmentVault(2, 1);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
    }

    function testShutdownClaimRemainingBypassesGate() public {
        _deployMinCommitmentVault(2, 0);
        _deposit(alice, 100e18);

        vm.prank(owner);
        vault.shutdown();

        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
    }

    function testHoldToMaturityVaultDrainsAtTerminal() public {
        // minCommitmentEpochs >= maxEpochs: the exit gate can never pass before terminal, so the facility is
        // hold-to-maturity; the terminal claim still drains in full.
        _deployMinCommitmentVault(64, 1);
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.CommitmentNotMature.selector);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + EPOCH);
        vm.prank(alice);
        assertEq(vault.claimRemainingMargin(alice), 100e18);
    }

    function testValidationCeiling() public {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);

        params.minCommitmentEpochs = 65;
        vm.expectRevert(LCCErrorsLib.InvalidParams.selector);
        _newVault(params);

        params.minCommitmentEpochs = 64;
        assertEq(_newVault(params).epochConfig().minCommitmentEpochs, 64);

        params.minCommitmentEpochs = 0;
        assertEq(_newVault(params).epochConfig().minCommitmentEpochs, 0);
    }

    function _deployMinCommitmentVault(uint256 minCommitmentEpochs, uint256 maxEpochs) internal {
        ILCCVault.VaultParams memory params = _params(CAP, CAP);
        params.minCommitmentEpochs = minCommitmentEpochs;
        params.maxEpochs = maxEpochs;
        _deployVaultWithParams(params);
    }
}
