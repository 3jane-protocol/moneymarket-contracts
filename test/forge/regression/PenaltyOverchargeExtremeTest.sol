// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseTest} from "../BaseTest.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {
    Id,
    MarketParams,
    Position,
    Market,
    IMorphoCredit,
    RepaymentStatus,
    RepaymentObligation,
    BorrowerPremium
} from "../../../src/interfaces/IMorpho.sol";
import {MathLib, WAD} from "../../../src/libraries/MathLib.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title PenaltyOverchargeExtremeTest
 * @notice Extreme test case for Sherlock issue #237 with high utilization
 * @dev Uses 90% utilization to get 90% APR base rate and demonstrates the bug more clearly
 */
contract PenaltyOverchargeExtremeTest is BaseTest {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    CreditLineMock internal creditLine;

    function setUp() public override {
        super.setUp();

        // Deploy a mock credit line contract
        creditLine = new CreditLineMock(address(morpho));

        // Create credit line market
        marketParams = MarketParams(
            address(loanToken),
            address(0), // No collateral for credit line
            address(0), // No oracle needed
            address(irm),
            0, // No LLTV
            address(creditLine) // Credit line address
        );
        id = marketParams.id();

        vm.prank(OWNER);
        morpho.createMarket(marketParams);

        // Initialize market cycles
        _ensureMarketActive(id);

        // Supply only 100k to create high utilization when we borrow 90k
        loanToken.setBalance(SUPPLIER, 100_000e18);
        vm.startPrank(SUPPLIER);
        morpho.supply(marketParams, 100_000e18, 0, SUPPLIER, new bytes(0));
        vm.stopPrank();

        // Set credit line for borrower with 2% APR premium
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, 100_000e18, uint128(PREMIUM_RATE_PER_SECOND));

        // Borrow 90k to create 90% utilization = 90% APR base rate
        loanToken.setBalance(BORROWER, 90_000e18);
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 90_000e18, 0, BORROWER, BORROWER);
    }

    /**
     * @notice Extreme test showing penalty overcharge with high base rate
     * @dev With 90% APR base rate, the miscalculation becomes much more apparent
     */
    function test_extremePenaltyOvercharge() public {
        // Record initial state
        (uint128 initialLastAccrualTime,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        uint256 initialDebt = _getBorrowerDebt(id, BORROWER);
        console2.log("\n=== INITIAL STATE (90% utilization) ===");
        console2.log("Initial debt:", initialDebt);
        console2.log("Initial lastAccrualTime:", initialLastAccrualTime);

        // Fast forward 30 days without accruing premium
        // This keeps lastAccrualTime at day 0
        vm.warp(block.timestamp + 30 days);

        // Get debt at cycle end (should show significant base interest growth)
        uint256 debtAtCycleEnd = _getBorrowerDebt(id, BORROWER);
        console2.log("\n=== CYCLE END (day 30) ===");
        console2.log("Debt at cycle end:", debtAtCycleEnd);
        console2.log("Base interest earned:", debtAtCycleEnd - initialDebt);

        // Create obligation with ending balance = debt at cycle end
        _createRepaymentObligation(id, BORROWER, 45000e18, debtAtCycleEnd, 1);

        // Fast forward to 10 days after cycle end (3 days past grace period)
        vm.warp(block.timestamp + 10 days);

        // Get obligation details
        (,, uint128 endingBalance) = IMorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        console2.log("Obligation endingBalance stored:", endingBalance);

        // Calculate debt before penalty accrual
        uint256 debtBeforePenalty = _getBorrowerDebt(id, BORROWER);
        console2.log("\n=== BEFORE PENALTY (day 40) ===");
        console2.log("Debt before penalty:", debtBeforePenalty);
        console2.log("Additional base growth:", debtBeforePenalty - debtAtCycleEnd);

        // Check lastAccrualTime is still at day 0
        (uint128 lastAccrualBeforePenalty,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, BORROWER);
        console2.log("LastAccrualTime (still day 0):", lastAccrualBeforePenalty);

        // Now accrue premiums - this triggers the penalty
        console2.log("\n=== ACCRUING PENALTY ===");

        // Let's manually calculate what we expect
        // The penalty should be calculated with:
        // - principal: endingBalance (96,909e18)
        // - current: debtBeforePenalty (99,593e18)
        // - rate: 2% premium + 10% penalty = 12% APR total
        // - elapsed: 10 days

        // First the premium from cycle end (2% APR for 10 days)
        // This uses the _calculateBorrowerPremiumAmount logic
        uint256 baseGrowth = debtBeforePenalty - endingBalance; // 2,684e18
        console2.log("Base growth from cycle end:", baseGrowth);

        // The function backs out base rate then adds premium
        // With such high base growth, the backed-out rate is very high
        // This might cause precision issues

        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(BORROWER));

        uint256 debtAfterPenalty = _getBorrowerDebt(id, BORROWER);
        uint256 totalPenalty = debtAfterPenalty - debtBeforePenalty;

        console2.log("Debt after penalty:", debtAfterPenalty);
        console2.log("Total penalty applied:", totalPenalty);

        // Calculate expected penalty
        // With 90% base + 2% premium + 10% penalty = 102% APR for 10 days
        uint256 expectedGrowthFor10Days = endingBalance * 102 * 10 / 365 / 100;
        console2.log("\n=== ANALYSIS ===");
        console2.log("Expected growth (102% APR for 10 days):", expectedGrowthFor10Days);
        console2.log("Actual penalty:", totalPenalty);
        console2.log("Ratio (actual/expected):", totalPenalty * 100 / expectedGrowthFor10Days, "%");

        // The bug should cause significant deviation from expected
        // Due to mixing 40 days of premium with 10 days of elapsed time
        if (totalPenalty > expectedGrowthFor10Days * 110 / 100) {
            console2.log("ERROR: Penalty is >10% higher than expected!");
            console2.log("This indicates the time period mismatch bug exists");
        } else if (totalPenalty < expectedGrowthFor10Days * 90 / 100) {
            console2.log("ERROR: Penalty is >10% lower than expected!");
            console2.log("This may indicate a different calculation issue");
        } else {
            console2.log("Penalty is within 10% of expected");
        }
    }

    // Helper to get debt (triggers base accrual)
    function _getBorrowerDebt(Id _id, address borrower) internal returns (uint256) {
        morpho.accrueInterest(marketParams);
        Market memory m = morpho.market(_id);
        Position memory pos = morpho.position(_id, borrower);
        if (pos.borrowShares == 0) return 0;
        return uint256(pos.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }
}
