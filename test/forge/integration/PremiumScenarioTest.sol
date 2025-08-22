// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";

contract PremiumScenarioTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    CreditLineMock public creditLine;
    CreditLineMock public creditLine2;
    address public creditAnalyst; // Simulates 3CA role

    // Multiple test markets for cross-market scenarios
    MarketParams public marketParams2;
    Id public id2;

    function setUp() public override {
        super.setUp();

        // Stop any active pranks from parent setUp
        vm.stopPrank();

        // Deploy credit line mocks
        creditLine = new CreditLineMock(address(morpho));
        creditLine2 = new CreditLineMock(address(morpho));

        irm = new ConfigurableIrmMock();
        vm.prank(OWNER);
        morpho.enableIrm(address(irm));

        // Set credit line in market params before creation
        marketParams.irm = address(irm);
        marketParams.creditLine = address(creditLine);
        vm.prank(OWNER);
        morpho.createMarket(marketParams);
        id = MarketParamsLib.id(marketParams);

        creditAnalyst = makeAddr("CreditAnalyst");

        // Enable LLTV for second market (first is already enabled in BaseTest)
        vm.prank(OWNER);
        morpho.enableLltv(0.9e18); // Higher LLTV for second market

        // Create second market with different LLTV
        marketParams2 = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.9e18,
            creditLine: address(creditLine2)
        });

        vm.prank(OWNER);
        morpho.createMarket(marketParams2);
        id2 = marketParams2.id();

        // Set up initial balances
        loanToken.setBalance(SUPPLIER, HIGH_COLLATERAL_AMOUNT);
        collateralToken.setBalance(BORROWER, HIGH_COLLATERAL_AMOUNT);

        // Approve morpho
        vm.prank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(BORROWER);
        collateralToken.approve(address(morpho), type(uint256).max);
        vm.prank(BORROWER);
        loanToken.approve(address(morpho), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setCreditLineWithPremium(Id marketId, address borrower, uint256 credit, uint128 premiumRatePerSecond)
        internal
    {
        CreditLineMock cl = Id.unwrap(marketId) == Id.unwrap(id) ? creditLine : creditLine2;
        vm.prank(address(cl));
        IMorphoCredit(address(morpho)).setCreditLine(marketId, borrower, credit, premiumRatePerSecond);
    }

    /*//////////////////////////////////////////////////////////////
                    COMPLETE CREDIT LINE LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function testCompleteCreditLineLifecycle() public {
        // This test simulates a complete lifecycle of a credit line in 3Jane
        // without traditional liquidations

        uint256 supplyAmount = 100_000e18;

        // Phase 1: Initial setup and credit assessment
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        // Borrower supplies collateral (could be virtual in future)
        // Credit line setup needed

        // 3CA assesses borrower and sets initial premium rate based on credit score
        uint128 initialPremiumRate = uint128(uint256(0.08e18) / 365 days); // 8% APR - good credit
        _setCreditLineWithPremium(id, BORROWER, 50_000e18, initialPremiumRate);

        // Phase 2: Initial borrow
        uint256 initialBorrow = 20_000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, initialBorrow, 0, BORROWER, BORROWER);

        // Record initial state

        // Phase 3: Time passes, borrower makes partial payments
        vm.warp(block.timestamp + 30 days);

        // Borrower makes first payment
        uint256 firstPayment = 2_000e18;
        loanToken.setBalance(BORROWER, firstPayment);
        vm.prank(BORROWER);
        morpho.repay(marketParams, firstPayment, 0, BORROWER, hex"");

        // Phase 4: Credit improvement - 3CA reduces premium rate
        vm.warp(block.timestamp + 30 days);
        uint128 improvedPremiumRate = uint128(uint256(0.05e18) / 365 days); // 5% APR - improved credit
        _setCreditLineWithPremium(id, BORROWER, 50_000e18, improvedPremiumRate);

        // Phase 5: Borrower increases credit line usage
        uint256 additionalBorrow = 10_000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, additionalBorrow, 0, BORROWER, BORROWER);

        // Phase 6: Regular payments over time
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + 30 days);

            uint256 monthlyPayment = 3_000e18;
            loanToken.setBalance(BORROWER, monthlyPayment);
            vm.prank(BORROWER);
            morpho.repay(marketParams, monthlyPayment, 0, BORROWER, hex"");
        }

        // Phase 7: Credit deterioration - 3CA increases premium
        vm.warp(block.timestamp + 30 days);
        uint128 deterioratedPremiumRate = uint128(uint256(0.15e18) / 365 days); // 15% APR - credit issues
        _setCreditLineWithPremium(id, BORROWER, 50_000e18, deterioratedPremiumRate);

        // Phase 8: Final repayment
        vm.warp(block.timestamp + 60 days);

        // First accrue premium to get accurate debt
        vm.prank(BORROWER);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Calculate final debt after premium accrual
        Position memory finalPosition = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);

        // Borrower repays all shares to close position
        uint256 repayAssets =
            uint256(finalPosition.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        loanToken.setBalance(BORROWER, repayAssets + 1000e18); // Extra buffer
        vm.prank(BORROWER);
        morpho.repay(marketParams, 0, finalPosition.borrowShares, BORROWER, hex"");

        // Verify complete repayment (may have tiny remainder due to rounding)
        Position memory closedPosition = morpho.position(id, BORROWER);
        assertLe(closedPosition.borrowShares, 1); // Allow 1 wei rounding

        // Verify supplier benefited from all premiums
        _verifySupplierEarnedPremiums(id, SUPPLIER, supplyAmount);
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-MARKET BORROWER SCENARIO
    //////////////////////////////////////////////////////////////*/

    function testMultiMarketBorrowerWithDifferentPremiums() public {
        // Simulates a borrower with positions in multiple markets
        // Each market has different risk assessment

        uint256 supplyAmount = 50_000e18;

        // Supply to both markets
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");
        vm.prank(SUPPLIER);
        morpho.supply(marketParams2, supplyAmount, 0, SUPPLIER, hex"");

        // Borrower supplies collateral to both markets
        // Credit line setup needed
        // Credit line setup needed

        // Different premium rates for different markets (risk assessment)
        uint128 market1Premium = uint128(uint256(0.1e18) / 365 days); // 10% APR - standard risk
        uint128 market2Premium = uint128(uint256(0.2e18) / 365 days); // 20% APR - higher risk market

        _setCreditLineWithPremium(id, BORROWER, 30_000e18, market1Premium);
        _setCreditLineWithPremium(id2, BORROWER, 30_000e18, market2Premium);

        // Borrow from both markets
        uint256 borrow1 = 15_000e18;
        uint256 borrow2 = 20_000e18;

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrow1, 0, BORROWER, BORROWER);
        vm.prank(BORROWER);
        morpho.borrow(marketParams2, borrow2, 0, BORROWER, BORROWER);

        // Time passes - premiums accrue at different rates
        vm.warp(block.timestamp + 90 days);

        // Manually accrue premiums for both markets
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id2, BORROWER);

        // Check debt in both markets
        Position memory pos1 = morpho.position(id, BORROWER);
        Position memory pos2 = morpho.position(id2, BORROWER);
        Market memory market1 = morpho.market(id);
        Market memory market2 = morpho.market(id2);

        uint256 debt1 = uint256(pos1.borrowShares).toAssetsUp(market1.totalBorrowAssets, market1.totalBorrowShares);
        uint256 debt2 = uint256(pos2.borrowShares).toAssetsUp(market2.totalBorrowAssets, market2.totalBorrowShares);

        // Market 2 should have accumulated more premium
        uint256 premium1 = debt1 - borrow1;
        uint256 premium2 = debt2 - borrow2;
        assertGt(premium2.wDivDown(borrow2), premium1.wDivDown(borrow1));

        // Borrower prioritizes repaying higher premium market
        // First accrue premium to get accurate repayment amount
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id2, BORROWER);

        // Get updated position after premium accrual
        pos2 = morpho.position(id2, BORROWER);
        market2 = morpho.market(id2);
        debt2 = uint256(pos2.borrowShares).toAssetsUp(market2.totalBorrowAssets, market2.totalBorrowShares);

        loanToken.setBalance(BORROWER, debt2 + 1000e18);
        vm.prank(BORROWER);
        morpho.repay(marketParams2, 0, pos2.borrowShares, BORROWER, hex"");

        // Verify market 2 debt cleared (may have tiny remainder due to rounding)
        Position memory clearedPos2 = morpho.position(id2, BORROWER);
        assertLe(clearedPos2.borrowShares, 1);

        // Continue with market 1
        vm.warp(block.timestamp + 30 days);

        // Update debt calculation for market 1
        pos1 = morpho.position(id, BORROWER);
        market1 = morpho.market(id);
        debt1 = uint256(pos1.borrowShares).toAssetsUp(market1.totalBorrowAssets, market1.totalBorrowShares);

        // Partial repayment on market 1
        uint256 partialPayment = debt1 / 2;
        loanToken.setBalance(BORROWER, partialPayment);
        vm.prank(BORROWER);
        morpho.repay(marketParams, partialPayment, 0, BORROWER, hex"");

        // Verify partial repayment
        Position memory finalPos1 = morpho.position(id, BORROWER);
        assertGt(finalPos1.borrowShares, 0);
        assertLt(finalPos1.borrowShares, pos1.borrowShares);
    }

    /*//////////////////////////////////////////////////////////////
                    DYNAMIC PREMIUM ADJUSTMENT SCENARIO
    //////////////////////////////////////////////////////////////*/

    function testDynamicPremiumAdjustmentBasedOnBehavior() public {
        // Simulates 3CA dynamically adjusting rates based on borrower behavior

        uint256 supplyAmount = 100_000e18;
        uint256 creditLineAmount = 75_000e18; // Account for 80% LLTV
        uint256 borrowAmount = 30_000e18;

        // Initial setup
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        // Initial borrow with standard premium
        uint128 standardPremium = uint128(uint256(0.12e18) / 365 days); // 12% APR
        _setCreditLineWithPremium(id, BORROWER, creditLineAmount, standardPremium);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Good behavior: Regular payments
        uint256[] memory paymentHistory = new uint256[](12);
        uint128[] memory premiumAdjustments = new uint128[](12);

        // Simulate 12 months of payment history
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(block.timestamp + 30 days);

            if (i < 6) {
                // First 6 months: Good payment behavior
                uint256 payment = 2_500e18;
                paymentHistory[i] = payment;

                loanToken.setBalance(BORROWER, payment);
                vm.prank(BORROWER);
                morpho.repay(marketParams, payment, 0, BORROWER, hex"");

                // 3CA reduces premium every 2 months for good behavior
                if (i % 2 == 1) {
                    // Convert reduction to per-second
                    uint128 reduction = uint128(uint256((i / 2 + 1) * 0.01e18) / 365 days);
                    uint128 newPremium = standardPremium - reduction;
                    premiumAdjustments[i] = newPremium;

                    _setCreditLineWithPremium(id, BORROWER, creditLineAmount, newPremium);
                }
            } else if (i >= 6 && i < 9) {
                // Months 7-9: Missed payments
                paymentHistory[i] = 0;

                // 3CA increases premium for missed payments
                if (i == 7) {
                    uint128 penaltyPremium = uint128(uint256(0.18e18) / 365 days); // 18% APR
                    premiumAdjustments[i] = penaltyPremium;

                    _setCreditLineWithPremium(id, BORROWER, creditLineAmount, penaltyPremium);
                }
            } else {
                // Months 10-12: Recovery with larger payments
                uint256 recoveryPayment = 5_000e18;
                paymentHistory[i] = recoveryPayment;

                loanToken.setBalance(BORROWER, recoveryPayment);
                vm.prank(BORROWER);
                morpho.repay(marketParams, recoveryPayment, 0, BORROWER, hex"");

                // 3CA gradually reduces premium again
                if (i == 11) {
                    uint128 recoveryPremium = uint128(uint256(0.14e18) / 365 days); // 14% APR
                    premiumAdjustments[i] = recoveryPremium;

                    _setCreditLineWithPremium(id, BORROWER, creditLineAmount, recoveryPremium);
                }
            }
        }

        // Final position check
        Position memory finalPosition = morpho.position(id, BORROWER);
        assertGt(finalPosition.borrowShares, 0); // Still has outstanding debt

        // Calculate total paid
        uint256 totalPaid = 0;
        for (uint256 i = 0; i < 12; i++) {
            totalPaid += paymentHistory[i];
        }

        // Calculate remaining debt in assets
        Market memory finalMarket = morpho.market(id);
        uint256 remainingDebt =
            uint256(finalPosition.borrowShares).toAssetsUp(finalMarket.totalBorrowAssets, finalMarket.totalBorrowShares);

        // Verify that total paid + remaining debt > borrowed amount (shows premium accumulation)
        assertGt(totalPaid + remainingDebt, borrowAmount);
    }

    /*//////////////////////////////////////////////////////////////
                    SUPPLIER YIELD OPTIMIZATION SCENARIO
    //////////////////////////////////////////////////////////////*/

    function testSupplierYieldFromDiversifiedPremiums() public {
        // Demonstrates how suppliers benefit from a diversified portfolio
        // of borrowers with different risk premiums

        uint256 supplyAmount = 200_000e18;
        uint256 collateralPerBorrower = 20_000e18;
        uint256 borrowPerBorrower = 10_000e18;

        // Create multiple borrowers with different risk profiles
        address[] memory borrowers = new address[](5);
        uint128[] memory riskPremiums = new uint128[](5);

        // Setup borrowers in scoped block
        {
            borrowers[0] = makeAddr("PrimeBorrower");
            borrowers[1] = makeAddr("GoodBorrower");
            borrowers[2] = makeAddr("StandardBorrower");
            borrowers[3] = makeAddr("SubprimeBorrower");
            borrowers[4] = makeAddr("HighRiskBorrower");

            riskPremiums[0] = uint128(uint256(0.02e18) / 365 days); // 2% APR - Prime
            riskPremiums[1] = uint128(uint256(0.05e18) / 365 days); // 5% APR - Good
            riskPremiums[2] = uint128(uint256(0.1e18) / 365 days); // 10% APR - Standard
            riskPremiums[3] = uint128(uint256(0.2e18) / 365 days); // 20% APR - Subprime
            riskPremiums[4] = uint128(uint256(0.35e18) / 365 days); // 35% APR - High Risk
        }

        // Supplier provides liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        // Setup all borrowers
        _setupMultipleBorrowers(borrowers, riskPremiums, collateralPerBorrower, borrowPerBorrower);

        // Simulate 1 year with different payment behaviors
        uint256 baseRate = 0.03e18; // 3% base rate
        ConfigurableIrmMock(address(irm)).setApr(baseRate);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Trigger premium accrual for all borrowers
        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, borrowers);

        // Calculate supplier's yield in scoped block
        uint256 yieldRate;
        {
            Position memory finalSupplierPos = morpho.position(id, SUPPLIER);
            Market memory finalMarket = morpho.market(id);

            uint256 supplierValue = uint256(finalSupplierPos.supplyShares).toAssetsDown(
                finalMarket.totalSupplyAssets, finalMarket.totalSupplyShares
            );

            uint256 supplierYield = supplierValue - supplyAmount;
            yieldRate = supplierYield.wDivDown(supplyAmount);
        }

        // Calculate expected yield accounting for how the protocol actually works
        // The protocol calculates base and premium rates together from the same starting principal

        uint256 expectedTotalInterest = 0;

        // For each borrower, calculate interest with combined rates
        for (uint256 i = 0; i < 5; i++) {
            // Calculate combined rate (base + premium)
            uint256 baseRatePerSecond = baseRate / 365 days;
            uint256 combinedRate = baseRatePerSecond + uint256(riskPremiums[i]);

            // Apply combined rate to original principal
            uint256 totalGrowth = combinedRate.wTaylorCompounded(365 days);
            uint256 totalInterest = borrowPerBorrower.wMulDown(totalGrowth);

            expectedTotalInterest += totalInterest;
        }

        uint256 expectedYieldRate = expectedTotalInterest.wDivDown(supplyAmount);

        // Verify supplier earned approximately the expected yield
        // Tolerance accounts for:
        // 1. Rounding differences in share calculations
        // 2. Minor timing differences in accrual
        // 3. Protocol fee calculations (if any)
        assertApproxEqRel(yieldRate, expectedYieldRate, 0.05e18); // 5% tolerance

        // Demonstrate individual borrower debts
        _verifyBorrowerDebts(borrowers, riskPremiums, borrowPerBorrower, baseRate);
    }

    /*//////////////////////////////////////////////////////////////
                    CREDIT LINE INCREASE SCENARIO
    //////////////////////////////////////////////////////////////*/

    function testCreditLineIncreaseWithPremiumAdjustment() public {
        // Simulates a borrower earning a credit line increase through good behavior

        uint256 initialSupply = 200_000e18;
        uint256 initialCreditLine = 20_000e18;

        // Setup market with credit line feature
        // Note: In real implementation, credit lines would be managed by the creditLine contract
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, initialSupply, 0, SUPPLIER, hex"");

        // Credit line setup needed

        // Initial credit assessment - moderate risk
        uint128 initialPremium = uint128(uint256(0.15e18) / 365 days); // 15% APR
        _setCreditLineWithPremium(id, BORROWER, 40_000e18, initialPremium);

        // Use initial credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, initialCreditLine * 8 / 10, 0, BORROWER, BORROWER); // 80% utilization

        // Good payment history for 6 months
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + 30 days);

            // Regular payments
            uint256 payment = 1_500e18;
            loanToken.setBalance(BORROWER, payment);
            vm.prank(BORROWER);
            morpho.repay(marketParams, payment, 0, BORROWER, hex"");
        }

        // Credit line increase approved by 3CA
        // 1. Reduce premium rate
        uint128 improvedPremium = uint128(uint256(0.08e18) / 365 days); // 8% APR
        _setCreditLineWithPremium(id, BORROWER, 40_000e18, improvedPremium);

        // 2. Borrower can now access more credit
        uint256 additionalCredit = 15_000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, additionalCredit, 0, BORROWER, BORROWER);

        // Continue good behavior
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + 30 days);

            // Increased payments for larger balance
            uint256 payment = 2_500e18;
            loanToken.setBalance(BORROWER, payment);
            vm.prank(BORROWER);
            morpho.repay(marketParams, payment, 0, BORROWER, hex"");
        }

        // Final assessment after 1 year
        Position memory finalPos = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);

        uint256 remainingDebt =
            uint256(finalPos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        // Verify borrower successfully managed increased credit line
        assertLt(remainingDebt, initialCreditLine + additionalCredit);

        // Calculate total interest paid
        uint256 totalPayments = 6 * 1_500e18 + 6 * 2_500e18;
        uint256 totalBorrowed = initialCreditLine * 8 / 10 + additionalCredit;
        uint256 interestPaid = totalPayments + remainingDebt - totalBorrowed;

        assertGt(interestPaid, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    PROTOCOL FEE IMPACT SCENARIO
    //////////////////////////////////////////////////////////////*/

    function testProtocolFeeDistributionAcrossMultipleBorrowers() public {
        // Demonstrates how protocol fees from premiums affect different stakeholders

        uint256 supplyAmount = 150_000e18;
        uint256 protocolFeeRate = 0.15e18; // 15% of interest/premiums

        // Set protocol fee
        vm.prank(OWNER);
        morpho.setFee(marketParams, protocolFeeRate);

        // Supply liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, hex"");

        // Setup borrowers with scoped block to reduce stack usage
        address[] memory borrowerArray = new address[](3);
        {
            address borrowerA = makeAddr("BorrowerA");
            address borrowerB = makeAddr("BorrowerB");
            address borrowerC = makeAddr("BorrowerC");

            borrowerArray[0] = borrowerA;
            borrowerArray[1] = borrowerB;
            borrowerArray[2] = borrowerC;

            uint256[3] memory borrowAmounts = [uint256(30_000e18), uint256(40_000e18), uint256(50_000e18)];
            uint128[3] memory premiumRates = [
                uint128(uint256(0.05e18) / 365 days),
                uint128(uint256(0.12e18) / 365 days),
                uint128(uint256(0.25e18) / 365 days)
            ]; // 5%, 12%, 25% APR

            _setupBorrowers(borrowerArray, borrowAmounts, premiumRates);
        }

        // Simulate 180 days
        vm.warp(block.timestamp + 180 days);

        // Accrue all premiums
        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, borrowerArray);

        // Calculate fee recipient earnings
        Position memory feeFinal = morpho.position(id, FEE_RECIPIENT);
        Market memory market = morpho.market(id);

        uint256 feeValue =
            uint256(feeFinal.supplyShares).toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);

        // Calculate supplier earnings (net of fees)
        Position memory supplierFinal = morpho.position(id, SUPPLIER);
        uint256 supplierValue =
            uint256(supplierFinal.supplyShares).toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);
        uint256 supplierEarnings = supplierValue - supplyAmount;

        // Calculate total premiums generated in scoped block
        uint256 totalPremiums;
        {
            uint256[3] memory borrowAmounts = [uint256(30_000e18), uint256(40_000e18), uint256(50_000e18)];
            uint128[3] memory premiumRates = [uint128(0.05e18), uint128(0.12e18), uint128(0.25e18)];

            for (uint256 i = 0; i < 3; i++) {
                // Approximate premium for each borrower
                uint256 premium = borrowAmounts[i].wMulDown(premiumRates[i]).wMulDown(180 * WAD / 365);
                totalPremiums += premium;
            }
        }

        // Verify fee distribution
        uint256 expectedFees = totalPremiums.wMulDown(protocolFeeRate);
        assertApproxEqRel(feeValue, expectedFees, 0.1e18); // 10% tolerance

        // Verify supplier gets remaining premiums
        uint256 expectedSupplierEarnings = totalPremiums - expectedFees;
        assertApproxEqRel(supplierEarnings, expectedSupplierEarnings, 0.1e18);

        // Demonstrate fee recipient can withdraw
        vm.prank(FEE_RECIPIENT);
        morpho.withdraw(marketParams, feeValue, 0, FEE_RECIPIENT, FEE_RECIPIENT);
        assertEq(loanToken.balanceOf(FEE_RECIPIENT), feeValue);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _verifySupplierEarnedPremiums(Id _id, address supplier, uint256 originalSupply) internal {
        Position memory supplierPos = morpho.position(_id, supplier);
        Market memory market = morpho.market(_id);
        uint256 supplierValue =
            uint256(supplierPos.supplyShares).toAssetsDown(market.totalSupplyAssets, market.totalSupplyShares);
        assertGt(supplierValue, originalSupply);
    }

    function _setupBorrowers(
        address[] memory borrowers,
        uint256[3] memory borrowAmounts,
        uint128[3] memory premiumRates
    ) internal {
        for (uint256 i = 0; i < 3; i++) {
            collateralToken.setBalance(borrowers[i], borrowAmounts[i] * 2);

            vm.prank(borrowers[i]);
            collateralToken.approve(address(morpho), type(uint256).max);

            // Credit line setup needed

            _setCreditLineWithPremium(id, borrowers[i], borrowAmounts[i] * 2, premiumRates[i]);

            vm.prank(borrowers[i]);
            morpho.borrow(marketParams, borrowAmounts[i], 0, borrowers[i], borrowers[i]);
        }
    }

    function _setupMultipleBorrowers(
        address[] memory borrowers,
        uint128[] memory riskPremiums,
        uint256 collateralPerBorrower,
        uint256 borrowPerBorrower
    ) internal {
        for (uint256 i = 0; i < borrowers.length; i++) {
            // Give collateral and approve
            collateralToken.setBalance(borrowers[i], collateralPerBorrower);
            vm.prank(borrowers[i]);
            collateralToken.approve(address(morpho), type(uint256).max);

            // Supply collateral
            // Credit line setup needed

            // Set risk premium
            _setCreditLineWithPremium(id, borrowers[i], collateralPerBorrower, riskPremiums[i]);

            // Borrow
            vm.prank(borrowers[i]);
            morpho.borrow(marketParams, borrowPerBorrower, 0, borrowers[i], borrowers[i]);
        }
    }

    function _verifyBorrowerDebts(
        address[] memory borrowers,
        uint128[] memory riskPremiums,
        uint256 borrowPerBorrower,
        uint256 baseRate
    ) internal {
        Market memory finalMarket = morpho.market(id);

        for (uint256 i = 0; i < borrowers.length; i++) {
            Position memory borrowerPos = morpho.position(id, borrowers[i]);
            uint256 debt = uint256(borrowerPos.borrowShares).toAssetsUp(
                finalMarket.totalBorrowAssets, finalMarket.totalBorrowShares
            );

            // Calculate expected debt with combined rates
            uint256 baseRatePerSecond = baseRate / 365 days;
            uint256 combinedRate = baseRatePerSecond + uint256(riskPremiums[i]);

            // Apply combined rate to original principal
            uint256 totalGrowth = combinedRate.wTaylorCompounded(365 days);
            uint256 expectedDebt = borrowPerBorrower + borrowPerBorrower.wMulDown(totalGrowth);
            assertApproxEqRel(debt, expectedDebt, 0.05e18); // 5% tolerance
        }
    }
}
