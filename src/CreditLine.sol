// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {Id, IMorphoCredit} from "./interfaces/IMorpho.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {IProver} from "./interfaces/IProver.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @title CreditLine
/// @author Morpho Labs
/// @custom:contact security@morpho.org
contract CreditLine is ICreditLine {
    /// @notice Maximum premium rate allowed per second (100% APR / 365 days)
    /// @dev ~31.7 billion per second for 100% APR
    uint256 internal constant MAX_PREMIUM_RATE = 31709791983;

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
        if (newMorpho == address(0)) revert ErrorsLib.ZeroAddress();
        if (newOwner == address(0)) revert ErrorsLib.ZeroAddress();
        morpho = newMorpho;
        owner = newOwner;
        ozd = newOzd;
        prover = newProver;
        emit EventsLib.SetOwner(newOwner);
    }

    /// @dev Reverts if the caller is not the owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrorsLib.NotOwner();
        _;
    }

    /* ONLY OWNER FUNCTIONS */
    /// @inheritdoc ICreditLine
    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == owner) revert ErrorsLib.AlreadySet();

        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /// @inheritdoc ICreditLine
    function setOzd(address newOzd) external onlyOwner {
        if (newOzd == ozd) revert ErrorsLib.AlreadySet();

        ozd = newOzd;
    }

    /// @inheritdoc ICreditLine
    function setProver(address newProver) external onlyOwner {
        if (newProver == prover) revert ErrorsLib.AlreadySet();

        prover = newProver;
    }

    /// @inheritdoc ICreditLine
    function setCreditLine(Id id, address borrower, uint256 credit, uint128 premiumRate) external {
        if (msg.sender != owner && msg.sender != ozd) revert ErrorsLib.NotOwnerOrOzd();
        if (prover != address(0) && !IProver(prover).isSafeTVV(borrower, credit)) revert ErrorsLib.UnsafeTvv();
        if (premiumRate > MAX_PREMIUM_RATE) revert ErrorsLib.PremiumRateTooHigh();
        IMorphoCredit(morpho).setCreditLine(id, borrower, credit, premiumRate);
    }
}
