// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {Id, MarketParams, Position, Market, BorrowerPremium, IMorphoCredit} from "./interfaces/IMorpho.sol";

import {Morpho} from "./Morpho.sol";

import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";

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

    /// @inheritdoc IMorphoCredit
    mapping(Id => mapping(address => BorrowerPremium)) public borrowerPremium;

    /// @notice Minimum premium amount to accrue (prevents precision loss)
    uint256 internal constant MIN_PREMIUM_THRESHOLD = 1;

    /// @notice Maximum elapsed time for premium accrual (365 days)
    /// @dev This limit serves multiple purposes:
    /// 1. Maintains accuracy of wTaylorCompounded approximation (error < 8% for periods up to 365 days)
    /// 2. Prevents numerical overflow when combined with MAX_PREMIUM_RATE (100% APR)
    /// 3. Protects against runaway debt accumulation on abandoned positions
    /// 4. Aligns with the test bounds in MathLibTest which validate behavior up to 365 days
    uint256 internal constant MAX_ELAPSED_TIME = 365 days;

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

    /// @inheritdoc IMorphoCredit
    function accrueBorrowerPremium(Id id, address borrower) external {
        MarketParams memory marketParams = idToMarketParams[id];
        _accrueInterest(marketParams, id);
        _accrueBorrowerPremium(id, borrower);
        _snapshotBorrowerPosition(id, borrower);
    }

    /// @inheritdoc IMorphoCredit
    function accruePremiumsForBorrowers(Id id, address[] calldata borrowers) external {
        MarketParams memory marketParams = idToMarketParams[id];
        _accrueInterest(marketParams, id);
        for (uint256 i = 0; i < borrowers.length; i++) {
            _accrueBorrowerPremium(id, borrowers[i]);
            _snapshotBorrowerPosition(id, borrowers[i]);
        }
    }

    /// @dev Calculates the premium amount to be added based on observed base rate growth
    /// @param borrowAssetsAtLastAccrual The borrower's assets at last premium accrual
    /// @param borrowAssetsCurrent The borrower's current assets (including base interest)
    /// @param premiumRate The borrower's premium rate per second (scaled by WAD)
    /// @param elapsed Time elapsed since last accrual
    /// @return premiumAmount The premium amount to add
    function _calculateBorrowerPremiumAmount(
        uint256 borrowAssetsAtLastAccrual,
        uint256 borrowAssetsCurrent,
        uint256 premiumRate,
        uint256 elapsed
    ) internal pure returns (uint256 premiumAmount) {
        // Prevent division by zero
        if (borrowAssetsAtLastAccrual == 0 || elapsed == 0) return 0;

        // Calculate the actual base growth
        uint256 baseGrowthActual;
        uint256 baseRatePerSecond;
        if (borrowAssetsCurrent > borrowAssetsAtLastAccrual) {
            baseGrowthActual = borrowAssetsCurrent - borrowAssetsAtLastAccrual;
            baseRatePerSecond = borrowAssetsCurrent.wDivUp(borrowAssetsAtLastAccrual).wInverseTaylorCompounded(elapsed);
        }

        // Combine base rate with premium rate (both per-second)
        uint256 combinedRate = baseRatePerSecond + premiumRate;

        // Calculate compound growth using wTaylorCompounded
        uint256 totalGrowth = combinedRate.wTaylorCompounded(elapsed);
        uint256 totalGrowthAmount = borrowAssetsAtLastAccrual.wMulDown(totalGrowth);

        // Premium amount is the difference between total growth and actual base growth
        premiumAmount = totalGrowthAmount > baseGrowthActual ? totalGrowthAmount - baseGrowthActual : 0;
    }

    /// @notice Accrue premium for a specific borrower
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @dev _accrueInterest must be called prior to ensure calculation is accurate
    function _accrueBorrowerPremium(Id id, address borrower) internal {
        BorrowerPremium memory premium = borrowerPremium[id][borrower];
        if (premium.rate == 0) return;

        uint256 elapsed = block.timestamp - premium.lastAccrualTime;
        if (elapsed == 0) return;

        // Cap elapsed time to prevent overflow in compound calculations
        if (elapsed > MAX_ELAPSED_TIME) {
            elapsed = MAX_ELAPSED_TIME;
        }

        Position memory borrowerPosition = position[id][borrower];
        if (borrowerPosition.borrowShares == 0) return;

        Market memory targetMarket = market[id];

        uint256 borrowAssetsCurrent = uint256(borrowerPosition.borrowShares).toAssetsUp(
            targetMarket.totalBorrowAssets, targetMarket.totalBorrowShares
        );
        uint256 premiumAmount = _calculateBorrowerPremiumAmount(
            premium.borrowAssetsAtLastAccrual, borrowAssetsCurrent, premium.rate, elapsed
        );

        // Skip if premium amount is below threshold (prevents precision loss)
        if (premiumAmount < MIN_PREMIUM_THRESHOLD) {
            // Still update timestamp to prevent repeated negligible calculations
            borrowerPremium[id][borrower].lastAccrualTime = uint128(block.timestamp);
            return;
        }

        uint256 premiumShares = premiumAmount.toSharesUp(targetMarket.totalBorrowAssets, targetMarket.totalBorrowShares);

        // Update borrower position
        position[id][borrower].borrowShares += premiumShares.toUint128();

        // Update market totals
        targetMarket.totalBorrowShares += premiumShares.toUint128();
        targetMarket.totalBorrowAssets += premiumAmount.toUint128();
        targetMarket.totalSupplyAssets += premiumAmount.toUint128();

        uint256 feeAmount;
        if (targetMarket.fee != 0) {
            feeAmount = premiumAmount.wMulDown(targetMarket.fee);
            // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
            // that total supply is already increased by the full premium (including the fee amount).
            uint256 feeShares =
                feeAmount.toSharesDown(targetMarket.totalSupplyAssets - feeAmount, targetMarket.totalSupplyShares);
            position[id][feeRecipient].supplyShares += feeShares;
            targetMarket.totalSupplyShares += feeShares.toUint128();
        }

        // Write back to storage
        market[id] = targetMarket;

        emit EventsLib.PremiumAccrued(id, borrower, premiumAmount, feeAmount);

        borrowerPremium[id][borrower].lastAccrualTime = uint128(block.timestamp);
    }

    /// @notice Snapshot borrower's position for premium tracking
    /// @param id Market ID
    /// @param borrower Borrower address
    function _snapshotBorrowerPosition(Id id, address borrower) internal {
        BorrowerPremium memory premium = borrowerPremium[id][borrower];

        if (premium.rate == 0) return;

        Market memory targetMarket = market[id];

        uint256 currentBorrowAssets = uint256(position[id][borrower].borrowShares).toAssetsUp(
            targetMarket.totalBorrowAssets, targetMarket.totalBorrowShares
        );

        // Update premium struct in memory
        premium.borrowAssetsAtLastAccrual = currentBorrowAssets;

        // Safety check: Initialize timestamp if not already set
        if (premium.lastAccrualTime == 0) {
            premium.lastAccrualTime = uint128(block.timestamp);
        }

        // Write back to storage
        borrowerPremium[id][borrower] = premium;
    }

    /* ONLY CREDIT LINE FUNCTIONS */

    /// @inheritdoc IMorphoCredit
    function setCreditLine(Id id, address borrower, uint256 credit, uint128 premiumRate) external {
        require(idToMarketParams[id].creditLine == msg.sender, ErrorsLib.NOT_CREDIT_LINE);

        position[id][borrower].collateral = credit.toUint128();

        emit EventsLib.SetCreditLine(id, borrower, credit);

        _setBorrowerPremiumRate(id, borrower, premiumRate);
    }

    /// @notice Set or update a borrower's premium rate
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @param newRate New premium rate per second in WAD (e.g., 0.1e18 / 365 days for 10% APR)
    function _setBorrowerPremiumRate(Id id, address borrower, uint128 newRate) internal {
        // Accrue base interest first to ensure premium calculations are accurate
        MarketParams memory marketParams = idToMarketParams[id];
        _accrueInterest(marketParams, id);

        BorrowerPremium storage premium = borrowerPremium[id][borrower];
        uint128 oldRate = premium.rate;

        // If there's an existing position with borrow shares
        uint256 borrowShares = uint256(position[id][borrower].borrowShares);

        if (borrowShares > 0) {
            // If there was a previous rate, accrue premium first
            if (oldRate > 0) {
                _accrueBorrowerPremium(id, borrower);
            }
        }

        // Set the new rate before taking snapshot
        premium.rate = newRate;
        if (premium.lastAccrualTime == 0) {
            premium.lastAccrualTime = uint128(block.timestamp);
        }

        // Take snapshot after setting the new rate if there are borrow shares
        if (borrowShares > 0 && newRate > 0) {
            _snapshotBorrowerPosition(id, borrower);
        }

        emit EventsLib.BorrowerPremiumRateSet(id, borrower, oldRate, newRate);
    }

    /* HOOK IMPLEMENTATIONS */

    /// @inheritdoc Morpho
    function _beforeBorrow(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets, uint256 shares)
        internal
        override
    {
        _accrueBorrowerPremium(id, onBehalf);
    }

    /// @inheritdoc Morpho
    function _beforeRepay(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets, uint256 shares)
        internal
        override
    {
        _accrueBorrowerPremium(id, onBehalf);
    }

    /// @inheritdoc Morpho
    function _beforeLiquidate(
        MarketParams memory marketParams,
        Id id,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) internal override {
        _accrueBorrowerPremium(id, borrower);
    }

    /// @inheritdoc Morpho
    function _afterBorrow(MarketParams memory marketParams, Id id, address onBehalf) internal override {
        _snapshotBorrowerPosition(id, onBehalf);
    }

    /// @inheritdoc Morpho
    function _afterRepay(MarketParams memory marketParams, Id id, address onBehalf) internal override {
        _snapshotBorrowerPosition(id, onBehalf);
    }

    /// @inheritdoc Morpho
    function _afterLiquidate(MarketParams memory marketParams, Id id, address borrower) internal override {
        _snapshotBorrowerPosition(id, borrower);
    }
}
