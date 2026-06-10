// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";

contract LCCEscrowTest is LCCBase {
    function testFundingEscrowsWhenUsd3CapacityInsufficient() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        usd3.setDepositLimit(0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ILeveragedCallableCreditVault.FundingEscrowed(alice, 0, 100e18);
        uint256 obligation = _fund(alice);

        assertEq(obligation, 100e18);
        assertEq(usd3.balanceOf(alice), 0);
        assertEq(vault.escrowedFundingUsdc(alice), 100e18);
        assertEq(vault.totalEscrowedFundingUsdc(), 100e18);
        assertEq(usdc.balanceOf(address(vault)), 100e18);
        assertEq(margin.balanceOf(alice), 1_000_000e18 - 50e18);
        assertTrue(vault.fundedEpoch(0, alice));
    }

    function testEscrowedFunderIsNotSlashed() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        usd3.setDepositLimit(0);
        _fund(alice);
        _finishFunding();

        vault.finalizeEpochSlash(0);

        assertEq(margin.balanceOf(treasury), 0);
        assertFalse(vault.defaultedEpoch(0, alice));
        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 50e18);
        assertEq(account.activeCallableUsdc, 100e18);
    }

    function testPlaceEscrowedFundingPartialThenFull() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        usd3.setDepositLimit(0);
        _fund(alice);

        usd3.setDepositLimit(40e18);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ILeveragedCallableCreditVault.EscrowedFundingPlaced(alice, 40e18);
        uint256 placed = vault.placeEscrowedFunding(alice);

        assertEq(placed, 40e18);
        assertEq(usd3.balanceOf(alice), 40e18);
        assertEq(vault.escrowedFundingUsdc(alice), 60e18);
        assertEq(vault.totalEscrowedFundingUsdc(), 60e18);

        usd3.setDepositLimit(type(uint256).max);
        placed = vault.placeEscrowedFunding(alice);

        assertEq(placed, 60e18);
        assertEq(usd3.balanceOf(alice), 100e18);
        assertEq(vault.escrowedFundingUsdc(alice), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function testPlaceEscrowedFundingRevertsWithoutEscrowOrCapacity() public {
        vm.expectRevert(LeveragedCallableCreditVault.NothingToClaim.selector);
        vault.placeEscrowedFunding(alice);

        _deposit(alice, 100e18);
        _openCall(100e18);
        usd3.setDepositLimit(0);
        _fund(alice);

        vm.expectRevert(LeveragedCallableCreditVault.InvalidAmount.selector);
        vault.placeEscrowedFunding(alice);
    }

    function testClaimEscrowedFundingRequiresShutdown() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        usd3.setDepositLimit(0);
        _fund(alice);

        vm.expectRevert(LeveragedCallableCreditVault.ShutdownRequired.selector);
        vm.prank(alice);
        vault.claimEscrowedFunding(alice);

        vm.prank(owner);
        vault.shutdown();

        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimEscrowedFunding(alice);

        assertEq(claimed, 100e18);
        assertEq(usdc.balanceOf(alice), usdcBefore + 100e18);
        assertEq(vault.escrowedFundingUsdc(alice), 0);
        assertEq(vault.totalEscrowedFundingUsdc(), 0);
    }
}

contract LCCFundForTest is LCCBase {
    function testFundEpochCallForPayerPaysAndUserBenefits() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        vm.warp(START + NORMAL + PRE_CALL);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceMarginBefore = margin.balanceOf(alice);

        vm.prank(bob);
        uint256 obligation = vault.fundEpochCallFor(0, alice);

        assertEq(obligation, 100e18);
        assertEq(usdc.balanceOf(bob), bobUsdcBefore - 100e18);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore);
        assertEq(usd3.balanceOf(alice), 100e18);
        assertEq(usd3.balanceOf(bob), 0);
        assertEq(margin.balanceOf(alice), aliceMarginBefore + 50e18);
        assertTrue(vault.fundedEpoch(0, alice));
        assertFalse(vault.fundedEpoch(0, bob));
    }

    function testFundEpochCallForCannotRepeatOrTargetZero() public {
        _deposit(alice, 100e18);
        _openCall(100e18);
        vm.warp(START + NORMAL + PRE_CALL);

        vm.expectRevert(LeveragedCallableCreditVault.ZeroAddress.selector);
        vm.prank(bob);
        vault.fundEpochCallFor(0, address(0));

        vm.prank(bob);
        vault.fundEpochCallFor(0, alice);

        vm.expectRevert(LeveragedCallableCreditVault.AlreadyFunded.selector);
        vm.prank(alice);
        vault.fundEpochCall(0);
    }
}

contract LCCEventEnrichmentTest is LCCBase {
    function testDepositCheckpointedIncludesMarginValue() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit ILeveragedCallableCreditVault.DepositCheckpointed(alice, 100e18, 100e18, 200e18, 0, true);
        _deposit(alice, 100e18);
    }

    function testExitRequestedIncludesMargin() public {
        _deposit(alice, 100e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ILeveragedCallableCreditVault.ExitRequested(alice, 1, 100e18, 200e18);
        vm.prank(alice);
        vault.requestExit();
    }

    function testUserDefaultedIncludesSlashedAmounts() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(100e18);
        _fund(alice);
        _finishFunding();
        vault.finalizeEpochSlash(0);

        vm.expectEmit(true, true, false, true, address(vault));
        emit ILeveragedCallableCreditVault.UserDefaulted(bob, 0, 50e18, 100e18);
        vault.materializeAccount(bob);

        assertTrue(vault.defaultedEpoch(0, bob));
        assertEq(margin.balanceOf(treasury), 50e18);
    }
}
