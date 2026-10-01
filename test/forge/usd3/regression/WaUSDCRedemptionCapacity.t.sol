// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";

contract WaUSDCRedemptionCapacityTest is Setup {
    USD3 public usd3;
    address public alice = makeAddr("alice");

    function setUp() public override {
        super.setUp();
        usd3 = USD3(address(strategy));

        airdrop(asset, alice, 10_000e6);
        vm.prank(alice);
        asset.approve(address(strategy), type(uint256).max);
    }

    function test_availableWithdrawLimit_capsLocalAndMorphoByGlobalRedeemCapacity() public {
        setMaxOnCredit(5_000);

        vm.prank(alice);
        strategy.deposit(2_000e6, alice);

        assertEq(usd3.balanceOfWaUSDC(), 1_000e6, "setup local");
        assertEq(usd3.suppliedWaUSDC(), 1_000e6, "setup morpho");

        waUSDC.setVirtualUnderlyingBalance(1_500e6);

        assertEq(usd3.availableWithdrawLimit(alice), 1_500e6, "withdraw limit");

        vm.prank(alice);
        uint256 shares = strategy.withdraw(1_500e6, alice, alice);

        assertEq(shares, 1_500e6, "shares burned");
        assertEq(asset.balanceOf(alice), 9_500e6, "alice balance");
    }

    function test_availableWithdrawLimit_countsMorphoLiquidityWhenLocalBalanceIsZero() public {
        setMaxOnCredit(10_000);

        vm.prank(alice);
        strategy.deposit(1_000e6, alice);

        assertEq(usd3.balanceOfWaUSDC(), 0, "setup local");
        assertEq(usd3.suppliedWaUSDC(), 1_000e6, "setup morpho");

        waUSDC.setVirtualUnderlyingBalance(1_000e6);

        assertEq(waUSDC.maxRedeem(address(usd3)), 0, "local max redeem");
        assertEq(usd3.availableWithdrawLimit(alice), 1_000e6, "withdraw limit");

        vm.prank(alice);
        uint256 shares = strategy.withdraw(1_000e6, alice, alice);

        assertEq(shares, 1_000e6, "shares burned");
        assertEq(asset.balanceOf(alice), 10_000e6, "alice balance");
    }
}
