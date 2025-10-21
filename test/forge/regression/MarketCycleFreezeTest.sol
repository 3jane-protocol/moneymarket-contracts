// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {IProtocolConfig} from "../../../src/interfaces/IProtocolConfig.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";

/// @title Market Cycle Freeze Test
/// @notice Tests the automatic market freezing mechanism that prevents
///         borrow/repay operations between cycle end and obligation posting
/// @dev Markets automatically freeze when cycle duration expires to ensure
///      ending balances remain accurate point-in-time snapshots
contract MarketCycleFreezeTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    uint256 constant CREDIT_AMOUNT = 100_000e18;
    uint256 constant BORROW_AMOUNT = 50_000e18;
    uint256 constant SUPPLY_AMOUNT = 200_000e18;
    uint256 constant TEST_CYCLE_DURATION = 30 days;

    CreditLineMock creditLine;
    address protocolConfigAddr;
    MarketParams testMarketParams;
    Id testMarketId;
    address mockHelper;
    address mockUsd3;

    function setUp() public override {
        super.setUp();

        // Use existing morpho from BaseTest (it's MorphoCredit)
        // Set up helper and USD3
        mockHelper = makeAddr("MockHelper");
        mockUsd3 = makeAddr("MockUsd3");

        vm.startPrank(OWNER);
        IMorphoCredit(address(morpho)).setHelper(mockHelper);
        IMorphoCredit(address(morpho)).setUsd3(mockUsd3);
        vm.stopPrank();

        // Set cycle duration in protocol config
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), TEST_CYCLE_DURATION);

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Create market with credit line
        testMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV,
            creditLine: address(creditLine)
        });
        testMarketId = testMarketParams.id();

        // Set up the market (IRM and LLTV already enabled in BaseTest)
        vm.startPrank(OWNER);
        morpho.createMarket(testMarketParams);
        morpho.setFee(testMarketParams, 1e17); // 10% fee
        vm.stopPrank();

        // Supply liquidity through USD3
        loanToken.setBalance(mockUsd3, SUPPLY_AMOUNT);
        vm.startPrank(mockUsd3);
        loanToken.approve(address(morpho), SUPPLY_AMOUNT);
        morpho.supply(testMarketParams, SUPPLY_AMOUNT, 0, mockUsd3, "");
        vm.stopPrank();
    }

    /// @notice Test that market starts frozen before first cycle
    function testMarketStartsFrozen() public {
        // Set up borrower with credit line
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(testMarketId, BORROWER, CREDIT_AMOUNT, 0);

        // Try to borrow - should revert because market is frozen
        vm.prank(mockHelper);
        vm.expectRevert(ErrorsLib.MarketFrozen.selector);
        morpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);
    }

    /// @notice Test that posting first cycle unfreezes the market
    function testFirstCycleUnfreezesMarket() public {
        // Set up borrower with credit line
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(testMarketId, BORROWER, CREDIT_AMOUNT, 0);

        // Warp to end of first cycle period
        vm.warp(block.timestamp + TEST_CYCLE_DURATION);

        // Post first cycle to unfreeze (with current timestamp as cycle end)
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        uint256 firstCycleEnd = block.timestamp; // Use current time since cycle has ended
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Now borrowing should work
        loanToken.setBalance(BORROWER, BORROW_AMOUNT);
        vm.prank(mockHelper);
        (uint256 borrowedAssets,) = morpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);
        assertEq(borrowedAssets, BORROW_AMOUNT, "Should borrow successfully after first cycle");
    }

    /// @notice Test that market freezes automatically after cycle duration
    function testMarketFreezesAfterCycleDuration() public {
        // Warp to end of first cycle and post it
        vm.warp(block.timestamp + TEST_CYCLE_DURATION);

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Set up borrower with credit line
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(testMarketId, BORROWER, CREDIT_AMOUNT, 0);

        // Borrow during active cycle - should work
        vm.prank(mockHelper);
        (uint256 borrowedAssets,) = morpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);
        assertGt(borrowedAssets, 0, "Should borrow during active cycle");

        // Warp past the expected next cycle end
        vm.warp(firstCycleEnd + TEST_CYCLE_DURATION + 1);

        // Try to borrow again - should revert because market is frozen
        vm.prank(mockHelper);
        vm.expectRevert(ErrorsLib.MarketFrozen.selector);
        morpho.borrow(testMarketParams, BORROW_AMOUNT / 2, 0, BORROWER, BORROWER);

        // Try to repay - should also revert
        loanToken.setBalance(BORROWER, BORROW_AMOUNT);
        vm.startPrank(BORROWER);
        loanToken.approve(address(morpho), BORROW_AMOUNT);
        vm.expectRevert(ErrorsLib.MarketFrozen.selector);
        morpho.repay(testMarketParams, BORROW_AMOUNT / 2, 0, BORROWER, "");
        vm.stopPrank();
    }

    /// @notice Test that posting obligations unfreezes the market for next cycle
    function testPostingObligationsUnfreezesMarket() public {
        // Warp to end of first cycle and post it
        vm.warp(block.timestamp + TEST_CYCLE_DURATION);

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Set up and execute borrow
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(testMarketId, BORROWER, CREDIT_AMOUNT, 0);

        vm.prank(mockHelper);
        morpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        // Warp past next cycle end - market should freeze
        vm.warp(firstCycleEnd + TEST_CYCLE_DURATION + 1);

        // Verify market is frozen
        vm.prank(mockHelper);
        vm.expectRevert(ErrorsLib.MarketFrozen.selector);
        morpho.borrow(testMarketParams, BORROW_AMOUNT / 2, 0, BORROWER, BORROWER);

        // Now we're at the second cycle end, post obligations without repayment requirement
        // (to avoid OutstandingRepayment error when trying to borrow again)
        borrowers = new address[](0);
        repaymentBps = new uint256[](0);
        endingBalances = new uint256[](0);

        uint256 secondCycleEnd = block.timestamp; // Current time since we're past the cycle
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, secondCycleEnd, borrowers, repaymentBps, endingBalances);

        // Market should be unfrozen now - borrow should work
        vm.prank(mockHelper);
        (uint256 borrowedMore,) = morpho.borrow(testMarketParams, BORROW_AMOUNT / 2, 0, BORROWER, BORROWER);
        assertGt(borrowedMore, 0, "Should borrow after posting obligations");
    }

    /// @notice Test that markets remain frozen when cycle duration is 0
    function testMarketFrozenWhenCycleDurationZero() public {
        // Reset cycle duration to 0
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), 0);

        // Post first cycle
        vm.warp(block.timestamp + 30 days);

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Set up borrower
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(testMarketId, BORROWER, CREDIT_AMOUNT, 0);

        // Market should be frozen because cycle duration is 0
        vm.prank(mockHelper);
        vm.expectRevert(ErrorsLib.MarketFrozen.selector);
        morpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);

        // Even after more time passes, market remains frozen
        vm.warp(block.timestamp + 60 days);

        vm.prank(mockHelper);
        vm.expectRevert(ErrorsLib.MarketFrozen.selector);
        morpho.borrow(testMarketParams, BORROW_AMOUNT, 0, BORROWER, BORROWER);
    }

    /* CYCLE DURATION VALIDATION TESTS */

    /// @notice Test that cycles cannot be closed before the minimum duration
    function testCannotCloseCycleBeforeMinimumDuration() public {
        // Post first cycle
        vm.warp(block.timestamp + TEST_CYCLE_DURATION);

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Try to close second cycle before minimum duration (e.g., 20 days instead of 30)
        vm.warp(firstCycleEnd + 20 days);

        uint256 tooEarlyEndDate = block.timestamp;
        vm.prank(address(creditLine));
        vm.expectRevert(ErrorsLib.InvalidCycleDuration.selector);
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, tooEarlyEndDate, borrowers, repaymentBps, endingBalances);
    }

    /// @notice Test that cycles can be closed exactly at the expected duration
    function testCanCloseCycleExactlyAtExpectedDuration() public {
        // Post first cycle
        vm.warp(block.timestamp + TEST_CYCLE_DURATION);

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Close second cycle exactly at expected duration
        vm.warp(firstCycleEnd + TEST_CYCLE_DURATION);

        uint256 secondCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        // Should not revert
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, secondCycleEnd, borrowers, repaymentBps, endingBalances);

        // Verify cycle was created successfully
        assertEq(
            secondCycleEnd, firstCycleEnd + TEST_CYCLE_DURATION, "Second cycle should end exactly at expected duration"
        );
    }

    /// @notice Test that cycles can be closed after the expected duration (late closing)
    function testCanCloseCycleAfterExpectedDuration() public {
        // Post first cycle
        vm.warp(block.timestamp + TEST_CYCLE_DURATION);

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Close second cycle late (e.g., 40 days instead of 30)
        vm.warp(firstCycleEnd + 40 days);

        uint256 lateCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        // Should not revert - late closing is allowed
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, lateCycleEnd, borrowers, repaymentBps, endingBalances);

        // Verify cycle was created successfully
        assertGt(lateCycleEnd, firstCycleEnd + TEST_CYCLE_DURATION, "Second cycle should end after expected duration");
    }

    /// @notice Test that first cycle has no minimum duration requirement
    function testFirstCycleHasNoMinimumDuration() public {
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        // Test closing first cycle early (10 days)
        vm.warp(block.timestamp + 10 days);
        uint256 earlyFirstCycle = block.timestamp;
        vm.prank(address(creditLine));
        // Should not revert even though it's less than TEST_CYCLE_DURATION
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, earlyFirstCycle, borrowers, repaymentBps, endingBalances);

        // Create another market to test different first cycle duration
        MarketParams memory newMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV - 1,
            creditLine: address(creditLine)
        });
        Id newMarketId = newMarketParams.id();

        // Enable the new LLTV and create market
        vm.startPrank(OWNER);
        morpho.enableLltv(DEFAULT_TEST_LLTV - 1);
        morpho.createMarket(newMarketParams);
        vm.stopPrank();

        // Test closing first cycle late (50 days)
        vm.warp(block.timestamp + 50 days);
        uint256 lateFirstCycle = block.timestamp;
        vm.prank(address(creditLine));
        // Should not revert even though it's more than TEST_CYCLE_DURATION
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(newMarketId, lateFirstCycle, borrowers, repaymentBps, endingBalances);
    }

    /// @notice Test that when cycleDuration is 0, no minimum duration is enforced
    function testZeroCycleDurationAllowsAnyCycleLength() public {
        // Post first cycle with normal duration
        vm.warp(block.timestamp + TEST_CYCLE_DURATION);

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Set cycle duration to 0
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), 0);

        // Should be able to close cycle immediately (1 second later)
        vm.warp(firstCycleEnd + 1);
        uint256 immediateSecondCycle = block.timestamp;
        vm.prank(address(creditLine));
        // Should not revert
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, immediateSecondCycle, borrowers, repaymentBps, endingBalances);

        // Should also be able to close cycle after a long time
        vm.warp(immediateSecondCycle + 100 days);
        uint256 lateThirdCycle = block.timestamp;
        vm.prank(address(creditLine));
        // Should not revert
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, lateThirdCycle, borrowers, repaymentBps, endingBalances);
    }

    /// @notice Test multiple cycles in sequence respect duration requirements
    function testMultipleCyclesRespectDurationRequirement() public {
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        // First cycle - can be any duration
        vm.warp(block.timestamp + 15 days);
        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Second cycle - must respect minimum duration
        vm.warp(firstCycleEnd + TEST_CYCLE_DURATION);
        uint256 secondCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, secondCycleEnd, borrowers, repaymentBps, endingBalances);

        // Third cycle - test that it also respects minimum from second cycle
        // Try to close too early
        vm.warp(secondCycleEnd + 25 days); // Less than TEST_CYCLE_DURATION
        uint256 tooEarlyThirdCycle = block.timestamp;
        vm.prank(address(creditLine));
        vm.expectRevert(ErrorsLib.InvalidCycleDuration.selector);
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, tooEarlyThirdCycle, borrowers, repaymentBps, endingBalances);

        // Now close at correct duration
        vm.warp(secondCycleEnd + TEST_CYCLE_DURATION);
        uint256 thirdCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, thirdCycleEnd, borrowers, repaymentBps, endingBalances);
    }

    /// @notice Test changing cycle duration between cycles
    function testCycleDurationChangeBetweenCycles() public {
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        // First cycle with 30-day duration
        vm.warp(block.timestamp + TEST_CYCLE_DURATION);
        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Change cycle duration to 15 days
        uint256 newDuration = 15 days;
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), newDuration);

        // Second cycle should now respect 15-day minimum
        // Try to close at 10 days - should fail
        vm.warp(firstCycleEnd + 10 days);
        vm.prank(address(creditLine));
        vm.expectRevert(ErrorsLib.InvalidCycleDuration.selector);
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, block.timestamp, borrowers, repaymentBps, endingBalances);

        // Close at 15 days - should work
        vm.warp(firstCycleEnd + newDuration);
        uint256 secondCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, secondCycleEnd, borrowers, repaymentBps, endingBalances);

        // Change duration to 60 days
        uint256 longDuration = 60 days;
        vm.prank(OWNER);
        protocolConfig.setConfig(keccak256("CYCLE_DURATION"), longDuration);

        // Third cycle should respect 60-day minimum
        // Try to close at 45 days - should fail
        vm.warp(secondCycleEnd + 45 days);
        vm.prank(address(creditLine));
        vm.expectRevert(ErrorsLib.InvalidCycleDuration.selector);
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, block.timestamp, borrowers, repaymentBps, endingBalances);

        // Close at 60 days - should work
        vm.warp(secondCycleEnd + longDuration);
        uint256 thirdCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, thirdCycleEnd, borrowers, repaymentBps, endingBalances);
    }

    /// @notice Test edge case where endDate equals startDate + cycleDuration (boundary condition)
    function testCycleDurationBoundaryCondition() public {
        // Post first cycle
        uint256 start = block.timestamp;
        vm.warp(start + TEST_CYCLE_DURATION);

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        uint256 firstCycleEnd = block.timestamp;
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, firstCycleEnd, borrowers, repaymentBps, endingBalances);

        // Test exact boundary: endDate = startDate + cycleDuration
        uint256 exactEnd = firstCycleEnd + TEST_CYCLE_DURATION;
        vm.warp(exactEnd);

        vm.prank(address(creditLine));
        // Should work without reverting (endDate >= startDate + cycleDuration)
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, exactEnd, borrowers, repaymentBps, endingBalances);

        // Test one second before boundary: endDate = startDate + cycleDuration - 1
        uint256 oneSecondBefore = exactEnd + TEST_CYCLE_DURATION - 1;
        vm.warp(oneSecondBefore);

        vm.prank(address(creditLine));
        vm.expectRevert(ErrorsLib.InvalidCycleDuration.selector);
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(testMarketId, oneSecondBefore, borrowers, repaymentBps, endingBalances);
    }
}
