// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Initializable} from "../lib/openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MarketConfig, CreditLineConfig, IRMConfig} from "./interfaces/IProtocolConfig.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @title ProtocolConfig
/// @author 3Jane
/// @custom:contact support@3jane.xyz
contract ProtocolConfig is Initializable {
    // Custom errors for emergency functions
    error EmergencyCanOnlyPause();
    error EmergencyCanOnlySetToZero();
    error UnauthorizedEmergencyConfig();

    // Custom events for emergency actions
    event EmergencyAdminSet(address indexed emergencyAdmin);

    // Configuration keys
    // Credit Line
    bytes32 private constant MAX_LTV = keccak256("MAX_LTV");
    bytes32 private constant MAX_VV = keccak256("MAX_VV");
    bytes32 private constant MAX_CREDIT_LINE = keccak256("MAX_CREDIT_LINE");
    bytes32 private constant MIN_CREDIT_LINE = keccak256("MIN_CREDIT_LINE");
    bytes32 private constant MAX_DRP = keccak256("MAX_DRP");
    // Market
    bytes32 private constant IS_PAUSED = keccak256("IS_PAUSED");
    bytes32 private constant DEBT_CAP = keccak256("DEBT_CAP");
    bytes32 private constant IRP = keccak256("IRP");
    bytes32 private constant MIN_BORROW = keccak256("MIN_BORROW");
    bytes32 private constant GRACE_PERIOD = keccak256("GRACE_PERIOD");
    bytes32 private constant DELINQUENCY_PERIOD = keccak256("DELINQUENCY_PERIOD");
    bytes32 private constant CYCLE_DURATION = keccak256("CYCLE_DURATION");
    // IRM
    bytes32 private constant CURVE_STEEPNESS = keccak256("CURVE_STEEPNESS");
    bytes32 private constant ADJUSTMENT_SPEED = keccak256("ADJUSTMENT_SPEED");
    bytes32 private constant TARGET_UTILIZATION = keccak256("TARGET_UTILIZATION");
    bytes32 private constant INITIAL_RATE_AT_TARGET = keccak256("INITIAL_RATE_AT_TARGET");
    bytes32 private constant MIN_RATE_AT_TARGET = keccak256("MIN_RATE_AT_TARGET");
    bytes32 private constant MAX_RATE_AT_TARGET = keccak256("MAX_RATE_AT_TARGET");
    // USD3 & sUSD3
    bytes32 private constant MAX_ON_CREDIT = keccak256("MAX_ON_CREDIT");
    bytes32 private constant TRANCHE_RATIO = keccak256("TRANCHE_RATIO");
    bytes32 private constant TRANCHE_SHARE_VARIANT = keccak256("TRANCHE_SHARE_VARIANT");
    bytes32 private constant SUSD3_LOCK_DURATION = keccak256("SUSD3_LOCK_DURATION");
    bytes32 private constant SUSD3_COOLDOWN_PERIOD = keccak256("SUSD3_COOLDOWN_PERIOD");
    bytes32 private constant USD3_COMMITMENT_TIME = keccak256("USD3_COMMITMENT_TIME");
    bytes32 private constant SUSD3_WITHDRAWAL_WINDOW = keccak256("SUSD3_WITHDRAWAL_WINDOW");
    bytes32 private constant USD3_SUPPLY_CAP = keccak256("USD3_SUPPLY_CAP");
    // Callable Credit
    bytes32 private constant CC_FROZEN = keccak256("CC_FROZEN");
    bytes32 private constant CC_DEBT_CAP_BPS = keccak256("CC_DEBT_CAP_BPS");
    bytes32 private constant CC_CREDIT_LINE_BPS = keccak256("CC_CREDIT_LINE_BPS");

    /// @dev Configuration storage mapping
    mapping(bytes32 => uint256) public config;

    address public owner;
    address public emergencyAdmin;

    /// @dev Storage gap for future upgrades
    uint256[19] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Initialize the contract with the owner
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert ErrorsLib.ZeroAddress();
        owner = _owner;
    }

    /// @dev Set owner
    function setOwner(address _owner) external {
        if (msg.sender != owner) revert ErrorsLib.NotOwner();
        owner = _owner;
        emit EventsLib.SetOwner(_owner);
    }

    /// @dev Set a configuration value
    /// @param key The configuration key
    /// @param value The configuration value
    function setConfig(bytes32 key, uint256 value) external {
        if (msg.sender != owner) revert ErrorsLib.NotOwner();
        config[key] = value;
    }

    /// @dev Set the emergency admin address
    /// @param _emergencyAdmin The new emergency admin address
    function setEmergencyAdmin(address _emergencyAdmin) external {
        if (msg.sender != owner) revert ErrorsLib.NotOwner();
        emergencyAdmin = _emergencyAdmin;
        emit EmergencyAdminSet(_emergencyAdmin);
    }

    /// @dev Set emergency configuration with binary constraints
    /// @param key The configuration key
    /// @param value The configuration value (restricted to binary values)
    /// @notice Emergency parameters and their effects:
    /// - IS_PAUSED: Set to 1 to pause all borrowing operations
    /// - CC_FROZEN: Set to 1 to freeze all callable credit operations
    /// - DEBT_CAP: Set to 0 to prevent new borrows
    /// - MAX_ON_CREDIT: Set to 0 to stop USD3 deployments to MorphoCredit (protects lenders)
    /// - USD3_SUPPLY_CAP: Set to 0 to prevent new USD3 deposits
    function setEmergencyConfig(bytes32 key, uint256 value) external {
        if (msg.sender != owner && msg.sender != emergencyAdmin) {
            revert ErrorsLib.Unauthorized();
        }
        // IS_PAUSED, CC_FROZEN: can only set to 1 (pause/freeze)
        if (key == IS_PAUSED || key == CC_FROZEN) {
            if (value != 1) revert EmergencyCanOnlyPause();
        }
        // All other emergency params: can only set to 0 (full stop)
        else if (key == DEBT_CAP || key == MAX_ON_CREDIT || key == USD3_SUPPLY_CAP) {
            if (value != 0) revert EmergencyCanOnlySetToZero();
        }
        // Parameter not allowed for emergency admin
        else {
            revert UnauthorizedEmergencyConfig();
        }

        config[key] = value;
    }

    // Credit Line getters
    function getCreditLineConfig() external view returns (CreditLineConfig memory) {
        return CreditLineConfig({
            maxLTV: config[MAX_LTV],
            maxVV: config[MAX_VV],
            maxCreditLine: config[MAX_CREDIT_LINE],
            minCreditLine: config[MIN_CREDIT_LINE],
            maxDRP: config[MAX_DRP]
        });
    }

    // Market getters
    function getIsPaused() external view returns (uint256) {
        return config[IS_PAUSED];
    }

    function getMaxOnCredit() external view returns (uint256) {
        return config[MAX_ON_CREDIT];
    }

    function getMarketConfig() external view returns (MarketConfig memory) {
        return MarketConfig({
            gracePeriod: config[GRACE_PERIOD],
            delinquencyPeriod: config[DELINQUENCY_PERIOD],
            minBorrow: config[MIN_BORROW],
            irp: config[IRP]
        });
    }

    function getCycleDuration() external view returns (uint256) {
        return config[CYCLE_DURATION];
    }

    // IRM getters
    function getIRMConfig() external view returns (IRMConfig memory) {
        return IRMConfig({
            curveSteepness: config[CURVE_STEEPNESS],
            adjustmentSpeed: config[ADJUSTMENT_SPEED],
            targetUtilization: config[TARGET_UTILIZATION],
            initialRateAtTarget: config[INITIAL_RATE_AT_TARGET],
            minRateAtTarget: config[MIN_RATE_AT_TARGET],
            maxRateAtTarget: config[MAX_RATE_AT_TARGET]
        });
    }

    // USD3 & sUSD3 getters
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

    function getUsd3CommitmentTime() external view returns (uint256) {
        return config[USD3_COMMITMENT_TIME];
    }

    function getSusd3WithdrawalWindow() external view returns (uint256) {
        return config[SUSD3_WITHDRAWAL_WINDOW];
    }

    function getUsd3SupplyCap() external view returns (uint256) {
        return config[USD3_SUPPLY_CAP];
    }

    // Callable Credit getters
    function getCcFrozen() external view returns (uint256) {
        return config[CC_FROZEN];
    }
}
