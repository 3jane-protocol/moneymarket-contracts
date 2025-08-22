// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {CreditLineMock} from "../../../src/mocks/CreditLineMock.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";

/// @title SettlementResetTest
/// @notice Regression test for Sherlock audit issue #15: Settlement doesn't reset borrowerPremium
contract SettlementResetTest is BaseTest {
    using MarketParamsLib for MarketParams;

    CreditLineMock creditLine;
    IMorphoCredit morphoCredit;

    function setUp() public override {
        super.setUp();

        // Deploy credit line mock
        creditLine = new CreditLineMock(morphoAddress);
        morphoCredit = IMorphoCredit(morphoAddress);

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

        // Create market and supply liquidity
        vm.prank(OWNER);
        morpho.createMarket(marketParams);

        loanToken.setBalance(SUPPLIER, 100000e18);
        vm.startPrank(SUPPLIER);
        loanToken.approve(address(morpho), type(uint256).max);
        morpho.supply(marketParams, 100000e18, 0, SUPPLIER, "");
        vm.stopPrank();
    }

    /// @notice Test that borrowerPremium is not reset after settlement (demonstrates the bug)
    function test_BorrowerPremiumNotResetAfterSettlement() public {
        uint256 creditLineAmount = 10000e18;
        uint128 premiumRate = 0.1e18; // 10% APR

        // Set credit line with premium
        vm.prank(address(creditLine));
        morphoCredit.setCreditLine(id, BORROWER, creditLineAmount, premiumRate);

        // Borrow
        vm.prank(BORROWER);
        morpho.borrow(marketParams, 5000e18, 0, BORROWER, BORROWER);

        // Verify premium is set before settlement
        (uint128 timestampBefore, uint128 rateBefore, uint128 borrowAssetsBefore) =
            morphoCredit.borrowerPremium(id, BORROWER);
        assertGt(timestampBefore, 0, "Timestamp should be set before settlement");
        assertEq(rateBefore, premiumRate, "Rate should be set before settlement");
        assertGt(borrowAssetsBefore, 0, "Borrow assets should be set before settlement");

        // Settle account
        vm.prank(address(creditLine));
        morphoCredit.settleAccount(marketParams, BORROWER);

        // Check if premium is reset after settlement
        (uint128 timestampAfter, uint128 rateAfter, uint128 borrowAssetsAfter) =
            morphoCredit.borrowerPremium(id, BORROWER);

        // Demonstrate the bug: these values should be 0 but aren't
        if (timestampAfter != 0) {
            emit log_string("BUG FOUND: Premium timestamp not reset after settlement");
            emit log_named_uint("Timestamp still", timestampAfter);
        }

        if (rateAfter != 0) {
            emit log_string("BUG FOUND: Premium rate not reset after settlement");
            emit log_named_uint("Rate still", rateAfter);
        }

        if (borrowAssetsAfter != 0) {
            emit log_string("BUG FOUND: Borrow assets not reset after settlement");
            emit log_named_uint("BorrowAssets still", borrowAssetsAfter);
        }

        // Also check that borrow shares were properly cleared
        Position memory pos = morpho.position(id, BORROWER);
        assertEq(pos.borrowShares, 0, "Borrow shares should be zero after settlement");
    }
}
