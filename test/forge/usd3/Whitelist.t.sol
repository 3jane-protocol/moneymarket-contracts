// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IUSD3} from "./utils/Setup.sol";
import {USD3} from "../../../src/usd3/USD3.sol";

contract WhitelistTest is Setup {
    USD3 public usd3Strategy;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Give users some USDC
        deal(address(underlyingAsset), alice, 10_000e6);
        deal(address(underlyingAsset), bob, 10_000e6);
        deal(address(underlyingAsset), charlie, 10_000e6);

        // Approve strategy for all users
        vm.prank(alice);
        underlyingAsset.approve(address(strategy), type(uint256).max);

        vm.prank(bob);
        underlyingAsset.approve(address(strategy), type(uint256).max);

        vm.prank(charlie);
        underlyingAsset.approve(address(strategy), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        WHITELIST ENABLE/DISABLE
    //////////////////////////////////////////////////////////////*/

    function test_whitelistDisabledByDefault() public {
        assertEq(usd3Strategy.whitelistEnabled(), false, "Whitelist should be disabled by default");

        // All users should be able to deposit
        vm.prank(alice);
        uint256 shares = strategy.deposit(100e6, alice);
        assertGt(shares, 0, "Alice should receive shares");

        vm.prank(bob);
        shares = strategy.deposit(100e6, bob);
        assertGt(shares, 0, "Bob should receive shares");
    }

    function test_enableWhitelist_onlyManagement() public {
        // Non-management cannot enable whitelist
        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.setWhitelistEnabled(true);

        // Management can enable
        vm.prank(management);
        usd3Strategy.setWhitelistEnabled(true);

        assertEq(usd3Strategy.whitelistEnabled(), true, "Whitelist should be enabled");
    }

    function test_disableWhitelist_onlyManagement() public {
        // Enable whitelist first
        vm.prank(management);
        usd3Strategy.setWhitelistEnabled(true);

        // Non-management cannot disable
        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.setWhitelistEnabled(false);

        // Management can disable
        vm.prank(management);
        usd3Strategy.setWhitelistEnabled(false);

        assertEq(usd3Strategy.whitelistEnabled(), false, "Whitelist should be disabled");
    }

    /*//////////////////////////////////////////////////////////////
                        WHITELIST MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_setWhitelist_onlyManagement() public {
        // Non-management cannot set whitelist
        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.setWhitelist(bob, true);

        // Management can set whitelist
        vm.prank(management);
        usd3Strategy.setWhitelist(alice, true);

        assertEq(usd3Strategy.whitelist(alice), true, "Alice should be whitelisted");
    }

    function test_setWhitelist_addAndRemove() public {
        vm.startPrank(management);

        // Add to whitelist
        usd3Strategy.setWhitelist(alice, true);
        assertEq(usd3Strategy.whitelist(alice), true, "Alice should be whitelisted");

        // Remove from whitelist
        usd3Strategy.setWhitelist(alice, false);
        assertEq(usd3Strategy.whitelist(alice), false, "Alice should not be whitelisted");

        vm.stopPrank();
    }

    function test_setWhitelist_eventEmission() public {
        vm.prank(management);

        // Expect event when adding to whitelist
        vm.expectEmit(true, false, false, true);
        emit WhitelistUpdated(alice, true);
        usd3Strategy.setWhitelist(alice, true);

        vm.stopPrank();

        // Expect event when removing from whitelist
        vm.prank(management);
        vm.expectEmit(true, false, false, true);
        emit WhitelistUpdated(alice, false);
        usd3Strategy.setWhitelist(alice, false);
    }

    /*//////////////////////////////////////////////////////////////
                    WHITELIST DEPOSIT ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_whitelistEnforcement_preventNonWhitelistedDeposits() public {
        // Enable whitelist and add only alice
        vm.startPrank(management);
        usd3Strategy.setWhitelistEnabled(true);
        usd3Strategy.setWhitelist(alice, true);
        vm.stopPrank();

        // Alice can deposit
        vm.prank(alice);
        uint256 shares = strategy.deposit(100e6, alice);
        assertGt(shares, 0, "Alice should receive shares");

        // Bob cannot deposit (not whitelisted)
        vm.prank(bob);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(100e6, bob);

        // Check availableDepositLimit
        assertEq(strategy.availableDepositLimit(alice), type(uint256).max, "Alice should have no limit");
        assertEq(strategy.availableDepositLimit(bob), 0, "Bob should have 0 limit");
    }

    function test_whitelistEnforcement_mintAlsoRespected() public {
        // Enable whitelist and add only alice
        vm.startPrank(management);
        usd3Strategy.setWhitelistEnabled(true);
        usd3Strategy.setWhitelist(alice, true);
        vm.stopPrank();

        // Alice can mint
        vm.prank(alice);
        uint256 assets = strategy.mint(100e6, alice);
        assertGt(assets, 0, "Alice should mint shares");

        // Bob cannot mint (not whitelisted)
        vm.prank(bob);
        vm.expectRevert("ERC4626: mint more than max");
        strategy.mint(100e6, bob);
    }

    function test_whitelistToggle_duringActiveDeposits() public {
        // Start with whitelist disabled
        assertEq(usd3Strategy.whitelistEnabled(), false);

        // Both users deposit
        vm.prank(alice);
        strategy.deposit(100e6, alice);

        vm.prank(bob);
        strategy.deposit(100e6, bob);

        // Enable whitelist with only alice
        vm.startPrank(management);
        usd3Strategy.setWhitelistEnabled(true);
        usd3Strategy.setWhitelist(alice, true);
        vm.stopPrank();

        // Alice can deposit more
        vm.prank(alice);
        strategy.deposit(50e6, alice);

        // Bob cannot deposit more (now blocked)
        vm.prank(bob);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(50e6, bob);

        // But Bob can still withdraw his existing shares
        uint256 bobShares = strategy.balanceOf(bob);
        vm.prank(bob);
        uint256 assets = strategy.redeem(bobShares, bob, bob);
        assertGt(assets, 0, "Bob should be able to withdraw");
    }

    /*//////////////////////////////////////////////////////////////
                    WHITELIST AND TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_whitelistBypass_viaTransfer() public {
        // Enable whitelist with only alice
        vm.startPrank(management);
        usd3Strategy.setWhitelistEnabled(true);
        usd3Strategy.setWhitelist(alice, true);
        vm.stopPrank();

        // Alice deposits
        vm.prank(alice);
        strategy.deposit(100e6, alice);

        uint256 aliceShares = strategy.balanceOf(alice);

        // Alice can transfer shares to non-whitelisted Bob
        vm.prank(alice);
        strategy.transfer(bob, aliceShares);

        // Bob now has shares despite not being whitelisted
        assertEq(strategy.balanceOf(bob), aliceShares, "Bob should have received shares");
        assertEq(strategy.balanceOf(alice), 0, "Alice should have no shares");

        // Bob can withdraw these shares
        vm.prank(bob);
        uint256 assets = strategy.redeem(aliceShares, bob, bob);
        assertGt(assets, 0, "Bob should be able to withdraw transferred shares");
    }

    /*//////////////////////////////////////////////////////////////
                WHITELIST AND MIN DEPOSIT INTERACTION
    //////////////////////////////////////////////////////////////*/

    function test_whitelistAndMinDeposit_bothEnforced() public {
        // Set minimum deposit and enable whitelist
        vm.startPrank(management);
        usd3Strategy.setMinDeposit(50e6); // 50 USDC minimum
        usd3Strategy.setWhitelistEnabled(true);
        usd3Strategy.setWhitelist(alice, true);
        vm.stopPrank();

        // Alice (whitelisted) cannot deposit below minimum for first deposit
        vm.prank(alice);
        vm.expectRevert("Below minimum deposit");
        strategy.deposit(25e6, alice);

        // Alice can deposit at or above minimum
        vm.prank(alice);
        uint256 shares = strategy.deposit(50e6, alice);
        assertGt(shares, 0, "Alice should receive shares");

        // Alice can now deposit any amount as existing depositor
        vm.prank(alice);
        uint256 moreShares = strategy.deposit(10e6, alice); // Below minimum but allowed
        assertGt(moreShares, 0, "Alice should be able to deposit any amount after first deposit");

        // Bob (not whitelisted) cannot deposit even above minimum
        vm.prank(bob);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(100e6, bob);
    }

    /*//////////////////////////////////////////////////////////////
                    WHITELIST BATCH OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function test_whitelistBatchOperations() public {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        // Enable whitelist
        vm.prank(management);
        usd3Strategy.setWhitelistEnabled(true);

        // Add multiple users to whitelist
        vm.startPrank(management);
        for (uint256 i = 0; i < users.length; i++) {
            usd3Strategy.setWhitelist(users[i], true);
        }
        vm.stopPrank();

        // All whitelisted users can deposit
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            uint256 shares = strategy.deposit(100e6, users[i]);
            assertGt(shares, 0, "User should receive shares");
        }

        // Remove bob from whitelist
        vm.prank(management);
        usd3Strategy.setWhitelist(bob, false);

        // Bob cannot deposit anymore
        vm.prank(bob);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(50e6, bob);

        // Alice and Charlie can still deposit
        vm.prank(alice);
        strategy.deposit(50e6, alice);

        vm.prank(charlie);
        strategy.deposit(50e6, charlie);
    }

    /*//////////////////////////////////////////////////////////////
                    WHITELIST WITH SHUTDOWN
    //////////////////////////////////////////////////////////////*/

    function test_whitelistDuringShutdown() public {
        // Enable whitelist with alice
        vm.startPrank(management);
        usd3Strategy.setWhitelistEnabled(true);
        usd3Strategy.setWhitelist(alice, true);
        vm.stopPrank();

        // Alice deposits
        vm.prank(alice);
        strategy.deposit(100e6, alice);

        // Shutdown strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        // Even whitelisted users cannot deposit during shutdown
        vm.prank(alice);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(50e6, alice);

        // But can withdraw
        uint256 aliceShares = strategy.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = strategy.redeem(aliceShares, alice, alice);
        assertGt(assets, 0, "Alice should be able to withdraw during shutdown");
    }

    // Event definition for testing
    event WhitelistUpdated(address indexed user, bool allowed);
}
