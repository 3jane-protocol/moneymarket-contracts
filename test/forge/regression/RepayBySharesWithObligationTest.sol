// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {Id, MarketParams, RepaymentStatus, IMorphoCredit, Position, Market} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";

/// @title RepayBySharesWithObligationTest
/// @notice Test for repayment by shares when an obligation exists
/// @dev This test should FAIL initially, demonstrating the bug where users cannot
///      repay using shares when they have outstanding payment obligations
contract RepayBySharesWithObligationTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    CreditLineMock internal creditLine;
    ConfigurableIrmMock internal configurableIrm;

    address internal ALICE;

    function setUp() public override {
        super.setUp();

        ALICE = makeAddr("Alice");

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
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 100000e18, 634195840); // 2% premium
        vm.stopPrank();

        // Warp time forward
        vm.warp(block.timestamp + 30 days);

        // Continue market cycles after time warp to keep market active
        _continueMarketCycles(id, block.timestamp);

        // Setup token approval for Alice
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
    }

    /// @notice Test that demonstrates the bug: repayment by shares fails when obligation exists
    /// @dev This test should FAIL with ErrorsLib.MustPayFullObligation() error
    function testRepayBySharesFailsWithObligation() public {
        // Step 1: Alice borrows 10,000 tokens
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Step 2: Create an obligation using the helper (handles time warping and cycle creation)
        uint256 borrowBalance = morpho.expectedBorrowAssets(marketParams, ALICE);
        _createPastObligation(ALICE, 1000, borrowBalance); // 10% obligation

        // Step 3: Alice tries to repay using shares (not assets)
        // Calculate shares needed to repay the obligation amount
        Position memory pos = morpho.position(id, ALICE);
        uint256 borrowShares = pos.borrowShares;

        // Get current market state to calculate conversion
        Market memory m = morpho.market(id);
        uint128 totalBorrowAssets = m.totalBorrowAssets;
        uint128 totalBorrowShares = m.totalBorrowShares;

        // Calculate shares equivalent to obligation amount (10% of borrow balance)
        uint256 obligationAmount = borrowBalance.mulDivUp(1000, 10000); // 10% obligation
        uint256 sharesToRepay = obligationAmount.toSharesDown(totalBorrowAssets, totalBorrowShares);

        // Give Alice enough tokens to cover the repayment
        deal(address(loanToken), ALICE, obligationAmount + 100e18);

        // THIS TEST SHOULD PASS BUT CURRENTLY FAILS: Try to repay using shares parameter (assets = 0)
        // The bug is that _trackObligationPayment receives assets=0 and reverts
        // even though the shares would convert to sufficient assets
        vm.prank(ALICE);
        (uint256 assetsRepaid, uint256 sharesRepaid) = morpho.repay(marketParams, 0, sharesToRepay, ALICE, "");

        // Verify the repayment was successful
        assertTrue(assetsRepaid >= obligationAmount, "Should have repaid at least the obligation amount");
        assertEq(sharesRepaid, sharesToRepay, "Should have repaid exact shares requested");

        // Verify obligation is cleared (allow small rounding error)
        (uint256 amountDue,,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertLe(amountDue, 10, "Obligation should be cleared (allowing small rounding)");
    }

    /// @notice Test that shows asset-based repayment works with obligation (control test)
    /// @dev This should PASS, showing that the issue is specific to share-based repayment
    function testRepayByAssetsWorksWithObligation() public {
        // Step 1: Alice borrows 10,000 tokens
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Step 2: Create an obligation using the helper (handles time warping and cycle creation)
        uint256 borrowBalance = morpho.expectedBorrowAssets(marketParams, ALICE);
        _createPastObligation(ALICE, 1000, borrowBalance); // 10% obligation

        // Step 3: Alice repays using assets (not shares) - this should work
        uint256 obligationAmount = borrowBalance.mulDivUp(1000, 10000); // 10% obligation

        // Give Alice enough tokens to cover the repayment
        deal(address(loanToken), ALICE, obligationAmount + 100e18);

        // THIS SHOULD PASS: Repay using assets parameter works fine
        vm.prank(ALICE);
        (uint256 assetsRepaid, uint256 sharesRepaid) = morpho.repay(marketParams, obligationAmount, 0, ALICE, "");

        // Verify the repayment was successful
        assertTrue(assetsRepaid >= obligationAmount, "Should have repaid at least the obligation amount");
        assertTrue(sharesRepaid > 0, "Should have repaid some shares");

        // Verify obligation is cleared (allow small rounding error)
        (uint256 amountDue,,) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        assertLe(amountDue, 10, "Obligation should be cleared (allowing small rounding)");
    }

    /// @notice Test that shows share-based repayment works WITHOUT obligation
    /// @dev This should PASS, showing share-based repayment normally works
    function testRepayBySharesWorksWithoutObligation() public {
        // Step 1: Alice borrows 10,000 tokens
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Step 2: NO OBLIGATION POSTED - this is the key difference

        // Step 3: Alice repays using shares
        Position memory pos = morpho.position(id, ALICE);
        uint256 borrowShares = pos.borrowShares;
        uint256 sharesToRepay = borrowShares / 2; // Repay half

        // Give Alice enough tokens
        deal(address(loanToken), ALICE, 10000e18);

        // THIS SHOULD PASS: Share-based repayment works when no obligation exists
        vm.prank(ALICE);
        (uint256 assetsRepaid, uint256 sharesRepaid) = morpho.repay(marketParams, 0, sharesToRepay, ALICE, "");

        // Verify the repayment was successful
        assertTrue(assetsRepaid > 0, "Should have repaid some assets");
        assertEq(sharesRepaid, sharesToRepay, "Should have repaid exact shares requested");
    }
}
