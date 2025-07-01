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
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory endingBalances = new uint256[](2);

        borrowers[0] = ALICE;
        borrowers[1] = BOB;
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;
        endingBalances[0] = 10000e18;
        endingBalances[1] = 20000e18;

        // Expect event
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.PaymentCycleCreated(id, 0, 0, endDate);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, amounts, endingBalances);

        // Verify cycle was created
        assertEq(IMorphoCredit(address(morpho)).getLatestCycleId(id), 0);

        // Verify obligations were posted
        (uint128 cycleId, uint128 amountDue, uint256 balance) =
            IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(cycleId, 0);
        assertEq(amountDue, 1000e18);
        assertEq(balance, 10000e18);
    }

    function testCloseCycleAndPostObligations_InvalidCaller() public {
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory endingBalances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        endingBalances[0] = 10000e18;

        vm.expectRevert(bytes(ErrorsLib.NOT_CREDIT_LINE));
        vm.prank(ALICE); // Not the credit line
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, amounts, endingBalances);
    }

    function testCloseCycleAndPostObligations_FutureCycle() public {
        uint256 endDate = block.timestamp + 1 days; // Future date
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory endingBalances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        endingBalances[0] = 10000e18;

        vm.expectRevert("Cannot close future cycle");
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, amounts, endingBalances);
    }

    function testCloseCycleAndPostObligations_InvalidDuration() public {
        // Create first cycle
        uint256 firstEndDate = block.timestamp - 10 days;
        address[] memory borrowers = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, firstEndDate, borrowers, amounts, endingBalances
        );

        // Try to create second cycle that overlaps
        uint256 secondEndDate = firstEndDate + 12 hours; // Less than 1 day after first

        vm.expectRevert("Invalid cycle duration");
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, secondEndDate, borrowers, amounts, endingBalances
        );
    }

    function testCloseCycleAndPostObligations_LengthMismatch() public {
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](2);
        uint256[] memory amounts = new uint256[](1); // Mismatch
        uint256[] memory endingBalances = new uint256[](2);

        borrowers[0] = ALICE;
        borrowers[1] = BOB;
        amounts[0] = 1000e18;
        endingBalances[0] = 10000e18;
        endingBalances[1] = 20000e18;

        vm.expectRevert(bytes(ErrorsLib.INCONSISTENT_INPUT));
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, amounts, endingBalances);
    }

    // ============ Add to Latest Cycle Tests ============

    function testAddObligationsToLatestCycle_Success() public {
        // First create a cycle
        uint256 endDate = block.timestamp - 1 days;
        address[] memory initialBorrowers = new address[](1);
        uint256[] memory initialAmounts = new uint256[](1);
        uint256[] memory initialBalances = new uint256[](1);

        initialBorrowers[0] = ALICE;
        initialAmounts[0] = 1000e18;
        initialBalances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, endDate, initialBorrowers, initialAmounts, initialBalances
        );

        // Now add more obligations to the same cycle
        address[] memory newBorrowers = new address[](2);
        uint256[] memory newAmounts = new uint256[](2);
        uint256[] memory newBalances = new uint256[](2);

        newBorrowers[0] = BOB;
        newBorrowers[1] = CHARLIE;
        newAmounts[0] = 2000e18;
        newAmounts[1] = 3000e18;
        newBalances[0] = 20000e18;
        newBalances[1] = 30000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).addObligationsToLatestCycle(id, newBorrowers, newAmounts, newBalances);

        // Verify obligations were added
        (uint128 cycleId, uint128 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, BOB);
        assertEq(cycleId, 0);
        assertEq(amountDue, 2000e18);
    }

    function testAddObligationsToLatestCycle_NoCycles() public {
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.expectRevert("No cycles exist");
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).addObligationsToLatestCycle(id, borrowers, amounts, balances);
    }

    // ============ Obligation Posting Tests ============

    function testPostRepaymentObligation_OverwriteExisting() public {
        // Create cycle and post initial obligation
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, amounts, balances);

        // Create second cycle
        vm.warp(block.timestamp + 31 days); // Move time forward
        uint256 secondEndDate = block.timestamp - 1 days;
        amounts[0] = 500e18; // New amount
        balances[0] = 9500e18;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, secondEndDate, borrowers, amounts, balances);

        // Verify amount was overwritten (not accumulated)
        (, uint128 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDue, 500e18);
    }

    function testPostRepaymentObligation_EventEmission() public {
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        amounts[0] = 1000e18;
        balances[0] = 10000e18;

        // Expect RepaymentObligationPosted event
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.RepaymentObligationPosted(id, ALICE, 1000e18, 0, 10000e18);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, amounts, balances);
    }

    // ============ View Function Tests ============

    function testGetLatestCycleId_Success() public {
        // Create a cycle
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256[] memory balances = new uint256[](0);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, amounts, balances);

        assertEq(IMorphoCredit(address(morpho)).getLatestCycleId(id), 0);

        // Create another cycle
        vm.warp(block.timestamp + 31 days); // Move time forward
        uint256 secondEndDate = block.timestamp - 1 days;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, secondEndDate, borrowers, amounts, balances);

        assertEq(IMorphoCredit(address(morpho)).getLatestCycleId(id), 1);
    }

    function testGetLatestCycleId_NoCycles() public {
        vm.expectRevert("No cycles exist");
        IMorphoCredit(address(morpho)).getLatestCycleId(id);
    }

    function testGetCycleDates_FirstCycle() public {
        uint256 endDate = block.timestamp - 1 days;
        address[] memory borrowers = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256[] memory balances = new uint256[](0);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, endDate, borrowers, amounts, balances);

        (uint256 startDate, uint256 returnedEndDate) = IMorphoCredit(address(morpho)).getCycleDates(id, 0);

        assertEq(startDate, 0); // First cycle starts at 0
        assertEq(returnedEndDate, endDate);
    }

    function testGetCycleDates_SubsequentCycles() public {
        // Create first cycle
        uint256 firstEndDate = block.timestamp - 31 days;
        address[] memory borrowers = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256[] memory balances = new uint256[](0);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, firstEndDate, borrowers, amounts, balances);

        // Create second cycle
        uint256 secondEndDate = block.timestamp - 1 days;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(id, secondEndDate, borrowers, amounts, balances);

        (uint256 startDate, uint256 returnedEndDate) = IMorphoCredit(address(morpho)).getCycleDates(id, 1);

        assertEq(startDate, firstEndDate + 1 days);
        assertEq(returnedEndDate, secondEndDate);
    }

    function testGetCycleDates_InvalidCycleId() public {
        vm.expectRevert("Invalid cycle ID");
        IMorphoCredit(address(morpho)).getCycleDates(id, 0);
    }
}
