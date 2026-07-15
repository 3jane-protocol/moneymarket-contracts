// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.22;

import {Setup} from "./utils/Setup.sol";
import {IUSD3} from "../../../src/usd3/interfaces/IUSD3.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {KeeperRelayer} from "../../../src/usd3/KeeperRelayer.sol";
import {USD3} from "../../../src/usd3/USD3.sol";
import {sUSD3 as SUSD3Strategy} from "../../../src/usd3/sUSD3.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {ERC20} from "../../../lib/openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "../../../lib/openzeppelin/contracts/utils/math/Math.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "../../../lib/openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract MockRelayerStrategy {
    address public asset;
    address internal _susd3;
    address public management;
    address public keeper;
    address public performanceFeeRecipient;
    uint16 public performanceFee;
    uint256 public totalAssets;
    uint256 public lastReport;
    uint256 public profitMaxUnlockTime;
    bool public isShutdown;
    uint256 public reportCalls;
    uint256 public tendCalls;

    uint256 internal _nextTotalAssets;
    uint256 internal _nextProfit;
    uint256 internal _nextLoss;
    bool internal _reportReverts;

    error MockReportFailed(address strategy);
    error MockNotKeeper();

    constructor(uint256 initialTotalAssets) {
        totalAssets = initialTotalAssets;
        _nextTotalAssets = initialTotalAssets;
        lastReport = block.timestamp;
        profitMaxUnlockTime = 10 days;
    }

    function setAsset(address newAsset) external {
        asset = newAsset;
    }

    function setSUSD3(address newSusd3) external {
        _susd3 = newSusd3;
    }

    function sUSD3() external view returns (address) {
        return _susd3;
    }

    function setKeeper(address newKeeper) external {
        keeper = newKeeper;
    }

    function setManagement(address newManagement) external {
        management = newManagement;
    }

    function setPerformanceFeeRecipient(address newRecipient) external {
        performanceFeeRecipient = newRecipient;
    }

    function setPerformanceFee(uint16 newPerformanceFee) external {
        performanceFee = newPerformanceFee;
    }

    function setTotalAssets(uint256 newTotalAssets) external {
        totalAssets = newTotalAssets;
    }

    function setLastReport(uint256 newLastReport) external {
        lastReport = newLastReport;
    }

    function setProfitMaxUnlockTime(uint256 newProfitMaxUnlockTime) external {
        profitMaxUnlockTime = newProfitMaxUnlockTime;
    }

    function setIsShutdown(bool newIsShutdown) external {
        isShutdown = newIsShutdown;
    }

    function configureReport(uint256 newTotalAssets, uint256 profit, uint256 loss, bool shouldRevert) external {
        _nextTotalAssets = newTotalAssets;
        _nextProfit = profit;
        _nextLoss = loss;
        _reportReverts = shouldRevert;
    }

    function report() external returns (uint256 profit, uint256 loss) {
        if (msg.sender != keeper) revert MockNotKeeper();
        if (_reportReverts) revert MockReportFailed(address(this));
        reportCalls++;
        totalAssets = _nextTotalAssets;
        lastReport = block.timestamp;
        return (_nextProfit, _nextLoss);
    }

    function tend() external {
        if (msg.sender != keeper) revert MockNotKeeper();
        tendCalls++;
    }

    bool internal _tendTriggerValue;

    function setTendTrigger(bool value) external {
        _tendTriggerValue = value;
    }

    function tendTrigger() external view returns (bool, bytes memory) {
        return (_tendTriggerValue, abi.encodeWithSelector(this.tend.selector));
    }

    function syncTrancheShare() external view {
        if (msg.sender != keeper) revert MockNotKeeper();
    }
}

