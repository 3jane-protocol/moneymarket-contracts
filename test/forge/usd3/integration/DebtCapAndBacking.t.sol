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
import {TransparentUpgradeableProxy} from
    "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title Debt Cap and Backing Requirements Integration Test
 * @notice Tests the new debt cap and minimum backing ratio features
 */
contract DebtCapAndBackingTest is Setup {
    USD3 public usd3Strategy;
    sUSD3 public susd3Strategy;
    MockProtocolConfig public protocolConfig;

    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public borrower = makeAddr("borrower");

    // Test amounts
    uint256 public constant DEPOSIT_AMOUNT = 1_000_000e6; // 1M USDC
    uint256 public constant DEBT_CAP_USDC = 500_000e6; // 500K in USDC terms
    uint256 public constant MIN_BACKING_RATIO = 5000; // 50%

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
        deal(address(underlyingAsset), alice, DEPOSIT_AMOUNT * 2);
        deal(address(underlyingAsset), bob, DEPOSIT_AMOUNT);

        // Setup approvals
        vm.prank(alice);
        asset.approve(address(strategy), type(uint256).max);

        vm.prank(bob);
        asset.approve(address(strategy), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            DEBT CAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_debtCap_preventsExcessiveBorrowing() public {
        // Set debt cap directly (waUSDC and USDC are 1:1 initially)
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, DEBT_CAP_USDC);

        // Alice deposits to provide liquidity
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        // Set MAX_ON_CREDIT to allow borrowing
        setMaxOnCredit(8000); // 80%

        // Deploy funds to market first
        vm.prank(keeper);
        strategy.report();

        // Try to borrow more than the cap (in USDC terms)
        uint256 excessiveBorrowUSDC = DEBT_CAP_USDC + 100e6;

        // Set up the borrowing directly to avoid report() side effects
        Id marketId = USD3(address(strategy)).marketId();
        MarketParams memory marketParams = USD3(address(strategy)).marketParams();
        IMorpho morpho = USD3(address(strategy)).morphoCredit();

        // Create payment cycle
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).closeCycleAndPostObligations(
            marketId, block.timestamp, borrowers, repaymentBps, endingBalances
        );

        // Set credit line for borrower
        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, excessiveBorrowUSDC * 2, 0);

        // Borrowing should revert with DebtCapExceeded
        vm.expectRevert(ErrorsLib.DebtCapExceeded.selector);
        vm.prank(borrower);
        helper.borrow(marketParams, excessiveBorrowUSDC, 0, borrower, borrower);
    }

    function test_debtCap_allowsBorrowingUpToCap() public {
        // Set debt cap directly (waUSDC and USDC are 1:1 initially)
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, DEBT_CAP_USDC);

        // Alice deposits to provide liquidity
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        // Set MAX_ON_CREDIT to allow borrowing
        setMaxOnCredit(8000); // 80%

        // Borrow exactly up to the cap (in USDC terms)
        createMarketDebt(borrower, DEBT_CAP_USDC);

        // Debt cap was enforced - test passes if we get here without reverting
    }

    function test_debtCap_zeroDisablesLimit() public {
        // Set debt cap to 0 (disabled)
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, 0);

        // Alice deposits to provide liquidity
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT * 2, alice);

        // Set MAX_ON_CREDIT to allow borrowing
        setMaxOnCredit(8000); // 80%

        // Should be able to borrow more than previous cap
        uint256 largeBorrow = DEPOSIT_AMOUNT;
        createMarketDebt(borrower, largeBorrow);

        // Successfully borrowed beyond old cap - test passes
    }

    /*//////////////////////////////////////////////////////////////
                        BACKING REQUIREMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_backingRequirement_preventsWithdrawals() public {
        // Set minimum backing ratio
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, MIN_BACKING_RATIO);

        // Alice deposits to USD3
        vm.prank(alice);
        uint256 aliceShares = strategy.deposit(DEPOSIT_AMOUNT, alice);

        // Bob deposits to USD3 first
        vm.prank(bob);
        strategy.deposit(DEPOSIT_AMOUNT, bob);

        // Create debt first to enable sUSD3 deposits (debt-based subordination)
        setMaxOnCredit(8000);
        createMarketDebt(borrower, DEPOSIT_AMOUNT / 2); // 500K debt

        // Now Bob can deposit USD3 to sUSD3 (after debt exists)
        uint256 bobUSD3 = strategy.balanceOf(bob);

        // Check available deposit limit first
        uint256 depositLimit = susd3Strategy.availableDepositLimit(bob);
        console2.log("Bob USD3 balance:", bobUSD3);
        console2.log("sUSD3 deposit limit:", depositLimit);
        console2.log("Expected: 500K * 0.5 = 250K in USD3 terms");

        // Deposit up to the limit (or all of Bob's USD3)
        uint256 toDeposit = bobUSD3 > depositLimit ? depositLimit : bobUSD3;

        vm.prank(bob);
        strategy.approve(address(susd3Strategy), toDeposit);

        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(toDeposit, bob);

        // Fast forward past lock period (default 90 days)
        skip(91 days);

        // Start cooldown for Bob
        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);

        // Fast forward past cooldown
        skip(8 days);

        // Bob tries to withdraw all - should be limited by backing requirement
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);

        // Calculate expected limit based on backing requirement
        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();
        assertGt(debtFloor, 0, "Should have debt floor");

        // Bob shouldn't be able to withdraw everything
        uint256 bobAssets = ITokenizedStrategy(address(susd3Strategy)).convertToAssets(bobSUSD3Shares);
        assertLt(withdrawLimit, bobAssets, "Withdrawal should be limited by backing requirement");
    }

    function test_backingRequirement_allowsPartialWithdrawals() public {
        // Set minimum backing ratio to 25%
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 2500);

        // Alice deposits to USD3
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        // Bob deposits to USD3 first
        vm.prank(bob);
        strategy.deposit(DEPOSIT_AMOUNT, bob);

        // Create debt first to enable sUSD3 deposits
        setMaxOnCredit(8000);
        createMarketDebt(borrower, 200_000e6); // 200K debt needs 50K backing at 25%

        // Now Bob can deposit USD3 to sUSD3 (after debt exists)
        uint256 bobUSD3 = strategy.balanceOf(bob);

        // Check deposit limit
        uint256 depositLimit = susd3Strategy.availableDepositLimit(bob);
        uint256 toDeposit = bobUSD3 > depositLimit ? depositLimit : bobUSD3;

        vm.prank(bob);
        strategy.approve(address(susd3Strategy), toDeposit);

        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(toDeposit, bob);

        // Fast forward past lock period (default 90 days)
        skip(91 days);

        // Start cooldown
        vm.prank(bob);
        susd3Strategy.startCooldown(bobSUSD3Shares);

        // Fast forward past cooldown
        skip(8 days);

        // Bob should be able to withdraw most funds
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        uint256 debtFloor = susd3Strategy.getSubordinatedDebtFloorInUSDC();

        // Should be able to withdraw everything except the floor
        // Note: toDeposit might be less than bobUSD3 due to deposit limits
        uint256 bobAssetsUSDC = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(toDeposit);
        uint256 expectedLimit = bobAssetsUSDC > debtFloor ? bobAssetsUSDC - debtFloor : 0;

        // Allow for some rounding (1% tolerance)
        if (expectedLimit > 0) {
            assertApproxEqRel(withdrawLimit, expectedLimit, 0.01e18, "Should allow withdrawal above floor");
        } else {
            assertEq(withdrawLimit, 0, "Should not allow withdrawal below floor");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        COMBINED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_debtCeilingLimitsSubordinateDeposits() public {
        // Set debt cap and subordination ratio
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, DEBT_CAP_USDC);
        protocolConfig.setConfig(ProtocolConfigLib.TRANCHE_RATIO, 1500); // 15%

        // Alice deposits to USD3
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT * 2, alice);

        // Check sUSD3 deposit limit
        uint256 depositLimit = susd3Strategy.availableDepositLimit(alice);

        // With 500K debt cap and 15% subordination, max sUSD3 should be 75K in USDC terms
        uint256 expectedMaxSUSD3 = (DEBT_CAP_USDC * 1500) / 10000;

        // Convert to USD3 shares for comparison
        uint256 expectedMaxUSD3 = ITokenizedStrategy(address(strategy)).convertToShares(expectedMaxSUSD3);

        assertLe(depositLimit, expectedMaxUSD3, "Deposit limit should respect debt ceiling");
    }

    function test_emergencyShutdownBypassesChecks() public {
        // Set strict backing requirement
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 10000); // 100%

        // Setup positions
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        vm.prank(bob);
        strategy.deposit(DEPOSIT_AMOUNT, bob);

        // Create debt first to enable sUSD3 deposits
        setMaxOnCredit(8000);
        createMarketDebt(borrower, DEPOSIT_AMOUNT / 2);

        // Now Bob can deposit USD3 to sUSD3 (after debt exists)
        uint256 bobUSD3 = strategy.balanceOf(bob);

        // Check deposit limit
        uint256 depositLimit = susd3Strategy.availableDepositLimit(bob);
        uint256 toDeposit = bobUSD3 > depositLimit ? depositLimit : bobUSD3;

        vm.prank(bob);
        strategy.approve(address(susd3Strategy), toDeposit);

        vm.prank(bob);
        uint256 bobSUSD3Shares = susd3Strategy.deposit(toDeposit, bob);

        // Trigger emergency shutdown
        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();

        // Bob should be able to withdraw despite backing requirement
        uint256 withdrawLimit = susd3Strategy.availableWithdrawLimit(bob);
        assertGt(withdrawLimit, 0, "Should allow withdrawal during shutdown");

        // Withdraw should succeed
        vm.prank(bob);
        uint256 withdrawn = susd3Strategy.redeem(bobSUSD3Shares, bob, bob);
        assertGt(withdrawn, 0, "Should successfully withdraw during shutdown");
    }
}
