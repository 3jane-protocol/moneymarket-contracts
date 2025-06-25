// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {
    Id,
    MarketParams,
    Position,
    Market,
    BorrowerPremium,
    RepaymentStatus,
    PaymentCycle,
    RepaymentObligation,
    IMorphoCredit
} from "./interfaces/IMorpho.sol";

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

    /// @notice Payment cycles for each market
    mapping(Id => PaymentCycle[]) public paymentCycle;

    /// @notice Repayment obligations for each borrower in each market
    mapping(Id => mapping(address => RepaymentObligation)) public repaymentObligation;

    /// @notice Minimum premium amount to accrue (prevents precision loss)
    uint256 internal constant MIN_PREMIUM_THRESHOLD = 1;

    /// @notice Maximum elapsed time for premium accrual (365 days)
    /// @dev This limit serves multiple purposes:
    /// 1. Maintains accuracy of wTaylorCompounded approximation (error < 8% for periods up to 365 days)
    /// 2. Prevents numerical overflow when combined with MAX_PREMIUM_RATE (100% APR)
    /// 3. Protects against runaway debt accumulation on abandoned positions
    /// 4. Aligns with the test bounds in MathLibTest which validate behavior up to 365 days
    uint256 internal constant MAX_ELAPSED_TIME = 365 days;

    /// @notice Grace period duration for repayments
    uint256 internal constant GRACE_PERIOD_DURATION = 7 days;

    /// @notice Default period duration (time after cycle end to enter default status)
    uint256 internal constant DEFAULT_PERIOD_DURATION = 30 days;

    /// @notice Minimum outstanding loan balance to prevent dust
    uint256 internal constant MIN_OUTSTANDING = 1000e18;

    /// @notice Penalty rate per second for delinquent borrowers (~5% APR)
    uint256 internal constant PENALTY_RATE_PER_SECOND = 1585489599;

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

        // Check repayment status and add penalty interest if delinquent
        RepaymentStatus status = getRepaymentStatus(id, borrower);

        if (status == RepaymentStatus.Delinquent || status == RepaymentStatus.Default) {
            RepaymentObligation storage obligation = repaymentObligation[id][borrower];

            // Calculate when they entered delinquency
            PaymentCycle storage cycle = paymentCycle[id][obligation.paymentCycleId];
            uint256 delinquencyStartTime = cycle.endDate + GRACE_PERIOD_DURATION;

            // Calculate penalty accrual period
            uint256 penaltyStart =
                premium.lastAccrualTime > delinquencyStartTime ? premium.lastAccrualTime : delinquencyStartTime;
            uint256 penaltyDuration = block.timestamp - penaltyStart;

            if (penaltyDuration > 0 && obligation.endingBalance > 0) {
                // Calculate penalty interest using the ending balance
                uint256 penaltyInterest =
                    obligation.endingBalance.wMulDown(PENALTY_RATE_PER_SECOND.wTaylorCompounded(penaltyDuration));

                // Add penalty to premium amount
                premiumAmount += penaltyInterest;
            }
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
        require(borrower != address(0), ErrorsLib.ZERO_ADDRESS);
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
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

    /* REPAYMENT MANAGEMENT */

    /// @notice Modifier to restrict access to the market's CreditLine contract
    modifier onlyCreditLine(Id id) {
        require(msg.sender == idToMarketParams[id].creditLine, ErrorsLib.NOT_CREDIT_LINE);
        _;
    }

    /// @notice Close a payment cycle and create it on-chain retroactively
    /// @param id Market ID
    /// @param endDate Cycle end date
    /// @param borrowers Array of borrower addresses
    /// @param amounts Array of amounts due
    /// @param endingBalances Array of ending balances for penalty calculations
    function closeCycleAndPostObligations(
        Id id,
        uint256 endDate,
        address[] calldata borrowers,
        uint256[] calldata amounts,
        uint256[] calldata endingBalances
    ) external onlyCreditLine(id) {
        require(
            borrowers.length == amounts.length && amounts.length == endingBalances.length, ErrorsLib.INCONSISTENT_INPUT
        );
        require(endDate <= block.timestamp, "Cannot close future cycle");

        uint256 cycleLength = paymentCycle[id].length;
        uint256 startDate;

        if (cycleLength > 0) {
            // Validate cycle comes after previous one
            PaymentCycle storage prevCycle = paymentCycle[id][cycleLength - 1];
            startDate = prevCycle.endDate + 1 days;
            require(startDate < endDate, "Invalid cycle duration");
        }
        // else startDate remains 0 for the first cycle

        // Create the payment cycle record
        paymentCycle[id].push(PaymentCycle({endDate: endDate}));

        uint256 cycleId = paymentCycle[id].length - 1;

        // Post obligations for this cycle
        for (uint256 i = 0; i < borrowers.length; i++) {
            _postRepaymentObligation(id, borrowers[i], amounts[i], cycleId, endingBalances[i]);
        }

        emit EventsLib.PaymentCycleCreated(id, cycleId, startDate, endDate);
    }

    /// @notice Add more obligations to the most recently closed cycle
    /// @param id Market ID
    /// @param borrowers Array of borrower addresses
    /// @param amounts Array of amounts due
    /// @param endingBalances Array of ending balances
    function addObligationsToLatestCycle(
        Id id,
        address[] calldata borrowers,
        uint256[] calldata amounts,
        uint256[] calldata endingBalances
    ) external onlyCreditLine(id) {
        require(
            borrowers.length == amounts.length && amounts.length == endingBalances.length, ErrorsLib.INCONSISTENT_INPUT
        );
        require(paymentCycle[id].length > 0, "No cycles exist");

        uint256 latestCycleId = paymentCycle[id].length - 1;

        for (uint256 i = 0; i < borrowers.length; i++) {
            _postRepaymentObligation(id, borrowers[i], amounts[i], latestCycleId, endingBalances[i]);
        }
    }

    /// @notice Internal function to post individual obligation
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @param amount Amount due
    /// @param cycleId Payment cycle ID
    /// @param endingBalance Balance at cycle end for penalty calculations
    function _postRepaymentObligation(Id id, address borrower, uint256 amount, uint256 cycleId, uint256 endingBalance)
        internal
    {
        RepaymentObligation storage obligation = repaymentObligation[id][borrower];

        // If there's an existing unpaid obligation, add to it
        if (obligation.amountDue > 0) {
            amount += obligation.amountDue;
        }

        // Set new obligation
        obligation.paymentCycleId = uint128(cycleId);
        obligation.amountDue = uint128(amount);
        obligation.endingBalance = endingBalance;

        emit EventsLib.RepaymentObligationPosted(id, borrower, amount, cycleId, endingBalance);
    }

    /// @notice Get repayment status for a borrower
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return status The borrower's current repayment status
    function getRepaymentStatus(Id id, address borrower) public view returns (RepaymentStatus) {
        RepaymentObligation storage obligation = repaymentObligation[id][borrower];
        if (obligation.amountDue == 0) return RepaymentStatus.Current;

        // Validate cycleId is within bounds
        require(obligation.paymentCycleId < paymentCycle[id].length, "Invalid cycle ID");

        PaymentCycle storage cycle = paymentCycle[id][obligation.paymentCycleId];
        uint256 cycleEndDate = cycle.endDate;

        if (block.timestamp <= cycleEndDate + GRACE_PERIOD_DURATION) {
            return RepaymentStatus.GracePeriod;
        } else if (block.timestamp <= cycleEndDate + DEFAULT_PERIOD_DURATION) {
            return RepaymentStatus.Delinquent;
        } else {
            return RepaymentStatus.Default;
        }
    }

    /* HOOK IMPLEMENTATIONS */

    /// @inheritdoc Morpho
    function _beforeBorrow(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets, uint256 shares)
        internal
        override
    {
        // Check if borrower can borrow
        require(
            getRepaymentStatus(id, onBehalf) == RepaymentStatus.Current, "Cannot borrow with outstanding repayments"
        );

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
    function _afterRepay(MarketParams memory marketParams, Id id, address onBehalf, uint256 assets) internal override {
        _snapshotBorrowerPosition(id, onBehalf);

        // Track payment against obligation
        RepaymentObligation storage obligation = repaymentObligation[id][onBehalf];

        if (obligation.amountDue > 0 && assets > 0) {
            uint256 paymentToObligation = assets > obligation.amountDue ? obligation.amountDue : assets;

            obligation.amountDue = uint128(obligation.amountDue - paymentToObligation);

            emit EventsLib.RepaymentTracked(id, onBehalf, paymentToObligation, obligation.amountDue);
        }
    }

    /// @inheritdoc Morpho
    function _afterLiquidate(MarketParams memory marketParams, Id id, address borrower) internal override {
        _snapshotBorrowerPosition(id, borrower);
    }

    /* VIEW FUNCTIONS */

    /// @notice Check if borrower can borrow
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return Whether the borrower can take new loans
    function canBorrow(Id id, address borrower) external view returns (bool) {
        return getRepaymentStatus(id, borrower) == RepaymentStatus.Current;
    }

    /// @notice Get the ID of the latest payment cycle
    /// @param id Market ID
    /// @return The latest cycle ID
    function getLatestCycleId(Id id) external view returns (uint256) {
        require(paymentCycle[id].length > 0, "No cycles exist");
        return paymentCycle[id].length - 1;
    }

    /// @notice Get both start and end dates for a given cycle
    /// @param id Market ID
    /// @param cycleId Cycle ID
    /// @return startDate The cycle start date
    /// @return endDate The cycle end date
    function getCycleDates(Id id, uint256 cycleId) external view returns (uint256 startDate, uint256 endDate) {
        require(cycleId < paymentCycle[id].length, "Invalid cycle ID");

        PaymentCycle storage cycle = paymentCycle[id][cycleId];
        endDate = cycle.endDate;

        if (cycleId != 0) {
            startDate = paymentCycle[id][cycleId - 1].endDate + 1 days;
        }
    }

    /* HEALTH CHECK OVERRIDE */

    /// @dev Override health check for credit-based lending (without price)
    /// @param marketParams The market parameters
    /// @param id The market id
    /// @param borrower The borrower address
    /// @return healthy Whether the position is healthy
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower)
        internal
        view
        override
        returns (bool)
    {
        if (position[id][borrower].borrowShares == 0) return true;

        // For credit-based lending, we don't need oracle price
        // Just check credit utilization directly
        uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
            market[id].totalBorrowAssets, market[id].totalBorrowShares
        );
        uint256 creditLimit = position[id][borrower].collateral;

        return creditLimit >= borrowed;
    }

    /// @dev Override health check for credit-based lending (with price)
    /// @param marketParams The market parameters
    /// @param id The market id
    /// @param borrower The borrower address
    /// @param collateralPrice The collateral price (unused in credit model)
    /// @return healthy Whether the position is healthy
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower, uint256 collateralPrice)
        internal
        view
        override
        returns (bool)
    {
        // For credit-based lending, health is determined by credit utilization
        // position.collateral represents the credit limit
        uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
            market[id].totalBorrowAssets, market[id].totalBorrowShares
        );
        uint256 creditLimit = position[id][borrower].collateral;

        return creditLimit >= borrowed;
    }
}
