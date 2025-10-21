// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {Id, MarketParams, RepaymentStatus, IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";

contract RepaymentTrackingIntegrationTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    CreditLineMock internal creditLine;
    ConfigurableIrmMock internal configurableIrm;

    // Test borrowers
    address internal ALICE;
    address internal BOB;
    address internal CHARLIE;

    // Test-specific constants (common ones are in BaseTest)

    function setUp() public override {
        super.setUp();

        ALICE = makeAddr("Alice");
        BOB = makeAddr("Bob");
        CHARLIE = makeAddr("Charlie");

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Deploy configurable IRM
        configurableIrm = new ConfigurableIrmMock();
        configurableIrm.setApr(0.1e18); // 10% APR

        // Create market with credit line
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0),
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

        // Initialize first cycle to unfreeze the market
        _ensureMarketActive(id);

        // Setup liquidity
        deal(address(loanToken), SUPPLIER, 1000000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");

        // Setup credit lines
        vm.startPrank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 50000e18, 634195840); // 2% premium
        IMorphoCredit(address(morpho)).setCreditLine(id, BOB, 100000e18, 951293759); // 3% premium
        IMorphoCredit(address(morpho)).setCreditLine(id, CHARLIE, 75000e18, 317097920); // 1% premium
        vm.stopPrank();

        // Warp time forward to avoid underflow in tests
        _continueMarketCycles(id, block.timestamp + 60 days); // 2 monthly cycles

        // Setup token approvals for test borrowers
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(BOB);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(CHARLIE);
        loanToken.approve(address(morpho), type(uint256).max);
    }

    // ============ Full Cycle Flow Tests ============

    function testFullCycleFlow_SingleBorrower() public {
        // 1. Alice borrows
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        uint256 initialBorrowAssets = morpho.expectedBorrowAssets(marketParams, ALICE);

        // 2. Create obligation using helper to ensure proper cycle management
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10% monthly payment
        balances[0] = initialBorrowAssets; // Current balance

        _createMultipleObligations(id, borrowers, repaymentBps, balances, 0);

        // 4. Verify borrowing is blocked
        vm.expectRevert(ErrorsLib.OutstandingRepayment.selector);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 1000e18, 0, ALICE, ALICE);

        // 5. Alice makes payment
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // 6. Verify status is current
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));

        // 7. Verify borrowing is allowed again
        deal(address(loanToken), ALICE, 5000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 5000e18, 0, ALICE, ALICE);
    }

    function testFullCycleFlow_MultipleBorrowers() public {
        // 1. Multiple borrowers take loans
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        deal(address(loanToken), BOB, 20000e18);
        vm.prank(BOB);
        morpho.borrow(marketParams, 20000e18, 0, BOB, BOB);

        deal(address(loanToken), CHARLIE, 15000e18);
        vm.prank(CHARLIE);
        morpho.borrow(marketParams, 15000e18, 0, CHARLIE, CHARLIE);

        // 2. Post obligations for all borrowers using helper
        address[] memory borrowers = new address[](3);
        uint256[] memory repaymentBps = new uint256[](3);
        uint256[] memory balances = new uint256[](3);

        borrowers[0] = ALICE;
        borrowers[1] = BOB;
        borrowers[2] = CHARLIE;
        repaymentBps[0] = 1000; // 10%
        repaymentBps[1] = 1000; // 10%
        repaymentBps[2] = 1000; // 10%
        balances[0] = 10000e18;
        balances[1] = 20000e18;
        balances[2] = 15000e18;

        _createMultipleObligations(id, borrowers, repaymentBps, balances, 0);

        // 4. Verify all borrowers are blocked from borrowing
        vm.expectRevert(ErrorsLib.OutstandingRepayment.selector);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 100e18, 0, ALICE, ALICE);

        vm.expectRevert(ErrorsLib.OutstandingRepayment.selector);
        vm.prank(BOB);
        morpho.borrow(marketParams, 100e18, 0, BOB, BOB);

        // 5. Alice pays in full, Bob attempts partial payment
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // Bob's partial payment is rejected
        deal(address(loanToken), BOB, 1000e18);
        vm.prank(BOB);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 1000e18, 0, BOB, "");

        // 6. Alice can borrow, Bob cannot
        deal(address(loanToken), ALICE, 500e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 500e18, 0, ALICE, ALICE); // Should succeed

        vm.expectRevert(ErrorsLib.OutstandingRepayment.selector);
        vm.prank(BOB);
        morpho.borrow(marketParams, 500e18, 0, BOB, BOB); // Should fail
    }

    // ============ Delinquency Flow Tests ============

    function testDelinquencyFlow_WithPenaltyAccrual() public {
        // 1. Setup: Alice borrows
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // 2. Create obligation (use helper to ensure proper cycle management)
        _createPastObligation(ALICE, 1000, 10000e18); // 10% of 10000e18

        // Warp forward to delinquent period (need >7 days past cycle end)
        vm.warp(block.timestamp + 7 days); // Total 8 days since cycle end

        // 3. Verify status is delinquent
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // 4. Record borrow assets before penalty accrual
        uint256 borrowAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // 5. Advance time and trigger penalty accrual
        _continueMarketCycles(id, block.timestamp + 5 days);
        vm.prank(ALICE);
        _triggerAccrual(); // Trigger market-wide accrual

        // 6. Verify penalty was accrued
        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        assertGt(borrowAssetsAfter, borrowAssetsBefore);

        // 7. Verify partial payment is rejected
        deal(address(loanToken), ALICE, 500e18);
        vm.prank(ALICE);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 500e18, 0, ALICE, "");

        // 8. Status should still be delinquent
        (status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));

        // 9. Pay full obligation amount
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // 10. Status should be current
        (status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    // ============ Multiple Cycle Tests ============

    function testMultipleCycles_OverwritingObligations() public {
        // Setup: Alice borrows
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Cycle 1 - use helper for proper cycle management
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10%
        balances[0] = 10000e18;

        _createMultipleObligations(id, borrowers, repaymentBps, balances, 0);

        // Alice doesn't pay cycle 1
        // Warp forward to be in default for the first cycle
        vm.warp(block.timestamp + 30 days); // Move to default period

        // Cycle 2 - create another obligation
        repaymentBps[0] = 1000; // 10% (higher amount due to higher balance)
        balances[0] = 11000e18; // Balance grew

        _createMultipleObligations(id, borrowers, repaymentBps, balances, 0);

        // Check total obligation (now overwritten, not accumulated)
        (, uint128 totalDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(totalDue, 1100e18); // Only the latest amount

        // Status should be based on oldest cycle (now in default)
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));

        // Verify partial payment is rejected
        deal(address(loanToken), ALICE, 500e18);
        vm.prank(ALICE);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 500e18, 0, ALICE, "");

        // Pay full obligation
        deal(address(loanToken), ALICE, 1100e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1100e18, 0, ALICE, "");

        // Should be current now
        (status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));
    }

    // ============ Edge Case Tests ============

    function testRepaymentTracking_ZeroAmountOperations() public {
        // Setup obligation
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create an obligation that will be delinquent (past grace period)
        _createPastObligation(ALICE, 1000, 10000e18); // 10% of 10000e18

        // Cannot make tiny repayments when obligation exists
        _continueMarketCycles(id, block.timestamp + 1 days);

        // Verify tiny repayment is rejected
        deal(address(loanToken), ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 1, 0, ALICE, "");

        // Can trigger accrual through accruePremiumsForBorrowers (since we're past grace period)
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(ALICE));

        // Premium should have accrued
        (uint128 lastAccrualTime,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, ALICE);
        assertEq(lastAccrualTime, block.timestamp);
    }

    function testRepaymentTracking_ExcessPayment() public {
        // Setup
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create an obligation using helper to ensure proper cycle management
        _createPastObligation(ALICE, 1000, 10000e18); // 10% of 10000e18

        // Pay more than obligation
        deal(address(loanToken), ALICE, 2000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 2000e18, 0, ALICE, "");

        // Obligation should be fully paid
        (, uint128 amountDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDue, 0);

        // Status should be current
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Current));

        // Actual debt should be reduced by full 2000
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, ALICE);
        // Since interest has accrued during the test, the debt won't be exactly 8000e18
        // After paying 2000e18 on a 10000e18 debt, we should have ~8000e18 + some interest
        // The actual debt should be less than 8200e18 accounting for reasonable interest accrual
        assertLt(borrowAssets, 8200e18); // ~8000 + reasonable interest
    }

    function testRepaymentTracking_RapidCycles() public {
        // Test handling of multiple cycles in quick succession
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);
        borrowers[0] = ALICE;

        // Create 3 cycles with proper spacing using helper
        for (uint256 i = 0; i < 3; i++) {
            repaymentBps[0] = 300 + (i * 100); // 3%, 4%, 5%
            balances[0] = 10000e18 + (i * 1000e18); // Growing balance

            _createMultipleObligations(id, borrowers, repaymentBps, balances, 0);

            // Warp forward for next cycle if not the last iteration
            if (i < 2) {
                vm.warp(block.timestamp + CYCLE_DURATION);
            }
        }

        // Total obligation should be overwritten to latest
        (, uint128 totalDue,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(totalDue, 600e18); // Only the latest amount (5% of 12000e18)

        // Latest cycle ID should be correct after properly spaced cycles
        uint256 paymentCycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        assertGe(paymentCycleLength, 3); // At least 3 cycles created
    }

    // ============ Critical Edge Case Tests ============

    function testClearingDelinquencyWithZeroAmount() public {
        // This test verifies that a malicious or faulty creditLine contract
        // can clear a borrower's delinquency by posting a zero-amount obligation

        // Step 1: Alice borrows
        deal(address(loanToken), ALICE, 20000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 20000e18, 0, ALICE, ALICE);

        // Step 2: Create an obligation that makes Alice delinquent
        _createPastObligation(ALICE, 2500, 20000e18); // 25% of 20000e18

        // Warp forward to delinquent period (need >7 days past cycle end)
        vm.warp(block.timestamp + 7 days); // Total 8 days since cycle end

        // Verify Alice is delinquent with a non-zero obligation
        (RepaymentStatus statusBefore,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(statusBefore), uint256(RepaymentStatus.Delinquent), "Should be delinquent");

        (, uint128 amountDueBefore,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDueBefore, 5000e18, "Should have 5000e18 obligation");

        // Verify Alice cannot borrow while delinquent
        vm.expectRevert(ErrorsLib.OutstandingRepayment.selector);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 1000e18, 0, ALICE, ALICE);

        // Step 3: CreditLine posts a new cycle with 0 bps for Alice
        // Use helper to create a new cycle with proper spacing
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 0; // Zero bps - this overwrites the existing obligation!
        balances[0] = 21000e18; // New balance (doesn't matter for this test)

        // Use _createMultipleObligations helper to handle cycle creation properly
        _createMultipleObligations(id, borrowers, repaymentBps, balances, 0);

        // Step 4: Verify the exploit worked
        (, uint128 amountDueAfter,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDueAfter, 0, "Obligation should be cleared to zero");

        (RepaymentStatus statusAfter,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(statusAfter), uint256(RepaymentStatus.Current), "Should be current after zero obligation");

        // Step 5: Verify Alice can now borrow again (without paying the original 5000e18!)
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 1000e18, 0, ALICE, ALICE); // This should succeed

        // The test confirms that the creditLine can effectively forgive debt by posting zero
        emit log_string("WARNING: CreditLine can clear delinquent obligations with zero amount!");
        emit log_named_uint("Original obligation cleared", 5000e18);
    }
}
