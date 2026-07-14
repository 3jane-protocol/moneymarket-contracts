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

    uint256 internal constant STATIC_PRICE = 1_178_000;

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
                         PRE-FIX REPRODUCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_reportMainnetTrace_zeroShareMintDoesNotDoS() public {
        wrapper.setSharePrice(STATIC_PRICE);
        _depositExactShares(5_000_000_000);

        deal(address(asset), address(usd3), asset.balanceOf(address(usd3)) + 1);

        vm.prank(keeper);
        tokenized.report();

        _assertAccounted("report must crystallize wrapping value");
    }

    function test_depositSpamCannotFreezeWithdrawals() public {
        wrapper.setSharePrice(STATIC_PRICE);
        setMaxOnCredit(0);
        _depositExactShares(5_000_000_000);

        vm.prank(keeper);
        tokenized.report();

        for (uint256 i; i < 50; ++i) {
            vm.prank(alice);
            tokenized.deposit(2, alice);

            vm.prank(keeper);
            tokenized.tend();

            _assertAccounted("dust deposit/tend must not create deficit");
            assertGt(usd3.availableWithdrawLimit(alice), 0, "dust spam froze withdrawals");
        }
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

    /*//////////////////////////////////////////////////////////////
                        REPORT-TIME HEAL
    //////////////////////////////////////////////////////////////*/

    function test_staticPriceReportHealsFreshVaultPileAndDeploys() public {
        wrapper.setSharePrice(STATIC_PRICE);
        setMaxOnCredit(10_000);

        uint256 shares = 5_000_000_001; // Non-zero mock carry; deliberately not divisible by 500.
        uint256 assets = wrapper.previewMint(shares);
        _deposit(assets);

        assertEq(wrapper.balanceOf(address(usd3)), 0, "fresh lossy wrap should wait for report");
        assertEq(asset.balanceOf(address(usd3)), assets, "fresh pile should stay idle");

        vm.prank(keeper);
        (, uint256 loss) = tokenized.report();

        assertEq(loss, 1, "report must crystallize the wrap loss");
        assertEq(asset.balanceOf(address(usd3)), 0, "report did not clear the wrappable pile");
        assertGt(usd3.suppliedWaUSDC(), 0, "post-report rebalance did not deploy");
        _assertAccounted("report bootstrap left stale accounting");
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
        // Donate one unit of live slack so the clamped wrap's one-unit loss is funded.
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

    function _assertAccounted(string memory reason) internal view {
        assertLe(tokenized.totalAssets(), usd3.nav(), reason);
    }
}
