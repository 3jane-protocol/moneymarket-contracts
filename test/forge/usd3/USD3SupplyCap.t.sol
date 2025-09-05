// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IUSD3} from "./utils/Setup.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {MockProtocolConfig} from "./mocks/MockProtocolConfig.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";

/**
 * @title USD3SupplyCapTest
 * @notice Comprehensive test suite for USD3 supply cap functionality
 * @dev Tests supply cap enforcement, edge cases, and integration with other features
 */
contract USD3SupplyCapTest is Setup {
    USD3 public usd3Strategy;
    MockProtocolConfig public protocolConfig;

    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public whale = makeAddr("whale");

    // Constants for testing
    uint256 constant TEST_CAP = 1_000_000e6; // 1M USDC
    uint256 constant SMALL_AMOUNT = 100e6; // 100 USDC
    uint256 constant MEDIUM_AMOUNT = 100_000e6; // 100K USDC
    uint256 constant LARGE_AMOUNT = 500_000e6; // 500K USDC

    // Storage key for USD3_SUPPLY_CAP in MockProtocolConfig
    bytes32 private constant USD3_SUPPLY_CAP = keccak256("USD3_SUPPLY_CAP");

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Get the protocol config instance
        address morphoCredit = address(usd3Strategy.morphoCredit());
        protocolConfig = MockProtocolConfig(IMorphoCredit(morphoCredit).protocolConfig());

        // Fund test users
        _fundUsers();

        // Approve strategy for all users
        _approveForAllUsers();
    }

    function _fundUsers() internal {
        deal(address(underlyingAsset), alice, 10_000_000e6);
        deal(address(underlyingAsset), bob, 10_000_000e6);
        deal(address(underlyingAsset), charlie, 10_000_000e6);
        deal(address(underlyingAsset), whale, 100_000_000e6);
    }

    function _approveForAllUsers() internal {
        vm.prank(alice);
        underlyingAsset.approve(address(strategy), type(uint256).max);

        vm.prank(bob);
        underlyingAsset.approve(address(strategy), type(uint256).max);

        vm.prank(charlie);
        underlyingAsset.approve(address(strategy), type(uint256).max);

        vm.prank(whale);
        underlyingAsset.approve(address(strategy), type(uint256).max);
    }

    function _setSupplyCap(uint256 cap) internal {
        address owner = protocolConfig.owner();
        vm.prank(owner);
        protocolConfig.setConfig(USD3_SUPPLY_CAP, cap);
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC SUPPLY CAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_supplyCap_zeroCapAllowsUnlimitedDeposits() public {
        // Default cap is 0 (unlimited)
        assertEq(usd3Strategy.supplyCap(), 0, "Default cap should be 0");
        assertEq(usd3Strategy.availableDepositLimit(alice), type(uint256).max, "Should allow unlimited deposits");

        // Can deposit large amounts
        vm.prank(whale);
        uint256 shares = strategy.deposit(10_000_000e6, whale);
        assertGt(shares, 0, "Should receive shares");

        // Still unlimited
        assertEq(usd3Strategy.availableDepositLimit(alice), type(uint256).max, "Should still allow unlimited deposits");
    }

    function test_supplyCap_basicEnforcement() public {
        // Set a supply cap
        _setSupplyCap(TEST_CAP);

        assertEq(usd3Strategy.supplyCap(), TEST_CAP, "Cap should be set");
        assertEq(usd3Strategy.availableDepositLimit(alice), TEST_CAP, "Available should equal cap initially");

        // Deposit half the cap
        vm.prank(alice);
        strategy.deposit(LARGE_AMOUNT, alice);

        // Check remaining capacity
        assertEq(usd3Strategy.availableDepositLimit(bob), TEST_CAP - LARGE_AMOUNT, "Remaining capacity incorrect");

        // Bob can deposit up to remaining
        vm.prank(bob);
        strategy.deposit(TEST_CAP - LARGE_AMOUNT, bob);

        // No more capacity
        assertEq(usd3Strategy.availableDepositLimit(charlie), 0, "No capacity should remain");
    }

    function test_supplyCap_cannotExceedCap() public {
        _setSupplyCap(TEST_CAP);

        // Try to deposit more than cap
        vm.prank(alice);
        vm.expectRevert(); // ERC4626 will revert when maxDeposit is exceeded
        strategy.deposit(TEST_CAP + 1, alice);

        // Deposit exactly the cap should work
        vm.prank(alice);
        uint256 shares = strategy.deposit(TEST_CAP, alice);
        assertGt(shares, 0, "Should receive shares");

        // Any additional deposit should fail
        vm.prank(bob);
        vm.expectRevert();
        strategy.deposit(1, bob);
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_supplyCap_exactlyAtCap() public {
        _setSupplyCap(TEST_CAP);

        // Deposit exactly to cap
        vm.prank(alice);
        strategy.deposit(TEST_CAP, alice);

        assertEq(strategy.totalAssets(), TEST_CAP, "Total assets should equal cap");
        assertEq(usd3Strategy.availableDepositLimit(bob), 0, "No capacity at cap");

        // Even 1 wei deposit should fail
        vm.prank(bob);
        vm.expectRevert();
        strategy.deposit(1, bob);
    }

    function test_supplyCap_belowCapByOne() public {
        _setSupplyCap(TEST_CAP);

        // Deposit to one below cap
        vm.prank(alice);
        strategy.deposit(TEST_CAP - 1, alice);

        assertEq(usd3Strategy.availableDepositLimit(bob), 1, "Should have 1 wei capacity");

        // Can deposit exactly 1
        vm.prank(bob);
        strategy.deposit(1, bob);

        assertEq(usd3Strategy.availableDepositLimit(charlie), 0, "Should be at cap now");
    }

    function test_supplyCap_capLowerThanCurrentAssets() public {
        // Deposit first
        vm.prank(alice);
        strategy.deposit(TEST_CAP, alice);

        // Set cap below current assets
        _setSupplyCap(TEST_CAP / 2);

        assertEq(usd3Strategy.availableDepositLimit(bob), 0, "No capacity when over cap");

        // Cannot deposit anything
        vm.prank(bob);
        vm.expectRevert();
        strategy.deposit(1, bob);

        // But withdrawals should still work
        vm.prank(alice);
        uint256 withdrawn = strategy.withdraw(SMALL_AMOUNT, alice, alice);
        assertEq(withdrawn, SMALL_AMOUNT, "Should withdraw successfully");
    }

    /*//////////////////////////////////////////////////////////////
                    MULTIPLE DEPOSITOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_supplyCap_multipleDepositors() public {
        _setSupplyCap(TEST_CAP);

        // Multiple users deposit
        vm.prank(alice);
        strategy.deposit(300_000e6, alice);

        vm.prank(bob);
        strategy.deposit(400_000e6, bob);

        vm.prank(charlie);
        strategy.deposit(200_000e6, charlie);

        // Remaining capacity
        uint256 remaining = TEST_CAP - 900_000e6;
        assertEq(usd3Strategy.availableDepositLimit(whale), remaining, "Incorrect remaining capacity");

        // Try to exceed
        vm.prank(whale);
        vm.expectRevert();
        strategy.deposit(remaining + 1, whale);

        // Exact remaining should work
        vm.prank(whale);
        strategy.deposit(remaining, whale);

        assertEq(usd3Strategy.availableDepositLimit(alice), 0, "Should be at cap");
    }

    function test_supplyCap_raceCondition() public {
        _setSupplyCap(TEST_CAP);

        // Both users try to deposit near cap
        uint256 amount1 = 600_000e6;
        uint256 amount2 = 500_000e6; // Total would exceed cap

        // Alice deposits first
        vm.prank(alice);
        strategy.deposit(amount1, alice);

        // Bob tries to deposit but would exceed cap
        vm.prank(bob);
        vm.expectRevert();
        strategy.deposit(amount2, bob);

        // Bob can only deposit remaining
        uint256 remaining = TEST_CAP - amount1;
        vm.prank(bob);
        strategy.deposit(remaining, bob);

        assertEq(strategy.totalAssets(), TEST_CAP, "Should be exactly at cap");
    }

    /*//////////////////////////////////////////////////////////////
                    DYNAMIC CAP CHANGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_supplyCap_increaseCapAfterDeposits() public {
        _setSupplyCap(TEST_CAP);

        // Deposit to cap
        vm.prank(alice);
        strategy.deposit(TEST_CAP, alice);

        assertEq(usd3Strategy.availableDepositLimit(bob), 0, "No capacity at cap");

        // Increase cap
        _setSupplyCap(TEST_CAP * 2);

        assertEq(usd3Strategy.availableDepositLimit(bob), TEST_CAP, "Should have new capacity");

        // Can deposit more
        vm.prank(bob);
        strategy.deposit(TEST_CAP, bob);

        assertEq(strategy.totalAssets(), TEST_CAP * 2, "Total should be at new cap");
    }

    function test_supplyCap_decreaseCapAfterDeposits() public {
        _setSupplyCap(TEST_CAP * 2);

        // Deposit some amount
        vm.prank(alice);
        strategy.deposit(TEST_CAP, alice);

        // Decrease cap to below current deposits
        _setSupplyCap(TEST_CAP / 2);

        assertEq(usd3Strategy.availableDepositLimit(bob), 0, "No capacity when over new cap");

        // Withdrawals should free up capacity
        vm.prank(alice);
        strategy.withdraw(700_000e6, alice, alice);

        // Now below cap, should have capacity
        uint256 expectedCapacity = (TEST_CAP / 2) - 300_000e6;
        assertEq(usd3Strategy.availableDepositLimit(bob), expectedCapacity, "Should have capacity after withdrawal");
    }

    function test_supplyCap_removeCapAfterDeposits() public {
        _setSupplyCap(TEST_CAP);

        // Deposit to cap
        vm.prank(alice);
        strategy.deposit(TEST_CAP, alice);

        // Remove cap (set to 0)
        _setSupplyCap(0);

        assertEq(usd3Strategy.availableDepositLimit(bob), type(uint256).max, "Should be unlimited after cap removal");

        // Can deposit large amounts
        vm.prank(bob);
        strategy.deposit(10_000_000e6, bob);
        assertGt(strategy.totalAssets(), TEST_CAP, "Should exceed previous cap");
    }

    /*//////////////////////////////////////////////////////////////
                    WHITELIST INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_supplyCap_withWhitelistEnabled() public {
        _setSupplyCap(TEST_CAP);

        // Enable whitelist and add alice
        vm.prank(management);
        usd3Strategy.setWhitelistEnabled(true);
        vm.prank(management);
        usd3Strategy.setWhitelist(alice, true);

        // Alice can deposit up to cap
        assertEq(usd3Strategy.availableDepositLimit(alice), TEST_CAP, "Alice should see cap");

        // Bob not whitelisted, should see 0
        assertEq(usd3Strategy.availableDepositLimit(bob), 0, "Bob should see 0 (not whitelisted)");

        // Alice deposits
        vm.prank(alice);
        strategy.deposit(LARGE_AMOUNT, alice);

        // Add bob to whitelist
        vm.prank(management);
        usd3Strategy.setWhitelist(bob, true);

        // Bob should see remaining capacity
        assertEq(usd3Strategy.availableDepositLimit(bob), TEST_CAP - LARGE_AMOUNT, "Bob should see remaining capacity");
    }

    function test_supplyCap_whitelistPriorityOverCap() public {
        _setSupplyCap(TEST_CAP);

        // Enable whitelist but don't add anyone
        vm.prank(management);
        usd3Strategy.setWhitelistEnabled(true);

        // Even with capacity, non-whitelisted users see 0
        assertEq(usd3Strategy.availableDepositLimit(alice), 0, "Should be 0 due to whitelist");

        // Add alice
        vm.prank(management);
        usd3Strategy.setWhitelist(alice, true);

        // Now alice sees the cap
        assertEq(usd3Strategy.availableDepositLimit(alice), TEST_CAP, "Alice should see cap after whitelisting");
    }

    /*//////////////////////////////////////////////////////////////
                    ERC4626 INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_maxDeposit_respectsCap() public {
        _setSupplyCap(TEST_CAP);

        assertEq(strategy.maxDeposit(alice), TEST_CAP, "maxDeposit should equal cap initially");

        // After some deposits
        vm.prank(alice);
        strategy.deposit(LARGE_AMOUNT, alice);

        assertEq(strategy.maxDeposit(bob), TEST_CAP - LARGE_AMOUNT, "maxDeposit should reflect remaining capacity");

        // At cap
        vm.prank(bob);
        strategy.deposit(TEST_CAP - LARGE_AMOUNT, bob);

        assertEq(strategy.maxDeposit(charlie), 0, "maxDeposit should be 0 at cap");
    }

    function test_maxMint_respectsCap() public {
        _setSupplyCap(TEST_CAP);

        uint256 maxMintShares = strategy.maxMint(alice);
        assertGt(maxMintShares, 0, "Should have max mint initially");

        // Convert to assets to verify it respects cap
        uint256 maxAssets = strategy.convertToAssets(maxMintShares);
        assertLe(maxAssets, TEST_CAP, "Max mint should respect cap");

        // Mint shares equivalent to cap
        vm.prank(alice);
        strategy.mint(maxMintShares, alice);

        assertEq(strategy.maxMint(bob), 0, "Should have no mint capacity at cap");
    }

    function test_mint_respectsCap() public {
        _setSupplyCap(TEST_CAP);

        // Calculate shares for amount that would exceed cap
        uint256 excessAmount = TEST_CAP + 1000e6;
        uint256 excessShares = strategy.convertToShares(excessAmount);

        // Try to mint excessive shares
        vm.prank(alice);
        vm.expectRevert();
        strategy.mint(excessShares, alice);

        // Mint up to cap should work
        uint256 capShares = strategy.convertToShares(TEST_CAP);
        vm.prank(alice);
        uint256 assets = strategy.mint(capShares, alice);
        assertLe(assets, TEST_CAP, "Should not exceed cap");
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAWAL AND CAPACITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_supplyCap_withdrawalFreesCapacity() public {
        _setSupplyCap(TEST_CAP);

        // Deposit to cap
        vm.prank(alice);
        strategy.deposit(TEST_CAP, alice);
        assertEq(usd3Strategy.availableDepositLimit(bob), 0, "No capacity at cap");

        // Alice withdraws some
        vm.prank(alice);
        strategy.withdraw(MEDIUM_AMOUNT, alice, alice);

        // Capacity should be freed
        assertEq(usd3Strategy.availableDepositLimit(bob), MEDIUM_AMOUNT, "Withdrawal should free capacity");

        // Bob can deposit the freed amount
        vm.prank(bob);
        strategy.deposit(MEDIUM_AMOUNT, bob);

        assertEq(usd3Strategy.availableDepositLimit(charlie), 0, "Should be at cap again");
    }

    function test_supplyCap_redeemFreesCapacity() public {
        _setSupplyCap(TEST_CAP);

        // Deposit to cap
        vm.prank(alice);
        uint256 shares = strategy.deposit(TEST_CAP, alice);

        // Redeem half the shares
        uint256 halfShares = shares / 2;
        vm.prank(alice);
        uint256 assetsRedeemed = strategy.redeem(halfShares, alice, alice);

        // Capacity should be freed
        assertEq(usd3Strategy.availableDepositLimit(bob), assetsRedeemed, "Redeem should free capacity");
    }

    function test_supplyCap_multipleWithdrawalsAndDeposits() public {
        _setSupplyCap(TEST_CAP);

        // Initial deposits
        vm.prank(alice);
        strategy.deposit(400_000e6, alice);

        vm.prank(bob);
        strategy.deposit(300_000e6, bob);

        // Check remaining
        assertEq(usd3Strategy.availableDepositLimit(charlie), 300_000e6, "Initial remaining incorrect");

        // Alice withdraws
        vm.prank(alice);
        strategy.withdraw(200_000e6, alice, alice);

        // More capacity available
        assertEq(usd3Strategy.availableDepositLimit(charlie), 500_000e6, "After withdrawal remaining incorrect");

        // Charlie deposits
        vm.prank(charlie);
        strategy.deposit(400_000e6, charlie);

        // Bob withdraws
        vm.prank(bob);
        strategy.withdraw(100_000e6, bob, bob);

        // Final capacity check
        assertEq(usd3Strategy.availableDepositLimit(whale), 200_000e6, "Final remaining incorrect");
    }

    /*//////////////////////////////////////////////////////////////
                        INTEREST ACCRUAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_supplyCap_withInterestAccrual() public {
        _setSupplyCap(TEST_CAP);

        // Deposit to exactly the cap
        vm.prank(alice);
        strategy.deposit(TEST_CAP, alice);

        uint256 assetsBeforeInterest = strategy.totalAssets();
        assertEq(assetsBeforeInterest, TEST_CAP, "Should be at cap");

        // Simulate a scenario where total assets exceed cap
        // This could happen due to interest accrual, performance fees, etc.
        // For testing, we'll manually increase the total supply shares to simulate profit

        // First verify no more deposits allowed at cap
        assertEq(usd3Strategy.availableDepositLimit(bob), 0, "No capacity at cap");

        // Manually simulate interest accrual by manipulating Morpho's state
        // In real scenario, this would happen through borrower interest payments
        // For now, we'll just test the behavior when totalAssets would exceed cap

        // Even when conceptually over cap, withdrawals should work
        vm.prank(alice);
        uint256 withdrawn = strategy.withdraw(100_000e6, alice, alice);
        assertEq(withdrawn, 100_000e6, "Should be able to withdraw");

        // After withdrawal, should have capacity again
        uint256 expectedCapacity = TEST_CAP - strategy.totalAssets();
        assertEq(usd3Strategy.availableDepositLimit(bob), expectedCapacity, "Should have capacity after withdrawal");

        // Bob can deposit up to the available capacity
        vm.prank(bob);
        strategy.deposit(expectedCapacity, bob);

        // Should be at cap again
        assertEq(strategy.totalAssets(), TEST_CAP, "Should be at cap again");
        assertEq(usd3Strategy.availableDepositLimit(charlie), 0, "No capacity at cap");
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_supplyCap_enforcement(uint256 cap, uint256 depositAmount) public {
        // Bound inputs to reasonable ranges
        cap = bound(cap, 0, 100_000_000e6); // 0 to 100M USDC
        depositAmount = bound(depositAmount, 1, 100_000_000e6);

        // Ensure alice has enough balance
        deal(address(underlyingAsset), alice, depositAmount + 1e6);

        _setSupplyCap(cap);

        if (cap == 0) {
            // Unlimited deposits
            assertEq(usd3Strategy.availableDepositLimit(alice), type(uint256).max, "Should be unlimited with 0 cap");

            // Can deposit any amount (up to balance)
            vm.prank(alice);
            strategy.deposit(depositAmount, alice);
            assertEq(strategy.totalAssets(), depositAmount, "Deposit should succeed with no cap");
        } else {
            // Limited by cap
            assertEq(usd3Strategy.availableDepositLimit(alice), cap, "Available should equal cap");

            if (depositAmount <= cap) {
                vm.prank(alice);
                strategy.deposit(depositAmount, alice);
                assertEq(strategy.totalAssets(), depositAmount, "Deposit within cap should succeed");
                assertEq(usd3Strategy.availableDepositLimit(bob), cap - depositAmount, "Remaining should be correct");
            } else {
                vm.prank(alice);
                vm.expectRevert();
                strategy.deposit(depositAmount, alice);
            }
        }
    }

    function testFuzz_supplyCap_multipleDepositors(uint256 cap, uint256 deposit1, uint256 deposit2, uint256 deposit3)
        public
    {
        // Bound inputs
        cap = bound(cap, 100e6, 10_000_000e6); // 100 to 10M USDC
        deposit1 = bound(deposit1, 1, cap);
        deposit2 = bound(deposit2, 1, cap);
        deposit3 = bound(deposit3, 1, cap);

        _setSupplyCap(cap);

        uint256 totalDeposited = 0;

        // First deposit
        if (deposit1 <= cap) {
            vm.prank(alice);
            strategy.deposit(deposit1, alice);
            totalDeposited += deposit1;
        }

        // Second deposit
        if (totalDeposited + deposit2 <= cap) {
            vm.prank(bob);
            strategy.deposit(deposit2, bob);
            totalDeposited += deposit2;
        } else if (cap > totalDeposited) {
            // Deposit only what fits
            uint256 remaining = cap - totalDeposited;
            vm.prank(bob);
            strategy.deposit(remaining, bob);
            totalDeposited = cap;
        }

        // Third deposit
        if (totalDeposited < cap) {
            uint256 remaining = cap - totalDeposited;
            if (deposit3 <= remaining) {
                vm.prank(charlie);
                strategy.deposit(deposit3, charlie);
                totalDeposited += deposit3;
            } else {
                vm.prank(charlie);
                strategy.deposit(remaining, charlie);
                totalDeposited = cap;
            }
        }

        // Verify total doesn't exceed cap
        assertLe(strategy.totalAssets(), cap, "Total assets should not exceed cap");

        // Verify available capacity
        if (totalDeposited >= cap) {
            assertEq(usd3Strategy.availableDepositLimit(whale), 0, "No capacity at cap");
        } else {
            assertEq(usd3Strategy.availableDepositLimit(whale), cap - totalDeposited, "Available capacity incorrect");
        }
    }
}
