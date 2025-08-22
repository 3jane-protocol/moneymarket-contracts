// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../mocks/MarkdownManagerMock.sol";
import {CreditLine} from "../../../../src/CreditLine.sol";
import {HelperMock} from "../../../../src/mocks/HelperMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {Market, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";

/// @title PhantomLiquidityTest
/// @notice Tests to verify phantom liquidity creation through markdown manipulation is prevented
/// @dev Tests the fixes for the critical vulnerability where malicious markdown could create phantom liquidity
contract PhantomLiquidityTest is BaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    MarkdownManagerMock public maliciousMarkdownManager;
    CreditLine public maliciousCreditLine;
    HelperMock public helper;
    address internal maliciousOwner;

    function setUp() public override {
        super.setUp();

        // Deploy helper for borrow operations
        helper = new HelperMock(address(morpho));

        // Set up malicious actors
        maliciousOwner = makeAddr("MaliciousOwner");
        maliciousMarkdownManager = new MarkdownManagerMock();
        maliciousCreditLine = new CreditLine(
            address(morpho),
            maliciousOwner,
            address(1), // ozd
            address(maliciousMarkdownManager),
            address(0) // prover
        );
    }

    /// @notice Test that non-owners cannot create markets (primary defense)
    function testCannotCreateMarketAsNonOwner() public {
        // Prepare malicious market parameters
        MarketParams memory maliciousMarket = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(maliciousCreditLine)
        );

        // Attempt to create market as non-owner should fail
        vm.prank(maliciousOwner);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        morpho.createMarket(maliciousMarket);
    }

    /// @notice Test that the original attack vector fails even if owner creates malicious market
    /// @dev This demonstrates that even with owner compromise, the markdown fix prevents fund drainage
    function testBalanceDrainingAttackPrevented() public {
        // Create market as owner with malicious components
        marketParams.creditLine = address(maliciousCreditLine);
        vm.prank(OWNER);
        morpho.createMarket(marketParams);
        id = marketParams.id();

        // Initialize first cycle to unfreeze the market
        vm.warp(block.timestamp + CYCLE_DURATION);
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, block.timestamp, borrowers, repaymentBps, endingBalances
        );

        IMorphoCredit mc = IMorphoCredit(address(morpho));

        // Fund the morpho contract to simulate USD3 deposits
        loanToken.setBalance(address(morpho), 10 ** 10 * 10 ** 18);

        // Set up attacker's credit line
        vm.prank(address(maliciousCreditLine));
        mc.setCreditLine(id, BORROWER, HIGH_COLLATERAL_AMOUNT, 0);

        // Step 1: Borrow virtual shares (creates minimal position)
        (uint256 assets, uint256 shares) = helper.borrow(marketParams, 0, 10 ** 6 - 1, BORROWER, BORROWER);
        assertEq(assets, 0, "Virtual shares should not create assets");
        assertEq(shares, 10 ** 6 - 1, "Should have borrowed virtual shares");

        // Step 2: Set up repayment obligation to trigger default
        address[] memory borrowers2 = new address[](1);
        borrowers2[0] = BORROWER;
        uint256[] memory repaymentBps2 = new uint256[](1);
        repaymentBps2[0] = 10000;
        uint256[] memory endingBalances2 = new uint256[](1);
        endingBalances2[0] = 1000000;

        // Move forward to allow next cycle
        vm.warp(block.timestamp + CYCLE_DURATION);
        vm.prank(address(maliciousCreditLine));
        mc.closeCycleAndPostObligations(id, block.timestamp, borrowers2, repaymentBps2, endingBalances2);
        mc.accrueBorrowerPremium(id, BORROWER);

        // Step 3: Set malicious markdown (would exploit old code)
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, 10 ** 10 * 10 ** 18);

        // Move to default state
        vm.warp(block.timestamp + 31 days);
        mc.accrueBorrowerPremium(id, BORROWER);

        Market memory m = morpho.market(id);
        uint256 supplyAfterFirstMarkdown = m.totalSupplyAssets;
        uint256 markdownAfterFirst = m.totalMarkdownAmount;

        // Step 4: Second markdown - this would create phantom liquidity in vulnerable code
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, 0);
        vm.warp(block.timestamp + 1 days);
        mc.accrueBorrowerPremium(id, BORROWER);

        m = morpho.market(id);

        // Verify the fix prevents phantom liquidity creation
        // The supply should only reflect actual marked down amount, not the requested 10^28
        assertTrue(m.totalSupplyAssets < 10 ** 20, "Supply should not have phantom liquidity");

        // Step 5: Ensure market is still active for the attack attempt
        // Post a new cycle to keep market active
        vm.warp(block.timestamp + CYCLE_DURATION - 2 days);
        address[] memory borrowers3 = new address[](0);
        uint256[] memory repaymentBps3 = new uint256[](0);
        uint256[] memory endingBalances3 = new uint256[](0);
        vm.prank(address(maliciousCreditLine));
        mc.closeCycleAndPostObligations(id, block.timestamp, borrowers3, repaymentBps3, endingBalances3);

        // Attempt to drain funds should fail
        address attacker2 = makeAddr("Attacker2");
        vm.prank(address(maliciousCreditLine));
        mc.setCreditLine(id, attacker2, HIGH_COLLATERAL_AMOUNT, 0);

        // This should revert with InsufficientLiquidity
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        helper.borrow(marketParams, 10 ** 8 * 10 ** 18, 0, attacker2, attacker2);
    }

    /// @notice Test that markdown is properly capped at borrower's debt
    function testMarkdownCappedAtBorrowerDebt() public {
        // Create legitimate market but with test markdown manager
        marketParams.creditLine = address(maliciousCreditLine);
        vm.prank(OWNER);
        morpho.createMarket(marketParams);
        id = marketParams.id();

        // Initialize first cycle to unfreeze the market
        vm.warp(block.timestamp + CYCLE_DURATION);
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, block.timestamp, borrowers, repaymentBps, endingBalances
        );

        IMorphoCredit mc = IMorphoCredit(address(morpho));

        // Supply funds to market
        loanToken.setBalance(SUPPLIER, 1000 ether);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 1000 ether, 0, SUPPLIER, "");
        vm.stopPrank();

        // Set up borrower
        vm.prank(address(maliciousCreditLine));
        mc.setCreditLine(id, BORROWER, 100 ether, 0);

        // Borrow 10 ether
        loanToken.setBalance(BORROWER, 0);
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 10 ether, 0, BORROWER, BORROWER);

        // Set up repayment obligation to trigger default
        address[] memory borrowers3 = new address[](1);
        borrowers3[0] = BORROWER;
        uint256[] memory repaymentBps3 = new uint256[](1);
        repaymentBps3[0] = 10000;
        uint256[] memory endingBalances3 = new uint256[](1);
        endingBalances3[0] = 10 ether;

        // Move forward to allow next cycle
        vm.warp(block.timestamp + CYCLE_DURATION);
        vm.prank(address(maliciousCreditLine));
        mc.closeCycleAndPostObligations(id, block.timestamp, borrowers3, repaymentBps3, endingBalances3);

        // Move to default
        vm.warp(block.timestamp + 31 days);

        // Set markdown way above borrower's debt
        maliciousMarkdownManager.setMarkdownForBorrower(BORROWER, 1000 ether);
        mc.accrueBorrowerPremium(id, BORROWER);

        Market memory m = morpho.market(id);

        // Markdown should be capped at approximately the borrower's debt (10 ether + interest)
        assertTrue(m.totalMarkdownAmount < 15 ether, "Markdown should be capped at borrower's debt");
    }
}
