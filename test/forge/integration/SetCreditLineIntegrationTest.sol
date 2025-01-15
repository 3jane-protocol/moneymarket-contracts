// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";

contract SetCreditLineIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    function testSetCreditLineWithCreatedMarketWrongCreditLine(MarketParams memory marketParamsFuzz) public {
        marketParamsFuzz.creditLine = address(1);
        morpho.createMarket(marketParamsFuzz);

        vm.prank(address(2));
        IMorphoCredit(morphoAddress).setCreditLine(marketParamsFuzz, address(0), 10);
    }

    function testSetCreditLineWithCreatedMarket(MarketParams memory marketParamsFuzz) public {
        Id marketParamsFuzzId = marketParamsFuzz.id();

        morpho.createMarket(marketParamsFuzz);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetCreditLine(marketParamsFuzz.id(), address(1), 100);
        vm.prank(marketParamsFuzz.creditLine);
        IMorphoCredit(morphoAddress).setCreditLine(marketParamsFuzz, address(0), 10);

        assertEq(morpho.collateral(marketParamsFuzzId, address(1)), 100, "collateral != credit");
    }
}
