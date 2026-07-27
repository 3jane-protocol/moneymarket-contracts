// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LCCVault} from "../../../src/lcc/LCCVault.sol";
import {ILCCVault} from "../../../src/lcc/interfaces/ILCCVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCCallTest is LCCBase {
    function testOpenCallSnapshotsDenominatorAfterPendingActivation() public {
        vm.warp(START + NORMAL + PRE_CALL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(1, 100e18);

        ILCCVault.EpochState memory state = vault.getEpochState(1);
        assertEq(state.commitmentDenominator, 200e18);
        assertEq(state.marginAtCallOpen, 100e18);
    }

    function testOpenCallRequiresPreCallAndOwner() public {
        _deposit(alice, 100e18);

        vm.expectRevert(LCCErrorsLib.InvalidPhase.selector);
        vm.prank(owner);
        vault.openEpochCall(0, 100e18);

        vm.warp(START + NORMAL);
        vm.expectRevert();
        vault.openEpochCall(0, 100e18);
    }

    function testDepositCreditsCallerOnly() public {
        // deposit is self-only: there is no receiver argument to credit a third party's obligation.
        vm.startPrank(alice);
        margin.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, 1, type(uint256).max, true, type(uint256).max);
        vm.stopPrank();

        assertEq(vault.getAccount(alice).activeMargin, 100e18);
        assertEq(vault.getAccount(bob).activeMargin, 0);
    }

    function testOpenCallRejectsNonCurrentEpoch() public {
        _deposit(alice, 100e18);

        vm.warp(START + NORMAL);
        vm.expectRevert(LCCErrorsLib.InvalidEpoch.selector);
        vm.prank(owner);
        vault.openEpochCall(1, 100e18);
    }

    function testNextOpenAutoFinalizesPriorSlashBeforeSnapshot() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.warp(START + EPOCH + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(1, 100e18);

        ILCCVault.EpochState memory state = vault.getEpochState(1);
        assertEq(state.commitmentDenominator, 200e18);
        assertEq(state.marginAtCallOpen, 100e18);
    }

    function testOpenCallRevertsAboveActiveCommitment() public {
        _deposit(alice, 100e18);

        vm.warp(START + NORMAL);
        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(owner);
        vault.openEpochCall(0, 200e18 + 1);
    }
}
