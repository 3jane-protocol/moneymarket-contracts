// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {IUSD3} from "./interfaces/IUSD3.sol";

/// @title KeeperRelayer
/// @author 3Jane
/// @custom:contact support@3jane.xyz
/// @notice Atomically reports USD3 before sUSD3 for a configurable set of keeper accounts.
/// @dev Administrative authorization follows USD3's live management address, deliberately including sUSD3's health
/// configuration; the strategies are expected to share one management. USD3 health limits are denominated in
/// USDC NAV, while sUSD3 health limits are denominated in USD3 shares. Junior loss limits must account for first-loss
/// amplification, and junior profit limits must account for fee-mint amplification.
/// @dev Disabling a health check skips only that strategy's next report, then automatically re-enables the check.
/// ReportDeltaMismatch and wiring validation are always enforced.
/// @dev Every report synchronizes USD3's tranche share before reporting either strategy. An invalid ProtocolConfig
/// tranche share makes synchronization revert and fail-closes the report before either strategy records new state.
contract KeeperRelayer {
    uint256 internal constant MAX_BPS = 10_000;

    address public immutable usd3;
    address public immutable susd3;

    mapping(address keeper => bool authorized) public keepers;

    struct HealthCheckConfig {
        uint32 profitLimitRatio;
        uint16 lossLimitRatio;
        bool doHealthCheck;
    }

    mapping(address strategy => HealthCheckConfig config) public healthCheck;

    event KeeperSet(address indexed keeper, bool indexed authorized);
    event ProfitLimitRatioSet(address indexed strategy, uint256 ratio);
    event LossLimitRatioSet(address indexed strategy, uint256 ratio);
    event DoHealthCheckSet(address indexed strategy, bool doHealthCheck);
    event Reported(address indexed strategy, uint256 profit, uint256 loss, uint256 preTotalAssets, bool healthChecked);

    error NotManagement(address caller);
    error NotKeeper(address caller);
    error InvalidStrategy(address strategy);
    error HealthCheckFailed(address strategy, uint256 profit, uint256 loss, uint256 preTotalAssets);
    error ReportDeltaMismatch(
        address strategy, uint256 reportedProfit, uint256 reportedLoss, uint256 expectedProfit, uint256 expectedLoss
    );
    error RelayerNotKeeper(address strategy, address configuredKeeper);
    error Susd3LinkMismatch(address actual);
    error Susd3AssetMismatch(address actual);
    error FeeRecipientNotSusd3(address actual);
    error NonzeroSusd3PerformanceFee(uint256 fee);
    error InvalidProfitLimit(uint256 ratio);
    error InvalidLossLimit(uint256 ratio);

    modifier onlyManagement() {
        if (msg.sender != ITokenizedStrategy(usd3).management()) revert NotManagement(msg.sender);
        _;
    }

    modifier onlyKeepers() {
        if (!keepers[msg.sender] && msg.sender != ITokenizedStrategy(usd3).management()) revert NotKeeper(msg.sender);
        _;
    }

    /// @notice Initializes the immutable strategy pair, keepers, and default health limits.
    /// @param _usd3 Address of the USD3 strategy; sUSD3 is read from its configured link.
    /// @param _keepers Initial accounts authorized to call keeper operations.
    constructor(address _usd3, address[] memory _keepers) {
        if (_usd3 == address(0)) revert ErrorsLib.ZeroAddress();
        address _susd3 = IUSD3(_usd3).sUSD3();
        if (_susd3 == address(0)) revert ErrorsLib.ZeroAddress();
        address susd3Asset = ITokenizedStrategy(_susd3).asset();
        if (susd3Asset != _usd3) revert Susd3AssetMismatch(susd3Asset);

        usd3 = _usd3;
        susd3 = _susd3;

        address[2] memory strategies = [_usd3, _susd3];
        for (uint256 i = 0; i < strategies.length; i++) {
            healthCheck[strategies[i]] = HealthCheckConfig(uint32(MAX_BPS), 0, true);
            emit ProfitLimitRatioSet(strategies[i], MAX_BPS);
            emit LossLimitRatioSet(strategies[i], 0);
        }

        for (uint256 i = 0; i < _keepers.length; i++) {
            _setKeeper(_keepers[i], true);
        }
    }

    /// @notice Reports USD3 and then sUSD3 in the same transaction.
    /// @return usd3Profit Profit reported by USD3 in USDC NAV units.
    /// @return usd3Loss Loss reported by USD3 in USDC NAV units.
    /// @return susd3Profit Profit reported by sUSD3 in USD3-share units.
    /// @return susd3Loss Loss reported by sUSD3 in USD3-share units.
    function report()
        external
        onlyKeepers
        returns (uint256 usd3Profit, uint256 usd3Loss, uint256 susd3Profit, uint256 susd3Loss)
    {
        _validateWiring();
        IUSD3(usd3).syncTrancheShare();

        (usd3Profit, usd3Loss) = _reportStrategy(usd3);
        (susd3Profit, susd3Loss) = _reportStrategy(susd3);
    }

    /// @notice Rebalances USD3 without recording a report or applying health checks.
    function tend() external onlyKeepers {
        ITokenizedStrategy(usd3).tend();
    }

    /// @notice Forwards USD3's tend trigger with calldata retargeted at this relayer's tend().
    function tendTrigger() external view returns (bool shouldTend, bytes memory callData) {
        (shouldTend,) = IUSD3(usd3).tendTrigger();
        callData = abi.encodeWithSelector(this.tend.selector);
    }

    /// @notice Adds or removes an authorized keeper account.
    function setKeeper(address keeper, bool authorized) external onlyManagement {
        _setKeeper(keeper, authorized);
    }

    /// @notice Sets a strategy's maximum profit ratio for one report, in basis points of pre-report assets.
    /// @dev Ratios above 10,000 are permitted; junior fee-mint amplification can exceed 100% legitimately.
    function setProfitLimitRatio(address strategy, uint32 ratio) external onlyManagement {
        HealthCheckConfig storage config = _config(strategy);
        if (ratio == 0) revert InvalidProfitLimit(ratio);
        config.profitLimitRatio = ratio;
        emit ProfitLimitRatioSet(strategy, ratio);
    }

    /// @notice Sets a strategy's maximum loss ratio for one report, in basis points of pre-report assets.
    function setLossLimitRatio(address strategy, uint16 ratio) external onlyManagement {
        HealthCheckConfig storage config = _config(strategy);
        if (ratio >= MAX_BPS) revert InvalidLossLimit(ratio);
        config.lossLimitRatio = ratio;
        emit LossLimitRatioSet(strategy, ratio);
    }

    /// @notice Enables or disables a strategy's health check for its next report.
    function setDoHealthCheck(address strategy, bool doHealthCheck) external onlyManagement {
        _config(strategy).doHealthCheck = doHealthCheck;
        emit DoHealthCheckSet(strategy, doHealthCheck);
    }

    function _setKeeper(address keeper, bool authorized) internal {
        if (keeper == address(0)) revert ErrorsLib.ZeroAddress();
        if (keepers[keeper] == authorized) revert ErrorsLib.AlreadySet();
        keepers[keeper] = authorized;
        emit KeeperSet(keeper, authorized);
    }

    function _validateWiring() internal view {
        address usd3Keeper = ITokenizedStrategy(usd3).keeper();
        if (usd3Keeper != address(this)) revert RelayerNotKeeper(usd3, usd3Keeper);

        address susd3Keeper = ITokenizedStrategy(susd3).keeper();
        if (susd3Keeper != address(this)) revert RelayerNotKeeper(susd3, susd3Keeper);

        _validatePair(usd3, susd3);

        address feeRecipient = ITokenizedStrategy(usd3).performanceFeeRecipient();
        if (feeRecipient != susd3) revert FeeRecipientNotSusd3(feeRecipient);

        uint256 susd3PerformanceFee = ITokenizedStrategy(susd3).performanceFee();
        if (susd3PerformanceFee != 0) revert NonzeroSusd3PerformanceFee(susd3PerformanceFee);
    }

    function _reportStrategy(address strategy) internal returns (uint256 profit, uint256 loss) {
        ITokenizedStrategy tokenizedStrategy = ITokenizedStrategy(strategy);
        uint256 preTotalAssets = tokenizedStrategy.totalAssets();
        (profit, loss) = tokenizedStrategy.report();
        uint256 postTotalAssets = tokenizedStrategy.totalAssets();

        uint256 expectedProfit = postTotalAssets > preTotalAssets ? postTotalAssets - preTotalAssets : 0;
        uint256 expectedLoss = preTotalAssets > postTotalAssets ? preTotalAssets - postTotalAssets : 0;
        if (profit != expectedProfit || loss != expectedLoss) {
            revert ReportDeltaMismatch(strategy, profit, loss, expectedProfit, expectedLoss);
        }

        HealthCheckConfig storage config = healthCheck[strategy];
        bool checked = config.doHealthCheck;
        if (checked) {
            if (
                profit > (preTotalAssets * config.profitLimitRatio) / MAX_BPS
                    || loss > (preTotalAssets * config.lossLimitRatio) / MAX_BPS
            ) {
                revert HealthCheckFailed(strategy, profit, loss, preTotalAssets);
            }
        } else {
            config.doHealthCheck = true;
        }

        emit Reported(strategy, profit, loss, preTotalAssets, checked);
    }

    function _config(address strategy) internal view returns (HealthCheckConfig storage config) {
        if (strategy != usd3 && strategy != susd3) revert InvalidStrategy(strategy);
        return healthCheck[strategy];
    }

    function _validatePair(address _usd3, address _susd3) private view {
        address linkedSusd3 = IUSD3(_usd3).sUSD3();
        if (linkedSusd3 != _susd3) revert Susd3LinkMismatch(linkedSusd3);

        address susd3Asset = ITokenizedStrategy(_susd3).asset();
        if (susd3Asset != _usd3) revert Susd3AssetMismatch(susd3Asset);
    }
}
