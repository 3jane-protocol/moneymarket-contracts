// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMorphoCredit} from "./interfaces/IMorpho.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @title CreditLine
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice The Morpho contract.
contract CreditLine is ICreditLine {
    /// @inheritdoc ICreditLine
    address public owner;

    /// @inheritdoc ICreditLine
    address public ozd;

    /// @inheritdoc ICreditLine
    address public morpho;

    /* CONSTRUCTOR */

    /// @param newOwner The new owner of the contract.
    constructor(address newMorpho, address newOwner, address newOzd) {
        require(morpho != address(0), ErrorsLib.ZERO_ADDRESS);
        require(newOwner != address(0), ErrorsLib.ZERO_ADDRESS);
        require(newOzd != address(0), ErrorsLib.ZERO_ADDRESS);
        morpho = newMorpho;
        owner = newOwner;
        ozd = newOzd;
        emit EventsLib.SetOwner(newOwner);
    }

    /// @dev Reverts if the caller is not the owner.
    modifier onlyOwner() {
        require(msg.sender == owner, ErrorsLib.NOT_OWNER);
        _;
    }

    /* ONLY OWNER FUNCTIONS */
    /// @inheritdoc ICreditLine
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != owner, ErrorsLib.ALREADY_SET);

        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /// @inheritdoc ICreditLine
    function setOzd(address newOzd) external onlyOwner {
        require(newOzd != ozd, ErrorsLib.ALREADY_SET);

        ozd = newOzd;
    }

    /// @inheritdoc ICreditLine
    function setCreditLine(MarketParams memory marketParams, address borrower, uint256 credit) external {
        require(msg.sender == owner || msg.sender == ozd, ErrorsLib.NOT_OWNER_OR_OZD);
        IMorphoCredit(morpho).setCreditLine(marketParams, borrower, credit);
    }
}
