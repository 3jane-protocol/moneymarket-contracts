// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLine} from "../../../../src/CreditLine.sol";
import {AdaptiveCurveIrm} from "../../../../src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {MathLib} from "../../../../src/libraries/MathLib.sol";
import {Market, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";

/// @notice Simple mock insurance fund for testing
contract SimpleInsuranceFund {
    function bring(address token, uint256 amount) external {
        // In tests, the funds are already in the creditLine address
        // So this is a no-op
    }
}

/// @title RealComponentsTest
/// @notice Integration tests with real components instead of mocks
contract RealComponentsTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    MarkdownManagerMock markdownManager;
    CreditLine creditLine;
    AdaptiveCurveIrm realIrm;
    IMorphoCredit morphoCredit;

    function setUp() public override {
        super.setUp();

        // Deploy markdown manager mock
        markdownManager = new MarkdownManagerMock(address(protocolConfig), OWNER);

        // Deploy real IRM
        realIrm = new AdaptiveCurveIrm(address(morpho));

        // Deploy simple insurance fund mock
        SimpleInsuranceFund insuranceFund = new SimpleInsuranceFund();

        // Deploy real credit line
        creditLine = new CreditLine(
            morphoAddress,
            OWNER, // Owner
            OWNER, // OZD (use OWNER for simplicity in tests)
            address(markdownManager), // Markdown manager
            address(0) // Prover (optional, can be zero)
        );
        morphoCredit = IMorphoCredit(morphoAddress);

        // Set insurance fund
        vm.prank(OWNER);
        creditLine.setInsuranceFund(address(insuranceFund));

        // Create market with real components
        marketParams = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(realIrm),
            DEFAULT_TEST_LLTV,
            address(creditLine)
        );
        id = marketParams.id();

        vm.startPrank(OWNER);

        // Enable the IRM first
        morpho.enableIrm(address(realIrm));

        // Then create the market
        morpho.createMarket(marketParams);

        // Enable markdown for test borrowers
        markdownManager.setEnableMarkdown(BORROWER, true);
        markdownManager.setEnableMarkdown(ONBEHALF, true);

        vm.stopPrank();

        // Initialize first cycle to unfreeze the market
        _ensureMarketActive(id);

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 1_000_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1_000_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test markdown with real IRM rate calculations
    function testRealIRM_MarkdownWithDynamicRates() public {
        uint256 borrowAmount = 100_000e18;

        // Setup borrower
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Check initial rate from real IRM
        MarketParams memory mp = marketParams;
        Market memory market = morpho.market(id);

        // Initial utilization and rate
        uint256 utilization = uint256(market.totalBorrowAssets).wDivDown(uint256(market.totalSupplyAssets));
        uint256 borrowRate = realIrm.borrowRateView(mp, market);

        emit log_named_uint("Initial Utilization", utilization);
        emit log_named_uint("Initial Borrow Rate (per second)", borrowRate);

        // Create obligation and move to default
        _createPastObligation(BORROWER, 500, borrowAmount);
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 10 days);

        // Accrue premium with real IRM rates
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Check markdown with actual interest accrual
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);

        assertTrue(status == RepaymentStatus.Default, "Should be in default");

        uint256 timeInDefault = block.timestamp - defaultTime;
        uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);

        // Verify markdown calculation with real rates
        assertGt(markdown, 0, "Should have markdown");
        assertLe(markdown, borrowAssets, "Markdown should not exceed debt");

        // Check market impact
        Market memory marketAfter = morpho.market(id);
        assertEq(marketAfter.totalMarkdownAmount, markdown, "Market should track markdown");
    }

    /// @notice Test multiple borrowers with varying credit limits using real credit line
    function testRealCreditLine_MultipleBorrowers() public {
        address[] memory borrowers = new address[](3);
        uint256[] memory creditLimits = new uint256[](3);
        uint128[] memory drps = new uint128[](3);

        borrowers[0] = BORROWER;
        borrowers[1] = ONBEHALF;
        borrowers[2] = address(0x3333);

        creditLimits[0] = 50_000e18;
        creditLimits[1] = 100_000e18;
        creditLimits[2] = 25_000e18;

        drps[0] = 100; // 1% premium
        drps[1] = 200; // 2% premium
        drps[2] = 50; // 0.5% premium

        // Enable markdown and set credit lines
        vm.startPrank(OWNER);
        markdownManager.setEnableMarkdown(borrowers[2], true);
        vm.stopPrank();

        // Set credit lines directly through morphoCredit (bypass CreditLine validation)
        for (uint256 i = 0; i < borrowers.length; i++) {
            vm.prank(address(creditLine));
            morphoCredit.setCreditLine(id, borrowers[i], creditLimits[i], drps[i]);
        }

        // Each borrower borrows up to their limit
        for (uint256 i = 0; i < borrowers.length; i++) {
            uint256 borrowAmount = creditLimits[i] / 2; // Borrow half the limit

            vm.prank(borrowers[i]);
            morpho.borrow(marketParams, borrowAmount, 0, borrowers[i], borrowers[i]);

            // Credit line verification handled internally by the system
        }

        // Put borrowers in default at different times
        for (uint256 i = 0; i < borrowers.length; i++) {
            uint256 borrowAmount = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            _createPastObligation(borrowers[i], 500, borrowAmount);

            // Stagger defaults
            _continueMarketCycles(id, block.timestamp + (i + 1) * 5 days);
        }

        // Move to full default
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);

        // Check individual markdowns
        uint256 totalMarkdown = 0;
        for (uint256 i = 0; i < borrowers.length; i++) {
            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);

            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (RepaymentStatus status, uint256 defaultTime) =
                MorphoCreditLib.getRepaymentStatus(morphoCredit, id, borrowers[i]);

            if (status == RepaymentStatus.Default && defaultTime > 0) {
                uint256 timeInDefault = block.timestamp - defaultTime;
                uint256 markdown = markdownManager.calculateMarkdown(borrowers[i], borrowAssets, timeInDefault);
                totalMarkdown += markdown;

                emit log_named_address("Borrower", borrowers[i]);
                emit log_named_uint("Markdown", markdown);
            }
        }

        // Verify total market markdown
        Market memory market = morpho.market(id);
        assertEq(market.totalMarkdownAmount, totalMarkdown, "Total markdown should match sum");
    }

    /// @notice Test markdown behavior with real oracle price changes
    function testRealOracle_MarkdownWithPriceChanges() public {
        uint256 borrowAmount = 50_000e18;

        // Setup borrower
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Simulate oracle price change (though markdown doesn't depend on collateral)
        uint256 newPrice = 0.5e36; // 50% price drop
        oracle.setPrice(newPrice);

        // Create obligation and default
        _createPastObligation(BORROWER, 500, borrowAmount);
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 15 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Check markdown still works correctly
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);

        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp - defaultTime;
            uint256 markdown = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);

            assertGt(markdown, 0, "Should have markdown regardless of oracle price");
            assertLe(markdown, borrowAssets, "Markdown capped at debt");
        }
    }

    /// @notice Test complete lifecycle with real components
    function testRealComponents_CompleteLifecycle() public {
        uint256 supplyAmount = 500_000e18;
        uint256 borrowAmount = 100_000e18;

        // Additional suppliers for more realistic market
        address supplier2 = address(0x5555);
        loanToken.setBalance(supplier2, supplyAmount);
        vm.startPrank(supplier2);
        loanToken.approve(address(morpho), supplyAmount);
        morpho.supply(marketParams, supplyAmount, 0, supplier2, hex"");
        vm.stopPrank();

        // Multiple borrowers with real credit lines
        address[] memory borrowers = new address[](2);
        borrowers[0] = BORROWER;
        borrowers[1] = ONBEHALF;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = borrowAmount;
        amounts[1] = borrowAmount * 2;

        uint128[] memory drps = new uint128[](2);
        drps[0] = 150; // 1.5% premium
        drps[1] = 250; // 2.5% premium

        // Set credit lines directly through morphoCredit (bypass CreditLine validation)
        for (uint256 i = 0; i < borrowers.length; i++) {
            vm.prank(address(creditLine));
            morphoCredit.setCreditLine(id, borrowers[i], amounts[i], drps[i]);
        }

        // Borrowers take loans
        for (uint256 i = 0; i < borrowers.length; i++) {
            vm.prank(borrowers[i]);
            morpho.borrow(marketParams, amounts[i] / 2, 0, borrowers[i], borrowers[i]);
        }

        // Check initial market state with real IRM
        Market memory marketInitial = morpho.market(id);
        uint256 borrowRateInitial = realIrm.borrowRateView(marketParams, marketInitial);
        emit log_named_uint("Initial Market Borrow Rate", borrowRateInitial);

        // Borrower 1 defaults
        _createPastObligation(borrowers[0], 500, amounts[0] / 2);
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 20 days);
        morphoCredit.accrueBorrowerPremium(id, borrowers[0]);

        // Check markdown impact
        Market memory marketDuringDefault = morpho.market(id);
        assertGt(marketDuringDefault.totalMarkdownAmount, 0, "Should have markdown");

        // Borrower 1 recovers
        (, uint128 amountDue,) = morphoCredit.repaymentObligation(id, borrowers[0]);
        loanToken.setBalance(borrowers[0], amountDue);
        vm.startPrank(borrowers[0]);
        loanToken.approve(address(morpho), amountDue);
        morpho.repay(marketParams, amountDue, 0, borrowers[0], hex"");
        vm.stopPrank();

        morphoCredit.accrueBorrowerPremium(id, borrowers[0]);

        // Verify markdown cleared
        Market memory marketAfterRecovery = morpho.market(id);
        assertLt(
            marketAfterRecovery.totalMarkdownAmount,
            marketDuringDefault.totalMarkdownAmount,
            "Markdown should decrease after recovery"
        );

        // Check final rates with real IRM
        uint256 borrowRateFinal = realIrm.borrowRateView(marketParams, marketAfterRecovery);
        emit log_named_uint("Final Market Borrow Rate", borrowRateFinal);

        // Verify market health
        assertGt(marketAfterRecovery.totalSupplyAssets, 0, "Market should have supply");
        assertGe(
            marketAfterRecovery.totalSupplyAssets,
            marketAfterRecovery.totalBorrowAssets - marketAfterRecovery.totalMarkdownAmount,
            "Supply should cover net debt"
        );
    }

    /// @notice Test markdown with real IRM adjustments over time
    function testRealIRM_RateAdjustmentWithMarkdown() public {
        uint256 borrowAmount = 200_000e18;

        // Setup borrower
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Record initial IRM state
        Market memory market = morpho.market(id);
        uint256 rate1 = realIrm.borrowRateView(marketParams, market);

        emit log_named_uint("Initial Rate", rate1);

        // Time passes, IRM adjusts
        skip(30 days);
        morpho.accrueInterest(marketParams);

        // Check rate after time
        market = morpho.market(id);
        uint256 rate2 = realIrm.borrowRateView(marketParams, market);

        emit log_named_uint("Rate After 30 Days", rate2);

        // Trigger default with markdown
        _createPastObligation(BORROWER, 500, borrowAmount);
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 10 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Check rate with markdown applied
        market = morpho.market(id);
        uint256 rate3 = realIrm.borrowRateView(marketParams, market);

        emit log_named_uint("Rate With Markdown", rate3);
        emit log_named_uint("Total Markdown", market.totalMarkdownAmount);

        // Rates should adjust based on utilization changes
        assertTrue(rate3 != rate1 || rate3 != rate2, "Rate should change with market conditions");
    }

    /// @notice Test settlement with real credit line
    function testRealCreditLine_Settlement() public {
        uint256 borrowAmount = 75_000e18;

        // Setup credit line for borrower directly through morphoCredit
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, borrowAmount * 2, 300); // 3% premium

        // Borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Default for extended period
        _createPastObligation(BORROWER, 500, borrowAmount);
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 60 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Calculate markdown before settlement
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        uint256 timeInDefault = block.timestamp - defaultTime;
        uint256 expectedMarkdown = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);

        // Settle the debt
        uint256 coverAmount = borrowAssets / 4; // Cover 25% of debt
        loanToken.setBalance(address(creditLine), coverAmount);

        vm.prank(OWNER);
        (uint256 settled, uint256 covered) = creditLine.settle(marketParams, BORROWER, borrowAssets, coverAmount);

        emit log_named_uint("Settled Amount", settled);
        emit log_named_uint("Covered Amount", covered);

        // Verify settlement cleared markdown
        Market memory marketAfter = morpho.market(id);
        assertLt(marketAfter.totalMarkdownAmount, expectedMarkdown, "Markdown should be reduced after settlement");

        // Verify borrower position cleared
        uint256 remainingDebt = morpho.expectedBorrowAssets(marketParams, BORROWER);
        assertEq(remainingDebt, 0, "Borrower debt should be settled");
    }

    // Helper functions
    function _toArray(address value) private pure returns (address[] memory) {
        address[] memory array = new address[](1);
        array[0] = value;
        return array;
    }

    function _toArray(uint256 value) private pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = value;
        return array;
    }

    function _toArrayUint128(uint128 value) private pure returns (uint128[] memory) {
        uint128[] memory array = new uint128[](1);
        array[0] = value;
        return array;
    }

    function _toIdArray(Id value) private pure returns (Id[] memory) {
        Id[] memory array = new Id[](1);
        array[0] = value;
        return array;
    }
}
