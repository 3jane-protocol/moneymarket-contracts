// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";

contract CallbacksIntegrationTest is BaseTest, IMorphoRepayCallback, IMorphoSupplyCallback, IMorphoFlashLoanCallback {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    // Callback functions.

    function onMorphoSupply(uint256 amount, bytes memory data) external {
        require(msg.sender == address(morpho));
        bytes4 selector;
        (selector, data) = abi.decode(data, (bytes4, bytes));
        if (selector == this.testSupplyCallback.selector) {
            loanToken.approve(address(morpho), amount);
        }
    }

    function onMorphoRepay(uint256 amount, bytes memory data) external {
        require(msg.sender == address(morpho));
        bytes4 selector;
        (selector, data) = abi.decode(data, (bytes4, bytes));
        if (selector == this.testRepayCallback.selector) {
            loanToken.approve(address(morpho), amount);
        } else if (selector == this.testFlashActions.selector) {
            // In 3Jane, there's no collateral to withdraw
            // This callback path is no longer used
        }
    }

    function onMorphoFlashLoan(uint256 amount, bytes memory data) external {
        require(msg.sender == address(morpho));
        bytes4 selector;
        (selector, data) = abi.decode(data, (bytes4, bytes));
        if (selector == this.testFlashLoan.selector) {
            assertEq(loanToken.balanceOf(address(this)), amount);
            loanToken.approve(address(morpho), amount);
        }
    }

    // Tests.

    function testFlashLoan(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        morpho.flashLoan(address(loanToken), amount, abi.encode(this.testFlashLoan.selector, hex""));

        assertEq(loanToken.balanceOf(address(morpho)), amount, "balanceOf");
    }

    function testFlashLoanZero() public {
        vm.expectRevert(ErrorsLib.ZeroAssets.selector);
        morpho.flashLoan(address(loanToken), 0, abi.encode(this.testFlashLoan.selector, hex""));
    }

    function testFlashLoanShouldRevertIfNotReimbursed(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        loanToken.approve(address(morpho), 0);

        vm.expectRevert(ErrorsLib.TransferFromReverted.selector);
        morpho.flashLoan(
            address(loanToken), amount, abi.encode(this.testFlashLoanShouldRevertIfNotReimbursed.selector, hex"")
        );
    }

    function testSupplyCallback(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amount);
        loanToken.approve(address(morpho), 0);

        vm.expectRevert();
        morpho.supply(marketParams, amount, 0, address(this), hex"");
        morpho.supply(marketParams, amount, 0, address(this), abi.encode(this.testSupplyCallback.selector, hex""));
    }

    // Removed testSupplyCollateralCallback as collateral operations are removed in 3Jane
    // Credit lines are managed through the CreditLine contract instead

    function testRepayCallback(uint256 loanAmount) public {
        loanAmount = bound(loanAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 collateralAmount;
        (collateralAmount, loanAmount,) = _boundHealthyPosition(0, loanAmount, oracle.price());

        oracle.setPrice(ORACLE_PRICE_SCALE);

        loanToken.setBalance(address(this), loanAmount);

        morpho.supply(marketParams, loanAmount, 0, address(this), hex"");

        // Set up credit line instead of supplying collateral
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, address(this), collateralAmount, 0);

        morpho.borrow(marketParams, loanAmount, 0, address(this), address(this));

        loanToken.approve(address(morpho), 0);

        vm.expectRevert();
        morpho.repay(marketParams, loanAmount, 0, address(this), hex"");
        morpho.repay(marketParams, loanAmount, 0, address(this), abi.encode(this.testRepayCallback.selector, hex""));
    }

    function testFlashActions(uint256 loanAmount) public {
        loanAmount = bound(loanAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 creditLine;
        (creditLine, loanAmount,) = _boundHealthyPosition(0, loanAmount, oracle.price());

        oracle.setPrice(ORACLE_PRICE_SCALE);

        loanToken.setBalance(address(this), loanAmount);
        morpho.supply(marketParams, loanAmount, 0, address(this), hex"");

        // Set up credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, address(this), creditLine, 0);

        // Borrow directly since we can't use the supplyCollateral callback pattern
        morpho.borrow(marketParams, loanAmount, 0, address(this), address(this));
        assertGt(morpho.borrowShares(marketParams.id(), address(this)), 0, "no borrow");

        // Repay the loan
        loanToken.setBalance(address(this), loanAmount);
        loanToken.approve(address(morpho), loanAmount);
        morpho.repay(marketParams, loanAmount, 0, address(this), hex"");

        // In 3Jane, credit line remains even after full repayment
        assertEq(morpho.collateral(marketParams.id(), address(this)), creditLine, "credit line should remain");
    }
}
