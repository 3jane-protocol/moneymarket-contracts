// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {IMorpho, Id, MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {ErrorsLib} from "../../../../src/libraries/ErrorsLib.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title Comprehensive Debt Floor Testing
 * @notice Tests edge cases, boundary conditions, and complex scenarios for debt floor feature
 */
contract DebtFloorComprehensiveTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    MockProtocolConfig public protocolConfig;

    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public borrower = makeAddr("borrower");
    address public borrower2 = makeAddr("borrower2");

    // Test amounts
    uint256 public constant DEPOSIT_AMOUNT = 1_000_000e6; // 1M USDC
    uint256 public constant SMALL_AMOUNT = 1e6; // 1 USDC

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Get protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        protocolConfig = MockProtocolConfig(MorphoCredit(morphoAddress).protocolConfig());

        // Deploy and link sUSD3
        sUSD3 susd3Implementation = new sUSD3();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);
        TransparentUpgradeableProxy susd3Proxy = new TransparentUpgradeableProxy(
            address(susd3Implementation),
            address(susd3ProxyAdmin),
            abi.encodeCall(sUSD3.initialize, (address(usd3Strategy), management, keeper))
        );
        susd3Strategy = sUSD3(address(susd3Proxy));

        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));

        // Fund test users
        deal(address(underlyingAsset), alice, DEPOSIT_AMOUNT * 3);
        deal(address(underlyingAsset), bob, DEPOSIT_AMOUNT * 2);
        deal(address(underlyingAsset), charlie, DEPOSIT_AMOUNT);

        // Setup approvals
        vm.prank(alice);
        asset.approve(address(strategy), type(uint256).max);

        vm.prank(bob);
        asset.approve(address(strategy), type(uint256).max);

        vm.prank(charlie);
        asset.approve(address(strategy), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    ZERO BACKING RATIO EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_debtFloor_zeroBackingRatio_allowsFullWithdrawal() public {
        // Set backing ratio to 0 (no backing required)
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);

        // Setup positions
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(bob);
        strategy.deposit(DEPOSIT_AMOUNT, bob);

        // Create debt to enable sUSD3
        setMaxOnCredit(8000);
        createMarketDebt(borrower, 500_000e6);

        // Bob deposits to sUSD3
        uint256 bobUSD3 = strategy.balanceOf(bob);
        uint256 depositLimit = susd3Strategy.availableDepositLimit(bob);
        uint256 toDeposit = bobUSD3 > depositLimit ? depositLimit : bobUSD3;

        vm.prank(bob);
        strategy.approve(address(susd3Strategy), toDeposit);

        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(toDeposit, bob);

        // Fast forward past lock period
        skip(91 days);

        // Start cooldown
        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);

        // Fast forward past cooldown
        skip(8 days);

        // With zero backing ratio, Bob should be able to withdraw everything
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        // Convert sUSD3 shares to USD3 tokens, then to USDC
        uint256 bobUSD3Amount = ITokenizedStrategy(address(susd3Strategy)).convertToAssets(bobSUSD3Shares);
        uint256 bobAssets = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(bobUSD3Amount);

        assertEq(withdrawLimit, bobAssets, "Should allow full withdrawal with zero backing ratio");

        // Verify debt floor is indeed zero
        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        assertEq(debtFloor, 0, "Debt floor should be zero");
    }

    function test_debtFloor_dynamicBackingRatioChange_fromZeroToNonZero() public {
        // Start with zero backing ratio
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);

        // Setup positions and debt
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(bob);
        strategy.deposit(DEPOSIT_AMOUNT, bob);

        setMaxOnCredit(8000);
        createMarketDebt(borrower, 400_000e6); // 400K debt

        // Bob deposits to sUSD3
        uint256 bobUSD3 = strategy.balanceOf(bob);
        uint256 depositLimit = susd3Strategy.availableDepositLimit(bob);
        uint256 toDeposit = bobUSD3 > depositLimit ? depositLimit : bobUSD3;

        vm.prank(bob);
        strategy.approve(address(susd3Strategy), toDeposit);

        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(toDeposit, bob);

        // Fast forward and start cooldown
        skip(91 days);
        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);
        skip(8 days);

        // Initially should allow full withdrawal
        uint256 withdrawLimit1 = susd3Strategy.availableWithdrawLimit(bob);
        // Convert sUSD3 shares to USD3 tokens, then to USDC
        uint256 bobUSD3Amount = ITokenizedStrategy(address(susd3Strategy)).convertToAssets(bobSUSD3Shares);
        uint256 bobAssets = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(bobUSD3Amount);
        assertEq(withdrawLimit1, bobAssets, "Should allow full withdrawal initially");

        // Change backing ratio to 50% mid-cooldown window
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 5000);

        // Now withdrawal should be limited
        uint256 withdrawLimit2 = susd3Strategy.availableWithdrawLimit(bob);
        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();

        assertGt(debtFloor, 0, "Debt floor should be non-zero after change");
        assertLt(withdrawLimit2, bobAssets, "Withdrawal should be limited after backing ratio change");
    }

    /*//////////////////////////////////////////////////////////////
                    BOUNDARY CONDITION TESTING
    //////////////////////////////////////////////////////////////*/

    function test_debtFloor_withdrawalAtExactFloor() public {
        // Set backing ratio to 25%
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 2500);

        // Setup positions
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(bob);
        strategy.deposit(DEPOSIT_AMOUNT, bob);

        // Create specific debt amount
        setMaxOnCredit(8000);
        createMarketDebt(borrower, 200_000e6); // 200K debt needs 50K backing at 25%

        // Bob deposits to sUSD3
        uint256 bobUSD3 = strategy.balanceOf(bob);
        uint256 depositLimit = susd3Strategy.availableDepositLimit(bob);
        uint256 toDeposit = bobUSD3 > depositLimit ? depositLimit : bobUSD3;

        vm.prank(bob);
        strategy.approve(address(susd3Strategy), toDeposit);

        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(toDeposit, bob);

        // Fast forward and start cooldown
        skip(91 days);
        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);
        skip(8 days);

        // Calculate exact floor
        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        uint256 currentAssetsUSDC =
            ITokenizedStrategy(address(usd3Strategy)).convertToAssets(strategy.balanceOf(address(susd3Strategy)));

        // Calculate Bob's share of assets - sUSD3's asset is USD3, so convertToAssets gives USD3 tokens
        uint256 bobUSD3Tokens = ITokenizedStrategy(address(susd3Strategy)).convertToAssets(bobSUSD3Shares);
        // Convert USD3 tokens to USDC value
        uint256 bobAssetsUSDC = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(bobUSD3Tokens);

        // Calculate how much Bob can withdraw while maintaining floor
        uint256 excessAboveFloor = currentAssetsUSDC > debtFloor ? currentAssetsUSDC - debtFloor : 0;

        // Bob can withdraw minimum of his assets or the excess above floor
        uint256 expectedWithdrawable = bobAssetsUSDC < excessAboveFloor ? bobAssetsUSDC : excessAboveFloor;
        uint256 expectedWithdrawableUSD3 = expectedWithdrawable > 0
            ? ITokenizedStrategy(address(usd3Strategy)).convertToShares(expectedWithdrawable)
            : 0;

        // Should be able to withdraw up to but not beyond floor
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);

        // Allow for rounding and interest accrual
        assertApproxEqRel(
            withdrawLimit,
            expectedWithdrawableUSD3,
            0.05e18, // 5% tolerance for interest and rounding
            "Should allow withdrawal up to floor limit"
        );
    }

    function test_debtFloor_withdrawalOneCentAboveFloor() public {
        // Set backing ratio to 30%
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 3000);

        // Setup positions
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(bob);
        strategy.deposit(500_000e6, bob); // 500K

        // Create debt
        setMaxOnCredit(8000);
        createMarketDebt(borrower, 100_000e6); // 100K debt needs 30K backing

        // Bob deposits specific amount to sUSD3 (slightly above floor requirement)
        vm.prank(bob);
        strategy.approve(address(susd3Strategy), 31_000e6); // 31K (1K above floor)

        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(31_000e6, bob);

        // Fast forward and start cooldown
        skip(91 days);
        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);
        skip(8 days);

        // Should be able to withdraw only the amount above floor
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);

        // Get current floor and total assets
        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        uint256 currentAssetsUSDC =
            ITokenizedStrategy(address(usd3Strategy)).convertToAssets(strategy.balanceOf(address(susd3Strategy)));

        // Calculate Bob's share of assets
        uint256 bobUSD3Tokens = ITokenizedStrategy(address(susd3Strategy)).convertToAssets(bobSUSD3Shares);
        uint256 bobAssetsUSDC = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(bobUSD3Tokens);

        // Bob can withdraw the minimum of:
        // 1. His total assets (bobAssetsUSDC)
        // 2. The excess of total sUSD3 assets above the floor
        uint256 excessAboveFloor = currentAssetsUSDC > debtFloor ? currentAssetsUSDC - debtFloor : 0;
        uint256 expectedWithdrawableUSDC = bobAssetsUSDC < excessAboveFloor ? bobAssetsUSDC : excessAboveFloor;
        uint256 expectedWithdrawable =
            ITokenizedStrategy(address(usd3Strategy)).convertToShares(expectedWithdrawableUSDC);

        assertApproxEqRel(
            withdrawLimit,
            expectedWithdrawable,
            0.05e18, // 5% tolerance for interest accrual and rounding
            "Should allow withdrawal of amount above floor"
        );
    }

    /*//////////////////////////////////////////////////////////////
                COOLDOWN PERIOD INTERACTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_debtFloor_debtIncreaseDuringCooldown() public {
        // Set backing ratio
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 4000); // 40%

        // Setup initial positions
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT * 2, alice);

        vm.prank(bob);
        strategy.deposit(DEPOSIT_AMOUNT, bob);

        // Create initial debt
        setMaxOnCredit(8000);
        createMarketDebt(borrower, 100_000e6); // 100K initial debt

        // Bob deposits to sUSD3
        vm.prank(bob);
        strategy.approve(address(susd3Strategy), 100_000e6);

        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(100_000e6, bob);

        // Fast forward and start cooldown
        skip(91 days);
        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);

        // Check initial withdrawal limit
        skip(8 days);
        uint256 withdrawLimit1 = susd3Strategy.availableWithdrawLimit(bob);
        assertGt(withdrawLimit1, 0, "Should have some withdrawal available initially");

        // Increase debt during cooldown window
        createMarketDebt(borrower2, 150_000e6); // Additional 150K debt

        // Check withdrawal limit after debt increase
        uint256 withdrawLimit2 = susd3Strategy.availableWithdrawLimit(bob);
        assertLt(withdrawLimit2, withdrawLimit1, "Withdrawal limit should decrease after debt increase");

        // Verify new floor
        uint256 newDebtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        assertApproxEqRel(
            newDebtFloor,
            (250_000e6 * 4000) / 10000,
            0.01e18, // 1% tolerance for interest accrual
            "Debt floor should approximately reflect new total debt"
        );
    }

    function test_debtFloor_backingRatioChangeDuringCooldown() public {
        // Start with 20% backing ratio
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 2000);

        // Setup positions and debt
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(bob);
        strategy.deposit(DEPOSIT_AMOUNT, bob);

        setMaxOnCredit(8000);
        createMarketDebt(borrower, 200_000e6);

        // Bob deposits to sUSD3
        vm.prank(bob);
        strategy.approve(address(susd3Strategy), 100_000e6);

        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(100_000e6, bob);

        // Start cooldown
        skip(91 days);
        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);
        skip(8 days);

        // Check initial limit
        uint256 withdrawLimit1 = susd3Strategy.availableWithdrawLimit(bob);

        // Increase backing ratio requirement during cooldown window
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 6000); // 60%

        // Check new limit
        uint256 withdrawLimit2 = susd3Strategy.availableWithdrawLimit(bob);

        assertLt(withdrawLimit2, withdrawLimit1, "Stricter backing ratio should reduce withdrawal limit");

        // Verify floor increased
        uint256 newFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        assertApproxEqRel(
            newFloor,
            (200_000e6 * 6000) / 10000,
            0.05e18, // 5% tolerance for interest accrual
            "Floor should reflect new backing ratio"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    CONCURRENT OPERATIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_debtFloor_simultaneousWithdrawalsNearFloor() public {
        // Set backing ratio
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 3000); // 30%

        // Setup positions
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(bob);
        strategy.deposit(DEPOSIT_AMOUNT, bob);

        vm.prank(charlie);
        strategy.deposit(DEPOSIT_AMOUNT, charlie);

        // Create debt
        setMaxOnCredit(8000);
        createMarketDebt(borrower, 300_000e6); // 300K debt needs 90K backing

        // Bob and Charlie both deposit to sUSD3
        vm.prank(bob);
        strategy.approve(address(susd3Strategy), 60_000e6);
        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(60_000e6, bob);

        vm.prank(charlie);
        strategy.approve(address(susd3Strategy), 60_000e6);
        vm.prank(charlie);
        uint256 charlieSUSD3Shares = susd3Strategy.deposit(60_000e6, charlie);

        // Both start cooldowns
        skip(91 days);

        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);

        vm.prank(charlie);
        susd3Strategy.startCooldown(charlieSUSD3Shares);

        skip(8 days);

        // Bob withdraws first
        uint256 bobWithdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        vm.prank(bob);
        uint256 bobWithdrawn = susd3Strategy.redeem(bobWithdrawLimit, bob, bob);

        // Charlie's withdrawal should now be more limited
        uint256 charlieWithdrawLimit = susd3Strategy.availableWithdrawLimit(charlie);

        // Charlie should have less available than Bob had
        assertLt(charlieWithdrawLimit, bobWithdrawLimit, "Second withdrawal should be more limited");

        // Verify total remaining is at least floor
        // sUSD3 holds USD3 tokens (which is 'strategy'), so get the balance and convert to USDC value
        uint256 remainingUSD3Tokens = strategy.balanceOf(address(susd3Strategy));
        uint256 remainingAssetsUSDC = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(remainingUSD3Tokens);
        uint256 floor = susd3Strategy.getSubordinatedDebtFloorInUSDC();

        assertGe(remainingAssetsUSDC, floor, "Should maintain minimum floor after first withdrawal");
    }

    /*//////////////////////////////////////////////////////////////
                    RECOVERY SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_debtFloor_recoveryFromBelowFloor() public {
        // Set backing ratio
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 5000); // 50%

        // Setup positions
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(bob);
        strategy.deposit(200_000e6, bob); // 200K

        // Create debt
        setMaxOnCredit(8000);
        createMarketDebt(borrower, 400_000e6); // 400K debt needs 200K backing

        // Bob deposits less than floor requirement
        vm.prank(bob);
        strategy.approve(address(susd3Strategy), 150_000e6);
        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(150_000e6, bob);

        // Fast forward and start cooldown
        skip(91 days);
        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);
        skip(8 days);

        // Bob shouldn't be able to withdraw (below floor)
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        assertEq(withdrawLimit, 0, "Should not allow withdrawal when below floor");

        // Alice deposits more to sUSD3 to help recovery
        vm.prank(alice);
        strategy.approve(address(susd3Strategy), 100_000e6);
        vm.prank(alice);
        susd3Strategy.deposit(100_000e6, alice);

        // Now Bob should be able to withdraw some
        uint256 newWithdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        assertGt(newWithdrawLimit, 0, "Should allow partial withdrawal after recovery");

        // Verify we're above floor now
        // sUSD3 holds USD3 tokens (which is 'strategy'), so get the balance and convert to USDC value
        uint256 totalUSD3Tokens = strategy.balanceOf(address(susd3Strategy));
        uint256 totalAssetsUSDC = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(totalUSD3Tokens);
        uint256 floor = susd3Strategy.getSubordinatedDebtFloorInUSDC();

        assertGt(totalAssetsUSDC, floor, "Total assets should be above floor after recovery");
    }
}
