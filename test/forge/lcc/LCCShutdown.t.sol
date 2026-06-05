// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";

contract LCCShutdownTest is LCCBase {
    function testShutdownDuringFundingDisablesSlash() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.warp(START + NORMAL + PRE_CALL);
        vm.prank(owner);
        vault.shutdown();

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(state.slashFinalized);
        assertTrue(state.slashDisabledByShutdown);
        assertEq(margin.balanceOf(treasury), 0);
        assertEq(vault.totalActiveMargin(), 100e18);
    }

    function testShutdownAfterFundingDeadlineAllowsNormalSlash() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        _finishFunding();

        vm.prank(owner);
        vault.shutdown();

        ILeveragedCallableCreditVault.EpochState memory state = vault.getEpochState(0);
        assertTrue(state.slashFinalized);
        assertFalse(state.slashDisabledByShutdown);
        assertEq(margin.balanceOf(treasury), 100e18);
    }

    function testEmergencyClaimWithdrawsSafeMarginAndBlocksDeposits() public {
        _deposit(alice, 100e18);

        vm.prank(owner);
        vault.shutdown();

        vm.expectRevert();
        _deposit(alice, 1e18);

        uint256 beforeBalance = margin.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimEmergencyMargin(alice);

        assertEq(claimed, 100e18);
        assertEq(margin.balanceOf(alice), beforeBalance + 100e18);
        assertEq(vault.totalActiveMargin(), 0);
    }

    function testEmergencyClaimClearsPendingExitBucket() public {
        _deposit(alice, 100e18);

        vm.prank(alice);
        uint256 maturity = vault.requestExit();

        vm.prank(owner);
        vault.shutdown();

        vm.prank(alice);
        vault.claimEmergencyMargin(alice);

        assertEq(vault.exitRequestedMarginByMaturity(maturity), 0);
        assertEq(vault.exitRequestedCallableByMaturity(maturity), 0);

        vm.warp(START + EPOCH * (maturity + 1));
        _syncAs(bob);

        assertEq(vault.totalActiveMargin(), 0);
        assertEq(vault.totalActiveCallableUsdc(), 0);
    }
}
