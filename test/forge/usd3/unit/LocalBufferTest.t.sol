// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IERC20} from "../../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title Local Buffer Test
 * @notice Tests the local waUSDC buffer management in USD3
 * @dev Verifies buffer accumulation, usage, and gas optimization
 */
contract LocalBufferTest is Setup {
    USD3 public usd3Strategy;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    function setUp() public override {
        super.setUp();
        usd3Strategy = USD3(address(strategy));

        // Fund test users with USDC
        airdrop(asset, alice, 10000e6);
        airdrop(asset, bob, 10000e6);
        airdrop(asset, charlie, 10000e6);
    }

    function test_localWaUSDCBufferAccumulates() public {
        // Set maxOnCredit to 80% so 20% stays local
        setMaxOnCredit(8000);

        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(1000e6, alice);
        vm.stopPrank();

        // Check buffer accumulated (~20% of deposit)
        uint256 localBuffer = usd3Strategy.balanceOfWaUSDC();
        uint256 deployed = usd3Strategy.suppliedWaUSDC();
        uint256 total = localBuffer + deployed;

        assertApproxEqAbs(localBuffer, total * 2000 / 10000, 2, "Local buffer should be ~20%");
        assertApproxEqAbs(deployed, total * 8000 / 10000, 2, "Deployed should be ~80%");

        // Bob deposits, buffer should maintain ratio
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 2000e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(2000e6, bob);
        vm.stopPrank();

        localBuffer = usd3Strategy.balanceOfWaUSDC();
        deployed = usd3Strategy.suppliedWaUSDC();
        total = localBuffer + deployed;

        assertApproxEqAbs(localBuffer, total * 2000 / 10000, 2, "Buffer ratio not maintained");
    }

    function test_withdrawUsesLocalBufferFirst() public {
        // Set maxOnCredit to create local buffer
        setMaxOnCredit(7000); // 70% deployed, 30% local

        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(1000e6, alice);
        vm.stopPrank();

        uint256 localBufferBefore = usd3Strategy.balanceOfWaUSDC();
        uint256 deployedBefore = usd3Strategy.suppliedWaUSDC();

        assertGt(localBufferBefore, 0, "Should have local buffer");

        // Small withdrawal should use local buffer only
        uint256 smallWithdraw = localBufferBefore / 2; // Half of local buffer in USDC terms

        vm.startPrank(alice);
        uint256 sharesNeeded = ITokenizedStrategy(address(usd3Strategy)).previewWithdraw(smallWithdraw);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), sharesNeeded);
        ITokenizedStrategy(address(usd3Strategy)).withdraw(smallWithdraw, alice, alice);
        vm.stopPrank();

        uint256 localBufferAfter = usd3Strategy.balanceOfWaUSDC();
        uint256 deployedAfter = usd3Strategy.suppliedWaUSDC();

        // Local buffer should decrease
        assertLt(localBufferAfter, localBufferBefore, "Local buffer should decrease");
        // Deployed amount should stay the same
        assertEq(deployedAfter, deployedBefore, "Deployed amount should not change");
    }

    function test_maxOnCreditEnforcesLocalBuffer() public {
        // Test different maxOnCredit ratios
        uint256[] memory ratios = new uint256[](5);
        ratios[0] = 0; // 0% - all local
        ratios[1] = 2500; // 25% deployed
        ratios[2] = 5000; // 50% deployed
        ratios[3] = 7500; // 75% deployed
        ratios[4] = 10000; // 100% deployed

        for (uint256 i = 0; i < ratios.length; i++) {
            // Reset state
            vm.startPrank(alice);
            uint256 aliceBalance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);
            if (aliceBalance > 0) {
                ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), aliceBalance);
                ITokenizedStrategy(address(usd3Strategy)).redeem(aliceBalance, alice, alice);
            }
            vm.stopPrank();

            // Set new ratio
            setMaxOnCredit(ratios[i]);

            // Deposit
            deal(address(asset), alice, 1000e6);
            vm.startPrank(alice);
            asset.approve(address(usd3Strategy), 1000e6);
            ITokenizedStrategy(address(usd3Strategy)).deposit(1000e6, alice);
            vm.stopPrank();

            uint256 localBuffer = usd3Strategy.balanceOfWaUSDC();
            uint256 deployed = usd3Strategy.suppliedWaUSDC();
            uint256 total = localBuffer + deployed;

            uint256 expectedDeployed = (total * ratios[i]) / 10000;
            uint256 expectedLocal = total - expectedDeployed;

            assertApproxEqAbs(deployed, expectedDeployed, 2, "Incorrect deployed amount");
            assertApproxEqAbs(localBuffer, expectedLocal, 2, "Incorrect local buffer");
        }
    }

    function test_tendRebalancesBuffer() public {
        // Initial deposit with 50% ratio
        setMaxOnCredit(5000);

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(1000e6, alice);
        vm.stopPrank();

        uint256 localBefore = usd3Strategy.balanceOfWaUSDC();
        uint256 deployedBefore = usd3Strategy.suppliedWaUSDC();

        // Change ratio to 90%
        setMaxOnCredit(9000);

        // Tend should rebalance
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        uint256 localAfter = usd3Strategy.balanceOfWaUSDC();
        uint256 deployedAfter = usd3Strategy.suppliedWaUSDC();

        assertLt(localAfter, localBefore, "Local buffer should decrease");
        assertGt(deployedAfter, deployedBefore, "Deployed should increase");

        uint256 total = localAfter + deployedAfter;
        assertApproxEqAbs(deployedAfter, (total * 9000) / 10000, 2, "Should be ~90% deployed");
    }

    function test_bufferReducesGasCosts() public {
        // Setup: deposit to create local buffer
        setMaxOnCredit(5000); // 50% local buffer

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 2000e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(2000e6, alice);
        vm.stopPrank();

        // Measure gas for withdrawal from local buffer
        uint256 withdrawAmount = 500e6; // Should be fully covered by local buffer

        vm.startPrank(alice);
        uint256 sharesNeeded = ITokenizedStrategy(address(usd3Strategy)).previewWithdraw(withdrawAmount);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), sharesNeeded);

        uint256 gasStart = gasleft();
        ITokenizedStrategy(address(usd3Strategy)).withdraw(withdrawAmount, alice, alice);
        uint256 gasUsedLocal = gasStart - gasleft();
        vm.stopPrank();

        console2.log("Gas used for local buffer withdrawal:", gasUsedLocal);

        // Now force a withdrawal from MorphoCredit
        // First deplete local buffer
        setMaxOnCredit(10000); // Deploy everything

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        assertEq(usd3Strategy.balanceOfWaUSDC(), 0, "Should have no local buffer");

        // Measure gas for withdrawal from MorphoCredit
        vm.startPrank(alice);
        sharesNeeded = ITokenizedStrategy(address(usd3Strategy)).previewWithdraw(withdrawAmount);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), sharesNeeded);

        gasStart = gasleft();
        ITokenizedStrategy(address(usd3Strategy)).withdraw(withdrawAmount, alice, alice);
        uint256 gasUsedMorpho = gasStart - gasleft();
        vm.stopPrank();

        console2.log("Gas used for MorphoCredit withdrawal:", gasUsedMorpho);

        // Local buffer withdrawal should use less gas
        assertLt(gasUsedLocal, gasUsedMorpho, "Local buffer should be more gas efficient");
        console2.log("Gas savings:", gasUsedMorpho - gasUsedLocal);
    }

    function test_bufferWithMultipleDepositsAndWithdrawals() public {
        // Set moderate buffer
        setMaxOnCredit(6000); // 60% deployed, 40% local

        // Multiple deposits
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(1000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 500e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(500e6, bob);
        vm.stopPrank();

        vm.startPrank(charlie);
        asset.approve(address(usd3Strategy), 1500e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(1500e6, charlie);
        vm.stopPrank();

        uint256 totalDeposited = 3000e6;
        uint256 totalWaUSDC = usd3Strategy.balanceOfWaUSDC() + usd3Strategy.suppliedWaUSDC();
        assertEq(totalWaUSDC, totalDeposited, "Total waUSDC should match deposits");

        // Multiple withdrawals
        vm.startPrank(alice);
        uint256 aliceShares = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), aliceShares / 2);
        ITokenizedStrategy(address(usd3Strategy)).redeem(aliceShares / 2, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobShares = ITokenizedStrategy(address(usd3Strategy)).balanceOf(bob);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), bobShares);
        ITokenizedStrategy(address(usd3Strategy)).redeem(bobShares, bob, bob);
        vm.stopPrank();

        // Check buffer ratio after withdrawals
        // Note: After partial withdrawals, the ratio might not be exactly maintained
        // until the next tend() call rebalances it
        uint256 localAfter = usd3Strategy.balanceOfWaUSDC();
        uint256 deployedAfter = usd3Strategy.suppliedWaUSDC();
        uint256 totalAfter = localAfter + deployedAfter;

        // Trigger tend to rebalance
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        localAfter = usd3Strategy.balanceOfWaUSDC();
        deployedAfter = usd3Strategy.suppliedWaUSDC();
        totalAfter = localAfter + deployedAfter;

        if (totalAfter > 0) {
            uint256 deployedRatio = (deployedAfter * 10000) / totalAfter;
            assertApproxEqAbs(deployedRatio, 6000, 200, "Ratio should stay close to 60% after rebalance");
        }
    }

    function test_bufferWithZeroMaxOnCredit() public {
        // Set maxOnCredit to 0 - everything stays local
        setMaxOnCredit(0);

        // Deposit
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 1000e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(1000e6, alice);
        vm.stopPrank();

        uint256 localBuffer = usd3Strategy.balanceOfWaUSDC();
        uint256 deployed = usd3Strategy.suppliedWaUSDC();

        assertEq(localBuffer, 1000e6, "All funds should be local");
        assertEq(deployed, 0, "Nothing should be deployed");

        // Withdrawals should work from local buffer
        vm.startPrank(alice);
        uint256 shares = ITokenizedStrategy(address(usd3Strategy)).balanceOf(alice);
        ITokenizedStrategy(address(usd3Strategy)).approve(address(usd3Strategy), shares);
        uint256 withdrawn = ITokenizedStrategy(address(usd3Strategy)).redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(withdrawn, 1000e6, 1, "Should withdraw full amount");
        assertEq(usd3Strategy.balanceOfWaUSDC(), 0, "Local buffer should be empty");
    }

    function test_bufferRebalancingWithLargeSwings() public {
        // Start with 50% deployment
        setMaxOnCredit(5000);

        // Large deposit
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        ITokenizedStrategy(address(usd3Strategy)).deposit(5000e6, alice);
        vm.stopPrank();

        // Suddenly change to 100% deployment
        setMaxOnCredit(10000);

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        assertEq(usd3Strategy.balanceOfWaUSDC(), 0, "Should deploy everything");

        // Then change to 0% deployment
        setMaxOnCredit(0);

        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        assertEq(usd3Strategy.suppliedWaUSDC(), 0, "Should withdraw everything from MorphoCredit");
        assertGt(usd3Strategy.balanceOfWaUSDC(), 0, "Should have everything local");
    }
}
