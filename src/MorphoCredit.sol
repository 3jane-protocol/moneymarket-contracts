// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {
    Id,
    MarketParams,
    Position,
    Market,
    BorrowerPremium,
    RepaymentStatus,
    PaymentCycle,
    RepaymentObligation,
    MarkdownState,
    IMorphoCredit
} from "./interfaces/IMorpho.sol";
import {IMarkdownManager} from "./interfaces/IMarkdownManager.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IMorphoRepayCallback} from "./interfaces/IMorphoCallbacks.sol";
import {IProtocolConfig, MarketConfig} from "./interfaces/IProtocolConfig.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {Morpho} from "./Morpho.sol";

import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

/// @title Morpho Credit
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice The Morpho Credit contract extends Morpho with credit-based lending and per-borrower risk premiums.
/// @dev This contract implements a three-tier interest accrual system:
///
/// **Interest Rate Components:**
/// 1. Base Rate: Market-wide rate from the IRM, applied to all borrowers
/// 2. Premium Rate: Per-borrower risk premium based on creditworthiness
/// 3. Penalty Rate: Additional rate when borrower is delinquent (past grace period)
///
/// **Accrual Process Flow:**
/// ```
/// Market Interest (continuous) → Base Rate Growth
///                                      ↓
/// Borrower Premium Accrual → Premium on top of base
///                                      ↓
/// Delinquency Check → If delinquent, add penalty rate
/// ```
/// - Using ending balance for penalty calculations
contract MorphoCredit is Morpho, IMorphoCredit {
    using UtilsLib for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using MathLib for uint256;
    using SafeTransferLib for IERC20;

    /* STATE VARIABLES */

    /// @inheritdoc IMorphoCredit
    address public helper;

    /// @notice Immutable protocol configuration contract
    address public immutable protocolConfig;

    /// @inheritdoc IMorphoCredit
    address public usd3;

    /// @inheritdoc IMorphoCredit
    mapping(Id => mapping(address => BorrowerPremium)) public borrowerPremium;

    /// @notice Payment cycles for each market
    mapping(Id => PaymentCycle[]) public paymentCycle;

    /// @notice Repayment obligations for each borrower in each market
    mapping(Id => mapping(address => RepaymentObligation)) public repaymentObligation;

    /// @notice Markdown state for tracking defaulted debt value reduction
    mapping(Id => mapping(address => MarkdownState)) public markdownState;

    /// @dev Storage gap for future upgrades (14 slots).
    uint256[14] private __gap;

    /* CONSTANTS */

    /// @notice Minimum premium amount to accrue (prevents precision loss)
    uint256 internal constant MIN_PREMIUM_THRESHOLD = 1;

    /// @notice Maximum elapsed time for premium accrual (365 days)
    uint256 internal constant MAX_ELAPSED_TIME = 365 days;

    /// @notice Maximum basis points (100%)
    uint256 internal constant MAX_BPS = 10000;

    /* INITIALIZER */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _protocolConfig) {
        if (_protocolConfig == address(0)) revert ErrorsLib.ZeroAddress();
        protocolConfig = _protocolConfig;
        _disableInitializers();
    }

    /// @dev Initializes the MorphoCredit contract.
    /// @param newOwner The initial owner of the contract.
    function initialize(address newOwner) external initializer {
        __Morpho_init(newOwner);
    }

    /* ADMIN FUNCTIONS */

    /// @inheritdoc IMorphoCredit
    function setHelper(address newHelper) external onlyOwner {
        if (newHelper == helper) revert ErrorsLib.AlreadySet();

        helper = newHelper;

        emit EventsLib.SetHelper(newHelper);
    }

    /// @inheritdoc IMorphoCredit
    function setUsd3(address newUsd3) external onlyOwner {
        if (newUsd3 == usd3) revert ErrorsLib.AlreadySet();

        usd3 = newUsd3;

        emit EventsLib.SetUsd3(newUsd3);
    }

    /* EXTERNAL FUNCTIONS - PREMIUM MANAGEMENT */

    /// @inheritdoc IMorphoCredit
    function accrueBorrowerPremium(Id id, address borrower) external {
        MarketParams memory marketParams = idToMarketParams[id];
        _accrueInterest(marketParams, id);
        _accrueBorrowerPremium(id, borrower);
        _updateBorrowerMarkdown(id, borrower);
        _snapshotBorrowerPosition(id, borrower);
    }

    /// @inheritdoc IMorphoCredit
    function accruePremiumsForBorrowers(Id id, address[] calldata borrowers) external {
        MarketParams memory marketParams = idToMarketParams[id];
        _accrueInterest(marketParams, id);
        for (uint256 i = 0; i < borrowers.length; i++) {
            _accrueBorrowerPremium(id, borrowers[i]);
            _updateBorrowerMarkdown(id, borrowers[i]);
            _snapshotBorrowerPosition(id, borrowers[i]);
        }
    }

    /* INTERNAL FUNCTIONS - PREMIUM CALCULATIONS */

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

    /// @dev Calculate ongoing premium and penalty rate if already past grace period
    /// @return premiumAmount The calculated premium amount (including penalty if applicable)
    function _calculateOngoingPremiumAndPenalty(
        Id id,
        address borrower,
        BorrowerPremium memory premium,
        RepaymentStatus status,
        uint256 borrowAssetsCurrent
    ) internal view returns (uint256 premiumAmount) {
        uint256 elapsed = block.timestamp - premium.lastAccrualTime;
        if (elapsed == 0) return 0;

        if (elapsed > MAX_ELAPSED_TIME) {
            elapsed = MAX_ELAPSED_TIME;
        }

        uint256 totalPremiumRate = premium.rate;

        // Add penalty rate if already in penalty period (after grace period)
        if (status != RepaymentStatus.Current && status != RepaymentStatus.GracePeriod) {
            RepaymentObligation memory obligation = repaymentObligation[id][borrower];
            uint256 cycleEndDate = paymentCycle[id][obligation.paymentCycleId].endDate;
            MarketConfig memory terms = IProtocolConfig(protocolConfig).getMarketConfig();

            if (premium.lastAccrualTime > cycleEndDate + terms.gracePeriod) {
                totalPremiumRate += terms.irp;
            }
        }

        premiumAmount = _calculateBorrowerPremiumAmount(
            premium.borrowAssetsAtLastAccrual, borrowAssetsCurrent, totalPremiumRate, elapsed
        );
    }

    /// @dev Calculate initial penalty when first transitioning into penalty period
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @param status Current repayment status
    /// @param borrowAssetsCurrent Current borrow assets after base accrual
    /// @param basePremiumAmount Premium amount already calculated
    /// @return penaltyAmount The calculated penalty amount
    /// @dev Penalty calculation logic:
    /// 1. Only applies if status is Delinquent or Default
    /// 2. Only for first accrual after grace period ends (lastAccrualTime <= cycleEndDate + gracePeriod)
    /// 3. Uses ending balance from obligation as the principal
    /// 4. Calculates penalty from cycle end date to now
    /// 5. Adds basePremiumAmount to current assets for accurate compounding
    function _calculateInitialPenalty(
        Id id,
        address borrower,
        RepaymentStatus status,
        uint256 borrowAssetsCurrent,
        uint256 basePremiumAmount
    ) internal view returns (uint256 penaltyAmount) {
        if (status != RepaymentStatus.Delinquent && status != RepaymentStatus.Default) {
            return 0;
        }

        BorrowerPremium memory premium = borrowerPremium[id][borrower];
        RepaymentObligation memory obligation = repaymentObligation[id][borrower];
        uint256 cycleEndDate = paymentCycle[id][obligation.paymentCycleId].endDate;
        MarketConfig memory terms = IProtocolConfig(protocolConfig).getMarketConfig();

        if (premium.lastAccrualTime > cycleEndDate + terms.gracePeriod) {
            return 0; // Already handled in premium calculation
        }

        uint256 elapsed = block.timestamp - cycleEndDate;
        if (elapsed > MAX_ELAPSED_TIME) {
            elapsed = MAX_ELAPSED_TIME;
        }
        penaltyAmount = _calculateBorrowerPremiumAmount(
            obligation.endingBalance, borrowAssetsCurrent + basePremiumAmount, terms.irp, elapsed
        );
    }

    /// @dev Update position and market with premium shares
    function _updatePositionWithPremium(Id id, address borrower, uint256 premiumAmount) internal {
        Market memory targetMarket = market[id];

        uint256 premiumShares = premiumAmount.toSharesUp(targetMarket.totalBorrowAssets, targetMarket.totalBorrowShares);

        // Update borrower position
        position[id][borrower].borrowShares += premiumShares.toUint128();

        // Update market totals
        targetMarket.totalBorrowShares += premiumShares.toUint128();
        targetMarket.totalBorrowAssets += premiumAmount.toUint128();
        targetMarket.totalSupplyAssets += premiumAmount.toUint128();

        // Handle fees
        uint256 feeAmount;
        if (targetMarket.fee != 0) {
            feeAmount = premiumAmount.wMulDown(targetMarket.fee);
            uint256 feeShares =
                feeAmount.toSharesDown(targetMarket.totalSupplyAssets - feeAmount, targetMarket.totalSupplyShares);
            position[id][feeRecipient].supplyShares += feeShares;
            targetMarket.totalSupplyShares += feeShares.toUint128();
        }

        // Write back to storage
        market[id] = targetMarket;

        emit EventsLib.PremiumAccrued(id, borrower, premiumAmount, feeAmount);
    }

    /// @notice Accrue premium for a specific borrower
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @dev Core accrual function that orchestrates the premium and penalty calculation process:
    /// 1. Check repayment status
    /// 2. Calculate premium based on elapsed time and rates
    /// 3. Calculate penalty if borrower is delinquent/default (not during grace period)
    /// 4. Apply combined premium+penalty as new borrow shares
    /// 5. Update timestamp to prevent double accrual
    /// @dev MUST be called after _accrueInterest to ensure base rate is current
    function _accrueBorrowerPremium(Id id, address borrower) internal {
        RepaymentObligation memory obligation = repaymentObligation[id][borrower];
        (RepaymentStatus status,) = _getRepaymentStatus(id, borrower, obligation);

        BorrowerPremium memory premium = borrowerPremium[id][borrower];
        if (premium.rate == 0 && status == RepaymentStatus.Current) return;

        if (position[id][borrower].borrowShares == 0) return;

        // Calculate current borrow assets
        Market memory targetMarket = market[id];
        uint256 borrowAssetsCurrent = uint256(position[id][borrower].borrowShares).toAssetsUp(
            targetMarket.totalBorrowAssets, targetMarket.totalBorrowShares
        );

        // Calculate premium and penalty accruals
        uint256 premiumAmount = _calculateOngoingPremiumAndPenalty(id, borrower, premium, status, borrowAssetsCurrent);

        // Calculate penalty if needed (handles first penalty accrual)
        uint256 penaltyAmount = _calculateInitialPenalty(id, borrower, status, borrowAssetsCurrent, premiumAmount);

        uint256 totalPremium = premiumAmount + penaltyAmount;

        // Skip if below threshold
        if (totalPremium < MIN_PREMIUM_THRESHOLD) {
            return;
        }

        // Apply the premium
        _updatePositionWithPremium(id, borrower, totalPremium);

        // Update timestamp
        borrowerPremium[id][borrower].lastAccrualTime = uint128(block.timestamp);
    }

    /// @notice Snapshot borrower's position for premium tracking
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @dev Snapshots are critical for accurate premium calculation:
    /// - Captures the current borrow amount after all accruals
    /// - Updates borrowAssetsAtLastAccrual to this new value
    /// - Ensures next premium calculation starts from correct base
    /// - Only updates if borrower has a premium rate set
    /// @dev Called after every borrow, repay, or liquidation to maintain accuracy
    function _snapshotBorrowerPosition(Id id, address borrower) internal {
        BorrowerPremium memory premium = borrowerPremium[id][borrower];

        Market memory targetMarket = market[id];

        uint256 currentBorrowAssets = uint256(position[id][borrower].borrowShares).toAssetsUp(
            targetMarket.totalBorrowAssets, targetMarket.totalBorrowShares
        );

        // Update premium struct in memory
        premium.borrowAssetsAtLastAccrual = currentBorrowAssets.toUint128();

        // Safety check: Initialize timestamp if not already set
        if (premium.lastAccrualTime == 0) {
            premium.lastAccrualTime = uint128(block.timestamp);
        }

        // Write back to storage
        borrowerPremium[id][borrower] = premium;
    }

    /* MODIFIERS */

    /// @notice Modifier to restrict access to the market's CreditLine contract
    modifier onlyCreditLine(Id id) {
        if (market[id].lastUpdate == 0) revert ErrorsLib.MarketNotCreated();
        if (msg.sender != idToMarketParams[id].creditLine) revert ErrorsLib.NotCreditLine();
        _;
    }

    /* EXTERNAL FUNCTIONS - CREDIT LINE MANAGEMENT */

    /// @inheritdoc IMorphoCredit
    function setCreditLine(Id id, address borrower, uint256 credit, uint128 premiumRate) external onlyCreditLine(id) {
        if (borrower == address(0)) revert ErrorsLib.ZeroAddress();

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

        BorrowerPremium memory premium = borrowerPremium[id][borrower];
        uint128 oldRate = premium.rate;

        // If there's an existing position with borrow shares
        uint256 borrowShares = uint256(position[id][borrower].borrowShares);

        // If there was a previous rate, accrue premium first
        if (borrowShares > 0 && oldRate > 0) {
            _accrueBorrowerPremium(id, borrower);
        }

        // Set the new rate before taking snapshot
        premium.rate = newRate;
        if (premium.lastAccrualTime == 0) {
            premium.lastAccrualTime = uint128(block.timestamp);
        }

        borrowerPremium[id][borrower] = premium;

        // Take snapshot after setting the new rate if there are borrow shares
        if (borrowShares > 0 && newRate > 0) {
            _snapshotBorrowerPosition(id, borrower);
        }

        emit EventsLib.BorrowerPremiumRateSet(id, borrower, oldRate, newRate);
    }

    /* EXTERNAL FUNCTIONS - REPAYMENT MANAGEMENT */

    /// @notice Close a payment cycle and create it on-chain retroactively
    /// @param id Market ID
    /// @param endDate Cycle end date
    /// @param borrowers Array of borrower addresses
    /// @param repaymentBps Array of repayment basis points (e.g., 500 = 5%)
    /// @param endingBalances Array of ending balances for penalty calculations
    /// @dev The ending balance is crucial for penalty calculations - it represents
    /// the borrower's debt at cycle end and is used to calculate penalty interest
    /// from that point forward, ensuring path independence
    function closeCycleAndPostObligations(
        Id id,
        uint256 endDate,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external onlyCreditLine(id) {
        if (borrowers.length != repaymentBps.length || repaymentBps.length != endingBalances.length) {
            revert ErrorsLib.InconsistentInput();
        }
        if (endDate > block.timestamp) revert ErrorsLib.CannotCloseFutureCycle();

        uint256 cycleLength = paymentCycle[id].length;
        uint256 startDate;

        if (cycleLength > 0) {
            // Validate cycle comes after previous one
            PaymentCycle storage prevCycle = paymentCycle[id][cycleLength - 1];
            startDate = prevCycle.endDate + 1 days;
            if (startDate >= endDate) revert ErrorsLib.InvalidCycleDuration();
        }
        // else startDate remains 0 for the first cycle

        // Create the payment cycle record
        paymentCycle[id].push(PaymentCycle({endDate: endDate}));

        uint256 cycleId = paymentCycle[id].length - 1;

        // Post obligations for this cycle
        for (uint256 i = 0; i < borrowers.length; i++) {
            _postRepaymentObligation(id, borrowers[i], repaymentBps[i], cycleId, endingBalances[i]);
        }

        emit EventsLib.PaymentCycleCreated(id, cycleId, startDate, endDate);
    }

    /// @notice Add more obligations to the most recently closed cycle
    /// @param id Market ID
    /// @param borrowers Array of borrower addresses
    /// @param repaymentBps Array of repayment basis points (e.g., 500 = 5%)
    /// @param endingBalances Array of ending balances
    function addObligationsToLatestCycle(
        Id id,
        address[] calldata borrowers,
        uint256[] calldata repaymentBps,
        uint256[] calldata endingBalances
    ) external onlyCreditLine(id) {
        if (borrowers.length != repaymentBps.length || repaymentBps.length != endingBalances.length) {
            revert ErrorsLib.InconsistentInput();
        }
        if (paymentCycle[id].length == 0) revert ErrorsLib.NoCyclesExist();

        uint256 latestCycleId = paymentCycle[id].length - 1;

        for (uint256 i = 0; i < borrowers.length; i++) {
            _postRepaymentObligation(id, borrowers[i], repaymentBps[i], latestCycleId, endingBalances[i]);
        }
    }

    /// @notice Internal function to post individual obligation
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @param repaymentBps Repayment percentage in basis points (e.g., 500 = 5%)
    /// @param cycleId Payment cycle ID
    /// @param endingBalance Balance at cycle end for penalty calculations
    function _postRepaymentObligation(
        Id id,
        address borrower,
        uint256 repaymentBps,
        uint256 cycleId,
        uint256 endingBalance
    ) internal {
        if (repaymentBps > MAX_BPS) revert ErrorsLib.RepaymentExceedsHundredPercent();

        RepaymentObligation memory obligation = repaymentObligation[id][borrower];

        // Calculate actual amount from basis points
        uint256 amount = endingBalance * repaymentBps / MAX_BPS;

        // Only set cycleId and endingBalance for new obligations
        if (obligation.amountDue == 0) {
            obligation.paymentCycleId = uint128(cycleId);
            obligation.endingBalance = endingBalance.toUint128();
        }

        // Update amount due
        obligation.amountDue = uint128(amount);

        repaymentObligation[id][borrower] = obligation;

        // Emit input parameters to reflect poster's intent
        emit EventsLib.RepaymentObligationPosted(id, borrower, amount, cycleId, endingBalance);
    }

    /// @notice Get repayment status for a borrower
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return status The borrower's current repayment status
    /// @return statusStartTime The timestamp when the current status began
    function getRepaymentStatus(Id id, address borrower) public view returns (RepaymentStatus, uint256) {
        return _getRepaymentStatus(id, borrower, repaymentObligation[id][borrower]);
    }

    /// @notice Get repayment status for a borrower
    /// @param id Market ID
    /// @param obligation the borrower repaymentObligation struct
    /// @return _status The borrower's current repayment status
    /// @return _statusStartTime The timestamp when the current status began
    function _getRepaymentStatus(Id id, address, RepaymentObligation memory obligation)
        internal
        view
        returns (RepaymentStatus _status, uint256 _statusStartTime)
    {
        if (obligation.amountDue == 0) return (RepaymentStatus.Current, 0);

        // Validate cycleId is within bounds
        if (obligation.paymentCycleId >= paymentCycle[id].length) revert ErrorsLib.InvalidCycleId();

        _statusStartTime = paymentCycle[id][obligation.paymentCycleId].endDate;

        MarketConfig memory terms = IProtocolConfig(protocolConfig).getMarketConfig();

        if (block.timestamp <= _statusStartTime + terms.gracePeriod) {
            return (RepaymentStatus.GracePeriod, _statusStartTime);
        }
        _statusStartTime += terms.gracePeriod;
        if (block.timestamp < _statusStartTime + terms.delinquencyPeriod) {
            return (RepaymentStatus.Delinquent, _statusStartTime);
        }

        return (RepaymentStatus.Default, _statusStartTime + terms.delinquencyPeriod);
    }

    /* INTERNAL FUNCTIONS - HOOK IMPLEMENTATIONS */

    /// @inheritdoc Morpho
    function _beforeSupply(MarketParams memory, Id id, address onBehalf, uint256, uint256, bytes calldata)
        internal
        virtual
        override
    {
        if (msg.sender != usd3) revert ErrorsLib.NotUsd3();
        if (IProtocolConfig(protocolConfig).getIsPaused() > 0) revert ErrorsLib.Paused();
    }

    /// @inheritdoc Morpho
    function _beforeWithdraw(MarketParams memory, Id id, address onBehalf, uint256, uint256)
        internal
        virtual
        override
    {
        if (msg.sender != usd3) revert ErrorsLib.NotUsd3();
    }

    /// @inheritdoc Morpho
    function _beforeBorrow(MarketParams memory, Id id, address onBehalf, uint256, uint256) internal virtual override {
        if (msg.sender != helper) revert ErrorsLib.NotHelper();
        if (IProtocolConfig(protocolConfig).getIsPaused() > 0) revert ErrorsLib.Paused();

        // Check if borrower can borrow
        (RepaymentStatus status,) = getRepaymentStatus(id, onBehalf);
        if (status != RepaymentStatus.Current) revert ErrorsLib.OutstandingRepayment();
        _accrueBorrowerPremium(id, onBehalf);
        // No need to update markdown - borrower must be Current to borrow, so markdown is always 0
    }

    /// @inheritdoc Morpho
    /// @dev Accrues premium before tracking payment. During grace period, only base + premium
    /// accrue (no penalty), allowing borrowers to clear obligations without penalty.
    /// During delinquent/default, penalty also accrues before payment is tracked.
    function _beforeRepay(MarketParams memory, Id id, address onBehalf, uint256 assets, uint256)
        internal
        virtual
        override
    {
        // Accrue premium (including penalty if past grace period)
        _accrueBorrowerPremium(id, onBehalf);
        _updateBorrowerMarkdown(id, onBehalf); // TODO: decide whether to remove

        // Track payment against obligation
        _trackObligationPayment(id, onBehalf, assets);
    }

    /// @inheritdoc Morpho
    function _afterBorrow(MarketParams memory, Id id, address onBehalf) internal virtual override {
        _snapshotBorrowerPosition(id, onBehalf);
    }

    /// @inheritdoc Morpho
    function _afterRepay(MarketParams memory, Id id, address onBehalf, uint256) internal virtual override {
        _snapshotBorrowerPosition(id, onBehalf);
        _updateBorrowerMarkdown(id, onBehalf);
    }

    /// @dev Track obligation payment and update state
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @param payment Payment amount being made
    /// @dev Enforces minimum payment requirement - must pay full obligation
    /// This prevents partial payments that would leave borrowers in limbo
    function _trackObligationPayment(Id id, address borrower, uint256 payment) internal {
        uint256 amountDue = repaymentObligation[id][borrower].amountDue;

        if (amountDue == 0) return;

        if (payment < amountDue) revert ErrorsLib.MustPayFullObligation();

        // Clear the obligation
        repaymentObligation[id][borrower].amountDue = 0;

        emit EventsLib.RepaymentTracked(id, borrower, payment, 0);
    }

    /* EXTERNAL VIEW FUNCTIONS */

    /// @notice Get the total number of payment cycles for a market
    /// @param id Market ID
    /// @return The number of payment cycles
    function getPaymentCycleLength(Id id) external view returns (uint256) {
        return paymentCycle[id].length;
    }

    /// @notice Get both start and end dates for a given cycle
    /// @param id Market ID
    /// @param cycleId Cycle ID
    /// @return startDate The cycle start date
    /// @return endDate The cycle end date
    function getCycleDates(Id id, uint256 cycleId) external view returns (uint256 startDate, uint256 endDate) {
        if (cycleId >= paymentCycle[id].length) revert ErrorsLib.InvalidCycleId();

        endDate = paymentCycle[id][cycleId].endDate;

        if (cycleId != 0) {
            startDate = paymentCycle[id][cycleId - 1].endDate + 1 days;
        }
    }

    /* INTERNAL FUNCTIONS - HEALTH CHECK OVERRIDES */

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
        // For credit-based lending, price is irrelevant
        return _isHealthy(marketParams, id, borrower, 0);
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
        Position memory position = position[id][borrower];

        // Early return if no borrow position
        if (position.borrowShares == 0) return true;

        Market memory market = market[id];

        // For credit-based lending, health is determined by credit utilization
        // position.collateral represents the credit limit
        uint256 borrowed = uint256(position.borrowShares).toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        uint256 creditLimit = position.collateral;

        return creditLimit >= borrowed;
    }

    /* MARKDOWN FUNCTIONS */

    /// @notice Update a borrower's markdown state and market total
    /// @param id Market ID
    /// @param borrower Borrower address
    function _updateBorrowerMarkdown(Id id, address borrower) internal {
        address manager = ICreditLine(idToMarketParams[id].creditLine).mm();
        if (manager == address(0)) return; // No markdown manager set

        uint256 lastMarkdown = markdownState[id][borrower].lastCalculatedMarkdown;
        (RepaymentStatus status, uint256 statusStartTime) =
            _getRepaymentStatus(id, borrower, repaymentObligation[id][borrower]);

        // Check if in default and emit status change events
        bool isInDefault = status == RepaymentStatus.Default && statusStartTime > 0;
        bool wasInDefault = lastMarkdown > 0;

        if (isInDefault && !wasInDefault) {
            emit EventsLib.DefaultStarted(id, borrower, statusStartTime);
        } else if (!isInDefault && wasInDefault) {
            emit EventsLib.DefaultCleared(id, borrower);
        }

        // Calculate new markdown
        uint256 newMarkdown = 0;
        if (isInDefault) {
            uint256 timeInDefault = block.timestamp > statusStartTime ? block.timestamp - statusStartTime : 0;
            uint256 borrowerAssets = _getBorrowerAssets(id, borrower);

            newMarkdown = IMarkdownManager(manager).calculateMarkdown(borrower, borrowerAssets, timeInDefault);

            // Cap markdown at the borrower's actual outstanding debt
            // since markdown represents the write-down of the loan value
            if (newMarkdown > borrowerAssets) {
                newMarkdown = borrowerAssets;
            }
        }

        if (newMarkdown != lastMarkdown) {
            // Update borrower state
            markdownState[id][borrower].lastCalculatedMarkdown = uint128(newMarkdown);

            // Update market totals - use a separate function to avoid stack issues
            _updateMarketMarkdown(id, int256(newMarkdown) - int256(lastMarkdown));

            emit EventsLib.BorrowerMarkdownUpdated(id, borrower, lastMarkdown, newMarkdown);
        }
    }

    /// @notice Update market totals for markdown changes
    /// @param id Market ID
    /// @param markdownDelta Change in markdown (positive = increase, negative = decrease)
    function _updateMarketMarkdown(Id id, int256 markdownDelta) internal {
        if (markdownDelta == 0) return;

        Market memory m = market[id];

        if (markdownDelta > 0) {
            // Markdown increasing (borrower deeper in default)
            uint256 increase = uint256(markdownDelta);

            // Only reduce supply by what's actually available to avoid underflow
            // Track the actual reduction amount in totalMarkdownAmount for accurate reversal
            uint256 actualReduction = m.totalSupplyAssets >= increase ? increase : m.totalSupplyAssets;

            // Apply the reduction to supply and record what was actually marked down
            m.totalSupplyAssets = (m.totalSupplyAssets - actualReduction).toUint128();
            m.totalMarkdownAmount = (m.totalMarkdownAmount + actualReduction).toUint128();
        } else {
            // Markdown decreasing (borrower repaying/recovering)
            uint256 decrease = uint256(-markdownDelta);

            // Only restore supply up to the amount that was previously marked down
            // This ensures we don't create supply that was never removed
            uint256 maxRestore = m.totalMarkdownAmount;
            uint256 actualRestore = decrease <= maxRestore ? decrease : maxRestore;

            // Restore the supply and reduce the tracked markdown amount
            m.totalSupplyAssets = (m.totalSupplyAssets + actualRestore).toUint128();
            m.totalMarkdownAmount = (m.totalMarkdownAmount - actualRestore).toUint128();
        }

        market[id] = m;
    }

    /// @notice Get borrower's current borrow assets
    /// @param id Market ID
    /// @param borrower Borrower address
    /// @return assets Current borrow amount in assets
    function _getBorrowerAssets(Id id, address borrower) internal view returns (uint256 assets) {
        Market memory m = market[id];
        assets = uint256(position[id][borrower].borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    /// @notice Settle a borrower's account by writing off all remaining debt
    /// @dev Only callable by credit line contract
    /// @dev Should be called after any partial repayments have been made
    /// @param marketParams The market parameters
    /// @param borrower The borrower whose account to settle
    /// @return writtenOffAssets Amount of assets written off
    /// @return writtenOffShares Amount of shares written off
    function settleAccount(MarketParams memory marketParams, address borrower)
        external
        onlyCreditLine(marketParams.id())
        returns (uint256 writtenOffAssets, uint256 writtenOffShares)
    {
        Id id = marketParams.id();

        _accrueInterest(marketParams, id);
        _accrueBorrowerPremium(id, borrower);

        // Get position
        writtenOffShares = position[id][borrower].borrowShares;
        if (writtenOffShares == 0) revert ErrorsLib.NoAccountToSettle();

        Market memory m = market[id];

        // Calculate written off assets
        writtenOffAssets = writtenOffShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

        // Clear position and apply supply adjustment
        _applySettlement(id, borrower, writtenOffShares, writtenOffAssets);

        emit EventsLib.AccountSettled(id, msg.sender, borrower, writtenOffAssets, writtenOffShares);
    }

    /// @notice Apply settlement to storage
    function _applySettlement(Id id, address borrower, uint256 writtenOffShares, uint256 writtenOffAssets) internal {
        uint256 lastMarkdown = markdownState[id][borrower].lastCalculatedMarkdown;

        // Clear position
        position[id][borrower].borrowShares = 0;
        delete markdownState[id][borrower];
        delete repaymentObligation[id][borrower];

        // Update borrow totals
        market[id].totalBorrowShares = (market[id].totalBorrowShares - writtenOffShares).toUint128();
        market[id].totalBorrowAssets = (market[id].totalBorrowAssets - writtenOffAssets).toUint128();

        // Apply net supply adjustment
        uint128 totalSupplyAssets = market[id].totalSupplyAssets;
        int256 netAdjustment = int256(lastMarkdown) - int256(writtenOffAssets);
        if (netAdjustment > 0) {
            market[id].totalSupplyAssets = (totalSupplyAssets + uint256(netAdjustment)).toUint128();
        } else if (netAdjustment < 0) {
            uint256 loss = uint256(-netAdjustment);
            if (totalSupplyAssets < loss) revert ErrorsLib.InsufficientLiquidity();
            market[id].totalSupplyAssets = (totalSupplyAssets - loss).toUint128();
        }

        // Update markdown total
        if (lastMarkdown > 0) {
            uint128 totalMarkdownAmount = market[id].totalMarkdownAmount;
            market[id].totalMarkdownAmount =
                totalMarkdownAmount > lastMarkdown ? (totalMarkdownAmount - lastMarkdown).toUint128() : 0;
        }
    }
}
