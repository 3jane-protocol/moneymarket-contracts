// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {InsuranceFundMock} from "../../../src/mocks/InsuranceFundMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {Id, MarketParams, Position, Market, IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {ICreditLine} from "../../../src/interfaces/ICreditLine.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";

/// @title SettlementWithFullCoverageTest
/// @notice Regression test for Issue #12: Settlement reverts when debt is fully repaid
/// @dev Demonstrates the bug where CreditLine.settle() fails when insurance covers 100% of debt
///
/// THE BUG:
/// In CreditLine.settle(), when insurance covers the full debt amount:
/// 1. The repay() call clears all borrowShares (reduces them to 0)
/// 2. Then settleAccount() is called, which checks if borrowShares == 0
/// 3. Since borrowShares is 0, settleAccount() reverts with NoAccountToSettle
/// 4. This breaks valid settlement flows where insurance fully covers the debt
///
/// Expected behavior: Settlement should succeed even when insurance covers 100% of debt
/// Current behavior: Settlement reverts with NoAccountToSettle error
///
/// Test results:
/// - testSettlementWithFullInsuranceCoverage: FAILS (demonstrates the bug)
/// - testSettlementWithPartialInsuranceCoverage: PASSES (control test)
/// - testSettledBorrowerCannotBorrowAgain: PASSES (security check)
/// - testDoubleSettlementIsIdempotent: PASSES (idempotency check)
contract SettlementWithFullCoverageTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    CreditLineMock internal creditLine;
    InsuranceFundMock internal insuranceFund;
    ConfigurableIrmMock internal configurableIrm;

    address internal ALICE;
    uint256 constant BORROW_AMOUNT = 10000e18;
    uint256 constant CREDIT_LIMIT = 50000e18;

    function setUp() public override {
        super.setUp();

        ALICE = makeAddr("Alice");

        // Deploy mocks
        creditLine = new CreditLineMock(address(morpho));
        insuranceFund = new InsuranceFundMock();
        configurableIrm = new ConfigurableIrmMock();
        configurableIrm.setApr(0.1e18); // 10% APR

        // Set the owner of creditLine to OWNER for settle calls
        creditLine.setOwner(OWNER);

        // Set insurance fund in credit line
        creditLine.setInsuranceFund(address(insuranceFund));

        // Set credit line in insurance fund
        insuranceFund.setCreditLine(address(creditLine));

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

        // Enable IRM and create market
        vm.startPrank(OWNER);
        morpho.enableIrm(address(configurableIrm));
        morpho.createMarket(marketParams);
        vm.stopPrank();

        // Initialize market cycles to prevent freezing
        _ensureMarketActive(id);

        // Setup liquidity
        deal(address(loanToken), SUPPLIER, 1000000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");

        // Setup credit line for Alice
        vm.startPrank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, CREDIT_LIMIT, 0);
        vm.stopPrank();

        // Setup token approvals
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
    }

    /// @notice Test that demonstrates the bug: settlement fails when insurance fully covers debt
    /// @dev This test should initially FAIL with NoAccountToSettle error
    function testSettlementWithFullInsuranceCoverage() public {
        // Step 1: Alice borrows
        deal(address(loanToken), ALICE, BORROW_AMOUNT);
        vm.prank(ALICE);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, ALICE, ALICE);

        // Verify Alice has debt
        Position memory posBeforeBorrower = morpho.position(id, ALICE);
        assertTrue(posBeforeBorrower.borrowShares > 0, "Alice should have borrow shares");
        assertEq(posBeforeBorrower.collateral, CREDIT_LIMIT, "Alice should have credit limit set");

        // Step 2: Fund the insurance with enough to cover full debt
        uint256 debtAmount = morpho.expectedBorrowAssets(marketParams, ALICE);
        deal(address(loanToken), address(insuranceFund), debtAmount);

        // Step 3: Settle with full insurance coverage
        // THIS SHOULD SUCCEED BUT CURRENTLY FAILS
        // The bug: When cover == debt, repay clears all borrowShares,
        // then settleAccount reverts with NoAccountToSettle
        vm.prank(OWNER);
        (uint256 writtenOffAssets, uint256 writtenOffShares) = creditLine.settle(
            marketParams,
            ALICE,
            debtAmount, // assets to settle
            debtAmount // insurance covers 100%
        );

        // Verify settlement succeeded
        assertEq(writtenOffAssets, 0, "No assets should be written off (insurance covered all)");
        assertEq(writtenOffShares, 0, "No shares should be written off (insurance covered all)");

        // Step 4: Verify all state is cleared
        Position memory posAfter = morpho.position(id, ALICE);
        assertEq(posAfter.borrowShares, 0, "Borrow shares should be cleared");
        assertEq(posAfter.collateral, 0, "Credit line should be cleared");

        // Verify borrower premium is cleared
        (uint128 rate, uint128 lastAccrualTime,) = IMorphoCredit(address(morpho)).borrowerPremium(id, ALICE);
        assertEq(rate, 0, "Premium rate should be cleared");
        assertEq(lastAccrualTime, 0, "Premium timestamp should be cleared");

        // Verify repayment obligation is cleared
        (uint128 amountDue,,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertEq(amountDue, 0, "Repayment obligation should be cleared");
    }

    /// @notice Test that settled borrowers cannot borrow again
    /// @dev This ensures that clearing the credit line prevents re-borrowing
    function testSettledBorrowerCannotBorrowAgain() public {
        // Step 1: Alice borrows
        deal(address(loanToken), ALICE, BORROW_AMOUNT);
        vm.prank(ALICE);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, ALICE, ALICE);

        // Step 2: Settle Alice's account (no insurance, full write-off)
        vm.prank(OWNER);
        creditLine.settle(marketParams, ALICE, 0, 0);

        // Step 3: Verify Alice cannot borrow again
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        vm.expectRevert(ErrorsLib.InsufficientCollateral.selector);
        morpho.borrow(marketParams, 1000e18, 0, ALICE, ALICE);

        // Verify credit line is indeed zero
        Position memory pos = morpho.position(id, ALICE);
        assertEq(pos.collateral, 0, "Credit line should remain zero after settlement");
    }

    /// @notice Test that settlement is idempotent (can be called multiple times)
    /// @dev This test works around the current bug by settling directly through MorphoCredit
    function testDoubleSettlementIsIdempotent() public {
        // Step 1: Alice borrows
        deal(address(loanToken), ALICE, BORROW_AMOUNT);
        vm.prank(ALICE);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, ALICE, ALICE);

        // Step 2: First settlement - settle directly through MorphoCredit to bypass the CreditLine bug
        vm.prank(address(creditLine));
        (uint256 writtenOff1Assets, uint256 writtenOff1Shares) =
            IMorphoCredit(address(morpho)).settleAccount(marketParams, ALICE);
        assertTrue(writtenOff1Assets > 0, "First settlement should write off assets");
        assertTrue(writtenOff1Shares > 0, "First settlement should write off shares");

        // Step 3: Second settlement - after our fix, this is idempotent and returns (0,0)
        vm.prank(address(creditLine));
        (uint256 writtenOff2Assets, uint256 writtenOff2Shares) =
            IMorphoCredit(address(morpho)).settleAccount(marketParams, ALICE);
        assertEq(writtenOff2Assets, 0, "Second settlement should write off zero assets");
        assertEq(writtenOff2Shares, 0, "Second settlement should write off zero shares");

        // Verify state is cleared after first settlement and remains cleared
        Position memory pos = morpho.position(id, ALICE);
        assertEq(pos.borrowShares, 0, "Borrow shares should be zero after settlement");
        assertEq(pos.collateral, 0, "Credit line should be zero after settlement");

        // Verify borrower premium remains cleared
        (uint128 rate, uint128 lastAccrualTime,) = IMorphoCredit(address(morpho)).borrowerPremium(id, ALICE);
        assertEq(rate, 0, "Premium rate should remain cleared");
        assertEq(lastAccrualTime, 0, "Premium timestamp should remain cleared");
    }

    /// @notice Test settlement with partial insurance coverage
    function testSettlementWithPartialInsuranceCoverage() public {
        // Step 1: Alice borrows
        deal(address(loanToken), ALICE, BORROW_AMOUNT);
        vm.prank(ALICE);
        morpho.borrow(marketParams, BORROW_AMOUNT, 0, ALICE, ALICE);

        uint256 debtAmount = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 insuranceCover = debtAmount / 2; // 50% coverage

        // Step 2: Fund insurance with partial amount
        deal(address(loanToken), address(insuranceFund), insuranceCover);

        // Step 3: Settle with partial insurance
        vm.prank(OWNER);
        (uint256 writtenOffAssets, uint256 writtenOffShares) =
            creditLine.settle(marketParams, ALICE, debtAmount, insuranceCover);

        // Verify partial write-off
        assertTrue(writtenOffAssets > 0, "Should write off remaining debt");
        assertTrue(writtenOffShares > 0, "Should write off remaining shares");

        // Approximately half the debt should be written off
        assertApproxEqRel(writtenOffAssets, debtAmount - insuranceCover, 0.01e18, "Written off should be ~50% of debt");

        // Verify all state is cleared
        Position memory pos = morpho.position(id, ALICE);
        assertEq(pos.borrowShares, 0, "All borrow shares should be cleared");
        assertEq(pos.collateral, 0, "Credit line should be cleared");
    }
}
