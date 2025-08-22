// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
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

        // Setup test tokens and supply liquidity
        deal(address(loanToken), SUPPLIER, 1000000e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");

        // Setup credit line for borrower with premium rate
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 50000e18, uint128(PREMIUM_RATE_PER_SECOND));

        // Warp time forward to avoid underflow in tests
        vm.warp(block.timestamp + 60 days);

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

        // Step 2: Create obligation that puts Alice in grace period
        // Set cycle end to be 3 days ago (within 7-day grace period)
        uint256 cycleEndDate = block.timestamp - 3 days;

        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = OBLIGATION_BPS;
        balances[0] = ENDING_BALANCE;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Verify we're in grace period
        (RepaymentStatus status,) = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod), "Should be in grace period");

        // Step 3: Record state before accrual
        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 totalSupplyBefore = morpho.market(id).totalSupplyAssets;

        // Step 4: Move time forward but stay in grace period
        vm.warp(block.timestamp + 2 days); // Now 5 days after cycle end, still in grace

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

        // Create obligation 5 days ago (in grace period)
        uint256 cycleEndDate = block.timestamp - 5 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = OBLIGATION_BPS;
        balances[0] = ENDING_BALANCE;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Record state
        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Move time forward 1 day (still in grace)
        vm.warp(block.timestamp + 1 days);

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

        // Create obligation exactly at grace period boundary
        uint256 cycleEndDate = block.timestamp - GRACE_PERIOD_DURATION;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = OBLIGATION_BPS;
        balances[0] = ENDING_BALANCE;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Should still be in grace period
        {
            (RepaymentStatus _status,) = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
            assertEq(uint256(_status), uint256(RepaymentStatus.GracePeriod), "Should be in grace period");
        }

        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Move exactly 1 second past grace period
        vm.warp(block.timestamp + 1);

        // Now should be delinquent
        {
            (RepaymentStatus _status,) = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
            assertEq(uint256(_status), uint256(RepaymentStatus.Delinquent), "Should be delinquent");
        }

        // Accrue - this should include penalty
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);

        // The increase should include penalty on ending balance
        // Penalty has been accruing for GRACE_PERIOD_DURATION + 1 second
        uint256 penaltyDuration = GRACE_PERIOD_DURATION + 1;
        uint256 expectedPenaltyGrowth = PENALTY_RATE_PER_SECOND.wTaylorCompounded(penaltyDuration);
        uint256 expectedPenalty = ENDING_BALANCE.wMulDown(expectedPenaltyGrowth);

        uint256 actualIncrease = borrowAssetsAfter - borrowAssetsBefore;

        // The actual increase includes base + premium on current balance + penalty on ending balance
        // So it should be significantly more than just base + premium
        uint256 normalGrowth = (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND).wTaylorCompounded(1);
        uint256 normalIncrease = borrowAssetsBefore.wMulDown(normalGrowth);

        assertGt(actualIncrease, normalIncrease + expectedPenalty / 2, "Should include significant penalty");

        emit log_named_uint("Expected penalty on ending balance", expectedPenalty);
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

        // Create obligation 4 days ago
        uint256 cycleEndDate = block.timestamp - 4 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = OBLIGATION_BPS;
        balances[0] = ENDING_BALANCE;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

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
            (RepaymentStatus _status,) = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
            assertEq(uint256(_status), uint256(RepaymentStatus.Current), "Should be current after payment");
        }

        // The debt should have decreased by exactly the payment amount
        uint256 debtAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        assertEq(debtBefore - debtAfter, 1000e18, "Debt should decrease by payment amount");

        // Move time forward and verify no penalty accrues
        vm.warp(block.timestamp + 10 days);
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(id, ALICE);

        uint256 debtFinal = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Should only have normal accrual, no penalty
        uint256 expectedGrowth = (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND).wTaylorCompounded(10 days);
        uint256 expectedDebt = debtAfter.wMulDown(expectedGrowth + WAD);

        assertApproxEqRel(debtFinal, expectedDebt, 0.001e18, "Should only have normal accrual");
    }
}
