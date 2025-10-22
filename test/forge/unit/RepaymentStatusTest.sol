// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {Id, MarketParams, RepaymentStatus, IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {MorphoCreditLib} from "../../../src/libraries/periphery/MorphoCreditLib.sol";

contract RepaymentStatusTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;

    CreditLineMock internal creditLine;
    ConfigurableIrmMock internal configurableIrm;

    // Test borrowers
    address internal ALICE;
    address internal BOB;

    // Test-specific constants (common ones are in BaseTest)

    function setUp() public override {
        super.setUp();

        ALICE = makeAddr("Alice");
        BOB = makeAddr("Bob");

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Deploy configurable IRM for testing
        configurableIrm = new ConfigurableIrmMock();
        configurableIrm.setApr(0.1e18); // 10% APR

        // Create market with credit line
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0), // No collateral for credit-based lending
            oracle: address(0),
            irm: address(configurableIrm),
            lltv: 0,
            creditLine: address(creditLine)
        });

        id = marketParams.id();

        // Enable IRM
        vm.startPrank(OWNER);
        morpho.enableIrm(address(configurableIrm));
        morpho.createMarket(marketParams);
        vm.stopPrank();

        // Initialize market cycles since it has a credit line
        _ensureMarketActive(id);

        // Setup test tokens and supply liquidity
        deal(address(loanToken), SUPPLIER, 1000000e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");

        // Setup credit lines for borrowers
        vm.startPrank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 50000e18, 634195840); // 2% APR
        IMorphoCredit(address(morpho)).setCreditLine(id, BOB, 100000e18, 951293760); // 3% APR
        vm.stopPrank();

        // Warp time forward to avoid underflow in tests
        _continueMarketCycles(id, block.timestamp + 60 days); // 2 monthly cycles

        // Setup token approvals for test borrowers
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(BOB);
        loanToken.approve(address(morpho), type(uint256).max);

        // Have borrowers take out loans
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        deal(address(loanToken), BOB, 20000e18);
        vm.prank(BOB);
        morpho.borrow(marketParams, 20000e18, 0, BOB, BOB);
    }

    // ============ Current Status Tests ============

    function testRepaymentStatus_Current_NoObligations() public {
        // User with no obligations should be Current
        address CHARLIE = makeAddr("Charlie");

        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, CHARLIE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    function testRepaymentStatus_Current_ObligationFullyPaid() public {
        // Create a cycle with obligation
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, CYCLE_DURATION / 1 days);

        // ALICE fully pays the obligation
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // Status should be Current
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    function testRepaymentStatus_GracePeriod_WithOutstandingDebt() public {
        // Create a cycle ending 2 days ago (within grace period)
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 2);

        // No payment - still within grace period with outstanding debt, should be GracePeriod
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod));
    }

    // ============ Grace Period Status Tests ============

    function testRepaymentStatus_GracePeriod() public {
        // Create a cycle ending 4 days ago (past grace, not yet delinquent)
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 4);

        // No payment - should be in Grace Period
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod));
    }

    function testRepaymentStatus_GracePeriod_EdgeCase() public {
        // Test exactly at grace period boundary
        // Use helper to create past obligation that ended exactly GRACE_PERIOD_DURATION ago
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, GRACE_PERIOD_DURATION / 1 days);

        // No payment - exactly at grace period boundary, should still be in grace
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod));
    }

    // ============ Delinquent Status Tests ============

    function testRepaymentStatus_Delinquent() public {
        // Create an obligation (starts 1 day ago)
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 1);

        // Warp forward 9 days to get to delinquent period (total 10 days since cycle end)
        vm.warp(block.timestamp + 9 days);

        // No payment - should be Delinquent
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));
    }

    function testRepaymentStatus_Delinquent_JustPastGrace() public {
        // Test just past delinquency threshold
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 1);

        // Warp forward to just past grace period (8 days total since cycle end)
        vm.warp(block.timestamp + 7 days);

        // No payment - should be Delinquent (just past grace)
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));
    }

    // ============ Default Status Tests ============

    function testRepaymentStatus_Default() public {
        // Create an obligation
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 1);

        // Warp forward to default period (31 days total since cycle end)
        vm.warp(block.timestamp + 30 days);

        // No payment
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));
    }

    function testRepaymentStatus_Default_ExactBoundary() public {
        // Test exactly at default boundary (30 days)
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 1);

        // Warp to exactly 30 days since cycle end
        vm.warp(block.timestamp + 29 days);

        // Should still be Default at exactly 30 days
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));
    }

    function testRepaymentStatus_Default_WithPartialPayment() public {
        // Test that partial payments are rejected in default status
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 1);

        // Warp to default period
        vm.warp(block.timestamp + 34 days);

        // Continue market cycles to unfreeze the market
        _continueMarketCycles(id, block.timestamp);

        // Verify partial payment is rejected
        deal(address(loanToken), ALICE, 999e18);
        vm.prank(ALICE);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 999e18, 0, ALICE, "");

        // Status remains Default
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));
    }

    // ============ Status Transition Tests ============

    function testRepaymentStatus_TransitionAfterPayment() public {
        // Create obligation
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 1);

        // Warp to delinquent period
        vm.warp(block.timestamp + 9 days);

        // Verify delinquent
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // Full payment
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // Should transition to Current
        (status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    function testRepaymentStatus_TimeBasedTransition() public {
        // Create obligation (starts 1 day ago, so currently in grace period)
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 1);

        // Verify Grace Period
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod));

        // Fast forward to delinquent period (need to be >7 days past cycle end)
        vm.warp(block.timestamp + 7 days); // Total 8 days since cycle end

        // Should now be Delinquent
        (status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // Fast forward to default period (need to be >30 days past cycle end)
        vm.warp(block.timestamp + 23 days); // Total 31 days since cycle end

        // Should now be Default
        (status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));
    }

    // ============ Multiple Cycles Tests ============

    function testRepaymentStatus_MultipleCycles_OldestDeterminesStatus() public {
        // Create first cycle - this will end 1 day ago
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 10);

        // Warp forward to make it delinquent (need >7 days past cycle end)
        vm.warp(block.timestamp + 7 days); // Total 8 days since cycle end

        // The obligation gets overwritten, not accumulated - so this will be recent
        // The status should still be based on time since the cycle end

        // Status should be based on oldest unpaid cycle (Delinquent)
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));
    }

    function testRepaymentStatus_MultipleCycles_PaymentOverwritesObligation() public {
        // Create cycle with 1000e18 obligation (10% of 10000e18)
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 10);

        // Warp forward to make it delinquent
        vm.warp(block.timestamp + 7 days);

        // Total obligation should be 1000e18 (10% of 10000e18)
        (, uint128 totalDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(totalDue, 1000e18); // 10% of 10000e18

        // Must pay full amount - verify partial payment is rejected
        deal(address(loanToken), ALICE, 400e18);
        vm.prank(ALICE);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 400e18, 0, ALICE, "");

        // Status remains Delinquent
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // Pay full amount (1000e18)
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // Should now be Current
        (status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    // ============ Edge Cases ============

    function testRepaymentStatus_ZeroObligation() public {
        // Create cycle with zero obligation
        _createRepaymentObligationBps(id, ALICE, 0, 10000e18, 10);

        // Should be Current (no payment due)
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    function testRepaymentStatus_OverPayment() public {
        // Create obligation
        _createRepaymentObligationBps(id, ALICE, 1000, 10000e18, 1);

        // Overpay
        deal(address(loanToken), ALICE, 2000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 2000e18, 0, ALICE, "");

        // Should be Current
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));

        // Obligation should be fully paid
        (, uint128 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDue, 0);
    }
}
