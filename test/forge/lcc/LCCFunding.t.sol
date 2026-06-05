// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {LCCBase} from "./LCCBase.t.sol";
import {LeveragedCallableCreditVault} from "../../../src/lcc/LeveragedCallableCreditVault.sol";
import {ILeveragedCallableCreditVault} from "../../../src/lcc/interfaces/ILeveragedCallableCreditVault.sol";

contract LCCFundingTest is LCCBase {
    function testFundingPullsExactObligationDepositsUsd3AndReleasesMargin() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        _openCall(75e18);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 obligation = _fund(alice);

        assertEq(obligation, 50e18);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - 50e18);
        assertEq(usd3.balanceOf(alice), 50e18);
        assertEq(margin.balanceOf(alice), 1_000_000e18 - 75e18);
        assertTrue(vault.fundedEpoch(0, alice));

        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 75e18);
        assertEq(account.activeCallableUsdc, 150e18);
    }

    function testObligationRoundsUpAndMarginReleaseRoundsDown() public {
        _deposit(alice, 1e18);
        _openCall(1);

        uint256 obligation = _fund(alice);

        assertEq(obligation, 1);
        assertEq(usd3.balanceOf(alice), 1);

        ILeveragedCallableCreditVault.Account memory account = vault.getAccount(alice);
        assertEq(account.activeMargin, 1e18);
        assertEq(account.activeCallableUsdc, 2e18 - 1);
    }

    function testFundingRequiresFundingPhaseAndCannotRepeat() public {
        _deposit(alice, 100e18);
        _openCall(100e18);

        vm.expectRevert(LeveragedCallableCreditVault.InvalidPhase.selector);
        vm.prank(alice);
        vault.fundEpochCall(0);

        _fund(alice);

        vm.expectRevert(LeveragedCallableCreditVault.AlreadyFunded.selector);
        vm.prank(alice);
        vault.fundEpochCall(0);
    }
}
