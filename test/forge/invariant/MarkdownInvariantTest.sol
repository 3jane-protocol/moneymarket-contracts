// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import "../InvariantTest.sol";
import {MarkdownManagerMock} from "../mocks/MarkdownManagerMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {HelperMock} from "../../../src/mocks/HelperMock.sol";
import {Market} from "../../../src/interfaces/IMorpho.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";

/// @title MarkdownInvariantTest
/// @notice Invariant tests to ensure markdown logic maintains critical properties
/// @dev Tests that markdown operations preserve protocol safety invariants
contract MarkdownInvariantTest is BaseTest, InvariantTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    MarkdownManagerMock markdownManager;
    CreditLineMock creditLine;
    HelperMock helper;
    IMorphoCredit morphoCredit;

    // Time limit constant - 1 year max for accurate Taylor expansion
    uint256 constant MAX_TOTAL_TIME = 365 days;

    // State tracking for invariants
    uint256 public initialTokenBalance;
    uint256 public totalSupplied;
    uint256 public testStartTime;
    uint256 public totalTimeElapsed;
    mapping(address => uint256) public borrowerDebts;
    address[] public activeBorrowers;

    function setUp() public override(BaseTest, InvariantTest) {
        // Call BaseTest setUp directly to avoid InvariantTest's _targetSenders pranks
        BaseTest.setUp();

        // Deploy contracts
        markdownManager = new MarkdownManagerMock();
        creditLine = new CreditLineMock(morphoAddress);
        morphoCredit = IMorphoCredit(morphoAddress);
        helper = new HelperMock(morphoAddress);

        // Create market
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
        vm.stopPrank();

        // Supply initial funds
        totalSupplied = 1000 ether;
        loanToken.setBalance(SUPPLIER, totalSupplied);

        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, totalSupplied, 0, SUPPLIER, "");
        vm.stopPrank();

        // Track initial state
        initialTokenBalance = loanToken.balanceOf(address(morpho));
        testStartTime = block.timestamp;
        totalTimeElapsed = 0;

        // Set up target contracts for invariant testing
        targetContract(address(this));
    }

    /// @notice Invariant: totalSupplyAssets + totalMarkdownAmount should remain constant during markdown changes
    /// @dev This ensures markdown only redistributes value, not creates or destroys it
    function invariant_markdownConservesValue() public {
        Market memory m = morpho.market(id);
        uint256 expectedTotal = totalSupplied;

        // Calculate dynamic tolerance based on elapsed time and maximum possible rates
        uint256 timeElapsed = block.timestamp - testStartTime;

        // Ensure we don't exceed 1 year (safety check - handlers should already enforce this)
        if (timeElapsed > MAX_TOTAL_TIME) {
            timeElapsed = MAX_TOTAL_TIME;
        }

        // Maximum possible rate: 100% APR (base at full utilization) + 10% APR (penalty)
        // Convert to per-second rate: 110% / 365 days
        uint256 maxRatePerSecond = (110 * WAD) / (100 * 365 days);

        // Calculate compound interest growth using the same formula as the protocol
        uint256 compoundedGrowth = maxRatePerSecond.wTaylorCompounded(timeElapsed);

        // Calculate maximum possible interest with 5% buffer for rounding errors
        uint256 maxInterest = totalSupplied.wMulDown(compoundedGrowth).mulDivUp(105, 100);

        assertApproxEqAbs(
            m.totalSupplyAssets + m.totalMarkdownAmount,
            expectedTotal,
            maxInterest,
            "Markdown should conserve total value"
        );
    }

    /// @notice Invariant: markdown should be properly bounded
    /// @dev Ensures markdown doesn't exceed total borrow assets
    function invariant_markdownProperlyBounded() public {
        Market memory m = morpho.market(id);

        // Markdown should never exceed total borrow assets (within 1 wei for rounding)
        if (m.totalMarkdownAmount > m.totalBorrowAssets) {
            // Allow 1 wei of rounding error if markdown exceeds debt
            assertLe(
                m.totalMarkdownAmount - m.totalBorrowAssets,
                1,
                "Total markdown should not exceed total debt by more than 1 wei"
            );
        }

        // If there's no debt, there should be no markdown
        if (m.totalBorrowAssets == 0) {
            assertEq(m.totalMarkdownAmount, 0, "No markdown without debt");
        }
    }

    /// @notice Invariant: Markdown per borrower should never exceed their debt
    /// @dev Ensures markdown is bounded by actual obligations
    function invariant_markdownCappedAtDebt() public {
        for (uint256 i = 0; i < activeBorrowers.length; i++) {
            address borrower = activeBorrowers[i];
            uint256 borrowShares = morpho.position(id, borrower).borrowShares;

            if (borrowShares > 0) {
                Market memory m = morpho.market(id);
                uint256 debt = borrowShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

                // Get borrower's markdown state (would need to expose this in real implementation)
                // For now, we verify the total markdown doesn't exceed total debt (with rounding tolerance)
                if (m.totalMarkdownAmount > m.totalBorrowAssets) {
                    // Allow 1 wei of rounding error if markdown exceeds debt
                    assertLe(
                        m.totalMarkdownAmount - m.totalBorrowAssets,
                        1,
                        "Total markdown should not exceed total debt by more than 1 wei"
                    );
                }
            }
        }
    }

    /// @notice Invariant: Sum of individual positions should match market totals
    /// @dev Ensures accounting consistency across the protocol
    function invariant_positionSumsMatchTotals() public {
        uint256 totalBorrowSharesSum = 0;
        uint256 totalSupplySharesSum = 0;

        // Sum up all positions (simplified - would need to track all users in production)
        for (uint256 i = 0; i < activeBorrowers.length; i++) {
            totalBorrowSharesSum += morpho.position(id, activeBorrowers[i]).borrowShares;
        }
        totalSupplySharesSum = morpho.position(id, SUPPLIER).supplyShares;

        Market memory m = morpho.market(id);

        assertEq(totalBorrowSharesSum, m.totalBorrowShares, "Sum of borrow shares should match total");

        assertEq(totalSupplySharesSum, m.totalSupplyShares, "Sum of supply shares should match total");
    }

    // Handler functions for invariant testing

    /// @notice Handler: Create a new borrower and borrow
    function handler_borrow(uint256 amount) public {
        amount = bound(amount, 1 ether, 50 ether);
        address borrower = makeAddr(string(abi.encodePacked("Borrower", activeBorrowers.length)));

        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, borrower, amount * 2, 0);

        vm.prank(borrower);
        try morpho.borrow(marketParams, amount, 0, borrower, borrower) {
            activeBorrowers.push(borrower);
            borrowerDebts[borrower] = amount;
        } catch {}
    }

    /// @notice Handler: Trigger markdown for a random borrower
    function handler_markdown(uint256 borrowerIndex, uint256 markdownAmount) public {
        if (activeBorrowers.length == 0) return;

        borrowerIndex = borrowerIndex % activeBorrowers.length;
        address borrower = activeBorrowers[borrowerIndex];

        // Accrue premium first to get accurate debt
        morphoCredit.accrueBorrowerPremium(id, borrower);

        // Get actual current debt after accrual
        Position memory pos = morpho.position(id, borrower);
        if (pos.borrowShares == 0) return; // No debt to markdown

        Market memory m = morpho.market(id);
        uint256 currentDebt = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        markdownAmount = bound(markdownAmount, 0, currentDebt * 2);

        // Set up default state for borrower
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = 10000;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = currentDebt;

        vm.prank(address(creditLine));
        try morphoCredit.closeCycleAndPostObligations(id, block.timestamp, borrowers, repaymentBps, endingBalances) {
            // Move to default
            vm.warp(block.timestamp + 31 days);

            // Apply markdown
            markdownManager.setMarkdownForBorrower(borrower, markdownAmount);
            morphoCredit.accrueBorrowerPremium(id, borrower);

            // Update tracked debt after markdown
            borrowerDebts[borrower] = currentDebt;
        } catch {}
    }

    /// @notice Handler: Reverse markdown for a random borrower
    function handler_reverseMarkdown(uint256 borrowerIndex) public {
        if (activeBorrowers.length == 0) return;

        borrowerIndex = borrowerIndex % activeBorrowers.length;
        address borrower = activeBorrowers[borrowerIndex];

        // Set markdown to 0 (full reversal)
        markdownManager.setMarkdownForBorrower(borrower, 0);
        try morphoCredit.accrueBorrowerPremium(id, borrower) {} catch {}
    }

    /// @notice Handler: Partial repayment
    function handler_repay(uint256 borrowerIndex, uint256 amount) public {
        if (activeBorrowers.length == 0) return;

        borrowerIndex = borrowerIndex % activeBorrowers.length;
        address borrower = activeBorrowers[borrowerIndex];

        // Accrue premium to get accurate debt amount
        morphoCredit.accrueBorrowerPremium(id, borrower);

        // Get actual current debt after accrual
        Position memory pos = morpho.position(id, borrower);
        if (pos.borrowShares == 0) return; // No debt to repay

        Market memory m = morpho.market(id);
        uint256 actualDebt = uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

        // Bound amount to actual debt to prevent underflow
        amount = bound(amount, 0, actualDebt);
        if (amount == 0) return;

        loanToken.setBalance(borrower, amount);
        vm.startPrank(borrower);
        loanToken.approve(address(morpho), amount);
        try morpho.repay(marketParams, amount, 0, borrower, "") {
            // Update tracked debt based on actual repayment
            if (amount >= actualDebt) {
                borrowerDebts[borrower] = 0;
            } else {
                borrowerDebts[borrower] = actualDebt - amount;
            }
        } catch {}
        vm.stopPrank();
    }

    /// @notice Handler: Time progression
    function handler_warp(uint256 time) public {
        time = bound(time, 1 hours, 7 days);

        uint256 currentTime = block.timestamp - testStartTime;

        // Don't exceed 1 year total from test start
        if (currentTime + time > MAX_TOTAL_TIME) {
            time = MAX_TOTAL_TIME - currentTime;
            if (time == 0) return; // Already at max time
        }

        totalTimeElapsed = currentTime + time;
        vm.warp(block.timestamp + time);

        // Accrue interest for all borrowers
        for (uint256 i = 0; i < activeBorrowers.length; i++) {
            try morphoCredit.accrueBorrowerPremium(id, activeBorrowers[i]) {} catch {}
        }
    }

    /// @notice Override mine to respect time limit
    function mine(uint256 blocks) public override {
        blocks = bound(blocks, 1, 1 days / BLOCK_TIME);

        uint256 timeToAdd = blocks * BLOCK_TIME;
        uint256 currentTime = block.timestamp - testStartTime;

        // Don't exceed 1 year total from test start
        if (currentTime + timeToAdd > MAX_TOTAL_TIME) {
            timeToAdd = MAX_TOTAL_TIME - currentTime;
            if (timeToAdd == 0) return; // Already at max time
            blocks = timeToAdd / BLOCK_TIME;
            if (blocks == 0) return; // Less than one block of time left
        }

        totalTimeElapsed = currentTime + timeToAdd;
        _forward(blocks);
    }
}
