// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {MorphoCredit} from "../../../../src/MorphoCredit.sol";
import {IMorpho, Id, Market, MarketParams} from "../../../../src/interfaces/IMorpho.sol";
import {MorphoStorageLib} from "../../../../src/libraries/periphery/MorphoStorageLib.sol";
import {ProtocolConfigLib} from "../../../../src/libraries/ProtocolConfigLib.sol";
import {SharesMathLib} from "../../../../src/libraries/SharesMathLib.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {MockProtocolConfig} from "../mocks/MockProtocolConfig.sol";

contract USD3AuditRound2RemediationsTest is Setup {
    uint256 internal constant SUPPLY_SHARE_PRICE_FLOOR_RATIO = 1e15;

    event RebalanceDeferred(uint256 waUSDCAmount);

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

        deal(address(underlyingAsset), alice, 10_000_000e6);
        deal(address(underlyingAsset), bob, 10_000_000e6);

        vm.prank(alice);
        asset.approve(address(strategy), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(strategy), type(uint256).max);
    }

    function test_reportCompletesAndBurnsJuniorWhenMorphoPausedThenDeferredFundsDeploy() public {
        _setupPendingSettlementLoss(200_000e6);
        protocolConfig.setConfig(keccak256("IS_PAUSED"), 1);

        uint256 assetsBefore = strategy.totalAssets();
        uint256 backingBefore = strategy.balanceOf(address(susd3));
        uint256 suppliedBefore = usd3.suppliedWaUSDC();
        uint256 localBefore = usd3.balanceOfWaUSDC();
        uint256 deferred = _supplyGap();

        vm.expectEmit(false, false, false, true, address(usd3));
        emit RebalanceDeferred(deferred);
        vm.prank(keeper);
        (, uint256 loss) = strategy.report();

        assertGt(loss, 0, "report should recognize the settlement loss");
        assertLt(strategy.totalAssets(), assetsBefore, "report should reduce stored assets");
        assertEq(strategy.totalAssets(), usd3.nav(), "report should rebase stored assets to NAV");
        assertLt(strategy.balanceOf(address(susd3)), backingBefore, "report should burn junior-owned USD3 shares");
        assertEq(usd3.suppliedWaUSDC(), suppliedBefore, "failed optional supply should remain deferred");
        assertEq(usd3.balanceOfWaUSDC(), localBefore, "failed optional supply should remain local");

        protocolConfig.setConfig(keccak256("IS_PAUSED"), 0);
        (bool shouldTend,) = usd3.tendTrigger();
        assertTrue(shouldTend, "cleared rejection should expose the deferred deployment drift");

        vm.prank(keeper);
        strategy.tend();

        assertGt(usd3.suppliedWaUSDC(), suppliedBefore, "later tend should deploy the deferred waUSDC");
        assertLt(usd3.balanceOfWaUSDC(), localBefore, "later tend should consume local waUSDC");
    }

    function test_reportCompletesAndBurnsJuniorWhenMarketInWindDown() public {
        _setupPendingSettlementLoss(900_000e6);
        assertTrue(morpho.marketInWindDown(usd3.marketId()), "settlement should put the market in wind-down");

        uint256 assetsBefore = strategy.totalAssets();
        uint256 backingBefore = strategy.balanceOf(address(susd3));
        uint256 suppliedBefore = usd3.suppliedWaUSDC();
        uint256 localBefore = usd3.balanceOfWaUSDC();
        uint256 deferred = _supplyGap();

        vm.expectEmit(false, false, false, true, address(usd3));
        emit RebalanceDeferred(deferred);
        vm.prank(keeper);
        (, uint256 loss) = strategy.report();

        assertGt(loss, 0, "report should recognize the wind-down settlement loss");
        assertLt(strategy.totalAssets(), assetsBefore, "report should reduce stored assets");
        assertEq(strategy.totalAssets(), usd3.nav(), "report should rebase stored assets to NAV");
        assertLt(strategy.balanceOf(address(susd3)), backingBefore, "report should burn junior-owned USD3 shares");
        assertEq(usd3.suppliedWaUSDC(), suppliedBefore, "wind-down rejection should leave deployment unchanged");
        assertEq(usd3.balanceOfWaUSDC(), localBefore, "wind-down rejection should leave waUSDC local");
    }

    function test_reportCompletesAndBurnsJuniorWhenSupplySharePriceIsBelowFloor() public {
        _setupPendingSettlementLoss(200_000e6);
        _corruptSupplySharePriceBelowFloor();
        assertFalse(
            morpho.marketInWindDown(usd3.marketId()), "share-price rejection should be independent of wind-down"
        );

        uint256 assetsBefore = strategy.totalAssets();
        uint256 backingBefore = strategy.balanceOf(address(susd3));
        uint256 suppliedBefore = usd3.suppliedWaUSDC();
        uint256 localBefore = usd3.balanceOfWaUSDC();
        uint256 deferred = _supplyGap();

        vm.expectEmit(false, false, false, true, address(usd3));
        emit RebalanceDeferred(deferred);
        vm.prank(keeper);
        (, uint256 loss) = strategy.report();

        assertGt(loss, 0, "report should recognize the corrupted market-value loss");
        assertLt(strategy.totalAssets(), assetsBefore, "report should reduce stored assets");
        assertEq(strategy.totalAssets(), usd3.nav(), "report should rebase stored assets to NAV");
        assertLt(strategy.balanceOf(address(susd3)), backingBefore, "report should burn junior-owned USD3 shares");
        assertEq(usd3.suppliedWaUSDC(), suppliedBefore, "share-price rejection should leave deployment unchanged");
        assertEq(usd3.balanceOfWaUSDC(), localBefore, "share-price rejection should leave waUSDC local");
    }

    function test_cleanDepositDoesNotTripPendingLossGate() public {
        setMaxOnCredit(5_000);

        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);

        assertEq(strategy.totalAssets(), 1_000_000e6, "deposit should update stored accounting");
        assertFalse(usd3.nav() + 2 < strategy.totalAssets(), "clean deposit should not create a pending loss");
        assertApproxEqAbs(usd3.suppliedWaUSDC(), 500_000e6, 2, "clean deposit should deploy at the configured cap");
    }

    function test_cleanDepositDeploysWithPreExistingIdleUSDC() public {
        setMaxOnCredit(5_000);

        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);

        uint256 idleUSDC = 100;
        waUSDC.setPaused(true);
        deal(address(underlyingAsset), address(usd3), idleUSDC);

        vm.prank(keeper);
        strategy.report();

        assertEq(strategy.totalAssets(), usd3.nav(), "paused report should account for the idle USDC");
        assertEq(underlyingAsset.balanceOf(address(usd3)), idleUSDC, "paused report should leave USDC idle");

        waUSDC.setPaused(false);
        uint256 suppliedBefore = usd3.suppliedWaUSDC();

        vm.prank(bob);
        strategy.deposit(250_000e6, bob);

        assertGt(usd3.suppliedWaUSDC(), suppliedBefore, "clean deposit should deploy despite pre-existing idle USDC");
        assertFalse(usd3.nav() + 2 < strategy.totalAssets(), "clean deposit should not create a pending loss");
    }

    function test_largeDepositCannotMaskPendingLoss() public {
        _setupPendingSettlementLoss(200_000e6);

        address depositor = makeAddr("pendingLossDepositor");
        uint256 depositAmount = 2_000_000e6;
        uint256 suppliedBefore = usd3.suppliedWaUSDC();
        uint256 localBefore = usd3.balanceOfWaUSDC();

        deal(address(underlyingAsset), depositor, depositAmount);
        vm.prank(depositor);
        asset.approve(address(strategy), depositAmount);
        vm.prank(depositor);
        strategy.deposit(depositAmount, depositor);

        assertTrue(usd3.nav() + 2 < strategy.totalAssets(), "deposit should not erase the pre-existing loss");
        assertEq(usd3.suppliedWaUSDC(), suppliedBefore, "pending-loss deposit must not increase Morpho supply");
        assertEq(
            usd3.balanceOfWaUSDC(), localBefore + depositAmount, "pending-loss deposit should remain as local waUSDC"
        );
    }

    function test_windDownDeferredSupplyRetriesRemainTriggeredNoOps() public {
        _setupPendingSettlementLoss(900_000e6);
        assertTrue(morpho.marketInWindDown(usd3.marketId()), "settlement should put the market in wind-down");

        vm.prank(keeper);
        strategy.report();

        uint256 suppliedBefore = usd3.suppliedWaUSDC();
        uint256 localBefore = usd3.balanceOfWaUSDC();
        uint256 deferred = _supplyGap();
        assertGt(deferred, 0, "wind-down report should leave a failed supply gap");
        assertEq(strategy.totalAssets(), usd3.nav(), "report should clear the pending-loss predicate");

        for (uint256 i; i < 2; ++i) {
            (bool shouldTendBefore,) = usd3.tendTrigger();
            assertTrue(shouldTendBefore, "failed wind-down supply should keep tend triggered");

            vm.expectEmit(false, false, false, true, address(usd3));
            emit RebalanceDeferred(deferred);
            vm.prank(keeper);
            strategy.tend();

            assertEq(usd3.suppliedWaUSDC(), suppliedBefore, "caught wind-down retry should not change supply");
            assertEq(usd3.balanceOfWaUSDC(), localBefore, "caught wind-down retry should leave waUSDC local");

            (bool shouldTendAfter,) = usd3.tendTrigger();
            assertTrue(shouldTendAfter, "caught wind-down retry should leave tend triggered");
        }
    }

    function test_reportTendDeploysImmediatelyAfterRecognizingPendingLoss() public {
        _setupPendingSettlementLoss(200_000e6);

        uint256 suppliedBefore = usd3.suppliedWaUSDC();
        uint256 localBefore = usd3.balanceOfWaUSDC();
        assertTrue(usd3.nav() + 2 < strategy.totalAssets(), "setup should leave a loss pending");

        vm.prank(keeper);
        (, uint256 loss) = strategy.report();

        assertGt(loss, 0, "report should recognize the pending loss");
        assertEq(strategy.totalAssets(), usd3.nav(), "report should clear the pending-loss predicate before its tend");
        assertGt(usd3.suppliedWaUSDC(), suppliedBefore, "post-report tend should deploy in the report transaction");
        assertLt(usd3.balanceOfWaUSDC(), localBefore, "post-report tend should use local waUSDC");
    }

    function test_pendingLossTendSkipsSupplyButStillExecutesRequiredRecall() public {
        _setupPendingSettlementLoss(200_000e6);

        uint256 suppliedBefore = usd3.suppliedWaUSDC();
        uint256 localBefore = usd3.balanceOfWaUSDC();
        assertTrue(usd3.nav() + 2 < strategy.totalAssets(), "setup should leave a loss pending");
        (bool shouldSupplyTend,) = usd3.tendTrigger();

        vm.prank(keeper);
        strategy.tend();

        assertEq(usd3.suppliedWaUSDC(), suppliedBefore, "pending-loss tend must not increase supply");
        assertEq(usd3.balanceOfWaUSDC(), localBefore, "pending-loss tend must leave local waUSDC untouched");
        assertFalse(shouldSupplyTend, "pending loss should suppress a supply-only keeper signal");

        setMaxOnCredit(2_500);
        (bool shouldRecallTend,) = usd3.tendTrigger();
        assertTrue(shouldRecallTend, "pending loss must not suppress a required recall signal");

        vm.prank(keeper);
        strategy.tend();

        assertLt(usd3.suppliedWaUSDC(), suppliedBefore, "pending-loss tend should remain withdraw-enabled");
        assertGt(usd3.balanceOfWaUSDC(), localBefore, "required recall should return waUSDC locally");
    }

    function _setupPendingSettlementLoss(uint256 borrowAmount) internal {
        setMaxOnCredit(10_000);
        setMorphoDebtCap(10_000_000e6);

        vm.prank(alice);
        strategy.deposit(1_000_000e6, alice);

        createMarketDebt(borrower, borrowAmount);

        vm.prank(bob);
        strategy.deposit(200_000e6, bob);
        vm.prank(bob);
        strategy.approve(address(susd3), type(uint256).max);
        vm.prank(bob);
        susd3.deposit(200_000e6, bob);

        setMaxOnCredit(5_000);
        vm.prank(keeper);
        strategy.tend();

        MarketParams memory params = usd3.marketParams();
        vm.prank(params.creditLine);
        morpho.settleAccount(params, borrower);

        assertTrue(usd3.nav() + 2 < strategy.totalAssets(), "settlement should leave a reportable loss");
        assertGt(_supplyGap(), 0, "loss should leave local waUSDC deployable under stale accounting");
    }

    function _supplyGap() internal view returns (uint256) {
        uint256 supplied = usd3.suppliedWaUSDC();
        uint256 local = usd3.balanceOfWaUSDC();
        uint256 target = ((supplied + local) * usd3.maxOnCredit()) / 10_000;
        return target > supplied ? target - supplied : 0;
    }

    function _corruptSupplySharePriceBelowFloor() internal {
        Id id = usd3.marketId();
        Market memory state = IMorpho(address(morpho)).market(id);
        uint128 invalidShares = uint128(
            (uint256(state.totalSupplyAssets) + 1) * SUPPLY_SHARE_PRICE_FLOOR_RATIO - SharesMathLib.VIRTUAL_SHARES + 1
        );
        bytes32 slot = MorphoStorageLib.marketTotalSupplyAssetsAndSharesSlot(id);
        vm.store(address(morpho), slot, bytes32(uint256(state.totalSupplyAssets) | (uint256(invalidShares) << 128)));
    }
}
