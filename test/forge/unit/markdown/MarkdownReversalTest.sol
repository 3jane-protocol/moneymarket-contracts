// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {Market, MarkdownState, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";

/// @title MarkdownReversalTest
/// @notice Tests for markdown reversal scenarios when borrowers cure their defaults
contract MarkdownReversalTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    function setUp() public override {
        super.setUp();

        // Deploy markdown manager
        markdownManager = new MarkdownManagerMock();

        // Deploy credit line
        creditLine = new CreditLineMock(morphoAddress);
        morphoCredit = IMorphoCredit(morphoAddress);

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

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 100_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test markdown reversal when borrower becomes current
    function testMarkdownReversalWhenBorrowerBecomesCurrent() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Record initial market state
        Market memory marketBefore = morpho.market(id);
        uint256 supplyBefore = marketBefore.totalSupplyAssets;

        // Create past obligation to trigger default
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Fast forward to default
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown applied
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        uint256 markdownApplied = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
            markdownApplied = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);
        }
        assertTrue(markdownApplied > 0, "Markdown should be applied");
        assertTrue(defaultTime > 0, "Default time should be set");

        // Verify markdown applied (supply may have increased due to interest, but markdown is tracked)
        Market memory marketDuringDefault = morpho.market(id);
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        assertEq(totalMarkdown, markdownApplied, "Total markdown should match borrower markdown");

        // Borrower makes payment to become current
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);
        loanToken.setBalance(BORROWER, amountDue);
        vm.prank(BORROWER);
        morpho.repay(marketParams, amountDue, 0, BORROWER, hex"");

        // Update markdown state
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown reversed
        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus statusAfter, uint256 defaultTimeAfter) =
            MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        uint256 markdownAfter = 0;
        if (statusAfter == RepaymentStatus.Default && defaultTimeAfter > 0) {
            uint256 timeInDefault = block.timestamp > defaultTimeAfter ? block.timestamp - defaultTimeAfter : 0;
            markdownAfter = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);
        }
        assertEq(markdownAfter, 0, "Markdown should be cleared");
        assertEq(defaultTimeAfter, 0, "Default time should be cleared");

        // Verify supply restored (should be original + interest accrued)
        Market memory marketAfterCure = morpho.market(id);
        assertGt(marketAfterCure.totalSupplyAssets, supplyBefore, "Supply should be greater due to interest");

        // Verify total markdown cleared
        uint256 totalMarkdownAfter = morpho.market(id).totalMarkdownAmount;
        assertEq(totalMarkdownAfter, 0, "Total markdown should be cleared");
    }

    /// @notice Test markdown continues to increase while in default
    function testMarkdownContinuesInDefault() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower in default
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Fast forward to default
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Record initial markdown
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        uint256 markdown1 = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
            markdown1 = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);
        }
        assertTrue(markdown1 > 0, "Should have initial markdown");

        // Fast forward more time
        _continueMarketCycles(id, block.timestamp + 10 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown increased
        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (status, defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        uint256 markdown2 = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
            markdown2 = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);
        }
        assertTrue(markdown2 > markdown1, "Markdown should increase over time");

        // Fast forward even more
        _continueMarketCycles(id, block.timestamp + 30 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown continues to increase
        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (status, defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        uint256 markdown3 = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
            markdown3 = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);
        }
        assertTrue(markdown3 > markdown2, "Markdown should continue increasing");

        // Verify market total tracks correctly
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        assertEq(totalMarkdown, markdown3, "Market total should match borrower markdown");
    }

    /// @notice Test multiple default/recovery cycles
    function testMultipleDefaultRecoveryCycles() public {
        uint256 borrowAmount = 10_000e18;
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        uint256 initialSupply = morpho.market(id).totalSupplyAssets;

        // Cycle 1: Default and recover
        _createPastObligation(BORROWER, 500, borrowAmount);
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 5 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown applied
        uint256 supplyDuringDefault1 = morpho.market(id).totalSupplyAssets;
        assertLt(supplyDuringDefault1, initialSupply, "Supply should decrease in default");

        // Recover by paying obligation
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);
        loanToken.setBalance(BORROWER, amountDue);
        vm.prank(BORROWER);
        morpho.repay(marketParams, amountDue, 0, BORROWER, hex"");
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify recovery (supply will be higher due to interest)
        uint256 supplyAfterRecovery1 = morpho.market(id).totalSupplyAssets;
        assertGt(supplyAfterRecovery1, initialSupply, "Supply should be higher due to interest");
        assertEq(morpho.market(id).totalMarkdownAmount, 0, "Markdown should be cleared");

        // Cycle 2: Default again
        _continueMarketCycles(id, block.timestamp + 30 days);
        uint256 currentBorrowAmount = _getBorrowerAssets(id, BORROWER);
        _createPastObligation(BORROWER, 500, currentBorrowAmount);
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 10 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown applied again
        uint256 markdownDuringDefault2 = morpho.market(id).totalMarkdownAmount;
        assertTrue(markdownDuringDefault2 > 0, "Should have markdown in default again");

        // Recover again
        (, amountDue,) = morphoCredit.repaymentObligation(id, BORROWER);
        loanToken.setBalance(BORROWER, amountDue);
        vm.prank(BORROWER);
        morpho.repay(marketParams, amountDue, 0, BORROWER, hex"");
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify final recovery
        assertEq(morpho.market(id).totalMarkdownAmount, 0, "Markdown should be cleared again");
    }

    /// @notice Test market-wide recovery with multiple borrowers
    function testMarketWideRecovery() public {
        uint256 borrowAmount = 10_000e18;
        address borrower2 = address(0x2222);
        address borrower3 = address(0x3333);

        // Setup multiple borrowers
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _setupBorrowerWithLoan(borrower2, borrowAmount);
        _setupBorrowerWithLoan(borrower3, borrowAmount);

        uint256 initialSupply = morpho.market(id).totalSupplyAssets;

        // Put all borrowers in default
        _createPastObligation(BORROWER, 500, borrowAmount);
        _createPastObligation(borrower2, 500, borrowAmount);
        _createPastObligation(borrower3, 500, borrowAmount);

        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 7 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);
        morphoCredit.accrueBorrowerPremium(id, borrower2);
        morphoCredit.accrueBorrowerPremium(id, borrower3);

        // Verify total markdown
        uint256 totalMarkdownDuringDefault = morpho.market(id).totalMarkdownAmount;
        assertTrue(totalMarkdownDuringDefault > 0, "Should have market-wide markdown");

        uint256 supplyDuringDefault = morpho.market(id).totalSupplyAssets;
        assertLt(supplyDuringDefault, initialSupply, "Supply should be reduced");

        // Borrowers recover one by one
        // Borrower 1 recovers
        (, uint128 amountDue1,) = morphoCredit.repaymentObligation(id, BORROWER);
        loanToken.setBalance(BORROWER, amountDue1);
        vm.prank(BORROWER);
        morpho.repay(marketParams, amountDue1, 0, BORROWER, hex"");
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        uint256 supplyAfter1Recovery = morpho.market(id).totalSupplyAssets;
        assertTrue(supplyAfter1Recovery > supplyDuringDefault, "Supply should increase after 1 recovery");
        assertTrue(supplyAfter1Recovery < initialSupply, "Supply not fully restored yet");

        // Borrower 2 recovers
        (, uint128 amountDue2,) = morphoCredit.repaymentObligation(id, borrower2);
        loanToken.setBalance(borrower2, amountDue2);
        vm.startPrank(borrower2);
        loanToken.approve(address(morpho), amountDue2);
        morpho.repay(marketParams, amountDue2, 0, borrower2, hex"");
        vm.stopPrank();
        morphoCredit.accrueBorrowerPremium(id, borrower2);

        uint256 supplyAfter2Recovery = morpho.market(id).totalSupplyAssets;
        assertTrue(supplyAfter2Recovery > supplyAfter1Recovery, "Supply should increase more");

        // Borrower 3 recovers
        (, uint128 amountDue3,) = morphoCredit.repaymentObligation(id, borrower3);
        loanToken.setBalance(borrower3, amountDue3);
        vm.startPrank(borrower3);
        loanToken.approve(address(morpho), amountDue3);
        morpho.repay(marketParams, amountDue3, 0, borrower3, hex"");
        vm.stopPrank();
        morphoCredit.accrueBorrowerPremium(id, borrower3);

        // Verify full recovery (supply will be higher due to interest)
        uint256 finalSupply = morpho.market(id).totalSupplyAssets;
        assertGt(finalSupply, initialSupply, "Supply should be higher due to interest");

        uint256 finalTotalMarkdown = morpho.market(id).totalMarkdownAmount;
        assertEq(finalTotalMarkdown, 0, "Total markdown should be cleared");
    }

    /// @notice Test that new depositors don't lose value with direct asset reduction
    function testNewDepositorsProtected() public {
        uint256 borrowAmount = 20_000e18;

        // Setup borrower in default
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Fast forward to default with significant markdown
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 15 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // New supplier deposits
        address newSupplier = address(0x9999);
        uint256 depositAmount = 10_000e18;
        loanToken.setBalance(newSupplier, depositAmount);

        vm.startPrank(newSupplier);
        loanToken.approve(address(morpho), depositAmount);
        (uint256 depositedAssets, uint256 depositedShares) =
            morpho.supply(marketParams, depositAmount, 0, newSupplier, hex"");
        vm.stopPrank();

        // Immediately withdraw to check value
        vm.prank(newSupplier);
        (uint256 withdrawnAssets, uint256 withdrawnShares) =
            morpho.withdraw(marketParams, 0, depositedShares, newSupplier, newSupplier);

        // Verify no immediate loss (allow for small rounding)
        assertApproxEqAbs(withdrawnAssets, depositAmount, 1, "New depositor should not lose value");
    }

    // Helper functions
    function _getBorrowerAssets(Id _id, address borrower) internal view returns (uint256) {
        Market memory m = morpho.market(_id);
        return uint256(morpho.position(_id, borrower).borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }
}
