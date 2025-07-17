// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Initializable} from "@openzeppelin/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/access/Ownable2Step.sol";

contract ProtocolConfig is Initializable, Ownable2Step {
    // Configuration keys
    bytes32 private constant MAX_LTV = keccak256("MAX_LTV");
    bytes32 private constant MAX_CREDIT_LINE = keccak256("MAX_CREDIT_LINE");
    bytes32 private constant MIN_CREDIT_LINE = keccak256("MIN_CREDIT_LINE");
    bytes32 private constant MIN_BORROW = keccak256("MIN_BORROW");
    bytes32 private constant MAX_DRP = keccak256("MAX_DRP");
    bytes32 private constant MAX_IRP = keccak256("MAX_IRP");
    bytes32 private constant GRACE_PERIOD = keccak256("GRACE_PERIOD");
    bytes32 private constant DELINQUENCY_PERIOD = keccak256("DELINQUENCY_PERIOD");
    bytes32 private constant IS_PAUSED = keccak256("IS_PAUSED");
    bytes32 private constant MAX_OC = keccak256("MAX_OC");
    bytes32 private constant TRANCHE_RATIO = keccak256("TRANCHE_RATIO");
    bytes32 private constant TRANCHE_SHARE_VARIANT = keccak256("TRANCHE_SHARE_VARIANT");
    bytes32 private constant SUSD3_LOCK_DURATION = keccak256("SUSD3_LOCK_DURATION");
    bytes32 private constant SUSD3_COOLDOWN_PERIOD = keccak256("SUSD3_COOLDOWN_PERIOD");

    /// @dev Configuration storage mapping
    mapping(bytes32 => uint256) public config;

    /// @dev Storage gap for future upgrades (20 slots).
    uint256[20] private __gap;

    /// @dev Initialize the contract with the owner
    /// @param newOwner The address of the new owner
    function initialize(address newOwner) external initializer {
        _transferOwnership(newOwner);
    }

    /// @dev Set a configuration value
    /// @param key The configuration key
    /// @param value The configuration value
    function setConfig(bytes32 key, uint256 value) external onlyOwner {
        config[key] = value;
    }

    // External getters for each parameter
    function getMaxLTV() external view returns (uint256) {
        return config[MAX_LTV];
    }

    function getMaxCreditLine() external view returns (uint256) {
        return config[MAX_CREDIT_LINE];
    }

    function getMinCreditLine() external view returns (uint256) {
        return config[MIN_CREDIT_LINE];
    }

    function getMinBorrow() external view returns (uint256) {
        return config[MIN_BORROW];
    }

    function getMaxDRP() external view returns (uint256) {
        return config[MAX_DRP];
    }

    function getMaxIRP() external view returns (uint256) {
        return config[MAX_IRP];
    }

    function getGracePeriod() external view returns (uint256) {
        return config[GRACE_PERIOD];
    }

    function getDelinquencyPeriod() external view returns (uint256) {
        return config[DELINQUENCY_PERIOD];
    }

    function getIsPaused() external view returns (uint256) {
        return config[IS_PAUSED];
    }

    function getMaxOC() external view returns (uint256) {
        return config[MAX_OC];
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
