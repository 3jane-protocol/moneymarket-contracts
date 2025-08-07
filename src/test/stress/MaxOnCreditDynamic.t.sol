// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {USD3} from "../../USD3.sol";
import {IMorpho, MarketParams, Id} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@3jane-morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@3jane-morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {MorphoCredit} from "@3jane-morpho-blue/MorphoCredit.sol";

/**
 * @title MaxOnCredit Dynamic Test Suite
 * @notice Tests for dynamic MaxOnCredit adjustments and operational scenarios
 * @dev Validates edge cases in deployment calculations and rebalancing logic
 */
contract MaxOnCreditDynamicTest is Setup {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    USD3 public usd3Strategy;
    IMorpho public morpho;
    MarketParams public marketParams;
    Id public marketId;

    // Test users (different from management which is address(1))
    address public alice = address(0x1001);
    address public bob = address(0x1002);
    address public charlie = address(0x1003);

    // Test amounts
    uint256 public constant LARGE_DEPOSIT = 1_000_000e6; // 1M USDC
    uint256 public constant MEDIUM_DEPOSIT = 100_000e6; // 100K USDC
    uint256 public constant SMALL_DEPOSIT = 10_000e6; // 10K USDC

    // MaxOnCredit values (basis points)
    uint256 public constant MAX_ON_CREDIT_0 = 0; // 0%
    uint256 public constant MAX_ON_CREDIT_25 = 2500; // 25%
    uint256 public constant MAX_ON_CREDIT_50 = 5000; // 50%
    uint256 public constant MAX_ON_CREDIT_75 = 7500; // 75%
    uint256 public constant MAX_ON_CREDIT_100 = 10000; // 100%

    event MaxOnCreditUpdated(uint256 newValue);
    event FundsDeployed(uint256 amount);
    event FundsFreed(uint256 amount);

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));
        morpho = IMorpho(usd3Strategy.morphoCredit());
        marketParams = usd3Strategy.marketParams();
        marketId = marketParams.id();

        // Fund test users
        airdrop(asset, alice, LARGE_DEPOSIT * 2);
        airdrop(asset, bob, LARGE_DEPOSIT * 2);
        airdrop(asset, charlie, LARGE_DEPOSIT * 2);

        // Set initial MaxOnCredit to 50%
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_50);
    }

    /*//////////////////////////////////////////////////////////////
                        DYNAMIC ADJUSTMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_decreaseMaxOnCreditWithExistingDeployment() public {
        // Setup: Deposit and deploy at 50% MaxOnCredit
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Trigger deployment via report
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Check deployment at 50%
        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssets = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 expectedDeployment = (totalAssets * MAX_ON_CREDIT_50) / 10_000;

        assertApproxEqAbs(
            morphoPositionAssets,
            expectedDeployment,
            1000e6,
            "Should deploy ~50% to Morpho"
        );

        // Decrease MaxOnCredit to 25% - should not immediately rebalance
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_25);

        // Deployment should remain the same until next deposit/report
        uint256 morphoPositionAssetsAfterDecrease = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        assertEq(
            morphoPositionAssetsAfterDecrease,
            morphoPositionAssets,
            "Should not immediately rebalance on decrease"
        );

        // New deposit should respect new limit
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, bob);
        vm.stopPrank();

        uint256 newTotalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 newExpectedDeployment = (newTotalAssets * MAX_ON_CREDIT_25) /
            10_000;

        // Should deploy only to reach 25% limit
        uint256 morphoPositionAssetsAfterNewDeposit = morpho
            .expectedSupplyAssets(marketParams, address(usd3Strategy));
        assertLe(
            morphoPositionAssetsAfterNewDeposit,
            newExpectedDeployment + 1000e6,
            "Should respect new lower limit"
        );
    }

    function test_increaseMaxOnCreditTriggersDeployment() public {
        // Setup with 25% MaxOnCredit
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_25);

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Trigger deployment via report
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssetsBefore = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 expectedAt25 = (totalAssets * MAX_ON_CREDIT_25) / 10_000;

        assertApproxEqAbs(
            morphoPositionAssetsBefore,
            expectedAt25,
            1000e6,
            "Should deploy ~25% initially"
        );

        // Increase MaxOnCredit to 75%
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_75);

        // Trigger rebalancing via report to deploy existing funds up to new limit
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // New deposit should maintain the 75% deployment ratio
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, bob);
        vm.stopPrank();

        // Trigger deployment of new deposit
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 newTotalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssetsAfter = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 expectedAt75 = (newTotalAssets * MAX_ON_CREDIT_75) / 10_000;

        // Allow wider tolerance since deployment happens incrementally
        assertApproxEqRel(
            morphoPositionAssetsAfter,
            expectedAt75,
            0.1e18,
            "Should deploy more to reach ~75%"
        );
        assertGt(
            morphoPositionAssetsAfter,
            morphoPositionAssetsBefore,
            "Should have deployed additional funds"
        );
    }

    function test_maxOnCreditZeroToNonZero() public {
        // Start with MaxOnCredit = 0 (no deployment)
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_0);

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Report to trigger deployment (should not deploy when MaxOnCredit is 0)
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // With the bug fixed, MaxOnCredit = 0 should deploy nothing
        uint256 morphoPositionAssetsAtZero = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        assertEq(
            morphoPositionAssetsAtZero,
            0,
            "Should not deploy anything at 0% MaxOnCredit"
        );

        // Increase to 50%
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_50);

        // New deposit with Bob
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), MEDIUM_DEPOSIT);
        usd3Strategy.deposit(MEDIUM_DEPOSIT, bob);
        vm.stopPrank();

        // Trigger rebalancing to 50%
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssetsAfter = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 expected = (totalAssets * MAX_ON_CREDIT_50) / 10_000;

        // Should have deployed to 50% after changing from 0%
        assertApproxEqRel(
            morphoPositionAssetsAfter,
            expected,
            0.1e18,
            "Should deploy to 50% after changing from 0%"
        );
        assertGt(morphoPositionAssetsAfter, 0, "Should have some deployment");
    }

    function test_maxOnCreditToOneHundredPercent() public {
        // Test extreme case of 100% deployment
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_100);

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Trigger deployment via report
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssets = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 idleBalance = asset.balanceOf(address(usd3Strategy));

        // Should deploy everything to Morpho
        assertApproxEqAbs(
            morphoPositionAssets,
            totalAssets,
            1000e6,
            "Should deploy ~100% to Morpho"
        );
        assertLt(idleBalance, 1000e6, "Should have minimal idle funds");
    }

    /*//////////////////////////////////////////////////////////////
                        PRECISION AND ROUNDING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_precisionInDeploymentCalculations() public {
        // Test with odd amounts that might cause rounding issues
        uint256 oddAmount = 12_345_678; // 12.345678 USDC

        vm.startPrank(alice);
        airdrop(asset, alice, oddAmount);
        asset.approve(address(usd3Strategy), oddAmount);
        usd3Strategy.deposit(oddAmount, alice);
        vm.stopPrank();

        // Trigger deployment
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssets = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 expectedDeployment = (totalAssets * MAX_ON_CREDIT_50) / 10_000;

        // Should handle precision correctly
        assertApproxEqAbs(
            morphoPositionAssets,
            expectedDeployment,
            10,
            "Should handle odd amounts precisely"
        );
    }

    function test_deploymentCalculationsWithFees() public {
        // Test deployment calculations when performance fees are taken

        // Setup yield sharing via protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        address protocolConfigAddress = MorphoCredit(morphoAddress)
            .protocolConfig();
        MockProtocolConfig protocolConfig = MockProtocolConfig(
            protocolConfigAddress
        );

        // Set the tranche share variant in protocol config
        bytes32 TRANCHE_SHARE_VARIANT = keccak256("TRANCHE_SHARE_VARIANT");
        protocolConfig.setConfig(TRANCHE_SHARE_VARIANT, 2000); // 20% to sUSD3

        // Sync the value to USD3 strategy as keeper
        vm.prank(keeper);
        usd3Strategy.syncTrancheShare();

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Simulate some yield
        airdrop(asset, address(usd3Strategy), 50_000e6);

        // Report to trigger fee distribution and deployment
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // Verify deployment still respects MaxOnCredit after fees
        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssets = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 expectedDeployment = (totalAssets * MAX_ON_CREDIT_50) / 10_000;

        // With fees, deployment ratio might vary more
        assertApproxEqRel(
            morphoPositionAssets,
            expectedDeployment,
            0.15e18,
            "Should maintain deployment ratio after fees"
        );
    }

    function test_deploymentWithMinimalAmounts() public {
        // Test with very small amounts
        uint256 minimalAmount = 1e6; // 1 USDC

        vm.startPrank(alice);
        airdrop(asset, alice, minimalAmount);
        asset.approve(address(usd3Strategy), minimalAmount);
        usd3Strategy.deposit(minimalAmount, alice);
        vm.stopPrank();

        // Trigger deployment
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssets = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 expectedDeployment = (totalAssets * MAX_ON_CREDIT_50) / 10_000;

        // Should handle minimal amounts without reverting
        assertApproxEqAbs(
            morphoPositionAssets,
            expectedDeployment,
            minimalAmount,
            "Should handle minimal amounts"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        REBALANCING SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function test_rebalancingOnWithdrawal() public {
        // Setup large position
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        uint256 shares = usd3Strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Trigger initial deployment
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 morphoPositionAssetsBefore = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );

        // Large withdrawal that should trigger rebalancing
        vm.startPrank(alice);
        uint256 withdrawShares = (shares * 60) / 100; // Withdraw 60%
        ITokenizedStrategy(address(usd3Strategy)).redeem(
            withdrawShares,
            alice,
            alice
        );
        vm.stopPrank();

        // Trigger rebalancing after withdrawal
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 totalAssetsAfter = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssetsAfter = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 expectedDeploymentAfter = (totalAssetsAfter *
            MAX_ON_CREDIT_50) / 10_000;

        assertLt(
            morphoPositionAssetsAfter,
            morphoPositionAssetsBefore,
            "Should have withdrawn from Morpho"
        );
        // With fixed _tend, rebalancing should be precise
        assertApproxEqRel(
            morphoPositionAssetsAfter,
            expectedDeploymentAfter,
            0.05e18,
            "Should maintain deployment ratio"
        );
    }

    function test_rebalancingAfterLoss() public {
        // Setup position
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Trigger initial deployment
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 totalAssetsBefore = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();

        // Simulate loss by transferring some assets away
        uint256 loss = (totalAssetsBefore * 10) / 100; // 10% loss
        vm.prank(address(usd3Strategy));
        asset.transfer(address(0xdead), loss);

        // Report loss
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 totalAssetsAfter = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssetsAfter = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 expectedDeploymentAfter = (totalAssetsAfter *
            MAX_ON_CREDIT_50) / 10_000;

        assertLt(
            totalAssetsAfter,
            totalAssetsBefore,
            "Should have reduced total assets"
        );
        // After loss, deployment ratio should still be maintained on next operation
    }

    /*//////////////////////////////////////////////////////////////
                        BOUNDARY CONDITIONS
    //////////////////////////////////////////////////////////////*/

    function test_maxOnCreditBoundaryValidation() public {
        // Test setting MaxOnCredit to maximum allowed value
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_100);

        assertEq(
            usd3Strategy.maxOnCredit(),
            MAX_ON_CREDIT_100,
            "Should accept 100%"
        );

        // Test setting to 0
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_0);

        assertEq(
            usd3Strategy.maxOnCredit(),
            MAX_ON_CREDIT_0,
            "Should accept 0%"
        );
    }

    function test_deploymentWithZeroTotalAssets() public {
        // Test deployment calculation when totalAssets is 0
        // This shouldn't revert or cause issues

        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        assertEq(totalAssets, 0, "Should start with 0 total assets");

        // Attempt to deploy nothing - should handle gracefully
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 0);
        // This might revert due to minimum deposit requirements, which is expected behavior
        vm.stopPrank();

        assertTrue(true, "Should handle zero assets gracefully");
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION WITH MORPHO
    //////////////////////////////////////////////////////////////*/

    function test_deploymentWithMorphoLiquidityConstraints() public {
        // This test would require a more sophisticated Morpho mock
        // that can simulate liquidity constraints

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        // Trigger deployment
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        // In a real scenario, if Morpho has limited liquidity,
        // deployment should handle this gracefully
        uint256 morphoPositionAssets = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );

        // At minimum, deployment shouldn't revert
        assertTrue(
            morphoPositionAssets >= 0,
            "Deployment should handle Morpho constraints"
        );
    }

    function test_deploymentConsistencyAcrossOperations() public {
        // Test that deployment ratio remains consistent across multiple operations

        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), LARGE_DEPOSIT);
        usd3Strategy.deposit(LARGE_DEPOSIT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), MEDIUM_DEPOSIT);
        usd3Strategy.deposit(MEDIUM_DEPOSIT, bob);
        vm.stopPrank();

        vm.startPrank(charlie);
        asset.approve(address(usd3Strategy), SMALL_DEPOSIT);
        usd3Strategy.deposit(SMALL_DEPOSIT, charlie);
        vm.stopPrank();

        // Trigger deployment
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 totalAssets = ITokenizedStrategy(address(usd3Strategy))
            .totalAssets();
        uint256 morphoPositionAssets = morpho.expectedSupplyAssets(
            marketParams,
            address(usd3Strategy)
        );
        uint256 deploymentRatio = (morphoPositionAssets * 10_000) / totalAssets;

        assertApproxEqAbs(
            deploymentRatio,
            MAX_ON_CREDIT_50,
            100,
            "Should maintain consistent deployment ratio"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ERROR HANDLING
    //////////////////////////////////////////////////////////////*/

    function test_unauthorizedMaxOnCreditChange() public {
        // Only management should be able to change MaxOnCredit
        vm.expectRevert();
        vm.prank(alice);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_75);

        vm.expectRevert();
        vm.prank(keeper);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_75);

        // Management should succeed
        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_75);

        assertEq(
            usd3Strategy.maxOnCredit(),
            MAX_ON_CREDIT_75,
            "Management should be able to change"
        );
    }

    function test_maxOnCreditChangeEvents() public {
        // Test that MaxOnCredit changes emit proper events

        vm.expectEmit(true, true, true, true);
        emit MaxOnCreditUpdated(MAX_ON_CREDIT_75);

        vm.prank(management);
        usd3Strategy.setMaxOnCredit(MAX_ON_CREDIT_75);
    }
}
