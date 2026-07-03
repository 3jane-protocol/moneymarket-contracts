// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";
import {LCCErrorsLib} from "../../../src/lcc/libraries/LCCErrorsLib.sol";

contract LCCCallTest is LCCBase {
    function testOpenCallSnapshotsDenominatorAfterPendingActivation() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH + NORMAL);
        vm.prank(owner);
        vault.openEpochCall(1, 100e18);

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(1);
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
        vault.deposit(100e18);
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

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(1);
        assertEq(state.commitmentDenominator, 180e18);
        assertEq(state.marginAtCallOpen, 90e18);
    }

    function testOpenCallRevertsAboveActiveCommitment() public {
        _deposit(alice, 100e18);

        vm.warp(START + NORMAL);
        vm.expectRevert(LCCErrorsLib.InvalidAmount.selector);
        vm.prank(owner);
        vault.openEpochCall(0, 200e18 + 1);
    }
}
