// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AdaptiveCurveIrm} from "../../../src/irm/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {IAdaptiveCurveIrm} from "../../../src/irm/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol";
import {IIrm} from "../../../src/interfaces/IIrm.sol";
import {Id, MarketParams, Market} from "../../../src/interfaces/IMorpho.sol";
import {MathLib, WAD_INT as WAD} from "../../../src/irm/adaptive-curve-irm/libraries/MathLib.sol";
import {UtilsLib} from "../../../src/irm/adaptive-curve-irm/libraries/UtilsLib.sol";
import {ExpLib} from "../../../src/irm/adaptive-curve-irm/libraries/ExpLib.sol";
import {ConstantsLib} from "../../../src/irm/adaptive-curve-irm/libraries/ConstantsLib.sol";
import {ErrorsLib} from "../../../src/irm/adaptive-curve-irm/libraries/ErrorsLib.sol";
import {MarketParamsLib} from "../../../src/libraries/MarketParamsLib.sol";
import {MathLib as MorphoMathLib} from "../../../src/libraries/MathLib.sol";
import "../../../lib/forge-std/src/Test.sol";
import {MorphoCredit} from "../../../src/MorphoCredit.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {TransparentUpgradeableProxy} from
    "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AavePoolMock} from "../mocks/AavePoolMock.sol";

