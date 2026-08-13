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

    function test_syncTrancheShareReportsPendingProfitAtOldRate() public {
        uint16 oldTrancheShare = 1_000;
        uint256 pendingProfit = 100_000e6;

        vm.startPrank(management);
        strategy.setPerformanceFee(oldTrancheShare);
        strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        vm.stopPrank();

        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);
        airdrop(asset, address(strategy), pendingProfit);

        uint256 storedAssetsBefore = strategy.totalAssets();
        uint256 feeSharesBefore = strategy.balanceOf(performanceFeeRecipient);
        assertGt(usd3.nav(), storedAssetsBefore, "airdrop should leave profit pending");

        protocolConfig.setConfig(ProtocolConfigLib.TRANCHE_SHARE_VARIANT, 0);
        vm.prank(keeper);
        usd3.syncTrancheShare();

        uint256 feeSharesMinted = strategy.balanceOf(performanceFeeRecipient) - feeSharesBefore;
        assertEq(strategy.totalAssets(), usd3.nav(), "sync should checkpoint pending profit");
        assertGt(feeSharesMinted, 0, "old nonzero tranche share should receive the checkpointed profit");
        assertEq(strategy.performanceFee(), 0, "sync should install the new tranche share after the checkpoint");
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
