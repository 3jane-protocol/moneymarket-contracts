// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";

contract LCCSyncTest is LCCBase {
    function testSyncActivatesPendingBeforeCapSensitiveDeposit() public {
        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);

        assertEq(vault.totalPendingMargin(), 0);
        assertEq(vault.totalActiveMargin(), 150e18);
    }

    function testSyncFoldsMaturedExitsBeforeNextAction() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vault.requestExit();

        vm.warp(START + EPOCH);
        _deposit(bob, 50e18);

        assertEq(vault.totalActiveMargin(), 50e18);
    }

    function testExplicitFinalizeAndAutoSyncReachSameState() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();

        vm.prank(bob);
        vault.materializeAccount(bob);

        assertEq(margin.balanceOf(treasury), 100e18);
        assertEq(vault.totalActiveMargin(), 0);
    }
}
