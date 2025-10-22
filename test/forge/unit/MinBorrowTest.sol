// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorpho, IMorphoCredit, Id, MarketParams, Position, Market} from "../../../src/interfaces/IMorpho.sol";
import {IProtocolConfig, MarketConfig} from "../../../src/interfaces/IProtocolConfig.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {HelperMock} from "../../../src/mocks/HelperMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {USD3Mock} from "../../../src/mocks/USD3Mock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title MinBorrowTest
/// @notice Comprehensive tests for minBorrow functionality
contract MinBorrowTest is BaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    HelperMock public helper;
    USD3Mock public usd3;
    CreditLineMock public creditLine;
    IMorphoCredit public morphoCredit;

    address public constant BORROWER_1 = address(0x1111);
    address public constant BORROWER_2 = address(0x2222);
    address public constant TEST_SUPPLIER = address(0x3333);

    uint256 public constant MIN_BORROW_AMOUNT = 1000e18;
    uint256 public constant SUPPLY_AMOUNT = 100_000e18;
    uint256 public constant LARGE_BORROW = 5000e18;

    function setUp() public override {
        super.setUp();

        // Deploy a REAL MorphoCredit instance (not the mock from BaseTest)
        MorphoCredit realMorphoImpl = new MorphoCredit(address(protocolConfig));
        TransparentUpgradeableProxy realMorphoProxy = new TransparentUpgradeableProxy(
            address(realMorphoImpl),
            address(proxyAdmin),
            abi.encodeWithSelector(MorphoCredit.initialize.selector, OWNER)
        );

        // Override the morpho references to use the real instance
        morpho = IMorpho(address(realMorphoProxy));
        morphoCredit = IMorphoCredit(address(realMorphoProxy));

        // Deploy helper, USD3, and creditLine pointing to the real instance
        helper = new HelperMock(address(realMorphoProxy));
        usd3 = new USD3Mock(address(realMorphoProxy));
        creditLine = new CreditLineMock(address(realMorphoProxy));

        // Set up the real morpho instance
        vm.startPrank(OWNER);
        morphoCredit.setUsd3(address(usd3));
        morpho.enableIrm(address(0));
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0);
        morpho.setFeeRecipient(FEE_RECIPIENT);
        morphoCredit.setHelper(address(helper));

        // Set minBorrow and cycle duration in protocolConfig
        protocolConfig.setConfig(keccak256("MIN_BORROW"), MIN_BORROW_AMOUNT);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), 30 days); // Set proper cycle duration
        vm.stopPrank();

        // Create market with credit line
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0,
            creditLine: address(creditLine)
        });

        vm.prank(OWNER);
        morpho.createMarket(marketParams);
        id = marketParams.id();

        // Create initial payment cycle with empty arrays to prevent market from being frozen
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        vm.prank(address(creditLine));
        morphoCredit.closeCycleAndPostObligations(id, block.timestamp, borrowers, repaymentBps, endingBalances);

        // Setup initial supply
        _supply(TEST_SUPPLIER, SUPPLY_AMOUNT);

        // Give borrowers credit lines
        _setCreditLine(BORROWER_1, 10_000e18);
        _setCreditLine(BORROWER_2, 10_000e18);
    }

    // Helper functions

    function _supply(address supplier, uint256 amount) internal {
        loanToken.setBalance(address(usd3), amount);
        vm.startPrank(address(usd3));
        loanToken.approve(address(morpho), amount);
        morpho.supply(marketParams, amount, 0, supplier, "");
        vm.stopPrank();
    }

    function _setCreditLine(address user, uint256 amount) internal {
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, user, amount, 0);
    }

    function _borrowAs(address user, uint256 amount) internal returns (uint256 shares) {
        vm.prank(address(helper));
        (, shares) = morpho.borrow(marketParams, amount, 0, user, user);
    }

    function _repayAs(address user, uint256 amount) internal returns (uint256 actualRepaid) {
        loanToken.setBalance(user, amount);
        vm.startPrank(user);
        loanToken.approve(address(morpho), amount);
        (actualRepaid,) = morpho.repay(marketParams, amount, 0, user, "");
        vm.stopPrank();
    }

    function _getBorrowBalance(address user) internal view returns (uint256) {
        Position memory position = morpho.position(id, user);
        Market memory market = morpho.market(id);
        if (position.borrowShares == 0) return 0;
        return uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
    }

    function _setMinBorrow(uint256 amount) internal {
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("MIN_BORROW"), amount);
    }

    // Test: Basic Borrow Scenarios

    function testBorrowAboveMinBorrow() public {
        uint256 borrowAmount = MIN_BORROW_AMOUNT + 100e18;

        _borrowAs(BORROWER_1, borrowAmount);

        assertEq(_getBorrowBalance(BORROWER_1), borrowAmount, "Borrow balance should equal borrowed amount");
    }

    function testBorrowExactlyMinBorrow() public {
        uint256 borrowAmount = MIN_BORROW_AMOUNT;

        _borrowAs(BORROWER_1, borrowAmount);

        assertEq(_getBorrowBalance(BORROWER_1), borrowAmount, "Borrow balance should equal minBorrow");
    }

    function testBorrowBelowMinBorrowReverts() public {
        uint256 borrowAmount = MIN_BORROW_AMOUNT - 1;

        vm.prank(address(helper));
        vm.expectRevert(ErrorsLib.BelowMinimumBorrow.selector);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER_1, BORROWER_1);
    }

    function testIncrementalBorrowBelowMinBorrowReverts() public {
        // First borrow a small amount
        uint256 firstBorrow = MIN_BORROW_AMOUNT / 3;

        vm.prank(address(helper));
        vm.expectRevert(ErrorsLib.BelowMinimumBorrow.selector);
        morpho.borrow(marketParams, firstBorrow, 0, BORROWER_1, BORROWER_1);
    }

    function testIncrementalBorrowAboveMinBorrow() public {
        // First borrow above minBorrow
        _borrowAs(BORROWER_1, MIN_BORROW_AMOUNT + 100e18);

        // Second borrow any amount should work since total remains above minBorrow
        _borrowAs(BORROWER_1, 50e18);

        assertGt(_getBorrowBalance(BORROWER_1), MIN_BORROW_AMOUNT, "Total debt should be above minBorrow");
    }

    // Test: Basic Repay Scenarios

    function testFullRepaymentToZero() public {
        // Borrow first
        _borrowAs(BORROWER_1, LARGE_BORROW);
        uint256 debt = _getBorrowBalance(BORROWER_1);

        // Full repayment should succeed even though it crosses minBorrow threshold
        _repayAs(BORROWER_1, debt);

        assertEq(_getBorrowBalance(BORROWER_1), 0, "Debt should be fully repaid");
    }

    function testPartialRepayAboveMinBorrow() public {
        // Borrow a large amount
        _borrowAs(BORROWER_1, LARGE_BORROW);

        // Partial repay leaving debt above minBorrow
        uint256 repayAmount = LARGE_BORROW - MIN_BORROW_AMOUNT - 100e18;
        _repayAs(BORROWER_1, repayAmount);

        assertGt(_getBorrowBalance(BORROWER_1), MIN_BORROW_AMOUNT, "Remaining debt should be above minBorrow");
    }

    function testPartialRepayExactlyMinBorrow() public {
        // Borrow a large amount
        _borrowAs(BORROWER_1, LARGE_BORROW);

        // Partial repay leaving debt exactly at minBorrow
        uint256 repayAmount = LARGE_BORROW - MIN_BORROW_AMOUNT;
        _repayAs(BORROWER_1, repayAmount);

        // Allow for small rounding difference
        assertApproxEqAbs(_getBorrowBalance(BORROWER_1), MIN_BORROW_AMOUNT, 2, "Remaining debt should be minBorrow");
    }

    function testPartialRepayBelowMinBorrowReverts() public {
        // Borrow a large amount
        _borrowAs(BORROWER_1, LARGE_BORROW);

        // Try to partially repay leaving debt below minBorrow
        uint256 repayAmount = LARGE_BORROW - MIN_BORROW_AMOUNT + 1;

        loanToken.setBalance(BORROWER_1, repayAmount);
        vm.startPrank(BORROWER_1);
        loanToken.approve(address(morpho), repayAmount);

        vm.expectRevert(ErrorsLib.BelowMinimumBorrow.selector);
        morpho.repay(marketParams, repayAmount, 0, BORROWER_1, "");
        vm.stopPrank();
    }

    function testRepayFromLargeDebtToZero() public {
        // Borrow well above minBorrow
        _borrowAs(BORROWER_1, LARGE_BORROW * 2);
        uint256 debt = _getBorrowBalance(BORROWER_1);

        // Can repay all at once to zero, skipping minBorrow threshold
        _repayAs(BORROWER_1, debt);

        assertEq(_getBorrowBalance(BORROWER_1), 0, "Should be able to fully repay large debt");
    }

    // Test: Edge Cases & Configuration

    function testMinBorrowZeroDisablesCheck() public {
        // Set minBorrow to 0
        _setMinBorrow(0);

        // Should be able to borrow any amount
        uint256 smallBorrow = 1e18;
        _borrowAs(BORROWER_1, smallBorrow);

        assertEq(_getBorrowBalance(BORROWER_1), smallBorrow, "Should allow small borrow when minBorrow is 0");

        // Should be able to partially repay to any amount
        _repayAs(BORROWER_1, smallBorrow - 1);

        assertGt(_getBorrowBalance(BORROWER_1), 0, "Should allow tiny remaining debt when minBorrow is 0");
    }

    function testMinBorrowChangesDuringMarketLife() public {
        // Borrow at current minBorrow
        _borrowAs(BORROWER_1, MIN_BORROW_AMOUNT);

        // Increase minBorrow
        _setMinBorrow(MIN_BORROW_AMOUNT * 2);

        // Existing position should remain valid (no liquidation)
        assertEq(_getBorrowBalance(BORROWER_1), MIN_BORROW_AMOUNT, "Existing debt unchanged by config change");

        // But new borrows must respect new minBorrow
        vm.prank(address(helper));
        vm.expectRevert(ErrorsLib.BelowMinimumBorrow.selector);
        morpho.borrow(marketParams, 100e18, 0, BORROWER_2, BORROWER_2);
    }

    function testBorrowWithAccruedInterest() public {
        // Deploy and set a ConfigurableIrmMock with non-zero interest rate
        ConfigurableIrmMock configurableIrm = new ConfigurableIrmMock();
        configurableIrm.setApr(0.1e18); // 10% APR for testing

        // Update market params with the new IRM
        marketParams.irm = address(configurableIrm);
        id = marketParams.id();

        // Enable the new IRM and create the market
        vm.prank(OWNER);
        morpho.enableIrm(address(configurableIrm));
        vm.prank(OWNER);
        morpho.createMarket(marketParams);

        // Initialize the market to prevent freezing
        vm.warp(block.timestamp + CYCLE_DURATION);
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(marketParams.creditLine);
        morphoCredit.closeCycleAndPostObligations(id, block.timestamp, borrowers, repaymentBps, endingBalances);

        // Set up supply and credit line
        _supply(SUPPLIER, SUPPLY_AMOUNT);
        _setCreditLine(BORROWER_1, SUPPLY_AMOUNT);

        // Borrow exactly minBorrow
        _borrowAs(BORROWER_1, MIN_BORROW_AMOUNT);

        // Let time pass to accrue interest
        vm.warp(block.timestamp + 30 days);

        // Trigger interest accrual by calling accrueInterest
        morpho.accrueInterest(marketParams);

        // Accrued interest shouldn't trigger minBorrow violation
        uint256 debtWithInterest = _getBorrowBalance(BORROWER_1);
        assertGt(debtWithInterest, MIN_BORROW_AMOUNT, "Debt should have grown with interest");

        // Post new cycle since we're past cycle duration (market would be frozen)
        vm.prank(marketParams.creditLine);
        morphoCredit.closeCycleAndPostObligations(id, block.timestamp, borrowers, repaymentBps, endingBalances);

        // Can still perform operations
        _borrowAs(BORROWER_1, 100e18);
        assertGt(_getBorrowBalance(BORROWER_1), debtWithInterest, "Should be able to borrow more");
    }

    // Test: Complex Multi-User Scenarios

    function testMultipleBorrowersIndependentMinBorrow() public {
        // Both borrowers borrow above minBorrow
        _borrowAs(BORROWER_1, MIN_BORROW_AMOUNT + 100e18);
        _borrowAs(BORROWER_2, MIN_BORROW_AMOUNT + 200e18);

        assertGt(_getBorrowBalance(BORROWER_1), MIN_BORROW_AMOUNT, "Borrower 1 above minBorrow");
        assertGt(_getBorrowBalance(BORROWER_2), MIN_BORROW_AMOUNT, "Borrower 2 above minBorrow");

        // One borrower fully repays
        _repayAs(BORROWER_1, _getBorrowBalance(BORROWER_1));

        assertEq(_getBorrowBalance(BORROWER_1), 0, "Borrower 1 fully repaid");
        assertGt(_getBorrowBalance(BORROWER_2), MIN_BORROW_AMOUNT, "Borrower 2 unaffected");
    }

    function testBorrowerCannotCircumventViaMultipleAccounts() public {
        // Try to borrow small amounts from multiple accounts
        // This should fail as each account must meet minBorrow independently

        uint256 smallAmount = MIN_BORROW_AMOUNT / 2;

        vm.prank(address(helper));
        vm.expectRevert(ErrorsLib.BelowMinimumBorrow.selector);
        morpho.borrow(marketParams, smallAmount, 0, BORROWER_1, BORROWER_1);

        vm.prank(address(helper));
        vm.expectRevert(ErrorsLib.BelowMinimumBorrow.selector);
        morpho.borrow(marketParams, smallAmount, 0, BORROWER_2, BORROWER_2);
    }

    function testMarketWideMinBorrowEnforcement() public {
        // Multiple borrowers with valid positions
        _borrowAs(BORROWER_1, MIN_BORROW_AMOUNT * 2);
        _borrowAs(BORROWER_2, MIN_BORROW_AMOUNT * 3);

        Market memory market = morpho.market(id);
        uint256 totalBorrow = market.totalBorrowAssets;

        assertEq(totalBorrow, MIN_BORROW_AMOUNT * 5, "Total market borrow should be sum of individual borrows");

        // Each position must still individually respect minBorrow
        assertGt(_getBorrowBalance(BORROWER_1), MIN_BORROW_AMOUNT, "Each position respects minBorrow");
        assertGt(_getBorrowBalance(BORROWER_2), MIN_BORROW_AMOUNT, "Each position respects minBorrow");
    }

    // Test: Fuzz Testing

    function testFuzzBorrowAmount(uint256 borrowAmount) public {
        borrowAmount = bound(borrowAmount, 1, SUPPLY_AMOUNT);

        // Set up supply and credit line
        _supply(SUPPLIER, SUPPLY_AMOUNT);
        _setCreditLine(BORROWER_1, SUPPLY_AMOUNT);

        if (borrowAmount < MIN_BORROW_AMOUNT) {
            vm.prank(address(helper));
            vm.expectRevert(ErrorsLib.BelowMinimumBorrow.selector);
            morpho.borrow(marketParams, borrowAmount, 0, BORROWER_1, BORROWER_1);
        } else {
            _borrowAs(BORROWER_1, borrowAmount);
            assertGe(_getBorrowBalance(BORROWER_1), MIN_BORROW_AMOUNT, "Borrow should respect minBorrow");
        }
    }

    function testFuzzRepayAmount(uint256 initialBorrow, uint256 repayAmount) public {
        initialBorrow = bound(initialBorrow, MIN_BORROW_AMOUNT, SUPPLY_AMOUNT);
        repayAmount = bound(repayAmount, 1, initialBorrow);

        // Set up supply and credit line
        _supply(SUPPLIER, SUPPLY_AMOUNT);
        _setCreditLine(BORROWER_1, SUPPLY_AMOUNT);

        _borrowAs(BORROWER_1, initialBorrow);
        uint256 debtBefore = _getBorrowBalance(BORROWER_1);

        uint256 expectedRemaining = debtBefore > repayAmount ? debtBefore - repayAmount : 0;

        if (expectedRemaining > 0 && expectedRemaining < MIN_BORROW_AMOUNT) {
            // Should revert
            loanToken.setBalance(BORROWER_1, repayAmount);
            vm.startPrank(BORROWER_1);
            loanToken.approve(address(morpho), repayAmount);
            vm.expectRevert(ErrorsLib.BelowMinimumBorrow.selector);
            morpho.repay(marketParams, repayAmount, 0, BORROWER_1, "");
            vm.stopPrank();
        } else {
            // Should succeed
            _repayAs(BORROWER_1, repayAmount);
            assertApproxEqAbs(_getBorrowBalance(BORROWER_1), expectedRemaining, 2, "Repay should work");
        }
    }
}
