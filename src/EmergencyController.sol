// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.18;

import {Id, MarketParams} from "./interfaces/IMorpho.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {CreditLine} from "./CreditLine.sol";
import {Ownable} from "../lib/openzeppelin/contracts/access/Ownable.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ProtocolConfigLib} from "./libraries/ProtocolConfigLib.sol";

interface IProtocolConfigEmergency {
    function setEmergencyConfig(bytes32 key, uint256 value) external;
}

/// @title EmergencyController
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Emergency controller for immediate protocol safety actions
/// @dev Provides binary stop controls and credit line revocation capabilities
/// @dev Key emergency actions:
/// - Pause protocol: Stops all borrowing operations
/// - Stop borrowing: Sets DEBT_CAP to 0
/// - Stop deployments: Sets MAX_ON_CREDIT to 0 (prevents USD3 from deploying to MorphoCredit)
/// - Stop deposits: Sets USD3_SUPPLY_CAP to 0
/// - Revoke credit: Remove individual borrower's credit line
contract EmergencyController is Ownable {
    // Custom events
    event EmergencyPauseActivated(address indexed executor);
    event BorrowingStopped(address indexed executor);
    event DeploymentsStopped(address indexed executor);
    event DepositsStopped(address indexed executor);
    event CreditLineRevoked(address indexed borrower, address indexed executor);

    /// @notice Address of the ProtocolConfig contract
    IProtocolConfigEmergency public immutable protocolConfig;

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
        protocolConfig = IProtocolConfigEmergency(_protocolConfig);
        creditLine = ICreditLine(_creditLine);
    }

    // ============ Emergency Stop Functions ============

    /// @notice Pause the entire protocol
    /// @dev Sets IS_PAUSED = 1, preventing all borrowing operations
    function emergencyPause() external onlyOwner {
        protocolConfig.setEmergencyConfig(ProtocolConfigLib.IS_PAUSED, 1);
        emit EmergencyPauseActivated(msg.sender);
    }

    /// @notice Stop all new borrowing
    /// @dev Sets DEBT_CAP = 0, preventing new borrows
    function emergencyStopBorrowing() external onlyOwner {
        protocolConfig.setEmergencyConfig(ProtocolConfigLib.DEBT_CAP, 0);
        emit BorrowingStopped(msg.sender);
    }

    /// @notice Stop USD3 deployments to MorphoCredit markets
    /// @dev Sets MAX_ON_CREDIT = 0, preventing USD3 strategy from deploying funds to credit markets
    /// @dev This protects lenders by keeping funds in the strategy rather than lending them out
    /// @dev Does NOT affect existing deployed funds or borrower credit lines
    function emergencyStopDeployments() external onlyOwner {
        protocolConfig.setEmergencyConfig(ProtocolConfigLib.MAX_ON_CREDIT, 0);
        emit DeploymentsStopped(msg.sender);
    }

    /// @notice Stop all new deposits to USD3
    /// @dev Sets USD3_SUPPLY_CAP = 0, preventing new deposits
    function emergencyStopUsd3Deposits() external onlyOwner {
        protocolConfig.setEmergencyConfig(ProtocolConfigLib.USD3_SUPPLY_CAP, 0);
        emit DepositsStopped(msg.sender);
    }

    // ============ Credit Line Control ============

    /// @notice Revoke a single borrower's credit line
    /// @param id Market ID
    /// @param borrower Address to revoke credit from
    /// @dev Sets the borrower's credit line to 0, preventing further borrowing
    function emergencyRevokeCreditLine(Id id, address borrower) external onlyOwner {
        if (borrower == address(0)) revert ErrorsLib.ZeroAddress();

        Id[] memory ids = new Id[](1);
        address[] memory borrowers = new address[](1);
        uint256[] memory vv = new uint256[](1);
        uint256[] memory credit = new uint256[](1);
        uint128[] memory drp = new uint128[](1);

        ids[0] = id;
        borrowers[0] = borrower;
        vv[0] = 1; // Set minimal vv to avoid division by zero in LTV check
        credit[0] = 0; // Revoke credit
        drp[0] = 0;

        creditLine.setCreditLines(ids, borrowers, vv, credit, drp);
        emit CreditLineRevoked(borrower, msg.sender);
    }
}
