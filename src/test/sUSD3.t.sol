// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {sUSD3} from "../sUSD3.sol";
import {USD3} from "../USD3.sol";
import {ISUSD3} from "../interfaces/ISUSD3.sol";
import {TransparentUpgradeableProxy} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";

contract sUSD3Test is Setup {
    sUSD3 public susd3Strategy;
    USD3 public usd3;
    address public susd3Asset; // USD3 token address
    
    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    
    function setUp() public override {
        super.setUp();
        
        // USD3 is already deployed in Setup as 'strategy'
        usd3 = USD3(address(strategy));
        susd3Asset = address(usd3); // sUSD3's asset is USD3 tokens
        
        // Deploy sUSD3 implementation
        sUSD3 susd3Implementation = new sUSD3();
        
        // Deploy proxy admin
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin();
        
        // Deploy proxy with initialization
        bytes memory susd3InitData = abi.encodeWithSelector(
            sUSD3.initialize.selector,
            susd3Asset,
            "sUSD3",
            management,
            performanceFeeRecipient,
            keeper
        );
        
        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
            address(susd3Implementation),
            address(susd3ProxyAdmin),
            susd3InitData
        );
        
        susd3Strategy = sUSD3(address(susd3Proxy));
        
        // Link USD3 and sUSD3
        vm.prank(management);
        usd3.setSusd3Strategy(address(susd3Strategy));
        
        vm.prank(management);
        susd3Strategy.setUsd3Strategy(address(usd3));
        
        // Give test users some USD3 tokens
        // First give them USDC
        deal(address(underlyingAsset), alice, 10_000e6);
        deal(address(underlyingAsset), bob, 10_000e6);
        
        // Have them deposit to get USD3
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3), type(uint256).max);
        usd3.deposit(5_000e6, alice);
        vm.stopPrank();
        
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3), type(uint256).max);
        usd3.deposit(5_000e6, bob);
        vm.stopPrank();
        
        // Label addresses
        vm.label(address(susd3Strategy), "sUSD3");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
    }
    
    /*//////////////////////////////////////////////////////////////
                            BASIC TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_initialization() public {
        assertEq(address(susd3Strategy.asset()), susd3Asset);
        assertEq(susd3Strategy.symbol(), "sUSD3");
        assertEq(IStrategyInterface(address(susd3Strategy)).management(), management);
        assertEq(IStrategyInterface(address(susd3Strategy)).keeper(), keeper);
        assertEq(IStrategyInterface(address(susd3Strategy)).performanceFeeRecipient(), performanceFeeRecipient);
        
        // Check default durations
        assertEq(susd3Strategy.lockDuration(), 90 days);
        assertEq(susd3Strategy.cooldownDuration(), 7 days);
        assertEq(susd3Strategy.withdrawalWindow(), 2 days);
    }
    
    function test_deposit() public {
        uint256 depositAmount = 100e6; // 100 USD3
        
        // Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Check balances
        assertEq(ERC20(address(susd3Strategy)).balanceOf(alice), shares);
        assertEq(ERC20(address(usd3)).balanceOf(address(susd3Strategy)), depositAmount);
        
        // Check lock period was set
        assertEq(susd3Strategy.lockedUntil(alice), block.timestamp + 90 days);
    }
    
    /*//////////////////////////////////////////////////////////////
                        COOLDOWN TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_startCooldown_success() public {
        // Setup: Alice deposits
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Fast forward past lock period
        skip(91 days);
        
        // Start cooldown
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);
        
        // Check cooldown state
        (uint256 cooldownEnd, uint256 windowEnd, uint256 cooldownShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownEnd, block.timestamp + 7 days);
        assertEq(windowEnd, block.timestamp + 7 days + 2 days);
        assertEq(cooldownShares, shares);
    }
    
    function test_startCooldown_stillLocked() public {
        // Setup: Alice deposits
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Try to start cooldown immediately (still locked)
        vm.prank(alice);
        vm.expectRevert("Still in lock period");
        susd3Strategy.startCooldown(depositAmount);
    }
    
    function test_startCooldown_partialAmount() public {
        // Setup: Alice deposits
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Fast forward past lock period
        skip(91 days);
        
        // Start cooldown for half the shares
        uint256 cooldownAmount = shares / 2;
        vm.prank(alice);
        susd3Strategy.startCooldown(cooldownAmount);
        
        // Check cooldown state
        (, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownShares, cooldownAmount);
    }
    
    function test_startCooldown_overwritePrevious() public {
        // Setup: Alice deposits
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Fast forward past lock period
        skip(91 days);
        
        // Start first cooldown
        vm.prank(alice);
        susd3Strategy.startCooldown(shares / 2);
        
        // Start second cooldown (overwrites first)
        skip(3 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);
        
        // Check cooldown state - should be the new one
        (uint256 cooldownEnd, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownEnd, block.timestamp + 7 days);
        assertEq(cooldownShares, shares);
    }
    
    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_withdraw_success() public {
        // Setup: Alice deposits
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Fast forward past lock period
        skip(91 days);
        
        // Start cooldown
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);
        
        // Fast forward past cooldown
        skip(7 days + 1);
        
        // Withdraw
        uint256 balanceBefore = ERC20(address(usd3)).balanceOf(alice);
        vm.prank(alice);
        uint256 assets = susd3Strategy.withdraw();
        
        // Check results
        assertEq(ERC20(address(susd3Strategy)).balanceOf(alice), 0);
        assertGt(ERC20(address(usd3)).balanceOf(alice), balanceBefore);
        assertEq(assets, depositAmount); // Should get back full amount
        
        // Check cooldown cleared
        (, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownShares, 0);
    }
    
    function test_withdraw_stillCoolingDown() public {
        // Setup: Alice deposits and starts cooldown
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        skip(91 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(depositAmount);
        
        // Try to withdraw before cooldown ends
        skip(6 days); // Not enough
        vm.prank(alice);
        vm.expectRevert("Still cooling down");
        susd3Strategy.withdraw();
    }
    
    function test_withdraw_windowExpired() public {
        // Setup: Alice deposits and starts cooldown
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        skip(91 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);
        
        // Fast forward past window
        skip(10 days); // Past 7 day cooldown + 2 day window
        vm.prank(alice);
        vm.expectRevert("Withdrawal window expired");
        susd3Strategy.withdraw();
    }
    
    function test_withdraw_noCooldown() public {
        vm.prank(alice);
        vm.expectRevert("No active cooldown");
        susd3Strategy.withdraw();
    }
    
    /*//////////////////////////////////////////////////////////////
                    SUBORDINATION RATIO TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_subordinationRatio_enforcement() public {
        // First have alice deposit a large amount to USD3
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3), type(uint256).max);
        usd3.deposit(4_000e6, alice); // Total USD3: 9000e6
        vm.stopPrank();
        
        // Now try to deposit to sUSD3 to exceed 15% ratio
        // Current: USD3 = 9000e6, sUSD3 = 0
        // Max sUSD3 allowed = 9000 * 0.15 / 0.85 = ~1588e6
        
        uint256 maxDeposit = susd3Strategy.availableDepositLimit(bob);
        console2.log("Max deposit allowed:", maxDeposit);
        
        // Deposit close to limit
        vm.startPrank(bob);
        ERC20(address(usd3)).approve(address(susd3Strategy), maxDeposit);
        susd3Strategy.deposit(maxDeposit, bob);
        vm.stopPrank();
        
        // Now available deposit should be limited
        uint256 remainingLimit = susd3Strategy.availableDepositLimit(alice);
        console2.log("Remaining deposit limit:", remainingLimit);
        
        // The exact limit depends on share price conversion, but it should be much less than the initial max
        assertLt(remainingLimit, maxDeposit / 5); // Less than 20% of initial max
    }
    
    /*//////////////////////////////////////////////////////////////
                        MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_setParameters() public {
        // Set lock duration
        vm.prank(management);
        susd3Strategy.setLockDuration(60 days);
        assertEq(susd3Strategy.lockDuration(), 60 days);
        
        // Set cooldown duration
        vm.prank(management);
        susd3Strategy.setCooldownDuration(14 days);
        assertEq(susd3Strategy.cooldownDuration(), 14 days);
        
        // Set withdrawal window
        vm.prank(management);
        susd3Strategy.setWithdrawalWindow(3 days);
        assertEq(susd3Strategy.withdrawalWindow(), 3 days);
    }
    
    function test_setParameters_invalidValues() public {
        // Lock duration too long
        vm.prank(management);
        vm.expectRevert("Lock too long");
        susd3Strategy.setLockDuration(366 days);
        
        // Cooldown too long
        vm.prank(management);
        vm.expectRevert("Cooldown too long");
        susd3Strategy.setCooldownDuration(31 days);
        
        // Window too short
        vm.prank(management);
        vm.expectRevert("Invalid window");
        susd3Strategy.setWithdrawalWindow(12 hours);
        
        // Window too long
        vm.prank(management);
        vm.expectRevert("Invalid window");
        susd3Strategy.setWithdrawalWindow(8 days);
    }
    
    function test_onlyManagement() public {
        vm.prank(alice);
        vm.expectRevert();
        susd3Strategy.setLockDuration(60 days);
        
        vm.prank(alice);
        vm.expectRevert();
        susd3Strategy.setUsd3Strategy(address(0));
    }
    
    /*//////////////////////////////////////////////////////////////
                        LOSS ABSORPTION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_absorbLoss() public {
        uint256 lossAmount = 100e6;
        
        vm.prank(keeper);
        susd3Strategy.absorbLoss(lossAmount);
        
        assertEq(susd3Strategy.totalLossesAbsorbed(), lossAmount);
        assertEq(susd3Strategy.lastLossTime(), block.timestamp);
    }
    
    function test_absorbLoss_onlyKeeper() public {
        vm.prank(alice);
        vm.expectRevert();
        susd3Strategy.absorbLoss(100e6);
    }
    
    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_cancelCooldown() public {
        // Setup: Alice deposits and starts cooldown
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        skip(91 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);
        
        // Cancel cooldown
        vm.prank(alice);
        susd3Strategy.cancelCooldown();
        
        // Check cooldown cleared
        (, , uint256 cooldownShares) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownShares, 0);
        
        // Cannot withdraw anymore
        vm.prank(alice);
        vm.expectRevert("No active cooldown");
        susd3Strategy.withdraw();
    }
    
    function test_availableWithdrawLimit_withCooldown() public {
        // Setup: Alice deposits
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();
        
        // Before cooldown - should return max
        uint256 limitBefore = susd3Strategy.availableWithdrawLimit(alice);
        assertEq(limitBefore, type(uint256).max);
        
        // Start cooldown
        skip(91 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(depositAmount);
        
        // During cooldown - should return 0
        uint256 limitDuring = susd3Strategy.availableWithdrawLimit(alice);
        assertEq(limitDuring, 0);
    }
    
    function test_multipleUsers() public {
        // Check balances first
        uint256 aliceBalance = ERC20(address(usd3)).balanceOf(alice);
        uint256 bobBalance = ERC20(address(usd3)).balanceOf(bob);
        console2.log("Alice USD3 balance:", aliceBalance);
        console2.log("Bob USD3 balance:", bobBalance);
        
        // Deposit smaller amounts to avoid hitting subordination ratio and ensure they have enough
        uint256 aliceDeposit = aliceBalance > 100e6 ? 100e6 : aliceBalance;
        uint256 bobDeposit = bobBalance > 200e6 ? 200e6 : bobBalance;
        
        require(aliceDeposit > 0 && bobDeposit > 0, "Test users need USD3 balance");
        
        // Both users deposit their USD3
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), aliceDeposit);
        susd3Strategy.deposit(aliceDeposit, alice);
        vm.stopPrank();
        
        vm.startPrank(bob);
        ERC20(address(usd3)).approve(address(susd3Strategy), bobDeposit);
        susd3Strategy.deposit(bobDeposit, bob);
        vm.stopPrank();
        
        // Fast forward and both start cooldowns
        skip(91 days);
        
        // Get their sUSD3 shares
        uint256 aliceShares = ERC20(address(susd3Strategy)).balanceOf(alice);
        uint256 bobShares = ERC20(address(susd3Strategy)).balanceOf(bob);
        
        assertGt(aliceShares, 0, "Alice should have shares");
        assertGt(bobShares, 0, "Bob should have shares");
        
        vm.prank(alice);
        susd3Strategy.startCooldown(aliceShares);
        
        vm.prank(bob);
        susd3Strategy.startCooldown(bobShares);
        
        // Check both have independent cooldowns
        (, , uint256 aliceCooldownShares) = susd3Strategy.getCooldownStatus(alice);
        (, , uint256 bobCooldownShares) = susd3Strategy.getCooldownStatus(bob);
        
        assertEq(aliceCooldownShares, aliceShares);
        assertEq(bobCooldownShares, bobShares);
        assertNotEq(aliceShares, bobShares, "Different deposits should result in different shares");
    }
}