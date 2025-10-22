// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IIrm} from "../../interfaces/IIrm.sol";
import {IAdaptiveCurveIrm} from "./interfaces/IAdaptiveCurveIrm.sol";
import {IProtocolConfig, IRMConfig, IRMConfigTyped} from "../../interfaces/IProtocolConfig.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ExpLib} from "./libraries/ExpLib.sol";
import {MathLib, WAD_INT as WAD} from "./libraries/MathLib.sol";
import {MarketParamsLib} from "../../libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market, IMorphoCredit} from "../../interfaces/IMorpho.sol";
import {MathLib as MorphoMathLib} from "../../libraries/MathLib.sol";
import {Initializable} from "../../../lib/openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IAaveMarket} from "./interfaces/IAaveMarket.sol";

/// @title AdaptiveCurveIrm
/// @author Morpho Labs
/// @custom:contact security@morpho.org
contract AdaptiveCurveIrm is IAdaptiveCurveIrm, Initializable {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MorphoMathLib for uint256;
    using MarketParamsLib for MarketParams;

    /* EVENTS */

    /// @notice Emitted when a borrow rate is updated.
    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    /* IMMUTABLES */

    /// @inheritdoc IAdaptiveCurveIrm
    address public immutable MORPHO;

    /// @notice The Aave V3 pool address for fetching reserve data
    address public immutable AAVE_POOL;

    /// @notice The underlying USDC asset address
    address public immutable USDC;

    /* STORAGE */

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => int256) public rateAtTarget;

    /// @notice Tracks Aave normalized index data per market for spread calculation
    /// @dev Packed into a single storage slot: 96 + 96 + 64 = 256 bits
    struct AaveIndexData {
        uint96 lastNormalizedDebt; // Last recorded Aave normalized variable debt (RAY)
        uint96 lastNormalizedIncome; // Last recorded Aave normalized income (RAY)
        uint64 lastUpdate; // Timestamp of last index update
    }

    /// @notice Aave index data per market ID
    mapping(Id => AaveIndexData) public aaveIndexData;

    /// @dev Storage gap for future upgrades (8 slots after adding 2 for mapping).
    uint256[8] private __gap;

    /* CONSTRUCTOR */

    /// @notice Constructor.
    /// @param morpho The address of Morpho.
    /// @param aavePool The address of the Aave V3 pool.
    /// @param usdc The address of the underlying USDC asset.
    constructor(address morpho, address aavePool, address usdc) {
        require(morpho != address(0), ErrorsLib.ZERO_ADDRESS);
        require(aavePool != address(0), ErrorsLib.ZERO_ADDRESS);
        require(usdc != address(0), ErrorsLib.ZERO_ADDRESS);

        MORPHO = morpho;
        AAVE_POOL = aavePool;
        USDC = usdc;
        _disableInitializers();
    }

    function initialize() external initializer {}

    /* BORROW RATES */

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        (uint256 avgRate,) = _borrowRate(marketParams.id(), market);
        return avgRate;
    }

    /// @inheritdoc IIrm
    function borrowRate(MarketParams memory marketParams, Market memory market) public virtual returns (uint256) {
        require(msg.sender == MORPHO, ErrorsLib.NOT_MORPHO);

        Id id = marketParams.id();

        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, market);

        rateAtTarget[id] = endRateAtTarget;

        // Update Aave indices for next calculation
        _updateAaveIndices(id);

        // Safe "unchecked" cast because endRateAtTarget >= 0.
        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));

        return avgRate;
    }

    /// @dev Returns avgRate and endRateAtTarget.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _borrowRate(Id id, Market memory market) internal view returns (uint256, int256) {
        (uint256 adaptiveCurveRate, int256 endRateAtTarget) = _calculateAdaptiveCurve(id, market);

        // Calculate and add the Aave spread
        uint256 aaveSpread = _calculateAaveSpread(id);

        return (adaptiveCurveRate + aaveSpread, endRateAtTarget);
    }

    /// @dev Calculates the adaptive curve rate portion.
    function _calculateAdaptiveCurve(Id id, Market memory market) internal view returns (uint256, int256) {
        IRMConfigTyped memory terms = _unpackIRMConfig();

        // Safe "unchecked" cast because the utilization is smaller than 1 (scaled by WAD).
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);

        int256 errNormFactor =
            utilization > terms.targetUtilization ? WAD - terms.targetUtilization : terms.targetUtilization;
        int256 err = (utilization - terms.targetUtilization).wDivToZero(errNormFactor);

        int256 startRateAtTarget = rateAtTarget[id];

        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            // First interaction.
            avgRateAtTarget = terms.initialRateAtTarget;
            endRateAtTarget = terms.initialRateAtTarget;
        } else {
            // The speed is assumed constant between two updates, but it is in fact not constant because of interest.
            // So the rate is always underestimated.
            int256 speed = terms.adjustmentSpeed.wMulToZero(err);
            // market.lastUpdate != 0 because it is not the first interaction with this market.
            // Safe "unchecked" cast because block.timestamp - market.lastUpdate <= block.timestamp <= type(int256).max.
            int256 elapsed = int256(block.timestamp - market.lastUpdate);
            int256 linearAdaptation = speed * elapsed;

            if (linearAdaptation == 0) {
                // If linearAdaptation == 0, avgRateAtTarget = endRateAtTarget = startRateAtTarget;
                avgRateAtTarget = startRateAtTarget;
                endRateAtTarget = startRateAtTarget;
            } else {
                // Formula of the average rate that should be returned to Morpho Blue:
                // avg = 1/T * ∫_0^T curve(startRateAtTarget*exp(speed*x), err) dx
                // The integral is approximated with the trapezoidal rule:
                // avg ~= 1/T * Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / 2 * T/N
                // Where f(x) = startRateAtTarget*exp(speed*x)
                // avg ~= Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / (2 * N)
                // As curve is linear in its first argument:
                // avg ~= curve([Σ_i=1^N [f((i-1) * T/N) + f(i * T/N)] / (2 * N), err)
                // avg ~= curve([(f(0) + f(T))/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
                // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
                // With N = 2:
                // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + startRateAtTarget*exp(speed*T/2)] / 2, err)
                // avg ~= curve([startRateAtTarget + endRateAtTarget + 2*startRateAtTarget*exp(speed*T/2)] / 4, err)
                endRateAtTarget =
                    _newRateAtTarget(startRateAtTarget, linearAdaptation, terms.minRateAtTarget, terms.maxRateAtTarget);
                int256 midRateAtTarget = _newRateAtTarget(
                    startRateAtTarget, linearAdaptation / 2, terms.minRateAtTarget, terms.maxRateAtTarget
                );
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        // Safe "unchecked" cast because avgRateAtTarget >= 0.
        return (uint256(_curve(avgRateAtTarget, err, terms.curveSteepness)), endRateAtTarget);
    }

    /// @dev Returns the rate for a given `_rateAtTarget` and an `err`.
    /// The formula of the curve is the following:
    /// r = ((1-1/C)*err + 1) * rateAtTarget if err < 0
    ///     ((C-1)*err + 1) * rateAtTarget else.
    function _curve(int256 _rateAtTarget, int256 err, int256 curveSteepness) private pure returns (int256) {
        // Non negative because 1 - 1/C >= 0, C - 1 >= 0.
        int256 coeff = err < 0 ? WAD - WAD.wDivToZero(curveSteepness) : curveSteepness - WAD;
        // Non negative if _rateAtTarget >= 0 because if err < 0, coeff <= 1.
        return (coeff.wMulToZero(err) + WAD).wMulToZero(_rateAtTarget);
    }

    /// @dev Returns the new rate at target, for a given `startRateAtTarget` and a given `linearAdaptation`.
    /// The formula is: max(min(startRateAtTarget * exp(linearAdaptation), maxRateAtTarget), minRateAtTarget).
    function _newRateAtTarget(
        int256 startRateAtTarget,
        int256 linearAdaptation,
        int256 minRateAtTarget,
        int256 maxRateAtTarget
    ) internal view virtual returns (int256) {
        // Non negative because MIN_RATE_AT_TARGET > 0.
        return startRateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(minRateAtTarget, maxRateAtTarget);
    }

    /// @dev Unpacks IRMConfig into individual int256 values.
    /// @return terms The IRMConfigTyped struct.
    function _unpackIRMConfig() internal view returns (IRMConfigTyped memory) {
        IRMConfig memory terms = IProtocolConfig(IMorphoCredit(MORPHO).protocolConfig()).getIRMConfig();
        return IRMConfigTyped({
            curveSteepness: int256(terms.curveSteepness),
            adjustmentSpeed: int256(terms.adjustmentSpeed),
            targetUtilization: int256(terms.targetUtilization),
            initialRateAtTarget: int256(terms.initialRateAtTarget),
            minRateAtTarget: int256(terms.minRateAtTarget),
            maxRateAtTarget: int256(terms.maxRateAtTarget)
        });
    }

    /// @dev Calculates the Aave borrow-supply spread to be added to the adaptive curve rate.
    /// Uses time-weighted average rates from index growth to be manipulation-resistant.
    /// @param id The market ID
    /// @return The spread rate per second (scaled by WAD)
    function _calculateAaveSpread(Id id) internal view returns (uint256) {
        AaveIndexData memory lastData = aaveIndexData[id];

        // If never initialized, return 0 (will be initialized on first write)
        if (lastData.lastUpdate == 0) {
            return 0;
        }

        uint256 elapsed = block.timestamp - lastData.lastUpdate;

        // If no time has passed, no spread to calculate
        if (elapsed == 0) {
            return 0;
        }

        // Fetch current normalized indices (these are automatically up-to-date)
        uint256 currentNormalizedDebt = IAaveMarket(AAVE_POOL).getReserveNormalizedVariableDebt(USDC);
        uint256 currentNormalizedIncome = IAaveMarket(AAVE_POOL).getReserveNormalizedIncome(USDC);

        // Calculate rates from normalized index growth
        uint256 aaveBorrowRate =
            currentNormalizedDebt.wDivUp(lastData.lastNormalizedDebt).wInverseTaylorCompounded(elapsed);
        uint256 aaveSupplyRate =
            currentNormalizedIncome.wDivUp(lastData.lastNormalizedIncome).wInverseTaylorCompounded(elapsed);

        // The spread is the difference (can be 0 if rates are equal)
        return aaveBorrowRate > aaveSupplyRate ? aaveBorrowRate - aaveSupplyRate : 0;
    }

    /// @dev Updates the stored Aave normalized indices for the next spread calculation.
    /// @param id The market ID
    function _updateAaveIndices(Id id) internal {
        // Fetch current normalized indices (automatically includes all accrued interest)
        uint256 currentNormalizedDebt = IAaveMarket(AAVE_POOL).getReserveNormalizedVariableDebt(USDC);
        uint256 currentNormalizedIncome = IAaveMarket(AAVE_POOL).getReserveNormalizedIncome(USDC);

        AaveIndexData memory data = aaveIndexData[id];

        // Update normalized indices for next calculation
        // Safe to cast as Aave indices start at 1e27 and would take decades to overflow uint96
        data.lastNormalizedDebt = uint96(currentNormalizedDebt);
        data.lastNormalizedIncome = uint96(currentNormalizedIncome);
        data.lastUpdate = uint64(block.timestamp);

        aaveIndexData[id] = data;
    }
}
