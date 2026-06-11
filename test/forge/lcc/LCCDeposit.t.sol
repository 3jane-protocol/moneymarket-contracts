// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase, LCCRevertingOracle} from "./LCCBase.t.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";

contract LCCDepositTest is LCCBase {
    function testDepositValuesMarginAndActivatesDuringNormal() public {
        uint256 callable = _deposit(alice, 100e18);

        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(alice);
        assertEq(callable, 200e18);
        assertEq(account.activeMargin, 100e18);
        assertEq(account.activeCallableUsdc, 200e18);
        assertEq(vault.totalActiveMargin(), 100e18);
        assertEq(vault.totalActiveCallableUsdc(), 200e18);
    }

    function testDepositStagesOutsideNormalAndAggregateBucketActivates() public {
        vm.warp(START + NORMAL);
        uint256 callable = _deposit(alice, 100e18);

        assertEq(callable, 200e18);
        assertEq(vault.totalPendingMargin(), 100e18);
        assertEq(vault.pendingMarginByActivationEpoch(1), 100e18);

        vm.warp(START + EPOCH);
        _syncAs(bob);

        assertEq(vault.totalPendingMargin(), 0);
        assertEq(vault.totalActiveMargin(), 100e18);

        ILeveragedCallableCreditVault.Account memory derived = vault.getAccount(alice);
        assertEq(derived.activeMargin, 100e18);
        assertEq(derived.pendingMargin, 0);
    }

    function testCapsIncludePendingCallable() public {
        vault = new LeveragedCallableCreditVault(_params(400e18, 400e18));
        vm.startPrank(alice);
        margin.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.warp(START + NORMAL);
        _deposit(alice, 100e18);

        vm.expectRevert(LeveragedCallableCreditVault.CapExceeded.selector);
        _deposit(alice, 101e18);
    }

    function testMinDepositEnforced() public {
        ILeveragedCallableCreditVault.VaultParams memory params = _params(CAP, CAP);
        params.minDepositAssets = 10e18;
        vault = new LeveragedCallableCreditVault(params);
        _mintAndApprove(alice, 0, 0);

        vm.expectRevert(LeveragedCallableCreditVault.InvalidAmount.selector);
        _deposit(alice, 10e18 - 1);

        _deposit(alice, 10e18);
        assertEq(vault.getAccount(alice).activeMargin, 10e18);
    }

    function testSetRiskCapsUpdatesMinDeposit() public {
        vm.prank(owner);
        vault.setRiskCaps(CAP, CAP, 2_000, 5e18);

        assertEq(vault.minDepositAssets(), 5e18);

        vm.expectRevert(LeveragedCallableCreditVault.InvalidAmount.selector);
        _deposit(alice, 1e18);

        _deposit(alice, 5e18);
    }

    function testZeroOraclePriceReverts() public {
        oracle.setPrice(0);
        vm.expectRevert(LeveragedCallableCreditVault.OraclePriceInvalid.selector);
        _deposit(alice, 100e18);
    }

    function testRevertingOracleBubbles() public {
        LCCRevertingOracle badOracle = new LCCRevertingOracle();
        vault = new LeveragedCallableCreditVault(_params(address(badOracle), CAP, CAP, 2_000));

        vm.expectRevert("ORACLE_DOWN");
        _deposit(alice, 100e18);
    }
}
