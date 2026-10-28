// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title TransferRestrictionComplexScenarios
 * @notice Tests multi-user transfer scenarios for current USD3 and sUSD3 behavior.
 */
contract TransferRestrictionComplexScenarios is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(makeAddr("ProxyAdminOwner"));
        bytes memory susd3InitData =
            abi.encodeWithSelector(sUSD3.initialize.selector, address(usd3Strategy), management, keeper);
        TransparentUpgradeableProxy susd3Proxy =
            new TransparentUpgradeableProxy(address(susd3Implementation), address(susd3ProxyAdmin), susd3InitData);
        susd3Strategy = sUSD3(address(susd3Proxy));

        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        vm.prank(management);
        usd3Strategy.setMinDeposit(100e6);

        address[4] memory users = [alice, bob, charlie, dave];
        for (uint256 i = 0; i < users.length; i++) {
            airdrop(asset, users[i], 10000e6);
        }
    }

    function test_multiUserUsd3TransfersRemainLiquid() public {
        _depositUsd3(alice, 1000e6);
        _depositUsd3(bob, 1000e6);
        _depositUsd3(charlie, 1000e6);

        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(dave, 100e6);

        vm.prank(bob);
        IERC20(address(usd3Strategy)).transfer(dave, 200e6);

        vm.prank(charlie);
        IERC20(address(usd3Strategy)).transfer(dave, 300e6);

        assertEq(IERC20(address(usd3Strategy)).balanceOf(dave), 600e6);
    }

    function test_susd3LockedSharesCannotBeCircularlyMoved() public {
        _depositSusd3(alice, 1000e6, 100e6);
        _depositSusd3(bob, 1000e6, 50e6);

        uint256 aliceShares = IERC20(address(susd3Strategy)).balanceOf(alice);
        uint256 bobShares = IERC20(address(susd3Strategy)).balanceOf(bob);

        vm.prank(alice);
        vm.expectRevert("sUSD3: Cannot transfer during lock period");
        IERC20(address(susd3Strategy)).transfer(bob, aliceShares);

        vm.prank(bob);
        vm.expectRevert("sUSD3: Cannot transfer during lock period");
        IERC20(address(susd3Strategy)).transfer(alice, bobShares);
    }

    function test_susd3CooldownRestrictionsComposeAcrossUsers() public {
        _depositSusd3(alice, 1000e6, 100e6);
        skip(90 days);

        uint256 aliceShares = IERC20(address(susd3Strategy)).balanceOf(alice);
        uint256 cooldownShares = aliceShares / 2;
        uint256 liquidShares = aliceShares - cooldownShares;

        vm.prank(alice);
        susd3Strategy.startCooldown(cooldownShares);

        vm.prank(alice);
        IERC20(address(susd3Strategy)).transfer(charlie, liquidShares);

        vm.prank(alice);
        vm.expectRevert("sUSD3: Cannot transfer shares in cooldown");
        IERC20(address(susd3Strategy)).transfer(charlie, 1);
    }

    function test_susd3TransfersAfterLockCanEnterFreshCooldown() public {
        _depositSusd3(alice, 1000e6, 100e6);
        skip(90 days);

        uint256 shares = IERC20(address(susd3Strategy)).balanceOf(alice);

        vm.prank(alice);
        IERC20(address(susd3Strategy)).transfer(bob, shares);

        vm.prank(bob);
        susd3Strategy.startCooldown(shares);

        (,, uint256 cooldownShares) = susd3Strategy.getCooldownStatus(bob);
        assertEq(cooldownShares, shares);
    }

    function _depositUsd3(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(usd3Strategy), amount);
        usd3Strategy.deposit(amount, user);
        vm.stopPrank();
    }

    function _depositSusd3(address user, uint256 usd3Amount, uint256 susd3Amount) internal {
        vm.startPrank(user);
        asset.approve(address(usd3Strategy), usd3Amount);
        usd3Strategy.deposit(usd3Amount, user);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), susd3Amount);
        susd3Strategy.deposit(susd3Amount, user);
        vm.stopPrank();
    }
}
