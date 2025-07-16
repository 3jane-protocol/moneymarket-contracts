// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {MarkdownManagerMock} from "../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {Market} from "../../../src/interfaces/IMorpho.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";

contract MarkdownTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

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
    }

    function testMarkdownManagerSet() public {
        assertEq(MorphoCredit(address(morphoCredit)).markdownManager(id), address(markdownManager));
    }

    function testMarkdownCalculation() public {
        uint256 borrowAmount = 1000e18;
        uint256 defaultStartTime = block.timestamp;

        // Fast forward 10 days
        vm.warp(block.timestamp + 10 days);

        // Calculate markdown (10 days * 1% per day = 10%)
        uint256 timeInDefault = block.timestamp > defaultStartTime ? block.timestamp - defaultStartTime : 0;
        uint256 markdown = markdownManager.calculateMarkdown(borrowAmount, timeInDefault);

        assertEq(markdown, 100e18); // 10% of 1000 = 100
    }

    function testBorrowerMarkdownUpdate() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;

        // Setup: create supply and borrow
        loanToken.setBalance(address(this), supplyAmount);
        loanToken.approve(address(morpho), supplyAmount);
        morpho.supply(marketParams, supplyAmount, 0, address(this), hex"");

        // Set credit line and borrow
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, borrowAmount * 2, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Create an obligation to trigger default
        _createPastObligation(BORROWER, 500, borrowAmount); // 5% repayment

        // Fast forward to default (past grace + delinquency period)
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);

        // Trigger markdown update by accruing premium
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Check markdown info
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultStartTime) = morphoCredit.getRepaymentStatus(id, BORROWER);
        uint256 currentMarkdown = 0;
        if (status == RepaymentStatus.Default && defaultStartTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultStartTime ? block.timestamp - defaultStartTime : 0;
            currentMarkdown = markdownManager.calculateMarkdown(borrowAssets, timeInDefault);
        }

        assertEq(uint8(status), uint8(RepaymentStatus.Default), "Should be in default");
        assertTrue(defaultStartTime > 0, "Default start time should be set");
        assertTrue(currentMarkdown > 0, "Markdown should be calculated");
        assertTrue(borrowAssets >= borrowAmount, "Borrow assets should be at least initial amount");
    }

    function testSettleDebt() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 repayAmount = 1_000e18; // 20% repayment

        // Setup: create supply and borrow
        loanToken.setBalance(address(this), supplyAmount);
        loanToken.approve(address(morpho), supplyAmount);
        morpho.supply(marketParams, supplyAmount, 0, address(this), hex"");

        // Set credit line and borrow
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, borrowAmount * 2, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Create an obligation to trigger default
        _createPastObligation(BORROWER, 500, borrowAmount); // 5% repayment

        // Fast forward to default
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);

        // Settle the debt
        loanToken.setBalance(address(creditLine), repayAmount);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), repayAmount);

        (uint256 repaidAssets, uint256 repaidShares) = morpho.repay(marketParams, repayAmount, 0, BORROWER, hex"");
        (uint256 writtenOffAssets, uint256 writtenOffShares) = morphoCredit.settleAccount(marketParams, BORROWER);
        vm.stopPrank();

        // Check results
        assertTrue(repaidShares > 0, "Some shares should be repaid");
        assertTrue(writtenOffShares > 0, "Some shares should be written off");
        assertEq(morpho.position(id, BORROWER).borrowShares, 0, "Borrower position should be cleared");

        // Check market totals were updated
        Market memory marketAfter = morpho.market(id);
        assertTrue(marketAfter.totalBorrowAssets < borrowAmount, "Total borrow should decrease");
        assertTrue(marketAfter.totalSupplyAssets < supplyAmount, "Total supply should decrease due to write-off");
    }

    function testEffectiveSupplyWithMarkdown() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;

        // Setup: create supply and borrow
        loanToken.setBalance(address(this), supplyAmount);
        loanToken.approve(address(morpho), supplyAmount);
        (, uint256 supplyShares) =
            morpho.supply(marketParams, supplyAmount, 0, address(this), hex"");

        // Set credit line and borrow
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, borrowAmount * 2, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Create an obligation to trigger default
        _createPastObligation(BORROWER, 500, borrowAmount); // 5% repayment

        // Fast forward to default and trigger markdown
        vm.warp(block.timestamp + 31 days);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get market markdown info
        uint256 totalMarkdown = morpho.market(id).totalMarkdownAmount;

        // Get current market state to compare with effective supply

        assertTrue(totalMarkdown > 0, "Total markdown should be positive");
        // Since markdowns directly reduce totalSupplyAssets, markdown is tracked in totalMarkdownAmount

        // Try to withdraw - should use effective supply for conversion
        uint256 withdrawAmount = 1_000e18;
        (uint256 withdrawnAssets, uint256 withdrawnShares) =
            morpho.withdraw(marketParams, withdrawAmount, 0, address(this), address(this));

        assertTrue(withdrawnAssets <= withdrawAmount, "Should not withdraw more than requested");
        assertTrue(withdrawnShares > 0, "Should burn some shares");
    }
}
