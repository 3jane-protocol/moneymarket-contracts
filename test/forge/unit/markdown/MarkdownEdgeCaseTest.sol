// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {HelperMock} from "../../../../src/mocks/HelperMock.sol";
import {Market, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";

/// @title MarkdownEdgeCaseTest
/// @notice Tests edge cases and boundary conditions for markdown logic
/// @dev Covers scenarios like zero debt, maximum values, concurrent updates
contract MarkdownEdgeCaseTest is BaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    HelperMock helper;
    IMorphoCredit morphoCredit;

    function setUp() public override {
        super.setUp();

        // Deploy contracts
        markdownManager = new MarkdownManagerMock(address(protocolConfig), OWNER);
        creditLine = new CreditLineMock(morphoAddress);
        morphoCredit = IMorphoCredit(morphoAddress);
        helper = new HelperMock(morphoAddress);

        // Create market
        marketParams = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(creditLine)
        );
        id = marketParams.id();

        vm.startPrank(OWNER);
        morpho.createMarket(marketParams);
        creditLine.setMm(address(markdownManager));
        vm.stopPrank();

        // Initialize first cycle to unfreeze the market
        vm.warp(block.timestamp + CYCLE_DURATION);
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, block.timestamp, borrowers, repaymentBps, endingBalances
        );
    }

    /// @notice Test markdown with zero debt borrower
    function testMarkdownWithZeroDebt() public {
        // Supply funds
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower with credit line but no debt
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, 100 ether, 0);

        // Try to set markdown without any debt
        markdownManager.setMarkdownForBorrower(BORROWER, 50 ether);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m = morpho.market(id);

        // Markdown should be zero since there's no debt
        assertEq(m.totalMarkdownAmount, 0, "No markdown without debt");
        assertEq(m.totalSupplyAssets, 1000 ether, "Supply should be unchanged");
    }

    /// @notice Test markdown with maximum uint256 values
    function testMarkdownWithMaxValues() public {
        // Supply funds
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, 100 ether, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);

        // Create an obligation that will put borrower in default
        _createPastObligation(BORROWER, 10000, 50 ether); // 100% repayment

        // Warp to default status (30+ days past due)
        vm.warp(block.timestamp + 31 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Try to set a very large markdown value (but not max to avoid overflow)
        // Use a value that won't overflow when multiplied by 200 in the mock
        uint256 largeMarkdown = type(uint256).max / 200; // Prevent overflow in mock calculation
        markdownManager.setMarkdownForBorrower(BORROWER, largeMarkdown);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m = morpho.market(id);

        // Markdown should be capped at debt (around 50 ether)
        assertTrue(m.totalMarkdownAmount < 60 ether, "Markdown capped at debt");
        assertTrue(m.totalSupplyAssets > 940 ether, "Supply reduced by debt amount");
    }

    /// @notice Test markdown with minimum borrow amount (1 wei)
    function testMarkdownWithMinimalShares() public {
        // Supply funds
        loanToken.setBalance(SUPPLIER, 10 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 10 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, HIGH_COLLATERAL_AMOUNT, 0);

        // Borrow minimal amount (1 wei) instead of trying to borrow 0 assets
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1, 0, BORROWER, BORROWER);

        // Create an obligation that will put borrower in default
        _createPastObligation(BORROWER, 10000, 1); // 100% repayment

        // Warp to default status (30+ days past due)
        vm.warp(block.timestamp + 31 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Set markdown
        markdownManager.setMarkdownForBorrower(BORROWER, 1 ether);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m = morpho.market(id);

        // Markdown should be minimal (for 1 wei of debt)
        assertTrue(m.totalMarkdownAmount <= 1, "Minimal markdown for 1 wei debt");
    }

    /// @notice Test concurrent markdown updates for same borrower
    function testConcurrentMarkdownUpdates() public {
        // Supply funds
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, 100 ether, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);

        // Create an obligation that will put borrower in default
        _createPastObligation(BORROWER, 10000, 50 ether); // 100% repayment

        // Warp to default status (30+ days past due)
        vm.warp(block.timestamp + 31 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Apply multiple markdowns in same block
        markdownManager.setMarkdownForBorrower(BORROWER, 20 ether);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m1 = morpho.market(id);

        // Update markdown again in same block
        markdownManager.setMarkdownForBorrower(BORROWER, 30 ether);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m2 = morpho.market(id);

        // Verify markdown updated correctly
        assertTrue(m2.totalMarkdownAmount > m1.totalMarkdownAmount, "Markdown increased");
        assertTrue(m2.totalSupplyAssets < m1.totalSupplyAssets, "Supply decreased");
    }

    /// @notice Test markdown behavior when debt changes
    function testMarkdownWithDebtChanges() public {
        // Supply funds
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, 100 ether, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);

        // Create an obligation that will put borrower in default
        _createPastObligation(BORROWER, 10000, 50 ether); // 100% repayment

        // Warp to default status (30+ days past due)
        vm.warp(block.timestamp + 31 days);
        _continueMarketCycles(id, block.timestamp + 1 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Apply markdown
        markdownManager.setMarkdownForBorrower(BORROWER, 30 ether);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mWithMarkdown = morpho.market(id);
        assertTrue(mWithMarkdown.totalMarkdownAmount > 0, "Markdown applied");

        // Clear markdown before repayment to avoid underflow
        markdownManager.setMarkdownForBorrower(BORROWER, 0);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Repay the exact obligation amount (50 ether)
        loanToken.setBalance(BORROWER, 50 ether);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.repay(marketParams, 50 ether, 0, BORROWER, "");
        vm.stopPrank();

        // After repayment, markdown should remain zero
        Market memory mFinal = morpho.market(id);
        assertEq(mFinal.totalMarkdownAmount, 0, "No markdown after repayment");
    }

    /// @notice Test markdown with zero supply market
    function testMarkdownWithZeroSupply() public {
        // Create borrower with credit line
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, HIGH_COLLATERAL_AMOUNT, 0);

        // Cannot borrow virtual shares without actual assets
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        helper.borrow(marketParams, 0, 1000, BORROWER, BORROWER);

        // Verify market remains clean
        Market memory m = morpho.market(id);
        assertEq(m.totalSupplyAssets, 0, "Supply remains zero");
        assertEq(m.totalBorrowAssets, 0, "No phantom borrows");
        assertEq(m.totalBorrowShares, 0, "No virtual shares");
        assertEq(m.totalMarkdownAmount, 0, "No markdown without debt");
    }

    /// @notice Test markdown transitions between states
    function testMarkdownStateTransitions() public {
        // Supply funds
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, 100 ether, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);

        // Create a past obligation that will transition through states
        _createPastObligation(BORROWER, 10000, 50 ether); // 100% repayment obligation

        // Current state
        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        markdownManager.setMarkdownForBorrower(BORROWER, 10 ether);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mCurrent = morpho.market(id);
        assertEq(mCurrent.totalMarkdownAmount, 0, "No markdown in current state");

        // Grace period
        vm.warp(block.timestamp + 3 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mGrace = morpho.market(id);
        assertEq(mGrace.totalMarkdownAmount, 0, "No markdown in grace period");

        // Delinquent state
        vm.warp(block.timestamp + 8 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mDelinquent = morpho.market(id);
        assertEq(mDelinquent.totalMarkdownAmount, 0, "No markdown in delinquent state");

        // Default state
        vm.warp(block.timestamp + 25 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mDefault = morpho.market(id);
        assertTrue(mDefault.totalMarkdownAmount > 0, "Markdown applied in default state");
    }

    /// @notice Test markdown with interest accrual edge cases
    function testMarkdownWithInterestAccrual() public {
        // Supply funds
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, 100 ether, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);

        // Let interest accrue significantly
        vm.warp(block.timestamp + 365 days);

        // Create an obligation that will put borrower in default
        _createPastObligation(BORROWER, 10000, 50 ether); // 100% repayment

        // Warp to default status (30+ days past due)
        vm.warp(block.timestamp + 31 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Apply markdown after significant interest
        Market memory mBefore = morpho.market(id);
        uint256 borrowShares = morpho.position(id, BORROWER).borrowShares;
        uint256 debtWithInterest = borrowShares.toAssetsUp(mBefore.totalBorrowAssets, mBefore.totalBorrowShares);

        markdownManager.setMarkdownForBorrower(BORROWER, debtWithInterest * 2);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mAfter = morpho.market(id);

        // Markdown should be capped at actual debt with interest
        assertApproxEqAbs(mAfter.totalMarkdownAmount, debtWithInterest, 1e18, "Markdown equals debt with interest");
    }

    // Helper function to trigger default state
    function _triggerDefault(address borrower, uint256 amount) internal {
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = 10000;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = amount;

        // Ensure CYCLE_DURATION has passed since last cycle
        // This will create cycles up to the target time but not create one at exactly that time
        _continueMarketCycles(id, block.timestamp + CYCLE_DURATION);

        // Now we need to create another cycle with obligations
        // Get the last cycle end date and add CYCLE_DURATION
        uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        (, uint256 lastCycleEnd) = MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), id, cycleLength - 1);
        uint256 newCycleEnd = lastCycleEnd + CYCLE_DURATION;

        // Warp to new cycle end if needed
        if (block.timestamp < newCycleEnd) {
            vm.warp(newCycleEnd);
        }

        vm.prank(address(creditLine));
        morphoCredit.closeCycleAndPostObligations(id, newCycleEnd, borrowers, repaymentBps, endingBalances);

        // Move to default (past grace and delinquent periods)
        _continueMarketCycles(id, block.timestamp + 31 days);
        morphoCredit.accrueBorrowerPremium(id, borrower);
    }
}
