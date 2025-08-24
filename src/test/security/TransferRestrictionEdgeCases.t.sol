// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../USD3.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {sUSD3} from "../../sUSD3.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title TransferRestrictionEdgeCases
 * @notice Tests edge cases for transfer restrictions in USD3 and sUSD3
 * @dev Comprehensive edge case coverage for transfer restriction functionality
 */
contract TransferRestrictionEdgeCases is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

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
        // Set commitment period via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        bytes32 USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");

        // Configure commitment and lock periods
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Set config as the owner (test contract in this case)
        MockProtocolConfig(protocolConfigAddress).setConfig(
            USD3_COMMITMENT_TIME,
            7 days
        );

        vm.prank(management);
        usd3Strategy.setMinDeposit(100e6);

        // Setup test users
        airdrop(asset, alice, 10000e6);
        airdrop(asset, bob, 10000e6);
        airdrop(asset, charlie, 10000e6);
    }

    // Boundary Condition Tests

    function test_transfer_exactly_at_commitment_expiry() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        vm.stopPrank();

        // Fast forward to exactly commitment expiry
        skip(7 days);

        // Transfer should succeed at exact boundary
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, aliceShares / 2);

        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), aliceShares / 2);
    }

    function test_transfer_one_second_before_commitment_expiry() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        vm.stopPrank();

        // Fast forward to one second before expiry
        skip(7 days - 1);

        // Transfer should fail
        vm.prank(alice);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, aliceShares / 2);

        // One second later should work
        skip(1);
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, aliceShares / 2);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), aliceShares / 2);
    }

    function test_zero_amount_transfers() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        vm.stopPrank();

        // Zero amount transfer during commitment is still blocked by the hook
        // The hook checks commitment before checking amount
        vm.prank(alice);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, 0);

        // After commitment, zero transfers work (though they're no-ops)
        skip(7 days);
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, 0);

        // Verify no actual transfer occurred
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 0);
    }

    // Approval and TransferFrom Tests

    function test_transferFrom_with_infinite_approval() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);

        // Alice gives Bob infinite approval
        IERC20(address(usd3Strategy)).approve(bob, type(uint256).max);
        vm.stopPrank();

        // Bob cannot transfer during commitment even with infinite approval
        vm.prank(bob);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transferFrom(
            alice,
            charlie,
            aliceShares / 2
        );

        // After commitment period
        skip(7 days);

        // Now Bob can transfer
        vm.prank(bob);
        IERC20(address(usd3Strategy)).transferFrom(
            alice,
            charlie,
            aliceShares / 2
        );
        assertEq(
            IERC20(address(usd3Strategy)).balanceOf(charlie),
            aliceShares / 2
        );
    }

    function test_partial_approval_scenarios() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        vm.stopPrank();

        // Skip commitment
        skip(7 days);

        // Alice approves Bob for only half her shares
        vm.prank(alice);
        IERC20(address(usd3Strategy)).approve(bob, aliceShares / 2);

        // Bob tries to transfer more than approved
        vm.prank(bob);
        vm.expectRevert(); // ERC20 insufficient allowance
        IERC20(address(usd3Strategy)).transferFrom(alice, charlie, aliceShares);

        // Bob transfers exactly approved amount
        vm.prank(bob);
        IERC20(address(usd3Strategy)).transferFrom(
            alice,
            charlie,
            aliceShares / 2
        );
        assertEq(
            IERC20(address(usd3Strategy)).balanceOf(charlie),
            aliceShares / 2
        );
    }

    // Flash Loan Attack Prevention

    function test_flash_loan_cannot_bypass_commitment() public {
        // Simulate a flash loan attack scenario
        FlashLoanAttacker attacker = new FlashLoanAttacker(
            address(usd3Strategy),
            address(asset)
        );

        // Fund attacker
        airdrop(asset, address(attacker), 10000e6);

        // Attacker tries to deposit and immediately transfer
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        attacker.attack();
    }

    // Emergency Scenarios

    function test_transfer_during_shutdown() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        vm.stopPrank();

        // Shutdown strategy
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        // Alice still cannot transfer during commitment (shutdown doesn't bypass transfer restrictions)
        vm.prank(alice);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, aliceShares);

        // After commitment, transfer works
        skip(7 days);
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, aliceShares);
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), aliceShares);
    }

    // Multiple Partial Transfers

    function test_multiple_partial_transfers_after_commitment() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        uint256 initialShares = IERC20(address(usd3Strategy)).balanceOf(alice);
        vm.stopPrank();

        // Skip commitment
        skip(7 days);

        // Alice makes multiple partial transfers
        vm.startPrank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, initialShares / 4);
        IERC20(address(usd3Strategy)).transfer(charlie, initialShares / 4);
        IERC20(address(usd3Strategy)).transfer(bob, initialShares / 4);
        vm.stopPrank();

        // Verify final balances
        assertEq(
            IERC20(address(usd3Strategy)).balanceOf(alice),
            initialShares / 4
        );
        assertEq(
            IERC20(address(usd3Strategy)).balanceOf(bob),
            initialShares / 2
        );
        assertEq(
            IERC20(address(usd3Strategy)).balanceOf(charlie),
            initialShares / 4
        );
    }

    // sUSD3 Edge Cases

    function test_susd3_transfer_exactly_at_lock_expiry() public {
        // Setup USD3 first
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days); // Pass USD3 commitment

        // Deposit into sUSD3
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        uint256 susd3Shares = IERC20(address(susd3Strategy)).balanceOf(alice);
        vm.stopPrank();

        // Fast forward to exactly lock expiry
        skip(90 days);

        // Transfer should succeed at exact boundary
        vm.prank(alice);
        IERC20(address(susd3Strategy)).transfer(bob, susd3Shares / 2);
        assertEq(
            IERC20(address(susd3Strategy)).balanceOf(bob),
            susd3Shares / 2
        );
    }

    function test_susd3_cooldown_shares_boundary() public {
        // Setup
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days);

        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);
        skip(90 days);

        uint256 totalShares = IERC20(address(susd3Strategy)).balanceOf(alice);

        // Start cooldown for exactly half
        susd3Strategy.startCooldown(totalShares / 2);

        // Can transfer exactly the non-cooldown half
        IERC20(address(susd3Strategy)).transfer(bob, totalShares / 2);

        // Cannot transfer even 1 wei more
        vm.expectRevert("sUSD3: Cannot transfer shares in cooldown");
        IERC20(address(susd3Strategy)).transfer(bob, 1);
        vm.stopPrank();
    }

    // Reentrancy During Transfer

    function test_no_reentrancy_during_transfer_hook() public {
        ReentrantReceiver reentrant = new ReentrantReceiver(
            address(usd3Strategy)
        );

        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days); // Pass commitment

        // Transfer to reentrant contract
        // The transfer should complete without reentrancy issues
        IERC20(address(usd3Strategy)).transfer(address(reentrant), 100e6);
        vm.stopPrank();

        assertEq(
            IERC20(address(usd3Strategy)).balanceOf(address(reentrant)),
            100e6
        );
    }

    // Gas Optimization Tests

    function test_gas_transfer_after_commitment() public {
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        skip(7 days);

        uint256 gasBefore = gasleft();
        IERC20(address(usd3Strategy)).transfer(bob, 100e6);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        // Log gas usage for optimization tracking
        emit log_named_uint("Gas used for transfer after commitment", gasUsed);

        // Ensure reasonable gas usage (< 100k)
        assertLt(gasUsed, 100000);
    }

    // Transfer to self

    function test_transfer_to_self_during_commitment() public {
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);
        uint256 aliceShares = IERC20(address(usd3Strategy)).balanceOf(alice);

        // Transfer to self should still be blocked during commitment
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(alice, aliceShares);
        vm.stopPrank();
    }

    // USD3 to sUSD3 transfer exception

    function test_can_transfer_usd3_to_susd3_during_commitment() public {
        // Alice deposits USD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        usd3Strategy.deposit(1000e6, alice);

        // Alice can transfer USD3 to sUSD3 even during commitment
        // This is allowed by the _preTransferHook exception
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, alice);

        // Verify sUSD3 received the USD3
        assertGt(IERC20(address(susd3Strategy)).balanceOf(alice), 0);
        vm.stopPrank();
    }

    function test_griefing_attack_prevention_usd3() public {
        // Airdrop USDC to users
        airdrop(underlyingAsset, alice, 1000e6);
        airdrop(underlyingAsset, bob, 1000e6);

        // Alice deposits and has commitment period
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 100e6);
        usd3Strategy.deposit(100e6, alice);
        uint256 aliceCommitmentEnd = block.timestamp + 7 days;
        vm.stopPrank();

        // Advance time partially through commitment
        vm.warp(block.timestamp + 3 days);

        // Bob (attacker) tries to grief Alice by depositing on her behalf
        // This should now be blocked entirely (not just prevent commitment extension)
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), 1);
        vm.expectRevert("USD3: Only self or whitelisted deposits allowed");
        usd3Strategy.deposit(1, alice); // Attempt to deposit to Alice
        vm.stopPrank();

        // Verify Bob's deposit was blocked (Alice's balance unchanged)
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 100e6);

        // Fast forward to original commitment end
        vm.warp(aliceCommitmentEnd + 1);

        // Alice should be able to transfer after commitment ends
        vm.startPrank(alice);
        uint256 balance = IERC20(address(usd3Strategy)).balanceOf(alice);
        IERC20(address(usd3Strategy)).transfer(bob, balance);
        vm.stopPrank();

        // Verify transfer succeeded
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), balance);
    }

    function test_griefing_attack_prevention_susd3() public {
        // Airdrop USDC to users
        airdrop(underlyingAsset, alice, 1000e6);
        airdrop(underlyingAsset, bob, 1000e6);

        // Alice deposits USD3 and stakes to sUSD3
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 100e6);
        usd3Strategy.deposit(100e6, alice);

        // Wait for commitment to end
        vm.warp(block.timestamp + 7 days + 1);

        // Stake only 10e6 USD3 to sUSD3 (to stay within subordination ratio)
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 10e6);
        susd3Strategy.deposit(10e6, alice);
        uint256 aliceLockEnd = block.timestamp + 90 days;
        vm.stopPrank();

        // Advance time partially through lock
        vm.warp(block.timestamp + 30 days);

        // Bob gets some USD3 to attempt the griefing attack
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), 100e6);
        usd3Strategy.deposit(100e6, bob);
        vm.warp(block.timestamp + 7 days + 1); // Wait for Bob's commitment

        // Bob tries to deposit on Alice's behalf to extend her lock
        // This should now be blocked entirely (not just prevent lock extension)
        uint256 bobUsd3Balance = IERC20(address(usd3Strategy)).balanceOf(bob);
        require(bobUsd3Balance >= 1e6, "Bob needs more USD3");
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 1e6);
        vm.expectRevert("sUSD3: Only self or whitelisted deposits allowed");
        susd3Strategy.deposit(1e6, alice); // Attempt to deposit to Alice
        vm.stopPrank();

        // Verify Alice's sUSD3 balance unchanged (Bob's deposit was blocked)
        assertEq(IERC20(address(susd3Strategy)).balanceOf(alice), 10e6);

        // Alice's lock ends as originally scheduled
        vm.warp(aliceLockEnd + 1);

        // Alice should be able to transfer
        vm.startPrank(alice);
        uint256 shares = IERC20(address(susd3Strategy)).balanceOf(alice);
        IERC20(address(susd3Strategy)).transfer(bob, shares);
        vm.stopPrank();

        assertEq(IERC20(address(susd3Strategy)).balanceOf(bob), shares);
    }

    function test_whitelisted_depositor_can_extend_commitment() public {
        // Airdrop USDC to users and test contract
        airdrop(underlyingAsset, alice, 1000e6);
        airdrop(underlyingAsset, address(this), 1000e6);

        // First whitelist a helper contract (using address(this) as mock helper)
        // Set commitment period via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        bytes32 USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");
        vm.prank(management);
        usd3Strategy.setDepositorWhitelist(address(this), true);

        // Alice deposits
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 100e6);
        usd3Strategy.deposit(100e6, alice);
        vm.stopPrank();

        // Advance time partially
        vm.warp(block.timestamp + 3 days);

        // Whitelisted depositor deposits on Alice's behalf
        underlyingAsset.approve(address(usd3Strategy), 10e6);
        usd3Strategy.deposit(10e6, alice);

        // Alice's commitment SHOULD be extended
        vm.warp(block.timestamp + 4 days + 1); // Original would have ended

        // Alice should NOT be able to transfer yet
        vm.startPrank(alice);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, 1);
        vm.stopPrank();

        // But after new commitment ends, she can
        vm.warp(block.timestamp + 3 days); // Complete new 7-day period
        vm.prank(alice);
        IERC20(address(usd3Strategy)).transfer(bob, 1);

        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 1);
    }

    function test_self_deposit_always_extends_commitment() public {
        // Airdrop USDC to Alice
        airdrop(underlyingAsset, alice, 1000e6);

        // Alice deposits initially
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 200e6);
        usd3Strategy.deposit(100e6, alice);

        // Advance time partially
        vm.warp(block.timestamp + 3 days);

        // Alice deposits again for herself
        usd3Strategy.deposit(100e6, alice);

        // Commitment should be extended
        vm.warp(block.timestamp + 4 days + 1); // Original would have ended

        // Should still be locked
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, 1);

        // After new period ends, can transfer
        vm.warp(block.timestamp + 3 days);
        IERC20(address(usd3Strategy)).transfer(bob, 1);
        vm.stopPrank();

        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 1);
    }

    function test_commitment_bypass_prevention() public {
        // Airdrop USDC to Alice and her secondary address (Bob)
        airdrop(underlyingAsset, alice, 1000e6);
        airdrop(underlyingAsset, bob, 1000e6);

        // Alice tries to bypass commitment by depositing from Alice to Bob
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 100e6);

        // This should be blocked - can't deposit to a different address
        vm.expectRevert("USD3: Only self or whitelisted deposits allowed");
        usd3Strategy.deposit(100e6, bob);
        vm.stopPrank();

        // Verify Bob has no USD3 balance
        assertEq(IERC20(address(usd3Strategy)).balanceOf(bob), 0);

        // Alice can only deposit to herself
        vm.startPrank(alice);
        usd3Strategy.deposit(100e6, alice);
        vm.stopPrank();

        // Verify Alice has the balance with commitment
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 100e6);

        // Alice cannot transfer during commitment
        vm.startPrank(alice);
        vm.expectRevert("USD3: Cannot transfer during commitment period");
        IERC20(address(usd3Strategy)).transfer(bob, 50e6);
        vm.stopPrank();
    }

    function test_deposit_restrictions() public {
        // Airdrop USDC to users
        airdrop(underlyingAsset, alice, 1000e6);
        airdrop(underlyingAsset, bob, 1000e6);
        airdrop(underlyingAsset, charlie, 1000e6);

        // Test 1: Users can deposit to themselves
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 100e6);
        usd3Strategy.deposit(100e6, alice);
        vm.stopPrank();
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 100e6);

        // Test 2: Users cannot deposit to others
        vm.startPrank(bob);
        underlyingAsset.approve(address(usd3Strategy), 100e6);
        vm.expectRevert("USD3: Only self or whitelisted deposits allowed");
        usd3Strategy.deposit(100e6, alice);
        vm.stopPrank();

        // Test 3: Whitelist an address (like Helper contract)
        // Set commitment period via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        bytes32 USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");
        vm.prank(management);
        usd3Strategy.setDepositorWhitelist(charlie, true);

        // Test 4: Whitelisted address can deposit for others
        vm.startPrank(charlie);
        underlyingAsset.approve(address(usd3Strategy), 200e6); // Need 200e6 total
        usd3Strategy.deposit(100e6, alice); // Charlie can deposit for Alice
        vm.stopPrank();
        assertEq(IERC20(address(usd3Strategy)).balanceOf(alice), 200e6);

        // Test 5: Remove from whitelist
        vm.prank(management);
        usd3Strategy.setDepositorWhitelist(charlie, false);

        // Test 6: Charlie can no longer deposit for others
        vm.startPrank(charlie);
        vm.expectRevert("USD3: Only self or whitelisted deposits allowed");
        usd3Strategy.deposit(50e6, alice);
        vm.stopPrank();

        // Test 7: Charlie can still deposit for himself
        vm.startPrank(charlie);
        usd3Strategy.deposit(100e6, charlie); // Charlie deposits to himself (minimum deposit)
        vm.stopPrank();
        assertEq(IERC20(address(usd3Strategy)).balanceOf(charlie), 100e6);
    }

    function test_susd3_dos_via_commitment_timestamp() public {
        // Setup: Give users USDC
        airdrop(underlyingAsset, alice, 1000e6);
        airdrop(underlyingAsset, bob, 1000e6);

        // Deploy a mock Helper contract and whitelist it
        address mockHelper = makeAddr("mockHelper");
        // Set commitment period via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        bytes32 USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");
        vm.prank(management);
        usd3Strategy.setDepositorWhitelist(mockHelper, true);

        // Step 1: Alice deposits USD3 and waits for commitment to pass
        vm.startPrank(alice);
        underlyingAsset.approve(address(usd3Strategy), 500e6);
        usd3Strategy.deposit(500e6, alice);
        vm.stopPrank();

        // Wait for Alice's commitment to pass
        skip(7 days + 1);

        // Step 2: Alice stakes USD3 to sUSD3
        vm.startPrank(alice);
        uint256 aliceUsd3Balance = IERC20(address(usd3Strategy)).balanceOf(
            alice
        );
        IERC20(address(usd3Strategy)).approve(
            address(susd3Strategy),
            aliceUsd3Balance
        );

        // Deposit half to sUSD3 (respecting subordination ratio)
        uint256 depositAmount = 75e6; // Small amount to stay within ratio
        susd3Strategy.deposit(depositAmount, alice);
        uint256 aliceSusd3Shares = IERC20(address(susd3Strategy)).balanceOf(
            alice
        );
        assertGt(aliceSusd3Shares, 0, "Alice should have sUSD3 shares");
        vm.stopPrank();

        // Wait for sUSD3 lock period to pass
        skip(90 days);

        // Step 3: Alice starts cooldown for withdrawal
        vm.prank(alice);
        susd3Strategy.startCooldown(aliceSusd3Shares);

        // Wait for cooldown to complete
        skip(7 days + 1);

        // Step 4: Now the attack - Helper deposits 1 wei to sUSD3
        // This gives sUSD3 contract a commitment timestamp
        airdrop(underlyingAsset, mockHelper, 1e6);
        vm.startPrank(mockHelper);
        underlyingAsset.approve(address(usd3Strategy), 1);

        // Helper can deposit on behalf of sUSD3 because it's whitelisted
        usd3Strategy.deposit(1, address(susd3Strategy));
        vm.stopPrank();

        // Verify sUSD3 now has a commitment timestamp
        uint256 susd3CommitmentTime = usd3Strategy.depositTimestamp(
            address(susd3Strategy)
        );
        assertGt(
            susd3CommitmentTime,
            0,
            "sUSD3 should have commitment timestamp"
        );

        // Step 5: Alice tries to withdraw from sUSD3 - THIS SHOULD SUCCEED DESPITE sUSD3's COMMITMENT
        vm.startPrank(alice);

        // Check Alice is in valid withdrawal window
        (
            uint256 cooldownEnd,
            uint256 windowEnd,
            uint256 cooldownShares
        ) = susd3Strategy.getCooldownStatus(alice);
        assertLt(block.timestamp, windowEnd, "Should be in withdrawal window");
        assertGt(cooldownShares, 0, "Should have cooldown shares");

        // Get balances before withdrawal
        uint256 aliceUsd3Before = IERC20(address(usd3Strategy)).balanceOf(
            alice
        );

        // Approve sUSD3 to burn shares
        IERC20(address(susd3Strategy)).approve(
            address(susd3Strategy),
            aliceSusd3Shares
        );

        // Withdraw should succeed because sUSD3 is exempt from commitment restrictions
        susd3Strategy.redeem(aliceSusd3Shares, alice, alice);

        // Verify withdrawal succeeded
        uint256 aliceUsd3After = IERC20(address(usd3Strategy)).balanceOf(alice);
        assertGt(
            aliceUsd3After,
            aliceUsd3Before,
            "Alice should have received USD3"
        );
        assertEq(
            IERC20(address(susd3Strategy)).balanceOf(alice),
            0,
            "Alice should have no sUSD3 left"
        );
        vm.stopPrank();

        // Step 6: Verify that even with commitment extended, withdrawals still work
        skip(6 days); // Almost at end of commitment

        // Helper deposits another 1 wei to reset commitment
        vm.startPrank(mockHelper);
        underlyingAsset.approve(address(usd3Strategy), 1);
        usd3Strategy.deposit(1, address(susd3Strategy));
        vm.stopPrank();

        // Commitment has been extended again
        uint256 newCommitmentTime = usd3Strategy.depositTimestamp(
            address(susd3Strategy)
        );
        assertGt(
            newCommitmentTime,
            susd3CommitmentTime,
            "Commitment should be extended"
        );

        // But this doesn't affect sUSD3's ability to operate
        // (Alice already withdrew, but if there were other users, they could still withdraw)

        emit log_string(
            "TEST RESULT: sUSD3 withdrawals work correctly despite commitment timestamp!"
        );
        emit log_string(
            "Fix successfully prevents DoS attack by exempting sUSD3 from transfer restrictions"
        );
    }
}

/**
 * @notice Flash loan attacker contract
 */
contract FlashLoanAttacker {
    USD3 public immutable usd3;
    IERC20 public immutable usdc;

    constructor(address _usd3, address _usdc) {
        usd3 = USD3(_usd3);
        usdc = IERC20(_usdc);
    }

    function attack() external {
        // Approve and deposit
        usdc.approve(address(usd3), 1000e6);
        usd3.deposit(1000e6, address(this));

        // Try to immediately transfer (should fail)
        IERC20(address(usd3)).transfer(
            msg.sender,
            IERC20(address(usd3)).balanceOf(address(this))
        );
    }
}

/**
 * @notice Reentrant receiver contract
 */
contract ReentrantReceiver {
    address public immutable token;
    bool public reentered;

    constructor(address _token) {
        token = _token;
    }

    // ERC20 receive hook (if it existed)
    function onERC20Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        if (!reentered) {
            reentered = true;
            // Try to transfer during receive (would cause reentrancy if vulnerable)
            try IERC20(token).transfer(msg.sender, 1) {} catch {}
        }
        return this.onERC20Received.selector;
    }
}
