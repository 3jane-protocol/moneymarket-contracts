// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id, IMorphoCredit} from "./interfaces/IMorpho.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {CreditLineConfig} from "./interfaces/IProtocolConfig.sol";
import {IProver} from "./interfaces/IProver.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

/// @title CreditLine
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice This contract manages credit line operations for the Morpho protocol
/// @dev Handles credit line creation, validation, and configuration management
contract CreditLine is ICreditLine, Ownable {
    using MathLib for uint256;

    /// @notice Maximum premium rate allowed per second (100% APR / 365 days)
    /// @dev ~31.7 billion per second for 100% APR
    uint256 private constant MAX_DRP = 31709791983;

    /// @notice Address of the OZ Defender
    /// @inheritdoc ICreditLine
    address private ozd;

    /// @notice Address of the prover contract for additional verification
    /// @dev Prover can be set to address(0) to disable verification
    /// @inheritdoc ICreditLine
    address private prover;

    /// @inheritdoc ICreditLine
    IMorphoCredit private immutable MORPHO;

    /* CONSTRUCTOR */
    /// @notice Initializes the CreditLine contract with required addresses
    /// @param morpho Address of the main Morpho Credit contract
    /// @param owner Address that will have owner privileges
    /// @param ozd Address of the OZD contract for external touch
    /// @param prover Address of the prover contract (can be address(0))
    /// @dev Validates all non-zero addresses and transfers ownership to the specified owner
    constructor(address morpho, address owner, address ozd, address prover) {
        // Validate that critical addresses are not zero
        if (morpho == address(0)) revert ErrorsLib.ZeroAddress();
        if (owner == address(0)) revert ErrorsLib.ZeroAddress();
        if (ozd == address(0)) revert ErrorsLib.ZeroAddress();

        // Initialize contract state
        MORPHO = IMorphoCredit(morpho);
        ozd = ozd;
        prover = prover;
        _transferOwnership(owner);
    }

    /// @dev Reverts if the caller is not the owner
    /// @notice Ensures only the contract owner can execute privileged functions
    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrorsLib.NotOwner();
        _;
    }

    /// @notice Updates the OZD contract address
    /// @param newOzd New address for the OZD contract
    /// @dev Only callable by the contract owner
    /// @dev Reverts if the new address is the same as the current one
    /// @inheritdoc ICreditLine
    function setOzd(address newOzd) external onlyOwner {
        if (newOzd == ozd) revert ErrorsLib.AlreadySet();

        ozd = newOzd;
    }

    /// @notice Updates the prover contract address
    /// @param newProver New address for the prover contract
    /// @dev Only callable by the contract owner
    /// @dev Reverts if the new address is the same as the current one
    /// @dev Can be set to address(0) to disable verification
    /// @inheritdoc ICreditLine
    function setProver(address newProver) external onlyOwner {
        if (newProver == prover) revert ErrorsLib.AlreadySet();

        prover = newProver;
    }

    /// @notice Sets or updates a credit line for a specific borrower
    /// @param id Unique identifier for the credit line
    /// @param borrower Address of the borrower
    /// @param vv Value verified for the credit line
    /// @param credit Maximum credit amount that can be borrowed
    /// @param drp Default risk premium (interest rate) for the credit line
    /// @dev Only callable by owner or OZD contract
    /// @dev Validates all parameters against protocol limits and constraints
    /// @dev Calls the main Morpho contract to set the credit line
    /// @inheritdoc ICreditLine
    function setCreditLine(Id id, address borrower, uint256 vv, uint256 credit, uint128 drp) external {
        // Check authorization - only owner or OZD can set credit lines
        if (msg.sender != owner && msg.sender != ozd) revert ErrorsLib.NotOwnerOrOzd();

        // Verify the credit line parameters if a prover is set
        if (prover != address(0) && !IProver(prover).verify(id, borrower, vv, credit, drp)) {
            revert ErrorsLib.Unverified();
        }

        // Get protocol configuration for validation
        CreditLineConfig memory terms = IProtocolConfig(MORPHO.protocolConfig()).getCreditLineConfig();

        // Validate value verified against maximum allowed
        if (vv > terms.maxVV) revert ErrorsLib.MaxVvExceeded();

        // Validate credit amount against minimum and maximum limits
        if (credit > terms.maxCreditLine) revert ErrorsLib.MaxCreditLineExceeded();
        if (credit < terms.minCreditLine) revert ErrorsLib.MinCreditLineExceeded();

        // Validate loan-to-value ratio (LTV) - credit/vv must not exceed maxLTV
        if (credit.wDivDown(vv) > terms.maxLTV) revert ErrorsLib.MaxLtvExceeded();

        // Validate default risk premium against both contract and protocol limits
        if (drp > MAX_DRP || drp > terms.maxDRP) revert ErrorsLib.MaxDrpExceeded();

        // Set the credit line in the main Morpho contract
        IMorphoCredit(MORPHO).setCreditLine(id, borrower, credit, drp);
    }
}
