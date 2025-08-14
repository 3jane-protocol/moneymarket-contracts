// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract BorrowIntegrationTest is BaseTest {
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
    }

    function testBorrowMarketNotCreated(MarketParams memory marketParamsFuzz, address borrowerFuzz, uint256 amount)
        public
    {
        vm.assume(neq(marketParamsFuzz, marketParams));
        vm.assume(!_isProxyRelatedAddress(borrowerFuzz));

        vm.prank(borrowerFuzz);
        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.borrow(marketParamsFuzz, amount, 0, borrowerFuzz, RECEIVER);
    }

    function testBorrowZeroAmount(address borrowerFuzz) public {
        vm.assume(!_isProxyRelatedAddress(borrowerFuzz));
        vm.prank(borrowerFuzz);
        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.borrow(marketParams, 0, 0, borrowerFuzz, RECEIVER);
    }

    function testBorrowInconsistentInput(address borrowerFuzz, uint256 amount, uint256 shares) public {
        vm.assume(!_isProxyRelatedAddress(borrowerFuzz));
        amount = bound(amount, 1, MAX_TEST_AMOUNT);
        shares = bound(shares, 1, MAX_TEST_SHARES);

        vm.prank(borrowerFuzz);
        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.borrow(marketParams, amount, shares, borrowerFuzz, RECEIVER);
    }

    function testBorrowToZeroAddress(address borrowerFuzz, uint256 amount) public {
        vm.assume(!_isProxyRelatedAddress(borrowerFuzz));
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        _supply(amount);

        vm.prank(borrowerFuzz);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        morpho.borrow(marketParams, amount, 0, borrowerFuzz, address(0));
    }

    function testBorrowUnauthorized(address supplier, address attacker, uint256 amount) public {
        // Test that only helper contract can call borrow
        // For this test, we need to use actual MorphoCredit, not the mock
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        // Exclude proxy-related addresses from fuzzing
        vm.assume(!_isProxyRelatedAddress(supplier));
        vm.assume(!_isProxyRelatedAddress(attacker));
        vm.assume(supplier != address(0));
        vm.assume(supplier != attacker);
        vm.assume(attacker != address(0));

        // Deploy a separate MorphoCredit instance (not mock) for this test
        MorphoCredit morphoCreditImpl = new MorphoCredit(address(protocolConfig));
        TransparentUpgradeableProxy morphoCreditProxy = new TransparentUpgradeableProxy(
            address(morphoCreditImpl),
            address(proxyAdmin),
            abi.encodeWithSelector(MorphoCredit.initialize.selector, OWNER)
        );
        IMorpho morphoCredit = IMorpho(address(morphoCreditProxy));

        // Set helper and usd3 addresses to allow supply
        address mockUsd3 = makeAddr("MockUSD3");
        vm.prank(OWNER);
        IMorphoCredit(address(morphoCredit)).setUsd3(mockUsd3);

        // Create a new market params for the isolated test
        MarketParams memory isolatedMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV,
            creditLine: address(creditLine)
        });

        // Set up the market on the new instance
        vm.startPrank(OWNER);
        morphoCredit.enableIrm(address(irm));
        morphoCredit.enableLltv(DEFAULT_TEST_LLTV);
        morphoCredit.createMarket(isolatedMarketParams);
        vm.stopPrank();

        Id isolatedId = isolatedMarketParams.id();

        // Supply to the market (through mockUsd3 to pass the check)
        loanToken.setBalance(mockUsd3, amount);
        vm.startPrank(mockUsd3);
        loanToken.approve(address(morphoCredit), amount);
        morphoCredit.supply(isolatedMarketParams, amount, 0, supplier, hex"");
        vm.stopPrank();

        // Set up credit line for attacker
        vm.prank(isolatedMarketParams.creditLine);
        IMorphoCredit(address(morphoCredit)).setCreditLine(isolatedId, attacker, amount, 0);

        // Try to borrow directly (not through helper) - should fail
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.NotHelper.selector);
        morphoCredit.borrow(isolatedMarketParams, amount, 0, attacker, attacker);
    }

    function testBorrowUnhealthyPosition(uint256 creditLimit, uint256 amountSupplied, uint256 amountBorrowed) public {
        // For credit-based lending: unhealthy = trying to borrow more than credit limit
        creditLimit = bound(creditLimit, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT / 2);
        amountBorrowed = bound(amountBorrowed, creditLimit + 1, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        _supply(amountSupplied);

        // Set up credit line for borrower
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

        vm.prank(BORROWER);
        vm.expectRevert(ErrorsLib.InsufficientCollateral.selector);
        morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();
    }

    function testBorrowUnsufficientLiquidity(uint256 creditLimit, uint256 amountSupplied, uint256 amountBorrowed)
        public
    {
        // For credit-based lending: ensure credit is sufficient but liquidity is not
        amountBorrowed = bound(amountBorrowed, 2, MAX_TEST_AMOUNT);
        creditLimit = bound(creditLimit, amountBorrowed, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, 1, amountBorrowed - 1);

        _supply(amountSupplied);

        // Set up credit line for borrower
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

        vm.prank(BORROWER);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
        vm.stopPrank();
    }

    function testBorrowAssets(uint256 creditLimit, uint256 amountSupplied, uint256 amountBorrowed) public {
        // For credit-based lending: healthy position = borrowing within credit limit
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        creditLimit = bound(creditLimit, amountBorrowed, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        _supply(amountSupplied);

        // Set up credit line for borrower
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

        vm.startPrank(BORROWER);
        uint256 expectedBorrowShares = amountBorrowed.toSharesUp(0, 0);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Borrow(id, BORROWER, BORROWER, RECEIVER, amountBorrowed, expectedBorrowShares);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, RECEIVER);
        vm.stopPrank();

        assertEq(returnAssets, amountBorrowed, "returned asset amount");
        assertEq(returnShares, expectedBorrowShares, "returned shares amount");
        assertEq(morpho.totalBorrowAssets(id), amountBorrowed, "total borrow");
        assertEq(morpho.borrowShares(id, BORROWER), expectedBorrowShares, "borrow shares");
        assertEq(morpho.borrowShares(id, BORROWER), expectedBorrowShares, "total borrow shares");
        assertEq(loanToken.balanceOf(RECEIVER), amountBorrowed, "borrower balance");
        assertEq(loanToken.balanceOf(address(morpho)), amountSupplied - amountBorrowed, "morpho balance");
    }

    function testBorrowShares(uint256 creditLimit, uint256 amountSupplied, uint256 sharesBorrowed) public {
        sharesBorrowed = bound(sharesBorrowed, MIN_TEST_SHARES, MAX_TEST_SHARES);
        uint256 expectedAmountBorrowed = sharesBorrowed.toAssetsDown(0, 0);

        // For credit-based lending: ensure credit limit covers the expected borrow amount
        // Use toAssetsUp to ensure we have enough credit for potential rounding
        uint256 maxPossibleAmount = sharesBorrowed.toAssetsUp(0, 0);
        creditLimit = bound(creditLimit, maxPossibleAmount, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, maxPossibleAmount, MAX_TEST_AMOUNT);

        _supply(amountSupplied);

        // Set up credit line for borrower
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

        vm.startPrank(BORROWER);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.borrow(marketParams, 0, sharesBorrowed, BORROWER, RECEIVER);
        vm.stopPrank();

        assertEq(returnAssets, expectedAmountBorrowed, "returned asset amount");
        assertEq(returnShares, sharesBorrowed, "returned shares amount");
        assertEq(morpho.totalBorrowAssets(id), expectedAmountBorrowed, "total borrow");
        assertEq(morpho.borrowShares(id, BORROWER), sharesBorrowed, "borrow shares");
        assertEq(morpho.borrowShares(id, BORROWER), sharesBorrowed, "total borrow shares");
        assertEq(loanToken.balanceOf(RECEIVER), expectedAmountBorrowed, "borrower balance");
        assertEq(loanToken.balanceOf(address(morpho)), amountSupplied - expectedAmountBorrowed, "morpho balance");
    }

    function testBorrowAssetsOnBehalf(uint256 creditLimit, uint256 amountSupplied, uint256 amountBorrowed) public {
        // For credit-based lending: healthy position = borrowing within credit limit
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        creditLimit = bound(creditLimit, amountBorrowed, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        _supply(amountSupplied);

        // Set up credit line for ONBEHALF
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, ONBEHALF, creditLimit, 0);
        // BORROWER is already authorized.

        uint256 expectedBorrowShares = amountBorrowed.toSharesUp(0, 0);

        vm.prank(BORROWER);
        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Borrow(id, BORROWER, ONBEHALF, RECEIVER, amountBorrowed, expectedBorrowShares);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.borrow(marketParams, amountBorrowed, 0, ONBEHALF, RECEIVER);

        assertEq(returnAssets, amountBorrowed, "returned asset amount");
        assertEq(returnShares, expectedBorrowShares, "returned shares amount");
        assertEq(morpho.borrowShares(id, ONBEHALF), expectedBorrowShares, "borrow shares");
        assertEq(morpho.totalBorrowAssets(id), amountBorrowed, "total borrow");
        assertEq(morpho.totalBorrowShares(id), expectedBorrowShares, "total borrow shares");
        assertEq(loanToken.balanceOf(RECEIVER), amountBorrowed, "borrower balance");
        assertEq(loanToken.balanceOf(address(morpho)), amountSupplied - amountBorrowed, "morpho balance");
    }

    function testBorrowSharesOnBehalf(uint256 creditLimit, uint256 amountSupplied, uint256 sharesBorrowed) public {
        sharesBorrowed = bound(sharesBorrowed, MIN_TEST_SHARES, MAX_TEST_SHARES);
        uint256 expectedAmountBorrowed = sharesBorrowed.toAssetsDown(0, 0);

        // For credit-based lending: ensure credit limit covers the expected borrow amount
        // Use toAssetsUp to ensure we have enough credit for potential rounding
        uint256 maxPossibleAmount = sharesBorrowed.toAssetsUp(0, 0);
        creditLimit = bound(creditLimit, maxPossibleAmount, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, maxPossibleAmount, MAX_TEST_AMOUNT);

        _supply(amountSupplied);

        // Set up credit line for ONBEHALF
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, ONBEHALF, creditLimit, 0);
        // BORROWER is already authorized.

        vm.prank(BORROWER);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.borrow(marketParams, 0, sharesBorrowed, ONBEHALF, RECEIVER);

        assertEq(returnAssets, expectedAmountBorrowed, "returned asset amount");
        assertEq(returnShares, sharesBorrowed, "returned shares amount");
        assertEq(morpho.borrowShares(id, ONBEHALF), sharesBorrowed, "borrow shares");
        assertEq(morpho.totalBorrowAssets(id), expectedAmountBorrowed, "total borrow");
        assertEq(morpho.totalBorrowShares(id), sharesBorrowed, "total borrow shares");
        assertEq(loanToken.balanceOf(RECEIVER), expectedAmountBorrowed, "borrower balance");
        assertEq(loanToken.balanceOf(address(morpho)), amountSupplied - expectedAmountBorrowed, "morpho balance");
    }
}
