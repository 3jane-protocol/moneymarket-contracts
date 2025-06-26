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

contract RepaymentTrackingIntegrationTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    CreditLineMock internal creditLine;
    ConfigurableIrmMock internal configurableIrm;

    // Test borrowers
    address internal ALICE;
    address internal BOB;
    address internal CHARLIE;

    // Test-specific constants (common ones are in BaseTest)

    function setUp() public override {
        super.setUp();

        ALICE = makeAddr("Alice");
        BOB = makeAddr("Bob");
        CHARLIE = makeAddr("Charlie");

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Deploy configurable IRM
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

        // Setup liquidity
        deal(address(loanToken), SUPPLIER, 1000000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");

        // Setup credit lines
        vm.startPrank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 50000e18, 634195840); // 2% premium
        IMorphoCredit(address(morpho)).setCreditLine(id, BOB, 100000e18, 951293759); // 3% premium
        IMorphoCredit(address(morpho)).setCreditLine(id, CHARLIE, 75000e18, 317097920); // 1% premium
        vm.stopPrank();

        // Warp time forward to avoid underflow in tests
        vm.warp(block.timestamp + 60 days); // 2 monthly cycles

        // Setup token approvals for test borrowers
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(BOB);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(CHARLIE);
        loanToken.approve(address(morpho), type(uint256).max);
    }

    // ============ Full Cycle Flow Tests ============

    function testFullCycleFlow_SingleBorrower() public {
        // 1. Alice borrows
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        uint256 initialBorrowAssets = morpho.expectedBorrowAssets(marketParams, ALICE);

        // 2. Advance time to simulate a month
        vm.warp(block.timestamp + CYCLE_DURATION);

        // 3. Credit line posts obligation
        uint256 cycleEndDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18; // Monthly payment
        balances[0] = initialBorrowAssets; // Current balance

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // 4. Verify borrowing is blocked
        vm.expectRevert(bytes(ErrorsLib.OUTSTANDING_REPAYMENT));
        vm.prank(ALICE);
        morpho.borrow(marketParams, 1000e18, 0, ALICE, ALICE);

        // 5. Alice makes payment
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // 6. Verify status is current
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));

        // 7. Verify borrowing is allowed again
        deal(address(loanToken), ALICE, 5000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 5000e18, 0, ALICE, ALICE);
    }

    function testFullCycleFlow_MultipleBorrowers() public {
        // 1. Multiple borrowers take loans
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        deal(address(loanToken), BOB, 20000e18);
        vm.prank(BOB);
        morpho.borrow(marketParams, 20000e18, 0, BOB, BOB);

        deal(address(loanToken), CHARLIE, 15000e18);
        vm.prank(CHARLIE);
        morpho.borrow(marketParams, 15000e18, 0, CHARLIE, CHARLIE);

        // 2. Advance time
        vm.warp(block.timestamp + CYCLE_DURATION);

        // 3. Post obligations for all borrowers
        uint256 cycleEndDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        uint256[] memory balances = new uint256[](3);

        borrowers[0] = ALICE;
        borrowers[1] = BOB;
        borrowers[2] = CHARLIE;
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;
        amounts[2] = 1500e18;
        balances[0] = 10000e18;
        balances[1] = 20000e18;
        balances[2] = 15000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // 4. Verify all borrowers are blocked from borrowing
        vm.expectRevert(bytes(ErrorsLib.OUTSTANDING_REPAYMENT));
        vm.prank(ALICE);
        morpho.borrow(marketParams, 100e18, 0, ALICE, ALICE);

        vm.expectRevert(bytes(ErrorsLib.OUTSTANDING_REPAYMENT));
        vm.prank(BOB);
        morpho.borrow(marketParams, 100e18, 0, BOB, BOB);

        // 5. Alice pays in full, Bob pays partial
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        deal(address(loanToken), BOB, 1000e18);
        vm.prank(BOB);
        morpho.repay(marketParams, 1000e18, 0, BOB, "");

        // 6. Alice can borrow, Bob cannot
        deal(address(loanToken), ALICE, 500e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 500e18, 0, ALICE, ALICE); // Should succeed

        vm.expectRevert(bytes(ErrorsLib.OUTSTANDING_REPAYMENT));
        vm.prank(BOB);
        morpho.borrow(marketParams, 500e18, 0, BOB, BOB); // Should fail
    }

    // ============ Delinquency Flow Tests ============

    function testDelinquencyFlow_WithPenaltyAccrual() public {
        // 1. Setup: Alice borrows
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // 2. Create obligation
        uint256 cycleEndDate = block.timestamp - 10 days; // Already delinquent
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // 3. Verify status is delinquent
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // 4. Record borrow assets before penalty accrual
        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // 5. Advance time and trigger penalty accrual
        vm.warp(block.timestamp + 5 days);
        vm.prank(ALICE);
        _triggerAccrual(); // Trigger market-wide accrual

        // 6. Verify penalty was accrued
        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        assertGt(borrowAssetsAfter, borrowAssetsBefore);

        // 7. Make partial payment
        deal(address(loanToken), ALICE, 500e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 500e18, 0, ALICE, "");

        // 8. Status should still be delinquent
        status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // 9. Pay remaining amount
        deal(address(loanToken), ALICE, 500e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 500e18, 0, ALICE, "");

        // 10. Status should be current
        status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    // ============ Multiple Cycle Tests ============

    function testMultipleCycles_AccumulatingObligations() public {
        // Setup: Alice borrows
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Cycle 1
        vm.warp(block.timestamp + CYCLE_DURATION);
        uint256 cycle1EndDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycle1EndDate, borrowers, amounts, balances);

        // Alice doesn't pay cycle 1

        // Cycle 2
        vm.warp(block.timestamp + CYCLE_DURATION);
        uint256 cycle2EndDate = block.timestamp - 1 days;
        amounts[0] = 1100e18; // Higher payment
        balances[0] = 11000e18; // Balance grew

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycle2EndDate, borrowers, amounts, balances);

        // Check total obligation
        (, uint128 totalDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(totalDue, 2100e18); // 1000 + 1100

        // Status should be based on oldest cycle (now in default)
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));

        // Partial payment
        deal(address(loanToken), ALICE, 1500e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1500e18, 0, ALICE, "");

        // Should still have outstanding amount
        (, uint128 remainingDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(remainingDue, 600e18); // 2100 - 1500 = 600

        // Pay remaining
        deal(address(loanToken), ALICE, 600e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 600e18, 0, ALICE, "");

        // Should be current now
        status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    // ============ Liquidation Integration Tests ============

    // TODO: Liquidation tests will be updated when liquidation logic changes
    /*
    function testLiquidation_WithRepaymentTracking() public {
        // Alice borrows
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
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id,
            cycleEndDate,
            borrowers,
            amounts,
            balances
        );

        // Advance time to accrue penalties
        vm.warp(block.timestamp + 5 days);

        // Liquidator repays part of the debt
        deal(address(loanToken), LIQUIDATOR, 5000e18);
        vm.prank(LIQUIDATOR);
        morpho.liquidate(marketParams, ALICE, 0, 5000e18, "");

        // Check paid amount was updated
        (, uint256 paidAmount) = IMorphoCredit(address(morpho)).totalPaidAmount(id, ALICE);
        
        // Payment should be applied to obligation first
        uint256 expectedPaid = 5000e18 > amounts[0] ? amounts[0] : 5000e18;
        assertEq(paidAmount, expectedPaid);

        // If liquidation covered obligation, status should improve
        if (paidAmount >= amounts[0]) {
            RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
            assertEq(uint256(status), uint256(RepaymentStatus.Current));
        }
    }
    */

    // ============ Edge Case Tests ============

    function testRepaymentTracking_ZeroAmountOperations() public {
        // Setup obligation
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        uint256 cycleEndDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // Zero repayment should still trigger premium accrual
        uint256 borrowSharesBefore = morpho.position(id, ALICE).borrowShares;

        vm.warp(block.timestamp + 1 days);

        // Trigger accrual through a minimal repay operation
        deal(address(loanToken), ALICE, 1);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1, 0, ALICE, "");

        // Premium should have accrued
        (uint128 lastAccrualTime,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, ALICE);
        assertEq(lastAccrualTime, block.timestamp);
    }

    function testRepaymentTracking_ExcessPayment() public {
        // Setup
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        uint256 cycleEndDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, amounts, balances);

        // Pay more than obligation
        deal(address(loanToken), ALICE, 2000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 2000e18, 0, ALICE, "");

        // Obligation should be fully paid
        (, uint128 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDue, 0);

        // Status should be current
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));

        // Actual debt should be reduced by full 2000
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, ALICE);
        assertLe(borrowAssets, 8100e18); // ~8000 + some interest
    }

    function testRepaymentTracking_RapidCycles() public {
        // Test handling of multiple cycles in quick succession
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);
        borrowers[0] = ALICE;

        // Create 3 cycles rapidly
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 2 days);

            amounts[0] = 300e18 + (i * 100e18); // 300, 400, 500
            balances[0] = 10000e18 + (i * 1000e18); // Growing balance

            vm.prank(address(creditLine));
            IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
                id, block.timestamp - 1 hours, borrowers, amounts, balances
            );
        }

        // Total obligation should be sum
        (, uint128 totalDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(totalDue, 1200e18); // 300 + 400 + 500

        // Latest cycle ID should be 2
        uint256 latestCycle = IMorphoCredit(address(morpho)).getLatestCycleId(id);
        assertEq(latestCycle, 2);
    }
}
