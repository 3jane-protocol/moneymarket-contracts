// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IIrm} from "../../interfaces/IIrm.sol";
import {IJaneAdaptiveCurveIrm} from "./interfaces/IAdaptiveCurveIrm.sol";
import {IRMConfig} from "../../interfaces/IProtocolConfig.sol";
import {IMorphoCredit} from "../../interfaces/IMorphoCredit.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {ExpLib} from "./libraries/ExpLib.sol";
import {MathLib, WAD_INT as WAD} from "./libraries/MathLib.sol";
import {ConstantsLib} from "./libraries/ConstantsLib.sol";
import {MarketParamsLib} from "../../libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../../interfaces/IMorpho.sol";
import {MathLib as MorphoMathLib} from "../../libraries/MathLib.sol";
import {Initializable} from "@openzeppelin/proxy/utils/Initializable.sol";

/// @title AdaptiveCurveIrm
/// @author Morpho Labs
/// @custom:contact security@morpho.org
contract JaneAdaptiveCurveIrm is IJaneAdaptiveCurveIrm, Initializable {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MarketParamsLib for MarketParams;

    /* EVENTS */

    /// @notice Emitted when a borrow rate is updated.
    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    /* IMMUTABLES */

    /// @inheritdoc IAdaptiveCurveIrm
    address public immutable MORPHO;
    /// @inheritdoc IAdaptiveCurveIrm
    address public immutable AAVE_MARKET;

    /* STORAGE */

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => int256) public rateAtTarget;

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => int256) public aaveRate;

    /// @dev Storage gap for future upgrades (10 slots).
    uint256[10] private __gap;

    /* CONSTRUCTOR */

    /// @notice Constructor.
    /// @param morpho The address of Morpho.
    /// @param aaveMarket The address of Aave market.
    constructor(address morpho, address aaveMarket) {
        require(morpho != address(0), ErrorsLib.ZERO_ADDRESS);
        require(aaveMarket != address(0), ErrorsLib.ZERO_ADDRESS);

        MORPHO = morpho;
        AAVE_MARKET = aaveMarket;
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

        // Safe "unchecked" cast because endRateAtTarget >= 0.
        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));

        return avgRate;
    }

    /// @dev Returns the rate at target utilization.
    function touchAaveRate(MarketParams memory marketParams) external {
        Id id = marketParams.id();

        address underlying = IMorpho(MORPHO).idToMarketParams(id).collateralToken;

        ReserveDataLegacy memory reserveData = IAaveMarket(AAVE_MARKET).getReserveData(underlying);

        aaveRate[id] = int128((reserveData.currentVariableBorrowRate / 1e9)) / int128(365 days);
    }

    /// @dev Returns avgRate and endRateAtTarget.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _borrowRate(Id id, Market memory market) internal view returns (uint256, int256) {
        IRMConfig memory terms = IProtocolConfig(IMorphoCredit(MORPHO).protocolConfig()).getIRMConfig();

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
                endRateAtTarget = _newRateAtTarget(
                    id,
                    startRateAtTarget,
                    linearAdaptation,
                    terms.curveSteepness,
                    terms.minRateAtTarget,
                    terms.maxRateAtTarget
                );
                int256 midRateAtTarget = _newRateAtTarget(
                    id,
                    startRateAtTarget,
                    linearAdaptation / 2,
                    terms.curveSteepness,
                    terms.minRateAtTarget,
                    terms.maxRateAtTarget
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
        return (coeff.wMulToZero(err) + WAD).wMulToZero(int256(_rateAtTarget));
    }

    /// @dev Returns the new rate at target, for a given `startRateAtTarget` and a given `linearAdaptation`.
    /// The formula is: max(min(startRateAtTarget * exp(linearAdaptation), maxRateAtTarget), minRateAtTarget).
    function _newRateAtTarget(
        Id id,
        int256 startRateAtTarget,
        int256 linearAdaptation,
        int256 curveSteepness,
        int256 minRateAtTarget,
        int256 maxRateAtTarget
    ) internal view virtual returns (int256) {
        minRateAtTarget = aaveRate[id] * (curveSteepness / 1e18);
        // Non negative because MIN_RATE_AT_TARGET > 0.
        return startRateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(minRateAtTarget, maxRateAtTarget);
    }
}
