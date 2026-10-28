// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title TransferRestrictionEdgeCases
 * @notice Tests live USD3 transfer behavior and sUSD3 transfer restrictions.
 */
contract TransferRestrictionEdgeCases is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

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

        airdrop(asset, alice, 10000e6);
        airdrop(asset, bob, 10000e6);
        airdrop(asset, charlie, 10000e6);
    }

    function test_usd3_transferAndTransferFromAfterDeposit() public {
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        IERC20(address(usd3Strategy)).transfer(bob, 250e6);
        IERC20(address(usd3Strategy)).approve(bob, 250e6);
        vm.stopPrank();

        vm.prank(bob);
        IERC20(address(usd3Strategy)).transferFrom(alice, charlie, 250e6);

        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 500e6);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 250e6);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(charlie), 250e6);
    }

    function test_usd3_zeroAndSelfTransfers() public {
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        IERC20(address(usd3Strategy)).transfer(bob, 0);
        IERC20(address(usd3Strategy)).transfer(alice, 100e6);
        vm.stopPrank();

        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 1000e6);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 0);
    }

    function test_usd3_transferDuringShutdown() public {
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, 1000e6);

        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 1000e6);
    }

    function test_susd3_transferBlockedDuringLockAndAllowedAfterExpiry() public {
        _depositSusd3(alice, 1000e6, 100e6);
        uint256 aliceSusd3Shares = IERC20(address(susd3Strategy)).balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert("sUSD3: Cannot transfer during lock period");
        IERC20(address(susd3Strategy)).transfer(bob, aliceSusd3Shares);

        skip(90 days);

        vm.prank(alice);
        IERC20(address(susd3Strategy)).transfer(bob, aliceSusd3Shares);

        assertEq(IERC20(address(susd3Strategy)).balanceOf(bob), aliceSusd3Shares);
    }

    function test_susd3_cooldownSharesBoundary() public {
        _depositSusd3(alice, 1000e6, 100e6);
        skip(90 days);

        vm.startPrank(alice);
        uint256 totalShares = IERC20(address(susd3Strategy)).balanceOf(alice);
        susd3Strategy.startCooldown(totalShares / 2);

        IERC20(address(susd3Strategy)).transfer(bob, totalShares / 2);

        vm.expectRevert("sUSD3: Cannot transfer shares in cooldown");
        IERC20(address(susd3Strategy)).transfer(bob, 1);
        vm.stopPrank();
    }

    function test_susd3_thirdPartyDepositBlockedByDefault() public {
        _depositUsd3(alice, 1000e6);

        vm.startPrank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, 100e6);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 1e6);
        vm.expectRevert("sUSD3: Only self or whitelisted deposits allowed");
        susd3Strategy.deposit(1e6, alice);
        vm.stopPrank();
    }

    function test_cannotBypassMinimumDeposit() public {
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        vm.expectRevert(bytes("<min"));
        usd3Strategy.deposit(50e6, alice);

        uint256 sharesToMint = ITokenizedStrategy(address(usd3Strategy)).previewDeposit(50e6);
        vm.expectRevert(bytes("<min"));
        usd3Strategy.mint(sharesToMint, alice);

        usd3Strategy.deposit(100e6, alice);
        uint256 shares = usd3Strategy.deposit(10e6, alice);
        vm.stopPrank();

        assertGt(shares, 0, "subsequent deposits allow any amount");
    }

    function test_noReentrancyDuringTransferHook() public {
        ReentrantReceiver reentrant = new ReentrantReceiver(address(usd3Strategy));

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        IERC20(address(usd3Strategy)).transfer(address(reentrant), 100e6);
        vm.stopPrank();

        assertEq(IERC20(address(usd3Strategy)).balanceOf(address(reentrant)), 100e6);
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

/**
 * @notice Reentrant receiver contract
 */
contract ReentrantReceiver {
    address public immutable token;
    bool public reentered;

    constructor(address _token) {
        token = _token;
    }

    function onERC20Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!reentered) {
            reentered = true;
            try IERC20(token).transfer(msg.sender, 1) {} catch {}
        }
        return this.onERC20Received.selector;
    }
}
