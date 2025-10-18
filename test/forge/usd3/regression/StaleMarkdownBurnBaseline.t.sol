// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {MarkdownController} from "../../../../src/MarkdownController.sol";
import {MarketParams, Id, RepaymentStatus} from "../../../../src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../../src/libraries/MarketParamsLib.sol";
import {MorphoCreditLib} from "../../../../src/libraries/periphery/MorphoCreditLib.sol";
import {ErrorsLib} from "../../../../src/libraries/ErrorsLib.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {ERC20Mock} from "../../../../src/mocks/ERC20Mock.sol";
import {OracleMock} from "../../../../src/mocks/OracleMock.sol";
import {ConfigurableIrmMock} from "../../mocks/ConfigurableIrmMock.sol";
import {CreditLineMock} from "../../../../src/mocks/CreditLineMock.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {Jane} from "../../../../src/jane/Jane.sol";
import {HelperMock} from "../../../../src/mocks/HelperMock.sol";
import {
    TransparentUpgradeableProxy
} from "../../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title StaleMarkdownBurnBaselineTest
 * @notice Regression test for the Stale Markdown Burn Baseline vulnerability (Sherlock #70)
 * @dev Tests the vulnerability where `MarkdownController` doesn't reset burn tracking when
 *      a borrower exits Default status, causing accelerated JANE burns on subsequent defaults.
 *
 * Vulnerability Details:
 * - `burnJaneProportional()` snapshots `initialJaneBalance[borrower]` on first burn
 * - When borrower exits Default (returns to Current), this baseline is NOT reset
 * - If borrower reduces JANE holdings and defaults again, burns continue from old baseline
 * - Result: Disproportionate burn rate relative to current holdings
 *
 * Attack Vector / Unexpected Behavior:
 * 1. Borrower enters Default with 1000 JANE tokens
 * 2. MarkdownController snapshots initialJaneBalance = 1000
 * 3. Some burns occur, then borrower repays and exits Default
 * 4. Borrower transfers out 500 JANE (now holds 500)
 * 5. Borrower defaults again
 * 6. Burns continue based on 1000 JANE baseline instead of 500
 * 7. Result: Burns happen at 2x the expected rate
 *
 * Fix:
 * - Add `resetBorrowerState()` to MarkdownController
 * - Call reset when entering Default (to start fresh for new episode)
 * - Call reset when exiting Default (to clear stale data)
 */
contract StaleMarkdownBurnBaselineTest is Test {
    using MarketParamsLib for MarketParams;

    MorphoCredit public morpho;
    MockProtocolConfig public protocolConfig;
    CreditLineMock public creditLine;
    MarkdownController public markdownController;
    Jane public janeToken;
    HelperMock public helper;

    ERC20Mock public loanToken;
    ERC20Mock public collateralToken;
    OracleMock public oracle;
    ConfigurableIrmMock public irm;

    MarketParams public marketParams;
    Id public marketId;

    address public morphoOwner = makeAddr("morphoOwner");
    address public borrower = makeAddr("borrower");
    address public janeMinter = makeAddr("janeMinter");

    uint256 public constant ORACLE_PRICE = 1e18;
    uint256 public constant INITIAL_JANE = 1000e18;
    uint256 public constant FULL_MARKDOWN_DURATION = 90 days;
    uint256 public constant CREDIT_AMOUNT = 10000e18;
    uint256 public constant BORROW_AMOUNT = 5000e18;
    uint256 public constant GRACE_PERIOD = 7 days;
    uint256 public constant DELINQUENCY_PERIOD = 30 days;
    uint256 public constant CYCLE_DURATION = 30 days;

    function setUp() public {
        // Deploy protocol config
        protocolConfig = new MockProtocolConfig();
        protocolConfig.setConfig(ProtocolConfigLib.FULL_MARKDOWN_DURATION, FULL_MARKDOWN_DURATION);

        // Set grace and delinquency periods through the MockProtocolConfig keys
        bytes32 GRACE_PERIOD_KEY = keccak256("GRACE_PERIOD");
        bytes32 DELINQUENCY_PERIOD_KEY = keccak256("DELINQUENCY_PERIOD");
        protocolConfig.setConfig(GRACE_PERIOD_KEY, GRACE_PERIOD);
        protocolConfig.setConfig(DELINQUENCY_PERIOD_KEY, DELINQUENCY_PERIOD);

        // Deploy MorphoCredit implementation
        MorphoCredit morphoImpl = new MorphoCredit(address(protocolConfig));

        // Deploy proxy admin
        ProxyAdmin proxyAdmin = new ProxyAdmin(morphoOwner);

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(MorphoCredit.initialize.selector, morphoOwner);
        TransparentUpgradeableProxy morphoProxy =
            new TransparentUpgradeableProxy(address(morphoImpl), address(proxyAdmin), initData);

        morpho = MorphoCredit(address(morphoProxy));

        // Set USD3 address to allow supply operations (test uses morphoOwner for supply)
        vm.prank(morphoOwner);
        morpho.setUsd3(morphoOwner);

        // Deploy JANE token - test contract is owner for easier role management
        janeToken = new Jane(address(this), janeMinter, address(this));

        // Deploy credit line mock
        creditLine = new CreditLineMock(address(morpho));

        // Setup tokens
        loanToken = new ERC20Mock();
        collateralToken = new ERC20Mock();
        oracle = new OracleMock();
        irm = new ConfigurableIrmMock();

        // Set oracle price
        oracle.setPrice(ORACLE_PRICE);

        // Create market params
        marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8e18,
            creditLine: address(creditLine)
        });

        // Calculate market ID
        marketId = marketParams.id();

        // Enable IRM and LLTV
        vm.startPrank(morphoOwner);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0.8e18);
        morpho.createMarket(marketParams);
        vm.stopPrank();

        // Deploy MarkdownController (with morphoOwner as owner)
        markdownController =
            new MarkdownController(address(protocolConfig), morphoOwner, address(janeToken), address(morpho), marketId);

        // Grant burner role to markdown controller (this contract has OWNER_ROLE in Jane)
        janeToken.grantRole(janeToken.BURNER_ROLE(), address(markdownController));

        // Set markdown manager on credit line
        vm.prank(morphoOwner);
        creditLine.setMm(address(markdownController));

        // Deploy and set helper for borrowing operations
        helper = new HelperMock(address(morpho));
        vm.prank(morphoOwner);
        morpho.setHelper(address(helper));

        // Grant minter role and mint initial JANE to borrower
        janeToken.grantRole(janeToken.MINTER_ROLE(), janeMinter);

        vm.prank(janeMinter);
        janeToken.mint(borrower, INITIAL_JANE);

        // Enable markdown for borrower
        vm.prank(morphoOwner);
        markdownController.setEnableMarkdown(borrower, true);

        // Enable JANE token transfers globally (test contract is owner)
        janeToken.setTransferable();

        // Setup borrower with credit line
        vm.prank(address(creditLine));
        morpho.setCreditLine(marketId, borrower, CREDIT_AMOUNT, 0);
    }

    /**
     * @notice Test that demonstrates proper reset behavior after fix
     * @dev After fix, reset occurs on both default entry and exit, ensuring fresh baseline
     */
    function test_fix_prevents_accelerated_burns() public {
        // Setup: Create initial payment cycle to allow borrowing
        _createPaymentCycle();

        // Step 1: Borrower borrows
        _borrowFunds(borrower, BORROW_AMOUNT);

        // Step 2: Advance to next cycle and post obligation for borrower (10% of debt)
        // Must wait at least CYCLE_DURATION from previous cycle end
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        uint256 obligationBps = 1000; // 10%
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = obligationBps;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = BORROW_AMOUNT;

        vm.prank(address(creditLine));
        morpho.closeCycleAndPostObligations(marketId, block.timestamp, borrowers, repaymentBps, endingBalances);

        // Step 3: Advance past grace and delinquency into Default
        vm.warp(block.timestamp + GRACE_PERIOD + DELINQUENCY_PERIOD + 1);

        // Verify borrower is in Default with 1000 JANE
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(morpho, marketId, borrower);
        assertEq(uint256(status), uint256(RepaymentStatus.Default), "Should be in Default");
        assertEq(janeToken.balanceOf(borrower), INITIAL_JANE, "Should have initial JANE");

        // Step 4: Trigger markdown (initializes baseline at 1000 JANE)
        vm.warp(block.timestamp + 10 days);
        morpho.accrueBorrowerPremium(marketId, borrower);

        // Verify some JANE was burned from first default episode
        uint256 janeAfterFirstDefault = janeToken.balanceOf(borrower);
        assertLt(janeAfterFirstDefault, INITIAL_JANE, "Some JANE should be burned");

        uint256 janeBurnedFirstEpisode = INITIAL_JANE - janeAfterFirstDefault;
        emit log_named_uint("JANE burned in first default episode", janeBurnedFirstEpisode);

        // Record baseline state for comparison
        uint256 initialBalanceTracked = markdownController.initialJaneBalance(borrower);
        uint256 janeBurnedTracked = markdownController.janeBurned(borrower);
        emit log_named_uint("Initial balance tracked after first default", initialBalanceTracked);
        emit log_named_uint("Jane burned tracked after first default", janeBurnedTracked);

        // Step 5: Create new cycle before repaying (to avoid MarketFrozen)
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        address[] memory emptyBorrowers = new address[](0);
        uint256[] memory emptyBps = new uint256[](0);
        uint256[] memory emptyBalances = new uint256[](0);
        vm.prank(address(creditLine));
        morpho.closeCycleAndPostObligations(marketId, block.timestamp, emptyBorrowers, emptyBps, emptyBalances);

        // Step 6: Borrower repays obligation to exit Default
        uint256 obligation = BORROW_AMOUNT * obligationBps / 10000;
        vm.startPrank(borrower);
        loanToken.setBalance(borrower, obligation);
        loanToken.approve(address(morpho), obligation);
        morpho.repay(marketParams, obligation, 0, borrower, "");
        vm.stopPrank();

        // Verify borrower returned to Current status
        (status,) = MorphoCreditLib.getRepaymentStatus(morpho, marketId, borrower);
        assertEq(uint256(status), uint256(RepaymentStatus.Current), "Should return to Current");

        // Step 7: After fix, baseline should be reset
        assertEq(markdownController.initialJaneBalance(borrower), 0, "Baseline should be reset on exit");
        assertEq(markdownController.janeBurned(borrower), 0, "Burned tracker should be reset on exit");

        // Step 8: Borrower reduces JANE holdings (transfers out half)
        uint256 janeToTransfer = janeAfterFirstDefault / 2;
        vm.prank(borrower);
        janeToken.transfer(address(1), janeToTransfer);

        uint256 janeBeforeSecondDefault = janeToken.balanceOf(borrower);
        emit log_named_uint("JANE balance before second default", janeBeforeSecondDefault);

        // Step 9: Create new cycle and default again (must wait at least CYCLE_DURATION from previous cycle end)
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        _postObligationOnly(borrower, BORROW_AMOUNT);

        // Advance into Default again
        vm.warp(block.timestamp + GRACE_PERIOD + DELINQUENCY_PERIOD + 1);

        // Step 10: After fix, baseline should be reset on default entry too
        assertEq(markdownController.initialJaneBalance(borrower), 0, "Baseline should be reset on entry");
        assertEq(markdownController.janeBurned(borrower), 0, "Burned tracker should be reset on entry");

        // Step 11: Trigger markdown again (should snapshot current JANE balance)
        vm.warp(block.timestamp + 10 days);
        morpho.accrueBorrowerPremium(marketId, borrower);

        // Verify burns are proportional to NEW baseline (reduced JANE holdings)
        uint256 janeAfterSecondDefault = janeToken.balanceOf(borrower);
        uint256 janeBurnedSecondEpisode = janeBeforeSecondDefault - janeAfterSecondDefault;

        emit log_named_uint("JANE burned in second default episode", janeBurnedSecondEpisode);

        // After fix: Burns should be proportional to current holdings
        // Both episodes have same time in default (10 days), so burn amounts should be proportional to holdings
        uint256 expectedBurnRatio = (janeBurnedSecondEpisode * INITIAL_JANE) / janeBeforeSecondDefault; // Normalize to
            // original holdings
        uint256 actualBurnRatio = janeBurnedFirstEpisode;

        // Allow 1% tolerance for rounding
        uint256 tolerance = actualBurnRatio / 100;
        assertApproxEqAbs(
            expectedBurnRatio, actualBurnRatio, tolerance, "Burn amounts should be proportional to holdings"
        );
    }

    /**
     * @notice Test that baseline resets on default entry
     */
    function test_baseline_resets_on_default_entry() public {
        _createPaymentCycle();
        _borrowFunds(borrower, BORROW_AMOUNT);

        // Advance to next cycle and post obligation and enter default
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        _postObligationAndEnterDefault(borrower, BORROW_AMOUNT);

        // Trigger markdown to initialize baseline
        vm.warp(block.timestamp + 10 days);
        morpho.accrueBorrowerPremium(marketId, borrower);

        uint256 baselineAfterFirstDefault = markdownController.initialJaneBalance(borrower);
        assertGt(baselineAfterFirstDefault, 0, "Baseline should be set after first default");

        // Repay and exit default
        _repayAndExitDefault(borrower, BORROW_AMOUNT);

        // Verify reset on exit
        assertEq(markdownController.initialJaneBalance(borrower), 0, "Baseline reset on exit");

        // Enter default again (wait for next cycle)
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        _postObligationAndEnterDefault(borrower, BORROW_AMOUNT);

        // Baseline should still be 0 before first burn of new episode
        assertEq(markdownController.initialJaneBalance(borrower), 0, "Baseline reset on entry");
    }

    /**
     * @notice Test that baseline resets on default exit
     */
    function test_baseline_resets_on_default_exit() public {
        _createPaymentCycle();
        _borrowFunds(borrower, BORROW_AMOUNT);

        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        _postObligationAndEnterDefault(borrower, BORROW_AMOUNT);

        // Trigger markdown
        vm.warp(block.timestamp + 10 days);
        morpho.accrueBorrowerPremium(marketId, borrower);

        // Verify baseline is set
        uint256 baselineBeforeExit = markdownController.initialJaneBalance(borrower);
        uint256 burnedBeforeExit = markdownController.janeBurned(borrower);
        assertGt(baselineBeforeExit, 0, "Baseline should be set");
        assertGt(burnedBeforeExit, 0, "Some burns should have occurred");

        // Repay and exit default
        _repayAndExitDefault(borrower, BORROW_AMOUNT);

        // Verify reset occurred
        assertEq(markdownController.initialJaneBalance(borrower), 0, "Baseline should be reset");
        assertEq(markdownController.janeBurned(borrower), 0, "Burn tracker should be reset");
    }

    /**
     * @notice Test multiple default episodes with different JANE balances
     * @dev Verifies that baseline resets properly across multiple default episodes
     */
    function test_multiple_default_episodes_with_varying_jane() public {
        _createPaymentCycle();
        _borrowFunds(borrower, BORROW_AMOUNT);

        // Episode 1: Default with 1000 JANE
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        _postObligationAndEnterDefault(borrower, BORROW_AMOUNT);
        vm.warp(block.timestamp + 20 days);
        morpho.accrueBorrowerPremium(marketId, borrower);

        uint256 janeAfterEpisode1 = janeToken.balanceOf(borrower);
        uint256 burnedEpisode1 = INITIAL_JANE - janeAfterEpisode1;
        emit log_named_uint("Burned in episode 1 (1000 JANE baseline)", burnedEpisode1);
        assertGt(burnedEpisode1, 0, "Should have burned some JANE in episode 1");

        // Verify baseline is set
        assertGt(markdownController.initialJaneBalance(borrower), 0, "Baseline should be set");

        // Exit default
        _repayAndExitDefault(borrower, BORROW_AMOUNT);

        // Verify baseline is reset on exit
        assertEq(markdownController.initialJaneBalance(borrower), 0, "Baseline should be reset after exit");

        // Reduce holdings to 75%
        vm.prank(borrower);
        janeToken.transfer(address(1), janeAfterEpisode1 / 4);
        uint256 janeBeforeEpisode2 = janeToken.balanceOf(borrower);

        // Episode 2: Default with 75% of previous JANE (wait for next cycle)
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        _postObligationAndEnterDefault(borrower, BORROW_AMOUNT);

        // Baseline should still be 0 before first burn
        assertEq(markdownController.initialJaneBalance(borrower), 0, "Baseline should be 0 on entry");

        vm.warp(block.timestamp + 20 days);
        morpho.accrueBorrowerPremium(marketId, borrower);

        uint256 janeAfterEpisode2 = janeToken.balanceOf(borrower);
        uint256 burnedEpisode2 = janeBeforeEpisode2 - janeAfterEpisode2;
        emit log_named_uint("Burned in episode 2 (75% JANE baseline)", burnedEpisode2);
        assertGt(burnedEpisode2, 0, "Should have burned some JANE in episode 2");

        // Verify new baseline is set based on current holdings
        uint256 baseline2 = markdownController.initialJaneBalance(borrower);
        assertEq(baseline2, janeBeforeEpisode2, "Baseline should match JANE balance at episode 2 start");

        // Exit default
        _repayAndExitDefault(borrower, BORROW_AMOUNT);

        // Verify baseline is reset on exit
        assertEq(markdownController.initialJaneBalance(borrower), 0, "Baseline should be reset after episode 2");

        // Reduce holdings to 50%
        vm.prank(borrower);
        janeToken.transfer(address(1), janeAfterEpisode2 / 2);
        uint256 janeBeforeEpisode3 = janeToken.balanceOf(borrower);

        // Episode 3: Default with 50% of episode 2 JANE (wait for next cycle)
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        _postObligationAndEnterDefault(borrower, BORROW_AMOUNT);

        // Baseline should still be 0 before first burn
        assertEq(markdownController.initialJaneBalance(borrower), 0, "Baseline should be 0 on entry");

        vm.warp(block.timestamp + 20 days);
        morpho.accrueBorrowerPremium(marketId, borrower);

        uint256 janeAfterEpisode3 = janeToken.balanceOf(borrower);
        uint256 burnedEpisode3 = janeBeforeEpisode3 - janeAfterEpisode3;
        emit log_named_uint("Burned in episode 3 (50% of ep2 JANE baseline)", burnedEpisode3);
        assertGt(burnedEpisode3, 0, "Should have burned some JANE in episode 3");

        // Verify new baseline is set based on current holdings
        uint256 baseline3 = markdownController.initialJaneBalance(borrower);
        assertEq(baseline3, janeBeforeEpisode3, "Baseline should match JANE balance at episode 3 start");
    }

    /**
     * @notice Test that zero JANE balance doesn't cause issues
     */
    function test_zero_jane_balance_handling() public {
        _createPaymentCycle();
        _borrowFunds(borrower, BORROW_AMOUNT);

        // Borrower transfers away all JANE
        vm.prank(borrower);
        janeToken.transfer(address(1), INITIAL_JANE);

        assertEq(janeToken.balanceOf(borrower), 0, "Should have zero JANE");

        // Enter default (wait for next cycle)
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        _postObligationAndEnterDefault(borrower, BORROW_AMOUNT);

        // Trigger markdown (should handle zero balance gracefully)
        vm.warp(block.timestamp + 10 days);
        morpho.accrueBorrowerPremium(marketId, borrower);

        // Verify no burns occurred and baseline is 0
        assertEq(janeToken.balanceOf(borrower), 0, "Still zero JANE");
        assertEq(markdownController.janeBurned(borrower), 0, "No burns tracked");
    }

    /* HELPER FUNCTIONS */

    function _createPaymentCycle() internal {
        address[] memory emptyBorrowers = new address[](0);
        uint256[] memory emptyBps = new uint256[](0);
        uint256[] memory emptyBalances = new uint256[](0);

        vm.prank(address(creditLine));
        morpho.closeCycleAndPostObligations(marketId, block.timestamp, emptyBorrowers, emptyBps, emptyBalances);

        // Warp forward to give buffer before cycle end
        // This ensures we're not at the frozen boundary when borrowing
        vm.warp(block.timestamp + 1 days);
    }

    function _borrowFunds(address _borrower, uint256 amount) internal {
        // Set loan token balance for Morpho for lending
        loanToken.setBalance(address(morpho), amount);

        // Deposit as supply
        vm.startPrank(morphoOwner);
        loanToken.setBalance(morphoOwner, amount);
        loanToken.approve(address(morpho), amount);
        morpho.supply(marketParams, amount, 0, morphoOwner, "");
        vm.stopPrank();

        // Borrower borrows through helper
        vm.prank(_borrower);
        helper.borrow(marketParams, amount, 0, _borrower, _borrower);
    }

    function _postObligationAndEnterDefault(address _borrower, uint256 endingBalance) internal {
        _postObligationOnly(_borrower, endingBalance);

        // Advance past grace and delinquency into Default
        vm.warp(block.timestamp + GRACE_PERIOD + DELINQUENCY_PERIOD + 1);

        // Verify in Default
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(morpho, marketId, _borrower);
        assertEq(uint256(status), uint256(RepaymentStatus.Default), "Should be in Default");
    }

    function _postObligationOnly(address _borrower, uint256 endingBalance) internal {
        uint256 obligationBps = 1000; // 10%
        address[] memory borrowers = new address[](1);
        borrowers[0] = _borrower;
        uint256[] memory repaymentBps = new uint256[](1);
        repaymentBps[0] = obligationBps;
        uint256[] memory endingBalances = new uint256[](1);
        endingBalances[0] = endingBalance;

        vm.prank(address(creditLine));
        morpho.closeCycleAndPostObligations(marketId, block.timestamp, borrowers, repaymentBps, endingBalances);
    }

    function _repayAndExitDefault(address _borrower, uint256 endingBalance) internal {
        // Create new cycle before repaying to avoid MarketFrozen
        vm.warp(block.timestamp + CYCLE_DURATION + 1 days);
        address[] memory emptyBorrowers = new address[](0);
        uint256[] memory emptyBps = new uint256[](0);
        uint256[] memory emptyBalances = new uint256[](0);
        vm.prank(address(creditLine));
        morpho.closeCycleAndPostObligations(marketId, block.timestamp, emptyBorrowers, emptyBps, emptyBalances);

        uint256 obligationBps = 1000; // 10%
        uint256 obligation = endingBalance * obligationBps / 10000;

        vm.startPrank(_borrower);
        loanToken.setBalance(_borrower, obligation);
        loanToken.approve(address(morpho), obligation);
        morpho.repay(marketParams, obligation, 0, _borrower, "");
        vm.stopPrank();

        // Verify returned to Current
        (RepaymentStatus status,) = MorphoCreditLib.getRepaymentStatus(morpho, marketId, _borrower);
        assertEq(uint256(status), uint256(RepaymentStatus.Current), "Should return to Current");
    }
}
