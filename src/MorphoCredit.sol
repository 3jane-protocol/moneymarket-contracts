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

    /// @inheritdoc IMorphoCredit
    address public helper;

    constructor(address newOwner) Morpho(newOwner) {}

    /// @inheritdoc IMorphoCredit
    function setHelper(address newHelper) external onlyOwner {
        require(newHelper != helper, ErrorsLib.ALREADY_SET);

        helper = newHelper;

        emit EventsLib.SetHelper(newHelper);
    }

    /// @inheritdoc IMorphoCredit
    function setAuthorizationV2(address authorizee, bool newIsAuthorized) external {
        require(msg.sender == helper, ErrorsLib.NOT_HELPER);
        require(newIsAuthorized != isAuthorized[authorizee][helper], ErrorsLib.ALREADY_SET);

        isAuthorized[authorizee][helper] = newIsAuthorized;

        emit EventsLib.SetAuthorization(msg.sender, authorizee, helper, newIsAuthorized);
    }

    /* ONLY CREDIT LINE FUNCTIONS */

    /// @inheritdoc IMorphoCredit
    function setCreditLine(Id id, address borrower, uint256 credit) external {
        require(idToMarketParams[id].creditLine == msg.sender, ErrorsLib.NOT_CREDIT_LINE);

        position[id][borrower].collateral = credit.toUint128();

        emit EventsLib.SetCreditLine(id, borrower, credit);
    }

    /* HOOK IMPLEMENTATIONS */

    /// @inheritdoc Morpho
    function _beforeBorrow(
        MarketParams memory marketParams,
        Id id,
        address onBehalf,
        uint256 assets,
        uint256 shares
    ) internal override {
        // TODO: Implement premium accrual for borrower
        // This will call _accrueBorrowerPremium(id, onBehalf) once implemented
    }

    /// @inheritdoc Morpho
    function _beforeRepay(
        MarketParams memory marketParams,
        Id id,
        address onBehalf,
        uint256 assets,
        uint256 shares
    ) internal override {
        // TODO: Implement premium accrual for borrower
        // This will call _accrueBorrowerPremium(id, onBehalf) once implemented
    }

    /// @inheritdoc Morpho
    function _beforeLiquidate(
        MarketParams memory marketParams,
        Id id,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) internal override {
        // TODO: Implement premium accrual for borrower
        // This will call _accrueBorrowerPremium(id, borrower) once implemented
    }

    /// @inheritdoc Morpho
    function _beforeWithdrawCollateral(
        MarketParams memory marketParams,
        Id id,
        address onBehalf,
        uint256 assets
    ) internal override {
        // TODO: Implement premium accrual for borrower if they have debt
        // This will call _accrueBorrowerPremium(id, onBehalf) once implemented
        // Only if position[id][onBehalf].borrowShares > 0
    }

    /// @inheritdoc Morpho
    function _beforeWithdraw(
        MarketParams memory marketParams,
        Id id,
        address onBehalf,
        uint256 assets,
        uint256 shares
    ) internal override {
        // TODO: Implement premium accrual for borrower if they have debt
        // This will call _accrueBorrowerPremium(id, onBehalf) once implemented
        // Only if position[id][onBehalf].borrowShares > 0
    }

    /// @inheritdoc Morpho
    function _afterBorrow(
        MarketParams memory marketParams,
        Id id,
        address onBehalf
    ) internal override {
        // TODO: Update borrowAssetsAtLastAccrual snapshot
    }

    /// @inheritdoc Morpho
    function _afterRepay(
        MarketParams memory marketParams,
        Id id,
        address onBehalf
    ) internal override {
        // TODO: Update borrowAssetsAtLastAccrual snapshot
    }

    /// @inheritdoc Morpho
    function _afterLiquidate(
        MarketParams memory marketParams,
        Id id,
        address borrower
    ) internal override {
        // TODO: Update borrowAssetsAtLastAccrual snapshot
    }
}
