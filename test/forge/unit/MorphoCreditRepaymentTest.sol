// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {
    Id,
    MarketParams,
    RepaymentStatus,
    PaymentCycle,
    RepaymentObligation,
    IMorphoCredit
} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";

contract MorphoCreditRepaymentTest is BaseTest {
    using MarketParamsLib for MarketParams;

    CreditLineMock internal creditLine;
    address internal CREDIT_LINE_OWNER;

    // Test borrowers
    address internal ALICE;
    address internal BOB;
    address internal CHARLIE;

    function setUp() public override {
        super.setUp();

        CREDIT_LINE_OWNER = makeAddr("CreditLineOwner");
        ALICE = makeAddr("Alice");
        BOB = makeAddr("Bob");
        CHARLIE = makeAddr("Charlie");

        // Warp time forward to avoid underflow in tests
        vm.warp(block.timestamp + 365 days);

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Create market with credit line
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0), // No collateral for credit-based lending
            oracle: address(0),
            irm: address(irm),
            lltv: 0,
            creditLine: address(creditLine)
        });

        id = marketParams.id();
        vm.prank(OWNER);
        morpho.createMarket(marketParams);

        // Setup test tokens
        deal(address(loanToken), SUPPLIER, 1000000e18);

        // Supply liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");
    }

    // ============ Payment Cycle Management Tests ============

    function testCloseCycleAndPostObligations_Success() public {
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](2);
        uint256[] memory repaymentBps = new uint256[](2);
        uint256[] memory endingBalances = new uint256[](2);

        borrowers[0] = ALICE;
        borrowers[1] = BOB;
        repaymentBps[0] = 1000; // 10%
        repaymentBps[1] = 1000; // 10%
        endingBalances[0] = 10000e18;
        endingBalances[1] = 20000e18;

        // Expect event
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.PaymentCycleCreated(id, 0, 0, endDate);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, endDate, borrowers, repaymentBps, endingBalances
        );

        // Verify cycle was created
        uint256 paymentCycleLength = IMorphoCredit(address(morpho)).getPaymentCycleLength(id);
        assertEq(paymentCycleLength, 1); // First cycle created, so length is 1

        // Verify obligations were posted (10% of ending balance)
        (uint128 cycleId, uint128 amountDue, uint256 balance) =
            IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(cycleId, 0);
        assertEq(amountDue, 1000e18); // 10% of 10000e18
        assertEq(balance, 10000e18);
    }

    function testCloseCycleAndPostObligations_InvalidCaller() public {
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory endingBalances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        endingBalances[0] = 10000e18;

        vm.expectRevert(ErrorsLib.NotCreditLine.selector);
        vm.prank(ALICE); // Not the credit line
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, endDate, borrowers, repaymentBps, endingBalances
        );
    }

    function testCloseCycleAndPostObligations_FutureCycle() public {
        uint256 endDate = block.timestamp + 1 days; // Future date
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory endingBalances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        endingBalances[0] = 10000e18;

        vm.expectRevert(ErrorsLib.CannotCloseFutureCycle.selector);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, endDate, borrowers, repaymentBps, endingBalances
        );
    }

    function testCloseCycleAndPostObligations_InvalidDuration() public {
        // Create first cycle
        uint256 firstEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, firstEndDate, borrowers, repaymentBps, endingBalances
        );

        // Try to create second cycle that overlaps
        uint256 secondEndDate = firstEndDate + 12 hours; // Less than 1 day after first

        vm.expectRevert(ErrorsLib.InvalidCycleDuration.selector);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, secondEndDate, borrowers, repaymentBps, endingBalances
        );
    }

    function testCloseCycleAndPostObligations_LengthMismatch() public {
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](2);
        uint256[] memory repaymentBps = new uint256[](1); // Mismatch
        uint256[] memory endingBalances = new uint256[](2);

        borrowers[0] = ALICE;
        borrowers[1] = BOB;
        repaymentBps[0] = 1000; // 10%
        endingBalances[0] = 10000e18;
        endingBalances[1] = 20000e18;

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, endDate, borrowers, repaymentBps, endingBalances
        );
    }

    // ============ Add to Latest Cycle Tests ============

    function testAddObligationsToLatestCycle_Success() public {
        // First create a cycle
        uint256 endDate = block.timestamp - 1 days;
        address[] memory initialBorrowers = new address[](1);
        uint256[] memory initialRepaymentBps = new uint256[](1);
        uint256[] memory initialBalances = new uint256[](1);

        initialBorrowers[0] = ALICE;
        initialRepaymentBps[0] = 1000; // 10%
        initialBalances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, endDate, initialBorrowers, initialRepaymentBps, initialBalances
        );

        // Now add more obligations to the same cycle
        address[] memory newBorrowers = new address[](2);
        uint256[] memory newRepaymentBps = new uint256[](2);
        uint256[] memory newBalances = new uint256[](2);

        newBorrowers[0] = BOB;
        newBorrowers[1] = CHARLIE;
        newRepaymentBps[0] = 1000; // 10%
        newRepaymentBps[1] = 1000; // 10%
        newBalances[0] = 20000e18;
        newBalances[1] = 30000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).addObligationsToLatestCycle(id, newBorrowers, newRepaymentBps, newBalances);

        // Verify obligations were added
        (uint128 cycleId, uint128 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, BOB);
        assertEq(cycleId, 0);
        assertEq(amountDue, 2000e18); // 10% of 20000e18
    }

    function testAddObligationsToLatestCycle_NoCycles() public {
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.expectRevert(ErrorsLib.NoCyclesExist.selector);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).addObligationsToLatestCycle(id, borrowers, repaymentBps, balances);
    }

    // ============ Obligation Posting Tests ============

    function testPostRepaymentObligation_OverwriteExisting() public {
        // Create cycle and post initial obligation
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, repaymentBps, balances);

        // Create second cycle
        vm.warp(block.timestamp + 31 days); // Move time forward
        uint256 secondEndDate = block.timestamp - 1 days;
        repaymentBps[0] = 526; // ~5.26% to get 500e18 from 9500e18
        balances[0] = 9500e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, secondEndDate, borrowers, repaymentBps, balances
        );

        // Verify amount was overwritten (not accumulated)
        (, uint128 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDue, 499700000000000000000); // ~500e18 (5.26% of 9500e18)
    }

    function testPostRepaymentObligation_EventEmission() public {
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        // Expect RepaymentObligationPosted event
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.RepaymentObligationPosted(id, ALICE, 1000e18, 0, 10000e18); // 10% of 10000e18

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, repaymentBps, balances);
    }

    // ============ View Function Tests ============

    function testGetLatestCycleId_Success() public {
        // Create a cycle
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory balances = new uint256[](0);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, repaymentBps, balances);

        uint256 paymentCycleLength = IMorphoCredit(address(morpho)).getPaymentCycleLength(id);
        assertEq(paymentCycleLength, 1); // First cycle created, so length is 1

        // Create another cycle
        vm.warp(block.timestamp + 31 days); // Move time forward
        uint256 secondEndDate = block.timestamp - 1 days;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, secondEndDate, borrowers, repaymentBps, balances
        );

        paymentCycleLength = IMorphoCredit(address(morpho)).getPaymentCycleLength(id);
        assertEq(paymentCycleLength, 2); // Second cycle created
    }

    function testGetLatestCycleId_NoCycles() public {
        // Test removed as getLatestCycleId function was removed
        // Users should check paymentCycleLength == 0 instead
        uint256 paymentCycleLength = IMorphoCredit(address(morpho)).getPaymentCycleLength(id);
        assertEq(paymentCycleLength, 0);
    }

    function testGetCycleDates_FirstCycle() public {
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory balances = new uint256[](0);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, repaymentBps, balances);

        (uint256 startDate, uint256 returnedEndDate) = IMorphoCredit(address(morpho)).getCycleDates(id, 0);

        assertEq(startDate, 0); // First cycle starts at 0
        assertEq(returnedEndDate, endDate);
    }

    function testGetCycleDates_SubsequentCycles() public {
        // Create first cycle
        uint256 firstEndDate = block.timestamp - 31 days;
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory balances = new uint256[](0);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, firstEndDate, borrowers, repaymentBps, balances);

        // Create second cycle
        uint256 secondEndDate = block.timestamp - 1 days;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, secondEndDate, borrowers, repaymentBps, balances
        );

        (uint256 startDate, uint256 returnedEndDate) = IMorphoCredit(address(morpho)).getCycleDates(id, 1);

        assertEq(startDate, firstEndDate + 1 days);
        assertEq(returnedEndDate, secondEndDate);
    }

    function testGetCycleDates_InvalidCycleId() public {
        vm.expectRevert(ErrorsLib.InvalidCycleId.selector);
        IMorphoCredit(address(morpho)).getCycleDates(id, 0);
    }
}
