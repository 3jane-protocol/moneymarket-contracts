// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";

contract USD3AuditRound3RemediationsTest is Setup {
    USD3 internal usd3;
    sUSD3 internal susd3;
    MorphoCredit internal morpho;
    MockProtocolConfig internal protocolConfig;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal borrower = makeAddr("borrower");

    function setUp() public override {
        super.setUp();

        usd3 = USD3(address(strategy));
        morpho = MorphoCredit(address(usd3.morphoCredit()));
        protocolConfig = MockProtocolConfig(morpho.protocolConfig());
        susd3 = setUpSUSD3();

        protocolConfig.setConfig(ProtocolConfigLib.TRANCHE_RATIO, 10_000);
        protocolConfig.setConfig(ProtocolConfigLib.SUSD3_LOCK_DURATION, 0);
        protocolConfig.setConfig(ProtocolConfigLib.SUSD3_COOLDOWN_PERIOD, 0);
        protocolConfig.setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);

        deal(address(underlyingAsset), alice, 1_000_000e6);
        deal(address(underlyingAsset), bob, 200_000e6);

        vm.prank(alice);
        asset.approve(address(strategy), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(strategy), type(uint256).max);
    }

    function test_sUSD3DepositsCloseWhileUSD3LossIsPending() public {
        setMaxOnCredit(10_000);

        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);

        createMarketDebt(borrower, 200_000e6);

        vm.prank(bob);
        strategy.deposit(200_000e6, bob);
        vm.prank(bob);
        strategy.approve(address(susd3), type(uint256).max);
        vm.prank(bob);
        susd3.deposit(200_000e6, bob);

        MarketParams memory params = usd3.marketParams();
        vm.prank(params.creditLine);
        morpho.settleAccount(params, borrower);

        assertTrue(usd3.nav() + 2 < strategy.totalAssets(), "settlement should leave a USD3 loss pending");
        assertEq(
            strategy.balanceOf(address(susd3)),
            ITokenizedStrategy(address(susd3)).totalAssets(),
            "sUSD3-local accounting should remain synchronized"
        );
        assertEq(susd3.availableDepositLimit(alice), 0, "pending USD3 loss should close sUSD3 deposits");
        assertEq(ITokenizedStrategy(address(susd3)).maxDeposit(alice), 0, "maxDeposit should be zero");
        assertEq(ITokenizedStrategy(address(susd3)).maxMint(alice), 0, "maxMint should be zero");

        vm.startPrank(alice);
        strategy.approve(address(susd3), type(uint256).max);
        vm.expectRevert(bytes("ERC4626: deposit more than max"));
        susd3.deposit(1e6, alice);
        vm.expectRevert(bytes("ERC4626: mint more than max"));
        susd3.mint(1e6, alice);
        vm.stopPrank();
    }
}
