// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "../../../../lib/openzeppelin/contracts/interfaces/IERC4626.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "../../../../lib/openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title WaUSDC Wrapping Test
 * @notice Tests the USDC to waUSDC wrapping functionality in USD3
 * @dev Verifies that USD3 correctly wraps USDC to waUSDC internally while accepting USDC from users
 */
contract WaUSDCWrappingTest is Setup {
    USD3 public usd3Strategy;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        usd3Strategy = USD3(address(strategy));

        // Fund test users with USDC
        airdrop(asset, alice, 10000e6);
        airdrop(asset, bob, 10000e6);
    }

    function test_depositWrapsUSDCToWaUSDC() public {
        uint256 depositAmount = 1000e6;

        // Check initial balances
        uint256 initialUSDC = asset.balanceOf(alice);
        uint256 initialWaUSDC = waUSDC.balanceOf(address(usd3Strategy));

        // Alice deposits USDC
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), depositAmount);
        uint256 shares = ITokenizedStrategy(address(usd3Strategy)).deposit(depositAmount, alice);
        vm.stopPrank();

        // Check that USDC was taken from Alice
        assertEq(asset.balanceOf(alice), initialUSDC - depositAmount, "USDC not taken from Alice");

        // Check that strategy now holds waUSDC (either locally or in MorphoCredit)
        uint256 totalWaUSDC = usd3Strategy.balanceOfWaUSDC() + usd3Strategy.suppliedWaUSDC();
        assertEq(totalWaUSDC, initialWaUSDC + depositAmount, "waUSDC not created correctly");

        // Check that Alice received shares
        assertGt(shares, 0, "No shares minted");
        assertEq(ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice), shares, "Incorrect shares balance");
    }

    function test_withdrawUnwrapsWaUSDCToUSDC() public {
        uint256 depositAmount = 1000e6;
        uint256 withdrawAmount = 500e6;

        // Alice deposits first
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), depositAmount);
        ITokenizedStrategy(address(usd3Strategy)).deposit(depositAmount, alice);
        vm.stopPrank();

        // Trigger tend to potentially deploy funds
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        // Check Alice's USDC balance before withdrawal
        uint256 usdcBefore = asset.balanceOf(alice);

        // Alice withdraws USDC
        vm.startPrank(alice);
        uint256 sharesNeeded = ITokenizedStrategy(address(usd3Strategy)).previewWithdraw(withdrawAmount);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), sharesNeeded);
        uint256 sharesRedeemed = ITokenizedStrategy(address(usd3Strategy)).withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        // Check that Alice received USDC (not waUSDC)
        assertEq(asset.balanceOf(alice), usdcBefore + withdrawAmount, "Incorrect USDC received");
        assertEq(waUSDC.balanceOf(alice), 0, "Alice should not receive waUSDC");

        // Check shares were burned
        assertGt(sharesRedeemed, 0, "No shares redeemed");
    }

    function test_localWaUSDCBufferManagement() public {
        uint256 depositAmount = 1000e6;

        // Deposit with maxOnCredit set to 0 to keep everything local
        setMaxOnCredit(0);

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), depositAmount);
        ITokenizedStrategy(address(usd3Strategy)).deposit(depositAmount, alice);
        vm.stopPrank();

        // Check all waUSDC is held locally
        uint256 localWaUSDC = usd3Strategy.balanceOfWaUSDC();
        uint256 deployedWaUSDC = usd3Strategy.suppliedWaUSDC();

        assertEq(localWaUSDC, depositAmount, "waUSDC not held locally");
        assertEq(deployedWaUSDC, 0, "waUSDC incorrectly deployed");

        // Now set maxOnCredit to 50% and trigger tend
        setMaxOnCredit(5000); // 50%

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        // Check that half is deployed
        localWaUSDC = usd3Strategy.balanceOfWaUSDC();
        deployedWaUSDC = usd3Strategy.suppliedWaUSDC();

        assertApproxEqAbs(localWaUSDC, depositAmount / 2, 1, "Incorrect local balance after tend");
        assertApproxEqAbs(deployedWaUSDC, depositAmount / 2, 1, "Incorrect deployed balance after tend");
    }

    function test_maxOnCreditRatioWithWrapping() public {
        uint256 depositAmount = 1000e6;
        uint256 maxOnCreditRatio = 7000; // 70%

        setMaxOnCredit(maxOnCreditRatio);

        // Deposit USDC
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), depositAmount);
        ITokenizedStrategy(address(usd3Strategy)).deposit(depositAmount, alice);
        vm.stopPrank();

        // Check deployment ratio
        uint256 deployed = usd3Strategy.suppliedWaUSDC();
        uint256 local = usd3Strategy.balanceOfWaUSDC();
        uint256 total = deployed + local;

        uint256 expectedDeployed = (total * maxOnCreditRatio) / 10000;
        assertApproxEqAbs(deployed, expectedDeployed, 2, "Incorrect deployment ratio");
    }

    function test_tendRebalancesWrappedAssets() public {
        uint256 initialDeposit = 1000e6;

        // Start with 50% deployment ratio
        setMaxOnCredit(5000);

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), initialDeposit);
        ITokenizedStrategy(address(usd3Strategy)).deposit(initialDeposit, alice);
        vm.stopPrank();

        uint256 deployedBefore = usd3Strategy.suppliedWaUSDC();
        uint256 localBefore = usd3Strategy.balanceOfWaUSDC();

        // Change to 80% deployment ratio
        setMaxOnCredit(8000);

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        uint256 deployedAfter = usd3Strategy.suppliedWaUSDC();
        uint256 localAfter = usd3Strategy.balanceOfWaUSDC();

        // More should be deployed now
        assertGt(deployedAfter, deployedBefore, "Deployment didn't increase");
        assertLt(localAfter, localBefore, "Local balance didn't decrease");

        uint256 total = deployedAfter + localAfter;
        uint256 expectedDeployed = (total * 8000) / 10000;
        assertApproxEqAbs(deployedAfter, expectedDeployed, 2, "Incorrect rebalanced ratio");
    }

    function test_previewFunctionsWithWrapping() public {
        uint256 depositAmount = 1000e6;

        // Test preview before any deposits
        uint256 previewShares = ITokenizedStrategy(address(usd3Strategy)).previewDeposit(depositAmount);
        assertGt(previewShares, 0, "Preview shares should be positive");

        // Actual deposit
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), depositAmount);
        uint256 actualShares = ITokenizedStrategy(address(usd3Strategy)).deposit(depositAmount, alice);
        vm.stopPrank();

        // Preview should match actual (first deposit)
        assertEq(actualShares, previewShares, "Preview doesn't match actual");

        // Test preview withdraw
        uint256 withdrawAmount = 500e6;
        uint256 previewSharesNeeded = ITokenizedStrategy(address(usd3Strategy)).previewWithdraw(withdrawAmount);

        vm.startPrank(alice);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), previewSharesNeeded);
        uint256 actualSharesUsed = ITokenizedStrategy(address(usd3Strategy)).withdraw(withdrawAmount, alice, alice);
        vm.stopPrank();

        assertEq(actualSharesUsed, previewSharesNeeded, "Preview withdraw doesn't match actual");
    }

    function test_wrappingPrecisionLoss() public {
        // Test with amounts that might cause rounding issues
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1; // Minimum amount
        amounts[1] = 999; // Odd amount
        amounts[2] = 1e6 - 1; // Just under 1 USDC
        amounts[3] = 123456789; // Random large number

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];

            // Give Bob exact amount needed
            deal(address(asset), bob, amount);

            vm.startPrank(bob);
            asset.approve(address(usd3Strategy), amount);
            uint256 shares = ITokenizedStrategy(address(usd3Strategy)).deposit(amount, bob);

            // Immediately withdraw to test round-trip precision
            ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), shares);
            uint256 withdrawn = ITokenizedStrategy(address(usd3Strategy)).redeem(shares, bob, bob);
            vm.stopPrank();

            // Should get back exactly what we put in (or very close)
            assertApproxEqAbs(withdrawn, amount, 1, "Precision loss in round-trip");
        }
    }

    function test_wrappingWithZeroAmount() public {
        // First deposit some assets to test zero withdraw
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(1000e6, alice);
        vm.stopPrank();

        // Test zero withdraw (should revert with ZERO_SHARES)
        vm.startPrank(alice);
        vm.expectRevert("ZERO_SHARES");
        ITokenizedStrategy(address(usd3Strategy)).withdraw(0, alice, alice);
        vm.stopPrank();

        // Test zero redeem (should also revert with ZERO_ASSETS)
        vm.startPrank(alice);
        vm.expectRevert("ZERO_ASSETS");
        ITokenizedStrategy(address(usd3Strategy)).redeem(0, alice, alice);
        vm.stopPrank();
    }

    function test_wrappingWithMaxUint256() public {
        // Test with maximum approval
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), type(uint256).max);

        // Deposit actual balance
        uint256 balance = asset.balanceOf(alice);
        uint256 shares = ITokenizedStrategy(address(usd3Strategy)).deposit(balance, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares");
        assertEq(asset.balanceOf(alice), 0, "All USDC should be deposited");

        // Check waUSDC was created
        uint256 totalWaUSDC = usd3Strategy.balanceOfWaUSDC() + usd3Strategy.suppliedWaUSDC();
        assertEq(totalWaUSDC, balance, "waUSDC should match deposited USDC");
    }

    function test_multipleUsersWrapping() public {
        uint256 aliceDeposit = 1000e6;
        uint256 bobDeposit = 2000e6;

        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), aliceDeposit);
        uint256 aliceShares = ITokenizedStrategy(address(usd3Strategy)).deposit(aliceDeposit, alice);
        vm.stopPrank();

        // Bob deposits
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), bobDeposit);
        uint256 bobShares = ITokenizedStrategy(address(usd3Strategy)).deposit(bobDeposit, bob);
        vm.stopPrank();

        // Total waUSDC should equal sum of deposits
        uint256 totalWaUSDC = usd3Strategy.balanceOfWaUSDC() + usd3Strategy.suppliedWaUSDC();
        assertEq(totalWaUSDC, aliceDeposit + bobDeposit, "Total waUSDC incorrect");

        // Shares should be proportional to deposits
        assertApproxEqRel(
            aliceShares * bobDeposit,
            bobShares * aliceDeposit,
            1e15, // 0.1% tolerance
            "Shares not proportional to deposits"
        );

        // Both can withdraw
        vm.startPrank(alice);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), aliceShares);
        uint256 aliceWithdrawn = ITokenizedStrategy(address(usd3Strategy)).redeem(aliceShares, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), bobShares);
        uint256 bobWithdrawn = ITokenizedStrategy(address(usd3Strategy)).redeem(bobShares, bob, bob);
        vm.stopPrank();

        // Should get back approximately what they put in
        assertApproxEqAbs(aliceWithdrawn, aliceDeposit, 2, "Alice withdrawal incorrect");
        assertApproxEqAbs(bobWithdrawn, bobDeposit, 2, "Bob withdrawal incorrect");
    }
}
