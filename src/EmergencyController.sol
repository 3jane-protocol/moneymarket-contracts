// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.18;

import {Id, MarketParams} from "./interfaces/IMorpho.sol";
import {IMorphoCredit} from "./interfaces/IMorpho.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {CreditLine} from "./CreditLine.sol";
import {Ownable} from "../lib/openzeppelin/contracts/access/Ownable.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ProtocolConfigLib} from "./libraries/ProtocolConfigLib.sol";

/// @title EmergencyController
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Emergency controller for immediate protocol safety actions
/// @dev Provides binary stop controls via setConfig() and credit line revocation
/// @dev setConfig() enforces binary constraints through ProtocolConfig.setEmergencyConfig():
/// - IS_PAUSED: Can only be set to 1 (pause protocol)
/// - DEBT_CAP: Can only be set to 0 (stop new borrowing)
/// - MAX_ON_CREDIT: Can only be set to 0 (stop USD3 deployments to MorphoCredit)
/// - USD3_SUPPLY_CAP: Can only be set to 0 (stop new deposits)
/// @dev emergencyRevokeCreditLine() removes individual borrower's credit line while preserving DRP
contract EmergencyController is Ownable {
    // Custom events
    event CreditLineRevoked(address indexed borrower, address indexed executor);

    /// @notice Address of the ProtocolConfig contract
    IProtocolConfig public immutable protocolConfig;

    /// @notice Address of the CreditLine contract
    ICreditLine public immutable creditLine;

    /// @notice Constructor to set immutable addresses
    /// @param _protocolConfig Address of the ProtocolConfig contract
    /// @param _creditLine Address of the CreditLine contract
    /// @param _owner Initial owner address (emergency multisig)
    constructor(address _protocolConfig, address _creditLine, address _owner) Ownable(_owner) {
        if (_protocolConfig == address(0) || _creditLine == address(0) || _owner == address(0)) {
            revert ErrorsLib.ZeroAddress();
        }
        protocolConfig = IProtocolConfig(_protocolConfig);
        creditLine = ICreditLine(_creditLine);
    }

    // ============ Emergency Stop Functions ============

    /// @notice Set emergency configuration with binary constraints
    /// @param key Configuration key (IS_PAUSED, DEBT_CAP, MAX_ON_CREDIT, USD3_SUPPLY_CAP)
    /// @param value Configuration value (binary constraints enforced by ProtocolConfig)
    /// @dev IS_PAUSED can only be set to 1, others can only be set to 0
    function setConfig(bytes32 key, uint256 value) external onlyOwner {
        protocolConfig.setEmergencyConfig(key, value);
    }

    // ============ Credit Line Control ============

    /// @notice Revoke a single borrower's credit line
    /// @param id Market ID
    /// @param borrower Address to revoke credit from
    /// @dev Sets the borrower's credit line to 0, preventing further borrowing
    /// @dev Preserves the borrower's existing DRP rate so they continue paying risk premium on existing debt
    function emergencyRevokeCreditLine(Id id, address borrower) external onlyOwner {
        if (borrower == address(0)) revert ErrorsLib.ZeroAddress();

        // Query the borrower's current DRP to preserve it
        address morpho = creditLine.MORPHO();
        (, uint128 currentDrp,) = IMorphoCredit(morpho).borrowerPremium(id, borrower);

        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = id;
        borrowers[0] = borrower;
        vv[0] = 1; // Set minimal vv to avoid division by zero in LTV check
        credit[0] = 0; // Revoke credit
        drp[0] = currentDrp; // Preserve existing DRP rate

        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
        emit CreditLineRevoked(borrower, msg.sender);
    }
}
