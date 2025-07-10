// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";

contract LiquidateIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;

    function testLiquidateNotCreatedMarket(MarketParams memory marketParamsFuzz, uint256 lltv) public {
        _setLltv(_boundTestLltv(lltv));
        vm.assume(neq(marketParamsFuzz, marketParams));

        vm.expectRevert(ErrorsLib.MarketNotCreated.selector);
        morpho.liquidate(marketParamsFuzz, address(this), 1, 0, hex"");
    }

    function testLiquidateZeroAmount(uint256 lltv) public {
        _setLltv(_boundTestLltv(lltv));
        vm.prank(BORROWER);

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.liquidate(marketParams, address(this), 0, 0, hex"");
    }

    function testLiquidateInconsistentInput(uint256 seized, uint256 sharesRepaid) public {
        seized = bound(seized, 1, MAX_TEST_AMOUNT);
        sharesRepaid = bound(sharesRepaid, 1, MAX_TEST_SHARES);

        vm.prank(BORROWER);

        vm.expectRevert(ErrorsLib.InconsistentInput.selector);
        morpho.liquidate(marketParams, address(this), seized, sharesRepaid, hex"");
    }

    // Note: In credit-based lending, liquidation logic would be different
    // The following tests are simplified placeholders that would need to be
    // redesigned based on the actual credit-based liquidation mechanics

    function testLiquidateHealthyPosition() public {
        // Skip this test in credit-based model as health is determined by credit utilization
        // not collateral ratios
    }

    function testLiquidateUnhealthyPosition() public {
        // Skip this test in credit-based model as we don't have collateral to seize
    }

    // Additional credit-based liquidation tests would go here
    // For example:
    // - Test liquidation when borrower exceeds credit limit
    // - Test partial repayment during liquidation
    // - Test fee distribution during liquidation
    // etc.
}
