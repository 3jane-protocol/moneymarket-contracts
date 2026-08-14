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

    function testPremiumUsesCurrentDebtAfterMaterialBaseGrowth() public {
        configurableIrm.setApr(1e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        uint256 premiumRate = uint256(0.1e18) / 365 days;
        vm.prank(address(creditLine));
        creditLine.setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRate));

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1_000e18, 0, BORROWER, BORROWER);

        vm.warp(block.timestamp + 365 days);
        morpho.accrueInterest(marketParams);

        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);
        uint256 currentDebt = uint256(positionBefore.borrowShares)
            .toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);
        uint256 expectedPremium = currentDebt.wMulDown(premiumRate.wTaylorCompounded(365 days));

        morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));

        Position memory positionAfter = morpho.position(id, BORROWER);
        Market memory marketAfter = morpho.market(id);
        uint256 finalDebt = uint256(positionAfter.borrowShares)
            .toAssetsUp(marketAfter.totalBorrowAssets, marketAfter.totalBorrowShares);

        assertApproxEqAbs(finalDebt, currentDebt + expectedPremium, 2, "premium must apply directly to current debt");
    }

    // Regression guard: with base growth above 3x, premium accrual reverted before c55efd41
    // (wInverseTaylorCompounded underflow in the old base-rate reconstruction). The guarded
    // behaviour is that accruePremiumsForBorrowers completes without reverting; the assertion
    // below only pins the >3x precondition that used to trigger the underflow.
    function testPremiumAccrualSurvivesBaseGrowthAboveThreeX() public {
        configurableIrm.setApr(1.5e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        uint256 premiumRate = uint256(0.1e18) / 365 days;
        vm.prank(address(creditLine));
        creditLine.setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRate));

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1_000e18, 0, BORROWER, BORROWER);

        vm.warp(block.timestamp + 365 days);
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));

        (,, uint128 borrowAssetsAtLastAccrual) = morphoCredit.borrowerPremium(id, BORROWER);
        assertGt(borrowAssetsAtLastAccrual, 3_000e18, "base-accrued debt should exceed three times principal");
    }

    function testPremiumCrossCompoundsWithBaseGrowth() public {
        // Set base rate to 10% APR
        uint256 baseRateAPR = 0.1e18; // 10% in WAD
        configurableIrm.setApr(baseRateAPR);

        // Supply liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        // Set up borrower with a 10% premium.
        uint256 premiumAPR = 0.1e18; // 10% in WAD
        uint256 premiumRatePerSecond = premiumAPR / 365 days;

        vm.prank(address(creditLine));
        creditLine.setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRatePerSecond));

        // Borrow 1000 tokens
        uint256 borrowAmount = 1000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        vm.warp(block.timestamp + 365 days);
        morpho.accrueInterest(marketParams);

        Position memory pos = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);
        uint256 amountAfterBase =
            uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 expectedPremium = amountAfterBase.wMulDown(premiumRatePerSecond.wTaylorCompounded(365 days));

        morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));

        pos = morpho.position(id, BORROWER);
        market = morpho.market(id);
        uint256 finalAmount = uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

        assertApproxEqAbs(finalAmount, amountAfterBase + expectedPremium, 2, "base growth must carry the premium");

        // Independent oracle: 10% base + 10% premium continuously compounded over one year
        // is borrowAmount * e^0.2. This bound is implementation-agnostic and must keep holding
        // even if the premium expression is rewritten self-consistently.
        assertApproxEqRel(
            finalAmount, borrowAmount.wMulDown(1.2214e18), 1e14, "premium+base must match continuous compounding e^0.2"
        );
    }

    function testPremiumElapsedTimeClampedToOneYearOnDormantBorrower() public {
        configurableIrm.setApr(0.1e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        uint256 premiumRate = uint256(0.1e18) / 365 days;
        vm.prank(address(creditLine));
        creditLine.setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRate));

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1_000e18, 0, BORROWER, BORROWER);

        // Leave the borrower untouched for materially longer than MAX_ELAPSED_TIME (365 days).
        uint256 dormancy = 550 days;
        vm.warp(block.timestamp + dormancy);
        morpho.accrueInterest(marketParams);

        Position memory positionBefore = morpho.position(id, BORROWER);
        Market memory marketBefore = morpho.market(id);
        uint256 currentDebt = uint256(positionBefore.borrowShares)
            .toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);

        // The premium factor is clamped to 365 days while currentDebt carries the full
        // unclamped 550 days of base growth: premium = currentDebt * (e^{p*365d} - 1).
        // Pre-c55efd41 this scenario charged zero premium: the clamped total-growth figure
        // fell below full-period base growth, so the old subtraction guard zeroed it out and
        // a borrower untouched for over a year escaped premium entirely. Charging the
        // clamped-period premium on current debt is a deliberate behaviour change.
        uint256 expectedPremium = currentDebt.wMulDown(premiumRate.wTaylorCompounded(365 days));
        assertGt(expectedPremium, 0, "dormant borrower must still be charged premium");

        morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));

        Position memory positionAfter = morpho.position(id, BORROWER);
        Market memory marketAfter = morpho.market(id);
        uint256 finalDebt = uint256(positionAfter.borrowShares)
            .toAssetsUp(marketAfter.totalBorrowAssets, marketAfter.totalBorrowShares);

        assertApproxEqAbs(
            finalDebt, currentDebt + expectedPremium, 2, "premium must equal the 365-day clamped figure on current debt"
        );

        uint256 unclampedPremium = currentDebt.wMulDown(premiumRate.wTaylorCompounded(dormancy));
        assertLt(finalDebt, currentDebt + unclampedPremium, "elapsed time must be clamped to MAX_ELAPSED_TIME");
    }

    // Anti-griefing guard: spamming accruePremiumsForBorrowers every few seconds must not suppress
    // premium yield. Two properties make this hold, and this test breaks if either is lost:
    // 1. Sub-threshold accruals (totalPremium < MIN_PREMIUM_THRESHOLD) return before the
    //    lastAccrualTime write, so elapsed time is deferred and keeps accumulating, not discarded.
    // 2. Premium is charged on current borrow assets, not borrowAssetsAtLastAccrual, so the
    //    unconditional snapshot rewrite performed on every accruePremiumsForBorrowers call cannot
    //    shrink the amount charged.
    function testAccrualSpamCannotSuppressPremiumYield() public {
        // Zero base rate isolates premium: all debt growth below is charged premium.
        configurableIrm.setApr(0);

        // The 1-wei MIN_PREMIUM_THRESHOLD is only reachable per-call with small debt; lift the
        // dust floor so the borrower can sit in the sub-threshold regime.
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("MIN_BORROW"), 0);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        // 2.5e9 per-second WAD (~7.9% APR) on 1e7 wei of debt accrues exactly 0.25 wei of premium
        // per 10-second step, so three out of every four spam calls are sub-threshold.
        uint256 premiumRate = 2.5e9;
        vm.prank(address(creditLine));
        creditLine.setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRate));

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1e7, 0, BORROWER, BORROWER);

        uint256 debtStart = _currentBorrowerDebt();
        (uint128 accrualClockStart,,) = morphoCredit.borrowerPremium(id, BORROWER);

        uint256 step = 10 seconds;
        uint256 totalPeriod = 3 days;

        // First spam call is sub-threshold: it must charge nothing AND leave the accrual clock
        // untouched, so the elapsed time it covers is deferred rather than discarded.
        vm.warp(block.timestamp + step);
        morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));
        (uint128 accrualClockAfterOne,,) = morphoCredit.borrowerPremium(id, BORROWER);
        assertEq(accrualClockAfterOne, accrualClockStart, "sub-threshold accrual must not advance the clock");
        assertEq(_currentBorrowerDebt(), debtStart, "sub-threshold accrual must charge nothing");

        for (uint256 elapsed = step; elapsed < totalPeriod; elapsed += step) {
            vm.warp(block.timestamp + step);
            morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));
        }

        uint256 totalCharged = _currentBorrowerDebt() - debtStart;
        uint256 singleAccrualReference = debtStart.wMulDown(premiumRate.wTaylorCompounded(totalPeriod));

        assertGt(totalCharged, 0, "spammed accrual must still charge premium");

        // Tolerance 0.5% relative. Legitimate drift between the spammed and single-shot figures is
        // (a) Taylor partitioning: the single accrual carries the x^2/2 and x^3/6 compounding terms
        //     over the full 3 days (~3e-4 relative here) that per-slice charging realizes only
        //     through debt growth, and
        // (b) rounding: each charging event floors via wMulDown (losing the sub-wei residual, under
        //     0.25 wei per event with these parameters) and share conversion rounds by 1 wei.
        // Both are orders of magnitude inside 0.5%, while the guarded failure -- yield collapsing
        // toward zero under spam -- is a 100% deviation.
        assertApproxEqRel(
            totalCharged, singleAccrualReference, 0.005e18, "spam must not suppress premium versus a single accrual"
        );
    }

    function _currentBorrowerDebt() internal view returns (uint256) {
        Position memory pos = morpho.position(id, BORROWER);
        Market memory market = morpho.market(id);
        return uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
    }

    function testMonthlyPremiumAccrualAppliesStableRateToCurrentDebt() public {
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

        uint256 lastGrowthRate;
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(block.timestamp + 30 days);

            morpho.accrueInterest(marketParams);
            Position memory positionAfterBase = morpho.position(id, BORROWER);
            Market memory marketAfterBase = morpho.market(id);
            uint256 debtAfterBase = uint256(positionAfterBase.borrowShares)
                .toAssetsUp(marketAfterBase.totalBorrowAssets, marketAfterBase.totalBorrowShares);
            uint256 expectedPremium = debtAfterBase.wMulDown(premiumRatePerSecond.wTaylorCompounded(30 days));

            morphoCredit.accruePremiumsForBorrowers(id, _toArray(BORROWER));

            Position memory pos = morpho.position(id, BORROWER);
            Market memory market = morpho.market(id);
            uint256 currentAmount =
                uint256(pos.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);

            assertApproxEqAbs(
                currentAmount, debtAfterBase + expectedPremium, 2, "monthly premium must apply to base-accrued debt"
            );

            uint256 growthRate = expectedPremium.wDivDown(debtAfterBase);
            if (i != 0) assertApproxEqAbs(growthRate, lastGrowthRate, 1, "premium factor must be checkpoint-stable");
            lastGrowthRate = growthRate;
        }
    }
}
