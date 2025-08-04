// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseTest} from "../BaseTest.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {SimpleCreditLineMock} from "../mocks/SimpleCreditLineMock.sol";
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
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";

contract PathIndependentPenaltyTest is BaseTest {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    SimpleCreditLineMock internal creditLine;

    function setUp() public override {
        super.setUp();

        // Deploy a mock credit line contract
        creditLine = new SimpleCreditLineMock();

        // Create credit line market
        marketParams = MarketParams(
            address(loanToken),
            address(0), // No collateral for credit line
            address(0), // No oracle needed
            address(irm),
            0, // No LLTV
            address(creditLine) // Credit line address
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
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 100_000e18, uint128(PREMIUM_RATE_PER_SECOND));

        // Borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 10_000e18, 0, BORROWER, BORROWER);

        // Move time forward to avoid any edge cases
        vm.warp(block.timestamp + 100 days);
    }

    function testPathIndependence_GracePeriodDeferral() public {
        // Test Scenario A: Touch contract during grace period
        // Record initial state (not needed for this test but removing unused variable)

        // Create an obligation that ended 3 days ago (still in grace period)
        _createRepaymentObligation(id, BORROWER, 5000e18, 10_000e18, 3);

        // Touch the contract (should defer premium calculation)
        vm.prank(BORROWER);
        morpho.accrueInterest(marketParams);

        // Move to after grace period
        vm.warp(block.timestamp + 5 days); // Now 8 days after cycle end

        // Get final debt for Path A by calculating it directly
        uint256 pathADebt = _calculateBorrowerDebt(id, BORROWER);

        // Test Scenario B: No touch during grace period
        setUp(); // Reset

        // Create same obligation
        _createRepaymentObligation(id, BORROWER, 5000e18, 10_000e18, 3);

        // Move directly to after grace period without touching
        vm.warp(block.timestamp + 5 days); // Now 8 days after cycle end

        // Get final debt for Path B by calculating it directly
        uint256 pathBDebt = _calculateBorrowerDebt(id, BORROWER);

        // Both paths should yield the same result
        assertApproxEqRel(pathADebt, pathBDebt, 1e12, "Path independence violated");
    }

    function testMinimumRepaymentRequirement() public {
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

    function testPenaltyCompoundsAfterGracePeriod() public {
        // Create an obligation that ended more than 7 days ago (past grace period)
        _createRepaymentObligation(id, BORROWER, 5000e18, 10_000e18, 8); // 8 days ago = 1 day past grace period

        // Record debt at this point - penalty should already be active
        uint256 debtAtStart = _calculateBorrowerDebt(id, BORROWER);

        // Move forward in time
        vm.warp(block.timestamp + 7 days); // Now 8 days past grace period

        uint256 debtAfterWeek = _calculateBorrowerDebt(id, BORROWER);

        // Verify penalty is compounding
        uint256 increase = debtAfterWeek - debtAtStart;

        // The increase should be meaningful
        // With 10% APR penalty + 10% base + 2% premium = 22% total APR
        // Over 7 days that's roughly 0.42% growth
        // We'll check for at least 0.2% to be conservative
        uint256 minExpectedIncrease = debtAtStart * 2 / 1000; // 0.2%

        assertGt(increase, minExpectedIncrease, "Penalty not properly compounding");
    }

    // Helper function to calculate borrower's total debt including premiums
    function _calculateBorrowerDebt(Id _id, address borrower) internal returns (uint256) {
        // First accrue interest and premiums
        IMorphoCredit(address(morpho)).accrueBorrowerPremium(_id, borrower);

        // Get the market state
        Market memory m = morpho.market(_id);
        Position memory pos = morpho.position(_id, borrower);

        // Convert shares to assets
        if (pos.borrowShares == 0) return 0;
        return uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }
}
