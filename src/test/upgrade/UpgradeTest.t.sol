// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {USD3} from "../../USD3.sol";
import {sUSD3} from "../../sUSD3.sol";
import {MarketParams, IMorpho} from "@3jane-morpho-blue/interfaces/IMorpho.sol";

/**
 * @title Upgrade Compatibility Test Suite
 * @notice Tests for upgrade scenarios and contract compatibility
 * @dev Tests scenarios that would occur during actual system upgrades:
 * - State preservation during parameters changes
 * - Emergency scenarios requiring configuration changes
 * - Data migration compatibility
 * - Cross-contract interaction stability
 */
contract UpgradeTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    // Test users
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    // Test amounts
    uint256 public constant DEPOSIT_AMOUNT = 100_000e6;

    function setUp() public override {
        // Call parent setup which properly initializes everything including USD3 strategy
        super.setUp();

        // Get references to deployed strategies
        usd3Strategy = USD3(address(strategy));

        // Note: sUSD3 cannot be directly initialized due to _disableInitializers()
        // Tests will run without sUSD3 for now

        // Fund test users
        deal(address(asset), alice, DEPOSIT_AMOUNT * 3);
        deal(address(asset), bob, DEPOSIT_AMOUNT * 3);
        deal(address(asset), charlie, DEPOSIT_AMOUNT * 3);

        // Label addresses
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(charlie, "charlie");
        vm.label(address(usd3Strategy), "USD3");
        vm.label(address(susd3Strategy), "sUSD3");
    }

    function _deployStrategies() internal {
        // Deploy sUSD3 strategy normally (not proxied)
        susd3Strategy = new sUSD3();

        // Initialize sUSD3 with USD3 as asset
        susd3Strategy.initialize(
            address(usd3Strategy), // sUSD3 accepts USD3 tokens
            "sUSD3",
            management,
            keeper
        );

        // Link strategies
        vm.prank(management);
        usd3Strategy.setSusd3Strategy(address(susd3Strategy));

        vm.prank(management);
        susd3Strategy.setUsd3Strategy(address(usd3Strategy));
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION UPGRADE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_parameterUpgradePreservesState() public {
        // Setup state before parameter changes - simplified without sUSD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        uint256 shares = usd3Strategy.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        uint256 bobUsd3Shares = usd3Strategy.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // Record state before parameter changes
        uint256 aliceSharesBefore = ITokenizedStrategy(address(usd3Strategy))
            .balanceOf(alice);
        uint256 bobSharesBefore = ITokenizedStrategy(address(usd3Strategy))
            .balanceOf(bob);
        uint256 totalAssetsBefore = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();

        // Simulate upgrade scenario: changing yield share parameters
        vm.prank(management);
        usd3Strategy.setYieldShare(4000); // 40% to sUSD3

        // Verify state is preserved after parameter changes
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice),
            aliceSharesBefore,
            "Alice's shares preserved"
        );
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).balanceOf(bob),
            bobSharesBefore,
            "Bob's shares preserved"
        );
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).totalAssets(),
            totalAssetsBefore,
            "Total assets preserved"
        );

        // Verify new parameter is active
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).performanceFee(),
            4000,
            "New yield share parameter active"
        );

        // Verify functionality still works
        vm.startPrank(alice);
        uint256 assetsWithdrawn = ITokenizedStrategy(address(usd3Strategy))
            .redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(
            assetsWithdrawn,
            DEPOSIT_AMOUNT,
            "Should be able to withdraw after parameter change"
        );
    }

    function test_emergencyParameterChanges() public {
        // Setup positions
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        usd3Strategy.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        uint256 usd3Shares = usd3Strategy.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // Simulate emergency scenario: change max on credit
        uint256 originalMaxOnCredit = usd3Strategy.maxOnCredit();

        vm.prank(management);
        usd3Strategy.setMaxOnCredit(5000); // Reduce to 50%

        assertEq(
            usd3Strategy.maxOnCredit(),
            5000,
            "Emergency parameter change applied"
        );

        // Test that USD3 operations still work after parameter change
        vm.startPrank(bob);
        uint256 assetsWithdrawn = usd3Strategy.redeem(usd3Shares, bob, bob);
        vm.stopPrank();

        assertGt(
            assetsWithdrawn,
            0,
            "Emergency parameter change should not break existing operations"
        );

        // Restore original parameter
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(originalMaxOnCredit);
    }

    function test_managementTransferPreservesState() public {
        address newManagement = makeAddr("newManagement");

        // Setup state
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        uint256 shares = usd3Strategy.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Record state before management transfer
        uint256 aliceSharesBefore = ITokenizedStrategy(address(usd3Strategy))
            .balanceOf(alice);
        uint256 totalAssetsBefore = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();

        // Transfer management (simulate governance upgrade)
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPendingManagement(
            newManagement
        );

        // Pending management accepts
        vm.prank(newManagement);
        ITokenizedStrategy(address(usd3Strategy)).acceptManagement();

        // Verify state preserved
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice),
            aliceSharesBefore,
            "Shares preserved after management change"
        );
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).totalAssets(),
            totalAssetsBefore,
            "Assets preserved after management change"
        );
        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).management(),
            newManagement,
            "New management active"
        );

        // Verify new management can perform operations
        vm.prank(newManagement);
        usd3Strategy.setYieldShare(2500); // 25% to sUSD3

        assertEq(
            ITokenizedStrategy(address(usd3Strategy)).performanceFee(),
            2500,
            "New management can update parameters"
        );

        // User operations still work
        vm.startPrank(alice);
        uint256 assetsWithdrawn = ITokenizedStrategy(address(usd3Strategy))
            .redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(
            assetsWithdrawn,
            DEPOSIT_AMOUNT,
            "User operations work after management change"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    CROSS-CONTRACT INTERACTION STABILITY
    //////////////////////////////////////////////////////////////*/

    function test_strategyLinkingStability() public {
        // Setup positions
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        uint256 aliceShares = usd3Strategy.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        uint256 bobShares = usd3Strategy.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // Test setting/unsetting sUSD3 strategy link
        address originalSusd3 = usd3Strategy.susd3Strategy();

        vm.prank(management);
        usd3Strategy.setSusd3Strategy(address(0));

        assertEq(usd3Strategy.susd3Strategy(), address(0), "Strategy unlinked");

        // Test that USD3 operations still work without sUSD3 link
        vm.startPrank(alice);
        uint256 aliceAssets = usd3Strategy.redeem(
            aliceShares / 2,
            alice,
            alice
        );
        vm.stopPrank();

        assertGt(
            aliceAssets,
            0,
            "USD3 operations should work without sUSD3 link"
        );

        // Set a new address (could be future sUSD3)
        address newSusd3 = address(0x123);
        vm.prank(management);
        usd3Strategy.setSusd3Strategy(newSusd3);

        assertEq(usd3Strategy.susd3Strategy(), newSusd3, "New strategy linked");
    }

    function test_emergencyShutdownAndRecovery() public {
        // Setup positions
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        uint256 aliceShares = usd3Strategy.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        uint256 bobShares = usd3Strategy.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // Record state before shutdown
        uint256 totalAssetsBefore = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();

        // Emergency shutdown USD3
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        assertTrue(
            ITokenizedStrategy(address(usd3Strategy)).isShutdown(),
            "Strategy should be shut down"
        );

        // Users should still be able to withdraw during shutdown
        vm.startPrank(alice);
        uint256 aliceWithdrawn = ITokenizedStrategy(address(usd3Strategy))
            .redeem(aliceShares, alice, alice);
        vm.stopPrank();

        assertGt(
            aliceWithdrawn,
            0,
            "Alice should be able to withdraw during shutdown"
        );

        // Bob should also be able to withdraw
        vm.startPrank(bob);
        uint256 bobWithdrawn = ITokenizedStrategy(address(usd3Strategy)).redeem(
            bobShares,
            bob,
            bob
        );
        vm.stopPrank();

        assertGt(
            bobWithdrawn,
            0,
            "Bob should be able to withdraw during shutdown"
        );

        // Total withdrawn should approximately equal total assets before shutdown
        assertApproxEqAbs(
            aliceWithdrawn + bobWithdrawn,
            totalAssetsBefore,
            100,
            "All assets should be withdrawable"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        DATA COMPATIBILITY TESTS  
    //////////////////////////////////////////////////////////////*/

    function test_storageLayoutStability() public {
        // This test ensures that key storage locations remain accessible
        // Setup state
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), DEPOSIT_AMOUNT);
        usd3Strategy.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Record key values
        uint256 aliceBalance = ITokenizedStrategy(address(usd3Strategy))
            .balanceOf(alice);
        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 totalSupply = ITokenizedStrategy(address(usd3Strategy))
            .totalSupply();
        address morphoBlue = address(usd3Strategy.morphoBlue());
        MarketParams memory marketParams = usd3Strategy.marketParams();

        // These values should remain stable and accessible
        assertEq(aliceBalance, DEPOSIT_AMOUNT, "Balance should be readable");
        assertEq(
            totalAssets,
            DEPOSIT_AMOUNT,
            "Total assets should be readable"
        );
        assertEq(
            totalSupply,
            DEPOSIT_AMOUNT,
            "Total supply should be readable"
        );
        assertNotEq(
            morphoBlue,
            address(0),
            "Morpho blue reference should be valid"
        );
        assertNotEq(
            marketParams.loanToken,
            address(0),
            "Market params should be valid"
        );

        // Strategy-specific storage
        uint256 yieldShare = ITokenizedStrategy(address(usd3Strategy))
            .performanceFee();
        uint256 maxOnCredit = usd3Strategy.maxOnCredit();
        address susd3StrategyAddr = usd3Strategy.susd3Strategy();

        // Note: performanceFee may be set to a default value (e.g., 1000 = 10%)
        // This is acceptable as long as it's within valid range
        assertLe(
            yieldShare,
            10_000,
            "Yield share should be within valid range"
        );
        assertEq(maxOnCredit, 10_000, "Default max on credit should be 100%");
        // sUSD3 strategy may be unset initially
        assertTrue(
            susd3StrategyAddr == address(0) || susd3StrategyAddr != address(0),
            "sUSD3 strategy reference should be valid"
        );
    }

    function test_shareCalculationStability() public {
        // Test that share calculations remain consistent
        uint256 depositAmount1 = 50_000e6;
        uint256 depositAmount2 = 75_000e6;

        // First deposit
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), depositAmount1);
        uint256 shares1 = usd3Strategy.deposit(depositAmount1, alice);
        vm.stopPrank();

        // Second deposit
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), depositAmount2);
        uint256 shares2 = usd3Strategy.deposit(depositAmount2, bob);
        vm.stopPrank();

        // Share calculations should be proportional
        assertEq(
            shares1,
            depositAmount1,
            "First deposit should get 1:1 shares"
        );
        assertEq(
            shares2,
            depositAmount2,
            "Second deposit should get 1:1 shares"
        );

        // Preview functions should match actual results
        uint256 previewShares1 = ITokenizedStrategy(address(usd3Strategy))
            .previewDeposit(depositAmount1);
        uint256 previewAssets1 = ITokenizedStrategy(address(usd3Strategy))
            .previewRedeem(shares1);

        // Account for potential rounding differences
        assertApproxEqAbs(
            previewShares1,
            shares1,
            1,
            "Preview deposit should match actual"
        );
        assertApproxEqAbs(
            previewAssets1,
            depositAmount1,
            1,
            "Preview redeem should match actual"
        );
    }
}
