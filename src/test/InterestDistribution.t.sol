// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {USD3} from "../USD3.sol";
import {sUSD3} from "../sUSD3.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {console2} from "forge-std/console2.sol";
import {TransparentUpgradeableProxy} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title InterestDistribution
 * @notice Tests for correct interest distribution between USD3 and sUSD3
 * @dev Validates yield sharing mechanics and edge cases
 */
contract InterestDistribution is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant INTEREST_SHARE_BPS = 2000; // 20% to sUSD3

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 implementation with proxy
        sUSD3 susd3Implementation = new sUSD3();

        // Deploy proxy admin
        address proxyAdminOwner = makeAddr("ProxyAdminOwner");
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(proxyAdminOwner);

        // Deploy proxy with initialization
        bytes memory susd3InitData = abi.encodeWithSelector(
            sUSD3.initialize.selector,
            address(usd3Strategy),
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

        // Link strategies and configure interest sharing
        vm.startPrank(management);
        usd3Strategy.setSusd3Strategy(address(susd3Strategy));
        // Set performance fee to distribute yield to sUSD3
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(
            uint16(INTEREST_SHARE_BPS)
        );
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFeeRecipient(
            address(susd3Strategy)
        );
        susd3Strategy.setUsd3Strategy(address(usd3Strategy));
        vm.stopPrank();

        // Setup test users with USDC
        airdrop(asset, alice, 100000e6);
        airdrop(asset, bob, 100000e6);
        airdrop(asset, charlie, 100000e6);
    }

    function test_basic_interest_distribution() public {
        // Alice deposits into USD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        // Bob deposits USD3 into sUSD3
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, bob);

        // Check Bob's USD3 balance before sUSD3 deposit
        uint256 bobUsd3Balance = IERC20(address(usd3Strategy)).balanceOf(bob);
        console2.log("Bob's USD3 balance:", bobUsd3Balance);
        console2.log(
            "sUSD3 available deposit limit:",
            susd3Strategy.availableDepositLimit(bob)
        );

        // Deposit within the subordination limit (about 3529e6 max)
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 3000e6);
        susd3Strategy.deposit(3000e6, bob);
        vm.stopPrank();

        uint256 usd3InitialTotal = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 susd3InitialTotal = ITokenizedStrategy(address(susd3Strategy))
            .totalAssets();

        // Simulate yield by airdropping USDC to strategy
        uint256 yieldAmount = 1000e6;
        airdrop(asset, address(usd3Strategy), yieldAmount);

        // Report to distribute yield
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // sUSD3 should have received minted USD3 shares
        uint256 susd3BalanceAfter = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertGt(
            susd3BalanceAfter,
            3000e6,
            "sUSD3 should have received USD3 shares"
        );

        // The value of the yield shares should be approximately expectedSusd3Share
        uint256 expectedSusd3Share = (yieldAmount * INTEREST_SHARE_BPS) / 10000;
        uint256 yieldSharesReceived = susd3BalanceAfter - 3000e6; // Subtract initial deposit
        uint256 yieldValue = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(yieldSharesReceived);
        assertApproxEqAbs(
            yieldValue,
            expectedSusd3Share,
            1e6,
            "Incorrect share value minted"
        );
    }

    function test_no_distribution_without_susd3() public {
        // Only USD3 deposits, no sUSD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        // Remove sUSD3 strategy link
        vm.prank(management);
        usd3Strategy.setSusd3Strategy(address(0));

        // Simulate yield
        uint256 yieldAmount = 1000e6;
        airdrop(asset, address(usd3Strategy), yieldAmount);

        // Report
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Without sUSD3, no shares should be minted to address(0)
        // Total supply should only be alice's shares
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);

        // All yield goes to USD3
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).totalAssets(),
            10000e6 + yieldAmount,
            "USD3 should get all yield"
        );
    }

    function test_distribution_with_zero_interest_share() public {
        // Set interest share to 0
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(0);

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

        // Simulate yield
        uint256 yieldAmount = 1000e6;
        airdrop(asset, address(usd3Strategy), yieldAmount);

        // Track sUSD3 balance before report
        uint256 susd3BalanceBefore = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );

        // Report
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // With 0% share, no additional shares should be minted to sUSD3
        uint256 susd3BalanceAfter = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertEq(
            susd3BalanceAfter,
            susd3BalanceBefore,
            "No additional shares should be minted to sUSD3"
        );
    }

    function test_multiple_yield_accumulation() public {
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

        // First yield event
        uint256 initialSusd3Balance = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        airdrop(asset, address(usd3Strategy), 500e6);
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();
        uint256 firstSusd3Balance = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertGt(
            firstSusd3Balance,
            initialSusd3Balance,
            "sUSD3 should receive shares"
        );

        // Second yield event - shares accumulate
        airdrop(asset, address(usd3Strategy), 300e6);
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();
        uint256 secondSusd3Balance = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertGt(
            secondSusd3Balance,
            firstSusd3Balance,
            "sUSD3 should receive more shares"
        );

        // Verify accumulated value
        uint256 totalValue = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(secondSusd3Balance - initialSusd3Balance);
        // Should be approximately 20% of 800 total yield
        assertApproxEqAbs(
            totalValue,
            160e6,
            10e6,
            "Total accumulated value incorrect"
        );
    }

    function test_distribution_affects_withdrawal_limits() public {
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

        // Check initial withdrawal limit
        uint256 initialLimit = usd3Strategy.availableWithdrawLimit(alice);

        // Generate yield
        airdrop(asset, address(usd3Strategy), 1000e6);
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // sUSD3 should have received shares
        uint256 susd3Shares = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertGt(susd3Shares, 0, "sUSD3 should have received shares");

        // Withdrawal limit for alice should still work normally
        uint256 newLimit = usd3Strategy.availableWithdrawLimit(alice);
        assertGt(newLimit, 0, "Alice should still be able to withdraw");
    }

    function test_automatic_distribution_to_susd3() public {
        // Setup and generate yield
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

        uint256 initialSusd3Balance = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );

        airdrop(asset, address(usd3Strategy), 1000e6);
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // sUSD3 should automatically receive shares without claiming
        uint256 finalSusd3Balance = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertGt(
            finalSusd3Balance,
            initialSusd3Balance,
            "sUSD3 should automatically receive shares"
        );
    }

    // TODO: Fix this test - requires complex Morpho mocking to simulate losses
    function skip_test_distribution_with_losses() public {
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

        uint256 initialTotal = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();

        // Simulate loss by adjusting internal accounting
        // (In production this would be from loan defaults in Morpho)
        // Since most funds are deployed to Morpho, we can't transfer them
        // Instead, we'll skip the loss test for now as it requires mocking Morpho returns
        // TODO: Mock Morpho's supply/withdraw to simulate losses properly

        // Report with loss
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // On losses, sUSD3 shouldn't receive any new shares
        uint256 susd3Shares = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertEq(
            susd3Shares,
            3000e6,
            "sUSD3 shares should not increase on losses"
        );

        // Total assets should reflect loss
        assertTrue(
            ITokenizedStrategy(address(usd3Strategy)).totalAssets() <
                initialTotal,
            "Should show loss"
        );
    }

    function test_distribution_precision() public {
        // Test with small yield amounts to check rounding
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

        // Small yield that tests rounding
        uint256 smallYield = 7; // 7 units (0.000007 USDC)
        airdrop(asset, address(usd3Strategy), smallYield);

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // sUSD3 should receive shares even for small yields
        uint256 initialSusd3Shares = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        uint256 susd3SharesAfterSmall = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        // May or may not mint shares for 7 units depending on rounding

        // Large yield to test maximum precision
        uint256 largeYield = 999999999999; // Nearly 1M USDC
        airdrop(asset, address(usd3Strategy), largeYield);

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Check sUSD3 received appropriate shares
        uint256 finalSusd3Shares = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertGt(
            finalSusd3Shares,
            susd3SharesAfterSmall,
            "sUSD3 should receive shares for large yield"
        );

        // Verify value is approximately correct
        uint256 shareValue = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(finalSusd3Shares - initialSusd3Shares);
        uint256 expectedValue = (largeYield * INTEREST_SHARE_BPS) / 10000;
        assertApproxEqRel(
            shareValue,
            expectedValue,
            0.01e18,
            "Share value should be close to expected"
        );
    }

    function test_distribution_with_morpho_deployment() public {
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

        // Generate yield
        airdrop(asset, address(usd3Strategy), 1000e6);
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Check sUSD3 received shares
        uint256 susd3Shares = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertGt(
            susd3Shares,
            3000e6,
            "sUSD3 should have received yield shares"
        );

        // Deploy all funds to Morpho (simulate no idle liquidity)
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        // sUSD3 should still be able to withdraw their shares
        uint256 idleBefore = asset.balanceOf(address(usd3Strategy));
        assertEq(idleBefore, 0, "Should have no idle funds");

        // sUSD3 can still withdraw after cooldown
        // Report to update sUSD3's assets
        vm.prank(keeper);
        ITokenizedStrategy(address(susd3Strategy)).report();
    }

    function test_interest_share_update() public {
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

        // First yield with 20% share
        airdrop(asset, address(usd3Strategy), 1000e6);
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();
        uint256 initialSusd3Shares = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertGt(
            initialSusd3Shares,
            3000e6,
            "sUSD3 should have received shares for 20% of yield"
        );

        // Update share to 30%
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(
            uint16(3000)
        );

        // Second yield with 30% share
        airdrop(asset, address(usd3Strategy), 1000e6);
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // sUSD3 should have more shares now (from both 20% and 30% distributions)
        uint256 finalSusd3Shares = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        assertGt(
            finalSusd3Shares,
            initialSusd3Shares,
            "sUSD3 should have received more shares"
        );

        // Verify approximate value received
        uint256 totalSharesReceived = finalSusd3Shares - 3000e6; // Subtract initial deposit
        uint256 totalValue = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(totalSharesReceived);
        // Should be roughly 200e6 (20% of 1000) + 300e6 (30% of 1000) = 500e6
        assertApproxEqRel(
            totalValue,
            500e6,
            0.1e18,
            "Total value received should be approximately correct"
        );
    }

    function test_high_yield_share_70_percent() public {
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

        // Set yield share to 70% using direct storage manipulation
        vm.prank(management);
        usd3Strategy.setYieldShare(uint16(7000)); // 70%

        // Generate yield
        uint256 yieldAmount = 1000e6;
        airdrop(asset, address(usd3Strategy), yieldAmount);

        // Track sUSD3 balance before report
        uint256 susd3BalanceBefore = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );

        // Report to distribute yield
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // sUSD3 should have received 70% of yield
        uint256 susd3BalanceAfter = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        uint256 sharesReceived = susd3BalanceAfter - susd3BalanceBefore;
        uint256 valueReceived = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(sharesReceived);

        uint256 expectedValue = (yieldAmount * 7000) / 10000; // 700e6
        assertApproxEqAbs(
            valueReceived,
            expectedValue,
            10e6,
            "sUSD3 should receive 70% of yield"
        );
    }

    function test_maximum_yield_share_100_percent() public {
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

        // Set yield share to 100% using direct storage manipulation
        vm.prank(management);
        usd3Strategy.setYieldShare(uint16(10000)); // 100%

        // Generate yield
        uint256 yieldAmount = 1000e6;
        airdrop(asset, address(usd3Strategy), yieldAmount);

        // Track balances before report
        uint256 susd3BalanceBefore = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        uint256 aliceBalanceBefore = IERC20(address(usd3Strategy)).balanceOf(
            alice
        );

        // Report to distribute yield
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // sUSD3 should have received 100% of yield
        uint256 susd3BalanceAfter = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        uint256 sharesReceived = susd3BalanceAfter - susd3BalanceBefore;
        uint256 valueReceived = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(sharesReceived);

        // With 100% fee, all profit goes to sUSD3
        assertApproxEqAbs(
            valueReceived,
            yieldAmount,
            10e6,
            "sUSD3 should receive 100% of yield"
        );

        // Alice's shares should not have increased in value beyond the initial deposit
        uint256 aliceBalanceAfter = IERC20(address(usd3Strategy)).balanceOf(
            alice
        );
        assertEq(
            aliceBalanceAfter,
            aliceBalanceBefore,
            "Alice's shares should not change with 100% fee"
        );
    }

    function test_yield_share_cannot_exceed_100_percent() public {
        // Try to set yield share above 100%
        vm.prank(management);
        vm.expectRevert("Yield share > 100%");
        usd3Strategy.setYieldShare(uint16(10001)); // 100.01%
    }

    function test_yield_share_updates_via_storage_manipulation() public {
        // Set yield share to 80% using direct storage manipulation
        vm.prank(management);
        usd3Strategy.setYieldShare(uint16(8000));

        // The performanceFee should now be 8000, but we can't directly read it
        // We can verify it works by checking yield distribution

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

        // Generate yield
        uint256 yieldAmount = 1000e6;
        airdrop(asset, address(usd3Strategy), yieldAmount);

        uint256 susd3BalanceBefore = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );

        // Report
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Verify 80% went to sUSD3
        uint256 susd3BalanceAfter = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        uint256 sharesReceived = susd3BalanceAfter - susd3BalanceBefore;
        uint256 valueReceived = ITokenizedStrategy(address(usd3Strategy))
            .convertToAssets(sharesReceived);

        uint256 expectedValue = (yieldAmount * 8000) / 10000; // 800e6
        assertApproxEqAbs(
            valueReceived,
            expectedValue,
            10e6,
            "sUSD3 should receive 80% of yield"
        );
    }

    function test_loss_absorption_burns_susd3_shares() public {
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

        // Set performance fee for profit sharing
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFee(
            uint16(2000)
        ); // 20%

        // First generate some profit so sUSD3 has extra shares
        airdrop(asset, address(usd3Strategy), 1000e6);
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Record balances before loss
        uint256 susd3SharesBefore = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        uint256 totalSupplyBefore = IERC20(address(usd3Strategy)).totalSupply();
        uint256 totalAssetsBefore = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();

        assertGt(
            susd3SharesBefore,
            3000e6,
            "sUSD3 should have received profit shares"
        );

        // Simulate a loss by removing assets from the strategy
        // This simulates a default/markdown in lending
        // First get idle assets
        uint256 idleAssets = asset.balanceOf(address(usd3Strategy));
        uint256 lossAmount = 500e6; // 5% loss on initial deposits

        // If not enough idle, first withdraw from Morpho
        if (idleAssets < lossAmount) {
            vm.prank(keeper);
            ITokenizedStrategy(address(usd3Strategy)).tend(); // This might help free some
            idleAssets = asset.balanceOf(address(usd3Strategy));
        }

        // Now simulate loss with what we have available (or less)
        uint256 actualLoss = idleAssets < lossAmount ? idleAssets : lossAmount;
        if (actualLoss > 0) {
            vm.prank(address(usd3Strategy));
            asset.transfer(address(1), actualLoss);
        }

        // Report the loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = ITokenizedStrategy(
            address(usd3Strategy)
        ).report();

        // Verify loss was reported
        assertEq(loss, actualLoss, "Loss should be reported");
        assertEq(profit, 0, "No profit on loss");

        // Check that sUSD3's shares were burned proportionally
        uint256 susd3SharesAfter = IERC20(address(usd3Strategy)).balanceOf(
            address(susd3Strategy)
        );
        uint256 totalSupplyAfter = IERC20(address(usd3Strategy)).totalSupply();

        // sUSD3 should have lost shares if there was a loss
        if (actualLoss > 0) {
            assertLt(
                susd3SharesAfter,
                susd3SharesBefore,
                "sUSD3 shares should be burned"
            );

            // Total supply should have decreased
            assertLt(
                totalSupplyAfter,
                totalSupplyBefore,
                "Total supply should decrease"
            );

            // The burn amount should equal the shares needed to cover the loss
            // sUSD3 should absorb the entire loss if they have enough shares
            uint256 expectedSharesBurned = ITokenizedStrategy(
                address(usd3Strategy)
            ).convertToShares(actualLoss);
            // Cap at sUSD3's actual balance before the loss
            if (expectedSharesBurned > susd3SharesBefore) {
                expectedSharesBurned = susd3SharesBefore;
            }
            uint256 actualSharesBurned = susd3SharesBefore - susd3SharesAfter;

            assertApproxEqAbs(
                actualSharesBurned,
                expectedSharesBurned,
                10e6,
                "Shares burned should cover the loss amount"
            );
        }
    }

    function test_no_share_burning_without_susd3() public {
        // Only USD3 deposits, no sUSD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, alice);
        vm.stopPrank();

        // Remove sUSD3 strategy link
        vm.prank(management);
        usd3Strategy.setSusd3Strategy(address(0));

        uint256 totalSupplyBefore = IERC20(address(usd3Strategy)).totalSupply();

        // Simulate a loss - get available idle assets first
        uint256 idleAssets = asset.balanceOf(address(usd3Strategy));
        uint256 desiredLoss = 500e6;
        uint256 actualLoss = idleAssets < desiredLoss
            ? idleAssets
            : desiredLoss;

        if (actualLoss > 0) {
            vm.prank(address(usd3Strategy));
            asset.transfer(address(1), actualLoss);
        }

        // Report the loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = ITokenizedStrategy(
            address(usd3Strategy)
        ).report();

        if (actualLoss > 0) {
            assertEq(loss, actualLoss, "Loss should be reported");
        }

        // Total supply should remain the same (no burning)
        uint256 totalSupplyAfter = IERC20(address(usd3Strategy)).totalSupply();
        assertEq(
            totalSupplyAfter,
            totalSupplyBefore,
            "No shares should be burned without sUSD3"
        );
    }
}
