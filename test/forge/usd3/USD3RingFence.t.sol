// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {sUSD3} from "../../../src/usd3/sUSD3.sol";
import {MockProtocolConfig} from "./mocks/MockProtocolConfig.sol";
import {IMorphoCredit} from "../../../src/interfaces/IMorpho.sol";
import {ProtocolConfigLib} from "../../../src/libraries/ProtocolConfigLib.sol";
import {IERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract RingFenceConduit {
    USD3 public immutable usd3;
    IERC20 public immutable asset;

    constructor(USD3 _usd3) {
        usd3 = _usd3;
        asset = IERC20(ITokenizedStrategy(address(_usd3)).asset());
    }

    function depositSelf(uint256 assets) external returns (uint256 shares) {
        asset.approve(address(usd3), assets);
        return usd3.deposit(assets, address(this));
    }

    function depositMax() external returns (uint256 shares) {
        asset.approve(address(usd3), type(uint256).max);
        return usd3.deposit(type(uint256).max, address(this));
    }

    function mintSelf(uint256 shares) external returns (uint256 assets) {
        asset.approve(address(usd3), type(uint256).max);
        return usd3.mint(shares, address(this));
    }

    function depositTo(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.approve(address(usd3), assets);
        return usd3.deposit(assets, receiver);
    }

    function withdrawSelf(uint256 assets) external returns (uint256 shares) {
        return usd3.withdraw(assets, address(this), address(this));
    }
}

contract USD3RingFenceTest is Setup {
    event RingFenceConduitUpdated(address indexed conduit, bool enabled);
    event RingFencedLiquidityIncreased(address indexed conduit, uint256 assets, uint256 newTotal);
    event RingFenceReleased(uint256 assets, uint256 newTotal);

    USD3 public usd3Strategy;
    MockProtocolConfig public protocolConfig;
    RingFenceConduit public conduit;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public nonManagement = makeAddr("nonManagement");

    uint256 internal constant SMALL_AMOUNT = 50_000e6;
    uint256 internal constant MEDIUM_AMOUNT = 100_000e6;
    uint256 internal constant LARGE_AMOUNT = 1_000_000e6;
    uint256 internal constant BPS = 10_000;

    function setUp() public override {
        super.setUp();

        usd3Strategy = USD3(address(strategy));
        protocolConfig = MockProtocolConfig(IMorphoCredit(address(usd3Strategy.morphoCredit())).protocolConfig());
        conduit = new RingFenceConduit(usd3Strategy);

        deal(address(underlyingAsset), alice, 10_000_000e6);
        deal(address(underlyingAsset), bob, 10_000_000e6);
        deal(address(underlyingAsset), address(conduit), 10_000_000e6);

        vm.prank(alice);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);
        vm.prank(bob);
        underlyingAsset.approve(address(usd3Strategy), type(uint256).max);
    }

    function test_conduitSelfDepositIncrementsFenceAndEmits() public {
        vm.prank(management);
        usd3Strategy.setRingFenceConduit(address(conduit), true);

        vm.expectEmit(true, false, false, true, address(usd3Strategy));
        emit RingFencedLiquidityIncreased(address(conduit), MEDIUM_AMOUNT, MEDIUM_AMOUNT);
        conduit.depositSelf(MEDIUM_AMOUNT);

        assertEq(usd3Strategy.ringFencedLiquidity(), MEDIUM_AMOUNT, "fence incremented");
    }

    function test_conduitSelfMintIncrementsByReturnedAssets() public {
        vm.prank(management);
        usd3Strategy.setRingFenceConduit(address(conduit), true);

        uint256 shares = 75_000e6;
        uint256 expectedAssets = ITokenizedStrategy(address(usd3Strategy)).previewMint(shares);

        vm.expectEmit(true, false, false, true, address(usd3Strategy));
        emit RingFencedLiquidityIncreased(address(conduit), expectedAssets, expectedAssets);
        uint256 assets = conduit.mintSelf(shares);

        assertEq(assets, expectedAssets, "mint assets");
        assertEq(usd3Strategy.ringFencedLiquidity(), expectedAssets, "fence incremented");
    }

    function test_conduitDepositMaxIncrementsByConvertedShares() public {
        vm.prank(management);
        usd3Strategy.setRingFenceConduit(address(conduit), true);

        // Drift PPS above 1.0 so the sentinel path's convertToAssets fallback is exercised off the trivial
        // exchange rate: the fence must record the floor-converted value of the minted shares, which can
        // under-state the deposited balance by rounding but never exceed it.
        _depositFor(alice, MEDIUM_AMOUNT);
        airdrop(underlyingAsset, address(usd3Strategy), MEDIUM_AMOUNT / 10);
        vm.prank(keeper);
        ITokenizedStrategy(address(usd3Strategy)).report();

        uint256 balance = 321_000e6;
        deal(address(underlyingAsset), address(conduit), balance);

        uint256 shares = conduit.depositMax();
        uint256 expectedFence = ITokenizedStrategy(address(usd3Strategy)).convertToAssets(shares);

        assertEq(usd3Strategy.ringFencedLiquidity(), expectedFence, "fence matches floor-converted shares");
        assertLe(expectedFence, balance, "sentinel path never over-fences");
        assertApproxEqAbs(expectedFence, balance, balance / 1000, "under-fencing bounded to rounding");
    }

    function test_nonConduitAndThirdPartyDepositsDoNotIncrement() public {
        vm.prank(management);
        usd3Strategy.setRingFenceConduit(address(conduit), true);

        vm.prank(alice);
        usd3Strategy.deposit(MEDIUM_AMOUNT, alice);
        assertEq(usd3Strategy.ringFencedLiquidity(), 0, "ordinary public deposit");

        RingFenceConduit unlistedConduit = new RingFenceConduit(usd3Strategy);
        deal(address(underlyingAsset), address(unlistedConduit), MEDIUM_AMOUNT);
        unlistedConduit.depositSelf(MEDIUM_AMOUNT);
        assertEq(usd3Strategy.ringFencedLiquidity(), 0, "non-conduit self-deposit");

        vm.prank(alice);
        usd3Strategy.deposit(SMALL_AMOUNT, address(conduit));
        assertEq(usd3Strategy.ringFencedLiquidity(), 0, "third-party deposit to conduit");

        conduit.depositTo(SMALL_AMOUNT, bob);
        assertEq(usd3Strategy.ringFencedLiquidity(), 0, "conduit sender to different receiver");
    }

    function test_availableWithdrawLimitSubtractsFenceAndFeedsMaxWithdrawRedeem() public {
        _depositFor(alice, LARGE_AMOUNT);
        _enableConduitAndDeposit(MEDIUM_AMOUNT);

        uint256 expectedLimit = LARGE_AMOUNT;
        assertEq(usd3Strategy.availableWithdrawLimit(alice), expectedLimit, "limit subtracts fence");
        assertEq(ITokenizedStrategy(address(usd3Strategy)).maxWithdraw(alice), expectedLimit, "maxWithdraw");
        assertEq(ITokenizedStrategy(address(usd3Strategy)).maxRedeem(alice), expectedLimit, "maxRedeem");
    }

    function test_availableWithdrawLimitComposesWithNominalAndBpsFloors() public {
        _depositFor(alice, LARGE_AMOUNT);
        _enableConduitAndDeposit(MEDIUM_AMOUNT);

        _setConfig(ProtocolConfigLib.USD3_REDEMPTION_FLOOR, 25_000e6);
        assertEq(usd3Strategy.availableWithdrawLimit(alice), LARGE_AMOUNT, "fence binds");

        _setConfig(ProtocolConfigLib.USD3_REDEMPTION_FLOOR, 300_000e6);
        assertEq(usd3Strategy.availableWithdrawLimit(alice), 800_000e6, "nominal floor binds");

        _setConfig(ProtocolConfigLib.USD3_REDEMPTION_FLOOR, 0);
        _setConfig(ProtocolConfigLib.USD3_REDEMPTION_FLOOR_BPS, 5_000);
        assertEq(usd3Strategy.availableWithdrawLimit(alice), 550_000e6, "bps floor binds");
    }

    function test_releaseRingFenceAccessControlOverReleaseAndLimitRestoration() public {
        _depositFor(alice, LARGE_AMOUNT);
        _enableConduitAndDeposit(MEDIUM_AMOUNT);

        uint256 beforeRelease = usd3Strategy.availableWithdrawLimit(alice);

        vm.prank(nonManagement);
        vm.expectRevert();
        usd3Strategy.releaseRingFence(1);

        vm.prank(management);
        vm.expectRevert(bytes("!fence"));
        usd3Strategy.releaseRingFence(MEDIUM_AMOUNT + 1);

        vm.expectEmit(false, false, false, true, address(usd3Strategy));
        emit RingFenceReleased(40_000e6, 60_000e6);
        vm.prank(management);
        usd3Strategy.releaseRingFence(40_000e6);

        assertEq(usd3Strategy.ringFencedLiquidity(), 60_000e6, "partial release");
        assertEq(usd3Strategy.availableWithdrawLimit(alice), beforeRelease + 40_000e6, "limit restored");
    }

    function test_conduitDepositWithdrawCycleDoesNotReleaseFence() public {
        _depositFor(alice, MEDIUM_AMOUNT);
        _enableConduitAndDeposit(SMALL_AMOUNT);

        conduit.withdrawSelf(SMALL_AMOUNT);

        assertEq(usd3Strategy.ringFencedLiquidity(), SMALL_AMOUNT, "withdraw does not release fence");
    }

    function test_shutdownBypassesRingFence() public {
        _enableConduitAndDeposit(MEDIUM_AMOUNT);
        assertEq(usd3Strategy.availableWithdrawLimit(address(conduit)), 0, "fence blocks before shutdown");

        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();

        assertEq(usd3Strategy.availableWithdrawLimit(address(conduit)), MEDIUM_AMOUNT, "shutdown bypasses fence");
    }

    function test_lossSaturationClampsLimitAndErc4626Views() public {
        _depositFor(alice, MEDIUM_AMOUNT);
        _enableConduitAndDeposit(MEDIUM_AMOUNT);

        // Draw strictly more than the non-fenced liquidity so the fence exceeds what remains: the
        // subtraction must saturate to zero rather than underflow (a checked subtraction would panic here).
        createMarketDebt(makeAddr("ring-fence-borrower"), MEDIUM_AMOUNT + MEDIUM_AMOUNT / 2);

        assertEq(usd3Strategy.availableWithdrawLimit(alice), 0, "saturates to zero");
        assertEq(ITokenizedStrategy(address(usd3Strategy)).maxWithdraw(alice), 0, "maxWithdraw clamps");
        assertEq(ITokenizedStrategy(address(usd3Strategy)).maxRedeem(alice), 0, "maxRedeem clamps");
    }

    function test_sUSD3SecondLegBlockedByFenceAndUnblockedByRelease() public {
        _setConfig(keccak256("SUSD3_LOCK_DURATION"), 0);
        _setConfig(keccak256("SUSD3_COOLDOWN_PERIOD"), 0);
        _setConfig(ProtocolConfigLib.MIN_SUSD3_BACKING_RATIO, 0);
        _setConfig(ProtocolConfigLib.SUSD3_NOMINAL_BACKING_FLOOR, 0);

        sUSD3 susd3Strategy = _deploySUSD3();

        _depositFor(alice, SMALL_AMOUNT);
        vm.startPrank(alice);
        IERC20(address(usd3Strategy)).approve(address(susd3Strategy), SMALL_AMOUNT);
        susd3Strategy.deposit(SMALL_AMOUNT, alice);
        vm.stopPrank();

        _enableConduitAndDeposit(200_000e6);
        createMarketDebt(makeAddr("second-leg-borrower"), SMALL_AMOUNT);

        vm.prank(alice);
        susd3Strategy.withdraw(SMALL_AMOUNT, alice, alice);

        assertEq(usd3Strategy.availableWithdrawLimit(alice), 0, "USD3 second leg clamped");

        vm.prank(alice);
        vm.expectRevert();
        usd3Strategy.redeem(SMALL_AMOUNT, alice, alice);

        vm.prank(management);
        usd3Strategy.releaseRingFence(SMALL_AMOUNT);

        vm.prank(alice);
        uint256 withdrawn = usd3Strategy.redeem(SMALL_AMOUNT, alice, alice);
        assertEq(withdrawn, SMALL_AMOUNT, "USD3 second leg unblocked");
    }

    function test_setRingFenceConduitAccessControlAndEvent() public {
        vm.prank(nonManagement);
        vm.expectRevert();
        usd3Strategy.setRingFenceConduit(address(conduit), true);

        vm.expectEmit(true, false, false, true, address(usd3Strategy));
        emit RingFenceConduitUpdated(address(conduit), true);
        vm.prank(management);
        usd3Strategy.setRingFenceConduit(address(conduit), true);

        assertTrue(usd3Strategy.ringFenceConduit(address(conduit)), "conduit enabled");

        vm.expectEmit(true, false, false, true, address(usd3Strategy));
        emit RingFenceConduitUpdated(address(conduit), false);
        vm.prank(management);
        usd3Strategy.setRingFenceConduit(address(conduit), false);

        assertFalse(usd3Strategy.ringFenceConduit(address(conduit)), "conduit disabled");
    }

    function _depositFor(address receiver, uint256 assets) internal {
        vm.prank(receiver);
        usd3Strategy.deposit(assets, receiver);
    }

    function _enableConduitAndDeposit(uint256 assets) internal {
        vm.prank(management);
        usd3Strategy.setRingFenceConduit(address(conduit), true);
        conduit.depositSelf(assets);
    }

    function _setConfig(bytes32 key, uint256 value) internal {
        vm.prank(protocolConfig.owner());
        protocolConfig.setConfig(key, value);
    }

    function _deploySUSD3() internal returns (sUSD3 susd3Strategy) {
        sUSD3 implementation = new sUSD3();
        ProxyAdmin proxyAdmin = new ProxyAdmin(management);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            abi.encodeCall(sUSD3.initialize, (address(usd3Strategy), management, keeper))
        );
        susd3Strategy = sUSD3(address(proxy));

        vm.prank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));
    }
}