contract KeeperRelayerTest is Setup {
    event KeeperSet(address indexed keeper, bool indexed authorized);
    event ProfitLimitRatioSet(address indexed strategy, uint256 ratio);
    event LossLimitRatioSet(address indexed strategy, uint256 ratio);
    event Reported(address indexed strategy, uint256 profit, uint256 loss, uint256 preTotalAssets, bool healthChecked);

    USD3 public usd3Strategy;
    SUSD3Strategy public susd3Strategy;
    KeeperRelayer public relayer;

    address public backupKeeper = makeAddr("backupKeeper");
    address public thirdKeeper = makeAddr("thirdKeeper");
    address public random = makeAddr("random");
    address public newManagement = makeAddr("newManagement");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 internal constant SENIOR_DEPOSIT = 1_000_000e6;
    uint256 internal constant JUNIOR_SOURCE_DEPOSIT = 100_000e6;

    function setUp() public override {
        super.setUp();
        usd3Strategy = USD3(address(strategy));
        _deploySUSD3AndRelayer();
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR AND AUTH
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revertsOnZeroAddresses() public {
        address[] memory noKeepers = new address[](0);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new KeeperRelayer(address(0), noKeepers);

        MockRelayerStrategy unlinkedUsd3 = new MockRelayerStrategy(0);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new KeeperRelayer(address(unlinkedUsd3), noKeepers);
    }

    function test_constructor_derivesSusd3AndRevertsOnAssetMismatch() public {
        address[] memory noKeepers = new address[](0);
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3) = _configuredMockPair(0);

        KeeperRelayer derived = new KeeperRelayer(address(mockUsd3), noKeepers);
        assertEq(derived.susd3(), address(mockSusd3));

        mockSusd3.setAsset(thirdKeeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.Susd3AssetMismatch.selector, thirdKeeper));
        new KeeperRelayer(address(mockUsd3), noKeepers);
    }

    function test_repointedSusd3LinkFailsClosedAtReport() public {
        (MockRelayerStrategy mockUsd3,, KeeperRelayer mockRelayer) = _deployMockRelayer(10_000, keeper);
        mockUsd3.setSUSD3(thirdKeeper);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.Susd3LinkMismatch.selector, thirdKeeper));
        vm.prank(keeper);
        mockRelayer.report();
    }

    function test_constructor_setsDefaultsAndInitialKeepers() public {
        (uint32 usd3ProfitRatio, uint16 usd3LossRatio, bool usd3DoHealthCheck) =
            relayer.healthCheck(address(usd3Strategy));
        (uint32 susd3ProfitRatio, uint16 susd3LossRatio, bool susd3DoHealthCheck) =
            relayer.healthCheck(address(susd3Strategy));

        assertEq(usd3ProfitRatio, 10_000);
        assertEq(usd3LossRatio, 0);
        assertTrue(usd3DoHealthCheck);
        assertEq(susd3ProfitRatio, 10_000);
        assertEq(susd3LossRatio, 0);
        assertTrue(susd3DoHealthCheck);
        assertTrue(relayer.keepers(keeper));
        assertTrue(relayer.keepers(backupKeeper));
    }

    function test_constructor_emitsDefaultLimitAndKeeperEvents() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3) = _configuredMockPair(0);
        address[] memory initialKeepers = new address[](2);
        initialKeepers[0] = keeper;
        initialKeepers[1] = backupKeeper;

        vm.expectEmit(true, false, false, true);
        emit ProfitLimitRatioSet(address(mockUsd3), 10_000);
        vm.expectEmit(true, false, false, true);
        emit LossLimitRatioSet(address(mockUsd3), 0);
        vm.expectEmit(true, false, false, true);
        emit ProfitLimitRatioSet(address(mockSusd3), 10_000);
        vm.expectEmit(true, false, false, true);
        emit LossLimitRatioSet(address(mockSusd3), 0);
        vm.expectEmit(true, true, false, true);
        emit KeeperSet(keeper, true);
        vm.expectEmit(true, true, false, true);
        emit KeeperSet(backupKeeper, true);
        new KeeperRelayer(address(mockUsd3), initialKeepers);
    }

    function test_constructor_revertsOnZeroOrDuplicateInitialKeeper() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3) = _configuredMockPair(0);
        address[] memory initialKeepers = new address[](1);
        initialKeepers[0] = address(0);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new KeeperRelayer(address(mockUsd3), initialKeepers);

        initialKeepers = new address[](2);
        initialKeepers[0] = keeper;
        initialKeepers[1] = keeper;

        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        new KeeperRelayer(address(mockUsd3), initialKeepers);
    }

    function test_setKeeper_addRemoveAndGuards() public {
        vm.expectEmit(true, true, false, true, address(relayer));
        emit KeeperSet(thirdKeeper, true);
        vm.prank(management);
        relayer.setKeeper(thirdKeeper, true);
        assertTrue(relayer.keepers(thirdKeeper));

        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        vm.prank(management);
        relayer.setKeeper(thirdKeeper, true);

        vm.expectEmit(true, true, false, true, address(relayer));
        emit KeeperSet(thirdKeeper, false);
        vm.prank(management);
        relayer.setKeeper(thirdKeeper, false);
        assertFalse(relayer.keepers(thirdKeeper));

        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        vm.prank(management);
        relayer.setKeeper(thirdKeeper, false);

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(management);
        relayer.setKeeper(address(0), true);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_nonKeeperCannotReportOrTend() public {
        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.NotKeeper.selector, random));
        vm.prank(random);
        relayer.report();

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.NotKeeper.selector, random));
        vm.prank(random);
        relayer.tend();
    }

    function test_multipleKeepersCanReportAndTend() public {
        vm.prank(keeper);
        relayer.report();

        vm.prank(backupKeeper);
        relayer.report();

        vm.prank(keeper);
        relayer.tend();
    }

    function test_managementCanCallAllAdminAndKeeperOperations() public {
        testProtocolConfig.setConfig(keccak256("TRANCHE_SHARE_VARIANT"), 3333);
        assertFalse(relayer.keepers(management));

        vm.startPrank(management);
        relayer.setKeeper(thirdKeeper, true);
        relayer.setProfitLimitRatio(address(usd3Strategy), 200_000);
        relayer.setLossLimitRatio(address(usd3Strategy), 100);
        relayer.setDoHealthCheck(address(susd3Strategy), false);
        relayer.report();
        relayer.tend();
        vm.stopPrank();

        assertTrue(relayer.keepers(thirdKeeper));
        assertEq(ITokenizedStrategy(address(usd3Strategy)).performanceFee(), 3333);
    }

    function test_keepersAndRandomCannotCallAdminOperations() public {
        _assertCannotCallAdmin(keeper);
        _assertCannotCallAdmin(random);
    }

    function test_managementTransferUpdatesRelayerAuthorization() public {
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPendingManagement(newManagement);
        vm.prank(newManagement);
        ITokenizedStrategy(address(usd3Strategy)).acceptManagement();

        assertEq(ITokenizedStrategy(address(usd3Strategy)).management(), newManagement);

        vm.prank(newManagement);
        relayer.setKeeper(thirdKeeper, true);
        assertTrue(relayer.keepers(thirdKeeper));

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.NotManagement.selector, management));
        vm.prank(management);
        relayer.setKeeper(backupKeeper, false);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.NotKeeper.selector, management));
        vm.prank(management);
        relayer.report();

        vm.prank(newManagement);
        relayer.report();
    }

    function test_reportSyncsTrancheShareBeforeFeeMint() public {
        _seedSeniorAndJunior();
        testProtocolConfig.setConfig(keccak256("TRANCHE_SHARE_VARIANT"), 3333);
        uint256 juniorBalanceBefore = ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        _simulateYield(usd3Strategy, 10_000e6);

        vm.prank(keeper);
        (uint256 usd3Profit,, uint256 susd3Profit,) = relayer.report();

        assertEq(ITokenizedStrategy(address(usd3Strategy)).performanceFee(), 3333);
        assertEq(ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)) - juniorBalanceBefore, susd3Profit);
        assertApproxEqAbs(susd3Profit, (usd3Profit * 3333) / 10_000, 2);
    }

    /*//////////////////////////////////////////////////////////////
                       ORDERING AND ATOMICITY
    //////////////////////////////////////////////////////////////*/

    function test_reportAccruedInterestReportsBothLegsInSameTransaction() public {
        _seedSeniorAndJunior();
        _simulateYield(usd3Strategy, 10_000e6);

        vm.prank(keeper);
        (uint256 usd3Profit, uint256 usd3Loss, uint256 susd3Profit, uint256 susd3Loss) = relayer.report();

        assertGt(usd3Profit, 0);
        assertEq(usd3Loss, 0);
        assertGt(susd3Profit, 0);
        assertEq(susd3Loss, 0);
        assertEq(
            ITokenizedStrategy(address(susd3Strategy)).totalAssets(),
            ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy))
        );
    }

    function test_emptyJuniorRecoversWithOneShotSusd3Skip() public {
        mintAndDepositIntoStrategy(IUSD3(address(usd3Strategy)), alice, SENIOR_DEPOSIT);

        vm.prank(keeper);
        relayer.report();
        assertEq(ITokenizedStrategy(address(susd3Strategy)).totalAssets(), 0);

        _simulateYield(usd3Strategy, 5_000e6);

        bool reportSucceeded;
        bytes memory revertData;
        try this.callReport() {
            reportSucceeded = true;
        } catch (bytes memory err) {
            revertData = err;
        }

        assertFalse(reportSucceeded);
        (bytes4 selector, address failedStrategy, uint256 profit, uint256 loss, uint256 preTotalAssets) =
            _decodeHealthCheckFailed(revertData);
        assertEq(selector, KeeperRelayer.HealthCheckFailed.selector);
        assertEq(failedStrategy, address(susd3Strategy));
        assertGt(profit, 0);
        assertEq(loss, 0);
        assertEq(preTotalAssets, 0);

        vm.prank(management);
        relayer.setDoHealthCheck(address(susd3Strategy), false);
        vm.prank(backupKeeper);
        (uint256 usd3Profit,, uint256 susd3Profit,) = relayer.report();

        assertGt(usd3Profit, 0);
        assertGt(susd3Profit, 0);
        assertEq(ITokenizedStrategy(address(susd3Strategy)).totalAssets(), susd3Profit);
        (,, bool doHealthCheck) = relayer.healthCheck(address(susd3Strategy));
        assertTrue(doHealthCheck);

        vm.prank(keeper);
        (uint256 nextUsd3Profit, uint256 nextUsd3Loss, uint256 nextSusd3Profit, uint256 nextSusd3Loss) =
            relayer.report();
        assertEq(nextUsd3Profit, 0);
        assertEq(nextUsd3Loss, 0);
        assertEq(nextSusd3Profit, 0);
        assertEq(nextSusd3Loss, 0);
    }

    function test_reportLossRecognizesJuniorBurnOnSecondLegInSameTransaction() public {
        _seedSeniorAndJunior();
        uint256 juniorBalanceBefore = ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        _simulateLoss(usd3Strategy, 5_000e6);
        _setLossLimits(9000, 9000);

        vm.prank(keeper);
        (uint256 usd3Profit, uint256 usd3Loss, uint256 susd3Profit, uint256 susd3Loss) = relayer.report();

        assertEq(usd3Profit, 0);
        assertGt(usd3Loss, 0);
        assertEq(susd3Profit, 0);
        assertGt(susd3Loss, 0);
        assertLt(ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)), juniorBalanceBefore);
        assertEq(
            ITokenizedStrategy(address(susd3Strategy)).totalAssets(),
            ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy))
        );
    }

    function test_fullJuniorWipeRecoversWithOneShotSusd3Skip() public {
        _seedSeniorAndJunior();
        uint256 juniorAssetsBefore = ITokenizedStrategy(address(susd3Strategy)).totalAssets();
        uint256 marketAssets = usd3Strategy.morphoCredit().market(usd3Strategy.marketId()).totalSupplyAssets;
        assertGe(marketAssets, juniorAssetsBefore);
        _simulateLoss(usd3Strategy, juniorAssetsBefore);
        _setLossLimits(9000, 9999);

        vm.expectRevert(
            abi.encodeWithSelector(
                KeeperRelayer.HealthCheckFailed.selector, susd3Strategy, 0, juniorAssetsBefore, juniorAssetsBefore
            )
        );
        vm.prank(keeper);
        relayer.report();

        vm.prank(management);
        relayer.setDoHealthCheck(address(susd3Strategy), false);
        vm.prank(backupKeeper);
        (, uint256 usd3Loss,, uint256 susd3Loss) = relayer.report();

        assertGt(usd3Loss, 0);
        assertEq(susd3Loss, juniorAssetsBefore);
        assertEq(ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)), 0);
        assertEq(ITokenizedStrategy(address(susd3Strategy)).totalAssets(), 0);
    }

    function test_susd3LegFailureRollsBackUsd3ReportBurnTendAndMorphoPosition() public {
        _seedSeniorAndJunior();
        _simulateLoss(usd3Strategy, 5_000e6);
        _setLossLimits(9000, 0);

        uint256 usd3AssetsBefore = ITokenizedStrategy(address(usd3Strategy)).totalAssets();
        uint256 usd3SupplyBefore = ERC20(address(usd3Strategy)).totalSupply();
        uint256 susd3AssetsBefore = ITokenizedStrategy(address(susd3Strategy)).totalAssets();
        uint256 susd3SupplyBefore = ERC20(address(susd3Strategy)).totalSupply();
        uint256 susd3Usd3BalanceBefore = ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy));
        uint256 morphoSharesBefore =
            usd3Strategy.morphoCredit().position(usd3Strategy.marketId(), address(usd3Strategy)).supplyShares;
        uint256 suppliedBefore = usd3Strategy.suppliedWaUSDC();
        uint256 localWaUsdcBefore = usd3Strategy.balanceOfWaUSDC();

        bool reportSucceeded;
        bytes memory revertData;
        try this.callReport() {
            reportSucceeded = true;
        } catch (bytes memory err) {
            revertData = err;
        }
        assertFalse(reportSucceeded);
        (bytes4 selector, address failedStrategy,,,) = _decodeHealthCheckFailed(revertData);
        assertEq(selector, KeeperRelayer.HealthCheckFailed.selector);
        assertEq(failedStrategy, address(susd3Strategy));

        assertEq(ITokenizedStrategy(address(usd3Strategy)).totalAssets(), usd3AssetsBefore);
        assertEq(ERC20(address(usd3Strategy)).totalSupply(), usd3SupplyBefore);
        assertEq(ITokenizedStrategy(address(susd3Strategy)).totalAssets(), susd3AssetsBefore);
        assertEq(ERC20(address(susd3Strategy)).totalSupply(), susd3SupplyBefore);
        assertEq(ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy)), susd3Usd3BalanceBefore);
        uint256 morphoSharesAfter =
            usd3Strategy.morphoCredit().position(usd3Strategy.marketId(), address(usd3Strategy)).supplyShares;
        assertEq(morphoSharesAfter, morphoSharesBefore);
        assertEq(usd3Strategy.suppliedWaUSDC(), suppliedBefore);
        assertEq(usd3Strategy.balanceOfWaUSDC(), localWaUsdcBefore);

        vm.prank(management);
        relayer.setLossLimitRatio(address(susd3Strategy), 9000);
        vm.prank(keeper);
        (, uint256 usd3Loss,, uint256 susd3Loss) = relayer.report();
        assertGt(usd3Loss, 0);
        assertGt(susd3Loss, 0);
    }

    function test_usd3LegFailureNeverReachesSusd3() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, address(this));
        mockUsd3.configureReport(10_000, 0, 0, true);
        mockSusd3.configureReport(11_000, 1_000, 0, true);

        vm.expectRevert(abi.encodeWithSelector(MockRelayerStrategy.MockReportFailed.selector, address(mockUsd3)));
        mockRelayer.report();
    }

    function test_mockSecondLegFailureRevertsWithSecondLegError() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, address(this));
        mockUsd3.configureReport(10_100, 100, 0, false);
        mockSusd3.configureReport(10_000, 0, 0, true);

        vm.expectRevert(abi.encodeWithSelector(MockRelayerStrategy.MockReportFailed.selector, address(mockSusd3)));
        mockRelayer.report();
    }

    /*//////////////////////////////////////////////////////////////
                            HEALTH CHECKS
    //////////////////////////////////////////////////////////////*/

    function test_profitAtLimitPassesAndOneAboveRevertsForBothStrategies() public {
        _assertBoundary(false, false);
        _assertBoundary(true, false);
    }

    function test_lossAtMulDivLimitPassesAndOneAboveRevertsForBothStrategies() public {
        _assertBoundary(false, true);
        _assertBoundary(true, true);
    }

    function test_zeroLossLimitRejectsOneWei() public {
        (MockRelayerStrategy mockUsd3,, KeeperRelayer mockRelayer) = _deployMockRelayer(100, address(this));
        mockUsd3.configureReport(99, 0, 1, false);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.HealthCheckFailed.selector, mockUsd3, 0, 1, 100));
        mockRelayer.report();
    }

    function test_limitsAreIndependentPerStrategy() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, address(this));
        mockRelayer.setProfitLimitRatio(address(mockUsd3), 1000);
        mockRelayer.setProfitLimitRatio(address(mockSusd3), 500);
        mockUsd3.configureReport(11_000, 1_000, 0, false);
        mockSusd3.configureReport(10_501, 501, 0, false);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.HealthCheckFailed.selector, mockSusd3, 501, 0, 10_000));
        mockRelayer.report();

        assertEq(mockUsd3.totalAssets(), 10_000);
        assertEq(mockSusd3.totalAssets(), 10_000);
    }

    function test_profitLimitAboveUint16AllowsAmplifiedJuniorFeeMint() public {
        _seedSeniorAndJunior(100e6);
        uint256 preTotalAssets = ITokenizedStrategy(address(susd3Strategy)).totalAssets();

        vm.prank(management);
        relayer.setProfitLimitRatio(address(susd3Strategy), 200_000);
        _simulateYield(usd3Strategy, 10_000e6);

        vm.prank(keeper);
        (,, uint256 susd3Profit, uint256 susd3Loss) = relayer.report();

        assertGt(susd3Profit, Math.mulDiv(preTotalAssets, type(uint16).max, 10_000));
        assertLe(susd3Profit, Math.mulDiv(preTotalAssets, 200_000, 10_000));
        assertEq(susd3Loss, 0);
    }

    function test_oneShotSkipIsPerLegConsumedByNextKeeperAndAutoReenables() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        mockRelayer.setProfitLimitRatio(address(mockUsd3), 1);
        mockRelayer.setProfitLimitRatio(address(mockSusd3), 1);
        mockUsd3.configureReport(11_000, 1_000, 0, false);
        mockSusd3.configureReport(11_000, 1_000, 0, false);
        mockRelayer.setDoHealthCheck(address(mockSusd3), false);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.HealthCheckFailed.selector, mockUsd3, 1_000, 0, 10_000));
        vm.prank(keeper);
        mockRelayer.report();

        (,, bool doHealthCheckAfterRevert) = mockRelayer.healthCheck(address(mockSusd3));
        assertFalse(doHealthCheckAfterRevert);

        mockUsd3.configureReport(10_000, 0, 0, false);
        vm.expectEmit(true, false, false, true, address(mockRelayer));
        emit Reported(address(mockUsd3), 0, 0, 10_000, true);
        vm.expectEmit(true, false, false, true, address(mockRelayer));
        emit Reported(address(mockSusd3), 1_000, 0, 10_000, false);
        vm.prank(keeper);
        mockRelayer.report();

        (,, bool doHealthCheckAfterSkip) = mockRelayer.healthCheck(address(mockSusd3));
        assertTrue(doHealthCheckAfterSkip);

        mockSusd3.setTotalAssets(10_000);
        mockSusd3.configureReport(11_000, 1_000, 0, false);
        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.HealthCheckFailed.selector, mockSusd3, 1_000, 0, 10_000));
        vm.prank(keeper);
        mockRelayer.report();
    }

    function test_nearTotalWipeRevertsUnlessSkipArmed() public {
        (MockRelayerStrategy mockUsd3,, KeeperRelayer mockRelayer) = _deployMockRelayer(3, keeper);
        mockUsd3.configureReport(1, 0, 2, false);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.HealthCheckFailed.selector, mockUsd3, 0, 2, 3));
        vm.prank(keeper);
        mockRelayer.report();

        mockRelayer.setDoHealthCheck(address(mockUsd3), false);
        vm.prank(keeper);
        mockRelayer.report();
        assertEq(mockUsd3.totalAssets(), 1);
    }

    function test_reportDeltaMismatchAlwaysRevertsWhenSkipArmed() public {
        (MockRelayerStrategy mockUsd3,, KeeperRelayer mockRelayer) = _deployMockRelayer(10_000, address(this));
        mockUsd3.configureReport(10_010, 11, 0, false);
        mockRelayer.setDoHealthCheck(address(mockUsd3), false);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.ReportDeltaMismatch.selector, mockUsd3, 11, 0, 10, 0));
        mockRelayer.report();
    }

    function test_healthSettersValidateStrategyAndBounds() public {
        vm.startPrank(management);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.InvalidStrategy.selector, random));
        relayer.setProfitLimitRatio(random, 1);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.InvalidStrategy.selector, random));
        relayer.setLossLimitRatio(random, 1);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.InvalidStrategy.selector, random));
        relayer.setDoHealthCheck(random, false);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.InvalidProfitLimit.selector, 0));
        relayer.setProfitLimitRatio(address(usd3Strategy), 0);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.InvalidLossLimit.selector, 10_000));
        relayer.setLossLimitRatio(address(usd3Strategy), 10_000);

        vm.expectEmit(true, false, false, true, address(relayer));
        emit ProfitLimitRatioSet(address(usd3Strategy), type(uint32).max);
        relayer.setProfitLimitRatio(address(usd3Strategy), type(uint32).max);

        vm.expectEmit(true, false, false, true, address(relayer));
        emit LossLimitRatioSet(address(usd3Strategy), 9999);
        relayer.setLossLimitRatio(address(usd3Strategy), 9999);
        relayer.setDoHealthCheck(address(usd3Strategy), false);
        vm.stopPrank();

        (uint32 profitRatio, uint16 lossRatio, bool doHealthCheck) = relayer.healthCheck(address(usd3Strategy));
        assertEq(profitRatio, type(uint32).max);
        assertEq(lossRatio, 9999);
        assertFalse(doHealthCheck);
    }

    function testFuzz_profitLimitUsesFloorRounding(uint128 rawPreAssets, uint32 rawRatio) public {
        uint256 preAssets = bound(uint256(rawPreAssets), 1, type(uint128).max);
        uint32 ratio = uint32(bound(uint256(rawRatio), 1, type(uint32).max));
        uint256 limit = Math.mulDiv(preAssets, ratio, 10_000);
        (MockRelayerStrategy mockUsd3,, KeeperRelayer mockRelayer) = _deployMockRelayer(preAssets, address(this));
        mockRelayer.setProfitLimitRatio(address(mockUsd3), ratio);
        mockUsd3.configureReport(preAssets + limit, limit, 0, false);

        mockRelayer.report();

        mockUsd3.setTotalAssets(preAssets);
        mockUsd3.configureReport(preAssets + limit + 1, limit + 1, 0, false);
        vm.expectRevert(
            abi.encodeWithSelector(KeeperRelayer.HealthCheckFailed.selector, mockUsd3, limit + 1, 0, preAssets)
        );
        mockRelayer.report();
    }

    function testFuzz_fullWipeAlwaysFailsHealthCheck(uint128 rawPreAssets, uint16 rawRatio) public {
        uint256 preAssets = bound(uint256(rawPreAssets), 1, type(uint128).max);
        uint16 ratio = uint16(bound(uint256(rawRatio), 0, 9999));
        (MockRelayerStrategy mockUsd3,, KeeperRelayer mockRelayer) = _deployMockRelayer(preAssets, address(this));
        mockRelayer.setLossLimitRatio(address(mockUsd3), ratio);
        mockUsd3.configureReport(0, 0, preAssets, false);

        vm.expectRevert(
            abi.encodeWithSelector(KeeperRelayer.HealthCheckFailed.selector, mockUsd3, 0, preAssets, preAssets)
        );
        mockRelayer.report();
    }

    /*//////////////////////////////////////////////////////////////
                          WIRING AND EDGES
    //////////////////////////////////////////////////////////////*/

    function test_repointedKeeperFailsClosedBeforeStateChanges() public {
        _seedSeniorAndJunior();
        _simulateYield(usd3Strategy, 1_000e6);
        uint256 usd3AssetsBefore = ITokenizedStrategy(address(usd3Strategy)).totalAssets();
        uint256 susd3AssetsBefore = ITokenizedStrategy(address(susd3Strategy)).totalAssets();

        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setKeeper(thirdKeeper);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.RelayerNotKeeper.selector, usd3Strategy, thirdKeeper));
        vm.prank(keeper);
        relayer.report();

        assertEq(ITokenizedStrategy(address(usd3Strategy)).totalAssets(), usd3AssetsBefore);
        assertEq(ITokenizedStrategy(address(susd3Strategy)).totalAssets(), susd3AssetsBefore);
    }

    function test_repointedFeeRecipientFailsClosed() public {
        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFeeRecipient(thirdKeeper);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.FeeRecipientNotSusd3.selector, thirdKeeper));
        vm.prank(keeper);
        relayer.report();
    }

    function test_nonzeroSusd3PerformanceFeeFailsClosed() public {
        vm.prank(management);
        ITokenizedStrategy(address(susd3Strategy)).setPerformanceFee(1);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.NonzeroSusd3PerformanceFee.selector, 1));
        vm.prank(keeper);
        relayer.report();
    }

    /*//////////////////////////////////////////////////////////////
                            REPORT TRIGGER
    //////////////////////////////////////////////////////////////*/

    function test_reportTriggerFalseBeforeBothDeadlines() public {
        (,, KeeperRelayer mockRelayer) = _deployMockRelayer(10_000, keeper);

        (bool shouldReport, bytes memory callData) = mockRelayer.reportTrigger();

        assertFalse(shouldReport);
        assertEq(callData, abi.encodeWithSelector(KeeperRelayer.report.selector));
    }

    function test_reportTriggerUsesStrictDeadlineBoundary() public {
        (,, KeeperRelayer mockRelayer) = _deployMockRelayer(10_000, keeper);
        uint256 lastReport = block.timestamp;

        vm.warp(lastReport + 10 days);
        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        vm.warp(lastReport + 10 days + 1);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);
    }

    function test_reportTriggerTrueWhenOnlyUsd3IsDue() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        uint256 lastReport = block.timestamp;

        vm.warp(lastReport + 10 days + 1);
        mockSusd3.setLastReport(block.timestamp);

        assertGt(block.timestamp - mockUsd3.lastReport(), mockUsd3.profitMaxUnlockTime());
        assertEq(block.timestamp, mockSusd3.lastReport());
        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);
    }

    function test_reportTriggerTrueWhenOnlySusd3IsDue() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        uint256 lastReport = block.timestamp;

        vm.warp(lastReport + 10 days + 1);
        mockUsd3.setLastReport(block.timestamp);

        assertEq(block.timestamp, mockUsd3.lastReport());
        assertGt(block.timestamp - mockSusd3.lastReport(), mockSusd3.profitMaxUnlockTime());
        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);
    }

    function test_reportTriggerRespectsDivergentPerLegUnlockTimes() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        uint256 lastReport = block.timestamp;
        mockUsd3.setProfitMaxUnlockTime(2 days);
        mockSusd3.setProfitMaxUnlockTime(20 days);

        vm.warp(lastReport + 2 days);
        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        vm.warp(lastReport + 2 days + 1);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);

        vm.warp(lastReport + 20 days);
        mockUsd3.setLastReport(block.timestamp);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        vm.warp(lastReport + 20 days + 1);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);
    }

    function test_reportTriggerFalseWhenEitherStrategyIsShutdown() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        vm.warp(block.timestamp + 10 days + 1);

        mockUsd3.setIsShutdown(true);
        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        mockUsd3.setIsShutdown(false);
        mockSusd3.setIsShutdown(true);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);
    }

    function test_reportTriggerFalseWhenEitherZeroAssetHealthCheckIsArmed() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        vm.warp(block.timestamp + 10 days + 1);

        mockUsd3.setTotalAssets(0);
        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        mockUsd3.setTotalAssets(10_000);
        mockSusd3.setTotalAssets(0);
        mockUsd3.setPerformanceFee(1);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);
    }

    function test_reportTriggerTrueWhenZeroAssetLegSkipIsArmed() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        vm.warp(block.timestamp + 10 days + 1);
        mockUsd3.setPerformanceFee(1);
        mockSusd3.setTotalAssets(0);

        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        mockRelayer.setDoHealthCheck(address(mockSusd3), false);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);
    }

    function test_reportTriggerTrueWhenZeroAssetSeniorSkipIsArmed() public {
        (MockRelayerStrategy mockUsd3,, KeeperRelayer mockRelayer) = _deployMockRelayer(10_000, keeper);
        vm.warp(block.timestamp + 10 days + 1);
        mockUsd3.setTotalAssets(0);

        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        mockRelayer.setDoHealthCheck(address(mockUsd3), false);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);
    }

    function test_reportTriggerFalseWhenZeroAssetLegSkipIsArmedBeforeBothDeadlines() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        mockUsd3.setPerformanceFee(1);
        mockSusd3.setTotalAssets(0);
        mockRelayer.setDoHealthCheck(address(mockSusd3), false);

        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);
    }

    function test_reportTriggerEmptyJuniorGuardRequiresNonzeroSeniorPerformanceFee() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        vm.warp(block.timestamp + 10 days + 1);
        mockSusd3.setTotalAssets(0);

        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);

        mockUsd3.setPerformanceFee(1);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        mockRelayer.setDoHealthCheck(address(mockSusd3), false);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);
    }

    function test_reportTriggerZeroUnlockDisablesOnlyThatLeg() public {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, keeper);
        uint256 lastReport = block.timestamp;
        mockUsd3.setProfitMaxUnlockTime(0);

        vm.warp(lastReport + 10 days);
        (bool shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        vm.warp(lastReport + 10 days + 1);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertTrue(shouldReport);

        mockSusd3.setLastReport(block.timestamp);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);

        mockSusd3.setProfitMaxUnlockTime(0);
        vm.warp(block.timestamp + 100 days);
        (shouldReport,) = mockRelayer.reportTrigger();
        assertFalse(shouldReport);
    }

    function test_reportTriggerRealStrategiesUsesStrictProfitUnlockDeadline() public {
        _seedSeniorAndJunior();
        uint256 lastReport = ITokenizedStrategy(address(usd3Strategy)).lastReport();
        assertEq(lastReport, ITokenizedStrategy(address(susd3Strategy)).lastReport());

        (bool shouldReport,) = relayer.reportTrigger();
        assertFalse(shouldReport);

        vm.warp(lastReport + 10 days);
        (shouldReport,) = relayer.reportTrigger();
        assertFalse(shouldReport);

        vm.warp(lastReport + 10 days + 1);
        (shouldReport,) = relayer.reportTrigger();
        assertTrue(shouldReport);
    }

    function test_reportTriggerCalldataReportsBothStrategiesAndResetsCadence() public {
        _seedSeniorAndJunior();
        uint256 previousReport = ITokenizedStrategy(address(usd3Strategy)).lastReport();
        vm.warp(previousReport + 10 days + 1);

        (bool shouldReport, bytes memory callData) = relayer.reportTrigger();
        assertTrue(shouldReport);
        assertEq(callData, abi.encodeWithSelector(KeeperRelayer.report.selector));

        vm.prank(keeper);
        (bool success,) = address(relayer).call(callData);
        assertTrue(success);
        assertEq(ITokenizedStrategy(address(usd3Strategy)).lastReport(), block.timestamp);
        assertEq(ITokenizedStrategy(address(susd3Strategy)).lastReport(), block.timestamp);

        (shouldReport,) = relayer.reportTrigger();
        assertFalse(shouldReport);
    }

    function test_reportTriggerStaysTrueWhenManagementDirectReportsOnlyUsd3() public {
        _seedSeniorAndJunior();
        uint256 previousReport = ITokenizedStrategy(address(usd3Strategy)).lastReport();
        vm.warp(previousReport + 10 days + 1);

        (bool shouldReport,) = relayer.reportTrigger();
        assertTrue(shouldReport);

        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).report();
        assertEq(ITokenizedStrategy(address(usd3Strategy)).lastReport(), block.timestamp);
        assertEq(ITokenizedStrategy(address(susd3Strategy)).lastReport(), previousReport);

        (shouldReport,) = relayer.reportTrigger();
        assertTrue(shouldReport);
    }

    function test_reportTriggerEmptyJuniorRecoveryUsesOneShotSkip() public {
        mintAndDepositIntoStrategy(IUSD3(address(usd3Strategy)), alice, SENIOR_DEPOSIT);
        vm.prank(keeper);
        relayer.report();
        uint256 previousReport = ITokenizedStrategy(address(usd3Strategy)).lastReport();
        assertEq(ITokenizedStrategy(address(susd3Strategy)).totalAssets(), 0);

        _simulateYield(usd3Strategy, 5_000e6);
        vm.warp(previousReport + 10 days + 1);

        (bool shouldReport,) = relayer.reportTrigger();
        assertFalse(shouldReport);

        vm.prank(management);
        relayer.setDoHealthCheck(address(susd3Strategy), false);
        bytes memory callData;
        (shouldReport, callData) = relayer.reportTrigger();
        assertTrue(shouldReport);

        vm.prank(keeper);
        (bool success,) = address(relayer).call(callData);
        assertTrue(success);
        assertGt(ITokenizedStrategy(address(susd3Strategy)).totalAssets(), 0);
        (,, bool doHealthCheck) = relayer.healthCheck(address(susd3Strategy));
        assertTrue(doHealthCheck);

        (shouldReport,) = relayer.reportTrigger();
        assertFalse(shouldReport);
    }

    function test_reportTriggerShutdownDisablesCadenceButManualReportStillSucceeds() public {
        _seedSeniorAndJunior();
        uint256 previousReport = ITokenizedStrategy(address(usd3Strategy)).lastReport();
        vm.warp(previousReport + 10 days + 1);

        vm.startPrank(management);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();
        vm.stopPrank();

        (bool shouldReport, bytes memory callData) = relayer.reportTrigger();
        assertFalse(shouldReport);
        assertEq(callData, abi.encodeWithSelector(KeeperRelayer.report.selector));

        vm.prank(keeper);
        (bool success,) = address(relayer).call(callData);
        assertTrue(success);
        assertEq(ITokenizedStrategy(address(usd3Strategy)).lastReport(), block.timestamp);
        assertEq(ITokenizedStrategy(address(susd3Strategy)).lastReport(), block.timestamp);
    }

    function test_tendTriggerForwardsUsd3StateWithRelayerCalldata() public {
        (MockRelayerStrategy mockUsd3,, KeeperRelayer mockRelayer) = _deployMockRelayer(10_000, keeper);

        (bool shouldTend, bytes memory callData) = mockRelayer.tendTrigger();
        assertFalse(shouldTend);
        assertEq(callData, abi.encodeWithSelector(KeeperRelayer.tend.selector));

        mockUsd3.setTendTrigger(true);
        (shouldTend, callData) = mockRelayer.tendTrigger();
        assertTrue(shouldTend);
        assertEq(callData, abi.encodeWithSelector(KeeperRelayer.tend.selector));
    }

    function test_tendTriggerCalldataExecutesTendOnRelayer() public {
        _seedSeniorAndJunior();
        (bool shouldTend, bytes memory callData) = relayer.tendTrigger();
        assertFalse(shouldTend);

        setMaxOnCredit(5_000);
        (bool usd3ShouldTend,) = IUSD3(address(usd3Strategy)).tendTrigger();
        (shouldTend, callData) = relayer.tendTrigger();
        assertEq(shouldTend, usd3ShouldTend);
        assertTrue(shouldTend);

        uint256 deployedBefore = usd3Strategy.suppliedWaUSDC();
        vm.prank(keeper);
        (bool success,) = address(relayer).call(callData);
        assertTrue(success);
        assertLt(usd3Strategy.suppliedWaUSDC(), deployedBefore);

        (shouldTend,) = relayer.tendTrigger();
        assertFalse(shouldTend);
    }

    function test_managementCanStillDirectReportOutsideRelayer() public {
        assertEq(ITokenizedStrategy(address(usd3Strategy)).keeper(), address(relayer));

        vm.prank(management);
        ITokenizedStrategy(address(usd3Strategy)).report();
    }

    function test_usd3DonationToSusd3RecoversWithOneShotSkip() public {
        _seedSeniorAndJunior();
        vm.prank(management);
        relayer.setProfitLimitRatio(address(susd3Strategy), 100);

        uint256 donation = 1_000e6;
        uint256 preTotalAssets = ITokenizedStrategy(address(susd3Strategy)).totalAssets();
        vm.prank(alice);
        ERC20(address(usd3Strategy)).transfer(address(susd3Strategy), donation);

        vm.expectRevert(
            abi.encodeWithSelector(KeeperRelayer.HealthCheckFailed.selector, susd3Strategy, donation, 0, preTotalAssets)
        );
        vm.prank(keeper);
        relayer.report();

        vm.prank(management);
        relayer.setDoHealthCheck(address(susd3Strategy), false);
        vm.prank(backupKeeper);
        relayer.report();

        assertEq(
            ITokenizedStrategy(address(susd3Strategy)).totalAssets(),
            ERC20(address(usd3Strategy)).balanceOf(address(susd3Strategy))
        );
    }

    function test_shutdownStrategiesStillReport() public {
        _seedSeniorAndJunior();
        vm.startPrank(management);
        ITokenizedStrategy(address(usd3Strategy)).shutdownStrategy();
        ITokenizedStrategy(address(susd3Strategy)).shutdownStrategy();
        vm.stopPrank();

        vm.prank(keeper);
        relayer.report();

        assertTrue(ITokenizedStrategy(address(usd3Strategy)).isShutdown());
        assertTrue(ITokenizedStrategy(address(susd3Strategy)).isShutdown());
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function callReport() external {
        vm.prank(keeper);
        relayer.report();
    }

    function _decodeHealthCheckFailed(bytes memory revertData)
        internal
        view
        returns (bytes4 selector, address failedStrategy, uint256 profit, uint256 loss, uint256 preTotalAssets)
    {
        return this.decodeHealthCheckFailedCalldata(revertData);
    }

    function decodeHealthCheckFailedCalldata(bytes calldata revertData)
        external
        pure
        returns (bytes4 selector, address failedStrategy, uint256 profit, uint256 loss, uint256 preTotalAssets)
    {
        selector = bytes4(revertData[:4]);
        (failedStrategy, profit, loss, preTotalAssets) =
            abi.decode(revertData[4:], (address, uint256, uint256, uint256));
    }

    function _deploySUSD3AndRelayer() internal {
        SUSD3Strategy susd3Implementation = new SUSD3Strategy();
        ProxyAdmin susd3ProxyAdmin = new ProxyAdmin(management);
        bytes memory susd3InitData =
            abi.encodeWithSelector(SUSD3Strategy.initialize.selector, address(usd3Strategy), management, keeper);
        TransparentUpgradeableProxy susd3Proxy =
            new TransparentUpgradeableProxy(address(susd3Implementation), address(susd3ProxyAdmin), susd3InitData);
        susd3Strategy = SUSD3Strategy(address(susd3Proxy));

        vm.startPrank(management);
        usd3Strategy.setSUSD3(address(susd3Strategy));
        ITokenizedStrategy(address(usd3Strategy)).setPerformanceFeeRecipient(address(susd3Strategy));
        ITokenizedStrategy(address(susd3Strategy)).setPerformanceFee(0);
        vm.stopPrank();

        vm.prank(keeper);
        usd3Strategy.syncTrancheShare();

        address[] memory initialKeepers = new address[](2);
        initialKeepers[0] = keeper;
        initialKeepers[1] = backupKeeper;
        relayer = new KeeperRelayer(address(usd3Strategy), initialKeepers);

        vm.startPrank(management);
        ITokenizedStrategy(address(usd3Strategy)).setKeeper(address(relayer));
        ITokenizedStrategy(address(susd3Strategy)).setKeeper(address(relayer));
        vm.stopPrank();
    }

    function _seedSeniorAndJunior() internal {
        _seedSeniorAndJunior(0);
    }

    function _seedSeniorAndJunior(uint256 juniorDeposit) internal {
        mintAndDepositIntoStrategy(IUSD3(address(usd3Strategy)), alice, SENIOR_DEPOSIT);
        mintAndDepositIntoStrategy(IUSD3(address(usd3Strategy)), bob, JUNIOR_SOURCE_DEPOSIT);

        if (juniorDeposit == 0) juniorDeposit = ERC20(address(usd3Strategy)).balanceOf(bob) / 5;
        vm.startPrank(bob);
        ERC20(address(usd3Strategy)).approve(address(susd3Strategy), juniorDeposit);
        susd3Strategy.deposit(juniorDeposit, bob);
        vm.stopPrank();

        vm.prank(keeper);
        relayer.report();
    }

    function _setLossLimits(uint16 usd3Ratio, uint16 susd3Ratio) internal {
        vm.startPrank(management);
        relayer.setLossLimitRatio(address(usd3Strategy), usd3Ratio);
        relayer.setLossLimitRatio(address(susd3Strategy), susd3Ratio);
        vm.stopPrank();
    }

    function _assertCannotCallAdmin(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.NotManagement.selector, caller));
        vm.prank(caller);
        relayer.setKeeper(thirdKeeper, true);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.NotManagement.selector, caller));
        vm.prank(caller);
        relayer.setProfitLimitRatio(address(usd3Strategy), 1);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.NotManagement.selector, caller));
        vm.prank(caller);
        relayer.setLossLimitRatio(address(usd3Strategy), 1);

        vm.expectRevert(abi.encodeWithSelector(KeeperRelayer.NotManagement.selector, caller));
        vm.prank(caller);
        relayer.setDoHealthCheck(address(usd3Strategy), false);
    }

    function _configuredMockPair(uint256 assets)
        internal
        returns (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3)
    {
        mockUsd3 = new MockRelayerStrategy(assets);
        mockSusd3 = new MockRelayerStrategy(assets);
        mockUsd3.setSUSD3(address(mockSusd3));
        mockUsd3.setPerformanceFeeRecipient(address(mockSusd3));
        mockSusd3.setAsset(address(mockUsd3));
        mockUsd3.configureReport(assets, 0, 0, false);
        mockSusd3.configureReport(assets, 0, 0, false);
    }

    function _deployMockRelayer(uint256 assets, address authorizedKeeper)
        internal
        returns (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer)
    {
        (mockUsd3, mockSusd3) = _configuredMockPair(assets);
        mockUsd3.setManagement(address(this));
        address[] memory initialKeepers = new address[](1);
        initialKeepers[0] = authorizedKeeper;
        mockRelayer = new KeeperRelayer(address(mockUsd3), initialKeepers);
        mockUsd3.setKeeper(address(mockRelayer));
        mockSusd3.setKeeper(address(mockRelayer));
    }

    function _assertBoundary(bool junior, bool isLoss) internal {
        (MockRelayerStrategy mockUsd3, MockRelayerStrategy mockSusd3, KeeperRelayer mockRelayer) =
            _deployMockRelayer(10_000, address(this));
        MockRelayerStrategy target = junior ? mockSusd3 : mockUsd3;
        if (isLoss) {
            mockRelayer.setLossLimitRatio(address(target), 1000);
        } else {
            mockRelayer.setProfitLimitRatio(address(target), 1000);
        }

        target.configureReport(isLoss ? 9_000 : 11_000, isLoss ? 0 : 1_000, isLoss ? 1_000 : 0, false);
        mockRelayer.report();

        target.setTotalAssets(10_000);
        target.configureReport(isLoss ? 8_999 : 11_001, isLoss ? 0 : 1_001, isLoss ? 1_001 : 0, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                KeeperRelayer.HealthCheckFailed.selector, target, isLoss ? 0 : 1_001, isLoss ? 1_001 : 0, 10_000
            )
        );
        mockRelayer.report();
    }
}
