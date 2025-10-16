// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {MarketConfig, CreditLineConfig, IRMConfig} from "../../../src/interfaces/IProtocolConfig.sol";
import {
    TransparentUpgradeableProxy
} from "../../../lib/openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";

contract ProtocolConfigTest is Test {
    ProtocolConfig internal protocolConfig;
    address internal owner;
    address internal nonOwner;

    // Configuration keys for testing
    bytes32 private constant MAX_LTV = keccak256("MAX_LTV");
    bytes32 private constant MAX_VV = keccak256("MAX_VV");
    bytes32 private constant MAX_CREDIT_LINE = keccak256("MAX_CREDIT_LINE");
    bytes32 private constant MIN_CREDIT_LINE = keccak256("MIN_CREDIT_LINE");
    bytes32 private constant MAX_DRP = keccak256("MAX_DRP");
    bytes32 private constant IS_PAUSED = keccak256("IS_PAUSED");
    bytes32 private constant MAX_ON_CREDIT = keccak256("MAX_ON_CREDIT");
    bytes32 private constant IRP = keccak256("IRP");
    bytes32 private constant MIN_BORROW = keccak256("MIN_BORROW");
    bytes32 private constant GRACE_PERIOD = keccak256("GRACE_PERIOD");
    bytes32 private constant DELINQUENCY_PERIOD = keccak256("DELINQUENCY_PERIOD");
    bytes32 private constant CURVE_STEEPNESS = keccak256("CURVE_STEEPNESS");
    bytes32 private constant ADJUSTMENT_SPEED = keccak256("ADJUSTMENT_SPEED");
    bytes32 private constant TARGET_UTILIZATION = keccak256("TARGET_UTILIZATION");
    bytes32 private constant INITIAL_RATE_AT_TARGET = keccak256("INITIAL_RATE_AT_TARGET");
    bytes32 private constant MIN_RATE_AT_TARGET = keccak256("MIN_RATE_AT_TARGET");
    bytes32 private constant MAX_RATE_AT_TARGET = keccak256("MAX_RATE_AT_TARGET");
    bytes32 private constant TRANCHE_RATIO = keccak256("TRANCHE_RATIO");
    bytes32 private constant TRANCHE_SHARE_VARIANT = keccak256("TRANCHE_SHARE_VARIANT");
    bytes32 private constant SUSD3_LOCK_DURATION = keccak256("SUSD3_LOCK_DURATION");
    bytes32 private constant SUSD3_COOLDOWN_PERIOD = keccak256("SUSD3_COOLDOWN_PERIOD");
    bytes32 private constant USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");
    bytes32 private constant SUSD3_WITHDRAWAL_WINDOW = keccak256("SUSD3_WITHDRAWAL_WINDOW");
    bytes32 private constant CYCLE_DURATION = keccak256("CYCLE_DURATION");

    function setUp() public {
        owner = makeAddr("ProtocolConfigOwner");
        nonOwner = makeAddr("NonOwner");

        // Deploy proxy with initialization
        ProtocolConfig protocolConfigImpl = new ProtocolConfig();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(protocolConfigImpl),
            address(this), // Test contract acts as admin
            abi.encodeWithSelector(ProtocolConfig.initialize.selector, owner)
        );

        // Set the protocolConfig to the proxy address
        protocolConfig = ProtocolConfig(address(proxy));
        assertEq(protocolConfig.owner(), owner);
    }

    function test_SetConfig_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        protocolConfig.setConfig(MAX_LTV, 0.8 ether);
    }

    function test_SetConfig_Success() public {
        uint256 testValue = 0.8 ether;
        vm.prank(owner);
        protocolConfig.setConfig(MAX_LTV, testValue);

        assertEq(protocolConfig.config(MAX_LTV), testValue);
    }

    function test_GetIsPaused() public {
        vm.prank(owner);
        protocolConfig.setConfig(IS_PAUSED, 1);
        assertEq(protocolConfig.getIsPaused(), 1);

        vm.prank(owner);
        protocolConfig.setConfig(IS_PAUSED, 0);
        assertEq(protocolConfig.getIsPaused(), 0);
    }

    function test_GetMaxOnCredit() public {
        uint256 testValue = 0.95 ether;
        vm.prank(owner);
        protocolConfig.setConfig(MAX_ON_CREDIT, testValue);
        assertEq(protocolConfig.getMaxOnCredit(), testValue);
    }

    function test_GetCreditLineConfig() public {
        // Set up credit line config values
        vm.startPrank(owner);
        protocolConfig.setConfig(MAX_LTV, 0.8 ether);
        protocolConfig.setConfig(MAX_VV, 0.9 ether);
        protocolConfig.setConfig(MAX_CREDIT_LINE, 1e30);
        protocolConfig.setConfig(MIN_CREDIT_LINE, 1e18);
        protocolConfig.setConfig(MAX_DRP, 0.1 ether);
        vm.stopPrank();

        CreditLineConfig memory config = protocolConfig.getCreditLineConfig();

        assertEq(config.maxLTV, 0.8 ether);
        assertEq(config.maxVV, 0.9 ether);
        assertEq(config.maxCreditLine, 1e30);
        assertEq(config.minCreditLine, 1e18);
        assertEq(config.maxDRP, 0.1 ether);
    }

    function test_GetMarketConfig() public {
        // Set up market config values
        vm.startPrank(owner);
        protocolConfig.setConfig(GRACE_PERIOD, 7 days);
        protocolConfig.setConfig(DELINQUENCY_PERIOD, 23 days);
        protocolConfig.setConfig(MIN_BORROW, 1000e18);
        protocolConfig.setConfig(IRP, 0.1 ether);
        vm.stopPrank();

        MarketConfig memory config = protocolConfig.getMarketConfig();

        assertEq(config.gracePeriod, 7 days);
        assertEq(config.delinquencyPeriod, 23 days);
        assertEq(config.minBorrow, 1000e18);
        assertEq(config.irp, 0.1 ether);
    }

    function test_GetIRMConfig() public {
        // Set up IRM config values
        vm.startPrank(owner);
        protocolConfig.setConfig(CURVE_STEEPNESS, 4 ether);
        protocolConfig.setConfig(ADJUSTMENT_SPEED, 50 ether);
        protocolConfig.setConfig(TARGET_UTILIZATION, 0.9 ether);
        protocolConfig.setConfig(INITIAL_RATE_AT_TARGET, 0.04 ether);
        protocolConfig.setConfig(MIN_RATE_AT_TARGET, 0.001 ether);
        protocolConfig.setConfig(MAX_RATE_AT_TARGET, 2.0 ether);
        vm.stopPrank();

        IRMConfig memory config = protocolConfig.getIRMConfig();

        assertEq(config.curveSteepness, 4 ether);
        assertEq(config.adjustmentSpeed, 50 ether);
        assertEq(config.targetUtilization, 0.9 ether);
        assertEq(config.initialRateAtTarget, 0.04 ether);
        assertEq(config.minRateAtTarget, 0.001 ether);
        assertEq(config.maxRateAtTarget, 2.0 ether);
    }

    function test_GetTrancheRatio() public {
        uint256 testValue = 0.7 ether;
        vm.prank(owner);
        protocolConfig.setConfig(TRANCHE_RATIO, testValue);
        assertEq(protocolConfig.getTrancheRatio(), testValue);
    }

    function test_GetTrancheShareVariant() public {
        uint256 testValue = 1;
        vm.prank(owner);
        protocolConfig.setConfig(TRANCHE_SHARE_VARIANT, testValue);
        assertEq(protocolConfig.getTrancheShareVariant(), testValue);
    }

    function test_GetSusd3LockDuration() public {
        uint256 testValue = 30 days;
        vm.prank(owner);
        protocolConfig.setConfig(SUSD3_LOCK_DURATION, testValue);
        assertEq(protocolConfig.getSusd3LockDuration(), testValue);
    }

    function test_GetSusd3CooldownPeriod() public {
        uint256 testValue = 7 days;
        vm.prank(owner);
        protocolConfig.setConfig(SUSD3_COOLDOWN_PERIOD, testValue);
        assertEq(protocolConfig.getSusd3CooldownPeriod(), testValue);
    }

    function test_GetCycleDuration() public {
        uint256 testValue = 30 days;
        vm.prank(owner);
        protocolConfig.setConfig(CYCLE_DURATION, testValue);
        assertEq(protocolConfig.getCycleDuration(), testValue);
    }

    function test_GetUsd3CommitmentTime() public {
        uint256 testValue = 90 days;
        vm.prank(owner);
        protocolConfig.setConfig(USD3_COMMITMENT_TIME, testValue);
        assertEq(protocolConfig.getUsd3CommitmentTime(), testValue);
    }

    function test_GetSusd3WithdrawalWindow() public {
        uint256 testValue = 2 days; // 172800 seconds
        vm.prank(owner);
        protocolConfig.setConfig(SUSD3_WITHDRAWAL_WINDOW, testValue);
        assertEq(protocolConfig.getSusd3WithdrawalWindow(), testValue);
    }
}
