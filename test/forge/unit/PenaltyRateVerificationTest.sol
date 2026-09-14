// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {ConfigurableIrmMock} from "../mocks/ConfigurableIrmMock.sol";
import {Id, MarketParams, RepaymentStatus, IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {EventsLib} from "../../../src/libraries/EventsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {MathLib} from "../../../src/libraries/MathLib.sol";
import {MorphoCreditLib} from "../../../src/libraries/periphery/MorphoCreditLib.sol";

/// @title Penalty Rate Verification Test
/// @notice Precise tests to verify penalty interest accrues at exactly the expected rates
/// @dev Tests both initial penalty accrual (crossing into delinquency) and subsequent accruals
contract PenaltyRateVerificationTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant TEST_CYCLE_DURATION = 30 days;

    CreditLineMock internal creditLine;
    ConfigurableIrmMock internal configurableIrm;

    // Test borrower
    address internal ALICE;

    // Test constants for precise calculations
    uint256 internal constant ENDING_BALANCE = 10000e18;
    uint256 internal constant INITIAL_BORROW = 10000e18;
    uint256 internal constant OBLIGATION_BPS = 1000; // 10%

    function setUp() public override {
        super.setUp();

        // Set cycle duration in protocol config
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), TEST_CYCLE_DURATION);

        ALICE = makeAddr("Alice");

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Deploy configurable IRM for testing
        configurableIrm = new ConfigurableIrmMock();
        configurableIrm.setApr(0.1e18); // 10% APR base rate

        // Create market with credit line
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(configurableIrm),
            lltv: 0,
            creditLine: address(creditLine)
        });

        id = marketParams.id();

        // Enable IRM
        vm.startPrank(OWNER);
        morpho.enableIrm(address(configurableIrm));
        morpho.createMarket(marketParams);
        vm.stopPrank();

        // Initialize market cycles since it has a credit line
        _ensureMarketActive(id);

        // Setup test tokens and supply liquidity
        deal(address(loanToken), SUPPLIER, 1000000e18);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 1000000e18, 0, SUPPLIER, "");

        // Setup credit line for borrower with premium rate
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE, 50000e18, uint128(PREMIUM_RATE_PER_SECOND));

        // Use _continueMarketCycles to properly advance time while keeping market active
        _continueMarketCycles(id, block.timestamp + 90 days);

        // Setup token approvals
        vm.prank(ALICE);
        loanToken.approve(address(morpho), type(uint256).max);
    }

    /// @notice Test initial penalty accrual when crossing into delinquency
    /// @dev Tests the _calculatePenaltyIfNeeded path
    function testPenaltyRate_InitialAccrualAtDelinquency() public {
        // Timeline:
        // - Day 60 (from setUp): Initial timestamp
        // - Day 60: Alice borrows (timestamp initialized on first borrow)
        // - Day 67: Warp forward by grace period and create obligation
        // - Obligation cycleEndDate = Day 60 (when borrow happened)
        // - Day 67 + 1 second: Move into delinquency

        // Step 1: Alice borrows at day 60
        deal(address(loanToken), ALICE, INITIAL_BORROW);
        vm.prank(ALICE);
        morpho.borrow(marketParams, INITIAL_BORROW, 0, ALICE, ALICE);

        // Step 2: Create obligation using helper that handles cycle timing properly
        _createPastObligation(ALICE, OBLIGATION_BPS, ENDING_BALANCE);

        // Warp to be exactly at the end of grace period
        uint256 cycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        (, uint256 cycleEndDate) = MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), id, cycleLength - 1);
        vm.warp(cycleEndDate + GRACE_PERIOD_DURATION);

        // Verify we're still in grace period
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.GracePeriod), "Should be in grace period");

        // Step 3: Move time to exactly 1 second past grace period
        vm.warp(block.timestamp + 1);

        // Now we should be delinquent
        (status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent), "Should be delinquent");

        // Step 4: Accrue the market base rate, then calculate the two premium legs from their exact principals.
        morpho.accrueInterest(marketParams);
        uint256 borrowAssetsCurrent = morpho.expectedBorrowAssets(marketParams, ALICE);
        (uint128 lastAccrualTime,,) = IMorphoCredit(address(morpho)).borrowerPremium(id, ALICE);
        uint256 premiumDuration = block.timestamp - lastAccrualTime;
        uint256 expectedBasePremium =
            borrowAssetsCurrent.wMulDown(PREMIUM_RATE_PER_SECOND.wTaylorCompounded(premiumDuration));

        uint256 totalSupplyBefore = morpho.market(id).totalSupplyAssets;
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(ALICE));

        // Step 5: Initial IRP is retroactive to cycle end and cross-compounds the base premium.
        cycleLength = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        (, uint256 actualCycleEndDate) =
            MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), id, cycleLength - 1);
        uint256 penaltyDuration = block.timestamp - actualCycleEndDate;
        uint256 expectedPenaltyGrowth = PENALTY_RATE_PER_SECOND.wTaylorCompounded(penaltyDuration);
        uint256 currentDebtWithPremium = borrowAssetsCurrent + expectedBasePremium;
        uint256 penaltyPrincipal = currentDebtWithPremium > ENDING_BALANCE ? currentDebtWithPremium : ENDING_BALANCE;
        uint256 expectedPenaltyAmount = penaltyPrincipal.wMulDown(expectedPenaltyGrowth);
        uint256 expectedTotalPremium = expectedBasePremium + expectedPenaltyAmount;

        // Step 6: Verify both borrower debt and lender assets receive exactly those two legs.
        uint256 borrowAssetsAfter = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 actualTotalIncrease = borrowAssetsAfter - borrowAssetsCurrent;
        assertApproxEqAbsWithLogs(
            actualTotalIncrease, expectedTotalPremium, 2, "initial premium and IRP must match their exact principals"
        );

        uint256 totalSupplyAfter = morpho.market(id).totalSupplyAssets;
        uint256 supplyIncrease = totalSupplyAfter - totalSupplyBefore;
        assertEq(supplyIncrease, expectedTotalPremium, "lenders must receive the exact premium and IRP amount");
    }

    /// @notice Test subsequent penalty accruals after already in delinquency
    /// @dev Tests the _calculateAndApplyPremium path with penalty rate included
    function testPenaltyRate_SubsequentAccruals() public {
        // Step 1: Setup - Alice borrows and becomes delinquent
        deal(address(loanToken), ALICE, INITIAL_BORROW);
        vm.prank(ALICE);
        morpho.borrow(marketParams, INITIAL_BORROW, 0, ALICE, ALICE);

        // Create obligation using helper and then warp to delinquency
        _createPastObligation(ALICE, OBLIGATION_BPS, ENDING_BALANCE);

        // Warp to be 3 days past grace period (well into delinquency)
        uint256 cycleLen = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        (, uint256 cycleEnd) = MorphoCreditLib.getCycleDates(IMorphoCredit(address(morpho)), id, cycleLen - 1);
        vm.warp(cycleEnd + GRACE_PERIOD_DURATION + 3 days);

        // Verify we're delinquent
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(IMorphoCredit(address(morpho)), id, ALICE);
        assertEq(uint256(status), uint256(RepaymentStatus.Delinquent), "Should be delinquent");

        // Step 2: First accrual to capture initial penalty
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(ALICE));

        // Step 3: Wait exactly 1 day, accrue base interest, then isolate the ongoing premium + IRP leg.
        uint256 timeStep = 1 days;
        vm.warp(block.timestamp + timeStep);
        morpho.accrueInterest(marketParams);
        uint256 borrowAssetsBeforeSecondPremium = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 expectedIncrementalIncrease = borrowAssetsBeforeSecondPremium.wMulDown(
            (PREMIUM_RATE_PER_SECOND + PENALTY_RATE_PER_SECOND).wTaylorCompounded(timeStep)
        );

        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(ALICE));

        uint256 borrowAssetsAfterSecond = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 incrementalIncrease = borrowAssetsAfterSecond - borrowAssetsBeforeSecondPremium;
        assertApproxEqAbsWithLogs(
            incrementalIncrease,
            expectedIncrementalIncrease,
            2,
            "ongoing premium and IRP must apply directly to current debt"
        );

        // Step 4: The same direct-current-debt formula holds over a two-day checkpoint.
        vm.warp(block.timestamp + 2 days);
        morpho.accrueInterest(marketParams);
        uint256 borrowAssetsBeforeThirdPremium = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 expectedSecondIncrement = borrowAssetsBeforeThirdPremium.wMulDown(
            (PREMIUM_RATE_PER_SECOND + PENALTY_RATE_PER_SECOND).wTaylorCompounded(2 days)
        );
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(ALICE));
        uint256 borrowAssetsAfterThird = morpho.expectedBorrowAssets(marketParams, ALICE);
        uint256 secondIncrement = borrowAssetsAfterThird - borrowAssetsBeforeThirdPremium;
        assertApproxEqAbsWithLogs(
            secondIncrement, expectedSecondIncrement, 2, "two-day premium and IRP must match the compounded factor"
        );
    }

    /// @notice Test that penalty accrual is path-independent
    /// @dev Verifies that multiple small accruals equal one large accrual
    function testPenaltyRate_PathIndependence() public {
        // We'll test two paths:
        // Path A: Single accrual after 10 days
        // Path B: Daily accruals for 10 days

        // Setup two identical positions
        address ALICE_PATH_A = makeAddr("AlicePathA");
        address ALICE_PATH_B = makeAddr("AlicePathB");

        // Setup credit lines
        vm.startPrank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE_PATH_A, 50000e18, uint128(PREMIUM_RATE_PER_SECOND));
        IMorphoCredit(address(morpho)).setCreditLine(id, ALICE_PATH_B, 50000e18, uint128(PREMIUM_RATE_PER_SECOND));
        vm.stopPrank();

        // Setup token approvals
        vm.prank(ALICE_PATH_A);
        loanToken.approve(address(morpho), type(uint256).max);
        vm.prank(ALICE_PATH_B);
        loanToken.approve(address(morpho), type(uint256).max);

        // Both borrow the same amount at the same time
        deal(address(loanToken), ALICE_PATH_A, INITIAL_BORROW);
        vm.prank(ALICE_PATH_A);
        morpho.borrow(marketParams, INITIAL_BORROW, 0, ALICE_PATH_A, ALICE_PATH_A);

        deal(address(loanToken), ALICE_PATH_B, INITIAL_BORROW);
        vm.prank(ALICE_PATH_B);
        morpho.borrow(marketParams, INITIAL_BORROW, 0, ALICE_PATH_B, ALICE_PATH_B);

        // Create identical delinquent obligations using helper
        address[] memory borrowers = new address[](2);
        uint256[] memory repaymentBps = new uint256[](2);
        uint256[] memory balances = new uint256[](2);

        borrowers[0] = ALICE_PATH_A;
        borrowers[1] = ALICE_PATH_B;
        repaymentBps[0] = OBLIGATION_BPS;
        repaymentBps[1] = OBLIGATION_BPS;
        balances[0] = ENDING_BALANCE;
        balances[1] = ENDING_BALANCE;

        _createMultipleObligations(id, borrowers, repaymentBps, balances, 0);

        // Warp to be past grace period (delinquent)
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + 1 days);

        // Initial accrual for both to capture the initial penalty
        address[] memory aliceAddrs = new address[](2);
        aliceAddrs[0] = ALICE_PATH_A;
        aliceAddrs[1] = ALICE_PATH_B;
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, aliceAddrs);

        uint256 startTime = block.timestamp;

        // Path B: Daily accruals for 10 days
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(startTime + (i + 1) * 1 days);
            IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(ALICE_PATH_B));
        }

        // Path A: Single accrual after 10 days
        vm.warp(startTime + 10 days);
        IMorphoCredit(address(morpho)).accruePremiumsForBorrowers(id, _toArray(ALICE_PATH_A));

        // Compare final states
        uint256 borrowAssetsA = morpho.expectedBorrowAssets(marketParams, ALICE_PATH_A);
        uint256 borrowAssetsB = morpho.expectedBorrowAssets(marketParams, ALICE_PATH_B);

        // Taylor partitioning and share rounding are the only permitted path difference.
        uint256 strictTolerance = borrowAssetsA / 1e10;
        assertApproxEqAbsWithLogs(
            borrowAssetsA,
            borrowAssetsB,
            strictTolerance,
            "Path independence: single vs multiple accruals should yield same result"
        );

        emit log_named_uint("Path A (single accrual) final assets", borrowAssetsA);
        emit log_named_uint("Path B (daily accruals) final assets", borrowAssetsB);
        emit log_named_uint(
            "Difference", borrowAssetsA > borrowAssetsB ? borrowAssetsA - borrowAssetsB : borrowAssetsB - borrowAssetsA
        );
        emit log_named_uint("Tolerance", strictTolerance);
    }

    /// @notice Helper to assert approximate equality with detailed logging
    function assertApproxEqAbsWithLogs(uint256 actual, uint256 expected, uint256 tolerance, string memory err)
        internal
    {
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        if (diff > tolerance) {
            emit log_named_string("Error", err);
            emit log_named_uint("Expected", expected);
            emit log_named_uint("Actual", actual);
            emit log_named_uint("Difference", diff);
            emit log_named_uint("Max tolerance", tolerance);
            revert(err);
        }
    }
}
