// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";

contract USD3AuditRound3FeeAndUnlockTest is Setup {
    USD3 internal usd3;
    MorphoCredit internal morpho;
    MockProtocolConfig internal protocolConfig;

    address internal alice = makeAddr("alice");
    address internal borrower = makeAddr("borrower");

    function setUp() public override {
        super.setUp();

        usd3 = USD3(address(strategy));
        morpho = MorphoCredit(address(usd3.morphoCredit()));
        protocolConfig = MockProtocolConfig(morpho.protocolConfig());

        deal(address(underlyingAsset), alice, 2_000_000e6);
        vm.prank(alice);
        asset.approve(address(strategy), type(uint256).max);
    }

    function test_zeroProfitUnlockRevertsWhileLossIsPending() public {
        setMaxOnCredit(10_000);

        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);

        airdrop(asset, address(strategy), 100_000e6);
        vm.prank(keeper);
        strategy.report();
        assertGt(strategy.balanceOf(address(strategy)), 0, "profit report should create locked shares");

        createMarketDebt(borrower, 200_000e6);
        MarketParams memory params = usd3.marketParams();
        vm.prank(params.creditLine);
        morpho.settleAccount(params, borrower);

        assertTrue(usd3.nav() + 2 < strategy.totalAssets(), "settlement should leave a reportable loss");
        assertGt(strategy.balanceOf(address(strategy)), 0, "locked profit should remain available to absorb the loss");

        vm.expectRevert(bytes("!loss"));
        vm.prank(management);
        strategy.setProfitMaxUnlockTime(0);
    }
}
