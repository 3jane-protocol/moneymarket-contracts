// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FeeRecipientWithdrawRegressionTest
/// @notice Regression test for Sherlock issue #23 - Fee recipient withdrawal capability
/// @dev This test uses a real MorphoCredit instance (not the mock) to properly test the withdrawal restriction
contract FeeRecipientWithdrawRegressionTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    // Separate MorphoCredit instance for testing real restrictions
    IMorpho realMorpho;
    address realMorphoAddress;

    // Test market on the real instance
    MarketParams testMarketParams;
    Id testMarketId;

    // Credit line for the test market
    CreditLineMock creditLine;

    // Test constants
    uint256 constant SUPPLY_AMOUNT = 10000e18;
    uint256 constant BORROW_AMOUNT = 1000e18;
    uint256 constant FEE_RATE = 0.1e18; // 10% fee
    uint128 constant PREMIUM_RATE = 3170979; // ~10% APR

    function setUp() public override {
        super.setUp();

        // Deploy a real MorphoCredit instance (not mock) to test actual restrictions
        MorphoCredit morphoCreditImpl = new MorphoCredit(address(protocolConfig));
        TransparentUpgradeableProxy realMorphoProxy = new TransparentUpgradeableProxy(
            address(morphoCreditImpl),
            address(proxyAdmin),
            abi.encodeWithSelector(MorphoCredit.initialize.selector, OWNER)
        );

        realMorphoAddress = address(realMorphoProxy);
        realMorpho = IMorpho(realMorphoAddress);

        // Set up USD3 address to enable supply/withdraw through USD3 only
        address mockUsd3 = makeAddr("MockUSD3");
        vm.prank(OWNER);
        IMorphoCredit(realMorphoAddress).setUsd3(mockUsd3);

        // Deploy credit line
        creditLine = new CreditLineMock(realMorphoAddress);

        // Create test market params on the real instance
        testMarketParams = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(creditLine)
        );
        testMarketId = testMarketParams.id();

        // Set up the market on the real instance
        vm.startPrank(OWNER);
        realMorpho.enableIrm(address(irm));
        realMorpho.enableLltv(DEFAULT_TEST_LLTV);
        realMorpho.createMarket(testMarketParams);
        realMorpho.setFee(testMarketParams, FEE_RATE);
        // FEE_RECIPIENT is already set in the parent setUp
        vm.stopPrank();

        // Supply liquidity through USD3
        loanToken.setBalance(mockUsd3, SUPPLY_AMOUNT);
        vm.startPrank(mockUsd3);
        loanToken.approve(realMorphoAddress, type(uint256).max);
        realMorpho.supply(testMarketParams, SUPPLY_AMOUNT, 0, mockUsd3, "");
        vm.stopPrank();
    }

    /// @notice Test that fee recipient can withdraw their earned shares
    /// @dev Verifies fee recipient can withdraw fee shares earned from interest
    function testFeeRecipientCanWithdrawEarnedShares() public {
        // Set credit line with premium for borrower
        vm.prank(address(creditLine));
        IMorphoCredit(realMorphoAddress).setCreditLine(testMarketId, BORROWER, BORROW_AMOUNT * 2, PREMIUM_RATE);

        // Set helper to allow borrowing (real MorphoCredit requires this)
        address mockHelper = makeAddr("MockHelper");
        vm.prank(OWNER);
        IMorphoCredit(realMorphoAddress).setHelper(mockHelper);

        // Fund borrower for repayments
        loanToken.setBalance(BORROWER, BORROW_AMOUNT * 2);

        // Borrow through helper
        vm.startPrank(mockHelper);
        realMorpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);
        vm.stopPrank();

        // Fast forward to accrue interest
        skip(30 days);

        // Repay partial amount to trigger fee accrual
        vm.startPrank(BORROWER);
        loanToken.approve(realMorphoAddress, type(uint256).max);
        realMorpho.repay(testMarketParams, BORROW_AMOUNT / 2, 0, BORROWER, "");
        vm.stopPrank();

        // Verify fee recipient has earned shares
        Position memory feePos = realMorpho.position(testMarketId, FEE_RECIPIENT);
        assertGt(feePos.supplyShares, 0, "Fee recipient should have earned shares");

        // Calculate the value of fee shares
        Market memory marketState = realMorpho.market(testMarketId);
        uint256 feeValue =
            uint256(feePos.supplyShares).toAssetsDown(marketState.totalSupplyAssets, marketState.totalSupplyShares);
        assertGt(feeValue, 0, "Fee value should be positive");

        console2.log("Fee recipient earned shares:", feePos.supplyShares);
        console2.log("Fee value in assets:", feeValue);

        // Fee recipient withdraws their earned shares
        uint256 balanceBefore = loanToken.balanceOf(FEE_RECIPIENT);

        vm.prank(FEE_RECIPIENT);
        (uint256 withdrawn,) =
            realMorpho.withdraw(testMarketParams, 0, feePos.supplyShares, FEE_RECIPIENT, FEE_RECIPIENT);

        uint256 balanceAfter = loanToken.balanceOf(FEE_RECIPIENT);
        assertGt(withdrawn, 0, "Should have withdrawn assets");
        assertEq(balanceAfter - balanceBefore, withdrawn, "Balance should increase by withdrawn amount");

        Position memory finalPos = realMorpho.position(testMarketId, FEE_RECIPIENT);
        assertEq(finalPos.supplyShares, 0, "All shares should be withdrawn");
    }

    /// @notice Test that fee recipient can withdraw accumulated fees
    /// @dev Verifies fee recipient can withdraw fees accumulated over multiple periods
    function testFeeRecipientCanWithdrawAccumulatedFees() public {
        // Set credit line with premium
        vm.prank(address(creditLine));
        IMorphoCredit(realMorphoAddress).setCreditLine(testMarketId, BORROWER, BORROW_AMOUNT * 2, PREMIUM_RATE);

        // Set helper for borrowing
        address mockHelper = makeAddr("MockHelper");
        vm.prank(OWNER);
        IMorphoCredit(realMorphoAddress).setHelper(mockHelper);

        // Fund borrower
        loanToken.setBalance(BORROWER, BORROW_AMOUNT * 3);

        // Initial borrow
        vm.prank(mockHelper);
        realMorpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        uint256 totalFeeShares = 0;

        // Multiple repayments over time to generate fees
        vm.startPrank(BORROWER);
        loanToken.approve(realMorphoAddress, type(uint256).max);

        for (uint256 i = 0; i < 3; i++) {
            skip(10 days);

            // Each repayment triggers fee accrual
            realMorpho.repay(testMarketParams, BORROW_AMOUNT / 10, 0, BORROWER, "");

            Position memory feePos = realMorpho.position(testMarketId, FEE_RECIPIENT);
            assertGt(feePos.supplyShares, totalFeeShares, "Fees should accumulate");
            totalFeeShares = feePos.supplyShares;
        }
        vm.stopPrank();

        console2.log("Total accumulated fee shares:", totalFeeShares);

        // Fee recipient withdraws all accumulated fees
        uint256 balanceBefore = loanToken.balanceOf(FEE_RECIPIENT);

        vm.prank(FEE_RECIPIENT);
        (uint256 withdrawn,) = realMorpho.withdraw(testMarketParams, 0, totalFeeShares, FEE_RECIPIENT, FEE_RECIPIENT);

        uint256 balanceAfter = loanToken.balanceOf(FEE_RECIPIENT);
        assertGt(withdrawn, 0, "Should have withdrawn accumulated fees");
        assertEq(balanceAfter - balanceBefore, withdrawn, "Balance should increase by withdrawn amount");

        Position memory finalPos = realMorpho.position(testMarketId, FEE_RECIPIENT);
        assertEq(finalPos.supplyShares, 0, "All accumulated shares withdrawn");
    }

    /// @notice Test withdrawal behavior when fee recipient changes
    /// @dev Verifies both old and new fee recipients can withdraw their respective shares
    function testFeeRecipientChangeAndWithdrawal() public {
        // Generate fees for original fee recipient
        vm.prank(address(creditLine));
        IMorphoCredit(realMorphoAddress).setCreditLine(testMarketId, BORROWER, BORROW_AMOUNT * 2, PREMIUM_RATE);

        address mockHelper = makeAddr("MockHelper");
        vm.prank(OWNER);
        IMorphoCredit(realMorphoAddress).setHelper(mockHelper);

        loanToken.setBalance(BORROWER, BORROW_AMOUNT * 2);

        vm.prank(mockHelper);
        realMorpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        skip(30 days);

        vm.startPrank(BORROWER);
        loanToken.approve(realMorphoAddress, type(uint256).max);
        realMorpho.repay(testMarketParams, BORROW_AMOUNT / 2, 0, BORROWER, "");
        vm.stopPrank();

        // Verify original fee recipient has shares
        Position memory oldFeePos = realMorpho.position(testMarketId, FEE_RECIPIENT);
        assertGt(oldFeePos.supplyShares, 0, "Original fee recipient should have shares");
        uint256 oldFeeShares = oldFeePos.supplyShares;

        // Change fee recipient
        address newFeeRecipient = makeAddr("NewFeeRecipient");
        vm.prank(OWNER);
        realMorpho.setFeeRecipient(newFeeRecipient);

        // Original fee recipient can withdraw their shares
        vm.prank(FEE_RECIPIENT);
        (uint256 withdrawn,) = realMorpho.withdraw(testMarketParams, 0, oldFeeShares, FEE_RECIPIENT, FEE_RECIPIENT);
        assertGt(withdrawn, 0, "Original fee recipient should withdraw their shares");

        Position memory afterWithdraw = realMorpho.position(testMarketId, FEE_RECIPIENT);
        assertEq(afterWithdraw.supplyShares, 0, "Original fee recipient shares should be withdrawn");

        // Generate fees for new fee recipient
        skip(30 days);
        vm.prank(BORROWER);
        realMorpho.repay(testMarketParams, BORROW_AMOUNT / 4, 0, BORROWER, "");

        // New fee recipient can also withdraw their shares
        Position memory newFeePos = realMorpho.position(testMarketId, newFeeRecipient);
        assertGt(newFeePos.supplyShares, 0, "New fee recipient should have shares");

        vm.prank(newFeeRecipient);
        (uint256 newWithdrawn,) =
            realMorpho.withdraw(testMarketParams, 0, newFeePos.supplyShares, newFeeRecipient, newFeeRecipient);
        assertGt(newWithdrawn, 0, "New fee recipient should withdraw their shares");
    }

    /// @notice Test successful fee recipient withdrawal
    /// @dev Verifies complete withdrawal flow for fee recipient
    function testFeeRecipientWithdrawsSuccessfully() public {
        // Generate fees
        vm.prank(address(creditLine));
        IMorphoCredit(realMorphoAddress).setCreditLine(testMarketId, BORROWER, BORROW_AMOUNT * 2, PREMIUM_RATE);

        address mockHelper = makeAddr("MockHelper");
        vm.prank(OWNER);
        IMorphoCredit(realMorphoAddress).setHelper(mockHelper);

        loanToken.setBalance(BORROWER, BORROW_AMOUNT * 2);

        vm.prank(mockHelper);
        realMorpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        skip(7 days);

        vm.startPrank(BORROWER);
        loanToken.approve(realMorphoAddress, type(uint256).max);
        realMorpho.repay(testMarketParams, 100e18, 0, BORROWER, "");
        vm.stopPrank();

        // Fee recipient withdraws their earned shares
        Position memory feePos = realMorpho.position(testMarketId, FEE_RECIPIENT);
        uint256 balanceBefore = loanToken.balanceOf(FEE_RECIPIENT);

        vm.prank(FEE_RECIPIENT);
        (uint256 withdrawn,) =
            realMorpho.withdraw(testMarketParams, 0, feePos.supplyShares, FEE_RECIPIENT, FEE_RECIPIENT);

        uint256 balanceAfter = loanToken.balanceOf(FEE_RECIPIENT);
        assertGt(withdrawn, 0, "Should have withdrawn assets");
        assertEq(balanceAfter - balanceBefore, withdrawn, "Balance should increase by withdrawn amount");

        Position memory finalPos = realMorpho.position(testMarketId, FEE_RECIPIENT);
        assertEq(finalPos.supplyShares, 0, "All shares should be withdrawn");
    }
}
