// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IUSD3} from "./utils/Setup.sol";
import {sUSD3} from "../sUSD3.sol";
import {USD3} from "../USD3.sol";
import {ISUSD3} from "../interfaces/ISUSD3.sol";
import {TransparentUpgradeableProxy} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {MockProtocolConfig} from "./mocks/MockProtocolConfig.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";
import {MarketParams, Id} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@3jane-morpho-blue/libraries/MarketParamsLib.sol";

contract sUSD3Test is Setup {
    using MarketParamsLib for MarketParams;

    sUSD3 public susd3Strategy;
    USD3 public usd3;
    address public susd3Asset; // USD3 token address
    address public morpho;
    MarketParams public marketParams;

    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();

        // USD3 is already deployed in Setup as 'strategy'
        usd3 = USD3(address(strategy));
        susd3Asset = address(usd3); // sUSD3's asset is USD3 tokens

        // Get morpho and market params from USD3
        morpho = address(usd3.morphoCredit());
        marketParams = usd3.marketParams();

        // Deploy sUSD3 implementation
        sUSD3 susd3Implementation = new sUSD3();

        // Deploy proxy admin
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);

        // Deploy proxy with initialization
        bytes memory susd3InitData = abi.encodeWithSelector(
            sUSD3.initialize.selector,
            susd3Asset,
            management,
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
        usd3.setSUSD3(address(susd3Strategy));

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
        assertEq(IUSD3(address(susd3Strategy)).asset(), susd3Asset);
        assertEq(susd3Strategy.symbol(), "sUSD3");
        assertEq(IUSD3(address(susd3Strategy)).management(), management);
        assertEq(IUSD3(address(susd3Strategy)).keeper(), keeper);
        assertEq(
            IUSD3(address(susd3Strategy)).performanceFeeRecipient(),
            management
        );

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
        assertEq(
            ERC20(address(usd3)).balanceOf(address(susd3Strategy)),
            depositAmount
        );

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
        (
            uint256 cooldownEnd,
            uint256 windowEnd,
            uint256 cooldownShares
        ) = susd3Strategy.getCooldownStatus(alice);
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
        (uint256 cooldownEnd, , uint256 cooldownShares) = susd3Strategy
            .getCooldownStatus(alice);
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

        // Withdraw using standard redeem function
        uint256 balanceBefore = ERC20(address(usd3)).balanceOf(alice);
        vm.prank(alice);
        uint256 assets = susd3Strategy.redeem(shares, alice, alice);

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
        vm.expectRevert(); // Will revert due to availableWithdrawLimit returning 0
        susd3Strategy.redeem(depositAmount, alice, alice);
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
        vm.expectRevert(); // Will revert due to availableWithdrawLimit returning 0
        susd3Strategy.redeem(depositAmount, alice, alice);
    }

    function test_withdraw_noCooldown() public {
        // Without a cooldown, availableWithdrawLimit returns 0, so withdraw will revert
        // Setup: Alice deposits some of her USD3 into sUSD3
        uint256 depositAmount = 1000e6; // 1000 USD3 (with 6 decimals like USDC)
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Try to withdraw without starting cooldown
        vm.prank(alice);
        vm.expectRevert(); // Will revert due to availableWithdrawLimit returning 0
        susd3Strategy.withdraw(depositAmount, alice, alice);
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
        // Get protocol config to set lock and cooldown durations
        address morphoAddress = address(usd3.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        MockProtocolConfig protocolConfig = MockProtocolConfig(
            protocolConfigAddress
        );

        // Set lock duration via protocol config
        bytes32 SUSD3_LOCK_DURATION = keccak256("SUSD3_LOCK_DURATION");
        protocolConfig.setConfig(SUSD3_LOCK_DURATION, 60 days);
        assertEq(susd3Strategy.lockDuration(), 60 days);

        // Set cooldown duration via protocol config
        bytes32 SUSD3_COOLDOWN_PERIOD = keccak256("SUSD3_COOLDOWN_PERIOD");
        protocolConfig.setConfig(SUSD3_COOLDOWN_PERIOD, 14 days);
        assertEq(susd3Strategy.cooldownDuration(), 14 days);

        // Set withdrawal window via protocol config
        bytes32 SUSD3_WITHDRAWAL_WINDOW = keccak256("SUSD3_WITHDRAWAL_WINDOW");
        protocolConfig.setConfig(SUSD3_WITHDRAWAL_WINDOW, 3 days);
        assertEq(susd3Strategy.withdrawalWindow(), 3 days);
    }

    function test_setParameters_invalidValues() public {
        // Get protocol config
        address morphoAddress = address(usd3.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        MockProtocolConfig protocolConfig = MockProtocolConfig(
            protocolConfigAddress
        );

        // Test that extreme values can be set in protocol config (validation is elsewhere)
        // Set very long lock duration - will be read directly
        bytes32 SUSD3_LOCK_DURATION = keccak256("SUSD3_LOCK_DURATION");
        protocolConfig.setConfig(SUSD3_LOCK_DURATION, 366 days);
        assertEq(susd3Strategy.lockDuration(), 366 days);

        // Set very long cooldown - will be read directly
        bytes32 SUSD3_COOLDOWN_PERIOD = keccak256("SUSD3_COOLDOWN_PERIOD");
        protocolConfig.setConfig(SUSD3_COOLDOWN_PERIOD, 31 days);
        assertEq(susd3Strategy.cooldownDuration(), 31 days);

        // Withdrawal window validation now handled by ProtocolConfig
        // Tests for validation would be done at ProtocolConfig level
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

        // Cannot withdraw anymore (availableWithdrawLimit will return 0)
        vm.prank(alice);
        vm.expectRevert(); // Will revert due to availableWithdrawLimit returning 0
        susd3Strategy.withdraw(depositAmount, alice, alice);
    }

    function test_availableWithdrawLimit_withCooldown() public {
        // Setup: Alice deposits
        uint256 depositAmount = 100e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Before cooldown - should return 0 (no cooldown started)
        uint256 limitBefore = susd3Strategy.availableWithdrawLimit(alice);
        assertEq(limitBefore, 0);

        // Start cooldown
        skip(91 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(depositAmount);

        // During cooldown - should still return 0
        uint256 limitDuring = susd3Strategy.availableWithdrawLimit(alice);
        assertEq(limitDuring, 0);

        // After cooldown - should return the withdrawable amount
        skip(7 days + 1);
        uint256 limitAfter = susd3Strategy.availableWithdrawLimit(alice);
        assertEq(limitAfter, depositAmount);
    }

    function test_subsequentDepositsExtendLock() public {
        // First deposit sets initial lock
        uint256 firstDeposit = 500e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), type(uint256).max);
        susd3Strategy.deposit(firstDeposit, alice);

        uint256 firstLock = susd3Strategy.lockedUntil(alice);
        assertEq(
            firstLock,
            block.timestamp + 90 days,
            "First lock should be 90 days"
        );

        // Fast forward 30 days
        skip(30 days);

        // Second deposit should extend the lock
        uint256 secondDeposit = 300e6;
        susd3Strategy.deposit(secondDeposit, alice);

        uint256 secondLock = susd3Strategy.lockedUntil(alice);
        assertEq(
            secondLock,
            block.timestamp + 90 days,
            "Lock should be extended to 90 days from now"
        );
        assertGt(
            secondLock,
            firstLock,
            "Second lock should be later than first"
        );

        // Verify cannot withdraw before new lock expires
        vm.expectRevert(); // Still locked
        susd3Strategy.redeem(100e6, alice, alice);

        // Fast forward to after original lock but before new lock
        skip(60 days); // Now 90 days from first deposit, but only 60 from second

        // Still cannot withdraw
        vm.expectRevert(); // Still locked due to extension
        susd3Strategy.redeem(100e6, alice, alice);

        // Fast forward past new lock
        skip(31 days); // Now past 90 days from second deposit

        // Can start cooldown now
        susd3Strategy.startCooldown(100e6);
        vm.stopPrank();
    }

    function test_lockClearedOnFullWithdrawal() public {
        // Deposit and wait for lock
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), type(uint256).max);
        uint256 shares = susd3Strategy.deposit(500e6, alice);

        // Verify lock is set
        uint256 lockTime = susd3Strategy.lockedUntil(alice);
        assertGt(lockTime, 0, "Lock should be set");

        // Fast forward past lock and cooldown
        skip(91 days);
        susd3Strategy.startCooldown(shares);
        skip(8 days);

        // Full withdrawal
        susd3Strategy.redeem(shares, alice, alice);

        // Verify lock is cleared
        assertEq(
            susd3Strategy.lockedUntil(alice),
            0,
            "Lock should be cleared after full withdrawal"
        );
        assertEq(
            ERC20(address(susd3Strategy)).balanceOf(alice),
            0,
            "Balance should be 0"
        );

        // New deposit should set fresh lock
        susd3Strategy.deposit(100e6, alice);
        uint256 newLock = susd3Strategy.lockedUntil(alice);
        assertEq(
            newLock,
            block.timestamp + 90 days,
            "New lock should be 90 days from now"
        );
        vm.stopPrank();
    }

    function test_mintAlsoSetsLockPeriod() public {
        // Verify that using mint() instead of deposit() also sets the lock period
        uint256 sharesToMint = 100e6; // Request 100 shares

        // Alice uses mint instead of deposit
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), type(uint256).max);
        susd3Strategy.mint(sharesToMint, alice);
        vm.stopPrank();

        // Check that lock period was set
        assertGt(
            susd3Strategy.lockedUntil(alice),
            block.timestamp,
            "Lock period should be set via mint"
        );
        assertEq(
            susd3Strategy.lockedUntil(alice),
            block.timestamp + 90 days,
            "Lock should be 90 days"
        );

        // Verify cannot withdraw before lock expires
        vm.prank(alice);
        vm.expectRevert(); // Should fail due to lock
        susd3Strategy.redeem(sharesToMint, alice, alice);

        // Fast forward past lock and verify can withdraw (with cooldown)
        skip(91 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(sharesToMint);

        skip(7 days + 1);
        vm.prank(alice);
        uint256 assets = susd3Strategy.redeem(sharesToMint, alice, alice);
        assertGt(
            assets,
            0,
            "Should be able to withdraw after lock and cooldown"
        );
    }

    function test_partialWithdrawal() public {
        // Setup: Alice deposits
        uint256 depositAmount = 1000e6;
        vm.startPrank(alice);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        uint256 totalShares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Fast forward and start cooldown
        skip(91 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(totalShares);

        // Fast forward past cooldown
        skip(7 days + 1);

        // Withdraw only 30% of shares
        uint256 partialShares = (totalShares * 30) / 100;
        vm.prank(alice);
        uint256 assetsWithdrawn = susd3Strategy.redeem(
            partialShares,
            alice,
            alice
        );

        // Check cooldown still exists with remaining shares
        (, , uint256 remainingCooldownShares) = susd3Strategy.getCooldownStatus(
            alice
        );
        assertEq(
            remainingCooldownShares,
            totalShares - partialShares,
            "Cooldown should have remaining shares"
        );

        // Can withdraw more within same window
        uint256 moreShares = (totalShares * 20) / 100;
        vm.prank(alice);
        susd3Strategy.redeem(moreShares, alice, alice);

        // Check cooldown updated again
        (, , uint256 finalCooldownShares) = susd3Strategy.getCooldownStatus(
            alice
        );
        assertEq(
            finalCooldownShares,
            totalShares - partialShares - moreShares,
            "Cooldown should be reduced"
        );
    }

    function test_subordinationRatio_exactBoundary() public {
        // Test exact 15% subordination ratio boundary

        // Work with existing USD3 supply from setUp (10 billion)
        uint256 existingUsd3 = ERC20(address(usd3)).totalSupply();

        // Calculate max USD3 that sUSD3 can hold (15% of USD3 total supply)
        // Ratio is: sUSD3's USD3 holdings / USD3 totalSupply <= 15%
        uint256 maxSusd3Allowed = (existingUsd3 * 1500) / 10000; // 15% of USD3 supply

        // Get available deposit limit - should be approximately this amount
        uint256 availableLimit = susd3Strategy.availableDepositLimit(bob);
        assertApproxEqAbs(
            availableLimit,
            maxSusd3Allowed,
            10e6,
            "Should allow up to exact ratio"
        );

        // Bob deposits close to the limit (slightly less to avoid hitting exact limit)
        uint256 depositAmount = availableLimit > 10e6
            ? availableLimit - 10e6
            : availableLimit;
        vm.startPrank(bob);
        ERC20(address(usd3)).approve(address(susd3Strategy), depositAmount);
        susd3Strategy.deposit(depositAmount, bob);
        vm.stopPrank();

        // Check we're close to 15% subordination
        // sUSD3's USD3 holdings / USD3 totalSupply
        uint256 usd3Total = ERC20(address(usd3)).totalSupply();
        uint256 susd3Usd3Holdings = ERC20(address(usd3)).balanceOf(
            address(susd3Strategy)
        );

        uint256 actualRatio = (susd3Usd3Holdings * 10000) / usd3Total;
        assertApproxEqAbs(actualRatio, 1500, 100, "Should be close to 15%");

        // Further deposits should be very limited
        uint256 limitAfter = susd3Strategy.availableDepositLimit(alice);
        assertLt(
            limitAfter,
            100e6,
            "Should have very limited deposit capacity left"
        );
    }

    function test_subordinationRatio_afterLoss() public {
        // Test ratio enforcement after sUSD3 absorbs losses

        // Work with existing USD3 supply from setUp
        // Bob deposits some USD3 to sUSD3 (well below limit)
        vm.startPrank(bob);
        ERC20(address(usd3)).approve(address(susd3Strategy), 1000e6);
        susd3Strategy.deposit(1000e6, bob);
        vm.stopPrank();

        // Get initial amounts
        uint256 initialSusd3Balance = ERC20(address(susd3Strategy))
            .totalSupply();
        uint256 usd3Total = ERC20(address(usd3)).totalSupply();

        // Check available deposit limit after sUSD3 deposit
        // Should still have room up to 15% subordination
        uint256 availableLimit = susd3Strategy.availableDepositLimit(alice);
        assertGt(availableLimit, 0, "Should have room for more deposits");

        // In a real loss scenario, sUSD3 shares would be burned via USD3's _postReportHook
        // For this test, we're just verifying the subordination ratio logic
        // The actual loss absorption is tested in LossAbsorptionStress tests

        // Verify current ratio is well below 15%
        uint256 currentRatio = (initialSusd3Balance * 10000) /
            (usd3Total + initialSusd3Balance);
        assertLt(currentRatio, 1500, "Should be below 15% subordination");
    }

    function test_subordinationRatio_zeroSupply() public {
        // Test ratio calculation when starting from zero

        // Note: USD3 already has initial supply from setUp (10 billion)
        uint256 usd3Supply = ERC20(address(usd3)).totalSupply();
        uint256 susd3Supply = ERC20(address(susd3Strategy)).totalSupply();
        assertGt(usd3Supply, 0, "USD3 has initial supply from setUp");
        assertEq(susd3Supply, 0, "sUSD3 should start at zero");

        // Check deposit limit with existing USD3 supply
        uint256 availableLimit = susd3Strategy.availableDepositLimit(alice);
        // With existing USD3 supply, sUSD3 should have a limit
        assertLt(
            availableLimit,
            type(uint256).max,
            "Should have a limit based on USD3 supply"
        );

        // Get a fresh user without USD3
        address charlie = makeAddr("charlie");

        // Give charlie some USDC and deposit to USD3
        deal(address(underlyingAsset), charlie, 1000e6);
        vm.startPrank(charlie);
        underlyingAsset.approve(address(usd3), 1000e6);
        usd3.deposit(1000e6, charlie);
        vm.stopPrank();

        // Check sUSD3 deposit limit after additional USD3 deposit
        uint256 newUsd3Supply = ERC20(address(usd3)).totalSupply();
        uint256 limitAfterDeposit = susd3Strategy.availableDepositLimit(bob);

        // The limit should be based on the 15% subordination ratio
        // sUSD3 can hold max 15% of USD3 total supply
        uint256 maxSusd3 = (newUsd3Supply * 1500) / 10000; // 15% of USD3 supply
        assertApproxEqAbs(
            limitAfterDeposit,
            maxSusd3,
            10e6,
            "Should calculate correct limit based on ratio"
        );
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

        require(
            aliceDeposit > 0 && bobDeposit > 0,
            "Test users need USD3 balance"
        );

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
        (, , uint256 aliceCooldownShares) = susd3Strategy.getCooldownStatus(
            alice
        );
        (, , uint256 bobCooldownShares) = susd3Strategy.getCooldownStatus(bob);

        assertEq(aliceCooldownShares, aliceShares);
        assertEq(bobCooldownShares, bobShares);
        assertNotEq(
            aliceShares,
            bobShares,
            "Different deposits should result in different shares"
        );
    }
}
