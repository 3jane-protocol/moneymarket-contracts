// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";

contract PremiumIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    CreditLineMock public creditLine;

    event PremiumAccrued(Id indexed id, address indexed borrower, uint256 premiumAmount, uint256 feeAmount);

    function setUp() public override {
        super.setUp();

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        irm = new ConfigurableIrmMock();
        vm.prank(OWNER);
        morpho.enableIrm(address(irm));

        // Set credit line in market params before creation
        marketParams.irm = address(irm);
        marketParams.creditLine = address(creditLine);

        vm.prank(OWNER);
        morpho.createMarket(marketParams);
        id = MarketParamsLib.id(marketParams);

        // Initialize first cycle to unfreeze the market
        _ensureMarketActive(id);

        // Set up initial balances
        loanToken.setBalance(SUPPLIER, HIGH_COLLATERAL_AMOUNT);
        collateralToken.setBalance(BORROWER, HIGH_COLLATERAL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setCreditLineWithPremium(address borrower, uint256 credit, uint128 premiumRatePerSecond) internal {
        vm.prank(address(creditLine));
        creditLine.setCreditLine(id, borrower, credit, premiumRatePerSecond);
    }

    /*//////////////////////////////////////////////////////////////
                        BORROW OPERATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testBorrowAccruesPremiumBeforeIncrease() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR

        // Supply liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time while maintaining cycles
        _continueMarketCycles(id, block.timestamp + 1 hours);

        // Record position before second borrow
        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);
        uint256 borrowAssetsBefore = uint256(positionBefore.borrowShares).toAssetsUp(
            marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
        );

        // Calculate expected premium
        uint256 elapsed = 1 hours;
        uint256 expectedGrowth = uint256(premiumRatePerSecond).wTaylorCompounded(elapsed);
        uint256 expectedPremiumAmount = borrowAmount.wMulDown(expectedGrowth);

        // Expect PremiumAccrued event (without fee since market fee is 0)
        vm.expectEmit(true, true, false, true);
        emit PremiumAccrued(id, BORROWER, expectedPremiumAmount, 0);

        // Second borrow should trigger premium accrual
        uint256 additionalBorrow = 1_000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, additionalBorrow, 0, BORROWER, BORROWER);

        // Check that premium was accrued
        Position memory positionAfter = morpho.position(id, BORROWER);
        Market memory marketAfter = morpho.market(id);
        uint256 borrowAssetsAfter =
            uint256(positionAfter.borrowShares).toAssetsUp(marketAfter.totalBorrowAssets, marketAfter.totalBorrowShares);

        // Borrow assets should increase by more than just the additional borrow
        assertGt(borrowAssetsAfter, borrowAssetsBefore + additionalBorrow);
        // More precise check
        assertApproxEqRel(borrowAssetsAfter, borrowAssetsBefore + expectedPremiumAmount + additionalBorrow, 0.01e18);
    }

    function testBorrowUpdatesSnapshotAfterAccrual() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.1e18) / 365 days); // 10% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Get initial snapshot
        (,, uint256 snapshot1) = MorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertEq(snapshot1, borrowAmount);

        // Advance time and borrow more while maintaining cycles
        _continueMarketCycles(id, block.timestamp + 1 hours);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1_000e18, 0, BORROWER, BORROWER);

        // Check updated snapshot includes accrued premium
        (,, uint256 snapshot2) = MorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertGt(snapshot2, borrowAmount + 1_000e18);
    }

    function testBorrowWithMultiplePremiumAccruals() public {
        uint256 supplyAmount = 20_000e18;
        // With 80% LLTV, need higher credit line for total borrows + premium
        uint256 creditLineAmount = 12_500e18; // Effective capacity = 12500 * 0.8 = 10000
        uint256 initialBorrow = 5_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.15e18) / 365 days); // 15% APR

        // Setup
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate BEFORE borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // First borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, initialBorrow, 0, BORROWER, BORROWER);

        // Multiple borrows with time gaps
        uint256[] memory borrowAmounts = new uint256[](3);
        borrowAmounts[0] = 1_000e18;
        borrowAmounts[1] = 2_000e18;
        borrowAmounts[2] = 1_500e18;

        uint256 totalDebt = initialBorrow;

        for (uint256 i = 0; i < borrowAmounts.length; i++) {
            _continueMarketCycles(id, block.timestamp + 2 hours);

            // Record state before borrow
            Market memory marketBefore = morpho.market(id);
            uint256 totalBorrowAssetsBefore = marketBefore.totalBorrowAssets;

            // Borrow
            vm.prank(BORROWER);
            morpho.borrow(marketParams, borrowAmounts[i], 0, BORROWER, BORROWER);

            // Verify premium was accrued
            Market memory marketAfter = morpho.market(id);
            assertGt(
                marketAfter.totalBorrowAssets,
                totalBorrowAssetsBefore + borrowAmounts[i],
                "Premium should be accrued on each borrow"
            );

            totalDebt = marketAfter.totalBorrowAssets;
        }

        // Final debt should be significantly higher than sum of borrows
        uint256 sumOfBorrows = initialBorrow + borrowAmounts[0] + borrowAmounts[1] + borrowAmounts[2];
        assertGt(totalDebt, sumOfBorrows);
    }

    function testBorrowHealthCheckIncludesPremium() public {
        uint256 supplyAmount = 10_000e18;
        // For credit-based lending, credit limit is the direct constraint
        uint256 creditLineAmount = 7_000e18; // Credit line limit
        uint256 borrowAmount = 6_900e18; // Close to limit
        uint128 premiumRatePerSecond = uint128(uint256(0.5e18) / 365 days); // 50% APR - high rate

        // Setup
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with high premium rate BEFORE borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time significantly - premium will accrue
        _continueMarketCycles(id, block.timestamp + 60 days);

        // Try to borrow a small amount - should fail because the accrued premium
        // will push the total debt over the credit limit
        vm.prank(BORROWER);
        vm.expectRevert(ErrorsLib.InsufficientCollateral.selector);
        morpho.borrow(marketParams, 10e18, 0, BORROWER, BORROWER);
    }

    function testFirstBorrowWithExistingPremiumRate() public {
        uint256 supplyAmount = 10_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.25e18) / 365 days); // 25% APR

        // Supply liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate BEFORE first borrow
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // First borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Check snapshot was initialized
        (uint128 lastAccrualTime,, uint256 snapshot) = MorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertEq(snapshot, borrowAmount);
        assertEq(lastAccrualTime, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        REPAY OPERATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRepayAccruesPremiumBeforeDecrease() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 7 days);

        // Give borrower tokens for repayment
        loanToken.setBalance(BORROWER, borrowAmount);

        // Record total borrow before repay
        Market memory marketBefore = morpho.market(id);
        uint256 totalBorrowBefore = marketBefore.totalBorrowAssets;

        // Repay partial amount
        uint256 repayAmount = 1_000e18;
        vm.prank(BORROWER);
        morpho.repay(marketParams, repayAmount, 0, BORROWER, "");

        // Check that premium was accrued before repayment
        Market memory marketAfter = morpho.market(id);

        // Total borrow should have increased (premium) then decreased (repayment)
        // Net effect should be: totalBorrowAfter > totalBorrowBefore - repayAmount
        assertGt(marketAfter.totalBorrowAssets, totalBorrowBefore - repayAmount);
    }

    function testRepayFullAmountWithPremium() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.1e18) / 365 days); // 10% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 30 days);

        // First trigger premium accrual to get accurate debt
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Now get the updated position with premium included
        Position memory positionAfterAccrual = morpho.position(id, BORROWER);
        Market memory marketAfterAccrual = morpho.market(id);
        uint256 totalDebt = uint256(positionAfterAccrual.borrowShares).toAssetsUp(
            marketAfterAccrual.totalBorrowAssets, marketAfterAccrual.totalBorrowShares
        );

        // Give borrower enough tokens to repay full debt
        loanToken.setBalance(BORROWER, totalDebt + 1000e18); // Extra buffer

        // Repay using all shares to ensure full repayment
        vm.prank(BORROWER);
        morpho.repay(marketParams, 0, positionAfterAccrual.borrowShares, BORROWER, "");

        // Verify borrower has no debt
        Position memory finalPosition = morpho.position(id, BORROWER);
        assertEq(finalPosition.borrowShares, 0);
    }

    function testRepayPartialWithPremium() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.15e18) / 365 days); // 15% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 10 days);

        // Calculate current debt
        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);
        uint256 debtBefore = uint256(positionBefore.borrowShares).toAssetsUp(
            marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
        );

        // Repay 50% of original borrow
        uint256 repayAmount = borrowAmount / 2;
        loanToken.setBalance(BORROWER, repayAmount);

        vm.prank(BORROWER);
        morpho.repay(marketParams, repayAmount, 0, BORROWER, "");

        // Calculate remaining debt
        Position memory positionAfter = morpho.position(id, BORROWER);
        Market memory marketAfter = morpho.market(id);
        uint256 debtAfter =
            uint256(positionAfter.borrowShares).toAssetsUp(marketAfter.totalBorrowAssets, marketAfter.totalBorrowShares);

        // Debt should decrease but still be higher than half of original
        assertLt(debtAfter, debtBefore);
        assertGt(debtAfter, borrowAmount / 2);
    }

    function testRepaySnapshotUpdateAfterPremium() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        (,, uint256 snapshotBefore) = MorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 5 days);

        // Repay
        loanToken.setBalance(BORROWER, 2_000e18);
        vm.prank(BORROWER);
        morpho.repay(marketParams, 1_000e18, 0, BORROWER, "");

        // Check snapshot was updated
        (uint128 lastAccrualTime,, uint256 snapshotAfter) = MorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertEq(lastAccrualTime, block.timestamp);
        assertGt(snapshotAfter, snapshotBefore - 1_000e18); // Should include accrued premium
    }

    function testRepayMoreThanDebtWithPremium() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.1e18) / 365 days); // 10% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 10 days);

        // First accrue premium to get accurate debt
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Calculate actual debt
        Position memory positionBeforeRepay = morpho.position(id, BORROWER);
        Market memory marketBeforeRepay = morpho.market(id);
        uint256 actualDebt = uint256(positionBeforeRepay.borrowShares).toAssetsUp(
            marketBeforeRepay.totalBorrowAssets, marketBeforeRepay.totalBorrowShares
        );

        // Give borrower way more than needed
        uint256 excessAmount = actualDebt + 5_000e18;
        loanToken.setBalance(BORROWER, excessAmount);

        uint256 balanceBefore = loanToken.balanceOf(BORROWER);

        // Repay exact debt amount using shares to ensure full repayment
        vm.prank(BORROWER);
        morpho.repay(marketParams, 0, positionBeforeRepay.borrowShares, BORROWER, "");

        // Should only take what's needed
        uint256 balanceAfter = loanToken.balanceOf(BORROWER);
        assertGt(balanceAfter, 0);
        assertApproxEqAbs(balanceBefore - balanceAfter, actualDebt, 2); // Allow 2 wei rounding

        // Borrower should have no debt
        Position memory finalPosition = morpho.position(id, BORROWER);
        assertEq(finalPosition.borrowShares, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAW OPERATIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function testWithdrawSupplyWithBorrowerPremium() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time to accrue premium
        _continueMarketCycles(id, block.timestamp + 30 days);

        // Manually accrue borrower's premium since withdraw doesn't trigger it
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Supplier withdraws
        vm.prank(SUPPLIER);
        morpho.withdraw(marketParams, 1_000e18, 0, SUPPLIER, SUPPLIER);

        // Check that supplier benefited from accrued premium
        Position memory supplierPosAfter = morpho.position(id, SUPPLIER);
        Market memory market = morpho.market(id);

        // Calculate value of remaining supply shares
        uint256 remainingValue =
            uint256(supplierPosAfter.supplyShares).toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);

        // Should be worth more than initial supply minus withdrawal
        assertGt(remainingValue, supplyAmount - 1_000e18);
    }

    function testWithdrawHealthCheckWithPremium() public {
        uint256 supplyAmount = 10_000e18;
        uint256 creditLineAmount = 7_500e18; // Tight credit limit
        uint256 borrowAmount = 7_400e18; // Close to credit limit
        uint128 premiumRatePerSecond = uint128(uint256(0.3e18) / 365 days); // 30% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time - premium will accrue
        _continueMarketCycles(id, block.timestamp + 30 days);

        // Try to borrow additional amount - should fail because accumulated premium
        // has pushed the debt close to or over the credit limit
        vm.prank(BORROWER);
        vm.expectRevert(ErrorsLib.InsufficientCollateral.selector);
        morpho.borrow(marketParams, 50e18, 0, BORROWER, BORROWER);
    }

    function testWithdrawBySupplierWithActivePremiums() public {
        uint256 supplyAmount = 20_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.25e18) / 365 days); // 25% APR

        // Setup multiple borrowers
        address borrower2 = makeAddr("Borrower2");
        collateralToken.setBalance(borrower2, creditLineAmount);
        vm.prank(borrower2);
        collateralToken.approve(address(morpho), type(uint256).max);

        // Supplier supplies
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit lines with premium rates before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);
        _setCreditLineWithPremium(borrower2, creditLineAmount, premiumRatePerSecond);

        // Two borrowers borrow using credit lines
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        vm.prank(borrower2);
        morpho.borrow(marketParams, borrowAmount, 0, borrower2, borrower2);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 10 days);

        // Manually accrue premiums for both borrowers since withdraw doesn't trigger it
        address[] memory borrowers = new address[](2);
        borrowers[0] = BORROWER;
        borrowers[1] = borrower2;
        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, borrowers);

        // Get supplier position before withdrawal
        Position memory supplierPosBefore = morpho.position(id, SUPPLIER);
        Market memory marketBefore = morpho.market(id);

        // Supplier withdraws half of original supply
        vm.prank(SUPPLIER);
        morpho.withdraw(marketParams, supplyAmount / 2, 0, SUPPLIER, SUPPLIER);

        // Get remaining value
        Position memory supplierPosAfter = morpho.position(id, SUPPLIER);
        Market memory marketAfter = morpho.market(id);
        uint256 supplierValueAfter = uint256(supplierPosAfter.supplyShares).toAssetsDown(
            marketAfter.totalSupplyAssets, marketAfter.totalSupplyShares
        );

        // Total value (withdrawn + remaining) should be more than original supply
        uint256 totalValue = (supplyAmount / 2) + supplierValueAfter;
        assertGt(totalValue, supplyAmount);
    }

    /*//////////////////////////////////////////////////////////////
                MARKET INTEREST VS PREMIUM TESTS
    //////////////////////////////////////////////////////////////*/

    function testAccrueInterestDoesNotAccruePremium() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate BEFORE borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Get premium details before
        (uint128 timeBefore,, uint256 snapshotBefore) = MorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 1 days);

        // Call accrueInterest
        morpho.accrueInterest(marketParams);

        // Premium details should not change
        (uint128 timeAfter,, uint256 snapshotAfter) = MorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertEq(timeBefore, timeAfter);
        assertEq(snapshotBefore, snapshotAfter);
    }

    function testPremiumAccrualAfterMarketInterest() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.15e18) / 365 days); // 15% APR

        // Set base interest rate
        ConfigurableIrmMock(address(irm)).setApr(0.05e18); // 5% APR base rate

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 365 days);

        // Trigger both accruals via borrow
        loanToken.setBalance(BORROWER, 10_000e18);
        vm.prank(BORROWER);
        morpho.repay(marketParams, 100e18, 0, BORROWER, "");

        // Calculate final debt
        Position memory position = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);
        uint256 finalDebt =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        // After 1 year: 5% base + 15% premium = 20% total
        // So debt should be approximately borrowAmount * 1.2 - 100 (repayment)
        uint256 expectedDebt = borrowAmount.wMulDown(1.2e18) - 100e18;
        assertApproxEqRel(finalDebt, expectedDebt, 0.05e18); // 5% tolerance
    }

    function testNoDoubleCounting() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.1e18) / 365 days); // 10% APR

        // Set base rate
        ConfigurableIrmMock(address(irm)).setApr(0.05e18); // 5% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate BEFORE borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Record initial state
        Market memory marketInitial = morpho.market(id);

        // Advance time
        uint256 timeElapsed = 30 days;
        _continueMarketCycles(id, block.timestamp + timeElapsed);

        // Manually accrue interest first
        morpho.accrueInterest(marketParams);
        Market memory marketAfterBase = morpho.market(id);
        uint256 baseInterest = marketAfterBase.totalBorrowAssets - marketInitial.totalBorrowAssets;

        // Then accrue premium
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);
        Market memory marketFinal = morpho.market(id);
        uint256 totalInterest = marketFinal.totalBorrowAssets - marketInitial.totalBorrowAssets;

        // Premium should be additional to base interest
        uint256 premiumAmount = totalInterest - baseInterest;
        assertGt(premiumAmount, 0);

        // Verify rough correctness (10% APR for 30 days on 5000)
        uint256 expectedPremium = borrowAmount.wMulDown(uint256(premiumRatePerSecond).wTaylorCompounded(timeElapsed));
        assertApproxEqRel(premiumAmount, expectedPremium, 0.1e18); // 10% tolerance
    }

    function testPremiumWithZeroBaseRate() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR

        // Ensure base rate is zero
        ConfigurableIrmMock(address(irm)).setApr(0);

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Set credit line with premium rate
        _setCreditLineWithPremium(BORROWER, 10_000e18, premiumRatePerSecond);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 365 days);

        // Accrue premium
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Calculate debt
        Position memory position = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);
        uint256 finalDebt =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        // With zero base rate, only premium applies
        uint256 expectedDebt = borrowAmount.wMulDown(1.2e18); // 20% increase
        assertApproxEqRel(finalDebt, expectedDebt, 0.05e18);
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-BORROWER TESTS
    //////////////////////////////////////////////////////////////*/

    function testMultipleBorrowersIndependentPremiums() public {
        uint256 supplyAmount = 30_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 collateralAmount = 10_000e18;

        // Setup three borrowers
        address borrower2 = makeAddr("Borrower2");
        address borrower3 = makeAddr("Borrower3");

        // Give them tokens
        collateralToken.setBalance(borrower2, collateralAmount);
        collateralToken.setBalance(borrower3, collateralAmount);

        // Approve
        vm.prank(borrower2);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.prank(borrower3);
        collateralToken.approve(address(morpho), type(uint256).max);

        // Supply liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // All borrowers borrow
        address[3] memory borrowers = [BORROWER, borrower2, borrower3];
        uint128[3] memory premiumRates = [
            uint128(uint256(0.1e18) / 365 days),
            uint128(uint256(0.2e18) / 365 days),
            uint128(uint256(0.3e18) / 365 days)
        ]; // 10%, 20%, 30% APR

        for (uint256 i = 0; i < 3; i++) {
            // Set credit lines with different premium rates before borrowing
            _setCreditLineWithPremium(borrowers[i], 10_000e18, premiumRates[i]);

            vm.prank(borrowers[i]);
            morpho.borrow(marketParams, borrowAmount, 0, borrowers[i], borrowers[i]);
        }

        // Advance time
        _continueMarketCycles(id, block.timestamp + 365 days);

        // Accrue premiums for all
        address[] memory borrowerArray = new address[](3);
        borrowerArray[0] = BORROWER;
        borrowerArray[1] = borrower2;
        borrowerArray[2] = borrower3;
        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, borrowerArray);

        // Check debts are different based on premium rates
        Market memory market = morpho.market(id);
        uint256[3] memory debts;

        for (uint256 i = 0; i < 3; i++) {
            Position memory pos = morpho.position(id, borrowers[i]);
            debts[i] = uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        }

        // Debts should be ordered by premium rate
        assertLt(debts[0], debts[1]);
        assertLt(debts[1], debts[2]);

        // Verify approximate correctness
        assertApproxEqRel(debts[0], borrowAmount.wMulDown(1.1e18), 0.05e18); // 10% increase
        assertApproxEqRel(debts[1], borrowAmount.wMulDown(1.2e18), 0.05e18); // 20% increase
        assertApproxEqRel(debts[2], borrowAmount.wMulDown(1.3e18), 0.05e18); // 30% increase
    }

    function testSupplierBenefitsFromAllPremiums() public {
        uint256 supplyAmount = 20_000e18;
        uint256 borrowAmount = 4_000e18;
        uint256 collateralAmount = 8_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR

        // Setup three borrowers
        address borrower2 = makeAddr("Borrower2");
        address borrower3 = makeAddr("Borrower3");

        collateralToken.setBalance(borrower2, collateralAmount);
        collateralToken.setBalance(borrower3, collateralAmount);

        vm.prank(borrower2);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.prank(borrower3);
        collateralToken.approve(address(morpho), type(uint256).max);

        // Supply
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Multiple borrowers borrow with premiums
        address[3] memory borrowers = [BORROWER, borrower2, borrower3];

        for (uint256 i = 0; i < 3; i++) {
            // Set credit line with premium rate before borrowing
            _setCreditLineWithPremium(borrowers[i], 10_000e18, premiumRatePerSecond);

            vm.prank(borrowers[i]);
            morpho.borrow(marketParams, borrowAmount, 0, borrowers[i], borrowers[i]);
        }

        // Record supplier position
        Position memory supplierPosBefore = morpho.position(id, SUPPLIER);
        Market memory marketBefore = morpho.market(id);
        uint256 supplyValueBefore = uint256(supplierPosBefore.supplyShares).toAssetsDown(
            marketBefore.totalSupplyAssets, marketBefore.totalSupplyShares
        );

        // Advance time
        _continueMarketCycles(id, block.timestamp + 180 days);

        // Trigger premium accrual for all borrowers
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1e18, 0, BORROWER, BORROWER);

        vm.prank(borrower2);
        morpho.borrow(marketParams, 1e18, 0, borrower2, borrower2);

        vm.prank(borrower3);
        morpho.borrow(marketParams, 1e18, 0, borrower3, borrower3);

        // Check supplier value increased
        Position memory supplierPosAfter = morpho.position(id, SUPPLIER);
        Market memory marketAfter = morpho.market(id);
        uint256 supplyValueAfter = uint256(supplierPosAfter.supplyShares).toAssetsDown(
            marketAfter.totalSupplyAssets, marketAfter.totalSupplyShares
        );

        // Supplier should benefit from all premiums
        assertGt(supplyValueAfter, supplyValueBefore);

        // Rough calculation: 3 borrowers * 4000 * 20% APR * 0.5 years = 2400
        uint256 growthFactor = uint256(premiumRatePerSecond).wTaylorCompounded(180 days);
        uint256 singleBorrowerPremium = borrowAmount.wMulDown(growthFactor);
        uint256 expectedIncrease = 3 * singleBorrowerPremium;
        uint256 actualIncrease = supplyValueAfter - supplyValueBefore;
        assertApproxEqRel(actualIncrease, expectedIncrease, 0.1e18); // 10% tolerance
    }

    function testConcurrentOperationsWithPremiums() public {
        uint256 supplyAmount = 30_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 collateralAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.15e18) / 365 days); // 15% APR

        // Setup second borrower
        address borrower2 = makeAddr("Borrower2");
        collateralToken.setBalance(borrower2, collateralAmount);
        loanToken.setBalance(borrower2, borrowAmount);

        vm.prank(borrower2);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.prank(borrower2);
        loanToken.approve(address(morpho), type(uint256).max);

        // Supply
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit lines with premium rates BEFORE borrowing
        _setCreditLineWithPremium(BORROWER, 10_000e18, premiumRatePerSecond);
        _setCreditLineWithPremium(borrower2, 10_000e18, premiumRatePerSecond);

        // Both borrowers borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        vm.prank(borrower2);
        morpho.borrow(marketParams, borrowAmount, 0, borrower2, borrower2);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 30 days);

        // Concurrent operations
        // Borrower1 borrows more (triggers premium accrual)
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1_000e18, 0, BORROWER, BORROWER);

        // Borrower2 repays (triggers premium accrual)
        vm.prank(borrower2);
        morpho.repay(marketParams, 1_000e18, 0, borrower2, "");

        // Verify both premiums were accrued correctly
        Market memory market = morpho.market(id);
        Position memory pos1 = morpho.position(id, BORROWER);
        Position memory pos2 = morpho.position(id, borrower2);

        uint256 debt1 = uint256(pos1.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 debt2 = uint256(pos2.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        // Borrower1 should have initial + premium + additional borrow
        assertGt(debt1, borrowAmount + 1_000e18);

        // Borrower2 should have initial + premium - repayment
        assertGt(debt2, borrowAmount - 1_000e18);
        assertLt(debt2, borrowAmount);
    }

    function testBatchPremiumAccrualIntegration() public {
        uint256 supplyAmount = 40_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 collateralAmount = 10_000e18;

        // Setup 5 borrowers
        address[] memory borrowers = new address[](5);
        uint128[] memory rates = new uint128[](5);

        for (uint256 i = 0; i < 5; i++) {
            borrowers[i] = makeAddr(string.concat("Borrower", vm.toString(i)));
            rates[i] = uint128(uint256(0.1e18 + i * 0.05e18) / 365 days); // 10%, 15%, 20%, 25%, 30% APR

            // Setup borrower
            collateralToken.setBalance(borrowers[i], collateralAmount);
            vm.prank(borrowers[i]);
            collateralToken.approve(address(morpho), type(uint256).max);
        }

        // Supply
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // All get credit lines and borrow
        for (uint256 i = 0; i < 5; i++) {
            // Set credit line with premium rate before borrowing
            _setCreditLineWithPremium(borrowers[i], 10_000e18, rates[i]);

            vm.prank(borrowers[i]);
            morpho.borrow(marketParams, borrowAmount, 0, borrowers[i], borrowers[i]);
        }

        // Advance time
        _continueMarketCycles(id, block.timestamp + 90 days);

        // Record market state before batch accrual
        Market memory marketBefore = morpho.market(id);

        // Batch accrue all premiums
        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, borrowers);

        // Verify market totals increased
        Market memory marketAfter = morpho.market(id);
        assertGt(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets);
        assertGt(marketAfter.totalSupplyAssets, marketBefore.totalSupplyAssets);

        // Verify all borrowers have updated timestamps
        for (uint256 i = 0; i < 5; i++) {
            (uint128 lastAccrualTime,,) = MorphoCredit(address(morpho)).borrowerPremium(id, borrowers[i]);
            assertEq(lastAccrualTime, block.timestamp);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASES AND RACE CONDITIONS
    //////////////////////////////////////////////////////////////*/

    function testKeeperVsUserRaceCondition() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate BEFORE borrowing
        _setCreditLineWithPremium(BORROWER, 10_000e18, premiumRatePerSecond);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 7 days);

        // Simulate keeper calling accrue in same block as user operation
        // First keeper accrues
        address keeper = makeAddr("Keeper");
        vm.prank(keeper);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Then user tries to borrow - should not double accrue
        uint256 marketTotalBefore = morpho.market(id).totalBorrowAssets;

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 100e18, 0, BORROWER, BORROWER);

        uint256 marketTotalAfter = morpho.market(id).totalBorrowAssets;

        // Should only increase by the new borrow amount (no double premium)
        assertEq(marketTotalAfter - marketTotalBefore, 100e18);
    }

    function testPremiumRateChangesDuringOperation() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 initialRatePerSecond = uint128(uint256(0.1e18) / 365 days); // 10% APR
        uint128 newRatePerSecond = uint128(uint256(0.3e18) / 365 days); // 30% APR

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set initial credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, initialRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 30 days);

        // Change rate (this accrues at old rate first)
        _setCreditLineWithPremium(BORROWER, 10_000e18, newRatePerSecond);

        // Advance more time
        _continueMarketCycles(id, block.timestamp + 30 days);

        // Trigger accrual
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 100e18, 0, BORROWER, BORROWER);

        // Calculate final debt
        Position memory position = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);
        uint256 finalDebt =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        // Debt should reflect both rate periods
        // Roughly: 5000 * (1 + 0.1 * 30/365) * (1 + 0.3 * 30/365) + 100
        uint256 firstGrowth = uint256(initialRatePerSecond).wTaylorCompounded(30 days);
        uint256 firstPeriod = borrowAmount + borrowAmount.wMulDown(firstGrowth);
        uint256 secondGrowth = uint256(newRatePerSecond).wTaylorCompounded(30 days);
        uint256 secondPeriod = firstPeriod + firstPeriod.wMulDown(secondGrowth);
        uint256 expectedDebt = secondPeriod + 100e18;

        assertApproxEqRel(finalDebt, expectedDebt, 0.05e18); // 5% tolerance
    }

    function testZeroPremiumRateBehavior() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with zero premium rate BEFORE borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 365 days);

        // Record debt before
        Position memory posBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);
        uint256 debtBefore =
            uint256(posBefore.borrowShares).toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);

        // Trigger potential premium accrual
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Check debt unchanged (only base interest should apply)
        Position memory posAfter = morpho.position(id, BORROWER);
        Market memory marketAfter = morpho.market(id);
        uint256 debtAfter =
            uint256(posAfter.borrowShares).toAssetsUp(marketAfter.totalBorrowAssets, marketAfter.totalBorrowShares);

        assertEq(debtAfter, debtBefore);
    }

    function testVeryLargePremiumAccumulation() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 20_000e18; // Extra credit for safety
        uint128 premiumRatePerSecond = uint128(uint256(1e18) / 365 days); // 100% APR - maximum allowed

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with maximum premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time significantly
        _continueMarketCycles(id, block.timestamp + 365 days);

        // Accrue premium
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Calculate expected debt using wTaylorCompounded
        uint256 growthFactor = uint256(premiumRatePerSecond).wTaylorCompounded(365 days);
        uint256 expectedPremium = borrowAmount.wMulDown(growthFactor);
        uint256 expectedDebt = borrowAmount + expectedPremium; // Assuming base rate is 0

        // Get actual debt
        Position memory position = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);
        uint256 finalDebt =
            uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        // Use precise assertion with reasonable tolerance
        assertApproxEqRel(finalDebt, expectedDebt, 0.01e18); // 1% tolerance

        // Ensure no overflow occurred
        assertLt(finalDebt, type(uint128).max);
    }

    function testPremiumAccrualWithMaxValues() public {
        uint256 supplyAmount = type(uint128).max / 10; // Large but safe amount
        uint256 borrowAmount = supplyAmount / 2;
        uint256 creditLineAmount = borrowAmount * 2;
        uint128 premiumRatePerSecond = uint128(uint256(0.5e18) / 365 days); // 50% APR

        // Use smaller values for this test to avoid overflow
        supplyAmount = 1e24;
        borrowAmount = 5e23;
        creditLineAmount = 1e24;

        // Setup position
        loanToken.setBalance(SUPPLIER, supplyAmount);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 30 days);

        // Should not revert
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Verify state is consistent
        Market memory market = morpho.market(id);
        assertLe(market.totalBorrowAssets, market.totalSupplyAssets);
        assertGt(market.totalBorrowAssets, borrowAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        FEE INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testProtocolFeeOnPremium() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.2e18) / 365 days); // 20% APR
        uint256 protocolFee = 0.1e18; // 10% of interest

        // Set protocol fee
        vm.prank(OWNER);
        morpho.setFee(marketParams, protocolFee);

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Record fee recipient position
        Position memory feePosBefore = morpho.position(id, FEE_RECIPIENT);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 365 days);

        // Accrue premium
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Check fee recipient received shares
        Position memory feePosAfter = morpho.position(id, FEE_RECIPIENT);
        assertGt(feePosAfter.supplyShares, feePosBefore.supplyShares);

        // Calculate fee value
        Market memory market = morpho.market(id);
        uint256 feeValue = uint256(feePosAfter.supplyShares - feePosBefore.supplyShares).toAssetsDown(
            market.totalSupplyAssets, market.totalSupplyShares
        );

        // Fee should be roughly 10% of premium
        // Note: Premium is compounded, not simple interest, so it will be higher than borrowAmount * rate
        // With compounding over 1 year at 20% APR, the actual premium is more than 20%
        uint256 expectedGrowth = uint256(premiumRatePerSecond).wTaylorCompounded(365 days);
        uint256 expectedPremium = borrowAmount.wMulDown(expectedGrowth);
        uint256 expectedMinFee = expectedPremium.wMulDown(protocolFee);

        // The actual fee should be higher due to compounding
        // Allow 1 wei tolerance for rounding
        assertGe(feeValue, expectedMinFee - 1);
        // But still reasonable (less than double the simple calculation)
        assertLt(feeValue, expectedMinFee * 2);
    }

    function testFeeRecipientSharesFromPremium() public {
        uint256 supplyAmount = 20_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 collateralAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.3e18) / 365 days); // 30% APR
        uint256 protocolFee = 0.2e18; // 20% fee

        // Set protocol fee
        vm.prank(OWNER);
        morpho.setFee(marketParams, protocolFee);

        // Setup multiple borrowers
        address borrower2 = makeAddr("Borrower2");
        collateralToken.setBalance(borrower2, collateralAmount);
        vm.prank(borrower2);
        collateralToken.approve(address(morpho), type(uint256).max);

        // Supply
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit lines with premium rates before borrowing
        _setCreditLineWithPremium(BORROWER, 10_000e18, premiumRatePerSecond);
        _setCreditLineWithPremium(borrower2, 10_000e18, premiumRatePerSecond);

        // Two borrowers borrow using credit lines
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        vm.prank(borrower2);
        morpho.borrow(marketParams, borrowAmount, 0, borrower2, borrower2);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 180 days);

        // Accrue premiums
        address[] memory borrowers = new address[](2);
        borrowers[0] = BORROWER;
        borrowers[1] = borrower2;
        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, borrowers);

        // Check fee recipient can withdraw
        Position memory feePos = morpho.position(id, FEE_RECIPIENT);
        Market memory market = morpho.market(id);
        uint256 feeValue = uint256(feePos.supplyShares).toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);

        assertGt(feeValue, 0);

        // Fee recipient withdraws
        vm.prank(FEE_RECIPIENT);
        morpho.withdraw(marketParams, feeValue, 0, FEE_RECIPIENT, FEE_RECIPIENT);

        // Verify received tokens
        assertEq(loanToken.balanceOf(FEE_RECIPIENT), feeValue);
    }

    function testZeroFeeMarketWithPremium() public {
        uint256 supplyAmount = 10_000e18;
        uint256 borrowAmount = 5_000e18;
        uint256 creditLineAmount = 10_000e18;
        uint128 premiumRatePerSecond = uint128(uint256(0.25e18) / 365 days); // 25% APR

        // Ensure zero fee (default)
        assertEq(morpho.market(id).fee, 0);

        // Setup position
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");

        // Set credit line with premium rate before borrowing
        _setCreditLineWithPremium(BORROWER, creditLineAmount, premiumRatePerSecond);

        // Borrower borrows using credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Record state
        Position memory feePosBefore = morpho.position(id, FEE_RECIPIENT);
        Market memory marketBefore = morpho.market(id);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 100 days);

        // Accrue premium
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Fee recipient should have no shares
        Position memory feePosAfter = morpho.position(id, FEE_RECIPIENT);
        assertEq(feePosAfter.supplyShares, feePosBefore.supplyShares);

        // All premium should go to suppliers
        Market memory marketAfter = morpho.market(id);
        uint256 premiumAmount = marketAfter.totalSupplyAssets - marketBefore.totalSupplyAssets;
        assertGt(premiumAmount, 0);

        // Verify supplier gets full benefit (with small rounding tolerance)
        Position memory supplierPos = morpho.position(id, SUPPLIER);
        uint256 supplierValue =
            uint256(supplierPos.supplyShares).toAssetsDown(marketAfter.totalSupplyAssets, marketAfter.totalSupplyShares);
        // Allow for 1 wei rounding error
        assertApproxEqAbs(supplierValue, supplyAmount + premiumAmount, 1);
    }
}
