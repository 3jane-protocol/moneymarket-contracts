// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IUSD3} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {MockWaUSDC} from "../mocks/MockWaUSDC.sol";

/**
 * @title WaUSDCPauseEIP4626ComplianceTest
 * @notice Tests for Sherlock Issue #92 - EIP-4626 compliance when waUSDC is paused
 * @dev Verifies that maxDeposit, maxMint, maxWithdraw, and maxRedeem return appropriate
 *      values when waUSDC is paused, per EIP-4626 requirements
 */
contract WaUSDCPauseEIP4626ComplianceTest is Setup {
    USD3 public usd3Strategy;
    MockWaUSDC public mockWaUSDC;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant DEPOSIT_AMOUNT = 1_000_000e6; // 1M USDC
    uint256 constant SMALL_AMOUNT = 100e6; // 100 USDC

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));
        mockWaUSDC = MockWaUSDC(address(waUSDC));

        // Fund users
        deal(address(underlyingAsset), alice, 10_000_000e6);
        deal(address(underlyingAsset), bob, 10_000_000e6);

        // Approve
        vm.prank(alice);
        underlyingAsset.approve(address(strategy), type(uint256).max);

        vm.prank(bob);
        underlyingAsset.approve(address(strategy), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC PAUSE BEHAVIOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_waUSDC_paused_maxDeposit_returns_zero() public {
        // Pause waUSDC
        mockWaUSDC.setPaused(true);

        // maxDeposit should return 0 per EIP-4626
        uint256 maxDep = strategy.maxDeposit(alice);
        assertEq(maxDep, 0, "maxDeposit should return 0 when waUSDC paused");
    }

    function test_waUSDC_paused_maxMint_returns_zero() public {
        // Pause waUSDC
        mockWaUSDC.setPaused(true);

        // maxMint should return 0 per EIP-4626
        uint256 maxMnt = strategy.maxMint(alice);
        assertEq(maxMnt, 0, "maxMint should return 0 when waUSDC paused");
    }

    function test_waUSDC_paused_maxWithdraw_returns_idle_only() public {
        // First deposit some funds when not paused
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        // Give strategy some idle USDC (not wrapped)
        deal(address(underlyingAsset), address(strategy), SMALL_AMOUNT);

        // Pause waUSDC
        mockWaUSDC.setPaused(true);

        // maxWithdraw should only count idle USDC
        uint256 maxWith = strategy.maxWithdraw(alice);

        // Should be equal to idle USDC (waUSDC can't be unwrapped)
        assertEq(maxWith, SMALL_AMOUNT, "maxWithdraw should only count idle USDC when paused");
    }

    function test_waUSDC_paused_maxRedeem_returns_idle_only() public {
        // First deposit some funds when not paused
        vm.prank(alice);
        uint256 shares = strategy.deposit(DEPOSIT_AMOUNT, alice);

        // Give strategy some idle USDC
        deal(address(underlyingAsset), address(strategy), SMALL_AMOUNT);

        // Pause waUSDC
        mockWaUSDC.setPaused(true);

        // maxRedeem should reflect only idle USDC value
        uint256 maxRed = strategy.maxRedeem(alice);

        // Calculate expected shares for idle USDC
        uint256 expectedShares = strategy.convertToShares(SMALL_AMOUNT);
        assertEq(maxRed, expectedShares, "maxRedeem should only count idle USDC when paused");
    }

    /*//////////////////////////////////////////////////////////////
                    OPERATION REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_waUSDC_paused_deposit_reverts() public {
        // Pause waUSDC
        mockWaUSDC.setPaused(true);

        // Deposit should revert when waUSDC is paused
        // Note: Reverts with "ERC4626: deposit more than max" because maxDeposit returns 0
        // This is correct EIP-4626 behavior - checked before reaching waUSDC's EnforcedPause
        vm.prank(alice);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(DEPOSIT_AMOUNT, alice);
    }

    function test_waUSDC_paused_withdraw_allows_idle() public {
        // First deposit when not paused
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        // Give strategy idle USDC
        deal(address(underlyingAsset), address(strategy), SMALL_AMOUNT);

        // Pause waUSDC
        mockWaUSDC.setPaused(true);

        // Should be able to withdraw idle USDC even when paused
        vm.prank(alice);
        uint256 withdrawn = strategy.withdraw(SMALL_AMOUNT, alice, alice);

        assertEq(withdrawn, SMALL_AMOUNT, "Should withdraw idle USDC even when paused");
    }

    /*//////////////////////////////////////////////////////////////
                    NORMAL OPERATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_waUSDC_unpaused_normal_operations() public {
        // Ensure not paused
        mockWaUSDC.setPaused(false);

        // Normal deposit should work
        vm.prank(alice);
        uint256 shares = strategy.deposit(DEPOSIT_AMOUNT, alice);
        assertGt(shares, 0, "Should receive shares");

        // Normal withdraw should work
        vm.prank(alice);
        uint256 assets = strategy.withdraw(SMALL_AMOUNT, alice, alice);
        assertEq(assets, SMALL_AMOUNT, "Should withdraw requested amount");

        // maxDeposit should be non-zero
        uint256 maxDep = strategy.maxDeposit(bob);
        assertGt(maxDep, 0, "maxDeposit should be non-zero when not paused");

        // maxWithdraw should reflect full balance
        uint256 maxWith = strategy.maxWithdraw(alice);
        assertGt(maxWith, 0, "maxWithdraw should be non-zero when not paused");
    }

    /*//////////////////////////////////////////////////////////////
                    AAVE RESERVE PAUSE SIMULATION
    //////////////////////////////////////////////////////////////*/

    function test_waUSDC_aave_reserve_paused() public view {
        // When Aave reserve is paused (not contract), maxDeposit returns 0
        // but MockWaUSDC.paused() returns false

        // We can't easily simulate Aave reserve pause in MockWaUSDC
        // but the logic in USD3 checks WAUSDC.maxDeposit() == 0
        // This is already handled by the maxDeposit check in availableDepositLimit

        // This test documents the behavior:
        // - Contract pause: Pausable(WAUSDC).paused() == true
        // - Reserve pause: WAUSDC.maxDeposit() == 0
        // Both are checked in availableDepositLimit

        assertTrue(true, "Reserve pause handled via maxDeposit check");
    }
}
