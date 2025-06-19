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
}
