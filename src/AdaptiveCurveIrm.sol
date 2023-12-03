// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IIrm} from "../lib/morpho-blue/src/interfaces/IIrm.sol";

import {UtilsLib} from "./libraries/UtilsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD_INT as WAD} from "./libraries/MathLib.sol";
import {ExpLib} from "./libraries/adaptive-curve/ExpLib.sol";
import {MarketParamsLib} from "../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MathLib as MorphoMathLib} from "../lib/morpho-blue/src/libraries/MathLib.sol";

/// @title AdaptiveCurveIrm
/// @author Morpho Labs
/// @custom:contact security@morpho.org
contract AdaptiveCurveIrm is IIrm {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MorphoMathLib for uint256;
    using MarketParamsLib for MarketParams;

    /* EVENTS */

    /// @notice Emitted when a borrow rate is updated.
    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    /* CONSTANT */

    /// @notice Address of Morpho.
    address public immutable MORPHO;

    /// @notice Curve steepness (scaled by WAD).
    int256 public constant CURVE_STEEPNESS = 4 ether;

    /// @notice Adjustment speed per second (scaled by WAD).
    int256 public constant ADJUSTMENT_SPEED = int256(50 ether) / 365 days;

    /// @notice Target utilization (scaled by WAD).
    int256 public constant TARGET_UTILIZATION = 0.9 ether;

    /// @notice Initial rate at target per second (scaled by WAD).
    int256 public constant INITIAL_RATE_AT_TARGET = int256(0.04 ether) / 365 days;

    /// @notice Mininimum rate at target per second (scaled by WAD) (0.1% APR).
    int256 public constant MIN_RATE_AT_TARGET = int256(0.001 ether) / 365 days;

    /// @notice Maximum rate at target per second (scaled by WAD) (1B% APR).
    int256 public constant MAX_RATE_AT_TARGET = int256(0.01e9 ether) / 365 days;

    /* STORAGE */

    /// @notice Rate at target utilization.
    /// @dev Tells the height of the curve.
    mapping(Id => int256) public rateAtTarget;

    /* CONSTRUCTOR */

    /// @notice Constructor.
    /// @param morpho The address of Morpho.
    constructor(address morpho) {
        require(morpho != address(0), ErrorsLib.ZERO_ADDRESS);

        MORPHO = morpho;
    }

    /* BORROW RATES */

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        (uint256 avgRate,) = _borrowRate(marketParams.id(), market);
        return avgRate;
    }

    /// @inheritdoc IIrm
    function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256) {
        require(msg.sender == MORPHO, ErrorsLib.NOT_MORPHO);

        Id id = marketParams.id();

        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, market);

        rateAtTarget[id] = endRateAtTarget;

        // Safe "unchecked" cast because endRateAtTarget >= 0.
        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));

        return avgRate;
    }

    /// @dev Returns avgRate and endRateAtTarget.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _borrowRate(Id id, Market memory market) private view returns (uint256, int256) {
        // Safe "unchecked" cast because the utilization is smaller than 1 (scaled by WAD).
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);

        int256 errNormFactor = utilization > TARGET_UTILIZATION ? WAD - TARGET_UTILIZATION : TARGET_UTILIZATION;
        int256 err = (utilization - TARGET_UTILIZATION).wDivDown(errNormFactor);

        int256 startRateAtTarget = rateAtTarget[id];

        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            // First interaction.
            avgRateAtTarget = INITIAL_RATE_AT_TARGET;
            endRateAtTarget = INITIAL_RATE_AT_TARGET;
        } else {
            // Note that the speed is assumed constant between two interactions, but in theory it increases because of
            // interests. So the rate will be slightly underestimated.
            int256 speed = ADJUSTMENT_SPEED.wMulDown(err);
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
                endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation);
                int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2);
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        // Safe "unchecked" cast because avgRateAtTarget >= 0.
        return (uint256(_curve(avgRateAtTarget, err)), endRateAtTarget);
    }

    /// @dev Returns the rate for a given `_rateAtTarget` and an `err`.
    /// The formula of the curve is the following:
    /// r = ((1-1/C)*err + 1) * rateAtTarget if err < 0
    ///     ((C-1)*err + 1) * rateAtTarget else.
    function _curve(int256 _rateAtTarget, int256 err) private pure returns (int256) {
        // Non negative because 1 - 1/C >= 0, C - 1 >= 0.
        int256 coeff = err < 0 ? WAD - WAD.wDivDown(CURVE_STEEPNESS) : CURVE_STEEPNESS - WAD;
        // Non negative if _rateAtTarget >= 0 because if err < 0, coeff <= 1.
        return (coeff.wMulDown(err) + WAD).wMulDown(int256(_rateAtTarget));
    }

    /// @dev Returns the new rate at target, for a given `startRateAtTarget` and a given `linearAdaptation`.
    /// The formula is: max(min(startRateAtTarget * exp(linearAdaptation), maxRateAtTarget), minRateAtTarget).
    function _newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation) private pure returns (int256) {
        // Non negative because MIN_RATE_AT_TARGET > 0.
        return startRateAtTarget.wMulDown(ExpLib.wExp(linearAdaptation)).bound(MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET);
    }
}
