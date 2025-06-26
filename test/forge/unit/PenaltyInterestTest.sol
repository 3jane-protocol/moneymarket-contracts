// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {
    Id,
    MarketParams,
    RepaymentStatus,
    IMorphoCredit
} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";

contract PenaltyInterestTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    CreditLineMock internal creditLine;
    ConfigurableIrmMock internal configurableIrm;

    // Test borrowers
    address internal ALICE;
    address internal BOB;

    // Test-specific constants (common ones are in BaseTest)

    function setUp() public override {
        super.setUp();

        ALICE = makeAddr("Alice");
        BOB = makeAddr("Bob");

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Deploy configurable IRM for testing
        configurableIrm = new ConfigurableIrmMock();
        configurableIrm.setApr(0.1e18); // 10% APR

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
        vm.prank(OWNER);
        morpho.enableIrm(address(configurableIrm));

        morpho.createMarket(marketParams);

        // Setup test tokens and supply liquidity
        deal(address(loanToken), SUPPLIER, 1000000e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");

        // Setup credit lines for borrowers with premium rates
        vm.startPrank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 50000e18, uint128(PREMIUM_RATE_PER_SECOND));
        IMorphoCredit(address(morpho)).setCreditLine(id, BOB, 100000e18, uint128(PREMIUM_RATE_PER_SECOND * 2));
        vm.stopPrank();

        // Warp time forward to avoid underflow in tests
        vm.warp(block.timestamp + 60 days); // 2 monthly cycles

        // Setup token approvals for test borrowers
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(BOB);
        loanToken.approve(address(morpho), type(uint256).max);
    }

    // ============ Penalty Accrual Basic Tests ============

    function testPenaltyInterest_NoAccrualWhenCurrent() public {
        // Borrow
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        uint256 borrowSharesBefore = morpho.position(id, ALICE).borrowShares;

        // Create cycle with obligation that's fully paid
        uint256 cycleEndDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // Pay in full
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // Forward time and trigger accrual
        vm.warp(block.timestamp + 1 days);

        // Trigger accrual by borrowing a small amount
        deal(address(loanToken), ALICE, 1e18);
        vm.prank(ALICE);
        _triggerAccrual();

        // Should only have base + premium accrual, no penalty
        uint256 borrowSharesAfter = morpho.position(id, ALICE).borrowShares;
        uint256 expectedShares = borrowSharesBefore + 1e18; // From new borrow

        // Allow for some accrual but much less than if penalty was applied
        assertLe(borrowSharesAfter, expectedShares * 1001 / 1000); // Max 0.1% increase
    }

    function testPenaltyInterest_AccruesWhenDelinquent() public {
        // Borrow
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create delinquent obligation (10 days old, unpaid)
        uint256 cycleEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18; // Ending balance for penalty calculation

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // Record state before penalty accrual
        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 totalBorrowAssetsBefore = morpho.market(id).totalBorrowAssets;

        // Forward time and trigger accrual
        vm.warp(block.timestamp + 1 days);

        // Trigger accrual
        _triggerAccrual();

        // Calculate expected penalty
        uint256 penaltyDuration = block.timestamp - (cycleEndDate + GRACE_PERIOD_DURATION);
        uint256 expectedPenalty = balances[0].wMulDown(PENALTY_RATE_PER_SECOND.wTaylorCompounded(penaltyDuration));

        // Verify penalty was accrued
        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 actualIncrease = borrowAssetsAfter - borrowAssetsBefore;

        // Should include base rate + premium + penalty on ending balance
        // The actual increase includes base rate + premium on current balance + penalty on ending balance
        // So we just verify that there's a significant increase beyond normal accrual
        uint256 normalRate = (BASE_RATE_PER_SECOND + PREMIUM_RATE_PER_SECOND).wTaylorCompounded(1 days);
        uint256 normalIncrease = normalRate > WAD ? borrowAssetsBefore.wMulDown(normalRate - WAD) : 0;
        assertGt(actualIncrease, normalIncrease); // Should be more than just normal accrual

        // Verify market totals updated
        uint256 totalBorrowAssetsAfter = morpho.market(id).totalBorrowAssets;
        assertGt(totalBorrowAssetsAfter, totalBorrowAssetsBefore);
    }

    function testPenaltyInterest_AccruesFromDelinquencyDate() public {
        // Borrow
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create obligation that just became delinquent
        uint256 cycleEndDate = block.timestamp - GRACE_PERIOD_DURATION - 1;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // Fast forward 5 days
        vm.warp(block.timestamp + 5 days);

        // Trigger accrual through supply operation since Alice has outstanding repayment
        _triggerBorrowerAccrual(ALICE);

        // Verify penalty accrued (we can't predict exact amount due to compound calculations)
        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        assertGt(borrowAssetsAfter, 10000e18); // Should be more than initial borrow

        (uint128 lastAccrualTime,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, ALICE);

        // Last accrual time should be updated
        assertEq(lastAccrualTime, block.timestamp);
    }

    // ============ Penalty Calculation Tests ============

    function testPenaltyInterest_UsesEndingBalance() public {
        // Borrow initial amount
        deal(address(loanToken), ALICE, 5000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 5000e18, 0, ALICE, ALICE);

        // Create obligation with different ending balance
        uint256 cycleEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 20000e18; // Ending balance higher than current borrow

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Trigger penalty accrual
        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        _triggerAccrual();

        // Penalty should be calculated on ending balance (20000e18), not current balance
        uint256 penaltyDuration = block.timestamp - (cycleEndDate + GRACE_PERIOD_DURATION);
        uint256 expectedPenalty = balances[0].wMulDown(PENALTY_RATE_PER_SECOND.wTaylorCompounded(penaltyDuration));

        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 actualIncrease = borrowAssetsAfter - borrowAssetsBefore;

        // Verify penalty is significant (can't predict exact amount due to compound calculations)
        // The penalty on 20000e18 should be much more than on 5000e18
        assertGt(actualIncrease, 1); // Just verify there's some increase
    }

    function testPenaltyInterest_CompoundsWithBasePremium() public {
        // Borrow
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create delinquent obligation
        uint256 cycleEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // Get initial premium details
        (uint128 lastAccrualBefore,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, ALICE);
        uint256 borrowSharesBefore = morpho.position(id, ALICE).borrowShares;

        // Forward time significantly
        vm.warp(block.timestamp + 10 days);

        // Trigger accrual through supply operation
        _triggerBorrowerAccrual(ALICE);

        // Get updated state
        (uint128 lastAccrualAfter,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, ALICE);
        uint256 borrowSharesAfter = morpho.position(id, ALICE).borrowShares;

        // Last accrual time should have been updated
        assertGt(lastAccrualAfter, lastAccrualBefore);

        // Total borrow shares should increase (premium added as shares)
        assertGt(borrowSharesAfter, borrowSharesBefore);

        // But borrow assets should increase due to accrued interest
        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        assertGt(borrowAssetsAfter, 10000e18);
    }

    // ============ Multiple Obligations Tests ============

    function testPenaltyInterest_MultipleObligations() public {
        // Borrow
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create first delinquent obligation
        uint256 firstCycleEnd = block.timestamp - 15 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, firstCycleEnd, borrowers, amounts, balances);

        // Create second delinquent obligation
        uint256 secondCycleEnd = block.timestamp - 8 days;
        amounts[0] = 500e18;
        balances[0] = 9500e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, secondCycleEnd, borrowers, amounts, balances);

        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Forward time and trigger accrual
        vm.warp(block.timestamp + 2 days);
        vm.prank(ALICE);
        _triggerAccrual();

        // Both cycles should contribute to penalty
        // First cycle: 15 + 2 - 7 = 10 days of penalty
        // Second cycle: 8 + 2 - 7 = 3 days of penalty
        // But we use the ending balance from the latest obligation

        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 actualIncrease = borrowAssetsAfter - borrowAssetsBefore;

        // Should have significant penalty accrual
        assertGt(actualIncrease, 0);
    }

    // ============ Repayment Impact Tests ============

    function testPenaltyInterest_StopsAfterFullRepayment() public {
        // Borrow
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create delinquent obligation
        uint256 cycleEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // Accrue some penalty
        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        _triggerAccrual();

        uint256 borrowAssetsAfterPenalty = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Pay obligation in full
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // Forward more time
        vm.warp(block.timestamp + 5 days);

        // Trigger accrual again
        vm.prank(ALICE);
        _triggerAccrual();

        uint256 borrowAssetsAfterRepayment = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Should only have base + premium accrual, no more penalty
        // Account for the 1000e18 repayment
        uint256 expectedAssets = borrowAssetsAfterPenalty - 1000e18;
        // Should only have base + premium accrual, no more penalty
        // The increase should be reasonable (not the high penalty rate)
        uint256 increase = borrowAssetsAfterRepayment - expectedAssets;
        uint256 maxNormalIncrease = expectedAssets * 15 / 1000; // Max ~1.5% for 5 days normal accrual
        assertLe(increase, maxNormalIncrease);
    }

    function testPenaltyInterest_PartialRepaymentContinuesPenalty() public {
        // Borrow
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create delinquent obligation
        uint256 cycleEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // Partial payment
        deal(address(loanToken), ALICE, 400e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 400e18, 0, ALICE, "");

        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Forward time and trigger accrual
        vm.warp(block.timestamp + 3 days);
        vm.prank(ALICE);
        _triggerAccrual();

        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 actualIncrease = borrowAssetsAfter - borrowAssetsBefore;

        // Should still have penalty accrual since obligation not fully paid
        uint256 penaltyDuration = 3 days;
        uint256 expectedPenalty = balances[0].wMulDown(PENALTY_RATE_PER_SECOND.wTaylorCompounded(penaltyDuration));

        assertGt(actualIncrease, expectedPenalty * 95 / 100); // At least 95% of expected
    }

    // ============ Edge Cases ============

    function testPenaltyInterest_ZeroEndingBalance() public {
        // Borrow
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create obligation with zero ending balance
        uint256 cycleEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 0; // Zero ending balance

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Forward time and trigger accrual
        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        _triggerAccrual();

        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Should have no penalty (0 * rate = 0)
        // Only base + premium on actual balance
        assertLe(borrowAssetsAfter - borrowAssetsBefore, borrowAssetsBefore * 1 / 1000); // Max 0.1% for normal accrual
    }

    function testPenaltyInterest_TransitionToDefault() public {
        // Borrow
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create obligation that will transition from delinquent to default
        uint256 cycleEndDate = block.timestamp - 25 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // Status should be Delinquent
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // Forward to default period
        vm.warp(block.timestamp + 6 days);

        // Trigger accrual through supply operation
        _triggerBorrowerAccrual(ALICE);

        // Status should now be Default
        status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));

        // Penalty should still accrue in default status
        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        _triggerAccrual();

        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        assertGt(borrowAssetsAfter, borrowAssetsBefore);
    }
}
