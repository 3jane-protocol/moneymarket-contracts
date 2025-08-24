// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";

contract RepayIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    CreditLineMock internal creditLine;

    function setUp() public override {
        super.setUp();

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Update marketParams to use the credit line
        marketParams = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(creditLine)
        );
        id = marketParams.id();

        // Create the market with credit line
        vm.prank(OWNER);
        morpho.createMarket(marketParams);

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

    function testRepayMarketNotCreated(MarketParams memory marketParamsFuzz) public {
        vm.assume(neq(marketParamsFuzz, marketParams));

        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.repay(marketParamsFuzz, 1, 0, address(this), hex"");
    }

    function testRepayZeroAmount() public {
        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.repay(marketParams, 0, 0, address(this), hex"");
    }

    function testRepayInconsistentInput(uint256 amount, uint256 shares) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);
        shares = bound(shares, 1, MAX_TEST_SHARES);

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.repay(marketParams, amount, shares, address(this), hex"");
    }

    function testRepayOnBehalfZeroAddress(uint256 input, bool isAmount) public {
        input = bound(input, 1, type(uint256).max);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        morpho.repay(marketParams, isAmount ? input : 0, isAmount ? 0 : input, address(0), hex"");
    }

    function testRepayAssets(uint256 amountSupplied, uint256 creditLimit, uint256 amountBorrowed, uint256 amountRepaid)
        public
    {
        // For credit-based lending: set up credit limit for borrowing
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        creditLimit = bound(creditLimit, amountBorrowed, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        _supply(amountSupplied);

        amountRepaid = bound(amountRepaid, 1, amountBorrowed);
        uint256 expectedBorrowShares = amountBorrowed.toSharesUp(0, 0);
        uint256 expectedRepaidShares = amountRepaid.toSharesDown(amountBorrowed, expectedBorrowShares);

        loanToken.setBalance(REPAYER, amountRepaid);

        // Set up credit line for ONBEHALF
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, ONBEHALF, creditLimit, 0);

        vm.startPrank(ONBEHALF);
        morpho.borrow(marketParams, amountBorrowed, 0, ONBEHALF, RECEIVER);
        vm.stopPrank();

        vm.prank(REPAYER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Repay(id, REPAYER, ONBEHALF, amountRepaid, expectedRepaidShares);
        (uint256 returnAssets, uint256 returnShares) = morpho.repay(marketParams, amountRepaid, 0, ONBEHALF, hex"");

        expectedBorrowShares -= expectedRepaidShares;

        assertEq(returnAssets, amountRepaid, "returned asset amount");
        assertEq(returnShares, expectedRepaidShares, "returned shares amount");
        assertEq(morpho.borrowShares(id, ONBEHALF), expectedBorrowShares, "borrow shares");
        assertEq(morpho.totalBorrowAssets(id), amountBorrowed - amountRepaid, "total borrow");
        assertEq(morpho.totalBorrowShares(id), expectedBorrowShares, "total borrow shares");
        assertEq(loanToken.balanceOf(RECEIVER), amountBorrowed, "RECEIVER balance");
        assertEq(loanToken.balanceOf(address(morpho)), amountSupplied - amountBorrowed + amountRepaid, "morpho balance");
    }

    function testRepayShares(uint256 amountSupplied, uint256 creditLimit, uint256 amountBorrowed, uint256 sharesRepaid)
        public
    {
        // For credit-based lending: set up credit limit for borrowing
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        creditLimit = bound(creditLimit, amountBorrowed, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        _supply(amountSupplied);

        uint256 expectedBorrowShares = amountBorrowed.toSharesUp(0, 0);
        sharesRepaid = bound(sharesRepaid, 1, expectedBorrowShares);
        uint256 expectedAmountRepaid = sharesRepaid.toAssetsUp(amountBorrowed, expectedBorrowShares);

        loanToken.setBalance(REPAYER, expectedAmountRepaid);

        // Set up credit line for ONBEHALF
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, ONBEHALF, creditLimit, 0);

        vm.startPrank(ONBEHALF);
        morpho.borrow(marketParams, amountBorrowed, 0, ONBEHALF, RECEIVER);
        vm.stopPrank();

        vm.prank(REPAYER);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Repay(id, REPAYER, ONBEHALF, expectedAmountRepaid, sharesRepaid);
        (uint256 returnAssets, uint256 returnShares) = morpho.repay(marketParams, 0, sharesRepaid, ONBEHALF, hex"");

        expectedBorrowShares -= sharesRepaid;

        assertEq(returnAssets, expectedAmountRepaid, "returned asset amount");
        assertEq(returnShares, sharesRepaid, "returned shares amount");
        assertEq(morpho.borrowShares(id, ONBEHALF), expectedBorrowShares, "borrow shares");
        assertEq(morpho.totalBorrowAssets(id), amountBorrowed - expectedAmountRepaid, "total borrow");
        assertEq(morpho.totalBorrowShares(id), expectedBorrowShares, "total borrow shares");
        assertEq(loanToken.balanceOf(RECEIVER), amountBorrowed, "RECEIVER balance");
        assertEq(
            loanToken.balanceOf(address(morpho)),
            amountSupplied - amountBorrowed + expectedAmountRepaid,
            "morpho balance"
        );
    }

    function testRepayMax(uint256 shares) public {
        shares = bound(shares, MIN_TEST_SHARES, MAX_TEST_SHARES);

        uint256 assets = shares.toAssetsUp(0, 0);

        loanToken.setBalance(address(this), assets);

        morpho.supply(marketParams, 0, shares, SUPPLIER, hex"");

        // Set up credit line for BORROWER
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, assets, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 0, shares, BORROWER, RECEIVER);

        loanToken.setBalance(address(this), assets);

        morpho.repay(marketParams, 0, shares, BORROWER, hex"");
    }
}
