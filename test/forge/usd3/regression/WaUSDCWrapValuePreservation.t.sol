// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "../utils/Setup.sol";
import {USD3} from "../../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../../src/usd3/sUSD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {MockWaUSDC} from "../mocks/MockWaUSDC.sol";

contract WaUSDCWrapValuePreservationTest is Setup {
    USD3 internal usd3;
    MockWaUSDC internal wrapper;
    ITokenizedStrategy internal tokenized;

    address internal alice = makeAddr("alice");

    uint256 internal constant RAY = 1e27;
    uint256 internal constant STATIC_PRICE = 1_178_000;
    uint256 internal constant REALISTIC_RATE = 1_178_000_000_000_000_000_000_000_019;

    function setUp() public override {
        super.setUp();
        usd3 = USD3(address(strategy));
        wrapper = MockWaUSDC(address(waUSDC));
        tokenized = ITokenizedStrategy(address(usd3));

        deal(address(asset), alice, 20_000_000e6);
        vm.prank(alice);
        asset.approve(address(usd3), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         ROUNDING REGRESSIONS
    //////////////////////////////////////////////////////////////*/

    function test_reportMainnetTrace_zeroShareMintDoesNotDoS() public {
        wrapper.setSharePrice(STATIC_PRICE);
        _depositExactShares(5_000_000_000);

        deal(address(asset), address(usd3), asset.balanceOf(address(usd3)) + 1);

        vm.prank(keeper);
        tokenized.report();

        _assertAccounted("report must crystallize wrapping value");
    }

    function test_depositSpamCannotFreezeWithdrawals_realisticRate() public {
        wrapper.setRate(REALISTIC_RATE);
        setMaxOnCredit(0);
        _depositExactShares(5_000_000_000);

        vm.prank(keeper);
        tokenized.report();

        for (uint256 i; i < 50; ++i) {
            _deposit(2);

            vm.prank(keeper);
            tokenized.tend();

            assertLe(tokenized.totalAssets(), usd3.nav() + 2, "dust deposit/tend exceeded accounting slack");
            assertGt(usd3.availableWithdrawLimit(alice), 0, "dust spam froze withdrawals");
        }
    }

    function testFuzz_realisticRateDepositsPreserveSlackAndReportClearsPile(
        uint256 rayRate,
        uint256[8] memory depositAmounts
    ) public {
        rayRate = bound(rayRate, 1_150_000_000_000_000_000_000_000_000, 1_250_000_000_000_000_000_000_000_000);
        if (rayRate % 2 == 0) ++rayRate;
        wrapper.setRate(rayRate);
        setMaxOnCredit(0);
        _depositExactShares(5_000_000_000);

        vm.prank(keeper);
        tokenized.report();

        for (uint256 i; i < depositAmounts.length; ++i) {
            uint256 depositAmount = bound(depositAmounts[i], 2, 1_000_000e6);
            _deposit(depositAmount);

            vm.prank(keeper);
            tokenized.tend();

            assertLe(tokenized.totalAssets(), usd3.nav() + 2, "fuzzed deposit/tend exceeded accounting slack");
            assertGt(usd3.availableWithdrawLimit(alice), 0, "fuzzed deposit/tend froze withdrawals");
        }

        // A non-integer rate must eventually make a two-unit deposit lossy. Its deposit and tend
        // wraps are gated, leaving a wrappable pile for the deliberately ungated report path.
        for (uint256 i; i < 16 && wrapper.previewDeposit(asset.balanceOf(address(usd3))) == 0; ++i) {
            _deposit(2);

            vm.prank(keeper);
            tokenized.tend();

            assertLe(tokenized.totalAssets(), usd3.nav() + 2, "dust setup exceeded accounting slack");
            assertGt(usd3.availableWithdrawLimit(alice), 0, "dust setup froze withdrawals");
        }

        uint256 idleBeforeReport = asset.balanceOf(address(usd3));
        assertGt(wrapper.previewDeposit(idleBeforeReport), 0, "fuzz setup did not create a wrappable pile");

        vm.prank(keeper);
        tokenized.report();

        uint256 idleAfterReport = asset.balanceOf(address(usd3));
        assertLt(idleAfterReport, idleBeforeReport, "report did not consume the gated pile");
        assertEq(wrapper.previewDeposit(idleAfterReport), 0, "report left a wrappable USDC pile");
        assertLe(tokenized.totalAssets(), usd3.nav() + 2, "report left stale accounting");
    }

    /*//////////////////////////////////////////////////////////////
                              LEMMAS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_wrapRoundingLemmas(uint256 price, uint256 amount, uint256 aggregate) public {
        price = bound(price, 1e6, 3e6);
        amount = bound(amount, 0, 1e24);
        aggregate = bound(aggregate, 0, 1e24);
        wrapper.setSharePrice(price);

        uint256 shares = wrapper.previewDeposit(amount);
        uint256 cost = wrapper.previewMint(shares);
        assertLe(cost, amount, "L2: mint cost exceeds source amount");

        uint256 baseValue = wrapper.convertToAssets(aggregate);
        uint256 gain = wrapper.convertToAssets(aggregate + shares) - baseValue;
        assertLe(cost - gain, 1, "L1: wrap loss exceeds one unit");
    }

    function testFuzz_unwrapRoundingLemmas(uint256 price, uint256 amount, uint256 aggregate) public {
        price = bound(price, 1e6, 2e6);
        amount = bound(amount, 0, 1e24);
        aggregate = bound(aggregate, 0, 1e24);
        wrapper.setSharePrice(price);

        uint256 shares = wrapper.previewWithdraw(amount);
        uint256 redeemedAssets = wrapper.previewRedeem(shares);
        assertGe(redeemedAssets, amount, "U2: redeem does not cover requested withdrawal");

        uint256 remainingNav = wrapper.convertToAssets(aggregate);
        uint256 navBefore = wrapper.convertToAssets(aggregate + shares);
        uint256 marginalNav = navBefore - remainingNav;
        assertGe(marginalNav, redeemedAssets, "U3: redeem exceeds marginal NAV");
        assertLe(marginalNav - redeemedAssets, 1, "U4: unwrap loss exceeds one unit");

        uint256 navAfterWithdrawal = remainingNav + redeemedAssets - amount;
        uint256 withdrawalNavDrop = navBefore - navAfterWithdrawal;
        assertGe(withdrawalNavDrop, amount, "U5: withdrawal increased NAV");
        assertLe(withdrawalNavDrop - amount, 1, "U6: withdrawal NAV dust exceeds one unit");
    }

    /*//////////////////////////////////////////////////////////////
                        REPORT-TIME HEAL
    //////////////////////////////////////////////////////////////*/

    function test_reportWrapsLooseUSDCAndDeploys() public {
        wrapper.setSharePrice(STATIC_PRICE);
        setMaxOnCredit(10_000);

        _depositExactShares(5_000_000_000);
        uint256 suppliedBefore = usd3.suppliedWaUSDC();

        uint256 looseShares = 5_000_000_001; // Deliberately not divisible by 500.
        uint256 looseAssets = wrapper.previewMint(looseShares);
        assertEq(wrapper.previewDeposit(looseAssets), looseShares, "loose assets must map to exact whole shares");
        deal(address(asset), address(usd3), looseAssets);

        assertEq(asset.balanceOf(address(usd3)), looseAssets, "loose USDC setup failed");

        vm.prank(keeper);
        (uint256 profit,) = tokenized.report();

        assertGt(profit, 0, "report did not recognize loose USDC");
        assertEq(asset.balanceOf(address(usd3)), 0, "report did not wrap loose USDC");
        assertGt(usd3.suppliedWaUSDC(), suppliedBefore, "post-report rebalance did not deploy wrapped USDC");
        _assertAccounted("report-time wrap left stale accounting");
    }

    function test_reportWrapLossBurnsSUSD3WithoutRevert() public {
        wrapper.setSharePrice(STATIC_PRICE);
        setMaxOnCredit(10_000);
        sUSD3 subordinate = setUpSUSD3();

        uint256 assets = wrapper.previewMint(5_000_000_001);
        _deposit(assets);

        uint256 subordinateDeposit = tokenized.balanceOf(alice) / 10;
        vm.startPrank(alice);
        tokenized.approve(address(subordinate), subordinateDeposit);
        subordinate.deposit(subordinateDeposit, alice);
        vm.stopPrank();

        uint256 beforeBalance = tokenized.balanceOf(address(subordinate));
        vm.prank(keeper);
        (, uint256 loss) = tokenized.report();

        assertEq(loss, 1, "expected one-unit report loss");
        assertEq(tokenized.balanceOf(address(subordinate)), beforeBalance - 1, "sUSD3 did not absorb report loss");
        _assertAccounted("loss absorption left deficit");
    }

    function test_reportWrapLossWithZeroSUSD3BalanceDoesNotRevert() public {
        wrapper.setSharePrice(STATIC_PRICE);
        setMaxOnCredit(10_000);
        setUpSUSD3();

        _deposit(wrapper.previewMint(5_000_000_001));

        vm.prank(keeper);
        (, uint256 loss) = tokenized.report();
        assertEq(loss, 1, "expected one-unit report loss");
        _assertAccounted("zero-balance sUSD3 branch left deficit");
    }

    // Remaining defect 3: repeated unwrap/redeem rounding can temporarily cross the +2 guard.
    // It is a self-healing Low because the next report re-bases totalAssets to live NAV.
    function test_characterization_repeatedWithdrawDustSelfHealsOnReport() public {
        wrapper.setSharePrice(STATIC_PRICE);
        setMaxOnCredit(0);
        _depositExactShares(5_000_000_000);

        vm.prank(keeper);
        tokenized.report();

        uint256 withdrawals;
        while (usd3.availableWithdrawLimit(alice) > 0 && withdrawals < 32) {
            vm.prank(alice);
            tokenized.withdraw(1, alice, alice);
            ++withdrawals;
        }

        uint256 drift = tokenized.totalAssets() - usd3.nav();
        assertEq(drift, 3, "unwrap-side drift characterization changed");
        assertLt(withdrawals, 32, "withdrawal bundle did not reach the stale-NAV guard");
        assertEq(usd3.availableWithdrawLimit(alice), 0, "unwrap drift should temporarily restrict withdrawals");

        vm.prank(keeper);
        (, uint256 loss) = tokenized.report();

        assertEq(loss, drift, "report must recognize the unwrap dust");
        assertEq(tokenized.totalAssets(), usd3.nav(), "report must rebase totalAssets to NAV");
        assertGt(usd3.availableWithdrawLimit(alice), 0, "report must restore withdrawal availability");
    }

    function test_reportSucceedsUnderPausedWaUSDCWithDeployImbalance() public {
        uint256 snapshot = vm.snapshotState();
        bool overTargetSucceeded = _runPausedReportWithDeployImbalance(true);
        assertTrue(vm.revertToStateAndDelete(snapshot), "failed to restore fresh fixture");
        bool underTargetSucceeded = _runPausedReportWithDeployImbalance(false);

        assertTrue(overTargetSucceeded && underTargetSucceeded, "paused report reverted with deploy imbalance");
    }

    /*//////////////////////////////////////////////////////////////
                         FALLIBLE MINT PATHS
    //////////////////////////////////////////////////////////////*/

    function test_fallibleMintPauseModesAndMaxMintClamp() public {
        wrapper.setSharePrice(STATIC_PRICE);
        setMaxOnCredit(0);
        _depositExactShares(5_000_000_000);

        deal(address(asset), address(usd3), 100);
        wrapper.setPaused(true);
        assertGt(wrapper.maxMint(address(usd3)), 0, "wrapper pause must retain maxMint parity");

        vm.prank(keeper);
        tokenized.tend();
        vm.prank(keeper);
        tokenized.report();
        assertEq(asset.balanceOf(address(usd3)), 100, "paused mint consumed idle assets");

        wrapper.setPaused(false);
        wrapper.setReserveFrozen(true);
        assertEq(wrapper.maxMint(address(usd3)), 0, "reserve freeze must zero maxMint");
        vm.prank(keeper);
        tokenized.tend();
        vm.prank(keeper);
        tokenized.report();
        assertEq(asset.balanceOf(address(usd3)), 100, "reserve-frozen mint consumed idle assets");

        wrapper.setReserveFrozen(false);
        wrapper.setMaxMintOverride(10);
        // Fund the clamped wrap's one-unit rounding cost so the slack gate permits it.
        deal(address(asset), address(usd3), asset.balanceOf(address(usd3)) + 1);
        uint256 sharesBefore = wrapper.balanceOf(address(usd3));
        uint256 idleBefore = asset.balanceOf(address(usd3));
        uint256 expectedCost = wrapper.previewMint(10);

        vm.prank(keeper);
        tokenized.tend();

        assertEq(wrapper.balanceOf(address(usd3)), sharesBefore + 10, "maxMint clamp was not respected");
        assertEq(asset.balanceOf(address(usd3)), idleBefore - expectedCost, "partial wrap pulled wrong cost");
    }

    /*//////////////////////////////////////////////////////////////
                            MOCK PARITY
    //////////////////////////////////////////////////////////////*/

    function test_freshEtchedMockUsesRayFallbackAtOneToOne() public view {
        uint256 amount = 123_456_789;
        assertEq(wrapper.effectiveRate(), RAY, "etched mock rate fallback not initialized");
        assertEq(wrapper.convertToAssets(amount), amount, "one-to-one asset conversion changed");
        assertEq(wrapper.convertToShares(amount), amount, "one-to-one share conversion changed");
    }

    function test_mockZeroShareParity() public {
        wrapper.setSharePrice(STATIC_PRICE);
        deal(address(asset), address(this), 2);
        asset.approve(address(wrapper), 2);

        vm.expectRevert(MockWaUSDC.StaticATokenInvalidZeroShares.selector);
        wrapper.deposit(1, address(this));

        vm.expectRevert(MockWaUSDC.StaticATokenInvalidZeroShares.selector);
        wrapper.mint(0, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(uint256 assets) internal returns (uint256 shares) {
        vm.prank(alice);
        shares = tokenized.deposit(assets, alice);
    }

    function _depositExactShares(uint256 waShares) internal returns (uint256 assets) {
        assets = wrapper.previewMint(waShares);
        assertEq(wrapper.previewDeposit(assets), waShares, "amount does not mint exact waUSDC shares");
        _deposit(assets);
    }

    function _runPausedReportWithDeployImbalance(bool overTarget) internal returns (bool reportSucceeded) {
        sUSD3 subordinate = setUpSUSD3();
        setMaxOnCredit(overTarget ? 10_000 : 0);
        _deposit(10_000e6);

        uint256 subordinateDeposit = tokenized.balanceOf(alice) / 10;
        vm.startPrank(alice);
        tokenized.approve(address(subordinate), subordinateDeposit);
        subordinate.deposit(subordinateDeposit, alice);
        vm.stopPrank();

        if (overTarget) {
            assertGt(usd3.suppliedWaUSDC(), 0, "over-target setup requires deployed waUSDC");
            setMaxOnCredit(0);
        } else {
            assertGt(wrapper.balanceOf(address(usd3)), 0, "under-target setup requires local waUSDC");
            setMaxOnCredit(10_000);
        }

        wrapper.setSharePrice(990_000);
        uint256 expectedNav = usd3.nav();
        uint256 reportedAssetsBefore = tokenized.totalAssets();
        uint256 subordinateBalanceBefore = tokenized.balanceOf(address(subordinate));
        uint256 suppliedBefore = usd3.suppliedWaUSDC();
        uint256 localBefore = wrapper.balanceOf(address(usd3));
        assertLt(expectedNav, reportedAssetsBefore, "loss setup failed");

        (bool shouldTendBeforePause,) = usd3.tendTrigger();
        assertTrue(shouldTendBeforePause, "deploy imbalance should trigger tend before pause");

        wrapper.setPaused(true);
        (bool shouldTendWhilePaused,) = usd3.tendTrigger();
        assertFalse(shouldTendWhilePaused, "paused waUSDC should suppress tend trigger");

        vm.prank(keeper);
        bytes memory returnData;
        (reportSucceeded, returnData) = address(tokenized).call(abi.encodeCall(ITokenizedStrategy.report, ()));
        if (!reportSucceeded) return false;

        (, uint256 loss) = abi.decode(returnData, (uint256, uint256));
        assertGt(loss, 0, "report did not realize the loss");
        assertEq(tokenized.totalAssets(), expectedNav, "report did not rebase totalAssets to nav");
        assertEq(tokenized.totalAssets(), usd3.nav(), "post-report accounting is stale");
        assertLt(tokenized.balanceOf(address(subordinate)), subordinateBalanceBefore, "sUSD3 did not absorb the loss");
        assertEq(usd3.suppliedWaUSDC(), suppliedBefore, "paused report moved deployed waUSDC");
        assertEq(wrapper.balanceOf(address(usd3)), localBefore, "paused report moved local waUSDC");
    }

    function _assertAccounted(string memory reason) internal view {
        assertLe(tokenized.totalAssets(), usd3.nav(), reason);
    }
}
