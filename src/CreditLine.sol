// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMorphoCredit} from "./interfaces/IMorpho.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {IProver} from "./interfaces/IProver.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @title CreditLine
/// @author Morpho Labs
/// @custom:contact security@morpho.org
contract CreditLine is ICreditLine {
    /// @inheritdoc ICreditLine
    address public owner;

    /// @inheritdoc ICreditLine
    address public ozd;

    /// @inheritdoc ICreditLine
    address public prover;

    /// @inheritdoc ICreditLine
    address public morpho;

    /* CONSTRUCTOR */

    constructor(address newMorpho, address newOwner, address newOzd, address newProver) {
        require(newMorpho != address(0), ErrorsLib.ZERO_ADDRESS);
        require(newOwner != address(0), ErrorsLib.ZERO_ADDRESS);
        morpho = newMorpho;
        owner = newOwner;
        ozd = newOzd;
        prover = newProver;
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
    function setProver(address newProver) external onlyOwner {
        require(newProver != prover, ErrorsLib.ALREADY_SET);

        prover = newProver;
    }

    /// @inheritdoc ICreditLine
    function setCreditLine(MarketParams memory marketParams, address borrower, uint256 credit) external {
        require(msg.sender == owner || msg.sender == ozd, ErrorsLib.NOT_OWNER_OR_OZD);
        require(prover == address(0) || IProver(prover).isSafeTVV(borrower, credit), ErrorsLib.UNSAFE_TVV);
        IMorphoCredit(morpho).setCreditLine(marketParams, borrower, credit);
    }
}
