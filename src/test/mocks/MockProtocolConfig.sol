// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IProtocolConfig, MarketConfig, CreditLineConfig, IRMConfig} from "@3jane-morpho-blue/interfaces/IProtocolConfig.sol";

/**
 * @title MockProtocolConfig
 * @notice Mock implementation of ProtocolConfig for testing USD3/sUSD3 strategies
 */
contract MockProtocolConfig is IProtocolConfig {
    mapping(bytes32 => uint256) public config;
    address public owner;

    // Configuration keys
    bytes32 private constant TRANCHE_RATIO = keccak256("TRANCHE_RATIO");
    bytes32 private constant TRANCHE_SHARE_VARIANT =
        keccak256("TRANCHE_SHARE_VARIANT");
    bytes32 private constant SUSD3_LOCK_DURATION =
        keccak256("SUSD3_LOCK_DURATION");
    bytes32 private constant SUSD3_COOLDOWN_PERIOD =
        keccak256("SUSD3_COOLDOWN_PERIOD");
    bytes32 private constant IS_PAUSED = keccak256("IS_PAUSED");
    bytes32 private constant MAX_ON_CREDIT = keccak256("MAX_ON_CREDIT");
    bytes32 private constant GRACE_PERIOD = keccak256("GRACE_PERIOD");
    bytes32 private constant DELINQUENCY_PERIOD =
        keccak256("DELINQUENCY_PERIOD");
    bytes32 private constant MIN_BORROW = keccak256("MIN_BORROW");
    bytes32 private constant IRP = keccak256("IRP");

    constructor() {
        owner = msg.sender;

        // Set default values for testing
        config[TRANCHE_RATIO] = 1500; // 15% subordination ratio
        config[TRANCHE_SHARE_VARIANT] = 2000; // 20% performance fee to sUSD3
        config[SUSD3_LOCK_DURATION] = 90 days;
        config[SUSD3_COOLDOWN_PERIOD] = 7 days;
        config[MAX_ON_CREDIT] = 10000; // 100%
        config[GRACE_PERIOD] = 7 days;
        config[DELINQUENCY_PERIOD] = 30 days;
        config[MIN_BORROW] = 100e6; // 100 USDC minimum
    }

    function initialize(address newOwner) external {
        require(owner == address(0), "Already initialized");
        owner = newOwner;
    }

    function setConfig(bytes32 key, uint256 value) external {
        require(msg.sender == owner, "Not owner");
        config[key] = value;
    }

    function getIsPaused() external view returns (uint256) {
        return config[IS_PAUSED];
    }

    function getMaxOnCredit() external view returns (uint256) {
        return config[MAX_ON_CREDIT];
    }

    function getCreditLineConfig()
        external
        view
        returns (CreditLineConfig memory)
    {
        return
            CreditLineConfig({
                maxLTV: 0,
                maxVV: 0,
                maxCreditLine: 0,
                minCreditLine: 0,
                maxDRP: 0
            });
    }

    function getMarketConfig() external view returns (MarketConfig memory) {
        return
            MarketConfig({
                gracePeriod: config[GRACE_PERIOD],
                delinquencyPeriod: config[DELINQUENCY_PERIOD],
                minBorrow: config[MIN_BORROW],
                irp: config[IRP]
            });
    }

    function getIRMConfig() external view returns (IRMConfig memory) {
        return
            IRMConfig({
                curveSteepness: 0,
                adjustmentSpeed: 0,
                targetUtilization: 0,
                initialRateAtTarget: 0,
                minRateAtTarget: 0,
                maxRateAtTarget: 0
            });
    }

    function getTrancheRatio() external view returns (uint256) {
        return config[TRANCHE_RATIO];
    }

    function getTrancheShareVariant() external view returns (uint256) {
        return config[TRANCHE_SHARE_VARIANT];
    }

    function getSusd3LockDuration() external view returns (uint256) {
        return config[SUSD3_LOCK_DURATION];
    }

    function getSusd3CooldownPeriod() external view returns (uint256) {
        return config[SUSD3_COOLDOWN_PERIOD];
    }
}
