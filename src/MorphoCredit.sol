// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id, MarketParams, IMorphoCredit} from "./interfaces/IMorpho.sol";

import {Morpho} from "./Morpho.sol";

import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";

/// @title Morpho Credit
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice The Morpho contract.
contract MorphoCredit is Morpho, IMorphoCredit {
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;

    constructor(address newOwner) Morpho(newOwner) {}

    /* ONLY CREDIT LINE FUNCTIONS */

    /// @inheritdoc IMorphoCredit
    function setCreditLine(MarketParams memory marketParams, address borrower, uint256 credit) external {
        require(marketParams.creditLine == msg.sender, ErrorsLib.NOT_CREDIT_LINE);

        Id id = marketParams.id();

        position[id][borrower].collateral = credit.toUint128();

        emit EventsLib.SetCreditLine(id, borrower, credit);
    }
}
