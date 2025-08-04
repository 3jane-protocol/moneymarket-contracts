// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {SimpleCreditLineMock} from "../mocks/SimpleCreditLineMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract WithdrawIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    SimpleCreditLineMock internal creditLine;

    function setUp() public override {
        super.setUp();

        // Deploy credit line mock
        creditLine = new SimpleCreditLineMock();

        // Update marketParams to use the credit line
        marketParams = MarketParams(
            address(loanToken),
            address(collateralToken),
            address(oracle),
            address(irm),
            DEFAULT_TEST_LLTV,
            address(creditLine)
        );
        id = marketParams.id();

        // Create the market with credit line
        vm.prank(OWNER);
        morpho.createMarket(marketParams);
    }

    function testWithdrawMarketNotCreated(MarketParams memory marketParamsParamsFuzz) public {
        vm.assume(neq(marketParamsParamsFuzz, marketParams));

        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.withdraw(marketParamsParamsFuzz, 1, 0, address(this), address(this));
    }

    function testWithdrawZeroAmount(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.withdraw(marketParams, 0, 0, address(this), address(this));
    }

    function testWithdrawInconsistentInput(uint256 amount, uint256 shares) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);
        shares = bound(shares, 1, MAX_TEST_SHARES);

        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.withdraw(marketParams, amount, shares, address(this), address(this));
    }

    function testWithdrawToZeroAddress(uint256 amount) public {
        amount = bound(amount, 1, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amount);
        morpho.supply(marketParams, amount, 0, address(this), hex"");

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        morpho.withdraw(marketParams, amount, 0, address(this), address(0));
    }

    function testWithdrawUnauthorized(address attacker, uint256 amount) public {
        // Test that only USD3 contract can call withdraw
        // For this test, we need to use actual MorphoCredit, not the mock
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        // Exclude proxy-related addresses from fuzzing
        vm.assume(!_isProxyRelatedAddress(attacker));
        vm.assume(attacker != address(0));
        vm.assume(attacker != SUPPLIER);

        // Deploy a separate MorphoCredit instance (not mock) for this test
        MorphoCredit morphoCreditImpl = new MorphoCredit(address(protocolConfig));
        TransparentUpgradeableProxy morphoCreditProxy = new TransparentUpgradeableProxy(
            address(morphoCreditImpl),
            address(proxyAdmin),
            abi.encodeWithSelector(MorphoCredit.initialize.selector, OWNER)
        );
        IMorpho morphoCredit = IMorpho(address(morphoCreditProxy));

        // Set helper and usd3 addresses to allow supply
        address mockUsd3 = makeAddr("MockUSD3");
        vm.startPrank(OWNER);
        IMorphoCredit(address(morphoCredit)).setUsd3(mockUsd3);
        vm.stopPrank();

        // Create a new market params for the isolated test
        MarketParams memory isolatedMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(irm),
            lltv: DEFAULT_TEST_LLTV,
            creditLine: address(creditLine)
        });

        // Set up the market on the new instance
        vm.prank(OWNER);
        morphoCredit.enableIrm(address(irm));
        vm.prank(OWNER);
        morphoCredit.enableLltv(DEFAULT_TEST_LLTV);
        morphoCredit.createMarket(isolatedMarketParams);

        // Supply to the market (through mockUsd3 to pass the check)
        loanToken.setBalance(mockUsd3, amount);
        vm.startPrank(mockUsd3);
        loanToken.approve(address(morphoCredit), amount);
        morphoCredit.supply(isolatedMarketParams, amount, 0, SUPPLIER, hex"");
        vm.stopPrank();

        // Try to withdraw directly (not through USD3) - should fail
        vm.prank(attacker);
        vm.expectRevert(ErrorsLib.NotUsd3.selector);
        morphoCredit.withdraw(isolatedMarketParams, amount, 0, SUPPLIER, attacker);

        // Even the supplier themselves cannot withdraw directly
        vm.prank(SUPPLIER);
        vm.expectRevert(ErrorsLib.NotUsd3.selector);
        morphoCredit.withdraw(isolatedMarketParams, amount, 0, SUPPLIER, SUPPLIER);
    }

    function testWithdrawInsufficientLiquidity(uint256 amountSupplied, uint256 amountBorrowed) public {
        // For credit-based lending: test withdrawal when there's insufficient liquidity
        amountBorrowed = bound(amountBorrowed, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        amountSupplied = bound(amountSupplied, amountBorrowed + 1, MAX_TEST_AMOUNT + 1);
        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        loanToken.setBalance(SUPPLIER, amountSupplied);

        vm.prank(SUPPLIER);
        morpho.supply(marketParams, amountSupplied, 0, SUPPLIER, hex"");

        // Set up credit line for BORROWER
        vm.prank(marketParams.creditLine);
        IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

        vm.startPrank(BORROWER);
        morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, RECEIVER);
        vm.stopPrank();

        vm.prank(SUPPLIER);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        morpho.withdraw(marketParams, amountSupplied, 0, SUPPLIER, RECEIVER);
    }

    function testWithdrawAssets(uint256 amountSupplied, uint256 amountBorrowed, uint256 amountWithdrawn) public {
        // For credit-based lending: test withdrawal with active borrowing
        amountBorrowed = bound(amountBorrowed, 0, MAX_TEST_AMOUNT - 1);
        amountSupplied = bound(amountSupplied, amountBorrowed + 1, MAX_TEST_AMOUNT);
        amountWithdrawn = bound(amountWithdrawn, 1, amountSupplied - amountBorrowed);

        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        if (amountBorrowed > 0) {
            // Set up credit line for BORROWER
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

            vm.startPrank(BORROWER);
            morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
            vm.stopPrank();
        }

        uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
        uint256 expectedWithdrawnShares = amountWithdrawn.toSharesUp(amountSupplied, expectedSupplyShares);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Withdraw(id, address(this), address(this), RECEIVER, amountWithdrawn, expectedWithdrawnShares);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.withdraw(marketParams, amountWithdrawn, 0, address(this), RECEIVER);

        expectedSupplyShares -= expectedWithdrawnShares;

        assertEq(returnAssets, amountWithdrawn, "returned asset amount");
        assertEq(returnShares, expectedWithdrawnShares, "returned shares amount");
        assertEq(morpho.supplyShares(id, address(this)), expectedSupplyShares, "supply shares");
        assertEq(morpho.totalSupplyShares(id), expectedSupplyShares, "total supply shares");
        assertEq(morpho.totalSupplyAssets(id), amountSupplied - amountWithdrawn, "total supply");
        assertEq(loanToken.balanceOf(RECEIVER), amountWithdrawn, "RECEIVER balance");
        assertEq(loanToken.balanceOf(BORROWER), amountBorrowed, "borrower balance");
        assertEq(
            loanToken.balanceOf(address(morpho)), amountSupplied - amountBorrowed - amountWithdrawn, "morpho balance"
        );
    }

    function testWithdrawShares(uint256 amountSupplied, uint256 amountBorrowed, uint256 sharesWithdrawn) public {
        // For credit-based lending: test share-based withdrawal
        amountBorrowed = bound(amountBorrowed, 0, MAX_TEST_AMOUNT / 2);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
        uint256 availableLiquidity = amountSupplied - amountBorrowed;
        uint256 withdrawableShares = availableLiquidity.toSharesDown(amountSupplied, expectedSupplyShares);
        vm.assume(withdrawableShares != 0);

        sharesWithdrawn = bound(sharesWithdrawn, 1, withdrawableShares);
        uint256 expectedAmountWithdrawn = sharesWithdrawn.toAssetsDown(amountSupplied, expectedSupplyShares);

        loanToken.setBalance(address(this), amountSupplied);
        morpho.supply(marketParams, amountSupplied, 0, address(this), hex"");

        if (amountBorrowed > 0) {
            // Set up credit line for BORROWER
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho)).setCreditLine(id, BORROWER, creditLimit, 0);

            vm.startPrank(BORROWER);
            morpho.borrow(marketParams, amountBorrowed, 0, BORROWER, BORROWER);
            vm.stopPrank();
        }

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Withdraw(id, address(this), address(this), RECEIVER, expectedAmountWithdrawn, sharesWithdrawn);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.withdraw(marketParams, 0, sharesWithdrawn, address(this), RECEIVER);

        expectedSupplyShares -= sharesWithdrawn;

        assertEq(returnAssets, expectedAmountWithdrawn, "returned asset amount");
        assertEq(returnShares, sharesWithdrawn, "returned shares amount");
        assertEq(morpho.supplyShares(id, address(this)), expectedSupplyShares, "supply shares");
        assertEq(morpho.totalSupplyAssets(id), amountSupplied - expectedAmountWithdrawn, "total supply");
        assertEq(morpho.totalSupplyShares(id), expectedSupplyShares, "total supply shares");
        assertEq(loanToken.balanceOf(RECEIVER), expectedAmountWithdrawn, "RECEIVER balance");
        assertEq(
            loanToken.balanceOf(address(morpho)),
            amountSupplied - amountBorrowed - expectedAmountWithdrawn,
            "morpho balance"
        );
    }

    function testWithdrawAssetsOnBehalf(uint256 amountSupplied, uint256 amountBorrowed, uint256 amountWithdrawn)
        public
    {
        // For credit-based lending: test on-behalf withdrawal
        amountBorrowed = bound(amountBorrowed, 0, MAX_TEST_AMOUNT - 1);
        amountSupplied = bound(amountSupplied, amountBorrowed + 1, MAX_TEST_AMOUNT);
        amountWithdrawn = bound(amountWithdrawn, 1, amountSupplied - amountBorrowed);

        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        loanToken.setBalance(ONBEHALF, amountSupplied);

        vm.startPrank(ONBEHALF);
        morpho.supply(marketParams, amountSupplied, 0, ONBEHALF, hex"");

        if (amountBorrowed > 0) {
            // Set up credit line for ONBEHALF
            vm.stopPrank();
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho)).setCreditLine(id, ONBEHALF, creditLimit, 0);
            vm.startPrank(ONBEHALF);

            morpho.borrow(marketParams, amountBorrowed, 0, ONBEHALF, ONBEHALF);
        }
        vm.stopPrank();

        uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
        uint256 expectedWithdrawnShares = amountWithdrawn.toSharesUp(amountSupplied, expectedSupplyShares);

        uint256 receiverBalanceBefore = loanToken.balanceOf(RECEIVER);

        vm.startPrank(BORROWER);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Withdraw(id, BORROWER, ONBEHALF, RECEIVER, amountWithdrawn, expectedWithdrawnShares);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.withdraw(marketParams, amountWithdrawn, 0, ONBEHALF, RECEIVER);

        expectedSupplyShares -= expectedWithdrawnShares;

        assertEq(returnAssets, amountWithdrawn, "returned asset amount");
        assertEq(returnShares, expectedWithdrawnShares, "returned shares amount");
        assertEq(morpho.supplyShares(id, ONBEHALF), expectedSupplyShares, "supply shares");
        assertEq(morpho.totalSupplyAssets(id), amountSupplied - amountWithdrawn, "total supply");
        assertEq(morpho.totalSupplyShares(id), expectedSupplyShares, "total supply shares");
        assertEq(loanToken.balanceOf(RECEIVER) - receiverBalanceBefore, amountWithdrawn, "RECEIVER balance");
        assertEq(
            loanToken.balanceOf(address(morpho)), amountSupplied - amountBorrowed - amountWithdrawn, "morpho balance"
        );
    }

    function testWithdrawSharesOnBehalf(uint256 amountSupplied, uint256 amountBorrowed, uint256 sharesWithdrawn)
        public
    {
        // For credit-based lending: test share-based on-behalf withdrawal
        amountBorrowed = bound(amountBorrowed, 0, MAX_TEST_AMOUNT / 2);
        amountSupplied = bound(amountSupplied, amountBorrowed, MAX_TEST_AMOUNT);

        uint256 creditLimit = bound(amountBorrowed, amountBorrowed, MAX_TEST_AMOUNT);

        uint256 expectedSupplyShares = amountSupplied.toSharesDown(0, 0);
        uint256 availableLiquidity = amountSupplied - amountBorrowed;
        uint256 withdrawableShares = availableLiquidity.toSharesDown(amountSupplied, expectedSupplyShares);
        vm.assume(withdrawableShares != 0);

        sharesWithdrawn = bound(sharesWithdrawn, 1, withdrawableShares);
        uint256 expectedAmountWithdrawn = sharesWithdrawn.toAssetsDown(amountSupplied, expectedSupplyShares);

        loanToken.setBalance(ONBEHALF, amountSupplied);

        vm.startPrank(ONBEHALF);
        morpho.supply(marketParams, amountSupplied, 0, ONBEHALF, hex"");

        if (amountBorrowed > 0) {
            // Set up credit line for ONBEHALF
            vm.stopPrank();
            vm.prank(marketParams.creditLine);
            IMorphoCredit(address(morpho)).setCreditLine(id, ONBEHALF, creditLimit, 0);
            vm.startPrank(ONBEHALF);

            morpho.borrow(marketParams, amountBorrowed, 0, ONBEHALF, ONBEHALF);
        }
        vm.stopPrank();

        uint256 receiverBalanceBefore = loanToken.balanceOf(RECEIVER);

        vm.startPrank(BORROWER);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.Withdraw(id, BORROWER, ONBEHALF, RECEIVER, expectedAmountWithdrawn, sharesWithdrawn);
        (uint256 returnAssets, uint256 returnShares) =
            morpho.withdraw(marketParams, 0, sharesWithdrawn, ONBEHALF, RECEIVER);

        expectedSupplyShares -= sharesWithdrawn;

        assertEq(returnAssets, expectedAmountWithdrawn, "returned asset amount");
        assertEq(returnShares, sharesWithdrawn, "returned shares amount");
        assertEq(morpho.supplyShares(id, ONBEHALF), expectedSupplyShares, "supply shares");
        assertEq(morpho.totalSupplyAssets(id), amountSupplied - expectedAmountWithdrawn, "total supply");
        assertEq(morpho.totalSupplyShares(id), expectedSupplyShares, "total supply shares");
        assertEq(loanToken.balanceOf(RECEIVER) - receiverBalanceBefore, expectedAmountWithdrawn, "RECEIVER balance");
        assertEq(
            loanToken.balanceOf(address(morpho)),
            amountSupplied - amountBorrowed - expectedAmountWithdrawn,
            "morpho balance"
        );
    }
}
