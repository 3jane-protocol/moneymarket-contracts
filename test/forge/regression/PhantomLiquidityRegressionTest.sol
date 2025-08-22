// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {MarkdownManagerMock} from "../mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {HelperMock} from "../../../src/mocks/HelperMock.sol";
import {Market, RepaymentStatus} from "../../../src/interfaces/IMorpho.sol";

/// @title PhantomLiquidityRegressionTest
/// @notice Regression tests to ensure phantom liquidity exploit remains fixed
/// @dev Reproduces the exact steps from the original POC to verify the vulnerability is mitigated
contract PhantomLiquidityRegressionTest is BaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    MarkdownManagerMock maliciousMarkdownManager;
    CreditLineMock maliciousCreditLine;
    HelperMock helper;
    IMorphoCredit morphoCredit;

    // Track the exact values from the original POC
    uint256 constant INITIAL_BALANCE = 10 ** 10 * 10 ** 18; // 10^28
    uint256 constant VIRTUAL_SHARES = 10 ** 6 - 1;
    uint256 constant MARKDOWN_AMOUNT = 10 ** 10 * 10 ** 18; // 10^28
    uint256 constant ATTEMPTED_DRAIN = 10 ** 8 * 10 ** 18; // 10^26

    function setUp() public override {
        super.setUp();

        // Recreate exact POC setup
        maliciousMarkdownManager = new MarkdownManagerMock();
        maliciousCreditLine = new CreditLineMock(morphoAddress);
        morphoCredit = IMorphoCredit(morphoAddress);
        helper = new HelperMock(morphoAddress);

        // Create market with malicious credit line
        marketParams = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(maliciousCreditLine)
        );
        id = marketParams.id();

        // Only owner can create markets now
        vm.startPrank(OWNER);
        morpho.createMarket(marketParams);
        maliciousCreditLine.setMm(address(maliciousMarkdownManager));
        vm.stopPrank();

        // Initialize market to prevent freezing
        _ensureMarketActive(id);

        // Fund morpho with exact POC amount
        loanToken.setBalance(address(morpho), INITIAL_BALANCE);
    }

    /// @notice Test that the exact original POC attack no longer works
    function testOriginalPOCAttackFails() public {
        // Step 1: Set credit line for attacker
        vm.prank(address(maliciousCreditLine));
        morphoCredit.setCreditLine(id, BORROWER, HIGH_COLLATERAL_AMOUNT, 0);

        // Step 2: Borrow virtual shares (same as POC)
        (uint256 assets, uint256 shares) = helper.borrow(marketParams, 0, VIRTUAL_SHARES, BORROWER, BORROWER);

        assertEq(assets, 0, "Virtual shares should yield 0 assets");
        assertEq(shares, VIRTUAL_SHARES, "Should have exact virtual shares");

        // Step 3: Set up repayment obligation (trigger default)
        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = 10000; // 100%
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = 1000000; // Arbitrary obligation amount

        // Use helper to create obligation with proper cycle management
        _createMultipleObligations(id, borrowers, repaymentBps, endingBalances, 0);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Step 4: Set malicious markdown (exact POC amount)
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, MARKDOWN_AMOUNT);

        // Move to default state (31 days as in POC)
        _continueMarketCycles(id, block.timestamp + 31 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m1 = morpho.market(id);

        // Step 5: Reduce markdown to create phantom liquidity (POC exploit)
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, 0);
        _continueMarketCycles(id, block.timestamp + 1 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m2 = morpho.market(id);

        // Verify the fix: Supply should NOT have phantom liquidity
        assertTrue(m2.totalSupplyAssets < ATTEMPTED_DRAIN, "Supply should not have phantom liquidity to drain");

        // Step 6: Attempt to drain funds (should fail)
        address attacker2 = makeAddr("Attacker2");
        vm.prank(address(maliciousCreditLine));
        morphoCredit.setCreditLine(id, attacker2, HIGH_COLLATERAL_AMOUNT, 0);

        // This should revert - the attack is prevented
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        helper.borrow(marketParams, ATTEMPTED_DRAIN, 0, attacker2, attacker2);
    }

    /// @notice Test that market creation by non-owner fails (first defense)
    function testNonOwnerCannotCreateMarket() public {
        address attacker = makeAddr("Attacker");

        MarketParams memory maliciousMarket = MarketParams(
            address(loanToken),
            address(0), // Different collateral to create new market
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(maliciousCreditLine)
        );

        // Attacker tries to create market
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        morpho.createMarket(maliciousMarket);
    }

    /// @notice Test the exact markdown values from POC are handled correctly
    function testPOCMarkdownValuesCapped() public {
        // Setup with real supply (not just balance)
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set credit line
        vm.prank(address(maliciousCreditLine));
        morphoCredit.setCreditLine(id, BORROWER, 100 ether, 0);

        // Borrow small amount
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 10 ether, 0, BORROWER, BORROWER);

        // Trigger default
        _triggerDefault(BORROWER, 10 ether);

        // Apply POC's huge markdown value
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, MARKDOWN_AMOUNT);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m = morpho.market(id);

        // Verify markdown is capped at actual debt (~10 ether)
        assertTrue(m.totalMarkdownAmount < 20 ether, "Markdown should be capped at actual debt, not POC's huge value");
    }

    /// @notice Test virtual shares exploit with exact POC parameters
    function testVirtualSharesExploitPrevented() public {
        // Set credit line
        vm.prank(address(maliciousCreditLine));
        morphoCredit.setCreditLine(id, BORROWER, HIGH_COLLATERAL_AMOUNT, 0);

        // Borrow exact virtual shares from POC
        helper.borrow(marketParams, 0, VIRTUAL_SHARES, BORROWER, BORROWER);

        // Trigger default
        _triggerDefault(BORROWER, 1000000);

        // Apply huge markdown
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, MARKDOWN_AMOUNT);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m1 = morpho.market(id);
        assertEq(m1.totalSupplyAssets, 0, "Supply should stay at 0");

        // Reverse markdown (POC exploit step)
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, 0);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory m2 = morpho.market(id);

        // Verify minimal phantom liquidity from rounding
        // Virtual shares can create small amounts due to rounding (up to ~10000 wei is acceptable)
        assertTrue(m2.totalSupplyAssets < 10000, "Should not create significant phantom liquidity from virtual shares");
    }

    /// @notice Test that the fix handles markdown reversal correctly
    function testMarkdownReversalTracksActualAmount() public {
        // Supply real funds
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set credit line and borrow
        vm.prank(address(maliciousCreditLine));
        morphoCredit.setCreditLine(id, BORROWER, 100 ether, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 50 ether, 0, BORROWER, BORROWER);

        // Trigger default
        _triggerDefault(BORROWER, 50 ether);

        // Apply markdown larger than debt
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, 200 ether);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mMarkdown = morpho.market(id);
        uint256 actualMarkdown = mMarkdown.totalMarkdownAmount;

        // Should be capped at ~50 ether (the debt)
        assertTrue(actualMarkdown < 60 ether, "Markdown capped at debt");

        // Reverse markdown
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, 0);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        Market memory mReversed = morpho.market(id);

        // Supply should be restored by actual markdown amount, not requested 200 ether
        assertApproxEqAbs(mReversed.totalSupplyAssets, 1000 ether, 1e18, "Supply restored to original amount");
        assertEq(mReversed.totalMarkdownAmount, 0, "Markdown cleared");
    }

    /// @notice Test complete POC sequence with all mitigations in place
    function testCompletePOCSequenceBlocked() public {
        // Track initial state
        uint256 initialBalance = loanToken.balanceOf(address(morpho));
        assertEq(initialBalance, INITIAL_BALANCE, "Initial balance set");

        // Execute complete POC sequence

        // 1. Set credit line
        vm.prank(address(maliciousCreditLine));
        morphoCredit.setCreditLine(id, BORROWER, HIGH_COLLATERAL_AMOUNT, 0);

        // 2. Borrow virtual shares
        helper.borrow(marketParams, 0, VIRTUAL_SHARES, BORROWER, BORROWER);

        // 3. Default
        _triggerDefault(BORROWER, 1000000);

        // 4. First markdown
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, MARKDOWN_AMOUNT);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // 5. Second markdown (exploit attempt)
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, 0);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // 6. Setup second attacker
        address attacker2 = makeAddr("Attacker2");
        vm.prank(address(maliciousCreditLine));
        morphoCredit.setCreditLine(id, attacker2, HIGH_COLLATERAL_AMOUNT, 0);

        // 7. Attempt drain - should fail
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        helper.borrow(marketParams, ATTEMPTED_DRAIN, 0, attacker2, attacker2);

        // Verify funds are safe
        uint256 finalBalance = loanToken.balanceOf(address(morpho));
        assertEq(finalBalance, initialBalance, "No funds were drained");
    }

    // Helper function to trigger default state
    function _triggerDefault(address borrower, uint256 amount) internal {
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = 10000;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = amount;

        // Use helper to create obligation with proper cycle management
        _createMultipleObligations(id, borrowers, repaymentBps, endingBalances, 0);

        // Move to default (31 days past cycle end, which is 1 day ago from _createMultipleObligations)
        vm.warp(block.timestamp + 30 days);
        morphoCredit.accrueBorrowerPremium(id, borrower);
    }
}
