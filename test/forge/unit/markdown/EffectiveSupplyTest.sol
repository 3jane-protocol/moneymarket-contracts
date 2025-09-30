// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {Market, Position, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";

/// @title EffectiveSupplyTest
/// @notice Tests for effective supply calculations accounting for markdowns
contract EffectiveSupplyTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;
    using MathLib for uint256;

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
        vm.warp(block.timestamp + CYCLE_DURATION);
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, block.timestamp, borrowers, repaymentBps, endingBalances
        );
    }

    /// @notice Test withdraw uses effective supply for share/asset conversion
    function testWithdrawWithMarkdowns() public {
        uint256 supplyAmount = 100_000e18;
        uint256 borrowAmount = 50_000e18;
        uint256 withdrawAmount = 10_000e18;

        // Setup: Initial supply
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.prank(SUPPLIER);
        (uint256 suppliedAssets, uint256 supplyShares) = morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        // Setup: Borrower takes loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Create default scenario
        _createPastObligation(BORROWER, 500, borrowAmount);
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get markdown info
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        Market memory market = morpho.market(id);
        assertTrue(totalMarkdown > 0, "Should have markdown");

        // With direct asset reduction, totalSupplyAssets reflects net of markdown and interest
        // It may be higher or lower than initial supply depending on interest vs markdown

        // Calculate expected shares based on current totalSupplyAssets
        uint256 expectedShares = withdrawAmount.toSharesUp(market.totalSupplyAssets, market.totalSupplyShares);

        // Withdraw using asset amount
        vm.prank(SUPPLIER);
        (uint256 withdrawnAssets, uint256 withdrawnShares) =
            morpho.withdraw(marketParams, withdrawAmount, 0, SUPPLIER, SUPPLIER);

        // Verify conversion used totalSupplyAssets
        assertEq(withdrawnAssets, withdrawAmount, "Should withdraw requested amount");
        assertEq(withdrawnShares, expectedShares, "Shares should match calculation");
    }

    /// @notice Test withdraw by shares with markdowns
    function testWithdrawSharesWithMarkdowns() public {
        uint256 supplyAmount = 100_000e18;
        uint256 borrowAmount = 50_000e18;
        uint256 withdrawShares = 1_000e18;

        // Setup: Initial supply
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        // Setup: Borrower defaults
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get market state
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        Market memory market = morpho.market(id);
        assertTrue(totalMarkdown > 0, "Should have markdown");

        // Calculate expected assets based on current totalSupplyAssets
        uint256 expectedAssets = withdrawShares.toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);

        // Withdraw using shares
        vm.prank(SUPPLIER);
        (uint256 withdrawnAssets, uint256 withdrawnShares) =
            morpho.withdraw(marketParams, 0, withdrawShares, SUPPLIER, SUPPLIER);

        // Verify conversion
        assertEq(withdrawnShares, withdrawShares, "Should withdraw requested shares");
        assertEq(withdrawnAssets, expectedAssets, "Assets should match calculation");
    }

    /// @notice Test multiple defaulted borrowers impact on effective supply
    function testMultipleBorrowersMarkdownImpact() public {
        uint256 supplyAmount = 200_000e18;

        // Setup: Initial supply
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        // Setup: Multiple borrowers
        address[] memory borrowers = new address[](3);
        uint256[] memory borrowAmounts = new uint256[](3);
        borrowers[0] = BORROWER;
        borrowAmounts[0] = 30_000e18;
        borrowers[1] = ONBEHALF;
        borrowAmounts[1] = 40_000e18;
        borrowers[2] = RECEIVER;
        borrowAmounts[2] = 20_000e18;

        // All borrowers take loans and default
        for (uint256 i = 0; i < borrowers.length; i++) {
            _setupBorrowerWithLoan(borrowers[i], borrowAmounts[i]);
            _createPastObligation(borrowers[i], 500, borrowAmounts[i]);
        }

        // Fast forward to default and update all
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        for (uint256 i = 0; i < borrowers.length; i++) {
            morphoCredit.accrueBorrowerPremium(id, borrowers[i]);
        }

        // Get markdown info
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        uint256 effectiveSupplyAssets = morpho.market(id).totalSupplyAssets;
        Market memory market = morpho.market(id);

        // Calculate individual markdowns
        uint256 calculatedTotalMarkdown = 0;
        for (uint256 i = 0; i < borrowers.length; i++) {
            uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, borrowers[i]);
            (RepaymentStatus status, uint256 defaultTime) =
                MorphoCreditLib.getRepaymentStatus(morphoCredit, id, borrowers[i]);
            uint256 markdown = 0;
            if (status == RepaymentStatus.Default && defaultTime > 0) {
                uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
                markdown = markdownManager.calculateMarkdown(borrowers[i], borrowAssets, timeInDefault);
            }
            calculatedTotalMarkdown += markdown;
        }

        // Verify totals
        assertEq(totalMarkdown, calculatedTotalMarkdown, "Market total should equal sum of individual markdowns");

        // With direct asset reduction, totalSupplyAssets already reflects markdowns
        // Verify markdown is tracked
        assertTrue(totalMarkdown > 0, "Should have significant markdown from multiple defaults");

        // Test withdrawal with multiple markdowns
        uint256 withdrawAmount = 10_000e18;
        vm.prank(SUPPLIER);
        (uint256 withdrawnAssets, uint256 withdrawnShares) =
            morpho.withdraw(marketParams, withdrawAmount, 0, SUPPLIER, SUPPLIER);

        // Verify withdrawal worked
        assertEq(withdrawnAssets, withdrawAmount, "Should withdraw requested amount");
        assertTrue(withdrawnShares > 0, "Should burn shares");
    }

    /// @notice Test edge case where markdown exceeds supply
    function testMarkdownExceedsSupply() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 9_500e18; // 95% utilization

        // Setup: Small supply
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        // Setup: Large borrow
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Fast forward to extreme markdown (70% after 70+ days)
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 70 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get markdown info
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        Market memory market = morpho.market(id);

        // With 70% markdown on 95% utilization, markdown could be very large
        assertTrue(totalMarkdown > 0, "Should have significant markdown");

        // With direct asset reduction, totalSupplyAssets is already reduced by markdown
        // but increased by interest, so it won't go to zero
        assertTrue(market.totalSupplyAssets > 0, "Supply should still be positive due to interest");

        // With extreme markdown, totalBorrowAssets may exceed totalSupplyAssets
        // This creates insufficient liquidity for withdrawals
        if (market.totalBorrowAssets > market.totalSupplyAssets) {
            // Try to withdraw - should revert
            vm.prank(SUPPLIER);
            vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
            morpho.withdraw(marketParams, 100e18, 0, SUPPLIER, SUPPLIER);
        } else {
            // Normal withdrawal should work
            vm.prank(SUPPLIER);
            (uint256 withdrawnAssets, uint256 withdrawnShares) =
                morpho.withdraw(marketParams, 100e18, 0, SUPPLIER, SUPPLIER);
            assertEq(withdrawnAssets, 100e18, "Should withdraw requested amount");
            assertTrue(withdrawnShares > 0, "Should burn shares");
        }
    }

    /// @notice Test new supply diluted by existing markdowns
    function testNewSupplyDilution() public {
        uint256 initialSupply = 100_000e18;
        uint256 borrowAmount = 50_000e18;
        uint256 newSupply = 50_000e18;

        // Setup: Initial supply and borrow
        loanToken.setBalance(SUPPLIER, initialSupply);
        vm.prank(SUPPLIER);
        (uint256 initialAssets, uint256 initialShares) = morpho.supply(marketParams, initialSupply, 0, SUPPLIER, hex"");

        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Create markdown
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 10 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get markdown state
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        uint256 effectiveSupplyBefore = morpho.market(id).totalSupplyAssets;
        Market memory marketBefore = morpho.market(id);

        // New supplier enters
        loanToken.setBalance(ONBEHALF, newSupply);
        vm.prank(ONBEHALF);
        (uint256 newAssets, uint256 newShares) = morpho.supply(marketParams, newSupply, 0, ONBEHALF, hex"");

        // Calculate share price for new supplier
        uint256 newSharePrice = newAssets.wDivDown(newShares);
        uint256 initialSharePrice = initialAssets.wDivDown(initialShares);

        // New supplier should get better share price due to markdown
        assertLt(newSharePrice, initialSharePrice, "New supplier should get more shares per asset");

        // Verify market state after new supply
        Market memory marketAfter = morpho.market(id);
        assertEq(marketAfter.totalSupplyAssets, marketBefore.totalSupplyAssets + newSupply, "Supply should increase");
        assertEq(marketAfter.totalMarkdownAmount, totalMarkdown, "Markdown should not change");

        // Test withdrawal parity - both suppliers should get same rate
        uint256 withdrawAmount = 1_000e18;

        vm.prank(SUPPLIER);
        (uint256 oldSupplierAssets, uint256 oldSupplierShares) =
            morpho.withdraw(marketParams, withdrawAmount, 0, SUPPLIER, SUPPLIER);

        vm.prank(ONBEHALF);
        (uint256 newSupplierAssets, uint256 newSupplierShares) =
            morpho.withdraw(marketParams, withdrawAmount, 0, ONBEHALF, ONBEHALF);

        // Both should burn same shares for same assets (within rounding)
        assertApproxEqAbs(oldSupplierShares, newSupplierShares, 2, "Both suppliers should burn similar shares");
    }

    /// @notice Test APY calculations reflect markdowns
    function testAPYWithMarkdowns() public {
        uint256 supplyAmount = 100_000e18;
        uint256 borrowAmount = 80_000e18; // 80% utilization

        // Setup market
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        Position memory supplierPosBefore = morpho.position(id, SUPPLIER);

        // Create healthy borrow
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Let interest accrue normally for a period
        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(marketParams);

        // Check normal APY
        Position memory supplierPosMid = morpho.position(id, SUPPLIER);
        uint256 normalInterest = supplierPosMid.supplyShares - supplierPosBefore.supplyShares;

        // Now create default and markdown
        _createPastObligation(BORROWER, 500, borrowAmount);
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Forward another period with markdown
        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(marketParams);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get effective value change
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        uint256 effectiveSupply = morpho.market(id).totalSupplyAssets;
        Market memory market = morpho.market(id);

        // Calculate effective APY considering markdown
        uint256 effectiveValue = supplierPosMid.supplyShares.toAssetsDown(effectiveSupply, market.totalSupplyShares);
        uint256 initialValue = supplyAmount;

        // Effective return should be lower due to markdown
        assertLt(effectiveValue, initialValue + normalInterest * 2, "Effective returns reduced by markdown");
    }

    /// @notice Test zero markdown scenario
    function testZeroMarkdown() public {
        uint256 supplyAmount = 100_000e18;
        uint256 borrowAmount = 50_000e18;

        // Setup
        loanToken.setBalance(SUPPLIER, supplyAmount);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // No default, just healthy borrowing
        Market memory market = morpho.market(id);
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;
        uint256 effectiveSupply = morpho.market(id).totalSupplyAssets;

        // Verify no markdown
        assertEq(totalMarkdown, 0, "Should have no markdown");
        assertEq(effectiveSupply, market.totalSupplyAssets, "Effective supply should equal total supply");

        // Withdraw should work normally
        uint256 withdrawAmount = 10_000e18;
        uint256 expectedShares = withdrawAmount.toSharesUp(market.totalSupplyAssets, market.totalSupplyShares);

        vm.prank(SUPPLIER);
        (uint256 withdrawnAssets, uint256 withdrawnShares) =
            morpho.withdraw(marketParams, withdrawAmount, 0, SUPPLIER, SUPPLIER);

        assertEq(withdrawnAssets, withdrawAmount, "Should withdraw exact amount");
        assertEq(withdrawnShares, expectedShares, "Shares should match normal calculation");
    }
}
