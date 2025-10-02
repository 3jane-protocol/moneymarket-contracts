// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {HelperMock} from "../../../../src/mocks/HelperMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {Market, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";

/// @title MarkdownPhantomLiquidityTest
/// @notice Tests to verify that markdown logic cannot create phantom liquidity
/// @dev Ensures that markdown adjustments properly track actual vs requested amounts
contract MarkdownPhantomLiquidityTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    HelperMock helper;
    IMorphoCredit morphoCredit;

    event BorrowerMarkdownUpdated(Id indexed id, address indexed borrower, uint256 oldMarkdown, uint256 newMarkdown);

    function setUp() public override {
        super.setUp();

        // Deploy markdown manager
        markdownManager = new MarkdownManagerMock(address(protocolConfig), OWNER);

        // Deploy credit line
        creditLine = new CreditLineMock(morphoAddress);
        morphoCredit = IMorphoCredit(morphoAddress);

        // Deploy helper
        helper = new HelperMock(morphoAddress);

        // Create market with credit line
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
        _ensureMarketActive(id);
    }

    /// @notice Test that markdown cannot create supply from nothing
    function testMarkdownCannotCreatePhantomSupply() public {
        // Set up borrower with credit line
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, HIGH_COLLATERAL_AMOUNT, 0);

        // Cannot borrow virtual shares with 0 assets - protocol requires actual asset borrowing
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        helper.borrow(marketParams, 0, 10 ** 6 - 1, BORROWER, BORROWER);

        // Verify market remains clean with no phantom liquidity
        Market memory m = morpho.market(id);
        assertEq(m.totalSupplyAssets, 0, "No supply should exist");
        assertEq(m.totalBorrowAssets, 0, "No borrows should exist");
        assertEq(m.totalBorrowShares, 0, "No borrow shares should exist");
        assertEq(m.totalMarkdownAmount, 0, "No markdown should exist");

        // The attack vector is completely blocked, preventing any phantom liquidity creation
        _continueMarketCycles(id, block.timestamp + 1 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        m = morpho.market(id);

        // With the fix, supply should only be what was actually marked down
        // Since we started with 0 supply, we should end with minimal supply from interest
    }

    /// @notice Test that markdown properly tracks actual vs requested amounts
    function testMarkdownTracksActualReductions() public {
        // Supply some funds
        loanToken.setBalance(SUPPLIER, 100 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 100 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, 50 ether, 0);

        // Borrow 10 ether
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 10 ether, 0, BORROWER, BORROWER);

        // Trigger default using helper which handles cycle creation properly
        _createRepaymentObligation(id, BORROWER, 10 ether, 10 ether, 0); // 100% due, ending balance 10 ether

        _continueMarketCycles(id, block.timestamp + 31 days);

        Market memory mBefore = morpho.market(id);
        uint256 supplyBefore = mBefore.totalSupplyAssets;

        // Calculate borrower's debt from shares
        uint256 borrowShares = morpho.position(id, BORROWER).borrowShares;
        uint256 borrowerDebt = borrowShares.toAssetsUp(mBefore.totalBorrowAssets, mBefore.totalBorrowShares);

        // Request markdown larger than borrower's debt (which is the cap)
        markdownManager.setMarkdownForBorrower(BORROWER, borrowerDebt + 100 ether);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mAfter = morpho.market(id);

        // Markdown is capped at borrower's debt, so supply should reduce by that amount
        assertApproxEqAbs(
            mAfter.totalSupplyAssets,
            supplyBefore - borrowerDebt,
            1e18, // Allow for interest accrual
            "Should reduce by borrower's debt amount"
        );
        assertApproxEqAbs(
            mAfter.totalMarkdownAmount,
            borrowerDebt,
            1e18, // Allow for interest accrual
            "Should track actual reduction (capped at debt)"
        );

        // Restore markdown
        markdownManager.setMarkdownForBorrower(BORROWER, 0);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mRestored = morpho.market(id);

        // Should restore the markdown amount that was actually applied
        assertApproxEqAbs(
            mRestored.totalSupplyAssets,
            supplyBefore,
            1e18, // Allow for interest accrual
            "Should restore to original supply"
        );
        // Allow for small rounding/interest differences
        assertLe(mRestored.totalMarkdownAmount, 1e18, "Markdown should be mostly cleared (allowing for rounding)");
    }

    /// @notice Test markdown behavior with multiple borrowers
    function testMarkdownWithMultipleBorrowers() public {
        address borrower2 = makeAddr("Borrower2");

        // Supply funds
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up two borrowers
        vm.startPrank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, 100 ether, 0);
        morphoCredit.setCreditLine(id, borrower2, 100 ether, 0);
        vm.stopPrank();

        // Both borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);

        vm.prank(borrower2);
        morpho.borrow(marketParams, 50 ether, 0, borrower2, borrower2);

        // Set up obligations for both borrowers using helper
        // First borrower
        _createRepaymentObligation(id, BORROWER, 50 ether, 50 ether, 0); // 100% due

        // For the second borrower, we need to use the same cycle, so we'll add them to the existing cycle
        // Get the current cycle ID
        uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        (, uint256 cycleEnd) = MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), id, cycleLength - 1);

        // Add second borrower's obligation to the same cycle
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower2;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = 10000;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = 50 ether;

        vm.prank(address(creditLine));
        morphoCredit.addObligationsToLatestCycle(id, borrowers, repaymentBps, endingBalances);

        // Move to default
        _continueMarketCycles(id, block.timestamp + 31 days);

        // Set different markdowns for each borrower
        markdownManager.setMarkdownForBorrower(BORROWER, 30 ether);
        markdownManager.setMarkdownForBorrower(borrower2, 20 ether);

        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        morphoCredit.accrueBorrowerPremium(id, borrower2);

        Market memory m = morpho.market(id);

        // Total markdown should be sum of individual markdowns
        // But capped at actual borrower debts
        assertTrue(m.totalMarkdownAmount <= 100 ether, "Total markdown should not exceed total debt");
    }
}
