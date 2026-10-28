// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IKeeperRelayer {
    function report() external returns (uint256 usd3Profit, uint256 usd3Loss, uint256 susd3Profit, uint256 susd3Loss);

    function keepers(address account) external view returns (bool);
    function usd3() external view returns (address);
    function susd3() external view returns (address);
}

interface IStrategyKeeper {
    function keeper() external view returns (address);
    function totalAssets() external view returns (uint256);
    function lastReport() external view returns (uint256);
}

interface IAprOracle {
    function getCurrentApr(address vault) external view returns (uint256 apr);
}

/// @title SimulateKeeperRelayerReportProfit
/// @notice Finds the USDC transfer to USD3 that produces an exact target USD3 profit through KeeperRelayer.report().
/// @dev All candidate funding uses `deal` on the fork. No transaction is broadcast and no Safe proposal is created.
contract SimulateKeeperRelayerReportProfit is Script, Test {
    address private constant PROTOCOL_SAFE = 0x33333333Bd7045F1A601A1E289D7AB21036fB5EF;
    address private constant KEEPER_RELAYER = 0xc22158100B823e1Ef612fBA265941efE9E7d7975;
    address private constant APR_ORACLE = 0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address private constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;

    uint256 private constant MIN_PROBE_USDC = 1e6;
    uint256 private constant MAX_PROBE_ATTEMPTS = 32;

    struct ReportResult {
        uint256 usd3Profit;
        uint256 usd3Loss;
        uint256 susd3Profit;
        uint256 susd3Loss;
        uint256 usd3Apr;
        uint256 susd3IncrementalApr;
    }

    /// @notice Solves and fully simulates a target expressed in USDC base units.
    /// @return requiredTransferUsdc USDC base units that must be transferred directly to USD3 before reporting.
    function run(uint256 targetUsd3Profit) external returns (uint256 requiredTransferUsdc) {
        return _run(targetUsd3Profit);
    }

    /// @notice Convenience entrypoint for a whole-USDC target.
    function runWholeUsdc(uint256 targetWholeUsdc) external returns (uint256 requiredTransferUsdc) {
        require(targetWholeUsdc <= type(uint256).max / 1e6, "target overflow");
        return _run(targetWholeUsdc * 1e6);
    }

    /// @notice Solves for a target USD3 APR in the same 1e18 format returned by the APR oracle.
    /// @dev Returns the minimum USDC transfer whose fully simulated oracle APR is at least the target.
    function runForApr(uint256 targetUsd3Apr) external returns (uint256 requiredTransferUsdc) {
        require(targetUsd3Apr > 0, "target APR required");
        _validateConfiguration();

        uint256 warpTo = vm.envOr("WARP_TO", uint256(0));
        if (warpTo != 0) {
            require(warpTo >= block.timestamp, "WARP_TO before fork timestamp");
            vm.warp(warpTo);
        }

        address keeperCaller = vm.envOr("KEEPER_CALLER", PROTOCOL_SAFE);
        require(IKeeperRelayer(KEEPER_RELAYER).keepers(keeperCaller), "KEEPER_CALLER not authorized");

        uint256 initialUsd3Usdc = IERC20(USDC).balanceOf(USD3);
        uint256 initialTotalAssets = IStrategyKeeper(USD3).totalAssets();
        uint256 initialLastReport = IStrategyKeeper(USD3).lastReport();
        uint256 snapshotId = vm.snapshotState();

        console2.log("=== Target USD3 APR via Keeper Relayer ===");
        console2.log("Keeper relayer:", KEEPER_RELAYER);
        console2.log("Keeper caller:", keeperCaller);
        console2.log("USD3:", USD3);
        console2.log("USDC transfer receiver:", USD3);
        console2.log("Target USD3 APR (1e18):", targetUsd3Apr);
        console2.log("Target USD3 APR:", _formatApr(targetUsd3Apr));
        console2.log("Initial USD3 USDC balance:", initialUsd3Usdc);
        console2.log("Initial USD3 total assets:", initialTotalAssets);
        console2.log("Initial USD3 last report:", initialLastReport);
        console2.log("Simulation timestamp:", block.timestamp);
        console2.log("");

        ReportResult memory calibrationResult;
        (requiredTransferUsdc, calibrationResult) =
            _findTransferForApr(snapshotId, initialUsd3Usdc, targetUsd3Apr, keeperCaller);

        console2.log("=== APR Solver Calibration ===");
        console2.log("Calculated required transfer:", requiredTransferUsdc);
        _logReportResult(calibrationResult);
        _logCurrentAprs(calibrationResult);
        console2.log("Calibration USD3 APR (1e18):", calibrationResult.usd3Apr);
        console2.log("");

        ReportResult memory finalResult = _executeReport(initialUsd3Usdc, requiredTransferUsdc, keeperCaller);
        require(finalResult.usd3Apr >= targetUsd3Apr, "final USD3 APR below target");
        require(finalResult.usd3Loss == 0, "final USD3 report has a loss");

        console2.log("=== Final Full Keeper-Relayer Simulation ===");
        console2.log("Required USDC transfer:", requiredTransferUsdc);
        console2.log("Required whole USDC:", requiredTransferUsdc / 1e6);
        console2.log("Required USDC remainder:", requiredTransferUsdc % 1e6);
        console2.log("Final USD3 USDC balance before report:", initialUsd3Usdc + requiredTransferUsdc);
        _logReportResult(finalResult);
        _logCurrentAprs(finalResult);
        console2.log("Target USD3 APR (1e18):", targetUsd3Apr);
        console2.log("Actual USD3 APR (1e18):", finalResult.usd3Apr);
        console2.log("APR overshoot (1e18):", finalResult.usd3Apr - targetUsd3Apr);
        console2.log("Final USD3 total assets:", IStrategyKeeper(USD3).totalAssets());
        console2.log("Final USD3 last report:", IStrategyKeeper(USD3).lastReport());
        console2.log("");
        console2.log("RESULT_REQUIRED_USDC_BASE_UNITS:", requiredTransferUsdc);
    }

    function _run(uint256 targetUsd3Profit) private returns (uint256 requiredTransferUsdc) {
        require(targetUsd3Profit > 0, "target profit required");
        _validateConfiguration();

        uint256 warpTo = vm.envOr("WARP_TO", uint256(0));
        if (warpTo != 0) {
            require(warpTo >= block.timestamp, "WARP_TO before fork timestamp");
            vm.warp(warpTo);
        }

        address keeperCaller = vm.envOr("KEEPER_CALLER", PROTOCOL_SAFE);
        require(IKeeperRelayer(KEEPER_RELAYER).keepers(keeperCaller), "KEEPER_CALLER not authorized");

        uint256 initialUsd3Usdc = IERC20(USDC).balanceOf(USD3);
        uint256 initialTotalAssets = IStrategyKeeper(USD3).totalAssets();
        uint256 initialLastReport = IStrategyKeeper(USD3).lastReport();
        uint256 snapshotId = vm.snapshotState();

        console2.log("=== Target USD3 Profit via Keeper Relayer ===");
        console2.log("Keeper relayer:", KEEPER_RELAYER);
        console2.log("Keeper caller:", keeperCaller);
        console2.log("USD3:", USD3);
        console2.log("USDC transfer receiver:", USD3);
        console2.log("Target profit (USDC base units):", targetUsd3Profit);
        console2.log("Target profit (whole USDC):", targetUsd3Profit / 1e6);
        console2.log("Initial USD3 USDC balance:", initialUsd3Usdc);
        console2.log("Initial USD3 total assets:", initialTotalAssets);
        console2.log("Initial USD3 last report:", initialLastReport);
        console2.log("Simulation timestamp:", block.timestamp);
        console2.log("");

        (uint256 probeTransfer, ReportResult memory probeResult) =
            _findSuccessfulProbe(snapshotId, initialUsd3Usdc, targetUsd3Profit, keeperCaller);

        requiredTransferUsdc = _deriveRequiredTransfer(targetUsd3Profit, probeTransfer, probeResult);

        console2.log("=== Calibration Report ===");
        console2.log("Probe transfer:", probeTransfer);
        _logReportResult(probeResult);
        _logCurrentAprs(probeResult);
        console2.log("Calculated required transfer:", requiredTransferUsdc);
        console2.log("");

        ReportResult memory finalResult = _executeReport(initialUsd3Usdc, requiredTransferUsdc, keeperCaller);
        require(finalResult.usd3Profit == targetUsd3Profit, "final USD3 profit does not equal target");
        require(finalResult.usd3Loss == 0, "final USD3 report has a loss");

        console2.log("=== Final Full Keeper-Relayer Simulation ===");
        console2.log("Required USDC transfer:", requiredTransferUsdc);
        console2.log("Required whole USDC:", requiredTransferUsdc / 1e6);
        console2.log("Required USDC remainder:", requiredTransferUsdc % 1e6);
        console2.log("Final USD3 USDC balance before report:", initialUsd3Usdc + requiredTransferUsdc);
        _logReportResult(finalResult);
        _logCurrentAprs(finalResult);
        console2.log("Final USD3 total assets:", IStrategyKeeper(USD3).totalAssets());
        console2.log("Final USD3 last report:", IStrategyKeeper(USD3).lastReport());
        console2.log("");
        console2.log("RESULT_REQUIRED_USDC_BASE_UNITS:", requiredTransferUsdc);
    }

    function _findSuccessfulProbe(
        uint256 snapshotId,
        uint256 initialUsd3Usdc,
        uint256 targetUsd3Profit,
        address keeperCaller
    ) private returns (uint256 probeTransfer, ReportResult memory probeResult) {
        probeTransfer = targetUsd3Profit > MIN_PROBE_USDC ? targetUsd3Profit : MIN_PROBE_USDC;
        bytes memory lastRevertData;

        for (uint256 i; i < MAX_PROBE_ATTEMPTS; ++i) {
            (bool success, ReportResult memory result, bytes memory returnData) =
                _tryReport(initialUsd3Usdc, probeTransfer, keeperCaller);
            require(vm.revertToState(snapshotId), "failed to restore fork snapshot");

            if (success) return (probeTransfer, result);
            lastRevertData = returnData;

            require(probeTransfer <= type(uint256).max / 2, "probe overflow");
            probeTransfer *= 2;
        }

        console2.log("Last KeeperRelayer.report() revert data:");
        console2.logBytes(lastRevertData);
        revert("unable to find successful keeper-relayer probe");
    }

    function _findTransferForApr(
        uint256 snapshotId,
        uint256 initialUsd3Usdc,
        uint256 targetUsd3Apr,
        address keeperCaller
    ) private returns (uint256 requiredTransferUsdc, ReportResult memory targetResult) {
        uint256 low;
        uint256 high = MIN_PROBE_USDC;
        bool lowReportSucceeded;
        bool foundHigh;
        bytes memory lastRevertData;

        for (uint256 i; i < MAX_PROBE_ATTEMPTS; ++i) {
            (bool success, ReportResult memory result, bytes memory returnData) =
                _tryReport(initialUsd3Usdc, high, keeperCaller);
            require(vm.revertToState(snapshotId), "failed to restore fork snapshot");

            if (success) {
                if (result.usd3Apr >= targetUsd3Apr) {
                    targetResult = result;
                    foundHigh = true;
                    break;
                }
                lowReportSucceeded = true;
            } else {
                lastRevertData = returnData;
                if (lowReportSucceeded) {
                    console2.log("KeeperRelayer.report() reverted above the last successful APR probe:");
                    console2.logBytes(lastRevertData);
                    revert("target APR exceeds successful relayer range");
                }
            }

            low = high;
            require(high <= type(uint256).max / 2, "APR probe overflow");
            high *= 2;
        }

        if (!foundHigh) {
            console2.log("Last KeeperRelayer.report() revert data:");
            console2.logBytes(lastRevertData);
            revert("unable to bracket target APR");
        }

        for (uint256 i; i < 256 && low + 1 < high; ++i) {
            uint256 mid = low + (high - low) / 2;
            (bool success, ReportResult memory result, bytes memory returnData) =
                _tryReport(initialUsd3Usdc, mid, keeperCaller);
            require(vm.revertToState(snapshotId), "failed to restore fork snapshot");

            if (!success) {
                if (lowReportSucceeded) {
                    console2.log("Unexpected KeeperRelayer.report() revert inside APR search range:");
                    console2.logBytes(returnData);
                    revert("non-monotonic relayer revert during APR search");
                }
                low = mid;
            } else if (result.usd3Apr >= targetUsd3Apr) {
                high = mid;
                targetResult = result;
            } else {
                low = mid;
                lowReportSucceeded = true;
            }
        }

        requiredTransferUsdc = high;
    }

    function _deriveRequiredTransfer(uint256 targetUsd3Profit, uint256 probeTransfer, ReportResult memory probeResult)
        private
        pure
        returns (uint256 requiredTransferUsdc)
    {
        require(probeTransfer <= type(uint256).max - targetUsd3Profit, "calculation overflow");
        uint256 targetPlusProbe = targetUsd3Profit + probeTransfer;
        require(targetPlusProbe <= type(uint256).max - probeResult.usd3Loss, "calculation overflow");

        uint256 grossRequired = targetPlusProbe + probeResult.usd3Loss;
        console2.log("Base profit", probeResult.usd3Profit);
        require(probeResult.usd3Profit <= grossRequired, "target below unavoidable USD3 profit");
        requiredTransferUsdc = grossRequired - probeResult.usd3Profit;
    }

    function _executeReport(uint256 initialUsd3Usdc, uint256 transferUsdc, address keeperCaller)
        private
        returns (ReportResult memory result)
    {
        (bool success, ReportResult memory reportResult, bytes memory returnData) =
            _tryReport(initialUsd3Usdc, transferUsdc, keeperCaller);
        if (!success) {
            console2.log("KeeperRelayer.report() revert data:");
            console2.logBytes(returnData);
            revert("final keeper-relayer report reverted");
        }
        return reportResult;
    }

    function _tryReport(uint256 initialUsd3Usdc, uint256 transferUsdc, address keeperCaller)
        private
        returns (bool success, ReportResult memory result, bytes memory returnData)
    {
        require(initialUsd3Usdc <= type(uint256).max - transferUsdc, "balance overflow");
        deal(USDC, USD3, initialUsd3Usdc + transferUsdc);

        vm.prank(keeperCaller);
        (success, returnData) = KEEPER_RELAYER.call(abi.encodeCall(IKeeperRelayer.report, ()));
        if (!success) return (false, result, returnData);
        require(returnData.length == 128, "unexpected KeeperRelayer.report return data");

        (result.usd3Profit, result.usd3Loss, result.susd3Profit, result.susd3Loss) =
            abi.decode(returnData, (uint256, uint256, uint256, uint256));

        IAprOracle oracle = IAprOracle(APR_ORACLE);
        result.usd3Apr = oracle.getCurrentApr(USD3);
        result.susd3IncrementalApr = oracle.getCurrentApr(SUSD3);
    }

    function _validateConfiguration() private view {
        IKeeperRelayer relayer = IKeeperRelayer(KEEPER_RELAYER);
        require(relayer.usd3() == USD3, "relayer USD3 mismatch");
        require(relayer.susd3() == SUSD3, "relayer sUSD3 mismatch");
        require(IStrategyKeeper(USD3).keeper() == KEEPER_RELAYER, "USD3 keeper mismatch");
        require(IStrategyKeeper(SUSD3).keeper() == KEEPER_RELAYER, "sUSD3 keeper mismatch");
    }

    function _logReportResult(ReportResult memory result) private pure {
        console2.log("USD3 profit:", result.usd3Profit);
        console2.log("USD3 loss:", result.usd3Loss);
        console2.log("sUSD3 profit:", result.susd3Profit);
        console2.log("sUSD3 loss:", result.susd3Loss);
    }

    function _logCurrentAprs(ReportResult memory result) private pure {
        console2.log("Simulated current APR:");
        console2.log("  USD3:", _formatApr(result.usd3Apr));
        console2.log("  sUSD3:", _formatApr(result.usd3Apr + result.susd3IncrementalApr));
    }

    function _formatApr(uint256 apr) private pure returns (string memory) {
        uint256 percentage = (apr * 10_000) / 1e18;
        uint256 whole = percentage / 100;
        uint256 decimal = percentage % 100;

        return string(abi.encodePacked(vm.toString(whole), ".", decimal < 10 ? "0" : "", vm.toString(decimal), "%"));
    }
}
