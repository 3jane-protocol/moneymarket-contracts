// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {HelperMock} from "../../../../src/mocks/HelperMock.sol";
import {Market, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";

/// @title PhantomLiquidityFuzzTest
/// @notice Fuzz tests to verify markdown logic cannot create phantom liquidity
/// @dev Tests markdown behavior with random values, timings, and sequences to prevent exploitation
contract PhantomLiquidityFuzzTest is BaseTest {
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
        _ensureMarketActive(id);
    }

    /// @notice Fuzz test: Markdown amounts should never create phantom liquidity
    /// @param markdownAmount Random markdown amount to test
    /// @param supplyAmount Initial supply to the market
    /// @param borrowAmount Amount to borrow
    function testFuzz_MarkdownCannotCreatePhantomLiquidity(
        uint256 markdownAmount,
        uint256 supplyAmount,
        uint256 borrowAmount
    ) public {
        // Bound inputs to reasonable ranges
        supplyAmount = bound(supplyAmount, 1 ether, 10000 ether);
        borrowAmount = bound(borrowAmount, 0.1 ether, supplyAmount / 2);
        markdownAmount = bound(markdownAmount, 0, type(uint128).max);

        // Supply funds
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, borrowAmount * 2, 0);

        // Borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Trigger default using the base test helper
        _createPastObligation(BORROWER, 10000, borrowAmount); // 100% repayment

        // Record state BEFORE any markdown is applied
        // This is important because the first accrueBorrowerPremium will apply initial markdown
        Market memory mInitial = morpho.market(id);
        uint256 supplyBeforeAnyMarkdown = mInitial.totalSupplyAssets;

        // Warp to default status (30+ days past due)
        vm.warp(block.timestamp + 31 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Record state after first markdown but before applying test markdown
        Market memory mBefore = morpho.market(id);

        // Apply markdown
        markdownManager.setMarkdownForBorrower(BORROWER, markdownAmount);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mAfter = morpho.market(id);

        // Fixed: Account for interest accrual when calculating expected supply
        // The markdown is applied after interest has accrued, not before
        // This fix addresses a pre-existing test logic bug that was exposed by timing changes

        // Calculate the interest that accrued during the test
        // Critical: Interest increases both supply and borrow assets, and must be accounted for
        // when verifying that markdown doesn't create phantom liquidity
        uint256 interestAccrued = mAfter.totalBorrowAssets > mInitial.totalBorrowAssets
            ? mAfter.totalBorrowAssets - mInitial.totalBorrowAssets
            : 0;

        // The correct supply change equation accounts for both interest and markdown:
        // finalSupply = initialSupply + interestAccrued - markdownApplied
        // This ensures we're testing that markdown reduces supply, not that it creates phantom liquidity
        uint256 expectedFinalSupply = supplyBeforeAnyMarkdown + interestAccrued - mAfter.totalMarkdownAmount;

        assertApproxEqAbs(
            mAfter.totalSupplyAssets,
            expectedFinalSupply,
            1000, // Allow for rounding differences in interest calculations
            "Final supply should equal initial + interest - markdown"
        );

        // Reverse markdown
        markdownManager.setMarkdownForBorrower(BORROWER, 0);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mFinal = morpho.market(id);

        // Supply should not exceed original + reasonable interest (10% APR max)
        uint256 maxReasonableSupply = supplyAmount + (supplyAmount * 10) / 100;
        assertLe(mFinal.totalSupplyAssets, maxReasonableSupply, "Final supply should not have phantom increase");
    }

    /// @notice Fuzz test: Multiple markdown updates in sequence
    /// @param markdowns Array of markdown values to apply sequentially
    function testFuzz_SequentialMarkdownUpdates(uint256[5] memory markdowns) public {
        // Setup market with supply
        uint256 supplyAmount = 1000 ether;
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");
        vm.stopPrank();

        // Setup borrower
        uint256 borrowAmount = 100 ether;
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, borrowAmount * 2, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        _triggerDefault(BORROWER, borrowAmount);

        // Apply sequential markdowns
        for (uint256 i = 0; i < markdowns.length; i++) {
            // Bound markdown to reasonable range
            markdowns[i] = bound(markdowns[i], 0, borrowAmount * 2);

            Market memory mBeforeUpdate = morpho.market(id);
            uint256 supplyBefore = mBeforeUpdate.totalSupplyAssets;

            markdownManager.setMarkdownForBorrower(BORROWER, markdowns[i]);
            morphoCredit.accrueBorrowerPremium(id, BORROWER);

            // Verify markdown behavior after each update
            Market memory m = morpho.market(id);

            // Check that markdown amount is tracked correctly
            uint256 borrowShares = morpho.position(id, BORROWER).borrowShares;
            uint256 actualDebt = borrowShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
            assertLe(m.totalMarkdownAmount, actualDebt, "Markdown should not exceed borrower's debt");

            // Progress time slightly
            _continueMarketCycles(id, block.timestamp + 1 hours);
        }
    }

    /// @notice Fuzz test: Markdown with varying time delays
    /// @param timeDelay Time to wait before applying markdown
    /// @param markdownPercent Percentage of debt to markdown (in basis points)
    function testFuzz_MarkdownWithTimeDelays(uint256 timeDelay, uint256 markdownPercent) public {
        // Bound inputs - ensure we have enough time for at least one cycle
        timeDelay = bound(timeDelay, CYCLE_DURATION + 1 days, 365 days);
        markdownPercent = bound(markdownPercent, 0, 10000); // 0-100%

        // Setup market
        uint256 supplyAmount = 1000 ether;
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");
        vm.stopPrank();

        // Setup borrower
        uint256 borrowAmount = 100 ether;
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, borrowAmount * 2, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        _triggerDefault(BORROWER, borrowAmount);

        // Wait specified time while maintaining cycles
        _continueMarketCycles(id, block.timestamp + timeDelay);

        // Calculate and apply markdown
        uint256 markdownAmount = (borrowAmount * markdownPercent) / 10000;
        markdownManager.setMarkdownForBorrower(BORROWER, markdownAmount);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown is properly bounded
        Market memory m = morpho.market(id);
        uint256 borrowShares = morpho.position(id, BORROWER).borrowShares;
        uint256 actualDebt = borrowShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

        // Markdown should not exceed actual debt
        assertLe(m.totalMarkdownAmount, actualDebt, "Markdown should be capped at debt");
    }

    /// @notice Fuzz test: Multiple borrowers with random markdowns
    /// @param numBorrowers Number of borrowers to test
    /// @param seed Random seed for generating amounts
    function testFuzz_MultipleBorrowersRandomMarkdowns(uint8 numBorrowers, uint256 seed) public {
        // Bound number of borrowers
        numBorrowers = uint8(bound(numBorrowers, 1, 10));

        // Supply funds
        uint256 supplyAmount = 10000 ether;
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");
        vm.stopPrank();

        address[] memory borrowers = new address[](numBorrowers);
        uint256[] memory borrowAmounts = new uint256[](numBorrowers);
        uint256 totalBorrowed = 0;

        // Create borrowers and have them borrow
        for (uint256 i = 0; i < numBorrowers; i++) {
            borrowers[i] = makeAddr(string(abi.encodePacked("Borrower", i)));

            // Generate pseudo-random borrow amount
            uint256 borrowAmount = bound(uint256(keccak256(abi.encode(seed, i))), 1 ether, 100 ether);
            borrowAmounts[i] = borrowAmount;
            totalBorrowed += borrowAmount;

            // Ensure we don't exceed supply
            if (totalBorrowed > supplyAmount / 2) break;

            vm.prank(address(creditLine));
            morphoCredit.setCreditLine(id, borrowers[i], borrowAmount * 2, 0);

            vm.prank(borrowers[i]);
            morpho.borrow(marketParams, borrowAmount, 0, borrowers[i], borrowers[i]);
        }

        // Trigger defaults and apply random markdowns
        uint256 totalMarkdownApplied = 0;
        for (uint256 i = 0; i < numBorrowers; i++) {
            if (borrowAmounts[i] == 0) continue;

            _triggerDefault(borrowers[i], borrowAmounts[i]);

            // Generate pseudo-random markdown
            uint256 markdownAmount = bound(uint256(keccak256(abi.encode(seed, i, "markdown"))), 0, borrowAmounts[i] * 2);

            markdownManager.setMarkdownForBorrower(borrowers[i], markdownAmount);
            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);

            // Track actual markdown applied (capped at debt)
            totalMarkdownApplied += markdownAmount > borrowAmounts[i] ? borrowAmounts[i] : markdownAmount;
        }

        // Verify total markdown doesn't exceed total debt
        Market memory m = morpho.market(id);
        assertLe(m.totalMarkdownAmount, m.totalBorrowAssets, "Total markdown should not exceed total debt");
    }

    // Helper function to trigger default state
    function _triggerDefault(address borrower, uint256 amount) internal {
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = 10000;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = amount;

        // Ensure proper cycle spacing before creating obligation
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
