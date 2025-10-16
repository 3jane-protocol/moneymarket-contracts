// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {Helper} from "../../../../src/Helper.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {ErrorsLib} from "../../../../src/libraries/ErrorsLib.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Commitment Extension Griefing Test
 * @notice Demonstrates and tests fix for commitment extension griefing attack via Helper
 *
 * ISSUE: Helper.deposit() allowed third-party deposits, which could bypass USD3's
 * commitment extension protection if Helper was whitelisted as a depositor.
 *
 * ATTACK SCENARIO:
 * 1. Victim deposits to USD3 with commitment period
 * 2. Attacker calls Helper.deposit(dustAmount, victim, false)
 * 3. Victim's commitment timer resets to block.timestamp
 * 4. Attacker can repeat indefinitely, preventing victim from ever withdrawing
 *
 * FIX: Helper.deposit() now reverts with Unauthorized if msg.sender != receiver
 */
contract CommitmentExtensionGriefingTest is Setup {
    Helper public helperContract;

    address public victim = makeAddr("victim");
    address public attacker = makeAddr("attacker");

    uint256 public constant DEPOSIT_AMOUNT = 10_000e6; // 10K USDC
    uint256 public constant DUST_AMOUNT = 1e6; // 1 USDC
    uint256 public constant COMMITMENT_TIME = 30 days;

    function setUp() public override {
        super.setUp();

        // Deploy Helper contract
        helperContract = new Helper(
            address(USD3(address(strategy)).morphoCredit()),
            address(strategy),
            makeAddr("dummySUSD3"), // sUSD3 not needed for this test (using hop=false)
            address(underlyingAsset),
            address(waUSDC)
        );

        // Set commitment time in ProtocolConfig
        bytes32 USD3_COMMITMENT_KEY = keccak256("USD3_COMMITMENT_TIME");
        testProtocolConfig.setConfig(USD3_COMMITMENT_KEY, COMMITMENT_TIME);

        // Fund users with USDC
        deal(address(underlyingAsset), victim, DEPOSIT_AMOUNT);
        deal(address(underlyingAsset), attacker, DUST_AMOUNT * 10); // Attacker has enough for multiple attacks

        // Approve Helper to spend USDC
        vm.prank(victim);
        underlyingAsset.approve(address(helperContract), type(uint256).max);

        vm.prank(attacker);
        underlyingAsset.approve(address(helperContract), type(uint256).max);

        // Whitelist Helper as a depositor in USD3 so it can make deposits
        // (our fix in Helper prevents third-party deposits through it)
        vm.prank(strategy.management());
        USD3(address(strategy)).setDepositorWhitelist(address(helperContract), true);
    }

    /**
     * @notice Test that Helper correctly blocks third-party deposits
     * @dev This test verifies the fix: Helper.deposit() should revert when msg.sender != receiver
     */
    function test_helper_blocksThirdPartyDeposits() public {
        // Victim makes initial deposit through Helper
        vm.prank(victim);
        helperContract.deposit(DEPOSIT_AMOUNT, victim, false);

        uint256 initialTimestamp = USD3(address(strategy)).depositTimestamp(victim);
        assertEq(initialTimestamp, block.timestamp, "Initial timestamp not set");

        // Fast forward past commitment period
        skip(COMMITMENT_TIME + 1 days);

        // Attacker tries to extend victim's commitment by depositing on their behalf
        // This should revert with Unauthorized
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(attacker);
        helperContract.deposit(DUST_AMOUNT, victim, false);

        // Verify victim's timestamp was NOT updated
        uint256 finalTimestamp = USD3(address(strategy)).depositTimestamp(victim);
        assertEq(finalTimestamp, initialTimestamp, "Timestamp should not have changed");

        // Verify victim can still withdraw (commitment period passed)
        uint256 withdrawLimit = strategy.availableWithdrawLimit(victim);
        assertGt(withdrawLimit, 0, "Victim should be able to withdraw");
    }

    /**
     * @notice Test that users can still deposit for themselves through Helper
     * @dev Helper should allow self-deposits (msg.sender == receiver)
     */
    function test_helper_allowsSelfDeposits() public {
        // Victim deposits for themselves - should succeed
        vm.prank(victim);
        uint256 shares = helperContract.deposit(DEPOSIT_AMOUNT, victim, false);

        assertGt(shares, 0, "Should receive shares from self-deposit");
        assertEq(strategy.balanceOf(victim), shares, "Victim should have shares");
    }

    /**
     * @notice Demonstrate the attack scenario (would succeed without the fix)
     * @dev This test documents what the attack would look like
     */
    function test_documentAttackScenario() public {
        // Victim makes initial deposit
        vm.prank(victim);
        helperContract.deposit(DEPOSIT_AMOUNT, victim, false);

        uint256 initialTimestamp = USD3(address(strategy)).depositTimestamp(victim);

        // Fast forward 29 days (almost at withdrawal time)
        skip(29 days);

        // Verify victim cannot withdraw yet (1 day remaining)
        uint256 withdrawLimit = strategy.availableWithdrawLimit(victim);
        assertEq(withdrawLimit, 0, "Victim should not be able to withdraw yet");

        // WITHOUT FIX: Attacker could extend commitment here by calling:
        // helperContract.deposit(DUST_AMOUNT, victim, false)
        // This would reset victim's timestamp and force them to wait another 30 days

        // WITH FIX: The attack reverts
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(attacker);
        helperContract.deposit(DUST_AMOUNT, victim, false);

        // Verify timestamp unchanged
        assertEq(
            USD3(address(strategy)).depositTimestamp(victim),
            initialTimestamp,
            "Timestamp should remain unchanged after blocked attack"
        );

        // Fast forward the remaining day
        skip(2 days);

        // Victim can now withdraw
        withdrawLimit = strategy.availableWithdrawLimit(victim);
        assertGt(withdrawLimit, 0, "Victim should be able to withdraw after commitment period");
    }

    /**
     * @notice Test with referral function variant
     * @dev Both deposit functions should have the same protection
     */
    function test_helper_blocksThirdPartyDepositsWithReferral() public {
        bytes32 referral = keccak256("test_referral");

        // Attacker tries to deposit on behalf of victim using referral variant
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vm.prank(attacker);
        helperContract.deposit(DUST_AMOUNT, victim, false, referral);
    }
}
