// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";

contract PremiumCompoundingTest is BaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    uint256 internal constant TEST_CYCLE_DURATION = 30 days;

    MorphoCredit public morphoCredit;
    CreditLineMock public creditLine;
    ConfigurableIrmMock public configurableIrm;

    function setUp() public override {
        super.setUp();

        // Set cycle duration in protocol config
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), TEST_CYCLE_DURATION);

        morphoCredit = MorphoCredit(payable(address(morpho)));
        creditLine = new CreditLineMock(address(morpho));
        configurableIrm = new ConfigurableIrmMock();

        // Enable IRM
        vm.prank(OWNER);
        morpho.enableIrm(address(configurableIrm));

        // Create market with credit line
        marketParams.irm = address(configurableIrm);
        marketParams.creditLine = address(creditLine);
        vm.prank(OWNER);
        morpho.createMarket(marketParams);
        id = MarketParamsLib.id(marketParams);

        // Initialize first cycle to unfreeze the market
        vm.warp(block.timestamp + TEST_CYCLE_DURATION);
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(id, block.timestamp, borrowers, repaymentBps, endingBalances);

        // Set up initial balances
        loanToken.setBalance(SUPPLIER, HIGH_COLLATERAL_AMOUNT);
        loanToken.setBalance(BORROWER, HIGH_COLLATERAL_AMOUNT);
    }

    // This test demonstrates the compounding issue in premium calculation
    function test_premiumCompoundingIssue() public {
        // Set base rate to 10% APR
        uint256 baseRateAPR = 0.1e18; // 10% in WAD
        configurableIrm.setApr(baseRateAPR);

        // Supply liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        // Set up borrower with 10% premium (20% total APR)
        uint256 premiumAPR = 0.1e18; // 10% in WAD
        uint256 premiumRatePerSecond = premiumAPR / 365 days;

        vm.prank(address(creditLine));
        creditLine.setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRatePerSecond));

        // Borrow 1000 tokens
        uint256 borrowAmount = 1000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // === DEMONSTRATE THE ISSUE ===

        // After 1 year with continuous compounding at 20% APR:
        // Amount = Principal * e^(rate * time) = 1000 * e^0.2 ≈ 1221.4
        uint256 expectedFinalAmount = borrowAmount.wMulDown(1.2214e18); // e^0.2

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Accrue base interest
        morpho.accrueInterest(marketParams);

        // Get position after base interest only
        Position memory pos = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);
        uint256 amountAfterBase =
            uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        console.log("\n=== COMPOUNDING ISSUE DEMONSTRATION ===");
        console.log("Initial borrow: %e", borrowAmount / 1e18);
        console.log("After base interest (10% APR): %e", amountAfterBase / 1e18);

        // Now accrue premium
        morphoCredit.accrueBorrowerPremium(id, BORROWER);

        // Get final position
        pos = morpho.position(id, BORROWER);
        market = morpho.market(id);
        uint256 finalAmount = uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        console.log("After premium accrual: %d", finalAmount);
        console.log("Expected with true compounding (e^0.2): %d", expectedFinalAmount);

        // The issue: When we calculate premium, we:
        // 1. See base grew from 1000 to ~1105 (10% simple interest approximation)
        // 2. Reverse-engineer base rate: (1105-1000)/(1000*365days) ≈ 10%/year
        // 3. Add premium rate: 10% + 10% = 20%
        // 4. Compound at 20% from original 1000
        //
        // But this misses that the base already compounded!
        // The true calculation should compound the premium on top of
        // the already-compounded base amount.

        uint256 difference =
            expectedFinalAmount > finalAmount ? expectedFinalAmount - finalAmount : finalAmount - expectedFinalAmount;

        console.log("Difference: %e", difference);
        console.log("Difference bps: %e", difference * 1e18 / expectedFinalAmount / 1e14);
    }

    // Test showing the issue gets worse with multiple accruals
    function test_multipleAccrualsCompoundingDrift() public {
        // Set base rate to 10% APR
        configurableIrm.setApr(0.1e18);

        // Supply and set up borrower
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        vm.prank(address(creditLine));
        uint256 premiumAPR = 0.1e18;
        uint256 premiumRatePerSecond = premiumAPR / (365 days);
        creditLine.setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRatePerSecond));

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1000e18, 0, BORROWER, BORROWER);

        uint256 lastAmount = 1000e18;

        // Accrue monthly for a year
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(block.timestamp + 30 days);

            morpho.accrueInterest(marketParams);
            morphoCredit.accrueBorrowerPremium(id, BORROWER);

            Position memory pos = morpho.position(id, BORROWER);
            Market memory market = morpho.market(id);
            uint256 currentAmount =
                uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

            uint256 monthlyGrowth = currentAmount - lastAmount;
            uint256 growthRate = monthlyGrowth * 10000 / lastAmount; // basis points

            console.log(string.concat("Month ", vm.toString(i + 1)));
            console.log("Amount:", currentAmount / 1e18);
            console.log("Growth (bps):", growthRate);

            lastAmount = currentAmount;
        }

        console.log("\nNotice how the growth rate changes each month due to compounding drift");
    }
}
