// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseTest} from "../BaseTest.sol";
import {Helper} from "../../../src/Helper.sol";
import {IMorpho, MarketParams, Position} from "../../../src/interfaces/IMorpho.sol";
import {IERC20} from "../../../src/interfaces/IERC20.sol";
import {IERC4626} from "../../../lib/forge-std/src/interfaces/IERC4626.sol";
import {console2} from "../../../lib/forge-std/src/console2.sol";
import {ERC20Mock} from "../../../src/mocks/ERC20Mock.sol";
import {SharesMathLib} from "../../../src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";

// Import the mock contracts from HelperTest
import {USD3Mock, WrapMock} from "./HelperTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";

contract HelperBorrowTest is BaseTest {
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    Helper public helper;
    USD3Mock public USD3;
    USD3Mock public sUSD3;
    ERC20Mock public USDC;
    WrapMock public waUSDC;
    CreditLineMock public creditLine;

    address constant TEST_BORROWER = address(0x1234);
    uint256 constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC
    uint256 constant BORROW_AMOUNT = 10_000e6; // 10k USDC

    function setUp() public virtual override {
        super.setUp();

        // Deploy mock contracts
        USDC = new ERC20Mock();
        waUSDC = new WrapMock(address(USDC));
        USD3 = new USD3Mock();
        sUSD3 = new USD3Mock();

        // Deploy CreditLineMock
        creditLine = new CreditLineMock(address(morpho));

        // Configure USD3Mock with waUSDC as underlying
        USD3.setUnderlying(address(waUSDC));
        sUSD3.setUnderlying(address(USD3));

        // Deploy Helper contract
        helper = new Helper(address(morpho), address(USD3), address(sUSD3), address(USDC), address(waUSDC));

        // Setup borrower with USDC for fees/repayments
        USDC.setBalance(TEST_BORROWER, INITIAL_BALANCE);

        // Setup market with waUSDC as loan token
        marketParams = MarketParams({
            loanToken: address(waUSDC),
            collateralToken: address(0), // No collateral for credit line
            oracle: address(0), // No oracle needed
            irm: address(irm),
            lltv: 0, // No liquidation
            creditLine: address(creditLine) // Use the deployed credit line mock
        });
        id = marketParams.id();

        // Create the market (requires owner permission)
        vm.prank(OWNER);
        morpho.createMarket(marketParams);

        // Setup market with liquidity
        _setupMarketWithLiquidity();

        // Give borrower credit line
        _setupBorrowerCreditLine(TEST_BORROWER);

        // Close initial cycle to unfreeze the market
        _closeCycle();

        // Approve Helper to use TEST_BORROWER's USDC
        vm.prank(TEST_BORROWER);
        USDC.approve(address(helper), type(uint256).max);
    }

    function _setupMarketWithLiquidity() internal {
        // Create supplier with waUSDC
        address supplier = address(0x5555);

        // Mint USDC and convert to waUSDC
        USDC.setBalance(supplier, 10_000_000e6); // 10M USDC

        vm.startPrank(supplier);
        USDC.approve(address(waUSDC), type(uint256).max);
        uint256 waUsdcAmount = waUSDC.deposit(10_000_000e6, supplier);
        waUSDC.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, waUsdcAmount, 0, supplier, "");
        vm.stopPrank();
    }

    function _setupBorrowerCreditLine(address borrower) internal {
        // Use CreditLineMock to set credit line (which will also call morpho.setCreditLine)
        creditLine.setCreditLine(id, borrower, 100_000e6, 0); // 100k USDC credit line, 0 drp
    }

    function _closeCycle() internal {
        // Close the cycle to unfreeze the market
        // Markets are frozen between cycles, need to close cycle to allow borrowing
        vm.warp(block.timestamp + 30 days);

        address[] memory borrowers = new address[](0);
        uint256[] memory repaymentBps = new uint256[](0);
        uint256[] memory endingBalances = new uint256[](0);

        vm.prank(address(creditLine));
        IMorphoCredit(address(morpho))
            .closeCycleAndPostObligations(id, block.timestamp, borrowers, repaymentBps, endingBalances);
    }

    function test_BorrowConversion_BasicFlow() public {
        vm.startPrank(TEST_BORROWER);

        // Record initial states
        uint256 initialUsdcBalance = USDC.balanceOf(TEST_BORROWER);
        uint256 initialWaUsdcBalance = waUSDC.balanceOf(TEST_BORROWER);

        console2.log("Initial USDC balance:", initialUsdcBalance);
        console2.log("Initial waUSDC balance:", initialWaUsdcBalance);
        console2.log("Attempting to borrow USDC amount:", BORROW_AMOUNT);

        // Calculate expected waUSDC amount that should be borrowed from Morpho
        uint256 expectedWaUsdcBorrow = waUSDC.convertToShares(BORROW_AMOUNT);
        console2.log("Expected waUSDC to borrow from Morpho:", expectedWaUsdcBorrow);

        // Borrow through helper (user specifies USDC amount)
        (uint256 usdcReceived, uint256 borrowShares) = helper.borrow(marketParams, BORROW_AMOUNT);

        console2.log("USDC received:", usdcReceived);
        console2.log("Morpho borrow shares:", borrowShares);

        // Verify USDC was received
        uint256 finalUsdcBalance = USDC.balanceOf(TEST_BORROWER);
        assertEq(finalUsdcBalance, initialUsdcBalance + usdcReceived, "USDC balance incorrect");
        assertApproxEqAbs(usdcReceived, BORROW_AMOUNT, 10, "USDC received should match requested amount");

        // Verify no waUSDC remains with borrower (all redeemed to USDC)
        assertEq(waUSDC.balanceOf(TEST_BORROWER), initialWaUsdcBalance, "Borrower should not hold waUSDC");

        // Verify Morpho position
        Position memory pos = morpho.position(marketParams.id(), TEST_BORROWER);
        assertEq(pos.borrowShares, borrowShares, "Morpho borrow shares mismatch");

        vm.stopPrank();
    }

    function test_BorrowConversion_ExactAmounts() public {
        vm.startPrank(TEST_BORROWER);

        // Test that the conversion math is correct
        uint256 usdcAmount = 10_000e6; // 10k USDC

        // What helper does internally:
        // 1. Converts USDC amount to waUSDC shares
        uint256 waUsdcShares = waUSDC.convertToShares(usdcAmount);
        console2.log("Step 1 - waUSDC shares for", usdcAmount, "USDC:", waUsdcShares);

        // 2. Borrows that amount of waUSDC from Morpho
        (uint256 waUsdcBorrowed, uint256 borrowShares) = helper.borrow(marketParams, usdcAmount);
        console2.log("Step 2 - waUSDC borrowed from Morpho:", waUsdcBorrowed);

        // 3. Helper redeems waUSDC to USDC for user
        // Let's verify the amount by checking what would be redeemed
        uint256 expectedUsdcFromRedeem = waUSDC.previewRedeem(waUsdcShares);
        console2.log("Step 3 - Expected USDC from redeeming waUSDC:", expectedUsdcFromRedeem);

        assertApproxEqAbs(waUsdcBorrowed, usdcAmount, 10, "Amount borrowed should approximately equal USDC requested");

        vm.stopPrank();
    }

    function test_BorrowConversion_VaultExchangeRate() public {
        // Test when waUSDC vault has accumulated yield (exchange rate != 1:1)

        // Simulate some yield in waUSDC vault by sending extra USDC
        USDC.setBalance(address(waUSDC), USDC.balanceOf(address(waUSDC)) + 1_000e6);

        vm.startPrank(TEST_BORROWER);

        uint256 usdcAmount = 10_000e6;

        // Check the exchange rate
        uint256 waUsdcPerUsdc = waUSDC.convertToShares(1e6); // How many waUSDC shares for 1 USDC
        console2.log("waUSDC shares per 1 USDC:", waUsdcPerUsdc);

        uint256 usdcPerWaUsdc = waUSDC.convertToAssets(1e6); // How many USDC for 1 waUSDC share
        console2.log("USDC per 1 waUSDC share:", usdcPerWaUsdc);

        // Now borrow
        (uint256 usdcReceived,) = helper.borrow(marketParams, usdcAmount);

        console2.log("Requested USDC:", usdcAmount);
        console2.log("Received USDC:", usdcReceived);

        // Even with different exchange rates, user should get approximately what they asked for
        assertApproxEqRel(usdcReceived, usdcAmount, 0.01e18, "Should receive approximately requested USDC amount");

        vm.stopPrank();
    }

    function test_BorrowConversion_CompareWithDirectMorphoBorrow() public {
        // Compare borrowing through Helper vs directly through Morpho

        address directBorrower = address(0x9999);
        _setupBorrowerCreditLine(directBorrower);
        USDC.setBalance(directBorrower, INITIAL_BALANCE);

        uint256 borrowAmount = 5_000e6; // 5k USDC

        // Direct borrow from Morpho (need to handle waUSDC)
        vm.startPrank(directBorrower);
        uint256 waUsdcToBorrow = waUSDC.convertToShares(borrowAmount);
        (uint256 directWaUsdcReceived, uint256 directBorrowShares) =
            morpho.borrow(marketParams, waUsdcToBorrow, 0, directBorrower, directBorrower);

        // Must manually redeem waUSDC to USDC
        waUSDC.approve(address(waUSDC), type(uint256).max);
        uint256 directUsdcReceived = waUSDC.redeem(directWaUsdcReceived, directBorrower, directBorrower);
        vm.stopPrank();

        // Borrow through helper
        vm.startPrank(TEST_BORROWER);
        (uint256 helperUsdcReceived, uint256 helperBorrowShares) = helper.borrow(marketParams, borrowAmount);
        vm.stopPrank();

        console2.log("Direct borrow - USDC received:", directUsdcReceived);
        console2.log("Helper borrow - USDC received:", helperUsdcReceived);
        console2.log("Direct borrow shares:", directBorrowShares);
        console2.log("Helper borrow shares:", helperBorrowShares);

        // Both should receive approximately the same amount
        assertApproxEqRel(
            helperUsdcReceived, directUsdcReceived, 0.001e18, "Helper and direct should yield similar USDC amounts"
        );
        assertApproxEqRel(helperBorrowShares, directBorrowShares, 0.001e18, "Borrow shares should be similar");
    }
}
