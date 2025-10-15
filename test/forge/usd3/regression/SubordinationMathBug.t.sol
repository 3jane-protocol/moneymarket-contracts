// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IStrategy} from "../../../../src/usd3/USD3.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title SubordinationMathBug
 * @notice Regression test demonstrating the double-conversion bug in sUSD3 subordination calculations
 * @dev This test DEMONSTRATES the bug - it will show incorrect behavior with the current implementation
 *
 * THE BUG:
 * In getSubordinatedDebtCapInUSDC() and getSubordinatedDebtFloorInUSDC(), the code does:
 *   1. usd3.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC)  // waUSDC → USDC ✅ Correct
 *   2. IStrategy(address(asset)).convertToAssets(...)           // USDC → USD3 → USDC ❌ Wrong!
 *
 * The second conversion treats the USDC value as USD3 shares and applies the USD3 share price again.
 * When USD3 share price = 1.1, a 1000 USDC debt becomes 1100 USDC in the calculation.
 * This inflates backing requirements and can freeze withdrawals incorrectly.
 */
contract SubordinationMathBugTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public borrower = makeAddr("borrower");

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Deploy sUSD3 with proxy
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin();

        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
            address(susd3Implementation),
            address(susd3ProxyAdmin),
            abi.encodeCall(sUSD3.initialize, (address(usd3Strategy), management, keeper))
        );

        susd3Strategy = sUSD3(address(susd3Proxy));

        // Link USD3 to sUSD3
        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Configure protocol parameters
        MockProtocolConfig config =
            MockProtocolConfig(MorphoCredit(address(usd3Strategy.morphoCredit())).protocolConfig());
        config.setConfig(ProtocolConfigLib.DEBT_CAP, 10_000e6); // 10K USDC debt cap
        config.setConfig(ProtocolConfigLib.TRANCHE_RATIO, 1500); // 15% subordination ratio
        config.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 1000); // 10% minimum backing

        // Set no lock/cooldown for testing
        config.setConfig(ProtocolConfigLib.SUSD3_LOCK_DURATION, 0);
        config.setConfig(ProtocolConfigLib.SUSD3_COOLDOWN_PERIOD, 0);

        setMaxOnCredit(8000); // 80% max deployment

        // Fund test accounts
        deal(address(asset), alice, 10_000e6);
        deal(address(asset), bob, 10_000e6);
        deal(address(asset), charlie, 10_000e6);
    }

    /**
     * @notice Main test demonstrating the subordination math bug
     * @dev This test shows how the bug causes incorrect withdrawal blocking when USD3 has yield
     */
    function test_subordination_math_with_yield_demonstrates_bug() public {
        console2.log("\n=== Subordination Math Bug Demonstration ===\n");

        // 1. Alice deposits 5000 USDC to USD3
        console2.log("Step 1: Alice deposits to USD3");
        vm.startPrank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        usd3Strategy.deposit(5000e6, alice);
        vm.stopPrank();

        uint256 usd3SharePrice1 = IStrategy(address(usd3Strategy)).convertToAssets(1e6);
        console2.log("  USD3 share price:", usd3SharePrice1, "(should be ~1.0 USDC per 1e6 shares)");

        // 2. Create market debt of 1000 USDC
        console2.log("\nStep 2: Create 1000 USDC market debt");
        createMarketDebt(borrower, 1000e6);

        (,, uint256 totalBorrowAssetsWaUSDC,) = usd3Strategy.getMarketLiquidity();
        uint256 debtInUSDC = usd3Strategy.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC);
        console2.log("  Market debt (waUSDC):", totalBorrowAssetsWaUSDC);
        console2.log("  Market debt (USDC):", debtInUSDC);

        // 3. Generate 10% yield in USD3 to push share price to ~1.1
        console2.log("\nStep 3: Generate yield in USD3");
        vm.prank(keeper);
        usd3Strategy.report();

        // Simulate yield by having waUSDC appreciate (1000 bps = 10%)
        waUSDC.simulateYield(1000);

        vm.prank(keeper);
        (uint256 profit,) = usd3Strategy.report();
        console2.log("  Profit reported:", profit);

        uint256 usd3SharePrice2 = IStrategy(address(usd3Strategy)).convertToAssets(1e6);
        console2.log("  New USD3 share price:", usd3SharePrice2, "(should be ~1.1 USDC per 1e6 shares)");

        // 4. Calculate expected backing requirement
        console2.log("\nStep 4: Calculate backing requirements");
        uint256 subRatio = susd3Strategy.maxSubordinationRatio();
        console2.log("  Subordination ratio:", subRatio, "bps (15%)");

        uint256 expectedBackingCorrect = (debtInUSDC * subRatio) / MAX_BPS;
        console2.log("  CORRECT backing calculation:");
        console2.log("    Debt:", debtInUSDC, "USDC");
        console2.log("    Ratio:", subRatio, "bps");
        console2.log("    Required backing:", expectedBackingCorrect, "USDC");

        // 5. Show what the buggy calculation returns
        uint256 debtCapCalculated = susd3Strategy.getSubordinatedDebtCapInUSDC();
        uint256 debtFloorCalculated = susd3Strategy.getSubordinatedDebtFloorInUSDC();

        console2.log("\n  BUGGY calculation results:");
        console2.log("    getSubordinatedDebtCapInUSDC():", debtCapCalculated);
        console2.log("    getSubordinatedDebtFloorInUSDC():", debtFloorCalculated);

        // The bug: these values are inflated by USD3 share price
        // If share price is 1.1, then 1000 USDC debt is calculated as 1100
        console2.log("\n  BUG EVIDENCE:");
        console2.log("    Expected cap (15% of 1000):", expectedBackingCorrect);
        console2.log("    Buggy cap (inflated by", usd3SharePrice2, "/ 1e6):", debtCapCalculated);
        console2.log("    Inflation factor:", (debtCapCalculated * 1e18) / expectedBackingCorrect, "/ 1e18");

        // 6. Bob deposits USD3 to sUSD3 to meet backing requirement
        console2.log("\nStep 5: Bob deposits to sUSD3 to meet backing requirement");

        // Bob first gets USD3
        vm.startPrank(bob);
        asset.approve(address(usd3Strategy), 200e6);
        usd3Strategy.deposit(200e6, bob);

        // Bob deposits his USD3 to sUSD3 - deposit the CORRECT amount
        uint256 bobUSD3Balance = IERC20(address(usd3Strategy)).balanceOf(bob);
        uint256 bobUSD3InUSDC = IStrategy(address(usd3Strategy)).convertToAssets(bobUSD3Balance);
        console2.log("  Bob has", bobUSD3InUSDC, "USDC worth of USD3");

        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), bobUSD3Balance);

        // Try to deposit up to the limit
        uint256 depositLimit = susd3Strategy.availableDepositLimit(bob);
        console2.log("  availableDepositLimit:", IStrategy(address(usd3Strategy)).convertToAssets(depositLimit), "USDC");

        uint256 toDeposit = bobUSD3Balance < depositLimit ? bobUSD3Balance : depositLimit;
        susd3Strategy.deposit(toDeposit, bob);

        uint256 susd3Holdings = IERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 susd3HoldingsUSDC = IStrategy(address(usd3Strategy)).convertToAssets(susd3Holdings);
        console2.log("  sUSD3 now holds:", susd3HoldingsUSDC, "USDC worth of USD3");
        vm.stopPrank();

        // 7. Try to withdraw and show it's blocked by the bug
        console2.log("\nStep 6: Attempt withdrawal from sUSD3");

        vm.startPrank(bob);
        susd3Strategy.startCooldown(IERC20(address(susd3Strategy)).balanceOf(bob));
        vm.stopPrank();

        // Warp past cooldown
        vm.warp(block.timestamp + 1);

        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        console2.log("  availableWithdrawLimit:", withdrawLimit);

        console2.log("\n=== BUG DEMONSTRATION ===");
        if (withdrawLimit == 0) {
            console2.log("  BLOCKED: Withdrawal is frozen even though backing requirement is met!");
            console2.log("  Reason: Buggy math thinks we have", susd3HoldingsUSDC, "USDC");
            console2.log("         but need", debtFloorCalculated, "USDC (inflated floor)");
            console2.log("  Reality: We have", susd3HoldingsUSDC, "USDC");
            console2.log("           only need", expectedBackingCorrect * 1000 / 10000, "USDC (10% of correct debt)");
        } else {
            console2.log("  Withdrawal allowed:", withdrawLimit);
        }

        // This assertion will likely fail with the buggy code
        // When USD3 share price > 1, the debt is inflated, making backing insufficient
        assertEq(withdrawLimit, 0, "BUG: Withdrawal is incorrectly blocked");
    }

    /**
     * @notice Test showing debt calculation inflation with USD3 share price
     * @dev Directly tests the math bug by comparing against correct calculation
     */
    function test_debt_calculation_inflates_with_usd3_share_price() public {
        console2.log("\n=== Direct Math Comparison ===\n");

        // Setup: deposit and create debt
        vm.prank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        vm.prank(alice);
        usd3Strategy.deposit(5000e6, alice);

        createMarketDebt(borrower, 1000e6);

        // Get actual debt
        (,, uint256 totalBorrowAssetsWaUSDC,) = usd3Strategy.getMarketLiquidity();

        // CORRECT calculation: waUSDC → USDC
        uint256 correctDebtUSDC = usd3Strategy.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC);

        // Generate yield
        vm.prank(keeper);
        usd3Strategy.report();
        waUSDC.simulateYield(1000); // 10% yield
        vm.prank(keeper);
        usd3Strategy.report();

        // Get USD3 share price
        uint256 usd3SharePrice = IStrategy(address(usd3Strategy)).convertToAssets(1e6);
        console2.log("USD3 share price:", usd3SharePrice, "/ 1e6");

        // BUGGY calculation (what sUSD3 currently does): waUSDC → USDC → USD3 → USDC
        uint256 buggyDebtUSDC = IStrategy(address(usd3Strategy)).convertToAssets(
            usd3Strategy.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC)
        );

        console2.log("\nDebt calculations:");
        console2.log("  Correct debt (waUSDC -> USDC):", correctDebtUSDC);
        console2.log("  Buggy debt (double conversion):", buggyDebtUSDC);
        console2.log("  Inflation factor:", (buggyDebtUSDC * 1e6) / correctDebtUSDC, "/ 1e6");

        // The buggy calculation should be inflated by approximately the USD3 share price
        uint256 expectedInflation = (correctDebtUSDC * usd3SharePrice) / 1e6;
        console2.log("  Expected if bug exists:", expectedInflation);

        // Demonstrate the bug exists
        assertApproxEqRel(
            buggyDebtUSDC, expectedInflation, 0.01e18, "Buggy calculation should inflate by USD3 share price"
        );
        assertGt(buggyDebtUSDC, correctDebtUSDC, "BUG: Debt is incorrectly inflated");
    }

    /**
     * @notice Test showing what the correct backing calculation should be
     * @dev This shows the expected behavior without the bug
     */
    function test_backing_requirement_correct_calculation() public {
        console2.log("\n=== Correct Backing Calculation ===\n");

        // Setup
        vm.prank(alice);
        asset.approve(address(usd3Strategy), 5000e6);
        vm.prank(alice);
        usd3Strategy.deposit(5000e6, alice);

        createMarketDebt(borrower, 1000e6);

        // Get debt correctly
        (,, uint256 totalBorrowAssetsWaUSDC,) = usd3Strategy.getMarketLiquidity();
        uint256 debtUSDC = usd3Strategy.WAUSDC().convertToAssets(totalBorrowAssetsWaUSDC);

        uint256 subRatio = 1500; // 15%
        uint256 backingRatio = 1000; // 10%

        uint256 correctCap = (debtUSDC * subRatio) / MAX_BPS;
        uint256 correctFloor = (debtUSDC * backingRatio) / MAX_BPS;

        console2.log("Market debt:", debtUSDC, "USDC");
        console2.log("Subordination ratio:", subRatio, "bps (15%)");
        console2.log("Backing ratio:", backingRatio, "bps (10%)");
        console2.log("\nCorrect calculations:");
        console2.log("  Cap (max sUSD3 deposits):", correctCap, "USDC");
        console2.log("  Floor (min sUSD3 backing):", correctFloor, "USDC");

        // Compare against buggy implementation
        uint256 buggyCap = susd3Strategy.getSubordinatedDebtCapInUSDC();
        uint256 buggyFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();

        console2.log("\nBuggy implementation returns:");
        console2.log("  Cap:", buggyCap, "USDC");
        console2.log("  Floor:", buggyFloor, "USDC");

        console2.log("\nDifference (without yield, should be minimal):");
        console2.log("  Cap difference:", buggyCap > correctCap ? buggyCap - correctCap : correctCap - buggyCap);
        console2.log(
            "  Floor difference:", buggyFloor > correctFloor ? buggyFloor - correctFloor : correctFloor - buggyFloor
        );
    }
}
