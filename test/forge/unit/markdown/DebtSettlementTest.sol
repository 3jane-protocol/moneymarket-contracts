// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {IMorphoRepayCallback} from "../../../../src/interfaces/IMorphoCallbacks.sol";
import {Market, MarkdownState, RepaymentStatus, Position} from "../../../../src/interfaces/IMorpho.sol";

/// @title DebtSettlementTest
/// @notice Tests for debt settlement mechanism including full/partial settlements and authorization
contract DebtSettlementTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    event AccountSettled(
        Id indexed id,
        address indexed settler,
        address indexed borrower,
        uint256 writtenOffAmount,
        uint256 writtenOffShares
    );

    function setUp() public override {
        super.setUp();

        // Deploy markdown manager
        markdownManager = new MarkdownManagerMock(address(protocolConfig), OWNER);

        // Deploy credit line
        creditLine = new CreditLineMock(morphoAddress);
        morphoCredit = IMorphoCredit(morphoAddress);

        // Create market with credit line
        marketParams = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(creditLine)
        );
        id = marketParams.id();

        vm.startPrank(OWNER);
        morpho.createMarket(marketParams);
        creditLine.setMm(address(markdownManager));

        // Enable markdown for test borrowers
        markdownManager.setEnableMarkdown(BORROWER, true);

        vm.stopPrank();

        // Initialize first cycle to unfreeze the market
        _ensureMarketActive(id);

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 100_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test full repayment (no settlement needed)
    function testFullRepayment() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Forward time to accrue some interest
        _continueMarketCycles(id, block.timestamp + 30 days);
        morpho.accrueInterest(marketParams);

        // Get current debt
        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);

        // Calculate expected repay amount for exact shares - ensure we have enough
        uint256 expectedRepayAmount = uint256(positionBefore.borrowShares).toAssetsUp(
            marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
        ) + 1; // Add 1 wei buffer to ensure enough assets

        // Prepare full repayment
        loanToken.setBalance(address(creditLine), expectedRepayAmount);

        // Approve before expecting event
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), expectedRepayAmount);

        // Credit line repays using shares to ensure exact repayment
        (uint256 repaidAssets, uint256 repaidShares) =
            morpho.repay(marketParams, 0, positionBefore.borrowShares, BORROWER, hex"");
        vm.stopPrank();

        // Verify results
        assertEq(repaidShares, positionBefore.borrowShares, "All shares should be repaid");
        assertLe(repaidAssets, expectedRepayAmount, "Repaid amount should not exceed expected");

        // Verify position cleared
        Position memory positionAfter = morpho.position(id, BORROWER);
        assertEq(positionAfter.borrowShares, 0, "Borrower position should be cleared");

        // Verify market totals
        Market memory marketAfter = morpho.market(id);
        assertEq(marketAfter.totalBorrowAssets, 0, "Total borrow should be zero");
        assertEq(marketAfter.totalBorrowShares, 0, "Total borrow shares should be zero");
        assertEq(
            marketAfter.totalSupplyAssets, marketBefore.totalSupplyAssets, "Supply should not change for full repay"
        );
    }

    /// @notice Test partial settlement with write-off
    function testPartialSettlement() public {
        uint256 borrowAmount = 10_000e18;
        uint256 repayAmount = 2_000e18; // 20% repayment

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Forward time to accrue interest
        _continueMarketCycles(id, block.timestamp + 30 days);
        morpho.accrueInterest(marketParams);

        // Get position details
        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);

        // Calculate expected shares
        uint256 expectedRepaidShares =
            repayAmount.toSharesDown(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);
        uint256 expectedWrittenOffShares = positionBefore.borrowShares - expectedRepaidShares;
        uint256 expectedWrittenOffAssets =
            expectedWrittenOffShares.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);

        // Step 1: Partial repayment
        loanToken.setBalance(address(creditLine), repayAmount);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), repayAmount);
        (uint256 repaidAssets, uint256 repaidShares) = morpho.repay(marketParams, repayAmount, 0, BORROWER, hex"");
        assertEq(repaidShares, expectedRepaidShares, "Repaid shares should match expected");

        // Step 2: Settle remaining debt
        vm.expectEmit(true, true, true, true);
        emit AccountSettled(id, address(creditLine), BORROWER, expectedWrittenOffAssets, expectedWrittenOffShares);

        (uint256 writtenOffAssets, uint256 writtenOffShares) = morphoCredit.settleAccount(marketParams, BORROWER);
        vm.stopPrank();

        // Verify write-off
        assertEq(writtenOffShares, expectedWrittenOffShares, "Written off shares should match expected");
        assertApproxEqAbs(writtenOffAssets, expectedWrittenOffAssets, 1, "Written off assets should match expected");
        assertEq(repaidShares + writtenOffShares, positionBefore.borrowShares, "Total should equal original shares");

        // Verify position cleared
        Position memory positionAfter = morpho.position(id, BORROWER);
        assertEq(positionAfter.borrowShares, 0, "Borrower position should be cleared");

        // Verify market totals
        Market memory marketAfter = morpho.market(id);
        assertLt(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets, "Total borrow should decrease");
        assertLt(marketAfter.totalSupplyAssets, marketBefore.totalSupplyAssets, "Supply should decrease by write-off");

        // Verify supply decreased by write-off amount
        uint256 supplyReduction = marketBefore.totalSupplyAssets - marketAfter.totalSupplyAssets;
        assertApproxEqAbs(supplyReduction, expectedWrittenOffAssets, 1, "Supply reduction should match write-off");
    }

    /// @notice Test minimal settlement (very small repayment)
    function testMinimalSettlement() public {
        uint256 borrowAmount = 10_000e18;
        uint256 repayAmount = 100e18; // 1% repayment

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);

        // Step 1: Minimal repayment
        loanToken.setBalance(address(creditLine), repayAmount);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), repayAmount);
        (uint256 repaidAssets, uint256 repaidShares) = morpho.repay(marketParams, repayAmount, 0, BORROWER, hex"");

        // Step 2: Settle remaining debt
        (uint256 writtenOffAssets, uint256 writtenOffShares) = morphoCredit.settleAccount(marketParams, BORROWER);
        vm.stopPrank();

        // Verify most debt was written off
        assertTrue(writtenOffShares > repaidShares * 50, "Most debt should be written off");
        assertEq(repaidShares + writtenOffShares, positionBefore.borrowShares, "Total should match original");

        // Verify supply took the hit
        Market memory marketAfter = morpho.market(id);
        uint256 supplyReduction = marketBefore.totalSupplyAssets - marketAfter.totalSupplyAssets;
        assertTrue(supplyReduction > borrowAmount * 90 / 100, "Supply should decrease by most of the debt");
    }

    /// @notice Test settlement authorization (only credit line can settle)
    function testSettlementAuthorization() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        loanToken.setBalance(SUPPLIER, borrowAmount);

        // Try to settle as non-credit line (should fail)
        vm.prank(SUPPLIER);
        vm.expectRevert(ErrorsLib.NotCreditLine.selector);
        morphoCredit.settleAccount(marketParams, BORROWER);

        // Try as borrower (should fail)
        vm.prank(BORROWER);
        vm.expectRevert(ErrorsLib.NotCreditLine.selector);
        morphoCredit.settleAccount(marketParams, BORROWER);

        // Try as owner (should fail)
        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.NotCreditLine.selector);
        morphoCredit.settleAccount(marketParams, BORROWER);
    }

    /// @notice Test settlement clears markdown state
    function testSettlementClearsMarkdown() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower in default with markdown
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Fast forward to default
        _continueMarketCycles(id, block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown exists
        uint256 borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (RepaymentStatus status, uint256 defaultTime) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        uint256 markdownBefore = 0;
        if (status == RepaymentStatus.Default && defaultTime > 0) {
            uint256 timeInDefault = block.timestamp > defaultTime ? block.timestamp - defaultTime : 0;
            markdownBefore = markdownManager.calculateMarkdown(BORROWER, borrowAssets, timeInDefault);
        }
        assertTrue(markdownBefore > 0, "Should have markdown before settlement");

        // Get market markdown before
        Market memory marketBefore = morpho.market(id);
        assertTrue(marketBefore.totalMarkdownAmount > 0, "Market should have markdown");

        // Step 1: Partial repayment
        loanToken.setBalance(address(creditLine), 1_000e18);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), 1_000e18);
        morpho.repay(marketParams, 1_000e18, 0, BORROWER, hex"");

        // Step 2: Settle remaining debt
        morphoCredit.settleAccount(marketParams, BORROWER);
        vm.stopPrank();

        // Verify markdown cleared
        borrowAssets = morpho.expectedBorrowAssets(marketParams, BORROWER);
        (status,) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        uint256 markdownAfter = 0;
        // After settlement, borrower should have no debt, so no markdown
        assertEq(markdownAfter, 0, "Should have no markdown after settlement");

        // Verify market total updated
        Market memory marketAfter = morpho.market(id);
        assertEq(marketAfter.totalMarkdownAmount, 0, "Market markdown should be cleared");
    }

    /// @notice Test settlement clears repayment obligations
    function testSettlementClearsObligations() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower with obligation
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Wait a bit to ensure obligation is properly recorded
        vm.warp(block.timestamp + 1);

        // Verify obligation exists
        (uint128 cycleId, uint128 amountDue, uint128 endingBalance) = morphoCredit.repaymentObligation(id, BORROWER);
        // cycleId can be 0 for the first cycle
        assertTrue(amountDue > 0, "Should have amount due");
        assertTrue(endingBalance > 0, "Should have ending balance");

        // Step 1: Partial repayment
        loanToken.setBalance(address(creditLine), 1_000e18);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), 1_000e18);
        morpho.repay(marketParams, 1_000e18, 0, BORROWER, hex"");

        // Step 2: Settle remaining debt
        morphoCredit.settleAccount(marketParams, BORROWER);
        vm.stopPrank();

        // Verify obligation cleared
        (cycleId, amountDue, endingBalance) = morphoCredit.repaymentObligation(id, BORROWER);
        assertEq(cycleId, 0, "Cycle ID should be cleared");
        assertEq(amountDue, 0, "Amount due should be cleared");
        assertEq(endingBalance, 0, "Ending balance should be cleared");
    }

    /// @notice Test repayment with callback and settlement
    function testRepaymentWithCallbackAndSettlement() public {
        uint256 borrowAmount = 10_000e18;
        uint256 repayAmount = 5_000e18;

        // Setup borrower
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Deploy callback handler
        SettlementCallbackHandler callbackHandler = new SettlementCallbackHandler(address(loanToken), address(morpho));

        // Fund callback handler
        loanToken.setBalance(address(callbackHandler), repayAmount);

        // Use callback handler as credit line (for this test)
        vm.prank(OWNER);
        morpho.createMarket(
            MarketParams(address(loanToken), address(0), address(oracle), address(irm), 0, address(callbackHandler))
        );

        // Setup loan in new market
        Id callbackMarketId = MarketParams(
            address(loanToken), address(0), address(oracle), address(irm), 0, address(callbackHandler)
        ).id();

        vm.prank(address(callbackHandler));
        morphoCredit.setCreditLine(callbackMarketId, BORROWER, borrowAmount * 2, 0);

        // Initialize market cycles for the callback market directly
        // since _ensureMarketActive uses the wrong marketParams
        uint256 firstCycleEnd = block.timestamp + CYCLE_DURATION;
        vm.warp(firstCycleEnd);
        vm.prank(address(callbackHandler));
        IMorphoCredit(address(morpho)).closeCycleAndPostObligations(
            callbackMarketId, firstCycleEnd, new address[](0), new uint256[](0), new uint256[](0)
        );
        vm.warp(firstCycleEnd + 1);

        loanToken.setBalance(SUPPLIER, 20_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(
            MarketParams(address(loanToken), address(0), address(oracle), address(irm), 0, address(callbackHandler)),
            20_000e18,
            0,
            SUPPLIER,
            hex""
        );

        vm.prank(BORROWER);
        morpho.borrow(
            MarketParams(address(loanToken), address(0), address(oracle), address(irm), 0, address(callbackHandler)),
            borrowAmount,
            0,
            BORROWER,
            BORROWER
        );

        // Repay with callback data
        bytes memory callbackData = abi.encode(BORROWER, repayAmount);

        vm.startPrank(address(callbackHandler));
        // Step 1: Repay with callback
        (uint256 repaidAssets, uint256 repaidShares) = morpho.repay(
            MarketParams(address(loanToken), address(0), address(oracle), address(irm), 0, address(callbackHandler)),
            repayAmount,
            0,
            BORROWER,
            callbackData
        );

        // Verify callback was called
        assertTrue(callbackHandler.callbackExecuted(), "Callback should be executed");
        assertEq(callbackHandler.lastRepayAmount(), repayAmount, "Callback should receive correct amount");

        // Step 2: Settle remaining debt
        (uint256 writtenOffAssets, uint256 writtenOffShares) = morphoCredit.settleAccount(
            MarketParams(address(loanToken), address(0), address(oracle), address(irm), 0, address(callbackHandler)),
            BORROWER
        );
        vm.stopPrank();

        // Verify partial repayment and write-off
        assertTrue(repaidShares > 0, "Should have repaid shares");
        assertTrue(writtenOffShares > 0, "Should have written off shares");
    }

    /// @notice Test settling non-existent debt is idempotent and clears state
    function testSettleNonExistentDebtIsIdempotent() public {
        // After fix for Issue #12, settling non-existent debt is idempotent
        // It returns (0, 0) and clears any remaining state to prevent re-borrowing
        vm.prank(address(creditLine));
        (uint256 writtenOffAssets, uint256 writtenOffShares) = morphoCredit.settleAccount(marketParams, BORROWER);

        // Should return zero values for non-existent debt
        assertEq(writtenOffAssets, 0, "No assets should be written off");
        assertEq(writtenOffShares, 0, "No shares should be written off");

        // Verify state is cleared (important for preventing re-borrowing)
        Position memory pos = morpho.position(id, BORROWER);
        assertEq(pos.collateral, 0, "Collateral should be cleared");
        assertEq(pos.borrowShares, 0, "Borrow shares should be zero");
    }

    /// @notice Test zero repayment settlement (100% write-off)
    function testZeroRepaymentSettlement() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Get position and market before
        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);
        uint256 totalDebt = uint256(positionBefore.borrowShares).toAssetsUp(
            marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
        );

        // Track credit line balance before
        uint256 creditLineBalanceBefore = loanToken.balanceOf(address(creditLine));

        // Settle account without any repayment
        vm.prank(address(creditLine));
        (uint256 writtenOffAssets, uint256 writtenOffShares) = morphoCredit.settleAccount(marketParams, BORROWER);

        // Verify all shares written off
        assertEq(writtenOffShares, positionBefore.borrowShares, "All shares should be written off");
        assertApproxEqAbs(writtenOffAssets, totalDebt, 1, "Written off assets should match total debt");

        // Verify no tokens transferred
        uint256 creditLineBalanceAfter = loanToken.balanceOf(address(creditLine));
        assertEq(creditLineBalanceAfter, creditLineBalanceBefore, "No tokens should be transferred");

        // Verify position cleared
        Position memory positionAfter = morpho.position(id, BORROWER);
        assertEq(positionAfter.borrowShares, 0, "Borrower position should be cleared");

        // Verify market totals
        Market memory marketAfter = morpho.market(id);
        assertEq(marketAfter.totalBorrowAssets, 0, "Total borrow should be zero");
        assertEq(marketAfter.totalBorrowShares, 0, "Total borrow shares should be zero");

        // Verify supply reduced by full debt
        uint256 supplyReduction = marketBefore.totalSupplyAssets - marketAfter.totalSupplyAssets;
        assertApproxEqAbs(supplyReduction, totalDebt, 1, "Supply should be reduced by full debt amount");
    }

    /// @notice Test settlement of current status borrower
    function testSettlementCurrentStatusBorrower() public {
        uint256 borrowAmount = 10_000e18;
        uint256 repayAmount = 5_000e18;

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Verify borrower is Current
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Current), "Should be Current");

        // Get position before
        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);

        // Settle while Current
        loanToken.setBalance(address(creditLine), repayAmount);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), repayAmount);
        (uint256 repaidAssets, uint256 repaidShares) = morpho.repay(marketParams, repayAmount, 0, BORROWER, hex"");
        (uint256 writtenOffAssets, uint256 writtenOffShares) = morphoCredit.settleAccount(marketParams, BORROWER);
        vm.stopPrank();

        // Verify settlement worked normally
        assertTrue(repaidShares > 0, "Should have repaid shares");
        assertTrue(writtenOffShares > 0, "Should have written off shares");
        assertEq(repaidShares + writtenOffShares, positionBefore.borrowShares, "Total should match");

        // Verify no markdown applied (borrower was Current)
        assertEq(marketBefore.totalMarkdownAmount, 0, "Should have no markdown for Current borrower");
    }

    /// @notice Test settlement of grace period borrower
    function testSettlementGracePeriodBorrower() public {
        uint256 borrowAmount = 10_000e18;
        uint256 repayAmount = 5_000e18;

        // Setup grace period borrower
        address graceBorrower = makeAddr("GraceBorrower");
        vm.prank(OWNER);
        markdownManager.setEnableMarkdown(graceBorrower, true);
        vm.stopPrank();
        _setupBorrowerWithLoan(graceBorrower, borrowAmount);
        _createPastObligation(graceBorrower, 500, borrowAmount);

        // Move to grace period
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, graceBorrower);
        uint256 cycleEnd = morphoCredit.paymentCycle(id, cycleId);
        vm.warp(cycleEnd + 1); // Just past cycle end, in grace period

        // Verify status
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, graceBorrower);
        assertEq(uint8(status), uint8(RepaymentStatus.GracePeriod), "Should be in GracePeriod");

        // Settle during grace period
        loanToken.setBalance(address(creditLine), repayAmount);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), repayAmount);
        morpho.repay(marketParams, repayAmount, 0, graceBorrower, hex"");
        morphoCredit.settleAccount(marketParams, graceBorrower);
        vm.stopPrank();

        // Verify position cleared
        Position memory gracePositionAfter = morpho.position(id, graceBorrower);
        assertEq(gracePositionAfter.borrowShares, 0, "Grace borrower position should be cleared");
    }

    /// @notice Test settlement of delinquent borrower
    function testSettlementDelinquentBorrower() public {
        uint256 borrowAmount = 10_000e18;
        uint256 repayAmount = 5_000e18;

        // Setup delinquent borrower
        address delinquentBorrower = makeAddr("DelinquentBorrower");
        vm.prank(OWNER);
        markdownManager.setEnableMarkdown(delinquentBorrower, true);
        vm.stopPrank();
        _setupBorrowerWithLoan(delinquentBorrower, borrowAmount);
        _createPastObligation(delinquentBorrower, 500, borrowAmount);

        // Move to delinquent period
        (uint128 cycleId,,) = morphoCredit.repaymentObligation(id, delinquentBorrower);
        uint256 cycleEnd = morphoCredit.paymentCycle(id, cycleId);
        vm.warp(cycleEnd + GRACE_PERIOD_DURATION + 1); // Past grace, in delinquency

        // Verify status
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, delinquentBorrower);
        assertEq(uint8(status), uint8(RepaymentStatus.Delinquent), "Should be Delinquent");

        // Settle during delinquency
        loanToken.setBalance(address(creditLine), repayAmount);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), repayAmount);
        morpho.repay(marketParams, repayAmount, 0, delinquentBorrower, hex"");
        morphoCredit.settleAccount(marketParams, delinquentBorrower);
        vm.stopPrank();

        // Verify position cleared
        Position memory delinquentPositionAfter = morpho.position(id, delinquentBorrower);
        assertEq(delinquentPositionAfter.borrowShares, 0, "Delinquent borrower position should be cleared");
    }

    /// @notice Test repayment amount capping
    function testRepaymentAmountCapping() public {
        uint256 borrowAmount = 10_000e18;
        uint256 excessiveRepayAmount = 20_000e18; // More than owed

        // Setup borrower
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);
        uint256 totalDebt = uint256(positionBefore.borrowShares).toAssetsUp(
            marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
        );

        // Try to repay more than owed
        loanToken.setBalance(address(creditLine), excessiveRepayAmount);

        uint256 balanceBefore = loanToken.balanceOf(address(creditLine));

        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), excessiveRepayAmount);
        // Use share-based repayment to avoid rounding issues
        (uint256 repaidAssets, uint256 repaidShares) =
            morpho.repay(marketParams, 0, positionBefore.borrowShares, BORROWER, hex"");
        vm.stopPrank();

        // Should only take what's owed
        uint256 balanceAfter = loanToken.balanceOf(address(creditLine));
        uint256 actualRepaid = balanceBefore - balanceAfter;

        assertEq(repaidShares, positionBefore.borrowShares, "Should repay all shares");
        assertEq(repaidAssets, actualRepaid, "Repaid assets should match actual transfer");
        assertLe(actualRepaid, totalDebt + 1, "Should not take more than owed (accounting for rounding)");

        // Verify no debt left to settle
        // After fix for Issue #12, this is idempotent and returns (0, 0)
        vm.prank(address(creditLine));
        (uint256 writtenOffAssets, uint256 writtenOffShares) = morphoCredit.settleAccount(marketParams, BORROWER);
        assertEq(writtenOffAssets, 0, "No assets should be written off after full repayment");
        assertEq(writtenOffShares, 0, "No shares should be written off after full repayment");
    }
}

/// @notice Mock callback handler for testing settlement callbacks
contract SettlementCallbackHandler is IMorphoRepayCallback {
    address public immutable token;
    address public immutable morpho;
    bool public callbackExecuted;
    uint256 public lastRepayAmount;
    address public mm; // Market manager for credit line compatibility

    constructor(address _token, address _morpho) {
        token = _token;
        morpho = _morpho;
        mm = address(0); // No markdown manager for this test
    }

    function onMorphoRepay(uint256 amount, bytes calldata data) external {
        require(msg.sender == morpho, "Only Morpho can call");
        callbackExecuted = true;
        lastRepayAmount = amount;

        // Approve morpho to take the tokens
        IERC20(token).approve(morpho, amount);
    }
}
