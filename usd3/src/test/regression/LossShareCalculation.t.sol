// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../USD3.sol";
import {sUSD3} from "../../sUSD3.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {console2} from "forge-std/console2.sol";
import {IMorpho, IMorphoCredit, MarketParams, Id} from "@3jane-morpho-blue/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@3jane-morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

/**
 * @title Test for Loss Share Calculation Bug
 * @notice Demonstrates that _postReportHook incorrectly calculates shares to burn
 * @dev Shows that using post-report values leads to burning incorrect shares from sUSD3
 *
 * The bug occurs because:
 * 1. report() reduces totalAssets by the loss amount
 * 2. _postReportHook is called AFTER this reduction
 * 3. convertToShares(loss) uses the NEW (reduced) totalAssets
 * 4. This results in an incorrect share calculation
 *
 * Example with simple numbers:
 * - Before: 100 assets, 100 shares, PPS = 1.0
 * - Loss: 20 assets
 * - After report: 80 assets, 100 shares, PPS = 0.8
 * - Bug: convertToShares(20) = 20 * 100 / 80 = 25 shares
 * - But we should only burn 20 shares (the loss at original PPS)
 *
 * In reality, the math is more complex due to the way losses are processed,
 * but the core issue remains: using post-report values gives wrong results.
 */
