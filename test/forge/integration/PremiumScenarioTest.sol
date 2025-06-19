// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";

contract PremiumScenarioTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    address public premiumRateSetter;
    address public creditAnalyst; // Simulates 3CA role
    
    // Multiple test markets for cross-market scenarios
    MarketParams public marketParams2;
    Id public id2;
    
    function setUp() public override {
        super.setUp();
        
        premiumRateSetter = makeAddr("PremiumRateSetter");
        creditAnalyst = makeAddr("CreditAnalyst");
        
        // Set up premium rate setter
        vm.prank(OWNER);
        MorphoCredit(address(morpho)).setPremiumRateSetter(premiumRateSetter);
        
        // Enable LLTV for test markets
        vm.prank(OWNER);
        morpho.enableLltv(DEFAULT_TEST_LLTV);
        vm.prank(OWNER);
        morpho.enableLltv(0.9e18); // Higher LLTV for second market
        
        // Create first market
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV,
            creditLine: address(0)
        });
        
        morpho.createMarket(marketParams);
        id = marketParams.id();
        
        // Create second market with different LLTV
        marketParams2 = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.9e18,
            creditLine: address(0)
        });
        
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
                    COMPLETE CREDIT LINE LIFECYCLE
    //////////////////////////////////////////////////////////////*/
    
    function testCompleteCreditLineLifecycle() public {
        // This test simulates a complete lifecycle of a credit line in 3Jane
        // without traditional liquidations
        
        uint256 supplyAmount = 100_000e18;
        uint256 collateralAmount = 50_000e18;
        
        // Phase 1: Initial setup and credit assessment
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");
        
        // Borrower supplies collateral (could be virtual in future)
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, collateralAmount, BORROWER, "");
        
        // 3CA assesses borrower and sets initial premium rate based on credit score
        uint128 initialPremiumRate = 0.08e18; // 8% APR - good credit
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, initialPremiumRate);
        
        // Phase 2: Initial borrow
        uint256 initialBorrow = 20_000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, initialBorrow, 0, BORROWER, BORROWER);
        
        // Record initial state
        Position memory initialPosition = morpho.position(id, BORROWER);
        
        // Phase 3: Time passes, borrower makes partial payments
        vm.warp(block.timestamp + 30 days);
        
        // Borrower makes first payment
        uint256 firstPayment = 2_000e18;
        loanToken.setBalance(BORROWER, firstPayment);
        vm.prank(BORROWER);
        morpho.repay(marketParams, firstPayment, 0, BORROWER, "");
        
        // Phase 4: Credit improvement - 3CA reduces premium rate
        vm.warp(block.timestamp + 30 days);
        uint128 improvedPremiumRate = 0.05e18; // 5% APR - improved credit
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, improvedPremiumRate);
        
        // Phase 5: Borrower increases credit line usage
        uint256 additionalBorrow = 10_000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, additionalBorrow, 0, BORROWER, BORROWER);
        
        // Phase 6: Regular payments over time
        for (uint i = 0; i < 6; i++) {
            vm.warp(block.timestamp + 30 days);
            
            uint256 monthlyPayment = 3_000e18;
            loanToken.setBalance(BORROWER, monthlyPayment);
            vm.prank(BORROWER);
            morpho.repay(marketParams, monthlyPayment, 0, BORROWER, "");
        }
        
        // Phase 7: Credit deterioration - 3CA increases premium
        vm.warp(block.timestamp + 30 days);
        uint128 deterioratedPremiumRate = 0.15e18; // 15% APR - credit issues
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, deterioratedPremiumRate);
        
        // Phase 8: Final repayment
        vm.warp(block.timestamp + 60 days);
        
        // Calculate final debt
        Position memory finalPosition = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);
        uint256 finalDebt = uint256(finalPosition.borrowShares).toAssetsUp(
            market.totalBorrowAssets,
            market.totalBorrowShares
        );
        
        // Borrower repays remaining debt
        loanToken.setBalance(BORROWER, finalDebt + 1000e18); // Extra buffer
        vm.prank(BORROWER);
        morpho.repay(marketParams, 0, finalPosition.borrowShares, BORROWER, "");
        
        // Verify complete repayment
        Position memory closedPosition = morpho.position(id, BORROWER);
        assertEq(closedPosition.borrowShares, 0);
        
        // Verify supplier benefited from all premiums
        Position memory supplierPosition = morpho.position(id, SUPPLIER);
        Market memory finalMarket = morpho.market(id);
        uint256 supplierValue = uint256(supplierPosition.supplyShares).toAssetsDown(
            finalMarket.totalSupplyAssets,
            finalMarket.totalSupplyShares
        );
        assertGt(supplierValue, supplyAmount); // Supplier earned from premiums
    }
    
    /*//////////////////////////////////////////////////////////////
                    MULTI-MARKET BORROWER SCENARIO
    //////////////////////////////////////////////////////////////*/
    
    function testMultiMarketBorrowerWithDifferentPremiums() public {
        // Simulates a borrower with positions in multiple markets
        // Each market has different risk assessment
        
        uint256 supplyAmount = 50_000e18;
        uint256 collateralAmount = 30_000e18;
        
        // Supply to both markets
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");
        vm.prank(SUPPLIER);
        morpho.supply(marketParams2, supplyAmount, 0, SUPPLIER, "");
        
        // Borrower supplies collateral to both markets
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, collateralAmount, BORROWER, "");
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams2, collateralAmount, BORROWER, "");
        
        // Different premium rates for different markets (risk assessment)
        uint128 market1Premium = 0.1e18; // 10% APR - standard risk
        uint128 market2Premium = 0.2e18; // 20% APR - higher risk market
        
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, market1Premium);
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(id2, BORROWER, market2Premium);
        
        // Borrow from both markets
        uint256 borrow1 = 15_000e18;
        uint256 borrow2 = 20_000e18;
        
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrow1, 0, BORROWER, BORROWER);
        vm.prank(BORROWER);
        morpho.borrow(marketParams2, borrow2, 0, BORROWER, BORROWER);
        
        // Time passes - premiums accrue at different rates
        vm.warp(block.timestamp + 90 days);
        
        // Check debt in both markets
        Position memory pos1 = morpho.position(id, BORROWER);
        Position memory pos2 = morpho.position(id2, BORROWER);
        Market memory market1 = morpho.market(id);
        Market memory market2 = morpho.market(id2);
        
        uint256 debt1 = uint256(pos1.borrowShares).toAssetsUp(
            market1.totalBorrowAssets,
            market1.totalBorrowShares
        );
        uint256 debt2 = uint256(pos2.borrowShares).toAssetsUp(
            market2.totalBorrowAssets,
            market2.totalBorrowShares
        );
        
        // Market 2 should have accumulated more premium
        uint256 premium1 = debt1 - borrow1;
        uint256 premium2 = debt2 - borrow2;
        assertGt(premium2.wDivDown(borrow2), premium1.wDivDown(borrow1));
        
        // Borrower prioritizes repaying higher premium market
        loanToken.setBalance(BORROWER, debt2 + 1000e18);
        vm.prank(BORROWER);
        morpho.repay(marketParams2, 0, pos2.borrowShares, BORROWER, "");
        
        // Verify market 2 debt cleared
        Position memory clearedPos2 = morpho.position(id2, BORROWER);
        assertEq(clearedPos2.borrowShares, 0);
        
        // Continue with market 1
        vm.warp(block.timestamp + 30 days);
        
        // Update debt calculation for market 1
        pos1 = morpho.position(id, BORROWER);
        market1 = morpho.market(id);
        debt1 = uint256(pos1.borrowShares).toAssetsUp(
            market1.totalBorrowAssets,
            market1.totalBorrowShares
        );
        
        // Partial repayment on market 1
        uint256 partialPayment = debt1 / 2;
        loanToken.setBalance(BORROWER, partialPayment);
        vm.prank(BORROWER);
        morpho.repay(marketParams, partialPayment, 0, BORROWER, "");
        
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
        uint256 collateralAmount = 60_000e18;
        uint256 borrowAmount = 30_000e18;
        
        // Initial setup
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");
        
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, collateralAmount, BORROWER, "");
        
        // Initial borrow with standard premium
        uint128 standardPremium = 0.12e18; // 12% APR
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, standardPremium);
        
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);
        
        // Good behavior: Regular payments
        uint256[] memory paymentHistory = new uint256[](12);
        uint128[] memory premiumAdjustments = new uint128[](12);
        
        // Simulate 12 months of payment history
        for (uint i = 0; i < 12; i++) {
            vm.warp(block.timestamp + 30 days);
            
            if (i < 6) {
                // First 6 months: Good payment behavior
                uint256 payment = 2_500e18;
                paymentHistory[i] = payment;
                
                loanToken.setBalance(BORROWER, payment);
                vm.prank(BORROWER);
                morpho.repay(marketParams, payment, 0, BORROWER, "");
                
                // 3CA reduces premium every 2 months for good behavior
                if (i % 2 == 1) {
                    uint128 newPremium = standardPremium - uint128((i / 2 + 1) * 0.01e18);
                    premiumAdjustments[i] = newPremium;
                    
                    vm.prank(premiumRateSetter);
                    MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, newPremium);
                }
            } else if (i >= 6 && i < 9) {
                // Months 7-9: Missed payments
                paymentHistory[i] = 0;
                
                // 3CA increases premium for missed payments
                if (i == 7) {
                    uint128 penaltyPremium = 0.18e18; // 18% APR
                    premiumAdjustments[i] = penaltyPremium;
                    
                    vm.prank(premiumRateSetter);
                    MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, penaltyPremium);
                }
            } else {
                // Months 10-12: Recovery with larger payments
                uint256 recoveryPayment = 5_000e18;
                paymentHistory[i] = recoveryPayment;
                
                loanToken.setBalance(BORROWER, recoveryPayment);
                vm.prank(BORROWER);
                morpho.repay(marketParams, recoveryPayment, 0, BORROWER, "");
                
                // 3CA gradually reduces premium again
                if (i == 11) {
                    uint128 recoveryPremium = 0.14e18; // 14% APR
                    premiumAdjustments[i] = recoveryPremium;
                    
                    vm.prank(premiumRateSetter);
                    MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, recoveryPremium);
                }
            }
        }
        
        // Final position check
        Position memory finalPosition = morpho.position(id, BORROWER);
        assertGt(finalPosition.borrowShares, 0); // Still has outstanding debt
        
        // Calculate total paid vs borrowed
        uint256 totalPaid = 0;
        for (uint i = 0; i < 12; i++) {
            totalPaid += paymentHistory[i];
        }
        
        // Verify borrower paid significant premium over principal
        assertGt(totalPaid, borrowAmount);
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
        string[5] memory riskProfiles = ["Prime", "Good", "Standard", "Subprime", "HighRisk"];
        
        borrowers[0] = makeAddr("PrimeBorrower");
        borrowers[1] = makeAddr("GoodBorrower");
        borrowers[2] = makeAddr("StandardBorrower");
        borrowers[3] = makeAddr("SubprimeBorrower");
        borrowers[4] = makeAddr("HighRiskBorrower");
        
        riskPremiums[0] = 0.02e18;  // 2% APR - Prime
        riskPremiums[1] = 0.05e18;  // 5% APR - Good
        riskPremiums[2] = 0.10e18;  // 10% APR - Standard
        riskPremiums[3] = 0.20e18;  // 20% APR - Subprime
        riskPremiums[4] = 0.35e18;  // 35% APR - High Risk
        
        // Supplier provides liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");
        
        // Record initial supplier position
        Position memory initialSupplierPos = morpho.position(id, SUPPLIER);
        
        // Setup all borrowers
        for (uint i = 0; i < 5; i++) {
            // Give collateral and approve
            collateralToken.setBalance(borrowers[i], collateralPerBorrower);
            vm.prank(borrowers[i]);
            collateralToken.approve(address(morpho), type(uint256).max);
            
            // Supply collateral
            vm.prank(borrowers[i]);
            morpho.supplyCollateral(marketParams, collateralPerBorrower, borrowers[i], "");
            
            // Set risk premium
            vm.prank(premiumRateSetter);
            MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, borrowers[i], riskPremiums[i]);
            
            // Borrow
            vm.prank(borrowers[i]);
            morpho.borrow(marketParams, borrowPerBorrower, 0, borrowers[i], borrowers[i]);
        }
        
        // Simulate 1 year with different payment behaviors
        uint256 baseRate = 0.03e18; // 3% base rate
        ConfigurableIrmMock(address(irm)).setApr(baseRate);
        
        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);
        
        // Trigger premium accrual for all borrowers
        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, borrowers);
        
        // Calculate supplier's yield
        Position memory finalSupplierPos = morpho.position(id, SUPPLIER);
        Market memory finalMarket = morpho.market(id);
        
        uint256 supplierValue = uint256(finalSupplierPos.supplyShares).toAssetsDown(
            finalMarket.totalSupplyAssets,
            finalMarket.totalSupplyShares
        );
        
        uint256 supplierYield = supplierValue - supplyAmount;
        uint256 yieldRate = supplierYield.wDivDown(supplyAmount);
        
        // Calculate expected weighted average yield
        // With 5 borrowers each borrowing 10k from 200k supply = 50k utilized
        // Utilization = 25%
        uint256 totalBorrowed = borrowPerBorrower * 5;
        uint256 utilization = totalBorrowed.wDivDown(supplyAmount);
        
        // Weighted average premium across all borrowers
        uint256 avgPremium = (riskPremiums[0] + riskPremiums[1] + riskPremiums[2] + 
                             riskPremiums[3] + riskPremiums[4]) / 5;
        
        // Expected yield = utilization * (base rate + avg premium)
        uint256 expectedYieldRate = utilization.wMulDown(baseRate + avgPremium);
        
        // Verify supplier earned approximately the expected yield
        assertApproxEqRel(yieldRate, expectedYieldRate, 0.1e18); // 10% tolerance
        
        // Demonstrate individual borrower debts
        for (uint i = 0; i < 5; i++) {
            Position memory borrowerPos = morpho.position(id, borrowers[i]);
            uint256 debt = uint256(borrowerPos.borrowShares).toAssetsUp(
                finalMarket.totalBorrowAssets,
                finalMarket.totalBorrowShares
            );
            
            // Higher risk borrowers should have higher debt
            uint256 expectedDebt = borrowPerBorrower.wMulDown(WAD + baseRate + riskPremiums[i]);
            assertApproxEqRel(debt, expectedDebt, 0.05e18);
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                    CREDIT LINE INCREASE SCENARIO
    //////////////////////////////////////////////////////////////*/
    
    function testCreditLineIncreaseWithPremiumAdjustment() public {
        // Simulates a borrower earning a credit line increase through good behavior
        
        uint256 initialSupply = 200_000e18;
        uint256 initialCollateral = 30_000e18;
        uint256 initialCreditLine = 20_000e18;
        
        // Setup market with credit line feature
        // Note: In real implementation, credit lines would be managed by the creditLine contract
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, initialSupply, 0, SUPPLIER, "");
        
        vm.prank(BORROWER);
        morpho.supplyCollateral(marketParams, initialCollateral, BORROWER, "");
        
        // Initial credit assessment - moderate risk
        uint128 initialPremium = 0.15e18; // 15% APR
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, initialPremium);
        
        // Use initial credit line
        vm.prank(BORROWER);
        morpho.borrow(marketParams, initialCreditLine * 8 / 10, 0, BORROWER, BORROWER); // 80% utilization
        
        // Good payment history for 6 months
        for (uint i = 0; i < 6; i++) {
            vm.warp(block.timestamp + 30 days);
            
            // Regular payments
            uint256 payment = 1_500e18;
            loanToken.setBalance(BORROWER, payment);
            vm.prank(BORROWER);
            morpho.repay(marketParams, payment, 0, BORROWER, "");
        }
        
        // Credit line increase approved by 3CA
        // 1. Reduce premium rate
        uint128 improvedPremium = 0.08e18; // 8% APR
        vm.prank(premiumRateSetter);
        MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, BORROWER, improvedPremium);
        
        // 2. Borrower can now access more credit
        uint256 additionalCredit = 15_000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, additionalCredit, 0, BORROWER, BORROWER);
        
        // Continue good behavior
        for (uint i = 0; i < 6; i++) {
            vm.warp(block.timestamp + 30 days);
            
            // Increased payments for larger balance
            uint256 payment = 2_500e18;
            loanToken.setBalance(BORROWER, payment);
            vm.prank(BORROWER);
            morpho.repay(marketParams, payment, 0, BORROWER, "");
        }
        
        // Final assessment after 1 year
        Position memory finalPos = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);
        
        uint256 remainingDebt = uint256(finalPos.borrowShares).toAssetsUp(
            market.totalBorrowAssets,
            market.totalBorrowShares
        );
        
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
        morpho.supply(marketParams, supplyAmount, 0, SUPPLIER, "");
        
        // Create 3 borrowers with different profiles
        address borrowerA = makeAddr("BorrowerA");
        address borrowerB = makeAddr("BorrowerB");
        address borrowerC = makeAddr("BorrowerC");
        
        address[3] memory allBorrowers = [borrowerA, borrowerB, borrowerC];
        uint256[3] memory borrowAmounts = [uint256(30_000e18), uint256(40_000e18), uint256(50_000e18)];
        uint128[3] memory premiumRates = [uint128(0.05e18), uint128(0.12e18), uint128(0.25e18)]; // 5%, 12%, 25% APR
        
        // Setup all borrowers
        for (uint i = 0; i < 3; i++) {
            collateralToken.setBalance(allBorrowers[i], borrowAmounts[i] * 2);
            
            vm.prank(allBorrowers[i]);
            collateralToken.approve(address(morpho), type(uint256).max);
            
            vm.prank(allBorrowers[i]);
            morpho.supplyCollateral(marketParams, borrowAmounts[i] * 2, allBorrowers[i], "");
            
            vm.prank(premiumRateSetter);
            MorphoCredit(address(morpho)).setBorrowerPremiumRate(id, allBorrowers[i], premiumRates[i]);
            
            vm.prank(allBorrowers[i]);
            morpho.borrow(marketParams, borrowAmounts[i], 0, allBorrowers[i], allBorrowers[i]);
        }
        
        // Record initial positions
        Position memory supplierInitial = morpho.position(id, SUPPLIER);
        Position memory feeInitial = morpho.position(id, FEE_RECIPIENT);
        
        // Simulate 180 days
        vm.warp(block.timestamp + 180 days);
        
        // Accrue all premiums
        address[] memory borrowerArray = new address[](3);
        borrowerArray[0] = borrowerA;
        borrowerArray[1] = borrowerB;
        borrowerArray[2] = borrowerC;
        MorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, borrowerArray);
        
        // Calculate fee recipient earnings
        Position memory feeFinal = morpho.position(id, FEE_RECIPIENT);
        Market memory market = morpho.market(id);
        
        uint256 feeValue = uint256(feeFinal.supplyShares).toAssetsDown(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );
        
        // Calculate supplier earnings (net of fees)
        Position memory supplierFinal = morpho.position(id, SUPPLIER);
        uint256 supplierValue = uint256(supplierFinal.supplyShares).toAssetsDown(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );
        uint256 supplierEarnings = supplierValue - supplyAmount;
        
        // Calculate total premiums generated
        uint256 totalPremiums = 0;
        for (uint i = 0; i < 3; i++) {
            // Approximate premium for each borrower
            uint256 premium = borrowAmounts[i].wMulDown(premiumRates[i]).wMulDown(180 * WAD / 365);
            totalPremiums += premium;
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
}