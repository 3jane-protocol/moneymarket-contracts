// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";

contract AccrueInterestIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    CreditLineMock internal creditLine;

    function setUp() public override {
        super.setUp();

        // Deploy credit line mock
        // Required: Credit line markets need active payment cycles to allow borrowing after the market freeze refactor
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

        // Initialize market cycles to prevent MarketFrozen error
        // Required for all credit line markets after the freeze refactor - markets without active cycles are frozen
        _ensureMarketActive(id);
    }

    function testAccrueInterestMarketNotCreated(MarketParams memory marketParamsFuzz) public {
        vm.assume(neq(marketParamsFuzz, marketParams));

        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.accrueInterest(marketParamsFuzz);
    }

    function testAccrueInterestIrmZero(MarketParams memory marketParamsFuzz, uint256 blocks) public {
        marketParamsFuzz.irm = address(0);
        marketParamsFuzz.lltv = 0;
        blocks = _boundBlocks(blocks);

        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);

        // Use simple time warp since this market doesn't have credit lines
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_TIME);

        morpho.accrueInterest(marketParamsFuzz);
    }

    function testAccrueInterestNoTimeElapsed(uint256 amountSupplied, uint256 amountBorrowed, uint256 amountCollateral)
        public
    {
        uint256 collateralPrice = oracle.price();
        (amountCollateral, amountBorrowed,) = _boundHealthyPosition(amountCollateral, amountBorrowed, collateralPrice);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        // Set up credit line for borrower
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, amountCollateral, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);

        uint256 totalBorrowBeforeAccrued = morpho.totalBorrowAssets(id);
        uint256 totalSupplyBeforeAccrued = morpho.totalSupplyAssets(id);
        uint256 totalSupplySharesBeforeAccrued = morpho.totalSupplyShares(id);

        morpho.accrueInterest(marketParams);

        assertEq(morpho.totalBorrowAssets(id), totalBorrowBeforeAccrued, "total borrow");
        assertEq(morpho.totalSupplyAssets(id), totalSupplyBeforeAccrued, "total supply");
        assertEq(morpho.totalSupplyShares(id), totalSupplySharesBeforeAccrued, "total supply shares");
        assertEq(morpho.supplyShares(id, FEE_RECIPIENT), 0, "feeRecipient's supply shares");
    }

    function testAccrueInterestNoBorrow(uint256 amountSupplied, uint256 blocks) public {
        amountSupplied = bound(amountSupplied, 2, MAX_TEST_AMOUNT);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        _forwardWithMarket(blocks, id);

        uint256 totalBorrowBeforeAccrued = morpho.totalBorrowAssets(id);
        uint256 totalSupplyBeforeAccrued = morpho.totalSupplyAssets(id);
        uint256 totalSupplySharesBeforeAccrued = morpho.totalSupplyShares(id);

        morpho.accrueInterest(marketParams);

        assertEq(morpho.totalBorrowAssets(id), totalBorrowBeforeAccrued, "total borrow");
        assertEq(morpho.totalSupplyAssets(id), totalSupplyBeforeAccrued, "total supply");
        assertEq(morpho.totalSupplyShares(id), totalSupplySharesBeforeAccrued, "total supply shares");
        assertEq(morpho.supplyShares(id, FEE_RECIPIENT), 0, "feeRecipient's supply shares");
        assertEq(morpho.lastUpdate(id), block.timestamp, "last update");
    }

    function testAccrueInterestNoFee(
        uint256 amountSupplied,
        uint256 amountBorrowed,
        uint256 amountCollateral,
        uint256 blocks
    ) public {
        uint256 collateralPrice = oracle.price();
        (amountCollateral, amountBorrowed,) = _boundHealthyPosition(amountCollateral, amountBorrowed, collateralPrice);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        // Set up credit line for borrower
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, amountCollateral, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);

        _forwardWithMarket(blocks, id);

        uint256 borrowRate = (morpho.totalBorrowAssets(id).wDivDown(morpho.totalSupplyAssets(id))) / 365 days;
        uint256 totalBorrowBeforeAccrued = morpho.totalBorrowAssets(id);
        uint256 totalSupplyBeforeAccrued = morpho.totalSupplyAssets(id);
        uint256 totalSupplySharesBeforeAccrued = morpho.totalSupplyShares(id);
        uint256 expectedAccruedInterest =
            totalBorrowBeforeAccrued.wMulDown(borrowRate.wTaylorCompounded(blocks * BLOCK_TIME));

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.AccrueInterest(id, borrowRate, expectedAccruedInterest, 0);
        morpho.accrueInterest(marketParams);

        assertEq(morpho.totalBorrowAssets(id), totalBorrowBeforeAccrued + expectedAccruedInterest, "total borrow");
        assertEq(morpho.totalSupplyAssets(id), totalSupplyBeforeAccrued + expectedAccruedInterest, "total supply");
        assertEq(morpho.totalSupplyShares(id), totalSupplySharesBeforeAccrued, "total supply shares");
        assertEq(morpho.supplyShares(id, FEE_RECIPIENT), 0, "feeRecipient's supply shares");
        assertEq(morpho.lastUpdate(id), block.timestamp, "last update");
    }

    struct AccrueInterestWithFeesTestParams {
        uint256 borrowRate;
        uint256 totalBorrowBeforeAccrued;
        uint256 totalSupplyBeforeAccrued;
        uint256 totalSupplySharesBeforeAccrued;
        uint256 expectedAccruedInterest;
        uint256 feeAmount;
        uint256 feeShares;
    }

    function testAccrueInterestWithFees(
        uint256 amountSupplied,
        uint256 amountBorrowed,
        uint256 amountCollateral,
        uint256 blocks,
        uint256 fee
    ) public {
        AccrueInterestWithFeesTestParams memory params;

        uint256 collateralPrice = oracle.price();
        (amountCollateral, amountBorrowed,) = _boundHealthyPosition(amountCollateral, amountBorrowed, collateralPrice);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);
        blocks = _boundBlocks(blocks);
        fee = bound(fee, 1, MAX_FEE);

        // Set fee parameters.
        vm.startPrank(OWNER);
        if (fee != morpho.fee(id)) morpho.setFee(marketParams, fee);
        vm.stopPrank();

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        // Set up credit line for borrower
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, amountCollateral, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);

        _forwardWithMarket(blocks, id);

        params.borrowRate = (morpho.totalBorrowAssets(id).wDivDown(morpho.totalSupplyAssets(id))) / 365 days;
        params.totalBorrowBeforeAccrued = morpho.totalBorrowAssets(id);
        params.totalSupplyBeforeAccrued = morpho.totalSupplyAssets(id);
        params.totalSupplySharesBeforeAccrued = morpho.totalSupplyShares(id);
        params.expectedAccruedInterest =
            params.totalBorrowBeforeAccrued.wMulDown(params.borrowRate.wTaylorCompounded(blocks * BLOCK_TIME));
        params.feeAmount = params.expectedAccruedInterest.wMulDown(fee);
        params.feeShares = params.feeAmount.toSharesDown(
            params.totalSupplyBeforeAccrued + params.expectedAccruedInterest - params.feeAmount,
            params.totalSupplySharesBeforeAccrued
        );

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.AccrueInterest(id, params.borrowRate, params.expectedAccruedInterest, params.feeShares);
        morpho.accrueInterest(marketParams);

        assertEq(
            morpho.totalSupplyAssets(id),
            params.totalSupplyBeforeAccrued + params.expectedAccruedInterest,
            "total supply"
        );
        assertEq(
            morpho.totalBorrowAssets(id),
            params.totalBorrowBeforeAccrued + params.expectedAccruedInterest,
            "total borrow"
        );
        assertEq(
            morpho.totalSupplyShares(id),
            params.totalSupplySharesBeforeAccrued + params.feeShares,
            "total supply shares"
        );
        assertEq(morpho.supplyShares(id, FEE_RECIPIENT), params.feeShares, "feeRecipient's supply shares");
        assertEq(morpho.lastUpdate(id), block.timestamp, "last update");
    }
}
