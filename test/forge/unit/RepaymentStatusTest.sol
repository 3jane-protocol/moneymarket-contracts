// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {Id, MarketParams, RepaymentStatus, IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";

contract RepaymentStatusTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;

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
            collateralToken: address(0), // No collateral for credit-based lending
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

        // Setup credit lines for borrowers
        vm.startPrank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 50000e18, 634195840); // 2% APR
        IMorphoCredit(address(morpho)).setCreditLine(id, BOB, 100000e18, 951293760); // 3% APR
        vm.stopPrank();

        // Warp time forward to avoid underflow in tests
        vm.warp(block.timestamp + 60 days); // 2 monthly cycles

        // Setup token approvals for test borrowers
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(BOB);
        loanToken.approve(address(morpho), type(uint256).max);

        // Have borrowers take out loans
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        deal(address(loanToken), BOB, 20000e18);
        vm.prank(BOB);
        morpho.borrow(marketParams, 20000e18, 0, BOB, BOB);
    }

    // ============ Current Status Tests ============

    function testRepaymentStatus_Current_NoObligations() public {
        // User with no obligations should be Current
        address CHARLIE = makeAddr("Charlie");

        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, CHARLIE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    function testRepaymentStatus_Current_ObligationFullyPaid() public {
        // Create a cycle with obligation
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, CYCLE_DURATION / 1 days);

        // ALICE fully pays the obligation
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // Status should be Current
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    function testRepaymentStatus_GracePeriod_WithOutstandingDebt() public {
        // Create a cycle ending 2 days ago (within grace period)
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 2);

        // No payment - still within grace period with outstanding debt, should be GracePeriod
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod));
    }

    // ============ Grace Period Status Tests ============

    function testRepaymentStatus_GracePeriod() public {
        // Create a cycle ending 4 days ago (past grace, not yet delinquent)
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 4);

        // No payment - should be in Grace Period
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod));
    }

    function testRepaymentStatus_GracePeriod_EdgeCase() public {
        // Test exactly at grace period boundary
        uint256 cycleEndDate = block.timestamp - GRACE_PERIOD_DURATION;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // No payment - exactly at grace period boundary, should still be in grace
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod));
    }

    // ============ Delinquent Status Tests ============

    function testRepaymentStatus_Delinquent() public {
        // Create a cycle ending 10 days ago (delinquent)
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 10);

        // No payment - should be Delinquent
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));
    }

    function testRepaymentStatus_Delinquent_JustPastGrace() public {
        // Test just past delinquency threshold
        uint256 cycleEndDate = block.timestamp - GRACE_PERIOD_DURATION - 1;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // No payment - should be Delinquent (just past grace)
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));
    }

    // ============ Default Status Tests ============

    function testRepaymentStatus_Default() public {
        // Create a cycle ending 31 days ago (in default)
        uint256 cycleEndDate = block.timestamp - 31 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // No payment
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));
    }

    function testRepaymentStatus_Default_ExactBoundary() public {
        // Test exactly at default boundary (30 days)
        uint256 cycleEndDate = block.timestamp - (GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION);
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Should still be Default at exactly 30 days
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));
    }

    function testRepaymentStatus_Default_WithPartialPayment() public {
        // Test that partial payments are rejected in default status
        uint256 cycleEndDate = block.timestamp - 35 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Verify partial payment is rejected
        deal(address(loanToken), ALICE, 999e18);
        vm.prank(ALICE);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 999e18, 0, ALICE, "");

        // Status remains Default
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));
    }

    // ============ Status Transition Tests ============

    function testRepaymentStatus_TransitionAfterPayment() public {
        // Create obligation in delinquent period
        uint256 cycleEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Verify delinquent
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // Full payment
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // Should transition to Current
        status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    function testRepaymentStatus_TimeBasedTransition() public {
        // Create obligation just in grace period
        uint256 cycleEndDate = block.timestamp - 4 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Verify Grace Period
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod));

        // Fast forward to delinquent period
        vm.warp(block.timestamp + 4 days);

        // Should now be Delinquent
        status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // Fast forward to default period
        vm.warp(block.timestamp + 25 days);

        // Should now be Default
        status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));
    }

    // ============ Multiple Cycles Tests ============

    function testRepaymentStatus_MultipleCycles_OldestDeterminesStatus() public {
        // Create first cycle - old enough to be delinquent
        uint256 firstCycleEnd = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, firstCycleEnd, borrowers, repaymentBps, balances
        );

        // Create second cycle - recent (would be Current)
        uint256 secondCycleEnd = block.timestamp - 1 days;
        repaymentBps[0] = 500; // 5%
        balances[0] = 9500e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, secondCycleEnd, borrowers, repaymentBps, balances
        );

        // Status should be based on oldest unpaid cycle (Delinquent)
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));
    }

    function testRepaymentStatus_MultipleCycles_PaymentOverwritesObligation() public {
        // Create cycle with 1000e18 obligation
        uint256 cycleEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Warp forward to create second cycle (but not so far that first cycle goes to default)
        vm.warp(block.timestamp + 15 days);

        // Add another cycle with 500e18 obligation
        uint256 secondCycleEnd = block.timestamp - 1 days;
        repaymentBps[0] = 500; // 5%
        balances[0] = 9500e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, secondCycleEnd, borrowers, repaymentBps, balances
        );

        // Total obligation is overwritten to 475e18 (not accumulated)
        (, uint128 totalDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(totalDue, 475e18); // 5% of 9500e18

        // Must pay full amount - verify partial payment is rejected
        deal(address(loanToken), ALICE, 400e18);
        vm.prank(ALICE);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 400e18, 0, ALICE, "");

        // Status remains Delinquent
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // Pay full amount (475e18)
        deal(address(loanToken), ALICE, 475e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 475e18, 0, ALICE, "");

        // Should now be Current
        status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    // ============ Edge Cases ============

    function testRepaymentStatus_ZeroObligation() public {
        // Create cycle with zero obligation
        uint256 cycleEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 0; // 0%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Should be Current (no payment due)
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    function testRepaymentStatus_OverPayment() public {
        // Create obligation
        uint256 cycleEndDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, cycleEndDate, borrowers, repaymentBps, balances);

        // Overpay
        deal(address(loanToken), ALICE, 2000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 2000e18, 0, ALICE, "");

        // Should be Current
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));

        // Obligation should be fully paid
        (, uint128 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDue, 0);
    }
}
