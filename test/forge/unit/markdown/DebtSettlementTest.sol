// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {MarkdownManagerMock} from "../../../../src/mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {IMorphoRepayCallback} from "../../../../src/interfaces/IMorphoCallbacks.sol";
import {Market, MarkdownState, RepaymentStatus, Position} from "../../../../src/interfaces/IMorpho.sol";

/// @title DebtSettlementTest
/// @notice Tests for debt settlement mechanism including full/partial settlements and authorization
contract DebtSettlementTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    event DebtSettled(
        Id indexed id,
        address indexed borrower,
        address indexed settler,
        uint256 repaidAmount,
        uint256 writtenOffAmount,
        uint256 repaidShares,
        uint256 writtenOffShares
    );

    function setUp() public override {
        super.setUp();

        // Deploy markdown manager
        markdownManager = new MarkdownManagerMock();

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
        morphoCredit.setMarkdownManager(id, address(markdownManager));
        vm.stopPrank();

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 100_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 100_000e18, 0, SUPPLIER, hex"");
    }

    /// @notice Test full settlement (100% repayment, no write-off)
    function testFullSettlement() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower with loan
        _setupBorrowerWithLoan(BORROWER, borrowAmount);

        // Forward time to accrue some interest
        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(marketParams);

        // Get current debt
        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);
        uint256 totalDebt = uint256(positionBefore.borrowShares).toAssetsUp(
            marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
        );

        // Calculate expected repay amount for exact shares
        uint256 expectedRepayAmount = uint256(positionBefore.borrowShares).toAssetsUp(
            marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
        );

        // Prepare full repayment
        loanToken.setBalance(address(creditLine), expectedRepayAmount);

        // Approve before expecting event
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), expectedRepayAmount);

        // Expect event with no write-off
        vm.expectEmit(true, true, true, true);
        emit DebtSettled(id, BORROWER, address(creditLine), expectedRepayAmount, 0, positionBefore.borrowShares, 0);

        // Settle debt with exact amount
        (uint256 repaidShares, uint256 writtenOffShares) =
            morphoCredit.settleDebt(marketParams, BORROWER, expectedRepayAmount, hex"");
        vm.stopPrank();

        // Verify results
        assertEq(repaidShares, positionBefore.borrowShares, "All shares should be repaid");
        assertEq(writtenOffShares, 0, "No shares should be written off");

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
        vm.warp(block.timestamp + 30 days);
        morpho.accrueInterest(marketParams);

        // Get position details
        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);
        uint256 totalDebt = uint256(positionBefore.borrowShares).toAssetsUp(
            marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
        );

        // Calculate expected shares
        uint256 expectedRepaidShares =
            repayAmount.toSharesDown(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);
        uint256 expectedWrittenOffShares = positionBefore.borrowShares - expectedRepaidShares;
        uint256 expectedWrittenOffAssets =
            expectedWrittenOffShares.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);

        // Prepare partial repayment
        loanToken.setBalance(address(creditLine), repayAmount);

        // Settle debt
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), repayAmount);
        (uint256 repaidShares, uint256 writtenOffShares) =
            morphoCredit.settleDebt(marketParams, BORROWER, repayAmount, hex"");
        vm.stopPrank();

        // Verify shares
        assertEq(repaidShares, expectedRepaidShares, "Repaid shares should match expected");
        assertEq(writtenOffShares, expectedWrittenOffShares, "Written off shares should match expected");
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

        // Prepare minimal repayment
        loanToken.setBalance(address(creditLine), repayAmount);

        // Settle debt
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), repayAmount);
        (uint256 repaidShares, uint256 writtenOffShares) =
            morphoCredit.settleDebt(marketParams, BORROWER, repayAmount, hex"");
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
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), borrowAmount);
        vm.expectRevert(ErrorsLib.NotCreditLine.selector);
        morphoCredit.settleDebt(marketParams, BORROWER, borrowAmount, hex"");
        vm.stopPrank();

        // Try as borrower (should fail)
        loanToken.setBalance(BORROWER, borrowAmount);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), borrowAmount);
        vm.expectRevert(ErrorsLib.NotCreditLine.selector);
        morphoCredit.settleDebt(marketParams, BORROWER, borrowAmount, hex"");
        vm.stopPrank();

        // Try as owner (should fail)
        loanToken.setBalance(OWNER, borrowAmount);
        vm.startPrank(OWNER);
        loanToken.approve(address(morpho), borrowAmount);
        vm.expectRevert(ErrorsLib.NotCreditLine.selector);
        morphoCredit.settleDebt(marketParams, BORROWER, borrowAmount, hex"");
        vm.stopPrank();
    }

    /// @notice Test settlement clears markdown state
    function testSettlementClearsMarkdown() public {
        uint256 borrowAmount = 10_000e18;

        // Setup borrower in default with markdown
        _setupBorrowerWithLoan(BORROWER, borrowAmount);
        _createPastObligation(BORROWER, 500, borrowAmount);

        // Fast forward to default
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 1);
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Verify markdown exists
        (uint256 markdownBefore,,) = morphoCredit.getBorrowerMarkdownInfo(id, BORROWER);
        assertTrue(markdownBefore > 0, "Should have markdown before settlement");

        // Get market markdown before
        Market memory marketBefore = morpho.market(id);
        assertTrue(marketBefore.totalMarkdownAmount > 0, "Market should have markdown");

        // Settle debt
        loanToken.setBalance(address(creditLine), 1_000e18);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), 1_000e18);
        morphoCredit.settleDebt(marketParams, BORROWER, 1_000e18, hex"");
        vm.stopPrank();

        // Verify markdown cleared
        (uint256 markdownAfter,,) = morphoCredit.getBorrowerMarkdownInfo(id, BORROWER);
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
        (uint128 cycleId, uint128 amountDue, uint256 endingBalance) = morphoCredit.repaymentObligation(id, BORROWER);
        // cycleId can be 0 for the first cycle
        assertTrue(amountDue > 0, "Should have amount due");
        assertTrue(endingBalance > 0, "Should have ending balance");

        // Settle debt
        loanToken.setBalance(address(creditLine), 1_000e18);
        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), 1_000e18);
        morphoCredit.settleDebt(marketParams, BORROWER, 1_000e18, hex"");
        vm.stopPrank();

        // Verify obligation cleared
        (cycleId, amountDue, endingBalance) = morphoCredit.repaymentObligation(id, BORROWER);
        assertEq(cycleId, 0, "Cycle ID should be cleared");
        assertEq(amountDue, 0, "Amount due should be cleared");
        assertEq(endingBalance, 0, "Ending balance should be cleared");
    }

    /// @notice Test settlement with callback
    function testSettlementWithCallback() public {
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

        // Settle with callback data
        bytes memory callbackData = abi.encode(BORROWER, repayAmount);

        vm.prank(address(callbackHandler));
        (uint256 repaidShares, uint256 writtenOffShares) = morphoCredit.settleDebt(
            MarketParams(address(loanToken), address(0), address(oracle), address(irm), 0, address(callbackHandler)),
            BORROWER,
            repayAmount,
            callbackData
        );

        // Verify callback was called
        assertTrue(callbackHandler.callbackExecuted(), "Callback should be executed");
        assertEq(callbackHandler.lastRepayAmount(), repayAmount, "Callback should receive correct amount");
    }

    /// @notice Test cannot settle non-existent debt
    function testCannotSettleNonExistentDebt() public {
        // Try to settle for borrower with no debt
        loanToken.setBalance(address(creditLine), 1_000e18);

        vm.startPrank(address(creditLine));
        loanToken.approve(address(morpho), 1_000e18);
        vm.expectRevert(ErrorsLib.NoDebtToSettle.selector);
        morphoCredit.settleDebt(marketParams, BORROWER, 1_000e18, hex"");
        vm.stopPrank();
    }

    /// @notice Test settlement amount capping
    function testSettlementAmountCapping() public {
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
        (uint256 repaidShares, uint256 writtenOffShares) =
            morphoCredit.settleDebt(marketParams, BORROWER, excessiveRepayAmount, hex"");
        vm.stopPrank();

        // Should only take what's owed
        uint256 balanceAfter = loanToken.balanceOf(address(creditLine));
        uint256 actualRepaid = balanceBefore - balanceAfter;

        assertEq(repaidShares, positionBefore.borrowShares, "Should repay all shares");
        assertEq(writtenOffShares, 0, "Should not write off anything");
        assertLe(actualRepaid, totalDebt + 1, "Should not take more than owed (accounting for rounding)");
    }
}

/// @notice Mock callback handler for testing settlement callbacks
contract SettlementCallbackHandler is IMorphoRepayCallback {
    address public immutable token;
    address public immutable morpho;
    bool public callbackExecuted;
    uint256 public lastRepayAmount;

    constructor(address _token, address _morpho) {
        token = _token;
        morpho = _morpho;
    }

    function onMorphoRepay(uint256 amount, bytes calldata data) external {
        require(msg.sender == morpho, "Only Morpho can call");
        callbackExecuted = true;
        lastRepayAmount = amount;

        // Approve morpho to take the tokens
        IERC20(token).approve(morpho, amount);
    }
}
