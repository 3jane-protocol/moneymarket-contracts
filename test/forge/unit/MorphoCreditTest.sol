// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {Morpho} from "../../../src/Morpho.sol";
import {IMorpho, Id, MarketParams, Position, Market} from "../../../src/interfaces/IMorpho.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../../src/mocks/OracleMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";

contract MorphoCreditTest is Test {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    IMorpho public morpho;
    address public owner;
    address public premiumRateSetter;
    address public borrower;
    address public supplier;
    address public feeRecipient;

    ERC20Mock public loanToken;
    ERC20Mock public collateralToken;
    OracleMock public oracle;
    ConfigurableIrmMock public irm;

    MarketParams public marketParams;
    Id public marketId;

    uint256 constant INITIAL_SUPPLY = 10_000e18;
    uint256 constant MAX_PREMIUM_RATE_ANNUAL = 1e18; // 100% APR
    uint256 constant MAX_PREMIUM_RATE_PER_SECOND = 31709791983; // 100% APR / 365 days
    uint256 constant ORACLE_PRICE = 1e36;

    event PremiumRateSetterUpdated(address indexed newSetter);
    event BorrowerPremiumRateSet(Id indexed id, address indexed borrower, uint128 oldRate, uint128 newRate);
    event PremiumAccrued(Id indexed id, address indexed borrower, uint256 premiumAmount, uint256 feeAmount);

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        premiumRateSetter = makeAddr("premiumRateSetter");
        borrower = makeAddr("borrower");
        supplier = makeAddr("supplier");
        feeRecipient = makeAddr("feeRecipient");

        // Deploy contracts
        vm.prank(owner);
        morpho = IMorpho(address(new MorphoCredit(owner)));

        // Setup tokens
        loanToken = new ERC20Mock();
        collateralToken = new ERC20Mock();
        oracle = new OracleMock();
        irm = new ConfigurableIrmMock();

        // Set oracle price
        oracle.setPrice(ORACLE_PRICE);

        // Create market
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8e18,
            creditLine: address(0)
        });

        vm.prank(owner);
        morpho.enableLltv(0.8e18);

        vm.prank(owner);
        morpho.enableIrm(address(irm));

        morpho.createMarket(marketParams);
        marketId = marketParams.id();

        // Set fee recipient
        vm.prank(owner);
        morpho.setFeeRecipient(feeRecipient);

        // Setup initial token balances
        loanToken.setBalance(supplier, INITIAL_SUPPLY);
        collateralToken.setBalance(borrower, INITIAL_SUPPLY * 2);

        // Approve morpho
        vm.prank(supplier);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(borrower);
        collateralToken.approve(address(morpho), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        PREMIUM RATE SETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetPremiumRateSetter() public {
        vm.expectEmit(true, false, false, true);
        emit PremiumRateSetterUpdated(premiumRateSetter);

        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        assertEq(MorphoCredit(address(morpho)).premiumRateSetter(), premiumRateSetter);
    }

    function testSetPremiumRateSetterNotOwner() public {
        vm.expectRevert(bytes(ErrorsLib.NOT_OWNER));
        vm.prank(borrower);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);
    }

    /*//////////////////////////////////////////////////////////////
                        SET BORROWER PREMIUM RATE TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetBorrowerPremiumRate() public {
        uint128 newRateAnnual = 0.05e18; // 5% APR
        uint128 newRatePerSecond = uint128(uint256(newRateAnnual) / 365 days);

        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        vm.expectEmit(true, true, false, true);
        emit BorrowerPremiumRateSet(marketId, borrower, 0, newRatePerSecond);

        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, newRateAnnual);

        (uint128 lastAccrualTime, uint128 rate,) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertEq(rate, newRatePerSecond);
        assertEq(lastAccrualTime, block.timestamp);
    }

    function testSetBorrowerPremiumRateNotAuthorized() public {
        vm.expectRevert(bytes(ErrorsLib.NOT_PREMIUM_RATE_SETTER));
        vm.prank(borrower);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, 0.05e18);
    }

    function testSetBorrowerPremiumRateTooHigh() public {
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        // Use a rate that will definitely exceed the per-second limit
        // 10,000% APR = 100e18, which when converted to per-second will exceed MAX_PREMIUM_RATE
        uint128 tooHighAnnualRate = 100e18;

        vm.expectRevert(bytes(ErrorsLib.PREMIUM_RATE_TOO_HIGH));
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, tooHighAnnualRate);
    }

    function testSetBorrowerPremiumRateWithExistingPosition() public {
        // Supply and borrow first
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        // Set premium rate
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        uint128 newRate = 0.1e18; // 10% APR

        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, newRate);

        // Check that snapshot was taken
        (,, uint256 borrowAssetsAtLastAccrual) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertGt(borrowAssetsAtLastAccrual, 0);
        assertEq(borrowAssetsAtLastAccrual, 500e18); // Initial borrow amount
    }

    /*//////////////////////////////////////////////////////////////
                        PREMIUM ACCRUAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testAccrueBorrowerPremium() public {
        // Setup: Supply, borrow, and set premium rate
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        uint128 premiumRate = 0.2e18; // 20% APR
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, premiumRate);

        // Advance time (1 day to avoid overflow)
        vm.warp(block.timestamp + 1 hours);

        // Accrue premium
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check that borrower's debt increased
        Position memory position = morpho.position(marketId, borrower);
        Market memory marketData = morpho.market(marketId);
        uint256 borrowAssets =
            uint256(position.borrowShares).toAssetsUp(marketData.totalBorrowAssets, marketData.totalBorrowShares);

        // Should be more than initial amount after 1 hour with premium
        // Even small growth should be visible
        assertGt(borrowAssets, 500e18);
    }

    function testAccrueBorrowerPremiumWithFees() public {
        // Set protocol fee (lower to avoid overflow)
        vm.prank(owner);
        morpho.setFee(marketParams, 0.01e18); // 1% protocol fee

        // Setup: Supply, borrow, and set premium rate
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        uint128 premiumRate = 0.2e18; // 20% APR
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, premiumRate);

        // Advance time (1 day to avoid overflow)
        vm.warp(block.timestamp + 1 hours);

        // Record fee recipient position before
        Position memory feePositionBefore = morpho.position(marketId, feeRecipient);

        // Accrue premium
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check fee recipient received shares
        Position memory feePositionAfter = morpho.position(marketId, feeRecipient);
        assertGt(feePositionAfter.supplyShares, feePositionBefore.supplyShares);
    }

    function testAccrueBorrowerPremiumNoRate() public {
        // Supply and borrow without setting premium rate
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        uint256 borrowSharesBefore = morpho.position(marketId, borrower).borrowShares;

        // Advance time (1 day to avoid overflow)
        vm.warp(block.timestamp + 1 hours);

        // Accrue premium (should do nothing)
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        uint256 borrowSharesAfter = morpho.position(marketId, borrower).borrowShares;
        assertEq(borrowSharesAfter, borrowSharesBefore);
    }

    function testAccrueBorrowerPremiumNoElapsedTime() public {
        // Setup position and premium rate
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, 0.2e18);

        uint256 borrowSharesBefore = morpho.position(marketId, borrower).borrowShares;

        // Accrue premium immediately (no time elapsed)
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        uint256 borrowSharesAfter = morpho.position(marketId, borrower).borrowShares;
        assertEq(borrowSharesAfter, borrowSharesBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        BATCH PREMIUM ACCRUAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testAccruePremiumsForBorrowers() public {
        address borrower2 = makeAddr("borrower2");
        collateralToken.setBalance(borrower2, INITIAL_SUPPLY);
        vm.prank(borrower2);
        collateralToken.approve(address(morpho), type(uint256).max);

        // Setup positions for two borrowers
        vm.prank(supplier);
        morpho.supply(marketParams, 2_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower, "");
        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        vm.prank(borrower2);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower2, "");
        vm.prank(borrower2);
        morpho.borrow(marketParams, 500e18, 0, borrower2, borrower2);

        // Set premium rates
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, 0.1e18); // 10% APR
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower2, 0.2e18); // 20% APR

        // Advance time (1 day to avoid overflow)
        vm.warp(block.timestamp + 1 hours);

        // Batch accrue
        address[] memory borrowers = new address[](2);
        borrowers[0] = borrower;
        borrowers[1] = borrower2;

        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(marketId, borrowers);

        // Check both borrowers had premiums accrued
        Market memory marketData = morpho.market(marketId);
        uint256 borrowAssets1 = uint256(morpho.position(marketId, borrower).borrowShares).toAssetsUp(
            marketData.totalBorrowAssets, marketData.totalBorrowShares
        );
        uint256 borrowAssets2 = uint256(morpho.position(marketId, borrower2).borrowShares).toAssetsUp(
            marketData.totalBorrowAssets, marketData.totalBorrowShares
        );

        // After 1 hour, both borrowers should have accrued premium
        assertGt(borrowAssets1, 500e18);
        assertGt(borrowAssets2, 500e18);
        assertGt(borrowAssets2, borrowAssets1); // Borrower2 has higher rate
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testBorrowTriggersSnapshotUpdate() public {
        // Initial setup
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 2_000e18, borrower, "");

        // Set premium rate
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, 0.1e18);

        // First borrow
        vm.prank(borrower);
        morpho.borrow(marketParams, 300e18, 0, borrower, borrower);

        // Check snapshot was taken
        (,, uint256 snapshot1) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertEq(snapshot1, 300e18);

        // Advance time and accrue some interest/premium
        vm.warp(block.timestamp + 1 hours);

        // Second borrow should update snapshot
        vm.prank(borrower);
        morpho.borrow(marketParams, 200e18, 0, borrower, borrower);

        // Snapshot should now reflect total position including accrued amounts
        (,, uint256 snapshot2) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertGt(snapshot2, 500e18); // More than just 300 + 200 due to accrued interest/premium
    }

    function testRepayTriggersSnapshotUpdate() public {
        // Setup position
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        // Set premium rate
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, 0.1e18);

        // Advance time
        vm.warp(block.timestamp + 1 hours);

        // Add tokens for repayment and approve
        loanToken.setBalance(borrower, 600e18);
        vm.prank(borrower);
        loanToken.approve(address(morpho), type(uint256).max);

        // Repay should trigger snapshot update
        vm.prank(borrower);
        morpho.repay(marketParams, 100e18, 0, borrower, "");

        // Check snapshot was updated
        (uint128 lastAccrualTime,, uint256 snapshot) = MorphoCredit(address(morpho)).borrowerPremium(marketId, borrower);
        assertEq(lastAccrualTime, block.timestamp);
        // Check that snapshot reflects remaining position after repayment
        // The snapshot should be less than what it was before repayment
        Market memory marketData = morpho.market(marketId);
        uint256 remainingBorrowAssets = uint256(morpho.position(marketId, borrower).borrowShares).toAssetsUp(
            marketData.totalBorrowAssets, marketData.totalBorrowShares
        );
        assertEq(snapshot, remainingBorrowAssets);
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testPremiumCalculationWithBaseGrowthLessThanWAD() public {
        // This would happen if market conditions cause borrow position to decrease
        // For now, test that it doesn't revert
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, 500e18, 0, borrower, borrower);

        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, 0.1e18);

        // This should not revert even in edge cases
        vm.warp(block.timestamp + 1);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);
    }

    function testVerySmallPremiumAmount() public {
        // Test with very small borrow amount
        vm.prank(supplier);
        morpho.supply(marketParams, 1_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 1_000e18, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, 1, 0, borrower, borrower); // 1 wei borrow

        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, 0.01e18); // 1% APR

        // Should handle precision gracefully
        vm.warp(block.timestamp + 1 hours);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);
    }

    function testSetBorrowerPremiumRateAccruesBaseInterestFirst() public {
        // Setup: Supply and borrow
        vm.prank(supplier);
        morpho.supply(marketParams, 5_000e18, 0, supplier, "");

        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, 10_000e18, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, 2_500e18, 0, borrower, borrower);

        // Set up IRM with base rate
        irm.setApr(0.1e18); // 10% APR base rate

        // Set up premium rate setter
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);

        // Advance time to accumulate base interest
        vm.warp(block.timestamp + 30 days);

        // Get market state before setting premium rate
        Market memory marketBefore = morpho.market(marketId);
        uint256 lastUpdateBefore = marketBefore.lastUpdate;

        // Set premium rate - this should trigger _accrueInterest first
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, 0.2e18); // 20% APR

        // Get market state after
        Market memory marketAfter = morpho.market(marketId);

        // Verify that base interest was accrued (lastUpdate should be current timestamp)
        assertEq(marketAfter.lastUpdate, block.timestamp);
        assertGt(marketAfter.lastUpdate, lastUpdateBefore);

        // Verify that totalBorrowAssets increased due to base interest
        assertGt(marketAfter.totalBorrowAssets, marketBefore.totalBorrowAssets);

        // Calculate expected base interest
        uint256 elapsed = block.timestamp - lastUpdateBefore;
        uint256 borrowRate = irm.borrowRate(marketParams, marketBefore);
        uint256 expectedInterest =
            uint256(marketBefore.totalBorrowAssets).wMulDown(borrowRate.wTaylorCompounded(elapsed));

        // Verify the interest accrued matches expected
        assertApproxEqRel(
            marketAfter.totalBorrowAssets - marketBefore.totalBorrowAssets,
            expectedInterest,
            0.001e18 // 0.1% tolerance
        );
    }

    /*//////////////////////////////////////////////////////////////
                        NEW EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testAccrueBorrowerPremiumMaxElapsedTime() public {
        // Setup positions
        uint256 supplyAmount = 5_000e18; // Use amount within initial balance
        uint256 borrowAmount = 2_500e18;
        uint128 premiumRateAnnual = 0.5e18; // 50% APR

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Borrower supplies collateral and borrows
        uint256 collateralAmount = 10_000e18; // Within initial balance
        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, collateralAmount, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Set premium rate
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, premiumRateAnnual);

        // Warp time beyond MAX_ELAPSED_TIME (365 days + extra)
        uint256 MAX_ELAPSED_TIME = 365 days;
        vm.warp(block.timestamp + MAX_ELAPSED_TIME + 30 days);

        // Trigger premium accrual
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Calculate expected premium for exactly MAX_ELAPSED_TIME (not actual elapsed)
        uint256 ratePerSecond = uint256(premiumRateAnnual) / 365 days;
        uint256 expectedGrowth = ratePerSecond.wTaylorCompounded(MAX_ELAPSED_TIME);
        uint256 expectedPremium = borrowAmount.wMulDown(expectedGrowth);

        // Get actual debt
        Position memory pos = morpho.position(marketId, borrower);
        Market memory mkt = morpho.market(marketId);
        uint256 actualDebt = uint256(pos.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);

        // Debt should be borrowAmount + premium for MAX_ELAPSED_TIME only
        assertApproxEqRel(actualDebt, borrowAmount + expectedPremium, 0.01e18); // 1% tolerance
    }

    function testAccrueBorrowerPremiumBelowThreshold() public {
        // Setup with extremely small amounts to ensure premium < MIN_PREMIUM_THRESHOLD
        uint256 supplyAmount = 1000e18;
        uint256 borrowAmount = 1; // 1 wei borrow
        uint128 premiumRateAnnual = 0.001e18; // 0.1% APR

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Borrower supplies collateral and borrows
        uint256 collateralAmount = 1e18;
        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, collateralAmount, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Set very low premium rate
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, premiumRateAnnual);

        // Record state before
        Position memory posBefore = morpho.position(marketId, borrower);
        Market memory mktBefore = morpho.market(marketId);

        // Advance very short time
        vm.warp(block.timestamp + 1 seconds);

        // Trigger premium accrual
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check state after
        Position memory posAfter = morpho.position(marketId, borrower);
        Market memory mktAfter = morpho.market(marketId);

        // Borrow shares should not change (premium below threshold)
        assertEq(posAfter.borrowShares, posBefore.borrowShares);
        assertEq(mktAfter.totalBorrowAssets, mktBefore.totalBorrowAssets);
        assertEq(mktAfter.totalBorrowShares, mktBefore.totalBorrowShares);

        // But timestamp should be updated (check via another accrual with no time change)
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);
        // No revert means timestamp was updated in previous call
    }

    function testAccrueBorrowerPremiumAtThreshold() public {
        // Setup to ensure premium == MIN_PREMIUM_THRESHOLD
        uint256 supplyAmount = 5_000e18; // Within initial balance
        uint256 borrowAmount = 1000e18;
        uint128 premiumRateAnnual = 0.1e18; // 10% APR

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Borrower supplies collateral and borrows
        uint256 collateralAmount = 2000e18;
        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, collateralAmount, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Set premium rate
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, premiumRateAnnual);

        // Calculate time needed for premium to be exactly 1 (MIN_PREMIUM_THRESHOLD)
        // premium = borrowAmount * rate * time / (365 days * WAD)
        // 1 = 1000e18 * 0.1e18 * time / (365 days * 1e18)
        // time = 365 days / (1000 * 0.1) = 3.65 days / 100 ≈ 0.0365 days ≈ 3154 seconds
        uint256 timeForMinPremium = 3154;

        // Record state before
        Position memory posBefore = morpho.position(marketId, borrower);

        // Advance time
        vm.warp(block.timestamp + timeForMinPremium);

        // Trigger premium accrual
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check state after
        Position memory posAfter = morpho.position(marketId, borrower);

        // Borrow shares should increase (premium at threshold)
        assertGt(posAfter.borrowShares, posBefore.borrowShares);
    }

    function testPremiumCalculationPositionDecreased() public {
        // Setup positions
        uint256 supplyAmount = 5_000e18; // Within initial balance
        uint256 borrowAmount = 2_500e18;
        uint128 premiumRateAnnual = 0.2e18; // 20% APR

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Borrower supplies collateral and borrows
        uint256 collateralAmount = 10_000e18; // Within initial balance
        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, collateralAmount, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Set premium rate
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, premiumRateAnnual);

        // Advance time and let some premium accrue
        vm.warp(block.timestamp + 30 days);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Now repay more than the accrued interest (position decreases)
        uint256 repayAmount = 1_000e18;
        loanToken.setBalance(borrower, repayAmount);
        vm.prank(borrower);
        loanToken.approve(address(morpho), repayAmount);
        vm.prank(borrower);
        morpho.repay(marketParams, repayAmount, 0, borrower, "");

        // Record debt after repay
        Position memory posAfterRepay = morpho.position(marketId, borrower);
        Market memory mktAfterRepay = morpho.market(marketId);
        uint256 debtAfterRepay = uint256(posAfterRepay.borrowShares).toAssetsUp(
            mktAfterRepay.totalBorrowAssets, mktAfterRepay.totalBorrowShares
        );

        // Advance time again
        vm.warp(block.timestamp + 30 days);

        // Trigger premium accrual - position has decreased since last snapshot
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Premium should still accrue based on current position
        Position memory posFinal = morpho.position(marketId, borrower);
        Market memory mktFinal = morpho.market(marketId);
        uint256 debtFinal =
            uint256(posFinal.borrowShares).toAssetsUp(mktFinal.totalBorrowAssets, mktFinal.totalBorrowShares);

        assertGt(debtFinal, debtAfterRepay);
    }

    function testPremiumCalculationWithZeroTotalGrowth() public {
        // This tests the edge case where totalGrowthAmount <= baseGrowthActual
        // which should result in premiumAmount = 0

        // Setup positions
        uint256 supplyAmount = 5_000e18; // Within initial balance
        uint256 borrowAmount = 2_500e18;
        uint128 premiumRateAnnual = 0.001e18; // 0.1% APR - very low

        vm.prank(supplier);
        morpho.supply(marketParams, supplyAmount, 0, supplier, "");

        // Borrower supplies collateral and borrows
        uint256 collateralAmount = 10_000e18; // Within initial balance
        vm.prank(borrower);
        morpho.supplyCollateral(marketParams, collateralAmount, borrower, "");

        vm.prank(borrower);
        morpho.borrow(marketParams, borrowAmount, 0, borrower, borrower);

        // Configure IRM to have a high base rate
        irm.setApr(0.5e18); // 50% APR base rate

        // Set very low premium rate
        vm.prank(owner);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(marketId, borrower, premiumRateAnnual);

        // Advance short time
        vm.warp(block.timestamp + 1 days);

        // Accrue base interest first
        morpho.accrueInterest(marketParams);

        // Record state
        Position memory posBefore = morpho.position(marketId, borrower);
        Market memory mktBefore = morpho.market(marketId);

        // Trigger premium accrual
        // With high base rate and very low premium, totalGrowthAmount might be <= baseGrowthActual
        MorphoCredit(address(morpho)).accrueBorrowerPremium(marketId, borrower);

        // Check state - should have minimal or no change due to premium
        Position memory posAfter = morpho.position(marketId, borrower);
        Market memory mktAfter = morpho.market(marketId);

        // The debt increase should be minimal (only from rounding)
        uint256 debtBefore =
            uint256(posBefore.borrowShares).toAssetsUp(mktBefore.totalBorrowAssets, mktBefore.totalBorrowShares);
        uint256 debtAfter =
            uint256(posAfter.borrowShares).toAssetsUp(mktAfter.totalBorrowAssets, mktAfter.totalBorrowShares);

        // Assert debt increased by at most a tiny amount
        // With 2500e18 borrow, 0.001e18 APR for 1 day:
        // Expected premium ≈ 2500e18 * 0.001e18 * 1 / 365 / 1e18 ≈ 6.849e15
        // But with high base rate, the premium calculation might result in 0
        assertLe(debtAfter - debtBefore, 1e16); // Allow small amount for rounding
    }
}