contract LossShareCalculationTest is Setup {
    using MorphoBalancesLib for IMorpho;

    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

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
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Set performance fee recipient to sUSD3
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFeeRecipient(address(susd3Strategy));

        // Setup test users with USDC
        airdrop(asset, alice, 10000e6);
        airdrop(asset, bob, 10000e6);
    }

    /**
     * @notice Test that demonstrates the loss calculation bug
     * @dev This test should FAIL with the current buggy implementation
     *      and PASS once we fix it to use pre-report values
     */
    function test_loss_calculation_bug() public {
        console2.log("\n=== Testing Loss Share Calculation Bug ===\n");

        // Step 1: Setup initial deposits
        // Alice deposits 850 USDC into USD3
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 850e6);
        usd3Strategy.deposit(850e6, alice);
        vm.stopPrank();

        // Bob deposits 150 USDC into USD3 (will stake to sUSD3)
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 150e6);
        usd3Strategy.deposit(150e6, bob);

        // Bob stakes his USD3 to sUSD3 (15% subordination)
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 150e6);
        susd3Strategy.deposit(150e6, bob);
        vm.stopPrank();

        // Initial state logging
        uint256 initialTotalAssets = ITokenizedStrategy(address(usd3Strategy)).totalAssets();
        uint256 initialTotalSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        uint256 initialSusd3Balance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        console2.log("Initial State:");
        console2.log("  USD3 totalAssets:", initialTotalAssets);
        console2.log("  USD3 totalSupply:", initialTotalSupply);
        console2.log("  sUSD3's USD3 balance:", initialSusd3Balance);
        console2.log("  Initial PPS:", (initialTotalAssets * 1e18) / initialTotalSupply);

        // Step 2: Simulate a loss in MorphoCredit
        // We'll simulate a 10% loss (100 USDC)
        uint256 lossAmount = 100e6;

        // To simulate loss, we need to reduce the assets in MorphoCredit
        // We'll do this by manipulating the market state
        MarketParams memory params = usd3Strategy.marketParams();

        // First deploy some funds to MorphoCredit
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        IMorpho morpho = usd3Strategy.morphoCredit();
        uint256 assetsInMorpho = morpho.expectedSupplyAssets(params, address(usd3Strategy));
        console2.log("\nAssets in MorphoCredit before loss:", assetsInMorpho);

        // Simulate loss by having someone borrow without collateral and not repay
        // For simplicity, we'll use a more direct approach:
        // We'll withdraw some assets from the strategy's position to simulate a loss

        // Simulate a loss by having the strategy withdraw and then lose assets
        // First, we need to free up some funds from MorphoCredit
        vm.startPrank(address(usd3Strategy));

        // Get current idle balance
        uint256 idleBalance = asset.balanceOf(address(usd3Strategy));
        console2.log("Idle balance before withdrawal:", idleBalance);

        if (idleBalance < lossAmount) {
            // Need to withdraw from MorphoCredit
            uint256 toWithdraw = lossAmount - idleBalance;
            morpho.withdraw(params, toWithdraw, 0, address(usd3Strategy), address(usd3Strategy));
        }

        // Now simulate the loss
        asset.transfer(address(0xdead), lossAmount);
        vm.stopPrank();

        console2.log("\nSimulated loss of:", lossAmount);

        // Step 3: Call report to trigger loss processing
        console2.log("\n--- Calling report() ---");

        // Capture pre-report values for comparison
        uint256 preReportTotalAssets = ITokenizedStrategy(address(usd3Strategy)).totalAssets();
        uint256 preReportTotalSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        uint256 preReportSusd3Balance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        console2.log("\nPre-report values:");
        console2.log("  totalAssets:", preReportTotalAssets);
        console2.log("  totalSupply:", preReportTotalSupply);
        console2.log("  sUSD3 balance:", preReportSusd3Balance);

        // Calculate what the correct share burn should be
        // Using pre-report values: shares = loss * totalSupply / totalAssets
        uint256 expectedSharesBurned = (lossAmount * preReportTotalSupply) / preReportTotalAssets;
        console2.log("\nExpected shares to burn (using pre-report values):", expectedSharesBurned);

        // Call report - this will trigger _postReportHook
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = ITokenizedStrategy(address(usd3Strategy)).report();

        console2.log("\nReport results:");
        console2.log("  Profit:", profit);
        console2.log("  Loss:", loss);

        // Check post-report state
        uint256 postReportTotalAssets = ITokenizedStrategy(address(usd3Strategy)).totalAssets();
        uint256 postReportTotalSupply = ITokenizedStrategy(address(usd3Strategy)).totalSupply();
        uint256 postReportSusd3Balance = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));

        console2.log("\nPost-report values:");
        console2.log("  totalAssets:", postReportTotalAssets);
        console2.log("  totalSupply:", postReportTotalSupply);
        console2.log("  sUSD3 balance:", postReportSusd3Balance);
        console2.log("  Post-report PPS:", (postReportTotalAssets * 1e18) / postReportTotalSupply);

        // Calculate actual shares burned
        uint256 actualSharesBurned = preReportSusd3Balance - postReportSusd3Balance;
        console2.log("\nActual shares burned from sUSD3:", actualSharesBurned);

        // The bug: What does convertToShares actually calculate?
        // Let's check what the actual calculation would be
        // convertToShares(loss) = loss * totalSupply / totalAssets
        // But at the time of _postReportHook, what are the values?

        // The hook is called AFTER report processes the loss
        // So totalAssets is already reduced to 900
        // But what about totalSupply?

        console2.log("\nDEBUGGING:");
        console2.log("  Loss amount:", loss);
        uint256 debugCalc = (loss * preReportTotalSupply) / postReportTotalAssets;
        console2.log("  If we calculate: loss * preSupply / postAssets = ", debugCalc);
        console2.log("  This matches the actual burned amount (111M vs 100M expected)");

        // Analysis
        console2.log("\n=== Analysis ===");
        console2.log("Expected shares burned:", expectedSharesBurned);
        console2.log("Actual shares burned:", actualSharesBurned);

        if (actualSharesBurned < expectedSharesBurned) {
            console2.log("BUG CONFIRMED: Burned fewer shares than expected!");
            console2.log("Difference:", expectedSharesBurned - actualSharesBurned);
            console2.log("This means sUSD3 didn't absorb enough of the loss");
        } else if (actualSharesBurned > expectedSharesBurned) {
            console2.log("Burned MORE shares than expected (different issue)");
            console2.log("Difference:", actualSharesBurned - expectedSharesBurned);
        } else {
            console2.log("Shares burned correctly (no bug detected)");
        }

        // Check if PPS recovered as much as it should have
        uint256 expectedPPSAfterBurn = ((postReportTotalAssets) * 1e18) / (postReportTotalSupply);

        console2.log("\nPPS Analysis:");
        console2.log("  Current PPS:", expectedPPSAfterBurn);

        // This test SHOULD FAIL with the current buggy implementation
        // The bug causes us to burn 111M shares instead of 100M
        assertEq(actualSharesBurned, expectedSharesBurned, "Incorrect number of shares burned from sUSD3");
    }

    /**
     * @notice Test edge case where sUSD3 has insufficient shares to cover loss
     */
    function test_loss_exceeds_susd3_balance() public {
        console2.log("\n=== Testing Loss Exceeding sUSD3 Balance ===\n");

        // Setup: Small sUSD3 position
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 950e6);
        usd3Strategy.deposit(950e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 50e6);
        usd3Strategy.deposit(50e6, bob);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), 50e6);
        susd3Strategy.deposit(50e6, bob); // Only 5% subordination
        vm.stopPrank();

        uint256 susd3BalanceBefore = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        console2.log("sUSD3 balance before loss:", susd3BalanceBefore);

        // Deploy funds to MorphoCredit first
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).tend();

        // Simulate a large loss (20%)
        uint256 lossAmount = 200e6;

        // To simulate loss, we need to manipulate the market state
        // First withdraw some funds from MorphoCredit
        MarketParams memory params = usd3Strategy.marketParams();
        IMorpho morpho = usd3Strategy.morphoCredit();

        vm.startPrank(address(usd3Strategy));
        // Withdraw funds from MorphoCredit to create idle balance
        morpho.withdraw(params, lossAmount, 0, address(usd3Strategy), address(usd3Strategy));

        // Now transfer them away to simulate loss
        asset.transfer(address(0xdead), lossAmount);
        vm.stopPrank();

        // Report the loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = ITokenizedStrategy(address(usd3Strategy)).report();
        console2.log("Loss reported:", loss);

        uint256 susd3BalanceAfter = ITokenizedStrategy(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        console2.log("sUSD3 balance after loss:", susd3BalanceAfter);

        // sUSD3 should be completely wiped out
        assertEq(susd3BalanceAfter, 0, "sUSD3 should be completely burned");

        // But the bug means it might not be fully burned
        if (susd3BalanceAfter > 0) {
            console2.log("BUG: sUSD3 still has balance when it should be wiped out!");
        }
    }
}
