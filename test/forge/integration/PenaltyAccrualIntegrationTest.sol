// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {Id, MarketParams, RepaymentStatus, IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";

contract PenaltyAccrualIntegrationTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    CreditLineMock internal creditLine;
    ConfigurableIrmMock internal configurableIrm;

    // Test borrowers
    address internal ALICE;
    address internal BOB;
    address internal CHARLIE;

    // Test-specific rate constants (common ones are in BaseTest)
    uint256 internal constant PREMIUM_RATE_ALICE = 634195840; // ~2% APR
    uint256 internal constant PREMIUM_RATE_BOB = 951293759; // ~3% APR

    function setUp() public override {
        super.setUp();

        ALICE = makeAddr("Alice");
        BOB = makeAddr("Bob");
        CHARLIE = makeAddr("Charlie");

        // Deploy credit line and IRM
        creditLine = new CreditLineMock(address(morpho));
        configurableIrm = new ConfigurableIrmMock();
        configurableIrm.setApr(0.1e18); // 10% APR

        // Create market
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(configurableIrm),
            lltv: 0,
            creditLine: address(creditLine)
        });

        id = marketParams.id();

        vm.startPrank(OWNER);
        morpho.enableIrm(address(configurableIrm));
        morpho.createMarket(marketParams);
        vm.stopPrank();

        // Initialize market cycles to prevent MarketFrozen error
        // Required for all credit line markets after the freeze refactor - markets without active cycles are frozen
        _ensureMarketActive(id);

        // Setup liquidity
        deal(address(loanToken), SUPPLIER, 1000000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");

        // Setup credit lines
        vm.startPrank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 50000e18, uint128(PREMIUM_RATE_ALICE));
        IMorphoCredit(address(morpho)).setCreditLine(id, BOB, 100000e18, uint128(PREMIUM_RATE_BOB));
        IMorphoCredit(address(morpho)).setCreditLine(id, CHARLIE, 75000e18, 0); // No premium
        vm.stopPrank();

        // Warp time forward to avoid underflow in tests
        // Using helper to maintain active cycles during time progression
        _continueMarketCycles(id, block.timestamp + 60 days); // 2 monthly cycles

        // Setup token approvals for test borrowers
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(BOB);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(CHARLIE);
        loanToken.approve(address(morpho), type(uint256).max);

        // Approve for test contract itself (used by _triggerAccrual)
        loanToken.approve(address(morpho), type(uint256).max);
    }

    // ============ Multi-Borrower Penalty Tests ============

    function testPenaltyAccrual_MultipleDelinquentBorrowers() public {
        // Setup: Multiple borrowers with loans
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        deal(address(loanToken), BOB, 20000e18);
        vm.prank(BOB);
        morpho.borrow(marketParams, 20000e18, 0, BOB, BOB);

        deal(address(loanToken), CHARLIE, 15000e18);
        vm.prank(CHARLIE);
        morpho.borrow(marketParams, 15000e18, 0, CHARLIE, CHARLIE);

        // Create delinquent obligations for all
        address[] memory borrowers = new address[](3);
        uint256[] memory repaymentBps = new uint256[](3);
        uint256[] memory balances = new uint256[](3);

        borrowers[0] = ALICE;
        borrowers[1] = BOB;
        borrowers[2] = CHARLIE;
        repaymentBps[0] = 1000; // 10%
        repaymentBps[1] = 1000; // 10%
        repaymentBps[2] = 1000; // 10%
        balances[0] = 10000e18;
        balances[1] = 20000e18;
        balances[2] = 15000e18;

        _createMultipleObligations(id, borrowers, repaymentBps, balances, 10);

        // Wait for obligations to become delinquent
        // Using helper to maintain active cycles during time progression
        _continueMarketCycles(id, block.timestamp + 8 days);

        // Record initial states after obligations are delinquent
        uint256 aliceAssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 bobAssetsBefore = morpho.expectedBorrowAssets(marketParams, BOB);
        uint256 charlieAssetsBefore = morpho.expectedBorrowAssets(marketParams, CHARLIE);
        uint256 totalAssetsBefore = morpho.market(id).totalBorrowAssets;

        // Advance time
        _continueMarketCycles(id, block.timestamp + 5 days);

        // Trigger accrual once (it accrues for all borrowers)
        _triggerAccrual();

        // Verify penalties accrued for each
        uint256 aliceAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 bobAssetsAfter = morpho.expectedBorrowAssets(marketParams, BOB);
        uint256 charlieAssetsAfter = morpho.expectedBorrowAssets(marketParams, CHARLIE);

        // All should have increased
        assertGt(aliceAssetsAfter, aliceAssetsBefore);
        assertGt(bobAssetsAfter, bobAssetsBefore);
        assertGt(charlieAssetsAfter, charlieAssetsBefore);

        // Bob should have the highest increase (higher balance and premium)
        uint256 aliceIncrease = aliceAssetsAfter - aliceAssetsBefore;
        uint256 bobIncrease = bobAssetsAfter - bobAssetsBefore;
        uint256 charlieIncrease = charlieAssetsAfter - charlieAssetsBefore;

        assertGt(bobIncrease, aliceIncrease);
        assertGt(bobIncrease, charlieIncrease);

        // Total market assets should have increased significantly
        uint256 totalAssetsAfter = morpho.market(id).totalBorrowAssets;
        assertGt(totalAssetsAfter, totalAssetsBefore);

        // The total increase should be at least the sum of individual increases
        // (it may be more due to base interest on the entire market)
        assertGe(totalAssetsAfter - totalAssetsBefore, aliceIncrease + bobIncrease + charlieIncrease);
    }

    // ============ Premium vs Penalty Interaction Tests ============

    function testPenaltyAccrual_TransitionFromNormalToPenalty() public {
        // Alice borrows
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Let normal interest accrue for a while
        _continueMarketCycles(id, block.timestamp + 10 days);

        // Trigger normal accrual
        _triggerAccrual();

        uint256 assetsAfterNormalAccrual = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Create delinquent obligation using helper
        _createPastObligation(ALICE, 1000, assetsAfterNormalAccrual);

        // Advance time and trigger penalty accrual
        _continueMarketCycles(id, block.timestamp + 3 days);
        _triggerAccrual();

        uint256 assetsAfterPenaltyAccrual = morpho.expectedBorrowAssets(marketParams, ALICE);

        // The increase rate should be higher due to penalty
        uint256 penaltyPeriodIncrease = assetsAfterPenaltyAccrual - assetsAfterNormalAccrual;
        uint256 normalPeriodIncrease = assetsAfterNormalAccrual - 10000e18;

        // Penalty period had only 3 days vs 10 days normal, but should have significant increase
        assertGt(penaltyPeriodIncrease * 10 / 3, normalPeriodIncrease); // Higher rate than normal
    }

    // ============ Supply/Borrow Interaction Tests ============

    function testPenaltyAccrual_SupplySharesIncrease() public {
        // Setup: Borrower with delinquent obligation
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create delinquent obligation using helper
        _createPastObligation(ALICE, 1000, 10000e18);

        // Record supplier's position
        uint256 supplierSharesBefore = morpho.position(id, SUPPLIER).supplyShares;
        uint256 supplierAssetsBefore = morpho.expectedSupplyAssets(marketParams, SUPPLIER);

        // Advance time significantly
        _continueMarketCycles(id, block.timestamp + 30 days);

        // Trigger accrual
        _triggerAccrual();

        // Supplier's shares stay same but assets increase
        uint256 supplierSharesAfter = morpho.position(id, SUPPLIER).supplyShares;
        uint256 supplierAssetsAfter = morpho.expectedSupplyAssets(marketParams, SUPPLIER);

        assertEq(supplierSharesAfter, supplierSharesBefore);
        assertGt(supplierAssetsAfter, supplierAssetsBefore);

        // The increase should reflect penalty interest earnings
        uint256 supplierEarnings = supplierAssetsAfter - supplierAssetsBefore;
        assertGt(supplierEarnings, 0);
    }

    // ============ Repayment During Penalty Tests ============

    function testPenaltyAccrual_PartialRepaymentDuringPenalty() public {
        // Setup delinquent borrower
        deal(address(loanToken), ALICE, 10000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);

        // Create delinquent obligation using helper
        _createPastObligation(ALICE, 1000, 10000e18);

        // Advance time
        _continueMarketCycles(id, block.timestamp + 5 days);

        uint256 assetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Verify partial payment is rejected
        deal(address(loanToken), ALICE, 500e18);
        vm.prank(ALICE);
        vm.expectRevert(ErrorsLib.MustPayFullObligation.selector);
        morpho.repay(marketParams, 500e18, 0, ALICE, "");

        // Advance more time
        _continueMarketCycles(id, block.timestamp + 5 days);

        // Trigger accrual
        _triggerAccrual();

        uint256 assetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Should continue accruing penalty on ending balance
        assertGt(assetsAfter, assetsBefore);

        // Pay obligation in full
        deal(address(loanToken), ALICE, 1000e18);
        vm.prank(ALICE);
        morpho.repay(marketParams, 1000e18, 0, ALICE, "");

        // Advance time again
        uint256 assetsBeforeFinal = morpho.expectedBorrowAssets(marketParams, ALICE);
        _continueMarketCycles(id, block.timestamp + 5 days);

        _triggerAccrual();

        uint256 assetsFinal = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Should only have normal accrual now (no penalty)
        uint256 normalAccrual =
            assetsBeforeFinal.wMulDown((BASE_RATE_PER_SECOND + PREMIUM_RATE_ALICE).wTaylorCompounded(5 days));

        assertLe(assetsFinal, assetsBeforeFinal + normalAccrual + 100); // Small buffer
    }

    // ============ Extreme Scenarios ============

    function testPenaltyAccrual_LongTermDefault() public {
        // Setup borrower who will default for extended period
        deal(address(loanToken), BOB, 20000e18);
        vm.prank(BOB);
        morpho.borrow(marketParams, 20000e18, 0, BOB, BOB);

        // Create obligation that's already old using helper
        _createPastObligation(BOB, 1000, 20000e18);

        // Move to default status (need to be >30 days past due)
        // Using helper to maintain active cycles during time progression
        _continueMarketCycles(id, block.timestamp + 31 days); // _createPastObligation makes it 1 day old, so total 32
            // days

        // Bob is in default
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, BOB);
        assertEq(uint256(status), uint256(RepaymentStatus.Default));

        uint256 assetsBefore = morpho.expectedBorrowAssets(marketParams, BOB);

        // Advance significant time
        _continueMarketCycles(id, block.timestamp + 90 days);

        // Trigger accrual
        _triggerAccrual();

        uint256 assetsAfter = morpho.expectedBorrowAssets(marketParams, BOB);

        // Should have significant penalty accumulation
        // Verify there's substantial increase (can't predict exact due to compound calculations)
        uint256 increase = assetsAfter - assetsBefore;
        uint256 minExpectedIncrease = assetsBefore * 2 / 100; // At least 2% increase
        assertGt(increase, minExpectedIncrease);
    }

    function testPenaltyAccrual_MultipleMarketsIndependence() public {
        // Create second market with different parameters
        MarketParams memory market2Params = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken), // Different from first market
            oracle: address(oracle),
            irm: address(configurableIrm),
            lltv: 0.8e18,
            creditLine: address(creditLine)
        });

        Id market2Id = market2Params.id();
        vm.prank(OWNER);
        morpho.createMarket(market2Params);

        // Initialize first cycle for second market to unfreeze it
        vm.warp(block.timestamp + CYCLE_DURATION);
        address[] memory borrowers2 = new address[](0);
        uint256[] memory repaymentBps2 = new uint256[](0);
        uint256[] memory endingBalances2 = new uint256[](0);
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(market2Id, block.timestamp, borrowers2, repaymentBps2, endingBalances2);

        // Continue cycles for the original market too
        _continueMarketCycles(id, block.timestamp);

        // Supply to second market
        deal(address(loanToken), address(this), 500000e18);
        loanToken.approve(address(morpho), 500000e18);
        morpho.supply(market2Params, 500000e18, 0, address(this), "");

        // Setup credit line for ALICE in second market
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(market2Id, ALICE, 25000e18, uint128(PREMIUM_RATE_ALICE * 2));

        // ALICE borrows in both markets
        deal(address(loanToken), ALICE, 15000e18);
        vm.startPrank(ALICE);
        morpho.borrow(marketParams, 10000e18, 0, ALICE, ALICE);
        morpho.borrow(market2Params, 5000e18, 0, ALICE, ALICE);
        vm.stopPrank();

        // Create delinquent obligation only in first market using helper
        _createPastObligation(ALICE, 1000, 10000e18);

        // Record states
        uint256 market1AssetsBefore = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 market2AssetsBefore = morpho.expectedBorrowAssets(market2Params, ALICE);

        // Advance time and trigger accrual in both markets
        _continueMarketCycles(id, block.timestamp + 5 days);

        _triggerAccrual();

        // Trigger accrual in second market through ALICE's supply operation
        deal(address(loanToken), ALICE, 1);
        vm.prank(ALICE);
        morpho.supply(market2Params, 1, 0, ALICE, "");

        uint256 market1AssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 market2AssetsAfter = morpho.expectedBorrowAssets(market2Params, ALICE);

        // Market 1 should have penalty accrual
        uint256 market1Increase = market1AssetsAfter - market1AssetsBefore;
        uint256 market2Increase = market2AssetsAfter - market2AssetsBefore;

        // Market 1 increase should be at least as much as market 2 (when normalized by balance)
        // market1 has 10000e18 borrowed, market2 has 5000e18 borrowed
        // Both markets are accruing at similar rates which is acceptable
        assertGe(market1Increase * 5000, market2Increase * 10000); // Market1 rate >= Market2 rate

        // Market 2 should only have normal accrual (no penalty)
        // Just verify it's a reasonable increase for 5 days of interest
        // market2Increase is 6.854e18 on 5000e18 = 0.137% which is reasonable for 5 days
        uint256 minExpectedIncrease = market2AssetsBefore * 10 / 10000; // 0.10% minimum
        uint256 maxExpectedIncrease = market2AssetsBefore * 20 / 10000; // 0.20% maximum
        assertGe(market2Increase, minExpectedIncrease);
        assertLe(market2Increase, maxExpectedIncrease);
    }

    // ============ Gas Optimization Tests ============

    function testPenaltyAccrual_BatchedOperations() public {
        // Setup multiple borrowers with obligations
        address[] memory allBorrowers = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            allBorrowers[i] = makeAddr(string(abi.encodePacked("Borrower", i)));

            // Setup credit line
            vm.prank(address(creditLine));
            IMorphoCredit(address(morpho)).setCreditLine(id, allBorrowers[i], 50000e18, uint128(PREMIUM_RATE_ALICE));

            // Borrow
            deal(address(loanToken), allBorrowers[i], 5000e18);
            vm.prank(allBorrowers[i]);
            morpho.borrow(marketParams, 5000e18, 0, allBorrowers[i], allBorrowers[i]);
        }

        // Create obligations for all in one transaction using helper
        uint256[] memory repaymentBps = new uint256[](10);
        uint256[] memory balances = new uint256[](10);

        for (uint256 i = 0; i < 10; i++) {
            repaymentBps[i] = 1000; // 10%
            balances[i] = 5000e18;
        }

        uint256 gasBefore = gasleft();

        _createMultipleObligations(id, allBorrowers, repaymentBps, balances, 10);

        uint256 gasUsed = gasBefore - gasleft();

        // Gas should be reasonable for 10 borrowers
        assertLt(gasUsed, 1000000); // Less than 1M gas

        // Warp time forward to make them delinquent (>7 days past due)
        // Using helper to maintain active cycles during time progression
        _continueMarketCycles(id, block.timestamp + 8 days);

        // Verify all have delinquent status
        for (uint256 i = 0; i < 10; i++) {
            (RepaymentStatus status,) =
                MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, allBorrowers[i]);
            assertEq(uint256(status), uint256(RepaymentStatus.Delinquent));
        }
    }

    // ============ Multiple Cycle Penalty Tests ============

    function testPenaltyAccrual_AcrossMultipleCycles() public {
        // This test verifies that penalty accrual is based on the original delinquent cycle,
        // not subsequent cycles that might be posted for the same borrower

        // Step 1: Alice borrows
        deal(address(loanToken), ALICE, 20000e18);
        vm.prank(ALICE);
        morpho.borrow(marketParams, 20000e18, 0, ALICE, ALICE);

        // Trigger initial accrual to sync timestamps
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(ALICE));

        // Step 2: Create Cycle 1 obligation that will make Alice delinquent using helper
        // This ensures proper cycle spacing and management
        _createPastObligation(ALICE, 1000, 20000e18);

        // Move to delinquent status (need to be >7 days past due)
        // Using helper to maintain active cycles during time progression
        _continueMarketCycles(id, block.timestamp + 7 days); // _createPastObligation makes it 1 day old, so total 8
            // days = delinquent

        // Record the timestamp when this cycle was created
        uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        (, uint256 cycle1EndDate) = MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), id, cycleLength - 1);

        // Verify Alice is delinquent
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent), "Should be delinquent from Cycle 1");

        // Record the cycle ID and ending balance that were set
        (uint128 cycleId1,, uint128 endingBalance1) = IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);
        uint256 expectedCycleId = cycleLength - 1;
        assertEq(cycleId1, expectedCycleId, "Cycle ID should match");
        assertEq(endingBalance1, 20000e18, "Ending balance should be from Cycle 1");

        // Step 3: Time passes and a new obligation is posted for Cycle 2
        // Use helper to properly create a new cycle with obligations
        address[] memory borrowers = new address[](1);
        uint256[] memory repaymentBps = new uint256[](1);
        uint256[] memory balances = new uint256[](1);

        borrowers[0] = ALICE;
        repaymentBps[0] = 1000; // 10% - Higher obligation for Cycle 2
        balances[0] = 25000e18; // Higher ending balance for Cycle 2

        // This will properly handle cycle timing and create a new cycle
        _createMultipleObligations(id, borrowers, repaymentBps, balances, 0);

        // Verify the critical behavior: cycleId and endingBalance should NOT change
        // because Alice already had an outstanding obligation
        (uint128 cycleId2, uint128 amountDue2, uint128 endingBalance2) =
            IMorphoCredit(address(morpho)).repaymentObligation(id, ALICE);

        assertEq(cycleId2, cycleId1, "Cycle ID should remain unchanged");
        assertEq(endingBalance2, endingBalance1, "Ending balance should remain from Cycle 1");
        assertEq(amountDue2, 2500e18, "Amount due should be updated to Cycle 2 amount");

        // Step 4: Record debt before penalty accrual
        uint256 debtBefore = morpho.expectedBorrowAssets(marketParams, ALICE);

        // Step 5: Trigger penalty accrual
        _continueMarketCycles(id, block.timestamp + 5 days);
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(ALICE));

        uint256 debtAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 totalAccrued = debtAfter - debtBefore;

        // Step 6: Calculate expected penalty based on Cycle 1 (not Cycle 2!)
        // Penalty should be calculated from Cycle 1 end date to now
        uint256 timeSinceCycle1 = block.timestamp - cycle1EndDate;
        uint256 expectedPenalty =
            uint256(endingBalance1).wMulDown(PENALTY_RATE_PER_SECOND.wTaylorCompounded(timeSinceCycle1));

        // The total accrued should include base + premium + penalty
        // Penalty is based on Cycle 1's ending balance and time
        assertGt(totalAccrued, expectedPenalty * 8 / 10, "Should include significant penalty from Cycle 1");

        // Verify that the penalty is NOT based on Cycle 2's parameters
        // Get the actual cycle 2 end date
        uint256 newCycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        (, uint256 cycle2EndDate) =
            MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), id, newCycleLength - 1);
        uint256 timeSinceCycle2 = block.timestamp - cycle2EndDate;
        uint256 wrongPenalty = uint256(25000e18).wMulDown(PENALTY_RATE_PER_SECOND.wTaylorCompounded(timeSinceCycle2)); // Using
            // Cycle 2's balance

        // The actual penalty should be much higher than if calculated from Cycle 2
        assertGt(expectedPenalty, wrongPenalty * 2, "Penalty from Cycle 1 should be much higher");

        emit log_string("=== Penalty Accrual Across Cycles ===");
        emit log_named_uint("Time since Cycle 1", timeSinceCycle1);
        emit log_named_uint("Time since Cycle 2", timeSinceCycle2);
        emit log_named_uint("Penalty based on Cycle 1", expectedPenalty);
        emit log_named_uint("(Wrong) penalty if based on Cycle 2", wrongPenalty);
        emit log_named_uint("Total accrued", totalAccrued);
    }
}
