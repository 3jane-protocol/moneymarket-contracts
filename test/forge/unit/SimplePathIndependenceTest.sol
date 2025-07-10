// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseTest} from "../BaseTest.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {
    Id,
    MarketParams,
    Position,
    Market,
    IMorphoCredit,
    RepaymentStatus,
    RepaymentObligation
} from "../../../src/interfaces/IMorpho.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";

contract SimplePathIndependenceTest is BaseTest {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;

    address internal creditLine;

    function setUp() public override {
        super.setUp();

        // Deploy a mock credit line contract
        creditLine = makeAddr("CreditLine");

        // Create credit line market
        marketParams = MarketParams(
            address(loanToken),
            address(0), // No collateral for credit line
            address(0), // No oracle needed
            address(irm),
            0, // No LLTV
            creditLine // Credit line address
        );
        id = marketParams.id();

        vm.prank(OWNER);
        morpho.createMarket(marketParams);

        // Supply assets
        loanToken.setBalance(SUPPLIER, 1_000_000e18);
        vm.startPrank(SUPPLIER);
        morpho.supply(marketParams, 1_000_000e18, 0, SUPPLIER, new bytes(0));
        vm.stopPrank();

        // Set credit line for borrower (must be called by creditLine address)
        vm.prank(creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 100_000e18, uint128(PREMIUM_RATE_PER_SECOND));

        // Borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 10_000e18, 0, BORROWER, BORROWER);
    }

    function testBasicGracePeriodDeferral() public {
        // Advance time
        vm.warp(block.timestamp + 30 days);

        // Create an obligation that just ended (in grace period)
        _createRepaymentObligation(id, BORROWER, 5000e18, 10_000e18, 1);

        // Check status - should be in grace period
        RepaymentStatus status = IMorphoCredit(address(morpho)).getRepaymentStatus(id, BORROWER);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod), "Should be in grace period");

        // Get initial borrow shares
        uint256 sharesBefore = morpho.position(id, BORROWER).borrowShares;

        // Trigger accrual (should skip during grace period)
        vm.prank(BORROWER);
        morpho.accrueInterest(marketParams);

        // Shares should not change during grace period
        uint256 sharesAfter = morpho.position(id, BORROWER).borrowShares;
        assertEq(sharesAfter, sharesBefore, "Shares should not change during grace period");
    }

    function testMinimumRepaymentRequirement() public {
        // Advance time
        vm.warp(block.timestamp + 30 days);

        // Create an obligation
        _createRepaymentObligation(id, BORROWER, 5000e18, 10_000e18, 1);

        // Try to make partial payment (should fail)
        loanToken.setBalance(BORROWER, 3000e18);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), 3000e18);

        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 3000e18, 0, BORROWER, new bytes(0));

        // Full payment should succeed
        loanToken.setBalance(BORROWER, 5000e18);
        loanToken.approve(address(morpho), 5000e18);
        morpho.repay(marketParams, 5000e18, 0, BORROWER, new bytes(0));
        vm.stopPrank();

        // Verify obligation is cleared
        (, uint256 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        assertEq(amountDue, 0, "Obligation not cleared");
    }
}
