// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../USD3.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {sUSD3} from "../../sUSD3.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TransferRestrictionComplexScenarios
 * @notice Tests complex multi-user scenarios for transfer restrictions
 * @dev Tests interactions between multiple users with various restriction states
 */
contract TransferRestrictionComplexScenarios is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    // Multiple test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public dave = makeAddr("dave");
    address public eve = makeAddr("eve");

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 implementation with proxy
        sUSD3 susd3Implementation = new sUSD3();

        // Deploy proxy admin
        address proxyAdminOwner = makeAddr("ProxyAdminOwner");
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(proxyAdminOwner);

        // Deploy proxy with initialization
        bytes memory susd3InitData =
            abi.encodeWithSelector(sUSD3.initialize.selector, address(usd3Strategy), management, keeper);

        TransparentUpgradeableProxy susd3Proxy =
            new TransparentUpgradeableProxy(address(susd3Implementation), address(susd3ProxyAdmin), susd3InitData);

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link strategies
        // Set commitment period via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress).protocolConfig();
        bytes32 USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");

        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Set config as the owner (test contract in this case)
        MockProtocolConfig(protocolConfigAddress).setConfig(USD3_COMMITMENT_TIME, 7 days);

        // Configure commitment and lock periods
        vm.prank(management);
        usd3Strategy.setMinDeposit(100e6);

        // Setup test users with funds
        address[5] memory users = [alice, bob, charlie, dave, eve];
        for (uint256 i = 0; i < users.length; i++) {
            airdrop(asset, users[i], 10000e6);
        }
    }

    // Multi-User Interaction Tests

    function test_staggered_deposits_different_commitment_ends() public {
        // Users deposit at different times
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        skip(2 days);

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, bob);
        vm.stopPrank();

        skip(3 days);

        vm.startPrank(charlie);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, charlie);
        vm.stopPrank();

        // At this point:
        // Alice: 5 days into commitment (2 days left)
        // Bob: 3 days into commitment (4 days left)
        // Charlie: 0 days into commitment (7 days left)

        // Alice still cannot transfer
        vm.prank(alice);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(dave, 100e6);

        skip(2 days);

        // Now Alice can transfer (7 days passed)
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(dave, 100e6);

        // But Bob and Charlie still cannot
        vm.prank(bob);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(dave, 100e6);

        vm.prank(charlie);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(dave, 100e6);
    }

    // Circular Transfer Attempts

    function test_circular_transfers_blocked_by_commitment() public {
        // Setup: All users deposit
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            asset.approve(address(usd3Strategy), 1000e6);
            usd3Strategy.deposit(1000e6, users[i]);
            vm.stopPrank();
        }

        // Try circular transfer during commitment
        // Alice -> Bob -> Charlie -> Alice

        vm.prank(alice);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, 100e6);

        // Skip commitment
        skip(7 days);

        // Now circular transfer works
        uint256 amount = 100e6;

        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, amount);

        vm.prank(bob);
        IERC20(address(usd3Strategy)).transfer(charlie, amount);

        vm.prank(charlie);
        IERC20(address(usd3Strategy)).transfer(alice, amount);

        // Verify circular transfer completed
        // Everyone should have roughly the same balance as before
        assertApproxEqRel(
            IERC20(address(usd3Strategy)).balanceOf(alice),
            1000e6,
            0.01e18 // 1% tolerance for any rounding
        );
    }

    // Transfer Chains and Cascading Effects

    function test_transfer_chain_with_mixed_restrictions() public {
        // Alice deposits first (will be unrestricted)
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        skip(7 days); // Alice's commitment expires

        // Bob deposits (will be restricted)
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, bob);
        vm.stopPrank();

        // Alice can transfer to Charlie
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(charlie, 500e6);

        // Charlie receives shares without restriction
        // Charlie can immediately transfer to Dave
        vm.prank(charlie);
        IERC20(address(usd3Strategy)).transfer(dave, 250e6);

        // But Bob cannot participate in the chain
        vm.prank(bob);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(eve, 100e6);

        // Verify final distribution
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 500e6);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(charlie), 250e6);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(dave), 250e6);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 1000e6);
    }

    // High-Precision Rounding Edge Cases

    function test_transfer_precision_edge_cases() public {
        // Alice deposits a precise amount
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 123456789);
        usd3Strategy.deposit(123456789, alice);
        skip(7 days);

        uint256 balance = IERC20(address(usd3Strategy)).balanceOf(alice);

        // Transfer amounts that might cause rounding issues
        uint256 oneThird = balance / 3;

        IERC20(address(usd3Strategy)).transfer(bob, oneThird);
        IERC20(address(usd3Strategy)).transfer(charlie, oneThird);

        // Remaining balance might not be exactly oneThird due to rounding
        uint256 remaining = IERC20(address(usd3Strategy)).balanceOf(alice);

        // Transfer remaining (should work regardless of rounding)
        IERC20(address(usd3Strategy)).transfer(dave, remaining);
        vm.stopPrank();

        // Alice should have exactly 0
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 0);

        // Total should be preserved (within rounding)
        uint256 total = IERC20(address(usd3Strategy)).balanceOf(bob) + IERC20(address(usd3Strategy)).balanceOf(charlie)
            + IERC20(address(usd3Strategy)).balanceOf(dave);
        assertApproxEqAbs(total, balance, 3); // Allow 3 wei rounding
    }

    // Max Value Transfers

    function test_max_uint256_scenarios() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days);

        uint256 balance = IERC20(address(usd3Strategy)).balanceOf(alice);

        // Try to transfer max uint256 (should fail as balance is less)
        vm.expectRevert(); // Should revert with insufficient balance
        IERC20(address(usd3Strategy)).transfer(bob, type(uint256).max);

        // Transfer actual balance works
        IERC20(address(usd3Strategy)).transfer(bob, balance);
        vm.stopPrank();

        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 0);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), balance);
    }

    // Dust Amount Handling

    function test_dust_amount_transfers() public {
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days);

        // Transfer almost everything, leaving dust
        uint256 balance = IERC20(address(usd3Strategy)).balanceOf(alice);
        IERC20(address(usd3Strategy)).transfer(bob, balance - 1);

        // Alice has 1 wei left
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 1);

        // Can still transfer the dust
        IERC20(address(usd3Strategy)).transfer(charlie, 1);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 0);
        vm.stopPrank();
    }

    // Complex State Transitions

    function test_complex_susd3_state_transitions() public {
        // Setup: Multiple users with USD3
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            asset.approve(address(usd3Strategy), 2000e6);
            usd3Strategy.deposit(2000e6, users[i]);
            vm.stopPrank();
        }

        skip(7 days); // Pass USD3 commitment

        // Alice enters sUSD3 (gets lock)
        vm.startPrank(alice);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 200e6);
        susd3Strategy.deposit(200e6, alice);
        vm.stopPrank();

        // Bob enters sUSD3 later (different lock end)
        skip(30 days);
        vm.startPrank(bob);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 100e6);
        susd3Strategy.deposit(100e6, bob);
        vm.stopPrank();

        // Charlie enters even later
        skip(30 days);
        vm.startPrank(charlie);
        // Check remaining capacity for subordination
        uint256 availableLimit = susd3Strategy.availableDepositLimit(charlie);
        uint256 charlieDeposit = Math.min(50e6, availableLimit);
        if (charlieDeposit > 0) {
            IERC20(address(usd3Strategy)).approve(address(susd3Strategy), charlieDeposit);
            susd3Strategy.deposit(charlieDeposit, charlie);
        }
        vm.stopPrank();

        // At this point:
        // Alice: 60 days into lock (30 days left)
        // Bob: 30 days into lock (60 days left)
        // Charlie: 0 days into lock (90 days left)

        // Alice cannot transfer yet
        vm.prank(alice);
        vm.expectRevert("sUSD3: Cannot transfer during lock period");
        IERC20(address(susd3Strategy)).transfer(dave, 10e6);

        skip(30 days);

        // Now Alice can transfer (90 days passed for her)
        vm.prank(alice);
        IERC20(address(susd3Strategy)).transfer(dave, 10e6);

        // But Bob and Charlie still cannot
        vm.prank(bob);
        vm.expectRevert("sUSD3: Cannot transfer during lock period");
        IERC20(address(susd3Strategy)).transfer(dave, 10e6);

        if (charlieDeposit > 0) {
            vm.prank(charlie);
            vm.expectRevert("sUSD3: Cannot transfer during lock period");
            IERC20(address(susd3Strategy)).transfer(dave, 1e6);
        }
    }

    // Approval Chain Scenarios

    function test_complex_approval_chains() public {
        // Setup: Alice has shares past commitment
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days);
        uint256 aliceBalance = IERC20(address(usd3Strategy)).balanceOf(alice);

        // Alice sets up approval chain
        // Alice approves Bob, Bob approves Charlie (as operator pattern)
        IERC20(address(usd3Strategy)).approve(bob, aliceBalance / 2);
        vm.stopPrank();

        // Bob transfers some of Alice's shares to Charlie
        vm.prank(bob);
        IERC20(address(usd3Strategy)).transferFrom(alice, charlie, aliceBalance / 4);

        // Charlie now has shares without restriction
        assertEq(IERC20(address(usd3Strategy)).balanceOf(charlie), aliceBalance / 4);

        // Charlie can immediately transfer
        vm.prank(charlie);
        IERC20(address(usd3Strategy)).transfer(dave, aliceBalance / 8);

        // Verify final state
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), (aliceBalance * 3) / 4);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(charlie), aliceBalance / 8);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(dave), aliceBalance / 8);
    }

    // Subordination Ratio Edge Cases

    function test_subordination_ratio_transfer_limits() public {
        // Setup: Fill USD3 close to subordination limit
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 10000e6);
        usd3Strategy.deposit(10000e6, alice);
        skip(7 days);

        // Calculate max sUSD3 (15% of USD3 supply)
        uint256 usd3Supply = IERC20(address(usd3Strategy)).totalSupply();
        uint256 maxSubordination = (usd3Supply * 1500) / 10000; // 15%

        // Alice deposits close to max into sUSD3
        // Ensure we don't underflow by checking if maxSubordination > 10e6
        uint256 depositAmount;
        if (maxSubordination > 10e6) {
            depositAmount = Math.min(maxSubordination - 10e6, 1400e6);
        } else {
            depositAmount = maxSubordination; // Use full amount if small
        }

        if (depositAmount > 0) {
            IERC20(address(usd3Strategy)).approve(address(susd3Strategy), depositAmount);
            susd3Strategy.deposit(depositAmount, alice);
        }
        vm.stopPrank();

        // Bob tries to deposit more USD3
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, bob);
        skip(7 days);
        vm.stopPrank();

        // This might push us closer to subordination limit
        // Test that transfers still work correctly
        vm.prank(bob);
        IERC20(address(usd3Strategy)).transfer(charlie, 100e6);

        // Alice's sUSD3 transfers after lock
        skip(90 days);

        // Check Alice's balance before transfer
        uint256 susd3Balance = IERC20(address(susd3Strategy)).balanceOf(alice);

        if (susd3Balance > 0) {
            vm.prank(alice);
            IERC20(address(susd3Strategy)).transfer(dave, susd3Balance / 10);
        }
    }

    // Consecutive Deposit-Transfer Patterns

    function test_consecutive_deposit_transfer_patterns() public {
        // User makes multiple deposits and transfers in succession
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 5000e6);

        // First deposit
        usd3Strategy.deposit(1000e6, alice);

        // Cannot transfer immediately
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, 100e6);

        skip(7 days);

        // Can transfer now
        IERC20(address(usd3Strategy)).transfer(bob, 100e6);

        // Second deposit (resets commitment)
        usd3Strategy.deposit(1000e6, alice);

        // Cannot transfer again
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, 100e6);

        skip(7 days);

        // Can transfer entire balance now
        uint256 balance = IERC20(address(usd3Strategy)).balanceOf(alice);
        IERC20(address(usd3Strategy)).transfer(bob, balance);
        vm.stopPrank();

        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 0);
    }
}
