// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {ErrorsLib} from "../../../../src/libraries/ErrorsLib.sol";
import {IMorpho, Id, Market, MarketParams} from "../../../../src/interfaces/IMorpho.sol";

/**
 * @title Simple Debt Cap Test
 * @notice Isolated test for debt cap functionality
 */
contract DebtCapSimpleTest is Setup {
    USD3 public usd3Strategy;
    MockProtocolConfig public protocolConfig;

    address public alice = makeAddr("alice");
    address public borrower = makeAddr("borrower");

    uint256 public constant DEPOSIT_AMOUNT = 1_000_000e6; // 1M USDC
    uint256 public constant DEBT_CAP_USDC = 500_000e6; // 500K in USDC terms

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));

        // Get protocol config
        address morphoAddress = address(usd3Strategy.morphoCredit());
        protocolConfig = MockProtocolConfig(MorphoCredit(morphoAddress).protocolConfig());

        // Fund alice
        deal(address(underlyingAsset), alice, DEPOSIT_AMOUNT * 2);
    }

    function test_debtCap_simple() public {
        // Set debt cap in waUSDC terms (same as USDC since 1:1 initially)
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, DEBT_CAP_USDC);

        // Alice deposits to provide liquidity
        vm.prank(alice);
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        // Set MAX_ON_CREDIT to allow borrowing
        setMaxOnCredit(8000); // 80%

        // First borrow should use most but not all of the cap
        uint256 firstBorrow = DEBT_CAP_USDC - 1000e6; // Leave 1000 USDC room
        createMarketDebt(borrower, firstBorrow);

        // Check current total borrow after first borrow
        IMorpho morpho = USD3(address(strategy)).morphoCredit();
        Id marketId = USD3(address(strategy)).marketId();
        Market memory m = morpho.market(marketId);
        console2.log("Total borrow after first borrow:", m.totalBorrowAssets);
        console2.log("Debt cap:", DEBT_CAP_USDC);

        // Try to borrow more than remaining cap (should fail)
        address borrower2 = makeAddr("borrower2");

        // This should exceed the cap by 100 USDC
        // Directly borrow without calling report again
        MarketParams memory marketParams = USD3(address(strategy)).marketParams();

        // Set credit line for borrower2
        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower2, 2200e6, 0);

        // Try to borrow 1100 USDC when only 1000 available
        vm.expectRevert(ErrorsLib.DebtCapExceeded.selector);
        vm.prank(borrower2);
        helper.borrow(marketParams, 1100e6, 0, borrower2, borrower2);
    }

    function test_debtCap_zeroStopsBorrowing() public {
        protocolConfig.setConfig(ProtocolConfigLib.DEBT_CAP, 0);

        vm.prank(alice);
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        vm.prank(alice);
        strategy.deposit(DEPOSIT_AMOUNT, alice);

        setMaxOnCredit(8000);

        // Ensure funds deployed
        vm.prank(keeper);
        strategy.report();

        IMorpho morpho = USD3(address(strategy)).morphoCredit();
        Id marketId = USD3(address(strategy)).marketId();
        MarketParams memory marketParams = USD3(address(strategy)).marketParams();

        // Close cycle to enable borrowing
        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);
        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho))
            .closeCycleAndPostObligations(marketId, block.timestamp, borrowers, repaymentBps, endingBalances);

        vm.prank(marketParams.creditLine);
        MorphoCredit(address(morpho)).setCreditLine(marketId, borrower, 2 * DEBT_CAP_USDC, 0);

        uint256 borrowAmount = 1_000e6;
        vm.expectRevert(ErrorsLib.DebtCapExceeded.selector);
        vm.prank(borrower);
        helper.borrow(marketParams, borrowAmount, 0, borrower, borrower);
    }
}
