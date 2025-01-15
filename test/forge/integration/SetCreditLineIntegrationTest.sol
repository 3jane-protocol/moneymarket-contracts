// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";

contract SetCreditLineIntegrationTest is BaseTest {
    using MathLib for uint256;
    using MorphoLib for IMorpho;
    using MarketParamsLib for MarketParams;

    function testSetCreditLineWithNotCreatedMarket(MarketParams memory marketParamsFuzz) public {
        vm.assume(morpho.lastUpdate(marketParams.id()) == 0);

        vm.expectRevert(bytes(ErrorsLib.NOT_CREDIT_LINE));
        vm.prank(address(creditLine));
        IMorphoCredit(morphoAddress).setCreditLine(marketParamsFuzz, address(0), 10);
    }

    function testSetCreditLineWithCreatedMarketWrongCreditLine(MarketParams memory marketParamsFuzz) public {
        marketParamsFuzz.irm = address(irm);
        marketParamsFuzz.lltv = _boundValidLltv(marketParamsFuzz.lltv);

        vm.startPrank(OWNER);
        if (!morpho.isLltvEnabled(marketParamsFuzz.lltv)) morpho.enableLltv(marketParamsFuzz.lltv);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.CreateMarket(marketParamsFuzz.id(), marketParamsFuzz);
        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);

        vm.expectRevert(bytes(ErrorsLib.NOT_CREDIT_LINE));
        vm.prank(address(1));
        IMorphoCredit(morphoAddress).setCreditLine(marketParamsFuzz, address(0), 10);
    }

    function testSetCreditLineWithCreatedMarket(MarketParams memory marketParamsFuzz) public {
        marketParamsFuzz.irm = address(irm);
        marketParamsFuzz.lltv = _boundValidLltv(marketParamsFuzz.lltv);
        Id marketParamsFuzzId = marketParamsFuzz.id();

        vm.startPrank(OWNER);
        if (!morpho.isLltvEnabled(marketParamsFuzz.lltv)) morpho.enableLltv(marketParamsFuzz.lltv);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.CreateMarket(marketParamsFuzz.id(), marketParamsFuzz);
        vm.prank(OWNER);
        morpho.createMarket(marketParamsFuzz);

        vm.expectEmit(true, true, true, true, address(morpho));
        emit EventsLib.SetCreditLine(marketParamsFuzz.id(), address(1), 100);
        vm.prank(marketParamsFuzz.creditLine);
        IMorphoCredit(morphoAddress).setCreditLine(marketParamsFuzz, address(0), 10);

        assertEq(morpho.collateral(marketParamsFuzzId, address(1)), 100, "collateral != credit");
    }
}
