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
import {BaseHooksUpgradeable} from "../../../../src/usd3/base/BaseHooksUpgradeable.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title BaseStrategyCoverage
 * @notice Tests for BaseStrategyUpgradeable and BaseHooksUpgradeable coverage gaps
 * @dev Focuses on 4-parameter withdraw, emergency functions, and hooks
 */
contract BaseStrategyCoverage is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 implementation with proxy
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);

        bytes memory susd3InitData =
            abi.encodeWithSelector(sUSD3.initialize.selector, address(usd3Strategy), management, keeper);

        TransparentUpgradeableProxy susd3Proxy =
            new TransparentUpgradeableProxy(address(susd3Implementation), address(susd3ProxyAdmin), susd3InitData);

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Setup test users
        airdrop(asset, alice, 100000e6);
        airdrop(asset, bob, 100000e6);
    }

    /**
     * @notice Test 4-parameter withdraw function
     * @dev Tests withdraw with custom maxLoss parameter
     */
    function test_withdrawWithMaxLoss() public {
        // Alice deposits USDC to USD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        uint256 shares = usd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        // Test withdraw with different maxLoss values
        uint256 withdrawAmount = 1000e6;

        // Test with 0 maxLoss (no loss tolerance)
        vm.prank(alice);
        uint256 sharesUsed = usd3Strategy.withdraw(
            withdrawAmount,
            alice,
            alice,
            0 // maxLoss = 0 bps
        );
        assertGt(sharesUsed, 0, "Should have used shares for withdrawal");

        // Test with 100 bps (1%) maxLoss
        vm.prank(alice);
        uint256 sharesUsed100bps = usd3Strategy.withdraw(
            withdrawAmount,
            alice,
            alice,
            100 // maxLoss = 100 bps
        );
        assertGt(sharesUsed100bps, 0, "Should have used shares for withdrawal");

        // Test with MAX_BPS (100%) maxLoss
        vm.prank(alice);
        uint256 sharesUsedMax = usd3Strategy.withdraw(
            withdrawAmount,
            alice,
            alice,
            10000 // maxLoss = MAX_BPS
        );
        assertGt(sharesUsedMax, 0, "Should have used shares for withdrawal");

        // Verify alice received assets
        assertGt(asset.balanceOf(alice), 90000e6, "Alice should have received USDC");
    }

    /**
     * @notice Test 4-parameter redeem function
     * @dev Tests redeem with custom maxLoss parameter
     */
    function test_redeemWithMaxLoss() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        uint256 shares = usd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        uint256 redeemShares = shares / 10; // Redeem 10% of shares

        // Test with different maxLoss values
        // With 0 maxLoss
        vm.prank(alice);
        uint256 assetsReceived0 = usd3Strategy.redeem(
            redeemShares,
            alice,
            alice,
            0 // No loss tolerance
        );
        assertGt(assetsReceived0, 0, "Should receive assets");

        // With 500 bps (5%) maxLoss
        vm.prank(alice);
        uint256 assetsReceived500 = usd3Strategy.redeem(redeemShares, alice, alice, 500);
        assertGt(assetsReceived500, 0, "Should receive assets");

        // Verify consistent behavior
        assertApproxEqAbs(
            assetsReceived0,
            assetsReceived500,
            1e6,
            "Should receive similar assets with different maxLoss when no actual loss"
        );
    }

    /**
     * @notice Test emergency withdrawal function
     * @dev Tests _emergencyWithdraw through shutdown process
     */
    function test_emergencyWithdraw() public {
        // Setup: deposit funds
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 50000e6);
        usd3Strategy.deposit(50000e6, alice);
        vm.stopPrank();

        // Deploy funds to Morpho via tend
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        // Verify funds are deployed (idle balance should be low)
        uint256 idleBefore = asset.balanceOf(address(usd3Strategy));
        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy)).totalAssets();
        assertLt(idleBefore, totalAssets / 10, "Most funds should be deployed to Morpho");

        // Shutdown the strategy
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Emergency withdraw should free funds from Morpho
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).emergencyWithdraw(type(uint256).max);

        // Check that funds are now idle (freed from Morpho)
        uint256 idleAfter = asset.balanceOf(address(usd3Strategy));
        assertGt(idleAfter, (totalAssets * 9) / 10, "Most funds should be freed from Morpho");

        // Users can still withdraw after emergency withdrawal
        vm.startPrank(alice);
        uint256 shares = IERC20(address(usd3Strategy)).balanceOf(alice);
        uint256 withdrawn = usd3Strategy.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(withdrawn, 45000e6, "Should be able to withdraw most funds");
    }

    /**
     * @notice Test hooks execution in deposit flow
     * @dev Verifies pre and post deposit hooks are called
     */
    function test_depositHooks() public {
        // For sUSD3, deposit hooks set lock periods
        // First get alice some USD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        usd3Strategy.deposit(5000e6, alice);

        // Check available deposit limit for sUSD3 (15% of total USD3 supply)
        uint256 availableLimit = susd3Strategy.availableDepositLimit(alice);
        uint256 depositAmount = availableLimit > 500e6 ? 500e6 : availableLimit;
        require(depositAmount > 0, "No deposit capacity");

        // Now test sUSD3 deposit hooks
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), depositAmount);

        // Check lock period before deposit
        uint256 lockBefore = susd3Strategy.lockedUntil(alice);

        // Deposit triggers hooks
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);

        // Check lock period was set by pre-deposit hook
        uint256 lockAfter = susd3Strategy.lockedUntil(alice);
        assertGt(lockAfter, lockBefore, "Lock period should be set");
        assertEq(lockAfter, block.timestamp + 90 days, "Lock should be 90 days");

        vm.stopPrank();
    }

    /**
     * @notice Test hooks execution in mint flow
     * @dev Verifies pre and post deposit hooks are called via mint
     */
    function test_mintHooks() public {
        // Get alice some USD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        usd3Strategy.deposit(5000e6, alice);

        // Test sUSD3 mint hooks
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 2000e6);

        // Mint triggers same deposit hooks
        uint256 sharesToMint = 500e6;
        uint256 assets = susd3Strategy.mint(sharesToMint, alice);

        // Verify lock was set
        uint256 lockTime = susd3Strategy.lockedUntil(alice);
        assertEq(lockTime, block.timestamp + 90 days, "Lock should be set via mint");

        vm.stopPrank();
    }

    /**
     * @notice Test hooks execution in withdrawal flow
     * @dev Verifies pre and post withdrawal hooks are called
     */
    function test_withdrawalHooks() public {
        // Setup: Alice deposits USD3 into sUSD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        usd3Strategy.deposit(5000e6, alice);

        // Check available deposit limit and deposit within limit
        uint256 availableLimit = susd3Strategy.availableDepositLimit(alice);
        uint256 depositAmount = availableLimit > 500e6 ? 500e6 : availableLimit;
        require(depositAmount > 0, "No deposit capacity");

        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Fast forward and start cooldown
        skip(91 days);
        vm.prank(alice);
        susd3Strategy.startCooldown(shares);
        skip(8 days);

        // Check cooldown before withdrawal
        (,, uint256 cooldownSharesBefore) = susd3Strategy.getCooldownStatus(alice);
        assertEq(cooldownSharesBefore, shares, "Cooldown should be set");

        // Withdraw triggers hooks - withdraw half of what was deposited
        vm.prank(alice);
        uint256 assets = susd3Strategy.withdraw(depositAmount / 2, alice, alice);

        // Post-withdraw hook should update cooldown
        (,, uint256 cooldownSharesAfter) = susd3Strategy.getCooldownStatus(alice);
        assertLt(cooldownSharesAfter, cooldownSharesBefore, "Cooldown should decrease");
    }

    /**
     * @notice Test transfer hooks
     * @dev Verifies pre and post transfer hooks
     */
    function test_transferHooks() public {
        // Alice gets USD3 shares
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        uint256 shares = usd3Strategy.deposit(5000e6, alice);

        // Transfer to bob via hooks
        bool success = usd3Strategy.transfer(bob, shares / 2);
        assertTrue(success, "Transfer should succeed");

        // Verify balances updated
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), shares / 2, "Bob should receive shares");
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), shares / 2, "Alice should have remaining shares");
        vm.stopPrank();
    }

    /**
     * @notice Test transferFrom hooks
     * @dev Verifies pre and post transferFrom hooks
     */
    function test_transferFromHooks() public {
        // Alice gets USD3 shares
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        uint256 shares = usd3Strategy.deposit(5000e6, alice);

        // Approve bob to transfer
        IERC20(address(usd3Strategy)).approve(bob, shares / 2);
        vm.stopPrank();

        // Bob transfers from alice via hooks
        vm.prank(bob);
        bool success = usd3Strategy.transferFrom(alice, bob, shares / 2);
        assertTrue(success, "TransferFrom should succeed");

        // Verify balances
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), shares / 2, "Bob should receive shares");
    }

    /**
     * @notice Test report hooks
     * @dev Verifies pre and post report hooks
     */
    function test_reportHooks() public {
        // Setup deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, bob);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 3000e6);
        susd3Strategy.deposit(3000e6, bob);
        vm.stopPrank();

        // Generate profit
        airdrop(asset, address(usd3Strategy), 1000e6);

        // Report triggers hooks
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = usd3Strategy.report();

        // Hooks executed: _preReportHook and _postReportHook
        // Post-report hook handles loss absorption
        assertGt(profit, 0, "Should report profit");
        assertEq(loss, 0, "No loss in this scenario");
    }

    /**
     * @notice Test tend trigger
     * @dev Verifies tendTrigger returns correct values
     */
    function test_tendTrigger() public {
        // Setup deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        // Check tend trigger
        (bool shouldTend, bytes memory calldata_) = usd3Strategy.tendTrigger();

        // USD3 implements _tendTrigger based on idle ratio
        if (shouldTend) {
            // Calldata should be for tend function
            assertEq(calldata_.length, 4, "Should have function selector");
        }
    }

    /**
     * @notice Test available deposit limit
     * @dev Verifies availableDepositLimit calculation
     */
    function test_availableDepositLimit() public {
        // For USD3, limit is based on maxOnCredit
        uint256 limit = usd3Strategy.availableDepositLimit(alice);
        assertGt(limit, 0, "Should have deposit limit");

        // Make large deposit
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 50000e6);
        usd3Strategy.deposit(50000e6, alice);
        vm.stopPrank();

        // Limit should still be available
        uint256 limitAfter = usd3Strategy.availableDepositLimit(bob);
        assertGt(limitAfter, 0, "Should still have deposit capacity");
    }

    /**
     * @notice Test available withdraw limit
     * @dev Verifies availableWithdrawLimit calculation
     */
    function test_availableWithdrawLimit() public {
        // Deposit first
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        // Check withdraw limit
        uint256 limit = usd3Strategy.availableWithdrawLimit(alice);
        assertGt(limit, 0, "Should have withdraw limit");

        // Deploy funds to Morpho
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        // Withdraw limit should account for deployed funds
        uint256 limitAfterDeploy = usd3Strategy.availableWithdrawLimit(alice);
        assertGt(limitAfterDeploy, 0, "Should still allow withdrawals");
    }

    /**
     * @notice Test shutdown bypass in sUSD3
     * @dev Verifies shutdown bypasses all withdrawal restrictions
     */
    function test_sUSD3ShutdownBypass() public {
        // Alice deposits USD3 to sUSD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        usd3Strategy.deposit(5000e6, alice);

        // Check available deposit limit and deposit within limit
        uint256 availableLimit = susd3Strategy.availableDepositLimit(alice);
        uint256 depositAmount = availableLimit > 500e6 ? 500e6 : availableLimit;
        require(depositAmount > 0, "No deposit capacity");

        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), depositAmount);
        uint256 shares = susd3Strategy.deposit(depositAmount, alice);
        vm.stopPrank();

        // Without shutdown, withdrawal is restricted
        uint256 limitBeforeShutdown = susd3Strategy.availableWithdrawLimit(alice);
        assertEq(limitBeforeShutdown, 0, "Should be locked");

        // Shutdown sUSD3
        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        // Now withdrawal is unrestricted
        uint256 limitAfterShutdown = susd3Strategy.availableWithdrawLimit(alice);
        assertEq(
            limitAfterShutdown,
            IERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)),
            "Should allow full withdrawal"
        );

        // Can withdraw immediately
        vm.prank(alice);
        uint256 withdrawn = susd3Strategy.redeem(shares, alice, alice);
        assertEq(withdrawn, depositAmount, "Should withdraw full amount");
    }

    /**
     * @notice Test base strategy modifiers
     * @dev Verifies access control modifiers work correctly
     */
    function test_accessControlModifiers() public {
        // Test onlyManagement - sUSD3 is already set so test that it cannot be changed
        address newSusd3 = makeAddr("newSusd3");

        // Non-management cannot set sUSD3
        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.setSUSD3(newSusd3);

        // Even management cannot change it once set (one-time only)
        vm.prank(management);
        vm.expectRevert("sUSD3 already set");
        usd3Strategy.setSUSD3(newSusd3);

        // Test onlyKeepers (syncTrancheShare)
        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.syncTrancheShare();

        vm.prank(keeper);
        usd3Strategy.syncTrancheShare(); // Should succeed

        // Test onlyEmergencyAuthorized (emergencyWithdraw)
        vm.prank(alice);
        vm.expectRevert();
        ITokenizedStrategy(address(usd3Strategy)).emergencyWithdraw(1000e6);

        // Management can call emergency functions
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy(); // Enable emergency
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).emergencyWithdraw(1000e6); // Should succeed
    }
}
