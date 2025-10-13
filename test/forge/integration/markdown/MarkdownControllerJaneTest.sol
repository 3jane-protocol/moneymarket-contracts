// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../BaseTest.sol";
import {Jane} from "../../../../src/jane/Jane.sol";
import {MarkdownController} from "../../../../src/MarkdownController.sol";
import {IMarkdownController} from "../../../../src/interfaces/IMarkdownController.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "../../../../src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {Market, Position, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";
import {IProtocolConfig} from "../../../../src/interfaces/IProtocolConfig.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";

/// @title MarkdownControllerJaneTest
/// @notice Tests for MarkdownController's JANE token freeze and burn functionality
contract MarkdownControllerJaneTest is BaseTest {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using MorphoCreditLib for IMorphoCredit;

    Jane public jane;
    MarkdownController public markdownController;
    CreditLineMock public creditLine;
    IMorphoCredit public morphoCredit;

    address public janeMinter;
    address public janeBurner;
    address public janeOwner;

    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    uint256 constant INITIAL_JANE_SUPPLY = 1_000_000e18;
    uint256 constant BORROWER_JANE_BALANCE = 10_000e18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event MarkdownEnabledUpdated(address indexed borrower, bool enabled);
    event BorrowerMarkdownUpdated(Id indexed id, address indexed borrower, uint256 oldMarkdown, uint256 newMarkdown);
    event AccountSettled(
        Id indexed id,
        address indexed settler,
        address indexed borrower,
        uint256 writtenOffAmount,
        uint256 writtenOffShares
    );

    function setUp() public override {
        super.setUp();

        morphoCredit = IMorphoCredit(morphoAddress);

        // Deploy JANE token
        janeOwner = makeAddr("janeOwner");
        janeMinter = makeAddr("janeMinter");
        janeBurner = makeAddr("janeBurner");
        jane = new Jane(janeOwner, janeMinter, janeBurner);

        // Deploy credit line
        creditLine = new CreditLineMock(morphoAddress);

        // Create market with credit line
        marketParams = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(creditLine)
        );
        id = marketParams.id();

        vm.startPrank(OWNER);
        morpho.createMarket(marketParams);
        vm.stopPrank();

        // Deploy MarkdownController with JANE integration
        markdownController = new MarkdownController(address(protocolConfig), OWNER, address(jane), morphoAddress, id);

        // Set markdown controller in credit line
        vm.prank(OWNER);
        creditLine.setMm(address(markdownController));

        // Set markdown controller in JANE token
        vm.prank(janeOwner);
        jane.setMarkdownController(address(markdownController));

        // Authorize MarkdownController to burn JANE
        vm.prank(janeOwner);
        jane.grantRole(BURNER_ROLE, address(markdownController));

        // Initialize market cycles
        _continueMarketCyclesJane(id, block.timestamp + CYCLE_DURATION + 7 days);

        // Setup initial supply
        loanToken.setBalance(SUPPLIER, 500_000e18);
        vm.prank(SUPPLIER);
        morpho.supply(marketParams, 500_000e18, 0, SUPPLIER, hex"");

        // Mint JANE to borrower
        vm.prank(janeMinter);
        jane.mint(BORROWER, BORROWER_JANE_BALANCE);

        // Enable transfers for testing
        vm.prank(janeOwner);
        jane.setTransferable();

        // Set full markdown duration to 100 days
        vm.prank(OWNER);
        protocolConfig.setConfig(ProtocolConfigLib.FULL_MARKDOWN_DURATION, 100 days);
    }

    // ============ JANE Freeze Tests ============

    /// @notice Test that JANE transfers are frozen when borrower is delinquent with markdown enabled
    function testJaneFrozenWhenDelinquentWithMarkdown() public {
        // Enable markdown for borrower
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);

        // Setup borrower with loan
        _setupBorrowerWithLoanJane(BORROWER, 50_000e18);
        _createPastObligationJane(BORROWER, 500, 50_000e18);

        // Move to delinquent period
        (uint128 cycleId,,) = MorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        uint256 cycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleId);
        uint256 delinquentStart = cycleEnd + GRACE_PERIOD_DURATION;
        vm.warp(delinquentStart + 1);

        // Verify borrower is delinquent
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Delinquent), "Should be delinquent");

        // Check freeze status
        assertTrue(markdownController.isFrozen(BORROWER), "Borrower should be frozen");

        // Try to transfer JANE - should fail
        vm.prank(BORROWER);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        jane.transfer(SUPPLIER, 100e18);
    }

    /// @notice Test that JANE transfers are not frozen when delinquent but markdown disabled
    function testJaneNotFrozenWhenDelinquentWithoutMarkdown() public {
        // Markdown NOT enabled for borrower

        // Setup borrower with loan
        _setupBorrowerWithLoanJane(BORROWER, 50_000e18);
        _createPastObligationJane(BORROWER, 500, 50_000e18);

        // Move to delinquent period
        (uint128 cycleId,,) = MorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        uint256 cycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleId);
        uint256 delinquentStart = cycleEnd + GRACE_PERIOD_DURATION;
        vm.warp(delinquentStart + 1);

        // Verify borrower is delinquent
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Delinquent), "Should be delinquent");

        // Check freeze status
        assertFalse(markdownController.isFrozen(BORROWER), "Borrower should not be frozen");

        // Transfer should succeed
        uint256 balanceBefore = jane.balanceOf(BORROWER);
        vm.prank(BORROWER);
        assertTrue(jane.transfer(SUPPLIER, 100e18));
        assertEq(jane.balanceOf(BORROWER), balanceBefore - 100e18);
        assertEq(jane.balanceOf(SUPPLIER), 100e18);
    }

    /// @notice Test that JANE transfers are not frozen when markdown enabled but borrower is current
    function testJaneNotFrozenWhenCurrentWithMarkdown() public {
        // Enable markdown for borrower
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);

        // Setup borrower with loan but keep them current
        _setupBorrowerWithLoanJane(BORROWER, 50_000e18);

        // Verify borrower is current
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(morphoCredit, id, BORROWER);
        assertEq(uint8(status), uint8(RepaymentStatus.Current), "Should be current");

        // Check freeze status
        assertFalse(markdownController.isFrozen(BORROWER), "Borrower should not be frozen");

        // Transfer should succeed
        uint256 balanceBefore = jane.balanceOf(BORROWER);
        vm.prank(BORROWER);
        assertTrue(jane.transfer(SUPPLIER, 100e18));
        assertEq(jane.balanceOf(BORROWER), balanceBefore - 100e18);
    }

    /// @notice Test freeze status updates when borrower transitions between states
    function testFreezeStatusTransitions() public {
        // Enable markdown for borrower
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);

        // Setup borrower with loan
        _setupBorrowerWithLoanJane(BORROWER, 50_000e18);
        _createPastObligationJane(BORROWER, 500, 50_000e18);

        // Initially current
        assertFalse(markdownController.isFrozen(BORROWER), "Should not be frozen when current");

        // Move to delinquent
        (uint128 cycleId,,) = MorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        uint256 cycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleId);
        uint256 delinquentStart = cycleEnd + GRACE_PERIOD_DURATION;
        vm.warp(delinquentStart + 1);
        assertTrue(markdownController.isFrozen(BORROWER), "Should be frozen when delinquent");

        // Repay obligation to become current again
        _repayObligation(BORROWER);
        assertFalse(markdownController.isFrozen(BORROWER), "Should not be frozen after repayment");
    }

    // ============ Progressive JANE Burning Tests ============

    /// @notice Test proportional burning based on time in default
    function testProgressiveJaneBurning() public {
        // Enable markdown for borrower
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);

        // Setup borrower in default
        _setupBorrowerWithLoanJane(BORROWER, 50_000e18);
        _createPastObligationJane(BORROWER, 500, 50_000e18);

        (uint128 cycleId,,) = MorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        uint256 cycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleId);
        uint256 defaultStart = cycleEnd + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;

        // Move to 10 days in default (10% markdown with 100 day duration)
        vm.warp(defaultStart + 10 days);

        uint256 initialBalance = jane.balanceOf(BORROWER);

        // Trigger markdown update which should burn JANE proportionally
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Expected burn: 10% of balance
        uint256 expectedBurn = initialBalance * 10 / 100;
        assertEq(jane.balanceOf(BORROWER), initialBalance - expectedBurn, "Should burn 10% of JANE");
        assertEq(markdownController.janeBurned(BORROWER), expectedBurn, "Should track burned amount");

        // Move to 25 days total in default (25% total markdown)
        vm.warp(defaultStart + 25 days);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Should burn additional 15% (25% total - 10% already burned)
        uint256 expectedTotalBurn = initialBalance * 25 / 100;
        assertEq(jane.balanceOf(BORROWER), initialBalance - expectedTotalBurn, "Should have 25% total burn");
        assertEq(markdownController.janeBurned(BORROWER), expectedTotalBurn, "Should track total burned");
    }

    /// @notice Test that burn amount cannot exceed balance
    function testBurnCannotExceedBalance() public {
        // Enable markdown for borrower
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);

        // Setup borrower in default
        _setupBorrowerWithLoanJane(BORROWER, 50_000e18);
        _createPastObligationJane(BORROWER, 500, 50_000e18);

        (uint128 cycleId,,) = MorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        uint256 cycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleId);
        uint256 defaultStart = cycleEnd + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;

        // Move to 50% markdown
        vm.warp(defaultStart + 50 days);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        uint256 balanceAfter50Percent = jane.balanceOf(BORROWER);
        assertEq(balanceAfter50Percent, BORROWER_JANE_BALANCE / 2, "Should have 50% remaining");

        // Temporarily disable markdown to allow transfer (testing burn logic, not freeze)
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, false);

        // Transfer most of remaining balance away
        vm.prank(BORROWER);
        jane.transfer(SUPPLIER, balanceAfter50Percent - 100e18);
        assertEq(jane.balanceOf(BORROWER), 100e18, "Should have minimal balance");

        // Re-enable markdown for the rest of the test
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);

        // Move to 100% markdown
        vm.warp(defaultStart + 100 days);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        // Should burn only remaining balance
        assertEq(jane.balanceOf(BORROWER), 0, "Should burn all remaining");
        assertEq(
            markdownController.janeBurned(BORROWER), BORROWER_JANE_BALANCE / 2 + 100e18, "Should track actual burned"
        );
    }

    /// @notice Test no burning when borrower has zero JANE balance
    function testNoBurnWithZeroBalance() public {
        // Create a new borrower with no JANE
        address borrower2 = address(0xBEEF2);

        // Enable markdown for borrower2
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(borrower2, true);

        // Setup borrower2 with loan
        loanToken.setBalance(borrower2, 100_000e18);
        vm.prank(borrower2);
        loanToken.approve(morphoAddress, type(uint256).max);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, borrower2, 50_000e18, 0);

        vm.prank(borrower2);
        morpho.borrow(marketParams, 50_000e18, 0, borrower2, borrower2);

        // Create past obligation for borrower2
        // Get the current number of cycles to find the last cycle
        uint256 cycleCount = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        require(cycleCount > 0, "No cycles exist");

        // Get the last cycle's end date
        uint256 lastCycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleCount - 1);

        // Create a new cycle that's at least CYCLE_DURATION after the last one
        // Add some buffer time to ensure we're well past the minimum duration
        uint256 newCycleEnd = lastCycleEnd + CYCLE_DURATION + 1 days;

        address[] memory obligationBorrowers = new address[](1);
        obligationBorrowers[0] = borrower2;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = 500;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = 50_000e18;

        // Warp to the new cycle end
        vm.warp(newCycleEnd);
        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, newCycleEnd, obligationBorrowers, repaymentBps, endingBalances
        );

        // Move to default
        vm.warp(block.timestamp + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION + 10 days);

        // Trigger markdown - should not revert despite zero balance
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, borrower2);

        assertEq(jane.balanceOf(borrower2), 0, "Should still be zero");
        assertEq(markdownController.janeBurned(borrower2), 0, "No burn tracked");
    }

    // ============ Full JANE Burn on Settlement Tests ============

    /// @notice Test complete JANE burn on settlement
    function testFullJaneBurnOnSettlement() public {
        // Enable markdown for borrower
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);

        // Setup borrower in default
        _setupBorrowerWithLoanJane(BORROWER, 50_000e18);
        _createPastObligationJane(BORROWER, 500, 50_000e18);

        (uint128 cycleId,,) = MorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        uint256 cycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleId);
        uint256 defaultStart = cycleEnd + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;

        // Move to default with some markdown
        vm.warp(defaultStart + 20 days);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);

        uint256 balanceBeforeSettlement = jane.balanceOf(BORROWER);
        assertTrue(balanceBeforeSettlement > 0, "Should have JANE balance before settlement");
        assertTrue(markdownController.janeBurned(BORROWER) > 0, "Should have partial burn tracked");

        // Settle account
        vm.prank(address(creditLine));
        vm.expectEmit(true, true, true, false);
        emit AccountSettled(id, address(creditLine), BORROWER, 0, 0);
        MorphoCredit(address(morpho)).settleAccount(marketParams, BORROWER);

        // Verify all JANE burned
        assertEq(jane.balanceOf(BORROWER), 0, "All JANE should be burned");
        assertEq(markdownController.janeBurned(BORROWER), 0, "Burn tracking should reset");
    }

    /// @notice Test settlement when borrower has no JANE
    function testSettlementWithNoJane() public {
        // Create borrower with no JANE
        address borrower2 = address(0xBEEF2);

        // Setup borrower2 with loan
        loanToken.setBalance(borrower2, 100_000e18);
        vm.prank(borrower2);
        loanToken.approve(morphoAddress, type(uint256).max);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, borrower2, 50_000e18, 0);

        vm.prank(borrower2);
        morpho.borrow(marketParams, 50_000e18, 0, borrower2, borrower2);

        // Settle account - should not revert
        vm.prank(address(creditLine));
        MorphoCredit(address(morpho)).settleAccount(marketParams, borrower2);

        assertEq(jane.balanceOf(borrower2), 0, "Should remain zero");
    }

    // ============ Access Control Tests ============

    /// @notice Test only MorphoCredit can call burn functions
    function testOnlyMorphoCreditCanBurn() public {
        // Try to call burnJaneProportional as non-MorphoCredit
        vm.prank(BORROWER);
        vm.expectRevert("Only MorphoCredit");
        markdownController.burnJaneProportional(BORROWER, 10 days);

        // Try to call burnJaneFull as non-MorphoCredit
        vm.prank(BORROWER);
        vm.expectRevert("Only MorphoCredit");
        markdownController.burnJaneFull(BORROWER);
    }

    /// @notice Test only owner can set markdown enabled
    function testOnlyOwnerCanSetMarkdownEnabled() public {
        // Non-owner tries to set markdown enabled
        vm.prank(BORROWER);
        vm.expectRevert();
        markdownController.setEnableMarkdown(BORROWER, true);

        // Owner can set
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);
        assertTrue(markdownController.markdownEnabled(BORROWER));
    }

    /// @notice Test only JANE owner can set markdown controller
    function testOnlyJaneOwnerCanSetController() public {
        address newController = address(0xC0FFEE);

        // Non-owner tries to set
        vm.prank(BORROWER);
        vm.expectRevert();
        jane.setMarkdownController(newController);

        // Owner can set
        vm.prank(janeOwner);
        jane.setMarkdownController(newController);
        assertEq(jane.markdownController(), newController);
    }

    // ============ Integration Flow Tests ============

    /// @notice Test full flow: Borrow → Default → Freeze → Progressive Burn → Settlement
    function testFullIntegrationFlow() public {
        // Enable markdown for borrower
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);

        // 1. Borrow
        _setupBorrowerWithLoanJane(BORROWER, 50_000e18);
        assertFalse(markdownController.isFrozen(BORROWER), "Not frozen when current");

        // 2. Create obligation
        _createPastObligationJane(BORROWER, 500, 50_000e18);

        // 3. Move to delinquent - should freeze
        (uint128 cycleId,,) = MorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        uint256 cycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleId);
        uint256 delinquentStart = cycleEnd + GRACE_PERIOD_DURATION;
        vm.warp(delinquentStart + 1);

        assertTrue(markdownController.isFrozen(BORROWER), "Should be frozen when delinquent");
        vm.prank(BORROWER);
        vm.expectRevert(Jane.TransferNotAllowed.selector);
        jane.transfer(SUPPLIER, 100e18);

        // 4. Move to default - progressive burn starts
        uint256 defaultStart = cycleEnd + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;
        vm.warp(defaultStart + 10 days);

        uint256 initialBalance = jane.balanceOf(BORROWER);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);
        assertTrue(jane.balanceOf(BORROWER) < initialBalance, "JANE should be burned");

        // 5. Continue default - more burning
        vm.warp(defaultStart + 30 days);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);
        assertTrue(jane.balanceOf(BORROWER) <= initialBalance * 70 / 100, "More JANE burned");

        // 6. Settlement - full burn
        uint256 preSettlementBalance = jane.balanceOf(BORROWER);
        vm.prank(address(creditLine));
        MorphoCredit(address(morpho)).settleAccount(marketParams, BORROWER);

        assertEq(jane.balanceOf(BORROWER), 0, "All JANE burned on settlement");
        assertEq(markdownController.janeBurned(BORROWER), 0, "Burn counter reset");
    }

    /// @notice Test markdown updates through hooks
    function testMarkdownThroughHooks() public {
        // Enable markdown
        vm.prank(OWNER);
        markdownController.setEnableMarkdown(BORROWER, true);

        // Setup default state
        _setupBorrowerWithLoanJane(BORROWER, 50_000e18);
        _createPastObligationJane(BORROWER, 500, 50_000e18);

        (uint128 cycleId,,) = MorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        uint256 cycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleId);
        uint256 defaultStart = cycleEnd + GRACE_PERIOD_DURATION + DELINQUENCY_PERIOD_DURATION;
        vm.warp(defaultStart + 15 days);

        // Accrue premium to trigger markdown
        uint256 balanceBefore = jane.balanceOf(BORROWER);
        MorphoCredit(address(morpho)).accrueBorrowerPremium(id, BORROWER);
        assertTrue(jane.balanceOf(BORROWER) < balanceBefore, "JANE should be burned during accrual");

        // Close another cycle to unfreeze the market for new operations
        _continueMarketCyclesJane(id, block.timestamp + CYCLE_DURATION);

        // Repay outstanding obligation first to allow new operations
        (, uint128 amountDue,) = MorphoCredit(address(morpho)).repaymentObligation(id, BORROWER);
        if (amountDue > 0) {
            loanToken.setBalance(BORROWER, amountDue);
            vm.prank(BORROWER);
            loanToken.approve(morphoAddress, amountDue);
            vm.prank(BORROWER);
            morpho.repay(marketParams, amountDue, 0, BORROWER, hex"");
        }

        // Repay - should trigger _beforeRepay and _afterRepay hooks
        balanceBefore = jane.balanceOf(BORROWER);
        loanToken.setBalance(BORROWER, 10_000e18);
        vm.prank(BORROWER);
        loanToken.approve(morphoAddress, type(uint256).max);
        vm.prank(BORROWER);
        morpho.repay(marketParams, 5_000e18, 0, BORROWER, hex"");

        // Burn may occur if still in default
        assertTrue(jane.balanceOf(BORROWER) <= balanceBefore, "JANE may be burned in repay hook");
    }

    // ============ Helper Functions ============

    function _setupBorrowerWithLoanJane(address borrower, uint256 amount) internal {
        loanToken.setBalance(borrower, amount * 2);
        vm.prank(borrower);
        loanToken.approve(morphoAddress, type(uint256).max);

        // Set credit line
        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho)).setCreditLine(id, borrower, amount, 0);

        // Borrow
        vm.prank(borrower);
        morpho.borrow(marketParams, amount, 0, borrower, borrower);
    }

    function _createPastObligationJane(address borrower, uint256 repaymentBps, uint256 endingBalance) internal {
        // Get the current number of cycles to find the last cycle
        uint256 cycleCount = MorphoCreditLib.getPaymentCycleLength(IMorphoCredit(address(morpho)), id);
        require(cycleCount > 0, "No cycles exist");

        // Get the last cycle's end date
        uint256 lastCycleEnd = MorphoCredit(address(morpho)).paymentCycle(id, cycleCount - 1);

        // Create a new cycle that's at least CYCLE_DURATION after the last one
        // Add some buffer time to ensure we're well past the minimum duration
        uint256 newCycleEnd = lastCycleEnd + CYCLE_DURATION + 1 days;

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256[] memory repaymentBpsList = new uint256[](1);
        repaymentBpsList[0] = repaymentBps;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = endingBalance;

        // Warp to the new cycle end
        vm.warp(newCycleEnd);
        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).closeCycleAndPostObligations(
            id, newCycleEnd, borrowers, repaymentBpsList, endingBalances
        );

        // Move forward a bit after creating the cycle
        vm.warp(block.timestamp + 1);
    }

    function _repayObligation(address borrower) internal {
        (,, uint256 obligationAmount) = MorphoCredit(address(morpho)).repaymentObligation(id, borrower);

        loanToken.setBalance(borrower, obligationAmount);
        vm.prank(borrower);
        loanToken.approve(morphoAddress, obligationAmount);
        vm.prank(borrower);
        morpho.repay(marketParams, obligationAmount, 0, borrower, hex"");
    }

    function _continueMarketCyclesJane(Id marketId, uint256 targetTimestamp) internal {
        while (block.timestamp < targetTimestamp) {
            uint256 nextCycleEnd = block.timestamp + CYCLE_DURATION;
            if (nextCycleEnd > targetTimestamp) {
                vm.warp(targetTimestamp);
                break;
            }

            vm.warp(nextCycleEnd - 1);
            address[] memory borrowers = new address[](0);
            uint256[] memory repaymentBps = new uint256[](0);
            uint256[] memory endingBalances = new uint256[](0);

            vm.prank(marketParams.creditLine);
            MorphoCredit(address(morpho)).closeCycleAndPostObligations(
                marketId, block.timestamp, borrowers, repaymentBps, endingBalances
            );

            vm.warp(nextCycleEnd + 1);
        }
    }
}
