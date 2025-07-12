// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {MorphoCreditLib} from "../../../src/libraries/periphery/MorphoCreditLib.sol";
import {MorphoCreditBalancesLib} from "../../../src/libraries/periphery/MorphoCreditBalancesLib.sol";
import {MarkdownManagerMock} from "../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";

/// @title MorphoCreditLibTest
/// @notice Test the new periphery libraries for MorphoCredit
contract MorphoCreditLibTest is BaseTest {
    using MorphoCreditLib for IMorphoCredit;
    using MorphoCreditBalancesLib for IMorphoCredit;
    using MarketParamsLib for MarketParams;

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
        morphoCredit.setMarkdownManager(id, address(markdownManager));
        vm.stopPrank();

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 100_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test the reintroduced getBorrowerMarkdownInfo function
    function testGetBorrowerMarkdownInfo() public {
        // Setup borrower with loan
        address borrower = address(0x1234);
        uint256 borrowAmount = 10_000e18;

        vm.prank(marketParams.creditLine);
        morphoCredit.setCreditLine(id, borrower, borrowAmount * 2, 0);

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Get markdown info using the library
        (uint256 markdown, uint256 defaultTime, uint256 borrowAssets) =
            morphoCredit.getBorrowerMarkdownInfo(id, borrower);

        // Verify results
        assertEq(markdown, 0, "Should have no markdown when current");
        assertEq(defaultTime, 0, "Should have no default time when current");
        assertEq(borrowAssets, borrowAmount, "Should return correct borrow amount");
    }

    /// @notice Test the getMarketMarkdownInfo function
    function testGetMarketMarkdownInfo() public {
        // Initially should be 0
        uint256 totalMarkdown = morphoCredit.getMarketMarkdownInfo(id);
        assertEq(totalMarkdown, 0, "Initial markdown should be 0");

        // After some activity, this would change
        // (would need to trigger markdown through defaults)
    }

    /// @notice Test the getMarkdownManager function
    function testGetMarkdownManager() public {
        address manager = morphoCredit.getMarkdownManager(id);
        assertEq(manager, address(markdownManager), "Should return correct manager");
    }

    /// @notice Test expected balances with premium
    function testExpectedBorrowAssetsWithPremium() public {
        // Setup borrower with premium
        address borrower = address(0x1234);
        uint256 borrowAmount = 10_000e18;
        uint256 premiumRate = uint256(0.1e18) / uint256(365 days); // 10% APR

        vm.prank(marketParams.creditLine);
        morphoCredit.setCreditLine(id, borrower, borrowAmount * 2, uint128(premiumRate));

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Fast forward time
        vm.warp(block.timestamp + 30 days);

        // Get expected assets with premium
        uint256 expectedAssets = morphoCredit.expectedBorrowAssetsWithPremium(id, borrower);

        // Should be more than original borrow due to premium
        assertTrue(expectedAssets > borrowAmount, "Should include premium");
    }
}
