// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";

contract SetCreditLineIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    function testSetCreditLineWithCreatedMarketWrongCreditLine() public {
        vm.expectRevert(bytes(ErrorsLib.NOT_CREDIT_LINE));
        vm.prank(address(1));
        IMorphoCredit(morphoAddress).setCreditLine(marketParams.id(), address(0), 10, 0);
    }

    function testSetCreditLineWithCreatedMarket() public {
        Id marketParamsId = marketParams.id();

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetCreditLine(marketParamsId, address(1), 100);
        vm.prank(marketParams.creditLine);
        IMorphoCredit(morphoAddress).setCreditLine(marketParams.id(), address(1), 100, 0);

        assertEq(morpho.collateral(marketParamsId, address(1)), 100, "collateral != credit");
    }
}
