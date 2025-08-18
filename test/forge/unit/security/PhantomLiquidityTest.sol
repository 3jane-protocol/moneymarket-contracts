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

        IMorphoCredit mc = IMorphoCredit(address(morpho));

        // Fund the morpho contract to simulate USD3 deposits
        loanToken.setBalance(address(morpho), 10 ** 10 * 10 ** 18);

        // Set up attacker's credit line
        vm.prank(address(maliciousCreditLine));
        mc.setCreditLine(id, BORROWER, HIGH_COLLATERAL_AMOUNT, 0);

        // Step 1: Cannot borrow virtual shares with 0 assets - protocol requires actual borrowing
        vm.expectRevert(ErrorsLib.InsufficientBorrowAmount.selector);
        helper.borrow(marketParams, 0, 10 ** 6 - 1, BORROWER, BORROWER);

        // Verify the market remains clean - no phantom shares were created
        Market memory m = morpho.market(id);
        assertEq(m.totalBorrowAssets, 0, "No borrow assets should exist");
        assertEq(m.totalBorrowShares, 0, "No borrow shares should exist");
        assertEq(m.totalSupplyAssets, 0, "No supply should exist");
        assertEq(m.totalMarkdownAmount, 0, "No markdown should exist");

        // The attack cannot proceed since the initial vector is completely blocked
        // Funds remain safe in the contract
        uint256 morphoBalance = loanToken.balanceOf(address(morpho));
        assertEq(morphoBalance, 10 ** 10 * 10 ** 18, "All funds should remain safe");
    }

    /// @notice Test that markdown is properly capped at borrower's debt
    function testMarkdownCappedAtBorrowerDebt() public {
        // Create legitimate market but with test markdown manager
        marketParams.creditLine = address(maliciousCreditLine);
        vm.prank(OWNER);
        morpho.createMarket(marketParams);
        id = marketParams.id();

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
        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = 10000;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = 10 ether;

        vm.prank(address(maliciousCreditLine));
        mc.closeCycleAndPostObligations(id, block.timestamp, borrowers, repaymentBps, endingBalances);

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
