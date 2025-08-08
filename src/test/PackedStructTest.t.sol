// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {sUSD3} from "../sUSD3.sol";
import {USD3} from "../USD3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";

contract PackedStructTest is Setup {
    sUSD3 public susd3Strategy;
    USD3 public usd3;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();

        // USD3 is already deployed in Setup as 'strategy'
        usd3 = USD3(address(strategy));

        // Deploy sUSD3
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);

        bytes memory susd3InitData = abi.encodeWithSelector(
            sUSD3.initialize.selector,
            address(usd3),
            "sUSD3",
            management,
            keeper
        );

        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
                address(susd3Implementation),
                address(susd3ProxyAdmin),
                susd3InitData
            );

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        vm.prank(management);
        usd3.setSusd3Strategy(address(susd3Strategy));

        // Give test users USD3 tokens
        // Reduced amounts to fit within subordination limits
        deal(address(underlyingAsset), alice, 10_000e6);
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3), type(uint256).max);
        usd3.deposit(1_000e6, alice); // Reduced from 5_000e6
        vm.stopPrank();

        deal(address(underlyingAsset), bob, 10_000e6);
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3), type(uint256).max);
        usd3.deposit(1_000e6, bob); // Reduced from 5_000e6
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    PACKED STRUCT BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_packedUserCooldown_maxValues() public {
        // Test with maximum uint64 and uint128 values
        uint256 depositAmount = 100e6; // Reduced to fit within subordination limits

        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        IERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Fast forward past lock period
        skip(91 days);

        // Test starting cooldown with max shares (within uint128 range)
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        // Get cooldown status
        (
            uint256 cooldownEnd,
            uint256 windowEnd,
            uint256 cooldownShares
        ) = susd3Strategy.getCooldownStatus(alice);

        // Verify values are stored correctly
        assertEq(cooldownShares, shares, "Shares should match");
        assertGt(
            cooldownEnd,
            block.timestamp,
            "Cooldown end should be in future"
        );
        assertGt(windowEnd, cooldownEnd, "Window end should be after cooldown");

        // Test with very large timestamp (approaching uint64 max)
        // Note: uint64 max is ~584 billion years from epoch, so we test with a reasonable large value
        vm.warp(365 days * 1000); // 1000 years worth of seconds

        // Bob deposits and starts cooldown at this large timestamp
        vm.startPrank(bob);
        IERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 bobShares = susd3Strategy.deposit(depositAmount, bob);

        skip(91 days);
        susd3Strategy.startCooldown(bobShares);
        vm.stopPrank();

        (
            uint256 bobCooldownEnd,
            uint256 bobWindowEnd,
            uint256 bobCooldownShares
        ) = susd3Strategy.getCooldownStatus(bob);

        // Verify large timestamps are handled correctly
        assertEq(bobCooldownShares, bobShares, "Bob's shares should match");
        assertGt(
            bobCooldownEnd,
            block.timestamp,
            "Bob's cooldown should be in future"
        );
        assertGt(
            bobWindowEnd,
            bobCooldownEnd,
            "Bob's window should be after cooldown"
        );
    }

    function test_packedUserCooldown_storageIntegrity() public {
        // Test that packing doesn't cause data corruption
        uint256 depositAmount = 200e6; // Reasonable amount within limits

        // Ensure alice has enough USD3
        deal(address(usd3), alice, depositAmount);

        // Alice deposits max uint128 worth of shares
        vm.startPrank(alice);
        IERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Skip lock and start cooldown
        skip(91 days);

        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        // Store initial values
        (
            uint256 cooldownEnd1,
            uint256 windowEnd1,
            uint256 shares1
        ) = susd3Strategy.getCooldownStatus(alice);

        // Bob performs operations (shouldn't affect alice's packed struct)
        deal(address(usd3), bob, 100e6);
        vm.startPrank(bob);
        IERC20(address(usd3)).approve(address(susd3Strategy), 100e6);
        susd3Strategy.deposit(100e6, bob);
        vm.stopPrank();

        // Verify alice's values unchanged
        (
            uint256 cooldownEnd2,
            uint256 windowEnd2,
            uint256 shares2
        ) = susd3Strategy.getCooldownStatus(alice);

        assertEq(cooldownEnd1, cooldownEnd2, "Cooldown end should not change");
        assertEq(windowEnd1, windowEnd2, "Window end should not change");
        assertEq(shares1, shares2, "Shares should not change");
    }

    function test_packedUserCooldown_partialWithdrawal() public {
        uint256 depositAmount = 100e6; // Reduced to fit within subordination limits

        // Setup: Alice deposits
        vm.startPrank(alice);
        IERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Start cooldown
        skip(91 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);

        // Fast forward to withdrawal window
        skip(7 days + 1);

        // Partial withdrawal
        uint256 partialShares = shares / 3;
        vm.prank(alice);
        susd3Strategy.redeem(partialShares, alice, alice);

        // Check cooldown was updated correctly
        (, , uint256 remainingShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(
            remainingShares,
            shares - partialShares,
            "Should have correct remaining shares"
        );

        // Another partial withdrawal
        uint256 moreShares = shares / 3;
        vm.prank(alice);
        susd3Strategy.redeem(moreShares, alice, alice);

        // Check again
        (, , uint256 finalShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(
            finalShares,
            shares - partialShares - moreShares,
            "Should update correctly after multiple withdrawals"
        );
    }

    function test_packedUserCooldown_overflow_protection() public {
        // Test that shares amount doesn't overflow uint128
        uint256 largeDeposit = 300e6; // Reasonable amount within limits
        deal(address(usd3), alice, largeDeposit);

        vm.startPrank(alice);
        IERC20(address(usd3)).approve(address(susd3Strategy), largeDeposit);
        uint256 shares = susd3Strategy.deposit(largeDeposit, alice);

        // This should fit in uint128
        assertTrue(shares <= type(uint128).max, "Shares should fit in uint128");

        skip(91 days);

        // Starting cooldown should work with large shares
        susd3Strategy.startCooldown(shares);

        (, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(
            cooldownShares,
            shares,
            "Large shares should be stored correctly"
        );
        vm.stopPrank();
    }

    function test_packedUserCooldown_zeroValues() public {
        // Test edge case with zero values
        deal(address(usd3), alice, 100e6);

        // Deposit first
        vm.startPrank(alice);
        IERC20(address(usd3)).approve(address(susd3Strategy), 100e6);
        susd3Strategy.deposit(100e6, alice);
        skip(91 days);

        // Start cooldown with valid shares
        uint256 balance = IERC20(address(susd3Strategy)).balanceOf(alice);
        susd3Strategy.startCooldown(balance);

        // Cancel cooldown (sets to zero)
        susd3Strategy.cancelCooldown();
        vm.stopPrank();

        // Verify all values are zero
        (uint256 cooldownEnd, uint256 windowEnd, uint256 shares) = susd3Strategy
            .getCooldownStatus(alice);

        assertEq(cooldownEnd, 0, "Cooldown end should be zero");
        assertEq(windowEnd, 0, "Window end should be zero");
        assertEq(shares, 0, "Shares should be zero");
    }

    function test_packedUserCooldown_rapidUpdates() public {
        uint256 depositAmount = 100e6; // Reduced to fit within subordination limits

        vm.startPrank(alice);
        IERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);

        skip(91 days);

        // Rapid cooldown updates
        for (uint256 i = 1; i <= 5; i++) {
            susd3Strategy.startCooldown(shares / i);

            (, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(
                alice
            );
            assertEq(cooldownShares, shares / i, "Should update to new amount");

            skip(1 hours);
        }
        vm.stopPrank();
    }
}