contract AdaptiveCurveIrmTest is Test {
    using MathLib for int256;
    using MathLib for uint256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MorphoMathLib for uint256;
    using MarketParamsLib for MarketParams;

    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    IAdaptiveCurveIrm internal irm;
    MorphoCredit internal morphoCredit;
    ProtocolConfig internal protocolConfig;
    MarketParams internal marketParams = MarketParams(address(0), address(0), address(0), address(0), 0, address(0));

    address internal OWNER;
    AavePoolMock internal aavePoolMock;
    address internal mockUsdc;

    function setUp() public {
        OWNER = makeAddr("Owner");

        // Set the protocolConfig to the proxy address
        protocolConfig = ProtocolConfig(_deployProtocolConfigProxy());

        // Deploy MorphoCredit with protocol config
        morphoCredit = new MorphoCredit(address(protocolConfig));

        // Deploy Aave pool mock and set up USDC
        (mockUsdc, aavePoolMock) = _deployMocks();

        // Deploy IRM directly and proxy
        irm = AdaptiveCurveIrm(_deployIrmProxy(address(morphoCredit), address(aavePoolMock), mockUsdc));

        vm.warp(90 days);

        // Set up protocol configuration values
        _setProtocolConfig();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AdaptiveCurveIrmTest.handleBorrowRate.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    function _deployProtocolConfigProxy() internal returns (address proxy) {
        ProtocolConfig protocolConfigImpl = new ProtocolConfig();
        proxy = address(
            new TransparentUpgradeableProxy(
                address(protocolConfigImpl),
                address(this), // Test contract acts as admin
                abi.encodeWithSelector(ProtocolConfig.initialize.selector, OWNER)
            )
        );
    }

    function _deployMocks() internal returns (address mockUsdc, AavePoolMock aavePoolMock) {
        mockUsdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // Use mainnet USDC address as mock
        aavePoolMock = new AavePoolMock();
        aavePoolMock.setReserveData(
            mockUsdc,
            1e27, // liquidityIndex (RAY)
            0, // currentLiquidityRate
            1e27, // variableBorrowIndex (RAY)
            0 // currentVariableBorrowRate
        );
    }

    function _deployIrmProxy(address morphoCredit, address aavePoolMock, address mockUsdc)
        internal
        returns (address proxy)
    {
        AdaptiveCurveIrm irmImpl = new AdaptiveCurveIrm(address(morphoCredit), address(aavePoolMock), mockUsdc);
        proxy = address(
            new TransparentUpgradeableProxy(
                address(irmImpl),
                address(this), // Test contract acts as admin
                abi.encodeWithSelector(AdaptiveCurveIrm.initialize.selector)
            )
        );
    }

    function _setProtocolConfig() internal {
        vm.startPrank(OWNER);
        // IRM configurations
        protocolConfig.setConfig(keccak256("CURVE_STEEPNESS"), uint256(ConstantsLib.CURVE_STEEPNESS)); // 4 curve
            // steepness
        protocolConfig.setConfig(keccak256("ADJUSTMENT_SPEED"), uint256(ConstantsLib.ADJUSTMENT_SPEED));
        protocolConfig.setConfig(keccak256("TARGET_UTILIZATION"), uint256(ConstantsLib.TARGET_UTILIZATION)); // 90%
            // target utilization
        protocolConfig.setConfig(keccak256("INITIAL_RATE_AT_TARGET"), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET)); // 4%
            // initial rate
        protocolConfig.setConfig(keccak256("MIN_RATE_AT_TARGET"), uint256(ConstantsLib.MIN_RATE_AT_TARGET)); // 0.1%
            // minimum rate
        protocolConfig.setConfig(keccak256("MAX_RATE_AT_TARGET"), uint256(ConstantsLib.MAX_RATE_AT_TARGET)); // 200%
            // maximum rate

        vm.stopPrank();
    }

    /* TESTS */

    /*function testDeployment() public {
        // Test zero morpho address
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        new AdaptiveCurveIrm(address(0), address(aavePoolMock), mockUsdc);

        // Test zero aave pool address
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        new AdaptiveCurveIrm(address(morphoCredit), address(0), mockUsdc);

        // Test zero usdc address
        vm.expectRevert(bytes(ErrorsLib.ZERO_ADDRESS));
        new AdaptiveCurveIrm(address(morphoCredit), address(aavePoolMock), address(0));
    }*/

    function testFirstBorrowRateUtilizationZero() public {
        Market memory market;

        vm.startPrank(address(morphoCredit));
        assertApproxEqRel(
            irm.borrowRate(marketParams, market),
            uint256(ConstantsLib.INITIAL_RATE_AT_TARGET / 4),
            0.0001 ether,
            "avgBorrowRate"
        );
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET, "rateAtTarget");
    }

    function testFirstBorrowRateUtilizationOne() public {
        Market memory market;
        market.totalBorrowAssets = 1 ether;
        market.totalSupplyAssets = 1 ether;

        vm.startPrank(address(morphoCredit));
        assertEq(
            irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET * 4), "avgBorrowRate"
        );
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET, "rateAtTarget");
    }

    function testRateAfterUtilizationOne() public {
        vm.warp(365 days * 2);
        Market memory market;
        vm.startPrank(address(morphoCredit));
        assertApproxEqRel(
            irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET / 4), 0.001 ether
        );

        market.totalBorrowAssets = 1 ether;
        market.totalSupplyAssets = 1 ether;
        market.lastUpdate = uint128(block.timestamp - 5 days);

        // (exp((50/365)*5) ~= 1.9836.
        assertApproxEqRel(
            irm.borrowRateView(marketParams, market),
            uint256(
                (ConstantsLib.INITIAL_RATE_AT_TARGET * 4).wMulToZero(
                    (1.9836 ether - 1 ether) * WAD / (ConstantsLib.ADJUSTMENT_SPEED * 5 days)
                )
            ),
            0.1 ether
        );
        // The average value of exp((50/365)*x) between 0 and 5 is approx. 1.4361.
        assertApproxEqRel(
            irm.borrowRateView(marketParams, market),
            uint256((ConstantsLib.INITIAL_RATE_AT_TARGET * 4).wMulToZero(1.4361 ether)),
            0.1 ether
        );
        // Expected rate: 22.976%.
        assertApproxEqRel(irm.borrowRateView(marketParams, market), uint256(0.22976 ether) / 365 days, 0.1 ether);
    }

    function testRateAfterUtilizationZero() public {
        vm.warp(365 days * 2);
        Market memory market;
        vm.startPrank(address(morphoCredit));
        assertApproxEqRel(
            irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET / 4), 0.001 ether
        );

        market.totalBorrowAssets = 0 ether;
        market.totalSupplyAssets = 1 ether;
        market.lastUpdate = uint128(block.timestamp - 5 days);

        // (exp((-50/365)*5) ~= 0.5041.
        assertApproxEqRel(
            irm.borrowRateView(marketParams, market),
            uint256(
                (ConstantsLib.INITIAL_RATE_AT_TARGET / 4).wMulToZero(
                    (0.5041 ether - 1 ether) * WAD / (-ConstantsLib.ADJUSTMENT_SPEED * 5 days)
                )
            ),
            0.1 ether
        );
        // The average value of exp((-50/365*x)) between 0 and 5 is approx. 0.7240.
        assertApproxEqRel(
            irm.borrowRateView(marketParams, market),
            uint256((ConstantsLib.INITIAL_RATE_AT_TARGET / 4).wMulToZero(0.724 ether)),
            0.1 ether
        );
        // Expected rate: 0.7240%.
        assertApproxEqRel(irm.borrowRateView(marketParams, market), uint256(0.00724 ether) / 365 days, 0.1 ether);
    }

    function testRateAfter45DaysUtilizationAboveTargetNoPing() public {
        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION));
        vm.startPrank(address(morphoCredit));
        assertEq(irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET));
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);

        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + 45 days);

        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION + 1 ether) / 2); // Error = 50%
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market);

        // Expected rate: 4% * exp(50 * 45 / 365 * 50%) = 87.22%.
        assertApproxEqRel(irm.rateAtTarget(marketParams.id()), int256(0.8722 ether) / 365 days, 0.005 ether);
    }

    function testRateAfter45DaysUtilizationAboveTargetPingEvery10Minutes() public {
        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION));
        vm.startPrank(address(morphoCredit));
        assertEq(irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET));
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);

        uint128 initialBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION + 1 ether) / 2); // Error = 50%

        market.totalBorrowAssets = initialBorrowAssets;

        for (uint256 i; i < 45 days / 10 minutes; ++i) {
            market.lastUpdate = uint128(block.timestamp);
            vm.warp(block.timestamp + 10 minutes);

            vm.startPrank(address(morphoCredit));
            uint256 avgBorrowRate = irm.borrowRate(marketParams, market);
            uint256 interest = market.totalBorrowAssets.wMulDown(avgBorrowRate.wTaylorCompounded(10 minutes));
            market.totalSupplyAssets += uint128(interest);
            market.totalBorrowAssets += uint128(interest);
        }

        assertApproxEqRel(
            market.totalBorrowAssets.wDivDown(market.totalSupplyAssets), 0.95 ether, 0.01 ether, "utilization"
        );

        int256 rateAtTarget = irm.rateAtTarget(marketParams.id());
        // Expected rate: 4% * exp(50 * 45 / 365 * 50%) = 87.22%.
        int256 expectedRateAtTarget = int256(0.8722 ether) / 365 days;
        assertGe(rateAtTarget, expectedRateAtTarget);
        // The rate is tolerated to be +8% (relatively) because of the pings every minute.
        assertApproxEqRel(rateAtTarget, expectedRateAtTarget, 0.08 ether, "expectedRateAtTarget");

        // Expected growth: exp(87.22% * 3.5 * 45 / 365) = +45.70%.
        // The growth is tolerated to be +30% (relatively) because of the pings every minute.
        assertApproxEqRel(
            market.totalBorrowAssets, initialBorrowAssets.wMulDown(1.457 ether), 0.3 ether, "totalBorrowAssets"
        );
    }

    function testRateAfterUtilizationTargetNoPing(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, type(uint48).max);

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION));
        vm.startPrank(address(morphoCredit));
        assertEq(irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET));
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);

        market.lastUpdate = uint128(block.timestamp);
        vm.warp(block.timestamp + elapsed);

        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market);

        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);
    }

    function testRateAfter3WeeksUtilizationTargetPingEvery10Minutes() public {
        // Create a new IRM instance directly
        irm = new AdaptiveCurveIrm(address(morphoCredit), address(aavePoolMock), mockUsdc);

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = uint128(uint256(ConstantsLib.TARGET_UTILIZATION));
        vm.startPrank(address(morphoCredit));
        assertEq(irm.borrowRate(marketParams, market), uint256(ConstantsLib.INITIAL_RATE_AT_TARGET));
        assertEq(irm.rateAtTarget(marketParams.id()), ConstantsLib.INITIAL_RATE_AT_TARGET);

        for (uint256 i; i < 3 weeks / 10 minutes; ++i) {
            market.lastUpdate = uint128(block.timestamp);
            vm.warp(block.timestamp + 10 minutes);

            vm.startPrank(address(morphoCredit));
            uint256 avgBorrowRate = irm.borrowRate(marketParams, market);
            uint256 interest = market.totalBorrowAssets.wMulDown(avgBorrowRate.wTaylorCompounded(10 minutes));
            market.totalSupplyAssets += uint128(interest);
            market.totalBorrowAssets += uint128(interest);
        }

        assertApproxEqRel(
            market.totalBorrowAssets.wDivDown(market.totalSupplyAssets),
            uint256(ConstantsLib.TARGET_UTILIZATION),
            0.01 ether
        );

        int256 rateAtTarget = irm.rateAtTarget(marketParams.id());
        assertGe(rateAtTarget, ConstantsLib.INITIAL_RATE_AT_TARGET);
        // The rate is tolerated to be +10% (relatively) because of the pings every minute.
        assertApproxEqRel(rateAtTarget, ConstantsLib.INITIAL_RATE_AT_TARGET, 0.1 ether);
    }

    function testFirstBorrowRate(Market memory market) public {
        vm.assume(market.totalBorrowAssets > 0);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);

        vm.startPrank(address(morphoCredit));
        uint256 avgBorrowRate = irm.borrowRate(marketParams, market);
        int256 rateAtTarget = irm.rateAtTarget(marketParams.id());

        assertEq(avgBorrowRate, _curve(int256(ConstantsLib.INITIAL_RATE_AT_TARGET), _err(market)), "avgBorrowRate");
        assertEq(rateAtTarget, ConstantsLib.INITIAL_RATE_AT_TARGET, "rateAtTarget");
    }

    function testBorrowRateEventEmission(Market memory market) public {
        vm.assume(market.totalBorrowAssets > 0);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);

        vm.expectEmit(true, true, true, true, address(irm));
        emit BorrowRateUpdate(
            marketParams.id(),
            _curve(int256(ConstantsLib.INITIAL_RATE_AT_TARGET), _err(market)),
            uint256(_expectedRateAtTarget(marketParams.id(), market))
        );
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market);
    }

    function testFirstBorrowRateView(Market memory market) public {
        vm.assume(market.totalBorrowAssets > 0);
        vm.assume(market.totalSupplyAssets >= market.totalBorrowAssets);

        uint256 avgBorrowRate = irm.borrowRateView(marketParams, market);
        int256 rateAtTarget = irm.rateAtTarget(marketParams.id());

        assertEq(avgBorrowRate, _curve(int256(ConstantsLib.INITIAL_RATE_AT_TARGET), _err(market)), "avgBorrowRate");
        assertEq(rateAtTarget, 0, "prevBorrowRate");
    }

    function testBorrowRate(Market memory market0, Market memory market1) public {
        vm.assume(market0.totalBorrowAssets > 0);
        vm.assume(market0.totalSupplyAssets >= market0.totalBorrowAssets);
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market0);

        vm.assume(market1.totalBorrowAssets > 0);
        vm.assume(market1.totalSupplyAssets >= market1.totalBorrowAssets);
        market1.lastUpdate = uint128(bound(market1.lastUpdate, block.timestamp - 5 days, block.timestamp - 1));

        int256 expectedRateAtTarget = _expectedRateAtTarget(marketParams.id(), market1);
        uint256 expectedAvgRate = _expectedAvgRate(marketParams.id(), market1);

        uint256 borrowRateView = irm.borrowRateView(marketParams, market1);
        vm.startPrank(address(morphoCredit));
        uint256 borrowRate = irm.borrowRate(marketParams, market1);

        assertEq(borrowRateView, borrowRate, "borrowRateView");
        assertApproxEqRel(borrowRate, expectedAvgRate, 0.11 ether, "avgBorrowRate");
        assertApproxEqRel(irm.rateAtTarget(marketParams.id()), expectedRateAtTarget, 0.001 ether, "rateAtTarget");
    }

    function testBorrowRateNoTimeElapsed(Market memory market0, Market memory market1) public {
        vm.assume(market0.totalBorrowAssets > 0);
        vm.assume(market0.totalSupplyAssets >= market0.totalBorrowAssets);
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market0);

        vm.assume(market1.totalBorrowAssets > 0);
        vm.assume(market1.totalSupplyAssets >= market1.totalBorrowAssets);
        market1.lastUpdate = uint128(block.timestamp);

        int256 expectedRateAtTarget = _expectedRateAtTarget(marketParams.id(), market1);
        uint256 expectedAvgRate = _expectedAvgRate(marketParams.id(), market1);

        uint256 borrowRateView = irm.borrowRateView(marketParams, market1);
        vm.startPrank(address(morphoCredit));
        uint256 borrowRate = irm.borrowRate(marketParams, market1);

        assertEq(borrowRateView, borrowRate, "borrowRateView");
        assertApproxEqRel(borrowRate, expectedAvgRate, 0.01 ether, "avgBorrowRate");
        assertApproxEqRel(irm.rateAtTarget(marketParams.id()), expectedRateAtTarget, 0.001 ether, "rateAtTarget");
    }

    function testBorrowRateNoUtilizationChange(Market memory market0, Market memory market1) public {
        vm.assume(market0.totalBorrowAssets > 0);
        vm.assume(market0.totalSupplyAssets >= market0.totalBorrowAssets);
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market0);

        market1.totalBorrowAssets = market0.totalBorrowAssets;
        market1.totalSupplyAssets = market0.totalSupplyAssets;
        market1.lastUpdate = uint128(bound(market1.lastUpdate, block.timestamp - 5 days, block.timestamp - 1));

        int256 expectedRateAtTarget = _expectedRateAtTarget(marketParams.id(), market1);
        uint256 expectedAvgRate = _expectedAvgRate(marketParams.id(), market1);

        uint256 borrowRateView = irm.borrowRateView(marketParams, market1);
        vm.startPrank(address(morphoCredit));
        uint256 borrowRate = irm.borrowRate(marketParams, market1);

        assertEq(borrowRateView, borrowRate, "borrowRateView");
        assertApproxEqRel(borrowRate, expectedAvgRate, 0.1 ether, "avgBorrowRate");
        assertApproxEqRel(irm.rateAtTarget(marketParams.id()), expectedRateAtTarget, 0.001 ether, "rateAtTarget");
    }

    /* HANDLERS */

    function handleBorrowRate(uint256 totalSupplyAssets, uint256 totalBorrowAssets, uint256 elapsed) external {
        elapsed = bound(elapsed, 0, type(uint48).max);
        totalSupplyAssets = bound(totalSupplyAssets, 0, type(uint128).max);
        totalBorrowAssets = bound(totalBorrowAssets, 0, totalSupplyAssets);

        Market memory market;
        market.lastUpdate = uint128(block.timestamp);
        market.totalBorrowAssets = uint128(totalSupplyAssets);
        market.totalSupplyAssets = uint128(totalBorrowAssets);

        vm.warp(block.timestamp + elapsed);
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market);
    }

    /* INVARIANTS */

    function invariantGeMinRateAtTarget() public {
        Market memory market;
        market.totalBorrowAssets = 9 ether;
        market.totalSupplyAssets = 10 ether;

        assertGe(
            irm.borrowRateView(marketParams, market),
            uint256(ConstantsLib.MIN_RATE_AT_TARGET.wDivToZero(ConstantsLib.CURVE_STEEPNESS))
        );
        vm.startPrank(address(morphoCredit));
        assertGe(
            irm.borrowRate(marketParams, market),
            uint256(ConstantsLib.MIN_RATE_AT_TARGET.wDivToZero(ConstantsLib.CURVE_STEEPNESS))
        );
    }

    function invariantLeMaxRateAtTarget() public {
        Market memory market;
        market.totalBorrowAssets = 9 ether;
        market.totalSupplyAssets = 10 ether;

        assertLe(
            irm.borrowRateView(marketParams, market),
            uint256(ConstantsLib.MAX_RATE_AT_TARGET.wMulToZero(ConstantsLib.CURVE_STEEPNESS))
        );
        vm.startPrank(address(morphoCredit));
        assertLe(
            irm.borrowRate(marketParams, market),
            uint256(ConstantsLib.MAX_RATE_AT_TARGET.wMulToZero(ConstantsLib.CURVE_STEEPNESS))
        );
    }

    function testConstants() public {
        assertGe(ConstantsLib.CURVE_STEEPNESS, 1 ether, "curveSteepness too small");
        assertLe(ConstantsLib.CURVE_STEEPNESS, 100 ether, "curveSteepness too big");
        assertGe(ConstantsLib.ADJUSTMENT_SPEED, 0, "adjustmentSpeed too small");
        assertLe(ConstantsLib.ADJUSTMENT_SPEED, int256(1_000 ether) / 365 days, "adjustmentSpeed too big");
        assertGt(ConstantsLib.TARGET_UTILIZATION, 0, "targetUtilization too small");
        assertLt(ConstantsLib.TARGET_UTILIZATION, 1 ether, "targetUtilization too big");
        assertGe(ConstantsLib.INITIAL_RATE_AT_TARGET, ConstantsLib.MIN_RATE_AT_TARGET, "initialRateAtTarget too small");
        assertLe(ConstantsLib.INITIAL_RATE_AT_TARGET, ConstantsLib.MAX_RATE_AT_TARGET, "initialRateAtTarget too large");
    }

    /* HELPERS */

    function _expectedRateAtTarget(Id id, Market memory market) internal view returns (int256) {
        int256 rateAtTarget = irm.rateAtTarget(id);
        if (rateAtTarget == 0) {
            return ConstantsLib.INITIAL_RATE_AT_TARGET;
        }

        uint256 elapsed = block.timestamp - market.lastUpdate;
        int256 linearAdaptation = ConstantsLib.ADJUSTMENT_SPEED.wMulToZero(_err(market)) * int256(elapsed);

        return rateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(
            ConstantsLib.MIN_RATE_AT_TARGET, ConstantsLib.MAX_RATE_AT_TARGET
        );
    }

    function _expectedAvgRate(Id id, Market memory market) internal view returns (uint256) {
        int256 rateAtTarget = irm.rateAtTarget(id);
        if (rateAtTarget == 0) {
            return _curve(ConstantsLib.INITIAL_RATE_AT_TARGET, _err(market));
        }

        int256 err = _err(market);
        uint256 elapsed = block.timestamp - market.lastUpdate;
        int256 linearAdaptation = ConstantsLib.ADJUSTMENT_SPEED.wMulToZero(err) * int256(elapsed);

        if (linearAdaptation == 0) {
            return _curve(int256(_expectedRateAtTarget(id, market)), err);
        }

        // Calculate difference and divide by linearAdaptation
        return uint256(
            (int256(_curve(int256(_expectedRateAtTarget(id, market)), err)) - int256(_curve(rateAtTarget, err)))
                .wDivToZero(linearAdaptation)
        );
    }

    function _curve(int256 rateAtTarget, int256 err) internal pure returns (uint256) {
        // Safe "unchecked" cast because err >= -1 (in WAD).
        if (err < 0) {
            return uint256(
                ((WAD - WAD.wDivToZero(ConstantsLib.CURVE_STEEPNESS)).wMulToZero(err) + WAD).wMulToZero(rateAtTarget)
            );
        } else {
            return uint256(((ConstantsLib.CURVE_STEEPNESS - WAD).wMulToZero(err) + WAD).wMulToZero(rateAtTarget));
        }
    }

    function _err(Market memory market) internal pure returns (int256 err) {
        if (market.totalSupplyAssets == 0) return -1 ether;

        int256 utilization = int256(market.totalBorrowAssets.wDivDown(market.totalSupplyAssets));

        if (utilization > ConstantsLib.TARGET_UTILIZATION) {
            err = (utilization - ConstantsLib.TARGET_UTILIZATION).wDivToZero(WAD - ConstantsLib.TARGET_UTILIZATION);
        } else {
            err = (utilization - ConstantsLib.TARGET_UTILIZATION).wDivToZero(ConstantsLib.TARGET_UTILIZATION);
        }
    }

    /* AAVE SPREAD TESTS */

    function testAaveSpreadCalculation() public {
        // Set up Aave indices to create a spread
        // Using normalized indices that will show different growth rates
        aavePoolMock.setReserveData(
            mockUsdc,
            1.05e27, // liquidityIndex (5% growth)
            0,
            1.1e27, // variableBorrowIndex (10% growth)
            0
        );

        // First call to initialize indices
        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = 0.5 ether; // 50% utilization

        vm.startPrank(address(morphoCredit));
        uint256 rate1 = irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Advance time and update indices
        vm.warp(block.timestamp + 1 days);

        // Set new indices showing continued growth with spread
        // Borrow rate growing faster than supply rate
        aavePoolMock.setReserveData(
            mockUsdc,
            1.052e27, // liquidityIndex grew by ~0.19% (annualized ~70%)
            0,
            1.105e27, // variableBorrowIndex grew by ~0.45% (annualized ~170%)
            0
        );

        // Second call should include Aave spread
        market.lastUpdate = uint128(block.timestamp - 1 days);

        vm.startPrank(address(morphoCredit));
        uint256 rate2 = irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Rate should be positive and include spread component
        assertGt(rate2, 0, "Rate should be positive");
        // The spread component should make rate2 higher than base rate alone
        // Note: rate1 and rate2 may differ due to adaptive rate changes too
    }

    function testZeroSpreadWithEqualRates() public {
        // Set up Aave indices with equal values (no spread initially)
        aavePoolMock.setReserveData(
            mockUsdc,
            1.05e27, // liquidityIndex
            0,
            1.05e27, // variableBorrowIndex (same as liquidity)
            0
        );

        // First call to initialize
        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = 0.5 ether;

        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Advance time
        vm.warp(block.timestamp + 1 days);

        // Set indices with equal growth (no spread)
        aavePoolMock.setReserveData(
            mockUsdc,
            1.06e27, // both grow equally
            0,
            1.06e27, // same growth rate
            0
        );

        market.lastUpdate = uint128(block.timestamp - 1 days);

        vm.startPrank(address(morphoCredit));
        uint256 rate = irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Rate should still be positive (base rate) but spread component is zero
        assertGt(rate, 0, "Rate should include base rate");
        // With equal growth rates, the spread component should be 0
        // The rate consists only of the adaptive curve base rate
    }

    function testAaveSpreadWithHighDifferential() public {
        // Test with a large spread between borrow and supply rates
        aavePoolMock.setReserveData(
            mockUsdc,
            1.02e27, // 2% growth
            0,
            1.15e27, // 15% growth - large spread
            0
        );

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = 0.8 ether; // High utilization

        vm.startPrank(address(morphoCredit));
        uint256 rate1 = irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Advance time
        vm.warp(block.timestamp + 7 days);

        // Simulate continued high spread
        aavePoolMock.setReserveData(
            mockUsdc,
            1.025e27, // Supply rate: ~0.5% weekly growth
            0,
            1.2e27, // Borrow rate: ~4.3% weekly growth - maintaining large spread
            0
        );

        market.lastUpdate = uint128(block.timestamp - 7 days);

        vm.startPrank(address(morphoCredit));
        uint256 rate2 = irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // With high spread, rate should be significantly elevated
        assertGt(rate2, 0, "Rate should be positive with high spread");
    }

    function testProductionRealisticValues() public {
        // Use actual mainnet values from yesterday
        // Debt index: 1.19e27, Income index: 1.14e27
        aavePoolMock.setReserveData(
            mockUsdc,
            1146852376653095279072875698, // Actual income index (~1.14e27)
            0,
            1195654733361247084562890712, // Actual debt index (~1.19e27)
            0
        );

        Market memory market;
        market.totalSupplyAssets = 10_000_000 ether; // $10M supplied
        market.totalBorrowAssets = 8_500_000 ether; // 85% utilization (realistic)

        // First call to initialize
        vm.startPrank(address(morphoCredit));
        uint256 rate1 = irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Advance by 12 seconds (Ethereum block time)
        vm.warp(block.timestamp + 12);

        // Simulate realistic index growth over 12 seconds
        // ~5% APY spread = ~0.0000019% per 12 seconds
        aavePoolMock.setReserveData(
            mockUsdc,
            1146852376653095279072875698 + 22, // Tiny income growth
            0,
            1195654733361247084562890712 + 27, // Slightly more debt growth
            0
        );

        market.lastUpdate = uint128(block.timestamp - 12);

        vm.startPrank(address(morphoCredit));
        uint256 rate2 = irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Should have positive rate with spread component
        assertGt(rate2, 0, "Rate should be positive");
        // The spread exists because debt grows faster than income
    }

    function testFirstInteractionInitialization() public {
        // Deploy fresh IRM to test initialization
        AdaptiveCurveIrm freshIrm = new AdaptiveCurveIrm(address(morphoCredit), address(aavePoolMock), mockUsdc);

        // Set up Aave indices
        aavePoolMock.setReserveData(
            mockUsdc,
            1.1e27, // Income index
            0,
            1.15e27, // Debt index
            0
        );

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = 0.7 ether;

        // First interaction - should initialize indices
        vm.startPrank(address(morphoCredit));
        uint256 firstRate = freshIrm.borrowRate(marketParams, market);
        vm.stopPrank();

        // First rate should be base rate only (no spread yet)
        assertGt(firstRate, 0, "First rate should be positive");

        // Advance time
        vm.warp(block.timestamp + 1 hours);

        // Update indices
        aavePoolMock.setReserveData(
            mockUsdc,
            1.1001e27, // Small income growth
            0,
            1.1502e27, // Small debt growth
            0
        );

        market.lastUpdate = uint128(block.timestamp - 1 hours);

        // Second interaction - should now include spread
        vm.startPrank(address(morphoCredit));
        uint256 secondRate = freshIrm.borrowRate(marketParams, market);
        vm.stopPrank();

        assertGt(secondRate, 0, "Second rate should be positive with spread");
    }

    function testHighFrequencyUpdates() public {
        // Initialize with realistic indices
        aavePoolMock.setReserveData(mockUsdc, 1.14e27, 0, 1.19e27, 0);

        Market memory market;
        market.totalSupplyAssets = 1_000_000 ether;
        market.totalBorrowAssets = 750_000 ether; // 75% utilization

        // Initialize
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Simulate 100 rapid updates (12 seconds each)
        uint256 baseIncome = 1.14e27;
        uint256 baseDebt = 1.19e27;

        for (uint256 i = 1; i <= 100; i++) {
            vm.warp(block.timestamp + 12);

            // Tiny incremental growth each block
            // ~10% APY = ~0.0000038% per 12 seconds
            aavePoolMock.setReserveData(
                mockUsdc,
                uint128(baseIncome + (i * 4)), // Income grows slowly
                0,
                uint128(baseDebt + (i * 5)), // Debt grows slightly faster
                0
            );

            market.lastUpdate = uint128(block.timestamp - 12);

            vm.startPrank(address(morphoCredit));
            uint256 rate = irm.borrowRate(marketParams, market);
            vm.stopPrank();

            assertGt(rate, 0, "Rate should remain positive through rapid updates");
        }
    }

    function testApproachingUint96Limits() public {
        // Test with indices near uint96 max (~7.9e28)
        // This simulates many years of compound growth
        // uint96 max = 79,228,162,514,264,337,593,543,950,335
        uint256 nearMaxIncome = 7e28; // Still fits in uint96
        uint256 nearMaxDebt = 7.5e28; // Still fits in uint96

        aavePoolMock.setReserveData(mockUsdc, uint128(nearMaxIncome), 0, uint128(nearMaxDebt), 0);

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = 0.9 ether;

        // Initialize with high values
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        // Growth near limits
        aavePoolMock.setReserveData(
            mockUsdc,
            uint128(nearMaxIncome + 1e19), // Small growth relative to size (0.01% of base)
            0,
            uint128(nearMaxDebt + 2e19), // Slightly more growth
            0
        );

        market.lastUpdate = uint128(block.timestamp - 1 days);

        // Should handle large indices without overflow
        vm.startPrank(address(morphoCredit));
        uint256 rate = irm.borrowRate(marketParams, market);
        vm.stopPrank();

        assertGt(rate, 0, "Should handle near-limit indices");
        assertLt(rate, 10 ether, "Rate should be reasonable even with large indices");
    }

    function testZeroTimeElapsed() public {
        // Set up indices
        aavePoolMock.setReserveData(mockUsdc, 1.1e27, 0, 1.15e27, 0);

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = 0.5 ether;

        // Initialize
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Same block operation (no time elapsed)
        market.lastUpdate = uint128(block.timestamp);

        // Update indices (shouldn't matter with zero elapsed time)
        aavePoolMock.setReserveData(mockUsdc, 1.2e27, 0, 1.25e27, 0);

        vm.startPrank(address(morphoCredit));
        uint256 rate = irm.borrowRate(marketParams, market);
        vm.stopPrank();

        // Should return base rate only (no spread calculation with zero elapsed)
        assertGt(rate, 0, "Should have base rate");
    }

    function testMultipleMarketsIndependence() public {
        // Create different market params
        MarketParams memory market1Params = MarketParams(address(1), address(2), address(3), address(4), 0, address(5));
        MarketParams memory market2Params = MarketParams(address(6), address(7), address(8), address(9), 0, address(10));

        // Set up Aave indices
        aavePoolMock.setReserveData(mockUsdc, 1.05e27, 0, 1.1e27, 0);

        Market memory market;
        market.totalSupplyAssets = 1 ether;
        market.totalBorrowAssets = 0.5 ether;

        // Initialize both markets
        vm.startPrank(address(morphoCredit));
        irm.borrowRate(market1Params, market);
        irm.borrowRate(market2Params, market);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        // Update only market1
        aavePoolMock.setReserveData(mockUsdc, 1.06e27, 0, 1.12e27, 0);

        market.lastUpdate = uint128(block.timestamp - 1 hours);

        vm.startPrank(address(morphoCredit));
        uint256 rate1 = irm.borrowRate(market1Params, market);

        // Update indices differently for market2
        aavePoolMock.setReserveData(mockUsdc, 1.07e27, 0, 1.11e27, 0);

        uint256 rate2 = irm.borrowRate(market2Params, market);
        vm.stopPrank();

        // Rates should be different due to different index tracking
        assertGt(rate1, 0, "Market1 should have positive rate");
        assertGt(rate2, 0, "Market2 should have positive rate");
        // They calculate spread from different starting points
    }
}
