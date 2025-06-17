// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id, MarketParams, Position, Market, IMorphoCredit} from "./interfaces/IMorpho.sol";

import {Morpho} from "./Morpho.sol";

import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";

/// @notice Details for per-borrower premium tracking
/// @param lastPremiumAccrualTime Timestamp of the last premium accrual for this borrower
/// @param premiumRate Current risk premium rate in WAD (annual rate)
/// @param borrowAssetsAtLastAccrual Snapshot of borrow position at last premium accrual
struct BorrowerPremiumDetails {
    uint128 lastPremiumAccrualTime;
    uint128 premiumRate;
    uint256 borrowAssetsAtLastAccrual;
}

/// @title Morpho Credit
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice The Morpho contract.
contract MorphoCredit is Morpho, IMorphoCredit {
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    /// @inheritdoc IMorphoCredit
    address public helper;

    /// @notice Mapping of market ID to borrower address to premium details
    mapping(Id => mapping(address => BorrowerPremiumDetails)) public borrowerPremiumDetails;

    /// @notice Address authorized to set borrower premium rates (e.g., 3CA)
    address public premiumRateSetter;

    /// @notice Maximum premium rate allowed (100% APR)
    uint256 public constant MAX_PREMIUM_RATE = 1e18;

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

    /* PREMIUM RATE MANAGEMENT */

    /// @notice Modifier to restrict access to premium rate setter
    modifier onlyPremiumRateSetter() {
        require(msg.sender == premiumRateSetter, ErrorsLib.NOT_PREMIUM_RATE_SETTER);
        _;
    }

    /// @notice Set the premium rate setter address
    /// @param newSetter New premium rate setter address
    function setPremiumRateSetter(address newSetter) external onlyOwner {
        require(newSetter != premiumRateSetter, ErrorsLib.ALREADY_SET);
        premiumRateSetter = newSetter;
        emit EventsLib.PremiumRateSetterUpdated(newSetter);
    }

    /// @notice Set or update a borrower's premium rate
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @param newRate New premium rate in WAD
    function setBorrowerPremiumRate(Id id, address borrower, uint128 newRate) external onlyPremiumRateSetter {
        require(newRate <= MAX_PREMIUM_RATE, ErrorsLib.PREMIUM_RATE_TOO_HIGH);

        BorrowerPremiumDetails storage details = borrowerPremiumDetails[id][borrower];
        uint128 oldRate = details.premiumRate;

        // Accrue premium at old rate before updating
        if (oldRate > 0 && position[id][borrower].borrowShares > 0) {
            _accrueBorrowerPremium(id, borrower);
        }

        // Update rate and initialize timestamp if first time
        details.premiumRate = newRate;
        if (details.lastPremiumAccrualTime == 0) {
            details.lastPremiumAccrualTime = uint128(block.timestamp);
            // Initialize snapshot for new borrowers
            if (position[id][borrower].borrowShares > 0) {
                details.borrowAssetsAtLastAccrual = uint256(position[id][borrower].borrowShares).toAssetsUp(
                    market[id].totalBorrowAssets, market[id].totalBorrowShares
                );
            }
        }

        emit EventsLib.BorrowerPremiumRateSet(id, borrower, oldRate, newRate);
    }

    /// @notice Manually accrue premium for a borrower (callable by anyone, useful for keepers)
    /// @param id Market ID
    /// @param borrower Borrower address
    function accrueBorrowerPremium(Id id, address borrower) external {
        MarketParams memory marketParams = idToMarketParams[id];
        _accrueInterest(marketParams, id);
        _accrueBorrowerPremium(id, borrower);
    }

    /// @notice Batch accrue premiums for multiple borrowers
    /// @param id Market ID
    /// @param borrowers Array of borrower addresses
    function accruePremiumsForBorrowers(Id id, address[] calldata borrowers) external {
        MarketParams memory marketParams = idToMarketParams[id];
        _accrueInterest(marketParams, id);
        for (uint256 i = 0; i < borrowers.length; i++) {
            _accrueBorrowerPremium(id, borrowers[i]);
        }
    }

    /// @notice Accrue premium for a specific borrower
    /// @param id Market ID
    /// @param borrower Borrower address
    function _accrueBorrowerPremium(Id id, address borrower) internal {
        BorrowerPremiumDetails memory details = borrowerPremiumDetails[id][borrower];

        // Early returns for optimization
        if (details.premiumRate == 0) return;
        if (details.lastPremiumAccrualTime == block.timestamp) return;

        // Copy borrower position to memory
        Position memory borrowerPosition = position[id][borrower];
        if (borrowerPosition.borrowShares == 0) return;

        Market memory marketData = market[id];

        // Get asset amounts and time elapsed
        uint256 borrowAssetsAtLastAccrual = details.borrowAssetsAtLastAccrual;
        uint256 borrowAssetsCurrent = uint256(borrowerPosition.borrowShares).toAssetsUp(
            marketData.totalBorrowAssets, marketData.totalBorrowShares
        );
        uint256 timeElapsed = block.timestamp - details.lastPremiumAccrualTime;

        // Calculate the actual base rate that occurred over this period
        uint256 baseGrowthRatio = borrowAssetsCurrent.wDivUp(borrowAssetsAtLastAccrual);
        uint256 baseRateAnnualized = (baseGrowthRatio - WAD).wDivUp(timeElapsed * WAD / 365 days);

        // Combine observed base rate with premium rate
        uint256 premiumRateAnnual = details.premiumRate;
        uint256 combinedRateAnnual = baseRateAnnualized + premiumRateAnnual;

        // Calculate growth amounts
        uint256 baseGrowthActual = borrowAssetsCurrent - borrowAssetsAtLastAccrual;
        uint256 totalGrowthWithPremium =
            borrowAssetsAtLastAccrual.wMulDown(combinedRateAnnual.wTaylorCompounded(timeElapsed));
        uint256 premiumAmountToAdd = totalGrowthWithPremium - baseGrowthActual;

        // Convert premium to shares
        uint256 premiumShares =
            premiumAmountToAdd.toSharesUp(marketData.totalBorrowAssets, marketData.totalBorrowShares);

        // Update borrower position
        position[id][borrower].borrowShares = borrowerPosition.borrowShares + premiumShares.toUint128();

        // Update market totals
        market[id].totalBorrowShares = marketData.totalBorrowShares + premiumShares.toUint128();
        market[id].totalBorrowAssets = marketData.totalBorrowAssets + premiumAmountToAdd.toUint128();
        market[id].totalSupplyAssets = marketData.totalSupplyAssets + premiumAmountToAdd.toUint128();

        // Handle protocol fees
        uint256 feeAmount = 0;
        if (marketData.fee != 0) {
            feeAmount = premiumAmountToAdd.wMulDown(marketData.fee);
            uint256 feeShares = feeAmount.toSharesDown(
                marketData.totalSupplyAssets + premiumAmountToAdd.toUint128() - feeAmount, marketData.totalSupplyShares
            );
            position[id][feeRecipient].supplyShares += feeShares.toUint128();
            market[id].totalSupplyShares = marketData.totalSupplyShares + feeShares.toUint128();
        }

        // Update premium tracking timestamp
        borrowerPremiumDetails[id][borrower].lastPremiumAccrualTime = uint128(block.timestamp);

        emit EventsLib.PremiumAccrued(id, borrower, premiumAmountToAdd, feeAmount);
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
    function _beforeBorrow(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets, uint256 shares)
        internal
        override
    {
        // TODO: Implement premium accrual for borrower
        // This will call _accrueBorrowerPremium(id, onBehalf) once implemented
    }

    /// @inheritdoc Morpho
    function _beforeRepay(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets, uint256 shares)
        internal
        override
    {
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
    function _beforeWithdrawCollateral(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets)
        internal
        override
    {
        // TODO: Implement premium accrual for borrower if they have debt
        // This will call _accrueBorrowerPremium(id, onBehalf) once implemented
        // Only if position[id][onBehalf].borrowShares > 0
    }

    /// @inheritdoc Morpho
    function _beforeWithdraw(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets, uint256 shares)
        internal
        override
    {
        // TODO: Implement premium accrual for borrower if they have debt
        // This will call _accrueBorrowerPremium(id, onBehalf) once implemented
        // Only if position[id][onBehalf].borrowShares > 0
    }

    /// @inheritdoc Morpho
    function _afterBorrow(MarketParams memory marketParams, Id id, address onBehalf) internal override {
        // TODO: Update borrowAssetsAtLastAccrual snapshot
    }

    /// @inheritdoc Morpho
    function _afterRepay(MarketParams memory marketParams, Id id, address onBehalf) internal override {
        // TODO: Update borrowAssetsAtLastAccrual snapshot
    }

    /// @inheritdoc Morpho
    function _afterLiquidate(MarketParams memory marketParams, Id id, address borrower) internal override {
        // TODO: Update borrowAssetsAtLastAccrual snapshot
    }
}
