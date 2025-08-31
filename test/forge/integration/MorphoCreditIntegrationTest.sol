// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {CreditLine} from "../../../src/CreditLine.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";

contract MorphoCreditIntegrationTest is BaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    CreditLine public creditLine;

    function setUp() public override {
        super.setUp();

        // Deploy CreditLine contract
        creditLine = new CreditLine(address(morpho), address(this), address(1), address(1), address(1));

        // Create market with creditLine
        marketParams.creditLine = address(creditLine);
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
    }

    /*//////////////////////////////////////////////////////////////
                    MARKET AND AUTHORIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetCreditLineMarketNotCreated(MarketParams memory marketParamsFuzz, uint256 credit) public {
        vm.assume(neq(marketParamsFuzz, marketParams));
        vm.assume(!_isProxyRelatedAddress(marketParamsFuzz.creditLine));
        credit = bound(credit, 1, MAX_TEST_AMOUNT);

        vm.prank(marketParamsFuzz.creditLine);
        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        IMorphoCredit(address(morpho)).setCreditLine(marketParamsFuzz.id(), BORROWER, credit, 0);
    }

    function testSetCreditLineUnauthorized(address attacker, uint256 credit) public {
        vm.assume(attacker != marketParams.creditLine);
        vm.assume(!_isProxyRelatedAddress(attacker));
        credit = bound(credit, 1, MAX_TEST_AMOUNT);

        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.NotCreditLine.selector);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, credit, 0);
    }

    function testSetCreditLineZeroBorrower(uint256 credit) public {
        credit = bound(credit, 1, MAX_TEST_AMOUNT);

        vm.prank(marketParams.creditLine);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        IMorphoCredit(address(morpho)).setCreditLine(id, address(0), credit, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    CREDIT LINE MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetCreditLine(uint256 credit) public {
        credit = bound(credit, 1, MAX_TEST_AMOUNT);

        vm.prank(marketParams.creditLine);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetCreditLine(id, BORROWER, credit);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, credit, 0);

        assertEq(morpho.collateral(id, BORROWER), credit, "credit line not set correctly");
    }

    function testIncreaseCreditLine(uint256 initialCredit, uint256 additionalCredit) public {
        initialCredit = bound(initialCredit, 1, MAX_TEST_AMOUNT / 2);
        additionalCredit = bound(additionalCredit, 1, MAX_TEST_AMOUNT / 2);
        uint256 newCredit = initialCredit + additionalCredit;

        // Set initial credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, initialCredit, 0);

        // Increase credit line
        vm.prank(marketParams.creditLine);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetCreditLine(id, BORROWER, newCredit);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, newCredit, 0);

        assertEq(morpho.collateral(id, BORROWER), newCredit, "credit line not increased correctly");
    }

    function testDecreaseCreditLine(uint256 initialCredit, uint256 reductionAmount) public {
        initialCredit = bound(initialCredit, 2, MAX_TEST_AMOUNT);
        reductionAmount = bound(reductionAmount, 1, initialCredit - 1);
        uint256 newCredit = initialCredit - reductionAmount;

        // Set initial credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, initialCredit, 0);

        // Decrease credit line
        vm.prank(marketParams.creditLine);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetCreditLine(id, BORROWER, newCredit);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, newCredit, 0);

        assertEq(morpho.collateral(id, BORROWER), newCredit, "credit line not decreased correctly");
    }

    function testSetCreditLineWithPremiumRate(uint256 credit) public {
        credit = bound(credit, 1, MAX_TEST_AMOUNT);
        uint128 premiumRate = uint128(uint256(0.05e18) / 365 days); // 5% APR

        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, credit, premiumRate);

        assertEq(morpho.collateral(id, BORROWER), credit, "credit line not set correctly");

        // Verify premium rate was set
        (uint128 lastAccrualTime, uint128 rate,) = IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertEq(rate, premiumRate, "premium rate not set correctly");
        // With Issue #13 fix: timestamp is NOT set until first borrow
        assertEq(lastAccrualTime, 0, "timestamp should not be set until first borrow");
    }

    function testRemoveCreditLine(uint256 initialCredit) public {
        initialCredit = bound(initialCredit, 1, MAX_TEST_AMOUNT);

        // Set initial credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, initialCredit, 0);

        // Remove credit line (set to zero)
        vm.prank(marketParams.creditLine);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetCreditLine(id, BORROWER, 0);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 0, 0);

        assertEq(morpho.collateral(id, BORROWER), 0, "credit line not removed");
    }

    /*//////////////////////////////////////////////////////////////
                    INTEGRATION WITH BORROWING TESTS
    //////////////////////////////////////////////////////////////*/

    function testBorrowWithinCreditLine(uint256 credit, uint256 borrowAmount) public {
        credit = bound(credit, 1, MAX_TEST_AMOUNT);
        borrowAmount = bound(borrowAmount, 1, credit);

        // Supply to market
        _supply(credit);

        // Set credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, credit, 0);

        // Borrow within credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Verify position
        Position memory pos = morpho.position(id, BORROWER);
        assertEq(pos.collateral, credit, "credit line should remain unchanged");
        assertGt(pos.borrowShares, 0, "borrow shares should be positive");
    }

    function testBorrowExceedsCreditLine(uint256 credit, uint256 excessAmount) public {
        credit = bound(credit, 1, MAX_TEST_AMOUNT - 1);
        excessAmount = bound(excessAmount, 1, MAX_TEST_AMOUNT - credit);
        uint256 borrowAmount = credit + excessAmount;

        // Supply to market
        _supply(borrowAmount);

        // Set credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, credit, 0);

        // Try to borrow more than credit line
        vm.prank(BORROWER);
        vm.expectRevert(ErrorsLib.InsufficientCollateral.selector);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);
    }

    function testCreditUtilizationTracking(uint256 credit, uint256 borrowAmount) public {
        credit = bound(credit, 2, MAX_TEST_AMOUNT);
        borrowAmount = bound(borrowAmount, 1, credit / 2);

        // Supply to market
        _supply(credit);

        // Set credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, credit, 0);

        // Borrow partial amount
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Credit line should remain unchanged
        assertEq(morpho.collateral(id, BORROWER), credit, "credit line should not change after borrowing");

        // Available credit is credit - borrowed
        Position memory pos = morpho.position(id, BORROWER);
        Market memory mkt = morpho.market(id);
        uint256 borrowedAmount = uint256(pos.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        uint256 availableCredit = credit - borrowedAmount;

        // Should be able to borrow up to available credit
        vm.prank(BORROWER);
        morpho.borrow(marketParams, availableCredit, 0, BORROWER, BORROWER);
    }

    /*//////////////////////////////////////////////////////////////
                    HEALTH CHECK TESTS
    //////////////////////////////////////////////////////////////*/

    function testHealthyPositionWithCredit(uint256 credit, uint256 borrowAmount) public {
        credit = bound(credit, 1, MAX_TEST_AMOUNT);
        borrowAmount = bound(borrowAmount, 1, credit);

        // Supply to market
        _supply(credit);

        // Set credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, credit, 0);

        // Borrow within limit
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Position should be healthy
        assertTrue(_isHealthy(marketParams, id, BORROWER), "position should be healthy");
    }

    function testUnhealthyPositionPreventsCredit(uint256 initialCredit, uint256 borrowAmount) public {
        initialCredit = bound(initialCredit, 2, MAX_TEST_AMOUNT);
        borrowAmount = bound(borrowAmount, initialCredit / 2, initialCredit);

        // Supply to market
        _supply(initialCredit);

        // Set initial credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, initialCredit, 0);

        // Borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Try to reduce credit below borrowed amount - should succeed but make position unhealthy
        uint256 newCredit = borrowAmount - 1;
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, newCredit, 0);

        // Position should now be unhealthy
        assertFalse(_isHealthy(marketParams, id, BORROWER), "position should be unhealthy");
    }

    function testCreditLineAdjustmentWithActiveLoan(uint256 initialCredit, uint256 borrowAmount, uint256 adjustment)
        public
    {
        initialCredit = bound(initialCredit, 10, MAX_TEST_AMOUNT / 2);
        borrowAmount = bound(borrowAmount, 1, initialCredit / 2);
        adjustment = bound(adjustment, 1, initialCredit / 4);

        // Supply to market
        _supply(initialCredit * 2);

        // Set initial credit line
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, initialCredit, 0);

        // Borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Increase credit line
        uint256 increasedCredit = initialCredit + adjustment;
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, increasedCredit, 0);
        assertEq(morpho.collateral(id, BORROWER), increasedCredit, "credit should be increased");

        // Decrease credit line (but still above borrowed amount)
        uint256 decreasedCredit = borrowAmount + adjustment;
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, decreasedCredit, 0);
        assertEq(morpho.collateral(id, BORROWER), decreasedCredit, "credit should be decreased");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASES AND SECURITY TESTS
    //////////////////////////////////////////////////////////////*/

    function testMultipleCreditLineUpdates() public {
        uint256[5] memory credits = [uint256(1000e18), 2000e18, 1500e18, 3000e18, 0];

        for (uint256 i = 0; i < credits.length; i++) {
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, credits[i], 0);
            assertEq(morpho.collateral(id, BORROWER), credits[i], "credit line mismatch");
        }
    }

    function testCreditLineWithMaxValues() public {
        uint128 maxCredit = type(uint128).max;

        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, maxCredit, 0);
        assertEq(morpho.collateral(id, BORROWER), maxCredit, "max credit line not set");
    }

    function testConcurrentCreditOperations() public {
        uint256 credit1 = 1000e18;
        uint256 credit2 = 2000e18;
        uint256 credit3 = 1500e18;

        address borrower2 = makeAddr("borrower2");
        address borrower3 = makeAddr("borrower3");

        // Set multiple credit lines in same block
        vm.startPrank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, credit1, 0);
        IMorphoCredit(address(morpho)).setCreditLine(id, borrower2, credit2, 0);
        IMorphoCredit(address(morpho)).setCreditLine(id, borrower3, credit3, 0);
        vm.stopPrank();

        // Verify all credit lines
        assertEq(morpho.collateral(id, BORROWER), credit1, "borrower1 credit incorrect");
        assertEq(morpho.collateral(id, borrower2), credit2, "borrower2 credit incorrect");
        assertEq(morpho.collateral(id, borrower3), credit3, "borrower3 credit incorrect");
    }

    /*//////////////////////////////////////////////////////////////
                    HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setupCreditLine(address borrower, uint256 credit) internal {
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, borrower, credit, 0);
    }

    function _setupCreditLineWithPremium(address borrower, uint256 credit, uint128 premium) internal {
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, borrower, credit, premium);
    }

    function _assertCreditUtilization(Id marketId, address borrower, uint256 expectedCredit, uint256 expectedUtilized)
        internal
    {
        Position memory pos = morpho.position(marketId, borrower);
        Market memory mkt = morpho.market(marketId);

        assertEq(pos.collateral, expectedCredit, "credit line mismatch");

        uint256 actualUtilized = uint256(pos.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        assertApproxEqAbs(actualUtilized, expectedUtilized, 1, "utilization mismatch");
    }

    function _isHealthy(MarketParams memory params, Id marketId, address borrower) internal view returns (bool) {
        Position memory pos = morpho.position(marketId, borrower);
        if (pos.borrowShares == 0) return true;

        Market memory mkt = morpho.market(marketId);
        uint256 borrowed = uint256(pos.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        uint256 creditLimit = pos.collateral;

        return creditLimit >= borrowed;
    }
}
