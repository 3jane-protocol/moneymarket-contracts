// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";

contract WithdrawIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;

    function testWithdrawMarketNotCreated(MarketParams memory marketParamsParamsFuzz) public {
        vm.assume(neq(marketParamsParamsFuzz, marketParams));

        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.withdraw(marketParamsParamsFuzz, 1, 0, address(this), address(this));
    }

    function testWithdrawZeroAmount(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.withdraw(marketParams, 0, 0, address(this), address(this));
    }

    function testWithdrawInconsistentInput(uint256 amount, uint256 shares) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);
        shares = bound(shares, 1, MAX_TEST_SHARES);

        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.withdraw(marketParams, amount, shares, address(this), address(this));
    }

    function testWithdrawToZeroAddress(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        morpho.withdraw(marketParams, amount, 0, address(this), address(0));
    }

    function testWithdrawUnauthorized(address attacker, uint256 amount) public {
        vm.assume(attacker != address(this));
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        morpho.withdraw(marketParams, amount, 0, address(this), address(this));
    }

    function testWithdrawInsufficientLiquidity(uint256 amountSupplied, uint256 amountBorrowed) public {
        // For credit-based lending: test withdrawal when there's insufficient liquidity
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, amountBorrowed + 1, MAX_TEST_AMOUNT + 1);
        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        loanToken.setBalance(SUPPLIER, amountSupplied);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, amountSupplied, 0, SUPPLIER, hex"");

        // Set up credit line for BORROWER
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

        vm.startPrank(BORROWER);
        morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, RECEIVER);
        vm.stopPrank();

        vm.prank(SUPPLIER);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        morpho.withdraw(marketParams, amountSupplied, 0, SUPPLIER, RECEIVER);
    }

    function testWithdrawAssets(uint256 amountSupplied, uint256 amountBorrowed, uint256 amountWithdrawn) public {
        // For credit-based lending: test withdrawal with active borrowing
        amountBorrowed = bound(amountBorrowed, 0, MAX_TEST_AMOUNT - 1);
        amountSupplied = bound(amountSupplied, amountBorrowed + 1, MAX_TEST_AMOUNT);
        amountWithdrawn = bound(amountWithdrawn, 1, amountSupplied - amountBorrowed);

        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        if (amountBorrowed > 0) {
            // Set up credit line for BORROWER
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

            vm.startPrank(BORROWER);
            morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
            vm.stopPrank();
        }

        uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
        uint256 expectedWithdrawnShares = amountWithdrawn.toSharesUp(amountSupplied, expectedSupplyShares);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Withdraw(id, address(this), address(this), RECEIVER, amountWithdrawn, expectedWithdrawnShares);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.withdraw(marketParams, amountWithdrawn, 0, address(this), RECEIVER);

        expectedSupplyShares -= expectedWithdrawnShares;

        assertEq(returnAssets, amountWithdrawn, "returned asset amount");
        assertEq(returnShares, expectedWithdrawnShares, "returned shares amount");
        assertEq(morpho.supplyShares(id, address(this)), expectedSupplyShares, "supply shares");
        assertEq(morpho.totalSupplyShares(id), expectedSupplyShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(id), amountSupplied - amountWithdrawn, "total supply");
        assertEq(loanToken.balanceOf(RECEIVER), amountWithdrawn, "RECEIVER balance");
        assertEq(loanToken.balanceOf(BORROWER), amountBorrowed, "borrower balance");
        assertEq(
            loanToken.balanceOf(address(morpho)), amountSupplied - amountBorrowed - amountWithdrawn, "morpho balance"
        );
    }

    function testWithdrawShares(uint256 amountSupplied, uint256 amountBorrowed, uint256 sharesWithdrawn) public {
        // For credit-based lending: test share-based withdrawal
        amountBorrowed = bound(amountBorrowed, 0, MAX_TEST_AMOUNT / 2);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
        uint256 availableLiquidity = amountSupplied - amountBorrowed;
        uint256 withdrawableShares = availableLiquidity.toSharesDown(amountSupplied, expectedSupplyShares);
        vm.assume(withdrawableShares != 0);

        sharesWithdrawn = bound(sharesWithdrawn, 1, withdrawableShares);
        uint256 expectedAmountWithdrawn = sharesWithdrawn.toAssetsDown(amountSupplied, expectedSupplyShares);

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        if (amountBorrowed > 0) {
            // Set up credit line for BORROWER
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

            vm.startPrank(BORROWER);
            morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
            vm.stopPrank();
        }

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Withdraw(id, address(this), address(this), RECEIVER, expectedAmountWithdrawn, sharesWithdrawn);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.withdraw(marketParams, 0, sharesWithdrawn, address(this), RECEIVER);

        expectedSupplyShares -= sharesWithdrawn;

        assertEq(returnAssets, expectedAmountWithdrawn, "returned asset amount");
        assertEq(returnShares, sharesWithdrawn, "returned shares amount");
        assertEq(morpho.supplyShares(id, address(this)), expectedSupplyShares, "supply shares");
        assertEq(morpho.totalSupplyAssets(id), amountSupplied - expectedAmountWithdrawn, "total supply");
        assertEq(morpho.totalSupplyShares(id), expectedSupplyShares, "total supply shares");
        assertEq(loanToken.balanceOf(RECEIVER), expectedAmountWithdrawn, "RECEIVER balance");
        assertEq(
            loanToken.balanceOf(address(morpho)),
            amountSupplied - amountBorrowed - expectedAmountWithdrawn,
            "morpho balance"
        );
    }

    function testWithdrawAssetsOnBehalf(uint256 amountSupplied, uint256 amountBorrowed, uint256 amountWithdrawn)
        public
    {
        // For credit-based lending: test on-behalf withdrawal
        amountBorrowed = bound(amountBorrowed, 0, MAX_TEST_AMOUNT - 1);
        amountSupplied = bound(amountSupplied, amountBorrowed + 1, MAX_TEST_AMOUNT);
        amountWithdrawn = bound(amountWithdrawn, 1, amountSupplied - amountBorrowed);

        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        loanToken.setBalance(ONBEHALF, amountSupplied);

        vm.startPrank(ONBEHALF);
        morpho.supply(marketParams, amountSupplied, 0, ONBEHALF, hex"");

        if (amountBorrowed > 0) {
            // Set up credit line for ONBEHALF
            vm.stopPrank();
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho)).setCreditLine(id, ONBEHALF, creditLimit, 0);
            vm.startPrank(ONBEHALF);

            morpho.borrow(marketParams, amountBorrowed, 0, ONBEHALF, ONBEHALF);
        }
        vm.stopPrank();

        uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
        uint256 expectedWithdrawnShares = amountWithdrawn.toSharesUp(amountSupplied, expectedSupplyShares);

        uint256 receiverBalanceBefore = loanToken.balanceOf(RECEIVER);

        vm.startPrank(BORROWER);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Withdraw(id, BORROWER, ONBEHALF, RECEIVER, amountWithdrawn, expectedWithdrawnShares);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.withdraw(marketParams, amountWithdrawn, 0, ONBEHALF, RECEIVER);

        expectedSupplyShares -= expectedWithdrawnShares;

        assertEq(returnAssets, amountWithdrawn, "returned asset amount");
        assertEq(returnShares, expectedWithdrawnShares, "returned shares amount");
        assertEq(morpho.supplyShares(id, ONBEHALF), expectedSupplyShares, "supply shares");
        assertEq(morpho.totalSupplyAssets(id), amountSupplied - amountWithdrawn, "total supply");
        assertEq(morpho.totalSupplyShares(id), expectedSupplyShares, "total supply shares");
        assertEq(loanToken.balanceOf(RECEIVER) - receiverBalanceBefore, amountWithdrawn, "RECEIVER balance");
        assertEq(
            loanToken.balanceOf(address(morpho)), amountSupplied - amountBorrowed - amountWithdrawn, "morpho balance"
        );
    }

    function testWithdrawSharesOnBehalf(uint256 amountSupplied, uint256 amountBorrowed, uint256 sharesWithdrawn)
        public
    {
        // For credit-based lending: test share-based on-behalf withdrawal
        amountBorrowed = bound(amountBorrowed, 0, MAX_TEST_AMOUNT / 2);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
        uint256 availableLiquidity = amountSupplied - amountBorrowed;
        uint256 withdrawableShares = availableLiquidity.toSharesDown(amountSupplied, expectedSupplyShares);
        vm.assume(withdrawableShares != 0);

        sharesWithdrawn = bound(sharesWithdrawn, 1, withdrawableShares);
        uint256 expectedAmountWithdrawn = sharesWithdrawn.toAssetsDown(amountSupplied, expectedSupplyShares);

        loanToken.setBalance(ONBEHALF, amountSupplied);

        vm.startPrank(ONBEHALF);
        morpho.supply(marketParams, amountSupplied, 0, ONBEHALF, hex"");

        if (amountBorrowed > 0) {
            // Set up credit line for ONBEHALF
            vm.stopPrank();
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho)).setCreditLine(id, ONBEHALF, creditLimit, 0);
            vm.startPrank(ONBEHALF);

            morpho.borrow(marketParams, amountBorrowed, 0, ONBEHALF, ONBEHALF);
        }
        vm.stopPrank();

        uint256 receiverBalanceBefore = loanToken.balanceOf(RECEIVER);

        vm.startPrank(BORROWER);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Withdraw(id, BORROWER, ONBEHALF, RECEIVER, expectedAmountWithdrawn, sharesWithdrawn);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.withdraw(marketParams, 0, sharesWithdrawn, ONBEHALF, RECEIVER);

        expectedSupplyShares -= sharesWithdrawn;

        assertEq(returnAssets, expectedAmountWithdrawn, "returned asset amount");
        assertEq(returnShares, sharesWithdrawn, "returned shares amount");
        assertEq(morpho.supplyShares(id, ONBEHALF), expectedSupplyShares, "supply shares");
        assertEq(morpho.totalSupplyAssets(id), amountSupplied - expectedAmountWithdrawn, "total supply");
        assertEq(morpho.totalSupplyShares(id), expectedSupplyShares, "total supply shares");
        assertEq(loanToken.balanceOf(RECEIVER) - receiverBalanceBefore, expectedAmountWithdrawn, "RECEIVER balance");
        assertEq(
            loanToken.balanceOf(address(morpho)),
            amountSupplied - amountBorrowed - expectedAmountWithdrawn,
            "morpho balance"
        );
    }
}
