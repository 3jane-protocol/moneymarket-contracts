// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "../../../src/libraries/periphery/MorphoBalancesLib.sol";

/// @title PremiumRateChangeTimestampTest
/// @notice Regression tests for premium rate change timestamp update issue
/// @dev Verifies that timestamp is correctly updated when premium rate changes to prevent double accounting
contract PremiumRateChangeTimestampTest is BaseTest {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    MorphoCredit public morphoCredit;
    CreditLineMock public creditLine;
    ConfigurableIrmMock public configurableIrm;

    function setUp() public override {
        super.setUp();

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

        // Initialize market cycles to prevent freezing
        _ensureMarketActive(id);

        // Set up initial balances
        loanToken.setBalance(SUPPLIER, HIGH_COLLATERAL_AMOUNT);
        loanToken.setBalance(BORROWER, HIGH_COLLATERAL_AMOUNT);
    }

    /// @notice Test from audit PoC demonstrating the timestamp issue
    /// @dev This test will fail before the fix and pass after
    function test_UpdatePremiumRate_Timestamp() public {
        // Set base rate to 10% APR
        uint256 baseRateAPR = 0.1e18; // 10% in WAD
        configurableIrm.setApr(baseRateAPR);

        // Supply liquidity
        vm.prank(SUPPLIER);
        (, uint256 sharesMinted) = morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");
        console.log("Shares minted: ", sharesMinted);

        // Set up borrower with 10% premium (20% total APR)
        uint256 premiumAPR = 0.1e18; // 10% in WAD
        uint256 premiumRatePerSecond = premiumAPR / 365 days;

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRatePerSecond));

        // Borrow 1000 tokens
        uint256 borrowAmount = 1000e18;
        vm.prank(BORROWER);
        morpho.borrow(marketParams, borrowAmount, 0, BORROWER, BORROWER);

        // Get initial timestamp
        (uint256 lastAccrualTimeBefore,, uint256 borrowAssetsAtLastAccrualBefore) =
            IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        console.log("Initial premium timestamp:", lastAccrualTimeBefore);
        console.log("Initial borrow assets at last accrual:", borrowAssetsAtLastAccrualBefore);

        // Skip 7 days to accumulate some interest
        skip(86400 * 7);

        // Update premium rate (double it)
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRatePerSecond * 2));

        // Get timestamp after rate update
        (uint256 lastAccrualTimeAfter,, uint256 borrowAssetsAtLastAccrualAfter) =
            IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        console.log("Premium timestamp after rate update:", lastAccrualTimeAfter);
        console.log("Borrow assets at last accrual after rate update:", borrowAssetsAtLastAccrualAfter);

        // The timestamp should be updated to current time
        assertEq(lastAccrualTimeAfter, block.timestamp, "Timestamp should be updated to current time");

        // The borrow assets should be updated to reflect accrued interest
        assertGt(
            borrowAssetsAtLastAccrualAfter,
            borrowAssetsAtLastAccrualBefore,
            "Borrow assets should increase due to accrued interest"
        );
    }

    /// @notice Test that premium is not double-counted after rate change
    function test_NoDoubleAccountingAfterRateChange() public {
        // Set base rate to 10% APR
        configurableIrm.setApr(0.1e18);

        // Supply liquidity
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        // Set up borrower with 10% premium
        uint256 premiumRatePerSecond = uint256(0.1e18) / uint256(365 days);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRatePerSecond));

        // Borrow 1000 tokens
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1000e18, 0, BORROWER, BORROWER);

        // Wait 7 days
        skip(7 days);

        // Get debt before rate change
        uint256 debtBefore = morpho.expectedBorrowAssets(marketParams, BORROWER);

        // Update rate (double it)
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRatePerSecond * 2));

        // Get debt immediately after rate change
        uint256 debtAfterRateChange = morpho.expectedBorrowAssets(marketParams, BORROWER);

        // The debt should have increased due to the 7 days of interest
        assertGt(debtAfterRateChange, debtBefore, "Debt should increase from accrued interest");

        // Now skip another 7 days
        skip(7 days);

        // Accrue interest again
        morpho.accrueInterest(marketParams);
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(BORROWER));

        uint256 debtAfterSecondAccrual = morpho.expectedBorrowAssets(marketParams, BORROWER);

        // Calculate expected growth
        // First week: 10% base + 10% premium = 20% APR
        // Second week: 10% base + 20% premium = 30% APR
        // The growth in the second week should be higher than the first week
        uint256 firstWeekGrowth = debtAfterRateChange - 1000e18;
        uint256 secondWeekGrowth = debtAfterSecondAccrual - debtAfterRateChange;

        console.log("First week growth (20% APR):", firstWeekGrowth);
        console.log("Second week growth (30% APR):", secondWeekGrowth);

        // Second week should have more growth due to higher rate
        assertGt(secondWeekGrowth, firstWeekGrowth, "Second week should have higher growth due to increased rate");

        // Verify no double accounting: the total debt should be reasonable
        // With proper accounting: ~1000 * (1 + 0.20/52) * (1 + 0.30/52) ≈ 1009.6
        // With double accounting, it would be much higher
        assertLt(debtAfterSecondAccrual, 1015e18, "Total debt should not show double accounting");
    }

    /// @notice Test multiple rate changes in sequence
    function test_MultipleRateChanges() public {
        configurableIrm.setApr(0.1e18); // 10% base rate

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        uint256 basePremiumRate = uint256(0.05e18) / uint256(365 days); // 5% APR

        // Initial setup
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(basePremiumRate));

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1000e18, 0, BORROWER, BORROWER);

        uint256 lastTimestamp = block.timestamp;

        // Perform multiple rate changes
        for (uint256 i = 1; i <= 3; i++) {
            skip(3 days);

            // Change rate
            uint256 newRate = basePremiumRate * (i + 1);
            vm.prank(address(creditLine));
            IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(newRate));

            // Check timestamp is updated
            (uint256 currentTimestamp,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
            assertEq(currentTimestamp, block.timestamp, "Timestamp should be updated on each rate change");
            assertGt(currentTimestamp, lastTimestamp, "Timestamp should advance");

            lastTimestamp = currentTimestamp;

            console.log("Rate change", i, "- New timestamp:", currentTimestamp);
        }

        // Final accrual to ensure no issues
        skip(3 days);
        morpho.accrueInterest(marketParams);
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(BORROWER));

        uint256 finalDebt = morpho.expectedBorrowAssets(marketParams, BORROWER);
        console.log("Final debt after multiple rate changes:", finalDebt);

        // Debt should be reasonable (not doubled)
        assertLt(finalDebt, 1020e18, "Debt should grow reasonably without double accounting");
    }

    /// @notice Test rate decrease scenario
    function test_RateDecrease() public {
        configurableIrm.setApr(0.1e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        // Start with high premium rate
        uint256 highPremiumRate = uint256(0.2e18) / uint256(365 days); // 20% APR
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(highPremiumRate));

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1000e18, 0, BORROWER, BORROWER);

        skip(7 days);

        // Get debt with high rate
        uint256 debtBeforeDecrease = morpho.expectedBorrowAssets(marketParams, BORROWER);
        console.log("Debt before rate decrease:", debtBeforeDecrease);

        // Decrease rate to 5% APR
        uint256 lowPremiumRate = uint256(0.05e18) / uint256(365 days);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(lowPremiumRate));

        // Get debt right after rate change to see if premium was accrued
        uint256 debtAfterRateChange = morpho.expectedBorrowAssets(marketParams, BORROWER);
        console.log("Debt right after rate change:", debtAfterRateChange);

        // Verify timestamp is updated
        (uint256 timestampAfterDecrease,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertEq(timestampAfterDecrease, block.timestamp, "Timestamp should be updated on rate decrease");

        skip(7 days);

        // Get debt after second week (expectedBorrowAssets will trigger internal accrual)
        uint256 debtAfterLowRate = morpho.expectedBorrowAssets(marketParams, BORROWER);
        console.log("Debt after second week:", debtAfterLowRate);

        // Calculate growth rates (percentage increase) instead of absolute amounts
        // First week: from initial borrow to rate change (includes accrual at rate change)
        uint256 firstWeekGrowth = debtAfterRateChange - 1000e18;
        // Second week: from rate change to end (only the new lower rate)
        uint256 secondWeekGrowth = debtAfterLowRate - debtAfterRateChange;

        // Calculate growth rates relative to principal
        uint256 firstWeekRate = (firstWeekGrowth * 1e18) / 1000e18;
        uint256 secondWeekRate = (secondWeekGrowth * 1e18) / debtAfterRateChange;

        console.log("First week growth (30% APR):", firstWeekGrowth);
        console.log("Second week growth (15% APR):", secondWeekGrowth);
        console.log("First week growth rate (basis points):", firstWeekRate / 1e14);
        console.log("Second week growth rate (basis points):", secondWeekRate / 1e14);

        // Second week should have lower growth rate due to decreased rate
        assertLt(secondWeekRate, firstWeekRate, "Second week should have lower growth rate due to decreased rate");
    }

    /// @notice Test that rate change to zero works correctly
    function test_RateChangeToZero() public {
        configurableIrm.setApr(0.1e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        // Start with 10% premium
        uint256 premiumRate = uint256(0.1e18) / uint256(365 days);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(premiumRate));

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1000e18, 0, BORROWER, BORROWER);

        skip(7 days);

        // Set rate to zero (remove premium)
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, 0);

        // Timestamp should still be updated
        (uint256 timestampAfterZero, uint256 rateAfterZero,) =
            IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertEq(timestampAfterZero, block.timestamp, "Timestamp should be updated even when rate set to zero");
        assertEq(rateAfterZero, 0, "Rate should be zero");

        // Get debt right after setting rate to 0
        uint256 debtAtRateChange = morpho.expectedBorrowAssets(marketParams, BORROWER);

        skip(7 days);

        // Get debt after 7 days - this will trigger internal accrual
        uint256 debtAfterWeek = morpho.expectedBorrowAssets(marketParams, BORROWER);

        // Calculate actual growth
        uint256 weeklyGrowth = debtAfterWeek - debtAtRateChange;

        // Calculate expected base rate growth
        uint256 expectedBaseGrowth = debtAtRateChange.wMulDown(uint256(0.1e18) * uint256(7 days) / uint256(365 days));

        // Allow small tolerance for rounding
        assertApproxEqRel(weeklyGrowth, expectedBaseGrowth, 0.01e18, "Should only have base rate growth");
    }

    /// @dev Puts BORROWER in debt at zero premium rate, then lets the account go stale
    /// for `staleWindow` without any accrual touch. Returns the stale lastAccrualTime.
    function _setupStaleZeroRateBorrower(uint256 staleWindow) internal returns (uint256 staleTime) {
        configurableIrm.setApr(0);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, 0);

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1000e18, 0, BORROWER, BORROWER);

        _continueMarketCycles(id, block.timestamp + staleWindow);

        (staleTime,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertLt(staleTime, block.timestamp - staleWindow + 1, "setup: lastAccrualTime must be stale");
    }

    /// @notice Zero -> nonzero rate change on a stale account must not charge the new rate
    /// over the window that predates it
    function test_StaleZeroToNonzeroRate_NoRetroactivePremium() public {
        _setupStaleZeroRateBorrower(120 days);

        uint256 debtBefore = morpho.expectedBorrowAssets(marketParams, BORROWER);

        uint256 newRate = uint256(0.1e18) / uint256(365 days);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(newRate));

        (uint256 timeAfterSet,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertEq(timeAfterSet, block.timestamp, "rate change must reset the accrual clock");

        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(BORROWER));
        uint256 debtAfter = morpho.expectedBorrowAssets(marketParams, BORROWER);
        assertEq(debtAfter, debtBefore, "no premium may accrue for the window before the rate existed");

        skip(5 days);
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(BORROWER));
        uint256 debtLater = morpho.expectedBorrowAssets(marketParams, BORROWER);
        uint256 expectedPremium = debtAfter.wMulDown(newRate.wTaylorCompounded(5 days));
        assertApproxEqRel(
            debtLater - debtAfter, expectedPremium, 1e12, "new rate should accrue only from the rate change onward"
        );
    }

    /// @notice A nonzero -> nonzero rate change on an account whose accrual clock is stale
    /// must charge the old rate only over the window it was actually live
    function test_StaleNonzeroToNonzeroRate_NoRetroactivePremium() public {
        _setupStaleZeroRateBorrower(120 days);

        uint256 rate1 = uint256(0.05e18) / uint256(365 days);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(rate1));

        uint256 debtAtRate1 = morpho.expectedBorrowAssets(marketParams, BORROWER);

        skip(1 days);

        uint256 rate2 = uint256(0.15e18) / uint256(365 days);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(rate2));

        (uint256 timeAfterSet,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        assertEq(timeAfterSet, block.timestamp, "rate change must reset the accrual clock");

        uint256 debtAtRate2 = morpho.expectedBorrowAssets(marketParams, BORROWER);
        uint256 expectedEarned = debtAtRate1.wMulDown(rate1.wTaylorCompounded(1 days));
        assertApproxEqRel(
            debtAtRate2 - debtAtRate1, expectedEarned, 1e12, "old rate must be charged only over the window it was live"
        );

        skip(5 days);
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(BORROWER));
        uint256 debtLater = morpho.expectedBorrowAssets(marketParams, BORROWER);
        uint256 expectedPremium = debtAtRate2.wMulDown(rate2.wTaylorCompounded(5 days));
        assertApproxEqRel(
            debtLater - debtAtRate2, expectedPremium, 1e12, "new rate should accrue only from the rate change onward"
        );
    }

    /// @notice Premium genuinely earned under the old rate must still be charged at the switch
    function test_RateChange_ChargesPremiumEarnedUnderOldRate() public {
        configurableIrm.setApr(0);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 10_000e18, 0, SUPPLIER, "");

        uint256 rate1 = uint256(0.1e18) / uint256(365 days);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(rate1));

        vm.prank(BORROWER);
        morpho.borrow(marketParams, 1000e18, 0, BORROWER, BORROWER);

        uint256 borrowTime = block.timestamp;
        _continueMarketCycles(id, block.timestamp + 30 days);
        uint256 elapsed = block.timestamp - borrowTime;

        uint256 rate2 = uint256(0.2e18) / uint256(365 days);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 10_000e18, uint128(rate2));

        uint256 debtAfterSwitch = morpho.expectedBorrowAssets(marketParams, BORROWER);
        uint256 expectedEarned = uint256(1000e18).wMulDown(rate1.wTaylorCompounded(elapsed));
        assertGt(expectedEarned, 0, "sanity: old-rate premium must be nonzero");
        assertApproxEqRel(
            debtAfterSwitch - 1000e18,
            expectedEarned,
            1e12,
            "premium earned under the old rate must not be forgiven at the switch"
        );
    }
}
