// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {MorphoCreditLib} from "../../../src/libraries/periphery/MorphoCreditLib.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {Id, MarketParams, RepaymentStatus, IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";

/// @title Grace Period Accrual Test
/// @notice Tests to verify accrual behavior during grace period
/// @dev Ensures base + premium accrue during grace, but penalty does not
contract GracePeriodAccrualTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant TEST_CYCLE_DURATION = 30 days;

    CreditLineMock internal creditLine;
    ConfigurableIrmMock internal configurableIrm;

    // Test borrower
    address internal ALICE;

    // Test constants
    uint256 internal constant INITIAL_BORROW = 10000e18;
    uint256 internal constant OBLIGATION_BPS = 1000; // 10%
    uint256 internal constant ENDING_BALANCE = 10000e18;

    function setUp() public override {
        super.setUp();

        // Set cycle duration in protocol config
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), TEST_CYCLE_DURATION);

        ALICE = makeAddr("Alice");

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Deploy configurable IRM for testing
        configurableIrm = new ConfigurableIrmMock();
        configurableIrm.setApr(0.1e18); // 10% APR base rate

        // Create market with credit line
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(configurableIrm),
            lltv: 0,
            creditLine: address(creditLine)
        });

        id = marketParams.id();

        // Enable IRM
        vm.startPrank(OWNER);
        morpho.enableIrm(address(configurableIrm));
        morpho.createMarket(marketParams);
        vm.stopPrank();

        // Initialize first cycle to unfreeze the market
        _ensureMarketActive(id);

        // Setup test tokens and supply liquidity
        deal(address(loanToken), SUPPLIER, 1000000e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");

        // Setup credit line for borrower with premium rate
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 50000e18, uint128(PREMIUM_RATE_PER_SECOND));

        // Warp time forward to avoid underflow in tests
        _continueMarketCycles(id, block.timestamp + 60 days);

        // Setup token approvals
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
    }

    /// @notice Test that base + premium accrue during grace period
    function testAccrualDuringGracePeriod_BaseAndPremium() public {
        // Step 1: Alice borrows
        deal(address(loanToken), ALICE, INITIAL_BORROW);
        vm.prank(ALICE);
        morpho.borrow(marketParams, INITIAL_BORROW, 0, ALICE, ALICE);

        // Trigger accrual to sync timestamps before creating obligation
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        // Step 2: Create obligation that puts Alice in grace period using helper
        // This will create a past obligation properly
        _createPastObligation(ALICE, OBLIGATION_BPS, ENDING_BALANCE);

        // Verify we're in grace period
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod), "Should be in grace period");

        // Accrue again after obligation creation to reset the accounting
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        // Step 3: Record state before accrual
        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 totalSupplyBefore = morpho.market(id).totalSupplyAssets;

        // Step 4: Move time forward but stay in grace period
        _continueMarketCycles(id, block.timestamp + 2 days); // Now 5 days after cycle end, still in grace

        // Step 5: Trigger accrual - this should work now!
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        // Step 6: Verify accrual happened
        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 totalSupplyAfter = morpho.market(id).totalSupplyAssets;

        // Assets should have increased due to base + premium (but no penalty)
        assertGt(borrowAssetsAfter, borrowAssetsBefore, "Borrow assets should increase during grace");
        assertGt(totalSupplyAfter, totalSupplyBefore, "Supply assets should increase during grace");

        // Calculate expected increase (2 days of base + premium, no penalty)
        uint256 expectedGrowth = (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND).wTaylorCompounded(2 days);
        uint256 expectedIncrease = borrowAssetsBefore.wMulDown(expectedGrowth);

        // The actual increase should be close to expected (within 0.1%)
        uint256 actualIncrease = borrowAssetsAfter - borrowAssetsBefore;
        assertApproxEqRel(actualIncrease, expectedIncrease, 0.001e18, "Increase should match base + premium");

        emit log_named_uint("Borrow assets before", borrowAssetsBefore);
        emit log_named_uint("Borrow assets after", borrowAssetsAfter);
        emit log_named_uint("Expected increase", expectedIncrease);
        emit log_named_uint("Actual increase", actualIncrease);
    }

    /// @notice Test that penalty does NOT accrue during grace period
    function testNoPenaltyDuringGracePeriod() public {
        // Setup: Alice borrows and enters grace period
        deal(address(loanToken), ALICE, INITIAL_BORROW);
        vm.prank(ALICE);
        morpho.borrow(marketParams, INITIAL_BORROW, 0, ALICE, ALICE);

        // Trigger accrual to sync timestamps before creating obligation
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        // Create obligation using helper
        _createPastObligation(ALICE, OBLIGATION_BPS, ENDING_BALANCE);

        // Accrue again after obligation creation to reset the accounting
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        // Record state
        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Move time forward 1 day (still in grace)
        _continueMarketCycles(id, block.timestamp + 1 days);

        // Accrue
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 actualIncrease = borrowAssetsAfter - borrowAssetsBefore;

        // Calculate what increase would be WITH penalty
        uint256 growthWithPenalty =
            (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND + PENALTY_RATE_PER_SECOND).wTaylorCompounded(1 days);
        uint256 increaseWithPenalty = borrowAssetsBefore.wMulDown(growthWithPenalty);

        // Calculate what increase should be WITHOUT penalty
        uint256 growthWithoutPenalty = (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND).wTaylorCompounded(1 days);
        uint256 increaseWithoutPenalty = borrowAssetsBefore.wMulDown(growthWithoutPenalty);

        // Actual increase should be much closer to without-penalty than with-penalty
        assertLt(actualIncrease, increaseWithPenalty * 8 / 10, "Should not include penalty");
        assertApproxEqRel(actualIncrease, increaseWithoutPenalty, 0.01e18, "Should match base + premium only");
    }

    /// @notice Test that penalty starts accruing after grace period ends
    function testPenaltyStartsAfterGracePeriod() public {
        // Setup: Alice borrows
        deal(address(loanToken), ALICE, INITIAL_BORROW);
        vm.prank(ALICE);
        morpho.borrow(marketParams, INITIAL_BORROW, 0, ALICE, ALICE);

        // Trigger accrual to sync timestamps before creating obligation
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        // Create obligation using helper
        _createPastObligation(ALICE, OBLIGATION_BPS, ENDING_BALANCE);

        // Should still be in grace period
        {
            (RepaymentStatus _status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
            assertEq(uint256(_status), uint256(RepaymentStatus.GracePeriod), "Should be in grace period");
        }

        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Move past grace period (7 days from obligation end + 1 second)
        // The obligation ended 1 day ago, so we need to move forward 6 days + 1 second
        _continueMarketCycles(id, block.timestamp + 6 days + 1);

        // Now should be delinquent
        {
            (RepaymentStatus _status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
            assertEq(uint256(_status), uint256(RepaymentStatus.Delinquent), "Should be delinquent");
        }

        // Accrue - this should include penalty
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);

        // The increase should include penalty on ending balance
        // We moved forward 6 days + 1 second, so that's the accrual period
        uint256 accrualDuration = 6 days + 1;

        // Calculate expected growth with penalty (penalty only applies for the 1 second past grace)
        // For the 6 days in grace: base + premium
        // For the 1 second past grace: base + premium + penalty
        uint256 graceGrowth = (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND).wTaylorCompounded(6 days);
        uint256 penaltyGrowth =
            (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND + PENALTY_RATE_PER_SECOND).wTaylorCompounded(1);

        uint256 actualIncrease = borrowAssetsAfter - borrowAssetsBefore;

        // The actual increase includes base + premium for the whole period, plus penalty for 1 second
        // So it should be slightly more than just base + premium
        uint256 normalGrowth = (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND).wTaylorCompounded(accrualDuration);
        uint256 normalIncrease = borrowAssetsBefore.wMulDown(normalGrowth);

        // Since penalty just started (1 second), the increase should be only slightly more than normal
        assertGt(actualIncrease, normalIncrease, "Should include some penalty");
        emit log_named_uint("Actual total increase", actualIncrease);
    }

    /// @notice Test that repayment during grace period clears obligation without penalty
    function testRepaymentDuringGracePeriod_NoPenalty() public {
        // Setup: Alice borrows
        deal(address(loanToken), ALICE, INITIAL_BORROW);
        vm.prank(ALICE);
        morpho.borrow(marketParams, INITIAL_BORROW, 0, ALICE, ALICE);

        // Trigger accrual to sync timestamps before creating obligation
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        // Create obligation using helper
        _createPastObligation(ALICE, OBLIGATION_BPS, ENDING_BALANCE);

        // Accrue to sync state after obligation creation
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        // Record debt before repayment
        uint256 debtBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Pay the obligation during grace period
        deal(address(loanToken), ALICE, 1000e18); // Amount calculated from 10% of 10000e18
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, ""); // 10% of 10000e18

        // Verify obligation is cleared
        (, uint256 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDue, 0, "Obligation should be cleared");

        // Verify status is now Current
        {
            (RepaymentStatus _status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
            assertEq(uint256(_status), uint256(RepaymentStatus.Current), "Should be current after payment");
        }

        // The debt should have decreased by exactly the payment amount
        uint256 debtAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        assertEq(debtBefore - debtAfter, 1000e18, "Debt should decrease by payment amount");

        // Move time forward and verify no penalty accrues
        _continueMarketCycles(id, block.timestamp + 10 days);
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        uint256 debtFinal = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Should only have normal accrual, no penalty
        uint256 expectedGrowth = (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND).wTaylorCompounded(10 days);
        uint256 expectedDebt = debtAfter.wMulDown(expectedGrowth + WAD);

        assertApproxEqRel(debtFinal, expectedDebt, 0.001e18, "Should only have normal accrual");
    }
}
